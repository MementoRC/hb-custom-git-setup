#!/bin/bash
###############################################################################
# common.sh
# ---------
# This file is a utility library of shared environment variables and functions.
# It is meant to be sourced (not run directly) by other scripts.
#
# Usage:
#   source /path/to/common.sh
###############################################################################

###############################################################################
# 1) Environment Variables (Overridable)
###############################################################################
: "${REPO_PATH:=/home/memento/PycharmProjects/Hummingbot/hummingbot}"
: "${CUSTOM_GIT_PATH:=$REPO_PATH/../custom_git_setup}"
: "${CONFIG_PATH:=$CUSTOM_GIT_PATH/configs}"
: "${LOG_PATH:=$CUSTOM_GIT_PATH/logs}"
: "${BRANCH_CONFIG:=$CONFIG_PATH/branch-tracking.yaml}"

: "${BRANCH_LOG:=$LOG_PATH/branch_tracker.log}"
: "${TEST_LOG:=$LOG_PATH/test_verification.log}"
: "${STATUS_LOG:=$LOG_PATH/branch_status.log}"

# Run-scoped log grouping: inherit RUN_ID from a parent invocation (cron wrapper) if exported,
# else generate one. All logs for a single rebuild/cron invocation accumulate under this dir.
RUN_ID="${RUN_ID:-$(date '+%Y%m%d_%H%M%S')}"
export RUN_ID
RUN_LOG_DIR="${LOG_PATH}/runs/${RUN_ID}"
export RUN_LOG_DIR
mkdir -p "$RUN_LOG_DIR"
ln -sfn "$RUN_LOG_DIR" "${LOG_PATH}/runs/latest"

###############################################################################
# 2) PATH Configuration for Cron Environments
###############################################################################
# Ensure conda-managed tools (pixi) are reachable under cron's minimal PATH.
# /opt/conda/bin holds the pixi binary on this host; cron does not inherit
# the user's interactive PATH, so prepend it explicitly. Idempotent: only
# prepends when not already present.
case ":${PATH}:" in
    *:/opt/conda/bin:*) ;;
    *) export PATH="/opt/conda/bin:${PATH}" ;;
esac

###############################################################################
# 3) Color & Indentation Definitions
###############################################################################
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly BOX_TL="╔"
readonly BOX_TR="╗"
readonly BOX_BL="╚"
readonly BOX_BR="╝"
readonly BOX_H="═"
readonly BOX_V="║"
readonly BRANCH_CHAR="├"
readonly LAST_BRANCH_CHAR="└"
readonly PIPE="│"
readonly ARROW="→"

###############################################################################
# 3) Directory & File Setup
###############################################################################
# ensure_directories
# ------------------
# Creates the directories for BRANCH_CONFIG and STATUS_LOG if they don't exist.
###############################################################################
ensure_directories() {
    local paths=("$BRANCH_CONFIG" "$STATUS_LOG")
    for p in "${paths[@]}"; do
        local dir
        dir="$(dirname "$p")"
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir" || {
                echo -e "${RED}Failed to create directory: $dir${NC}"
                return 1
            }
        fi
    done
}

###############################################################################
# 4) Logging & Status Functions
###############################################################################
# log_message
# -----------
# Logs a message (with timestamp) both to stdout (in color) and appends to
# STATUS_LOG.
###############################################################################
log_message() {
    local message="$1"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "$timestamp: $message" | tee -a "$STATUS_LOG"
}

colorize() {
    local color="$1"
    local text="$2"
    echo -e "${color}${text}${NC}"
}

visible_length() {
    local text="$1"
    echo "${text}" | sed 's/\x1B\[[0-9;]*[JKmsu]//g' | wc -c
}

