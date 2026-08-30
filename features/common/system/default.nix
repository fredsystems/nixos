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

    # FIXME(nixpkgs-375376-stc-network-freeze): WORKAROUND, not a fix.
    #
    # Reload NetworkManager on activation instead of restarting it, so a
    # `nixos-rebuild switch` never takes the network down.
    #
    # Why this is not cosmetic: switch-to-configuration stops NetworkManager
    # in its stop pass, and then -- if systemd's store path changed, which a
    # glibc/stdenv mass rebuild causes even at an identical systemd version --
    # asks PID 1 to `daemon-reexec`. On re-exec PID 1 re-runs its generators,
    # and systemd-fstab-generator calls chase()/stat() on every fstab entry.
    # Our NFSv3 mounts (modules/data/nas-mounts.nix, mounted `hard`) then
    # block forever because the network is gone. The generator sandbox times
    # out after 90s, safe_fork(FORK_WAIT) maps that to -EPROTO, generators are
    # mandatory, and PID 1 executes `Freezing execution.` -- alive but deaf.
    # Nothing can start or stop, and `reboot` (a D-Bus call to PID 1) hangs,
    # so the box needs SysRq or the power button. Observed on maranello
    # 2026-08-29 20:21 and repeatedly on Daytona.
    #
    # Upstream: https://github.com/NixOS/nixpkgs/issues/375376 (open). The
    # NixOS systemd maintainers' stated position there is that network
    # daemons should reload rather than restart on activation -- "taking down
    # networking for stc is *very bad*" -- which is exactly this setting.
    #
    # Tradeoff: the running NetworkManager stays on the OLD store path until
    # something restarts it, so a NetworkManager update (including a security
    # fix) is not live until `systemctl restart NetworkManager` or a reboot.
    # scripts/switch-preflight.sh detects and reports that deferred restart by
    # comparing the unit's ExecStart against /proc/$MAINPID/exe, so it is a
    # visible, verified state rather than a silent one.
    #
    # Deliberately NOT applied to wpa_supplicant.service: it reports
    # CanReload=no, and the 2026-08-29 journal shows it was never stopped by
    # switch-to-configuration (its disconnect was NetworkManager tearing down
    # the supplicant interface during NM's own shutdown). Forcing a lifecycle
    # change there would be speculative. switch-preflight.sh watches it, along
    # with systemd-networkd and dhcpcd, and routes to `boot` if any of them
    # ever does land in the stop/restart set.
    #
    # Revert: once #375376 is fixed such that a hung generator can no longer
    # freeze PID 1 (or NixOS reloads network daemons by default), delete this
    # and the FIXME. See .github/workflows/track-upstream-fixes.yaml.
    #
    # Gated on the merged option value, so fredvps -- which sets
    # `networkmanager.enable = lib.mkForce false` and uses systemd-networkd
    # (hosts/linux/fredvps/configuration.nix:255) -- does not get a stub
    # systemd.services.NetworkManager definition.
    #
    # The mkIf MUST wrap the whole `systemd.services` attrset rather than sit
    # at `systemd.services.NetworkManager.reloadIfChanged = mkIf ...`. In the
    # latter form the attribute NAME `NetworkManager` is still part of the
    # definition, so the submodule is instantiated even when the condition is
    # false, and fredvps gains a stub NetworkManager.service in its closure.
    # Verified: with the inner form, fredvps's config.systemd.units gained a
    # "NetworkManager.service" key that it does not have on main.
    systemd.services = lib.mkIf config.networking.networkmanager.enable {
      NetworkManager.reloadIfChanged = true;
    };

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
