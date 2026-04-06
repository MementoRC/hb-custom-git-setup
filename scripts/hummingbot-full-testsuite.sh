#!/bin/bash -i
###############################################################################
# test_feature_branch.sh
# ----------------------
# This script performs a full test run on a specified feature branch.
#   1. Optionally stashes any local changes.
#   2. Checks out the feature branch.
#   3. Runs a compile/build/test step (by default, a full pytest run).
#   4. Restores local changes (if stashed).
#
# Usage:
#   ./test_feature_branch.sh [branch_name]
#
# Example:
#   ./test_feature_branch.sh bleeding-edge
###############################################################################

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"

###############################################################################
# Overridable Variables
###############################################################################
: "${FEATURE_BRANCH:="bleeding-edge"}"
: "${LOCAL_REPO_DIR:="$HOME/PycharmProjects/Hummingbot/hummingbot"}"

###############################################################################
# handle_working_changes
# ----------------------
# Checks for unstaged/untracked files and stashes them if necessary, saving
# the stash info in STASH_MESSAGE.
###############################################################################
handle_working_changes() {
    CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

    # Check for untracked files
    UNTRACKED_FILES="$(git ls-files --others --exclude-standard)"
    if [ -n "$UNTRACKED_FILES" ]; then
        log_message "${YELLOW}Found untracked files:${NC}"
        log_message "$UNTRACKED_FILES"
    fi

    # If we have any changes or untracked files, stash them
    if ! git diff --quiet HEAD || [ -n "$UNTRACKED_FILES" ]; then
        STASH_MESSAGE="AUTO_TEST_$(date +%Y%m%d_%H%M%S)_${CURRENT_BRANCH}"
        log_message "${YELLOW}Stashing all changes (including untracked)...${NC}"
        if ! git stash push --include-untracked -m "$STASH_MESSAGE"; then
            log_message "${RED}Failed to stash changes${NC}"
            exit 1
        fi
        STASHED=true
    else
        STASHED=false
    fi
}

###############################################################################
# restore_working_state
# ---------------------
# If changes were stashed, attempts to pop them back. Switches back to the
# original branch if needed.
###############################################################################
restore_working_state() {
    if [ "$STASHED" = true ]; then
        log_message "${YELLOW}Restoring your working changes...${NC}"
        if [ -n "$CURRENT_BRANCH" ]; then
            if ! git checkout "$CURRENT_BRANCH"; then
                log_message "${RED}Failed to switch back to $CURRENT_BRANCH${NC}"
                log_message "${YELLOW}Your changes remain stashed with: $STASH_MESSAGE${NC}"
                exit 1
            fi
            if ! git stash pop; then
                log_message "${RED}Failed to restore stashed changes.${NC}"
                log_message "${YELLOW}They remain in stash: $STASH_MESSAGE${NC}"
                exit 1
            fi
        fi
    else
        # If no stash but we changed branches, go back
        if [ -n "$CURRENT_BRANCH" ]; then
            git checkout "$CURRENT_BRANCH" >/dev/null 2>&1
        fi
    fi
}

###############################################################################
# run_full_feature_test
# ---------------------
# Performs a full test run on the given feature branch. Adjust commands (pytest,
# coverage, build steps, etc.) as needed.
###############################################################################
run_full_feature_test() {
    local branch="$1"

    log_message "${YELLOW}Switching to branch [$branch] to run tests...${NC}"
    if ! git checkout "$branch"; then
        log_message "${RED}Failed to checkout branch [$branch].${NC}"
        exit 1
    fi

    log_message "${YELLOW}Running full test suite for [$branch]...${NC}"
    # Example: run Pytest across entire hummingbot code
    # You could add coverage flags, e.g.:
    #   pytest --cov=hummingbot --cov-report=term-missing
    if ! ( ./compile && make test ); then
        log_message "${RED}Tests FAILED for branch [$branch].${NC}"
        exit 1
    fi

    log_message "${GREEN}All tests PASSED for branch [$branch].${NC}"
}

###############################################################################
# Main Execution
###############################################################################
log_message "${YELLOW}Starting feature-branch test script...${NC}"

# 1) If the user supplied a branch name as an argument, override FEATURE_BRANCH
if [ -n "$1" ]; then
    FEATURE_BRANCH="$1"
fi

conda activate hummingbot

# 2) Ensure directories exist, change to REPO_PATH
ensure_directories

cd "$REPO_PATH" || {
    log_message "${RED}Failed to change to repository directory: $REPO_PATH${NC}"
    exit 1
}

# 3) Validate environment (optional if you rely on common checks)
if ! validate_environment; then
    log_message "${RED}Environment validation failed.${NC}"
    exit 1
fi

# 4) Stash changes, run tests on the feature branch, restore changes
handle_working_changes
run_full_feature_test "$FEATURE_BRANCH"
restore_working_state

log_message "${GREEN}Feature-branch test script completed successfully!${NC}"
exit 0

