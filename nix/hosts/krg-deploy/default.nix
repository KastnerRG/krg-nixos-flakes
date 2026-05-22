{ pkgs, ... }: {
  imports = [
    ../../profiles/base.nix
    ../../modules/users.nix
    ../../users/admin.nix
    ./hardware-configuration.nix
  ];

  krg.adminAccount = "krg-admin";

  # Proxmox VM — QEMU guest agent; in-guest firewall stays ON.
  krg.base = {
    enable      = true;
    autoUpgrade = true;
    serviceHost = true;   # restrict SSH to trusted UCSD nets in-guest
    isVM        = true;
  };

  krg.firewall = {
    allowedTCPPorts = [ 22 ];
    monitoringPorts = [ 9100 ];
  };

  networking = {
    hostName = "krg-deploy";
    domain   = "ucsd.edu";
    useDHCP  = false;
    interfaces.ens18.ipv4.addresses = [{
      address      = "137.110.161.122";
      prefixLength = 24;
    }];
    defaultGateway = "137.110.161.1";
    nameservers    = [ "132.239.0.252" "8.8.8.8" "1.1.1.1" ];
  };

  # Ansible control node + OpenTofu for infrastructure provisioning.
  environment.systemPackages = with pkgs; [
    ansible
    opentofu
    python3     # ansible runtime dependency
    sshpass     # needed by some ansible connection scenarios
    jq
  ];

  # Not yet domain-joined — disable AD client until keytab is provisioned.
  krg.adClient.enable = false;

  system.stateVersion = "25.11";
}
