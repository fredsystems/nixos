# lan-mouse -- software KVM, so one keyboard and mouse cover both desks.
#
# maranello holds the physical peripherals and acts as the SENDER: when the
# pointer crosses the right-hand edge of its monitor layout, input capture
# engages and events are forwarded over the LAN to the Mac Studio, which acts
# as the RECEIVER and replays them locally. That removes the second keyboard
# and mouse from the desk; it is not a remote-desktop tool and carries no
# video.
#
# WHY THIS AND NOT DESKFLOW / INPUT LEAP / SYNERGY
#
# All three capture input on Wayland through the
# `org.freedesktop.portal.InputCapture` portal. That was a GNOME/KDE-only
# interface for years; xdg-desktop-portal-hyprland only gained it recently
# (hyprwm/xdg-desktop-portal-hyprland#268), so it is now possible here but
# barely exercised on this compositor. lan-mouse instead uses the wlroots
# protocols Hyprland has shipped for years -- a one-pixel `wlr-layer-shell`
# surface on each screen edge to capture, `wlr-virtual-pointer` /
# `virtual-keyboard` to emulate -- and has a native CoreGraphics backend on
# macOS rather than a portability shim.
#
# The one regression versus Deskflow is clipboard sharing, which lan-mouse
# does not implement. That matters less here than it would elsewhere: this
# fleet already syncs clipboards out of band through SyncClipboard
# (features/desktop/clipboard).
#
# THIS MODULE IS A THIN WRAPPER
#
# The systemd unit, the launchd agent and the config.toml rendering all come
# from upstream's own home-manager module (`inputs.lan-mouse`). This file only
# supplies the parts that module deliberately leaves alone: the NixOS-level
# firewall hole, the choice of package per platform, and an option surface
# shaped like the rest of `features/desktop`.
{
  lib,
  pkgs,
  config,
  inputs,
  user,
  extraUsers ? [ ],
  isDarwin,
  ...
}:
let
  cfg = config.desktop.lan-mouse;
  allUsers = [ user ] ++ extraUsers;

  # One package, both platforms. `platforms = unix ++ windows` in nixpkgs, and
  # aarch64-darwin builds of 0.11.0 are substitutable from cache.nixos.org, so
  # the Mac gets the same source-built binary as the Linux side rather than a
  # downloaded release artifact -- one version to reason about, and no second
  # thing to keep in step with this one.
  #
  # Set explicitly because the upstream module's default is
  # `self.packages.<system>.default`, i.e. ITS flake's build. That derivation
  # differs from nixpkgs' (own nixpkgs pin, rust-overlay toolchain), so it is
  # absent from cache.nixos.org and would compile Rust + GTK from source on
  # every host. This flake is imported for the module, not the package.
  #
  # `gtk` is a default cargo feature, so this carries the GUI on macOS as well
  # as the daemon -- which matters, see the note on `authorizedFingerprints`
  # about the permission grant.
  package = pkgs.lan-mouse;

  settings = {
    inherit (cfg) port;

    # Peers authenticate by DTLS certificate fingerprint, not by address, so
    # an unauthorised host on the same LAN cannot inject input by claiming an
    # IP. Keeping the list here rather than letting the GUI write it back is
    # what makes this whole module declarative -- see the option description
    # for how to obtain a fingerprint.
    authorized_fingerprints = cfg.authorizedFingerprints;
  }
  // lib.optionalAttrs (cfg.clients != [ ]) {
    clients = map (
      client:
      {
        inherit (client) hostname position;
        activate_on_startup = client.activateOnStartup;
      }
      // lib.optionalAttrs (client.ips != [ ]) { inherit (client) ips; }
      // lib.optionalAttrs (client.port != null) { inherit (client) port; }
    ) cfg.clients;
  };

  clientOpts = {
    options = {
      hostname = lib.mkOption {
        type = lib.types.str;
        example = "Freds-Mac-Studio.local";
        description = ''
          Hostname of the peer to hand input to.

          Do not rely on this alone for a `.local` name. lan-mouse resolves
          hostnames with its own `hickory-resolver` (`src/dns.rs`) rather than
          through the system resolver, so NSS -- and therefore avahi /
          `nssmdns4` -- is never consulted, and an mDNS name fails even on a
          host where `getent ahosts` answers it. Set `ips` as well.
        '';
      };

      position = lib.mkOption {
        type = lib.types.enum [
          "left"
          "right"
          "top"
          "bottom"
        ];
        example = "right";
        description = ''
          Which edge of this machine's screen layout the peer sits beyond.
          The barrier spans that entire edge of the whole layout, not of one
          monitor -- on a multi-monitor grid that is a tall strip, so pick the
          edge that matches the physical desk.
        '';
      };

      ips = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "192.168.31.30" ];
        description = ''
          Static addresses for the peer.

          Effectively mandatory whenever `hostname` is an mDNS `.local` name,
          because lan-mouse's resolver cannot see mDNS at all -- see the note
          on `hostname`. Listing an address grants nothing on its own: the
          peer is still authenticated by certificate fingerprint, so a wrong
          or stale address fails closed rather than open.
        '';
      };

      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = ''
          Port the peer listens on, when it differs from this host's own
          `port`. Null omits the key and lets lan-mouse use its default.
        '';
      };

      activateOnStartup = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to activate this peer as soon as the daemon starts, rather
          than waiting for it to be enabled from the GUI or CLI.
        '';
      };
    };
  };
