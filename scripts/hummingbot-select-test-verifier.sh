#!/bin/bash -i
###############################################################################
# test_verification.sh
# --------------------
# Usage: test_verification.sh base_ref compare_ref
# Example: test_verification.sh bleeding-edge feature/my-branch
#
# This script:
#   1. Verifies that pytest is installed.
#   2. Checks out the repository (assumes $REPO_PATH is defined in common.sh).
#   3. Finds the HEAD commit in `compare_ref` (the "latest" commit).
#   4. Identifies its parent commit.
#   5. Collects the list of *.py files changed in that commit (excluding tests/).
#   6. Attempts to locate corresponding test files and runs pytest on them.
#
###############################################################################

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"

###############################################################################
# Overridable / Additional Variables
###############################################################################
: "${TEST_HISTORY_FILE:="$CONFIG_PATH/test_history.json"}"
: "${TEST_LOG:="$LOG_PATH/test_verification.log"}"
TEST_COVERAGE_THRESHOLD=80

###############################################################################
# initialize_history_file
# -----------------------
# Ensures a JSON file is present that tracks tested commits. Creates if missing.
###############################################################################
initialize_history_file() {
    if [ ! -f "$TEST_HISTORY_FILE" ]; then
        echo '{"tested_commits": {}, "last_successful_test": ""}' > "$TEST_HISTORY_FILE"
    fi
}

###############################################################################
# get_commit_status
# -----------------
# Reads commit status from $TEST_HISTORY_FILE (JSON). Returns 'success', 'failed',
# or empty if commit not recorded.
###############################################################################
get_commit_status() {
    local commit_hash="$1"
    jq -r ".tested_commits[\"$commit_hash\"].status // \"\"" "$TEST_HISTORY_FILE" 2>/dev/null
}

###############################################################################
# record_commit_status
# --------------------
# Updates the JSON with pass/fail status, date/time, and files tested. If it's a
# success, also updates `last_successful_test`.
###############################################################################
record_commit_status() {
    local commit_hash="$1"
    local new_status="$2"
    local -n file_array_ref="$3"  # nameref to the Bash array of modified files

    local date_str
    date_str="$(date -Iseconds)"  # e.g., 2025-01-17T19:23:45+00:00

    # Convert Bash array -> JSON array
    local files_json
    files_json="$(printf '%s\n' "${file_array_ref[@]}" | jq -R . | jq -s .)"

    if [ "$new_status" == "success" ]; then
        # Also update 'last_successful_test'
        jq --arg ch "$commit_hash" \
           --arg st "$new_status" \
           --arg dt "$date_str" \
           --argjson files "$files_json" \
        '
          .tested_commits[$ch] = {
            "status": $st,
            "date": $dt,
            "files_tested": $files
          }
          | .last_successful_test = $ch
        ' "$TEST_HISTORY_FILE" > "${TEST_HISTORY_FILE}.tmp"
    else
        # Just record the commit without updating last_successful_test
        jq --arg ch "$commit_hash" \
           --arg st "$new_status" \
           --arg dt "$date_str" \
           --argjson files "$files_json" \
        '
          .tested_commits[$ch] = {
            "status": $st,
            "date": $dt,
            "files_tested": $files
          }
        ' "$TEST_HISTORY_FILE" > "${TEST_HISTORY_FILE}.tmp"
    fi

    mv "${TEST_HISTORY_FILE}.tmp" "$TEST_HISTORY_FILE"
}

###############################################################################
# debug_git_info
# --------------
# Logs commit details, files changed, and diff stats for debugging.
###############################################################################
debug_git_info() {
    local commit="$1"
    
    log_message "DEBUG: Commit details for $commit:" "$TEST_LOG"
    git log -1 --pretty=format:"Hash: %h%nParent: %p%nAuthor: %an%nDate: %ad%nSubject: %s" "$commit" >> "$TEST_LOG"
    log_message "" "$TEST_LOG"
    
    log_message "DEBUG: Files changed in commit $commit:" "$TEST_LOG"
    git show --name-only --format="" "$commit" >> "$TEST_LOG"
    log_message "" "$TEST_LOG"
    
    log_message "DEBUG: Diff stats for $commit:" "$TEST_LOG"
    git diff --stat "$commit^" "$commit" >> "$TEST_LOG"
    log_message "" "$TEST_LOG"
}

###############################################################################
# find_test_module
# ----------------
# Given a .py source file, attempts to locate a corresponding test file in
# certain known patterns.
###############################################################################
find_test_module() {
    local py_file="$1"
    local module_dir
    module_dir="$(dirname "$py_file")"
    local module_name
    module_name="$(basename "$py_file" .py)"

    # Convert path to Python module notation (e.g. hummingbot/connector -> hummingbot.connector)
    local module_path="${py_file%.py}"
    module_path="${module_path#hummingbot/}"
    module_path="${module_path//\//.}"

    # Known test file paths
    local test_locations=(
        "test/${module_dir}/test_${module_name}.py"
        "test/hummingbot/${module_dir}/test_${module_name}.py"
        "test/test_${module_name}.py"
    )

    for test_file in "${test_locations[@]}"; do
        if [ -f "$test_file" ]; then
            echo "$test_file:$module_path"
            return 0
        fi
    done
    return 1
}

