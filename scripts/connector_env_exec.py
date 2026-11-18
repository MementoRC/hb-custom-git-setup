"""Decrypt selected secret fields of ONE Hummingbot connector config and exec a command with them in its env.

Run via `pixi run connector-exec ...` (hummingbot env interpreter, isolated mode).
Nothing is written to disk, no hummingbot logging/Security machinery is started,
and no secret is ever printed.
"""

import argparse
import getpass
import os
import re
import sys
from pathlib import Path

DEFAULT_CONF_DIR = Path("/home/memento/PycharmProjects/Hummingbot/hummingbot/conf")
DEFAULT_MAPS = {
    "kraken": {"KRAKEN_API_KEY": "kraken_api_key", "KRAKEN_API_SECRET": "kraken_secret_key"},
}
_NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")
GENERIC_DECRYPT_ERROR = "decryption failed: wrong password or corrupt config"


_ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_DENIED_ENV_NAMES = frozenset({"PATH", "HOME", "SHELL", "ENV", "BASH_ENV", "IFS", "PS4", "PROMPT_COMMAND"})
_DENIED_ENV_PREFIXES = ("LD_", "DYLD_", "PYTHON")


class ToolError(Exception):
    """Carries a message that is safe to print (never contains secret material)."""


class UsageError(ToolError):
    """Invalid user-supplied names; maps to exit code 2."""


def _check_env_name(name: str) -> None:
    if not _ENV_NAME_RE.fullmatch(name):
        raise UsageError("invalid env var name in --map")
    if name in _DENIED_ENV_NAMES or name.startswith(_DENIED_ENV_PREFIXES):
        raise UsageError(f"refusing to set protected env var: {name}")


def _have_tty() -> bool:
    try:
        with open("/dev/tty"):
            return True
    except OSError:
        return False


def parse_args(argv: list[str]) -> tuple[argparse.Namespace, list[str]]:
    if "--" not in argv:
        raise ToolError("missing '--' followed by the command to run")
    split = argv.index("--")
    cmd = argv[split + 1:]
    parser = argparse.ArgumentParser(prog="connector_env_exec.py", add_help=True)
    parser.add_argument("connector")
    parser.add_argument("--conf-dir", type=Path, default=DEFAULT_CONF_DIR)
    parser.add_argument("--map", action="append", default=[], metavar="ENV_VAR=config_field")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv[:split])
    if not cmd:
        raise ToolError("no command given after '--'")
    return args, cmd


def build_mapping(connector: str, pairs: list[str]) -> dict[str, str]:
    if not _NAME_RE.match(connector):
        raise ToolError("invalid connector name")
    if pairs:
        mapping = {}
        for pair in pairs:
            env_var, sep, field = pair.partition("=")
            if not sep or not env_var or not field:
                raise UsageError("bad --map entry (expected ENV_VAR=config_field)")
            _check_env_name(env_var)
            if not _NAME_RE.fullmatch(field):
                raise UsageError("invalid config field name in --map")
            mapping[env_var] = field
        return mapping
    if connector not in DEFAULT_MAPS:
        raise ToolError(f"no built-in map for connector '{connector}'; pass --map ENV_VAR=config_field")
    return dict(DEFAULT_MAPS[connector])


def decrypt_fields(connector: str, conf_dir: Path, mapping: dict[str, str], password: str) -> dict[str, str]:
    """Return {env_var: plaintext}. Raises ToolError with generic messages only."""
    import yaml

    from hummingbot.client.config import config_crypt

    yml_path = conf_dir / "connectors" / f"{connector}.yml"
    verification_path = conf_dir / ".password_verification"
    if not yml_path.is_file():
        raise ToolError(f"connector config not found: {yml_path}")
    if not verification_path.is_file():
        raise ToolError(f"password verification file not found: {verification_path}")

    # load_connector_config_map_from_file (config_helpers.py:632) validates the whole model and calls
    # decrypt_all_secure_data() via the global Security state; a plain yaml.safe_load is side-effect-free
    # and lets us decrypt only the requested fields.
    try:
        with open(yml_path, encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    except Exception:
        raise ToolError("could not parse connector config") from None
    if not isinstance(data, dict):
        raise ToolError("could not parse connector config")

    for field in mapping.values():
        value = data.get(field)
        if not isinstance(value, str) or not value:
            raise ToolError(f"field missing or empty in config: {field}")

    # validate_password() reads the module-level PASSWORD_VERIFICATION_PATH; point it at --conf-dir.
    config_crypt.PASSWORD_VERIFICATION_PATH = verification_path
    try:
        secrets_manager = config_crypt.ETHKeyFileSecretManger(password)
        if not config_crypt.validate_password(secrets_manager):
            raise ToolError(GENERIC_DECRYPT_ERROR)
        result = {env_var: secrets_manager.decrypt_secret_value(field, data[field]) for env_var, field in mapping.items()}
    except ToolError:
        raise
    except BaseException:  # noqa: BLE001 - never leak exception text, it may embed secret material
        raise ToolError(GENERIC_DECRYPT_ERROR) from None
    for env_var, field in mapping.items():
        if not result[env_var]:
            raise ToolError(f"field decrypted to empty value: {field}")
    return result


def run(argv: list[str]) -> int:
    try:
        args, cmd = parse_args(argv)
        mapping = build_mapping(args.connector, args.map)
        if not _have_tty():
            print("error: no TTY available; refusing to read the password", file=sys.stderr)
            return 2
        password = getpass.getpass("Hummingbot password: ")
        values = decrypt_fields(args.connector, args.conf_dir, mapping, password)
    except UsageError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    except ToolError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    finally:
        password = None  # noqa: F841

    names = ", ".join(sorted(values))
    if args.dry_run:
        print(f"dry-run: would set env vars: {names}; would exec: {cmd[0]}")
        return 0
    print(f"exec: {cmd[0]} (env vars set: {names})", file=sys.stderr)
    env = {**os.environ, **values}
    try:
        os.execvpe(cmd[0], cmd, env)
    except OSError:
        print("error: could not exec command", file=sys.stderr)
        return 126
    return 0  # only reached when execvpe is mocked


def main() -> None:
    try:
        code = run(sys.argv[1:])
    except SystemExit:
        raise
    except FileNotFoundError:
        print("error: command not found", file=sys.stderr)
        code = 127
    except BaseException:  # noqa: BLE001 - no tracebacks: they could contain secret values
        print("error: unexpected failure", file=sys.stderr)
        code = 1
    sys.exit(code)


if __name__ == "__main__":
    main()
