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
    # 443: Traefik ingress for Authentik-gated lab services. Globally
    # reachable at the firewall layer; what filters attackers behind it
    # in THIS PR is the CrowdSec community blocklist (CAPI) — ~30K-50K
    # known-malicious IPs dropped by the bouncer regardless of
    # destination port. NO Traefik-specific scenario is enabled here
    # (the fleet baseline only acquires sshd logs); brute-force
    # protection against Authentik itself depends on Authentik's own
    # rate-limiting until we add the `crowdsecurity/traefik` collection +
    # a Traefik access-log acquisition. Tracked as a follow-up.
    # 22 comes from base.nix's default and is restricted by sshSources
    # via serviceHost.
    allowedTCPPorts = [ 22 443 ];
    # 80: DOCUMENTED EXCEPTION to the "US is the floor" policy. Traefik
    # handles ACME HTTP-01 on this port for the lab's public-facing
    # domains. Let's Encrypt's multi-perspective validation issues
    # challenges from validators in US + EU + Asia with unpredictable
    # source IPs and requires ALL perspectives to succeed; ANY source
    # restriction (geo allowlist, accidental community-blocklist hit)
    # would risk failing renewals within ~60-90 days (cert lifetime).
    # Mirrors the krg-vault publicPorts pattern. DNS-01 migration was
    # considered + rejected (closed issue #89); HTTP-01 + publicPorts
    # opt-in is the long-term answer.
    # reason: ACME HTTP-01 — LE multi-perspective validators are global
    publicPorts = [ 80 ];
    # Native node-exporter (9100), scraped from the monitoring host only. (The old
    # 9000 "service exporter" was the Ansible deploy-monitor, gone under autoUpgrade.)
    monitoringPorts = [ 9100 ];
  };
}
