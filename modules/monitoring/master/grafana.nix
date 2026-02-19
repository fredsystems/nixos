{
  #######################################
  # SOPS Secret
  #######################################
  sops.secrets."monitoring/grafana_pw" = {
    owner = "grafana";
  };

  networking.firewall.allowedTCPPorts = [
    3333 # Grafana
  ];

  environment.etc = {
    "grafana/provisioning/dashboards/system/node-exporter-full.json" = {
      source = ./dashboards/node-exporter-full.json;
      user = "grafana";
      group = "grafana";
      mode = "0444";
    };

    "grafana/provisioning/dashboards/containers/dashboard-container-overview.json" = {
      source = ./dashboards/container.json;
      user = "grafana";
      group = "grafana";
      mode = "0444";
    };

    "grafana/provisioning/dashboards/system/system-logs.json" = {
      source = ./dashboards/system-logs.json;
      user = "grafana";
      group = "grafana";
      mode = "0444";
    };

    "grafana/provisioning/dashboards/adsb/dashboard-adsb.json" = {
      source = ./dashboards/adsb.json;
      user = "grafana";
      group = "grafana";
      mode = "0444";
    };

    "grafana/provisioning/dashboards/adsb/dashboard-acars.json" = {
      source = ./dashboards/acars.json;
      user = "grafana";
      group = "grafana";
      mode = "0444";
    };
  };

  services = {
    #######################################
    # Grafana
    #######################################
    grafana = {
      enable = true;

      settings = {
        server = {
          http_port = 3333;
          http_addr = "0.0.0.0";
        };

        security = {
          admin_user = "admin";
          admin_password = "$__file{/run/secrets/monitoring/grafana_pw}";

          secret_key = "SW2YcwTIb9zpOOhoPsMm"; # default from pre 26.05. Why we removed it I'll never know.
        };
      };

      provision = {
        enable = true;

        datasources = {
          settings = {
            datasources = [
              {
                name = "Prometheus";
                type = "prometheus";
                url = "http://127.0.0.1:9090";
                access = "proxy";
                isDefault = true;
              }

              {
                name = "Loki";
                type = "loki";
                access = "proxy";
                url = "http://localhost:5678";
                isDefault = false;
              }
            ];
          };
        };

        dashboards = {
          settings = {
            apiVersion = 1;

            providers = [
              {
                name = "node-exporter";
                orgId = 1;
                folder = "System";
                type = "file";
                disableDeletion = true;
                updateIntervalSeconds = 60;

                options = {
                  path = "/etc/grafana/provisioning/dashboards/system";
                };
              }

              {
                name = "cadvisor";
                orgId = 1;
                folder = "Container";
                type = "file";
                disableDeletion = true;
                updateIntervalSeconds = 60;

                options = {
                  path = "/etc/grafana/provisioning/dashboards/containers";
                };
              }

              {
                name = "adsb";
                orgId = 1;
                folder = "ADSB";
                type = "file";
                disableDeletion = true;
                updateIntervalSeconds = 60;

                options = {
                  path = "/etc/grafana/provisioning/dashboards/adsb";
                };
              }
            ];
          };
        };
      };

      dataDir = "/var/lib/grafana";
    };
  };
}
