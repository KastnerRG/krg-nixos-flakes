# Working remotely (outside the US)

Our fleet enforces "no public access — US is the floor" (issue #74). The
policy is implemented by the fleet **CrowdSec stack** (services.crowdsec
+ services.crowdsec-firewall-bouncer + services.geoipupdate, wired up in
[`nix/profiles/base.nix`](../nix/profiles/base.nix)) and by the
[`krg.firewall`](../nix/modules/security/firewall.nix) policy module,
which together produce two tiers:

| Tier | Hosts | Default SSH access |
|------|-------|--------------------|
| Strict (base) | krg-prod, e4e-prod, krg-ldap, krg-vault, krg-deploy | `ucsd` IPSet + `ops` IPSet only (nftables source restriction) |
| Relaxed (compute) | waiter | globally reachable, **gated by CrowdSec** (community blocklists + ssh-bf + geo-enriched bans) |

Why two tiers: compute hosts are research-user-facing, including visiting
researchers and lab members traveling within the US. Service hosts are
infrastructure and only need to be reachable by admins (who are normally on
campus or in `ops`).

If you're traveling **outside the US** and need SSH to any host:
- **Strict hosts**: blocked unconditionally unless you're in `ops` (the
  in-guest nftables rule has no exception path other than `ops`).
- **Compute hosts**: connection lands, but CrowdSec will ban your IP
  after almost any scenario triggers (one bad SSH attempt, port-scan-
  like behavior, or — if your source IP is on a community blocklist —
  before you even authenticate).

Either way, the answer is the same: **add yourself to `ops` before you fly.**

## The escape hatch: `ops`

`nix/networks/trusted.json`'s `ops` IPSet is the manual-override slot.
It serves two roles:

1. **Service hosts (nftables-level)**: `ops` CIDRs are unioned with
   `ucsd` into `krg.firewall.sshSources`, so they bypass the strict-tier
   source restriction outright.
2. **Compute hosts (CrowdSec-level)**: `ops` CIDRs are part of the
   CrowdSec **trusted-nets whitelist** (s02-enrich parser in
   [`nix/modules/security/crowdsec.nix`](../nix/modules/security/crowdsec.nix)).
   Events from `ops` IPs never raise alerts → never produce decisions →
   never end up in the bouncer's nftables ban set. So `ops` travelers
   pass cleanly even when their behavior would otherwise trip a scenario
   (e.g. a few authentication retries before the right key is in `ssh-agent`).

## Before you fly (the 60-second version)

1. Find a stable IP you'll have during your trip. Options, in order of
   preference:
   - Your home / family / hotel public IP. Stable for a week-long trip.
   - A residential proxy / VPN endpoint with a static IP that's
     consistently US-routed — easiest for compute, sufficient even for
     service hosts (still added to `ops`).
   - **Avoid**: airport WiFi, conference WiFi, anywhere the IP rotates
     every few minutes.
2. Open a PR adding your IP to `nix/networks/trusted.json` under
   `ipsets.ops`. Mirror the existing comment style so future-you knows
   which trip it was for:
   ```diff
    "ops": [
      { "cidr": "97.252.106.89",  "comment": "admin remote (chris)" },
      { "cidr": "107.132.34.148", "comment": "admin remote (sean)"},
   +  { "cidr": "203.0.113.42",   "comment": "admin remote (you) — japan trip 2026-Q3" }
    ],
   ```
