"""Apply declared Z-Wave association groups through zwave-js-server.

For each declared source node and group, targets that are missing are added
(each checked with controller.check_association first) and targets that are
not declared are removed; the result is read back and compared. Group 1
(Lifeline, to the controller), undeclared groups and undeclared nodes are
never touched.

Usage: zwave-js-associations [--dry-run] DECLARATION. With --dry-run it checks
and reports what it would change, and changes nothing.

The declaration is a JSON file:
  {"url": "ws://127.0.0.1:3000", "timeout": 300,
   "nodes": {"<node>": {"<group>": [<target node>, ...]}}}
"""

import asyncio
import json
import logging
import sys
import time

import websockets

log = logging.getLogger("zwave-js-associations")

CHECK_RESULTS = {
    1: "OK",
    2: "the target is a Long Range node",
    3: "the source is a Long Range node",
    4: "a node cannot be associated with itself",
    5: "the security classes do not match",
    6: "the source does not have the target's security class",
    7: "the target supports none of the group's commands",
}


class AssociationError(Exception):
    pass


def plan(current, wanted):
    """Associations to add and to remove for one group.

    `current` is zwave-js's list of {"nodeId", "endpoint"?} for the group;
    `wanted` the declared target node IDs. A current entry with an endpoint
    is never what was declared (targets are whole nodes), so it is removed.
    Returns (add, remove), each a list of {"nodeId": ...} in a stable order.
    """
    wanted = sorted(set(wanted))
    present = {a["nodeId"] for a in current if a.get("endpoint") is None}
    add = [{"nodeId": n} for n in wanted if n not in present]
    remove = sorted(
        (a for a in current if a.get("endpoint") is not None or a["nodeId"] not in wanted),
        key=lambda a: (a["nodeId"], a.get("endpoint") or 0),
    )
    return add, remove


def validate(nodes):
    """Reject a declaration that touches group 1 or names nonsense."""
    for source, groups in nodes.items():
        for group, targets in groups.items():
            if int(group) == 1:
                raise AssociationError(f"node {source}: group 1 (Lifeline) is never managed")
            if int(source) in targets:
                raise AssociationError(f"node {source} group {group}: a node cannot target itself")


class Server:
    def __init__(self, ws):
        self.ws = ws
        self.next_id = 0

    async def call(self, command, **fields):
        self.next_id += 1
        mid = str(self.next_id)
        await self.ws.send(json.dumps({"messageId": mid, "command": command, **fields}))
        while True:
            msg = json.loads(await asyncio.wait_for(self.ws.recv(), 120))
            if msg.get("messageId") == mid:
                if not msg.get("success"):
                    raise AssociationError(
                        f"{command}: {msg.get('errorCode')} {msg.get('message') or msg.get('zwaveErrorMessage') or ''}".strip()
                    )
                return msg.get("result") or {}


async def connect(url, timeout):
    """zwave-js-server, once its driver is ready (it accepts connections
    only then)."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            ws = await websockets.connect(url, max_size=None)
            version = json.loads(await asyncio.wait_for(ws.recv(), 30))
            server = Server(ws)
            await server.call("set_api_schema", schemaVersion=version["maxSchemaVersion"])
            return server
        except (OSError, websockets.WebSocketException, asyncio.TimeoutError) as err:
            if time.monotonic() > deadline:
                raise AssociationError(f"zwave-js-server at {url} never answered: {err}") from None
            await asyncio.sleep(5)


async def apply(server, nodes, dry_run=False):
    """Make each declared group hold exactly its targets. With dry_run,
    check and report the changes without making them."""
    changes = 0
    for source in sorted(nodes, key=int):
        node = int(source)
        groups = (await server.call("controller.get_association_groups", nodeId=node)).get("groups", {})
        current = (await server.call("controller.get_associations", nodeId=node)).get("associations", {})
        for group in sorted(nodes[source], key=int):
            info = groups.get(group)
            if info is None:
                raise AssociationError(f"node {node} has no association group {group}")
            wanted = nodes[source][group]
            if len(set(wanted)) > info.get("maxNodes", 0):
                raise AssociationError(
                    f"node {node} group {group} ({info.get('label')}) takes {info.get('maxNodes')} targets, not {len(set(wanted))}"
                )
            add, remove = plan(current.get(group, []), wanted)
            for target in add:
                result = (await server.call(
                    "controller.check_association", nodeId=node, group=int(group), association=target
                )).get("result")
                if result != 1:
                    raise AssociationError(
                        f"node {node} group {group} -> node {target['nodeId']}: not allowed, "
                        f"{CHECK_RESULTS.get(result, result)}"
                    )
            verb = "would " if dry_run else ""
            if remove:
                if not dry_run:
                    await server.call("controller.remove_associations", nodeId=node, group=int(group), associations=remove)
                log.info("node %s group %s (%s): %sremove %s", node, group, info.get("label"), verb, [a["nodeId"] for a in remove])
                changes += 1
            if add:
                if not dry_run:
                    await server.call("controller.add_associations", nodeId=node, group=int(group), associations=add)
                log.info("node %s group %s (%s): %sadd %s", node, group, info.get("label"), verb, [a["nodeId"] for a in add])
                changes += 1
        if dry_run:
            continue
        # Read back: what zwave-js now holds must be exactly the declaration.
        after = (await server.call("controller.get_associations", nodeId=node)).get("associations", {})
        for group, wanted in nodes[source].items():
            add, remove = plan(after.get(group, []), wanted)
            if add or remove:
                raise AssociationError(f"node {node} group {group}: still differs after applying ({add}, {remove})")
    return changes


async def main_async(declaration, dry_run):
    validate(declaration["nodes"])
    server = await connect(declaration["url"], declaration.get("timeout", 300))
    try:
        changes = await apply(server, declaration["nodes"], dry_run)
    finally:
        await server.ws.close()
    log.info("done: %d changes%s", changes, " (dry run, none made)" if dry_run else "")


def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    args = [a for a in args if a != "--dry-run"]
    with open(args[0]) as f:
        declaration = json.load(f)
    try:
        asyncio.run(main_async(declaration, dry_run))
    except AssociationError as err:
        log.error("%s", err)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
