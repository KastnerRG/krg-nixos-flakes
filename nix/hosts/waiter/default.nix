{ inputs, ... }: {
  imports = [
    ../../profiles/compute.nix
    ./hardware-configuration.nix

    # Declarative disk layout (disko) + impermanent ZFS root.
    inputs.disko.nixosModules.disko
    ./disko-config.nix
    ../../modules/impermanence.nix
    ../../modules/nfs-home.nix
    ../../modules/scratch.nix
  ];

  # Physical host — keep the NixOS firewall enabled (this is the default).
  krg.base.isVM = false;

  # Impermanent ZFS root (erase-your-darlings): / is rolled back to nvmepool/root@blank
  # in initrd every boot; durable state is bind-mounted back from /persist
  # (modules/impermanence.nix). Enabling this also flips the host to systemd initrd
  # (the rollback runs as a stage-1 unit). VALIDATED on-box across two reboots 2026-05-21.
  #
  # Two fixes had to land before this was safe (both now in tree):
  #  - /home is on NFS and the mount is NON-BLOCKING (krg.nfsHome below — plain nofail,
  #    NOT x-systemd.automount, which wedged early boot). This moves user homes OFF the
  #    rolled-back root so they aren't wiped each boot.
  #  - the rolled-back root is empty, and systemd 258's PID1 FREEZES on an empty /usr
  #    ("Refusing to run ... /usr/ is not populated"); modules/impermanence.nix reseeds
  #    /usr/bin/env in initrd before switch-root so it boots (see that module + the
  #    disko-config.nix @blank note).
  #
  # GOTCHA when (re)enabling on a running or freshly-installed host: migrate live state
  # into /persist BEFORE the first rollback (keytab, ssh host keys, /etc/machine-id,
  # /var/lib/{nixos,sss,krg}; break-glass admin home /var/lib/<account> is in the list),
  # or the first boot wipes it. Deploy with `nixos-rebuild boot` (NOT switch — switch
  # fails on persist-files "file already exists"). /nix, /persist, /tools and
  # /var/lib/docker are separate datasets, off the rolled-back root.
  krg.impermanence.enable = true;

  # AD user homes come from NFS (fabricant: rpool/nfs/home -> /srv/nfs/home). This
  # moves /home OFF waiter's local ZFS root — the prerequisite for impermanence above.
  # Break-glass krg-admin is unaffected: its home is /var/lib/krg-admin (users/admin.nix),
  # which impermanence persists (modules/impermanence.nix). Server pinned by IP so /home
  # never waits on DNS. The mount is a PLAIN nofail NFS mount (NOT an automount — autofs
  # wedged early boot; see modules/nfs-home.nix), ordered after the network: the box
  # always boots, and if fabricant is down at boot /home is simply left UNMOUNTED (it
  # does NOT mount on later access — a remount or reboot is needed once the server is back).
  #
  # KNOWN TRADE-OFF (impermanence + nofail /home): if /home is unmounted at login time,
  # pam_mkhomedir (krg.adClient) creates an ephemeral home on the rolled-back root that
  # is WIPED on the next reboot — a data-loss window absent from the old persistent root.
  # fabricant being down at boot is already a major incident (it also hosts the AD DC, so
  # only SSSD-cached logins would even succeed), but gating AD logins on the /home mount
  # to close that window is a tracked follow-up (see CLAUDE.md pending items).
  krg.nfsHome = {
    enable = true;
    server = "137.110.161.98";   # fabricant (the hypervisor serving rpool/nfs)
  };

  # hddpool's datasets are all mountpoint=none with no fileSystems entry, so nothing
  # else triggers its import at boot — list it explicitly. (nvmepool is imported
  # because / lives on it.) NOTE: krg.scratch below now mounts hddpool/scratch-krg,
  # so a fileSystems entry references hddpool too — but keep this for the e4e
  # datasets, which remain unmounted scaffolding.
  krg.zfs.extraPools = [ "hddpool" ];

  # Tiered /scratch for the krg lab (autotier FUSE, modules/scratch.nix): one merged
  # /scratch/krg over hot NVMe -> warm HDD -> cold NFS on fabricant. autotier demotes
  # cold files down and promotes hot ones back automatically (daily pass).
  #
  # LAB ISOLATION: krg and e4e are INDEPENDENT labs sharing this box, so the tree is
  # owned by the "Kastner Research Group" AD group, mode 2770 (allow_other +
  # default_permissions enforce it through FUSE). The group must exist in Samba AD;
  # until the per-host domain join + group creation land, the perms step is tolerant
  # (tier roots stay root-owned/admin-only, then tighten on the next start).
  #
  # E4E IS NOT WIRED: no e4e users/machines yet, so its scratch-e4e datasets stay
  # mountpoint=none (disko) reserved scaffolding. e4e will later get e4e-nas as BOTH
  # its cold tier and its NFS homes (separate work). Add a `projects.e4e` here then.
  #
  # COLD TIER: fabricant exports rpool/nfs/scratch-krg -> /srv/nfs/scratch-krg to
  # waiter with no_root_squash (ansible nfs_server), so autotier (root) preserves
  # each file's owner/group when demoting onto the network tier. If fabricant is down
  # the autotier unit fails CLOSED (RequiresMountsFor) — it will NOT demote onto the
  # impermanent root (cf. the modules/nfs-home.nix login gate). The two local tiers
  # are their own datasets, durable across the boot rollback regardless.
  krg.scratch = {
    enable = true;
    projects.krg = {
      ownerGroup = "Kastner Research Group";
      # Each krg lab member gets a private /scratch/krg/<user>, auto-created on login
      # (created only for Kastner-Research-Group members, only while /scratch/krg is
      # mounted). autotier still tiers the whole lab pool underneath.
      perUser.enable = true;
      tiers = [
        { id = "nvme"; label = "NVMe"; fsType = "zfs"; device = "nvmepool/scratch-krg"; quota = "85%"; }
        { id = "hdd";  label = "HDD";  fsType = "zfs"; device = "hddpool/scratch-krg";  quota = "90%"; }
        # Overflow / cold tier (Quota defaults to 100 %). fabricant hypervisor IP,
        # same server as krg.nfsHome — pinned by IP so it never waits on DNS.
        { id = "nfs";  label = "NFS (fabricant)"; fsType = "nfs"; device = "137.110.161.98:/srv/nfs/scratch-krg"; }
      ];
    };
  };

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
