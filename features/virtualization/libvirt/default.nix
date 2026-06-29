{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.virtualization.libvirt;

  # XML definition of the stock libvirt "default" NAT network (virbr0).
  # libvirt does not start or autostart this network on a fresh NixOS host,
  # and there is no native NixOS option to declare it, so we define it
  # ourselves and bring it up via a oneshot ordered after libvirtd.
  defaultNetworkXml = pkgs.writeText "libvirt-default-network.xml" ''
    <network>
      <name>default</name>
      <forward mode="nat">
        <nat>
          <port start="1024" end="65535"/>
        </nat>
      </forward>
      <bridge name="virbr0" stp="on" delay="0"/>
      <ip address="192.168.122.1" netmask="255.255.255.0">
        <dhcp>
          <range start="192.168.122.2" end="192.168.122.254"/>
        </dhcp>
      </ip>
    </network>
  '';
in
{
  config = lib.mkIf cfg.enable {
    # QEMU/KVM via libvirtd. KVM is an in-tree kernel module, so this does
    # not pull in out-of-tree modules that rebuild on every kernel bump
    # (unlike VirtualBox), and everything here is free software served from
    # the binary cache.
    virtualisation.libvirtd = {
      enable = true;
      qemu = {
        package = pkgs.qemu_kvm;
        swtpm.enable = cfg.enableTpm;
      };
    };

    # SPICE USB redirection — native USB passthrough to guests, the
    # open-source replacement for VirtualBox's unfree extension pack.
    virtualisation.spiceUSBRedirection.enable = cfg.enableUsbRedirection;

    programs.virt-manager.enable = cfg.enableVirtManager;

    # Membership in the libvirtd group lets these users manage VMs without
    # root and satisfies the polkit action 'org.libvirt.unix.manage', so
    # virt-manager does not error out with "no polkit agent available".
    users.groups.libvirtd.members = cfg.users;

    # Make virt-manager auto-connect to the system QEMU instance on launch
    # instead of opening a disconnected window. Applied per-user via dconf.
    home-manager.users = lib.mkIf cfg.autoconnect (
      lib.genAttrs cfg.users (_: {
        dconf.settings."org/virt-manager/virt-manager/connections" = {
          autoconnect = [ "qemu:///system" ];
          uris = [ "qemu:///system" ];
        };
      })
    );

    # On recent nixpkgs the firewall blocks DHCP/DNS on virbr0, leaving
    # guests without an IP or internet. Trusting the bridge restores NAT
    # connectivity for the default network.
    networking.firewall.trustedInterfaces = lib.mkIf cfg.defaultNetwork.enable [ "virbr0" ];

    # Define and autostart the default NAT network declaratively so a fresh
    # rebuild has working guest networking without any manual `virsh` steps.
    systemd.services.libvirt-default-network = lib.mkIf cfg.defaultNetwork.enable {
      description = "Define and autostart the libvirt default network";
      after = [ "libvirtd.service" ];
      requires = [ "libvirtd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        virsh="${pkgs.libvirt}/bin/virsh -c qemu:///system"
        if ! $virsh net-info default >/dev/null 2>&1; then
          $virsh net-define ${defaultNetworkXml}
        fi
        $virsh net-autostart default
        if ! $virsh net-info default | grep -q 'Active:.*yes'; then
          $virsh net-start default
        fi
      '';
    };
  };
}
