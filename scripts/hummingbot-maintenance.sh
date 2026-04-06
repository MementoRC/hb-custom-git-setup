#!/bin/bash -i
###############################################################################
# branch_maintenance.sh
# ---------------------
# This script manages a local or remote repository for development flow:
#   1. Checks or clones a repo (local or remote).
#   2. Stashes local changes.
#   3. Syncs the development branch with origin.
#   4. Merges development into a feature branch.
#   5. Restores original working state.
#
# Usage:
#   ./branch_maintenance.sh
###############################################################################

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"

###############################################################################
# Overridable Variables
###############################################################################
: "${DEVELOPMENT_BRANCH:="development"}"
: "${FEATURE_BRANCH:="bleeding-edge"}"
: "${LOCAL_REPO_DIR:="$HOME/PycharmProjects/Hummingbot/hummingbot"}"

###############################################################################
# run_full_compile_test
# ---------------------
# Demonstrates how to run a complete build/test process. Customize commands
# for your actual project (e.g. Python build, Docker build, npm install, etc.).
###############################################################################
run_full_compile_test() {
    local branch="$1"

    log_message "${YELLOW}Running full compile/test for branch [$branch]...${NC}"

    conda activate hummingbot
    ./compile || {
            log_message "${RED}Failed to compile successfully${NC}"
            return 1
        }
    make test || {
            log_message "${RED}Failed to complete the tests${NC}"
            return 1
        }
    
    log_message "${GREEN}Compile/test process completed successfully for branch [$branch].${NC}"
    return 0
}

###############################################################################
# setup_repository
# ----------------
# Checks if REPO_PATH is remote or local. Clones if necessary (for remote).
# Ensures we cd into the repository directory. Confirms it's a valid git repo.
###############################################################################
setup_repository() {
    # Check if REPO_PATH looks like a remote URL
    if [[ "$REPO_PATH" == http* ]] || [[ "$REPO_PATH" == git@* ]]; then
        # Handle remote repository
        if [ ! -d "$LOCAL_REPO_DIR/.git" ]; then
            log_message "${YELLOW}Cloning remote repository...${NC}"
            if ! git clone "$REPO_PATH" "$LOCAL_REPO_DIR"; then
                log_message "${RED}Failed to clone repository${NC}"
                exit 1
            fi
        fi
        cd "$LOCAL_REPO_DIR" || {
            log_message "${RED}Failed to change to local repo directory${NC}"
            exit 1
        }
    else
        # Handle local path (expand ~ if present)
        REPO_PATH="${REPO_PATH/#\~/$HOME}"
        if [ ! -d "$REPO_PATH/.git" ]; then
            log_message "${RED}$REPO_PATH does not appear to be a valid Git repo${NC}"
            exit 1
        fi
        cd "$REPO_PATH" || {
            log_message "${RED}Failed to change to repository directory: $REPO_PATH${NC}"
            exit 1
        }
    fi

    # Final check: confirm we are in a Git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        log_message "${RED}Not a git repository${NC}"
        exit 1
    fi
}

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
        STASH_MESSAGE="AUTO_SYNC_$(date +%Y%m%d_%H%M%S)_${CURRENT_BRANCH}"
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
    
    # Restore compiled libs
    conda activate hummingbot && ./compile
}

###############################################################################
# sync_development_upstream
# -------------------------
# 1. Ensures the 'upstream' remote is present (the official Hummingbot repo).
# 2. Fetches upstream/development.
# 3. Merges or rebases your local development branch with upstream/development.
# 4. Optionally pushes changes back to origin/development if desired.
###############################################################################
sync_development_upstream() {
    # 1) Ensure 'upstream' remote is defined
    if ! git remote get-url upstream >/dev/null 2>&1; then
        log_message "${YELLOW}Upstream remote not found. Adding it...${NC}"
        # Adjust the URL to the official Hummingbot repo
        if ! git remote add upstream "https://github.com/hummingbot/hummingbot.git"; then
            log_message "${RED}Failed to add 'upstream' remote.${NC}"
            return 1
        fi
    fi
    
    # 2) Switch to development branch if not already
    log_message "${YELLOW}Checking out local development branch [$DEVELOPMENT_BRANCH]...${NC}"
    if ! git checkout "$DEVELOPMENT_BRANCH"; then
        log_message "${RED}Failed to checkout local branch $DEVELOPMENT_BRANCH${NC}"
        return 1
    fi
    
    # 3) Fetch upstream for the development branch
    log_message "${YELLOW}Fetching upstream/$DEVELOPMENT_BRANCH...${NC}"
    if ! git fetch upstream "$DEVELOPMENT_BRANCH"; then
        log_message "${RED}Failed to fetch upstream/$DEVELOPMENT_BRANCH${NC}"
        return 1
    fi
    
    # 4) Merge or rebase upstream/development into local development
    log_message "${YELLOW}Rebasing local $DEVELOPMENT_BRANCH onto upstream/$DEVELOPMENT_BRANCH...${NC}"
    if ! git rebase "upstream/$DEVELOPMENT_BRANCH"; then
        log_message "${RED}Rebase failed or conflict. Resolve manually.${NC}"
        # Optionally abort rebase if needed:
          git rebase --abort
        return 1
    fi
    
    # 5) Optional: push updated local development branch to your origin
    # Uncomment if you want your fork's origin/development to match 
    # the official hummingbot/dev right away:
    #
    log_message "${YELLOW}Pushing updated $DEVELOPMENT_BRANCH to origin...${NC}"
    if ! git push origin "$DEVELOPMENT_BRANCH"; then
        log_message "${RED}Failed to push updated $DEVELOPMENT_BRANCH to origin${NC}"
        return 1
    fi
    
    log_message "${GREEN}Local $DEVELOPMENT_BRANCH is now up to date with upstream/$DEVELOPMENT_BRANCH${NC}"
    return 0
}

