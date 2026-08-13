{
  pkgs,
  user,
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/desktop.nix
    ./tailscale.nix
  ];

  # Hardware profile settings
  hardware-profile = {
    graphics.enable = true;
    graphics.enable32Bit = true;
    fingerprint.enable = true;
    logitech.enable = true;
  };

  profile.desktop.bluetooth.enable = true;

  # extra options
  ai = {
    enable = false;
    opencode.enable = true;
    local-llm = {
      enable = false;
      ollamaPackage = pkgs.ollama;
    };
  };

  desktop.enable_games = false;

  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking = {
    hostName = "Daytona";
    networkmanager.wifi.scanRandMacAddress = false;
    firewall.allowedTCPPorts = [ 12345 ];
  };

  system.activationScripts.sddm-hyprland-config = ''
    mkdir -p /var/lib/sddm/.config/hypr
    # hyprland.conf (hyprlang) is deprecated upstream; the Lua config is the
    # supported format. No monitor rules are needed on this host -- the file
    # only has to exist so Hyprland does not fall back to its shipped default.
    rm -f /var/lib/sddm/.config/hypr/hyprland.conf
    cat <<EOF > /var/lib/sddm/.config/hypr/hyprland.lua
    -- Auto-generated for the SDDM Wayland session.
    EOF
    chown -R sddm:sddm /var/lib/sddm/.config
  '';

  services = {
    alloy = {
      enable = true;
      configPath = pkgs.writeText "daytona.alloy" ''
        // Journal source: tail systemd journal and emit Loki entries.
        loki.source.journal "journal" {
          path          = "/var/log/journal"
          forward_to    = [loki.write.default.receiver]
          relabel_rules = loki.relabel.journal.rules
          labels        = {
            job      = "journal",
            hostname = "Daytona",
            host     = "Daytona",
          }
        }

        // Relabel journal metadata into stable Loki labels.
        loki.relabel "journal" {
          forward_to = []

          rule {
            source_labels = ["__journal__systemd_unit"]
            target_label  = "unit"
          }
          rule {
            source_labels = ["__journal__container_name"]
            target_label  = "container"
          }
          rule {
            source_labels = ["__journal__container_id"]
            target_label  = "container_id"
          }
        }

        // Push logs to the central Loki master.
        loki.write "default" {
          endpoint {
            url       = "http://192.168.31.20:5678/loki/api/v1/push"
            tenant_id = "default"
          }
        }

        // Scrape local node_exporter
        prometheus.scrape "node_exporter" {
          targets = [
            {"__address__" = "localhost:9100"},
          ]
          forward_to = [prometheus.relabel.node_exporter.receiver]
          scrape_interval = "15s"
        }

        // Ensure proper labels for metrics
        prometheus.relabel "node_exporter" {
          forward_to = [prometheus.remote_write.default.receiver]

          rule {
            target_label = "hostname"
            replacement  = "Daytona"
          }
          rule {
            target_label = "role"
            replacement  = "desktop"
          }
          rule {
            target_label = "exporter"
            replacement  = "node"
          }
          rule {
            target_label = "job"
            replacement  = "node"
          }
          rule {
            target_label = "instance"
            replacement  = "Daytona.local:9100"
          }
        }

        // Push metrics to central Prometheus master
        prometheus.remote_write "default" {
          endpoint {
            url = "http://192.168.31.20:9090/api/v1/write"
          }
        }
      '';
    };

    displayManager = {
      defaultSession = "hyprland";
      sddm = {
        enable = true;
        wayland = {
          enable = true;
        };

        settings = {
          Wayland = {
            EnableHiDPI = true;

            CompositorCommand = "${pkgs.hyprland}/bin/start-hyprland";
          };
        };
      };
    };

    logind = {
      settings = {
        Login = {
          HandleLidSwitch = "suspend";
          HandlePowerKey = "suspend";
        };
      };
    };
  };

  security.pam.services = {
    login.fprintAuth = false;
  };

  powerManagement.enable = false;

  environment.systemPackages = [ ];

  system.stateVersion = stateVersion;

  sops.secrets = {
    "fred-yubi" = {
      path = "/home/${user}/.config/Yubico/u2f_keys";
      owner = user;
      mode = "0600";
    };
  };
}
