{
  user,
  extraUsers ? [ ],
  lib,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.gh-dash = {
        enable = true;
        settings = {
          prSections = [
            {
              title = "fredsystems";
              filters = "is:pr is:open org:fredsystems";
            }
            {
              title = "sdr-enthusiasts";
              filters = "is:pr is:open org:sdr-enthusiasts";
            }
            {
              title = "fredclausen";
              filters = "is:pr is:open user:fredclausen";
            }
          ];
        };
      };

      catppuccin.gh-dash.enable = true;
    });
  };
}
