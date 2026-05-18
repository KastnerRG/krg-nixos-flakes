# Fabricant-style server profile: web services, monitoring, reverse proxy.
# Import this in a host's default.nix, then add host-specific compose stacks.
{ ... }: {
  imports = [
    ../modules/base.nix
    ../modules/docker.nix
    ../modules/users.nix
    ../modules/security/firewall.nix
    ../modules/security/oec-qualys-trellix.nix
    ../modules/services/compose-stack.nix
    ../modules/services/node-exporter.nix
    ../modules/services/ipmi-exporter.nix
    ../users/fabricant-users.nix
  ];

  krg.base = {
    enable      = true;
    autoUpgrade = true;
  };

  krg.docker = {
    enable           = true;
    enableLokiDriver = true;
  };

  krg.nodeExporter.enable = true;
  krg.ipmiExporter.enable = true;

  # Qualys + Trellix: set installerArchive in the host config or environment.
  # e.g.: krg.oecQualysTrellix.installerArchive = /path/to/oec-qualys-trellix.tar.gz;
  krg.oecQualysTrellix.enable = true;

  krg.firewall = {
    enable          = true;
    # fabricant UFW: SSH + 80 + 443 + 8080 open globally
    allowedTCPPorts = [ 22 80 443 8080 ];
    # fabricant UFW: node-exporter (9100) and ads-exporter (9000) from monitoring host only
    monitoringPorts = [ 9100 9000 ];
  };
}
