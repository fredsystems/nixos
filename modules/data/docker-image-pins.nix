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
      dozzle = "amir20/dozzle:v11.3.4@sha256:8796ae7e1ecbe011482319cb7040e69aae91a0632b87bbe24b3f643e7455d94b";

      # acarshub host
      acarsdec = "ghcr.io/sdr-enthusiasts/docker-acarsdec:latest-build-508@sha256:724bcdb55104f9662a5788c66d123b90ffbe0627c7d2f57af59c7c2b09bfcf54";
      xng = "ghcr.io/sdr-enthusiasts/docker-xng:latest-build-6@sha256:705505766deabd50c5ff3510fe2c3433aa6d743d14fb855395777f75245fe2e1";

      # fredvps host
      fredSite = "ghcr.io/fredsystems/fred-site:latest-build-8@sha256:53659b897364c139dc504e6824ae999febdfe96616fbf306b8681a493510ed81";
      sdreImageApi = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-7@sha256:38df445fe37101648032e849a477ee3221ce8517cebd72983e21d9e1ba8dfbff";
      tar1090 = "ghcr.io/sdr-enthusiasts/docker-tar1090:telegraf-build-1492@sha256:817067f464d3c1f8b25c8d8c7bc2c84b2cd8eb76ea791a74b59c95610d04c36a";

      # Shared verbatim: sdrhub + fredvps.
      acarsRouter = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-591@sha256:9763e7c8d54a2bc258c1fa3d7dae6f4821502f6d7fbca82301adc15ad7e83425";
      acarshub = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1513@sha256:522c7064779d35431abb10bffed523a040449f3c3a992db438050a5852cdc3ae";

      # hfdlhub1 host
      dumphfdl = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-205@sha256:ccb50b509dd2e7b935cc4978c0f950177c2a5881e3901ebc7f4e7586226b8eb3";

      # hfdlhub2 host
      hfdlobserver = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-32@sha256:b23ecb022918c9a095b675cf1135a84b09b5d8faa3f2346949b7778bf1910236";

      # vdlmhub host
      dumpvdl2 = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-435@sha256:f0be947f3134a34337bac782d45f7c7c1fc551e2d3a4565e5b548cf9d0dcc6f5";

      # sdrhub host
      airspyAdsb = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-318@sha256:04d3abf7ccf284972c3a8b20d84aea0c357a414a9f7c1db7b2dabfb60650f353"; # inactive (commented-out container)
      adsbUltrafeeder = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf-build-975@sha256:1937a273d481760f2604d331c794a8553d4b5e211e5aa239ab8027f5efc9602d";
      dump978 = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-805@sha256:0e29f96fb26f61a22b04773870187bb2913d5c11d9fdcb9a43eaf8ac9f67c49e";
      adsbhub = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-533@sha256:6fdf14faf7512358530a22de85326ac4a3b044d1448c226f82b6f39e6549fedd";
      flightradar24 = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-863@sha256:1de9e501bdf48a863652c165681313d8463312e28a1ae5f6c83c5b4f684119d5";
      piaware = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-670@sha256:576da5db3f82a9153c64b1aff856a1e3da9040a8d9999e0c19e4b4f3362bfebe";
      planefinder = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-545@sha256:7abd0bf5583c71185093d6ff1dbe2fa000104c72ec651270f829519bc9867f5a";
      planewatch = "ghcr.io/plane-watch/docker-plane-watch:v0.0.11@sha256:24562527ff8ecd1b99f439646596bb9d4e2ee575d8dc09cafb663180767695d6";
      radarvirtuel = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-805@sha256:4d69f3b943f29c4695365d399936aa2b9552cc850d5ed6801e49ab876b32ccf3";
      airnavradar = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-888@sha256:427762e746037063874b26d453fdb584ccd42480d7186fe6b7b1df837be7be78";
      openskyNetwork = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-849@sha256:1b596f102a8d346a119de124c0fac95240f698cab021f88e0d4113d673f76ae4";
      sdrmap = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-103@sha256:c09de2e1877277d2dcba6d8b15cfd682828f7d667c21436fba5bab42e4724f2d";
      acarshubV4 = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-72@sha256:44e2e8f29e456dcc3d9316dab2b8169c6b5f4b46885eb307673790d970908e5b";
      acars2posAlt = "ghcr.io/rpatel3001/docker-acars2pos:latest-build-32@sha256:79eef9eaaa123f79a350e466452d577e71a6f11cedebad59ff91ebf97a6b6ea8"; # inactive (commented-out alternative)
      acars2pos = "ghcr.io/fredclausen/docker-acars2pos:latest-build-5@sha256:9b6570472effae546f835e7be28a94c9d582673eb792f33d2b49e900282095d9";
      degoog = "ghcr.io/fccview/degoog:0.24.0@sha256:79409f76137734baa0516a58def96e4d3842f6db26d813e75365dea8a00974e9";
      syncclipboard = "jericx/syncclipboard-server:v3.3.3@sha256:4fe1486f176679e18fbcd2d220d19d21c4d19ce76ef63d92c4a00e28e9314eca";
    };
    description = "Every container image this fleet runs, keyed by logical name. See the module header for why every image is here, not just the ones shared across hosts.";
  };
}
