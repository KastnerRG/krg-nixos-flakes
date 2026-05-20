{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.nvidia;
in {
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
  };
}
