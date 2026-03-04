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
  ++ lib.optional isDesktop ./desktop;

  config = {
    services.xserver.xkb = {
      layout = "us";
      variant = "";
    };
  };
}
