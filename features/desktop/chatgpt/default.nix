import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.chatgpt";
  description = "ChatGPT desktop app";
  packages = pkgs: [ pkgs.chatgpt ];
  unfree = [ "chatgpt" ];
}
