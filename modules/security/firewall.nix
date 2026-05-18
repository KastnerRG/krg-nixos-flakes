{ config, lib, ... }:
with lib;
let
  cfg = config.krg.firewall;
in {
  options.krg.firewall = {
    enable = mkEnableOption "KRG firewall (replaces UFW)";

    allowedTCPPorts = mkOption {
      type    = types.listOf types.port;
      default = [ 22 ];
    };

    allowedUDPPorts = mkOption {
      type    = types.listOf types.port;
      default = [];
    };

    # Ports only reachable from the KRG Prometheus scraping host.
    # Matches UFW rules: allow <port> from 132.239.95.67
    monitoringPorts = mkOption {
      type        = types.listOf types.port;
      default     = [];
      description = "Ports open only to monitoringSourceIp (Prometheus scraping)";
    };

    monitoringSourceIp = mkOption {
      type    = types.str;
      default = "132.239.95.67";
    };

    allowRDP = mkOption {
      type        = types.bool;
      default     = false;
      description = "Open port 3389 for XRDP (waiter compute nodes)";
    };
  };

  config = mkIf cfg.enable {
    # extraInputRules uses nftables syntax; enable the nftables backend
    networking.nftables.enable = true;

    networking.firewall = {
      enable          = true;
      allowedTCPPorts = cfg.allowedTCPPorts ++ optional cfg.allowRDP 3389;
      allowedUDPPorts = cfg.allowedUDPPorts;

      # Equivalent of: ufw allow from 132.239.95.67 to any port <n>
      extraInputRules = concatMapStringsSep "\n" (port: ''
        ip saddr ${cfg.monitoringSourceIp} tcp dport ${toString port} accept
      '') cfg.monitoringPorts;
    };
  };
}
