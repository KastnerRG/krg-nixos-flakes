#!/usr/bin/env python3
"""Refresh nix/networks/geoip-<cc>-{v4,v6}.json from MaxMind GeoLite2-Country.

Consumer: nix/modules/security/firewall-geoip.nix (krg.firewall.geoip).
Runner:   the fetch-geoip systemd timer on krg-deploy (weekly cadence).

Flow:
  1. Download GeoLite2-Country-CSV ZIP from MaxMind (needs a free license
     key — obtain from https://www.maxmind.com/en/geolite2/signup; store
     at `secret/krg-deploy/maxmind-geolite2` field `license_key` in OpenBao
     and have systemd inject it as env var MAXMIND_LICENSE_KEY).
  2. Parse the bundled CSVs:
       Locations-en.csv  → geoname_id → ISO 3166-1 alpha-2
       Blocks-IPv4.csv   → CIDR → geoname_id
       Blocks-IPv6.csv   → CIDR → geoname_id
  3. Filter blocks for the requested countries (`--countries US`).
  4. Coalesce adjacent prefixes via ipaddress.collapse_addresses to keep
     the resulting nftables interval set small (US v4 collapses from
     ~75K entries to ~70K, modest savings; mainly correctness — coalescing
     also strips duplicates and accidental overlaps).
  5. Sort the CIDRs (alphabetical-by-network — stable diff output) and
     write geoip-<cc>-{v4,v6}.json files matching the shape the
     firewall-geoip Nix module reads.

Usage (manual):
  MAXMIND_LICENSE_KEY=xxxx ./fetch-geoip.py \\
    --countries US --output-dir nix/networks

  # Dry-run (no network, useful for testing the parser against a local ZIP):
  ./fetch-geoip.py --countries US --output-dir /tmp/out \\
    --zip-path /tmp/GeoLite2-Country-CSV.zip

Stdlib-only on purpose: krg-deploy doesn't get extra Python packages just
for this. urllib.request handles the HTTP download; zipfile/csv handle the
parse; ipaddress.collapse_addresses handles coalescing.
"""
import argparse
import csv
import io
import ipaddress
import json
import os
import sys
import urllib.request
import zipfile
from datetime import datetime, timezone

MAXMIND_URL = (
    "https://download.maxmind.com/app/geoip_download"
    "?edition_id=GeoLite2-Country-CSV&suffix=zip&license_key={key}"
)
SOURCE = "MaxMind GeoLite2-Country-CSV (https://www.maxmind.com/en/geolite2)"


def fetch_zip(license_key, dest_path):
    """Download the GeoLite2-Country-CSV zip to dest_path."""
    url = MAXMIND_URL.format(key=license_key)
    req = urllib.request.Request(url, headers={"User-Agent": "krg-infra-fetch-geoip/1.0"})
    # urllib raises HTTPError for non-2xx — the `resp.status != 200` check
    # the obvious-looking version would do is unreachable. Surface the
    # common failure modes (bad/revoked license key → 401, MaxMind quota
    # → 429, MaxMind down → 5xx) as a friendly SystemExit instead of a
    # raw urllib traceback; the workflow log gets the operator-actionable
    # message instead of "_ssl.c:1081" noise.
    try:
        resp = urllib.request.urlopen(req, timeout=60)
    except urllib.error.HTTPError as e:
        hint = (
            "license key rejected (check secrets.MAXMIND_LICENSE_KEY at the repo level "
            "or the env var locally; rotate at https://www.maxmind.com/en/accounts)"
            if e.code in (401, 403)
            else "MaxMind quota or rate-limit"
            if e.code == 429
            else "MaxMind upstream error"
        )
        raise SystemExit(
            "MaxMind download failed: HTTP " + str(e.code) + " — " + hint)
    except urllib.error.URLError as e:
        raise SystemExit("MaxMind download failed: network/TLS error — " + str(e.reason))
    with resp, open(dest_path, "wb") as f:
        # 16MB chunks; the zip is ~10MB so this completes in one read most days.
        while True:
            chunk = resp.read(16 * 1024 * 1024)
            if not chunk:
                break
            f.write(chunk)


def parse_locations(zip_ref):
    """Return {geoname_id: 'US'|'CA'|...}. Skip rows with no country_iso_code
    (anonymous/satellite/EU-aggregate entries)."""
    # The ZIP contents are under a versioned dir GeoLite2-Country-CSV_YYYYMMDD/.
    # Find the locations CSV; English is fine for ISO code extraction.
    loc_name = next(
        n for n in zip_ref.namelist()
        if n.endswith("GeoLite2-Country-Locations-en.csv")
    )
    geoname_to_country = {}
    with zip_ref.open(loc_name) as raw:
        reader = csv.DictReader(io.TextIOWrapper(raw, encoding="utf-8"))
        for row in reader:
            iso = row.get("country_iso_code", "").strip()
            if not iso:
                continue
            geoname_to_country[row["geoname_id"]] = iso
    return geoname_to_country


