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
      dozzle = "amir20/dozzle:v10.7.4@sha256:068025ea622a1ce3e343a138dd9a962429b5187a133aca301bb4991fe7d2b708";

      # acarshub host
      acarsdec = "ghcr.io/sdr-enthusiasts/docker-acarsdec:latest-build-503@sha256:8a8924422d9c34ce3422859bb12b4e8bb33850b1cf4bb02edcc20a4601c43d6a";
      xng = "ghcr.io/sdr-enthusiasts/docker-xng:latest-build-4@sha256:670282c3d1d519bbcc3de03a2b22ba25242267980725da49f0ead8978f2fe2c8";

      # fredvps host
      fredSite = "ghcr.io/fredsystems/fred-site:latest-build-8@sha256:53659b897364c139dc504e6824ae999febdfe96616fbf306b8681a493510ed81";
      sdreImageApi = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-7@sha256:38df445fe37101648032e849a477ee3221ce8517cebd72983e21d9e1ba8dfbff";
      tar1090 = "ghcr.io/sdr-enthusiasts/docker-tar1090:telegraf-build-1474@sha256:26a2dae067d9cc5a9738f3370c2323cc397baf3823cf48523a176399b3894dc2";

      # Shared verbatim: sdrhub + fredvps.
      acarsRouter = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-588@sha256:0dc5e94dfa00a0d1f0d5c323a0e3e7cdbbfe9a4cc7de750114d7c887ea575cc5";
      acarshub = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1510@sha256:1938777a30eeb7fd5261b333cc9347b42c95e1b92baa6d871da7281a01696978";

      # hfdlhub1 host
      dumphfdl = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-202@sha256:4fdde386269d69b36e134b4a6d04e5085d1c9289996caacccad25f21e5b930b4";

      # hfdlhub2 host
      hfdlobserver = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-29@sha256:05b109c671c1664eb98400b3364cad9dbe2a864965df77b92b8e55cba47ec6e4";

      # vdlmhub host
      dumpvdl2 = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-432@sha256:514d599b75b45973aa4d28c044ff8609add9f8b0707cd3a47a9a23e2b96264b9";

      # sdrhub host
      airspyAdsb = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-316@sha256:a2f8a4a9d9d4f8899ff79b9ec80863c467b57fb70e88892c78fc47df1e323f9e"; # inactive (commented-out container)
      adsbUltrafeeder = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf-build-956@sha256:8b5b2c069c37273b4cd263da0857a1c11491c13d31e018434d91344c1717622b";
      dump978 = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-803@sha256:5034be7616afced79c9d46a8715073d14c7a4e745068a7c02999c23cda0f719b";
      adsbhub = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-531@sha256:6825ec77b86e13804fa5bbb98891ce787dfc121b57f0d4ffd4d38a98a0ae798d";
      flightradar24 = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-860@sha256:917e53402d5158800eef746839dfb722e30cd3b21019e3bc318abb4f3d807c03";
      piaware = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-667@sha256:086f48dfbb31d7551e40c0d3d57a6b4727eb54aa184e5c438ca57151740e299c";
      planefinder = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-542@sha256:56e493fe119812977385ec7ed0942de10acf8e5555f3078a00fe5f6eca2835cb";
      planewatch = "ghcr.io/plane-watch/docker-plane-watch:v0.0.10@sha256:f8cc3254943c3f0cd8b97d448bee929c87f3c78b9ecf1a61a255343797e61745";
      radarvirtuel = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-801@sha256:e45bc0dc644f5ab39fbf36e9b5fa40dd7e64fcbc75b553f04acdf38e9a3f5a4a";
      airnavradar = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-884@sha256:cfe95cf01250061f105d4665b2c410a3b079afb400f847cd49797d8f4707e636";
      openskyNetwork = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-847@sha256:434a94a02d6d6713dec6231fe1d3f08f1f007defa86e09f0a0cade644b485ca2";
      sdrmap = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-100@sha256:ef3d4c1f9d84ba9fe3ffe85d407235a89ed7a5ef00aeba910c22cc00cbf0d44e";
      acarshubV4 = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-72@sha256:44e2e8f29e456dcc3d9316dab2b8169c6b5f4b46885eb307673790d970908e5b";
      acars2posAlt = "ghcr.io/rpatel3001/docker-acars2pos:latest-build-31@sha256:229f6ee8a65a25989aacf62e2f93b30dff86066a9684396e599a95ccb049b834"; # inactive (commented-out alternative)
      acars2pos = "ghcr.io/fredclausen/docker-acars2pos:latest-build-2@sha256:44f0ed37ddc9f4fac092d905088d7b0b25e364b1453929125e76322e54b2bad2";
      degoog = "ghcr.io/fccview/degoog:0.24.0@sha256:79409f76137734baa0516a58def96e4d3842f6db26d813e75365dea8a00974e9";
      syncclipboard = "jericx/syncclipboard-server:v3.2.0@sha256:3f2d9c6ce4fbefca769e40d79ed2cac2ad8fc3adf962c0599ba9176b502a3b6d";
    };
    description = "Every container image this fleet runs, keyed by logical name. See the module header for why every image is here, not just the ones shared across hosts.";
  };
}
