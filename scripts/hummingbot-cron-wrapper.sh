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
# Step 3: Interface Compatibility Check
###############################################################################
if [ "$SKIP_INTERFACE" = false ]; then
    log_section "$(colorize "$BLUE" "Step 3: Interface Check")"

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
