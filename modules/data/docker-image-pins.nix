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
  # across sdrhub and fredvps, and three more repeat multiple times
  # within one host's own file (dumpvdl2 x4 in vdlmhub, dumphfdl x3 in
  # hfdlhub1, acarsdec x2 in acarshub) -- both are the same underlying
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
      dozzle = "amir20/dozzle:v11.1.1@sha256:c90494cbc3a9ca959634b89fdb3fdecbcbae1f690d7a567d0d356c6fda1d957c";

      # acarshub host
      acarsdec = "ghcr.io/sdr-enthusiasts/docker-acarsdec:latest-build-504@sha256:115e8b7b660ac351ee70d662e375221e8f50bc2be172646c7ee15287b078e2db";
      xng = "ghcr.io/sdr-enthusiasts/docker-xng:latest-build-5@sha256:c0085e25245d6c6b0c9bfd1f55990a3c3e28dca1b71eab21ca7a3186bd9e8123";

      # fredvps host
      fredSite = "ghcr.io/fredsystems/fred-site:latest-build-8@sha256:53659b897364c139dc504e6824ae999febdfe96616fbf306b8681a493510ed81";
      sdreImageApi = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-7@sha256:38df445fe37101648032e849a477ee3221ce8517cebd72983e21d9e1ba8dfbff";
      tar1090 = "ghcr.io/sdr-enthusiasts/docker-tar1090:telegraf-build-1483@sha256:78d684af64b99d17b966579cf9ac5c23c36a29c8ee8aedcaba76665596dcb853";

      # Shared verbatim: sdrhub + fredvps.
      acarsRouter = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-589@sha256:3d1c6f8195dcf475fc82eeb51a6f63ef74152356dc1e68a0e9a5a65072e19177";
      acarshub = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1511@sha256:0f58f0945a27bcc1762cea6d6d9c11cb857b7f2508954c6714e640e7b9957eab";

      # hfdlhub1 host
      dumphfdl = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-203@sha256:f18dda05bc7de5a9468d1b0309ebf257db36e0e2ab0d362747c24e4536ad59a4";

      # hfdlhub2 host
      hfdlobserver = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-30@sha256:2c5454760cfe9bf177f73ecc952f1487cba9ef440b520efa7ceca9b41a199baa";

      # vdlmhub host
      dumpvdl2 = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-433@sha256:2b1b06fbdb502a795aa8e40ab30a498b2b3406f2f9cb62501a81876bb885375f";

      # sdrhub host
      airspyAdsb = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-317@sha256:cb0ad30350eaf923df69bef8837be5265c24c5db4c6b436afcf831874e828212"; # inactive (commented-out container)
      adsbUltrafeeder = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf-build-965@sha256:44f79ddf6496479a35eaad50d6b93c33e744e51cc5c9f28feffe9a74e6ae1374";
      dump978 = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-804@sha256:f85523fd921a322d46628f7fc98c8ba9d2019184d4ae5787e23e52175fe2eb50";
      adsbhub = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-532@sha256:e625e25199a036a98ab605cb51ea6318378e294365bb5843eac570530d30b07a";
      flightradar24 = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-861@sha256:3e0fbd0274eb9d10f5506cd8bcbff5714476ae39b571400153f9aab264017b34";
      piaware = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-668@sha256:8c51da8fba1a1035b4a06608a064d71b6678556f68e9b72020ca61d67586405d";
      planefinder = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-543@sha256:dbb310c42272d00ed7fc7e24f8347f576ac068ba061ae2c230354028664da197";
      planewatch = "ghcr.io/plane-watch/docker-plane-watch:v0.0.10@sha256:f8cc3254943c3f0cd8b97d448bee929c87f3c78b9ecf1a61a255343797e61745";
      radarvirtuel = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-803@sha256:092dac878390839d7e18095fc467101a9ba1b5c7ecd20e0f663737a373e2f80f";
      airnavradar = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-885@sha256:dbddec5be33c082f1e5be6cc2db9704fd38b3e7fd8b9823cca5cdb39973e7f9e";
      openskyNetwork = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-848@sha256:05b949ea8af0f1cd27195682cd680df1ea9420ce6e7f7f7cdeb33c057fa0e370";
      sdrmap = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-101@sha256:5b36751e73c9b6bdb3bba1ce888a3efafc92d5dca556e8630ea4ca3ce957fcee";
      acarshubV4 = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-72@sha256:44e2e8f29e456dcc3d9316dab2b8169c6b5f4b46885eb307673790d970908e5b";
      acars2posAlt = "ghcr.io/rpatel3001/docker-acars2pos:latest-build-31@sha256:229f6ee8a65a25989aacf62e2f93b30dff86066a9684396e599a95ccb049b834"; # inactive (commented-out alternative)
      acars2pos = "ghcr.io/fredclausen/docker-acars2pos:latest-build-3@sha256:320fc96ab5b1698f7ce881b0af2fe6efe2cdd9385f4bc508b5080574b934132d";
      degoog = "ghcr.io/fccview/degoog:0.24.0@sha256:79409f76137734baa0516a58def96e4d3842f6db26d813e75365dea8a00974e9";
      syncclipboard = "jericx/syncclipboard-server:v3.2.0@sha256:3f2d9c6ce4fbefca769e40d79ed2cac2ad8fc3adf962c0599ba9176b502a3b6d";
    };
    description = "Every container image this fleet runs, keyed by logical name. See the module header for why every image is here, not just the ones shared across hosts.";
  };
}
