{ config, ... }:
{
  hardware.graphics.enable = true;
  networking.firewall.allowedTCPPorts = [
    config.ai.local-llm.ollamaPort
    config.ai.local-llm.webuiPort
  ];
}
