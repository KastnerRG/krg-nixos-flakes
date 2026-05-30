# Working remotely (outside the US)

Our fleet enforces "no public access — US is the floor" (issue #74). The
firewall policy in [`nix/modules/security/firewall.nix`](../nix/modules/security/firewall.nix)
and [`nix/profiles/base.nix`](../nix/profiles/base.nix) implements two
tiers:

| Tier | Hosts | Default SSH access |
|------|-------|--------------------|
| Strict (base) | krg-prod, e4e-prod, krg-ldap, krg-vault, krg-deploy | `ucsd` IPSet + `ops` IPSet only |
| Relaxed (compute) | waiter | strict ∪ **US CIDRs** (via geoIP) |

Why two tiers: compute hosts are research-user-facing, including visiting
researchers and lab members traveling within the US. Service hosts are
infrastructure and only need to be reachable by admins (who are normally on
campus or in `ops`).

If you're traveling **outside the US** and need SSH to any host:
- **Strict hosts**: blocked unconditionally unless you're in `ops`.
- **Compute hosts**: blocked unless you're in `ops` OR in a US-routed IP
  range (rare for international hotels/conferences).

Either way, the answer is the same: **add yourself to `ops` before you fly.**

## The escape hatch: `ops`

`nix/networks/trusted.json`'s `ops` IPSet is the manual-override slot — it
applies to *every* gated port across the fleet (both tiers), unioned in
before any country-based check. Travelers in `ops` get through regardless
of geo.

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
   if you're racing the timer).
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
   US ranges works for compute hosts. For strict hosts you'd need the
   VPN IP added to `ops` — back to option 1.

## Why we don't auto-detect

We considered an "if SSH auth fails from a foreign IP, automatically allow
that IP for 5min" pattern. We rejected it: it has the same attack-surface
as not having geoIP at all — an attacker who can knock the SSH port can
trigger the auto-allow. The point is to require an admin-driven decision
before opening the door.

## Where the policy is implemented

- Fleet policy:
  [`nix/profiles/base.nix`](../nix/profiles/base.nix) — sets
  `krg.firewall.geoip.enable = true` + `krg.base.serviceHost = true` as
  defaults.
- Compute relaxation:
  [`nix/profiles/compute.nix`](../nix/profiles/compute.nix) — sets
  `krg.base.serviceHost = false` (clears sshSources, lets geoIP route 22
  to US+trusted).
- Explicit globally-public escape hatch:
  `krg.firewall.publicPorts = [ N ];` — operator-explicit, requires
  inline `# reason: ...` comment for PR review. Only legitimate use case
  today is ACME HTTP-01 (krg-vault:80 — Let's Encrypt multi-perspective
  validation requires global reachability).
- Geo data source:
  [`nix/networks/geoip-us-{v4,v6}.json`](../nix/networks/) — refreshed
  weekly by the `fetch-geoip` systemd timer on krg-deploy from MaxMind
  GeoLite2-Country.
- Trusted IPSets:
  [`nix/networks/trusted.json`](../nix/networks/trusted.json) — shared
  with the Ansible Proxmox firewall layer.

## Check live state for a host

```bash
# What does the host actually have configured?
nix eval .#nixosConfigurations.<host>.config.krg.firewall.geoip.applyToPorts
nix eval .#nixosConfigurations.<host>.config.krg.firewall.sshSources
nix eval --raw .#nixosConfigurations.<host>.config.networking.firewall.extraInputRules
```
