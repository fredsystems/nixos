{
  description = "flake-input-impact.sh test fixture: an input that follows the root's nixpkgs";
  inputs.nixpkgs.url = "git+file://@TMPROOT@/fake-nixpkgs";
  outputs =
    { nixpkgs, ... }:
    {
      # Never read by consumer/flake.nix's outputs -- that is the point
      # of this fixture (case b).
      unused = nixpkgs.lib.version;
      marker = "follow-v1";
    };
}
