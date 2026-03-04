{
  lib,
  config,
  user,
  extraUsers ? [ ],
  pkgs,
  ...
}:

let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.thunderbird;

  tbSignatures = {
    natca = {
      email = "fclausen@natca.net";
      secret = config.sops.secrets."email/natca/signature".path;
    };
    iCloud = {
      email = "clausen.fred@icloud.com";
      secret = config.sops.secrets."email/icloud/signature".path;
    };

    gMail = {
      email = "clausen.fred@gmail.com";
      secret = config.sops.secrets."email/icloud/signature".path;
    };

    ZABNATCATech = {
      email = "zabnatca.tech@gmail.com";
      secret = config.sops.secrets."email/icloud/signature".path;
    };
  };
in
{
  options.desktop.thunderbird = {
    enable = lib.mkEnableOption "Enable Thunderbird email client";
  };

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.thunderbird = {
        enable = true;

        settings = {
        };

        profiles."default" = {
          isDefault = true;
          settings = {
          };

          accountsOrder = [
            "iCloud"
            "NATCA"
            "gMail"
            # "ZAB NATCA Tech"
          ];
        };
      };

      accounts = {
        # contact.accounts = {
        #   iCloud = {
        #     remote = {
        #       url = "https://carddav.icloud.com";
        #       type = "carddav";
        #       userName = "clausen.fred@icloud.com";
        #     };

        #     thunderbird = {
        #       enable = true; # generate thunderbird config for this account
        #       profiles = [ "default" ]; # attach to that profile
        #     };
        #   };
        # };

        #https://contacts.icloud.com/contacts/
        # calendar.accounts = {
        #   iCloud = {
        #     primary = true;

        #     remote = {
        #       url = "https://caldav.icloud.com";
        #       type = "caldav";
        #       userName = "clausen.fred@icloud.com";
        #     };

        #     thunderbird = {
        #       enable = true; # generate thunderbird config for this account
        #       profiles = [ "default" ]; # attach to that profile
        #     };
        #   };
        # };

        email.accounts = {
          NATCA = {
            primary = false;
            realName = "Fred Clausen";
            address = "fclausen@natca.net";
            userName = "fclausen@natca.net";

            imap = {
              host = "secure.emailsrvr.com";
              port = 993;
              tls.enable = true;
            };

            smtp = {
              host = "secure.emailsrvr.com";
              port = 587;
              authentication = "login";
              tls = {
                enable = true;
                useStartTls = true;
              };
            };

            signature = {
              showSignature = "append";
            };

            thunderbird = {
              enable = true; # generate thunderbird config for this account
              profiles = [ "default" ]; # attach to that profile
            };
          };

          gMail = {
            primary = false;
            realName = "Fred Clausen";
            address = "clausen.fred@gmail.com";
            userName = "clausen.fred@gmail.com";

            imap = {
              host = "imap.gmail.com";
              port = 993;
              tls.enable = true;
            };

            smtp = {
              host = "smtp.gmail.com";
              port = 587;
              authentication = "login";
              tls = {
                enable = true;
                useStartTls = true;
              };
            };

            signature = {
              showSignature = "append";
            };

            thunderbird = {
              enable = true; # generate thunderbird config for this account
              profiles = [ "default" ]; # attach to that profile
            };
          };

          # "ZAB NATCA Tech" = {
          #   primary = false;
          #   realName = "Fred Clausen";
          #   address = "zabnatca.tech@gmail.com";
          #   userName = "zabnatca.tech@gmail.com";

          #   imap = {
          #     host = "imap.gmail.com";
          #     port = 993;
          #     tls.enable = true;
          #   };

          #   smtp = {
          #     host = "smtp.gmail.com";
          #     port = 587;
          #     tls = {
          #       enable = true;
          #     };
          #   };

          #   signature = {
          #     showSignature = "append";
          #   };

          #   thunderbird = {
          #     enable = true; # generate thunderbird config for this account
          #     profiles = [ "default" ]; # attach to that profile
          #   };
          # };

          iCloud = {
            primary = true;
            realName = "Fred Clausen";
            address = "clausen.fred@icloud.com";
            userName = "clausen.fred@icloud.com";

            imap = {
              host = "imap.mail.me.com";
              port = 993;
              tls.enable = true;
            };

            smtp = {
              host = "smtp.mail.me.com";
              port = 587;
              authentication = "login";
              tls = {
                enable = true;
                useStartTls = true;
              };
            };

            signature = {
              showSignature = "append";
            };

            thunderbird = {
              enable = true; # generate thunderbird config for this account
              profiles = [ "default" ]; # attach to that profile
            };
          };
        };
      };

      # Catppuccin theme integration
      catppuccin.thunderbird.enable = true;

      home = {
        packages = with pkgs; [
          birdtray
        ];

        activation = {
          thunderbirdSignatureFiles = lib.mkAfter ''
            sigdir="$HOME/.thunderbird/signatures"
            mkdir -p "$sigdir"

            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (name: v: ''
                cp ${v.secret} "$sigdir/${name}.txt"
                chmod 600 "$sigdir/${name}.txt"
              '') tbSignatures
            )}
          '';

          thunderbirdSignaturePrefs = lib.mkAfter ''
            profile="$HOME/.thunderbird/default"
            sig_path="$HOME/.thunderbird/signatures"
            prefs="$profile/prefs.js"

            # If Thunderbird has never been run, bail safely
            [ -f "$prefs" ] || exit 0

            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (name: v: ''
                id="$(
                  ${pkgs.ripgrep}/bin/rg -m1 \
                    "user_pref\\(\"mail.identity.id_[^.]+\\.useremail\", \"${v.email}\"" \
                    "$prefs" 2>/dev/null || true \
                  | sed -E 's/.*mail.identity.id_([^.]+)\.useremail.*/\1/' \
                  | tr -d '\n'
                )"

                if [ -n "$id" ]; then
                  tmp="$(mktemp)"

                  ${pkgs.gawk}/bin/awk -v id="$id" '
                    $0 ~ "^user_pref\\(\"mail.identity.id_" id "\\.(sig_|htmlSigText|attach_signature)" {
                      next
                    }
                    { print }
                  ' "$prefs" > "$tmp"

                  mv "$tmp" "$prefs"

                  printf '%s\n' \
                    "user_pref(\"mail.identity.id_$id.attach_signature\", true);" \
                    "user_pref(\"mail.identity.id_$id.sig_file\", \"$sig_path/signatures/${name}.txt\");" \
                    "user_pref(\"mail.identity.id_$id.sig_file-rel\", \"[ProfD]../signatures/${name}.txt\");" \
                    >> "$prefs"
                fi

              '') tbSignatures
            )}
          '';
        };
      };
    });
  };
}
