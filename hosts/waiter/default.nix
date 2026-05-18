{ ... }:
let
  composeDir = ../../docker-compose/waiter;
in {
  imports = [
    ../../profiles/compute.nix
    ./hardware-configuration.nix
  ];

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
    hostId = "00000000"; # REPLACE with a real unique 8-hex-char ID
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

  # Installer is gitignored; only wired up when the file is present in the flake source.
  # Locally: git add -f oec-qualystrellixinstallers-linux.tgz before building.
  # CI: evaluates to null (safe — activation script is skipped).
  krg.oecQualysTrellix.installerArchive =
    let archive = ../../oec-qualystrellixinstallers-linux.tgz;
    in if builtins.pathExists archive then archive else null;

  # TODO: Secrets — before starting waiter-monitoring stack, populate:
  #   /var/lib/krg/waiter/.secrets/gf_admin_password.txt
}
