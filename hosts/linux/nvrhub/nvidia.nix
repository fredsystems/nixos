# NVIDIA proprietary driver for nvrhub — GPU object detection for Frigate.
#
# WHY THIS EXISTS
#
# Frigate runs object detection on the CPU here, and it is the single largest
# consumer on the box: the detector process alone averages ~219% CPU with a
# 320x320 ssdlite_mobiledet, against a 16-thread Ryzen 7 3800X carrying a load
# average of ~12. That model is also weak enough to be the root cause of the
# camera-process CPU on the outdoor cameras -- it scores a street-parked car at
# 0.63-0.67, straddling the confidence threshold, so the object is repeatedly
# acquired and lost instead of settling to `stationary`, and every frame gets a
# fresh detector region. It has also been observed labelling a car as a
# motorcycle at 0.707.
#
# The box has a GeForce RTX 3070 (GA104) sitting idle on nouveau. Moving
# inference onto it removes the detector CPU outright and, more importantly,
# affords a real model (YOLOv9 at 640) whose scores are high and stable enough
# that the churn stops.
#
# This file does NOTHING but make the GPU usable. It deliberately does not
# touch Frigate: the detector switch is a later, separate change, so that if
# the driver misbehaves the NVR keeps recording on the CPU detector exactly as
# before. See hosts/linux/nvrhub/frigate.nix.
#
# ROLLBACK
#
# This is the one change here that can stop a headless box booting. NixOS keeps
# the previous generation in the bootloader, so recovery is selecting the prior
# entry at the console -- which requires physical access to the machine, not
# SSH. Do not deploy this remotely.
{ config, ... }:
{
  # The `hardware.nvidia` module is GATED on this list, not on
  # `hardware.nvidia.enable` -- there is no such option. nixpkgs'
  # nixos/modules/hardware/video/nvidia.nix:8 reads
  #
  #   nvidiaEnabled = lib.elem "nvidia" config.services.xserver.videoDrivers;
  #
  # and every bit of config below is behind it. So a headless compute-only host
  # still has to name the driver here. This does NOT enable X: that is
  # `services.xserver.enable`, which stays off. The option is misnamed for this
  # use, not misused.
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    # 595.71.05 -- `production`, `stable` and `latest` are all the same version
    # in this nixpkgs, so this is the unambiguous choice rather than a
    # preference between branches.
    package = config.boot.kernelPackages.nvidiaPackages.production;

    # Open kernel modules.
    #
    # MUST be set explicitly: for drivers >= 560 the option defaults to `null`
    # and nvidia.nix:417 asserts `cfg.open != null`, so leaving it out is an
    # evaluation error rather than a silent default.
    #
    # `true` because this is a GA104 (Ampere). NVIDIA's open modules support
    # Turing and newer and are the recommended path there; the proprietary
    # modules are the legacy option for pre-Turing hardware. It also makes
    # `nvidia_uvm` an explicit kernelModule (nvidia.nix:455) rather than
    # relying on the softdep used for the closed modules, and nvidia_uvm is
    # what CUDA actually needs (see nvidia.nix:819).
    open = true;

    # nvidia-settings is a GTK control panel. There is no display, no X session
    # and nobody to click it, and the module defaults it to true, so it is
    # turned off here purely to keep it out of the closure.
    nvidiaSettings = false;

    # Keeps the GPU initialised when nothing holds a device handle.
    #
    # Without a running X server or persistent client, the driver tears down
    # GPU state whenever the last handle closes, and the next CUDA context has
    # to re-initialise the device. Frigate's detector opens a context at
    # startup and holds it, so this is not strictly required -- it matters for
    # the gap around a Frigate restart, and it removes a class of first-inference
    # latency spike that would otherwise look like a detector stall.
    nvidiaPersistenced = true;
  };

  # nouveau does NOT need blacklisting here. nvidia.nix:433 already adds it to
  # `boot.blacklistedKernelModules` whenever the module is enabled. Adding a
  # second declaration would merge harmlessly but would imply this file is
  # responsible for something it is not.

  # Unfree allowlist.
  #
  # This fleet has no blanket `allowUnfree`; modules/base/nixpkgs-unfree.nix
  # turns a merged allowlist into nixpkgs' `allowUnfreePredicate`, and the
  # convention documented there is that the module pulling a package in is the
  # one that declares it. Names are as `lib.getName` sees them, which is why
  # this is the pname and not the full derivation name.
  #
  # nvidia-x11 covers the driver and its kernel modules. nvidia-persistenced is
  # a separate derivation pulled in by nvidiaPersistenced above.
  nixpkgsUnfree.allowed = [
    "nvidia-x11"
    "nvidia-persistenced"
  ];
}
