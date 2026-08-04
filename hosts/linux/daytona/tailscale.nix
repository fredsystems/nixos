# Tailscale on the laptop, with LAN route acceptance gated on location.
#
# WHY THIS EXISTS
#
# The substituter list in modules/base/system.nix starts with
# http://192.168.31.14:8080/fred (Attic on fredhub), which is unroutable off the
# home network. Every nix invocation away from home therefore stalls on it before
# falling back, and with direnv loading a flake on every `cd` that is constantly.
# `connect-timeout = 5` bounds the stall; this makes the cache actually reachable.
#
# sdrhub already advertises 192.168.31.0/24 to the tailnet and fredvps already
# consumes it -- see the comment on `extraUpFlags` in
# hosts/linux/fredvps/configuration.nix, which cites the same motivation. This is
# that arrangement applied to the laptop.
#
# Everything here is deliberately scoped to this host rather than added to
# modules/services/tailscale, so enabling it cannot alter sdrhub's or fredvps'
# closures.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  # The LAN sdrhub advertises. Kept as a prefix string because the check below is
  # a substring match against `ip addr` output, not a CIDR computation.
  homeSubnetPrefix = "192.168.31.";

  # Route acceptance is toggled rather than the tailnet being joined and left.
  #
  # Leaving the tailnet at home would also give up remote SSH, MagicDNS and
  # anything else reachable over it, for no benefit -- the only thing that
  # interacts badly with being physically on the advertised LAN is accepting a
  # route for that same LAN. So the node stays up everywhere and only
  # --accept-routes moves.
  #
  # Worth knowing how much this is actually protecting against: the kernel
  # prefers the directly-connected 192.168.31.0/24 route in the main table, which
  # Tailscale's policy rules consult before its own table, so accepting the route
  # at home is usually harmless anyway. This is belt-and-braces that removes the
  # ambiguity, not a fix for a known breakage.
  routeGating = pkgs.writeShellApplication {
    name = "tailscale-route-gating";
    runtimeInputs = [
      pkgs.iproute2
      pkgs.jq
      config.services.tailscale.package
    ];
    text = ''
      # Presence of an address in the advertised range is the test, rather than
      # the wifi SSID: it works identically on ethernet and wifi, survives an
      # SSID rename, and cannot be fooled by a network that merely has a similar
      # name.
      if ip -4 -o addr show | grep -q "inet ${homeSubnetPrefix}"; then
        want=false
        where="on the home LAN"
      else
        want=true
        where="away from the home LAN"
      fi

      # tailscale set is idempotent, but reading the current value first keeps
      # this quiet in the journal and avoids poking the daemon on every
      # NetworkManager event -- of which a laptop generates plenty.
      #
      # `debug prefs` is the only place RouteAll is exposed; `status --json` does
      # not carry it. If that ever changes shape, the read fails and we fall
      # through to setting unconditionally, which is correct but chattier.
      # Deliberately not `.RouteAll // empty`: jq's alternative operator treats
      # `false` as absent, so that idiom returns nothing for the very state we
      # most need to recognise -- route acceptance already off. The script would
      # then think the value was unknown on every run and call `tailscale set`
      # each time, logging a line every five minutes forever. `// "unknown"` on
      # the null case keeps false distinguishable from missing.
      current=""
      if prefs=$(tailscale debug prefs 2>/dev/null); then
        current=$(jq -r 'if has("RouteAll") and .RouteAll != null then (.RouteAll | tostring) else "" end' \
          <<<"$prefs" 2>/dev/null || echo "")
      fi

      if [ "$current" = "$want" ]; then
        exit 0
      fi

      echo "tailscale-route-gating: $where; setting --accept-routes=$want (was ''${current:-unknown})"

      # Not fatal on failure. tailscaled may not be up yet during early boot or a
      # resume, and this runs again on the next NetworkManager event and on the
      # backstop timer below. Failing the unit here would only produce noise and,
      # for the dispatcher, a NetworkManager error.
      if ! tailscale set --accept-routes="$want"; then
        echo "tailscale-route-gating: could not set --accept-routes (tailscaled not ready?)" >&2
      fi
    '';
  };
in
{
  imports = [ ../../../modules/services/tailscale ];

  services.tailscale = {
    # Without this the advertised subnet route is ignored and 192.168.31.14 stays
    # unreachable even with the tunnel up. Linux clients do not accept advertised
    # routes by default. The gating script overrides the effective value at
    # runtime; this is what applies on the very first `tailscale up`.
    extraUpFlags = [ "--accept-routes" ];

    # Sets networking.firewall.checkReversePath = "loose".
    #
    # Daytona currently has strict reverse-path filtering (the NixOS default),
    # which can silently drop replies arriving over tailscale0 for a subnet
    # route. fredvps happens to work without this, but a strict-rp_filter drop is
    # an unpleasant thing to debug -- it looks like the route is missing when it
    # is not -- so the documented setting for a machine that accepts routes is
    # used here rather than relying on that.
    useRoutingFeatures = "client";
  };

  # Immediate reaction to a network change: connecting, disconnecting, a new
  # DHCP lease, or a resume that brings an interface back.
  networking.networkmanager.dispatcherScripts = [
    {
      source = lib.getExe routeGating;
      type = "basic";
    }
  ];

  systemd = {
    services.tailscale-route-gating = {
      description = "Gate Tailscale route acceptance on being off the home LAN";
      after = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe routeGating;
      };
    };

    # Backstop for events the dispatcher cannot see: tailscaled starting after
    # the last network event, a resume that does not re-trigger NetworkManager,
    # or the daemon not yet being ready when the dispatcher fired. Without it a
    # missed event leaves the wrong setting in place until the next network
    # change, which on a laptop that stays put could be days.
    timers.tailscale-route-gating = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
        Persistent = true;
      };
    };
  };
}
