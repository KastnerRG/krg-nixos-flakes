{ ... }:
{
  imports = [
    ../../profiles/directory.nix
    ./hardware-configuration.nix
  ];

  # Baseline admin account for this machine (krg-admin is the default).
  krg.adminAccount = "krg-admin";

  # Proxmox VM — the hypervisor owns the firewall, so base.nix leaves the
  # NixOS firewall disabled.
  krg.base.isVM = true;

  # Proxmox/QEMU VM — bootloader carried over from the installer config.
  boot.loader.grub = {
    enable      = true;
    device      = "/dev/sda";
    useOSProber = true;
  };

  networking = {
    hostName = "krg-ldap";
    useDHCP  = false;
    interfaces.ens18.ipv4.addresses = [{
      address      = "137.110.161.109";
      prefixLength = 24;
    }];
    defaultGateway = "137.110.161.1";
    # External resolvers for now; becomes 127.0.0.1 once the DC runs its own DNS.
    nameservers = [ "1.1.1.1" "8.8.8.8" ];
  };

  system.stateVersion = "25.11";
}
