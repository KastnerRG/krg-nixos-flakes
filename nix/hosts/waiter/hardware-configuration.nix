# waiter — hardware bits ONLY. Everything storage-related is owned elsewhere:
#   - partitions / pools / datasets / fileSystems  -> disko-config.nix (disko
#     generates config.fileSystems for /, /nix, /persist, /tools, /boot)
#   - ZFS knobs (devNodes, supportedFilesystems, hostId-consuming bits) -> modules/zfs.nix
#   - rollback + persistence                       -> modules/impermanence.nix
#
# GOTCHA — regenerating this file. When you run
#   nixos-generate-config --show-hardware-config
# on the real waiter, copy in ONLY the hardware lines (boot.initrd.*KernelModules,
# microcode, max-jobs). Do NOT paste the `fileSystems.*`, `swapDevices`, or
# `boot.loader.*` it emits: disko already declares the filesystems, swap is zram
# (see hosts/waiter/default.nix), and the bootloader is set below. Pasting them
# produces duplicate-definition conflicts.
{
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [(modulesPath + "/installer/scan/not-detected.nix")];

  # ---- bootloader: systemd-boot on the mirrored ESP ----
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # /boot is a RAID1 md device (see disko-config.nix). It is NOT needed in initrd
  # (firmware reads it pre-Linux; Linux mounts it in stage 2), but the mdadm
  # tooling/udev assembly must be present so the array comes up and systemd-boot
  # can write loader entries to it.
  boot.swraid.enable = true;
  # mdmon (md array monitor) crashes if mdadm.conf has no mail/program target.
  # Local root mail silences it; point MAILADDR at a real address once outbound
  # mail is wired up, so a degraded /boot mirror actually pages someone.
  boot.swraid.mdadmConf = "MAILADDR root";

  # ---- placeholders: replace with real `nixos-generate-config` output ----
  # These are reasonable defaults for an NVMe + SATA x86_64 server; the root pool
  # only needs `nvme` (+ zfs, pulled in by modules/zfs.nix) in initrd.
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [];
  boot.kernelModules = ["kvm-amd"]; # AMD Ryzen Threadripper PRO 7985WX (64C/128T)
  boot.extraModulePackages = [];

  # Microcode (generate-config sets this; harmless default until then).
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.amd.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;

  # No disk swap — swap is zram (hosts/waiter/default.nix). Kept explicit so a
  # stray generate-config swapDevices paste stands out as a conflict.
  swapDevices = [];

  # 64C/128T box — raised for build throughput. `cores` stays at the default
  # (0 = a single build may use all threads), so big local builds run full-speed.
  # This is a multi-user compute host: if a nightly autoUpgrade rebuild ever
  # starves running jobs, bound per-build width with `nix.settings.cores`.
  nix.settings.max-jobs = 32;
}
