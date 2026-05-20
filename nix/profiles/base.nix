# CROSS-REFERENCE: the OS baseline here (timezone, packages incl tmux, SSH
# hardening, auto-updates, sysctl, fail2ban, firewall) has a Proxmox/Debian
# counterpart under ansible/roles/ (base, ssh_hardening, fail2ban, krg_admin).
# When you change the baseline on either side, apply the equivalent to the other.
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.base;
  # Shared trusted-network data — single source of truth, also consumed by the
  # Ansible layer (cluster.fw IPSets + group_vars). Edit nix/networks/trusted.json.
  trusted = builtins.fromJSON (builtins.readFile ../networks/trusted.json);
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
      # The flake lives in the nix/ subtree of the krg-infra monorepo.
      default     = "github:KastnerRG/krg-infra?dir=nix";
      description = "Flake URL used for auto-upgrades";
    };

    isVM = mkOption {
      type        = types.bool;
      default     = false;
      description = ''
        Whether this host is a Proxmox/QEMU virtual machine. Enables the QEMU
        guest agent (graceful shutdown, IP reporting to the hypervisor). It does
        NOT disable the NixOS firewall — the in-guest firewall stays on for
        defense-in-depth and so fail2ban has a backend (Proxmox adds an
        additive perimeter layer on top, it does not replace the guest firewall).
      '';
    };

    serviceHost = mkOption {
      type        = types.bool;
      default     = false;
      description = ''
        Service host (vs compute): restrict in-guest SSH to the trusted UCSD nets
        (mirrors the Proxmox perimeter). Compute hosts leave this false so lab
        users can SSH from anywhere (protected by key-only auth + fail2ban).
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
      # Service hosts source-restrict SSH via krg.firewall.sshSources, so don't
      # let openssh open port 22 globally; compute hosts keep it open.
      openFirewall = !cfg.serviceHost;
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

    # In-guest firewall (krg.firewall → nftables) on EVERY host, VMs included.
    # Defense-in-depth: this owns *which ports* a service exposes and gives
    # fail2ban a backend to insert bans into (the dictionary attack that drove
    # this rebuild is exactly what fail2ban mitigates). On Proxmox VMs the
    # hypervisor firewall is an *additive* perimeter that owns *which sources*
    # may reach the VM — it does not replace this layer. A host can still set
    # krg.firewall.enable = false explicitly if it really must.
    krg.firewall.enable = mkDefault true;

    # Prometheus scrape source — sourced from the shared trusted-networks file
    # so the monitoring host isn't duplicated across nix / ansible / PVE.
    krg.firewall.monitoringSourceIp = mkDefault trusted.monitoring_host;

    # Service hosts restrict in-guest SSH to the trusted nets (mirrors the Proxmox
    # perimeter); compute hosts keep SSH open (key-only auth + fail2ban).
    krg.firewall.sshSources = mkIf cfg.serviceHost (map (e: e.cidr) trusted.ipsets.ucsd);

    # QEMU guest agent on VMs (graceful shutdown + IP reporting to Proxmox).
    services.qemuGuest.enable = mkDefault cfg.isVM;

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
