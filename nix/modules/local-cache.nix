# krg.localCache — node-local fast per-user cache at /local/<user>.
#
# WHAT: a plain, durable, NODE-local ZFS dataset (no FUSE, no NFS, no tiering)
# that holds the regenerable, hot, small-file, per-host state that has no business
# sitting on the NFS /home (modules/nfs-home.nix). Two kinds move here:
#   1. IDE remote servers — ~/.vscode-server, ~/.cursor-server — via a SYMLINK
#      created on login (the server tree is per-host and pure cache: delete it and
#      VS Code/Cursor re-download on next connect).
#   2. The cache class — XDG_CACHE_HOME, Hugging Face / torch model caches, the conda
#      PACKAGE cache, npm — via per-session env vars pointed under /local/<user>/cache
#      (surfaced as ~/machine/cache). Only CACHES move; conda ENVS and real data stay
#      in the user's home.
#   3. Working git repos — ~/machine/workspace -> /local/<user>/workspace, a plain dir
#      on this dataset. git+IDE is the small-file/watch-heavy load NFS is worst at, so
#      checkouts belong here. Repos are NOT cache: the git remote is their backup (this
#      dataset has no snapshots), so push — only uncommitted work is ever at risk.
#
# USER-FACING ~/machine/ LAYER: 2 and 3 (plus ~/machine/scratch, owned by
# modules/scratch.nix) are presented under one tidy ~/machine/ dir so users get "this is
# NOT your home, it lives on this box" without memorizing /local/<user>/... or
# /scratch/<lab>/<user>. The names are symlinks in the NFS home pointing OUT to local
# storage; `marker.enable` drops a README there saying as much.
#
# WHY not /home (NFS): the IDE servers and these caches are hot, watch-heavy,
# many-small-file workloads — exactly what NFS is worst at (latency per stat/open,
# and inotify doesn't propagate over NFS so file watchers fall back to polling).
# They're also regenerable, so they don't deserve durable, network-served home
# space. WHY not /scratch (krg.scratch / autotier): that namespace is FUSE + tiered
# and DEMOTES cold files onto the NFS tier — the opposite of what a dev cache wants,
# and it fails closed on the NFS tier. This module is the deliberately boring
# counterpart: one local NVMe dataset, fastest path, no network dependency.
#
# WAITER TOPOLOGY (the only consumer today): nvmepool/local -> /local (legacy mount,
# disko-config.nix). It is OFF the @blank rollback (its own dataset, like
# /var/lib/docker), so caches survive reboots and aren't re-downloaded — and for the
# same reason it needs NO entry in modules/impermanence.nix's /persist bind list.
#
# PER-USER DIR + SYMLINKS: a pam_exec session hook (the same pattern as
# krg.scratch.perUser and pam_mkhomedir) creates /local/<user> (mode 0700) on login,
# then lays the `symlinks` map — each entry links a home path to a /local/<user> target
# (e.g. ~/.vscode-server -> /local/<user>/.vscode-server, and the user-facing
# ~/machine/{workspace,cache} -> /local/<user>/{workspace,cache}). Link and target paths
# may differ, so any parent of the link (~/machine) is created first — `ln` won't.
# GUARDED: only while /local is actually mounted (never seed onto a bare mountpoint), and
# a link is made ONLY if the home path doesn't already exist — so an existing real
# ~/.vscode-server is never clobbered (the user opts in once with `rm -rf
# ~/.vscode-server`, then the next login links it). With `marker.enable`, a write-if-absent
# README is dropped (default ~/machine/README). Non-blocking: a failure never denies
# login. The companion ~/machine/scratch link is owned by krg.scratch, not this module.
#
# CACHE ENV VARS: set via environment.shellInit (cross-shell: bash + zsh), computed
# with `id -un` at shell start (robust where $USER expansion in sessionVariables is
# not), and only exported when /local/<user> exists — so a host/user without this
# cache (or with /local unmounted) just keeps the home defaults.
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.localCache;

  # Reject paths that could escape the user's home / the per-user dir when concatenated
  # in the root-run login hook: no leading "/" (absolute) and no ".." path segment.
  relUnsafe = p: hasPrefix "/" p || elem ".." (splitString "/" p);

  # README dropped in ~/machine (marker.enable) so the layout is self-documenting:
  # node-local + NOT backed up. Hostname baked in at eval time.
  markerFile = pkgs.writeText "machine-readme" ''
    This folder is NODE-LOCAL storage on ${config.networking.hostName} — it is NOT part
    of your home directory, and NOTHING in it is backed up.

      workspace/   your git repos — push to the remote; that push IS your only backup
      cache/       regenerable caches (HF/torch/pip/npm/conda pkgs) — safe to delete
      scratch/     tiered lab scratch (autotier) — treat as disposable

    If a folder here is missing or empty, that storage just isn't mounted right now.
  '';

  # --- per-user dir + symlink creation (pam_exec session hook) ----------------
  # Runs at session open as root (before the session drops to the user). See header
  # for the two guards (mount active; never clobber an existing home path).
  mkPerUserScript = pkgs.writeShellScript "krg-localcache-mkuser" ''
    set -u
    [ -n "''${PAM_USER:-}" ] || exit 0
    mp=${escapeShellArg cfg.mountPoint}
    # Guard 1: only when /local is actually mounted (don't seed a bare mountpoint).
    ${pkgs.util-linux}/bin/mountpoint -q -- "$mp" || exit 0

    d="$mp/$PAM_USER"
    if [ ! -e "$d" ]; then
      ${pkgs.coreutils}/bin/mkdir -p "$d" || exit 0
      ${pkgs.coreutils}/bin/chown "$PAM_USER" "$d" || true
      ${pkgs.coreutils}/bin/chmod ${cfg.perUser.mode} "$d" || true
    fi

    # The user's home (NFS) — needed to place the symlinks. If it isn't present
    # (server down), the nfs-home login gate already blocks these users; bail safely.
    home="$(${pkgs.getent}/bin/getent passwd "$PAM_USER" 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 | ${pkgs.coreutils}/bin/cut -d: -f6)"
    [ -n "$home" ] && [ -d "$home" ] || exit 0

    # Lay one symlink: $home/<linkRel> -> $d/<targetRel>. Link and target paths can
    # differ (e.g. ~/machine/workspace -> /local/<user>/workspace), so create any parent
    # of the link first (~/machine) — `ln` won't. Guard: never clobber an existing real
    # path (-e follows; -L catches a dangling/old symlink); the user removes it once to
    # opt in. chown the created parent so ~/machine isn't a root-owned dir in their home.
    mklink() {
      local link="$home/$1" target="$d/$2" pdir
      [ ! -e "$link" ] && [ ! -L "$link" ] || return 0
      ${pkgs.coreutils}/bin/mkdir -p "$target" || return 0
      ${pkgs.coreutils}/bin/chown "$PAM_USER" "$target" || true
      pdir="$(${pkgs.coreutils}/bin/dirname "$link")"
      if [ "$pdir" != "$home" ]; then
        ${pkgs.coreutils}/bin/mkdir -p "$pdir" || return 0
        ${pkgs.coreutils}/bin/chown "$PAM_USER" "$pdir" || true
      fi
      ${pkgs.coreutils}/bin/ln -s "$target" "$link" || return 0
      ${pkgs.coreutils}/bin/chown -h "$PAM_USER" "$link" || true
    }
    ${concatStringsSep "\n" (mapAttrsToList (link: target:
      "    mklink ${escapeShellArg link} ${escapeShellArg target}") cfg.symlinks)}
    ${optionalString cfg.marker.enable ''
      # Self-documenting marker: write-if-absent README that this area is node-local
      # and not backed up (see markerFile above).
      mrel=${escapeShellArg cfg.marker.path}
      mfile="$home/$mrel"
      if [ ! -e "$mfile" ]; then
        mdir="$(${pkgs.coreutils}/bin/dirname "$mfile")"
        ${pkgs.coreutils}/bin/mkdir -p "$mdir" || true
        if [ "$mdir" != "$home" ]; then
          ${pkgs.coreutils}/bin/chown "$PAM_USER" "$mdir" || true
        fi
        ${pkgs.coreutils}/bin/cp ${markerFile} "$mfile" || true
        ${pkgs.coreutils}/bin/chown "$PAM_USER" "$mfile" || true
        ${pkgs.coreutils}/bin/chmod 0644 "$mfile" || true
      fi
    ''}
    exit 0
  '';

  # --- cache env vars (environment.shellInit) ---------------------------------
  # Export each cacheEnv var under /local/<user>. `id -un` is set in every shell; this
  # avoids the pam_env $USER-expansion caveat. Tools mkdir their own subdirs on first use.
  # Two guards, both load-bearing:
  #   - `mountpoint -q` (NOT `[ -d ]`): systemd.tmpfiles always creates the bare
  #     <mountPoint> dir, so `[ -d ]` is true even when the dataset FAILED to mount —
  #     which would point caches at the ephemeral root. We require the real mount, the
  #     same check the pam hook uses.
  #   - `[ -d "$__krg_lc" ]`: only redirect if the per-user dir exists. It is created by
  #     the pam hook (running as root, the only one that can write under the 0755
  #     root-owned <mountPoint>); the unprivileged shell can't mkdir it, so without this
  #     the exported XDG_CACHE_HOME etc. would point at a dir the user can't create.
  # mountPoint goes through a shell var (escaped ONCE) so it's never interpolated raw
  # inside a double-quoted bash string (a non-standard mountPoint with $/backticks would
  # otherwise expand).
  shellInitSnippet = optionalString (cfg.cacheEnv != { }) ''
    # krg.localCache: redirect regenerable caches onto node-local NVMe (/local).
    __krg_mp=${escapeShellArg cfg.mountPoint}
    if ${pkgs.util-linux}/bin/mountpoint -q -- "$__krg_mp"; then
      __krg_lc="$__krg_mp/$(${pkgs.coreutils}/bin/id -un 2>/dev/null)"
      if [ -d "$__krg_lc" ]; then
    ${concatStringsSep "\n" (mapAttrsToList (var: rel:
      "    export ${var}=\"$__krg_lc/${rel}\"") cfg.cacheEnv)}
      fi
      unset __krg_lc
    fi
    unset __krg_mp
  '';
