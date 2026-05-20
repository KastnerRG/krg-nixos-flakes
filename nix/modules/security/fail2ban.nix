{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.fail2ban;
in {
  options.krg.fail2ban = {
    enable = mkEnableOption "KRG fail2ban SSH protection";

    bantime = mkOption {
      type    = types.str;
      default = "1d";
    };

    bantimeIncrement = mkOption {
      type        = types.bool;
      default     = true;
      description = "Exponentially increase ban duration for repeat offenders";
    };

    bantimeRndtime = mkOption {
      type        = types.int;
      default     = 3600;
      description = "Random time added to ban (seconds), prevents coordinated timing attacks";
    };

    maxRetry = mkOption {
      type    = types.int;
      default = 5;
    };
  };

  config = mkIf cfg.enable {
    services.fail2ban = {
      enable        = true;
      extraPackages = [ pkgs.ipset ];

      bantime          = cfg.bantime;
      bantime-increment = {
        enable  = cfg.bantimeIncrement;
        rndtime = "${toString cfg.bantimeRndtime}s";
      };

      jails.sshd.settings = {
        enabled  = true;
        filter   = "sshd";
        maxretry = cfg.maxRetry;
      };
    };
  };
}
