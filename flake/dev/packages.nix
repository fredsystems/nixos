# Per-system package outputs.
#
# Arguments:
#   inputs           — flake inputs attrset
#   forAllSystems    — nixpkgs.lib.genAttrs supportedSystems
{
  inputs,
  forAllSystems,
  ...
}:
let
  inherit (inputs) nixpkgs walls-catppuccin;
in
{
  packages = forAllSystems (
    system:
    let
      pkgs = import nixpkgs { inherit system; };
    in
    {
      catppuccin-wallpapers = pkgs.stdenvNoCC.mkDerivation {
        pname = "catppuccin-wallpapers";
        version = "git";

        src = walls-catppuccin;

        installPhase = ''
          mkdir -p $out/share/backgrounds
          cp -r . $out/share/backgrounds/
        '';
      };
    }
  );
}
