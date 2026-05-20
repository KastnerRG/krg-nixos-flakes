# Replace this file with the output of:
#   nixos-generate-config --show-hardware-config
# Run on the waiter host after booting the NixOS installer.
#
# waiter is a physical machine with:
#   - Intel NIC: enp3s0f0 (static IP 132.239.95.67/24)
#   - NVIDIA GPUs (4x, /dev/nvidia0-3)
#   - ZFS root pool (replacing the btrfs layout from the Ubuntu install)
#
# IMPORTANT: ZFS requires a unique hostId. Generate one and set it in default.nix:
#   python3 -c "import uuid; print(str(uuid.uuid4())[:8])"
{ modulesPath, ... }: {
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.loader.systemd-boot.enable      = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ZFS pool layout — adjust pool name (rpool) and dataset names to match actual setup
  boot.zfs.requestEncryptionCredentials = true;

  fileSystems."/" = {
    device  = "rpool/root";
    fsType  = "zfs";
  };

  fileSystems."/home" = {
    device  = "rpool/home";
    fsType  = "zfs";
  };

  fileSystems."/var/lib/docker/volumes" = {
    device  = "rpool/docker";
    fsType  = "zfs";
  };

  fileSystems."/boot" = {
    device  = "/dev/disk/by-label/boot"; # adjust
    fsType  = "vfat";
  };

  swapDevices = [];

  nix.settings.max-jobs = 16;
}
