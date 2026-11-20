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
  # Some images (acarshub, acarsRouter, xng) are genuinely shared verbatim
  # across hosts, and another repeats multiple times within one host's own
  # file (dumphfdl x3 in hfdlhub1) -- both are the same underlying risk: nothing stops the copies from drifting apart on a manual edit.
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
  # `acars2posAlt` is pinned here even though adsbhub's container block that
  # would use it is currently commented out (alternate configuration) --
  # kept so Renovate still tracks it and the pin is ready if re-enabled.
  options.shared.dockerImages = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {
      # Shared by every host that imports profiles/adsb-hub.nix or
      # modules/services/adsb-docker-units.nix directly (adsbhub), via
      # modules/services/mk-dozzle-agent.nix.
      dozzle = "amir20/dozzle:v11.5.0@sha256:74600d62dd73a72a5d36fbd0c98af649203df921d74310b7ed383ef63392358e";

      # acarshub + vdlmhub hosts
      xng = "ghcr.io/sdr-enthusiasts/docker-xng:latest-build-17@sha256:18070288a1f58d7fb13045263e6f35fa9b4cc22dd30f946393225e426e975009";

      # fredvps host
      fredSite = "ghcr.io/fredsystems/fred-site:latest-build-8@sha256:53659b897364c139dc504e6824ae999febdfe96616fbf306b8681a493510ed81";

      sdreImageApi = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-7@sha256:38df445fe37101648032e849a477ee3221ce8517cebd72983e21d9e1ba8dfbff";

      tar1090 = "ghcr.io/sdr-enthusiasts/docker-tar1090:telegraf-build-1511@sha256:3d4e7817dd9f7b7cedbef76799b1d1f8498bf674a34016d3bd9b638072d49d14";

      # Shared verbatim: adsbhub + fredvps.
      acarsRouter = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-603@sha256:13fd9e042a1283a8d69930aae192f9c47cbb5b17ae35fafa159008684608eaad";

      acarshub = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1528@sha256:0d9b5603b297a944c440bf1708341086bd0cbc2afb6b1e6ef86f3803cf31338e";

      # hfdlhub1 host
      dumphfdl = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-215@sha256:296e9009ca607a32c9f13a30d249f4038dac12ff469de38f4991eaa0a4ee5f50";

      # hfdlhub2 host
      hfdlobserver = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-43@sha256:bd6e6a3745a1f5f076ab68569c8322261a04b897bdd9ff8acdaf93532e674f52";

      # adsbhub host
      airspyAdsb = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-330@sha256:0ab916d9ecc72dd39d8e485ea52061185318bc7063179a91b5b1860e4076b17c";

      adsbUltrafeeder = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf-build-993@sha256:fe533789edc118852c989d461a0767f29a67a85141877b34c92af86d861cb0a6";

      dump978 = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-816@sha256:513433b187a3977b224b34aed3972909c9ca7f9c76a422e2f050e980ebab4caf";

      adsbhub = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-545@sha256:5047ceef3997e47f4f7d1963015945b23c2eef8f18323a4a87a3a3ed84f0cee9";

      flightradar24 = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-874@sha256:769a1436fb5137b321c7e69e29f7b7018c4b6db4acbf5d1b64478bd51ad38045";

      piaware = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-678@sha256:414d4fe9b27f060003763d50c57ede1c887a7bc81c2c5b726ddb7149687b7f56";

      planefinder = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-557@sha256:fe23e3c44d20ec4f855c0ba086f8ff981b6c550db6f32aa8c87f19325a13ea62";

      planewatch = "ghcr.io/plane-watch/docker-plane-watch:v0.0.11@sha256:0033f1c9aa10f291a40eae0fc03f4f6cf18f86595eebacdd68956944b36c93ca";

      radarvirtuel = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-818@sha256:8a33a79439a58ab14b0ef0fa58933da68577a5f4fddf6b40150771df5bedc551";

      airnavradar = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-901@sha256:0ba1cbe2283b57b738dacf8b9c1a5a6cdda8f5ab3bb3efd74aeacc80e6d9f218";

      openskyNetwork = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-858@sha256:1b6f5e1d9cdce6322cae0dfea071e7cdb1014bc6f81c7f01f6276c5c5c4b0d37";

      sdrmap = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-116@sha256:4e362457173e9416ee98068aafacc9c90f23d0a6400df9f6d494a7085d187d4d";

      acarshubV4 = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-76@sha256:653df4e48c3cb65f60c7185ffd16c1b5cc62f8a9d0e9e57e98f1f30e05b4209b";

      acars2posAlt = "ghcr.io/rpatel3001/docker-acars2pos:latest-build-32@sha256:79eef9eaaa123f79a350e466452d577e71a6f11cedebad59ff91ebf97a6b6ea8"; # inactive (commented-out alternative)

      acars2pos = "ghcr.io/fredclausen/docker-acars2pos:latest-build-9@sha256:04279ffa2186e55c4cf0403612ea0d15f82cdce929b0eee3179570ea3fc4eae1";

      degoog = "ghcr.io/fccview/degoog:0.24.0@sha256:79409f76137734baa0516a58def96e4d3842f6db26d813e75365dea8a00974e9";

      syncclipboard = "jericx/syncclipboard-server:v3.3.3@sha256:4fe1486f176679e18fbcd2d220d19d21c4d19ce76ef63d92c4a00e28e9314eca";
    };
    description = "Every container image this fleet runs, keyed by logical name. See the module header for why every image is here, not just the ones shared across hosts.";
  };
}
