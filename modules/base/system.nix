{
  config,
  inputs,
  lib,
  isDarwin,

  catppuccinInput ? inputs.catppuccin,
  ...
}:

let
  isLinux = !isDarwin;
in
{
  imports =
    lib.optional isDarwin inputs.home-manager.darwinModules.default
    ++ lib.optional isDarwin ../services/homebrew.nix
    ++ lib.optional isLinux catppuccinInput.nixosModules.catppuccin
    ++ lib.optional isLinux ../../features
    ++ lib.optional isLinux ../../modules/base/user.nix
    ++ lib.optional isLinux ../../modules/system/kernel-pin.nix
    ++ lib.optional isLinux ./catppuccin.nix;

  nix = {
    extraOptions = lib.mkIf isLinux ''
      !include ${config.sops.templates."nix-access-tokens.conf".path}
    '';

    settings = {
      substituters = [
        "http://192.168.31.14:8080/fred"
        "https://colmena.cachix.org"
        "https://catppuccin.cachix.org"
        "https://niri.cachix.org"
        "https://niri-epireyn.cachix.org"
        "https://cache.nixos.org"
      ];

      trusted-public-keys = [
        "fred:JjyhvRSvKfkk8r4HS0mS5r5I7dT4GociEFbrR9OgBZ0="
        "colmena.cachix.org-1:7BzpDnjjH8ki2CT3f6GdOk7QAzPOl+1t3LvTLXqYcSg="
        "catppuccin.cachix.org-1:noG/4HkbhJb+lUAdKrph6LaozJvAeEEZj4N732IysmU="
        "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
        "niri-epireyn.cachix.org-1:tlVyFN7CtsDT+ZcLPS+ekFWeT1X6X4OqvWqbBMyIzFA="
      ];

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
// lib.optionalAttrs isLinux {
  security.sudo.wheelNeedsPassword = false;

  sops.secrets.github_pat = { };

  sops.templates."nix-access-tokens.conf".content = ''
    access-tokens = github.com=${config.sops.placeholder.github_pat}
  '';

  # Explicit journal retention. Previously unset everywhere, which meant every
  # host silently inherited journald's defaults -- and those defaults are the
  # reason all seven servers sat at the same ~4G: SystemMaxUse defaults to 10%
  # of the filesystem but is hard-capped at 4G, so a 74G root resolved to
  # 7.4G -> clamped to 4G. Nothing was leaking; the cap was simply doing its
  # job invisibly, and the only way to find that out was to go read journald's
  # source-level defaults. Stating the policy here makes it reviewable and
  # per-host overridable via lib.mkForce.
  #
  # Compression is NOT configured because it is already active -- journal
  # headers report COMPRESSED-ZSTD, so there is no win available there.
  services.journald.extraConfig = ''
    # Total on-disk journal budget. 1G is ~20 days at fredvps's (post
    # --no-access-log) rate and far more on the quieter decoder hubs, while
    # returning ~3G per host versus the implicit 4G default.
    SystemMaxUse=1G

    # Cap per-file size so vacuuming is fine-grained. Files were landing at
    # 50-67M, meaning journald could only ever reclaim space in chunks that
    # coarse; 64M keeps rotation predictable rather than lumpy.
    SystemMaxFileSize=64M

    # Time ceiling, which was previously unbounded -- fredvps was holding 82
    # days purely because 4G happened to span that long. Retention should be a
    # decision, not a side effect of volume: a quiet host keeping a year and a
    # noisy one keeping a week is exactly the inconsistency that makes
    # cross-host incident correlation unreliable. Loki (sdrhub) is the
    # long-term store at retention_period=30d, so the local journal only needs
    # to cover the window where you would log into the box directly.
    MaxRetentionSec=30day

    # Force rotation by age so a low-traffic host still produces file
    # boundaries, keeping MaxRetentionSec able to expire whole files.
    MaxFileSec=1day
  '';

  # The goModules fixed-output derivation in nixpkgs includes "GOPROXY" in
  # impureEnvVars, meaning it inherits GOPROXY from the Nix daemon's environment.
  # proxy.golang.org redirects Go module downloads to a GCS bucket
  # (proxy-golang-org-prod) which is geo-restricted ("not available in your
  # location") on this local network.
  # goproxy.cn has its own storage for most modules but falls back to
  # proxy.golang.org (GCS) for uncached entries, which also fails.
  # mirrors.aliyun.com/goproxy/ is backed by Alibaba Cloud OSS (not GCS)
  # and confirmed to serve all required modules directly.
  systemd.services.nix-daemon.environment = {
    GOPROXY = "https://mirrors.aliyun.com/goproxy/";
    GONOSUMDB = "*";
  };
}