def parse_blocks(zip_ref, family):
    """Yield (cidr_str, geoname_id) pairs from the v4 or v6 blocks CSV.

    GeoLite2 has TWO geoname_id columns:
      geoname_id           — the actual location of the block
      registered_country_geoname_id  — the country the IP is registered in
    Prefer geoname_id (where the block IS); fall back to registered when
    blank (some satellite/anonymous proxy blocks have no location_geoname_id
    but DO have a registered country). Both are sufficient for "is this US?"
    """
    fam_suffix = "Blocks-IPv4.csv" if family == "v4" else "Blocks-IPv6.csv"
    blocks_name = next(
        n for n in zip_ref.namelist()
        if n.endswith("GeoLite2-Country-" + fam_suffix)
    )
    with zip_ref.open(blocks_name) as raw:
        reader = csv.DictReader(io.TextIOWrapper(raw, encoding="utf-8"))
        for row in reader:
            cidr = row.get("network", "").strip()
            if not cidr:
                continue
            gid = (row.get("geoname_id", "").strip()
                   or row.get("registered_country_geoname_id", "").strip())
            if not gid:
                continue
            yield cidr, gid


def collect_cidrs(zip_ref, geoname_to_country, wanted_countries, family):
    """Return a sorted, coalesced list of CIDR strings for the wanted countries."""
    wanted = set(c.upper() for c in wanted_countries)
    nets = []
    for cidr, gid in parse_blocks(zip_ref, family):
        cc = geoname_to_country.get(gid)
        if cc not in wanted:
            continue
        try:
            nets.append(ipaddress.ip_network(cidr, strict=True))
        except ValueError:
            # Skip malformed rows rather than aborting the whole refresh —
            # MaxMind CSVs are clean but we shouldn't let one bad row 502 the
            # whole timer.
            continue
    # collapse_addresses requires all inputs to be the same IP version;
    # MaxMind already splits v4 vs v6 into separate CSVs so this holds.
    coalesced = list(ipaddress.collapse_addresses(nets))
    # Stable diff output: sort by network address.
    coalesced.sort(key=lambda n: (n.version, int(n.network_address), n.prefixlen))
    return [str(n) for n in coalesced]


def write_json(out_path, country, family, cidrs):
    """Atomic write — tempfile + os.replace so a concurrent reader (the
    flake eval) never sees a half-written file."""
    payload = {
        "_comment": (
            "AUTO-GENERATED — DO NOT EDIT MANUALLY. Refreshed weekly by the "
            "fetch-geoip systemd timer on krg-deploy from MaxMind "
            "GeoLite2-Country. Edits get overwritten. Source: "
            "nix/modules/security/firewall-geoip/fetch-geoip.py. Consumer: "
            "nix/modules/security/firewall-geoip.nix (krg.firewall.geoip option)."
        ),
        "country": country.upper(),
        "ip_version": family,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": SOURCE,
        "cidrs": cidrs,
    }
    tmp = out_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")
    os.replace(tmp, out_path)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--countries", required=True,
                    help="comma-separated ISO codes (e.g. US,CA)")
    ap.add_argument("--output-dir", required=True,
                    help="directory to write geoip-<cc>-{v4,v6}.json")
    ap.add_argument("--zip-path",
                    help="use an existing zip file instead of downloading "
                         "(testing / cached-data path)")
    ap.add_argument("--license-key",
                    help="MaxMind license key (falls back to MAXMIND_LICENSE_KEY env)")
    a = ap.parse_args(argv)

    countries = [c.strip().upper() for c in a.countries.split(",") if c.strip()]
    if not countries:
        raise SystemExit("--countries cannot be empty")
    if not os.path.isdir(a.output_dir):
        raise SystemExit("--output-dir doesn't exist: " + a.output_dir)

    if a.zip_path:
        if not os.path.isfile(a.zip_path):
            raise SystemExit("--zip-path doesn't exist: " + a.zip_path)
        zip_path = a.zip_path
        cleanup = False
    else:
        key = a.license_key or os.environ.get("MAXMIND_LICENSE_KEY")
        if not key:
            raise SystemExit(
                "no MaxMind license key: pass --license-key or set "
                "MAXMIND_LICENSE_KEY env (read from "
                "secret/krg-deploy/maxmind-geolite2 via bao)")
        zip_path = os.path.join(a.output_dir, ".geolite2-country.zip.tmp")
        fetch_zip(key, zip_path)
        cleanup = True

    try:
        with zipfile.ZipFile(zip_path) as zf:
            geoname_to_country = parse_locations(zf)
            for cc in countries:
                for family in ("v4", "v6"):
                    cidrs = collect_cidrs(zf, geoname_to_country, [cc], family)
                    out = os.path.join(a.output_dir, "geoip-" + cc.lower() + "-" + family + ".json")
                    write_json(out, cc, family, cidrs)
                    print("wrote " + out + ": " + str(len(cidrs)) + " CIDRs")
    finally:
        if cleanup and os.path.exists(zip_path):
            os.remove(zip_path)

    return 0


if __name__ == "__main__":
    sys.exit(main())
