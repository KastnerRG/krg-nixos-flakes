{ ... }:
{
  imports = [
    ../../profiles/server.nix
    ./hardware-configuration.nix
  ];

  # E4E (Engineers for Exploration) production host — project-specific and
  # project-developed services (e.g. FishSense). Lab-wide tools live on krg-prod;
  # this host starts empty because none of the current services are project-specific.
  krg.adminAccount = "e4e-admin";

  # Proxmox VM — the hypervisor owns the firewall (base.nix leaves the NixOS
  # firewall disabled). Open ingress ports in the Proxmox firewall.
  krg.base.isVM = true;

  networking = {
    hostName = "e4e-prod";
    domain   = "ucsd.edu";
  };

  # E4E project services attach here as krg.composeStacks.<name> once defined,
  # following the krg-prod pattern (compose dir under nix/docker-compose/e4e-prod/,
  # working dir /var/lib/krg/e4e-prod). SSO can federate to krg-prod's Authentik.
}