# Enhanced logging functions
log_header() {
    local msg="$1"
    local width=80
    local visible_msg=$(echo "$msg" | sed 's/\x1B\[[0-9;]*[JKmsu]//g')
    local padding=$(( (width - ${#visible_msg} - 4) / 2 ))
    local padding_left=$padding
    local padding_right=$padding
    [ $(( ${#visible_msg} % 2 )) -eq 1 ] && ((padding_right++))

    echo
    echo "${BOX_TL}$(printf "%${padding_left}s" "" | sed "s/ /${BOX_H}/g")[ ${msg} ]$(printf "%${padding_right}s" "" | sed "s/ /${BOX_H}/g")${BOX_TR}"
}

log_footer() {
    local width=80
    echo "${BOX_BL}$(printf "%${width}s" "" | sed "s/ /${BOX_H}/g")${BOX_BR}"
    echo
}

log_section() {
    local msg="$1"
    echo "$(get_indent)${BRANCH_CHAR}${BOX_H} ${msg}"
    indent_push
}

log_step() {
    local msg="$1"
    echo "$(get_indent)${BRANCH_CHAR}${ARROW} ${msg}"
}

log_result() {
    local success=$1
    local msg="$2"
    if [ "$success" = true ]; then
        echo "$(get_indent)${LAST_BRANCH_CHAR}${ARROW} $(colorize "$GREEN" "✓ $msg")"
    else
        echo "$(get_indent)${LAST_BRANCH_CHAR}${ARROW} $(colorize "$RED" "✗ $msg")"
    fi
    indent_pop
}

log_operation() {
    local msg="$1"
    echo -e "$(get_indent)${BRANCH_CHAR}  $(colorize "$BLUE" "$msg")"
}

log_warning() {
    local msg="$1"
    echo -e "$(get_indent)${BRANCH_CHAR}  $(colorize "$YELLOW" "$msg")"
}

log_error() {
    local msg="$1"
    echo -e "$(get_indent)${BRANCH_CHAR}  $(colorize "$RED" "$msg")"
}

log_detail() {
    local msg="$1"
    echo "$(get_indent)${PIPE}     ${msg}"
}

###############################################################################
# update_status
# -------------
# Overwrites STATUS_LOG with a new header for this script run.
###############################################################################
update_status() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    {
        echo "Status Report - $timestamp"
        echo "================================="
        echo ""
    } > "$STATUS_LOG"
}

###############################################################################
# add_status_entry
# ----------------
# Appends a block describing a branch operation/status to STATUS_LOG.
###############################################################################
add_status_entry() {
    local target="$1"
    local branch="$2"
    local status="$3"
    local details="$4"
    {
        echo -e "\nTarget: $target"
        echo "Branch: $branch"
        echo "Status: $status"
        echo "Details: $details"
        echo "---"
    } >> "$STATUS_LOG"
}

###############################################################################
# 5) yq & YAML Helper Functions
###############################################################################
# check_yq
# --------
# Ensures the 'yq' command is present. If not, logs an error.
###############################################################################
check_yq() {
    if ! command -v yq &> /dev/null; then
        log_message "${RED}yq is required but not installed (try: sudo apt-get install yq).${NC}"
        return 1
    fi
    return 0
}

###############################################################################
# read_yaml_value
# ---------------
# Reads a value from a YAML file using yq. 
# Usage: read_yaml_value .path.to.key config_file.yaml
###############################################################################
read_yaml_value() {
    local path="$1"
    local config_file="${2:-$BRANCH_CONFIG}"
    local result
    
    if ! check_yq; then
        return 1
    fi
    
    result="$(yq -r "$path" "$config_file" 2>/dev/null)"
    echo "$result"
}

###############################################################################
# 6) Git Environment Validation
###############################################################################
# check_git_repo
# --------------
# Confirms that we're inside a valid git repository (git rev-parse works).
###############################################################################
check_git_repo() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_message "${RED}Not in a git repository${NC}"
        return 1
    fi
    return 0
}

ensure_clean_state() {
    if ! git diff --quiet --ignore-submodules || ! git diff --cached --quiet --ignore-submodules; then
        log_error "Working directory is not clean. Please commit or stash your changes."
        git status --short --ignore-submodules
        return 1
    fi
    return 0
}

git_quiet() {
    local output
    output=$(eval "git $*" 2>&1) || {
        local status=$?
        echo "$output" | grep -v "^hint:" >&2
        return $status
    }
    # Only show output that doesn't match common git messages
    echo "$output" | grep -Ev "^(Already on |Switched to |Your branch is )"
}

git_operation() {
    local operation="$1"
    shift
    local output

    # Log the command being executed (debug mode)
    if [ "${DEBUG:-false}" = "true" ]; then
        log_detail "Executing: git $operation $*"
    fi

    output=$(git $operation "$@" 2>&1)
    local status=$?

    if [ $status -ne 0 ]; then
        log_error "Git $operation failed:"
        log_detail "Command: git $operation $*"
        log_detail "Output: $output"
        return $status
    fi

    # Only show non-standard git messages
    echo "$output" | grep -Ev "^(Already on |Switched to |Your branch is |hint: |warning: )"
    return 0
}

branch_exists() {
    local branch="$1"
    if git_operation rev-parse --verify "$branch" >/dev/null 2>&1; then
        echo "local"
    elif git_operation ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
        echo "remote"
    else
        echo "none"
    fi
}

###############################################################################
# 7) Overall Environment Validation
###############################################################################
# validate_environment
# --------------------
# Ensures that REPO_PATH is valid, that we are in a git repo, yq is installed,
# and BRANCH_CONFIG exists.
###############################################################################
validate_environment() {
    local errors=0
    
    if [ ! -d "$REPO_PATH" ]; then
        log_message "${RED}Repository directory not found: $REPO_PATH${NC}"
        errors=$((errors + 1))
    fi
    
    if ! check_git_repo; then
        errors=$((errors + 1))
    fi
    
    if ! check_yq; then
        errors=$((errors + 1))
    fi
    
    if [ ! -f "$BRANCH_CONFIG" ]; then
        log_message "${RED}Configuration file not found: $BRANCH_CONFIG${NC}"
        errors=$((errors + 1))
    fi
    
    return $errors
}

###############################################################################
# 8) Usage Example (Optional)
###############################################################################
# show_usage
# ----------
# Simple usage instructions for scripts that source this file.
###############################################################################
show_usage() {
    local script_name="$1"
    echo "Usage: $script_name [options]"
    echo "Options:"
    echo "  --config PATH    Use custom config file"
    echo "  --log PATH       Use custom log file"
    echo "  --help           Show this help message"
}

###############################################################################
# 9) Indenting functions
###############################################################################
indent_push() { ((INDENT_LEVEL++)); }
indent_pop() { ((INDENT_LEVEL--)); }
get_indent() { printf "%${INDENT_LEVEL}s" "" | sed "s/ /  /g"; }

###############################################################################
# 10) Shared Summary Writer
###############################################################################
# write_run_summary <target_file> <overall_status> <upstream_status> <tracking_status> <interface_status> <log_path> [errors_array_name]
#
# Writes a structured run-summary file. Used by both cron-wrapper (logs/cron/latest_summary.txt)
# and branch-tracking --rebuild (logs/manual_rebuild_latest.txt).
#
# Args:
#   target_file       - output file path (will be overwritten)
#   overall_status    - integer exit code (0=clean, 2=conflicts, other=error)
#   upstream_status   - human label for upstream sync phase, or "n/a"
#   tracking_status   - human label for branch tracking phase, or "n/a"
#   interface_status  - human label for interface check phase, or "n/a"
#   log_path          - path to the underlying log file (or "(stdout)" for manual)
#   errors_array_name - OPTIONAL: name of a bash array variable containing error strings
write_run_summary() {
    local target_file="$1"
    local overall_status="$2"
    local upstream_status="${3:-n/a}"
    local tracking_status="${4:-n/a}"
    local interface_status="${5:-n/a}"
    local log_path="${6:-(stdout)}"
    local errors_var="${7:-}"

    local end_time
    end_time="$(date '+%Y-%m-%d %H:%M:%S')"

    local overall_label
    if [ "$overall_status" -eq 0 ]; then
        overall_label="CLEAN"
    elif [ "$overall_status" -eq 2 ]; then
        overall_label="CONFLICTS"
    else
        overall_label="ERROR"
    fi

    cat > "$target_file" <<EOF
Hummingbot Sync Summary
========================
Run:        $(date '+%Y%m%d_%H%M%S')
Completed:  ${end_time}
Overall:    ${overall_label}

Steps:
  Upstream Sync:     ${upstream_status}
  Branch Tracking:   ${tracking_status}
  Interface Check:   ${interface_status}
EOF

    if [ -n "$errors_var" ]; then
        local -n errors_ref="$errors_var"
        if [ ${#errors_ref[@]} -gt 0 ]; then
            echo "" >> "$target_file"
            echo "Issues:" >> "$target_file"
            for err in "${errors_ref[@]}"; do
                echo "  - ${err}" >> "$target_file"
            done
        fi
    fi

    echo "" >> "$target_file"
    echo "Log: ${log_path}" >> "$target_file"

    # Also copy the summary into the run-scoped log dir for per-run retention.
    cp -f "$target_file" "$RUN_LOG_DIR/summary.txt" 2>/dev/null || true
}

###############################################################################
# 9) Prevent Direct Execution
###############################################################################
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "This script (common.sh) should be sourced, not executed directly."
    echo "Usage: source ${BASH_SOURCE[0]}"
    exit 1
fi

