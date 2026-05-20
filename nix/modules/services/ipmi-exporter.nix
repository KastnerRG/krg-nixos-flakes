{ config, lib, ... }:
with lib;
let
  cfg = config.krg.ipmiExporter;
in {
  options.krg.ipmiExporter = {
    enable = mkEnableOption "Prometheus IPMI exporter (native systemd service)";

    port = mkOption {
      type    = types.port;
      default = 9290;
    };
  };

  # Uses the nixpkgs-provided ipmi_exporter, equivalent to the manual
  # v1.9.0 binary install in fabricant-prod monitoring.yaml
  config = mkIf cfg.enable {
    services.prometheus.exporters.ipmi = {
      enable = true;
      port   = cfg.port;
    };
  };
}
