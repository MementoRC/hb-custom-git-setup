#!/bin/bash
###############################################################################
# branch_tracker.sh
# -----------------
# This script reads a YAML configuration (branch-tracking.yaml) and attempts
# to keep certain target branches up to date by merging changes from "tracked"
# branches. It logs operations and writes status entries to a separate status
# file. If a merge actually introduces new commits, it optionally runs tests.
#
# Usage:
#   ./branch_tracker.sh
###############################################################################

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"

TEMP_DIR="${SCRIPT_DIR}/.tmp"
TEMP_LOG="${TEMP_DIR}/test_output.log"

###############################################################################
# Overridable Variables
###############################################################################
: "${DEVELOPMENT_BRANCH:="development"}"
: "${FEATURE_BRANCH:="bleeding-edge"}"
: "${LOCAL_REPO_DIR:="$HOME/PycharmProjects/Hummingbot/hummingbot"}"

###############################################################################
# Git State Management
###############################################################################

###############################################################################
# Denylist constants for ci-base artifact guard
# Paths / patterns that must NEVER appear in a ci-base auto-commit.
# Any match causes hard abort rather than silent inclusion.
###############################################################################
readonly CI_BASE_DENYLIST_PATHS=(
    ".gitmodules"
    "sub-packages/"
    "ci/check_subpackage_compat.py"
    "tach.toml"
)
readonly CI_BASE_DENYLIST_PYPROJECT_PATTERNS=(
    "install-subpackages"
    "\[tool\.hummingbot\.supersedes\]"
    "compat-"
    "submodule-update"
    # known-first-party sub-package namespaces (add as sub-packages grow)
    "hb_async_utils"
    "hb_candles_feed"
    "hb_connector_utils"
    "hb_data_type_primitives"
    "hb_event_bus"
    "hb_liquidations_feed"
    "hb_logger"
    "hb_market_connector"
    "hb_market_data"
    "hb_market_simulator"
    "hb_rate_oracle"
    "hb_remote_iface"
    "hb_strategy_framework"
    "hb_web_assistant"
)

