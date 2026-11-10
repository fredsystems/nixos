{
  description = "flake-input-impact.sh test fixture: dep-owning's own (owned) nixpkgs";
  outputs = _: {
    lib = {
      version = "owned-tar-v1";
    };
  };
}
