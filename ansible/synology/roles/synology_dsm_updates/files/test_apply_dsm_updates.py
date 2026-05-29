"""Unit tests for apply_dsm_updates.py — run with: pytest (no DSM needed)."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_dsm_updates as m  # noqa: E402


def _factory(live):
    """live: dict of API → {get: {...}}. set/etc calls are captured for assertions."""
    captured = []

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(live[api]["get"]), "success": True}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


# --- setting -------------------------------------------------------------------
def test_setting_no_change(monkeypatch, capsys):
    fake, _ = _factory({m.UPD_SETTING_API: {"get": {
        "auto_update_type": "hotfix-security",
        "enable_auto_update": True,
        "notify_email": True,
        "upgrade_day": "Sun",
        "upgrade_hour": 3,
        "upgrade_min": 0,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "setting", "--policy", "hotfix-security", "--auto-install", "true",
        "--notify-email", "true", "--day", "Sun", "--hour", "3", "--minute", "0",
    ])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_setting_drift_applied(monkeypatch, capsys):
    fake, captured = _factory({m.UPD_SETTING_API: {"get": {
        "auto_update_type": "nothing",         # drift
        "enable_auto_update": False,           # drift
        "notify_email": False,
        "upgrade_day": "Mon",
        "upgrade_hour": 5,
        "upgrade_min": 0,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "setting", "--policy", "hotfix-security", "--auto-install", "true",
        "--notify-email", "true", "--day", "Sun", "--hour", "3", "--minute", "0",
    ])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.UPD_SETTING_API)
    # full-object set MUST carry the desired values
    assert "auto_update_type=hotfix-security" in set_call
    assert "enable_auto_update=true" in set_call
    assert "upgrade_day=Sun" in set_call


def test_setting_check_mode_no_apply(monkeypatch, capsys):
    fake, captured = _factory({m.UPD_SETTING_API: {"get": {
        "auto_update_type": "nothing",
        "enable_auto_update": False,
        "notify_email": True,
        "upgrade_day": "Sun",
        "upgrade_hour": 3,
        "upgrade_min": 0,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "setting", "--policy", "hotfix-security", "--auto-install", "true",
        "--notify-email", "true", "--day", "Sun", "--hour", "3", "--minute", "0",
        "--check",
    ])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("WOULD-CHANGE")
    # no set captured
    assert not any(a == m.UPD_SETTING_API and "method=set" in p for a, p in captured)


def test_setting_preserves_unmanaged_keys(monkeypatch, capsys):
    """Full-object set MUST resend live keys we don't manage (DSM err 2001 otherwise)."""
    fake, captured = _factory({m.UPD_SETTING_API: {"get": {
        "auto_update_type": "nothing",
        "enable_auto_update": False,
        "notify_email": True,
        "upgrade_day": "Sun",
        "upgrade_hour": 3,
        "upgrade_min": 0,
        "unknown_dsm_internal_key": "preserve_me",   # unmanaged
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main([
        "setting", "--policy", "hotfix-security", "--auto-install", "true",
        "--notify-email", "true", "--day", "Sun", "--hour", "3", "--minute", "0",
    ])
    capsys.readouterr()
    set_call = next(p for a, p in captured if a == m.UPD_SETTING_API)
    assert "unknown_dsm_internal_key=preserve_me" in set_call


# --- channel -------------------------------------------------------------------
def test_channel_no_change(monkeypatch, capsys):
    fake, _ = _factory({m.UPD_SERVER_API: {"get": {"type": "stable"}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["channel", "--channel", "stable"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_channel_drift(monkeypatch, capsys):
    fake, captured = _factory({m.UPD_SERVER_API: {"get": {"type": "beta"}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["channel", "--channel", "stable"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.UPD_SERVER_API)
    assert "type=stable" in set_call
