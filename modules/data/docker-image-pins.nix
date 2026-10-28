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
      acarsdec = "ghcr.io/sdr-enthusiasts/docker-acarsdec:latest-build-512@sha256:cc59235b825650c033cf1893e3fbd2ff16f5a2bcb69665bfc2e1f24ab2a1f92a";

      xng = "ghcr.io/sdr-enthusiasts/docker-xng:latest-build-9@sha256:e90f6550aba47bb502373f39c6a54b3e31550778c5e002a3871e83d41ff7ff68";

      # fredvps host
      fredSite = "ghcr.io/fredsystems/fred-site:latest-build-8@sha256:53659b897364c139dc504e6824ae999febdfe96616fbf306b8681a493510ed81";

      sdreImageApi = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-7@sha256:38df445fe37101648032e849a477ee3221ce8517cebd72983e21d9e1ba8dfbff";

      tar1090 = "ghcr.io/sdr-enthusiasts/docker-tar1090:telegraf-build-1498@sha256:b3daf344c8ddd39a54d3e0776b9e10e82f37814bdf05d055c2919e077439de42";

      # Shared verbatim: sdrhub + fredvps.
      acarsRouter = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-596@sha256:25f50a6868b689f68f972c947de0a745b000a2eb02e30ef23e210413d44655b5";

      acarshub = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1513@sha256:522c7064779d35431abb10bffed523a040449f3c3a992db438050a5852cdc3ae";

      # hfdlhub1 host
      dumphfdl = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-205@sha256:ccb50b509dd2e7b935cc4978c0f950177c2a5881e3901ebc7f4e7586226b8eb3";

      # hfdlhub2 host
      hfdlobserver = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-32@sha256:b23ecb022918c9a095b675cf1135a84b09b5d8faa3f2346949b7778bf1910236";

      # vdlmhub host
      dumpvdl2 = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-439@sha256:e7318855491261dca5b9e891ebfa0681fc51f6de00a2b4bc3342a3513bc0fbb1";

      # sdrhub host
      airspyAdsb = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-324@sha256:d515d0fac58d0e7fe80480f7601c9417bfce74116b2fa75d639cc53f6441aac6"; # inactive (commented-out container)

      adsbUltrafeeder = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf-build-979@sha256:ecd3eeca1c327c34f5b0e4de8d1d6f88d50f5ba6b6ebf791e38c6baa5d1a3a6a";

      dump978 = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-806@sha256:1af94d0ec7b225b8dcf2e3dda48e783c117551d794d1571bef2af8f3680ccfae";

      adsbhub = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-534@sha256:fbfefa7b344b0468d269acdc79d58bda7f1803058fe5928b167114a9760acf59";

      flightradar24 = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-868@sha256:fe5e559677e61f9aed1c261fcb7a11d6a656d79c9eda7bbd5fd1ecb2c64a60c0";

      piaware = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-671@sha256:97293c1cb5dbbdb4ccc6d56e163c1677ff0662e7e0c43c71af315d7340603fb6";

      planefinder = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-545@sha256:7abd0bf5583c71185093d6ff1dbe2fa000104c72ec651270f829519bc9867f5a";

      planewatch = "ghcr.io/plane-watch/docker-plane-watch:v0.0.11@sha256:e0f0f5e55847273bae1b9b1c6a8962e74065f38659bd180e97d7da9d0a2865c3";

      radarvirtuel = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-811@sha256:d0d721e141c5d978c3e1c0b51cf004e7bfba7d38373ca1022bbc8d1c604d63e3";

      airnavradar = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-891@sha256:bee09f36dc5ce3ddcf963ca5a60437b425adcd59d66b408631cd79b812dfdd43";

      openskyNetwork = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-850@sha256:3411f0cb0f66e1da23f4bba60eb44d5bd83143acac070761771d0d4228e1bd52";

      sdrmap = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-107@sha256:f5533d4667b0d2c9e79b0efa04d22ef6ace2a63b4061884c562251ce318acfec";

      acarshubV4 = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-72@sha256:44e2e8f29e456dcc3d9316dab2b8169c6b5f4b46885eb307673790d970908e5b";

      acars2posAlt = "ghcr.io/rpatel3001/docker-acars2pos:latest-build-32@sha256:79eef9eaaa123f79a350e466452d577e71a6f11cedebad59ff91ebf97a6b6ea8"; # inactive (commented-out alternative)

      acars2pos = "ghcr.io/fredclausen/docker-acars2pos:latest-build-6@sha256:69ef9c559d6e7f31ac740ebfc41e661cbe75d72d5a7cc544e1bcc1a2939d0f4d";

      degoog = "ghcr.io/fccview/degoog:0.24.0@sha256:79409f76137734baa0516a58def96e4d3842f6db26d813e75365dea8a00974e9";

      syncclipboard = "jericx/syncclipboard-server:v3.3.3@sha256:4fe1486f176679e18fbcd2d220d19d21c4d19ce76ef63d92c4a00e28e9314eca";
    };
    description = "Every container image this fleet runs, keyed by logical name. See the module header for why every image is here, not just the ones shared across hosts.";
  };
}
