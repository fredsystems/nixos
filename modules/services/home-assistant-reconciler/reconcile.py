"""Apply a declared Home Assistant configuration through its APIs.

Home Assistant keeps onboarding, integration config entries, areas and the
device and entity registries in .storage, which configuration.yaml cannot
reach. This applies a JSON declaration of them through the same REST and
websocket APIs the frontend uses, and is safe to run any number of times:
a second run with the same declaration changes nothing.

Usage: reconcile <declaration.json>

Secrets are referenced in the declaration as {"_secret": "<name>"} and read
from $CREDENTIALS_DIRECTORY/<name> (systemd LoadCredential=).
"""

import asyncio
import hashlib
import json
import logging
import os
import re
import sys
import time
from pathlib import Path

import aiohttp

# Never pruned, whatever keepDomains says: the companion app creates these
# entries when a phone registers, so they can never be declared.
ALWAYS_KEEP = frozenset({"mobile_app"})

log = logging.getLogger("reconcile")


class ReconcileError(Exception):
    pass


def read_secret(name):
    directory = os.environ.get("CREDENTIALS_DIRECTORY")
    if not directory:
        raise ReconcileError(f"secret {name!r} needs $CREDENTIALS_DIRECTORY")
    path = Path(directory) / name
    if not path.is_file():
        raise ReconcileError(f"secret {name!r} not found at {path}")
    return path.read_text().strip()


def resolve(value):
    """Replace every {"_secret": name} in a value with the secret's text."""
    if isinstance(value, dict):
        if set(value) == {"_secret"}:
            return read_secret(value["_secret"])
        return {k: resolve(v) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v) for v in value]
    return value


def digest(value):
    blob = json.dumps(value, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode()).hexdigest()


def describe_step(result):
    """Summarise what a flow step asks for, for error messages."""
    if result.get("type") == "menu":
        return f"a menu of {result.get('menu_options')}"
    fields = []
    for field in result.get("data_schema") or []:
        mark = "" if field.get("required") else "?"
        fields.append(f"{field.get('name')}{mark}")
    return f"a form with fields {fields}"


class Api:
    def __init__(self, session, url):
        self.session = session
        self.url = url.rstrip("/")
        self.token = None

    async def request(self, method, path, *, body=None, form=None, auth=True):
        headers = {}
        if auth and self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        async with self.session.request(
            method, self.url + path, headers=headers, json=body, data=form
        ) as response:
            text = await response.text()
            if response.status >= 400:
                raise ReconcileError(
                    f"{method} {path}: HTTP {response.status}: {text[:500]}"
                )
            return json.loads(text) if text else None


class Websocket:
    def __init__(self, ws, timeout):
        self.ws = ws
        self.timeout = timeout
        self.next_id = 0

    @classmethod
    async def connect(cls, session, url, token, timeout):
        ws = await session.ws_connect(
            url.rstrip("/").replace("http", "ws", 1) + "/api/websocket",
            max_msg_size=0,
        )
        self = cls(ws, timeout)
        hello = await self.receive()
        if hello.get("type") != "auth_required":
            raise ReconcileError(f"unexpected websocket greeting: {hello}")
        await ws.send_json({"type": "auth", "access_token": token})
        reply = await self.receive()
        if reply.get("type") != "auth_ok":
            raise ReconcileError(f"websocket auth failed: {reply}")
        return self

    async def receive(self):
        """The next message, or ReconcileError if none arrives in time: a
        connection that goes silent must not hold the oneshot forever."""
        try:
            return await self.ws.receive_json(timeout=self.timeout)
        except asyncio.TimeoutError:
            raise ReconcileError(
                f"websocket: no message in {self.timeout}s"
            ) from None

    async def call(self, kind, **fields):
        self.next_id += 1
        await self.ws.send_json({"id": self.next_id, "type": kind, **fields})
        while True:
            msg = await self.receive()
            if msg.get("id") == self.next_id and msg.get("type") == "result":
                if not msg.get("success"):
                    raise ReconcileError(f"{kind}: {msg.get('error')}")
                return msg.get("result")

    async def close(self):
        await self.ws.close()


