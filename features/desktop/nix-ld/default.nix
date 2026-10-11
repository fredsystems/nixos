{
  lib,
  config,
  ...
}:
let
  cfg = config.desktop.nix-ld;
in
{
  options.desktop.nix-ld = {
    enable = lib.mkEnableOption "nix-ld, a dynamic loader shim for unpatched prebuilt binaries";
  };

  # NixOS has no /lib64/ld-linux-x86-64.so.2, so generic-Linux prebuilt
  # binaries fail to start with "No such file or directory". This hits
  # everyday dev work: pip/uv wheels with native code (numpy,
  # pydantic-core, ...), uv-managed Python downloads, and npm packages that
  # fetch a platform binary at install time (@biomejs/biome, sharp, esbuild).
  # nix-ld installs a shim at the standard loader path that resolves
  # libraries from NIX_LD_LIBRARY_PATH.
  #
  # `libraries` is left at the nixpkgs default set on purpose. It already
  # includes libstdc++ (stdenv.cc.cc), zlib, openssl, and the rest of the
  # usual suspects. Add to it only when a specific binary needs a library
  # that is not in it.
  config = lib.mkIf cfg.enable {
    programs.nix-ld.enable = true;
  };
}
