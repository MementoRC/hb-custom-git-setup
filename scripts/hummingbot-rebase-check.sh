#!/bin/bash
###############################################################################
# hummingbot-rebase-check.sh
# --------------------------
# Dry-run rebase test using git worktrees. Complements the merge-based branch
# tracker by testing whether tracked branches can cleanly rebase onto
# bleeding-edge without actually modifying any branch refs.
#
# For each enabled branch in branch-tracking.yaml:
#   1. Creates a temporary worktree
#   2. Attempts rebase onto bleeding-edge
#   3. Reports CLEAN / CONFLICT
#   4. Cleans up worktree (never modifies actual branches)
#
# Exit codes: 0=all clean, 1=error, 2=conflicts found
#
# Usage:
#   ./hummingbot-rebase-check.sh [--branch <name>] [--verbose]
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

###############################################################################
# Configuration
###############################################################################
: "${FEATURE_BRANCH:="bleeding-edge"}"
WORKTREE_BASE="${CUSTOM_GIT_PATH}/.worktrees"
REPORT_FILE="${LOG_PATH}/rebase_report_latest.txt"
VERBOSE=false
SINGLE_BRANCH=""

# Tracking
CLEAN_BRANCHES=()
CONFLICT_BRANCHES=()
SKIPPED_BRANCHES=()
ERROR_BRANCHES=()

###############################################################################
# Parse Arguments
###############################################################################
while [[ $# -gt 0 ]]; do
    case $1 in
        --branch)   SINGLE_BRANCH="$2"; shift 2 ;;
        --verbose)  VERBOSE=true; shift ;;
        --help)
            echo "Usage: $0 [--branch <name>] [--verbose]"
            echo ""
            echo "Options:"
            echo "  --branch <name>  Test a single branch instead of all tracked"
            echo "  --verbose        Show detailed rebase output"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

###############################################################################
# Worktree Helpers
###############################################################################
create_worktree() {
    local branch="$1"
    local worktree_path="$2"

    # Clean up any stale worktree at this path
    if [ -d "$worktree_path" ]; then
        git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi

    # Create worktree with a detached HEAD at the branch
    git worktree add --detach "$worktree_path" "$branch" 2>/dev/null
    return $?
}

cleanup_worktree() {
    local worktree_path="$1"
    if [ -d "$worktree_path" ]; then
        # Abort any in-progress rebase in the worktree
        git -C "$worktree_path" rebase --abort 2>/dev/null || true
        git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi
}

cleanup_all_worktrees() {
    if [ -d "$WORKTREE_BASE" ]; then
        for wt in "$WORKTREE_BASE"/rebase-check-*; do
            [ -d "$wt" ] && cleanup_worktree "$wt"
        done
        rmdir "$WORKTREE_BASE" 2>/dev/null || true
    fi
    # Prune stale worktree references
    git worktree prune 2>/dev/null || true
}

###############################################################################
# Rebase Test for Single Branch
###############################################################################
test_rebase_branch() {
    local branch="$1"
    local target="$2"
    local safe_name
    safe_name="$(echo "$branch" | tr '/' '-')"
    local worktree_path="${WORKTREE_BASE}/rebase-check-${safe_name}"

    log_section "Testing: $branch"

    # Verify branch exists
    local location
    location=$(branch_exists "$branch")
    if [ "$location" = "none" ]; then
        log_error "Branch does not exist: $branch"
        SKIPPED_BRANCHES+=("$branch (not found)")
        indent_pop
        return 0
    fi

    # Fetch if remote-only
    if [ "$location" = "remote" ]; then
        log_step "Fetching remote branch"
        git fetch origin "$branch" >/dev/null 2>&1 || {
            log_error "Failed to fetch $branch"
            ERROR_BRANCHES+=("$branch (fetch failed)")
            indent_pop
            return 1
        }
    fi

    # Resolve the actual ref
    local ref="$branch"
    [ "$location" = "remote" ] && ref="origin/$branch"

    # Check if already ancestor (nothing to rebase)
    if git merge-base --is-ancestor "$ref" "$target" 2>/dev/null; then
        log_step "Already merged into $target"
        CLEAN_BRANCHES+=("$branch (already merged)")
        log_result true "Nothing to rebase"
        return 0
    fi

    # Create worktree at the branch's tip
    log_step "Creating worktree"
    mkdir -p "$WORKTREE_BASE"
    if ! create_worktree "$ref" "$worktree_path"; then
        log_error "Failed to create worktree"
        ERROR_BRANCHES+=("$branch (worktree failed)")
        cleanup_worktree "$worktree_path"
        indent_pop
        return 1
    fi

    # Attempt rebase onto target
    log_step "Rebasing onto $target"
    local rebase_output
    rebase_output=$(git -C "$worktree_path" rebase "$target" 2>&1)
    local rebase_status=$?

    if [ $rebase_status -eq 0 ]; then
        # Count commits that would be replayed
        local commit_count
        commit_count=$(git -C "$worktree_path" log --oneline "$target"..HEAD 2>/dev/null | wc -l)
        CLEAN_BRANCHES+=("$branch ($commit_count commits)")
        log_result true "CLEAN - $commit_count commits rebase cleanly"
    else
        # Extract conflict info
        local conflict_files=""
        if [ "$VERBOSE" = true ]; then
            log_detail "Rebase output:"
            echo "$rebase_output" | while IFS= read -r line; do
                log_detail "  $line"
            done
        fi

        # List conflicting files from the worktree
        conflict_files=$(git -C "$worktree_path" diff --name-only --diff-filter=U 2>/dev/null | head -10)
        if [ -n "$conflict_files" ]; then
            CONFLICT_BRANCHES+=("$branch|$conflict_files")
            log_error "Conflicting files:"
            echo "$conflict_files" | while IFS= read -r f; do
                log_detail "  $f"
            done
        else
            CONFLICT_BRANCHES+=("$branch|unknown")
        fi

        log_result false "CONFLICT"
    fi

    # Always cleanup
    cleanup_worktree "$worktree_path"
    return 0
}