###############################################################################
# run_module_tests
# ----------------
# Runs pytest for a discovered test_file -> module_path pair. 
# Coverage can be toggled if needed.
###############################################################################
run_module_tests() {
    local test_info="$1"
    local test_file="${test_info%%:*}"
    local module_path="${test_info#*:}"

    log_message "${YELLOW}Testing module: $module_path${NC}" "$TEST_LOG"
    log_message "${BLUE}Using test file: $test_file${NC}" "$TEST_LOG"

    # Example coverage usage:
    # python -m pytest "$test_file" --cov="hummingbot.$module_path" --cov-fail-under="$TEST_COVERAGE_THRESHOLD" -v

    if ! python -m pytest "$test_file" -v; then
        log_message "${RED}Tests failed for $module_path${NC}" "$TEST_LOG"
        return 1
    fi

    log_message "${GREEN}Tests passed for $module_path${NC}" "$TEST_LOG"
    return 0
}

###############################################################################
# get_modified_source_files
# -------------------------
# Returns a list of changed .py files between two commits, excluding test files.
###############################################################################
get_modified_source_files() {
    local base="$1"
    local head="$2"
    git diff --name-only "$base" "$head" \
    | grep "\.py$" \
    | grep -v "^test/" || true
}

###############################################################################
# Main Script
###############################################################################
# 1) Check that pytest is installed
conda activate hummingbot
if ! command -v pytest &> /dev/null; then
    log_message "${RED}pytest is required but not installed. (pip install pytest pytest-cov)${NC}" "$TEST_LOG"
    exit 1
fi

# 2) Validate arguments
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 base_ref compare_ref [source_branch]"
    echo "Example: $0 bleeding-edge feature/my-branch _for_bleed/my-feature"
    exit 1
fi

BASE_REF="$1"
COMPARE_REF="$2"
SOURCE_BRANCH="${3:-}"  # Optional: limits file diff to branch-specific changes

log_message "Starting test verification between $BASE_REF and $COMPARE_REF" "$TEST_LOG"

# 3) cd into REPO_PATH
cd "$REPO_PATH" || {
    log_message "${RED}Failed to change to repository directory: $REPO_PATH${NC}" "$TEST_LOG"
    exit 1
}

# 4) Initialize the JSON history file
initialize_history_file

# 5) Resolve latest commit on compare_ref
commit_hash="$(git rev-parse "$COMPARE_REF" 2>/dev/null)" || {
    log_message "${RED}Failed to find commit for ref: $COMPARE_REF${NC}" "$TEST_LOG"
    exit 1
}

if [ -z "$commit_hash" ]; then
    log_message "${RED}No commit hash could be resolved for $COMPARE_REF${NC}" "$TEST_LOG"
    exit 1
fi

# 6) Check if commit was already tested successfully
commit_status="$(get_commit_status "$commit_hash")"
if [ "$commit_status" = "success" ]; then
    log_message "${GREEN}Commit $commit_hash was already tested successfully. Skipping...${NC}" "$TEST_LOG"
    exit 0
fi

# 7) Get parent commit
parent_hash="$(git rev-parse "${commit_hash}^" 2>/dev/null)" || {
    log_message "${RED}Failed to find parent commit for $commit_hash${NC}" "$TEST_LOG"
    exit 1
}

# 8) Debug info
debug_git_info "$commit_hash"

# 9) List modified source files
# If source branch provided, only check files unique to that branch (not inherited).
# This prevents codebase-wide format passes from triggering tests for every file.
if [ -n "$SOURCE_BRANCH" ]; then
    merge_base=$(git merge-base "$COMPARE_REF" "$SOURCE_BRANCH" 2>/dev/null || echo "$parent_hash")
    readarray -t modified_files < <(get_modified_source_files "$merge_base" "$SOURCE_BRANCH")
else
    readarray -t modified_files < <(get_modified_source_files "$parent_hash" "$commit_hash")
fi
if [ ${#modified_files[@]} -eq 0 ]; then
    log_message "${YELLOW}No source files modified in commit $commit_hash${NC}" "$TEST_LOG"
    # Consider that a "pass" since there's nothing to test
    record_commit_status "$commit_hash" "success" modified_files
    exit 0
fi

# 10) Run tests for each changed file
test_failures=0
for file in "${modified_files[@]}"; do
    log_message "${BLUE}Processing file: $file${NC}" "$TEST_LOG"
    test_info="$(find_test_module "$file")"

    if [ -n "$test_info" ]; then
        if ! run_module_tests "$test_info"; then
            test_failures=$((test_failures + 1))
            add_status_entry "Testing" "$file" "FAILED" "Tests failed"
        else
            add_status_entry "Testing" "$file" "PASSED" "All tests passed"
        fi
    else
        log_message "${RED}No test file found for $file${NC}" "$TEST_LOG"
        # Missing test files are informational, not failures.
        # Only actual test execution failures should block merges.
        add_status_entry "Testing" "$file" "NO_TESTS" "No test file found"
    fi
done

# 11) Final pass/fail
if [ "$test_failures" -eq 0 ]; then
    log_message "${GREEN}All tests passed for commit $commit_hash${NC}" "$TEST_LOG"
    record_commit_status "$commit_hash" "success" modified_files
    exit 0
else
    log_message "${RED}Some tests failed for commit $commit_hash${NC}" "$TEST_LOG"
    record_commit_status "$commit_hash" "failed" modified_files
    exit 1
fi

