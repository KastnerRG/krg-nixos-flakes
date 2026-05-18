{ config, lib, ... }:
with lib;
let
  cfg = config.krg.zfs;
in {
  options.krg.zfs = {
    enable = mkEnableOption "ZFS filesystem support with auto-scrub and auto-snapshot";

    autoScrub = mkOption {
      type    = types.bool;
      default = true;
    };

    autoScrubInterval = mkOption {
      type    = types.str;
      default = "weekly";
    };

    autoSnapshot = {
      enable = mkOption { type = types.bool; default = true; };
      # Retention counts — mirrors snapper-style policy
      frequent = mkOption { type = types.int; default = 4;  description = "15-minute snapshots to keep"; };
      hourly   = mkOption { type = types.int; default = 168; description = "1 week of hourly snapshots"; };
      daily    = mkOption { type = types.int; default = 14;  description = "2 weeks of daily snapshots"; };
      weekly   = mkOption { type = types.int; default = 16;  description = "4 months of weekly snapshots"; };
      monthly  = mkOption { type = types.int; default = 12;  description = "1 year of monthly snapshots"; };
    };
  };

  config = mkIf cfg.enable {
    boot.supportedFilesystems = [ "zfs" ];

    # ZFS requires a unique 8-hex-char hostId. Set this in hardware-configuration.nix:
    #   networking.hostId = "$(head -c4 /dev/urandom | od -A none -t x4 | tr -d ' ')";
    # or generate once with: python3 -c "import uuid; print(str(uuid.uuid4())[:8])"

    services.zfs.autoScrub = {
      enable   = cfg.autoScrub;
      interval = cfg.autoScrubInterval;
    };

    services.zfs.autoSnapshot = {
      enable   = cfg.autoSnapshot.enable;
      frequent = cfg.autoSnapshot.frequent;
      hourly   = cfg.autoSnapshot.hourly;
      daily    = cfg.autoSnapshot.daily;
      weekly   = cfg.autoSnapshot.weekly;
      monthly  = cfg.autoSnapshot.monthly;
    };

    # Trim SSD-backed pools weekly (safe no-op on HDDs)
    services.zfs.trim.enable = true;
  };
}
