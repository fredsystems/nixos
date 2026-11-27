"""Re-arm Frigate's indoor cameras when Home Assistant's heartbeat stops.

Plan 06, 6.17. Home Assistant publishes a retained epoch timestamp to
house/heartbeat every minute. If the newest one seen is older than
--stale-after, whether because Home Assistant is down, the broker is, or
corehub is, Home Assistant can no longer re-arm the cameras after home_awake,
so this does: every indoor camera whose review alerts or detections are off
gets them turned back on through Frigate's loopback websocket, which needs
neither the broker nor corehub.

The newest heartbeat seen is kept in --state, so one failed read of a
reachable broker does not count as stale. Nothing is ever turned off here.
"""

import argparse
import asyncio
import json
import logging
import sys
import threading
import time
from pathlib import Path

import aiohttp
import paho.mqtt.client as mqtt

log = logging.getLogger("house-watchdog")


def read_heartbeat(args, password):
    """The broker's retained heartbeat, or None if it cannot be read."""
    got = {}
    done = threading.Event()

    def on_connect(client, userdata, flags, reason, properties):
        if reason.is_failure:
            log.warning("broker refused the connection: %s", reason)
            done.set()
            return
        client.subscribe(args.topic)

    def on_message(client, userdata, message):
        got["payload"] = message.payload.decode(errors="replace")
        done.set()

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.username_pw_set(args.user, password)
    client.on_connect = on_connect
    client.on_message = on_message
    try:
        client.connect(args.broker, args.port, keepalive=30)
    except OSError as err:
        log.warning("broker %s unreachable: %s", args.broker, err)
        return None
    client.loop_start()
    done.wait(10)
    client.disconnect()
    client.loop_stop()
    try:
        return float(got["payload"])
    except (KeyError, ValueError):
        log.warning("no usable heartbeat on %s", args.topic)
        return None


def newest_heartbeat(args, password):
    state = Path(args.state)
    try:
        stored = float(state.read_text())
    except (OSError, ValueError):
        stored = None
    seen = read_heartbeat(args, password)
    if seen is not None and (stored is None or seen > stored):
        state.write_text(f"{seen}\n")
    known = [t for t in (seen, stored) if t is not None]
    return max(known) if known else None


async def rearm(args):
    url = args.frigate.rstrip("/")
    timeout = aiohttp.ClientTimeout(total=30)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        try:
            async with session.get(url + "/api/config") as response:
                response.raise_for_status()
                config = await response.json()
            off = [
                f"{camera}/review_{kind}/set"
                for camera in args.cameras
                for kind in ("alerts", "detections")
                if not config["cameras"][camera]["review"][kind]["enabled"]
            ]
            if not off:
                return
            async with session.ws_connect(url + "/ws") as ws:
                for topic in off:
                    await ws.send_str(json.dumps({"topic": topic, "payload": "ON"}))
                # Frigate handles the messages as they arrive; closing at
                # once can drop the last ones.
                await asyncio.sleep(1)
        except (aiohttp.ClientError, asyncio.TimeoutError, KeyError) as err:
            # Frigate down is alerted on by itself; it restarts armed.
            log.warning("could not re-arm through Frigate: %r", err)
            return
    log.warning("re-armed: %s", ", ".join(t.removesuffix("/set") for t in off))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--broker", required=True)
    parser.add_argument("--port", type=int, default=1883)
    parser.add_argument("--user", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--topic", default="house/heartbeat")
    parser.add_argument("--state", required=True)
    parser.add_argument("--frigate", default="http://127.0.0.1:5000")
    parser.add_argument("--stale-after", type=int, default=300)
    parser.add_argument("cameras", nargs="+")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    password = Path(args.password_file).read_text().strip()
    newest = newest_heartbeat(args, password)
    if newest is not None and time.time() - newest <= args.stale_after:
        return 0
    age = "never seen" if newest is None else f"{time.time() - newest:.0f}s old"
    log.info("Home Assistant heartbeat %s", age)
    asyncio.run(rearm(args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
