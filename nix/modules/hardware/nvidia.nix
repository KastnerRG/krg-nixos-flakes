{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.nvidia;
in {
  imports = [ ../services/compose-stack.nix ];

  options.krg.nvidia = {
    enable = mkEnableOption "NVIDIA CUDA + container toolkit (waiter compute nodes)";

    # Matches waiter: NVreg_DeviceFileGID=65533
    cudaGroupGid = mkOption {
      type    = types.int;
      default = 65533;
    };

    # true = nvidia-driver-580-open equivalent (open kernel module)
    openDriver = mkOption {
      type    = types.bool;
      default = true;
    };

    # DCGM GPU-metrics exporter, coupled to the driver: no reason to run GPUs without
    # GPU monitoring, so it's on whenever the driver is. Vendor container needing the
    # nvidia runtime → runs as a Docker compose stack (repo rule: native systemd for
    # what NixOS modules cover, Docker for the rest). Scraped on 9400 by Prometheus.
    dcgmExporter.enable = mkOption {
      type    = types.bool;
      default = true;
    };
  };

  config = mkIf cfg.enable {
    services.xserver.videoDrivers = [ "nvidia" ];

    hardware.nvidia = {
      modesetting.enable = true;
      open               = cfg.openDriver;
      nvidiaSettings     = true;
      package            = config.boot.kernelPackages.nvidiaPackages.stable;
    };

    # Replaces nvidia-container-toolkit_ubuntu.yaml (apt install)
    hardware.nvidia-container-toolkit.enable = true;

    hardware.graphics = {
      enable        = true;
      enable32Bit   = true;
    };

    # Fixed GID matching waiter NVreg_DeviceFileGID kernel param
    users.groups.cuda.gid = cfg.cudaGroupGid;

    # Match waiter cuda playbook: NVreg_DeviceFileGID + NVreg_DeviceFileMode=0770
    boot.kernelParams = [
      "nvidia.NVreg_DeviceFileGID=${toString cfg.cudaGroupGid}"
      "nvidia.NVreg_DeviceFileMode=0770"
    ];

    environment.systemPackages = with pkgs; [
      cudaPackages.cudatoolkit
    ];

    # GPU-metrics exporter (Docker compose stack), coupled to the driver above.
    krg.composeStacks.dcgm-exporter = mkIf cfg.dcgmExporter.enable {
      description  = "NVIDIA DCGM GPU metrics exporter";
      composeFiles = [ "${../../docker-compose/dcgm-exporter}/compose.yml" ];
      networks     = [];
    };

    # Intent: expose the exporter to the Prometheus scraping host only (merges with
    # profile ports). CAVEAT: dcgm is a Docker container publish, and Docker DNATs
    # published ports past krg.firewall's nftables INPUT rules — so this line does
    # NOT actually source-restrict 9400. The dcgm compose binds 0.0.0.0:9400, which
    # on a public-IP box (waiter) is reachable from anywhere. Real enforcement needs
    # a DOCKER-USER/nftables FORWARD rule (CLAUDE.md pending). Kept here so the intent
    # is recorded and so it works if dcgm ever moves to a native (non-Docker) exporter.
    krg.firewall.monitoringPorts = mkIf cfg.dcgmExporter.enable [ 9400 ];
  };
}