###############################################################################
# sync_development
# ----------------
# Checks out the development branch, fetches & pulls from origin.
###############################################################################
sync_development() {
    log_message "${YELLOW}Syncing development branch [$DEVELOPMENT_BRANCH]...${NC}"

    if ! git checkout "$DEVELOPMENT_BRANCH"; then
        log_message "${RED}Failed to checkout $DEVELOPMENT_BRANCH${NC}"
        exit 1
    fi

    if ! git fetch origin "$DEVELOPMENT_BRANCH"; then
        log_message "${RED}Failed to fetch origin/$DEVELOPMENT_BRANCH${NC}"
        exit 1
    fi

    if ! git pull origin "$DEVELOPMENT_BRANCH"; then
        log_message "${RED}Failed to pull latest changes for $DEVELOPMENT_BRANCH${NC}"
        exit 1
    fi

    log_message "${GREEN}Development branch [$DEVELOPMENT_BRANCH] is up to date.${NC}"
}

###############################################################################
# sync_feature_branch
# -------------------
# Checks out (or creates) the feature branch if missing, then merges
# DEVELOPMENT_BRANCH into the feature branch.
###############################################################################
sync_feature_branch() {
    log_message "${YELLOW}Syncing feature branch [$FEATURE_BRANCH] with [$DEVELOPMENT_BRANCH]...${NC}"

    # Attempt to checkout feature branch
    if ! git checkout "$FEATURE_BRANCH" 2>/dev/null; then
        log_message "${YELLOW}Feature branch [$FEATURE_BRANCH] doesn't exist. Creating...${NC}"
        if ! git checkout -b "$FEATURE_BRANCH"; then
            log_message "${RED}Failed to create feature branch [$FEATURE_BRANCH]${NC}"
            exit 1
        fi
    fi

    # Merge development into feature
    if ! git merge "$DEVELOPMENT_BRANCH"; then
        log_message "${RED}Merge conflicts detected in [$FEATURE_BRANCH].${NC}"
        log_message "${YELLOW}Please resolve conflicts manually.${NC}"
        # Not exiting so we can still restore stashed changes if needed
    else
        # Merge succeeded or did nothing (fast-forward)
        local new_head
        new_head="$(git rev-parse HEAD)"

        # If HEAD changed from the old HEAD => new commits arrived
        if [ -n "$old_head" ] && [ "$new_head" != "$old_head" ]; then
            log_message "${YELLOW}New commits have been merged into [$FEATURE_BRANCH].${NC}"
            # Now run compile/test
            if ! run_full_compile_test "$FEATURE_BRANCH"; then
                log_message "${RED}Compile/test step failed for [$FEATURE_BRANCH]: Reverting.${NC}"
                # Revert
                git reset --hard "$old_head"
                exit 1
            fi
        else
            log_message "${GREEN}No new commits were introduced into [$FEATURE_BRANCH].${NC}"
        fi
    fi
}

###############################################################################
# Main Execution
###############################################################################
log_message "${YELLOW}Starting branch maintenance...${NC}"

# 1) Ensure directories and environment
ensure_directories

# 2) cd into $REPO_PATH
cd "$REPO_PATH" || {
    log_message "${RED}Failed to change to repository directory: $REPO_PATH${NC}"
    exit 1
}

conda activate hummingbot

# 3) Validate environment
if ! validate_environment; then
    log_message "${RED}Environment validation failed.${NC}"
    exit 1
fi

# 4) Setup repository
setup_repository

# 5) Stash local changes
handle_working_changes

# 6) Sync upstream development branch
sync_development_upstream

# 6) Sync development branch
sync_feature_branch

# 7) Restore local changes
restore_working_state

log_message "${GREEN}Branch maintenance completed successfully!${NC}"
exit 0

