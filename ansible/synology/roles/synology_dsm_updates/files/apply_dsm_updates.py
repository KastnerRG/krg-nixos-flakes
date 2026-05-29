#!/usr/bin/env python3
"""Apply DSM auto-update policy idempotently via synowebapi. Two subcommands:

  setting   SYNO.Core.Upgrade.Setting set (v1) — policy (hotfix-security|...) +
            schedule (day/hour/minute) + notify-email. FULL-OBJECT (partial = err
            2001): GET → overlay managed keys → SET, only on drift.
  channel   SYNO.Core.Upgrade.Server set (v1) — stable|beta channel selection.

Invoked by the synology_dsm_updates ansible role via the `script` module (DSM's
Python 3.8 — same constraint as apply_dsm_web). OK no-change / WOULD-CHANGE <json>
/ CHANGED <json> / FAIL <json>; the role keys changed_when/failed_when off that.

Field mapping (DSM 7.3 best-known — empirical confirmation pending; the helper is
permissive about unknown DSM-side keys because we GET → overlay → SET):
  policy                  -> auto_update_type   ("hotfix-security"|"hotfix"|"smart"|"nothing")
  auto_install_enabled    -> enable_auto_update (bool)
  notify_email_on_install -> notify_email       (bool)
  schedule.day/hour/min   -> upgrade_day/hour/min (day = Sun..Sat string)
  channel                 -> Upgrade.Server `type` ("stable"|"beta")

If a field name differs on the live box (first apply will surface drift), update
the OUT_KEYS map below — single source of truth.
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
UPD_SETTING_API = "SYNO.Core.Upgrade.Setting"
UPD_SERVER_API = "SYNO.Core.Upgrade.Server"

# Spec-field -> DSM-field. Best-known mapping; flip values here if drift on first apply.
OUT_KEYS = {
    "policy": "auto_update_type",
    "auto_install": "enable_auto_update",
    "notify_email": "notify_email",
    "day": "upgrade_day",
    "hour": "upgrade_hour",
    "minute": "upgrade_min",
}


def _exec(api, *params):
    """Run synowebapi; preamble on stderr, JSON on stdout."""
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
    """dict -> synowebapi key=value tokens (bool->true/false, null skipped, list/dict->JSON)."""
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
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True))
        return 0
    res = apply_fn()
    if res.get("success"):
        print("CHANGED " + json.dumps(drift, sort_keys=True))
        return 0
    print("FAIL " + json.dumps(res))
    return 1


# --- setting (SYNO.Core.Upgrade.Setting, full-object) -----------------------------
def do_setting(a):
    desired = {
        OUT_KEYS["policy"]:        a.policy,
        OUT_KEYS["auto_install"]:  _bool(a.auto_install),
        OUT_KEYS["notify_email"]:  _bool(a.notify_email),
        OUT_KEYS["day"]:           a.day,
        OUT_KEYS["hour"]:          int(a.hour),
        OUT_KEYS["minute"]:        int(a.minute),
    }
    current = _exec(UPD_SETTING_API, "version=1", "method=get")["data"]
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(UPD_SETTING_API, "version=1", "method=set", *_args_from(current))

    return _result(drift, a.check, apply)


# --- channel (SYNO.Core.Upgrade.Server) -------------------------------------------
def do_channel(a):
    desired = {"type": a.channel}
    current = _exec(UPD_SERVER_API, "version=1", "method=get")["data"]
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(UPD_SERVER_API, "version=1", "method=set", *_args_from(current))

    return _result(drift, a.check, apply)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM auto-update policy via synowebapi.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("setting", help="Upgrade.Setting (policy + schedule + notify)")
    s.add_argument("--policy", required=True)
    s.add_argument("--auto-install", dest="auto_install", required=True)
    s.add_argument("--notify-email", dest="notify_email", required=True)
    s.add_argument("--day", required=True)
    s.add_argument("--hour", required=True)
    s.add_argument("--minute", required=True)
    s.add_argument("--check", action="store_true")
    s.set_defaults(func=do_setting)

    c = sub.add_parser("channel", help="Upgrade.Server (update channel)")
    c.add_argument("--channel", required=True, choices=["stable", "beta"])
    c.add_argument("--check", action="store_true")
    c.set_defaults(func=do_channel)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
