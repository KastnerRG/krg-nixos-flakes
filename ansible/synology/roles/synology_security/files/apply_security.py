#!/usr/bin/env python3
"""Apply DSM security perimeter (firewall + auto-block) idempotently via synowebapi.
Subcommands:
  firewall     — SYNO.Core.Security.Firewall set (enable, profile_name) — full-object.
  fw-conf      — SYNO.Core.Security.Firewall.Conf set (port_check) — full-object.
  autoblock    — SYNO.Core.Security.AutoBlock set (enable, attempts, within_mins,
                 expire_day) — full-object.

Per-rule firewall config (Firewall.Profile + Firewall.Rules load/save_start) and
AutoBlock allow/deny lists are NOT yet covered — the capture errored on them (wrong
param shape); add subcommands once the param shape is empirically confirmed.
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"


def _exec(api, *params):
    out = subprocess.run([WEBAPI, "--exec", "api=" + api, *params],
                         capture_output=True, text=True)
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
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True))
        return 0
    res = apply_fn()
    if res.get("success"):
        print("CHANGED " + json.dumps(drift, sort_keys=True))
        return 0
    print("FAIL " + json.dumps(res))
    return 1


def apply_full_object(api, version, desired, check):
    current = _exec(api, "version=%d" % version, "method=get")["data"]
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(api, "version=%d" % version, "method=set", *_args_from(current))

    return _result(drift, check, apply)


def do_firewall(a):
    desired = {}
    if a.enable is not None:
        desired["enable_firewall"] = _bool(a.enable)
    if a.profile is not None:
        desired["profile_name"] = a.profile
    return apply_full_object("SYNO.Core.Security.Firewall", 1, desired, a.check)


def do_fw_conf(a):
    desired = {}
    if a.port_check is not None:
        desired["enable_port_check"] = _bool(a.port_check)
    return apply_full_object("SYNO.Core.Security.Firewall.Conf", 1, desired, a.check)


def do_autoblock(a):
    desired = {}
    if a.enable is not None:
        desired["enable"] = _bool(a.enable)
    if a.attempts is not None:
        desired["attempts"] = int(a.attempts)
    if a.within_mins is not None:
        desired["within_mins"] = int(a.within_mins)
    if a.expire_day is not None:
        desired["expire_day"] = int(a.expire_day)
    return apply_full_object("SYNO.Core.Security.AutoBlock", 1, desired, a.check)


# --- Anti-lockout probe (H2) ---------------------------------------------------
# Enabling SYNO.Core.Security.Firewall on a profile with NO rules is a
# default-deny posture — DSM blocks all inbound, including the SSH session
# Ansible is running over. Probe the active profile's rule list FIRST and
# print one of:
#   PROFILE-EMPTY              — would lock us out; role asserts and halts
#   PROFILE-HAS-RULES count=N  — rules present; safe to proceed
#   PROFILE-UNKNOWN <reason>   — couldn't determine; role asserts and halts
# Best-known API: SYNO.Core.Security.Firewall.Profile method=get name=<n>
# returns rules under data.rules. First apply will surface the actual shape;
# flip RULE_KEYS if needed.
RULE_KEYS = ("rules", "rule_list", "fw_rules")


def do_probe_profile(a):
    try:
        res = _exec("SYNO.Core.Security.Firewall.Profile", "version=1",
                    "method=get", "name=" + a.profile)
    except RuntimeError as e:
        print("PROFILE-UNKNOWN " + json.dumps({"error": str(e)[:200]}))
        return 0
    data = res.get("data", {}) if res.get("success") else {}
    if not data:
        print("PROFILE-UNKNOWN " + json.dumps({"raw": res})[:200])
        return 0
    for k in RULE_KEYS:
        rules = data.get(k)
        if isinstance(rules, list):
            if not rules:
                print("PROFILE-EMPTY")
            else:
                print("PROFILE-HAS-RULES count=" + str(len(rules)))
            return 0
    # API shape we don't recognize. Treat as UNKNOWN so the role refuses to
    # blindly enable the firewall.
    print("PROFILE-UNKNOWN " + json.dumps({"keys": sorted(data.keys())}))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    fw = sub.add_parser("firewall")
    fw.add_argument("--enable")
    fw.add_argument("--profile")
    fw.add_argument("--check", action="store_true")
    fw.set_defaults(func=do_firewall)

    c = sub.add_parser("fw-conf")
    c.add_argument("--port-check", dest="port_check")
    c.add_argument("--check", action="store_true")
    c.set_defaults(func=do_fw_conf)

    ab = sub.add_parser("autoblock")
    ab.add_argument("--enable")
    ab.add_argument("--attempts")
    ab.add_argument("--within-mins", dest="within_mins")
    ab.add_argument("--expire-day", dest="expire_day")
    ab.add_argument("--check", action="store_true")
    ab.set_defaults(func=do_autoblock)

    pp = sub.add_parser("probe-profile",
                        help="Read-only: report whether the named firewall profile has any rules.")
    pp.add_argument("--profile", required=True)
    pp.set_defaults(func=do_probe_profile)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
