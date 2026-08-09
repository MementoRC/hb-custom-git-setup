#!/bin/bash
###############################################################################
# hummingbot-cron-wrapper.sh
# --------------------------
# Cron-safe entry point that orchestrates the full sync cycle:
#   1. Upstream sync (fetch upstream/development, fast-forward local, push)
#   2. Branch tracking merges (hummingbot-branch-tracking.sh)
#   3. Interface compatibility check (hummingbot-interface-check.sh)
#
# All output is captured to timestamped logs in logs/cron/.
# Exit codes: 0=clean, 1=error, 2=conflicts need attention
#
# Usage:
#   ./hummingbot-cron-wrapper.sh [--notify] [--skip-upstream] [--skip-tracking] [--skip-interface]
#
# Cron example:
#   0 3 * * 0 /path/to/hummingbot-cron-wrapper.sh --notify
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

###############################################################################
# Configuration
###############################################################################
CRON_LOG_DIR="${LOG_PATH}/cron"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
# Adopt TIMESTAMP as the shared RUN_ID so cron-wrapper and child branch-tracking.sh
# accumulate logs under the same run dir. common.sh already ran with its own generated
# RUN_ID; override both here and re-export so the child process inherits the cron TIMESTAMP.
RUN_ID="$TIMESTAMP"
export RUN_ID
RUN_LOG_DIR="${LOG_PATH}/runs/${RUN_ID}"
export RUN_LOG_DIR
mkdir -p "$RUN_LOG_DIR"
ln -sfn "$RUN_LOG_DIR" "${LOG_PATH}/runs/latest"
CRON_LOG="${CRON_LOG_DIR}/sync_${TIMESTAMP}.log"
SUMMARY_FILE="${CRON_LOG_DIR}/latest_summary.txt"

# Flags
DO_NOTIFY=false
SKIP_UPSTREAM=false
SKIP_TRACKING=false
SKIP_INTERFACE=false

###############################################################################
# Parse Arguments
###############################################################################
while [[ $# -gt 0 ]]; do
    case $1 in
        --notify)           DO_NOTIFY=true; shift ;;
        --skip-upstream)    SKIP_UPSTREAM=true; shift ;;
        --skip-tracking)    SKIP_TRACKING=true; shift ;;
        --skip-interface)   SKIP_INTERFACE=true; shift ;;
        --help)
            echo "Usage: $0 [--notify] [--skip-upstream] [--skip-tracking] [--skip-interface]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

###############################################################################
# Setup
###############################################################################
mkdir -p "$CRON_LOG_DIR"

# Redirect all output to log file (and stdout if interactive)
if [ -t 1 ]; then
    # Interactive: tee to both terminal and log
    exec > >(tee -a "$CRON_LOG") 2>&1
else
    # Cron: log only
    exec >> "$CRON_LOG" 2>&1
fi

###############################################################################
# Summary Tracking
###############################################################################
OVERALL_STATUS=0
UPSTREAM_STATUS="skipped"
TRACKING_STATUS="skipped"
SUBMODULE_SYNC_STATUS="skipped"
INTERFACE_STATUS="skipped"
ERRORS=()

