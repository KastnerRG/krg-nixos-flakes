# Source-restrict selected in-guest firewall ports to a union of:
#   * trusted-IPSet CIDRs from nix/networks/trusted.json (always-allowed
#     bypass; keeps staff in known nets + the `ops` manual-override slot
#     reachable even when the geoIP set is wrong or stale)
#   * country-allowlist CIDRs from nix/networks/geoip-<cc>-{v4,v6}.json
#     (refreshed weekly by the fetch-geoip timer on krg-deploy — see
#     `nix/modules/security/firewall-geoip/fetch-geoip.py`)
#
# Replaces the DSM-only "block outside US" pattern fleet-wide for any host
# with a port that has to bind 0.0.0.0 (waiter SSH, dcgm 9400, etc.). NOT
# a security control on its own — fail2ban + key-only auth + auth services
# remain the actual controls. This is *attack-surface noise reduction*:
# stops drive-by scanners from non-US ranges from even reaching the daemon.
#
# Design notes (issue #74):
#   * Builds on krg.firewall.sourcedPorts. Generates one sourcedPorts entry
#     per port in applyToPorts; the resulting nftables rules are identical
#     in shape to everything else sourcedPorts emits — no parallel rule path.
#   * Trusted IPSets are UNIONED with the geoIP set (not intersected) so a
#     staff member in `ops` can always get in even from outside the US.
#   * Reads JSON files at flake-eval time (same load pattern as trusted.json).
#     If a file is missing, treats as empty CIDR list — fail-closed: only
#     allowedSources reach the port until the timer produces the file.
#
# Lab-travel mitigation: see docs/working-remotely.md — "add yourself to
# `ops` before you fly". `allowedSources` includes `ops` by default.
{ config, lib, ... }:
with lib;
let
  cfg = config.krg.firewall.geoip;

  trusted = builtins.fromJSON (builtins.readFile ../../networks/trusted.json);

  # Load one country/family CIDR list; tolerate missing files (fail-closed:
  # empty list means only the trusted-IPSet bypass CIDRs reach the port).
  # The data file shape is `{ "cidrs": [ "1.2.3.0/24", ... ], "_comment": ... }`
  # — produced by the fetch-geoip generator from MaxMind GeoLite2-Country.
  readCountryCidrs = country: ipv:
    let
      file = cfg.dataDir + "/geoip-${toLower country}-${ipv}.json";
      data = if builtins.pathExists file
             then builtins.fromJSON (builtins.readFile file)
             else { cidrs = []; };
    in data.cidrs or [];

  geoipCidrs = concatMap (cc:
    readCountryCidrs cc "v4" ++ readCountryCidrs cc "v6"
  ) cfg.allowedCountries;

  # Expand each `allowedSources` entry (an IPSet name from trusted.json)
  # into its concrete CIDR list. Unknown sets resolve to [] rather than
  # erroring — operators see the empty result via `nix eval` if they typo.
  expandTrusted = setName:
    map (e: e.cidr) (trusted.ipsets.${setName} or []);
  bypassCidrs = concatMap expandTrusted cfg.allowedSources;
in
{
  options.krg.firewall.geoip = {
    enable = mkEnableOption ''
      geoIP source-restriction for `applyToPorts`. Generates
      `krg.firewall.sourcedPorts` entries from the union of `allowedSources`
      (trusted-IPSet bypass) and the `allowedCountries` geoIP CIDR lists
      under `dataDir`. Inert unless `applyToPorts` is non-empty
    '';

    allowedCountries = mkOption {
      type        = types.listOf types.str;
      default     = [ "US" ];
      example     = [ "US" "CA" ];
      description = ''
        ISO 3166-1 alpha-2 country codes whose IP ranges are allowed. The
        module reads `geoip-<lowercased-code>-{v4,v6}.json` from `dataDir`
        for each code and unions all the CIDRs.
      '';
    };

    allowedSources = mkOption {
      type        = types.listOf types.str;
      default     = [ "ucsd" "sealab" "ops" ];
      description = ''
        IPSet names from `nix/networks/trusted.json` that ALWAYS pass — these
        are unioned with the geoIP CIDRs, NOT intersected. `ops` is the
        manual-override slot for traveling staff; admins add their current
        IP there before flying so the geoIP block can't lock them out
        of a remote-only box. See docs/working-remotely.md.
      '';
    };

    applyToPorts = mkOption {
      type        = types.listOf types.port;
      default     = let
        fw = config.krg.firewall;
        # Don't loosen ports that already have a stricter rule:
        #   * sshSources covers 22 (sealab on service hosts) → keep that
        #   * manual sourcedPorts entries are operator-tighter restrictions
        #   * publicPorts are the explicit opt-IN-to-globally-public
        # In each case, the existing rule is correct and adding US+trusted
        # would WIDEN the source set (sealab ⊆ US+trusted; sourcedPorts
        # sealab-only would gain US+trusted as alternates; publicPorts
        # gating with US would defeat its purpose).
        alreadyTighter =
          (if fw.sshSources != [] then [ 22 ] else [])
          ++ (map (e: e.port) fw.sourcedPorts)
          ++ fw.publicPorts;
      in filter (p: !(elem p alreadyTighter)) fw.allowedTCPPorts;
      example     = [ 22 9400 ];
      description = ''
        Ports to source-restrict via the union of `allowedSources` + geoIP
        CIDRs.

        DEFAULTS TO `krg.firewall.allowedTCPPorts` minus any ports already
        covered by a stricter rule (`sshSources`, `sourcedPorts`,
        `publicPorts`). So on a typical host the operator just writes
        `krg.firewall.allowedTCPPorts = [ N ]` and the fleet-default geoIP
        gating Just Works without per-port wiring.

        Override explicitly if you want geoIP-gating on a port that ISN'T
        in `allowedTCPPorts` (uncommon — usually if you find yourself
        wanting this you should add the port to `allowedTCPPorts` instead).

        Each entry gets its own `krg.firewall.sourcedPorts` entry. The
        underlying in-guest firewall (`krg.firewall.enable`) must be ON
        for the rules to take effect — this module doesn't toggle it.
      '';
    };

    dataDir = mkOption {
      type        = types.path;
      default     = ../../networks;
      description = ''
        Directory containing the `geoip-<cc>-{v4,v6}.json` files. Defaults
        to `nix/networks/` (in-repo) so the flake reads them at eval time
        the same way it reads `trusted.json`. Override only if shipping
        the data files out-of-tree (uncommon).
      '';
    };
  };

  config = mkIf (cfg.enable && cfg.applyToPorts != []) {
    # Emit to the AUTO-derived channel (not the operator-facing
    # `sourcedPorts`). Splitting the channels avoids an infinite recursion:
    # `applyToPorts` default reads `cfg.sourcedPorts` to know what's
    # already operator-restricted, but if we wrote here too, the option
    # would depend on itself.
    krg.firewall._autoSourcedPorts = map (port: {
      inherit port;
      # bypass first so the trusted nets are matched before scanning the
      # ~75K-entry US CIDR list (ordering doesn't matter for correctness,
      # but reads more obviously to humans inspecting the generated rules).
      sources = bypassCidrs ++ geoipCidrs;
    }) cfg.applyToPorts;
  };
}
