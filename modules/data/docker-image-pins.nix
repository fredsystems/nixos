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
  # `acars2posAlt` is pinned here even though sdrhub's container block that
  # would use it is currently commented out (alternate configuration) --
  # kept so Renovate still tracks it and the pin is ready if re-enabled.
  options.shared.dockerImages = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {
      # Shared by every host that imports profiles/adsb-hub.nix or
      # modules/services/adsb-docker-units.nix directly (sdrhub), via
      # modules/services/mk-dozzle-agent.nix.
      dozzle = "amir20/dozzle:v11.4.1@sha256:915a5acf91b01bb4d11de1fde7e30d55646211240269e4404c03a6f71c5fc91e";

      # acarshub + vdlmhub hosts
      xng = "ghcr.io/sdr-enthusiasts/docker-xng:latest-build-17@sha256:18070288a1f58d7fb13045263e6f35fa9b4cc22dd30f946393225e426e975009";

      # fredvps host
      fredSite = "ghcr.io/fredsystems/fred-site:latest-build-8@sha256:53659b897364c139dc504e6824ae999febdfe96616fbf306b8681a493510ed81";

      sdreImageApi = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-7@sha256:38df445fe37101648032e849a477ee3221ce8517cebd72983e21d9e1ba8dfbff";

      tar1090 = "ghcr.io/sdr-enthusiasts/docker-tar1090:telegraf-build-1504@sha256:1ab0d7bfeacd2ac9a941554c3c8d62a572f501da8534f396a521f45c7ae9ba78";

      # Shared verbatim: sdrhub + fredvps.
      acarsRouter = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-601@sha256:1be30953c8c94f4b1ba8724a722fe54d2595605b9b5a525263f2d1d214527b75";

      acarshub = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1524@sha256:75ac513898aa0e8a3344c22659af10effdb79718cc47bb7b95129d747147347a";

      # hfdlhub1 host
      dumphfdl = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-213@sha256:647d8f3407b033bc92f3b0c68296f37a27219d82d4f682d9bf2f3dcefccad10e";

      # hfdlhub2 host
      hfdlobserver = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-40@sha256:3ca292faecb0bdce797ed4d114c25f770b3f8a905a46b5dbb3ab49de35727539";

      # sdrhub host
      airspyAdsb = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-328@sha256:a5886ef2e60ac0c81072e3f831dca4d97ab92da6e42c1bbeb95fe73be920e030";

      adsbUltrafeeder = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf-build-987@sha256:91bafaafade95eff6df786a3febd401e0ad3d32fccd6706cde7ac16f76355de0";

      dump978 = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-814@sha256:d31f51df6e35fcc47731f60ba94225e82f0570493d21a59ad93c9d84de489547";

      adsbhub = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-543@sha256:4dedb24675f8751ac6fe92be42f7a5808d9eba3a673cce27191912b4dc161630";

      flightradar24 = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-872@sha256:f4b45826c89d85a05078cd5111152c3824e62c281a372d89aaf866d105d86bca";

      piaware = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-678@sha256:414d4fe9b27f060003763d50c57ede1c887a7bc81c2c5b726ddb7149687b7f56";

      planefinder = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-555@sha256:c33bf5984fbedd936b00772fcf6a062d0666191dc2ea19918ccdc385fd72d328";

      planewatch = "ghcr.io/plane-watch/docker-plane-watch:v0.0.11@sha256:712b4cb7045ffb6b7b904981f287855264d8526becdc644b9bb2bd00bf25c658";

      radarvirtuel = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-816@sha256:c9651d298d3b81bf7567edaea7e41ace8458ae04091a7eedb390c4379fd029f5";

      airnavradar = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-899@sha256:8e10ead7d3a05ee6145b3e0fdb4f47b8964e53cbae9c8c1f97777ed3aefbd856";

      openskyNetwork = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-858@sha256:1b6f5e1d9cdce6322cae0dfea071e7cdb1014bc6f81c7f01f6276c5c5c4b0d37";

      sdrmap = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-114@sha256:a96dd788c078ef84d6f79d270acd5ea8eedb92e776e6e2421159153ff34e546c";

      acarshubV4 = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-75@sha256:032a37be45b61a800abd1210af594bf0591631fef4a0b70897f659b1082c58d5";

      acars2posAlt = "ghcr.io/rpatel3001/docker-acars2pos:latest-build-32@sha256:79eef9eaaa123f79a350e466452d577e71a6f11cedebad59ff91ebf97a6b6ea8"; # inactive (commented-out alternative)

      acars2pos = "ghcr.io/fredclausen/docker-acars2pos:latest-build-8@sha256:c589af2ffdb20ff4d4aa373540bcd2847ef97a0191049b1142fc7bbfe82ba837";

      degoog = "ghcr.io/fccview/degoog:0.24.0@sha256:79409f76137734baa0516a58def96e4d3842f6db26d813e75365dea8a00974e9";

      syncclipboard = "jericx/syncclipboard-server:v3.3.3@sha256:4fe1486f176679e18fbcd2d220d19d21c4d19ce76ef63d92c4a00e28e9314eca";
    };
    description = "Every container image this fleet runs, keyed by logical name. See the module header for why every image is here, not just the ones shared across hosts.";
  };
}
