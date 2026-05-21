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
    # Exclude sub-packages/ (submodules managed by own branch), tool configs (.serena/, .mcp.json), and worktrees
    untracked=$(git ls-files --others --exclude-standard | grep -Ev '^(sub-packages/|\.serena/|\.mcp\.json|\.worktrees/)')
    if [ -n "$untracked" ]; then
        log_operation "Adding new files..."
        git ls-files --others --exclude-standard -z | grep -zEv '^(sub-packages/|\.serena/|\.mcp\.json|\.worktrees/)' | xargs -0 -r git add
        # Skip hooks — these are auto-added files from merges, not user code
        git commit --no-verify -m "Auto-add new files" >& /dev/null || return 1
    fi
    return 0
}

###############################################################################
# Base Branch Sync
###############################################################################
get_base_branch() {
    local target="$1"
    local result
    result="$(yq -r ".target_branches[\"$target\"].base_branch" "$BRANCH_CONFIG" 2>/dev/null)"
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        echo ""
    else
        echo "$result"
    fi
}

assert_clean_working_tree() {
    local repo_path="$1"
    local unexpected
    # Untracked files outside sub-packages/ — those should NEVER exist at rebuild entry
    unexpected=$(git -C "$repo_path" ls-files --others --exclude-standard | grep -v '^sub-packages/' || true)
    if [[ -n "$unexpected" ]]; then
        echo "ERROR: rebuild aborted — unexpected untracked files in working tree:" >&2
        echo "$unexpected" >&2
        echo "" >&2
        echo "Resolve manually before retrying: stash, remove, or commit them." >&2
        return 1
    fi
    return 0
}

