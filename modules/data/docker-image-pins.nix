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
      dozzle = "amir20/dozzle:v11.4.0@sha256:d23d23ce02c8cc96416dfbad4a7de225d01fdc03ad310203d64d580034dd120d";

      # acarshub host
      xng = "ghcr.io/sdr-enthusiasts/docker-xng:latest-build-14@sha256:1d76dcebe76400b71d72e7e4df557eb98c45342eb860a9611663c16f2f96b0d1";

      # fredvps host
      fredSite = "ghcr.io/fredsystems/fred-site:latest-build-8@sha256:53659b897364c139dc504e6824ae999febdfe96616fbf306b8681a493510ed81";

      sdreImageApi = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-7@sha256:38df445fe37101648032e849a477ee3221ce8517cebd72983e21d9e1ba8dfbff";

      tar1090 = "ghcr.io/sdr-enthusiasts/docker-tar1090:telegraf-build-1500@sha256:c6c051191a7cf98fb281789c1ac380df92a1f8914b61503849a9ef9b1f38ad1e";

      # Shared verbatim: sdrhub + fredvps.
      acarsRouter = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-599@sha256:446cfb845c59969fc83eae35b63847a112c46e314b6d51c18ae52131902181f8";

      acarshub = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1521@sha256:ff3ee2594f9164ce60c92f74d9b93a66a48a53db21f28c0a766fa4f89d676725";

      # hfdlhub1 host
      dumphfdl = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-211@sha256:104b627afbe6217f2b89a31259574f5886856e2ed976b635d6b64cabf205f798";

      # hfdlhub2 host
      hfdlobserver = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-38@sha256:18e7a1b7f942fb9bfd9862994cfe7b4341006095758eb32d5f2a2b1ebe61c8c3";

      # vdlmhub host
      dumpvdl2 = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-441@sha256:f1af3f5647870c3bb615bf2f1d23d60c5cd2bbf6193d5c0570eb3ec0419bb04b";

      # sdrhub host
      airspyAdsb = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-326@sha256:cd59e311d60732104318157b788ad06c2ade720b7c20ea031c92af4d8e39587d"; # inactive (commented-out container)

      adsbUltrafeeder = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf-build-983@sha256:7ae9de6f192d3746017a4347afaabe94b6d6a79bf356c913223fe3ac702d57ef";

      dump978 = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-812@sha256:a58b6f14486667d2621bd51df0898816d7871c6a19daf15a6d85f8ec3a8c1f93";

      adsbhub = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-541@sha256:33202b3c60c4fdeaa8e49ffd137e39c6d746e232d0079c9f1dc07711efc82d6d";

      flightradar24 = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-870@sha256:d1436b1f38650ddd9485be0343942026eb7837d552e587f4572065d9033f0f24";

      piaware = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-676@sha256:1d7f45f8cdf9834eb9f86d644f2cebb3df0494615dd76e71a61778decfe26909";

      planefinder = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-553@sha256:53f34fb5514e521cc4afd5c90f2c94a88680b88733ec3c79265e350872e6f24d";

      planewatch = "ghcr.io/plane-watch/docker-plane-watch:v0.0.11@sha256:e0f0f5e55847273bae1b9b1c6a8962e74065f38659bd180e97d7da9d0a2865c3";

      radarvirtuel = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-813@sha256:ca2278cf31a2938237245675f8443084f5953df8cd3d05ebde1ff8872963f5db";

      airnavradar = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-895@sha256:9698b2b2908ec119271487c599e04f8f78601a6c99271e828f6a5511c8a968ab";

      openskyNetwork = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-856@sha256:53d97972c9cd2590b4ec349d6eaf6900966d33d2ec86d3deeeb4f8a6ddd29288";

      sdrmap = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-111@sha256:e8cb9ada0ffaec1cc1696915f92052529c747b8ab8c86cbf57e322768ee80fb8";

      acarshubV4 = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-75@sha256:032a37be45b61a800abd1210af594bf0591631fef4a0b70897f659b1082c58d5";

      acars2posAlt = "ghcr.io/rpatel3001/docker-acars2pos:latest-build-32@sha256:79eef9eaaa123f79a350e466452d577e71a6f11cedebad59ff91ebf97a6b6ea8"; # inactive (commented-out alternative)

      acars2pos = "ghcr.io/fredclausen/docker-acars2pos:latest-build-7@sha256:b9c16c281b0c340908c4d17850c72ef51032b723a37639a343e1d9bcfcec57ec";

      degoog = "ghcr.io/fccview/degoog:0.24.0@sha256:79409f76137734baa0516a58def96e4d3842f6db26d813e75365dea8a00974e9";

      syncclipboard = "jericx/syncclipboard-server:v3.3.3@sha256:4fe1486f176679e18fbcd2d220d19d21c4d19ce76ef63d92c4a00e28e9314eca";
    };
    description = "Every container image this fleet runs, keyed by logical name. See the module header for why every image is here, not just the ones shared across hosts.";
  };
}
