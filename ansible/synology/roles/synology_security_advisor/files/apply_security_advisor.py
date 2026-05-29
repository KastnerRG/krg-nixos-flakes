#!/usr/bin/env python3
"""Apply DSM Security Advisor config idempotently via synowebapi. One subcommand:

  main   SYNO.SDS.SecurityScan.Main set (v1) — enable + weekly schedule + categories +
         notify-email. FULL-OBJECT pattern (partial = err 2001): GET → overlay
         managed keys → SET, only on drift.

Invoked by the synology_security_advisor ansible role via the `script` module (DSM's
Python 3.8 — same constraint as apply_dsm_web). OK no-change / WOULD-CHANGE <json>
/ CHANGED <json> / FAIL <json>; the role keys changed_when/failed_when off that.

Field mapping (DSM 7.3 best-known — empirical confirmation pending; the captured
scheduler entry showed `SYNO.Core.SecurityScan.Operation start`, confirming Operation
runs scans but NOT confirming the Main config-set field names. Flip OUT_KEYS below
on first-apply drift):
  enabled                  -> enable          (bool)
  schedule.day             -> schedule_day    ("Sun".."Sat")
  schedule.hour            -> schedule_hour   (int)
  schedule.minute          -> schedule_min    (int)
  scan_categories          -> categories      (JSON list of strings)
  notify_email_on_finding  -> notify_email    (bool)

If `Main` does NOT own the schedule on the live box, fall back to managing a
SYNO.Core.EventScheduler entry that calls Operation.start (TODO follow-up; the
captured task on the live NAS suggests this is how DSM does it under the hood).
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
SA_MAIN_API = "SYNO.SDS.SecurityScan.Main"

# Spec-field -> DSM-field. Best-known; flip values here on first-apply drift.
OUT_KEYS = {
    "enable":         "enable",
    "day":            "schedule_day",
    "hour":           "schedule_hour",
    "minute":         "schedule_min",
    "categories":     "categories",
    "notify_email":   "notify_email",
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
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True, default=str))
        return 0
    res = apply_fn()
    if res.get("success"):
        print("CHANGED " + json.dumps(drift, sort_keys=True, default=str))
        return 0
    print("FAIL " + json.dumps(res))
    return 1


# --- main (SYNO.SDS.SecurityScan.Main, full-object) -------------------------------
def do_main(a):
    cats = json.loads(a.categories) if a.categories else []
    if not isinstance(cats, list):
        raise SystemExit("--categories must be a JSON list")
    desired = {
        OUT_KEYS["enable"]:        _bool(a.enable),
        OUT_KEYS["day"]:           a.day,
        OUT_KEYS["hour"]:          int(a.hour),
        OUT_KEYS["minute"]:        int(a.minute),
        OUT_KEYS["categories"]:    sorted(cats),
        OUT_KEYS["notify_email"]:  _bool(a.notify_email),
    }
    current = _exec(SA_MAIN_API, "version=1", "method=get")["data"]
    # Compare categories as sorted lists so order-only drift doesn't false-positive.
    cur_norm = dict(current)
    if isinstance(cur_norm.get(OUT_KEYS["categories"]), list):
        cur_norm[OUT_KEYS["categories"]] = sorted(cur_norm[OUT_KEYS["categories"]])
    drift = {k: {"current": cur_norm.get(k), "desired": v}
             for k, v in desired.items() if cur_norm.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(SA_MAIN_API, "version=1", "method=set", *_args_from(current))

    return _result(drift, a.check, apply)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM Security Advisor config via synowebapi.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("main", help="SecurityScan.Main (enable + schedule + categories + notify)")
    s.add_argument("--enable", required=True)
    s.add_argument("--day", required=True)
    s.add_argument("--hour", required=True)
    s.add_argument("--minute", required=True)
    s.add_argument("--categories", required=True, help="JSON list of strings")
    s.add_argument("--notify-email", dest="notify_email", required=True)
    s.add_argument("--check", action="store_true")
    s.set_defaults(func=do_main)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
