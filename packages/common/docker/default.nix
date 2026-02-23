{
  pkgs,
  ...
}:
{
  config = {
    virtualisation.docker = {
      enable = true;

      autoPrune = {
        enable = true;
        dates = "daily";
        flags = [ "--all" ];
      };
    };

    systemd = {
      services = {
        docker-create-adsbnet = {
          description = "Create Docker network adsbnet";
          after = [ "docker.service" ];
          requires = [ "docker.service" ];

          serviceConfig = {
            Type = "oneshot";
            ExecStart = ''${pkgs.runtimeShell} -c "${pkgs.docker}/bin/docker network create adsbnet || true"'';
          };

          wantedBy = [ "multi-user.target" ];
        };
      };
    };
  };
}
