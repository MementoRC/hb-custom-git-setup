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

# Check for clean state (cron should never run on dirty trees)
if ! ensure_clean_state; then
    log_error "Working directory is dirty - cron sync requires clean state"
    OVERALL_STATUS=1
    ERRORS+=("Working directory not clean")
    write_run_summary "$SUMMARY_FILE" "$OVERALL_STATUS" "$UPSTREAM_STATUS" "$TRACKING_STATUS" "$INTERFACE_STATUS" "$CRON_LOG" ERRORS
    exit 1
fi

###############################################################################
# Step 1: Upstream Sync
# ---------------------
# Fast-forward local development to upstream/development without checkout.
# This avoids "unable to rmdir sub-packages/*" errors from switching away
# from branches that have submodules (bleeding-edge/ci-base).
###############################################################################
if [ "$SKIP_UPSTREAM" = false ]; then
    log_section "$(colorize "$BLUE" "Step 1: Upstream Sync")"

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
                # Fast-forward: update local ref without checkout
                git branch -f development upstream/development 2>/dev/null
                log_operation "Fast-forwarded local development"

                # Push updated development to origin
                if git push origin development > /dev/null 2>&1; then
                    UPSTREAM_STATUS="success"
                    log_result true "Upstream sync completed"
                else
                    UPSTREAM_STATUS="failed"
                    ERRORS+=("Failed to push development to origin")
                    log_result false "Push to origin failed"
                    OVERALL_STATUS=1
                fi
            elif git merge-base --is-ancestor upstream/development development 2>/dev/null; then
                # Local is already ahead or at upstream — nothing to do
                UPSTREAM_STATUS="success"
                log_operation "Local development already up to date with upstream"
                log_result true "Upstream sync completed (already current)"
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
# Step 2: Branch Tracking
###############################################################################
if [ "$SKIP_TRACKING" = false ]; then
    log_section "$(colorize "$BLUE" "Step 2: Branch Tracking")"

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
# nothing has changed since the last successful build. Fatal failure mode:
# a build error aborts the rebuild instead of silently leaving stale .so.
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
DEP_GRAPH_DIFF="skipped"

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

        # lint-boundaries: tach boundary check (stub config initially)
        log_operation "Running lint-boundaries (tach)..."
        if pixi run --frozen lint-boundaries; then
            BOUNDARY_RESULT="pass"
            log_result true "lint-boundaries passed"
        else
            BOUNDARY_RESULT="FAIL"
            MODULAR_FAILURES=$((MODULAR_FAILURES + 1))
            log_result false "lint-boundaries failed"
        fi

        # dep-graph: snapshot for drift detection
        log_operation "Running dep-graph snapshot..."
        DEP_GRAPH_OUT="${CRON_LOG_DIR}/dep_graph_latest.json"
        DEP_GRAPH_PREV="${CRON_LOG_DIR}/dep_graph_prev.json"
        [ -f "$DEP_GRAPH_OUT" ] && mv "$DEP_GRAPH_OUT" "$DEP_GRAPH_PREV"
        if pixi run --frozen dep-graph > "$DEP_GRAPH_OUT" 2>&1; then
            if [ -f "$DEP_GRAPH_PREV" ]; then
                DEP_GRAPH_DIFF=$(diff -q "$DEP_GRAPH_PREV" "$DEP_GRAPH_OUT" 2>&1 || echo "changed")
            else
                DEP_GRAPH_DIFF="initial snapshot"
            fi
            log_result true "dep-graph snapshot: $DEP_GRAPH_DIFF"
        else
            DEP_GRAPH_DIFF="FAIL"
            MODULAR_FAILURES=$((MODULAR_FAILURES + 1))
            log_result false "dep-graph failed"
        fi

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
# Step 4: Interface Compatibility Check
###############################################################################
if [ "$SKIP_INTERFACE" = false ]; then
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
else
    log_step "Interface check: skipped (--skip-interface)"
fi

###############################################################################
# Wrap Up
###############################################################################
log_footer

write_run_summary "$SUMMARY_FILE" "$OVERALL_STATUS" "$UPSTREAM_STATUS" "$TRACKING_STATUS" "$INTERFACE_STATUS" "$CRON_LOG" ERRORS

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

# Append modularization health detail (written after write_run_summary to avoid overwrite)
if [ "$MODULAR_STATUS" != "skipped" ]; then
    {
        echo ""
        echo "Modularization Health:"
        echo "  Compat-check (all sub-packages): $COMPAT_RESULT"
        echo "  Lint-boundaries (tach):          $BOUNDARY_RESULT"
        echo "  Dep-graph diff:                  $DEP_GRAPH_DIFF"
        echo "  Overall:                         $MODULAR_STATUS"
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
