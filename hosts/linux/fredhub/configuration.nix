{
  config,
  inputs,
  system,
  stateVersion,
  lib,
  pkgs,
  ...
}:
let
  unstablePkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfreePredicate =
      pkg:
      builtins.elem (lib.getName pkg) [
        "open-webui"
      ];
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/adsb-hub.nix
    ../../../modules/services/attic/attic_server.nix
    ./nginx.nix
  ];

  # open-webui's nixpkgsUnfree.allowed entry is contributed by
  # features/ai/lammacpp/default.nix itself (mkIf ai.local-llm.enable), so no
  # entry is needed here. The near-identical predicate in the `let` above is
  # NOT a duplicate of that: this one configures a separate
  # `import nixpkgs { }` instance for unstable packages, which the NixOS
  # module system never reaches.

  ai = {
    local-llm = {
      enable = true;
      ollamaPackage = unstablePkgs.ollama;
      openwebPackage = unstablePkgs.open-webui;
      host = "0.0.0.0";
      models = [
        "qwen3.6:latest"
        "gemma4:latest"
      ];
    };
  };

  media.jellyfin = {
    enable = true;
  };

  networking.hostName = "fredhub";

  system.stateVersion = stateVersion;

  ci.githubRunners = {
    enable = true;
    repo = "FredSystems/nixos";
    defaultTokenFile = config.sops.secrets."github-token".path;
    # Auto-generates runner-1 through runner-8.
    #
    # fredhub is the only Linux runner host, and ci-linux.yaml's matrix can
    # fan out to 9 hosts, so 4 was the throughput ceiling for a full-fleet
    # rebuild. The box is 32 cores / 125 GiB with ~120 GiB genuinely
    # available; an idle runner costs ~65 MiB, so the runners themselves are
    # free. See the max-jobs note below before raising this further.
    runnerCount = 8;
  };

  # Self-hosted runner for fredsystems/freminal's nightly fuzzing
  # (.github/workflows/fuzz-nightly.yml in that repo, label `freminal-fuzz`).
  #
  # Defined directly, not through `ci.githubRunners`: that wrapper can express
  # neither labels nor serviceOverrides, and its stale-registration cleanup is
  # hard-wired to `ci.githubRunners.repo` (this repo). `replace = true` covers
  # re-registration instead.
  #
  # Non-ephemeral on purpose: the work dir (cargo's target/ and fuzz/target/)
  # then survives between nightly jobs and spares a cold build. The fuzz
  # corpus does NOT live here -- the job pulls it from and pushes it back to
  # the private fredsystems/freminal-fuzz-corpus repo -- so a wiped work dir or
  # a rebuilt host only costs one cold build.
  #
  # Only maintainer-triggered code reaches it: the freminal workflow runs on
  # schedule / workflow_dispatch only, never pull_request (public repo).
  #
  # Scheduling: the job runs inside a quiet window (01:07 UTC start, hard
  # 07:30 UTC end, enforced by the workflow) chosen to avoid this fleet's CI
  # load. As a second layer the unit runs at the lowest CPU and I/O priority,
  # so the fleet's ci-linux builds (runner-1..8 above) win the CPU if anything
  # still overlaps.
  services.github-runners.freminal-fuzz = {
    enable = true;
    name = "nixos-fredhub-freminal-fuzz";
    url = "https://github.com/fredsystems/freminal";
    # Same PAT as the fleet runners; it must be allowed to manage self-hosted
    # runners on fredsystems/freminal.
    tokenFile = config.sops.secrets."github-token".path;
    extraLabels = [ "freminal-fuzz" ];
    replace = true;
    ephemeral = false;
    # Tools the workflow's own shell steps use (the runner's default PATH is
    # only bash, coreutils, git, gnutar, gzip and nix): `gh` / `jq` for the
    # findings tracking issue, `hostname` for the corpus commit message.
    extraPackages = with pkgs; [
      gawk
      findutils
      gh
      gnugrep
      gnused
      hostname
      jq
    ];
    serviceOverrides = {
      Nice = 19;
      CPUWeight = 10;
      IOSchedulingClass = "idle";
      # Each fuzz target runs up to 8 libFuzzer workers capped at 2 GiB RSS
      # each; leave headroom for cargo builds without letting a runaway job
      # take the whole box.
      MemoryMax = "40G";
    };
  };
}