# check_ci_base_denylist <file_list_newline_separated>
# Returns 1 and prints offending paths if any denylist hit found.
check_ci_base_denylist() {
    local files="$1"
    local violations=()

    while IFS= read -r f; do
        [ -z "$f" ] && continue
        # Path-based denylist
        for denied in "${CI_BASE_DENYLIST_PATHS[@]}"; do
            if [[ "$f" == "$denied" ]] || [[ "$f" == "${denied}"* ]]; then
                violations+=("PATH: $f (matches denylist entry '$denied')")
            fi
        done
        # pyproject.toml content check
        if [[ "$f" == "pyproject.toml" ]] && [ -f "pyproject.toml" ]; then
            for pattern in "${CI_BASE_DENYLIST_PYPROJECT_PATTERNS[@]}"; do
                if grep -qE "$pattern" pyproject.toml 2>/dev/null; then
                    violations+=("CONTENT: pyproject.toml contains banned pattern '$pattern'")
                fi
            done
        fi
    done <<< "$files"

    if [ ${#violations[@]} -gt 0 ]; then
        log_error "FATAL: ci-base artifact denylist VIOLATED — aborting auto-commit"
        for v in "${violations[@]}"; do
            log_error "  $v"
        done
        log_error "Resolve: the offending content must be removed from ci-base or moved to modular."
        return 1
    fi
    return 0
}

handle_new_files() {
    local untracked
    # Exclude sub-packages/ (submodules managed by own branch), tool configs (.serena/, .mcp.json), and worktrees
    untracked=$(git ls-files --others --exclude-standard | grep -Ev '^(sub-packages/|\.serena/|\.mcp\.json|\.worktrees/)')
    if [ -n "$untracked" ]; then
        # GUARDRAIL: refuse to auto-commit any file matching the ci-base denylist.
        # This replaces the previous blind add that injected executor cruft (36e83809c).
        if [ "$REBUILD_MODE" = "true" ] || [ "$(git rev-parse --abbrev-ref HEAD)" = "ci-base" ]; then
            check_ci_base_denylist "$untracked" || return 1
        fi
        log_operation "Adding new files..."
        git ls-files --others --exclude-standard -z | grep -zEv '^(sub-packages/|\.serena/|\.mcp\.json|\.worktrees/)' | xargs -0 -r git add
        # Skip hooks — these are auto-added files from merges, not user code
        git commit --no-verify -m "Auto-add new files" >& /dev/null || return 1
    fi
    return 0
}

###############################################################################
# Post-Build ci-base Purity Assertion (--rebuild only)
# -------------------------------------------------------
# Verifies ZERO sub-package artifacts survived the seed-based ci-base build.
# Abort loudly rather than propagate a contaminated branch to origin.
# Requires CI_BASE_DENYLIST_PYPROJECT_PATTERNS from Change 2.
###############################################################################
assert_ci_base_purity() {
    local violations=()

    # 1. No .gitmodules
    if [ -f ".gitmodules" ]; then
        violations+=("FILE: .gitmodules present (sub-package artifact)")
    fi

    # 2. No sub-packages/ gitlinks in index
    local subpkg_entries
    subpkg_entries=$(git ls-files --stage | awk '$1 == "160000"' | grep 'sub-packages/' || true)
    if [ -n "$subpkg_entries" ]; then
        violations+=("GITLINKS: sub-packages/ submodule entries in index:")
        while IFS= read -r entry; do
            violations+=("  $entry")
        done <<< "$subpkg_entries"
    fi

    # 3. No banned patterns in pyproject.toml
    if [ -f "pyproject.toml" ]; then
        for pattern in "${CI_BASE_DENYLIST_PYPROJECT_PATTERNS[@]}"; do
            if grep -qE "$pattern" pyproject.toml 2>/dev/null; then
                violations+=("CONTENT: pyproject.toml contains banned pattern '$pattern'")
            fi
        done
    fi

    if [ ${#violations[@]} -gt 0 ]; then
        log_error "FATAL: ci-base post-build purity assertion FAILED — sub-package artifacts detected:"
        for v in "${violations[@]}"; do
            log_error "  $v"
        done
        log_error "DO NOT push ci-base. Diagnose the seed merge or _for_ci conflict resolution."
        return 1
    fi

    log_result true "ci-base purity assertion: CLEAN (no sub-package artifacts)"
    return 0
}

###############################################################################
# Base Branch Sync
###############################################################################
get_base_branch() {
    local target="$1"
    local result
    result="$(yq -r ".target_branches[\"$target\"].base_branch" "$BRANCH_CONFIG" 2>/dev/null)"
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        echo ""
    else
        echo "$result"
    fi
}

assert_clean_working_tree() {
    local repo_path="$1"
    local unexpected
    # Untracked files outside sub-packages/ — those should NEVER exist at rebuild entry
    unexpected=$(git -C "$repo_path" ls-files --others --exclude-standard | grep -v '^sub-packages/' || true)
    if [[ -n "$unexpected" ]]; then
        echo "ERROR: rebuild aborted — unexpected untracked files in working tree:" >&2
        echo "$unexpected" >&2
        echo "" >&2
        echo "Resolve manually before retrying: stash, remove, or commit them." >&2
        return 1
    fi
    return 0
}

###############################################################################
# Python 3.12 Transform Stage
# ---------------------------
# Post-merge, file-scoped AST transforms applied only to Python files that
# were introduced or modified by the development sync + _for_ci/* merges.
# Composed of:
#   1. refactor-py312  — project-specific rules (asyncio, distutils, removed stdlib)
#   2. ruff check --fix --unsafe-fixes  — auto-fix unused imports (best-effort)
#   3. ruff format     — normalise whitespace after AST rewrites
#
# Toggleable via PY312_TRANSFORMS=0 to bypass during incident triage.
# Called with the list of changed .py files as positional arguments.
###############################################################################
run_py312_transforms_for_changed() {
    # $@ — list of .py files relative to REPO_PATH
    if [ "${PY312_TRANSFORMS:-1}" = "0" ]; then
        log_operation "py312 transforms disabled via PY312_TRANSFORMS=0"
        return 0
    fi

    if [ $# -eq 0 ]; then
        log_operation "py312 post-merge transform: no changed Python files"
        return 0
    fi

    local refactor_cmd=""
    local ruff_cmd=""

    # Locate refactor-py312 — prefer pixi env, fall back to PATH.
    if [ -x "$REPO_PATH/.pixi/envs/default/bin/refactor-py312" ]; then
        refactor_cmd="$REPO_PATH/.pixi/envs/default/bin/refactor-py312"
    elif command -v refactor-py312 &> /dev/null; then
        refactor_cmd="refactor-py312"
    fi

    # Locate ruff — prefer PATH (usually available), fall back to pixi env.
    if command -v ruff &> /dev/null; then
        ruff_cmd="ruff"
    elif [ -x "$REPO_PATH/.pixi/envs/default/bin/ruff" ]; then
        ruff_cmd="$REPO_PATH/.pixi/envs/default/bin/ruff"
    fi

    if [ -z "$refactor_cmd" ] && [ -z "$ruff_cmd" ]; then
        log_warning "py312 transforms: neither refactor-py312 nor ruff found — skipping"
        return 0
    fi

    log_section "Running py312 post-merge transform pass (${#} files)"

    # Pass 1: refactor-py312 custom rules on changed files only.
    # --workers 1 is REQUIRED: refactor's default ProcessPoolExecutor cannot
    # pickle Rule classes that import `ast` (TypeError: cannot pickle module).
    if [ -n "$refactor_cmd" ]; then
        "$refactor_cmd" --workers 1 "$@" >& /dev/null
        local rc=$?
        # refactor-py312 exit codes: 0=no-changes, 1=changes-applied, >=2=error
        if [ $rc -gt 1 ]; then
            log_error "refactor-py312 failed (exit $rc)"
            return 1
        fi
    fi

    # Pass 1.5: StrEnum import fixup — refactor-py312 converts `class Foo(str, Enum)`
    # to `class Foo(StrEnum)` but does NOT add `from enum import StrEnum`; ruff's
    # subsequent --unsafe-fixes then strips the now-unused `from enum import Enum`,
    # leaving StrEnum undefined (F821).  This pass injects the missing import before
    # ruff can remove anything.
    python3 - "$@" << 'PYEOF'
import re
import sys

for path in sys.argv[1:]:
    try:
        text = open(path).read()
    except OSError:
        continue
    # Check if StrEnum is used as a base class but not yet imported.
    if not re.search(r'\bStrEnum\b', text):
        continue
    if re.search(r'from\s+enum\s+import\s+[^\n]*\bStrEnum\b', text):
        continue
    # File needs a StrEnum import.  Try to reuse an existing `from enum import`
    # line; otherwise insert a fresh import after the last stdlib/future import.
    if re.search(r'from\s+enum\s+import\s+', text):
        # Add StrEnum to the existing enum import line.
        text = re.sub(
            r'(from\s+enum\s+import\s+)([^\n]+)',
            lambda m: m.group(1) + 'StrEnum, ' + m.group(2)
            if not m.group(2).startswith('StrEnum')
            else m.group(0),
            text,
            count=1,
        )
    else:
        # Insert `from enum import StrEnum` after the last `import <stdlib>` line
        # at the top-level (before the first non-import, non-blank line).
        lines = text.splitlines(keepends=True)
        insert_at = 0
        for i, line in enumerate(lines):
            if re.match(r'^(?:import |from \S+ import )', line):
                insert_at = i + 1
        lines.insert(insert_at, 'from enum import StrEnum\n')
        text = ''.join(lines)
    open(path, 'w').write(text)
PYEOF

    # Pass 2: auto-fix unused imports (best-effort; non-fatal).
    if [ -n "$ruff_cmd" ]; then
        "$ruff_cmd" check --fix --unsafe-fixes "$@" >& /dev/null || true
    fi

    # Pass 3: format changed files.
    if [ -n "$ruff_cmd" ]; then
        "$ruff_cmd" format "$@" >& /dev/null || true
    fi

    # Stage and commit if anything changed.
    git add -- "$@"
    if ! git diff --cached --quiet; then
        git commit --no-verify -m "chore(ci-base): py312 post-merge transform pass" >& /dev/null \
            || { log_error "Failed to commit py312 transform changes"; return 1; }
        log_operation "Committed py312 post-merge transform changes"
    else
        log_operation "py312 post-merge transform: no changes produced"
    fi

    log_result true "py312 post-merge transform pass complete"
    return 0
}

###############################################################################
# Build ci-base from SEED (--rebuild only)
# -----------------------------------------
# Starts ci-base from the ci-base-seed-v1 tag (a fixed, GPG-signed snapshot
# that embeds the pixi-ci-migration + conda-removal + pytest-asyncio foundation),
# then merges origin/development on top.
#
# NEVER called in incremental cron mode (REBUILD_MODE != "true").
# In cron mode, sync_base_branch resets to origin/ci-base and patches new
# development commits — correct behaviour once a clean ci-base is in place.
###############################################################################
build_ci_base_from_seed() {
    local base_branch="$1"

    # Prerequisite: seed tag must exist (fetch tags from origin first)
    git fetch origin --tags >/dev/null 2>&1 || true
    local seed_tag="ci-base-seed-v1"
    local seed_sha
    seed_sha=$(git rev-parse --verify "refs/tags/$seed_tag" 2>/dev/null) || {
        log_error "FATAL: tag $seed_tag not found — create it first (see ci-base-clean-rebuild-plan.md Prerequisites)"
        return 1
    }
    log_operation "SEED anchor: $seed_tag @ $seed_sha"

    # Hard-reset ci-base to seed, discarding any prior state
    git fetch origin "$DEVELOPMENT_BRANCH" >/dev/null 2>&1
    git checkout "$base_branch" >& /dev/null || {
        # Branch may not exist yet (first run); create it
        git checkout -b "$base_branch" "$seed_sha" >& /dev/null || {
            log_error "Cannot create $base_branch from $seed_tag"
            return 1
        }
    }
    git reset --hard "$seed_sha" >/dev/null || {
        log_error "Failed to reset $base_branch to $seed_tag"
        return 1
    }
    log_operation "Reset $base_branch to $seed_tag"

    # Capture pre-merge SHA for scoped format/transform pass
    local pre_sync_sha
    pre_sync_sha=$(git rev-parse HEAD)

    # Merge development on top of SEED
    if git merge --no-verify "origin/$DEVELOPMENT_BRANCH" \
           -m "Sync $base_branch with $DEVELOPMENT_BRANCH (seed-based rebuild)" >& /dev/null; then
        log_operation "Merged origin/$DEVELOPMENT_BRANCH cleanly onto $seed_tag"
    else
        # Conflict classification: same logic as sync_base_branch
        local logical_conflicts=() format_only=()
        while IFS= read -r file; do
            case "$file" in
                pyproject.toml|.pre-commit-config.yaml|conftest.py|.github/*|test/conftest.py)
                    logical_conflicts+=("$file") ;;
                *) format_only+=("$file") ;;
            esac
        done < <(git diff --name-only --diff-filter=U)

        if [ ${#logical_conflicts[@]} -gt 0 ]; then
            log_error "Logical conflicts merging development onto SEED — manual resolution needed:"
            for f in "${logical_conflicts[@]}"; do log_detail "  $f"; done
            git merge --abort >& /dev/null
            return 1
        fi
        for f in "${format_only[@]}"; do
            git checkout --theirs "$f" 2>/dev/null
            git add "$f"
        done
        git commit --no-verify --no-edit >& /dev/null || {
            log_error "Failed to commit format-only conflict resolution"
            git merge --abort 2>/dev/null
            return 1
        }
        log_operation "Merged development (${#format_only[@]} format-only conflicts resolved)"
    fi

    # Submodule sync is NOT needed here: ci-base must have ZERO sub-package artifacts.
    # If .gitmodules appears in the working tree after this merge, the post-build
    # assertion (assert_ci_base_purity) will catch it and abort.

    # Return pre_sync_sha to caller via a global (NOT stdout): this function emits
    # log_* output on stdout, so echoing the SHA here would let the caller's command
    # substitution capture the log lines too, producing a corrupt revision like
    # "SEED anchor: ...\nReset ...\n<sha>" and a 'fatal: bad revision' in the scoped
    # py312 diff. A global decouples the return value from the log stream.
    SEED_PRE_SYNC_SHA="$pre_sync_sha"
    return 0
}

sync_base_branch() {
    local base_branch="$1"

    # Defense-in-depth: refuse to start if working tree has unexpected untracked files
    assert_clean_working_tree "$REPO_PATH" || return 1

    # Register merge.ours driver for .gitattributes resolution (idempotent)
    git -C "$REPO_PATH" config merge.ours.driver true

    log_section "Syncing $base_branch with $DEVELOPMENT_BRANCH"

    local checkout_output
    checkout_output=$(git checkout "$base_branch" 2>&1)
    local checkout_status=$?
    if [ $checkout_status -ne 0 ]; then
        log_error "Failed to checkout $base_branch (exit $checkout_status)"
        log_detail "git output: $checkout_output"
        indent_pop
        return 1
    fi

    # Safety guard: confirm HEAD is actually on $base_branch before merging.
    # A silent no-op checkout (e.g. already on bleeding-edge) would otherwise
    # cause development to be merged into the wrong branch.
    local current_branch
    current_branch=$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD)
    if [ "$current_branch" != "$base_branch" ]; then
        log_error "FATAL: sync_base_branch expected HEAD on '$base_branch' but found '$current_branch' — aborting to avoid merging $DEVELOPMENT_BRANCH into the wrong branch"
        indent_pop
        return 1
    fi

    local pre_sync_sha

    if [ "$REBUILD_MODE" = "true" ]; then
        # SEED-based rebuild: start from fixed anchor, merge development.
        # build_ci_base_from_seed returns the pre-merge SHA via the SEED_PRE_SYNC_SHA
        # global (not stdout) so its log output cannot corrupt the captured value.
        build_ci_base_from_seed "$base_branch" || return 1
        pre_sync_sha="$SEED_PRE_SYNC_SHA"
    else
        # Incremental cron: reset to origin tip, patch new development commits
        # (existing reset + dev_already_merged + format block — unchanged)

        # Reset local base_branch to origin to prevent stale-local-ref false positives.
        # If a prior rebuild advanced local ci-base without pushing, the is-ancestor
        # check on development would skip the merge and the bug perpetuates.
        if git ls-remote --exit-code origin "refs/heads/$base_branch" >/dev/null 2>&1; then
            git fetch origin "$base_branch" >/dev/null 2>&1 || true
            git reset --hard "origin/$base_branch" >/dev/null 2>&1 || {
                log_error "Failed to reset $base_branch to origin/$base_branch"
                return 1
            }
            log_operation "Reset $base_branch to origin/$base_branch tip"
        fi

        # Check if development has new commits
        local dev_already_merged=false
        if git merge-base --is-ancestor "$DEVELOPMENT_BRANCH" "$base_branch" 2>/dev/null; then
            log_operation "Already up to date with $DEVELOPMENT_BRANCH"
            dev_already_merged=true
        fi

        # Capture HEAD before the sync merge so the format pass can scope itself to
        # only files actually introduced or modified by this merge (not pre-existing
        # working-tree content).
        pre_sync_sha=$(git rev-parse HEAD)

        if [ "$dev_already_merged" = "false" ]; then
            # Merge development into base branch (skip pre-commit hooks for script-internal merge; gpg-signing handled by agent)
            if git merge --no-verify "$DEVELOPMENT_BRANCH" -m "Sync $base_branch with $DEVELOPMENT_BRANCH" >& /dev/null; then
                log_operation "Merged $DEVELOPMENT_BRANCH cleanly"
            else
                # Conflicts — classify as format-only vs logical
                local logical_conflicts=()
                local format_only=()

                while IFS= read -r file; do
                    case "$file" in
                        # CI/test config files have logical changes — need manual review
                        pyproject.toml|.pre-commit-config.yaml|conftest.py|.github/*|test/conftest.py)
                            logical_conflicts+=("$file")
                            ;;
                        *)
                            # All other conflicts are format-only — safe to accept upstream
                            format_only+=("$file")
                            ;;
                    esac
                done < <(git diff --name-only --diff-filter=U)

                if [ ${#logical_conflicts[@]} -gt 0 ]; then
                    log_error "Conflicts in logical files — manual resolution needed:"
                    for f in "${logical_conflicts[@]}"; do
                        log_detail "  $f"
                    done
                    git_quiet merge --abort
                    indent_pop
                    return 1
                fi

                # Format-only conflicts: accept upstream content, will reformat below
                for f in "${format_only[@]}"; do
                    git checkout --theirs "$f" 2>/dev/null
                    git add "$f"
                done
                git commit --no-verify --no-edit >& /dev/null || {
                    log_error "Failed to commit merge resolution"
                    git_quiet merge --abort 2>/dev/null
                    indent_pop
                    return 1
                }
                log_operation "Resolved ${#format_only[@]} format-only conflicts"
            fi

            # Re-initialize submodules after merge (development doesn't track them,
            # but ci-base does via .gitmodules).  The merge may leave stale working
            # trees; a sync+update restores the correct gitlinks and checkouts
            # without touching the index entries that pixi needs.
            # In rebuild mode, .gitmodules must NOT be present — the purity assertion
            # enforces this; abort hard if it is detected here.
            if [ -f ".gitmodules" ] && [ "$REBUILD_MODE" != "true" ]; then
                git submodule sync --quiet 2>/dev/null
                git submodule update --init --force 2>/dev/null
            elif [ -f ".gitmodules" ] && [ "$REBUILD_MODE" = "true" ]; then
                log_error "FATAL: .gitmodules found in ci-base after seed merge — sub-package artifact leaked into development or SEED"
                return 1
            fi

            # Reformat any new/changed upstream files.
            # Use ruff directly — pixi run format fails before pixi-workspace is merged
            # (sub-packages/ don't exist yet, breaking pixi dependency resolution).
            local format_ok=false
            local ruff_cmd=""
            if command -v ruff &> /dev/null; then
                ruff_cmd="ruff"
            elif [ -x "$REPO_PATH/.pixi/envs/default/bin/ruff" ]; then
                ruff_cmd="$REPO_PATH/.pixi/envs/default/bin/ruff"
            fi

            if [ -n "$ruff_cmd" ]; then
                if $ruff_cmd format hummingbot test controllers scripts >& /dev/null; then
                    format_ok=true
                else
                    log_warning "ruff format failed"
                fi
            else
                log_warning "ruff not found — skipping format step"
            fi

            if [ "$format_ok" = true ]; then
                # Run ruff I-rule (import sort) after format
                $ruff_cmd check --select I --fix hummingbot test controllers scripts >& /dev/null || true
                # Run ruff lint autofix (safe fixes only) so pre-existing upstream
                # violations (e.g. F811 redefinitions) that pre-commit-on-diff catches
                # are resolved, not just import sorting.
                $ruff_cmd check --fix hummingbot test controllers scripts >& /dev/null || true
                # Commit ALL in-scope tracked files ruff modified (not just the sync
                # delta) so pre-existing unformatted upstream files are also brought
                # into ruff compliance on ci-base. First run may be a large one-time
                # catch-up commit; subsequent runs are no-ops.
                if ! git diff --quiet -- hummingbot test controllers scripts ':!sub-packages' 2>/dev/null; then
                    git add -- hummingbot test controllers scripts ':!sub-packages'
                    git commit --no-verify -m "style: ruff format + lint fix + import sort (ci-base compliance)" >& /dev/null
                    log_operation "Formatted + lint-fixed ci-base to ruff compliance"
                else
                    log_operation "No formatting changes needed"
                fi
            fi
        fi  # end dev_already_merged guard
    fi  # end REBUILD_MODE branch

    # Merge _for_ci/* branches — ci-base-layer targeted fixes.
    # Runs unconditionally: _for_ci/* branches are OUR infrastructure additions
    # and must merge into ci-base regardless of whether development had new commits.
    # Uses the tracked_branches config under target_branches.ci-base.
    merge_for_ci_branches "$base_branch" || {
        log_error "_for_ci/* merge failed — rebuild aborted"
        return 1
    }

    # Inject external=["mock"] into [tool.ruff.lint] in pyproject.toml.
    # Suppresses 146KB of 'Invalid # noqa directive' warnings for # noqa: mock.
    # Delivered here (not via _for_ci/* branch) because pyproject.toml is in the
    # logical-conflict abort list — any earlier _for_ci/* branch touching it makes
    # subsequent pyproject.toml merges abort categorically.
    if [ -f "pyproject.toml" ] && ! grep -q 'external = \["mock"\]' pyproject.toml; then
        python3 - <<'PYEOF'
import re
path = "pyproject.toml"
c = open(path).read()
c = re.sub(
    r'(\[tool\.ruff\.lint\](?:.*?\n)*?ignore\s*=\s*\[[^\]]*\]\n)',
    r'\1external = ["mock"]\n',
    c
)
open(path, "w").write(c)
PYEOF
        if ! git diff --quiet pyproject.toml; then
            git add pyproject.toml
            git commit --no-verify -m 'fix(ruff): inject external=["mock"] to suppress # noqa: mock warnings' >/dev/null 2>&1 \
                && log_operation "Injected external=[\"mock\"] into [tool.ruff.lint]" \
                || log_warning "Failed to commit ruff external=[\"mock\"] fix"
        else
            log_warning "ruff external=[\"mock\"] injection: no change made (pattern not found)"
        fi
    else
        log_operation "ruff external=[\"mock\"] already present — skipping"
    fi

    # Post-merge py312 transform pass — scoped to files changed since ORIG_HEAD
    # (development sync + _for_ci merges combined).  Runs AFTER all merges so a
    # single commit covers the full delta, and AFTER ruff format so transforms
    # operate on already-normalised source.
    local -a py_changed=()
    while IFS= read -r f; do
        [[ "$f" == sub-packages/* ]] && continue
        [ -f "$f" ] && py_changed+=("$f")
    done < <(git diff --name-only "${pre_sync_sha}..HEAD" -- '*.py')

    if [ ${#py_changed[@]} -gt 0 ]; then
        run_py312_transforms_for_changed "${py_changed[@]}" || {
            log_error "py312 post-merge transform failed — aborting base branch sync"
            return 1
        }
    else
        log_operation "py312 post-merge transform: no Python files changed"
    fi

    # Final ruff normalization pass — runs AFTER merge_for_ci_branches AND the
    # py312 transform pass. The pre-merge format pass (above) only normalizes files
    # present BEFORE the _for_ci/* merges; cleanly-merged _for_ci files (rebased onto
    # development, never ci-base-formatted) and any py312 transform output therefore
    # arrive with import-order/format drift that fails the ci-base Quality gate
    # (ruff I001 + format). This pass brings the final tree into compliance.
    # Self-contained ruff detection so it works in incremental (non-REBUILD) mode
    # where the earlier ruff_cmd is never set. Idempotent: no-op when already clean.
    local final_ruff_cmd=""
    if command -v ruff &> /dev/null; then
        final_ruff_cmd="ruff"
    elif [ -x "$REPO_PATH/.pixi/envs/default/bin/ruff" ]; then
        final_ruff_cmd="$REPO_PATH/.pixi/envs/default/bin/ruff"
    fi
    if [ -n "$final_ruff_cmd" ]; then
        $final_ruff_cmd format hummingbot test controllers scripts >& /dev/null || true
        $final_ruff_cmd check --select I --fix hummingbot test controllers scripts >& /dev/null || true
        $final_ruff_cmd check --fix hummingbot test controllers scripts >& /dev/null || true
        if ! git diff --quiet -- hummingbot test controllers scripts ':!sub-packages' 2>/dev/null; then
            git add -- hummingbot test controllers scripts ':!sub-packages'
            git commit --no-verify -m "style: final ruff format + import sort after _for_ci merges (ci-base compliance)" >& /dev/null
            log_operation "Final ruff normalization after _for_ci merges"
        else
            log_operation "Final ruff normalization: no changes needed"
        fi
    else
        log_warning "ruff not found — skipping final normalization"
    fi

    log_result true "Base branch synced"
    return 0
}

###############################################################################
# Modular Branch Sync
# -------------------
# 1. Merges ci-base into the `modular` branch (--no-ff to preserve history).
#    modular may contain cherry-picked content ci-base doesn't have, so a
#    fast-forward would lose those commits.  A real merge absorbs ci-base
#    advances while keeping modular's own divergent commits.
# 2. Merges sub-package wiring branches listed in modular.tracked_branches.
#    (see merge_for_modular_branches below)
###############################################################################
sync_modular_branch() {
    local modular_branch="$1"
    local base_branch="$2"

    log_section "Merging $base_branch into $modular_branch"

    # Check out modular (create from base_branch tip if it doesn't exist yet)
    if git show-ref --verify --quiet "refs/heads/$modular_branch"; then
        git checkout "$modular_branch" >& /dev/null || {
            log_error "Failed to checkout $modular_branch"
            return 1
        }

        # Reset local modular to origin to prevent stale-local-ref false positives.
        # If a prior rebuild advanced local modular without pushing, the is-ancestor
        # check would skip the merge and the bug perpetuates.
        if git ls-remote --exit-code origin "refs/heads/$modular_branch" >/dev/null 2>&1; then
            git fetch origin "$modular_branch" >/dev/null 2>&1 || true
            git reset --hard "origin/$modular_branch" >/dev/null 2>&1 || {
                log_error "Failed to reset $modular_branch to origin/$modular_branch"
                return 1
            }
            log_operation "Reset $modular_branch to origin/$modular_branch tip"
        fi

        if git merge-base --is-ancestor "$base_branch" "$modular_branch" 2>/dev/null; then
            log_operation "$modular_branch already up to date with $base_branch — no merge needed"
        else
            # Merge ci-base into modular preserving modular's own commit history.
            # Skip pre-commit hooks for script-internal merge; gpg-signing handled by agent.
            if git merge --no-ff --no-verify \
                   "$base_branch" \
                   -m "sync(modular): merge $base_branch into $modular_branch" >& /dev/null; then
                log_operation "Merged $base_branch into $modular_branch"
            else
                # Classify conflicts: logical → abort, format-only → auto-resolve
                local logical_conflicts=() format_only=()
                while IFS= read -r file; do
                    case "$file" in
                        pyproject.toml|.pre-commit-config.yaml|conftest.py|.github/*|test/conftest.py)
                            logical_conflicts+=("$file") ;;
                        *)
                            format_only+=("$file") ;;
                    esac
                done < <(git diff --name-only --diff-filter=U)

                if [ ${#logical_conflicts[@]} -gt 0 ]; then
                    log_error "Logical conflicts merging $base_branch into $modular_branch — manual resolution needed:"
                    for f in "${logical_conflicts[@]}"; do log_detail "  $f"; done
                    git merge --abort >& /dev/null
                    return 1
                fi

                for f in "${format_only[@]}"; do
                    git checkout --theirs "$f" 2>/dev/null
                    git add "$f"
                done
                git commit --no-verify --no-edit >& /dev/null || {
                    log_error "Failed to commit format-only conflict resolution for $base_branch merge"
                    git merge --abort >& /dev/null
                    return 1
                }
                log_operation "Merged $base_branch (${#format_only[@]} format-only conflicts resolved)"
            fi
        fi
    else
        # First run: create modular from base_branch tip (prefer local, fallback to remote)
        local base_tip
        base_tip=$(git rev-parse "$base_branch" 2>/dev/null) || \
        base_tip=$(git rev-parse "origin/$base_branch" 2>/dev/null) || {
            log_error "Cannot resolve $base_branch tip — aborting modular sync"
            return 1
        }
        git checkout -b "$modular_branch" "$base_tip" >& /dev/null || {
            log_error "Failed to create $modular_branch from $base_branch"
            return 1
        }
        log_operation "$modular_branch created from $base_branch tip ($base_tip)"
    fi

    # Merge modular tracked_branches — sub-package wiring branches.
    # Runs unconditionally after the base merge: these are OUR additions that
    # must land on modular regardless of whether ci-base had new commits.
    merge_for_modular_branches "$modular_branch" || {
        log_error "Modular tracked-branch merge failed — rebuild aborted"
        return 1
    }

    log_result true "$modular_branch sync complete"
    return 0
}

###############################################################################
# Modular Tracked-Branch Merge Pass
# ----------------------------------
# Merges branches listed under target_branches.modular.tracked_branches into
# the modular branch.  Runs AFTER the fast-forward to ci-base tip.
# These are sub-package wiring branches (e.g. _for_bleed/strategy-framework).
# Conflict gates mirror merge_for_ci_branches: logical conflicts abort hard.
###############################################################################
merge_for_modular_branches() {
    local modular_branch="$1"

    # Read branches from YAML; skip if none configured
    local modular_branches
    modular_branches="$(yq -r '.target_branches["modular"].tracked_branches // [] | .[] | select(.enabled == true) | .name' "$BRANCH_CONFIG" 2>/dev/null)"
    if [ -z "$modular_branches" ]; then
        log_operation "No modular tracked branches configured — skipping"
        return 0
    fi

    log_section "Merging modular tracked branches into $modular_branch"

    while IFS= read -r branch; do
        [ -z "$branch" ] && continue
        log_operation "Merging $branch"

        local location
        location=$(branch_exists "$branch")
        if [ "$location" = "none" ]; then
            log_error "Modular branch $branch not found — skipping"
            continue
        fi

        local ref="$branch"
        if [ "$location" = "remote" ]; then
            git fetch origin "$branch" >& /dev/null || { log_error "Fetch failed for $branch"; return 1; }
            ref="origin/$branch"
        fi

        git checkout "$modular_branch" >& /dev/null || { log_error "Checkout $modular_branch failed"; return 1; }

        if git merge-base --is-ancestor "$ref" "$modular_branch" 2>/dev/null; then
            log_operation "$branch already in $modular_branch — skipping"
            continue
        fi

        if git merge --no-ff "$ref" -m "Auto-merge $branch into $modular_branch" >& /dev/null; then
            log_result true "$branch merged cleanly"
        else
            # Classify conflicts: logical → abort, format-only → auto-resolve
            local logical_conflicts=() format_only=()
            while IFS= read -r file; do
                case "$file" in
                    pyproject.toml|.pre-commit-config.yaml|conftest.py|.github/*|test/conftest.py)
                        logical_conflicts+=("$file") ;;
                    *)
                        format_only+=("$file") ;;
                esac
            done < <(git diff --name-only --diff-filter=U)

            if [ ${#logical_conflicts[@]} -gt 0 ]; then
                log_error "Logical conflicts in $branch — manual resolution needed:"
                for f in "${logical_conflicts[@]}"; do log_detail "  $f"; done
                git merge --abort >& /dev/null
                return 1
            fi

            for f in "${format_only[@]}"; do
                git checkout --theirs "$f" 2>/dev/null
                git add "$f"
            done
            git commit --no-verify --no-edit >& /dev/null || {
                log_error "Failed to commit format-only conflict resolution for $branch"
                git merge --abort >& /dev/null
                return 1
            }
            log_result true "$branch merged (${#format_only[@]} format-only conflicts resolved)"
        fi
    done < <(echo "$modular_branches")

    return 0
}

###############################################################################
# _for_ci/* Merge Pass
# --------------------
# Merges branches listed under target_branches.ci-base.tracked_branches into
# the base branch (ci-base).  Runs AFTER the development sync + format pass.
# Abort gates mirror _for_bleed: logical conflicts on pyproject.toml,
# conftest.py, .github/, .pre-commit-config.yaml cause hard abort.
###############################################################################
merge_for_ci_branches() {
    local base_branch="$1"

    # Read branches from YAML; skip if none configured
    local for_ci_branches
    for_ci_branches="$(yq -r '.target_branches["ci-base"].tracked_branches // [] | .[] | select(.enabled == true) | .name' "$BRANCH_CONFIG" 2>/dev/null)"
    if [ -z "$for_ci_branches" ]; then
        log_operation "No _for_ci/* branches configured — skipping"
        return 0
    fi

    log_section "Merging _for_ci/* branches into $base_branch"

    while IFS= read -r branch; do
        [ -z "$branch" ] && continue
        log_operation "Merging $branch"

        local location
        location=$(branch_exists "$branch")
        if [ "$location" = "none" ]; then
            log_error "_for_ci branch $branch not found — skipping"
            continue
        fi

        local ref="$branch"
        if [ "$location" = "remote" ]; then
            git fetch origin "$branch" >& /dev/null || { log_error "Fetch failed for $branch"; return 1; }
            ref="origin/$branch"
        fi

        git checkout "$base_branch" >& /dev/null || { log_error "Checkout $base_branch failed"; return 1; }

        if git merge-base --is-ancestor "$ref" "$base_branch" 2>/dev/null; then
            log_operation "$branch already in $base_branch — skipping"
            continue
        fi

        if git merge --no-ff "$ref" -m "Auto-merge $branch into $base_branch" >& /dev/null; then
            log_result true "$branch merged cleanly"
        else
            # Classify conflicts: logical → abort, format-only → auto-resolve
            local logical_conflicts=() format_only=()
            while IFS= read -r file; do
                case "$file" in
                    pyproject.toml|.pre-commit-config.yaml|conftest.py|.github/*|test/conftest.py)
                        logical_conflicts+=("$file") ;;
                    *)
                        format_only+=("$file") ;;
                esac
            done < <(git diff --name-only --diff-filter=U)

            if [ ${#logical_conflicts[@]} -gt 0 ]; then
                log_error "Logical conflicts in $branch — manual resolution needed:"
                for f in "${logical_conflicts[@]}"; do log_detail "  $f"; done
                git merge --abort >& /dev/null
                return 1
            fi

            for f in "${format_only[@]}"; do
                git checkout --theirs "$f" 2>/dev/null
                git add "$f"
            done
            git commit --no-verify --no-edit >& /dev/null || {
                log_error "Failed to commit format-only conflict resolution for $branch"
                git merge --abort >& /dev/null
                return 1
            }
            log_result true "$branch merged (${#format_only[@]} format-only conflicts resolved)"
        fi
    done < <(echo "$for_ci_branches")

    return 0
}

###############################################################################
# Branch Operations
###############################################################################
check_mergeability() {
    local branch="$1"
    local target="$2"

    # Use git merge-tree (plumbing) to check mergeability without touching
    # the working tree.  This avoids "unable to rmdir sub-packages/*" errors
    # caused by submodule directories that exist on bleeding-edge/ci-base but
    # not on the target branch.
    local conflict_log="${LOG_PATH}/merge_conflicts_${branch//\//_}.txt"
    git merge-tree --write-tree "$target" "$branch" > "$conflict_log" 2>&1
    local merge_rc=$?
    # Restore the index to HEAD so subsequent checkouts are not blocked by
    # staged merge-tree entries (index-dirtying defect).
    git read-tree HEAD
    if [ $merge_rc -eq 0 ]; then
        rm -f "$conflict_log"
        return 0
    else
        log_error "$branch has conflicts with $target"
        return 1
    fi
}

###############################################################################
# Test Management
###############################################################################
setup_temp_directory() {
    mkdir -p "${TEMP_DIR}" || return 1
    touch "${TEMP_LOG}" || return 1
}

parse_git_changes() {
    local output="$1"
    local files_changed=0
    local insertions=0
    local deletions=0
    local new_files=()

    while IFS= read -r line; do
        if [[ $line =~ ([0-9]+)[[:space:]]files?[[:space:]]changed ]]; then
            files_changed="${BASH_REMATCH[1]}"
        fi
        if [[ $line =~ ([0-9]+)[[:space:]]insertion ]]; then
            insertions="${BASH_REMATCH[1]}"
        fi
        if [[ $line =~ ([0-9]+)[[:space:]]deletion ]]; then
            deletions="${BASH_REMATCH[1]}"
        fi
        if [[ $line =~ ^[[:space:]]create[[:space:]]mode[[:space:]][0-9]+[[:space:]](.+)$ ]]; then
            new_files+=("${BASH_REMATCH[1]}")
        fi
    done < <(echo "$output")

    log_operation "Changes summary:"
    log_detail "${files_changed} files changed, +${insertions}/-${deletions} lines"

    if [ ${#new_files[@]} -gt 0 ]; then
        log_operation "New files created:"
        for file in "${new_files[@]}"; do
            log_detail "○ ${file}"
        done
    fi
}

get_suggested_test_path() {
    local file="$1"
    local base_dir="test"

    # Remove leading path components if they exist
    if [[ "$file" == *"hummingbot/"* ]]; then
        file="${file#*/}"  # Remove everything before first slash
    fi

    # Handle special files
    if [[ "$(basename "$file")" == "__init__.py" ]]; then
        # For __init__.py files, suggest a test for the module itself
        local dir_name=$(dirname "$file")
        local module_name=$(basename "$dir_name")
        echo "${base_dir}/${dir_name}/test_${module_name}.py"
        return
    fi

    # For normal Python files
    local file_no_ext="${file%.py}"
    echo "${base_dir}/${file_no_ext}/test_$(basename "$file")"
}

should_suggest_test() {
    local file="$1"

    # Skip suggesting tests for certain files
    if [[ "$file" == *"__init__.py" && ! -s "$file" ]]; then
        # Skip empty __init__.py files
        return 1
    fi

    if [[ "$file" == *".py" ]]; then
        # Only suggest tests for Python files
        return 0
    fi

    return 1
}

extract_missing_tests() {
    local log_file="$1"
    local missing_tests=()
    local skipped_files=()

    while IFS= read -r line; do
        if [[ $line =~ No[[:space:]]test[[:space:]]file[[:space:]]found[[:space:]]for[[:space:]](.+)$ ]]; then
            local file="${BASH_REMATCH[1]}"
            if should_suggest_test "$file"; then
                missing_tests+=("$file")
            else
                skipped_files+=("$file")
            fi
        fi
    done < "$log_file"

    if [ ${#missing_tests[@]} -gt 0 ]; then
        log_warning "Files requiring tests:"
        for file in "${missing_tests[@]}"; do
            local test_path=$(get_suggested_test_path "$file")
            log_detail "○ ${file}"
            log_detail "  Suggested test path: ${test_path}"
        done
    fi

    if [ ${#skipped_files[@]} -gt 0 ]; then
        log_operation "Files not requiring tests:"
        for file in "${skipped_files[@]}"; do
            log_detail "○ ${file} (skipped)"
        done
    fi

    [ ${#missing_tests[@]} -gt 0 ] && return 1 || return 0
}

run_tests() {
    local target_branch="$1"
    local source_branch="${2:-}"

    # Skip test verification during rebuild — the branch was just recreated
    # from development, so the test verifier can't resolve refs properly.
    # Tests should be run after the full rebuild completes.
    if [ "$REBUILD_MODE" = "true" ]; then
        return 0
    fi

    log_section "$(colorize "$BLUE" "Running tests")"

    # Paths
    local selector_script="${REPO_PATH}/.github/test-selection/select_tests.py"
    local selector_config="${REPO_PATH}/.github/test-selection/test-selection-map.yaml"
    local selector_state="${SCRIPT_DIR}/../state/select_tests_state.json"
    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local selector_log="${LOG_PATH}/select_tests_branch_${target_branch//\//_}_${timestamp}.log"
    local pytest_log="${LOG_PATH}/pytest_branch_${target_branch//\//_}_${timestamp}.log"
    local test_list_file="${LOG_PATH}/testlist_branch_${target_branch//\//_}_${timestamp}.txt"

    # Selector availability check (graceful degradation)
    if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$selector_script" ]; then
        log_step "Tests skipped: python3 or selector script not available"
        return 0
    fi

    mkdir -p "$(dirname "$selector_state")"

    # Resolve head SHA (used for mark-success and dedup)
    local head_sha
    head_sha="$(git -C "$REPO_PATH" rev-parse "$target_branch" 2>/dev/null)"
    if [ -z "$head_sha" ]; then
        log_result false "Tests aborted: could not resolve head SHA for $target_branch"
        return 1
    fi

    # Selector invocation
    local selector_args=(
        --mode branch
        --base-ref "origin/$DEVELOPMENT_BRANCH"
        --head-ref "$target_branch"
        --config "$selector_config"
        --state-file "$selector_state"
        --repo "$REPO_PATH"
    )
    if [ -n "$source_branch" ]; then
        selector_args+=(--source-branch "$source_branch")
    fi

    local selector_exit=0
    (cd "$REPO_PATH" && pixi run python "$selector_script" "${selector_args[@]}") > "$test_list_file" 2> "$selector_log" || selector_exit=$?

    case "$selector_exit" in
        0)
            # Filter blank lines and comments
            local test_files
            test_files="$(grep -v '^#' "$test_list_file" | grep -v '^[[:space:]]*$' || true)"
            if [ -z "$test_files" ]; then
                log_step "Selector returned 0 tests (dedup hit or empty selection); skipping pytest"
                return 0
            fi
            local test_count
            test_count="$(echo "$test_files" | wc -l)"
            log_step "Selector chose $test_count tests; running pixi pytest"
            # shellcheck disable=SC2086
            (cd "$REPO_PATH" && pixi run pytest $test_files -v) > "$pytest_log" 2>&1
            local pytest_exit=$?
            if [ "$pytest_exit" -eq 0 ]; then
                log_result true "pytest PASS ($test_count tests); see $(basename "$pytest_log")"
                # Update state with success
                (cd "$REPO_PATH" && pixi run python "$selector_script" --mark-success-for "$head_sha" --state-file "$selector_state") >/dev/null 2>&1 || \
                    log_step "Warning: failed to mark $head_sha as tested"
                return 0
            else
                log_result false "pytest FAIL ($test_count tests, exit=$pytest_exit); see $pytest_log"
                return 1
            fi
            ;;
        2)
            # Escape hatch: run full suite
            log_step "Selector emitted escape-hatch (exit 2); running full pixi pytest suite"
            (cd "$REPO_PATH" && pixi run pytest -v) > "$pytest_log" 2>&1
            local pytest_exit=$?
            if [ "$pytest_exit" -eq 0 ]; then
                log_result true "Full-suite pytest PASS; see $(basename "$pytest_log")"
                (cd "$REPO_PATH" && pixi run python "$selector_script" --mark-success-for "$head_sha" --state-file "$selector_state") >/dev/null 2>&1 || \
                    log_step "Warning: failed to mark $head_sha as tested"
                return 0
            else
                log_result false "Full-suite pytest FAIL (exit=$pytest_exit); see $pytest_log"
                return 1
            fi
            ;;
        *)
            log_result false "Selector failed (exit=$selector_exit); see $selector_log"
            return 1
            ;;
    esac
}

###############################################################################
# Branch Sync
###############################################################################
sync_branch() {
    local target="$1"
    local branch="$2"

    log_section "Processing $branch"

    # Verify branch exists
    local location
    location=$(branch_exists "$branch")
    if [ "$location" = "none" ]; then
        log_error "Branch does not exist"
        indent_pop
        return 1
    fi
    log_operation "$(colorize "$GREEN" "Branch found: $location")"

    # Check mergeability against the base branch (ci-base).  All _for_bleed
    # branches are based on ci-base, not development — checking against
    # development always fails on submodule entries that development lacks.
    # Skip during rebuild (branches are force-merged anyway).
    if [ "$target" = "$FEATURE_BRANCH" ] && [ "$REBUILD_MODE" != "true" ]; then
        local base_branch
        base_branch="$(get_base_branch "$target")"
        : "${base_branch:=$DEVELOPMENT_BRANCH}"  # fallback if no base configured
        check_mergeability "$branch" "$base_branch" || {
            log_error "Mergeability check failed (against $base_branch)"
            indent_pop
            return 1
        }
        log_operation "$(colorize "$GREEN" "Mergeable")"
    fi

    # Prepare reference
    local ref="$branch"
    if [ "$location" = "remote" ]; then
        git fetch origin "$branch" >& /dev/null || {
            log_error "Failed to fetch remote branch"
            indent_pop
            return 1
        }
        ref="origin/$branch"
        log_operation "$(colorize "$GREEN" "Fetch successful")"
    fi

    # Ensure we're on the target branch before checking ancestry or merging
    git checkout "$target" >& /dev/null || {
      log_result false "Checkout failed"
      indent_pop
      return 1
    }

    # Check if merge needed
    if git merge-base --is-ancestor "$ref" "$target" 2>/dev/null; then
        log_operation "Already up to date"
        indent_pop
        return 0
    fi

    if git -c commit.gpgsign=false merge --no-ff "$ref" -m "Auto-merge $branch into $target" >& /dev/null; then
        log_operation "Handle new files"
        handle_new_files || {
          log_error "Failed"
          indent_pop
          return 1
        }
        run_tests "$target" "$branch" || {
            log_error "Tests failed - reverting"
            git_quiet reset --hard HEAD^
            indent_pop
            return 1
        }
        log_result true "Done"
        return 0
    else
        git_quiet merge --abort

        # In rebuild mode, try format-aware merge before worktree rebase.
        # Feature branches are unformatted; bleeding-edge is formatted.
        # -X theirs prefers feature content for conflicting hunks (usually
        # format-only), then ruff format fixes the result.
        if [ "$REBUILD_MODE" = "true" ]; then
            log_operation "Merge conflict — trying format-aware merge"
            if git -c commit.gpgsign=false merge -X theirs --no-verify --no-ff "$ref" -m "Auto-merge $branch into $target" >& /dev/null; then
                # Merge succeeded with -X theirs — now reformat
                local ruff_cmd=""
                if command -v ruff &> /dev/null; then
                    ruff_cmd="ruff"
                elif [ -x "$REPO_PATH/.pixi/envs/default/bin/ruff" ]; then
                    ruff_cmd="$REPO_PATH/.pixi/envs/default/bin/ruff"
                fi
                local isort_cmd=""
                if command -v isort &> /dev/null; then
                    isort_cmd="isort"
                elif [ -x "$REPO_PATH/.pixi/envs/default/bin/isort" ]; then
                    isort_cmd="$REPO_PATH/.pixi/envs/default/bin/isort"
                fi
                if [ -n "$ruff_cmd" ] && ! git diff --quiet; then
                    $ruff_cmd format hummingbot test controllers scripts >& /dev/null
                fi
                if [ -n "$isort_cmd" ]; then
                    $isort_cmd hummingbot test controllers scripts >& /dev/null
                fi
                if ! git diff --quiet; then
                    git add -A
                    git -c commit.gpgsign=false commit --no-verify -m "style: ruff format + isort after $branch merge" >& /dev/null
                    log_operation "Formatted after merge"
                fi
                handle_new_files || {
                    log_error "Failed"
                    indent_pop
                    return 1
                }
                log_result true "Done (format-aware merge)"
                return 0
            fi
            git_quiet merge --abort 2>/dev/null
        fi

        # Fallback: worktree-based rebase onto ci-base (permanent base, not ephemeral bleeding-edge)
        if [ "$REBUILD_MODE" = "true" ]; then
            log_operation "Format-aware merge failed — attempting worktree rebase"
            local wt_dir="${REPO_PATH}/.worktrees/rebase-$(basename "$branch")"
            local rebase_target
            rebase_target=$(git rev-parse ci-base)

            # Clean up any stale worktree
            rm -rf "$wt_dir" 2>/dev/null
            git worktree prune 2>/dev/null

            # Create worktree on the conflicting branch
            if git worktree add "$wt_dir" "$ref" >& /dev/null; then
                # Attempt automatic rebase onto ci-base (permanent base, not ephemeral bleeding-edge)
                if (cd "$wt_dir" && GIT_EDITOR=true git -c commit.gpgsign=false -c rebase.gpgsign=false rebase "$rebase_target" >& /dev/null); then
                    # Rebase succeeded — update branch ref and retry merge
                    local new_tip
                    new_tip=$(cd "$wt_dir" && git rev-parse HEAD)
                    git worktree remove "$wt_dir" >& /dev/null 2>&1
                    git worktree prune 2>/dev/null

                    # Update the branch to point at the rebased tip
                    git branch -f "$branch" "$new_tip" >& /dev/null 2>&1

                    # Retry the merge
                    if git -c commit.gpgsign=false merge --no-ff "$branch" -m "Auto-merge $branch into $target (rebased)" >& /dev/null; then
                        log_operation "Handle new files"
                        handle_new_files || {
                            log_error "Failed"
                            indent_pop
                            return 1
                        }
                        run_tests "$target" "$branch" || {
                            log_error "Tests failed - reverting"
                            git_quiet reset --hard HEAD^
                            indent_pop
                            return 1
                        }
                        log_result true "Done (after rebase)"
                        indent_pop
                        return 0
                    else
                        git_quiet merge --abort
                        log_result false "Merge failed even after rebase"
                        indent_pop
                        return 1
                    fi
                else
                    # Auto-rebase failed — leave worktree for manual resolution
                    # Don't abort the rebase — leave it paused so user can resolve
                    log_warning "Worktree left for manual resolution: $wt_dir"
                    log_detail "  cd $wt_dir"
                    log_detail "  # resolve conflicts, git add, git rebase --continue"
                    log_detail "  # then: git -C $REPO_PATH branch -f $branch \$(git -C $wt_dir rev-parse HEAD)"
                    log_detail "  # finally: git -C $REPO_PATH worktree remove $wt_dir"
                    log_result false "Merge failed — worktree ready for manual rebase"
                    indent_pop
                    return 1
                fi
            else
                log_result false "Merge failed (worktree creation failed)"
                indent_pop
                return 1
            fi
        else
            log_result false "Merge failed"
            indent_pop
            return 1
        fi
    fi
}

###############################################################################
# Reads the YAML config (branch-tracking.yaml) for target branch keys.
###############################################################################
get_target_branches() {
    local result
    result="$(yq -r '.target_branches | keys[]' "$BRANCH_CONFIG" 2>/dev/null)"
    echo "$result"
}

get_tracked_branches() {
    local target="$1"
    local result
    result="$(yq -r ".target_branches[\"$target\"].tracked_branches[].name" "$BRANCH_CONFIG" 2>/dev/null)"
    echo "$result"
}

get_branch_parent() {
    local target="$1"
    local branch="$2"
    local result
    result="$(yq -r ".target_branches[\"$target\"].tracked_branches[] | select(.name == \"$branch\").parent" "$BRANCH_CONFIG" 2>/dev/null)"
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        echo ""
    else
        echo "$result"
    fi
}

get_branch_tier() {
    local target="$1"
    local branch="$2"
    local result
    result="$(yq -r ".target_branches[\"$target\"].tracked_branches[] | select(.name == \"$branch\").tier" "$BRANCH_CONFIG" 2>/dev/null)"
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        echo "feature"
    else
        echo "$result"
    fi
}

# Emits branches in topological order partitioned by tier.
# infrastructure branches are emitted first (in parent→child order),
# then feature branches (in parent→child order).
# Within each tier, flat branches (no parent) come before chained branches.
# A log banner is printed before each tier to mark the transition.
get_tracked_branches_sorted() {
    local target="$1"
    local -a infra_flat=() infra_chain_name=() infra_chain_parent=()
    local -a feat_flat=()  feat_chain_name=()  feat_chain_parent=()

    while IFS= read -r branch; do
        [ -z "$branch" ] && continue
        local parent tier
        parent="$(get_branch_parent "$target" "$branch")"
        tier="$(get_branch_tier "$target" "$branch")"
        if [ "$tier" = "infrastructure" ]; then
            if [ -z "$parent" ]; then
                infra_flat+=("$branch")
            else
                infra_chain_name+=("$branch")
                infra_chain_parent+=("$parent")
            fi
        else
            if [ -z "$parent" ]; then
                feat_flat+=("$branch")
            else
                feat_chain_name+=("$branch")
                feat_chain_parent+=("$parent")
            fi
        fi
    done < <(get_tracked_branches "$target")

    # Helper: emit one tier's flat+chained branches in dependency order
    # Usage: _emit_tier_branches flat_arr chain_name_arr chain_parent_arr emitted_arr_name
    _emit_tier_branches() {
        local -n _flat="$1"
        local -n _chain_name="$2"
        local -n _chain_parent="$3"
        local -n _emitted="$4"

        for b in "${_flat[@]}"; do
            echo "$b"
            _emitted+=("$b")
        done

        local -a pending_idx=()
        for i in "${!_chain_name[@]}"; do pending_idx+=("$i"); done

        local progress=true
        while [ ${#pending_idx[@]} -gt 0 ] && [ "$progress" = "true" ]; do
            progress=false
            local -a next_pending=()
            for i in "${pending_idx[@]}"; do
                local parent_found=false
                for e in "${_emitted[@]}"; do
                    if [ "$e" = "${_chain_parent[$i]}" ]; then parent_found=true; break; fi
                done
                if [ "$parent_found" = "true" ]; then
                    echo "${_chain_name[$i]}"
                    _emitted+=("${_chain_name[$i]}")
                    progress=true
                else
                    next_pending+=("$i")
                fi
            done
            pending_idx=("${next_pending[@]}")
        done

        for i in "${pending_idx[@]}"; do
            echo -e "$(get_indent)${BRANCH_CHAR}  $(colorize "$BLUE" "WARNING: branch ${_chain_name[$i]} has unresolved parent ${_chain_parent[$i]} — merging anyway")" >&2
            echo "${_chain_name[$i]}"
        done
    }

    local -a emitted=()

    # Banners go to stderr so they appear in the log without polluting the
    # stdout branch-name stream that callers consume via process substitution.
    echo -e "$(get_indent)${BRANCH_CHAR}  $(colorize "$BLUE" "=== Merging infrastructure branches ===")" >&2
    _emit_tier_branches infra_flat infra_chain_name infra_chain_parent emitted

    echo -e "$(get_indent)${BRANCH_CHAR}  $(colorize "$BLUE" "=== Merging feature branches ===")" >&2
    _emit_tier_branches feat_flat feat_chain_name feat_chain_parent emitted
}

is_branch_enabled() {
    local target="$1"
    local branch="$2"
    local result
    result="$(yq -r ".target_branches[\"$target\"].tracked_branches[] | select(.name == \"$branch\").enabled" "$BRANCH_CONFIG" 2>/dev/null)"
    if [ -z "$result" ]; then
        echo "false"
    else
        echo "$result"
    fi
}

is_branch_permanent() {
    local target="$1"
    local branch="$2"
    local result
    result="$(yq -r ".target_branches[\"$target\"].tracked_branches[] | select(.name == \"$branch\").permanent" "$BRANCH_CONFIG" 2>/dev/null)"
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        echo "false"
    else
        echo "$result"
    fi
}

is_branch_feature_only() {
    local target="$1"
    local branch="$2"
    local result
    result="$(yq -r ".target_branches[\"$target\"].tracked_branches[] | select(.name == \"$branch\").feature_only" "$BRANCH_CONFIG" 2>/dev/null)"
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        echo "false"
    else
        echo "$result"
    fi
}

###############################################################################
# Main Execution
###############################################################################
main() {
  log_header "$(colorize "$BLUE" "Branch Tracking")"

  ensure_directories
  update_status

  # Go to the repository directory
  cd "$REPO_PATH" || {
      log_error "Failed to change to repository directory: $REPO_PATH"
      exit 1
  }

  # Validate environment
  if ! validate_environment; then
      log_error "Environment validation failed."
      exit 1
  fi

  REBUILD_MODE=false

  if [ "$1" = "--rebuild" ]; then
      REBUILD_MODE=true
      # pixi.lock churn from pixi solves is transient in this rebuild-output tree; discard
      # it so the clean-state gate and the rebuild's branch checkouts do not abort.
      git -C "$REPO_PATH" checkout -- pixi.lock 2>/dev/null || true
      ensure_clean_state || exit 1
      log_section "$(colorize "$YELLOW" "Rebuilding")"

      # The 3-layer architecture: development → ci-base → modular → bleeding-edge.
      # ci-base is ALWAYS the infra root; modular sits above it; FEATURE_BRANCH (typically
      # bleeding-edge) sits above modular. get_base_branch(bleeding-edge) returns "modular",
      # but sync_base_branch must operate on ci-base, not modular — otherwise _for_ci/*
      # branches get merged into modular instead of ci-base.
      local root_base_branch="ci-base"
      local base_branch
      base_branch="$(get_base_branch "$FEATURE_BRANCH")"

      # Step 1: sync ci-base with development + merge _for_ci/* into ci-base
      sync_base_branch "$root_base_branch" || {
          log_error "ci-base sync failed — rebuild aborted"
          exit 1
      }

      # Step 1b: Assert ci-base purity before advancing to modular (REBUILD_MODE only)
      if [ "$REBUILD_MODE" = "true" ]; then
          git checkout "$root_base_branch" >& /dev/null
          assert_ci_base_purity || exit 1
      fi

      # Step 2: if FEATURE_BRANCH is bleeding-edge (base = modular), advance modular.
      # If FEATURE_BRANCH IS modular itself, skip (we just synced it via step 1's modular path? No — step 1 used ci-base).
      # If FEATURE_BRANCH IS ci-base, skip (already synced).
      if [ -n "$base_branch" ] && [ "$base_branch" != "$root_base_branch" ]; then
          sync_modular_branch "$base_branch" "$root_base_branch" || {
              log_error "Modular ($base_branch) sync failed — rebuild aborted"
              exit 1
          }
      fi

      if [ -n "$base_branch" ]; then
          log_operation "Create $FEATURE_BRANCH from $base_branch"
          git_quiet checkout "$base_branch"
          git_quiet branch -D "$FEATURE_BRANCH" >& /dev/null
          git_quiet checkout -b "$FEATURE_BRANCH"
      else
          # No base branch configured — use development directly (legacy behavior)
          log_operation "Checkout development branch"
          git_quiet checkout "$DEVELOPMENT_BRANCH"
          log_operation "Delete feature branch"
          git_quiet branch -D "$FEATURE_BRANCH" >& /dev/null
          log_operation "Create feature branch"
          git_quiet checkout -b "$FEATURE_BRANCH"

          # Clean up embedded git repos left over from prior feature branch.
          if [ -d "sub-packages" ]; then
              log_operation "Clean embedded sub-package repos"
              find sub-packages -maxdepth 2 -name ".git" -exec rm -rf {} + 2>/dev/null
              rm -rf sub-packages/*/
          fi
      fi

      # Ensure the new branch is properly initialized
      log_operation "Initialize feature branch"
      git -c commit.gpgsign=false commit --allow-empty --no-verify -m "Initialize $FEATURE_BRANCH" >& /dev/null || {
          log_error "Failed to initialize feature branch"
          exit 1
      }
      log_result true "Rebuild complete"
  fi

  # Ensure local modular tracks origin/modular even in incremental cron mode.
  # sync_modular_branch (which does this for --rebuild) is gated above; without
  # this block, direct commits to origin/modular wouldn't propagate.
  if git show-ref --verify --quiet "refs/heads/modular"; then
      git fetch origin modular >/dev/null 2>&1 || log_operation "modular fetch failed (non-fatal)"
      local _current_branch
      _current_branch=$(git rev-parse --abbrev-ref HEAD)
      git checkout modular >& /dev/null || log_error "Failed to checkout modular for sync"
      if git merge --ff-only origin/modular >& /dev/null; then
          log_operation "modular fast-forwarded to origin/modular"
      else
          log_operation "modular not fast-forwardable to origin/modular (diverged or already at tip)"
      fi
      git checkout "$_current_branch" >& /dev/null
  fi

  INDENT_LEVEL=0  # Flatten output for branch processing

  # For each target branch in the config
  while IFS= read -r target_branch; do
      [ -z "$target_branch" ] && continue

      # ci-base is managed exclusively by sync_base_branch (development sync +
      # format pass + merge_for_ci_branches + py312 post-merge transform).
      # Skip it here to prevent double-processing _for_ci/* branches.
      if [ "$target_branch" = "ci-base" ]; then
          continue
      fi

      log_step "$(colorize "$BLUE" "Processing target branch: $target_branch")"

      # For each tracked branch under that target
      local loop_indent=$INDENT_LEVEL
      while IFS= read -r branch; do
          [ -z "$branch" ] && continue

          enabled="$(is_branch_enabled "$target_branch" "$branch")"

          if [ "$enabled" = "true" ]; then
              INDENT_LEVEL=$loop_indent  # Reset indent before each branch
              sync_branch "$target_branch" "$branch"
          fi
      done < <(get_tracked_branches_sorted "$target_branch")
      INDENT_LEVEL=$loop_indent

  done < <(get_target_branches)

  # Final format pass — merges can produce unformatted results even when
  # individual branches are clean (e.g. merge conflict resolution artifacts
  # or content from different formatting epochs).
  if [ "$REBUILD_MODE" = "true" ]; then
      local ruff_cmd=""
      if command -v ruff &> /dev/null; then
          ruff_cmd="ruff"
      elif [ -x "$REPO_PATH/.pixi/envs/default/bin/ruff" ]; then
          ruff_cmd="$REPO_PATH/.pixi/envs/default/bin/ruff"
      fi
      local isort_cmd=""
      if command -v isort &> /dev/null; then
          isort_cmd="isort"
      elif [ -x "$REPO_PATH/.pixi/envs/default/bin/isort" ]; then
          isort_cmd="$REPO_PATH/.pixi/envs/default/bin/isort"
      fi
      if [ -n "$ruff_cmd" ]; then
          $ruff_cmd format hummingbot test controllers scripts >& /dev/null
          $ruff_cmd check --fix hummingbot test controllers scripts >& /dev/null || true
      fi
      if [ -n "$isort_cmd" ]; then
          $isort_cmd hummingbot test controllers scripts >& /dev/null
      fi
      if [ -n "$ruff_cmd" ] || [ -n "$isort_cmd" ]; then
          if ! git diff --quiet; then
              git add -A -- . ':!sub-packages'
              git -c commit.gpgsign=false commit --no-verify -m "style: final ruff format + lint fix + isort pass after rebuild" >& /dev/null
              log_step "Applied final format pass"
          fi
      fi
  fi

  # Conflict-marker validation — fail loudly if unresolved markers leaked
  # into committed source files after all merges and format/transform passes.
  if [ "$REBUILD_MODE" = "true" ]; then
      log_step "Conflict-marker scan"
      local conflict_files
      conflict_files=$(grep -rln \
          --include='*.py' --include='*.pyx' --include='*.pxd' \
          --include='*.toml' --include='*.yaml' --include='*.yml' \
          --exclude-dir='.git' --exclude-dir='.pixi' --exclude-dir='build' \
          --exclude-dir='dist' --exclude-dir='node_modules' --exclude-dir='.worktrees' \
          '^<<<<<<< ' "$REPO_PATH" 2>/dev/null || true)
      if [ -n "$conflict_files" ]; then
          log_error "FATAL: Unresolved conflict markers detected — rebuild ABORTED"
          log_error "Affected files:"
          while IFS= read -r f; do
              log_error "  $f"
              grep -n '^<<<<<<< \|^=======\s*$\|^>>>>>>> ' "$f" 2>/dev/null | head -5 | while IFS= read -r marker_line; do
                  log_detail "    $marker_line"
              done
          done <<< "$conflict_files"
          log_error "Resolve markers on the source _for_bleed/* branches and re-run --rebuild"
          exit 1
      fi
      log_step "Conflict-marker scan: clean"
  fi

  log_step "Branch tracking completed successfully!"

  if [ "$REBUILD_MODE" = true ]; then
      local MANUAL_REBUILD_SUMMARY="${LOG_PATH}/manual_rebuild_latest.txt"
      write_run_summary "$MANUAL_REBUILD_SUMMARY" 0 "n/a" "success" "n/a" "(stdout)"
      log_step "Wrote manual rebuild summary to $MANUAL_REBUILD_SUMMARY"
  fi

  # ----------------------------------------------------------------------------
  # Pre-push CI gate. We must NEVER publish a branch that would be red on CI:
  # upstream development is green and _for_ci/_for_bleed merges must not introduce
  # regressions onto ci-base/modular/bleeding-edge. For each output branch, in
  # dependency order, we run THE EXACT commands CI runs (workflow.yml, env -e ci),
  # locally, BEFORE pushing, so "green locally" == "green on CI":
  #   Quality (hard): pre-commit on the diff vs development (auto-fix + recommit,
  #                   then re-verify) + `lint` + `format-check`. (CI's type-check is
  #                   continue-on-error, so it is NOT a hard gate here.)
  #   Tests   (hard): `build` + CI's exact `coverage run -m pytest` invocation with
  #                   the --timeout/--ignore set (KEEP IN SYNC with workflow.yml).
  # Only a branch passing BOTH is pushed (--force-with-lease). If ci-base fails we
  # abort before pushing anything downstream (modular/bleeding-edge build on it). On
  # any failure: branches left built-but-unpushed, exit 1 so cron/operator sees it,
  # ci-base-pr NOT refreshed. NOTE: full build+test per branch is intentionally
  # expensive — correctness over speed, per requirement.
  # ----------------------------------------------------------------------------
  log_section "Pre-push CI gate (quality + tests, CI-identical)"
  local _pixi_cmd="" _gate_branch _changed _q_ok
  local -a _pushed=()
  local _gate_failed=false
  if command -v pixi &> /dev/null; then
      _pixi_cmd="pixi"
  else
      log_error "pixi not found — cannot run CI-identical gate; refusing to push unverified branches"
      exit 1
  fi
  local -a _pytest_ignores=(
      --timeout=30
      --ignore=test/mock
      --ignore=test/hummingbot/connector/exchange/ndax/
      --ignore=test/hummingbot/connector/derivative/dydx_v4_perpetual/
      --ignore=test/hummingbot/connector/derivative/decibel_perpetual/
      --ignore=test/hummingbot/core/rate_oracle/sources/test_decibel_perpetual_rate_source.py
      --ignore=test/hummingbot/connector/exchange/vertex/
      --ignore=test/hummingbot/connector/gateway/
      --ignore=test/connector/utilities/oms_connector/
      --ignore=test/hummingbot/strategy/amm_arb/
      --ignore=test/hummingbot/strategy/cross_exchange_market_making/
  )

  for _gate_branch in "ci-base" "modular" "$FEATURE_BRANCH"; do
      log_step "Gating $_gate_branch (quality + tests)"
      if ! git -C "$REPO_PATH" checkout "$_gate_branch" >& /dev/null; then
          log_error "  checkout $_gate_branch failed — aborting gate"
          _gate_failed=true; break
      fi

      _q_ok=true
      _changed=$(cd "$REPO_PATH" && git diff --name-only "origin/$DEVELOPMENT_BRANCH" | grep -v '^sub-packages/' | grep -v '^pixi\.lock$' || true)
      if [ -n "$_changed" ]; then
          if ! ( cd "$REPO_PATH" && "$_pixi_cmd" run --frozen -e ci pre-commit run --files $_changed ) >& /dev/null; then
              if ! git -C "$REPO_PATH" diff --quiet; then
                  git -C "$REPO_PATH" add -A -- . ':!sub-packages'
                  git -C "$REPO_PATH" -c commit.gpgsign=false commit --no-verify \
                      -m "style: pre-push CI-gate autofix on $_gate_branch" >& /dev/null
              fi
              _changed=$(cd "$REPO_PATH" && git diff --name-only "origin/$DEVELOPMENT_BRANCH" | grep -v '^sub-packages/' | grep -v '^pixi\.lock$' || true)
              if [ -n "$_changed" ]; then
                  ( cd "$REPO_PATH" && "$_pixi_cmd" run --frozen -e ci pre-commit run --files $_changed ) >& /dev/null || _q_ok=false
              fi
          fi
      fi
      if [ "$_q_ok" = true ]; then
          ( cd "$REPO_PATH" && "$_pixi_cmd" run --frozen -e ci lint ) >& /dev/null || _q_ok=false
      fi
      if [ "$_q_ok" = true ]; then
          ( cd "$REPO_PATH" && "$_pixi_cmd" run --frozen -e ci format-check ) >& /dev/null || _q_ok=false
      fi
      if [ "$_q_ok" != true ]; then
          log_error "  Quality gate FAILED on $_gate_branch — NOT pushing. Inspect: cd $REPO_PATH && pixi run -e ci lint && pixi run -e ci format-check"
          _gate_failed=true; break
      fi
      log_detail "  quality: pass"

      if ! ( cd "$REPO_PATH" && "$_pixi_cmd" run --frozen -e ci build ) >& /dev/null; then
          log_error "  Build FAILED on $_gate_branch — NOT pushing. Inspect: cd $REPO_PATH && pixi run -e ci build"
          _gate_failed=true; break
      fi
      if ! ( cd "$REPO_PATH" && "$_pixi_cmd" run --frozen -e ci coverage run -m pytest "${_pytest_ignores[@]}" ) >& /dev/null; then
          log_error "  Test gate FAILED on $_gate_branch — failing tests; NOT pushing. Inspect: cd $REPO_PATH && pixi run -e ci coverage run -m pytest ${_pytest_ignores[*]}"
          _gate_failed=true; break
      fi
      log_detail "  tests: pass"

      if git -C "$REPO_PATH" push origin "$_gate_branch" --force-with-lease >& /dev/null; then
          _pushed+=("$_gate_branch")
          log_result true "$_gate_branch gated green + pushed"
      else
          log_error "  push FAILED for $_gate_branch (gates passed) — run: git -C \"$REPO_PATH\" push origin $_gate_branch --force-with-lease"
          _gate_failed=true; break
      fi
  done

  if [ "$_gate_failed" = true ]; then
      log_error "Pre-push gate halted. Pushed: [${_pushed[*]:-none}]. Remaining branches built locally but NOT pushed. ci-base-pr NOT refreshed. Fix the failures and re-run."
      exit 1
  fi

  # All outputs verified green + pushed -> refresh the squashed ci-base-pr snapshot
  # (regenerate-ci-base-pr.sh reads origin/ci-base^{tree}, now freshly pushed + green;
  # MUST run after the ci-base push). Checkout-safe (refspec push via commit-tree).
  local _regen_script="$(dirname "${BASH_SOURCE[0]}")/regenerate-ci-base-pr.sh"
  if [ -x "$_regen_script" ] && bash "$_regen_script" "$REPO_PATH" >& /dev/null; then
      log_result true "regenerated + pushed ci-base-pr (green)"
  else
      log_error "ci-base-pr NOT refreshed (regenerate-ci-base-pr.sh missing or failed) — run it manually"
  fi
}

main "$@"
