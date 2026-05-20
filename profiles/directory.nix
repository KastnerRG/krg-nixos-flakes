# Directory-services profile: Samba Active Directory domain controller (LDAP/Kerberos/DNS).
# Import this in a host's default.nix, then add host-specific networking.
{ ... }: {
  imports = [
    ../modules/base.nix
    ../modules/users.nix
    ../modules/security/firewall.nix
    ../users/admin.nix
    # ../modules/samba-ad.nix   # Layer 2: enable once the Samba AD DC module exists
  ];

  krg.base = {
    enable      = true;
    autoUpgrade = true;
  };

  krg.firewall = {
    enable = true;
    # SSH only for now. The Samba AD DC port set (53, 88, 135, 137-139, 389,
    # 445, 464, 636, 3268-3269 + dynamic RPC, TCP and UDP) is added together
    # with the samba-ad module in Layer 2.
    allowedTCPPorts = [ 22 ];
  };
}
