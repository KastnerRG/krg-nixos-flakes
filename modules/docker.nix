{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.docker;
in {
  options.krg.docker = {
    enable = mkEnableOption "KRG Docker CE configuration";

    enableNvidiaRuntime = mkOption {
      type        = types.bool;
      default     = false;
      description = "Register nvidia-container-runtime in the Docker daemon (for GPU nodes)";
    };

    enableLokiDriver = mkOption {
      type        = types.bool;
      default     = false;
      description = "Set Loki as the default log driver. Requires manual plugin install on first boot.";
    };

    lokiUrl = mkOption {
      type    = types.str;
      default = "http://127.0.0.1:3100/loki/api/v1/push";
    };

    metricsAddr = mkOption {
      type    = types.str;
      default = "0.0.0.0:9323";
    };
  };

  config = mkIf cfg.enable {
    virtualisation.docker = {
      enable      = true;
      enableOnBoot = true;

      daemon.settings = mkMerge [
        {
          "metrics-addr" = cfg.metricsAddr;
          builder.gc = {
            enabled            = true;
            defaultKeepStorage = "512GB";
            policy             = [{ keepStorage = "0"; filter = [ "unused-for=2160h" ]; }];
          };
        }
        (mkIf cfg.enableNvidiaRuntime {
          runtimes.nvidia = {
            path = "${pkgs.nvidia-container-toolkit}/bin/nvidia-container-runtime";
            args = [];
          };
        })
        (mkIf cfg.enableLokiDriver {
          "log-driver" = "loki";
          "log-opts"   = { "loki-url" = cfg.lokiUrl; };
        })
      ];
    };

    # Install the Grafana Loki Docker log driver plugin on first boot.
    # The daemon.json above references it by alias "loki"; this service
    # ensures the plugin is installed before Docker tries to use it.
    systemd.services.docker-loki-plugin = mkIf cfg.enableLokiDriver {
      description = "Install Grafana Loki Docker log driver plugin";
      after       = [ "docker.service" ];
      requires    = [ "docker.service" ];
      wantedBy    = [ "multi-user.target" ];
      serviceConfig = {
        Type             = "oneshot";
        RemainAfterExit  = true;
        ExecStart        = pkgs.writeShellScript "install-loki-plugin" ''
          PLUGIN="grafana/loki-docker-driver:3.3.2-amd64"
          if ! ${pkgs.docker}/bin/docker plugin ls --format '{{.Name}}' | grep -qF "$PLUGIN"; then
            ${pkgs.docker}/bin/docker plugin install --alias loki "$PLUGIN" --grant-all-permissions
          fi
          ${pkgs.docker}/bin/docker plugin enable "$PLUGIN" 2>/dev/null || true
        '';
      };
    };
  };
}
