#!/usr/bin/env python3
"""Apply DSM Home Service config + per-user authorized_keys idempotently.

Subcommands:
  home              SYNO.Core.User.Home set (v1) — enable + include-domain-users.
                    FULL-OBJECT (partial = err 2001): GET → overlay → SET.
  authorized-keys   Write ~<user>/.ssh/authorized_keys atomically with the given
                    key list (one per line). 0600 / 0700, owner = the user.
                    Idempotent: compares to current; only writes on drift.

Invoked by the synology_users ansible role via the `script` module (DSM py3.8 —
template:/copy: ansible modules don't work; script: does).

OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>.

Field mapping (DSM 7.3 best-known — empirical confirmation pending; flip
OUT_KEYS on first-apply drift):
  enable                  -> enable_homes
  include_domain_users    -> enable_user_home_join_domain
"""
import argparse
import json
import os
import pwd
import subprocess
import sys
import tempfile

WEBAPI = "/usr/syno/bin/synowebapi"
HOME_API = "SYNO.Core.User.Home"

OUT_KEYS = {
    "enable":                "enable_homes",
    "include_domain_users":  "enable_user_home_join_domain",
}


def _exec(api, *params):
    out = subprocess.run(
        [WEBAPI, "--exec", "api=" + api, *params],
        capture_output=True, text=True,
    )
    txt = out.stdout
    brace = txt.find("{")
    if brace < 0:
        raise RuntimeError("no JSON in synowebapi output: " + (txt or out.stderr))
    return json.loads(txt[brace:])


def _bool(s):
    return str(s).strip().lower() in ("1", "true", "yes", "on")


def _args_from(data):
    args = []
    for key, val in data.items():
        if val is None:
            continue
        if isinstance(val, bool):
            val = "true" if val else "false"
        elif isinstance(val, (dict, list)):
            val = json.dumps(val)
        args.append("{}={}".format(key, val))
    return args


def _result(drift, check, apply_fn):
    if not drift:
        print("OK no-change")
        return 0
    if check:
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True, default=str))
        return 0
    res = apply_fn()
    if res.get("success"):
        print("CHANGED " + json.dumps(drift, sort_keys=True, default=str))
        return 0
    print("FAIL " + json.dumps(res))
    return 1


# --- home (SYNO.Core.User.Home, full-object) --------------------------------------
def do_home(a):
    desired = {
        OUT_KEYS["enable"]:               _bool(a.enable),
        OUT_KEYS["include_domain_users"]: _bool(a.include_domain_users),
    }
    current = _exec(HOME_API, "version=1", "method=get")["data"]
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(HOME_API, "version=1", "method=set", *_args_from(current))

    return _result(drift, a.check, apply)


# --- authorized-keys (write ~user/.ssh/authorized_keys atomically) ----------------
def _normalize(keys):
    """Drop blanks, strip whitespace, dedupe (order-preserving), ensure trailing newline."""
    seen, out = set(), []
    for k in keys:
        k = (k or "").strip()
        if not k or k in seen:
            continue
        seen.add(k)
        out.append(k)
    return ("\n".join(out) + "\n") if out else ""


def do_authorized_keys(a):
    try:
        keys = json.loads(a.keys)
    except json.JSONDecodeError:
        raise SystemExit("--keys must be a JSON list of strings")
    if not isinstance(keys, list):
        raise SystemExit("--keys must be a JSON list of strings")

    desired = _normalize(keys)
    try:
        pw = pwd.getpwnam(a.username)
    except KeyError:
        # User doesn't exist yet (sync race with user-creation task). Best-effort
        # bail: not an error — the role's next run will pick it up.
        print("OK no-change")
        return 0

    home = pw.pw_dir
    ssh_dir = os.path.join(home, ".ssh")
    auth = os.path.join(ssh_dir, "authorized_keys")
    try:
        with open(auth) as f:
            current = f.read()
    except FileNotFoundError:
        current = None

    drift_summary = {
        "user": a.username,
        "path": auth,
        "exists": current is not None,
        "bytes_current": len(current) if current is not None else 0,
        "bytes_desired": len(desired),
        "keys_desired": desired.count("\n") if desired else 0,
    }

    # Empty desired: if a file exists, we LEAVE it alone rather than wipe (a user
    # may have added a personal key out-of-band; we don't claim exclusive
    # ownership of authorized_keys here). This matches ansible.posix.authorized_key
    # with exclusive: false on the Debian side.
    if not desired:
        print("OK no-change")
        return 0

    if current == desired:
        print("OK no-change")
        return 0

    if a.check:
        print("WOULD-CHANGE " + json.dumps(drift_summary, sort_keys=True))
        return 0

    try:
        # ~/.ssh must exist with 0700 owned by the user — sshd refuses otherwise.
        os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
        os.chown(ssh_dir, pw.pw_uid, pw.pw_gid)
        os.chmod(ssh_dir, 0o700)
        with tempfile.NamedTemporaryFile("w", dir=ssh_dir, delete=False,
                                         prefix=".authorized_keys.",
                                         suffix=".tmp") as tf:
            tf.write(desired)
            tmp = tf.name
        os.chmod(tmp, 0o600)
        os.chown(tmp, pw.pw_uid, pw.pw_gid)
        os.replace(tmp, auth)
    except OSError as e:
        print("FAIL " + json.dumps({"error": str(e)}))
        return 1

    print("CHANGED " + json.dumps(drift_summary, sort_keys=True))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM Home Service + authorized_keys.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    h = sub.add_parser("home", help="User.Home (enable + include-domain-users)")
    h.add_argument("--enable", required=True)
    h.add_argument("--include-domain-users", dest="include_domain_users", required=True)
    h.add_argument("--check", action="store_true")
    h.set_defaults(func=do_home)

    k = sub.add_parser("authorized-keys", help="Write ~user/.ssh/authorized_keys")
    k.add_argument("--username", required=True)
    k.add_argument("--keys", required=True, help="JSON list of public-key strings")
    k.add_argument("--check", action="store_true")
    k.set_defaults(func=do_authorized_keys)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
