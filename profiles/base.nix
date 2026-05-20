{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.base;
in {
  imports = [
    ../modules/security/oec-qualys-trellix.nix
    ../modules/security/fail2ban.nix
    ../modules/security/firewall.nix
    ../modules/services/node-exporter.nix
  ];

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

    isVM = mkOption {
      type        = types.bool;
      default     = false;
      description = ''
        Whether this host is a virtual machine. On VMs the hypervisor (Proxmox)
        owns the firewall, so the NixOS firewall is left disabled; physical
        hosts run krg.firewall (nftables) instead.
      '';
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

    # Prometheus node exporter on every machine (native systemd service).
    # Hosts that run node_exporter another way override this — e.g. waiter's
    # Docker monitoring stack binds 9100 on the host network, so compute.nix
    # sets krg.nodeExporter.enable = false to avoid a port clash.
    krg.nodeExporter.enable = mkDefault true;

    # Fail2ban SSH brute-force protection on every machine.
    krg.fail2ban.enable = mkDefault true;

    # Physical hosts run the NixOS firewall (krg.firewall → nftables); VMs leave
    # it disabled because the hypervisor (Proxmox) owns the firewall.
    krg.firewall.enable = mkDefault (!cfg.isVM);

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
      tmux
    ];
  };
}
