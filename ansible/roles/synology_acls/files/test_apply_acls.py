"""Unit tests for apply_acls.py — run with: pytest (no DSM needed).

parse_list_acl is tested against the EXACT `synoshare --list_acl` output captured from
the DSM 7.3 rig. The subprocess boundary `_run` is monkeypatched to drive the
OK/WOULD-CHANGE/CHANGED/FAIL contract and verify only drifted tiers are re-set.
"""
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(__file__))
import apply_acls as m  # noqa: E402

# Verbatim rig output (note the leading tabs and variable dot-runs).
RIG_LIST_ACL = (
    "SYNOSHARE ACL Perm List:\n"
    "\t Name ............[acltest]\n"
    "\t ACL RO List .....[myadmin]\n"
    "\t ACL RW List .....[@rigtest,bob]\n"
    "\t ACL NA List .....[]\n"
    "\t ACL Custom List .[]\n"
)


class _R:
    def __init__(self, stdout="", rc=0):
        self.stdout = stdout
        self.returncode = rc
        self.stderr = ""


def test_parse_list_acl_real_output():
    t = m.parse_list_acl(RIG_LIST_ACL)
    assert t["RO"] == {"myadmin"}
    assert t["RW"] == {"@rigtest", "bob"}   # group is @-prefixed, user bare
    assert t["NA"] == set()                 # empty tier -> empty set


def test_desired_tiers_prefixes_groups():
    d = m.desired_tiers([{"group": "maya", "access": "rw"},
                         {"user": "alice", "access": "ro"},
                         {"group": "x", "access": "no"}])
    assert d["RW"] == {"@maya"} and d["RO"] == {"alice"} and d["NA"] == {"@x"}


def test_desired_tiers_rejects_bad_input():
    with pytest.raises(SystemExit):
        m.desired_tiers([{"group": "x", "access": "bogus"}])
    with pytest.raises(SystemExit):
        m.desired_tiers([{"access": "rw"}])  # neither group nor user


def test_no_change(monkeypatch, capsys):
    monkeypatch.setattr(m, "_run", lambda *a: _R(RIG_LIST_ACL))
    grants = [{"user": "myadmin", "access": "ro"},
              {"group": "rigtest", "access": "rw"},
              {"user": "bob", "access": "rw"}]
    rc = m.main(["--share", "acltest", "--grants", json.dumps(grants)])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_apply_only_resets_drifted_tiers(monkeypatch, capsys):
    setcalls = []

    def fake_run(*a):
        if a[0] == "--list_acl":
            return _R(RIG_LIST_ACL)
        setcalls.append(a)  # ("--setuser", share, tier, "=", csv)
        return _R("", 0)

    monkeypatch.setattr(m, "_run", fake_run)
    # desired: only @rigtest RW -> RO (myadmin) clears, RW (@rigtest,bob) -> @rigtest; NA unchanged
    rc = m.main(["--share", "acltest", "--grants",
                 json.dumps([{"group": "rigtest", "access": "rw"}])])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    tiers = {c[2] for c in setcalls}
    assert tiers == {"RW", "RO"}  # NA was already empty -> not touched
    rw_csv = next(c[4] for c in setcalls if c[2] == "RW")
    ro_csv = next(c[4] for c in setcalls if c[2] == "RO")
    assert rw_csv == "@rigtest" and ro_csv == ""  # `= ""` clears RO


def test_check_reports_without_setting(monkeypatch, capsys):
    monkeypatch.setattr(m, "_run", lambda *a: _R(RIG_LIST_ACL) if a[0] == "--list_acl"
                        else (_ for _ in ()).throw(AssertionError("must not set in --check")))
    rc = m.main(["--share", "acltest", "--grants",
                 json.dumps([{"group": "rigtest", "access": "rw"}]), "--check"])
    assert rc == 0 and capsys.readouterr().out.startswith("WOULD-CHANGE")


def test_fail_when_setuser_errors(monkeypatch, capsys):
    def fake_run(*a):
        return _R(RIG_LIST_ACL) if a[0] == "--list_acl" else _R("denied", 1)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main(["--share", "acltest", "--grants",
                 json.dumps([{"group": "rigtest", "access": "rw"}])])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")
