"""Tests for select_tests.py — diff-driven test selector."""
from __future__ import annotations

import json
import textwrap
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

import select_tests
from select_tests import (
    _apply_extra_mappings,
    _apply_mirror_rule,
    _extract_capture,
    _files_from_diff_file,
    _glob_match,
    _handle_mark_success_for,
    compute_total_tests,
    emit_selection,
    get_changed_files,
    load_config,
    load_state,
    save_state,
    select_tests as select_tests_fn,
)


# ---------------------------------------------------------------------------
# A. Glob matching
# ---------------------------------------------------------------------------


def test_glob_match_docs_doublestar() -> None:
    """docs/** matches a file directly under docs/."""
    assert _glob_match("docs/README.md", "docs/**") is True


def test_glob_match_doublestar_md_recursive() -> None:
    """**/*.md matches a deeply nested .md file."""
    assert _glob_match("docs/sub/file.md", "**/*.md") is True


def test_glob_match_different_top_dir_fails() -> None:
    """hummingbot/foo.py does not match docs/**."""
    assert _glob_match("hummingbot/foo.py", "docs/**") is False


def test_glob_match_doublestar_middle() -> None:
    """a/**/c matches a/b/c (** spanning one segment)."""
    assert _glob_match("a/b/c", "a/**/c") is True


def test_glob_match_doublestar_zero_segments() -> None:
    """a/**/c matches a/c (** spanning zero segments)."""
    assert _glob_match("a/c", "a/**/c") is True


def test_glob_match_single_star_no_cross_slash() -> None:
    """hummingbot/*.py does NOT match a file two dirs deep."""
    assert _glob_match("hummingbot/connector/exchange/foo.py", "hummingbot/*.py") is False


def test_glob_match_single_star_same_dir() -> None:
    """hummingbot/*.py matches a file directly in that dir."""
    assert _glob_match("hummingbot/foo.py", "hummingbot/*.py") is True


def test_glob_match_question_mark() -> None:
    """? matches exactly one non-slash character."""
    assert _glob_match("a/b", "a/?") is True
    assert _glob_match("a/bc", "a/?") is False


def test_glob_match_literal_dot() -> None:
    """Literal dot in pattern matches only a literal dot."""
    assert _glob_match("hummingbot/core/pubsub.py", "hummingbot/core/pubsub.*") is True
    assert _glob_match("hummingbot/core/pubsubXpy", "hummingbot/core/pubsub.*") is False


# ---------------------------------------------------------------------------
# B. Config loading
# ---------------------------------------------------------------------------


def test_load_config_valid(tmp_path: Path) -> None:
    """Valid YAML with required keys loads as a dict."""
    cfg_file = tmp_path / "cfg.yaml"
    cfg_file.write_text(
        textwrap.dedent("""\
        version: 1
        always_on: []
        ignore: []
        mirror_rule:
          enabled: true
          source_root: hummingbot
          test_root: test/hummingbot
          test_filename_prefix: test_
        extra_mappings: []
        cross_cutting: []
        escape_threshold_pct: 50
        """)
    )
    cfg = load_config(cfg_file)
    assert isinstance(cfg, dict), "load_config should return a dict"
    assert cfg["version"] == 1
    assert cfg["escape_threshold_pct"] == 50


def test_load_config_missing_file_exits(tmp_path: Path) -> None:
    """Missing config file triggers sys.exit(1)."""
    missing = tmp_path / "no_such.yaml"
    with pytest.raises(SystemExit) as exc_info:
        load_config(missing)
    assert exc_info.value.code == 1


def test_load_config_malformed_yaml_exits(tmp_path: Path) -> None:
    """A YAML file that parses to None (empty) triggers sys.exit(1)."""
    empty_cfg = tmp_path / "empty.yaml"
    empty_cfg.write_text("")
    with pytest.raises(SystemExit) as exc_info:
        load_config(empty_cfg)
    assert exc_info.value.code == 1


def test_load_config_non_dict_yaml_exits(tmp_path: Path) -> None:
    """A YAML file that parses to a list (not dict) triggers sys.exit(1)."""
    list_cfg = tmp_path / "list.yaml"
    list_cfg.write_text("- item1\n- item2\n")
    with pytest.raises(SystemExit) as exc_info:
        load_config(list_cfg)
    assert exc_info.value.code == 1


# ---------------------------------------------------------------------------
# C. Ignore filtering (via get_changed_files)
# ---------------------------------------------------------------------------


def _write_diff_file(tmp_path: Path, changed_paths: list[str]) -> Path:
    """Write a minimal unified diff referencing the given paths."""
    lines = []
    for p in changed_paths:
        lines.append(f"--- a/{p}\n")
        lines.append(f"+++ b/{p}\n")
    diff_file = tmp_path / "changes.diff"
    diff_file.write_text("".join(lines))
    return diff_file


def _minimal_config(ignore: list[str] | None = None) -> dict[str, Any]:
    return {
        "ignore": ignore or [],
        "always_on": [],
        "mirror_rule": {"enabled": False},
        "extra_mappings": [],
        "cross_cutting": [],
        "escape_threshold_pct": 50,
    }


