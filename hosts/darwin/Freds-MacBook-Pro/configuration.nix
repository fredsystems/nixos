{
  ...
}:
{
  imports = [
    ../../../profiles/darwin.nix
    ../../../features/ai/opencode
  ];

  ai = {
    # Temporarily disabled: nixpkgs b5aa0fbd forces a fresh aarch64-darwin
    # rebuild of opencode, whose build-time `--version` smoke test is
    # SIGKILLed (exit 137) by the macOS kernel due to the Mach-O page-hash
    # code-signing corruption from the unmerged nix daemon fix
    # (NixOS/nix#15638). Re-enable once a patched daemon ships.
    opencode.enable = false;
  };
}
