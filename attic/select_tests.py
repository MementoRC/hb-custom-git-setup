#!/usr/bin/env python3
"""
select_tests.py — Diff-driven test selector for the upstream→ci-base gate.

Given a git diff (by ref pair or diff file), resolves which test files should
run, using test-selection-map.yaml rules. Emits selected test paths to stdout.

Exit codes:
  0 = selection ready (stdout contains test paths)
  1 = error (stderr contains message)
  2 = escape to full suite (selected% > threshold)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# PyYAML import guard
# ---------------------------------------------------------------------------
try:
    import yaml
except ImportError:
    print("PyYAML not installed; pip install pyyaml", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_VERBOSE = False


def log(level: str, msg: str) -> None:
    if level == "DEBUG" and not _VERBOSE:
        return
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] [{level}] {msg}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Glob matching with ** support
# ---------------------------------------------------------------------------

def _glob_match(path: str, pattern: str) -> bool:
    """Match path against glob pattern with ** recursive support."""
    regex_parts: list[str] = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            if i + 1 < len(pattern) and pattern[i + 1] == "*":
                regex_parts.append(".*")
                i += 2
                if i < len(pattern) and pattern[i] == "/":
                    i += 1
            else:
                regex_parts.append("[^/]*")
                i += 1
        elif c == "?":
            regex_parts.append("[^/]")
            i += 1
        elif c in r".()[]{}+^$|\\":
            regex_parts.append(re.escape(c))
            i += 1
        else:
            regex_parts.append(c)
            i += 1
    try:
        return re.fullmatch("".join(regex_parts), path) is not None
    except re.error:
        return False


# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

def load_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        log("ERROR", f"Config file not found: {path}")
        sys.exit(1)
    with path.open() as fh:
        cfg = yaml.safe_load(fh)
    if cfg is None or not isinstance(cfg, dict):
        log("ERROR", f"Config file is empty or malformed: {path}")
        sys.exit(1)
    log("DEBUG", f"Loaded config from {path}")
    return cfg


# ---------------------------------------------------------------------------
# State file helpers
# ---------------------------------------------------------------------------

def load_state(state_file: Path) -> dict[str, Any]:
    if state_file.exists():
        try:
            with state_file.open() as fh:
                return json.load(fh)
        except (json.JSONDecodeError, OSError) as exc:
            log("WARN", f"Could not read state file {state_file}: {exc}; starting fresh")
    return {
        "version": 1,
        "tested_commits": {},
        "total_test_count_cache": {},
        "last_synced_upstream_sha": None,
    }


def save_state(state_file: Path, state: dict[str, Any]) -> None:
    try:
        state_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = state_file.with_suffix(".tmp")
        with tmp.open("w") as fh:
            json.dump(state, fh, indent=2)
        os.replace(tmp, state_file)
        log("DEBUG", f"State written to {state_file}")
    except OSError as exc:
        log("WARN", f"Could not write state file {state_file}: {exc}; continuing without persistence")


# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

def _git(repo: Path, *args: str) -> str:
    """Run a git command and return stripped stdout. Raises on error."""
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip())
    return result.stdout.strip()


def auto_detect_repo() -> Path:
    """Walk up from CWD to find a .git root."""
    current = Path.cwd()
    for candidate in [current, *current.parents]:
        if (candidate / ".git").exists():
            return candidate
    raise RuntimeError("Could not auto-detect git repository from CWD")


def _resolve_upstream_base(repo: Path, state: dict[str, Any]) -> str:
    """Return the best base ref for upstream mode."""
    cached = state.get("last_synced_upstream_sha")
    if cached:
        log("DEBUG", f"Using cached upstream sha as base: {cached}")
        return cached
    # Fallback: merge-base of ci-base and upstream/development
    try:
        base = _git(repo, "merge-base", "ci-base", "upstream/development")
        log("DEBUG", f"merge-base fallback: {base}")
        return base
    except RuntimeError as exc:
        log("ERROR", f"Could not resolve upstream base ref: {exc}")
        sys.exit(1)


def _files_from_diff_file(diff_file: Path) -> list[Path]:
    """Parse a unified diff file for changed file paths."""
    changed: list[Path] = []
    with diff_file.open() as fh:
        for line in fh:
            if line.startswith("+++ b/") or line.startswith("--- a/"):
                # Extract path after a/ or b/ prefix
                raw = line[6:].strip()
                if raw and raw != "/dev/null":
                    changed.append(Path(raw))
    # Deduplicate preserving order
    seen: set[str] = set()
    result: list[Path] = []
    for p in changed:
        s = str(p)
        if s not in seen:
            seen.add(s)
            result.append(p)
    return result


def get_changed_files(
    repo: Path,
    mode: str,
    base_ref: str | None,
    head_ref: str | None,
    diff_file: Path | None,
    state: dict[str, Any],
    config: dict[str, Any],
    source_branch: str | None = None,
) -> tuple[list[Path], str | None]:
    """
    Return (changed_source_files, resolved_head_sha).

    changed_source_files excludes test/ paths and ignored globs.
    resolved_head_sha is the concrete SHA of the head ref in upstream mode
    (resolved via git rev-parse), or None in branch/diff-file modes.

    When mode == "branch" and source_branch is provided, the diff base is
    resolved as merge-base(head_ref, source_branch) to narrow the diff to
    only the branch-specific changes.
    """
    ignore_globs: list[str] = config.get("ignore", [])
    resolved_head_sha: str | None = None

    if diff_file is not None:
        log("INFO", f"Reading diff from file: {diff_file}")
        raw_files = _files_from_diff_file(diff_file)
    else:
        if mode == "upstream":
            resolved_base = base_ref or _resolve_upstream_base(repo, state)
            head_ref_name = head_ref or "upstream/development"
            # Resolve the head ref to a concrete SHA so we can persist it
            try:
                resolved_head_sha = _git(repo, "rev-parse", head_ref_name)
            except RuntimeError as exc:
                log("WARN", f"Could not resolve head SHA for {head_ref_name}: {exc}")
                resolved_head_sha = None
            resolved_head = head_ref_name
        else:
            # branch mode: explicit refs required
            if not base_ref or not head_ref:
                log("ERROR", "branch mode requires --base-ref and --head-ref (or --diff-file)")
                sys.exit(1)
            if source_branch:
                # Narrow diff to branch-specific changes only
                try:
                    merge_base_sha = _git(repo, "merge-base", head_ref, source_branch)
                    log("DEBUG", f"merge-base({head_ref}, {source_branch}) = {merge_base_sha}")
                    resolved_base = merge_base_sha
                except RuntimeError as exc:
                    log("ERROR", f"Could not compute merge-base for --source-branch: {exc}")
                    sys.exit(1)
            else:
                resolved_base = base_ref
            resolved_head = head_ref

        log("INFO", f"Getting diff: {resolved_base}..{resolved_head}")
        try:
            output = _git(repo, "diff", "--name-only", resolved_base, resolved_head)
        except RuntimeError as exc:
            log("ERROR", f"git diff failed: {exc}")
            sys.exit(1)

        raw_files = [Path(line) for line in output.splitlines() if line.strip()]

    # Filter: exclude ignored globs and paths starting with test/
    result: list[Path] = []
    for p in raw_files:
        ps = str(p)
        if ps.startswith("test/"):
            log("DEBUG", f"Skip (test dir): {ps}")
            continue
        ignored = any(_glob_match(ps, g) for g in ignore_globs)
        if ignored:
            log("DEBUG", f"Skip (ignored): {ps}")
            continue
        result.append(p)

    log("INFO", f"Changed source files after filtering: {len(result)}")
    return result, resolved_head_sha


# ---------------------------------------------------------------------------
# Test selection
# ---------------------------------------------------------------------------

def _expand_glob_pattern(pattern: str, repo: Path) -> set[Path]:
    """Expand a glob pattern relative to repo root; return existing paths."""
    found: set[Path] = set()
    for p in repo.glob(pattern):
        rel = p.relative_to(repo)
        name = rel.name
        if name.startswith("test_") or name.endswith("_test.py"):
            found.add(rel)
    return found


def _apply_mirror_rule(
    source_file: Path,
    config: dict[str, Any],
    repo: Path,
) -> set[Path]:
    """Mirror hummingbot/X/foo.py -> test/hummingbot/X/test_foo.py."""
    rule = config.get("mirror_rule", {})
    if not rule.get("enabled", True):
        return set()

    src_root = rule.get("source_root", "hummingbot")
    test_root = rule.get("test_root", "test/hummingbot")
    prefix = rule.get("test_filename_prefix", "test_")

    parts = source_file.parts
    if not parts or parts[0] != src_root:
        return set()

    # Rebuild under test_root
    rel_parts = parts[1:]  # strip "hummingbot"
    if not rel_parts:
        return set()

    stem = source_file.stem
    test_name = f"{prefix}{stem}.py"
    test_path = Path(test_root, *rel_parts[:-1], test_name)
    abs_path = repo / test_path
    if abs_path.exists():
        log("DEBUG", f"Mirror hit: {source_file} -> {test_path}")
        return {test_path}
    log("DEBUG", f"Mirror miss: {test_path} does not exist")
    return set()


def _apply_extra_mappings(
    source_file: Path,
    config: dict[str, Any],
    repo: Path,
) -> set[Path]:
    """Apply extra_mappings; return test paths from first matching rule."""
    mappings = config.get("extra_mappings", [])
    sf_str = str(source_file)

    for mapping in mappings:
        src_glob = mapping.get("source_glob", "")
        if not _glob_match(sf_str, src_glob):
            continue

        test_globs: list[str] = mapping.get("test_globs", [])
        found: set[Path] = set()

        for tg in test_globs:
            # Handle {basename} substitution
            if "{basename}" in tg:
                tg = tg.replace("{basename}", source_file.stem)

            # Handle {1} capture from source_glob (sub-package name)
            if "{1}" in tg:
                # Extract the wildcard match from position 1 in source_glob
                # e.g. sub-packages/*/src/**/*.py => capture *
                cap = _extract_capture(sf_str, src_glob, 1)
                if cap:
                    tg = tg.replace("{1}", cap)
                else:
                    continue

            found |= _expand_glob_pattern(tg, repo)

        if found:
            log("DEBUG", f"extra_mappings hit: {source_file} -> {len(found)} tests")
            return found
        # Return empty but still matched — first match wins, no fallthrough
        return set()

    return set()


def _extract_capture(path_str: str, glob_pattern: str, index: int) -> str | None:
    """
    Extract the Nth wildcard capture from a glob pattern match.
    Very simplified: splits both on "/" and matches segment by segment.
    """
    p_parts = path_str.split("/")
    g_parts = glob_pattern.split("/")
    captures: list[str] = []

    gi = 0
    pi = 0
    while gi < len(g_parts) and pi < len(p_parts):
        gp = g_parts[gi]
        if gp == "**":
            # Consume remaining path segments to next static segment
            gi += 1
            next_static = g_parts[gi] if gi < len(g_parts) else None
            if next_static is None:
                break
            while pi < len(p_parts) and p_parts[pi] != next_static:
                pi += 1
        elif gp == "*":
            captures.append(p_parts[pi])
            gi += 1
            pi += 1
        else:
            gi += 1
            pi += 1

    if index <= len(captures):
        return captures[index - 1]
    return None


def select_tests(
    changed_files: list[Path],
    config: dict[str, Any],
    repo: Path,
) -> set[Path]:
    """
    Resolve the set of test files to run.

    Priority:
      1. always_on (unconditional)
      2. cross_cutting (broad, checked first per changed file)
      3. mirror_rule
      4. extra_mappings (first match wins)

    Returns only paths that exist on disk and match test_*.py / *_test.py.
    """
    always_on: list[str] = config.get("always_on", [])
    cross_cutting: list[dict[str, Any]] = config.get("cross_cutting", [])

    selected: set[Path] = set()

    # 1. always_on
    for p in always_on:
        path = repo / p
        if path.exists():
            selected.add(Path(p))
        else:
            log("WARN", f"always_on entry does not exist: {p}")

    # 2-4. Per changed file
    for sf in changed_files:
        sf_str = str(sf)
        matched_cross = False

        # 2. cross_cutting (check all; union results)
        for cc in cross_cutting:
            src_glob = cc.get("source_glob", "")
            if _glob_match(sf_str, src_glob):
                for tg in cc.get("tests_globs", []):
                    hits = _expand_glob_pattern(tg, repo)
                    selected |= hits
                    log("DEBUG", f"cross_cutting: {sf} matched {src_glob} -> {len(hits)} tests")
                matched_cross = True

        if matched_cross:
            continue

        # 3. mirror_rule
        mirror_hits = _apply_mirror_rule(sf, config, repo)
        if mirror_hits:
            selected |= mirror_hits
            continue

        # 4. extra_mappings
        extra_hits = _apply_extra_mappings(sf, config, repo)
        if extra_hits:
            selected |= extra_hits
            continue

        log("DEBUG", f"No test mapping found for: {sf}")

    # Final filter: only files that exist and are test files
    final: set[Path] = set()
    for p in selected:
        name = p.name
        is_test = name.startswith("test_") or name.endswith("_test.py")
        if not is_test:
            log("DEBUG", f"Dropping non-test path: {p}")
            continue
        if not (repo / p).exists():
            log("DEBUG", f"Dropping non-existent path: {p}")
            continue
        final.add(p)

    log("INFO", f"Selected {len(final)} test files")
    return final


# ---------------------------------------------------------------------------
# Total test count
# ---------------------------------------------------------------------------

def compute_total_tests(
    repo: Path,
    state: dict[str, Any],
    force_recompute: bool,
) -> int:
    """
    Return total test file count, using TTL cache in state.
    Falls back to counting test_*.py files if subprocess fails.
    """
    cache = state.get("total_test_count_cache", {})
    ttl_hours = cache.get("ttl_hours", 24)

    if not force_recompute and cache.get("value") and cache.get("computed_at"):
        try:
            computed_at = datetime.fromisoformat(cache["computed_at"])
            age_hours = (datetime.now(tz=timezone.utc) - computed_at).total_seconds() / 3600
            if age_hours < ttl_hours:
                log("DEBUG", f"Using cached total test count: {cache['value']}")
                return int(cache["value"])
        except (ValueError, TypeError):
            pass

    log("INFO", "Recomputing total test count via file count")
    # Count test_*.py files under repo/test/ only.
    # repo.rglob("test_*.py") is intentionally NOT used here — it would traverse
    # sub-packages/, hummingbot/ Cython test fixtures, and any other test_-prefixed
    # files outside the canonical test root, inflating the count ~70x.
    # If additional test roots are needed in future, add them here explicitly.
    test_root = repo / "test"
    if test_root.is_dir():
        count = sum(1 for _ in test_root.rglob("test_*.py"))
    else:
        count = 0
    log("INFO", f"Total test files: {count}")

    state["total_test_count_cache"] = {
        "value": count,
        "computed_at": datetime.now(tz=timezone.utc).isoformat(),
        "ttl_hours": ttl_hours,
    }
    return count


# ---------------------------------------------------------------------------
# Emit selection
# ---------------------------------------------------------------------------

def emit_selection(
    selected: set[Path],
    total: int,
    threshold_pct: int,
    shadow: bool,
) -> int:
    """
    Print selected tests to stdout and return exit code.

    Exit 2 if selected% > threshold_pct (unless shadow mode).
    In shadow mode, always exit 0 but prepend a marker line.
    """
    n = len(selected)
    pct = int(100 * n / max(total, 1))

    log("INFO", f"Selection: {n}/{total} ({pct}%) threshold={threshold_pct}%")

    if not shadow and pct > threshold_pct:
        log("WARN", f"Selection {pct}% > threshold {threshold_pct}%; falling back to full suite")
        return 2

    if shadow:
        print(f"# SHADOW: would-select {n} of {total} ({pct}%)")

    for p in sorted(str(p) for p in selected):
        print(p)

    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    script_dir = Path(__file__).parent
    default_config = script_dir.parent / "configs" / "test-selection-map.yaml"
    default_state = script_dir.parent / "state" / "select_tests_state.json"

    parser = argparse.ArgumentParser(
        description="Diff-driven test selector for the upstream→ci-base gate.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--mode",
        choices=["upstream", "branch"],
        required=True,
        help="upstream: diff against last synced upstream sha; branch: explicit refs required",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=default_config,
        metavar="PATH",
        help=f"Path to test-selection-map.yaml (default: {default_config})",
    )
    parser.add_argument(
        "--repo",
        type=Path,
        default=None,
        metavar="PATH",
        help="Repository root (default: $REPO_PATH env or auto-detected from git)",
    )

    diff_group = parser.add_mutually_exclusive_group()
    diff_group.add_argument(
        "--diff-file",
        type=Path,
        metavar="PATH",
        help="Read unified diff from file instead of running git diff",
    )
    diff_group.add_argument(
        "--base-ref",
        metavar="REF",
        help="Base git ref for diff (required with --head-ref in branch mode)",
    )
    parser.add_argument(
        "--head-ref",
        metavar="REF",
        help="Head git ref for diff",
    )

    parser.add_argument(
        "--escape-threshold-pct",
        type=int,
        default=None,
        metavar="N",
        help="Override escape_threshold_pct from config",
    )
    parser.add_argument(
        "--state-file",
        type=Path,
        default=default_state,
        metavar="PATH",
        help=f"State file path (default: {default_state})",
    )
    parser.add_argument(
        "--no-history",
        action="store_true",
        help="Skip commit-dedup and state-file writes",
    )
    parser.add_argument(
        "--recompute-total",
        action="store_true",
        help="Force refresh of total test count cache",
    )
    parser.add_argument(
        "--shadow",
        action="store_true",
        help="Shadow mode: emit selection to stdout + marker line; never exit 2",
    )
    parser.add_argument(
        "--source-branch",
        metavar="BRANCH",
        default=None,
        help=(
            "Branch mode only: narrow the diff to merge-base(head_ref, BRANCH)..head_ref "
            "instead of base_ref..head_ref. Mirrors the .sh verifier's per-merged-branch "
            "selective testing. Ignored when --diff-file is provided."
        ),
    )
    parser.add_argument(
        "--mark-success-for",
        metavar="SHA",
        default=None,
        help=(
            "Update state['tested_commits'][SHA] = {status: success, date: now, mode: branch} "
            "then exit 0. All other flags are ignored except --state-file. "
            "Used by the bash caller after pytest passes."
        ),
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Enable debug logging to stderr",
    )
    return parser


def _handle_mark_success_for(sha: str, state_file: Path) -> int:
    """
    Write tested_commits[sha] = {status, date, mode} to state and exit 0.

    Called when --mark-success-for is provided. All other main() logic is
    skipped; only the state file is touched.
    """
    state = load_state(state_file)
    state["tested_commits"][sha] = {
        "status": "success",
        "date": datetime.now(tz=timezone.utc).isoformat(),
        "mode": "branch",
    }
    save_state(state_file, state)
    log("INFO", f"Marked commit {sha} as successfully tested (branch mode)")
    return 0


def main() -> int:
    global _VERBOSE

    parser = build_parser()
    args = parser.parse_args()

    if args.verbose:
        _VERBOSE = True

    # --mark-success-for: state-only update, skip all diff/selection logic
    if args.mark_success_for:
        return _handle_mark_success_for(args.mark_success_for, args.state_file)

    # Resolve repo root
    repo: Path
    if args.repo:
        repo = args.repo.resolve()
    elif "REPO_PATH" in os.environ:
        repo = Path(os.environ["REPO_PATH"]).resolve()
    else:
        try:
            repo = auto_detect_repo()
        except RuntimeError as exc:
            log("ERROR", str(exc))
            return 1

    log("DEBUG", f"Repo root: {repo}")

    # Load config
    config = load_config(args.config)

    # Load state
    state: dict[str, Any] = {}
    if not args.no_history:
        state = load_state(args.state_file)

    # Branch-mode commit dedup: skip selection if this commit was previously tested OK
    if args.mode == "branch" and not args.no_history and args.head_ref and not args.diff_file:
        try:
            head_sha = _git(repo, "rev-parse", args.head_ref)
        except RuntimeError as exc:
            log("WARN", f"Could not resolve head SHA for dedup check: {exc}")
            head_sha = None
        if head_sha:
            entry = state.get("tested_commits", {}).get(head_sha)
            if isinstance(entry, dict) and entry.get("status") == "success" and entry.get("mode") == "branch":
                log("INFO", f"Commit {head_sha} previously tested (success); skipping")
                return 0
    else:
        head_sha = None

    # Get changed files
    changed, resolved_head_sha = get_changed_files(
        repo=repo,
        mode=args.mode,
        base_ref=args.base_ref,
        head_ref=args.head_ref,
        diff_file=args.diff_file,
        state=state,
        config=config,
        source_branch=args.source_branch,
    )

    if not changed:
        log("INFO", "No changed source files; emitting always_on list only")

    # Select tests
    selected = select_tests(changed, config, repo)

    # Compute total
    total = compute_total_tests(repo, state, args.recompute_total)

    # Threshold
    threshold = args.escape_threshold_pct
    if threshold is None:
        threshold = config.get("escape_threshold_pct", 50)

    # Emit
    exit_code = emit_selection(selected, total, threshold, args.shadow)

    # Persist state (unless --no-history or exit 2)
    if not args.no_history:
        # Persist the resolved upstream head SHA so the next run diffs only new commits.
        # Only in upstream mode; only when the SHA was successfully resolved.
        if args.mode == "upstream" and resolved_head_sha:
            state["last_synced_upstream_sha"] = resolved_head_sha
            log("DEBUG", f"Persisting last_synced_upstream_sha: {resolved_head_sha}")
        save_state(args.state_file, state)

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