def test_ignore_only_docs_returns_empty(tmp_path: Path) -> None:
    """A diff with only docs/README.md → zero source files after filtering."""
    diff_file = _write_diff_file(tmp_path, ["docs/README.md"])
    cfg = _minimal_config(ignore=["docs/**", "**/*.md"])
    result, _sha = get_changed_files(
        repo=tmp_path,
        mode="branch",
        base_ref=None,
        head_ref=None,
        diff_file=diff_file,
        state={},
        config=cfg,
    )
    assert result == [], f"Expected empty after ignore filtering, got {result}"


def test_ignore_mixed_diff_keeps_source(tmp_path: Path) -> None:
    """hummingbot/foo.py survives; docs/X.md is filtered out."""
    diff_file = _write_diff_file(tmp_path, ["hummingbot/foo.py", "docs/X.md"])
    cfg = _minimal_config(ignore=["docs/**", "**/*.md"])
    result, _sha = get_changed_files(
        repo=tmp_path,
        mode="branch",
        base_ref=None,
        head_ref=None,
        diff_file=diff_file,
        state={},
        config=cfg,
    )
    assert result == [Path("hummingbot/foo.py")], f"Unexpected result: {result}"


def test_test_dir_filtered_out(tmp_path: Path) -> None:
    """Files starting with test/ are silently dropped."""
    diff_file = _write_diff_file(tmp_path, ["test/hummingbot/foo.py"])
    cfg = _minimal_config()
    result, _sha = get_changed_files(
        repo=tmp_path,
        mode="branch",
        base_ref=None,
        head_ref=None,
        diff_file=diff_file,
        state={},
        config=cfg,
    )
    assert result == [], f"test/ files should be filtered, got {result}"


# ---------------------------------------------------------------------------
# D. Mirror rule
# ---------------------------------------------------------------------------


def _mirror_config() -> dict[str, Any]:
    return {
        "mirror_rule": {
            "enabled": True,
            "source_root": "hummingbot",
            "test_root": "test/hummingbot",
            "test_filename_prefix": "test_",
        },
    }


def test_mirror_rule_hit(tmp_path: Path) -> None:
    """Source hummingbot/strategy_v2/executors/foo.py → test/hummingbot/strategy_v2/executors/test_foo.py."""
    expected = tmp_path / "test" / "hummingbot" / "strategy_v2" / "executors" / "test_foo.py"
    expected.parent.mkdir(parents=True)
    expected.write_text("")

    result = _apply_mirror_rule(
        Path("hummingbot/strategy_v2/executors/foo.py"),
        _mirror_config(),
        tmp_path,
    )
    assert result == {Path("test/hummingbot/strategy_v2/executors/test_foo.py")}, (
        f"Mirror rule should return the test path, got {result}"
    )


def test_mirror_rule_miss_no_existing_file(tmp_path: Path) -> None:
    """When the expected test file does not exist, mirror returns empty set."""
    result = _apply_mirror_rule(
        Path("hummingbot/strategy_v2/executors/foo.py"),
        _mirror_config(),
        tmp_path,
    )
    assert result == set(), f"Mirror rule miss should return empty set, got {result}"


def test_mirror_rule_non_hummingbot_source(tmp_path: Path) -> None:
    """Source not under hummingbot/ is ignored by mirror rule."""
    result = _apply_mirror_rule(
        Path("sub-packages/foo/src/bar.py"),
        _mirror_config(),
        tmp_path,
    )
    assert result == set()


def test_mirror_rule_disabled(tmp_path: Path) -> None:
    """mirror_rule.enabled=false → always returns empty set."""
    cfg = {"mirror_rule": {"enabled": False}}
    result = _apply_mirror_rule(
        Path("hummingbot/foo.py"),
        cfg,
        tmp_path,
    )
    assert result == set()


# ---------------------------------------------------------------------------
# E. Cross-cutting trigger
# ---------------------------------------------------------------------------


def _make_test_tree(repo: Path, paths: list[str]) -> None:
    """Create placeholder test files in repo."""
    for p in paths:
        full = repo / p
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_text("")


def test_cross_cutting_trigger_expands_to_existing_tests(tmp_path: Path) -> None:
    """pubsub source → cross_cutting expands to test/hummingbot/**/*.py but only existing ones."""
    existing_tests = [
        "test/hummingbot/core/test_pubsub.py",
        "test/hummingbot/strategy_v2/test_runnable_base.py",
    ]
    _make_test_tree(tmp_path, existing_tests)

    cfg = {
        "always_on": [],
        "cross_cutting": [
            {
                "source_glob": "hummingbot/core/pubsub.*",
                "tests_globs": ["test/hummingbot/**/*.py"],
            }
        ],
        "mirror_rule": {"enabled": False},
        "extra_mappings": [],
    }
    changed = [Path("hummingbot/core/pubsub.py")]
    selected = select_tests_fn(changed, cfg, tmp_path)

    for t in existing_tests:
        assert Path(t) in selected, f"Expected {t} in cross-cutting selection, got {selected}"


def test_cross_cutting_only_selects_existing_files(tmp_path: Path) -> None:
    """Cross-cutting expansion silently drops non-existent test paths."""
    # Create only one of two plausible test files
    _make_test_tree(tmp_path, ["test/hummingbot/core/test_pubsub.py"])

    cfg = {
        "always_on": [],
        "cross_cutting": [
            {
                "source_glob": "hummingbot/core/pubsub.*",
                "tests_globs": ["test/hummingbot/**/*.py"],
            }
        ],
        "mirror_rule": {"enabled": False},
        "extra_mappings": [],
    }
    changed = [Path("hummingbot/core/pubsub.py")]
    selected = select_tests_fn(changed, cfg, tmp_path)

    for p in selected:
        assert (tmp_path / p).exists(), f"Selected non-existent: {p}"


