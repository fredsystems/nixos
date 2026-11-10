{
  description = "flake-input-impact.sh test fixture: the root's own nixpkgs";
  outputs = _: {
    lib = {
      version = "root-v1";
    };
  };
}
