{
  config,
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/adsb-hub.nix
    ../../../modules/hardware/usbfs.nix
  ];

  networking.hostName = "vdlmhub";

  # This host has USB SDR hardware attached; raise the global usbfs
  # transfer-buffer ceiling above the 16 MB kernel default.
  hardware-profile.usbfs.enable = true;

  system.stateVersion = stateVersion;

  # acars_router on sdrhub connects in to xng's ZMQ PUB socket
  # (AR_RECV_ZMQ_XNG), same as it does for acarshub.
  networking.firewall.allowedTCPPorts = [ 5555 ];

  services = {
    adsb.containers = [

      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      (import ../../../modules/services/mk-dozzle-agent.nix {
        image = config.shared.dockerImages.dozzle;
      })

      ###############################################################
      # XNG
      #
      # Replaces dumpvdl2-1..4: one station, one VDL2 session per SDR,
      # same serials and channel sets as the old containers. Session 1
      # uses the unsuffixed XNG_* vars, session 2+ use _2, _3, ...; the
      # container refuses to start on a numbering gap. Outputs are
      # station-wide and not indexed.
      ###############################################################
      (config.services.adsb.mkSdrContainer {
        name = "xng";
        image = config.shared.dockerImages.xng;

        tty = true;
        restart = "always";

        ports = [ "5555:5555" ];

        environment = {
          TZ = "America/Denver";

          # Station
          XNG_STATION_ID = "CS-KABQ-VDLM";
          XNG_VERBOSE = "1";

          # Outputs
          XNG_ZMQ = "tcp://0.0.0.0:5555";

          # Session 1: 136.775 - 136.975 MHz
          XNG_MODE = "vdl2";
          XNG_DRIVER = "rtlsdr";
          XNG_SERIAL = "00013475";
          XNG_CENTER = "136.875M";
          XNG_SAMPLE_RATE = "2400000";
          XNG_CHANNELS = "136.975;136.945;136.925;136.825;136.8;136.775";

          # Session 2: 136.1 - 136.725 MHz
          XNG_MODE_2 = "vdl2";
          XNG_DRIVER_2 = "rtlsdr";
          XNG_SERIAL_2 = "00013212";
          XNG_CENTER_2 = "136.4125M";
          XNG_SAMPLE_RATE_2 = "2400000";
          XNG_CHANNELS_2 = "136.725;136.7;136.675;136.65;136.3;136.1";

          # Session 3: 131.125 - 131.725 MHz
          XNG_MODE_3 = "vdl2";
          XNG_DRIVER_3 = "rtlsdr";
          XNG_SERIAL_3 = "00012507";
          XNG_CENTER_3 = "131.425M";
          XNG_SAMPLE_RATE_3 = "2400000";
          XNG_CHANNELS_3 = "131.725;131.55;131.125";

          # Session 4: 130.025 - 130.825 MHz
          XNG_MODE_4 = "vdl2";
          XNG_DRIVER_4 = "rtlsdr";
          XNG_SERIAL_4 = "00012867";
          XNG_CENTER_4 = "130.425M";
          XNG_SAMPLE_RATE_4 = "2400000";
          XNG_CHANNELS_4 = "130.825;130.45;130.025";
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
