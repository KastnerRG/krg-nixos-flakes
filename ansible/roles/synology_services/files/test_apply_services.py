"""Unit tests for apply_services.py — run with: pytest (no DSM needed)."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_services as m  # noqa: E402


def _exec_factory(get_data, set_capture=None):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(get_data), "success": True}
        if set_capture is not None:
            set_capture.append((api, params))
        return {"success": True}
    return fake


def test_apis_table():
    assert m.APIS == {
        "ftp":  ("SYNO.Core.FileServ.FTP", 1),
        "afp":  ("SYNO.Core.FileServ.AFP", 1),
        "snmp": ("SYNO.Core.SNMP", 1),
    }


def test_bool_helper():
    assert m._bool("true") and m._bool("yes") and m._bool("1")
    assert not (m._bool("false") or m._bool("no") or m._bool("0"))


def test_ftp_no_change(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory(
        {"enable_ftp": False, "enable_ftps": False, "ext_ip": ""}))
    rc = m.main(["ftp", "--enable-ftp", "false", "--enable-ftps", "false"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_ftp_apply_full_object(monkeypatch, capsys):
    captured = []
    monkeypatch.setattr(m, "_exec", _exec_factory(
        {"enable_ftp": False, "enable_ftps": True, "ext_ip": "", "custom_port": "55536:55899"},
        set_capture=captured))
    rc = m.main(["ftp", "--enable-ftp", "false", "--enable-ftps", "false"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    api, params = captured[0]
    assert api == "SYNO.Core.FileServ.FTP" and "version=1" in params and "method=set" in params
    rest = set(params[2:])
    assert "enable_ftps=false" in rest
    assert "custom_port=55536:55899" in rest  # unmanaged field retained


def test_afp_check_reports_drift(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory({"enable_afp": True}))
    rc = m.main(["afp", "--enable", "false", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE") and "enable_afp" in out


def test_snmp_v3_apply(monkeypatch, capsys):
    captured = []
    live = {"enable_snmp": False, "enable_snmp_v1v2": False, "enable_snmp_v3": False,
            "contact": "", "location": "", "name": "", "rouser": "",
            "rocommunity": "", "node0_name": "", "node1_name": ""}
    monkeypatch.setattr(m, "_exec", _exec_factory(live, set_capture=captured))
    rc = m.main(["snmp", "--enable", "true", "--v3", "true", "--v1v2", "false",
                 "--name", "e4e-nas", "--rouser", "krg-monitor",
                 "--contact", "admin@x", "--location", "UCSD"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    rest = set(captured[0][1][2:])
    for tok in ("enable_snmp=true", "enable_snmp_v3=true", "enable_snmp_v1v2=false",
                "name=e4e-nas", "rouser=krg-monitor", "contact=admin@x", "location=UCSD"):
        assert tok in rest


def test_snmp_fail_on_unsuccessful_set(monkeypatch, capsys):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": {"enable_snmp": False}, "success": True}
        return {"success": False, "error": {"code": 2001}}
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["snmp", "--enable", "true"])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")
