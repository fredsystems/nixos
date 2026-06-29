{
  lib,
  user,
  extraUsers ? [ ],
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
in
{
  imports = [
    ./libvirt
  ];

  options.virtualization.libvirt = {
    enable = lib.mkEnableOption "libvirt/QEMU/KVM virtualization with virt-manager";

    enableVirtManager = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the virt-manager graphical VM management GUI.";
    };

    enableUsbRedirection = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable SPICE USB redirection for host-to-guest USB passthrough.";
    };

    enableTpm = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable swtpm (TPM emulation) for guests.";
    };

    autoconnect = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Auto-connect virt-manager to qemu:///system on launch (per-user dconf).";
    };

    defaultNetwork.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Define and autostart the default libvirt NAT network (virbr0), plus trust the bridge in the firewall.";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = allUsers;
      description = "Users to add to the libvirtd group for VM management without root.";
    };
  };
}
