{ config, lib, ... }:
let
  cfg = config.ai.local-llm;
in
{
  # Everything here is gated on ai.local-llm.enable.
  #
  # This file is imported unconditionally for every Linux host
  # (`imports = lib.optional isLinux ./linux.nix` in default.nix), and
  # `imports` cannot be wrapped in mkIf. Without the guard below, its config
  # applied even where the LLM stack was switched off -- so all six servers
  # with ai.local-llm.enable = false were opening 11434 and 8889 in their
  # firewalls for services that were not running. On fredvps, which has a
  # public interface, that meant two ports advertised to the internet
  # pointing at nothing.
  #
  # Nothing was listening, so nothing was exploitable, but an open port to a
  # dead service is exactly the kind of thing that becomes a real hole the
  # day something else binds it.
  config = lib.mkIf cfg.enable {
    hardware.graphics.enable = true;

    networking.firewall.allowedTCPPorts = [
      cfg.ollamaPort
      cfg.webuiPort
    ];
  };
}
