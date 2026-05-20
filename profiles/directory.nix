# Directory-services profile: Samba Active Directory domain controller (LDAP/Kerberos/DNS).
# Import this in a host's default.nix, then add host-specific networking.
{ ... }: {
  imports = [
    ./base.nix
    ../modules/users.nix
    ../users/admin.nix
    # ../modules/samba-ad.nix   # Layer 2: enable once the Samba AD DC module exists
  ];

  krg.base = {
    enable      = true;
    autoUpgrade = true;
  };

  # Ingress ports for the directory role. These apply when the NixOS firewall
  # is enabled (physical hosts); on VMs base.nix disables it and the equivalent
  # rules must be opened in the Proxmox firewall instead.
  # Layer 2 adds the Samba AD DC port set (53, 88, 135, 137-139, 389, 445, 464,
  # 636, 3268-3269 + dynamic RPC, TCP and UDP) alongside the samba-ad module.
  krg.firewall = {
    allowedTCPPorts = [ 22 ];
    # node exporter (enabled in base.nix)
    monitoringPorts = [ 9100 ];
  };
}
