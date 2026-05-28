#!/usr/bin/env python3
"""Apply DSM file/system service settings idempotently via synowebapi.
Subcommands: ftp, afp, snmp. Each is a full-object set on its API (partial = err 2001),
so GET → overlay managed keys → SET, only on drift.

SFTP / WebDAV / Rsync: the synowebapi surfaces returned err 102 on probe — TODO discover
the right API namespace (likely package-provided) and add subcommands. Spec lists them
off for now.

SNMPv3 USM credentials (auth/priv password) are a separate bootstrap secret — NOT taken
on the CLI here. enable_snmp_v3=true without a credential set is accepted by the API but
no v3 user can authenticate until the credential is bootstrapped (DSM UI or a follow-up).
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
APIS = {
    "ftp":  ("SYNO.Core.FileServ.FTP",  1),
    "afp":  ("SYNO.Core.FileServ.AFP",  1),
    "snmp": ("SYNO.Core.SNMP",          1),
}


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


def apply_service(svc, desired, check):
    api, ver = APIS[svc]
    current = _exec(api, "version=%d" % ver, "method=get")["data"]
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(api, "version=%d" % ver, "method=set", *_args_from(current))

    return _result(drift, check, apply)


def do_ftp(a):
    desired = {}
    if a.enable_ftp is not None:
        desired["enable_ftp"] = _bool(a.enable_ftp)
    if a.enable_ftps is not None:
        desired["enable_ftps"] = _bool(a.enable_ftps)
    return apply_service("ftp", desired, a.check)


def do_afp(a):
    desired = {}
    if a.enable is not None:
        desired["enable_afp"] = _bool(a.enable)
    return apply_service("afp", desired, a.check)


def do_snmp(a):
    desired = {}
    if a.enable is not None:
        desired["enable_snmp"] = _bool(a.enable)
    if a.v1v2 is not None:
        desired["enable_snmp_v1v2"] = _bool(a.v1v2)
    if a.v3 is not None:
        desired["enable_snmp_v3"] = _bool(a.v3)
    if a.contact is not None:
        desired["contact"] = a.contact
    if a.location is not None:
        desired["location"] = a.location
    if a.name is not None:
        desired["name"] = a.name
    if a.rouser is not None:
        desired["rouser"] = a.rouser
    return apply_service("snmp", desired, a.check)


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("ftp")
    f.add_argument("--enable-ftp", dest="enable_ftp")
    f.add_argument("--enable-ftps", dest="enable_ftps")
    f.add_argument("--check", action="store_true")
    f.set_defaults(func=do_ftp)

    af = sub.add_parser("afp")
    af.add_argument("--enable")
    af.add_argument("--check", action="store_true")
    af.set_defaults(func=do_afp)

    s = sub.add_parser("snmp")
    s.add_argument("--enable")
    s.add_argument("--v1v2")
    s.add_argument("--v3")
    s.add_argument("--contact")
    s.add_argument("--location")
    s.add_argument("--name")
    s.add_argument("--rouser")
    s.add_argument("--check", action="store_true")
    s.set_defaults(func=do_snmp)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
