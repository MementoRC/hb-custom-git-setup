"""Tests for scripts/connector_env_exec.py. Run with the hummingbot env interpreter (pixi task connector-exec-test)."""

import importlib.util
from pathlib import Path

import pytest
import yaml

from hummingbot.client.config import config_crypt

SCRIPT = Path(__file__).resolve().parent.parent / "connector_env_exec.py"
PASSWORD = "correct-horse"
API_KEY = "KEY-plaintext-123"
API_SECRET = "SECRET-plaintext-456"


@pytest.fixture
def tool():
    spec = importlib.util.spec_from_file_location("connector_env_exec", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def conf_dir(tmp_path, monkeypatch):
    conf = tmp_path / "conf"
    (conf / "connectors").mkdir(parents=True)
    monkeypatch.setattr(config_crypt, "PASSWORD_VERIFICATION_PATH", conf / ".password_verification")
    manager = config_crypt.ETHKeyFileSecretManger(PASSWORD)
    config_crypt.store_password_verification(manager)
    data = {
        "connector": "kraken",
        "kraken_api_key": manager.encrypt_secret_value("kraken_api_key", API_KEY),
        "kraken_secret_key": manager.encrypt_secret_value("kraken_secret_key", API_SECRET),
        "kraken_api_tier": "",
    }
    (conf / "connectors" / "kraken.yml").write_text(yaml.safe_dump(data))
    return conf


@pytest.fixture(autouse=True)
def fake_which(tool, monkeypatch):
    monkeypatch.setattr(tool.shutil, "which", lambda name, path=None: f"/fake/bin/{name}")


@pytest.fixture
def tty(tool, monkeypatch):
    monkeypatch.setattr(tool, "_have_tty", lambda: True)


def _argv(conf, *extra, cmd=("echo", "hi")):
    return ["kraken", "--conf-dir", str(conf), *extra, "--", *cmd]


def _no_leak(captured):
    text = captured.out + captured.err
    for secret in (API_KEY, API_SECRET, PASSWORD):
        assert secret not in text


def test_wrong_password_generic_error(tool, tty, conf_dir, monkeypatch, capsys):
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": "wrong-password")
    monkeypatch.setattr(tool.os, "execvpe", lambda *a: pytest.fail("must not exec"))
    assert tool.run(_argv(conf_dir)) == 1
    captured = capsys.readouterr()
    assert "decryption failed: wrong password or corrupt config" in captured.err
    _no_leak(captured)


def test_dry_run_lists_names_only(tool, tty, conf_dir, monkeypatch, capsys):
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": PASSWORD)
    monkeypatch.setattr(tool.os, "execvpe", lambda *a: pytest.fail("must not exec"))
    assert tool.run(_argv(conf_dir, "--dry-run")) == 0
    captured = capsys.readouterr()
    assert "KRAKEN_API_KEY" in captured.out and "KRAKEN_API_SECRET" in captured.out
    _no_leak(captured)


def test_missing_field_error(tool, tty, conf_dir, monkeypatch, capsys):
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": PASSWORD)
    assert tool.run(_argv(conf_dir, "--map", "X=nonexistent_field")) == 1
    assert "nonexistent_field" in capsys.readouterr().err


def test_empty_field_error(tool, tty, conf_dir, monkeypatch, capsys):
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": PASSWORD)
    assert tool.run(_argv(conf_dir, "--map", "X=kraken_api_tier")) == 1
    assert "kraken_api_tier" in capsys.readouterr().err


def test_exec_env_has_secrets_argv_does_not(tool, tty, conf_dir, monkeypatch, capsys):
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": PASSWORD)
    calls = []
    monkeypatch.setattr(tool.os, "execvpe", lambda file, argv, env: calls.append((file, argv, env)))
    cmd = ("kraken", "order", "--validate")
    assert tool.run(_argv(conf_dir, cmd=cmd)) == 0
    (file, argv, env), = calls
    assert file == "/fake/bin/kraken" and argv == list(cmd)
    assert env["KRAKEN_API_KEY"] == API_KEY
    assert env["KRAKEN_API_SECRET"] == API_SECRET
    assert not any(API_KEY in a or API_SECRET in a for a in argv)
    _no_leak(capsys.readouterr())


def test_custom_map(tool, tty, conf_dir, monkeypatch):
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": PASSWORD)
    calls = []
    monkeypatch.setattr(tool.os, "execvpe", lambda file, argv, env: calls.append(env))
    assert tool.run(_argv(conf_dir, "--map", "MY_KEY=kraken_api_key")) == 0
    assert calls[0]["MY_KEY"] == API_KEY and "KRAKEN_API_SECRET" not in calls[0]


def test_non_kraken_requires_map(tool, tty, conf_dir, capsys):
    assert tool.run(["binance", "--conf-dir", str(conf_dir), "--", "true"]) == 1
    assert "--map" in capsys.readouterr().err


def test_wrong_password_never_decrypts_fields(tool, tty, conf_dir, monkeypatch):
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": "wrong-password")

    def fail(self, attr, value):
        pytest.fail("decrypt_secret_value must not be called")

    # validate_password itself decrypts the verification word, so stub it to the real wrong-password outcome
    monkeypatch.setattr(config_crypt, "validate_password", lambda manager: False)
    monkeypatch.setattr(config_crypt.ETHKeyFileSecretManger, "decrypt_secret_value", fail)
    assert tool.run(_argv(conf_dir)) == 1


def test_tmp_path_has_no_extra_files(tool, tty, conf_dir, tmp_path, monkeypatch):
    before = sorted(p.relative_to(tmp_path) for p in tmp_path.rglob("*"))
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": PASSWORD)
    monkeypatch.setattr(tool.os, "execvpe", lambda *a: None)
    assert tool.run(_argv(conf_dir, "--dry-run")) == 0
    assert tool.run(_argv(conf_dir)) == 0
    after = sorted(p.relative_to(tmp_path) for p in tmp_path.rglob("*"))
    assert after == before
    assert not any(p.name == "__pycache__" for p in tmp_path.rglob("*"))


@pytest.mark.parametrize("pair", [
    "LD_PRELOAD=kraken_api_key", "PYTHONPATH=kraken_api_key", "PATH=kraken_api_key",
    "HOME=kraken_api_key", "DYLD_X=kraken_api_key", "BASH_ENV=kraken_api_key",
    "A=B=C", "1X=kraken_api_key", "A B=kraken_api_key", "X\x00Y=kraken_api_key", "OK=bad field",
])
def test_bad_map_names_refused(tool, tty, conf_dir, monkeypatch, capsys, pair):
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": pytest.fail("must not prompt"))
    monkeypatch.setattr(tool.os, "execvpe", lambda *a: pytest.fail("must not exec"))
    assert tool.run(_argv(conf_dir, "--map", pair)) == 2
    captured = capsys.readouterr()
    _no_leak(captured)
    assert pair not in captured.err


def test_exec_oserror_generic(tool, tty, conf_dir, monkeypatch, capsys):
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": PASSWORD)

    def boom(file, argv, env):
        raise OSError(f"cannot exec with {API_KEY} {API_SECRET}")

    monkeypatch.setattr(tool.os, "execvpe", boom)
    assert tool.run(_argv(conf_dir)) == 126
    captured = capsys.readouterr()
    assert "could not exec /fake/bin/echo: OSError: None" in captured.err
    _no_leak(captured)


def test_exec_permission_error_reports_type_and_strerror(tool, tty, conf_dir, monkeypatch, capsys):
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": PASSWORD)

    def boom(file, argv, env):
        raise PermissionError(13, "Permission denied", API_KEY)

    monkeypatch.setattr(tool.os, "execvpe", boom)
    assert tool.run(_argv(conf_dir)) == 126
    captured = capsys.readouterr()
    assert "PermissionError" in captured.err and "Permission denied" in captured.err
    assert "/fake/bin/echo" in captured.err
    _no_leak(captured)


def test_command_not_found_exits_127_before_prompt(tool, tty, conf_dir, monkeypatch, capsys):
    monkeypatch.setattr(tool.shutil, "which", lambda name, path=None: None)
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": pytest.fail("must not prompt"))
    monkeypatch.setattr(tool.os, "execvpe", lambda *a: pytest.fail("must not exec"))
    assert tool.run(_argv(conf_dir, cmd=("kraken", "x"))) == 127
    assert "error: kraken: not found on PATH" in capsys.readouterr().err


def test_exec_receives_resolved_path_argv0_unchanged(tool, tty, conf_dir, monkeypatch, capsys):
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": PASSWORD)
    calls = []
    monkeypatch.setattr(tool.os, "execvpe", lambda file, argv, env: calls.append((file, argv)))
    assert tool.run(_argv(conf_dir, cmd=("kraken", "order"))) == 0
    assert calls == [("/fake/bin/kraken", ["kraken", "order"])]
    captured = capsys.readouterr()
    assert "exec: /fake/bin/kraken (env vars set: KRAKEN_API_KEY, KRAKEN_API_SECRET)" in captured.err


def test_dry_run_shows_resolved_path(tool, tty, conf_dir, monkeypatch, capsys):
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": PASSWORD)
    assert tool.run(_argv(conf_dir, "--dry-run", cmd=("kraken",))) == 0
    assert "would exec: /fake/bin/kraken" in capsys.readouterr().out


def test_no_tty_refused(tool, conf_dir, monkeypatch, capsys):
    monkeypatch.setattr(tool, "_have_tty", lambda: False)
    monkeypatch.setattr(tool.getpass, "getpass", lambda prompt="": pytest.fail("must not prompt"))
    assert tool.run(_argv(conf_dir)) == 2
    assert "no TTY" in capsys.readouterr().err
