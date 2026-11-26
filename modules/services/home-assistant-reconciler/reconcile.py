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
import sys
import time
from pathlib import Path

import aiohttp

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
    def __init__(self, ws):
        self.ws = ws
        self.next_id = 0

    @classmethod
    async def connect(cls, session, url, token):
        ws = await session.ws_connect(
            url.rstrip("/").replace("http", "ws", 1) + "/api/websocket",
            max_msg_size=0,
        )
        hello = await ws.receive_json()
        if hello.get("type") != "auth_required":
            raise ReconcileError(f"unexpected websocket greeting: {hello}")
        await ws.send_json({"type": "auth", "access_token": token})
        reply = await ws.receive_json()
        if reply.get("type") != "auth_ok":
            raise ReconcileError(f"websocket auth failed: {reply}")
        return cls(ws)

    async def call(self, kind, **fields):
        self.next_id += 1
        await self.ws.send_json({"id": self.next_id, "type": kind, **fields})
        while True:
            msg = await self.ws.receive_json()
            if msg.get("id") == self.next_id and msg.get("type") == "result":
                if not msg.get("success"):
                    raise ReconcileError(f"{kind}: {msg.get('error')}")
                return msg.get("result")

    async def close(self):
        await self.ws.close()


class Reconciler:
    def __init__(self, decl, session):
        self.decl = decl
        self.api = Api(session, decl["url"])
        self.session = session
        self.ws = None
        self.refresh_token = None
        self.changes = 0
        self.warnings = 0
        self.onboarded_now = False
        self.state_path = Path(decl["stateFile"])
        self.state = self.load_state()

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
            try:
                async with self.session.get(self.api.url + "/api/onboarding") as r:
                    if r.status == 404:
                        return []
                    if r.status == 200:
                        return await r.json()
                    raise ReconcileError(f"GET /api/onboarding: HTTP {r.status}")
            except (aiohttp.ClientError, ReconcileError) as err:
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
        self.api.token = tokens["access_token"]
        self.refresh_token = tokens["refresh_token"]

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
        for _ in range(25):
            kind = result.get("type")
            if kind == "create_entry":
                return result
            if kind == "abort":
                raise ReconcileError(f"{what}: aborted: {result.get('reason')}")
            flow_id = result["flow_id"]
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

            if entry is None or record.get("hash") != wanted:
                if entry is not None:
                    await self.remove_entry(entry, "declaration changed")
                owned = {r.get("entry_id") for r in managed.values()}
                for other in entries:
                    if other["domain"] == domain and other["entry_id"] not in owned:
                        await self.remove_entry(other, "not declared in Nix")
                before = {e["entry_id"] for e in await self.entries()}
                await self.run_flow(
                    "/api/config/config_entries/flow",
                    {"handler": domain, "show_advanced_options": True},
                    steps,
                    f"integration {name!r}",
                )
                new = [e for e in await self.entries() if e["entry_id"] not in before]
                if len(new) != 1:
                    raise ReconcileError(
                        f"integration {name!r}: expected one new entry, got {new}"
                    )
                entry = new[0]
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
            keep = set(self.decl["keepDomains"]) | domains
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

    async def find_devices(self):
        wanted = [tuple(d["identifier"]) for d in self.decl["devices"]]
        deadline = time.monotonic() + self.decl["deviceTimeout"]
        while True:
            devices = await self.ws.call("config/device_registry/list")
            index = {}
            for device in devices:
                for identifier in device.get("identifiers") or []:
                    index[tuple(identifier)] = device
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
        elif len(candidates) > 1:
            candidates = [e for e in candidates if e.get("entity_category") is None]
        if len(candidates) != 1:
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
            identifier = tuple(spec["identifier"])
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

            for entity_spec in spec["entities"]:
                entity = self.pick_entity(device, entities, entity_spec)
                update = {}
                if entity["entity_id"] != entity_spec["entityId"]:
                    update["new_entity_id"] = entity_spec["entityId"]
                if (
                    entity_spec["name"] is not None
                    and entity.get("name") != entity_spec["name"]
                ):
                    update["name"] = entity_spec["name"]
                if update:
                    await self.ws.call(
                        "config/entity_registry/update",
                        entity_id=entity["entity_id"],
                        **update,
                    )
                    self.changed(f"entity {entity['entity_id']}: {update}")

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
        await self.authenticate(onboarding)
        try:
            self.ws = await Websocket.connect(
                self.session, self.api.url, self.api.token
            )
            await self.wait_until_running()
            await self.reconcile_integrations()
            area_ids = await self.reconcile_areas()
            await self.reconcile_devices(area_ids)
            await self.reconcile_backup()
        finally:
            if self.ws:
                await self.ws.close()
            await self.revoke()
        log.info("done: %d changes, %d warnings", self.changes, self.warnings)


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