class Reconciler:
    def __init__(self, decl, session):
        self.decl = decl
        self.api = Api(session, decl["urls"][0])
        self.session = session
        self.ws = None
        self.refresh_token = None
        self.changes = 0
        self.warnings = 0
        self.onboarded_now = False
        self.state_path = Path(decl["stateFile"])
        self.state = self.load_state()
        # Entities keepEntities excludes, by entity_key, filled as devices
        # are reconciled.
        self.keep_excluded = set()

    # -- bookkeeping -----------------------------------------------------

    def changed(self, what):
        self.changes += 1
        log.info("changed: %s", what)

    def warn(self, what):
        self.warnings += 1
        log.warning("%s", what)

    def load_state(self):
        if self.state_path.is_file():
            return json.loads(self.state_path.read_text())
        return {"integrations": {}}

    def save_state(self):
        tmp = self.state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.state, indent=2, sort_keys=True) + "\n")
        tmp.replace(self.state_path)

    # -- startup and auth ------------------------------------------------

    async def wait_for_api(self):
        """Wait for the HTTP API, and return the onboarding steps.

        Once onboarding is finished, Home Assistant no longer registers the
        onboarding views at startup, so a 404 means every step is done.
        """
        deadline = time.monotonic() + self.decl["startTimeout"]
        while True:
            # Each candidate port in turn: Home Assistant is on the old one
            # until a declared server_port change restarts it on the new.
            for url in self.decl["urls"]:
                try:
                    async with self.session.get(url + "/api/onboarding") as r:
                        if r.status == 404:
                            self.api.url = url
                            return []
                        if r.status == 200:
                            self.api.url = url
                            return await r.json()
                        raise ReconcileError(f"GET /api/onboarding: HTTP {r.status}")
                # A port that accepts but never answers times out; try the next.
                except (aiohttp.ClientError, asyncio.TimeoutError, ReconcileError) as err:
                    if time.monotonic() > deadline:
                        raise ReconcileError(f"Home Assistant never answered: {err}")
            await asyncio.sleep(2)

    async def authenticate(self, onboarding):
        owner = self.decl["owner"]
        password = resolve(owner["password"])
        client_id = self.api.url + "/"
        done = {step["step"]: step["done"] for step in onboarding}

        if not done.get("user", True):
            result = await self.api.request(
                "POST",
                "/api/onboarding/users",
                auth=False,
                body={
                    "client_id": client_id,
                    "name": owner["name"],
                    "username": owner["username"],
                    "password": password,
                    "language": owner["language"],
                },
            )
            code = result["auth_code"]
            self.changed(f"onboarding: created owner {owner['username']!r}")
        else:
            flow = await self.api.request(
                "POST",
                "/auth/login_flow",
                auth=False,
                body={
                    "client_id": client_id,
                    "handler": ["homeassistant", None],
                    "redirect_uri": client_id,
                },
            )
            result = await self.api.request(
                "POST",
                f"/auth/login_flow/{flow['flow_id']}",
                auth=False,
                body={
                    "client_id": client_id,
                    "username": owner["username"],
                    "password": password,
                },
            )
            if result.get("type") != "create_entry":
                raise ReconcileError(
                    f"login as {owner['username']!r} failed "
                    f"({result.get('errors')}); does the password in sops "
                    "still match the account?"
                )
            code = result["result"]

        tokens = await self.api.request(
            "POST",
            "/auth/token",
            auth=False,
            form={
                "grant_type": "authorization_code",
                "code": code,
                "client_id": client_id,
            },
        )
        if not isinstance(tokens, dict):
            raise ReconcileError("/auth/token: reply is not an object")
        refresh, access = tokens.get("refresh_token"), tokens.get("access_token")
        if isinstance(refresh, str) and refresh:
            # Kept first, so the session is revoked even if the rest is bad.
            self.refresh_token = refresh
        if not (isinstance(access, str) and access and self.refresh_token):
            raise ReconcileError("/auth/token: reply lacks the expected tokens")
        self.api.token = access

        for step in ("core_config", "analytics", "integration"):
            if done.get(step, True):
                continue
            body = {}
            if step == "integration":
                body = {"client_id": client_id, "redirect_uri": client_id}
            await self.api.request("POST", f"/api/onboarding/{step}", body=body)
            self.changed(f"onboarding: completed step {step!r}")
            if step == "core_config":
                self.onboarded_now = True

    async def revoke(self):
        if self.refresh_token:
            await self.api.request(
                "POST", "/auth/revoke", auth=False, form={"token": self.refresh_token}
            )

    async def wait_until_running(self):
        deadline = time.monotonic() + self.decl["startTimeout"]
        while True:
            config = await self.ws.call("get_config")
            if config.get("state") == "RUNNING":
                return
            if time.monotonic() > deadline:
                raise ReconcileError(f"Home Assistant stuck in {config.get('state')}")
            await asyncio.sleep(2)

    # -- flows -----------------------------------------------------------

    async def run_flow(self, base, start, steps, what):
        result = await self.api.request("POST", base, body=start)
        for attempt in range(26):
            kind = result.get("type")
            if kind == "create_entry":
                return result
            if kind == "abort":
                raise ReconcileError(f"{what}: aborted: {result.get('reason')}")
            flow_id = result["flow_id"]
            if attempt == 25:
                # Still running: cancel it, or the next run starts a second.
                await self.api.request("DELETE", f"{base}/{flow_id}")
                break
            if kind == "progress":
                await asyncio.sleep(2)
                result = await self.api.request("GET", f"{base}/{flow_id}")
                continue
            step = result.get("step_id")
            if kind not in ("form", "menu") or step not in steps:
                await self.api.request("DELETE", f"{base}/{flow_id}")
                raise ReconcileError(
                    f"{what}: step {step!r} ({kind}) is not declared; "
                    f"it asks for {describe_step(result)}"
                )
            if kind == "menu":
                body = {"next_step_id": steps[step]}
            else:
                body = steps[step]
            result = await self.api.request("POST", f"{base}/{flow_id}", body=body)
            if (
                result.get("type") == "form"
                and result.get("step_id") == step
                and result.get("errors")
            ):
                await self.api.request("DELETE", f"{base}/{flow_id}")
                raise ReconcileError(
                    f"{what}: step {step!r} rejected: {result['errors']}"
                )
        raise ReconcileError(f"{what}: flow did not finish in 25 steps")

    # -- integrations ----------------------------------------------------

    async def entries(self):
        return await self.ws.call("config_entries/get")

    async def remove_entry(self, entry, why):
        await self.api.request(
            "DELETE", f"/api/config/config_entries/entry/{entry['entry_id']}"
        )
        self.changed(f"removed {entry['domain']} entry {entry['title']!r} ({why})")

    async def reconcile_integrations(self):
        declared = self.decl["integrations"]
        managed = self.state.setdefault("integrations", {})
        domains = {d["domain"] for d in declared.values()}

        for name in list(managed):
            if name not in declared:
                del managed[name]

        for name, integration in sorted(declared.items()):
            domain = integration["domain"]
            steps = resolve(integration["steps"])
            options = resolve(integration["options"])
            wanted = digest([domain, steps])
            record = managed.get(name)
            entries = await self.entries()
            entry = next(
                (
                    e
                    for e in entries
                    if record and e["entry_id"] == record.get("entry_id")
                ),
                None,
            )

            if entry is not None and record.get("hash") != wanted:
                await self.remove_entry(entry, "declaration changed")
                entry = None
            # Every run, not only when recreating: a second entry of a
            # declared domain is not declared in Nix either.
            owned = {r.get("entry_id") for r in managed.values()}
            for other in entries:
                if (
                    other["domain"] == domain
                    and other["entry_id"] not in owned
                    and other.get("source") not in ("ignore", "system", "import")
                ):
                    # A warning, not a failure: one entry Home Assistant will
                    # not delete must not hold up everything after it on
                    # every run. It is tried again on the next.
                    try:
                        await self.remove_entry(other, "not declared in Nix")
                    except ReconcileError as err:
                        self.warn(
                            f"could not remove {domain} entry {other['title']!r}: {err}"
                        )

            if entry is None:
                result = await self.run_flow(
                    "/api/config/config_entries/flow",
                    {"handler": domain, "show_advanced_options": True},
                    steps,
                    f"integration {name!r}",
                )
                # The created entry, as Home Assistant reports it, rather
                # than a registry diff another flow could add to.
                entry = result.get("result")
                if not isinstance(entry, dict) or not entry.get("entry_id"):
                    raise ReconcileError(
                        f"integration {name!r}: the flow reported no entry"
                    )
                record = {"entry_id": entry["entry_id"], "hash": wanted}
                managed[name] = record
                self.save_state()
                self.changed(f"created {domain} entry {entry['title']!r}")

            if options and record.get("options_hash") != digest(options):
                await self.run_flow(
                    "/api/config/config_entries/options/flow",
                    {"handler": entry["entry_id"], "show_advanced_options": True},
                    options,
                    f"options for {name!r}",
                )
                record["options_hash"] = digest(options)
                self.save_state()
                self.changed(f"set options of {domain} entry {entry['title']!r}")

        if self.decl["pruneIntegrations"]:
            if self.onboarded_now:
                await self.settle_onboarding_flows()
            keep = ALWAYS_KEEP | set(self.decl["keepDomains"]) | domains
            owned = {r["entry_id"] for r in managed.values()}
            for entry in await self.entries():
                if entry["domain"] in keep or entry["entry_id"] in owned:
                    continue
                # "import" entries are created from configuration.yaml, which
                # is already declarative, and come back on every start.
                if entry.get("source") in ("ignore", "system", "import"):
                    continue
                await self.remove_entry(entry, "not declared in Nix")

        await self.wait_for_entries_loaded({r["entry_id"] for r in managed.values()})

    async def settle_onboarding_flows(self):
        """Let the entries that finishing onboarding starts get created.

        The core_config step starts config flows for a few integrations as
        background tasks. Pruning before they finish would leave them for the
        next run to remove.
        """
        await asyncio.sleep(10)
        deadline = time.monotonic() + 60
        while await self.ws.call("config_entries/flow/progress"):
            if time.monotonic() > deadline:
                return
            await asyncio.sleep(2)

    async def wait_for_entries_loaded(self, entry_ids):
        deadline = time.monotonic() + self.decl["startTimeout"]
        while True:
            pending = [
                e
                for e in await self.entries()
                if e["entry_id"] in entry_ids and e.get("state") != "loaded"
            ]
            if not pending:
                return
            if time.monotonic() > deadline:
                states = {e["title"]: e.get("state") for e in pending}
                raise ReconcileError(f"config entries never loaded: {states}")
            await asyncio.sleep(2)

    # -- registries ------------------------------------------------------

    async def reconcile_areas(self):
        declared = self.decl["areas"]
        areas = await self.ws.call("config/area_registry/list")
        by_name = {a["name"]: a for a in areas}
        for name in declared:
            if name not in by_name:
                by_name[name] = await self.ws.call(
                    "config/area_registry/create", name=name
                )
                self.changed(f"created area {name!r}")
        if self.decl["pruneAreas"]:
            for area in areas:
                if area["name"] not in declared:
                    await self.ws.call(
                        "config/area_registry/delete", area_id=area["area_id"]
                    )
                    self.changed(f"removed area {area['name']!r}")
        return {name: by_name[name]["area_id"] for name in declared}

    async def reconcile_floors(self, area_ids):
        declared = self.decl["floors"]
        floors = {f["name"]: f for f in await self.ws.call("config/floor_registry/list")}
        for name, spec in sorted(declared.items()):
            floor = floors.get(name)
            if floor is None:
                floors[name] = await self.ws.call(
                    "config/floor_registry/create", name=name, level=spec["level"]
                )
                self.changed(f"created floor {name!r}")
            elif floor.get("level") != spec["level"]:
                await self.ws.call(
                    "config/floor_registry/update",
                    floor_id=floor["floor_id"],
                    level=spec["level"],
                )
                self.changed(f"floor {name!r}: level {spec['level']}")

        wanted = {}
        for name, spec in declared.items():
            for area in spec["areas"]:
                if area not in area_ids:
                    raise ReconcileError(f"floor {name!r}: area {area!r} is not declared")
                if area in wanted:
                    raise ReconcileError(f"area {area!r} is on two floors")
                wanted[area] = floors[name]["floor_id"]

        if declared:
            managed_floors = {floors[name]["floor_id"] for name in declared}
            for area in await self.ws.call("config/area_registry/list"):
                if area["name"] not in wanted:
                    # A declared area taken off a declared floor leaves it.
                    # Areas Nix does not declare, and floors it does not
                    # manage, are left alone.
                    if area["name"] in area_ids and area.get("floor_id") in managed_floors:
                        await self.ws.call(
                            "config/area_registry/update",
                            area_id=area["area_id"],
                            floor_id=None,
                        )
                        self.changed(f"area {area['name']!r}: no floor")
                    continue
                floor_id = wanted[area["name"]]
                if area.get("floor_id") != floor_id:
                    await self.ws.call(
                        "config/area_registry/update",
                        area_id=area["area_id"],
                        floor_id=floor_id,
                    )
                    self.changed(f"area {area['name']!r}: floor {floor_id!r}")

        if self.decl["pruneFloors"]:
            for name, floor in floors.items():
                if name not in declared:
                    await self.ws.call(
                        "config/floor_registry/delete", floor_id=floor["floor_id"]
                    )
                    self.changed(f"removed floor {name!r}")

    def identifier(self, spec):
        """A device spec's identifier, with {entry:NAME} replaced by the
        entry ID of the declared integration NAME, for integrations that
        put their entry ID in device identifiers."""
        out = []
        for part in spec["identifier"]:
            for name, record in self.state.get("integrations", {}).items():
                part = part.replace("{entry:" + name + "}", record["entry_id"])
            if "{entry:" in part:
                raise ReconcileError(
                    f"device {spec['identifier']}: no managed integration for {part!r}"
                )
            out.append(part)
        return tuple(out)

    async def find_devices(self):
        wanted = [self.identifier(d) for d in self.decl["devices"]]
        deadline = time.monotonic() + self.decl["deviceTimeout"]
        while True:
            devices = await self.ws.call("config/device_registry/list")
            index = {}
            for device in devices:
                for identifier in device.get("identifiers") or []:
                    # As text: Nix declares strings, and some integrations
                    # use numbers (Sense's monitor is ["sense", 6241]).
                    index[tuple(str(part) for part in identifier)] = device
            missing = [w for w in wanted if w not in index]
            if not missing or time.monotonic() > deadline:
                return index
            await asyncio.sleep(5)

    def pick_entity(self, device, entities, spec):
        domain = spec["domain"]
        candidates = [
            e
            for e in entities
            if e.get("device_id") == device["id"]
            and e["entity_id"].split(".", 1)[0] == domain
        ]
        if spec.get("uniqueId") is not None:
            candidates = [e for e in candidates if e["unique_id"] == spec["uniqueId"]]
        elif spec.get("originalName") is not None:
            candidates = [
                e for e in candidates if e.get("original_name") == spec["originalName"]
            ]
        else:
            # Even with one candidate: a diagnostic entity that registered
            # before the primary one must not take the primary's name.
            candidates = [e for e in candidates if e.get("entity_category") is None]
        if not candidates:
            # Not created yet, e.g. a Z-Wave node still being interviewed.
            # Like a missing device: warn, and the next run picks it up.
            self.warn(
                f"device {device_label(device)}: no {domain} entity matching "
                f"{spec['entityId']} yet; skipped"
            )
            return None
        if len(candidates) > 1:
            found = [(e["entity_id"], e.get("original_name")) for e in candidates]
            raise ReconcileError(
                f"device {device_label(device)}: {spec} matches {len(found)} "
                f"entities, not one: {found}"
            )
        return candidates[0]

    async def reconcile_devices(self, area_ids):
        if not self.decl["devices"]:
            return
        index = await self.find_devices()
        entities = await self.ws.call("config/entity_registry/list")

        for spec in self.decl["devices"]:
            identifier = self.identifier(spec)
            device = index.get(identifier)
            if device is None:
                self.warn(f"device {list(identifier)} is not registered; skipped")
                continue

            update = {}
            if spec["name"] is not None and device.get("name_by_user") != spec["name"]:
                update["name_by_user"] = spec["name"]
            if spec["area"] is not None:
                area_id = area_ids.get(spec["area"])
                if area_id is None:
                    raise ReconcileError(
                        f"device {list(identifier)}: area {spec['area']!r} "
                        "is not declared"
                    )
                if device.get("area_id") != area_id:
                    update["area_id"] = area_id
            if update:
                await self.ws.call(
                    "config/device_registry/update", device_id=device["id"], **update
                )
                self.changed(f"device {device_label(device)}: {update}")

            # A declared entity whose rename was skipped (its ID is taken)
            # keeps its current ID; keepEntities lists the wanted one, so
            # keep the current one in its place.
            kept_as = {}
            for entity_spec in spec["entities"]:
                entity = self.pick_entity(device, entities, entity_spec)
                if entity is not None:
                    actual = await self.update_entity(entity, entity_spec, area_ids)
                    kept_as[entity_spec["entityId"]] = actual

            if spec.get("keepEntities") is not None:
                keep = {kept_as.get(eid, eid) for eid in spec["keepEntities"]}
                await self.keep_only(device, keep)

    async def entity_id_free(self, entity, wanted):
        """Whether `entity` can be renamed to `wanted`. Taken by another
        entity is a warning, not a failure, so one clash does not stop the
        rest of the run."""
        try:
            other = await self.ws.call("config/entity_registry/get", entity_id=wanted)
        except ReconcileError:
            return True
        self.warn(
            f"cannot rename {entity['entity_id']} to {wanted}: taken by "
            f"{other.get('platform')} entity {other.get('unique_id')!r}; "
            "pick another entity ID"
        )
        return False

    async def reconcile_entity_rules(self):
        """Disable each entity of a ruled platform whose unique ID matches a
        rule, and enable again those it disabled that no longer match.

        Only what a rule disabled is ever re-enabled, recorded in the state
        file by platform and unique ID (so a rename keeps it): an entity
        keepEntities or a person disabled is left alone, and one a rule
        disabled that keepEntities now excludes stays disabled.
        """
        rules = {}
        for rule in self.decl["disableEntities"]:
            rules.setdefault(rule["platform"], []).append(re.compile(rule["uniqueId"]))
        owned = set(self.state.get("ruleDisabled", []))
        if not rules and not owned:
            return
        entities = await self.ws.call("config/entity_registry/list")
        # Records from before ownership was keyed by unique ID held entity
        # IDs, which never contain a colon.
        by_id = {e["entity_id"]: entity_key(e) for e in entities}
        owned = {by_id.get(o, o) if ":" not in o else o for o in owned}
        for entity in entities:
            eid, key = entity["entity_id"], entity_key(entity)
            patterns = rules.get(entity.get("platform"), [])
            matched = any(p.fullmatch(str(entity["unique_id"])) for p in patterns)
            by = entity.get("disabled_by")
            if matched and by is None:
                update = {"disabled_by": "user"}
                owned.add(key)
            elif not matched and key in owned:
                owned.discard(key)
                if by != "user" or key in self.keep_excluded:
                    self.save_owned(owned)
                    continue
                update = {"disabled_by": None}
            else:
                continue
            await self.ws.call("config/entity_registry/update", entity_id=eid, **update)
            self.changed(f"entity {eid}: {update}")
            self.save_owned(owned)
        self.save_owned(owned)

    def save_owned(self, owned):
        self.state["ruleDisabled"] = sorted(owned)
        self.save_state()

    async def keep_only(self, device, keep):
        """Disable every entity on the device that is not in `keep`, and
        enable the kept ones if they were disabled here. Entities that the
        integration itself disabled are left as they are."""
        keep = set(keep)
        # Read afresh: the renames just made change entity IDs.
        entities = await self.ws.call("config/entity_registry/list")
        for entity in entities:
            if entity.get("device_id") != device["id"]:
                continue
            if entity["entity_id"] not in keep:
                self.keep_excluded.add(entity_key(entity))
            eid = entity["entity_id"]
            by = entity.get("disabled_by")
            if eid in keep and by == "user":
                update = {"disabled_by": None}
            elif eid not in keep and by is None:
                update = {"disabled_by": "user"}
            else:
                continue
            await self.ws.call(
                "config/entity_registry/update", entity_id=eid, **update
            )
            self.changed(f"entity {eid}: {update}")
        missing = keep - {
            e["entity_id"] for e in entities if e.get("device_id") == device["id"]
        }
        for eid in sorted(missing):
            self.warn(f"device {device_label(device)}: kept entity {eid} does not exist")

    async def reconcile_entities(self, area_ids):
        """Entities declared by entity ID, such as those with no device."""
        if not self.decl["entities"]:
            return
        registry = {
            e["entity_id"]: e for e in await self.ws.call("config/entity_registry/list")
        }
        for spec in self.decl["entities"]:
            entity = registry.get(spec["entityId"])
            if entity is None:
                self.warn(f"entity {spec['entityId']} is not registered; skipped")
                continue
            await self.update_entity(entity, spec, area_ids)

    async def update_entity(self, entity, spec, area_ids):
        """Apply an entity spec; return the entity's ID afterwards."""
        update = {}
        if entity["entity_id"] != spec["entityId"] and await self.entity_id_free(
            entity, spec["entityId"]
        ):
            update["new_entity_id"] = spec["entityId"]
        if spec.get("name") is not None and entity.get("name") != spec["name"]:
            update["name"] = spec["name"]
        if spec.get("area") is not None:
            area_id = area_ids.get(spec["area"])
            if area_id is None:
                raise ReconcileError(
                    f"entity {spec['entityId']}: area {spec['area']!r} is not declared"
                )
            if entity.get("area_id") != area_id:
                update["area_id"] = area_id
        if spec.get("hidden") is not None:
            hidden_by = "user" if spec["hidden"] else None
            # Only "user" is ours to change; integrations hide entities too.
            if spec["hidden"] and entity.get("hidden_by") is None:
                update["hidden_by"] = hidden_by
            elif not spec["hidden"] and entity.get("hidden_by") == "user":
                update["hidden_by"] = hidden_by
        if update:
            await self.ws.call(
                "config/entity_registry/update",
                entity_id=entity["entity_id"],
                **update,
            )
            self.changed(f"entity {entity['entity_id']}: {update}")
        return update.get("new_entity_id", entity["entity_id"])

    # -- persons -----------------------------------------------------------

    async def reconcile_persons(self):
        declared = self.decl["persons"]
        if not declared:
            return
        persons = {p["name"]: p for p in (await self.ws.call("person/list"))["storage"]}
        for name, spec in sorted(declared.items()):
            person = persons.get(name)
            if person is None:
                self.warn(f"person {name!r} does not exist; skipped")
                continue
            wanted = spec["deviceTrackers"]
            if person.get("device_trackers") != wanted:
                await self.ws.call(
                    "person/update", person_id=person["id"], device_trackers=wanted
                )
                self.changed(f"person {name!r}: device trackers {wanted}")

    # -- HTTP --------------------------------------------------------------

    async def reconcile_http(self):
        """Apply the declared HTTP settings, returning True if that restarts
        Home Assistant.

        From 2026.11 Home Assistant keeps these in .storage and changes them
        only through http/config/configure, which stores them as `pending`
        and restarts. A pending config is a trial: unless it is promoted it
        reverts to `stable` after five minutes. So a change is applied, and
        promoted on the next pass, once the restarted Home Assistant has
        answered on it.
        """
        wanted = self.decl["http"]
        if wanted is None:
            return False
        info = await self.ws.call("http/config")
        stable, pending = info.get("stable") or {}, info.get("pending")
        if pending is None and contains(stable, wanted):
            return False
        if (
            pending is not None
            and contains(pending, wanted)
            and not pending.get("error")
            and info.get("active_config_type") == "pending"
        ):
            # We reached Home Assistant through it, so it works: confirm it.
            await self.ws.call("http/config/promote")
            self.changed("http: confirmed the new settings")
            return False
        result = await self.ws.call("http/config/configure", config=wanted)
        self.changed("http: applied new settings")
        return bool(result and result.get("restart"))

    async def confirm_http(self):
        """Fail unless the declared HTTP settings are the stable ones."""
        wanted = self.decl["http"]
        if wanted is None:
            return
        info = await self.ws.call("http/config")
        stable, pending = info.get("stable") or {}, info.get("pending")
        if pending is None and contains(stable, wanted):
            return
        error = pending.get("error") if pending else None
        raise ReconcileError(
            f"http: the declared settings are not in effect (pending error: {error})"
        )

    async def wait_for_restart(self):
        """Wait for a Home Assistant restart to begin and finish."""
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                async with self.session.get(self.api.url + "/api/") as r:
                    await r.read()
            except aiohttp.ClientError:
                break
            await asyncio.sleep(1)
        await self.wait_for_api()

    # -- backups ---------------------------------------------------------

    async def reconcile_backup(self):
        wanted = self.decl["backup"]
        if wanted is None:
            return
        wanted = resolve(wanted)
        current = (await self.ws.call("backup/config/info"))["config"]
        if not contains(current, wanted):
            await self.ws.call("backup/config/update", **wanted)
            self.changed("backup settings")

    # -- main ------------------------------------------------------------

    async def run(self):
        onboarding = await self.wait_for_api()
        timeout = self.decl["startTimeout"]
        try:
            await self.authenticate(onboarding)
            self.ws = await Websocket.connect(
                self.session, self.api.url, self.api.token, timeout
            )
            await self.wait_until_running()
            # First, because applying it restarts Home Assistant: apply and
            # restart, then confirm. A trial that failed at startup is
            # applied once more.
            for _ in range(3):
                if not await self.reconcile_http():
                    break
                await self.ws.close()
                self.ws = None
                await self.wait_for_restart()
                self.ws = await Websocket.connect(
                    self.session, self.api.url, self.api.token, timeout
                )
                await self.wait_until_running()
            await self.confirm_http()
            await self.reconcile_integrations()
            area_ids = await self.reconcile_areas()
            await self.reconcile_floors(area_ids)
            await self.reconcile_devices(area_ids)
            await self.reconcile_entity_rules()
            await self.reconcile_entities(area_ids)
            await self.reconcile_persons()
            await self.reconcile_backup()
        finally:
            try:
                if self.ws:
                    await self.ws.close()
            finally:
                await self.revoke()
        log.info("done: %d changes, %d warnings", self.changes, self.warnings)


def entity_key(entity):
    """An entity's identity that survives renames: platform and unique ID."""
    return f"{entity.get('platform')}:{entity['unique_id']}"


def device_label(device):
    return repr(device.get("name_by_user") or device.get("name") or device["id"])


def contains(current, wanted):
    """True when every key in `wanted` has the same value in `current`."""
    if isinstance(wanted, dict):
        return isinstance(current, dict) and all(
            k in current and contains(current[k], v) for k, v in wanted.items()
        )
    return current == wanted


async def main(path):
    decl = json.loads(Path(path).read_text())
    timeout = aiohttp.ClientTimeout(total=120)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        await Reconciler(decl, session).run()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    try:
        asyncio.run(main(sys.argv[1]))
    except ReconcileError as err:
        log.error("%s", err)
        sys.exit(1)
