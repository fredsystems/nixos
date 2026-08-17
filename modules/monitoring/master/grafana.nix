{
  #######################################
  # SOPS Secrets
  #######################################
  sops.secrets = {
    "monitoring/grafana_pw" = {
      owner = "grafana";
    };

    # Grafana's envelope-encryption root key.
    #
    # This used to be the string literal "SW2YcwTIb9zpOOhoPsMm" in this file --
    # which is nixpkgs' pre-26.05 default, i.e. a publicly documented constant,
    # committed to a public repository and rendered world-readable into the Nix
    # store. It protected nothing, twice over.
    #
    # Moving the SAME value into sops would have been theatre: it is already
    # public and unchangeable in git history. So the value behind this secret is
    # a freshly generated one, and the old constant is now dead.
    #
    # Rotating it is safe here, which was verified against the live database
    # rather than assumed:
    #
    #   * Both datasources' `secure_json_data` is `{}` -- they proxy to loopback
    #     Prometheus and Loki with no credentials to lose.
    #   * The `secrets` table holds one 79-byte row per datasource, and both
    #     datasources are provisioned declaratively below, so Grafana re-encrypts
    #     and rewrites them with the new key on the next start.
    #   * The unified-alerting config is Grafana's untouched default, whose only
    #     receiver carries a placeholder address in plain `settings`, not
    #     `secureSettings`.
    #   * Dashboards, users, alert rules and annotations are not encrypted with
    #     this key at all.
    #   * Browser sessions live in `user_auth_token` as hashes and are unrelated,
    #     so rotating does not sign anyone out.
    #
    # The 42 rows in `data_keys` are wrapped with the old key and become
    # undecryptable. They protect nothing per the above; expect Grafana to log
    # decryption errors for them once and then move on.
    "monitoring/grafana_secret_key" = {
      owner = "grafana";
    };
  };

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

    "grafana/provisioning/dashboards/fleet/fleet-overview.json" = {
      source = ./dashboards/fleet-overview.json;
      user = "grafana";
      group = "grafana";
      mode = "0444";
    };

    "grafana/provisioning/dashboards/security/security.json" = {
      source = ./dashboards/security.json;
      user = "grafana";
      group = "grafana";
      mode = "0444";
    };

    "grafana/provisioning/dashboards/github/github-ci.json" = {
      source = ./dashboards/github-ci.json;
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

          # Loopback only. Grafana was previously on 0.0.0.0 with 3333 opened in
          # the firewall and no TLS anywhere, which meant the admin password
          # crossed the LAN in cleartext on every login -- to a service that is
          # a full read/write control plane, not a read-only dashboard.
          #
          # It is now reached exclusively through the nginx vhost in
          # hosts/linux/sdrhub/configuration.nix, the same treatment karma and
          # the clipboard server already get. The `networking.firewall` entry
          # for 3333 is gone with it.
          #
          # This does not affect the Prometheus scrape job in prometheus.nix,
          # which already targets 127.0.0.1:3333.
          http_addr = "127.0.0.1";

          # Required once Grafana is behind a proxy: it builds absolute URLs
          # (login redirects, alert links, generated share URLs) from these, and
          # without them it would advertise http://localhost:3333 to browsers
          # that reached it over TLS on another name.
          #
          # Kept in lockstep with the vhost by an assertion in
          # hosts/linux/sdrhub/configuration.nix, which fails the build if this
          # URL and the server_name stop agreeing.
          domain = "grafana.int.fredsystems.org";
          root_url = "https://grafana.int.fredsystems.org/";
        };

        security = {
          admin_user = "admin";
          admin_password = "$__file{/run/secrets/monitoring/grafana_pw}";

          # See the sops block at the top of this file for why this is no longer
          # a literal, and for the evidence that rotating it is safe.
          secret_key = "$__file{/run/secrets/monitoring/grafana_secret_key}";
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
                uid = "PBFA97CFB590B2093";
              }

              {
                name = "Loki";
                type = "loki";
                access = "proxy";
                url = "http://localhost:5678";
                isDefault = false;
                uid = "P8E80F9AEF21F6940";
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

              {
                name = "fleet";
                orgId = 1;
                folder = "Fleet";
                type = "file";
                disableDeletion = true;
                updateIntervalSeconds = 60;

                options = {
                  path = "/etc/grafana/provisioning/dashboards/fleet";
                };
              }

              {
                name = "security";
                orgId = 1;
                folder = "Security";
                type = "file";
                disableDeletion = true;
                updateIntervalSeconds = 60;

                options = {
                  path = "/etc/grafana/provisioning/dashboards/security";
                };
              }

              {
                name = "github";
                orgId = 1;
                folder = "GitHub";
                type = "file";
                disableDeletion = true;
                updateIntervalSeconds = 60;

                options = {
                  path = "/etc/grafana/provisioning/dashboards/github";
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
