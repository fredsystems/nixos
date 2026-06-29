{
  lib,
  isDesktop ? false,
  ...
}:
{
  imports = [
    ./ai
    ./common
    ./media
    ./shell
  ]
  ++ lib.optionals isDesktop [
    ./desktop
    ./virtualization
  ];

  config = {
    services.xserver.xkb = {
      layout = "us";
      variant = "";
    };
  };
}
