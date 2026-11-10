{
  description = "flake-input-impact.sh test fixture: an input that owns its own nixpkgs";
  # Rewritten by the test to point at a new (v2) tarball snapshot to
  # simulate "this input's repo got a new commit that only bumps its own
  # nixpkgs pin" -- the real-world niri/colmena/catppuccin case.
  inputs.nixpkgs.url = "file://@TMPROOT@/tarballs/nixpkgs-owned-v1.tar.gz";
  outputs = { nixpkgs, ... }: { thing = nixpkgs.lib.version; };
}
