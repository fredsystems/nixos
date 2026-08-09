{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
{
  config = {

    # Enable networking
    networking.networkmanager.enable = true;

    environment.systemPackages = with pkgs; [
      pass
      wget
      unzip
      file
      zip
      (lib.lowPrio toybox)
      inetutils
      nix-index
      lm_sensors
      dig
      nethogs
      inotify-tools
      usbutils
      hwdata
      airspy
      pciutils
      inputs.nixos-needsreboot.packages.${config.nixpkgs.hostPlatform.system}.default
    ];

    services = {
      # mDNS/Bonjour, for `<host>.local` discovery on the LAN.
      #
      # Disabled on internet-facing nodes. It is a LAN discovery protocol
      # with nothing to discover on a VPS, and enabling it there means a
      # daemon bound to the public interface advertising the host's
      # existence, plus UDP 5353 open in the firewall.
      #
      # Not currently exploitable -- mDNS is link-local by design (TTL 1,
      # and responders ignore off-link unicast queries), and a query sent
      # to fredvps's public address from off-net got no reply. This is
      # removing surface that serves no purpose, not closing a live hole.
      avahi = {
        enable = !config.deployment.internetFacing;
        nssmdns4 = true;
        publish = {
          enable = true;
          addresses = true;
          workstation = true;
        };
      };
      fwupd.enable = true;

      udev.packages = with pkgs; [
        airspy
      ];

      logind = {
        settings = {
          Login = {
            KillUserProcesses = true;
          };
        };
      };
    };

    nixpkgs.config = {
      permittedInsecurePackages = [
        "openssl-1.1.1w"
      ];

      allowUnfree = true;
    };

    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (
          subject.isInGroup("users")
            && (
              action.id == "org.freedesktop.login1.reboot" ||
              action.id == "org.freedesktop.login1.reboot-multiple-sessions" ||
              action.id == "org.freedesktop.login1.power-off" ||
              action.id == "org.freedesktop.login1.power-off-multiple-sessions"
            )
          )
        {
          return polkit.Result.YES;
        }
      })

      // Workaround for upstream NixOS bug: fwupd-refresh.service runs
      // fwupdmgr as the `fwupd-refresh` user, which has no seat and
      // therefore falls under <allow_any>auth_admin</allow_any> for the
      // refresh polkit actions, so the unit fails with
      // "Failed to obtain auth" on every timer fire. Upstream expects
      // the uid to be listed under TrustedUids in fwupd.conf, but on
      // NixOS the uid is allocated at activation time and not known
      // during evaluation, so we grant the actions via a polkit rule
      // keyed on the user name instead. Mirrors NixOS/nixpkgs#526476;
      // remove this block once that lands in the channels we track.
      polkit.addRule(function(action, subject) {
        if ((action.id == "org.freedesktop.fwupd.get-remotes" ||
             action.id == "org.freedesktop.fwupd.refresh-remote") &&
            subject.user == "fwupd-refresh") {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
