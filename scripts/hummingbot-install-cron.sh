#!/bin/bash
###############################################################################
# hummingbot-install-cron.sh
# --------------------------
# Idempotent crontab installer for the hummingbot sync cycle.
# Adds/replaces entries with a unique marker comment so re-running is safe.
#
# Schedule:
#   Sunday 03:00    — Full sync cycle (upstream + tracking + interface check)
#   1st of month    — Log rotation (delete logs > 30 days)
#
# Usage:
#   ./hummingbot-install-cron.sh [--remove] [--dry-run] [--notify]
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

###############################################################################
# Configuration
###############################################################################
CRON_MARKER="# hummingbot-sync"
CRON_LOG_DIR="${LOG_PATH}/cron"
WRAPPER_SCRIPT="${SCRIPT_DIR}/hummingbot-cron-wrapper.sh"

# Flags
REMOVE_ONLY=false
DRY_RUN=false
NOTIFY_FLAG=""

###############################################################################
# Parse Arguments
###############################################################################
while [[ $# -gt 0 ]]; do
    case $1 in
        --remove)   REMOVE_ONLY=true; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --notify)   NOTIFY_FLAG=" --notify"; shift ;;
        --help)
            echo "Usage: $0 [--remove] [--dry-run] [--notify]"
            echo ""
            echo "Options:"
            echo "  --remove   Remove hummingbot-sync cron entries only"
            echo "  --dry-run  Show what would be added without modifying crontab"
            echo "  --notify   Include --notify flag in cron wrapper (desktop notifications)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

###############################################################################
# Validation
###############################################################################
log_header "$(colorize "$BLUE" "Cron Installer")"

# Verify the wrapper script exists and is executable
if [ ! -f "$WRAPPER_SCRIPT" ]; then
    log_error "Wrapper script not found: $WRAPPER_SCRIPT"
    exit 1
fi

if [ ! -x "$WRAPPER_SCRIPT" ]; then
    log_warning "Making wrapper script executable"
    chmod +x "$WRAPPER_SCRIPT"
fi

# Also make other scripts executable
for script in hummingbot-maintenance.sh hummingbot-branch-tracking.sh hummingbot-interface-check.sh hummingbot-rebase-check.sh; do
    script_path="${SCRIPT_DIR}/${script}"
    if [ -f "$script_path" ] && [ ! -x "$script_path" ]; then
        chmod +x "$script_path"
    fi
done

###############################################################################
# Cron Entry Definitions
###############################################################################
# Define the cron entries
CRON_ENTRIES=(
    "0 3 * * 0 ${WRAPPER_SCRIPT}${NOTIFY_FLAG} ${CRON_MARKER}"
    "0 2 1 * * find ${CRON_LOG_DIR} -name '*.log' -mtime +30 -delete ${CRON_MARKER}"
)

###############################################################################
# Current Crontab Management
###############################################################################
get_current_crontab() {
    crontab -l 2>/dev/null || echo ""
}

remove_existing_entries() {
    local current_crontab="$1"
    # Remove lines containing our marker
    echo "$current_crontab" | grep -v "$CRON_MARKER"
}

###############################################################################
# Main Execution
###############################################################################
log_step "Reading current crontab"
CURRENT_CRONTAB=$(get_current_crontab)

# Show existing hummingbot-sync entries
EXISTING_ENTRIES=$(echo "$CURRENT_CRONTAB" | grep "$CRON_MARKER" || true)
if [ -n "$EXISTING_ENTRIES" ]; then
    log_section "Existing entries found:"
    echo "$EXISTING_ENTRIES" | while IFS= read -r line; do
        log_detail "$line"
    done
    indent_pop
else
    log_step "No existing hummingbot-sync entries found"
fi

# Remove existing entries
CLEANED_CRONTAB=$(remove_existing_entries "$CURRENT_CRONTAB")

if [ "$REMOVE_ONLY" = true ]; then
    if [ -n "$EXISTING_ENTRIES" ]; then
        if [ "$DRY_RUN" = true ]; then
            log_step "DRY RUN: Would remove existing hummingbot-sync entries"
        else
            echo "$CLEANED_CRONTAB" | crontab -
            log_result true "Removed hummingbot-sync entries"
        fi
    else
        log_step "Nothing to remove"
    fi
    log_footer
    exit 0
fi

# Build new crontab
NEW_CRONTAB="$CLEANED_CRONTAB"

# Add a blank line separator if there's existing content
if [ -n "$NEW_CRONTAB" ] && [ "$(echo "$NEW_CRONTAB" | tail -c 1)" != "" ]; then
    NEW_CRONTAB="${NEW_CRONTAB}
"
fi

# Append our entries
for entry in "${CRON_ENTRIES[@]}"; do
    NEW_CRONTAB="${NEW_CRONTAB}
${entry}"
done

# Show what will be added
log_section "$(colorize "$BLUE" "New entries:")"
for entry in "${CRON_ENTRIES[@]}"; do
    log_detail "$entry"
done
indent_pop

if [ "$DRY_RUN" = true ]; then
    log_step "DRY RUN: Would install the following crontab:"
    echo ""
    echo "$NEW_CRONTAB"
    echo ""
    log_footer
    exit 0
fi

# Install the new crontab
echo "$NEW_CRONTAB" | crontab - || {
    log_error "Failed to install crontab"
    exit 1
}

log_result true "Crontab updated successfully"

# Verify
log_section "$(colorize "$BLUE" "Verification")"
echo ""
crontab -l 2>/dev/null | grep "$CRON_MARKER" | while IFS= read -r line; do
    log_detail "$line"
done
indent_pop

log_footer

echo ""
log_step "Cron schedule installed:"
log_detail "Sunday 03:00     - Full sync cycle (upstream + tracking + interface check)"
log_detail "1st of month     - Log cleanup (>30 days)"
echo ""
log_step "Logs will be written to: ${CRON_LOG_DIR}/"
log_step "Latest summary: ${CRON_LOG_DIR}/latest_summary.txt"
echo ""
log_step "To remove: $0 --remove"
log_step "To test now: ${WRAPPER_SCRIPT}"