in {
  options.krg.localCache = {
    enable = mkEnableOption "node-local fast per-user cache at /local/<user> (IDE servers + cache class off NFS /home)";

    mountPoint = mkOption {
      type = types.str;
      default = "/local";
      description = "Where the node-local cache dataset mounts; per-user dirs are <mountPoint>/<user>.";
    };

    device = mkOption {
      type = types.str;
      default = "nvmepool/local";
      example = "nvmepool/local";
      description = "ZFS dataset (legacy mountpoint) backing <mountPoint>. Must be OFF the impermanence rollback so caches persist.";
    };

    mountOptions = mkOption {
      type = types.listOf types.str;
      default = [ "defaults" "nofail" ];
      description = "Mount options for the /local dataset. `nofail` so a missing/late dataset never wedges boot (the pam hook + shellInit both guard on the mount being present).";
    };

    symlinks = mkOption {
      type = types.attrsOf types.str;
      default = {
        ".vscode-server" = ".vscode-server";
        ".cursor-server" = ".cursor-server";
      };
      example = literalExpression ''
        {
          ".vscode-server"    = ".vscode-server";
          "machine/workspace" = "workspace";   # ~/machine/workspace -> /local/<user>/workspace
          "machine/cache"     = "cache";        # ~/machine/cache     -> /local/<user>/cache
        }
      '';
      description = ''
        Map of home-relative LINK path -> <mountPoint>/<user>-relative TARGET path, laid
        on login (e.g. ~/.vscode-server -> /local/<user>/.vscode-server, or the
        user-facing ~/machine/workspace -> /local/<user>/workspace). Link and target may
        differ; any parent dir of the link (~/machine) is created first. A link is made
        only if the home path does not already exist (an existing real dir/symlink is
        never clobbered). Setting this REPLACES the default, so re-list the IDE servers.
      '';
    };

    marker = mkOption {
      default = { };
      description = ''
        Optional README dropped (write-if-absent) in each user's home, marking the
        node-local area as not-your-home + not-backed-up. Off by default; enable it on
        hosts that expose the ~/machine/ layout via `symlinks`.
      '';
      type = types.submodule {
        options = {
          enable = mkEnableOption "the node-local 'not backed up' README in each user's home";
          path = mkOption {
            type = types.str;
            default = "machine/README";
            description = "Home-relative path of the marker file (its parent dir is created if missing).";
          };
        };
      };
    };

    cacheEnv = mkOption {
      type = types.attrsOf types.str;
      default = {
        XDG_CACHE_HOME  = "cache";              # pip, matplotlib, many tools (= ~/machine/cache)
        HF_HOME         = "cache/huggingface";  # Hugging Face hub (hardcodes ~/.cache, ignores XDG)
        TORCH_HOME      = "cache/torch";         # torch.hub model cache
        CONDA_PKGS_DIRS = "cache/conda/pkgs";    # conda PACKAGE cache (envs stay in home)
        npm_config_cache = "cache/npm";          # npm download cache
      };
      description = ''
        Cache env vars -> path RELATIVE to <mountPoint>/<user>, exported per shell
        session (only when that dir exists). Only CACHES — never relocate where envs
        or real data live. Set to { } to disable cache redirection (symlinks only).
      '';
    };

    perUser = mkOption {
      default = { };
      description = "On-login creation of the private <mountPoint>/<user> dir (the symlink targets live under it).";
      type = types.submodule {
        options = {
          enable = mkEnableOption "auto-create <mountPoint>/<user> + the symlinks on login";
          mode = mkOption {
            type = types.str;
            default = "0700";
            description = "Mode for each per-user dir (0700 = private to the user).";
          };
          loginServices = mkOption {
            type = types.listOf types.str;
            default = [ "sshd" "login" ];
            description = "PAM services the per-user/symlink session hook is added to (add `xrdp` if the desktop is enabled).";
          };
        };
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # Admin-set link/target paths land in a root-run login hook, so reject anything
      # that could escape the user's home or /local/<user> (absolute, or with a ".."
      # segment) at eval time rather than in the shell.
      assertions =
        (mapAttrsToList (link: target: {
          assertion = !(relUnsafe link) && !(relUnsafe target);
          message = ''krg.localCache.symlinks entry "${link}" -> "${target}": both must be home-relative paths (no leading "/", no ".." segment) — it runs in a root login hook.'';
        }) cfg.symlinks)
        ++ optional cfg.marker.enable {
          assertion = !(relUnsafe cfg.marker.path);
          message = ''krg.localCache.marker.path "${cfg.marker.path}" must be a home-relative path (no leading "/", no ".." segment).'';
        };

      # The local dataset is mounted here (disko leaves it mountpoint=legacy with no
      # fileSystems entry, like the scratch datasets, so this module owns the mount).
      fileSystems.${cfg.mountPoint} = {
        device = cfg.device;
        fsType = "zfs";
        options = cfg.mountOptions;
      };

      # Bare mountpoint perms before the dataset mounts; once mounted the dataset
      # root (0755 root) shows through, and each user's dir is 0700 (perUser hook).
      systemd.tmpfiles.rules = [ "d ${cfg.mountPoint} 0755 root root -" ];

      environment.shellInit = shellInitSnippet;
    }

    (mkIf cfg.perUser.enable {
      # Session pam_exec hook on each login service. `optional` so it can NEVER block
      # a login (the cache is not critical). Distinct rule name from krg.scratch's.
      security.pam.services = genAttrs cfg.perUser.loginServices (_: {
        rules.session.krgLocalCacheMkdir = {
          control = "optional";
          modulePath = "${pkgs.pam}/lib/security/pam_exec.so";
          args = [ "${mkPerUserScript}" ];
          order = 13500; # session open, after pam_mkhomedir and krg.scratch's hook
        };
      });
    })
  ]);
}
