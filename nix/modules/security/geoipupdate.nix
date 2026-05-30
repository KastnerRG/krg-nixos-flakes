# krg.geoipupdate — MaxMind GeoLite2-Country.mmdb refresh on every host.
#
# Thin wrapper over upstream services.geoipupdate. Pulls the mmdb into
# /var/lib/GeoIP/ (the default) where the CrowdSec geoip-enrich parser
# reads it. The initial-run timer fires on first activation (when the
# DatabaseDirectory doesn't exist yet) and the recurring timer fires
# weekly thereafter — see upstream module for the timer plumbing.
#
# CONSUMERS:
#   * services.crowdsec (via the crowdsecurity/geoip-enrich parser).
#     CrowdSec reads /var/lib/GeoIP/GeoLite2-Country.mmdb out of the box;
#     no other wiring needed.
#
# SECRETS (operator-distributed, NOT in nix store):
#   * /var/lib/krg/maxmind/license-key  (mode 0400, owned by `geoip` user)
#       The MaxMind license key. Create a free GeoLite2 account at
#       https://www.maxmind.com/en/geolite2/signup, generate a license
#       key, drop the raw key (no trailing newline preferred) into the
#       file. Distribution path TBD — for now drop manually; future
#       work: ansible role distributes during nightly apply.
#   * The MaxMind account ID is NOT a secret (it's a numeric account
#     identifier, harmless on its own) — pass via `krg.geoipupdate.accountId`.
#
# OBSERVABILITY:
#   * `journalctl -u geoipupdate` — last refresh stdout/stderr.
#   * `journalctl -u geoipupdate-initial-run.timer` — initial-run trigger.
#   * `stat /var/lib/GeoIP/GeoLite2-Country.mmdb` — mmdb age.
#
# FAILURE MODES:
#   * Missing license key file → geoipupdate.service fails; CrowdSec
#     geoip-enrich silently leaves country untagged. Detect via the
#     geoipupdate service failing in node-exporter unit metrics.
#   * Stale mmdb (e.g. license key rotated / revoked) → CrowdSec keeps
#     using the last-good mmdb until the operator notices the failing
#     geoipupdate.service.
{ config, lib, ... }:
with lib;
let
  cfg = config.krg.geoipupdate;
in {
  options.krg.geoipupdate = {
    enable = mkEnableOption ''
      MaxMind GeoLite2-Country.mmdb auto-refresh (consumed by CrowdSec's
      geoip-enrich parser)
    '';

    accountId = mkOption {
      type        = types.int;
      default     = 200001;
      example     = 1234567;
      description = ''
        MaxMind account ID (NOT a secret — public account identifier,
        not the license key). Override per fleet — the default 200001 is
        a placeholder. Look it up in the MaxMind account portal.
      '';
    };

    licenseKeyFile = mkOption {
      type        = types.path;
      default     = "/var/lib/krg/maxmind/license-key";
      description = ''
        Path to the MaxMind license-key file (must exist on the host,
        mode 0400, owner `geoip`). NOT in the nix store — operator
        distributes (manual today; ansible-driven future).

        File contents: the raw license-key string, no trailing newline
        preferred (the upstream module's secret-replacement is
        whitespace-sensitive in some shells; safer to omit it).
      '';
    };

    interval = mkOption {
      type        = types.str;
      default     = "weekly";
      description = ''
        systemd.time(7) expression for the recurring refresh. Default
        weekly — MaxMind publishes country-database updates twice a
        week, weekly catches both with low call volume. More frequent
        is wasted bandwidth; less frequent risks stale data for new
        IP ranges.
      '';
    };

    editionIDs = mkOption {
      type        = types.listOf types.str;
      default     = [ "GeoLite2-Country" ];
      description = ''
        MaxMind edition IDs to download. Default is Country only — that's
        all CrowdSec's geoip-enrich parser uses. ASN or City editions are
        bigger and unused; don't add them without a consumer in mind.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.geoipupdate = {
      enable   = true;
      interval = cfg.interval;
      settings = {
        AccountID  = cfg.accountId;
        EditionIDs = cfg.editionIDs;
        # Upstream apply-fn wraps a bare path into { _secret = path; },
        # so the license-key file path stays out of the nix store and
        # is read at activation time via replace-secret.
        LicenseKey = cfg.licenseKeyFile;
        # DatabaseDirectory left at upstream default (/var/lib/GeoIP);
        # CrowdSec geoip-enrich reads from there.
      };
    };
  };
}
