#!/bin/bash
###############################################################################
# hummingbot-docs.sh
# -----------------
# This script helps to manage the development documentation for Hummingbot.
#
# Usage:
#   ./hummingbot-docs.sh
###############################################################################

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"

TEMP_DIR="${SCRIPT_DIR}/.tmp"
TEMP_LOG="${TEMP_DIR}/test_output.log"

readonly DOC_PATTERNS='\.(md|rst|txt|svg)$'
readonly PYTEST_PATTERNS='^pytest_tests/.*\.py$'

###############################################################################
# Overridable Variables
###############################################################################
: "${DEVELOPMENT_BRANCH:="development"}"
: "${FEATURE_BRANCH:="bleeding-edge"}"
: "${LOCAL_REPO_DIR:="$HOME/PycharmProjects/Hummingbot/hummingbot"}"

###############################################################################
# Documentation Management Functions
###############################################################################

validate_branch_name() {
    local branch="$1"
    local pattern="^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+$"

    if [[ ! "$branch" =~ $pattern ]]; then
        log_error "Invalid branch name format: $branch"
        log_detail "Expected format: <tag>/<feature>"
        log_detail "Allowed characters: a-z A-Z 0-9 _ -"
        log_detail "Example: feat/my-feature"
        return 1
    fi
    return 0
}

get_no_docs_branch_name() {
    local branch="$1"
    local tag prefix
    IFS='/' read -r tag prefix <<< "$branch"
    echo "_hb_${tag}/${prefix}"
}

check_branch_state() {
    local branch="$1"
    local location

    location=$(branch_exists "$branch")
    case "$location" in
        "none")
            return 0
            ;;
        "local")
            log_warning "Branch '$branch' already exists locally"
            ;;
        "remote")
            log_warning "Branch '$branch' exists in remote"
            git_operation fetch origin "$branch"
            ;;
    esac

    return 1
}

remove_temp_files() {
    local source_branch="$1"
    local pattern="$2"
    local description="$3"

    # Get files from both branches
    local current_files
    current_files=$(git ls-files | grep -E "$pattern" || true)

    local dev_files
    dev_files=$(git ls-tree -r --name-only "$DEVELOPMENT_BRANCH" | grep -E "$pattern" || true)

    # Find files unique to current branch
    local files_to_remove=""
    while IFS= read -r file; do
        if ! echo "$dev_files" | grep -q "^${file}$"; then
            files_to_remove+="${file}"$'\n'
        fi
    done < <(echo "$current_files")

    # Trim trailing newline
    files_to_remove=$(echo "$files_to_remove" | sed '/^$/d')

    if [ -n "$files_to_remove" ]; then
        log_operation "New $description files to remove:"
        echo "$files_to_remove" | while IFS= read -r file; do
            log_detail "○ $file (not in $DEVELOPMENT_BRANCH)"
        done

        # Remove files
        local failed=0
        while IFS= read -r file; do
            if [ -f "$file" ]; then
                if ! git_operation rm "$file" >& /dev/null ; then
                    log_error "Failed to remove: $file"
                    failed=1
                fi
            fi
        done < <(echo "$files_to_remove")

        [ "$failed" -eq 1 ] && return 1

        if ! git_operation commit -m "chore: Remove new $description files (not in $DEVELOPMENT_BRANCH)" >& /dev/null; then
            log_error "Failed to commit $description removal"
            return 1
        fi

        log_result true "$description files removed successfully"
    else
        log_result true "No new $description files found (compared to $DEVELOPMENT_BRANCH)"
    fi

    return 0
}

preview_files_to_remove() {
    local source_branch="$1"
    local pattern="$2"
    local description="$3"

    # Get files from both branches
    local current_files dev_files
    current_files=$(git ls-files | grep -E "$pattern" || true)
    dev_files=$(git ls-tree -r --name-only "$DEVELOPMENT_BRANCH" | grep -E "$pattern" || true)

    # Show statistics
    log_operation "$description files summary:"
    log_detail "Total in current branch: $(echo "$current_files" | wc -l)"
    log_detail "Total in $DEVELOPMENT_BRANCH: $(echo "$dev_files" | wc -l)"

    # Find and show new files
    log_operation "Files that would be removed:"
    local found=0
    while IFS= read -r file; do
        if ! echo "$dev_files" | grep -q "^${file}$"; then
            log_detail "○ $file"
            found=1
        fi
    done < <(echo "$current_files")

    [ "$found" -eq 0 ] && log_detail "None"
}