# ---------------------------------------------------------------------------
# F. Extra mappings + capture substitution
# ---------------------------------------------------------------------------


def test_extract_capture_sub_packages() -> None:
    """_extract_capture extracts the sub-package name from sub-packages/*/src/**/*.py."""
    cap = _extract_capture(
        "sub-packages/foobar/src/x/y.py",
        "sub-packages/*/src/**/*.py",
        1,
    )
    assert cap == "foobar", f"Expected 'foobar', got {cap!r}"


def test_extra_mappings_sub_package_capture(tmp_path: Path) -> None:
    """sub-packages/foobar/src/x/y.py → sub-packages/foobar/tests/**/*.py via {1} capture."""
    test_file = tmp_path / "sub-packages" / "foobar" / "tests" / "test_y.py"
    test_file.parent.mkdir(parents=True)
    test_file.write_text("")

    cfg = {
        "extra_mappings": [
            {
                "source_glob": "sub-packages/*/src/**/*.py",
                "test_globs": ["sub-packages/{1}/tests/**/*.py"],
            }
        ]
    }
    result = _apply_extra_mappings(
        Path("sub-packages/foobar/src/x/y.py"),
        cfg,
        tmp_path,
    )
    assert Path("sub-packages/foobar/tests/test_y.py") in result, (
        f"Expected sub-package test in result, got {result}"
    )


def test_extra_mappings_basename_substitution(tmp_path: Path) -> None:
    """test_{basename}.py substitution uses the source file stem."""
    test_file = tmp_path / "test" / "test_mymodule.py"
    test_file.parent.mkdir(parents=True)
    test_file.write_text("")

    cfg = {
        "extra_mappings": [
            {
                "source_glob": "hummingbot/*.py",
                "test_globs": ["test/test_{basename}.py"],
            }
        ]
    }
    result = _apply_extra_mappings(
        Path("hummingbot/mymodule.py"),
        cfg,
        tmp_path,
    )
    assert Path("test/test_mymodule.py") in result, f"Expected basename sub result, got {result}"


def test_extra_mappings_no_match_returns_empty(tmp_path: Path) -> None:
    """Source that matches no extra_mappings rule returns empty set."""
    cfg = {
        "extra_mappings": [
            {
                "source_glob": "sub-packages/*/src/**/*.py",
                "test_globs": ["sub-packages/{1}/tests/**/*.py"],
            }
        ]
    }
    result = _apply_extra_mappings(
        Path("hummingbot/foo.py"),
        cfg,
        tmp_path,
    )
    assert result == set()


# ---------------------------------------------------------------------------
# G. Always-on
# ---------------------------------------------------------------------------


def test_always_on_included_for_empty_diff(tmp_path: Path) -> None:
    """always_on tests are always included, even when changed_files is empty."""
    always_test = tmp_path / "test" / "hummingbot" / "test_base.py"
    always_test.parent.mkdir(parents=True)
    always_test.write_text("")

    cfg = {
        "always_on": ["test/hummingbot/test_base.py"],
        "cross_cutting": [],
        "mirror_rule": {"enabled": False},
        "extra_mappings": [],
    }
    selected = select_tests_fn([], cfg, tmp_path)
    assert Path("test/hummingbot/test_base.py") in selected, (
        f"always_on should be in selected even with empty diff: {selected}"
    )


def test_always_on_nonexistent_filtered_out(tmp_path: Path) -> None:
    """always_on entries that do NOT exist on disk are dropped from final set."""
    cfg = {
        "always_on": ["test/hummingbot/does_not_exist.py"],
        "cross_cutting": [],
        "mirror_rule": {"enabled": False},
        "extra_mappings": [],
    }
    selected = select_tests_fn([], cfg, tmp_path)
    assert Path("test/hummingbot/does_not_exist.py") not in selected, (
        f"Non-existent always_on entry should be dropped: {selected}"
    )


def test_always_on_included_with_nonempty_diff(tmp_path: Path) -> None:
    """always_on appears alongside mirror-matched tests when diff is non-empty."""
    always_test = tmp_path / "test" / "hummingbot" / "strategy_v2" / "executors" / "test_executor_base.py"
    always_test.parent.mkdir(parents=True)
    always_test.write_text("")

    mirror_test = tmp_path / "test" / "hummingbot" / "strategy_v2" / "executors" / "test_foo.py"
    mirror_test.write_text("")

    cfg = {
        "always_on": ["test/hummingbot/strategy_v2/executors/test_executor_base.py"],
        "cross_cutting": [],
        "mirror_rule": {
            "enabled": True,
            "source_root": "hummingbot",
            "test_root": "test/hummingbot",
            "test_filename_prefix": "test_",
        },
        "extra_mappings": [],
    }
    changed = [Path("hummingbot/strategy_v2/executors/foo.py")]
    selected = select_tests_fn(changed, cfg, tmp_path)

    assert Path("test/hummingbot/strategy_v2/executors/test_executor_base.py") in selected
    assert Path("test/hummingbot/strategy_v2/executors/test_foo.py") in selected


