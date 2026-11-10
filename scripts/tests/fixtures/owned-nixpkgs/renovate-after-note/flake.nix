{
  inputs = {
    # NOTE: deliberately NOT following our nixpkgs for testing.
    #
    # renovate: datasource=git-refs depName=opencode packageName=https://github.com/anomalyco/opencode versioning=semver
    opencode = {
      url = "github:anomalyco/opencode/v2.2.7";
    };
  };
}