###############################################################################
# Utility: clear_stale_git_index_lock
###############################################################################
# Clear stale .git/index.lock if older than threshold seconds.
# Safe — refuses to remove locks held by live git processes (mtime within last 30s)
# or where lsof reports an open handle.
clear_stale_git_index_lock() {
    local repo="$1"
    local lock="${repo}/.git/index.lock"
    local max_age_seconds="${2:-30}"

    [ -f "$lock" ] || return 0

    local lock_mtime
    lock_mtime=$(stat -c %Y "$lock" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    local age=$((now - lock_mtime))

    if [ "$age" -lt "$max_age_seconds" ]; then
        log_step "Lock $lock is recent (${age}s old < ${max_age_seconds}s); leaving alone"
        return 1
    fi

    # Check no live git holds it (best-effort; lsof may not be installed)
    if command -v lsof >/dev/null 2>&1; then
        if lsof "$lock" >/dev/null 2>&1; then
            log_step "Lock $lock has live handle (lsof); leaving alone"
            return 1
        fi
    fi

    rm -f "$lock"
    log_result true "Cleared stale $lock (age ${age}s)"
    return 0
}

###############################################################################
# Utility: clear_stale_submodule_index_locks
###############################################################################
# Clear stale .git/modules/*/index.lock files if older than threshold seconds.
# Safe — uses same age+lsof validation as parent lock helper.
# Silently ignores if .git/modules/ does not exist.
clear_stale_submodule_index_locks() {
    local repo="$1"
    local max_age_seconds="${2:-30}"
    local modules_dir="${repo}/.git/modules"
    [ -d "$modules_dir" ] || return 0

    local cleared=0
    local total=0
    # Use find to safely walk arbitrary depth (submodules of submodules)
    while IFS= read -r -d '' lock; do
        total=$((total + 1))
        local lock_mtime
        lock_mtime=$(stat -c %Y "$lock" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        local age=$((now - lock_mtime))

        if [ "$age" -lt "$max_age_seconds" ]; then
            log_step "Submodule lock $lock recent (${age}s); leaving alone"
            continue
        fi

        if command -v lsof >/dev/null 2>&1; then
            if lsof "$lock" >/dev/null 2>&1; then
                log_step "Submodule lock $lock has live handle (lsof); leaving alone"
                continue
            fi
        fi

        rm -f "$lock"
        cleared=$((cleared + 1))
        log_result true "Cleared stale submodule lock $lock (age ${age}s)"
    done < <(find "$modules_dir" -mindepth 2 -maxdepth 4 -name 'index.lock' -type f -print0 2>/dev/null)

    if [ "$total" -gt 0 ]; then
        log_step "Submodule lock scan: cleared ${cleared}/${total}"
    fi
    return 0
}

send_notification() {
    local title="$1"
    local body="$2"

    if command -v notify-send &> /dev/null; then
        # Set urgency based on status
        local urgency="normal"
        [ $OVERALL_STATUS -ge 1 ] && urgency="critical"
        notify-send --urgency="$urgency" "$title" "$body" 2>/dev/null || true
    fi
}

###############################################################################
# Main Execution
###############################################################################
log_header "$(colorize "$BLUE" "Cron Sync Cycle")"
log_step "Started: $(date '+%Y-%m-%d %H:%M:%S')"
log_step "Log: ${CRON_LOG}"

# Validate base environment
cd "$REPO_PATH" || {
    log_error "Failed to change to repository directory: $REPO_PATH"
    OVERALL_STATUS=1
    ERRORS+=("Cannot access repository: $REPO_PATH")
    write_run_summary "$SUMMARY_FILE" "$OVERALL_STATUS" "$UPSTREAM_STATUS" "$TRACKING_STATUS" "$INTERFACE_STATUS" "$CRON_LOG" ERRORS
    exit 1
}

if ! check_git_repo; then
    OVERALL_STATUS=1
    ERRORS+=("Not a git repository")
    write_run_summary "$SUMMARY_FILE" "$OVERALL_STATUS" "$UPSTREAM_STATUS" "$TRACKING_STATUS" "$INTERFACE_STATUS" "$CRON_LOG" ERRORS
    exit 1
fi

# pixi.lock is regenerated by every pixi solve/install and is transient churn in the
# cron-managed working tree; discard it so a lock-file-only diff does not abort the
# whole sync at the clean-state gate (and so later branch checkouts do not fail with
# "local changes would be overwritten").
git -C "$REPO_PATH" checkout -- pixi.lock 2>/dev/null || true

# Check for clean state (cron should never run on dirty trees)
if ! ensure_clean_state; then
    log_error "Working directory is dirty - cron sync requires clean state"
    OVERALL_STATUS=1
    ERRORS+=("Working directory not clean")
    write_run_summary "$SUMMARY_FILE" "$OVERALL_STATUS" "$UPSTREAM_STATUS" "$TRACKING_STATUS" "$INTERFACE_STATUS" "$CRON_LOG" ERRORS
    exit 1
fi

# Defensive: clear stale .git/index.lock from any prior interrupted run
clear_stale_git_index_lock "$REPO_PATH" 60 || true
clear_stale_submodule_index_locks "$REPO_PATH" 60 || true

###############################################################################
# Step 1a: Upstream Fetch + Local Fast-Forward
# --------------------------------------------
# Fast-forward local development to upstream/development without checkout.
# This avoids "unable to rmdir sub-packages/*" errors from switching away
# from branches that have submodules (bleeding-edge/ci-base).
# Push is deferred to Step 1b, after the upstream gate (Step 1.5) passes.
###############################################################################
PRE_FF_DEV_SHA=""
if [ "$SKIP_UPSTREAM" = false ]; then
    log_section "$(colorize "$BLUE" "Step 1a: Upstream Fetch + Local Fast-Forward")"

    # Check if upstream remote exists
    if ! git remote get-url upstream > /dev/null 2>&1; then
        UPSTREAM_STATUS="skipped"
        log_operation "No 'upstream' remote configured — skipping"
        log_result true "Upstream sync skipped (no remote)"
    else
        # Fetch latest upstream/development
        if git fetch upstream development > /dev/null 2>&1; then
            log_operation "Fetched upstream/development"

            # Check if local development can fast-forward to upstream
            if git merge-base --is-ancestor development upstream/development 2>/dev/null; then
                # Capture pre-FF SHA for potential rollback in Step 1.5
                PRE_FF_DEV_SHA=$(git rev-parse development 2>/dev/null || true)
                # Fast-forward: update local ref without checkout
                git branch -f development upstream/development 2>/dev/null
                log_operation "Fast-forwarded local development (pre-FF: ${PRE_FF_DEV_SHA:0:12})"
                UPSTREAM_STATUS="pass"
                log_result true "Step 1a: Fast-forward completed"
            elif git merge-base --is-ancestor upstream/development development 2>/dev/null; then
                # Local is already ahead or at upstream — nothing to do
                UPSTREAM_STATUS="pass"
                log_operation "Local development already up to date with upstream"
                log_result true "Step 1a: Already current (no FF needed)"
            else
                # Local development has diverged from upstream — needs manual attention
                UPSTREAM_STATUS="diverged"
                ERRORS+=("Local development has diverged from upstream — manual rebase needed")
                log_result false "Development diverged from upstream"
                OVERALL_STATUS=1
            fi
        else
            UPSTREAM_STATUS="failed"
            ERRORS+=("Failed to fetch upstream/development")
            log_result false "Upstream fetch failed"
            OVERALL_STATUS=1
        fi
    fi
else
    log_step "Upstream sync: skipped (--skip-upstream)"
fi

###############################################################################
# Step 1.5: Upstream-gate enforcement (selected tests must pass before push)
# ------------------------------------------------------------------------------
# Runs select_tests.py --mode upstream against the post-FF development to
# determine which tests are at risk. Then runs pixi pytest on the selected
# set. On failure: reset local development to pre-FF SHA, abort the push,
# next cron tick retries with the same diff (idempotent).
# Reference: hummingbot_ai_docs/2026-06-06-diff-driven-test-selection.md
###############################################################################
UPSTREAM_GATE_STATUS="skipped"
UPSTREAM_GATE_LOG="${CRON_LOG_DIR}/upstream_gate_${TIMESTAMP}.log"
UPSTREAM_GATE_PYTEST_LOG="${CRON_LOG_DIR}/upstream_gate_pytest_${TIMESTAMP}.log"
UPSTREAM_GATE_TEST_LIST="${CRON_LOG_DIR}/upstream_gate_testlist_${TIMESTAMP}.txt"
SELECT_TESTS_SCRIPT="${REPO_PATH}/.github/test-selection/select_tests.py"
SELECT_TESTS_CONFIG="${REPO_PATH}/.github/test-selection/test-selection-map.yaml"
SELECT_TESTS_STATE="${SCRIPT_DIR}/../state/select_tests_state.json"
UPSTREAM_GATE_TIMEOUT="20m"

if [ "$UPSTREAM_STATUS" != "pass" ]; then
    log_step "Step 1.5: Upstream gate skipped — Step 1a did not succeed"
elif ! command -v python3 >/dev/null 2>&1 || [ ! -f "$SELECT_TESTS_SCRIPT" ]; then
    log_step "Step 1.5: Upstream gate skipped — selector unavailable"
    UPSTREAM_GATE_STATUS="skipped"
else
    log_section "$(colorize "$BLUE" "Step 1.5: Upstream gate (enforcement)")"
    mkdir -p "$(dirname "$SELECT_TESTS_STATE")"

    # 1. Selector: get the test list
    if pixi run --frozen --manifest-path "$REPO_PATH/pyproject.toml" python "$SELECT_TESTS_SCRIPT" \
        --mode upstream \
        --config "$SELECT_TESTS_CONFIG" \
        --state-file "$SELECT_TESTS_STATE" \
        --repo "$REPO_PATH" \
        > "$UPSTREAM_GATE_TEST_LIST" 2> "$UPSTREAM_GATE_LOG"; then
        SELECTOR_EXIT=0
    else
        SELECTOR_EXIT=$?
    fi

    if [ "$SELECTOR_EXIT" -eq 0 ]; then
        # Filter blank lines and shadow markers
        TEST_FILES=$(grep -v '^#' "$UPSTREAM_GATE_TEST_LIST" | grep -v '^[[:space:]]*$' || true)
        TEST_COUNT=$(echo "$TEST_FILES" | grep -c '^[^[:space:]]' || true)
        if [ -z "$TEST_FILES" ] || [ "$TEST_COUNT" -eq 0 ]; then
            log_result true "Selector returned 0 tests — nothing to gate"
            UPSTREAM_GATE_STATUS="pass"
            clear_stale_git_index_lock "$REPO_PATH" 0 || true
            clear_stale_submodule_index_locks "$REPO_PATH" 0 || true
        else
            log_step "Selector chose $TEST_COUNT tests; running via pixi pytest (timeout ${UPSTREAM_GATE_TIMEOUT})"
            # Convert newline-delimited file list to args for pytest
            cd "$REPO_PATH" || true
            if timeout "$UPSTREAM_GATE_TIMEOUT" pixi run --frozen pytest \
                --quiet --tb=short $TEST_FILES \
                > "$UPSTREAM_GATE_PYTEST_LOG" 2>&1; then
                UPSTREAM_GATE_STATUS="pass"
                log_result true "Upstream gate pytest: PASS ($TEST_COUNT tests, see $(basename "$UPSTREAM_GATE_PYTEST_LOG"))"
                clear_stale_git_index_lock "$REPO_PATH" 0 || true
                clear_stale_submodule_index_locks "$REPO_PATH" 0 || true
            else
                PYTEST_EXIT=$?
                UPSTREAM_GATE_STATUS="fail"
                ERRORS+=("Upstream gate pytest FAILED (exit=$PYTEST_EXIT, $TEST_COUNT tests); see $UPSTREAM_GATE_PYTEST_LOG")
                log_result false "Upstream gate pytest: FAIL (exit=$PYTEST_EXIT) — see $(basename "$UPSTREAM_GATE_PYTEST_LOG")"
                [ "$OVERALL_STATUS" -eq 0 ] && OVERALL_STATUS=1
                # Roll back local development to pre-FF state
                if [ -n "$PRE_FF_DEV_SHA" ]; then
                    DIRTY=$(git -C "$REPO_PATH" status --porcelain --untracked-files=no 2>/dev/null | head -1)
                    if [ -n "$DIRTY" ]; then
                        log_result false "Working tree DIRTY at reset time — refusing to reset development; manual inspection needed"
                        ERRORS+=("Step 1.5 reset skipped: working tree dirty; first dirty entry: $DIRTY")
                    else
                        log_step "Working tree clean — resetting development to pre-FF SHA $PRE_FF_DEV_SHA"
                        git -C "$REPO_PATH" branch -f development "$PRE_FF_DEV_SHA" \
                            >> "$UPSTREAM_GATE_LOG" 2>&1 || \
                            ERRORS+=("Failed to roll back development to $PRE_FF_DEV_SHA")
                    fi
                fi
                clear_stale_git_index_lock "$REPO_PATH" 0 || true
                clear_stale_submodule_index_locks "$REPO_PATH" 0 || true
            fi
        fi
    elif [ "$SELECTOR_EXIT" -eq 2 ]; then
        # Escape-hatch: too many selected tests; fall back to full suite
        log_step "Selector emitted escape-hatch (exit 2); running full suite via pixi pytest"
        cd "$REPO_PATH" || true
        if timeout "$UPSTREAM_GATE_TIMEOUT" pixi run --frozen pytest \
            --quiet --tb=short \
            > "$UPSTREAM_GATE_PYTEST_LOG" 2>&1; then
            UPSTREAM_GATE_STATUS="pass"
            log_result true "Upstream gate full-suite pytest: PASS"
            clear_stale_git_index_lock "$REPO_PATH" 0 || true
            clear_stale_submodule_index_locks "$REPO_PATH" 0 || true
        else
            PYTEST_EXIT=$?
            UPSTREAM_GATE_STATUS="fail"
            ERRORS+=("Upstream gate full-suite pytest FAILED (exit=$PYTEST_EXIT); see $UPSTREAM_GATE_PYTEST_LOG")
            log_result false "Upstream gate full-suite pytest: FAIL (exit=$PYTEST_EXIT)"
            [ "$OVERALL_STATUS" -eq 0 ] && OVERALL_STATUS=1
            if [ -n "$PRE_FF_DEV_SHA" ]; then
                DIRTY=$(git -C "$REPO_PATH" status --porcelain --untracked-files=no 2>/dev/null | head -1)
                if [ -n "$DIRTY" ]; then
                    log_result false "Working tree DIRTY at reset time — refusing to reset development; manual inspection needed"
                    ERRORS+=("Step 1.5 reset skipped: working tree dirty; first dirty entry: $DIRTY")
                else
                    log_step "Working tree clean — resetting development to pre-FF SHA $PRE_FF_DEV_SHA"
                    git -C "$REPO_PATH" branch -f development "$PRE_FF_DEV_SHA" \
                        >> "$UPSTREAM_GATE_LOG" 2>&1 || \
                        ERRORS+=("Failed to roll back development to $PRE_FF_DEV_SHA")
                fi
            fi
            clear_stale_git_index_lock "$REPO_PATH" 0 || true
            clear_stale_submodule_index_locks "$REPO_PATH" 0 || true
        fi
    else
        UPSTREAM_GATE_STATUS="fail"
        ERRORS+=("Selector failed with exit=$SELECTOR_EXIT; see $UPSTREAM_GATE_LOG")
        log_result false "Selector failed (exit=$SELECTOR_EXIT); aborting push"
        [ "$OVERALL_STATUS" -eq 0 ] && OVERALL_STATUS=1
        clear_stale_git_index_lock "$REPO_PATH" 0 || true
        clear_stale_submodule_index_locks "$REPO_PATH" 0 || true
    fi
fi

###############################################################################
# Step 1b: Push development to origin
# ------------------------------------
# Only executes when the upstream gate passed (or was skipped because no new
# content arrived). Gate failure means tests are broken; push is withheld and
# local development is rolled back to pre-FF SHA. Next cron tick retries.
###############################################################################
if [ "$UPSTREAM_GATE_STATUS" = "pass" ] || [ "$UPSTREAM_GATE_STATUS" = "skipped" ]; then
    if [ "$SKIP_UPSTREAM" = false ] && [ "$UPSTREAM_STATUS" = "pass" ]; then
        log_section "$(colorize "$BLUE" "Step 1b: Push development to origin")"
        if git push origin development > /dev/null 2>&1; then
            UPSTREAM_STATUS="success"
            log_result true "Upstream sync completed (push OK)"
        else
            UPSTREAM_STATUS="failed"
            ERRORS+=("Failed to push development to origin")
            log_result false "Push to origin failed"
            OVERALL_STATUS=1
        fi
    fi
else
    log_step "Step 1b: Push skipped — upstream gate did not pass"
fi

###############################################################################
# Note: Step 2 runs regardless of Step 1.5 (upstream-gate) outcome.
# Gate failure blocks the push (Step 1b) but does NOT block branch-tracking.
# Branch tracking advances ci-base independent of upstream changes —
# decoupling lets the cron self-heal: a failing gate that's waiting on a
# branch in branch-tracking.yaml will pass once Step 2 merges that branch.
###############################################################################
# Step 2: Branch Tracking
###############################################################################
if [ "$SKIP_TRACKING" = false ]; then
    log_section "$(colorize "$BLUE" "Step 2: Branch Tracking")"

    clear_stale_git_index_lock "$REPO_PATH" 60 || log_step "Stale-lock cleanup unsuccessful; Step 2 may still hit lock"
    clear_stale_submodule_index_locks "$REPO_PATH" 60 || true

    if [ -x "$SCRIPT_DIR/hummingbot-branch-tracking.sh" ]; then
        if "$SCRIPT_DIR/hummingbot-branch-tracking.sh"; then
            TRACKING_STATUS="success"
            log_result true "Branch tracking completed"
        else
            TRACKING_STATUS="failed"
            ERRORS+=("Branch tracking failed")
            log_result false "Branch tracking failed"
            # Merge conflicts = exit 2
            [ $OVERALL_STATUS -eq 0 ] && OVERALL_STATUS=2
        fi
    else
        TRACKING_STATUS="not found"
        ERRORS+=("hummingbot-branch-tracking.sh not found or not executable")
        log_error "Branch tracking script not available"
        indent_pop
    fi
else
    log_step "Branch tracking: skipped (--skip-tracking)"
fi

###############################################################################
# Step 2.5: Sync submodule working trees to bumped gitlinks
# ---------------------------------------------------------
# Branch tracking only updates the parent repo's submodule POINTERS (gitlinks).
# Submodule working trees remain at the old SHAs until explicitly updated.
# Without this step, downstream checks (e.g. compat-check) see stale sub-package
# content, masking the actual current state of bumped sub-packages.
###############################################################################
if [ "$SKIP_TRACKING" = false ] && [ "$TRACKING_STATUS" = "success" ]; then
    log_section "$(colorize "$BLUE" "Step 2.5: Sync Submodule Working Trees")"

    if cd "$REPO_PATH" 2>/dev/null; then
        log_operation "Running git submodule update --recursive --force..."
        if git submodule update --recursive --force; then
            SUBMODULE_SYNC_STATUS="pass"
            log_result true "Submodule working trees synced"
        else
            SUBMODULE_SYNC_STATUS="FAIL"
            ERRORS+=("Submodule sync failed; subsequent checks may operate on stale content")
            log_result false "Submodule sync failed"
            [ $OVERALL_STATUS -eq 0 ] && OVERALL_STATUS=1
        fi
    else
        SUBMODULE_SYNC_STATUS="error (cannot cd to $REPO_PATH)"
        log_error "Cannot cd to $REPO_PATH — skipping submodule sync"
    fi
else
    log_step "Submodule sync: skipped (tracking not run or failed)"
fi

###############################################################################
# Step 2.75: Cython Build
# -----------------------
# Build in-place .so extensions so interface check (Step 4) and future
# test-selection gate can import Cython-backed modules. SHA marker over
# .pyx + .pxd content plus the active Python ABI tag — skips rebuild when
# nothing has changed since the last successful build. On failure: marks
# CYTHON_BUILD_STATUS=FAIL, records an error, and sets OVERALL_STATUS=1;
# execution continues to later steps (no exit), and Step 4 gates on this
# status instead of probing against a possibly-stale .so.
###############################################################################
CYTHON_BUILD_STATUS="skipped"
CYTHON_SHA_MARKER="${CRON_LOG_DIR}/cython_build_sha.txt"

if [ "$SKIP_TRACKING" = false ] && [ "$TRACKING_STATUS" = "success" ]; then
    log_section "$(colorize "$BLUE" "Step 2.75: Cython Build")"

    # Hash all .pyx + .pxd content; prefix with Python ABI tag so a Python
    # version bump invalidates the marker even when source is unchanged.
    PYTHON_ABI_TAG=$(cd "$REPO_PATH" && pixi run --frozen python -c "import sys; print(f'cpython-{sys.version_info.major}{sys.version_info.minor}')" 2>/dev/null || echo "unknown")
    PYX_FILES=$(find "$REPO_PATH/hummingbot" \( -name "*.pyx" -o -name "*.pxd" \) 2>/dev/null | sort)
    if [ -z "$PYX_FILES" ]; then
        CURRENT_PYX_SHA="${PYTHON_ABI_TAG}:no-pyx"
    else
        CURRENT_PYX_SHA="${PYTHON_ABI_TAG}:$(echo "$PYX_FILES" | xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}')"
    fi
    STORED_PYX_SHA=""
    [ -f "$CYTHON_SHA_MARKER" ] && STORED_PYX_SHA=$(cat "$CYTHON_SHA_MARKER")

    if [ -n "$STORED_PYX_SHA" ] && [ "$CURRENT_PYX_SHA" = "$STORED_PYX_SHA" ]; then
        CYTHON_BUILD_STATUS="skipped (no .pyx/.pxd changes)"
        log_step "Cython build: skipped (sources unchanged, ABI tag $PYTHON_ABI_TAG)"
        log_result true "Cython build unchanged"
    else
        log_operation "Running: pixi run build (ABI tag $PYTHON_ABI_TAG)"
        if ! cd "$REPO_PATH"; then
            CYTHON_BUILD_STATUS="FAIL"
            ERRORS+=("Cython build: cd to REPO_PATH failed")
            log_result false "Cython build: cd to $REPO_PATH failed"
            [ "$OVERALL_STATUS" -eq 0 ] && OVERALL_STATUS=1
        elif pixi run --frozen build >> "$CRON_LOG" 2>&1; then
            echo "$CURRENT_PYX_SHA" > "$CYTHON_SHA_MARKER"
            CYTHON_BUILD_STATUS="pass"
            log_result true "Cython build succeeded"
        else
            CYTHON_BUILD_STATUS="FAIL"
            ERRORS+=("Cython build failed - interface check will probe stale .so")
            log_result false "Cython build failed (see log)"
            [ "$OVERALL_STATUS" -eq 0 ] && OVERALL_STATUS=1
        fi
    fi
else
    log_step "Cython build: skipped (tracking not run or failed)"
fi

###############################################################################
# Step 3: Modularization Health Checks
# -------------------------------------
# Runs after bleeding-edge has the modularization pixi tasks available.
# Non-fatal: failures accumulate in MODULAR_FAILURES but do not set OVERALL_STATUS
# (these checks are advisory until tach.toml is fully populated).
###############################################################################
MODULAR_STATUS="skipped"
MODULAR_FAILURES=0
COMPAT_RESULT="skipped"
BOUNDARY_RESULT="skipped"

if [ "$SKIP_TRACKING" = false ] && [ "$TRACKING_STATUS" = "success" ]; then
    log_section "$(colorize "$BLUE" "Step 3: Modularization Health Checks")"

    if cd "$REPO_PATH" 2>/dev/null; then
        # compat-check: now covers all 14 sub-packages
        log_operation "Running compat-check (all sub-packages)..."
        if pixi run --frozen compat-check; then
            COMPAT_RESULT="pass"
            log_result true "compat-check passed"
        else
            COMPAT_RESULT="FAIL"
            MODULAR_FAILURES=$((MODULAR_FAILURES + 1))
            log_result false "compat-check failed"
        fi

        # lint-boundaries: import-linter boundary check
        log_operation "Running lint-boundaries (import-linter)..."
        if pixi run --frozen lint-boundaries; then
            BOUNDARY_RESULT="pass"
            log_result true "lint-boundaries passed"
        else
            BOUNDARY_RESULT="FAIL"
            MODULAR_FAILURES=$((MODULAR_FAILURES + 1))
            log_result false "lint-boundaries failed"
        fi

        # dep-graph snapshot dropped 2026-06-08 — superseded by import-linter boundary check above.
        # If drift detection is desired, add pydeps integration in a follow-up.

        if [ $MODULAR_FAILURES -eq 0 ]; then
            MODULAR_STATUS="pass"
        else
            MODULAR_STATUS="FAIL ($MODULAR_FAILURES check(s) failed)"
            ERRORS+=("Modularization health: $MODULAR_FAILURES check(s) failed")
            # Advisory only — do not escalate OVERALL_STATUS here
        fi
    else
        MODULAR_STATUS="error (cannot cd to $REPO_PATH)"
        log_error "Cannot cd to $REPO_PATH — skipping modularization checks"
        indent_pop
    fi
else
    log_step "Modularization health checks: skipped (tracking not run or failed)"
fi

###############################################################################
# Step 3b: Read branch-merge-failure artifact (Defect B)
# --------------------------------------------------------------------------
# hummingbot-branch-tracking.sh's own exit code (TRACKING_STATUS above) only
# reflects whether the SCRIPT completed, not whether every individual branch
# merge succeeded — sync_branch()'s return value used to be discarded at
# both call sites. branch_merge_failures.txt is written UNCONDITIONALLY by
# main() (even with zero failures), so a missing file means the run never
# reached that point rather than "no failures".
#
# Deliberately placed AFTER Steps 2.5/2.75/3 (which gate on the literal
# string "success") and BEFORE the TRACKING_STATUS mutation below — Step 4
# does not key off TRACKING_STATUS, so this is the last safe point to rewrite
# it before write_run_summary without breaking any `[ "$TRACKING_STATUS" =
# "success" ]` gate upstream.
###############################################################################
MERGE_FAILURES_FILE="$RUN_LOG_DIR/branch_merge_failures.txt"
MERGE_ATTEMPTED=0
MERGE_FAILURES=0
if [ -f "$MERGE_FAILURES_FILE" ]; then
    _mf_header="$(head -n 1 "$MERGE_FAILURES_FILE")"
    _mf_attempted="$(echo "$_mf_header" | grep -oE 'attempted=[0-9]+' | cut -d= -f2 || true)"
    _mf_failed="$(echo "$_mf_header" | grep -oE 'failed=[0-9]+' | cut -d= -f2 || true)"
    [ -n "$_mf_attempted" ] && MERGE_ATTEMPTED="$_mf_attempted"
    [ -n "$_mf_failed" ] && MERGE_FAILURES="$_mf_failed"
fi

if [ "$TRACKING_STATUS" = "success" ] && [ "$MERGE_FAILURES" -gt 0 ] 2>/dev/null; then
    TRACKING_STATUS="success, ${MERGE_FAILURES} of ${MERGE_ATTEMPTED} branches failed"
fi

###############################################################################
# Step 4: Interface Compatibility Check
###############################################################################
if [ "$SKIP_INTERFACE" = false ] && { [ "$CYTHON_BUILD_STATUS" = "pass" ] || [ "$CYTHON_BUILD_STATUS" = "skipped (no .pyx/.pxd changes)" ]; }; then
    log_section "$(colorize "$BLUE" "Step 4: Interface Check")"

    if [ -x "$SCRIPT_DIR/hummingbot-interface-check.sh" ]; then
        if "$SCRIPT_DIR/hummingbot-interface-check.sh"; then
            INTERFACE_STATUS="compatible"
            log_result true "Interface check passed"
        else
            iface_exit=$?
            if [ $iface_exit -eq 2 ]; then
                INTERFACE_STATUS="breaking changes"
                ERRORS+=("Breaking interface changes detected")
                log_result false "Breaking interface changes detected"
                [ $OVERALL_STATUS -eq 0 ] && OVERALL_STATUS=2
            else
                INTERFACE_STATUS="error"
                ERRORS+=("Interface check failed (exit $iface_exit)")
                log_result false "Interface check error"
                [ $OVERALL_STATUS -eq 0 ] && OVERALL_STATUS=1
            fi
        fi
    else
        INTERFACE_STATUS="not found"
        ERRORS+=("hummingbot-interface-check.sh not found or not executable")
        log_error "Interface check script not available"
        indent_pop
    fi
elif [ "$SKIP_INTERFACE" = false ]; then
    INTERFACE_STATUS="skipped (Cython build unavailable)"
    log_step "Interface check: skipped (Cython build did not run — result would be unreliable)"
else
    log_step "Interface check: skipped (--skip-interface)"
fi

###############################################################################
# Wrap Up
###############################################################################
log_footer

write_run_summary "$SUMMARY_FILE" "$OVERALL_STATUS" "$UPSTREAM_STATUS" "$TRACKING_STATUS" "$INTERFACE_STATUS" "$CRON_LOG" ERRORS "$MERGE_FAILURES"

# Append submodule sync detail (written after write_run_summary to avoid overwrite)
if [ "$SUBMODULE_SYNC_STATUS" != "skipped" ]; then
    {
        echo ""
        echo "Submodule sync: $SUBMODULE_SYNC_STATUS"
    } >> "$SUMMARY_FILE"
fi

# Append Cython build detail
if [ "$CYTHON_BUILD_STATUS" != "skipped" ]; then
    {
        echo ""
        echo "Cython build: $CYTHON_BUILD_STATUS"
    } >> "$SUMMARY_FILE"
fi

# Append upstream gate detail
if [ "$UPSTREAM_GATE_STATUS" != "skipped" ]; then
    {
        echo ""
        echo "Upstream gate: ${UPSTREAM_GATE_STATUS}"
    } >> "$SUMMARY_FILE"
fi

# Append modularization health detail (written after write_run_summary to avoid overwrite)
if [ "$MODULAR_STATUS" != "skipped" ]; then
    {
        echo ""
        echo "Modularization Health:"
        echo "  Compat-check (all sub-packages): $COMPAT_RESULT"
        echo "  Lint-boundaries (import-linter): $BOUNDARY_RESULT"
        echo "  Overall:                         $MODULAR_STATUS"
    } >> "$SUMMARY_FILE"
fi

# Append branch merge failures detail (written after write_run_summary to avoid overwrite).
# Body lines from branch_merge_failures.txt are re-indented by 2 spaces here so the
# "<branch> -> <target>" / "  <reason>" pairs nest visibly under this block's own header.
if [ "$MERGE_FAILURES" -gt 0 ] 2>/dev/null; then
    {
        echo ""
        echo "Branch merge failures (${MERGE_FAILURES}):"
        tail -n +2 "$MERGE_FAILURES_FILE" | sed 's/^/  /'
    } >> "$SUMMARY_FILE"
fi

# Display summary
echo ""
cat "$SUMMARY_FILE"

# Send desktop notification if requested
if [ "$DO_NOTIFY" = true ]; then
    if [ $OVERALL_STATUS -eq 0 ]; then
        send_notification "Hummingbot Sync" "Sync completed successfully"
    elif [ $OVERALL_STATUS -eq 2 ]; then
        send_notification "Hummingbot Sync" "Conflicts need attention. Check ${SUMMARY_FILE}"
    else
        send_notification "Hummingbot Sync" "Sync failed. Check ${SUMMARY_FILE}"
    fi
fi

exit $OVERALL_STATUS