# ---------------------------------------------------------------------------
# H. Escape threshold
# ---------------------------------------------------------------------------


def _build_test_tree(repo: Path, count: int) -> list[str]:
    """Create `count` placeholder test files; return their relative paths."""
    paths = []
    for i in range(count):
        p = f"test/hummingbot/subdir/test_module_{i}.py"
        full = repo / p
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_text("")
        paths.append(p)
    return paths


def test_emit_selection_escape_threshold_exit2() -> None:
    """When selected% > threshold, emit_selection returns exit code 2."""
    selected = {Path(f"test/test_{i}.py") for i in range(60)}
    total = 100
    code = emit_selection(selected, total, threshold_pct=50, shadow=False)
    assert code == 2, f"Expected exit code 2, got {code}"


def test_emit_selection_below_threshold_exit0() -> None:
    """When selected% <= threshold, emit_selection returns exit code 0."""
    selected = {Path(f"test/test_{i}.py") for i in range(10)}
    total = 100
    code = emit_selection(selected, total, threshold_pct=50, shadow=False)
    assert code == 0, f"Expected exit code 0, got {code}"


def test_emit_selection_shadow_suppresses_exit2(capsys: pytest.CaptureFixture[str]) -> None:
    """--shadow mode: never exits 2 even when threshold exceeded; emits marker line."""
    selected = {Path(f"test/test_{i}.py") for i in range(60)}
    total = 100
    code = emit_selection(selected, total, threshold_pct=50, shadow=True)
    assert code == 0, f"Shadow mode should return 0, got {code}"
    out = capsys.readouterr().out
    assert "# SHADOW:" in out, f"Shadow marker line missing from stdout: {out!r}"


def test_escape_threshold_full_pipeline(tmp_path: Path) -> None:
    """End-to-end: many tests selected vs small total triggers select_tests + emit_selection exit 2."""
    # Create 5 test files, then build a diff that triggers a cross-cutting rule selecting all of them
    test_paths = _build_test_tree(tmp_path, 5)

    cfg = {
        "always_on": [],
        "cross_cutting": [
            {
                "source_glob": "hummingbot/core/pubsub.*",
                "tests_globs": ["test/hummingbot/**/*.py"],
            }
        ],
        "mirror_rule": {"enabled": False},
        "extra_mappings": [],
        "escape_threshold_pct": 50,
    }
    changed = [Path("hummingbot/core/pubsub.py")]
    selected = select_tests_fn(changed, cfg, tmp_path)

    # All 5 exist → 5/5 = 100% > 50% threshold
    total = len(test_paths)
    code = emit_selection(selected, total, threshold_pct=50, shadow=False)
    assert code == 2, f"Expected exit 2 when 100% selected, got {code}"


# ---------------------------------------------------------------------------
# I. State file
# ---------------------------------------------------------------------------


def test_load_state_empty_returns_defaults(tmp_path: Path) -> None:
    """Missing state file returns a dict with expected default keys."""
    state_file = tmp_path / "state.json"
    state = load_state(state_file)
    assert state["version"] == 1
    assert "tested_commits" in state
    assert "total_test_count_cache" in state
    assert state["last_synced_upstream_sha"] is None


def test_save_and_load_state_roundtrip(tmp_path: Path) -> None:
    """save_state → load_state produces identical content."""
    state_file = tmp_path / "state.json"
    original = {
        "version": 1,
        "tested_commits": {"abc123": True},
        "total_test_count_cache": {"value": 42, "computed_at": "2026-01-01T00:00:00+00:00", "ttl_hours": 24},
        "last_synced_upstream_sha": "deadbeef",
    }
    save_state(state_file, original)
    loaded = load_state(state_file)
    assert loaded == original, f"Round-trip mismatch: {loaded}"


def test_save_state_atomic_uses_tmp(tmp_path: Path) -> None:
    """save_state uses a .tmp file that is replaced atomically — no .tmp remains after save."""
    state_file = tmp_path / "state.json"
    save_state(state_file, {"version": 1})
    tmp_file = state_file.with_suffix(".tmp")
    assert not tmp_file.exists(), ".tmp file should not remain after successful save"
    assert state_file.exists(), "state file should exist after save"


def test_load_state_corrupt_json_returns_defaults(tmp_path: Path) -> None:
    """Corrupt JSON in state file returns defaults without crashing."""
    state_file = tmp_path / "state.json"
    state_file.write_text("{broken json}")
    state = load_state(state_file)
    assert state["version"] == 1, "Should fall back to defaults on corrupt JSON"


# ---------------------------------------------------------------------------
# J. CLI integration tests
# ---------------------------------------------------------------------------


def _make_minimal_config_file(tmp_path: Path, always_on: list[str] | None = None) -> Path:
    cfg = {
        "version": 1,
        "always_on": always_on or [],
        "ignore": ["**/*.md", "docs/**"],
        "mirror_rule": {
            "enabled": True,
            "source_root": "hummingbot",
            "test_root": "test/hummingbot",
            "test_filename_prefix": "test_",
        },
        "extra_mappings": [],
        "cross_cutting": [],
        "escape_threshold_pct": 50,
    }
    import yaml  # noqa: PLC0415

    cfg_file = tmp_path / "test-selection-map.yaml"
    cfg_file.write_text(yaml.dump(cfg))
    return cfg_file