3. Merge before you leave. NixOS hosts pick it up on the next nightly
   `autoUpgrade` (so merge at least a day before your travel day, or ssh
   in and `nixos-rebuild switch --flake ./nix#<host>` to force pickup
   if you're racing the timer). The CrowdSec whitelist is regenerated
   from `trusted.json` on every rebuild — no separate refresh step.
4. **Confirm from the trip IP** before you depart. If you can't test from
   the trip IP in advance, have a fallback (US-routed mobile eSIM, etc.).

## After you're back

Remove your `ops` entry — same place, just delete the line. Keeps the
override list minimal so a future leak of any one of those IPs has a
small blast radius.

## If you're stuck outside the US and forgot

Two options:

1. **Have someone in-lab add you.** They push from a campus IP (which
   passes the strict policy); the nightly `autoUpgrade` pulls it. If you
   need it *now*, they can ssh to the target host and
   `nixos-rebuild switch` after pushing.
2. **Hop through a US-routed host.** A cloud VPN endpoint that lands in
   US ranges typically passes CrowdSec on compute hosts (the community
   blocklists target known-malicious infra, not generic US VPN IPs). For
   strict hosts you'd still need the endpoint's IP added to `ops` —
   back to option 1.

## Why we don't auto-detect

We considered an "if SSH auth fails from a foreign IP, automatically allow
that IP for 5min" pattern. We rejected it: it has the same attack-surface
as not having any geo policy at all — an attacker who can knock the SSH
port can trigger the auto-allow. The point is to require an admin-driven
decision before opening the door.

## Where the policy is implemented

- Fleet baseline:
  [`nix/profiles/base.nix`](../nix/profiles/base.nix) — enables the
  CrowdSec stack (`krg.geoipupdate`, `krg.crowdsec`,
  `krg.crowdsecBouncer`), sets `krg.base.serviceHost = true` as the
  fleet default, and disables fail2ban (superseded by CrowdSec).
- Strict-tier SSH source restriction:
  [`nix/modules/security/firewall.nix`](../nix/modules/security/firewall.nix)
  via `sshSources` (populated from `ucsd` + `ops` in `base.nix` when
  `serviceHost = true`).
- Compute relaxation:
  [`nix/profiles/compute.nix`](../nix/profiles/compute.nix) — sets
  `krg.base.serviceHost = false` (clears sshSources, leaves SSH globally
  open behind CrowdSec).
- CrowdSec scenarios + whitelist:
  [`nix/modules/security/crowdsec.nix`](../nix/modules/security/crowdsec.nix)
  — installs the `crowdsecurity/sshd` collection (ssh-bf scenarios) and
  the `geoip-enrich` parser; whitelists `ucsd + sealab + ops + machines`
  via an s02-enrich parser.
- Explicit globally-public escape hatch:
  `krg.firewall.publicPorts = [ N ];` — operator-explicit, requires
  inline `# reason: ...` comment for PR review. Only legitimate use case
  today is ACME HTTP-01 (krg-vault:80 + krg-prod:80 — Let's Encrypt
  multi-perspective validation requires global reachability).
- Geo data source:
  [`nix/modules/security/geoipupdate.nix`](../nix/modules/security/geoipupdate.nix)
  — pulls MaxMind GeoLite2-Country.mmdb weekly to `/var/lib/GeoIP/`;
  CrowdSec's `geoip-enrich` parser reads it from there. License key
  lives at `/var/lib/krg/maxmind/license-key` (operator-distributed,
  NOT in the nix store or git).
- Trusted IPSets:
  [`nix/networks/trusted.json`](../nix/networks/trusted.json) — shared
  with the Ansible Proxmox firewall layer; the single source of truth
  for `sshSources` AND the CrowdSec whitelist.

## Check live state for a host

```bash
# Strict-tier SSH source restriction:
nix eval .#nixosConfigurations.<host>.config.krg.firewall.sshSources
nix eval --raw .#nixosConfigurations.<host>.config.networking.firewall.extraInputRules

# CrowdSec stack health (run on the host):
systemctl status crowdsec crowdsec-firewall-bouncer geoipupdate
sudo -u crowdsec cscli decisions list          # active bans right now
sudo -u crowdsec cscli metrics                 # parser/scenario hit counts
sudo nft list set inet crowdsec crowdsec-blacklists  # what's actually blocked

# Confirm CAPI registration (community blocklist feed) is healthy:
sudo -u crowdsec cscli capi status             # should report "You can successfully interact with Central API"

# Confirm geoIP enrichment is parsing events (NixOS = journald, not /var/log):
# The geoip-enrich parser populates evt.Enriched.IsoCode on each event.
# Easiest verification is the parser hit count in `cscli metrics`
# (look for "crowdsecurity/geoip-enrich" with a non-zero `reads` count).
# To exercise the parser on a known line:
journalctl -u sshd -n 1 -o cat \
  | sudo -u crowdsec cscli explain --type syslog --log -
```
