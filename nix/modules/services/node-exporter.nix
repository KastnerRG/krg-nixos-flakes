# Prometheus node exporter (native systemd via NixOS).
# CROSS-REFERENCE: the Proxmox-host counterpart is ansible/roles/monitoring
# (binary + systemd unit). Keep the port aligned; both feed the same Prometheus.
{ config, lib, ... }:
with lib;
let
  cfg = config.krg.nodeExporter;
in {
  options.krg.nodeExporter = {
    enable = mkEnableOption "Prometheus node exporter (native systemd service)";

    port = mkOption {
      type    = types.port;
      default = 9100;
    };

    collectors = mkOption {
      type    = types.listOf types.str;
      default = [ "systemd" ];
    };
  };

  config = mkIf cfg.enable {
    services.prometheus.exporters.node = {
      enable            = true;
      port              = cfg.port;
      enabledCollectors = cfg.collectors;
    };
  };
}
