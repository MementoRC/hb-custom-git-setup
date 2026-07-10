# Phase 4 + Phase 5B Retirement Attic

Diff-driven test selection rollout (plan: `hummingbot_ai_docs/2026-06-06-diff-driven-test-selection.md`) replaced these files. Kept here as revert path during initial production cycles.

Phase 5B (2026-06-08) promoted the selector script and config into the repo at `.github/test-selection/`. The local cron scripts (`hummingbot-cron-wrapper.sh` Step 1.5 and `hummingbot-branch-tracking.sh:run_tests()`) now reference the in-repo copies via `${REPO_PATH}/.github/test-selection/`. The files below are retained as a revert path only; the in-repo copies at `.github/test-selection/` are now authoritative.

## Inventory

| File | Replaced by | Date retired |
|---|---|---|
| `hummingbot-select-test-verifier.sh` | `scripts/select_tests.py` + `hummingbot-branch-tracking.sh:run_tests()` rewrite | 2026-06-07 |
| `test_history.json` | `state/select_tests_state.json` (`tested_commits` dict, branch-mode entries) | 2026-06-07 |
| `scripts/select_tests.py` | `.github/test-selection/select_tests.py` (in repo) | 2026-06-08 (Phase 5B) |
| `configs/test-selection-map.yaml` | `.github/test-selection/test-selection-map.yaml` (in repo) | 2026-06-08 (Phase 5B) |
| `scripts/tests/` (renamed to `attic/tests-select/`) | `.github/test-selection/tests/` (in repo) | 2026-06-08 (Phase 5B) |

## Architecture context

Phase 4 unified branch-mode and upstream-mode test selection under a single Python selector (`select_tests.py`). The legacy bash verifier's responsibilities split into:

- **Selection** (which tests to run) → `select_tests.py` (Python, YAML-driven)
- **Execution** (run pytest, handle exit) → `hummingbot-branch-tracking.sh:run_tests()` (bash thin orchestrator)

Commit-dedup moved from `test_history.json` to `state/select_tests_state.json` under the `tested_commits` dict with `mode: "branch"` / `mode: "upstream"` markers.

## Revert path

If first production exercise of `run_tests()` surfaces an issue:

1. `mv attic/hummingbot-select-test-verifier.sh scripts/`
2. Revert `hummingbot-branch-tracking.sh:run_tests()` to call the verifier (git history under the file's working directory — not in git; recreate the call from this README's "How it was invoked" appendix below)
3. `mv attic/test_history.json $CONFIG_PATH/` (if branch-tracking.sh's reverted version relies on it)

## Appendix — Legacy `.sh` invocation pattern

For revert reference, the original call site (`hummingbot-branch-tracking.sh:run_tests()`) invoked the verifier as:

```bash
local test_script="${SCRIPT_DIR}/hummingbot-select-test-verifier.sh"
"$test_script" "origin/$DEVELOPMENT_BRANCH" "$target_branch" "$source_branch" > "${TEMP_LOG}" 2>&1
```

With output captured to `${TEMP_LOG}`, `cat`'d to console, and grep'd for "FAILED" to detect test failures. Exit code 1 = test failure → caller reverted the merge.

## Removal criteria

Delete this attic once:
- 4+ weeks of production cycles pass without invoking the revert path
- AND no Phase 4 follow-up issues surface in cron logs
- AND `select_tests.py` v2 (pytest `--collect-only` introspection) ships or is formally deferred
