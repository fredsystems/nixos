let
  # The public caches are listed once, in flake.nix's nixConfig: Nix
  # requires that attrset to be a literal, so it is the one place that
  # cannot read a shared file, and everything else reads it instead. Every
  # host (and so every self-hosted CI runner) adds our LAN Attic cache in
  # front of them and cache.nixos.org behind.
  inherit ((import ../../flake.nix).nixConfig) extra-substituters extra-trusted-public-keys;
in
{
  imports = [
    ./nixpkgs-unfree.nix
    ./fleet-identity.nix
    ./fleet-identity-hm-bridge.nix
  ];

  nix = {
    settings = {
      substituters = [
        "http://192.168.31.14:8080/fred"
      ]
      ++ extra-substituters
      ++ [ "https://cache.nixos.org" ];

      trusted-public-keys = [
        "fred:JjyhvRSvKfkk8r4HS0mS5r5I7dT4GociEFbrR9OgBZ0="
      ]
      ++ extra-trusted-public-keys;

      # Nix's default is 15s, which is the wrong shape for a substituter list
      # whose first entry is a LAN address.
      #
      # http://192.168.31.14:8080/fred is unroutable from anywhere but the home
      # network, and a foreign network typically blackholes 192.168.31.0/24
      # rather than returning ICMP unreachable -- so the connection does not fail
      # fast, it sits through the full timeout. Nix stops retrying a cache that
      # errored for the rest of the process, so the cost is roughly once per nix
      # invocation rather than once per path, but with direnv auto-loading a flake
      # on every `cd` that is once per directory change.
      #
      # 5s bounds the whole connection phase -- DNS resolution, the TCP handshake
      # and, for the https substituters, the TLS handshake -- but not the
      # transfer, which `stalled-download-timeout` already covers. Reaching that
      # point with cache.nixos.org or cachix takes well under a second on a
      # healthy link and a small multiple of that on a poor one, so 5s cuts the
      # off-LAN stall by two thirds while still leaving several times the
      # realistic worst case.
      #
      # This is a mitigation, not the fix: with Tailscale up and
      # --accept-routes, 192.168.31.14 is genuinely reachable and the timeout
      # stops mattering. It is worth having anyway, for when the tunnel is down
      # or deliberately off.
      connect-timeout = 5;

      trusted-users = [
        "root"
        "@wheel"
        "fred"
      ];

      experimental-features = [
        "nix-command"
        "flakes"
      ];

      # min-free/max-free are checked by the Nix daemon around normal store
      # operations (substitutions, builds), not just the scheduled `gc`
      # below -- when free space on the store's filesystem drops under
      # min-free, the daemon runs garbage collection there and then,
      # deleting until max-free is reached (or nothing is left to collect).
      # This is what actually reclaims space mid-week; `gc.automatic` above
      # only ever fires once a week and does nothing about a Tuesday that
      # fills the disk.
      #
      # Values are bytes and deliberately conservative given how wide this
      # fleet's disk sizes are -- a small VPS up to bare-metal servers with
      # multi-TB volumes all read this same setting. 1 GiB min-free is a
      # floor that still leaves real headroom before "disk full" on the
      # smallest host, without being so large it starts collecting
      # constantly there. 5 GiB max-free is a small, fast reclaim on a big
      # server and a meaningful chunk of breathing room on a small one;
      # either way collection stops well before it turns into an unbounded
      # sweep of the whole store.
      min-free = 1073741824; # 1 GiB
      max-free = 5368709120; # 5 GiB
    };

    gc = {
      automatic = true;
      options = "--delete-older-than 7d";
    };
    optimise.automatic = true;
  };
}
