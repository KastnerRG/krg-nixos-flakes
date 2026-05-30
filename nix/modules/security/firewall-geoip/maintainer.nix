# krg-deploy maintainer for the geoIP CIDR data files.
#
# Two jobs, both off by default — operator opts in after wiring the
# prerequisites (`enable = true` on a host that has the bao CLI + git
# push credentials):
#
#   krg.firewallGeoip.maintainer.fetch.enable
#     Weekly systemd timer that runs fetch-geoip.py:
#       1. Reads the MaxMind license key from OpenBao at
#          `secret/krg-deploy/maxmind-geolite2` field `license_key`.
#       2. Downloads + parses GeoLite2-Country-CSV, writes
#          nix/networks/geoip-<cc>-{v4,v6}.json for each `countries` entry.
#       3. git commits + pushes the changes so the flake on every other
#          host picks up the refreshed data on the next nightly autoUpgrade.
#       4. Re-runs `nix flake check` locally to catch any regression
#          before pushing (a corrupt JSON would 500 every host's rebuild).
#
#   krg.firewallGeoip.maintainer.staleness.enable
#     Writes a Prometheus textfile metric (`geoip_data_age_seconds`) every
#     5min, taken from the JSON files' `generated_at` field. Lets the
#     monitoring layer alert if the fetch job stops running (>14d stale →
#     warn; >30d → page). Independent of `fetch.enable` — useful even on
#     a host that only CONSUMES the data, but practically only matters on
#     krg-deploy where the refresh actually happens.
#
# Prerequisites operator has to wire BEFORE flipping `fetch.enable`:
#   * MaxMind GeoLite2 account + free license key — generate at
#     https://www.maxmind.com/en/geolite2/signup. Store in OpenBao:
#       bao kv put secret/krg-deploy/maxmind-geolite2 license_key=<key>
#   * git push credentials so the service can commit refreshes. Two
#     options:
#       (a) Deploy key: generate an ed25519 key on krg-deploy, add as a
#           Deploy Key with write access in the krg-infra repo settings.
#           Place private at /var/lib/krg-admin/.ssh/id_geoip and configure
#           ~/.ssh/config to use it for github.com.
#       (b) GitHub PAT: write-scoped, stored in OpenBao at
#           secret/krg-deploy/github-token, injected at runtime.
#   * The `git user.name` / `user.email` for the commits — set globally
#     for the `krg-admin` user (or per-script via env). Defaults below
#     are "krg-deploy <noreply@krg.ucsd.edu>".
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.firewallGeoip.maintainer;
  repoRoot = "/var/lib/krg-admin/krg-infra";

  # The fetch script ships in nix/modules/security/firewall-geoip/ — copy
  # into a Nix-built package so the systemd unit has a stable path even if
  # /var/lib/krg-admin/krg-infra is in a weird state mid-refresh.
  fetchScript = pkgs.writers.writePython3 "fetch-geoip" {
    flakeIgnore = [ "E501" "E402" "W503" ];
  } (builtins.readFile ./fetch-geoip.py);

  # Wrap fetch-geoip with the bao read + git commit/push logic. Designed
  # to be idempotent: no-op commit when the JSON didn't change (common
  # week-to-week if MaxMind hasn't moved the US prefixes).
  fetchWrapper = pkgs.writeShellScript "fetch-geoip-wrapper" ''
    set -uo pipefail
    repo='${repoRoot}'
    output='${repoRoot}/nix/networks'
    countries='${concatStringsSep "," cfg.fetch.countries}'

    log() { echo "[fetch-geoip] $*" >&2; }

    # 1. Refresh the repo (so the commit later doesn't conflict).
    if ! ${pkgs.git}/bin/git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
      log "repo not present at $repo — skipping refresh until ansible-apply clones it"
      exit 0
    fi
    ${pkgs.git}/bin/git -C "$repo" fetch --quiet origin main || {
      log "git fetch failed — network down? skipping this run"; exit 0; }
    ${pkgs.git}/bin/git -C "$repo" checkout --quiet main || exit 1
    ${pkgs.git}/bin/git -C "$repo" reset --quiet --hard origin/main

    # 2. Read MaxMind license key from OpenBao.
    if ! MAXMIND_LICENSE_KEY=$(
        ${pkgs.openbao}/bin/bao kv get -mount=secret \
          -field=license_key krg-deploy/maxmind-geolite2 2>/dev/null
      ); then
      log "couldn't read MaxMind license from bao (secret/krg-deploy/maxmind-geolite2) — skip"
      exit 0
    fi
    export MAXMIND_LICENSE_KEY

    # 3. Run the fetcher (writes nix/networks/geoip-<cc>-{v4,v6}.json).
    if ! ${fetchScript} --countries "$countries" --output-dir "$output"; then
      log "fetch-geoip.py failed"
      exit 1
    fi

    # 4. Validate the flake EVALUATES OK with the new data (catches a
    #    corrupted JSON before it ships to every host on the next nightly).
    if ! ${pkgs.nix}/bin/nix flake check --no-build "$repo/nix" >/dev/null 2>&1; then
      log "flake check failed with the refreshed data — reverting + exiting"
      ${pkgs.git}/bin/git -C "$repo" checkout -- nix/networks/geoip-*.json
      exit 1
    fi

    # 5. Commit + push if anything changed.
    if ${pkgs.git}/bin/git -C "$repo" diff --quiet -- nix/networks/geoip-*.json; then
      log "no changes — MaxMind data unchanged since last fetch"
      exit 0
    fi
    ${pkgs.git}/bin/git -C "$repo" add nix/networks/geoip-*.json
    ${pkgs.git}/bin/git -C "$repo" \
      -c user.name='${cfg.fetch.gitUserName}' \
      -c user.email='${cfg.fetch.gitUserEmail}' \
      commit --quiet -m "chore(geoip): weekly refresh from MaxMind GeoLite2"
    if ! ${pkgs.git}/bin/git -C "$repo" push --quiet origin main; then
      log "git push failed — credentials not wired? Refresh kept locally."
      exit 1
    fi
    log "pushed refresh — every host picks it up on next nightly autoUpgrade"
  '';

  # Staleness metric: parse `generated_at` from each JSON file and emit
  # geoip_data_age_seconds{country,ip_version} into the node_exporter
  # textfile dir. Independent of fetch; informational on any host that
  # consumes the data — but only meaningful where the refresh runs.
  stalenessScript = pkgs.writeShellScript "geoip-staleness-textfile" ''
    set -uo pipefail
    out='${config.krg.nodeExporter.textfileDir}/geoip.prom'
    tmp="$(${pkgs.coreutils}/bin/mktemp "''${out}.XXXXXX")"
    now=$(${pkgs.coreutils}/bin/date +%s)
    {
      echo "# HELP geoip_data_age_seconds Seconds since the geoIP CIDR file's generated_at field."
      echo "# TYPE geoip_data_age_seconds gauge"
      for f in ${repoRoot}/nix/networks/geoip-*.json; do
        [ -f "$f" ] || continue
        cc=$(${pkgs.jq}/bin/jq -r '.country // "unknown"' "$f")
        ipv=$(${pkgs.jq}/bin/jq -r '.ip_version // "unknown"' "$f")
        gen=$(${pkgs.jq}/bin/jq -r '.generated_at // ""' "$f")
        if [ -z "$gen" ] || [ "$gen" = "null" ]; then
          # never generated — emit -1 so an alert can distinguish "stale"
          # (>0, large) from "never" (-1). Plain "NaN" would also work.
          age=-1
        else
          gen_ts=$(${pkgs.coreutils}/bin/date -d "$gen" +%s 2>/dev/null || echo 0)
          age=$(( now - gen_ts ))
        fi
        cc_l=$(echo "$cc" | ${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]')
        echo "geoip_data_age_seconds{country=\"$cc_l\",ip_version=\"$ipv\"} $age"
      done
    } > "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" "$out"
  '';
in
{
  options.krg.firewallGeoip.maintainer = {
    fetch = {
      enable = mkEnableOption ''
        weekly geoIP fetcher (MaxMind GeoLite2 → nix/networks/geoip-*.json
        → git commit + push). Off by default — operator turns on after
        wiring MaxMind license + git deploy creds per the docstring at the
        top of this file
      '';
      countries = mkOption {
        type        = types.listOf types.str;
        default     = [ "US" ];
        description = "Country codes to refresh (passed through to fetch-geoip.py --countries).";
      };
      schedule = mkOption {
        type        = types.str;
        default     = "Sun *-*-* 03:30:00";
        description = "systemd OnCalendar expression. Default: Sun 03:30 (before nightly autoUpgrade so hosts pick up the refresh on the same night).";
      };
      gitUserName = mkOption {
        type        = types.str;
        default     = "krg-deploy";
      };
      gitUserEmail = mkOption {
        type        = types.str;
        default     = "noreply@krg.ucsd.edu";
      };
    };

    staleness = {
      enable = mkEnableOption ''
        Prometheus textfile metric `geoip_data_age_seconds` per
        country+ip_version. Reads JSON files at ${repoRoot}/nix/networks/.
        Useful on krg-deploy (where the refresh runs); cheap textfile
        emission, no node_exporter override required
      '';
      onCalendar = mkOption {
        type        = types.str;
        default     = "*:0/5";   # every 5min
        description = "How often to refresh the staleness textfile metric.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.fetch.enable {
      systemd.services.fetch-geoip = {
        description = "Refresh nix/networks/geoip-*.json from MaxMind GeoLite2";
        path        = [ pkgs.openssh pkgs.git ];
        serviceConfig = {
          Type             = "oneshot";
          User             = "krg-admin";
          WorkingDirectory = repoRoot;
          # Timeout the whole thing at 10min — MaxMind download + flake
          # check should fit in 2-3min; 10min is a generous cap to fail
          # fast if something's wedged.
          TimeoutStartSec  = "10min";
          ExecStart        = fetchWrapper;
        };
      };

      systemd.timers.fetch-geoip = {
        description = "Weekly geoIP CIDR refresh from MaxMind GeoLite2";
        wantedBy    = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.fetch.schedule;
          Persistent = true;  # catch up if krg-deploy was off at fire time
        };
      };
    })

    (mkIf cfg.staleness.enable {
      # The textfile metric needs the node_exporter textfile collector dir.
      # base.nix turns node-exporter on for every host; assert just in case.
      assertions = [{
        assertion = config.krg.nodeExporter.enable;
        message   = "krg.firewallGeoip.maintainer.staleness.enable requires krg.nodeExporter.enable";
      }];

      systemd.services.geoip-staleness-textfile = {
        description   = "Write geoip_data_age_seconds metric to node_exporter textfile dir";
        serviceConfig = {
          Type      = "oneshot";
          ExecStart = stalenessScript;
        };
      };
      systemd.timers.geoip-staleness-textfile = {
        description = "Refresh the geoip staleness metric periodically";
        wantedBy    = [ "timers.target" ];
        timerConfig = {
          OnBootSec       = "1min";
          OnUnitActiveSec = cfg.staleness.onCalendar;
        };
      };
    })
  ];
}
