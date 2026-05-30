# krg.firewall — the single switch for the in-guest OS firewall (nftables).
#
# Fleet-wide policy (set in profiles/base.nix, expressible per-host):
#   * NO PORT IS GLOBALLY OPEN BY DEFAULT. The most permissive a port can
#     be is "US + trusted IPSets" — applied via the always-on geoIP gate
#     (krg.firewall.geoip, default ON in base.nix; see issue #74).
#   * The four operator-facing port lists, from most-restrictive to least:
#
#     sourcedPorts      — explicit per-port source restriction (operator picks
#                         the CIDRs). Use for internal-only protocols where
#                         even US+trusted is too loose — e.g. OpenBao 8200
#                         sealab-only on krg-vault, AD ports sealab-only on
#                         krg-ldap.
#     sshSources        — SSH-specific (port 22) tightening for service hosts.
#                         Mirrors the Proxmox perimeter (sealab nets).
#     allowedTCPPorts   — "reachable per the host's policy". With geoIP on,
#                         these auto-route through `sourcedPorts` with the
#                         US+trusted union as the source. With geoIP off,
#                         they're globally open (legacy behavior). Operator
#                         intent: "this should be reachable somehow".
#     publicPorts       — EXPLICIT opt-IN-to-globally-public. The escape
#                         hatch for protocols where source restriction
#                         breaks legitimate clients (ACME HTTP-01 from
#                         Let's Encrypt's multi-perspective validators —
#                         see krg-vault). Each entry SHOULD have an inline
#                         `# reason:` comment for review.
#
#   * The four lists are intersected with disjointness assertions (see
#     `config.assertions` below) so operator can't silently put a port in
#     two contradictory lists (closes #83). If you put port N in:
#       allowedTCPPorts AND publicPorts → assertion fires (opposite intent)
#       allowedTCPPorts AND sourcedPorts → assertion fires (operator intent
#                                          unclear; sourcedPorts wins, but
#                                          listing in both is misleading)
#       publicPorts AND sourcedPorts → assertion fires (opposite intent)
#
#   * Service hosts (krg.base.serviceHost = true) automatically get
#     sshSources populated from trusted.json's sealab + ops nets, so 22 is
#     already tighter than US+trusted there. geoIP's auto-promotion of
#     `allowedTCPPorts` excludes 22 in that case (the stricter rule wins).
#
# Cross-references:
#   * Geo source data: nix/networks/geoip-<cc>-{v4,v6}.json (refreshed
#     weekly on krg-deploy from MaxMind GeoLite2 — issue #74).
#   * Trusted IPSets: nix/networks/trusted.json (shared with the Ansible
#     proxmox_firewall layer and fail2ban allow-list).
#   * The fleet policy is documented in docs/working-remotely.md (the
#     "add yourself to ops before traveling" workflow that makes the
#     US-only floor liveable for traveling staff).
{ config, lib, ... }:
with lib;
let
  cfg = config.krg.firewall;
  # nftables uses different match keywords for v4 (`ip saddr`) vs v6
  # (`ip6 saddr`). Pick by colon presence — only v6 has colons.
  isV6 = src: hasInfix ":" src;

  # Emit ONE rule per port per family using nftables anonymous inline
  # sets (`ip saddr { cidr1, cidr2, ... } proto dport N accept`) instead
  # of one rule per (port × CIDR). nftables auto-builds an interval tree
  # for CIDR-bearing inline sets, so lookup stays O(log n) regardless of
  # set size — and one rule replaces hundreds of thousands.
  #
  # Why this matters NOW: the geoIP data set is real (US ~163K v4 + 254K
  # v6 prefixes from MaxMind GeoLite2). Per-CIDR rules would have given
  # every gated port a ~417K-line addition to `nft list ruleset` per host,
  # with per-packet linear-scan cost on drops. Anonymous sets reduce that
  # to 2 lines per port (one v4, one v6). Reviewer flagged this on PR #90
  # — fix is critical before merge so the regression doesn't land on every
  # geoIP-gated host at the same time. Issue #74's design called this out.
  #
  # Helper: render a `{ a, b, c }` element list for nftables. Empty list
  # returns "", letting the caller skip emitting the rule entirely (an
  # empty set still parses but matches nothing — wasted work).
  inlineSet = cidrs: "{ " + concatStringsSep ", " cidrs + " }";

  # Render a per-port rule for one protocol+family. Returns "" if the
  # source list is empty (don't emit a rule that matches nothing).
  mkPortRule = { proto, family, port, sources }:
    if sources == [] then ""
    else "${family} ${inlineSet sources} ${proto} dport ${toString port} accept\n";

  # Render both v4 and v6 rules for a sourcedPort entry. Splits sources
  # by family so each rule references a single-family set (nftables
  # requires this; `ip saddr` can't reference an ipv6 set).
  mkSourcedRules = proto: { port, sources }:
    let
      v4 = filter (s: !(isV6 s)) sources;
      v6 = filter isV6 sources;
    in
      mkPortRule { inherit proto port; family = "ip saddr";  sources = v4; }
      + mkPortRule { inherit proto port; family = "ip6 saddr"; sources = v6; };
