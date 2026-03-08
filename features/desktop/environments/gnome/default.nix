{
  lib,
  pkgs,
  config,
  hmlib,
  user,
  extraUsers ? [ ],
  ...
}:
with lib;
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.gnome;
in
{
  options.desktop.environments.gnome = {
    enable = mkOption {
      description = "Install GNOME desktop environment.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      gnomeExtensions.caffeine
      gnomeExtensions.vitals
      gnomeExtensions.impatience
      gnomeExtensions.clipboard-indicator
      gnomeExtensions.dash-to-panel
      gnomeExtensions.arcmenu
      gnomeExtensions.search-light
      gnomeExtensions.weather-or-not
      gnomeExtensions.user-themes
      gnome-themes-extra
      flat-remix-gnome
      wl-clipboard
      dconf-editor
    ];

    services = {
      xserver.enable = false;
      desktopManager.gnome.enable = true;
    };

    environment.gnome.excludePackages = with pkgs; [
      atomix
      cheese
      epiphany
      geary
      gnome-characters
      gnome-music
      gnome-photos
      gnome-tour
      hitori
      iagno
      tali
      totem
    ];

    systemd.settings.Manager = {
      DefaultTimeoutStopSec = "10s";
    };

    home-manager.users = lib.genAttrs allUsers (_: {
      imports = [ ../modules/xdg-mime-common.nix ];

      catppuccin.gtk.icon.enable = true;

      dconf.settings = {
        "org/gnome/shell" = {
          disable-user-extensions = false;
          always-show-log-out = true;
          enabled-extensions = [
            "user-theme@gnome-shell-extensions.gcampax.github.com"
            "Vitals@CoreCoding.com"
            "arcmenu@arcmenu.com"
            "caffeine@patapon.info"
            "clipboard-indicator@tudmotu.com"
            "dash-to-panel@jderose9.github.com"
            "impatience@gfxmonk.net"
            "search-light@icedman.github.com"
            "weatherornot@somepaulo.github.io"
          ];
          favorite-apps = [
            "org.gnome.Nautilus.desktop"
            "org.gnome.Calendar.desktop"
            "org.gnome.Geary.desktop"
            "discord.desktop"
            "code.desktop"
            "org.wezfurlong.wezterm.desktop"
            "firefox.desktop"
          ];
        };

        "org.gnome.desktop.default-applications.terminal" = {
          exec = "wezterm";
        };

        "org/gnome/desktop/peripherals/mouse" = {
          speed = hmlib.hm.gvariant.mkDouble "-0.3023255813953488";
        };

        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
          enable-hot-corners = false;
          clock-show-seconds = true;
          clock-show-weekday = true;
          clock-format = "24h";
          show-battery-percentage = true;
        };

        "org.gnome.desktop.calendar" = {
          show-weekdate = true;
        };

        "org/gnome/shell/extensions/user-theme" = {
          name = "Catppuccin-GTK-Mauve-Dark";
        };

        "org/gnome/shell/extensions/arcmenu" = {
          menu-button-appears = "Icon";
          menu-layout = "Plasma";
        };

        "org/gnome/shell/extensions/dash-to-panel" = {
          trans-panel-opacity = 0.5;
          trans-use-custom-panel-opacity = true;
          panel-element-positions = ''
            {"0":[{"element":"showAppsButton","visible":false,"position":"stackedTL"},{"element":"activitiesButton","visible":false,"position":"stackedTL"},{"element":"leftBox","visible":true,"position":"stackedTL"},{"element":"taskbar","visible":true,"position":"stackedTL"},{"element":"centerBox","visible":true,"position":"stackedBR"},{"element":"rightBox","visible":true,"position":"stackedBR"},{"element":"dateMenu","visible":true,"position":"stackedBR"},{"element":"systemMenu","visible":true,"position":"stackedBR"},{"element":"desktopButton","visible":true,"position":"stackedBR"},{"element":"new-element","visible":true,"position":"stackedBR"}]}
          '';
        };

        "org/gnome/shell/extensions/weatherornot" = {
          position = "clock-right";
        };

        "org/gnome/shell/extensions/search-light" = {
          shortcut-search = [ "<Control>Space" ];
        };

        "org/gnome/shell/weather" = {
          automatic-location = true;
          locations = [
            (hmlib.hm.gvariant.mkVariant (
              hmlib.hm.gvariant.mkTuple [
                (hmlib.hm.gvariant.mkUint32 2)
                (hmlib.hm.gvariant.mkVariant (
                  hmlib.hm.gvariant.mkTuple [
                    "Albuquerque"
                    "KABQ"
                    true
                    [
                      (hmlib.hm.gvariant.mkTuple [
                        (hmlib.hm.gvariant.mkDouble "0.6115924645374438")
                        (hmlib.hm.gvariant.mkDouble "-1.8607779299984337")
                      ])
                    ]
                    [
                      (hmlib.hm.gvariant.mkTuple [
                        (hmlib.hm.gvariant.mkDouble "0.6123398843363179")
                        (hmlib.hm.gvariant.mkDouble "-1.8614134916455476")
                      ])
                    ]
                  ]
                ))
              ]
            ))
            (hmlib.hm.gvariant.mkVariant (
              hmlib.hm.gvariant.mkTuple [
                (hmlib.hm.gvariant.mkUint32 2)
                (hmlib.hm.gvariant.mkVariant (
                  hmlib.hm.gvariant.mkTuple [
                    "Albuquerque International Airport"
                    "KABQ"
                    false
                    [
                      (hmlib.hm.gvariant.mkTuple [
                        (hmlib.hm.gvariant.mkDouble "0.6115924645374438")
                        (hmlib.hm.gvariant.mkDouble "-1.8607779299984337")
                      ])
                    ]
                    (hmlib.hm.gvariant.mkArray "(dd)" [ ])
                  ]
                ))
              ]
            ))
          ];
        };

        "org/gnome/Weather" = {
          locations = [
            (hmlib.hm.gvariant.mkVariant (
              hmlib.hm.gvariant.mkTuple [
                (hmlib.hm.gvariant.mkUint32 2)
                (hmlib.hm.gvariant.mkVariant (
                  hmlib.hm.gvariant.mkTuple [
                    "Albuquerque"
                    "KABQ"
                    true
                    [
                      (hmlib.hm.gvariant.mkTuple [
                        (hmlib.hm.gvariant.mkDouble "0.6115924645374438")
                        (hmlib.hm.gvariant.mkDouble "-1.8607779299984337")
                      ])
                    ]
                    [
                      (hmlib.hm.gvariant.mkTuple [
                        (hmlib.hm.gvariant.mkDouble "0.6123398843363179")
                        (hmlib.hm.gvariant.mkDouble "-1.8614134916455476")
                      ])
                    ]
                  ]
                ))
              ]
            ))
            (hmlib.hm.gvariant.mkVariant (
              hmlib.hm.gvariant.mkTuple [
                (hmlib.hm.gvariant.mkUint32 2)
                (hmlib.hm.gvariant.mkVariant (
                  hmlib.hm.gvariant.mkTuple [
                    "Albuquerque International Airport"
                    "KABQ"
                    false
                    [
                      (hmlib.hm.gvariant.mkTuple [
                        (hmlib.hm.gvariant.mkDouble "0.6115924645374438")
                        (hmlib.hm.gvariant.mkDouble "-1.8607779299984337")
                      ])
                    ]
                    (hmlib.hm.gvariant.mkArray "(dd)" [ ])
                  ]
                ))
              ]
            ))
          ];
        };

        "org/gnome/GWeather4" = {
          temperature-unit = "centigrade";
        };
      };
    });
  };
}
