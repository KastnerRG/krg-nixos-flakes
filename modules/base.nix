{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.base;
in {
  options.krg.base = {
    enable = mkEnableOption "KRG base system configuration";

    timezone = mkOption {
      type    = types.str;
      default = "America/Los_Angeles";
    };

    autoUpgrade = mkOption {
      type        = types.bool;
      default     = true;
      description = "Enable automatic flake-based system upgrades (replaces unattended-upgrades)";
    };

    flakeUrl = mkOption {
      type        = types.str;
      default     = "github:KastnerRG/KRG-NixOS-Flakes";
      description = "Flake URL used for auto-upgrades";
    };
  };

  config = mkIf cfg.enable {
    time.timeZone = cfg.timezone;

    i18n.defaultLocale = "en_US.UTF-8";

    # Disable password auth on SSH (replaces Ansible SSH hardening task)
    services.openssh = {
      enable   = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin        = "no";
        X11Forwarding          = false;
      };
    };

    # kernel.sysrq = 1 (from waiter sysctl.d/90-sysrq.conf)
    boot.kernel.sysctl."kernel.sysrq" = 1;

    # Replaces APT unattended-upgrades; pulls the flake and rebuilds
    system.autoUpgrade = mkIf cfg.autoUpgrade {
      enable      = true;
      allowReboot = false;
      flake       = cfg.flakeUrl;
      flags       = [ "--update-input" "nixpkgs" "--commit-lock-file" ];
      dates       = "04:00";
    };

    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store   = true;
    };

    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = with pkgs; [
      git
      git-lfs
      curl
      wget
      htop
      vim
      bitwarden-cli
    ];
  };
}
