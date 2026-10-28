{
  config,
  stateVersion,
  ...
}:
let
  inherit (import ../../../modules/services/mk-container-secret.nix)
    mkContainerSecrets
    ;

in
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/adsb-hub.nix
    ../../../modules/hardware/usbfs.nix
  ];

  networking.hostName = "acarshub";

  # This host has USB SDR hardware attached; raise the global usbfs
  # transfer-buffer ceiling above the 16 MB kernel default.
  hardware-profile.usbfs.enable = true;

  system.stateVersion = stateVersion;
  networking = {
    firewall = {
      allowedTCPPorts = [ 5555 ];
    };
  };

  sops.secrets = {
    "docker/acarshub.env" = mkContainerSecrets [
      "xng"
      "dozzle-agent"
    ];
  };

  services = {
    adsb.containers = [
      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      (import ../../../modules/services/mk-dozzle-agent.nix {
        image = config.shared.dockerImages.dozzle;
        environmentFiles = [
          config.sops.secrets."docker/acarshub.env".path
        ];
      })

      ###############################################################
      # XNG
      #
      # One station, one session per SDR. Session 1 uses the
      # unsuffixed XNG_* vars, session 2+ use _2, _3, ...; the
      # container refuses to start on a numbering gap. Outputs are
      # station-wide and not indexed.
      ###############################################################
      (config.services.adsb.mkSdrContainer {
        name = "xng";
        image = config.shared.dockerImages.xng;

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/acarshub.env".path
        ];

        ports = [ "5555:5555" ];

        environment = {
          # Station
          XNG_STATION_ID = "CS-KABQ-ACARS";
          XNG_VERBOSE = "1";

          # Outputs
          XNG_ZMQ = "tcp://0.0.0.0:5555";

          # Session 1: 130.425 - 131.85 MHz
          XNG_MODE = "acars";
          XNG_DRIVER = "rtlsdr";
          XNG_SERIAL = "00012095";
          XNG_CENTER = "131.1375M";
          XNG_SAMPLE_RATE = "2400000";
          XNG_CHANNELS = "131.85;131.825;131.725;131.65;131.55;131.525;131.475;131.45;131.425;131.25;131.125;130.85;130.825;130.55;130.45;130.425";

          # Session 2: 129.0 - 130.025 MHz
          XNG_MODE_2 = "acars";
          XNG_DRIVER_2 = "rtlsdr";
          XNG_SERIAL_2 = "00013305";
          XNG_CENTER_2 = "129.5125M";
          XNG_SAMPLE_RATE_2 = "2400000";
          XNG_CHANNELS_2 = "130.025;129.9;129.525;129.35;129.125;129.0";

          # Session 3: 136.65 - 136.975 MHz
          XNG_MODE_3 = "acars";
          XNG_DRIVER_3 = "rtlsdr";
          XNG_SERIAL_3 = "00012785";
          XNG_CENTER_3 = "136.8125M";
          XNG_SAMPLE_RATE_3 = "2400000";
          XNG_CHANNELS_3 = "136.975;136.8;136.65";
        };

        tmpfs = [
          "/var/log"
        ];

        volumes = [
          "/dev:/dev"
        ];
      })
    ];
  };
}
