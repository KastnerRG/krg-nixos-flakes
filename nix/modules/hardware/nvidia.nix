{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.nvidia;

  # Local accounts NixOS declares into the cuda group (e.g. the break-glass admin
  # via krg.users.defaultGroups). The cuda-group-sync below uses `gpasswd -M`, which
  # REPLACES the whole member list — so these must be re-included on every sync or
  # the AD bridge would silently drop them.
  declaredCudaMembers = unique (
    (attrNames (filterAttrs (_: u: elem "cuda" u.extraGroups) config.users.users))
    ++ config.users.groups.cuda.members);
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

    # AD groups bridged into the local `cuda` group so their members can open
    # /dev/nvidia* (root:cuda, mode 0770 — see cudaGroupGid below). This bridge
    # exists because SSSD algorithmic ID mapping derives an AD group's GID from
    # its SID, so a new AD group can never land on the fixed device GID (65533);
    # instead a boot+timer unit re-derives the local cuda group's members from
    # these AD groups (getent → gpasswd -M). Login (krg.adClient.allowedGroups)
    # gates who may SSH in; this gates who may touch the GPU. See cuda-group-sync.
    cudaAccessGroups = mkOption {
      type    = types.listOf types.str;
      default = [];
      example = [ "GPU Users" ];
      description = ''
        AD groups whose members are granted GPU access by bridging them into the
        local `cuda` group. Matched by name via getent (so the group must resolve
        through SSSD). Empty = no AD group gets the GPU (only members the flake
        puts in `cuda` directly, e.g. the local break-glass admin via defaultGroups).
      '';
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

    # Bridge AD groups -> the local cuda group (see cudaAccessGroups). A oneshot +
    # timer re-derives membership on boot and every 10 min because the AD-synced
    # members are NOT durable here: with mutableUsers (default) /etc/group is mutable,
    # but impermanence rolls the root back each boot and every nixos-rebuild
    # regenerates /etc/group with only the DECLARED members (the break-glass admin via
    # defaultGroups) — so AD members must be re-applied. The sync UNIONs AD members
    # with those declared members because `gpasswd -M` replaces the whole list.
    #
    # Fail-SAFE vs revocation: skip ONLY when no AD group resolves at all (SSSD/AD
    # down), so a transient outage never wipes access. When a group DOES resolve, its
    # membership is applied as-is — an emptied AD group therefore revokes (the bug
    # avoided is treating "resolved but empty" the same as "couldn't resolve").
    # (After a switch there's a <=10min window until the timer re-syncs; run
    # `systemctl start cuda-group-sync` to apply immediately.)
    systemd.services.cuda-group-sync = mkIf (cfg.cudaAccessGroups != [ ]) {
      description = "Sync AD group members into the local cuda group (GPU device access)";
      after       = [ "sssd.service" "network-online.target" ];
      wants       = [ "sssd.service" "network-online.target" ];
      # getent MUST be pkgs.getent (the NixOS NSS-correct build), NOT pkgs.glibc.bin:
      # the raw glibc getent can't load the `sss` NSS module in a unit, so AD group
      # lookups silently return nothing (matches scratch.nix's AD-group lookup).
      path        = [ pkgs.shadow pkgs.coreutils pkgs.gnused pkgs.getent ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -uo pipefail
        adgroups=( ${escapeShellArgs cfg.cudaAccessGroups} )
        declared=${escapeShellArg (concatStringsSep "," declaredCudaMembers)}
        members=""
        resolved=0
        for g in "''${adgroups[@]}"; do
          if line=$(getent group "$g" 2>/dev/null); then
            resolved=1
            m=$(printf '%s' "$line" | cut -d: -f4)
            [ -n "$m" ] && members="''${members:+$members,}$m"
          else
            echo "cuda-group-sync: AD group '$g' did not resolve (SSSD/AD down?); skipping" >&2
          fi
        done
        # Only a TOTAL failure to resolve is treated as an outage (leave membership
        # alone). A group that resolves but is empty is applied, so removals revoke.
        if [ "$resolved" -eq 0 ]; then
          echo "cuda-group-sync: no AD group resolved (SSSD/AD down?); leaving local cuda group unchanged (fail-safe)" >&2
          exit 0
        fi
        # Union the AD members with the locally-declared members (e.g. break-glass
        # admin); gpasswd -M replaces the whole list, so omitting them would drop them.
        all=$(printf '%s\n%s\n' "$(printf '%s' "$members"  | tr ',' '\n')" \
                                "$(printf '%s' "$declared" | tr ',' '\n')" \
              | sed '/^$/d' | sort -u | paste -sd, -)
        echo "cuda-group-sync: setting cuda group members to: ''${all:-(none)}"
        gpasswd -M "$all" cuda
      '';
    };

    systemd.timers.cuda-group-sync = mkIf (cfg.cudaAccessGroups != [ ]) {
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnBootSec       = "30s";
        OnUnitActiveSec = "10min";
        Persistent      = true;
      };
    };

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

    # Expose the exporter to the Prometheus scraping host (merges with profile ports).
    krg.firewall.monitoringPorts = mkIf cfg.dcgmExporter.enable [ 9400 ];
  };
}
