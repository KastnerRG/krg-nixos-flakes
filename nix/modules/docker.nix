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
        # TODO (planned, not yet): ship container logs to a central Loki FLEET-WIDE
        # (every machine, probably from base.nix). The old approach here — Docker's
        # loki log-driver via an on-first-boot `docker plugin install` — was removed
        # for now: it's fragile (a dead Loki endpoint can hang docker) and isn't the
        # path we want for the fleet roll-out.
      ];
    };
  };
}
