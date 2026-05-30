# Server profile: web services, monitoring, reverse proxy (krg-prod, e4e-prod).
# Import this in a host's default.nix, then add host-specific compose stacks.
{ config, lib, ... }: {
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
    enable = true;
  };

  # krg.nodeExporter.enable is set by base.nix (true on every host).
  #
  # IPMI exporter only on PHYSICAL hosts. The current server hosts (krg-prod,
  # e4e-prod) are Proxmox VMs with no BMC, so the exporter would just error with
  # nothing to read — and 9290 isn't opened to the scraper here anyway. RESTORE:
  # this auto-enables if a physical server-profile host is ever added (then also
  # add 9290 to monitoringPorts below). The hypervisors' real BMCs are monitored
  # by the Ansible `monitoring` role, not from inside a guest.
  krg.ipmiExporter.enable = lib.mkDefault (!config.krg.base.isVM);

  # Qualys + Trellix are enabled for all machines in base.nix.
  # Provide the installer archive in the host config:
  #   krg.oecQualysTrellix.installerArchive = /path/to/oec-qualys-trellix.tar.gz;

  # Ingress for the server role. The in-guest firewall is ON on every host
  # (base.nix); serviceHost = true (inherited from base.nix default)
  # source-restricts SSH (22) to ucsd + ops via sshSources; the Proxmox
  # perimeter is the additive outer layer.
  krg.firewall = {
    # 80/443: Traefik ingress. The fleet-default geoIP gate (base.nix)
    # routes these to US+trusted — Authentik-gated lab web is reachable
    # from US clients without an `ops` entry; international travelers
    # add themselves to `ops` per docs/working-remotely.md (same workflow
    # as compute SSH). If a service genuinely needs global reach (rare),
    # move those ports to `krg.firewall.publicPorts` with a reason comment.
    # 22 comes from base.nix's default (allowedTCPPorts = [22]) and is
    # restricted by sshSources via serviceHost.
    allowedTCPPorts = [ 22 80 443 ];
    # Native node-exporter (9100), scraped from the monitoring host only. (The old
    # 9000 "service exporter" was the Ansible deploy-monitor, gone under autoUpgrade.)
    monitoringPorts = [ 9100 ];
  };
}