###############################################################################
# Report
###############################################################################
write_report() {
    cat > "$REPORT_FILE" <<EOF
Rebase Compatibility Report
============================
Date:     $(date '+%Y-%m-%d %H:%M:%S')
Target:   ${FEATURE_BRANCH}
Commit:   $(git rev-parse --short "$FEATURE_BRANCH" 2>/dev/null || echo "unknown")

EOF

    echo "Clean (${#CLEAN_BRANCHES[@]}):" >> "$REPORT_FILE"
    if [ ${#CLEAN_BRANCHES[@]} -gt 0 ]; then
        for b in "${CLEAN_BRANCHES[@]}"; do
            echo "  [OK] $b" >> "$REPORT_FILE"
        done
    else
        echo "  (none)" >> "$REPORT_FILE"
    fi
    echo "" >> "$REPORT_FILE"

    echo "Conflicts (${#CONFLICT_BRANCHES[@]}):" >> "$REPORT_FILE"
    if [ ${#CONFLICT_BRANCHES[@]} -gt 0 ]; then
        for entry in "${CONFLICT_BRANCHES[@]}"; do
            local branch="${entry%%|*}"
            local files="${entry#*|}"
            echo "  [CONFLICT] $branch" >> "$REPORT_FILE"
            echo "$files" | tr ',' '\n' | while IFS= read -r f; do
                [ -n "$f" ] && echo "    - $f" >> "$REPORT_FILE"
            done
        done
    else
        echo "  (none)" >> "$REPORT_FILE"
    fi
    echo "" >> "$REPORT_FILE"

    if [ ${#SKIPPED_BRANCHES[@]} -gt 0 ]; then
        echo "Skipped (${#SKIPPED_BRANCHES[@]}):" >> "$REPORT_FILE"
        for b in "${SKIPPED_BRANCHES[@]}"; do
            echo "  [SKIP] $b" >> "$REPORT_FILE"
        done
        echo "" >> "$REPORT_FILE"
    fi

    if [ ${#ERROR_BRANCHES[@]} -gt 0 ]; then
        echo "Errors (${#ERROR_BRANCHES[@]}):" >> "$REPORT_FILE"
        for b in "${ERROR_BRANCHES[@]}"; do
            echo "  [ERR] $b" >> "$REPORT_FILE"
        done
        echo "" >> "$REPORT_FILE"
    fi
}

###############################################################################
# Main Execution
###############################################################################
log_header "$(colorize "$BLUE" "Rebase Compatibility Check")"

# Ensure we're in the repo
cd "$REPO_PATH" || {
    log_error "Failed to change to repository directory: $REPO_PATH"
    exit 1
}

if ! check_git_repo; then
    exit 1
fi

# Ensure clean state (worktree operations need it)
if ! ensure_clean_state; then
    log_error "Working directory must be clean for rebase check"
    exit 1
fi

# Trap to ensure worktree cleanup on exit/interrupt
trap cleanup_all_worktrees EXIT INT TERM

log_step "Target branch: $FEATURE_BRANCH"
log_step "Worktree base: $WORKTREE_BASE"

if [ -n "$SINGLE_BRANCH" ]; then
    # Test a single branch
    test_rebase_branch "$SINGLE_BRANCH" "$FEATURE_BRANCH"
else
    # Validate environment for YAML parsing
    if ! check_yq; then
        exit 1
    fi
    if [ ! -f "$BRANCH_CONFIG" ]; then
        log_error "Branch config not found: $BRANCH_CONFIG"
        exit 1
    fi

    # Read all enabled branches from config
    while IFS= read -r target_branch; do
        [ -z "$target_branch" ] && continue

        log_section "$(colorize "$BLUE" "Target: $target_branch")"

        while IFS= read -r branch; do
            [ -z "$branch" ] && continue

            enabled="$(yq -r ".target_branches[\"$target_branch\"].tracked_branches[] | select(.name == \"$branch\").enabled" "$BRANCH_CONFIG" 2>/dev/null)"

            if [ "$enabled" = "true" ]; then
                test_rebase_branch "$branch" "$target_branch"
            else
                SKIPPED_BRANCHES+=("$branch (disabled)")
                if [ "$VERBOSE" = true ]; then
                    log_step "Skipped (disabled): $branch"
                fi
            fi
        done < <(yq -r ".target_branches[\"$target_branch\"].tracked_branches[].name" "$BRANCH_CONFIG" 2>/dev/null)

        indent_pop
    done < <(yq -r '.target_branches | keys[]' "$BRANCH_CONFIG" 2>/dev/null)
fi

# Write report
write_report

log_footer

# Display summary
echo ""
echo "Results:"
echo "  Clean:    ${#CLEAN_BRANCHES[@]}"
echo "  Conflict: ${#CONFLICT_BRANCHES[@]}"
echo "  Skipped:  ${#SKIPPED_BRANCHES[@]}"
echo "  Error:    ${#ERROR_BRANCHES[@]}"
echo ""
echo "Report: $REPORT_FILE"

# Exit code based on conflicts
if [ ${#CONFLICT_BRANCHES[@]} -gt 0 ]; then
    exit 2
elif [ ${#ERROR_BRANCHES[@]} -gt 0 ]; then
    exit 1
else
    exit 0
fi
