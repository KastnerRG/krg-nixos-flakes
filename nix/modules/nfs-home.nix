# /home from NFS — give AD users a home that lives OFF the host's local disk.
#
# WHY: SSSD's fallback_homedir=/home/%u + pam_mkhomedir (modules/sssd-ad-client.nix)
# create a home on first login. If /home sits on the local ZFS root, an impermanent
# host (krg.impermanence) would wipe every home on each boot — which is why waiter
# kept impermanence OFF. Mounting /home from NFS moves homes off the root, the
# prerequisite for turning impermanence back on. uid/gid are deterministic across
# the fleet (AD algorithmic ID mapping), so a plain sec=sys NFSv4 mount lines up
# without idmapd translation (the client uses numeric ids for AUTH_SYS by default;
# if owners ever show as `nobody`, set the idmapd Domain to krg.local on both ends).
#
# SERVER: fabricant exports this via the ansible nfs_server role (rpool/nfs/home ->
# /srv/nfs/home over NFSv4, no_root_squash so the client's pam_mkhomedir can create
# and chown each user's home).
#
# GOTCHA — local accounts under /home. This mount SHADOWS whatever already sits at
# the mountpoint. The break-glass admin must NOT keep its home here (users/admin.nix
# pins it to /var/lib/<account>), or it would depend on the NFS server being up —
# defeating the point of a break-glass account.
{ config, lib, ... }:
with lib;
let
  cfg = config.krg.nfsHome;
in {
  options.krg.nfsHome = {
    enable = mkEnableOption "mount /home from an NFS server (AD user homes)";

    server = mkOption {
      type    = types.str;
      example = "137.110.161.10";
      description = ''
        NFS server address. Prefer the IP for this foundational mount so it doesn't
        depend on DNS at mount time (DNS itself may run on a VM on the very
        hypervisor that serves NFS).
      '';
    };

    export = mkOption {
      type    = types.str;
      default = "/srv/nfs/home";
      description = "Server-side export path (fabricant nfs_server serves rpool/nfs/home here).";
    };

    mountPoint = mkOption {
      type    = types.str;
      default = "/home";
    };

    nfsVersion = mkOption {
      type    = types.str;
      default = "4.2";
    };

    extraOptions = mkOption {
      type    = types.listOf types.str;
      default = [];
      description = "Extra mount options appended to the defaults.";
    };
  };

  config = mkIf cfg.enable {
    fileSystems.${cfg.mountPoint} = {
      device = "${cfg.server}:${cfg.export}";
      fsType = "nfs";
      # automount: mount on first access, so a down server NEVER blocks boot (a
      # plain entry would hang the whole box waiting on /home). hard: no silent
      # data loss if the server blips. nconnect: parallel TCP for throughput.
      options = [
        "nfsvers=${cfg.nfsVersion}"
        "hard"
        "noatime"
        "nconnect=4"
        "_netdev"
        "x-systemd.automount"
        "x-systemd.mount-timeout=20s"
      ] ++ cfg.extraOptions;
    };
  };
}
