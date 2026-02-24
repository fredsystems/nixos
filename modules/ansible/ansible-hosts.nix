{
  sdrhub = {
    ip = "192.168.31.20";
    dir = "sdrhub";
    docker_path = "/opt/adsb";
    slow_start = false;
    os = "nixos";
  };

  fredhub = {
    ip = "192.168.31.14";
    dir = "fredhub";
    docker_path = "/opt/adsb";
    slow_start = false;
    os = "nixos";
  };

  fredvps = {
    ip = "fredclausen.com";
    dir = "fredhub";
    docker_path = "/opt/adsb";
    slow_start = false;
    os = "nixos";
  };

  hfdlhub1 = {
    ip = "192.168.31.19";
    dir = "hfdlhub-1";
    docker_path = "/opt/adsb";
    slow_start = true;
    os = "nixos";
  };

  hfdlhub2 = {
    ip = "192.168.31.17";
    dir = "hfdlhub-2";
    docker_path = "/opt/adsb";
    slow_start = true;
    os = "nixos";
  };

  vdlmhub = {
    ip = "192.168.31.23";
    dir = "vdlmhub";
    docker_path = "/opt/adsb";
    slow_start = false;
    os = "nixos";
  };

  acarshub = {
    ip = "192.168.31.24";
    dir = "acarshub";
    docker_path = "/opt/adsb";
    slow_start = false;
    os = "nixos";
  };

  brandon = {
    ip = "73.242.200.187";
    port = 3222;
    dir = "brandon";
    docker_path = "/opt/adsb";
    slow_start = false;
    os = "ubuntu";
  };
}