in
{
  options.desktop.lan-mouse = {
    enable = lib.mkEnableOption "lan-mouse software KVM";

    port = lib.mkOption {
      type = lib.types.port;
      default = 4242;
      description = ''
        UDP port the daemon listens on for peer traffic. Must agree with the
        `port` every peer has configured for this host.
      '';
    };

    clients = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule clientOpts);
      default = [ ];
      description = ''
        Peers this machine can hand input to, and where they sit relative to
        this machine's screen layout.

        A receive-only machine leaves this empty: it still accepts input from
        an authorised peer, because that depends on the peer's own client list
        plus `authorizedFingerprints` here, not on an entry in this list.
      '';
    };

    authorizedFingerprints = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "bc:05:ab:7a:a4:de:88:8c:2f:92:ac:bc:b8:49:b8:24" = "maranello";
      };
      description = ''
        Peer certificate fingerprints permitted to connect, keyed by
        fingerprint with a human label as the value.

        A fingerprint is `sha256` over the peer's DER certificate, lowercase
        hex, colon-separated (`src/crypto.rs:generate_fingerprint`). It does
        not exist until that machine has run lan-mouse once and generated
        `~/.config/lan-mouse/lan-mouse.pem`, so this is a bootstrap-once value:
        start the daemon on the peer, then read it back with

        ```sh
        nix run nixpkgs#openssl -- x509 -in ~/.config/lan-mouse/lan-mouse.pem \
          -noout -fingerprint -sha256 | sed 's/.*=//' | tr 'A-Z' 'a-z'
        ```

        The `--` is required: without it `nix run` parses `-noout` as its own
        flag and dies with "unrecognised flag '-n'". `openssl` is not in this
        host's `systemPackages`, hence `nix run` rather than a bare call.

        Note that the `.pem` holds the private key as well as the certificate
        (`crypto.rs` writes `cert.serialize_pem()`, mode 0400), so read the
        fingerprint out of it rather than copying the file around. The command
        above only ever reads the certificate block.

        and record it here. It is stable for as long as that `.pem` survives.

        Leaving this empty is not a security default, it is a broken one: no
        peer can connect, and the alternative (authorising interactively) does
        not survive an activation, because the config file this renders is a
        read-only store symlink.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to accept lan-mouse traffic on `port`. Linux only; macOS has
        no per-port firewall to open here.

        Needed even on a send-only machine. The protocol is bidirectional --
        the peer replies on the same socket for liveness tracking, which is
        what releases a grab and returns the pointer when the other end goes
        away. With the port closed the pointer can leave and not come back.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    {
      home-manager.users = lib.genAttrs allUsers (
        _:
        {
          imports = [ inputs.lan-mouse.homeManagerModules.default ];

          programs.lan-mouse = {
            enable = true;
            inherit package settings;

            # Set explicitly rather than left to their defaults, which are
            # `pkgs.stdenv.isLinux` / `pkgs.stdenv.isDarwin` -- deprecated
            # aliases that emit `evaluation warning: stdenv.isLinux is
            # deprecated`. This repo's CI fails on any evaluation warning
            # (ci-linux.yaml), so an unset default here is a broken build, not a
            # cosmetic nit. Assigning both means the defaults are never forced.
            systemd = !isDarwin;
            launchd = isDarwin;
          };
        }
        // lib.optionalAttrs (!isDarwin) {
          # Upstream's unit sets only Type and ExecStart, so a crash leaves
          # input sharing dead until the next login with no indication beyond
          # the pointer refusing to cross the edge. These merge into their
          # definition rather than replacing it -- no keys overlap. Matches what
          # features/desktop/clipboard does for the same reason.
          #
          # Ordering is handled separately: their `Install.WantedBy` is
          # `hyprland-session.target`, and maranello's home.nix additionally
          # restarts the unit from `hl.on("hyprland.start")`, which is what
          # guarantees the layer-shell capture surfaces are created against
          # outputs that actually exist.
          systemd.user.services.lan-mouse.Service = {
            Restart = "always";
            RestartSec = "5s";
          };
        }
      );
    }
    # `networking.firewall` does not exist on nix-darwin, so this cannot be a
    # `lib.mkIf` on the same attrset -- the option would still be looked up.
    // lib.optionalAttrs (!isDarwin) {
      # UDP, not TCP: lan-mouse carries input events over DTLS.
      networking.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
    }
  );
}
