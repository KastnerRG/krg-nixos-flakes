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
    serviceHost = true;   # restrict in-guest SSH to trusted UCSD nets
  };

  # Ingress for the directory role. The in-guest firewall is ON (base.nix runs it
  # on every host); modules/samba-ad.nix contributes the AD DC port set. SSH (22)
  # is source-restricted to the trusted UCSD nets in-guest (serviceHost), and the
  # Proxmox perimeter (ansible proxmox_firewall → 100.fw) source-restricts the AD
  # ports from there.
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
