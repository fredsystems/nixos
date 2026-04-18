{
  ...
}:
{
  imports = [
    ../../../profiles/darwin.nix
    ../../../features/ai/opencode
  ];

  ai = {
    opencode.enable = true;
  };
}
