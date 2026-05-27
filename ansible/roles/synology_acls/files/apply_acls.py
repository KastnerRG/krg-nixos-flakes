#!/usr/bin/env python3
"""Apply DSM share-level ACL grants (synoshare --setuser) idempotently.

The share -> principal grant matrix from spec/krg-prod/acls.yml. Each grant names a
`group` (DSM needs an `@` prefix — a bare group name silently no-ops!) or a `user`, with
`access: rw|ro|no` (-> DSM tiers RW/RO/NA). We read the current tiers with
`synoshare --list_acl`, diff, and only re-set the tiers that drift, using the `=`
operator (sets each tier's list EXACTLY — declarative; extras are removed and a principal
auto-moves to its single tier). Validated on the DSM 7.3.2-86009 rig.

Run by the synology_acls role via the `script` module (DSM's Python 3.8). Prints
OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <msg>.

SCOPE: this is the SHARE-level grant (DSM also writes it to the share-root filesystem
ACL). Recursive filesystem-ACL re-apply for *preserved data* carrying dead old-domain
SIDs (`synoacltool`, runbook) is a separate post-AD-join concern, not this role.
"""
import argparse
import json
import re
import subprocess
import sys

SYNOSHARE = "/usr/syno/sbin/synoshare"
TIER = {"rw": "RW", "ro": "RO", "no": "NA"}


def _run(*args):
    return subprocess.run([SYNOSHARE, *args], capture_output=True, text=True)


def current_tiers(share):
    """Parse `synoshare --list_acl` -> {RW,RO,NA: set(principals)} (groups are @name)."""
    out = _run("--list_acl", share).stdout
    tiers = {}
    for t in ("RW", "RO", "NA"):
        m = re.search(r"ACL " + t + r" List\s*\.*\[(.*?)\]", out)
        items = m.group(1).split(",") if (m and m.group(1)) else []
        tiers[t] = {x for x in items if x}
    return tiers


def desired_tiers(grants):
    tiers = {"RW": set(), "RO": set(), "NA": set()}
    for g in grants:
        if "group" in g:
            name = "@" + g["group"]
        elif "user" in g:
            name = g["user"]
        else:
            raise SystemExit("grant needs 'group' or 'user': " + json.dumps(g))
        tier = TIER.get(str(g.get("access", "")).lower())
        if not tier:
            raise SystemExit("grant 'access' must be rw|ro|no: " + json.dumps(g))
        tiers[tier].add(name)
    return tiers


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--share", required=True)
    ap.add_argument("--grants", required=True, help="JSON array of {group|user, access}")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)

    desired = desired_tiers(json.loads(a.grants))
    current = current_tiers(a.share)
    drift = {
        t: {"current": sorted(current[t]), "desired": sorted(desired[t])}
        for t in ("RW", "RO", "NA")
        if current[t] != desired[t]
    }

    if not drift:
        print("OK no-change")
        return 0
    if a.check:
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True))
        return 0
    for t in drift:  # `=` sets the tier exactly; empty string clears it
        r = _run("--setuser", a.share, t, "=", ",".join(sorted(desired[t])))
        if r.returncode != 0:
            print("FAIL setuser %s %s: %s" % (a.share, t, (r.stderr or r.stdout).strip()))
            return 1
    print("CHANGED " + json.dumps(drift, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
