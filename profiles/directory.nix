# Directory-services profile: Samba Active Directory domain controller (LDAP/Kerberos/DNS).
# Import this in a host's default.nix, then add host-specific networking.
{ ... }: {
  imports = [
    ./base.nix
    ../modules/users.nix
    ../modules/samba-ad.nix
    ../users/admin.nix
  ];

  krg.base = {
    enable      = true;
    autoUpgrade = true;
  };

  # Ingress ports for the directory role. These apply when the NixOS firewall
  # is enabled (physical hosts); on VMs base.nix disables it (krg.base.isVM) and
  # the equivalent rules must be opened in the Proxmox firewall instead.
  # modules/samba-ad.nix contributes the Samba AD DC port set (53, 88, 135,
  # 137-139, 389, 445, 464, 636, 3268-3269 + dynamic RPC, TCP and UDP); those
  # declarations merge with the list below but are inert while the firewall is
  # disabled — krg-ldap is a VM, so Proxmox owns the firewall.
  krg.firewall = {
    allowedTCPPorts = [ 22 ];
    # node exporter (enabled in base.nix)
    monitoringPorts = [ 9100 ];
  };

  # AD domain controller role for KRG. Realm/workgroup match the new forest;
  # see the "One-time provisioning" notes in modules/samba-ad.nix before deploy.
  krg.sambaAD = {
    enable    = true;
    realm     = "KRG.LOCAL";
    workgroup = "KRG";
  };
}