prepare_pr_branch() {
    local source_branch="$1"
    local target_branch="$2"

    log_section "$(colorize "$BLUE" "Preparing PR branch (no docs)")"

    # Preview all changes first
    log_section "Documentation Analysis"
    preview_files_to_remove "$source_branch" "$DOC_PATTERNS" "documentation"
    log_result true "Done"

    log_section "Pytest Files Analysis"
    preview_files_to_remove "$source_branch" "$PYTEST_PATTERNS" "pytest"
    log_result true "Done"

    # Check if target branch already exists
    if ! check_branch_state "$target_branch"; then
        log_warning "Target branch already exists. Options:"
        log_detail "1. Use existing branch (--force to overwrite)"
        log_detail "2. Choose a different name"
        return 1
    fi

    # Checkout source branch
    log_operation "Checking out source branch: $source_branch"
    if ! git_operation checkout "$source_branch"; then
        log_error "Failed to checkout source branch"
        return 1
    fi

    # Create new branch
    log_operation "Creating PR branch: $target_branch"
    if ! git_operation checkout -b "$target_branch"; then
        log_error "Failed to create PR branch"
        return 1
    fi

    # Remove files
    log_section "Removing Documentation"
    if ! remove_temp_files "$source_branch" "$DOC_PATTERNS" "documentation"; then
        log_error "Failed to remove documentation"
        return 1
    fi

    log_section "Removing Pytest Files"
    if ! remove_temp_files "$source_branch" "$PYTEST_PATTERNS" "pytest"; then
        log_error "Failed to remove pytest files"
        return 1
    fi

    if ! git_operation checkout "$source_branch"; then
        log_error "Failed to revert to source branch"
        return 1
    fi

    log_result true "PR branch prepared successfully"
    return 0
}

###############################################################################
# Main Execution
###############################################################################

main() {
    log_header "$(colorize "$BLUE" "Documentation Management Script")"

    # Initial setup
    ensure_directories || exit 1
    update_status || exit 1

    # Change to repository directory
    cd "$REPO_PATH" || {
        log_error "Failed to change to repository directory: $REPO_PATH"
        exit 1
    }

    # Validate environment
    if ! validate_environment; then
        log_error "Environment validation failed"
        exit 1
    fi

    # Parse arguments
    local FORCE=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --prepare-pr)
                if [ -z "$2" ]; then
                    log_error "Branch name is required"
                    exit 1
                fi
                BRANCH_NAME="$2"
                shift 2
                ;;
            --force)
                FORCE=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                log_detail "Usage: $0 --prepare-pr <branch-name> [--force]"
                exit 1
                ;;
        esac
    done

    # Validate branch name
    if ! validate_branch_name "$BRANCH_NAME"; then
        exit 1
    fi

    # Ensure clean working directory
    if ! ensure_clean_state; then
        log_error "Working directory is not clean"
        exit 1
    fi

    # Get no-docs branch name
    NO_DOCS_BRANCH=$(get_no_docs_branch_name "$BRANCH_NAME")

    # Handle existing branch
    if [ "$FORCE" = true ]; then
        if branch_exists "$NO_DOCS_BRANCH"; then
            log_warning "Removing existing branch: $NO_DOCS_BRANCH"
            git_operation branch -D "$NO_DOCS_BRANCH" >& /dev/null
        fi
    fi

    # Prepare PR branch
    if ! prepare_pr_branch "$BRANCH_NAME" "$NO_DOCS_BRANCH"; then
        log_error "Failed to prepare PR branch"
        exit 1
    fi

    log_operation "Next steps:"
    log_detail "1. Review changes in $NO_DOCS_BRANCH"
    log_detail "2. Push to remote: git push origin $NO_DOCS_BRANCH"

    exit 0
}

main "$@"
