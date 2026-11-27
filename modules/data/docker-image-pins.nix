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
      xng = "ghcr.io/sdr-enthusiasts/docker-xng:latest-build-27@sha256:bd4be8a8c151b88e2950a5abaed8eec7395368530c0acd6c9e88a29a340b52be";

      # fredvps host
      fredSite = "ghcr.io/fredsystems/fred-site:latest-build-8@sha256:53659b897364c139dc504e6824ae999febdfe96616fbf306b8681a493510ed81";

      sdreImageApi = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-7@sha256:38df445fe37101648032e849a477ee3221ce8517cebd72983e21d9e1ba8dfbff";

      tar1090 = "ghcr.io/sdr-enthusiasts/docker-tar1090:telegraf-build-1513@sha256:17744c2e8cf240e3db24d37c0e96e8831781a0cccfc2d02bbeff734ab11c9872";

      # Shared verbatim: adsbhub + fredvps.
      acarsRouter = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-604@sha256:13f2f985cfd1329cecc28c05d21edee792035bd87229575b27bd42b86e825fc9";

      acarshub = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1530@sha256:3031ad3918b4a69e03c59fca3e6941e4533f851ca94d3105b4475c626db7e268";

      # hfdlhub1 host
      dumphfdl = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-216@sha256:20b68f8eca03925774fb06d8d7a6a3e559c4186031211bc1accee7b8c296550d";

      # hfdlhub2 host
      hfdlobserver = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-44@sha256:c5a7d441697a0959e13a4767ecaafdbf22e7f2c8f710c7454c35469a09d41236";

      # adsbhub host
      airspyAdsb = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-331@sha256:7f94a4c1ab46ae763779d37430b0ce1ab7eeaa8e00a6c969e8505ba7d1a0376b";

      adsbUltrafeeder = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf-build-996@sha256:00f4d79e8eeada4605eeb82ac1bd68536960a30dc1da562bfd84b13cadfa4858";

      dump978 = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-817@sha256:a8c3b95eba0f9a203ed6a2bd734c185be2b12b4574e3bd9e55dc48d1cc0fa9b3";

      adsbhub = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-546@sha256:2a12260c9288755bbdcdd7398466dc95b7cd22400fdaa580fd534aaa7b0c08fb";

      flightradar24 = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-875@sha256:3a3a69d9c638cbf92b1c6bb48c3a520eb1107bdd1a454ae07196695a3d63885a";

      piaware = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-681@sha256:8c4ed8341213f5b55a6b447788292af1ef4a908c863dba43fa7dcaf35c148096";

      planefinder = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-558@sha256:20f48bac1de5d3599fe67d9a035173ad23c8eb88d051f6e9f2551fbcae0699c2";

      planewatch = "ghcr.io/plane-watch/docker-plane-watch:v0.0.11@sha256:0033f1c9aa10f291a40eae0fc03f4f6cf18f86595eebacdd68956944b36c93ca";

      radarvirtuel = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-819@sha256:e617d1e68965cf4560b3e10b90704662829d92f41a0c798e4d1d80699d747368";

      airnavradar = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-902@sha256:10e233e8899a7aabf1f4bbef21a40da21bc5eab98ca3364f17c7e37500c28128";

      openskyNetwork = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-861@sha256:0314cd4d73d394ae9d54335b77a753fc088cb33dc01c3de529bdfb64c2288523";

      sdrmap = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-117@sha256:26a8da145fb8747ea1939d398dee2a70428fc5c98aed050800fff3326ec2aeae";

      acarshubV4 = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-79@sha256:6b0d2ad292ff6a1a8966584f536fc5afc5c760591e799651681bcdd755554fec";

      acars2posAlt = "ghcr.io/rpatel3001/docker-acars2pos:latest-build-32@sha256:79eef9eaaa123f79a350e466452d577e71a6f11cedebad59ff91ebf97a6b6ea8"; # inactive (commented-out alternative)

      acars2pos = "ghcr.io/fredclausen/docker-acars2pos:latest-build-10@sha256:88f0576e859a53f600e03d718d1cb31717a299ca8265c56c363d0ec5725a50a0";

      degoog = "ghcr.io/fccview/degoog:0.24.0@sha256:79409f76137734baa0516a58def96e4d3842f6db26d813e75365dea8a00974e9";

      syncclipboard = "jericx/syncclipboard-server:v3.3.4@sha256:c0d0ec4ad362d2d9f5f6e9c403c902a7bf6abd45bb6aec9b8d3fbf9e5be06a08";
    };
    description = "Every container image this fleet runs, keyed by logical name. See the module header for why every image is here, not just the ones shared across hosts.";
  };
}
