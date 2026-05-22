{ ... }: {
  imports = [
    ../../profiles/base.nix
    ../../modules/users.nix
    ../../users/admin.nix
    ./hardware-configuration.nix
  ];

  krg.adminAccount = "krg-admin";

  krg.base = {
    enable      = true;
    autoUpgrade = true;
    serviceHost = true;
    isVM        = true;
  };

  networking = {
    hostName = "krg-vault";
    domain   = "ucsd.edu";
    useDHCP  = false;
    interfaces.ens18.ipv4.addresses = [{
      address      = "137.110.161.123";
      prefixLength = 24;
    }];
    defaultGateway = "137.110.161.1";
    nameservers    = [ "132.239.0.252" "8.8.8.8" "1.1.1.1" ];
  };

  # Not yet domain-joined — disable AD client until keytab is provisioned.
  krg.adClient.enable = false;

  krg.firewall = {
    allowedTCPPorts = [ 22 8200 ];  # 8200 = OpenBao API; Proxmox .fw restricts external access
    monitoringPorts = [ 9100 ];
  };

  services.openbao = {
    enable = true;
    settings = {
      ui = true;

      listener.default = {
        type        = "tcp";
        address     = "0.0.0.0:8200";
        tls_disable = true;  # TODO: enable TLS once DNS/cert is stable
      };

      storage.raft = {
        path    = "/var/lib/openbao";
        node_id = "krg-vault-1";
      };

      api_addr     = "http://krg-vault.ucsd.edu:8200";
      cluster_addr = "http://krg-vault.ucsd.edu:8201";
    };
  };

  system.stateVersion = "25.11";
}
