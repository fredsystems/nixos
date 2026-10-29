{ lib, ... }:
{
  # Single source of truth for every container image this fleet runs,
  # across every registry -- not just ghcr.io/sdr-enthusiasts. Follows the
  # same "shared value used by multiple hosts" idiom as nas-mounts.nix /
  # sync-hosts.nix / wifi-networks.nix in this directory: the data lives
  # directly in an option's default, and host configs read
  # config.shared.dockerImages.<name> instead of inlining the
  # repo:tag@digest string.
  #
  # WHY CENTRALIZE EVEN SINGLE-HOST IMAGES
  #
  # Two images (acarshub, acarsRouter) are genuinely shared verbatim
  # across sdrhub and fredvps, and two more repeat multiple times
  # within one host's own file (dumpvdl2 x4 in vdlmhub, dumphfdl x3 in
  # hfdlhub1) -- both are the same underlying
  # risk: nothing stops the copies from drifting apart on a manual edit.
  # Splitting "shared images live here, single-host images stay inline"
  # was considered and rejected as more confusing than one consistent
  # rule, so every image is here, including ones only one host runs
  # today. A CI cost objection to that (any file under modules/ used to
  # force a full 10-host rebuild) no longer applies: the impacted-hosts
  # classifier (scripts/impacted-hosts.sh) now decides from a real
  # derivation diff, so a pin bump here only rebuilds the hosts that
  # actually import it, regardless of file location.
  #
  # RENOVATE
  #
  # The `customManagers` regex manager in .github/renovate.json5 matches
  # on the quoted `registry/repo:tag@sha256:digest` value itself, not on
  # the attribute name preceding it, so it updates entries here exactly
  # like it previously updated inline `image = "...";` strings. See that
  # file's comments before changing the shape of entries below.
  #
  # ONE BLANK LINE BETWEEN PINS
  #
  # Renovate opens one PR per image, often a dozen within a minute, each
  # changing one line of this file from the same base. Git's three-way
  # merge treats edits to ADJACENT lines as a conflict even when they touch
  # different attributes, so with pins on consecutive lines the merge queue
  # kept ejecting bumps whose neighbour had landed first. A single unchanged
  # line between any two pins (blank or comment) is enough for git to merge
  # them cleanly. Enforced by scripts/check-docker-pin-spacing.sh (pre-commit
  # hook + `checks.docker-pin-spacing`); do not collapse the spacing.
  #
  # `airspyAdsb` and `acars2posAlt` are pinned here even though sdrhub's
  # container blocks that would use them are currently commented out
  # (inactive/alternate configurations) -- kept so Renovate still tracks
  # them and the pin is ready if either is re-enabled.
  options.shared.dockerImages = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {
      # Shared by every host that imports profiles/adsb-hub.nix or
      # modules/services/adsb-docker-units.nix directly (sdrhub), via
      # modules/services/mk-dozzle-agent.nix.
      dozzle = "amir20/dozzle:v11.3.5@sha256:dd09e6aaa9d5ad686b6017427a502c40dc862ba28445609813e5ea1f66f6dbdf";

      # acarshub host
      xng = "ghcr.io/sdr-enthusiasts/docker-xng:latest-build-12@sha256:878d2b04dc3e77ff2ba9f9b17998eb44da433aa8adeb5b6776921c65ea2abe33";

      # fredvps host
      fredSite = "ghcr.io/fredsystems/fred-site:latest-build-8@sha256:53659b897364c139dc504e6824ae999febdfe96616fbf306b8681a493510ed81";

      sdreImageApi = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-7@sha256:38df445fe37101648032e849a477ee3221ce8517cebd72983e21d9e1ba8dfbff";

      tar1090 = "ghcr.io/sdr-enthusiasts/docker-tar1090:telegraf-build-1498@sha256:b3daf344c8ddd39a54d3e0776b9e10e82f37814bdf05d055c2919e077439de42";

      # Shared verbatim: sdrhub + fredvps.
      acarsRouter = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-597@sha256:eccd7018caa4ee727918ec00db79a46072701e729fe09757a529814a9d41135b";

      acarshub = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1519@sha256:5f9991bbae642524280b87847846407855d6bc8c42a77f084258cec543ed244c";

      # hfdlhub1 host
      dumphfdl = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-209@sha256:0b25e9772e1892e2a04c4e4015ac5bca8f7127ef174f26af89f734240201db83";

      # hfdlhub2 host
      hfdlobserver = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-36@sha256:f5b3c17853f3b0519b402b6dbd2231a577f06d6bab42176fecfafa5b81d8e1d4";

      # vdlmhub host
      dumpvdl2 = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-441@sha256:f1af3f5647870c3bb615bf2f1d23d60c5cd2bbf6193d5c0570eb3ec0419bb04b";

      # sdrhub host
      airspyAdsb = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-324@sha256:d515d0fac58d0e7fe80480f7601c9417bfce74116b2fa75d639cc53f6441aac6"; # inactive (commented-out container)

      adsbUltrafeeder = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf-build-981@sha256:c27203e4f1ebd60aa32a34681ca9b593d81583b8d0fc1d3f534fb8a2ab7ecb32";

      dump978 = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-810@sha256:70a8ac5c8bf3639716d1ccd658f83ed9ceac23a6ca66091d569f9aaf19a0174b";

      adsbhub = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-539@sha256:957473849b0f775982fc2d84ffbffc57b10c6b9208932d66ebf50e6d19a78ab5";

      flightradar24 = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-868@sha256:fe5e559677e61f9aed1c261fcb7a11d6a656d79c9eda7bbd5fd1ecb2c64a60c0";

      piaware = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-674@sha256:733bfa6b15d4769049e0b727f8b0a2cba2bcb09719940406b7e2e5ebd0bc70ad";

      planefinder = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-550@sha256:f8bbe6ab30e8a8387b4fb6ed0a840236d317bec17b57eda49de5e23589f7476e";

      planewatch = "ghcr.io/plane-watch/docker-plane-watch:v0.0.11@sha256:e0f0f5e55847273bae1b9b1c6a8962e74065f38659bd180e97d7da9d0a2865c3";

      radarvirtuel = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-811@sha256:d0d721e141c5d978c3e1c0b51cf004e7bfba7d38373ca1022bbc8d1c604d63e3";

      airnavradar = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-893@sha256:a3d78b6750620dd8cc320faa4f855f15cd8d44985752942359df341e0e6b4c22";

      openskyNetwork = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-854@sha256:a6f620496968e762ae2e6f0f97a872b826ceb88a22f6bab2542fe0a75809251c";

      sdrmap = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-109@sha256:9e1fd2b2bddc195e389c9c65c3bd3d985d4e458fd4721abe8b22ea6c36c54570";

      acarshubV4 = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-74@sha256:86026a603bc65c551e3d01aa08e2ca098dfc38c94cb2b8b77e420188da90ae72";

      acars2posAlt = "ghcr.io/rpatel3001/docker-acars2pos:latest-build-32@sha256:79eef9eaaa123f79a350e466452d577e71a6f11cedebad59ff91ebf97a6b6ea8"; # inactive (commented-out alternative)

      acars2pos = "ghcr.io/fredclausen/docker-acars2pos:latest-build-6@sha256:69ef9c559d6e7f31ac740ebfc41e661cbe75d72d5a7cc544e1bcc1a2939d0f4d";

      degoog = "ghcr.io/fccview/degoog:0.24.0@sha256:79409f76137734baa0516a58def96e4d3842f6db26d813e75365dea8a00974e9";

      syncclipboard = "jericx/syncclipboard-server:v3.3.3@sha256:4fe1486f176679e18fbcd2d220d19d21c4d19ce76ef63d92c4a00e28e9314eca";
    };
    description = "Every container image this fleet runs, keyed by logical name. See the module header for why every image is here, not just the ones shared across hosts.";
  };
}
