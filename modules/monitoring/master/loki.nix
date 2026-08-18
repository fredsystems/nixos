{
  systemd.tmpfiles.rules = [
    "d /var/lib/loki 0750 loki loki -"
  ];

  networking.firewall.allowedTCPPorts = [
    5678 # Loki
  ];

  services = {
    loki = {
      enable = true;

      configuration = {
        server = {
          http_listen_address = "0.0.0.0";
          http_listen_port = 5678;

          # Loki was the single noisiest unit on this host: 22,080 journal
          # lines/hour, measured 2026-08-18. All of it routine internal
          # housekeeping at level=info -- "dynamically updated instance",
          # "recalculate owned streams job", "uploading tables", "no marks file
          # found", plus one line per rule evaluation from the ruler.
          #
          # That volume is not free. It drives journald's write amplification
          # (see the SyncIntervalSec note in modules/base/system.nix) on the
          # host with the fleet's most worn SSD -- 55% of rated endurance
          # consumed, +1% in the seven days to 2026-08-18.
          #
          # It is also self-referential in a way worth noticing: alloy tails
          # the journal and ships it to Loki, so Loki's own chatter about
          # ingesting logs becomes logs it then ingests, indexes and retains
          # for 30 days.
          #
          # warn keeps genuine problems -- ingestion failures, rule evaluation
          # errors, storage errors -- while dropping the running commentary.
          # Deliberately not `error`: a warn-level message here usually means
          # data is being dropped, which is exactly what this monitoring stack
          # exists to notice.
          log_level = "warn";
        };

        auth_enabled = false;

        common = {
          replication_factor = 1;
          path_prefix = "/var/lib/loki";

          ring = {
            kvstore.store = "inmemory";
            instance_addr = "127.0.0.1";
          };
        };

        #
        # Loki 3.x TSDB schema
        #
        schema_config = {
          configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
        };

        #
        # Loki 3.x retention lives here
        #
        limits_config = {
          retention_period = "30d";
        };

        #
        # Loki 3.x compactor settings
        #
        compactor = {
          working_directory = "/var/lib/loki/compactor";

          # shared_store = "filesystem";

          compaction_interval = "10m";
          retention_enabled = true;
          retention_delete_delay = "2h";
          delete_request_store = "filesystem";
        };

        storage_config.filesystem.directory = "/var/lib/loki/chunks";

        analytics.reporting_enabled = false;
      };
    };
  };
}