@pytest.mark.cli
def test_cli_empty_diff_emits_always_on(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    """--mode branch --diff-file <empty diff> → exit 0, stdout includes always_on path."""
    always_test = tmp_path / "test" / "hummingbot" / "test_always.py"
    always_test.parent.mkdir(parents=True)
    always_test.write_text("")

    cfg_file = _make_minimal_config_file(tmp_path, always_on=["test/hummingbot/test_always.py"])
    diff_file = tmp_path / "empty.diff"
    diff_file.write_text("")
    state_file = tmp_path / "state.json"

    monkeypatch.setattr(
        "sys.argv",
        [
            "select_tests.py",
            "--mode", "branch",
            "--config", str(cfg_file),
            "--repo", str(tmp_path),
            "--diff-file", str(diff_file),
            "--state-file", str(state_file),
            "--no-history",
            "--escape-threshold-pct", "100",
        ],
    )
    code = select_tests.main()
    assert code == 0, f"Expected exit 0, got {code}"
    out = capsys.readouterr().out
    assert "test/hummingbot/test_always.py" in out, f"always_on missing from stdout: {out!r}"


@pytest.mark.cli
def test_cli_diff_with_source_selects_mirror(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    """--diff-file with hummingbot/foo.py → mirror test selected in stdout."""
    mirror_test = tmp_path / "test" / "hummingbot" / "test_foo.py"
    mirror_test.parent.mkdir(parents=True)
    mirror_test.write_text("")

    cfg_file = _make_minimal_config_file(tmp_path)
    diff_file = tmp_path / "changes.diff"
    diff_file.write_text("--- a/hummingbot/foo.py\n+++ b/hummingbot/foo.py\n")
    state_file = tmp_path / "state.json"

    monkeypatch.setattr(
        "sys.argv",
        [
            "select_tests.py",
            "--mode", "branch",
            "--config", str(cfg_file),
            "--repo", str(tmp_path),
            "--diff-file", str(diff_file),
            "--state-file", str(state_file),
            "--no-history",
            "--escape-threshold-pct", "100",
        ],
    )
    code = select_tests.main()
    assert code == 0, f"Expected exit 0, got {code}"
    out = capsys.readouterr().out
    assert "test/hummingbot/test_foo.py" in out, f"Mirror test missing from stdout: {out!r}"


@pytest.mark.cli
def test_cli_missing_mode_exits(monkeypatch: pytest.MonkeyPatch) -> None:
    """Omitting --mode triggers argparse SystemExit."""
    monkeypatch.setattr("sys.argv", ["select_tests.py"])
    with pytest.raises(SystemExit):
        select_tests.main()


@pytest.mark.cli
def test_cli_shadow_emits_marker(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    """--shadow flag emits the SHADOW marker line to stdout."""
    cfg_file = _make_minimal_config_file(tmp_path)
    diff_file = tmp_path / "empty.diff"
    diff_file.write_text("")
    state_file = tmp_path / "state.json"

    monkeypatch.setattr(
        "sys.argv",
        [
            "select_tests.py",
            "--mode", "branch",
            "--config", str(cfg_file),
            "--repo", str(tmp_path),
            "--diff-file", str(diff_file),
            "--state-file", str(state_file),
            "--no-history",
            "--shadow",
        ],
    )
    code = select_tests.main()
    assert code == 0, f"Expected exit 0 in shadow mode, got {code}"
    out = capsys.readouterr().out
    assert "# SHADOW:" in out, f"Shadow marker line missing: {out!r}"


@pytest.mark.cli
def test_cli_branch_mode_requires_refs_or_diff_file(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """branch mode without --diff-file and without --base-ref/--head-ref → exit 1."""
    cfg_file = _make_minimal_config_file(tmp_path)
    state_file = tmp_path / "state.json"

    monkeypatch.setattr(
        "sys.argv",
        [
            "select_tests.py",
            "--mode", "branch",
            "--config", str(cfg_file),
            "--repo", str(tmp_path),
            "--state-file", str(state_file),
            "--no-history",
        ],
    )
    # get_changed_files will call sys.exit(1) when branch mode has no refs/diff
    with pytest.raises(SystemExit) as exc_info:
        select_tests.main()
    assert exc_info.value.code == 1


# ---------------------------------------------------------------------------
# Additional: files_from_diff_file parsing
# ---------------------------------------------------------------------------


def test_files_from_diff_file_deduplicates(tmp_path: Path) -> None:
    """_files_from_diff_file deduplicates paths appearing in both --- and +++ lines."""
    diff_file = tmp_path / "dup.diff"
    diff_file.write_text(
        "--- a/hummingbot/foo.py\n"
        "+++ b/hummingbot/foo.py\n"
        "--- a/hummingbot/bar.py\n"
        "+++ b/hummingbot/bar.py\n"
    )
    result = _files_from_diff_file(diff_file)
    # Each file should appear only once despite appearing in both --- and +++ lines
    paths = [str(p) for p in result]
    assert paths.count("hummingbot/foo.py") == 1, f"foo.py should appear once: {paths}"
    assert paths.count("hummingbot/bar.py") == 1, f"bar.py should appear once: {paths}"


def test_files_from_diff_file_excludes_dev_null(tmp_path: Path) -> None:
    """/dev/null in diff lines is excluded from the result."""
    diff_file = tmp_path / "new.diff"
    diff_file.write_text(
        "--- /dev/null\n"
        "+++ b/hummingbot/new_file.py\n"
    )
    result = _files_from_diff_file(diff_file)
    paths = [str(p) for p in result]
    assert "hummingbot/new_file.py" in paths
    # /dev/null should not appear (raw == "/dev/null" check strips it)
    assert all("/dev/null" not in p for p in paths), f"dev/null should be excluded: {paths}"


# ---------------------------------------------------------------------------
# compute_total_tests
# ---------------------------------------------------------------------------


def test_compute_total_tests_counts_test_files(tmp_path: Path) -> None:
    """compute_total_tests counts test_*.py files recursively."""
    _build_test_tree(tmp_path, 3)
    state: dict[str, Any] = {}
    count = compute_total_tests(tmp_path, state, force_recompute=True)
    assert count == 3, f"Expected 3 test files, got {count}"


def test_compute_total_tests_uses_cache(tmp_path: Path) -> None:
    """compute_total_tests returns cached value when fresh enough."""
    from datetime import datetime, timezone

    state: dict[str, Any] = {
        "total_test_count_cache": {
            "value": 99,
            "computed_at": datetime.now(tz=timezone.utc).isoformat(),
            "ttl_hours": 24,
        }
    }
    count = compute_total_tests(tmp_path, state, force_recompute=False)
    assert count == 99, f"Expected cached value 99, got {count}"


def test_compute_total_tests_force_recompute_ignores_cache(tmp_path: Path) -> None:
    """force_recompute=True bypasses cached value."""
    from datetime import datetime, timezone

    _build_test_tree(tmp_path, 2)
    state: dict[str, Any] = {
        "total_test_count_cache": {
            "value": 999,
            "computed_at": datetime.now(tz=timezone.utc).isoformat(),
            "ttl_hours": 24,
        }
    }
    count = compute_total_tests(tmp_path, state, force_recompute=True)
    assert count == 2, f"Expected recomputed value 2, got {count}"


# ---------------------------------------------------------------------------
# K. Regression tests for Bug 1 (last_synced_upstream_sha) and
#    Bug 2 (compute_total_tests scope)
# ---------------------------------------------------------------------------


def test_compute_total_tests_counts_only_test_dir_files(tmp_path: Path) -> None:
    """compute_total_tests counts test_*.py files under repo/test/ only.

    Verify:
    - test/**/test_*.py are counted
    - hummingbot/**/test_*.py are NOT counted (outside test/)
    - sub-packages/**/test_*.py are NOT counted
    - test/**/conftest.py is NOT counted (wrong prefix)
    - test/**/foo.py (no test_ prefix) is NOT counted
    """
    # Files that SHOULD be counted
    counted = [
        "test/hummingbot/test_alpha.py",
        "test/hummingbot/strategy_v2/test_beta.py",
        "test/hummingbot/connectors/test_gamma.py",
    ]
    # Files that should NOT be counted
    not_counted = [
        "hummingbot/core/test_should_not_count.py",
        "sub-packages/foobar/tests/test_should_not_count.py",
        "test/hummingbot/conftest.py",
        "test/hummingbot/helpers.py",
    ]
    for rel in counted + not_counted:
        p = tmp_path / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("")

    state: dict[str, Any] = {}
    count = compute_total_tests(tmp_path, state, force_recompute=True)
    assert count == len(counted), (
        f"Expected exactly {len(counted)} test files (only under test/), got {count}"
    )


def test_compute_total_tests_no_test_dir_returns_zero(tmp_path: Path) -> None:
    """When repo/test/ does not exist, count is 0 (not a crash)."""
    # Place a test_*.py outside test/ to confirm it is not counted
    stray = tmp_path / "hummingbot" / "test_stray.py"
    stray.parent.mkdir(parents=True, exist_ok=True)
    stray.write_text("")

    state: dict[str, Any] = {}
    count = compute_total_tests(tmp_path, state, force_recompute=True)
    assert count == 0, f"Expected 0 when test/ dir absent, got {count}"


@pytest.mark.cli
def test_upstream_mode_persists_last_synced_sha(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """After a successful upstream-mode run, state file MUST contain the resolved head SHA.

    Uses _git stub to avoid requiring a real git remote. The stub intercepts
    rev-parse (returns a known SHA), merge-base (supplies a base ref), and
    diff --name-only (returns empty — no source changes).
    """
    fake_sha = "aabbccdd" * 5  # 40-char hex

    # Minimal test tree so escape threshold is not triggered
    _build_test_tree(tmp_path, 2)
    cfg_file = _make_minimal_config_file(tmp_path)
    state_file = tmp_path / "state.json"

    # Stub _git: intercept all git calls so no real repo is needed.
    def fake_git(repo: Path, *args: str) -> str:
        if args[0] == "rev-parse":
            return fake_sha
        if args[0] == "merge-base":
            return "basesha000000000000000000000000000000000"
        if args[0] == "diff":
            return ""  # empty diff → no source changes
        raise RuntimeError(f"Unexpected git call: {args}")

    monkeypatch.setattr(select_tests, "_git", fake_git)

    # No --diff-file: must go through the git code path so rev-parse is called
    monkeypatch.setattr(
        "sys.argv",
        [
            "select_tests.py",
            "--mode", "upstream",
            "--config", str(cfg_file),
            "--repo", str(tmp_path),
            "--state-file", str(state_file),
            "--escape-threshold-pct", "100",
        ],
    )
    code = select_tests.main()
    assert code == 0, f"Expected exit 0, got {code}"

    saved = json.loads(state_file.read_text())
    assert saved.get("last_synced_upstream_sha") == fake_sha, (
        f"Expected SHA {fake_sha!r} in state, got {saved.get('last_synced_upstream_sha')!r}"
    )


# ---------------------------------------------------------------------------
# L. Branch-mode parity: --source-branch, commit dedup, --mark-success-for
# ---------------------------------------------------------------------------


def test_branch_mode_source_branch_uses_merge_base(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """When --source-branch is provided, diff base is merge-base(head_ref, source_branch)."""
    merge_base_sha = "mergebase" + "0" * 31

    calls: list[tuple[str, ...]] = []

    def fake_git(repo: Path, *args: str) -> str:
        calls.append(args)
        if args[0] == "merge-base":
            return merge_base_sha
        if args[0] == "diff":
            # Confirm the merge-base SHA was passed as the diff base
            assert args[2] == merge_base_sha, (
                f"Expected merge-base SHA as diff base, got {args[2]!r}"
            )
            return ""
        raise RuntimeError(f"Unexpected git call: {args}")

    monkeypatch.setattr(select_tests, "_git", fake_git)

    cfg = _minimal_config()
    result, _ = get_changed_files(
        repo=tmp_path,
        mode="branch",
        base_ref="origin/development",
        head_ref="HEAD",
        diff_file=None,
        state={},
        config=cfg,
        source_branch="origin/ci-base",
    )
    assert result == []
    merge_base_calls = [c for c in calls if c[0] == "merge-base"]
    assert len(merge_base_calls) == 1, f"Expected exactly one merge-base call, got {calls}"
    assert merge_base_calls[0] == ("merge-base", "HEAD", "origin/ci-base")


@pytest.mark.cli
def test_branch_mode_dedup_skips_selection_when_previously_passed(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """If state shows commit was previously tested OK, emit empty stdout + exit 0."""
    from datetime import datetime, timezone

    fake_sha = "cafebabe" * 5

    def fake_git(repo: Path, *args: str) -> str:
        if args[0] == "rev-parse":
            return fake_sha
        raise RuntimeError(f"Unexpected git call in dedup path: {args}")

    monkeypatch.setattr(select_tests, "_git", fake_git)

    cfg_file = _make_minimal_config_file(tmp_path)
    state_file = tmp_path / "state.json"
    state_file.write_text(json.dumps({
        "version": 1,
        "tested_commits": {
            fake_sha: {
                "status": "success",
                "date": datetime.now(tz=timezone.utc).isoformat(),
                "mode": "branch",
            },
        },
        "total_test_count_cache": {},
        "last_synced_upstream_sha": None,
    }))

    monkeypatch.setattr(
        "sys.argv",
        [
            "select_tests.py",
            "--mode", "branch",
            "--config", str(cfg_file),
            "--repo", str(tmp_path),
            "--base-ref", "origin/development",
            "--head-ref", "HEAD",
            "--state-file", str(state_file),
        ],
    )
    code = select_tests.main()
    assert code == 0, f"Expected exit 0 on dedup hit, got {code}"
    out = capsys.readouterr().out
    assert out.strip() == "", f"Expected empty stdout on dedup hit, got {out!r}"


@pytest.mark.cli
def test_branch_mode_dedup_does_not_skip_when_previously_failed(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """If state shows commit previously FAILED, do NOT skip — re-run selection."""
    from datetime import datetime, timezone

    fake_sha = "deadbeef" * 5
    cfg_file = _make_minimal_config_file(tmp_path)
    state_file = tmp_path / "state.json"
    state_file.write_text(json.dumps({
        "version": 1,
        "tested_commits": {
            fake_sha: {
                "status": "failure",
                "date": datetime.now(tz=timezone.utc).isoformat(),
                "mode": "branch",
            },
        },
        "total_test_count_cache": {},
        "last_synced_upstream_sha": None,
    }))

    _build_test_tree(tmp_path, 1)

    # Re-use a tracking fake_git that records diff calls
    called_diff: list[bool] = []

    def fake_git2(repo: Path, *args: str) -> str:
        if args[0] == "rev-parse":
            return fake_sha
        if args[0] == "diff":
            called_diff.append(True)
            return ""
        raise RuntimeError(f"Unexpected git call: {args}")

    monkeypatch.setattr(select_tests, "_git", fake_git2)

    monkeypatch.setattr(
        "sys.argv",
        [
            "select_tests.py",
            "--mode", "branch",
            "--config", str(cfg_file),
            "--repo", str(tmp_path),
            "--base-ref", "origin/development",
            "--head-ref", "HEAD",
            "--state-file", str(state_file),
            "--escape-threshold-pct", "100",
        ],
    )
    code = select_tests.main()
    assert code == 0, f"Expected exit 0, got {code}"
    assert called_diff, "git diff should have been called (dedup should NOT have skipped)"


@pytest.mark.cli
def test_branch_mode_no_history_disables_dedup(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """With --no-history, dedup is skipped — selection always runs even if commit was OK."""
    from datetime import datetime, timezone

    fake_sha = "aabbccdd" * 5
    called_diff: list[bool] = []

    def fake_git(repo: Path, *args: str) -> str:
        if args[0] == "rev-parse":
            return fake_sha
        if args[0] == "diff":
            called_diff.append(True)
            return ""
        raise RuntimeError(f"Unexpected git call: {args}")

    monkeypatch.setattr(select_tests, "_git", fake_git)

    cfg_file = _make_minimal_config_file(tmp_path)
    state_file = tmp_path / "state.json"
    # State has the commit marked as success — but --no-history should bypass dedup
    state_file.write_text(json.dumps({
        "version": 1,
        "tested_commits": {
            fake_sha: {
                "status": "success",
                "date": datetime.now(tz=timezone.utc).isoformat(),
                "mode": "branch",
            },
        },
        "total_test_count_cache": {},
        "last_synced_upstream_sha": None,
    }))

    _build_test_tree(tmp_path, 1)

    monkeypatch.setattr(
        "sys.argv",
        [
            "select_tests.py",
            "--mode", "branch",
            "--config", str(cfg_file),
            "--repo", str(tmp_path),
            "--base-ref", "origin/development",
            "--head-ref", "HEAD",
            "--state-file", str(state_file),
            "--no-history",
            "--escape-threshold-pct", "100",
        ],
    )
    code = select_tests.main()
    assert code == 0, f"Expected exit 0, got {code}"
    assert called_diff, "git diff should have been called when --no-history disables dedup"


def test_mark_success_for_writes_state(tmp_path: Path) -> None:
    """--mark-success-for SHA appends to tested_commits dict and exits 0."""
    state_file = tmp_path / "state.json"
    sha = "feedface" * 5

    code = _handle_mark_success_for(sha, state_file)
    assert code == 0, f"Expected exit 0 from _handle_mark_success_for, got {code}"

    saved = json.loads(state_file.read_text())
    entry = saved.get("tested_commits", {}).get(sha)
    assert entry is not None, f"Expected {sha!r} in tested_commits, got {saved}"
    assert entry["status"] == "success"
    assert entry["mode"] == "branch"
    assert "date" in entry


def test_mark_success_for_preserves_existing_state(tmp_path: Path) -> None:
    """--mark-success-for does not clobber other state keys."""
    state_file = tmp_path / "state.json"
    original_sha = "11223344" * 5
    new_sha = "aabbccdd" * 5

    # Pre-populate with an existing entry and other state keys
    state_file.write_text(json.dumps({
        "version": 1,
        "tested_commits": {
            original_sha: {"status": "success", "mode": "branch", "date": "2026-01-01T00:00:00+00:00"},
        },
        "total_test_count_cache": {"value": 42, "ttl_hours": 24},
        "last_synced_upstream_sha": "oldsha",
    }))

    code = _handle_mark_success_for(new_sha, state_file)
    assert code == 0

    saved = json.loads(state_file.read_text())
    # Existing commit entry preserved
    assert saved["tested_commits"].get(original_sha) is not None, "Existing commit entry should be preserved"
    # New commit entry added
    assert saved["tested_commits"].get(new_sha, {}).get("status") == "success"
    # Other state keys untouched
    assert saved["last_synced_upstream_sha"] == "oldsha"
    assert saved["total_test_count_cache"]["value"] == 42


@pytest.mark.cli
def test_upstream_mode_no_history_skips_sha_write(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """With --no-history, last_synced_upstream_sha stays untouched (state file not written)."""
    fake_sha = "deadbeef" * 5

    _build_test_tree(tmp_path, 1)
    cfg_file = _make_minimal_config_file(tmp_path)
    state_file = tmp_path / "state.json"
    # Pre-populate state file with a known SHA — should remain unchanged after run
    state_file.write_text(json.dumps({
        "version": 1,
        "tested_commits": {},
        "total_test_count_cache": {},
        "last_synced_upstream_sha": "original_sha",
    }))

    def fake_git(repo: Path, *args: str) -> str:
        if args[0] == "rev-parse":
            return fake_sha
        if args[0] == "merge-base":
            return "basesha000000000000000000000000000000000"
        if args[0] == "diff":
            return ""
        raise RuntimeError(f"Unexpected git call: {args}")

    monkeypatch.setattr(select_tests, "_git", fake_git)

    # No --diff-file; with --no-history state file must not be rewritten
    monkeypatch.setattr(
        "sys.argv",
        [
            "select_tests.py",
            "--mode", "upstream",
            "--config", str(cfg_file),
            "--repo", str(tmp_path),
            "--state-file", str(state_file),
            "--no-history",
            "--escape-threshold-pct", "100",
        ],
    )
    code = select_tests.main()
    assert code == 0, f"Expected exit 0, got {code}"

    # State file should be unchanged — original_sha preserved
    saved = json.loads(state_file.read_text())
    assert saved.get("last_synced_upstream_sha") == "original_sha", (
        f"--no-history must not update last_synced_upstream_sha, got {saved.get('last_synced_upstream_sha')!r}"
    )
