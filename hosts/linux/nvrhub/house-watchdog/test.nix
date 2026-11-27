# VM test of the house watchdog (./default.nix) against Mosquitto and a fake
# Frigate that serves /api/config and records what arrives on /ws.
#
# A fresh heartbeat re-arms nothing, including while the broker is down if
# the last one read is still fresh. A stale heartbeat re-arms exactly the
# review settings that are off, whether the broker is up or down. Frigate
# being down is not a failure.
{ pkgs, lib, ... }:
let
  password = "test-watchdog-password";

  fakeFrigate =
    pkgs.writers.writePython3Bin "fake-frigate"
      {
        libraries = [ pkgs.python3Packages.aiohttp ];
      }
      ''
        import json
        from aiohttp import web, WSMsgType

        review = {}
        received = []


        async def config(request):
            return web.json_response({"cameras": {
                cam: {"review": {k: {"enabled": v} for k, v in kinds.items()}}
                for cam, kinds in review.items()
            }})


        async def reset(request):
            review.clear()
            review.update(await request.json())
            received.clear()
            return web.json_response({})


        async def messages(request):
            return web.json_response(received)


        async def ws(request):
            sock = web.WebSocketResponse()
            await sock.prepare(request)
            async for msg in sock:
                if msg.type == WSMsgType.TEXT:
                    data = json.loads(msg.data)
                    received.append(data)
                    cam, kind, _ = data["topic"].split("/")
                    review[cam][kind.removeprefix("review_")] = data["payload"] == "ON"
            return sock


        app = web.Application()
        app.add_routes([
            web.get("/api/config", config),
            web.post("/reset", reset),
            web.get("/messages", messages),
            web.get("/ws", ws),
        ])
        web.run_app(app, host="127.0.0.1", port=5000)
      '';
in
{
  name = "house-watchdog";

  nodes.machine = {
    imports = [ ./default.nix ];

    services.mosquitto = {
      enable = true;
      listeners = [
        {
          port = 1883;
          settings.allow_anonymous = false;
          users = {
            nvr-watchdog = {
              acl = [ "read house/#" ];
              inherit password;
            };
            homeassistant = {
              acl = [ "readwrite #" ];
              password = "test-ha-password";
            };
          };
        }
      ];
    };

    systemd.services.fake-frigate = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${fakeFrigate}/bin/fake-frigate";
    };

    services.house-watchdog = {
      enable = true;
      broker = "127.0.0.1";
      user = "nvr-watchdog";
      passwordFile = pkgs.writeText "watchdog-password" password;
      cameras = [
        "kitchen"
        "office"
      ];
      staleAfter = 20;
    };
    # Started by the test script, never by the timer mid-test.
    systemd.timers.house-watchdog.wantedBy = lib.mkForce [ ];

    environment.systemPackages = [
      pkgs.mosquitto
      pkgs.jq
    ];
  };

  testScript = ''
    import json

    all_off = json.dumps({
        "kitchen": {"alerts": False, "detections": False},
        "office": {"alerts": True, "detections": False},
    })
    rearmed = [
        "kitchen/review_alerts/set",
        "kitchen/review_detections/set",
        "office/review_detections/set",
    ]

    def reset():
        machine.succeed(
            f"curl -sf -X POST -H 'Content-Type: application/json' -d '{all_off}' "
            "http://127.0.0.1:5000/reset"
        )

    def heartbeat():
        machine.succeed(
            "mosquitto_pub -h 127.0.0.1 -u homeassistant -P test-ha-password "
            "-r -t house/heartbeat -m $(date +%s)"
        )

    def run():
        machine.succeed("systemctl start house-watchdog.service")

    def sent():
        out = json.loads(machine.succeed("curl -sf http://127.0.0.1:5000/messages"))
        assert all(m["payload"] == "ON" for m in out), out
        return sorted(m["topic"] for m in out)

    machine.wait_for_unit("mosquitto.service")
    machine.wait_for_open_port(1883)
    machine.wait_for_open_port(5000)

    with subtest("a fresh heartbeat re-arms nothing"):
        reset()
        heartbeat()
        run()
        assert sent() == [], sent()

    with subtest("the broker down, with a fresh heartbeat read, re-arms nothing"):
        machine.succeed("systemctl stop mosquitto.service")
        run()
        assert sent() == [], sent()

    with subtest("the broker down, and the last heartbeat stale, re-arms what is off"):
        machine.sleep(25)
        run()
        assert sent() == rearmed, sent()
        machine.succeed(
            "curl -sf http://127.0.0.1:5000/api/config | "
            "jq -e '[.cameras[].review[].enabled] | all'"
        )

    with subtest("a reachable broker with a stale heartbeat re-arms too"):
        machine.succeed("systemctl start mosquitto.service")
        machine.wait_for_open_port(1883)
        reset()
        heartbeat()
        run()
        assert sent() == [], sent()
        machine.sleep(25)
        run()
        assert sent() == rearmed, sent()

    with subtest("nothing off, nothing sent"):
        run()
        assert sent() == rearmed, sent()

    with subtest("Frigate down is not a failure"):
        machine.succeed("systemctl stop fake-frigate.service")
        run()
        out = machine.succeed("journalctl -u house-watchdog.service -o cat")
        assert "could not re-arm through Frigate" in out, out
  '';
}
