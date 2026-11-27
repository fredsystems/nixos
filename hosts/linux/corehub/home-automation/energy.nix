# The Sense energy monitor (owner, 2026-11-27). Sense is cloud-only: Home
# Assistant polls the Sense account, not the monitor on the LAN. The
# reconciler creates the entry from the account's email and password, both
# in sops so the address stays out of this repository too. The account has no
# two-factor authentication; if it gains it, the flow's `validation` step
# asks for a code and the reconciler fails the run saying so.
#
# Sense keeps learning devices, each with seven entities (on/off, power, and
# energy per day, week, month, year and billing cycle), so the trimming is by
# unique-ID pattern rather than per device (owner, 2026-11-27): each device
# keeps on/off and power; the monitor keeps live power, voltages, and the
# daily and monthly figures. A few obvious devices are placed in areas; the
# rest stay unplaced, since Sense merges and splits its detections over time.
{ config, lib, ... }:
let
  reconciler = [ "home-assistant-reconciler.service" ];

  # The Sense monitor's ID, the prefix of its devices' identifiers.
  monitor = "6241";

  # Detected device ID -> area. A device Sense later drops is skipped with a
  # warning.
  placed = {
    Kitchen = [
      "78f7216c" # Fridge
      "f94b2d6b" # Fridge 2
      "7222c749" # Dishwasher
      "629fa461" # Dishwasher 2
      "d66efe75" # Dishwasher
      "00da29fa" # Microwave
      "780d5ac7" # Microwave 3
      "0a1e90ab" # Coffeemaker
      "2671e792" # Coffee Maker 2
      "f6052cb3" # Coffee Maker
      "aeb992ce" # Disposal
      "70e1076c" # Disposal 2
      "e217f76f" # Disposal 3
    ];
    "Laundry Room" = [ "4f6323a7" ]; # Dryer
    Garage = [
      "9b11e7df" # Garage Door
      "89eea1a8" # Garage Door 2
    ];
  };
in
{
  services.home-assistant.extraComponents = [ "sense" ];

  services.home-assistant-reconciler = {
    secrets = {
      sense-email = config.sops.secrets."home-assistant/sense/email".path;
      sense-password = config.sops.secrets."home-assistant/sense/password".path;
    };

    integrations.sense.steps.user = {
      email._secret = "sense-email";
      password._secret = "sense-password";
    };

    disableEntities = [
      # Each detected device's energy totals: <monitor>-<device>-<period>-energy.
      {
        platform = "sense";
        uniqueId = "[0-9]+-[^-]+-(daily|weekly|monthly|yearly|bill)-energy";
      }
      # The monitor's weekly, yearly and billing-cycle figures.
      {
        platform = "sense";
        uniqueId = "[0-9]+-(weekly|yearly|bill)-.+";
      }
    ];

    devices = lib.concatLists (
      lib.mapAttrsToList (
        area:
        map (device: {
          identifier = [
            "sense"
            "${monitor}:${device}"
          ];
          inherit area;
        })
      ) placed
    );
  };

  sops.secrets = {
    "home-assistant/sense/email".restartUnits = reconciler;
    "home-assistant/sense/password".restartUnits = reconciler;
  };
}
