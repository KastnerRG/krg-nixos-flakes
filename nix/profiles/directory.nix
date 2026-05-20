# Directory-services profile: Samba Active Directory domain controller (LDAP/Kerberos/DNS).
# Import this in a host's default.nix, then add host-specific networking.
{ ... }: {
  imports = [
    ./base.nix
    ../modules/users.nix
    ../modules/samba-ad.nix
    ../modules/sssd-ad-client.nix
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

  # Log into this host with AD accounts (SSSD). It's the directory server, so
  # restrict SSH to Domain Admins — lab users get AD login on member hosts, not
  # the DC. SSH stays key-only (base.nix); see the runtime prerequisites at the
  # top of modules/sssd-ad-client.nix (keytab export, POSIX attrs, key planting).
  krg.adClient = {
    enable        = true;
    realm         = "KRG.LOCAL";
    domain        = "krg.local";
    server        = "krg-ldap.krg.local";   # the DC is this host itself
    allowedGroups = [ "Domain Admins" ];
    # Pull SSH keys from AD (sss_ssh_authorizedkeys) instead of ~/.ssh. Needs the
    # one-time OpenSSH-LPK schema extension (sshPublicKey attribute) on the DC and
    # the key stored on each user object — see modules/sssd-ad-client.nix.
    sshKeysFromAD = true;
  };
}
