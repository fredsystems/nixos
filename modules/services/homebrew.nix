{

  homebrew = {
    enable = true;
    caskArgs.no_quarantine = true;
    taps = [
      "pothosware/pothos"
      #"mas-cli/tap/mas"
    ];

    brews = [
      "gcc"
      "telnet"
      "vttest"
      "trunk"
      "cargo-make"
      "diesel"
      "openssh"
    ];

    casks = [
      "ghostty"
      "vlc"
      "iterm2"
      "raycast"
      "visual-studio-code"
      "hiddenbar"
      "sublime-text"
      "tradingview"
      "macupdater"
      "istat-menus"
      "github"
      "discord"
      "docker-desktop"
      "brave-browser"
      "balenaetcher"
      "streamlabs"
      "ledger-wallet"
      "elgato-stream-deck"
      "db-browser-for-sqlite"
      "angry-ip-scanner"
      "font-fira-code"
      "font-hack-nerd-font"
      "font-meslo-lg-nerd-font"
      "multiviewer"
    ];

    masApps = {
      "1Password for Safari" = 1569813296;
      "AdGuard Mini" = 1440147259;
      "Amphetamine" = 937984704;
      "Banish" = 1639049780;
      "GarageBand" = 682658836;
      "HextEdit" = 1557247094;
      "iMovie" = 408981434;
      "Keynote" = 409183694;
      "Magnet" = 441258766;
      "Numbers" = 409203825;
      "Pages" = 409201541;
      "Pixelmator Pro" = 1289583905;
      "Stockfish" = 801463932;
      "StopTheMadness" = 6471380298;
      "Super Agent" = 1568262835;
      #"Wifiman" = 1385561119;
      "Xcode" = 497799835;
      "Yubikey" = 1497506650;
    };
  };
}
