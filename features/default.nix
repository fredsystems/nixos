# Applied by modules/base/system-linux.nix as `import ../../features { ... }`:
# whether a host gets the desktop tree is fixed by the builder (mkSystem's
# isDesktop) before module evaluation, so it can decide `imports` without the
# recursion a module argument or option would cause. desktop and
# virtualization stay at this position in the import order.
{
  isDesktop ? false,
}:
_: {
  imports = [
    ./ai
    ./common
    ./media
    ./shell
  ]
  ++ (
    if isDesktop then
      [
        ./desktop
        ./virtualization
      ]
    else
      [ ]
  );

  config = {
    services.xserver.xkb = {
      layout = "us";
      variant = "";
    };
  };
}
