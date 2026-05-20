# Waiter-style compute profile: GPU/CUDA, FPGA tools, XRDP desktop, research users.
# Import this in a host's default.nix, then add host-specific compose stacks and users.
{ ... }: {
  imports = [
    ./base.nix
    ../modules/docker.nix
    ../modules/users.nix
    ../modules/zfs.nix
    ../modules/services/compose-stack.nix
    ../modules/services/ipmi-exporter.nix
    ../modules/hardware/nvidia.nix
    ../modules/hardware/fpga.nix
    ../modules/desktop/xrdp.nix
    ../modules/nix-ld.nix
    ../users/admin.nix
    # Lab users come from Samba AD; only the local break-glass admin stays.
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

  # krg.fail2ban.enable is set by base.nix (true on every host).

  krg.nvidia = {
    enable     = true;
    openDriver = true;
  };

  krg.fpga.enable = true;
  krg.xrdp.enable = true;

  # Native IPMI exporter systemd service (from waiter monitoring.yaml)
  krg.ipmiExporter.enable = true;

  # Override base.nix's default-on node exporter: waiter runs node_exporter in
  # its Docker monitoring stack (network_mode: host, binds 9100), so the native
  # systemd exporter would clash on the same port.
  krg.nodeExporter.enable = false;

  # Qualys + Trellix are enabled for all machines in base.nix.
  # The installer archive is wired up in hosts/waiter/default.nix.

  krg.users.defaultGroups = [ "docker" "cuda" "rdp_users" ];

  # waiter is physical, so base.nix keeps the NixOS firewall enabled.
  krg.firewall = {
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
}
