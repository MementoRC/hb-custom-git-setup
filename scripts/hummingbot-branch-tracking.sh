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
handle_new_files() {
    local untracked
    # Exclude sub-packages/ (submodules managed by own branch) and tool configs (.serena/, .mcp.json)
    untracked=$(git ls-files --others --exclude-standard | grep -Ev '^(sub-packages/|\.serena/|\.mcp\.json)')
    if [ -n "$untracked" ]; then
        log_operation "Adding new files..."
        git ls-files --others --exclude-standard -z | grep -zEv '^(sub-packages/|\.serena/|\.mcp\.json)' | xargs -0 -r git add
        # Skip hooks — these are auto-added files from merges, not user code
        git -c commit.gpgsign=false commit --no-verify -m "Auto-add new files" >& /dev/null || return 1
    fi
    return 0
}

###############################################################################
# Branch Operations
###############################################################################
check_mergeability() {
    local branch="$1"
    local target="$2"

    # Store current branch
    local current_branch
    current_branch=$(git_quiet rev-parse --abbrev-ref HEAD)

    # Make sure working directory is clean
    if ! git diff --quiet || ! git diff --cached --quiet; then
        log_error "Cannot check mergeability with uncommitted changes"
        return 1
    fi

    # Switch to target branch
    git checkout "$target" >& /dev/null || {
        log_error "Failed to checkout $target"
        git checkout "$current_branch"
        return 1
    }

    # Try merge with --no-commit
    if git merge --no-commit --no-ff "$branch" >& /dev/null; then
        git merge --abort 2> /dev/null
        git checkout "$current_branch" 2> /dev/null
        return 0
    else
        log_error "$branch has conflicts with $target"
        git_quiet merge --abort
        git_quiet checkout "$current_branch"
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
    local source_branch="$2"

    log_section "$(colorize "$BLUE" "Running tests")"

    local test_script="${SCRIPT_DIR}/hummingbot-select-test-verifier.sh"
    if [ ! -x "$test_script" ]; then
        log_error "Test script not found or not executable"
        indent_pop
        return 1
    fi

    # Get git changes
    local git_changes
    git_changes=$(git_quiet show --stat HEAD)
    parse_git_changes "$git_changes"

    # Run tests — pass source branch so verifier can check only branch-specific changes
    "$test_script" "origin/$DEVELOPMENT_BRANCH" "$target_branch" "$source_branch" > "${TEMP_LOG}" 2>&1
    local test_exit_code=$?

    cat "${TEMP_LOG}"
    # Check for test failures
    if grep -q "FAILED" "${TEMP_LOG}"; then
        log_error "Test failures detected"
        while IFS= read -r line; do
            if [[ $line =~ FAILED ]]; then
                log_detail "✗ ${line}"
            fi
        done < "${TEMP_LOG}"
        indent_pop
        return 1
    fi

    # Check for missing tests
    extract_missing_tests "${TEMP_LOG}"
    local missing_tests_status=$?
    if [ $missing_tests_status -eq 1 ]; then
        log_warning "Some files need test coverage"
    fi

    # If there were changes but all tests passed
    if grep -q "All tests passed" "${TEMP_LOG}"; then
        log_detail "All existing tests passed"
    fi

    if [ $missing_tests_status -eq 1 ]; then
        log_warning "Merge allowed but tests should be added"
        indent_pop
        return 0
    fi

    if [ $test_exit_code -eq 0 ]; then
        indent_pop
        return 0
    else
        indent_pop
        return 1
    fi
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

    # Check mergeability with development (skip during rebuild — _for_bleed
    # branches are bleeding-edge-only and may not merge into development)
    if [ "$target" = "$FEATURE_BRANCH" ] && [ "$REBUILD_MODE" != "true" ]; then
        check_mergeability "$branch" "$DEVELOPMENT_BRANCH" || {
            log_error "Mergeability check failed"
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

    if git merge --no-ff "$ref" -m "Auto-merge $branch into $target" >& /dev/null; then
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
        indent_pop
        return 0
    else
        git_quiet merge --abort
        log_result false "Merge failed"
        indent_pop
        return 1
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
      ensure_clean_state || exit 1
      log_section "$(colorize "$YELLOW" "Rebuilding")"

      log_operation "Checkout development branch"
      git_quiet checkout "$DEVELOPMENT_BRANCH"
      log_operation "Delete feature branch"
      git_quiet branch -D "$FEATURE_BRANCH" >& /dev/null
      log_operation "Create feature branch"
      git_quiet checkout -b "$FEATURE_BRANCH"

      # Clean up embedded git repos left over from prior feature branch.
      # development doesn't have .gitmodules, so sub-packages/ dirs from
      # the old bleeding-edge persist as embedded repos and break git add.
      if [ -d "sub-packages" ]; then
          log_operation "Clean embedded sub-package repos"
          find sub-packages -maxdepth 2 -name ".git" -exec rm -rf {} + 2>/dev/null
          rm -rf sub-packages/*/
      fi

      # Ensure the new branch is properly initialized
      log_operation "Initialize feature branch"
      git commit --allow-empty -m "Initialize $FEATURE_BRANCH" >& /dev/null || {
          log_error "Failed to initialize feature branch"
          exit 1
      }
      log_result true "Rebuild complete"
  fi

  # For each target branch in the config
  while IFS= read -r target_branch; do
      [ -z "$target_branch" ] && continue

      log_section "$(colorize "$BLUE" "Processing target branch: $target_branch")"

      # For each tracked branch under that target
      while IFS= read -r branch; do
          [ -z "$branch" ] && continue

          enabled="$(is_branch_enabled "$target_branch" "$branch")"
          permanent="$(is_branch_permanent "$target_branch" "$branch")"
          feature_only="$(is_branch_feature_only "$target_branch" "$branch")"

          if [ "$enabled" = "true" ]; then
              sync_branch "$target_branch" "$branch"
              log_step "Branch $branch processed"
          fi
      done < <(get_tracked_branches "$target_branch")
      indent_pop

  done < <(get_target_branches)

  log_step "Branch tracking completed successfully!"
}

main "$@"