###############################################################################
# Python 3.12 Transform Stage
# ---------------------------
# Post-merge, file-scoped AST transforms applied only to Python files that
# were introduced or modified by the development sync + _for_ci/* merges.
# Composed of:
#   1. refactor-py312  — project-specific rules (asyncio, distutils, removed stdlib)
#   2. ruff check --fix --unsafe-fixes  — auto-fix unused imports (best-effort)
#   3. ruff format     — normalise whitespace after AST rewrites
#
# Toggleable via PY312_TRANSFORMS=0 to bypass during incident triage.
# Called with the list of changed .py files as positional arguments.
###############################################################################
run_py312_transforms_for_changed() {
    # $@ — list of .py files relative to REPO_PATH
    if [ "${PY312_TRANSFORMS:-1}" = "0" ]; then
        log_operation "py312 transforms disabled via PY312_TRANSFORMS=0"
        return 0
    fi

    if [ $# -eq 0 ]; then
        log_operation "py312 post-merge transform: no changed Python files"
        return 0
    fi

    local refactor_cmd=""
    local ruff_cmd=""

    # Locate refactor-py312 — prefer pixi env, fall back to PATH.
    if [ -x "$REPO_PATH/.pixi/envs/default/bin/refactor-py312" ]; then
        refactor_cmd="$REPO_PATH/.pixi/envs/default/bin/refactor-py312"
    elif command -v refactor-py312 &> /dev/null; then
        refactor_cmd="refactor-py312"
    fi

    # Locate ruff — prefer PATH (usually available), fall back to pixi env.
    if command -v ruff &> /dev/null; then
        ruff_cmd="ruff"
    elif [ -x "$REPO_PATH/.pixi/envs/default/bin/ruff" ]; then
        ruff_cmd="$REPO_PATH/.pixi/envs/default/bin/ruff"
    fi

    if [ -z "$refactor_cmd" ] && [ -z "$ruff_cmd" ]; then
        log_warning "py312 transforms: neither refactor-py312 nor ruff found — skipping"
        return 0
    fi

    log_section "Running py312 post-merge transform pass (${#} files)"

    # Pass 1: refactor-py312 custom rules on changed files only.
    # --workers 1 is REQUIRED: refactor's default ProcessPoolExecutor cannot
    # pickle Rule classes that import `ast` (TypeError: cannot pickle module).
    if [ -n "$refactor_cmd" ]; then
        "$refactor_cmd" --workers 1 "$@" >& /dev/null
        local rc=$?
        # refactor-py312 exit codes: 0=no-changes, 1=changes-applied, >=2=error
        if [ $rc -gt 1 ]; then
            log_error "refactor-py312 failed (exit $rc)"
            return 1
        fi
    fi

    # Pass 2: auto-fix unused imports (best-effort; non-fatal).
    if [ -n "$ruff_cmd" ]; then
        "$ruff_cmd" check --fix --unsafe-fixes "$@" >& /dev/null || true
    fi

    # Pass 3: format changed files.
    if [ -n "$ruff_cmd" ]; then
        "$ruff_cmd" format "$@" >& /dev/null || true
    fi

    # Stage and commit if anything changed.
    git add -- "$@"
    if ! git diff --cached --quiet; then
        git commit --no-verify -m "chore(ci-base): py312 post-merge transform pass" >& /dev/null \
            || { log_error "Failed to commit py312 transform changes"; return 1; }
        log_operation "Committed py312 post-merge transform changes"
    else
        log_operation "py312 post-merge transform: no changes produced"
    fi

    log_result true "py312 post-merge transform pass complete"
    return 0
}

sync_base_branch() {
    local base_branch="$1"

    # Defense-in-depth: refuse to start if working tree has unexpected untracked files
    assert_clean_working_tree "$REPO_PATH" || return 1

    # Register merge.ours driver for .gitattributes resolution (idempotent)
    git -C "$REPO_PATH" config merge.ours.driver true

    log_section "Syncing $base_branch with $DEVELOPMENT_BRANCH"

    local checkout_output
    checkout_output=$(git checkout "$base_branch" 2>&1)
    local checkout_status=$?
    if [ $checkout_status -ne 0 ]; then
        log_error "Failed to checkout $base_branch (exit $checkout_status)"
        log_detail "git output: $checkout_output"
        indent_pop
        return 1
    fi

    # Check if development has new commits
    if git merge-base --is-ancestor "$DEVELOPMENT_BRANCH" "$base_branch" 2>/dev/null; then
        log_operation "Already up to date with $DEVELOPMENT_BRANCH"
        indent_pop
        return 0
    fi

    # Capture HEAD before the sync merge so the format pass can scope itself to
    # only files actually introduced or modified by this merge (not pre-existing
    # working-tree content).
    local pre_sync_sha
    pre_sync_sha=$(git rev-parse HEAD)

    # Merge development into base branch (skip hooks/gpg for script-internal merge)
    if git merge --no-verify "$DEVELOPMENT_BRANCH" -m "Sync $base_branch with $DEVELOPMENT_BRANCH" >& /dev/null; then
        log_operation "Merged $DEVELOPMENT_BRANCH cleanly"
    else
        # Conflicts — classify as format-only vs logical
        local logical_conflicts=()
        local format_only=()

        while IFS= read -r file; do
            case "$file" in
                # CI/test config files have logical changes — need manual review
                pyproject.toml|.pre-commit-config.yaml|conftest.py|.github/*|test/conftest.py)
                    logical_conflicts+=("$file")
                    ;;
                *)
                    # All other conflicts are format-only — safe to accept upstream
                    format_only+=("$file")
                    ;;
            esac
        done < <(git diff --name-only --diff-filter=U)

        if [ ${#logical_conflicts[@]} -gt 0 ]; then
            log_error "Conflicts in logical files — manual resolution needed:"
            for f in "${logical_conflicts[@]}"; do
                log_detail "  $f"
            done
            git_quiet merge --abort
            indent_pop
            return 1
        fi

        # Format-only conflicts: accept upstream content, will reformat below
        for f in "${format_only[@]}"; do
            git checkout --theirs "$f" 2>/dev/null
            git add "$f"
        done
        git commit --no-verify --no-edit >& /dev/null || {
            log_error "Failed to commit merge resolution"
            git_quiet merge --abort 2>/dev/null
            indent_pop
            return 1
        }
        log_operation "Resolved ${#format_only[@]} format-only conflicts"
    fi

    # Re-initialize submodules after merge (development doesn't track them,
    # but ci-base does via .gitmodules).  The merge may leave stale working
    # trees; a sync+update restores the correct gitlinks and checkouts
    # without touching the index entries that pixi needs.
    if [ -f ".gitmodules" ]; then
        git submodule sync --quiet 2>/dev/null
        git submodule update --init --force 2>/dev/null
    fi

    # Reformat any new/changed upstream files.
    # Use ruff directly — pixi run format fails before pixi-workspace is merged
    # (sub-packages/ don't exist yet, breaking pixi dependency resolution).
    local format_ok=false
    local ruff_cmd=""
    if command -v ruff &> /dev/null; then
        ruff_cmd="ruff"
    elif [ -x "$REPO_PATH/.pixi/envs/default/bin/ruff" ]; then
        ruff_cmd="$REPO_PATH/.pixi/envs/default/bin/ruff"
    fi

    if [ -n "$ruff_cmd" ]; then
        if $ruff_cmd format hummingbot test controllers scripts >& /dev/null; then
            format_ok=true
        else
            log_warning "ruff format failed"
        fi
    else
        log_warning "ruff not found — skipping format step"
    fi

    if [ "$format_ok" = true ]; then
        # Only format files actually introduced/modified by the development sync (was: untracked cruft)
        local -a sync_py_files=()
        while IFS= read -r f; do
            [[ "$f" == sub-packages/* ]] && continue
            [ -f "$f" ] && sync_py_files+=("$f")
        done < <(git diff --name-only --diff-filter=AM "${pre_sync_sha}..HEAD" -- '*.py')
        if [ ${#sync_py_files[@]} -gt 0 ]; then
            # Check whether ruff actually changed any of these files
            if ! git diff --quiet -- "${sync_py_files[@]}" 2>/dev/null; then
                git add -- "${sync_py_files[@]}"
                git commit --no-verify -m "style: ruff format new upstream files" >& /dev/null
                log_operation "Formatted new upstream files"
            else
                log_operation "No formatting changes needed"
            fi
        else
            log_operation "No new upstream Python files to format"
        fi
    fi

    # Merge _for_ci/* branches after format pass — ci-base-layer targeted fixes.
    # Uses the same tracked_branches config under target_branches.ci-base.
    merge_for_ci_branches "$base_branch" || {
        log_error "_for_ci/* merge failed — rebuild aborted"
        return 1
    }

    # Post-merge py312 transform pass — scoped to files changed since ORIG_HEAD
    # (development sync + _for_ci merges combined).  Runs AFTER all merges so a
    # single commit covers the full delta, and AFTER ruff format so transforms
    # operate on already-normalised source.
    local -a py_changed=()
    while IFS= read -r f; do
        [[ "$f" == sub-packages/* ]] && continue
        [ -f "$f" ] && py_changed+=("$f")
    done < <(git diff --name-only "${pre_sync_sha}..HEAD" -- '*.py')

    if [ ${#py_changed[@]} -gt 0 ]; then
        run_py312_transforms_for_changed "${py_changed[@]}" || {
            log_error "py312 post-merge transform failed — aborting base branch sync"
            return 1
        }
    else
        log_operation "py312 post-merge transform: no Python files changed"
    fi

    log_result true "Base branch synced"
    return 0
}

###############################################################################
# _for_ci/* Merge Pass
# --------------------
# Merges branches listed under target_branches.ci-base.tracked_branches into
# the base branch (ci-base).  Runs AFTER the development sync + format pass.
# Abort gates mirror _for_bleed: logical conflicts on pyproject.toml,
# conftest.py, .github/, .pre-commit-config.yaml cause hard abort.
###############################################################################
merge_for_ci_branches() {
    local base_branch="$1"

    # Read branches from YAML; skip if none configured
    local for_ci_branches
    for_ci_branches="$(yq -r '.target_branches["ci-base"].tracked_branches // [] | .[] | select(.enabled == true) | .name' "$BRANCH_CONFIG" 2>/dev/null)"
    if [ -z "$for_ci_branches" ]; then
        log_operation "No _for_ci/* branches configured — skipping"
        return 0
    fi

    log_section "Merging _for_ci/* branches into $base_branch"

    while IFS= read -r branch; do
        [ -z "$branch" ] && continue
        log_operation "Merging $branch"

        local location
        location=$(branch_exists "$branch")
        if [ "$location" = "none" ]; then
            log_error "_for_ci branch $branch not found — skipping"
            continue
        fi

        local ref="$branch"
        if [ "$location" = "remote" ]; then
            git fetch origin "$branch" >& /dev/null || { log_error "Fetch failed for $branch"; return 1; }
            ref="origin/$branch"
        fi

        git checkout "$base_branch" >& /dev/null || { log_error "Checkout $base_branch failed"; return 1; }

        if git merge-base --is-ancestor "$ref" "$base_branch" 2>/dev/null; then
            log_operation "$branch already in $base_branch — skipping"
            continue
        fi

        if git merge --no-ff "$ref" -m "Auto-merge $branch into $base_branch" >& /dev/null; then
            log_result true "$branch merged cleanly"
        else
            # Classify conflicts: logical → abort, format-only → auto-resolve
            local logical_conflicts=() format_only=()
            while IFS= read -r file; do
                case "$file" in
                    pyproject.toml|.pre-commit-config.yaml|conftest.py|.github/*|test/conftest.py)
                        logical_conflicts+=("$file") ;;
                    *)
                        format_only+=("$file") ;;
                esac
            done < <(git diff --name-only --diff-filter=U)

            if [ ${#logical_conflicts[@]} -gt 0 ]; then
                log_error "Logical conflicts in $branch — manual resolution needed:"
                for f in "${logical_conflicts[@]}"; do log_detail "  $f"; done
                git merge --abort >& /dev/null
                return 1
            fi

            for f in "${format_only[@]}"; do
                git checkout --theirs "$f" 2>/dev/null
                git add "$f"
            done
            git commit --no-verify --no-edit >& /dev/null || {
                log_error "Failed to commit format-only conflict resolution for $branch"
                git merge --abort >& /dev/null
                return 1
            }
            log_result true "$branch merged (${#format_only[@]} format-only conflicts resolved)"
        fi
    done < <(echo "$for_ci_branches")

    return 0
}

###############################################################################
# Branch Operations
###############################################################################
check_mergeability() {
    local branch="$1"
    local target="$2"

    # Use git merge-tree (plumbing) to check mergeability without touching
    # the working tree.  This avoids "unable to rmdir sub-packages/*" errors
    # caused by submodule directories that exist on bleeding-edge/ci-base but
    # not on the target branch.
    if git merge-tree --write-tree "$target" "$branch" > /dev/null 2>&1; then
        return 0
    else
        log_error "$branch has conflicts with $target"
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

    # Skip test verification during rebuild — the branch was just recreated
    # from development, so the test verifier can't resolve refs properly.
    # Tests should be run after the full rebuild completes.
    if [ "$REBUILD_MODE" = "true" ]; then
        return 0
    fi

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

    # Check mergeability against the base branch (ci-base).  All _for_bleed
    # branches are based on ci-base, not development — checking against
    # development always fails on submodule entries that development lacks.
    # Skip during rebuild (branches are force-merged anyway).
    if [ "$target" = "$FEATURE_BRANCH" ] && [ "$REBUILD_MODE" != "true" ]; then
        local base_branch
        base_branch="$(get_base_branch "$target")"
        : "${base_branch:=$DEVELOPMENT_BRANCH}"  # fallback if no base configured
        check_mergeability "$branch" "$base_branch" || {
            log_error "Mergeability check failed (against $base_branch)"
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
        return 0
    else
        git_quiet merge --abort

        # In rebuild mode, try format-aware merge before worktree rebase.
        # Feature branches are unformatted; bleeding-edge is formatted.
        # -X theirs prefers feature content for conflicting hunks (usually
        # format-only), then ruff format fixes the result.
        if [ "$REBUILD_MODE" = "true" ]; then
            log_operation "Merge conflict — trying format-aware merge"
            if git merge -X theirs --no-verify --no-ff "$ref" -m "Auto-merge $branch into $target" >& /dev/null; then
                # Merge succeeded with -X theirs — now reformat
                local ruff_cmd=""
                if command -v ruff &> /dev/null; then
                    ruff_cmd="ruff"
                elif [ -x "$REPO_PATH/.pixi/envs/default/bin/ruff" ]; then
                    ruff_cmd="$REPO_PATH/.pixi/envs/default/bin/ruff"
                fi
                if [ -n "$ruff_cmd" ] && ! git diff --quiet; then
                    $ruff_cmd format hummingbot test controllers scripts >& /dev/null
                fi
                if ! git diff --quiet; then
                    git add -A
                    git commit --no-verify -m "style: ruff format after $branch merge" >& /dev/null
                    log_operation "Formatted after merge"
                fi
                handle_new_files || {
                    log_error "Failed"
                    indent_pop
                    return 1
                }
                log_result true "Done (format-aware merge)"
                return 0
            fi
            git_quiet merge --abort 2>/dev/null
        fi

        # Fallback: worktree-based rebase onto current bleeding-edge HEAD
        if [ "$REBUILD_MODE" = "true" ]; then
            log_operation "Format-aware merge failed — attempting worktree rebase"
            local wt_dir="${REPO_PATH}/.worktrees/rebase-$(basename "$branch")"
            local current_head
            current_head=$(git rev-parse HEAD)

            # Clean up any stale worktree
            rm -rf "$wt_dir" 2>/dev/null
            git worktree prune 2>/dev/null

            # Create worktree on the conflicting branch
            if git worktree add "$wt_dir" "$ref" >& /dev/null; then
                # Attempt automatic rebase onto current bleeding-edge HEAD
                if (cd "$wt_dir" && GIT_EDITOR=true git rebase "$current_head" >& /dev/null); then
                    # Rebase succeeded — update branch ref and retry merge
                    local new_tip
                    new_tip=$(cd "$wt_dir" && git rev-parse HEAD)
                    git worktree remove "$wt_dir" >& /dev/null 2>&1
                    git worktree prune 2>/dev/null

                    # Update the branch to point at the rebased tip
                    git branch -f "$branch" "$new_tip" >& /dev/null 2>&1

                    # Retry the merge
                    if git merge --no-ff "$branch" -m "Auto-merge $branch into $target (rebased)" >& /dev/null; then
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
                        log_result true "Done (after rebase)"
                        indent_pop
                        return 0
                    else
                        git_quiet merge --abort
                        log_result false "Merge failed even after rebase"
                        indent_pop
                        return 1
                    fi
                else
                    # Auto-rebase failed — leave worktree for manual resolution
                    # Don't abort the rebase — leave it paused so user can resolve
                    log_warning "Worktree left for manual resolution: $wt_dir"
                    log_detail "  cd $wt_dir"
                    log_detail "  # resolve conflicts, git add, git rebase --continue"
                    log_detail "  # then: git -C $REPO_PATH branch -f $branch \$(git -C $wt_dir rev-parse HEAD)"
                    log_detail "  # finally: git -C $REPO_PATH worktree remove $wt_dir"
                    log_result false "Merge failed — worktree ready for manual rebase"
                    indent_pop
                    return 1
                fi
            else
                log_result false "Merge failed (worktree creation failed)"
                indent_pop
                return 1
            fi
        else
            log_result false "Merge failed"
            indent_pop
            return 1
        fi
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

get_branch_parent() {
    local target="$1"
    local branch="$2"
    local result
    result="$(yq -r ".target_branches[\"$target\"].tracked_branches[] | select(.name == \"$branch\").parent" "$BRANCH_CONFIG" 2>/dev/null)"
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        echo ""
    else
        echo "$result"
    fi
}

get_branch_tier() {
    local target="$1"
    local branch="$2"
    local result
    result="$(yq -r ".target_branches[\"$target\"].tracked_branches[] | select(.name == \"$branch\").tier" "$BRANCH_CONFIG" 2>/dev/null)"
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        echo "feature"
    else
        echo "$result"
    fi
}

# Emits branches in topological order partitioned by tier.
# infrastructure branches are emitted first (in parent→child order),
# then feature branches (in parent→child order).
# Within each tier, flat branches (no parent) come before chained branches.
# A log banner is printed before each tier to mark the transition.
get_tracked_branches_sorted() {
    local target="$1"
    local -a infra_flat=() infra_chain_name=() infra_chain_parent=()
    local -a feat_flat=()  feat_chain_name=()  feat_chain_parent=()

    while IFS= read -r branch; do
        [ -z "$branch" ] && continue
        local parent tier
        parent="$(get_branch_parent "$target" "$branch")"
        tier="$(get_branch_tier "$target" "$branch")"
        if [ "$tier" = "infrastructure" ]; then
            if [ -z "$parent" ]; then
                infra_flat+=("$branch")
            else
                infra_chain_name+=("$branch")
                infra_chain_parent+=("$parent")
            fi
        else
            if [ -z "$parent" ]; then
                feat_flat+=("$branch")
            else
                feat_chain_name+=("$branch")
                feat_chain_parent+=("$parent")
            fi
        fi
    done < <(get_tracked_branches "$target")

    # Helper: emit one tier's flat+chained branches in dependency order
    # Usage: _emit_tier_branches flat_arr chain_name_arr chain_parent_arr emitted_arr_name
    _emit_tier_branches() {
        local -n _flat="$1"
        local -n _chain_name="$2"
        local -n _chain_parent="$3"
        local -n _emitted="$4"

        for b in "${_flat[@]}"; do
            echo "$b"
            _emitted+=("$b")
        done

        local -a pending_idx=()
        for i in "${!_chain_name[@]}"; do pending_idx+=("$i"); done

        local progress=true
        while [ ${#pending_idx[@]} -gt 0 ] && [ "$progress" = "true" ]; do
            progress=false
            local -a next_pending=()
            for i in "${pending_idx[@]}"; do
                local parent_found=false
                for e in "${_emitted[@]}"; do
                    if [ "$e" = "${_chain_parent[$i]}" ]; then parent_found=true; break; fi
                done
                if [ "$parent_found" = "true" ]; then
                    echo "${_chain_name[$i]}"
                    _emitted+=("${_chain_name[$i]}")
                    progress=true
                else
                    next_pending+=("$i")
                fi
            done
            pending_idx=("${next_pending[@]}")
        done

        for i in "${pending_idx[@]}"; do
            echo -e "$(get_indent)${BRANCH_CHAR}  $(colorize "$BLUE" "WARNING: branch ${_chain_name[$i]} has unresolved parent ${_chain_parent[$i]} — merging anyway")" >&2
            echo "${_chain_name[$i]}"
        done
    }

    local -a emitted=()

    # Banners go to stderr so they appear in the log without polluting the
    # stdout branch-name stream that callers consume via process substitution.
    echo -e "$(get_indent)${BRANCH_CHAR}  $(colorize "$BLUE" "=== Merging infrastructure branches ===")" >&2
    _emit_tier_branches infra_flat infra_chain_name infra_chain_parent emitted

    echo -e "$(get_indent)${BRANCH_CHAR}  $(colorize "$BLUE" "=== Merging feature branches ===")" >&2
    _emit_tier_branches feat_flat feat_chain_name feat_chain_parent emitted
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

      # Determine base branch from config (falls back to development if unset)
      local base_branch
      base_branch="$(get_base_branch "$FEATURE_BRANCH")"

      if [ -n "$base_branch" ]; then
          # Sync base branch with development (merge + format)
          sync_base_branch "$base_branch" || {
              log_error "Base branch sync failed — rebuild aborted"
              exit 1
          }

          log_operation "Create $FEATURE_BRANCH from $base_branch"
          git_quiet checkout "$base_branch"
          git_quiet branch -D "$FEATURE_BRANCH" >& /dev/null
          git_quiet checkout -b "$FEATURE_BRANCH"
      else
          # No base branch configured — use development directly (legacy behavior)
          log_operation "Checkout development branch"
          git_quiet checkout "$DEVELOPMENT_BRANCH"
          log_operation "Delete feature branch"
          git_quiet branch -D "$FEATURE_BRANCH" >& /dev/null
          log_operation "Create feature branch"
          git_quiet checkout -b "$FEATURE_BRANCH"

          # Clean up embedded git repos left over from prior feature branch.
          if [ -d "sub-packages" ]; then
              log_operation "Clean embedded sub-package repos"
              find sub-packages -maxdepth 2 -name ".git" -exec rm -rf {} + 2>/dev/null
              rm -rf sub-packages/*/
          fi
      fi

      # Ensure the new branch is properly initialized
      log_operation "Initialize feature branch"
      git commit --allow-empty --no-verify -m "Initialize $FEATURE_BRANCH" >& /dev/null || {
          log_error "Failed to initialize feature branch"
          exit 1
      }
      log_result true "Rebuild complete"
  fi

  INDENT_LEVEL=0  # Flatten output for branch processing

  # For each target branch in the config
  while IFS= read -r target_branch; do
      [ -z "$target_branch" ] && continue

      # ci-base is managed exclusively by sync_base_branch (development sync +
      # format pass + merge_for_ci_branches + py312 post-merge transform).
      # Skip it here to prevent double-processing _for_ci/* branches.
      if [ "$target_branch" = "ci-base" ]; then
          continue
      fi

      log_step "$(colorize "$BLUE" "Processing target branch: $target_branch")"

      # For each tracked branch under that target
      local loop_indent=$INDENT_LEVEL
      while IFS= read -r branch; do
          [ -z "$branch" ] && continue

          enabled="$(is_branch_enabled "$target_branch" "$branch")"

          if [ "$enabled" = "true" ]; then
              INDENT_LEVEL=$loop_indent  # Reset indent before each branch
              sync_branch "$target_branch" "$branch"
          fi
      done < <(get_tracked_branches_sorted "$target_branch")
      INDENT_LEVEL=$loop_indent

  done < <(get_target_branches)

  # Final format pass — merges can produce unformatted results even when
  # individual branches are clean (e.g. merge conflict resolution artifacts
  # or content from different formatting epochs).
  if [ "$REBUILD_MODE" = "true" ]; then
      local ruff_cmd=""
      if command -v ruff &> /dev/null; then
          ruff_cmd="ruff"
      elif [ -x "$REPO_PATH/.pixi/envs/default/bin/ruff" ]; then
          ruff_cmd="$REPO_PATH/.pixi/envs/default/bin/ruff"
      fi
      if [ -n "$ruff_cmd" ]; then
          $ruff_cmd format hummingbot test controllers scripts >& /dev/null
          if ! git diff --quiet; then
              git add -A -- . ':!sub-packages'
              git commit --no-verify -m "style: final ruff format pass after rebuild" >& /dev/null
              log_step "Applied final format pass"
          fi
      fi
  fi

  log_step "Branch tracking completed successfully!"
}

main "$@"
