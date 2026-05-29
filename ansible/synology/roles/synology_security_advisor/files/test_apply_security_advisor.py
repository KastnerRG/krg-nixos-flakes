"""Unit tests for apply_security_advisor.py — run with: pytest (no DSM needed)."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_security_advisor as m  # noqa: E402


def _factory(live):
    captured = []

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(live[api]["get"]), "success": True}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


def test_main_no_change(monkeypatch, capsys):
    fake, _ = _factory({m.SA_MAIN_API: {"get": {
        "enable": True,
        "schedule_day": "Wed",
        "schedule_hour": 4,
        "schedule_min": 15,
        "categories": ["account", "network", "performance", "security", "system_health"],
        "notify_email": True,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "main", "--enable", "true", "--day", "Wed", "--hour", "4", "--minute", "15",
        "--categories", json.dumps(["system_health", "security", "performance", "network", "account"]),
        "--notify-email", "true",
    ])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_main_drift_apply(monkeypatch, capsys):
    fake, captured = _factory({m.SA_MAIN_API: {"get": {
        "enable": False,                          # drift
        "schedule_day": "Mon",                    # drift
        "schedule_hour": 9,                       # drift
        "schedule_min": 0,                        # drift
        "categories": ["security"],               # drift
        "notify_email": False,                    # drift
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "main", "--enable", "true", "--day", "Wed", "--hour", "4", "--minute", "15",
        "--categories", json.dumps(["system_health", "security"]),
        "--notify-email", "true",
    ])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.SA_MAIN_API)
    assert "enable=true" in set_call
    assert "schedule_day=Wed" in set_call
    assert "notify_email=true" in set_call


def test_main_check_mode_no_apply(monkeypatch, capsys):
    fake, captured = _factory({m.SA_MAIN_API: {"get": {
        "enable": False,
        "schedule_day": "Wed",
        "schedule_hour": 4,
        "schedule_min": 15,
        "categories": [],
        "notify_email": True,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "main", "--enable", "true", "--day", "Wed", "--hour", "4", "--minute", "15",
        "--categories", "[]", "--notify-email", "true", "--check",
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not any(a == m.SA_MAIN_API and "method=set" in p for a, p in captured)


def test_main_categories_order_invariant(monkeypatch, capsys):
    """Categories list should not drift on order-only differences (sorted-compare)."""
    fake, _ = _factory({m.SA_MAIN_API: {"get": {
        "enable": True,
        "schedule_day": "Wed",
        "schedule_hour": 4,
        "schedule_min": 15,
        "categories": ["security", "account", "network"],
        "notify_email": True,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "main", "--enable", "true", "--day", "Wed", "--hour", "4", "--minute", "15",
        "--categories", json.dumps(["network", "security", "account"]),
        "--notify-email", "true",
    ])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_main_preserves_unmanaged_keys(monkeypatch, capsys):
    fake, captured = _factory({m.SA_MAIN_API: {"get": {
        "enable": False,
        "schedule_day": "Wed",
        "schedule_hour": 4,
        "schedule_min": 15,
        "categories": [],
        "notify_email": True,
        "dsm_internal_version": 7,           # unmanaged
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main([
        "main", "--enable", "true", "--day", "Wed", "--hour", "4", "--minute", "15",
        "--categories", "[]", "--notify-email", "true",
    ])
    capsys.readouterr()
    set_call = next(p for a, p in captured if a == m.SA_MAIN_API)
    assert "dsm_internal_version=7" in set_call
