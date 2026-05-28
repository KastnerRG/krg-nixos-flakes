"""Unit tests for apply_quotas.py — run with: pytest (no DSM needed)."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_quotas as m  # noqa: E402


class _R:
    def __init__(self, stdout="", rc=0):
        self.stdout = stdout
        self.returncode = rc
        self.stderr = ""


# --- _parse_current ---------------------------------------------------------
def test_parse_current_recognized_forms():
    assert m._parse_current("Quota: 500 GB (Hard)") == (500, True)
    assert m._parse_current("Quota: 500 GiB") == (500, False)
    assert m._parse_current("Quota: 2 TB (Soft)") == (2048, False)
    assert m._parse_current("No quota set") == (None, None)
    # Unparseable -> sentinel
    assert m._parse_current("???")[0] == "UNPARSEABLE"


# --- share quota -----------------------------------------------------------
def test_share_no_change(monkeypatch, capsys):
    monkeypatch.setattr(m, "_run", lambda cmd: _R("Quota: 500 GB (Hard)"))
    rc = m.main(["share", "--share", "temp", "--size-gib", "500", "--hard", "true"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_share_drift_applies_set(monkeypatch, capsys):
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        if "--get-share" in cmd:
            return _R("Quota: 200 GB (Soft)")    # drift on both size + hard
        return _R("", 0)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main(["share", "--share", "temp", "--size-gib", "500", "--hard", "true"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(c for c in calls if "--set-share" in c)
    assert "temp" in set_call
    assert "--size" in set_call
    assert str(500 * (1 << 30)) in set_call
    assert "hard" in set_call


def test_share_clear_when_size_zero(monkeypatch, capsys):
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        if "--get-share" in cmd:
            return _R("Quota: 500 GB (Hard)")
        return _R("", 0)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main(["share", "--share", "temp", "--size-gib", "0", "--hard", "false"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    assert any("--clear-share" in c for c in calls)


def test_share_size_zero_no_existing_quota_is_noop(monkeypatch, capsys):
    monkeypatch.setattr(m, "_run", lambda cmd: _R("No quota set"))
    rc = m.main(["share", "--share", "temp", "--size-gib", "0", "--hard", "false"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_share_check_mode(monkeypatch, capsys):
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        return _R("Quota: 200 GB (Hard)")

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main(["share", "--share", "temp", "--size-gib", "500", "--hard", "true", "--check"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    # only the get was issued — no set
    assert not any("--set-share" in c for c in calls)


def test_share_unparseable_fails(monkeypatch, capsys):
    monkeypatch.setattr(m, "_run", lambda cmd: _R("???"))
    rc = m.main(["share", "--share", "temp", "--size-gib", "500", "--hard", "true"])
    assert rc == 1
    assert capsys.readouterr().out.startswith("FAIL")


# --- user quota ------------------------------------------------------------
def test_user_drift_applies_set(monkeypatch, capsys):
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        if "--get" in cmd and "--user" in cmd:
            return _R("Quota: 100 GB (Soft)")
        return _R("", 0)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main([
        "user", "--user", "alice", "--volume", "/volume1",
        "--size-gib", "200", "--hard", "false",
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    set_call = next(c for c in calls if "--set" in c and "--user" in c)
    assert "alice" in set_call and "/volume1" in set_call


def test_user_hard_change_only(monkeypatch, capsys):
    """size unchanged but hard flips soft->hard -> drift."""
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        if "--get" in cmd and "--user" in cmd:
            return _R("Quota: 200 GB (Soft)")
        return _R("", 0)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main([
        "user", "--user", "alice", "--volume", "/volume1",
        "--size-gib", "200", "--hard", "true",
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
