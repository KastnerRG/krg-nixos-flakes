"""Unit tests for apply_external_access.py — run with: pytest (no DSM needed)."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_external_access as m  # noqa: E402


def _factory(live):
    captured = []

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(live[api]["get"]), "success": True}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


def test_quickconnect_disable_drift(monkeypatch, capsys):
    fake, captured = _factory({m.QC_API: {"get": {"enabled": True}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["quickconnect", "--enable", "false"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.QC_API)
    assert "enabled=false" in set_call


def test_quickconnect_already_off(monkeypatch, capsys):
    fake, _ = _factory({m.QC_API: {"get": {"enabled": False}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["quickconnect", "--enable", "false"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_upnp_check_mode_no_apply(monkeypatch, capsys):
    fake, captured = _factory({m.UPNP_API: {"get": {"enabled": True}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["upnp", "--enable", "false", "--check"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not any(a == m.UPNP_API and "method=set" in p for a, p in captured)


def test_ddns_drift_and_full_object_preservation(monkeypatch, capsys):
    fake, captured = _factory({m.DDNS_API: {"get": {
        "enabled": True,
        "provider": "Synology",     # unmanaged — must round-trip
        "hostname": "e4e-nas.synology.me",
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["ddns", "--enable", "false"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.DDNS_API)
    assert "enabled=false" in set_call
    # Unmanaged keys preserved (DSM full-object set requires them)
    assert "provider=Synology" in set_call
    assert "hostname=e4e-nas.synology.me" in set_call


def test_each_surface_targets_correct_api(monkeypatch, capsys):
    live = {
        m.QC_API:   {"get": {"enabled": True}},
        m.UPNP_API: {"get": {"enabled": True}},
        m.DDNS_API: {"get": {"enabled": True}},
    }
    fake, captured = _factory(live)
    monkeypatch.setattr(m, "_exec", fake)
    for sub in ("quickconnect", "upnp", "ddns"):
        m.main([sub, "--enable", "false"])
    capsys.readouterr()
    apis = {a for a, _ in captured}
    assert apis == {m.QC_API, m.UPNP_API, m.DDNS_API}
