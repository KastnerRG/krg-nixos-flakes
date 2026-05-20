{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.base;
in {
  imports = [ ./security/oec-qualys-trellix.nix ];

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
      default     = "github:KastnerRG/krg-nixos-flakes";
      description = "Flake URL used for auto-upgrades";
    };
  };

  config = mkIf cfg.enable {
    time.timeZone = cfg.timezone;

    i18n.defaultLocale = "en_US.UTF-8";

    # SSH hardening (replaces Ansible SSH hardening task): key-only auth,
    # and only ed25519 public keys are accepted — RSA/ECDSA are rejected.
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication        = false;
        KbdInteractiveAuthentication  = false;
        PermitRootLogin               = "no";
        X11Forwarding                 = false;
        # Restrict pubkey auth to ed25519 only (rejects ssh-rsa/rsa-sha2-*).
        PubkeyAcceptedAlgorithms =
          "ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,sk-ssh-ed25519@openssh.com,sk-ssh-ed25519-cert-v01@openssh.com";
      };
    };

    # Campus-mandated endpoint security on EVERY machine: Qualys Cloud Agent
    # (vulnerability management) + Trellix HX (EDR/anti-malware). The agents are
    # proprietary and install from a vendor archive — set
    # krg.oecQualysTrellix.installerArchive per host or they stay dormant.
    krg.oecQualysTrellix.enable = true;

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
    ];
  };
}
