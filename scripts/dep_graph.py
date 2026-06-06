#!/usr/bin/env python3
"""dep_graph.py — Emit JSON dependency graph of hb-* sub-packages.

Usage:
    python dep_graph.py
    python dep_graph.py --repo /path/to/hummingbot
    python dep_graph.py --repo /path/to/hummingbot | python -m json.tool

Output (stdout): JSON object with dependency metadata for all 14 sub-packages.
Errors/warnings: stderr only.
Exit code: always 0.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Python 3.11+ has tomllib in stdlib; fall back to tomli for 3.10
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib  # type: ignore[no-reattr,import-not-found]
    except ImportError:
        print(
            "ERROR: tomllib (Python 3.11+) or tomli package required. "
            "Install with: pip install tomli",
            file=sys.stderr,
        )
        sys.exit(1)

SUBPACKAGE_NAMES = [
    "async-utils",
    "candles-feed",
    "connector-utils",
    "data-type-primitives",
    "event-bus",
    "liquidations-feed",
    "logger",
    "market-connector",
    "market-data",
    "market-simulator",
    "rate-oracle",
    "remote-iface",
    "strategy-framework",
    "web-assistant",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Emit JSON dep graph for hb-* sub-packages.")
    parser.add_argument(
        "--repo",
        type=Path,
        default=None,
        help="Path to hummingbot repo root (default: ../../hummingbot relative to script dir)",
    )
    return parser.parse_args()


def resolve_repo(explicit: Path | None) -> Path:
    if explicit is not None:
        return explicit.resolve()
    script_dir = Path(__file__).resolve().parent
    # script is in custom_git_setup/scripts/; hummingbot is ../../hummingbot
    candidate = (script_dir / ".." / ".." / "hummingbot").resolve()
    return candidate


def read_toml(path: Path) -> dict[str, Any]:
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def extract_hb_deps(deps: list[str]) -> list[str]:
    """Filter dependency strings to those whose package name starts with 'hb-'."""
    result: list[str] = []
    for dep in deps:
        # PEP 508: name is the leading identifier before any version specifier or extras
        name = dep.strip().split("[")[0].split(">")[0].split("<")[0].split("=")[0].split("!")[0]
        name = name.strip()
        if name.startswith("hb-"):
            result.append(name)
    return result


def process_subpackage(pkg_name: str, subpkgs_dir: Path) -> dict[str, Any] | None:
    pkg_dir = subpkgs_dir / pkg_name
    pyproject_path = pkg_dir / "pyproject.toml"

    if not pyproject_path.exists():
        print(f"WARN: {pkg_name}: pyproject.toml not found at {pyproject_path}", file=sys.stderr)
        return None

    try:
        data = read_toml(pyproject_path)
    except Exception as exc:  # noqa: BLE001
        print(f"WARN: {pkg_name}: failed to parse pyproject.toml: {exc}", file=sys.stderr)
        return None

    project = data.get("project", {})
    name: str = project.get("name", pkg_name)
    deps: list[str] = project.get("dependencies", [])
    optional_deps: dict[str, list[str]] = project.get("optional-dependencies", {})

    # [tool.hummingbot.supersedes] — may be absent
    tool_hb = data.get("tool", {}).get("hummingbot", {})
    supersedes_raw = tool_hb.get("supersedes", {})
    if isinstance(supersedes_raw, dict):
        supersedes: list[str] = supersedes_raw.get("modules", [])
    elif isinstance(supersedes_raw, list):
        # future-proof: if it becomes a plain list
        supersedes = supersedes_raw
    else:
        supersedes = []

    # Collect all hb-* deps across main + optional groups
    all_dep_strings = list(deps)
    for group_deps in optional_deps.values():
        all_dep_strings.extend(group_deps)
    depends_on_hb = sorted(set(extract_hb_deps(all_dep_strings)))

    return {
        "name": name,
        "path": f"sub-packages/{pkg_name}",
        "deps": deps,
        "optional_deps": optional_deps,
        "supersedes": supersedes,
        "depends_on_hb": depends_on_hb,
    }


def main() -> None:
    args = parse_args()
    repo_root = resolve_repo(args.repo)
    subpkgs_dir = repo_root / "sub-packages"

    if not subpkgs_dir.is_dir():
        print(
            f"ERROR: sub-packages directory not found: {subpkgs_dir}\n"
            "Use --repo to specify the hummingbot repo root.",
            file=sys.stderr,
        )
        sys.exit(0)  # always exit 0 per spec

    subpackages: list[dict[str, Any]] = []
    for pkg_name in sorted(SUBPACKAGE_NAMES):  # alphabetical for deterministic diffs
        result = process_subpackage(pkg_name, subpkgs_dir)
        if result is not None:
            subpackages.append(result)

    output = {
        "generated_at": datetime.now(tz=timezone.utc).isoformat(),
        "repo_root": str(repo_root),
        "subpackages": subpackages,
    }

    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
