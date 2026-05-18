# Waiter-style compute profile: GPU/CUDA, FPGA tools, XRDP desktop, research users.
# Import this in a host's default.nix, then add host-specific compose stacks and users.
{ pkgs, ... }: {
  imports = [
    ../modules/base.nix
    ../modules/docker.nix
    ../modules/users.nix
    ../modules/zfs.nix
    ../modules/security/fail2ban.nix
    ../modules/security/firewall.nix
    ../modules/security/oec-qualys-trellix.nix
    ../modules/services/compose-stack.nix
    ../modules/services/node-exporter.nix
    ../modules/services/ipmi-exporter.nix
    ../modules/hardware/nvidia.nix
    ../modules/hardware/fpga.nix
    ../modules/desktop/xrdp.nix
    ../modules/nix-ld.nix
    ../users/waiter-users.nix
  ];

  krg.base = {
    enable      = true;
    autoUpgrade = true;
  };

  krg.docker = {
    enable              = true;
    enableNvidiaRuntime = true;
  };

  krg.zfs = {
    enable       = true;
    autoScrub    = true;
    autoSnapshot.enable = true;
  };

  krg.fail2ban.enable = true;

  krg.nvidia = {
    enable     = true;
    openDriver = true;
  };

  krg.fpga.enable = true;
  krg.xrdp.enable = true;

  # Native IPMI exporter systemd service (from waiter monitoring.yaml)
  krg.ipmiExporter.enable = true;

  # Node exporter also runs natively for the xrdp collector
  # (the waiter compose also has node_exporter in Docker — both can coexist
  # by binding to different addresses or using the compose version only)
  krg.nodeExporter.enable = false;

  # Qualys + Trellix: set installerArchive in the host config.
  # e.g.: krg.oecQualysTrellix.installerArchive = /path/to/oec-qualys-trellix.tar.gz;
  krg.oecQualysTrellix.enable = true;

  krg.users.defaultGroups = [ "docker" "cuda" "rdp_users" ];

  krg.firewall = {
    enable          = true;
    allowedTCPPorts = [ 22 ];
    allowRDP        = true;
    # waiter UFW: node-exporter (9100), docker metrics (9323), prometheus client (9000),
    # IPMI exporter (9290) — 9290 was missing from original UFW but prometheus.yml scrapes it
    monitoringPorts = [ 9100 9290 9323 9000 ];
  };

  # nix-ld allows running conda, MATLAB, and other dynamically-linked binaries
  # not built for NixOS. Essential for a research workstation.
  krg.nixLd.enable = true;

  # Enable Zsh system-wide (waiter playbook modified /etc/zsh/zshrc for Nix)
  programs.zsh.enable = true;

  environment.systemPackages = [ pkgs.nodejs_22 ];
}
