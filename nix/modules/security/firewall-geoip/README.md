# firewall-geoip — design + operator notes

The fleet-wide "no public access — US is the floor" gate
([issue #74](https://github.com/KastnerRG/krg-infra/issues/74)). Pairs
with `nix/modules/security/firewall.nix` (the in-guest firewall) and
`ansible/roles/proxmox_firewall` (the Proxmox perimeter, separate
layer, same `krg_geoip_us` data source).

## Files

| File | Purpose |
|------|---------|
| `../firewall-geoip.nix` | The Nix module (`krg.firewall.geoip` option). Reads `nix/networks/geoip-<cc>-{v4,v6}.json` and emits `krg.firewall._autoSourcedPorts` entries for each port in `applyToPorts`. Default-on per `nix/profiles/base.nix`. |
| `fetch-geoip.py` | The data refresher. Downloads MaxMind GeoLite2-Country-CSV, filters for `--countries`, coalesces adjacent prefixes via `ipaddress.collapse_addresses`, writes deterministic JSON. Stdlib only — runs on any Python 3.8+. |
| `test_fetch_geoip.py` | 9 unit tests on synthetic GeoLite2-shaped zips. Run: `pytest nix/modules/security/firewall-geoip/`. |
| `../../../../.github/workflows/refresh-geoip.yml` | Monthly cron + manual-dispatch workflow that runs `fetch-geoip.py` and opens an auto-PR with the diff. |
| `../../../networks/geoip-us-{v4,v6}.json` | The committed CIDR data. Same role as `flake.lock`: in-repo, refreshed via PR, reviewed before fleet rollout. |

## Why the data file lives in the repo (not auto-fetched on each host)

The original design had a systemd timer on `krg-deploy` that fetched
weekly + auto-committed + pushed. Replaced with the flake.lock pattern
because:

- **Fresh-deploy chicken-and-egg**: empty-seed JSON + 04:30 autoUpgrade
  meant a host's first rebuild gated SSH to `ucsd + sealab + ops` only
  (no US) — locking out US-based admins/researchers until the operator
  wired MaxMind license in OpenBao, generated a git deploy key, added
  it to the repo, enabled the timer, and waited a week. Now the data
  ships populated, every deploy works from day one.
- **Reviewability**: PR diffs are visible to humans (same as flake.lock
  bumps); silent auto-commits aren't.
- **Operational simplicity**: no OpenBao integration, no git deploy
  creds, no staleness textfile alert, no daemon-on-krg-deploy. The
  GitHub Action does it in 30 lines using the standard `GITHUB_TOKEN`.

## How a refresh lands

1. **Cron fires** (1st of month, 04:00 UTC) OR an operator triggers
   `workflow_dispatch` in the Actions tab.
2. **Workflow runs** `fetch-geoip.py` against MaxMind (license key
   from `secrets.MAXMIND_LICENSE_KEY` — set once at repo Settings →
   Secrets → Actions).
3. **If the diff is non-empty**, the workflow force-pushes to
   `auto/refresh-geoip` and opens / updates a PR.
4. **`build.yml` runs on the PR** — `nix flake check --all-systems`
   catches a corrupted JSON before merge.
5. **Reviewer approves** (treat like a flake.lock bump — stat line
   sanity-check, don't read every CIDR).
6. **Merge** — every host picks up the refreshed CIDR set on the next
   nightly autoUpgrade.

If the cron doesn't fire (workflow disabled, MaxMind down for the day,
etc.), nothing breaks — the previous month's data keeps working. There's
no staleness alarm by design; if MaxMind data drift bites a real user
(visiting researcher's IP fell out of `geoip_us`), `ops` is the
escape hatch (see [`docs/working-remotely.md`](../../../../docs/working-remotely.md)).

## Manual refresh (operator)

```bash
# One-shot, locally. Same script the CI workflow uses; no extra tooling.
MAXMIND_LICENSE_KEY=<key> python3 nix/modules/security/firewall-geoip/fetch-geoip.py \
  --countries US --output-dir nix/networks
git add nix/networks/geoip-us-*.json
git commit -m "chore(geoip): manual refresh"
gh pr create  # or push and open a PR by hand
```

If your environment's Python can't reach MaxMind (uv-installed Python
with no system CA bundle, etc.), download via `curl` first:

```bash
key=<your-maxmind-license-key>
tmp=$(mktemp --suffix=.zip)
curl --fail -L -o "$tmp" \
  "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country-CSV&suffix=zip&license_key=$key"
python3 nix/modules/security/firewall-geoip/fetch-geoip.py \
  --countries US --output-dir nix/networks --zip-path "$tmp"
rm "$tmp"
```

## Adding a country

Edit the `--countries` arg in `.github/workflows/refresh-geoip.yml`
(comma-separated) — the script writes `geoip-<cc>-{v4,v6}.json` per
country. Then update `krg.firewall.geoip.allowedCountries` on the hosts
that should accept the new country. Operator decision per host; the
default is `US`-only.