in {
  options.krg.firewall = {
    enable = mkEnableOption "KRG firewall (replaces UFW)";

    allowedTCPPorts = mkOption {
      type        = types.listOf types.port;
      default     = [];
      description = ''
        Ports the host wants reachable. With `krg.firewall.geoip` enabled
        (the fleet default per `profiles/base.nix`), these are AUTOMATICALLY
        gated to the US+trusted union via `sourcedPorts` — they're NOT
        globally open. For ports that genuinely must be globally reachable
        (ACME HTTP-01, public-facing web that legitimately needs
        international users), use `publicPorts` INSTEAD.

        Interaction with the other port lists:
          * `sshSources` (22 on service hosts) silently moves 22 out of
            the globally-open list AND out of the geoIP auto-promotion
            (the tighter rule wins). No assertion fires for an overlap
            here — it's the expected configuration on service hosts.
          * `sourcedPorts` (operator-explicit per-port restriction) wins
            over geoIP auto-promotion. Listing a port in BOTH is
            REDUNDANT — a per-PR assertion (`allowedTCPPorts ∩
            sourcedPorts`) flags the duplicate so the operator drops one.
          * `publicPorts` (intentional globally-open) is the opposite
            intent. A per-PR assertion (`allowedTCPPorts ∩ publicPorts`)
            fires; pick one.

        Default empty so a host that adds this module without explicit
        configuration gets the minimal attack surface (no in-guest ports
        beyond what `monitoringPorts`/`sshSources` open).
      '';
    };

    publicPorts = mkOption {
      type        = types.listOf types.port;
      default     = [];
      example     = [ 80 ];
      description = ''
        Ports that MUST be globally reachable — no source restriction.
        EXPLICIT opt-IN escape hatch for protocols where source
        restriction breaks legitimate clients. Each entry SHOULD have an
        inline `# reason: ...` comment for PR review.

        Today's only legitimate use case: ACME HTTP-01 challenge port 80.
        Let's Encrypt does multi-perspective validation from validators
        in multiple countries (US + EU + Asia); US-gating port 80 would
        fail cert issuance/renewal. Other hosts running ACME HTTP-01
        will need the same opt-in.

        If a port doesn't need this escape hatch, use `allowedTCPPorts`
        (geoIP-gated) instead.
      '';
    };

    allowedUDPPorts = mkOption {
      type    = types.listOf types.port;
      default = [];
    };

    # Ports only reachable from the KRG Prometheus scraping host
    # (krg-prod; set via monitoringSourceIp below, sourced from trusted.json).
    monitoringPorts = mkOption {
      type        = types.listOf types.port;
      default     = [];
      description = "Ports open only to monitoringSourceIp (Prometheus scraping)";
    };

    monitoringSourceIp = mkOption {
      type    = types.str;
      # Fallback only — base.nix sets this on every host from trusted.json's
      # monitoring_host (currently krg-prod). Kept in sync to avoid a stale value.
      default = "137.110.161.106";
    };

    allowRDP = mkOption {
      type        = types.bool;
      default     = false;
      description = "Open port 3389 for XRDP (waiter compute nodes)";
    };

    rdpSources = mkOption {
      type        = types.listOf types.str;
      default     = [];
      description = ''
        When allowRDP is set: if non-empty, 3389 is reachable ONLY from these
        CIDRs/IPs (source-restricted in-guest); if empty, 3389 is opened globally.
        On a public-IP compute box you want this set — base.nix defaults it to the
        trusted UCSD nets so RDP is never exposed to the whole internet (RDP is not
        key-only and there's no xrdp fail2ban jail). Inert unless allowRDP = true.
      '';
    };

    sshSources = mkOption {
      type        = types.listOf types.str;
      default     = [];
      description = ''
        If non-empty, SSH (port 22) is reachable ONLY from these CIDRs/IPs
        in-guest, instead of being globally open. Service hosts set this (mirrors
        the Proxmox perimeter); compute hosts leave it empty (krg.firewall.geoip
        gates 22 to US+trusted by default per the fleet policy).
        Usually set via krg.base.serviceHost.
      '';
    };

    sourcedPorts = mkOption {
      type    = types.listOf (types.submodule {
        options = {
          port    = mkOption { type = types.port; };
          sources = mkOption { type = types.listOf types.str; };
        };
      });
      default     = [];
      description = ''
        TCP ports reachable ONLY from specific source CIDRs/IPs in-guest.
        Use for services that should be internal-only (e.g. OpenBao API on
        sealab nets) while still benefiting from in-guest defense-in-depth.
        Each entry: { port = <N>; sources = [ "cidr1" "cidr2" ... ]; }

        Sources can be either IPv4 (`1.2.3.0/24`) or IPv6 (`2001:db8::/32`);
        the module picks the right nftables match (`ip saddr` vs `ip6 saddr`)
        per-entry by detecting the colon. This lets the geoIP module
        (`krg.firewall.geoip`) feed mixed-family CIDR lists in one go.

        STRICTER than `allowedTCPPorts`'s geoIP default — use this when
        even US+trusted is too loose (e.g. sealab-only). The geoIP module's
        auto-promotion of `allowedTCPPorts` excludes ports listed here, so
        the tighter rule wins without operator coordination.

        See `sourcedUDPPorts` for the UDP counterpart (samba-ad uses both
        for its DNS / Kerberos / CLDAP UDP surfaces).
      '';
    };

    sourcedUDPPorts = mkOption {
      type    = types.listOf (types.submodule {
        options = {
          port    = mkOption { type = types.port; };
          sources = mkOption { type = types.listOf types.str; };
        };
      });
      default     = [];
      description = ''
        UDP counterpart of `sourcedPorts`. Same shape, same dual-stack
        v4/v6 source handling. Used by samba-ad on krg-ldap to keep DNS,
        Kerberos, and CLDAP UDP surfaces sealab-only (stricter than the
        geoIP US+trusted floor that would apply to allowedUDPPorts).
      '';
    };

    # Internal: modules that AUTO-GENERATE per-port source restrictions
    # (today: krg.firewall.geoip) emit here, not into sourcedPorts. Splitting
    # them avoids an infinite recursion when an auto-emitter wants to READ
    # sourcedPorts (to know what's already tighter) AND write its own entries.
    # Operators always write `sourcedPorts`; the firewall.nix extraInputRules
    # emits the union of both lists.
    _autoSourcedPorts = mkOption {
      type    = types.listOf (types.submodule {
        options = {
          port    = mkOption { type = types.port; };
          sources = mkOption { type = types.listOf types.str; };
        };
      });
      default     = [];
      internal    = true;
      description = "Internal: auto-emit channel for modules that derive sourced ports (e.g. geoIP). Operators use sourcedPorts.";
    };
  };

  config = mkMerge [
    # krg.firewall is the single switch for the OS firewall. Enabling it turns
    # on nftables + the rules below; disabling it (e.g. VMs where the hypervisor
    # owns the firewall) explicitly turns the NixOS firewall OFF rather than
    # letting it fall back to its restrictive enabled-by-default state.
    { networking.firewall.enable = cfg.enable; }

    (mkIf cfg.enable (let
      # Ports that already have a per-port restriction tighter than the
      # geoIP default. The geoIP module's auto-promotion (applyToPorts)
      # excludes these so it doesn't loosen them. firewall.nix excludes
      # them from the globally-open list for the same reason.
      sshSourceCovered     = if cfg.sshSources != [] then [ 22 ] else [];
      manualSourcedCovered = map (e: e.port) cfg.sourcedPorts;
      publicCovered        = cfg.publicPorts;
      alreadyTighter       = sshSourceCovered ++ manualSourcedCovered ++ publicCovered;
      geoipOn              = config.krg.firewall.geoip.enable or false;
    in {
      # Disjointness assertions (closes #83 + extends for publicPorts).
      # A port belongs in ONE list — overlapping lists silently shadow
      # each other or signal contradictory intent.
      assertions = [
        {
          # publicPorts vs allowedTCPPorts: opposite intent (globally open
          # vs geoIP-policy-gated). publicPorts wins (it's added to the
          # globally-open list unconditionally), so the allowedTCPPorts
          # entry is misleading.
          assertion = builtins.all (p: !(elem p cfg.allowedTCPPorts)) cfg.publicPorts;
          message = ''
            krg.firewall: port(s) appear in BOTH publicPorts (intentionally
            globally open) and allowedTCPPorts (US+trusted via geoIP).
            Opposite intent — pick one:
              - publicPorts     = [ N ]   # globally open (with reason comment)
              - allowedTCPPorts = [ N ]   # US+trusted via fleet geoIP default
            Offending overlap: ${toString (filter (p: elem p cfg.allowedTCPPorts) cfg.publicPorts)}
            (host: ${config.networking.hostName})
          '';
        }
        {
          # publicPorts vs sourcedPorts: opposite intent (globally open vs
          # source-restricted). sourcedPorts emits accept rules; publicPorts
          # adds to the globally-open list. Globally-open wins. Pick one.
          assertion = builtins.all
            (p: !(elem p (map (e: e.port) cfg.sourcedPorts))) cfg.publicPorts;
          message = ''
            krg.firewall: port(s) appear in BOTH publicPorts and sourcedPorts.
            Opposite intent — pick one:
              - publicPorts                                  # globally open
              - sourcedPorts = [{ port=N; sources=[...]; }]  # restricted
            Offending overlap: ${toString (filter (p: elem p (map (e: e.port) cfg.sourcedPorts)) cfg.publicPorts)}
            (host: ${config.networking.hostName})
          '';
        }
        {
          # allowedTCPPorts vs sourcedPorts overlap is REDUNDANT (the
          # sourcedPorts entry's tighter rule wins; the allowedTCPPorts
          # listing is just stylistic). Soft-fail (loud comment but
          # non-blocking) — flag the redundancy so operators clean it up.
          # NOTE: with geoIP off + this overlap, sourcedPorts would be
          # silently shadowed by the globally-open allowedTCPPorts entry,
          # which IS the original #83 bug — but the firewall.nix
          # networking.firewall.allowedTCPPorts computation below now
          # ALSO subtracts alreadyTighter, so the bug can't surface even
          # with geoIP off. Assertion is now about clarity, not safety.
          assertion = let
            srcSet = map (e: e.port) cfg.sourcedPorts;
          in builtins.all (p: !(elem p srcSet)) cfg.allowedTCPPorts;
          message = ''
            krg.firewall: port(s) appear in BOTH allowedTCPPorts AND
            sourcedPorts. The sourcedPorts (per-port-restricted) rule
            wins, so the allowedTCPPorts entry is REDUNDANT. Drop the
            duplicate from allowedTCPPorts:
              krg.firewall.sourcedPorts = [{ port=N; sources=[...]; }]
              # remove N from krg.firewall.allowedTCPPorts
            Offending overlap: ${toString (filter (p: elem p (map (e: e.port) cfg.sourcedPorts)) cfg.allowedTCPPorts)}
            (host: ${config.networking.hostName})
          '';
        }
      ];

      # extraInputRules uses nftables syntax; enable the nftables backend
      networking.nftables.enable = true;

      networking.firewall = {
        # The globally-open list is THE only place we add ports without a
        # source filter. With the fleet policy:
        #   * publicPorts unconditionally land here (operator explicit
        #     opt-in to globally-open; rare, ACME-only today).
        #   * allowedTCPPorts land here ONLY when geoIP is OFF (legacy
        #     behavior); when geoIP is on (the fleet default) they're
        #     handled by the geoIP module's sourcedPorts entries below.
        #   * Ports already covered by a tighter rule (sshSources,
        #     sourcedPorts) are filtered out in either case.
        #   * RDP unchanged: 3389 only joins globally-open when allowRDP
        #     is set AND rdpSources is empty (a configuration we don't
        #     use, but supported for completeness).
        allowedTCPPorts =
          cfg.publicPorts
          ++ (if geoipOn
              then []
              else filter (p: !(elem p alreadyTighter)) cfg.allowedTCPPorts)
          ++ optional (cfg.allowRDP && cfg.rdpSources == []) 3389;
        allowedUDPPorts = cfg.allowedUDPPorts;

        # nftables rules: monitoring-port scraping, source-restricted SSH /
        # RDP / sourcedPorts. ALL use anonymous inline sets (one rule per
        # port per family) instead of one rule per CIDR — keeps the ruleset
        # tractable even when the geoIP set is ~163K CIDRs. See the
        # `mkSourcedRules` helper at the top for the per-family split.
        extraInputRules =
          # Monitoring: one source IP per scrape port. Stays per-rule
          # (the source set is a single IP each).
          concatMapStringsSep "" (port:
            mkPortRule { proto = "tcp"; family = "ip saddr"; port = port;
                         sources = [ cfg.monitoringSourceIp ]; }
          ) cfg.monitoringPorts
          # SSH (22) from sshSources — one rule per family.
          + mkSourcedRules "tcp" { port = 22; sources = cfg.sshSources; }
          # RDP (3389) from rdpSources — one rule per family.
          + optionalString cfg.allowRDP
              (mkSourcedRules "tcp" { port = 3389; sources = cfg.rdpSources; })
          # sourcedPorts (TCP): operator-explicit + auto-derived (geoIP).
          # mkSourcedRules splits sources by family and emits at most one
          # `ip saddr { ... } tcp dport N accept` + one `ip6 saddr { ... }`
          # per entry, no matter how many CIDRs each contains.
          + concatMapStrings (mkSourcedRules "tcp") (cfg.sourcedPorts ++ cfg._autoSourcedPorts)
          # sourcedUDPPorts: same shape, udp.
          + concatMapStrings (mkSourcedRules "udp") cfg.sourcedUDPPorts;
      };
    }))
  ];
}
