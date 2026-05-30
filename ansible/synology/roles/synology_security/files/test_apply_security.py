"""Unit tests for apply_security.py — run with: pytest (no DSM needed)."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_security as m  # noqa: E402


def _exec_factory(get_data, set_capture=None):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(get_data), "success": True}
        if set_capture is not None:
            set_capture.append((api, params))
        return {"success": True}
    return fake


def test_firewall_no_change(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory(
        {"enable_firewall": True, "profile_name": "default"}))
    rc = m.main(["firewall", "--enable", "true", "--profile", "default"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_firewall_check_reports_drift(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory(
        {"enable_firewall": False, "profile_name": "default"}))
    rc = m.main(["firewall", "--enable", "true", "--profile", "default", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE") and "enable_firewall" in out


def test_firewall_apply_preserves_unmanaged(monkeypatch, capsys):
    captured = []
    monkeypatch.setattr(m, "_exec", _exec_factory(
        {"enable_firewall": False, "profile_name": "default", "extra_unmanaged": "stays"},
        set_capture=captured))
    rc = m.main(["firewall", "--enable", "true"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    rest = set(captured[0][1][2:])
    assert "enable_firewall=true" in rest and "extra_unmanaged=stays" in rest


def test_fw_conf_check(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory({"enable_port_check": False}))
    rc = m.main(["fw-conf", "--port-check", "true", "--check"])
    assert rc == 0 and "WOULD-CHANGE" in capsys.readouterr().out


def test_autoblock_apply_int_fields(monkeypatch, capsys):
    captured = []
    monkeypatch.setattr(m, "_exec", _exec_factory(
        {"enable": True, "attempts": 10, "within_mins": 60, "expire_day": 0},
        set_capture=captured))
    rc = m.main(["autoblock", "--enable", "true", "--attempts", "3",
                 "--within-mins", "1440", "--expire-day", "7"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    rest = set(captured[0][1][2:])
    assert "attempts=3" in rest and "within_mins=1440" in rest and "expire_day=7" in rest


def test_autoblock_no_change_with_matching_values(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory(
        {"enable": True, "attempts": 3, "within_mins": 1440, "expire_day": 0}))
    rc = m.main(["autoblock", "--enable", "true", "--attempts", "3",
                 "--within-mins", "1440", "--expire-day", "0"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_fail_on_unsuccessful_set(monkeypatch, capsys):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": {"enable_firewall": False}, "success": True}
        return {"success": False, "error": {"code": 2001}}
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["firewall", "--enable", "true"])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")


# --- H2: anti-lockout probe-profile subcommand ----------------------------------
def test_probe_profile_empty(monkeypatch, capsys):
    """An active profile with no rules → PROFILE-EMPTY (role refuses enable)."""
    def fake(api, *params):
        return {"success": True, "data": {"rules": []}}
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["probe-profile", "--profile", "default"])
    assert rc == 0
    out = capsys.readouterr().out.strip()
    assert out == "PROFILE-EMPTY"


def test_probe_profile_has_rules(monkeypatch, capsys):
    """Rules present → PROFILE-HAS-RULES count=N (role proceeds)."""
    def fake(api, *params):
        return {"success": True, "data": {"rules": [{"id": 1}, {"id": 2}, {"id": 3}]}}
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["probe-profile", "--profile", "default"])
    assert rc == 0
    assert capsys.readouterr().out.strip() == "PROFILE-HAS-RULES count=3"


def test_probe_profile_unknown_shape(monkeypatch, capsys):
    """If DSM returns a shape we don't recognize → PROFILE-UNKNOWN (role refuses)."""
    def fake(api, *params):
        return {"success": True, "data": {"some_other_key": "weird"}}
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["probe-profile", "--profile", "default"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("PROFILE-UNKNOWN")


def test_probe_profile_exec_failure_is_unknown(monkeypatch, capsys):
    """Any RuntimeError from _exec must be reported as PROFILE-UNKNOWN — never EMPTY (which would let the role proceed)."""
    def fake(api, *params):
        raise RuntimeError("connection refused")
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["probe-profile", "--profile", "default"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("PROFILE-UNKNOWN")
    assert "PROFILE-EMPTY" not in out   # critical: must NOT be misclassified
