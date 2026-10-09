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
      dozzle = "amir20/dozzle:v11.3.0@sha256:a7d69d20891d3dcc82636e24afa4c1c162b41d0673ef798b14f09e6b69accc5a";

      # acarshub host
      acarsdec = "ghcr.io/sdr-enthusiasts/docker-acarsdec:latest-build-505@sha256:c34494fa9c9a8df0ecea11a7235b5c336121bfbe7b78199c3ce44b8ce28b8665";
      xng = "ghcr.io/sdr-enthusiasts/docker-xng:latest-build-6@sha256:705505766deabd50c5ff3510fe2c3433aa6d743d14fb855395777f75245fe2e1";

      # fredvps host
      fredSite = "ghcr.io/fredsystems/fred-site:latest-build-8@sha256:53659b897364c139dc504e6824ae999febdfe96616fbf306b8681a493510ed81";
      sdreImageApi = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-7@sha256:38df445fe37101648032e849a477ee3221ce8517cebd72983e21d9e1ba8dfbff";
      tar1090 = "ghcr.io/sdr-enthusiasts/docker-tar1090:telegraf-build-1489@sha256:399dab378b2f958271d887e6f5b25db96166cad918f484894575e101d82e2f86";

      # Shared verbatim: sdrhub + fredvps.
      acarsRouter = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-590@sha256:2c74b49f3e08952e2658c0a4fc04c419309a2044c740931da5c7ffa60f7d381c";
      acarshub = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1512@sha256:149324fc79c2d9f5cc9f34ee6d40b7db6a8e24f35db576dd8418593c6ff09d29";

      # hfdlhub1 host
      dumphfdl = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-204@sha256:b97b055e274da8117f336d4a986c4dd5bb671717698e4fb25ccd1d2842591b68";

      # hfdlhub2 host
      hfdlobserver = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-31@sha256:f2b19bdb2b367212268da0ba60c1c0266fab4ee3de4007e76ba40f12b35aceed";

      # vdlmhub host
      dumpvdl2 = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-434@sha256:0767325c999331d62cc5d259c44ba872e1c24c4fa9417e2e04db3c6b3100f0bc";

      # sdrhub host
      airspyAdsb = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-318@sha256:04d3abf7ccf284972c3a8b20d84aea0c357a414a9f7c1db7b2dabfb60650f353"; # inactive (commented-out container)
      adsbUltrafeeder = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf-build-971@sha256:1df784a7e3756d0a6483b93c429ec9eea9a7281e2be6a329fc3431b712fa81c5";
      dump978 = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-805@sha256:0e29f96fb26f61a22b04773870187bb2913d5c11d9fdcb9a43eaf8ac9f67c49e";
      adsbhub = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-533@sha256:6fdf14faf7512358530a22de85326ac4a3b044d1448c226f82b6f39e6549fedd";
      flightradar24 = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-862@sha256:b0b6b96adaa35f1670c324dbed071f68c025690ccc01d52a040ea8a3e102fb72";
      piaware = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-670@sha256:576da5db3f82a9153c64b1aff856a1e3da9040a8d9999e0c19e4b4f3362bfebe";
      planefinder = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-544@sha256:f5b460366fbc54d083b965efcfb60437aec37c984224a39ee1256e3a72fb439b";
      planewatch = "ghcr.io/plane-watch/docker-plane-watch:v0.0.10@sha256:f8cc3254943c3f0cd8b97d448bee929c87f3c78b9ecf1a61a255343797e61745";
      radarvirtuel = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-805@sha256:4d69f3b943f29c4695365d399936aa2b9552cc850d5ed6801e49ab876b32ccf3";
      airnavradar = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-887@sha256:f81a338fb4491815895db4e9a7d44e8bb573b42b803418016ee611c1852c309b";
      openskyNetwork = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-849@sha256:1b596f102a8d346a119de124c0fac95240f698cab021f88e0d4113d673f76ae4";
      sdrmap = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-103@sha256:c09de2e1877277d2dcba6d8b15cfd682828f7d667c21436fba5bab42e4724f2d";
      acarshubV4 = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-72@sha256:44e2e8f29e456dcc3d9316dab2b8169c6b5f4b46885eb307673790d970908e5b";
      acars2posAlt = "ghcr.io/rpatel3001/docker-acars2pos:latest-build-32@sha256:79eef9eaaa123f79a350e466452d577e71a6f11cedebad59ff91ebf97a6b6ea8"; # inactive (commented-out alternative)
      acars2pos = "ghcr.io/fredclausen/docker-acars2pos:latest-build-5@sha256:9b6570472effae546f835e7be28a94c9d582673eb792f33d2b49e900282095d9";
      degoog = "ghcr.io/fccview/degoog:0.24.0@sha256:79409f76137734baa0516a58def96e4d3842f6db26d813e75365dea8a00974e9";
      syncclipboard = "jericx/syncclipboard-server:v3.3.1@sha256:0d5db11ddcb8d6d7f88c8419a73101ad29298f08114d5a1f75503a81a194e3e5";
    };
    description = "Every container image this fleet runs, keyed by logical name. See the module header for why every image is here, not just the ones shared across hosts.";
  };
}
