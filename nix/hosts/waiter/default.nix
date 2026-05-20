{ ... }:
let
  composeDir = ../../docker-compose/waiter;
in {
  imports = [
    ../../profiles/compute.nix
    ./hardware-configuration.nix
  ];

  # Physical host — keep the NixOS firewall enabled (this is the default).
  krg.base.isVM = false;

  networking = {
    hostName = "waiter";
    domain   = "ucsd.edu";

    # Static IP from waiter netplan/01-waiter.yml
    useDHCP  = false;
    interfaces.enp3s0f0 = {
      ipv4.addresses = [{ address = "132.239.95.67"; prefixLength = 24; }];
    };
    defaultGateway = "132.239.95.1";
    nameservers    = [ "132.239.0.252" "8.8.8.8" "1.1.1.1" ];

    # ZFS requires a unique hostId — generate with:
    #   python3 -c "import uuid; print(str(uuid.uuid4())[:8])"
    # and set it here.
    hostId = "34658941";
  };

  # Monitoring compose stack (node_exporter in Docker, dcgm_exporter, blackbox_exporter)
  # Secrets required in /var/lib/krg/waiter/.secrets/ before starting:
  #   gf_admin_password.txt
  krg.composeStacks.waiter-monitoring = {
    description      = "Waiter monitoring stack (node exporter, DCGM, blackbox)";
    composeFiles     = [ "${composeDir}/compose.yml" ];
    workingDirectory = "/var/lib/krg/waiter";
    networks         = [];
  };

  # Qualys/Trellix agents are enabled for all hosts in base.nix. The installer
  # archive is referenced by a runtime path (default
  # /var/lib/krg/oec/oec-qualystrellixinstallers-linux.tgz) so its embedded
  # credentials never enter the Nix store — place it there out-of-band:
  #   scp oec-qualystrellixinstallers-linux.tgz waiter:/var/lib/krg/oec/
  # then rebuild; the oec-install service enrolls the agents on next boot.

  # TODO: Secrets — before starting waiter-monitoring stack, populate:
  #   /var/lib/krg/waiter/.secrets/gf_admin_password.txt

  system.stateVersion = "25.11";
}
