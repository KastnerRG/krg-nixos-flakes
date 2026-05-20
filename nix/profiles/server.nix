# Fabricant-style server profile: web services, monitoring, reverse proxy.
# Import this in a host's default.nix, then add host-specific compose stacks.
{ ... }: {
  imports = [
    ./base.nix
    ../modules/docker.nix
    ../modules/users.nix
    ../modules/services/compose-stack.nix
    ../modules/services/ipmi-exporter.nix
    ../users/admin.nix
    # Human users come from Samba AD; only the local break-glass admin stays.
  ];

  krg.base = {
    enable      = true;
    autoUpgrade = true;
  };

  krg.docker = {
    enable           = true;
    enableLokiDriver = true;
  };

  # krg.nodeExporter.enable is set by base.nix (true on every host).
  krg.ipmiExporter.enable = true;

  # Qualys + Trellix are enabled for all machines in base.nix.
  # Provide the installer archive in the host config:
  #   krg.oecQualysTrellix.installerArchive = /path/to/oec-qualys-trellix.tar.gz;

  # Ingress ports for the server role. These apply when the NixOS firewall is
  # enabled (physical hosts); on VMs base.nix disables it and the equivalent
  # rules must be opened in the Proxmox firewall instead.
  krg.firewall = {
    # fabricant UFW: SSH + 80 + 443 + 8080 open globally
    allowedTCPPorts = [ 22 80 443 8080 ];
    # fabricant UFW: node-exporter (9100) and ads-exporter (9000) from monitoring host only
    monitoringPorts = [ 9100 9000 ];
  };
}
