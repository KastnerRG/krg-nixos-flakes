"""Unit tests for apply_users.py — run with: pytest (no DSM needed)."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_users as m  # noqa: E402


def _factory(live):
    captured = []

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(live[api]["get"]), "success": True}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


# --- home (SYNO.Core.User.Home) -----------------------------------------------
def test_home_no_change(monkeypatch, capsys):
    fake, _ = _factory({m.HOME_API: {"get": {
        "enable": True,
        "enable_domain": True,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["home", "--enable", "true", "--include-domain-users", "true"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_home_drift_enables(monkeypatch, capsys):
    fake, captured = _factory({m.HOME_API: {"get": {
        "enable": False,
        "enable_domain": False,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["home", "--enable", "true", "--include-domain-users", "true"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.HOME_API)
    assert "enable=true" in set_call
    assert "enable_domain=true" in set_call


def test_home_check_mode_no_apply(monkeypatch, capsys):
    fake, captured = _factory({m.HOME_API: {"get": {
        "enable": False, "enable_domain": False,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["home", "--enable", "true", "--include-domain-users", "true", "--check"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not any(a == m.HOME_API and "method=set" in p for a, p in captured)


def test_home_preserves_unmanaged_keys(monkeypatch, capsys):
    fake, captured = _factory({m.HOME_API: {"get": {
        "enable": False, "enable_domain": False,
        "home_quota_default": "10GB",   # unmanaged
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main(["home", "--enable", "true", "--include-domain-users", "true"])
    capsys.readouterr()
    set_call = next(p for a, p in captured if a == m.HOME_API)
    assert "home_quota_default=10GB" in set_call


# --- authorized-keys ----------------------------------------------------------
def _fake_pwnam(monkeypatch, tmp_path, name="krg-admin"):
    class FakePw:
        pw_name = name
        pw_uid = os.getuid()
        pw_gid = os.getgid()
        pw_dir = str(tmp_path)

    monkeypatch.setattr(m.pwd, "getpwnam", lambda u: FakePw())


def test_keys_creates_dir_and_file(monkeypatch, capsys, tmp_path):
    _fake_pwnam(monkeypatch, tmp_path)
    keys = ["ssh-ed25519 AAAA chris@a", "ssh-ed25519 BBBB chris@b"]
    rc = m.main([
        "authorized-keys", "--username", "krg-admin", "--keys", json.dumps(keys),
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    auth = tmp_path / ".ssh" / "authorized_keys"
    assert auth.exists()
    written = auth.read_text()
    for k in keys:
        assert k in written
    # Trailing newline + 0600 perms
    assert written.endswith("\n")
    assert (auth.stat().st_mode & 0o777) == 0o600
    assert (tmp_path / ".ssh").stat().st_mode & 0o777 == 0o700


def test_keys_idempotent(monkeypatch, capsys, tmp_path):
    _fake_pwnam(monkeypatch, tmp_path)
    keys = ["ssh-ed25519 AAAA a@x"]
    m.main(["authorized-keys", "--username", "krg-admin", "--keys", json.dumps(keys)])
    capsys.readouterr()
    rc = m.main(["authorized-keys", "--username", "krg-admin", "--keys", json.dumps(keys)])
    assert rc == 0
    assert "OK no-change" in capsys.readouterr().out


def test_keys_dedupes_and_strips(monkeypatch, capsys, tmp_path):
    _fake_pwnam(monkeypatch, tmp_path)
    keys = ["  ssh-ed25519 AAAA a@x  ", "ssh-ed25519 AAAA a@x", "", "ssh-ed25519 BBBB b@y"]
    m.main(["authorized-keys", "--username", "krg-admin", "--keys", json.dumps(keys)])
    capsys.readouterr()
    written = (tmp_path / ".ssh" / "authorized_keys").read_text()
    # exactly two entries (deduped, blank dropped, leading/trailing ws stripped)
    assert written == "ssh-ed25519 AAAA a@x\nssh-ed25519 BBBB b@y\n"


def test_keys_check_mode_does_not_write(monkeypatch, capsys, tmp_path):
    _fake_pwnam(monkeypatch, tmp_path)
    keys = ["ssh-ed25519 AAAA a@x"]
    rc = m.main([
        "authorized-keys", "--username", "krg-admin", "--keys", json.dumps(keys), "--check",
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not (tmp_path / ".ssh" / "authorized_keys").exists()


def test_keys_empty_list_leaves_existing_alone(monkeypatch, capsys, tmp_path):
    """Per the role design, empty desired keys is a no-op (we don't claim
    exclusive ownership). Mirrors ansible.posix.authorized_key exclusive=false."""
    _fake_pwnam(monkeypatch, tmp_path)
    # Seed an existing file
    ssh = tmp_path / ".ssh"
    ssh.mkdir(mode=0o700)
    (ssh / "authorized_keys").write_text("ssh-ed25519 ZZZ external@key\n")
    rc = m.main([
        "authorized-keys", "--username", "krg-admin", "--keys", "[]",
    ])
    assert rc == 0
    assert "OK no-change" in capsys.readouterr().out
    # Existing keys preserved
    assert (ssh / "authorized_keys").read_text() == "ssh-ed25519 ZZZ external@key\n"


def test_keys_missing_user_is_noop(monkeypatch, capsys, tmp_path):
    def raises(_):
        raise KeyError("missing")
    monkeypatch.setattr(m.pwd, "getpwnam", raises)
    rc = m.main([
        "authorized-keys", "--username", "ghost", "--keys", json.dumps(["ssh-ed25519 AAAA x"]),
    ])
    assert rc == 0
    assert "OK no-change" in capsys.readouterr().out


def test_keys_invalid_json_errors():
    try:
        m.main(["authorized-keys", "--username", "x", "--keys", "not json"])
    except SystemExit as e:
        assert "--keys" in str(e) or "must be a JSON" in str(e)
    else:
        assert False, "should have raised SystemExit"


# --- --keys-b64 (shell-safe variant used by the ansible role) ---------------
import base64 as _b64    # noqa: E402


def test_keys_b64_equivalent_to_keys(monkeypatch, capsys, tmp_path):
    """--keys-b64 must produce the same result as --keys for the same payload."""
    _fake_pwnam(monkeypatch, tmp_path)
    payload = ["ssh-ed25519 AAAA chris@laptop", "ssh-ed25519 BBBB shperry@x"]
    b64 = _b64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")
    rc = m.main([
        "authorized-keys", "--username", "krg-admin", "--keys-b64", b64,
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    written = (tmp_path / ".ssh" / "authorized_keys").read_text()
    assert "chris@laptop" in written
    assert "shperry@x" in written


def test_keys_b64_handles_keys_with_spaces_and_quotes(monkeypatch, capsys, tmp_path):
    """Regression for the shell-quoting bug discovered on prod bring-up:
    keys contain SPACES (algo / base64 / comment) AND double-quotes (from JSON);
    bare --keys breaks when transported through ssh + remote sh word-splitter.
    --keys-b64 must survive any shell because base64 has no shell-special chars."""
    _fake_pwnam(monkeypatch, tmp_path)
    payload = [
        'ssh-ed25519 AAAA user@host with spaces',
        'ssh-rsa BBBB "weird" comment',
    ]
    b64 = _b64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")
    rc = m.main([
        "authorized-keys", "--username", "krg-admin", "--keys-b64", b64,
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    written = (tmp_path / ".ssh" / "authorized_keys").read_text()
    assert "user@host with spaces" in written
    assert 'ssh-rsa BBBB "weird" comment' in written


def test_keys_b64_invalid_base64_errors():
    try:
        m.main(["authorized-keys", "--username", "x", "--keys-b64", "not!valid@base64"])
    except SystemExit as e:
        assert "--keys-b64" in str(e) or "base64" in str(e).lower()
    else:
        assert False, "should have raised SystemExit"


def test_keys_b64_valid_base64_but_invalid_json_errors():
    bad = _b64.b64encode(b"not actually json").decode("ascii")
    try:
        m.main(["authorized-keys", "--username", "x", "--keys-b64", bad])
    except SystemExit as e:
        assert "JSON" in str(e) or "list" in str(e)
    else:
        assert False, "should have raised SystemExit"


def test_keys_and_keys_b64_are_mutually_exclusive():
    """argparse should reject passing both."""
    try:
        m.main([
            "authorized-keys", "--username", "x",
            "--keys", "[]",
            "--keys-b64", _b64.b64encode(b"[]").decode("ascii"),
        ])
    except SystemExit:
        pass  # argparse exits on mutually-exclusive violation
    else:
        assert False, "should have rejected both flags together"
