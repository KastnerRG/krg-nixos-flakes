# Server profile: web services, monitoring, reverse proxy (krg-prod, e4e-prod).
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
    serviceHost = true;   # restrict in-guest SSH to trusted UCSD nets
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

  # Ingress for the server role. The in-guest firewall is ON on every host
  # (base.nix); serviceHost = true (set in krg.base above) source-restricts SSH
  # to the trusted UCSD nets in-guest, and the Proxmox perimeter restricts the rest.
  krg.firewall = {
    # 80/443/8080 open globally; SSH (22) is source-restricted (serviceHost), so
    # the firewall module moves it from the open list to a per-source rule.
    allowedTCPPorts = [ 22 80 443 8080 ];
    # node-exporter (9100) + service exporter (9000) from the monitoring host only
    monitoringPorts = [ 9100 9000 ];
  };
}
