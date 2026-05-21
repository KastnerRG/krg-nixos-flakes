{ inputs, ... }: {
  imports = [
    ../../profiles/compute.nix
    ./hardware-configuration.nix

    # Declarative disk layout (disko) + impermanent ZFS root.
    inputs.disko.nixosModules.disko
    ./disko-config.nix
    ../../modules/impermanence.nix
  ];

  # Physical host — keep the NixOS firewall enabled (this is the default).
  krg.base.isVM = false;

  # Impermanent ZFS root: / would be rolled back to nvmepool/root@blank every boot;
  # durable state lives on /persist (modules/impermanence.nix). Enabling this also
  # flips the host to systemd initrd (the rollback runs as a stage-1 unit).
  #
  # DISABLED until NFS /home lands. waiter is multi-user and there is no /home
  # dataset yet — SSSD's fallback_homedir is /home/%u, which would sit on the
  # rolled-back root, so enabling impermanence now would WIPE every user's home
  # on each reboot. The disko layout already keeps /nix, /persist, /tools and the
  # dedicated /var/lib/docker dataset off the root, so with this off the box still
  # boots from a normal persistent root (no data loss) — we just don't get the
  # erase-your-darlings clean root yet.
  # RESTORE: once /home is on NFS (or its own non-rolled-back dataset), flip this
  # back to true and verify the @blank rollback + /persist bind mounts on a test
  # reboot. Tracked in CLAUDE.md pending items.
  krg.impermanence.enable = false;

  # hddpool's datasets are all mountpoint=none with no fileSystems entry, so nothing
  # else triggers its import at boot — list it explicitly. (nvmepool is imported
  # because / lives on it.)
  krg.zfs.extraPools = [ "hddpool" ];

  # Swap = zram (no on-disk swap; ZFS swap zvols are deadlock-prone under memory
  # pressure). zstd-compressed RAM cushion for OOM bursts. memoryPercent is a cap on
  # the zram device size, not a reservation. Interacts with the deferred earlyoom
  # change and the krg.zfs.arcMaxBytes ARC knob.
  zramSwap = {
    enable        = true;
    algorithm     = "zstd";
    memoryPercent = 50;
  };

  # FPGA/EDA toolchain (Vivado/Vitis/Questa/Verilator) stays OFF pending sign-off from
  # the other researchers. FPGA is opt-in in the compute profile now, so this is
  # explicit/deliberate — waiter IS the FPGA box, so flip to true once confirmed.
  # The /tools dataset is unaffected (modules/hardware/fpga.nix).
  krg.fpga.enable = false;

  # Login access: Domain Admins (infra admins — own-account login + sudo) PLUS the
  # "Waiter" AD group (this box's researchers). Overrides base.nix's Domain-Admins-only
  # default. Break-glass krg-admin (local) is unaffected. NOTE: the "Waiter" AD group
  # must exist and have members (AD-side, see docs/creating-a-user.md); it's matched
  # under CN=Users — use krg.adClient.accessFilter if it ever lives in a custom OU.
  krg.adClient.allowedGroups = [ "Domain Admins" "Waiter" ];

  networking = {
    hostName = "waiter";
    domain   = "ucsd.edu";

    # Static IP on the UCSD-facing onboard NIC. VERIFIED on the installed system
    # via `ip -br link`: name = eno1np0, MAC cc:28:aa:0a:58:fa. The `np0` suffix is
    # the netdev/phys-port of this multi-port onboard NIC (predictable naming) —
    # the earlier guesses enp3s0f0 and eno1 were BOTH wrong. Predictable names are
    # stable per hardware+driver, so this won't drift across reboots/rebuilds; only
    # a NIC swap or major driver change could rename it (then re-check, or pin by
    # MAC with a systemd .link rename).
    useDHCP  = false;
    interfaces.eno1np0 = {
      ipv4.addresses = [{ address = "137.110.161.67"; prefixLength = 24; }];
    };
    defaultGateway = "137.110.161.1";
    nameservers    = [ "132.239.0.252" "8.8.8.8" "1.1.1.1" ];

    # ZFS requires a unique hostId — generate with:
    #   python3 -c "import uuid; print(str(uuid.uuid4())[:8])"
    # and set it here.
    hostId = "34658941";
  };

  # Qualys/Trellix agents are enabled for all hosts in base.nix. The installer
  # archive is referenced by a runtime path (default
  # /var/lib/krg/oec/oec-qualystrellixinstallers-linux.tgz) so its embedded
  # credentials never enter the Nix store — place it there out-of-band:
  #   scp oec-qualystrellixinstallers-linux.tgz waiter:/var/lib/krg/oec/
  # then rebuild; the oec-install service enrolls the agents on next boot.

  system.stateVersion = "25.11";
}
