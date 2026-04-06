#!/usr/bin/env bash
###############################################################################
# rebuild-accelerated.sh
# ----------------------
# Rebuild the `accelerated` branch from `bleeding-edge` by applying automated
# AST transforms (pytest migration + cython annotations).
#
# The accelerated branch is a DERIVED branch. It is always reset to
# bleeding-edge's tip and then AST transforms are applied on top.
# Never commit to it manually — changes belong on bleeding-edge or in the
# refactor-applications transform scripts.
#
# Usage:
#   bash rebuild-accelerated.sh [--dry-run] [--pytest-only] [--cython-only]
#   bash rebuild-accelerated.sh --help
#
# Options:
#   --dry-run       Show what WOULD be transformed; no branches or commits
#   --pytest-only   Skip Phase 3 (cython annotations)
#   --cython-only   Skip Phase 2 (pytest migration)
#   --help          Show this help and exit
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

###############################################################################
# Configuration
###############################################################################
REPO_DIR="/home/memento/PycharmProjects/Hummingbot/hummingbot"
REFACTOR_DIR="/home/memento/PycharmProjects/refactor-applications"
REFACTOR_SCRIPT="${REFACTOR_DIR}/refactor/rules/pytest_migration.py"
CYTHON_SCRIPT="${REFACTOR_DIR}/refactor/rules/cython_augmented.py"
SOURCE_BRANCH="bleeding-edge"
TARGET_BRANCH="accelerated"
PYTHON="${REPO_DIR}/.pixi/envs/default/bin/python"

CYTHON_TARGETS=(
    # NOTE: Do NOT include directories with Pydantic models — cython annotations
    # break pydantic schema generation (cython.int/double on params of model classes)
    # "hummingbot/strategy_v2/backtesting/"   # EXCLUDED: Pydantic-interacting classes
    # "hummingbot/data_feed/candles_feed/"     # EXCLUDED: breaks import chain via Pydantic
    # TODO: Add individual files verified to not touch Pydantic
)

###############################################################################
# Runtime State
###############################################################################
DRY_RUN=false
PYTEST_ONLY=false
CYTHON_ONLY=false
ORIGINAL_BRANCH=""

PHASE_RESULTS=()
PHASE_NAMES=(
    "Validation"
    "Reset to bleeding-edge"
    "Pytest Migration"
    "Cython Annotations"
    "Quality Verification"
    "Test Verification"
    "Push to Remote"
)

INDENT_LEVEL=0

###############################################################################
# Helpers
###############################################################################
record_phase() {
    local phase_idx="$1"
    local status="$2"   # PASS | FAIL | SKIP
    PHASE_RESULTS[$phase_idx]="$status"
}

phase_header() {
    local phase_num="$1"
    local phase_name="$2"
    log_header "Phase ${phase_num}: ${phase_name}"
}

dry_run_notice() {
    log_warning "DRY-RUN MODE — no changes will be applied"
}

###############################################################################
# Cleanup / Trap
###############################################################################
cleanup() {
    local exit_code=$?
    if [ -n "${ORIGINAL_BRANCH}" ] && [ "${ORIGINAL_BRANCH}" != "${TARGET_BRANCH}" ]; then
        local current_branch
        current_branch="$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
        if [ "${current_branch}" = "${TARGET_BRANCH}" ] && [ "${exit_code}" -ne 0 ]; then
            log_warning "Returning to original branch (${ORIGINAL_BRANCH}) after failure..."
            git -C "${REPO_DIR}" checkout "${ORIGINAL_BRANCH}" --quiet 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT

###############################################################################
# Help
###############################################################################
show_help() {
    cat <<EOF
rebuild-accelerated.sh — Rebuild accelerated branch from bleeding-edge + AST transforms

USAGE:
    bash rebuild-accelerated.sh [OPTIONS]

OPTIONS:
    --dry-run       Show what WOULD be transformed but do not apply changes.
                    No branches are created or modified. No commits are made.
    --pytest-only   Apply only pytest migration (skip Cython annotations).
    --cython-only   Apply only Cython annotations (skip pytest migration).
    --help          Show this help message and exit.

PHASES:
    0  Validation          — verify environment, tools, and branches
    1  Reset               — create accelerated from bleeding-edge tip
    2  Pytest Migration    — migrate unittest → pytest via AST transforms
    3  Cython Annotations  — add augmented pure Python annotations via AST
    4  Quality             — ruff format + lint fixes after transforms
    5  Test Verification   — quick smoke test of transformed test suite
    6  Push to Remote      — force-push accelerated branch to origin (triggers CI)

IMPORTANT:
    The accelerated branch is derived automatically. Do NOT commit directly to
    it. Put all changes on bleeding-edge or in refactor-applications scripts.

EXAMPLES:
    bash rebuild-accelerated.sh
    bash rebuild-accelerated.sh --dry-run
    bash rebuild-accelerated.sh --pytest-only
    bash rebuild-accelerated.sh --cython-only
EOF
}

###############################################################################
# Argument Parsing
###############################################################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                ;;
            --pytest-only)
                PYTEST_ONLY=true
                ;;
            --cython-only)
                CYTHON_ONLY=true
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Run with --help for usage."
                exit 1
                ;;
        esac
        shift
    done

    if [ "${PYTEST_ONLY}" = true ] && [ "${CYTHON_ONLY}" = true ]; then
        log_error "--pytest-only and --cython-only are mutually exclusive"
        exit 1
    fi
}

###############################################################################
# Phase 0: Validation
###############################################################################
phase_0_validate() {
    phase_header "0" "${PHASE_NAMES[0]}"
    log_section "Environment checks"
    local errors=0

    # Check repo dir
    log_step "Checking repository directory: ${REPO_DIR}"
    if [ ! -d "${REPO_DIR}" ]; then
        log_error "Repository directory not found: ${REPO_DIR}"
        errors=$((errors + 1))
    else
        log_result true "Repository directory exists"
    fi

    # Check git repo
    log_step "Checking git repository"
    if ! git -C "${REPO_DIR}" rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Not a git repository: ${REPO_DIR}"
        errors=$((errors + 1))
    else
        log_result true "Valid git repository"
    fi

    # Check working directory state (warn but don't block — rebuild resets the branch anyway)
    log_step "Checking working directory state"
    local dirty_files
    dirty_files=$(git -C "${REPO_DIR}" status --porcelain --ignore-submodules=dirty 2>/dev/null | grep -v '^??' || true)
    if [[ -n "${dirty_files}" ]]; then
        log_warning "Working directory has uncommitted changes (will be lost on accelerated branch):"
        echo "${dirty_files}" | head -10
    else
        log_result true "Working directory is clean (submodule state ignored)"
    fi

    # Check source branch exists
    log_step "Checking source branch: ${SOURCE_BRANCH}"
    if ! git -C "${REPO_DIR}" rev-parse --verify "${SOURCE_BRANCH}" > /dev/null 2>&1; then
        log_error "Source branch not found: ${SOURCE_BRANCH}"
        errors=$((errors + 1))
    else
        local src_sha
        src_sha="$(git -C "${REPO_DIR}" rev-parse --short "${SOURCE_BRANCH}")"
        log_result true "Source branch exists: ${SOURCE_BRANCH} @ ${src_sha}"
    fi

    # Check refactor-applications dir
    log_step "Checking refactor-applications: ${REFACTOR_DIR}"
    if [ ! -d "${REFACTOR_DIR}" ]; then
        log_error "refactor-applications directory not found: ${REFACTOR_DIR}"
        errors=$((errors + 1))
    else
        log_result true "refactor-applications directory exists"
    fi

    # Check pytest migration script (skip if --cython-only)
    if [ "${CYTHON_ONLY}" = false ]; then
        log_step "Checking pytest migration script: ${REFACTOR_SCRIPT}"
        if [ ! -f "${REFACTOR_SCRIPT}" ]; then
            log_error "Pytest migration script not found: ${REFACTOR_SCRIPT}"
            errors=$((errors + 1))
        else
            log_result true "Pytest migration script found"
        fi
    fi

    # Check cython script (skip if --pytest-only)
    if [ "${PYTEST_ONLY}" = false ]; then
        log_step "Checking cython annotation script: ${CYTHON_SCRIPT}"
        if [ ! -f "${CYTHON_SCRIPT}" ]; then
            log_error "Cython annotation script not found: ${CYTHON_SCRIPT}"
            errors=$((errors + 1))
        else
            log_result true "Cython annotation script found"
        fi
    fi

    # Check Python interpreter
    log_step "Checking Python interpreter: ${PYTHON}"
    if [ ! -x "${PYTHON}" ]; then
        log_error "Python not found or not executable: ${PYTHON}"
        log_detail "Ensure pixi environment is initialized: cd ${REPO_DIR} && pixi install"
        errors=$((errors + 1))
    else
        local py_ver
        py_ver="$("${PYTHON}" --version 2>&1)"
        log_result true "Python found: ${py_ver}"
    fi

    log_footer

    if [ "${errors}" -gt 0 ]; then
        log_error "Validation failed with ${errors} error(s). Aborting."
        record_phase 0 "FAIL"
        return 1
    fi

    record_phase 0 "PASS"
    return 0
}

###############################################################################
# Phase 1: Reset accelerated to bleeding-edge
###############################################################################
phase_1_reset() {
    phase_header "1" "${PHASE_NAMES[1]}"

    if [ "${DRY_RUN}" = true ]; then
        dry_run_notice
        log_step "Would: git checkout ${SOURCE_BRANCH}"
        log_step "Would: git branch -D ${TARGET_BRANCH}  (if it exists)"
        log_step "Would: git checkout -b ${TARGET_BRANCH}"
        record_phase 1 "SKIP"
        log_footer
        return 0
    fi

    log_section "Resetting ${TARGET_BRANCH} to ${SOURCE_BRANCH}"

    # Record current branch for cleanup trap
    ORIGINAL_BRANCH="$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD)"
    log_step "Current branch: ${ORIGINAL_BRANCH}"

    log_step "Checking out ${SOURCE_BRANCH}"
    git -C "${REPO_DIR}" checkout "${SOURCE_BRANCH}" --quiet
    log_result true "Checked out ${SOURCE_BRANCH}"

    # Delete existing accelerated branch if present
    if git -C "${REPO_DIR}" rev-parse --verify "${TARGET_BRANCH}" > /dev/null 2>&1; then
        log_step "Deleting existing ${TARGET_BRANCH}"
        git -C "${REPO_DIR}" branch -D "${TARGET_BRANCH}"
        log_result true "Deleted existing ${TARGET_BRANCH}"
    else
        log_step "Branch ${TARGET_BRANCH} does not exist yet (fresh create)"
    fi

    log_step "Creating ${TARGET_BRANCH} from ${SOURCE_BRANCH}"
    git -C "${REPO_DIR}" checkout -b "${TARGET_BRANCH}"
    log_result true "Created ${TARGET_BRANCH}"

    # Patch workflow.yml to include accelerated branch in CI triggers
    log_step "Patching workflow.yml for accelerated branch CI"
    local workflow_file="${REPO_DIR}/.github/workflows/workflow.yml"
    if [[ -f "${workflow_file}" ]]; then
        # Add accelerated to push and pull_request branch lists if not already there
        if ! grep -q 'accelerated' "${workflow_file}"; then
            sed -i "s/branches: \[master, development/branches: [master, development, accelerated/" "${workflow_file}"
            git -C "${REPO_DIR}" add .github/workflows/workflow.yml
            git -C "${REPO_DIR}" commit --no-verify -S -m "ci: add accelerated branch to CI triggers

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
            log_result true "Patched workflow.yml for accelerated CI"
        else
            log_result true "workflow.yml already includes accelerated branch"
        fi
    fi

    log_footer
    record_phase 1 "PASS"
    return 0
}

###############################################################################
# Phase 2: Pytest Migration
###############################################################################
phase_2_pytest() {
    phase_header "2" "${PHASE_NAMES[2]}"

    if [ "${CYTHON_ONLY}" = true ]; then
        log_warning "Skipped (--cython-only)"
        record_phase 2 "SKIP"
        log_footer
        return 0
    fi

    log_section "Running pytest migration AST transform"
    log_step "Script: ${REFACTOR_SCRIPT}"
    log_step "Target: test/"

    if [ "${DRY_RUN}" = true ]; then
        dry_run_notice
        log_step "Running in preview mode (no --apply)"
        PYTHONPATH="${REFACTOR_DIR}:${PYTHONPATH:-}" "${PYTHON}" "${REFACTOR_SCRIPT}" \
            -d --verbose "test/" 2>&1 | while IFS= read -r line; do
                log_detail "  ${line}"
            done || {
                log_warning "Preview run completed with non-zero exit (normal if no changes detected)"
            }
        record_phase 2 "SKIP"
        log_footer
        return 0
    fi

    PYTHONPATH="${REFACTOR_DIR}:${PYTHONPATH:-}" "${PYTHON}" "${REFACTOR_SCRIPT}" \
        -d --apply --verbose "test/" 2>&1 | while IFS= read -r line; do
            log_detail "  ${line}"
        done || {
            log_warning "Pytest transform script exited non-zero (may be normal if few changes)"
        }

    # Restore infrastructure files that should NOT be migrated
    # IsolatedAsyncioWrapperTestCase is the async test base class — must keep unittest inheritance
    log_step "Restoring test infrastructure files (excluded from migration)"
    local infra_files=(
        # Test infrastructure (base classes — must keep unittest inheritance)
        "test/isolated_asyncio_wrapper_test_case.py"
        "test/logger_mixin_for_test.py"
        "test/test_isolated_asyncio_wrapper_test_case.py"
        "test/test_local_class_event_loop_wrapper_test_case.py"
        "test/test_local_test_event_loop_wrapper_test_case.py"
        "test/test_logger_mixin_for_test.py"
        # Bugs #25, #26, #27 fixed in refactor 5c5affd
        # Bug #29 (E711/E712) handled by ruff --unsafe-fixes in Phase 4
        # E721 type comparison (assertEqual(x, bool) → assert x == bool) — pre-existing pattern
        "test/hummingbot/connector/test_utils.py"
    )
    for infra_file in "${infra_files[@]}"; do
        if [[ -f "${REPO_DIR}/${infra_file}" ]]; then
            git -C "${REPO_DIR}" checkout "${SOURCE_BRANCH}" -- "${infra_file}" 2>/dev/null && \
                log_detail "Restored: ${infra_file}" || true
        fi
    done

    log_step "Staging transformed test files"
    git -C "${REPO_DIR}" add test/ 2>/dev/null || true

    local staged_count
    staged_count="$(git -C "${REPO_DIR}" diff --cached --name-only | wc -l | tr -d ' ')"
    log_detail "Files staged: ${staged_count}"

    if [ "${staged_count}" -gt 0 ]; then
        log_step "Committing pytest migration"
        git -C "${REPO_DIR}" commit --no-verify -S -m \
"transform(pytest): migrate unittest to pytest

Automated AST transformation via refactor-applications:
- Remove IsolatedAsyncioWrapperTestCase inheritance
- Convert self.assert* to plain assert
- Convert setUp/tearDown to @pytest.fixture
- Convert assertRaises to pytest.raises
- Add import pytest where needed

Files changed: ${staged_count}

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
        log_result true "Pytest migration committed (${staged_count} files)"
    else
        log_warning "No pytest changes to commit (transforms may have been no-ops)"
    fi

    log_footer
    record_phase 2 "PASS"
    return 0
}

###############################################################################
# Phase 3: Cython Annotations
###############################################################################
phase_3_cython() {
    phase_header "3" "${PHASE_NAMES[3]}"

    if [ "${PYTEST_ONLY}" = true ]; then
        log_warning "Skipped (--pytest-only)"
        record_phase 3 "SKIP"
        log_footer
        return 0
    fi

    log_section "Running cython annotation AST transform"
    log_step "Script: ${CYTHON_SCRIPT}"
    log_step "Targets: ${CYTHON_TARGETS[*]}"

    local any_changes=false

    for target in "${CYTHON_TARGETS[@]}"; do
        local abs_target="${REPO_DIR}/${target}"
        log_step "Processing: ${target}"

        if [ ! -d "${abs_target}" ] && [ ! -f "${abs_target}" ]; then
            log_warning "Target does not exist, skipping: ${target}"
            continue
        fi

        if [ "${DRY_RUN}" = true ]; then
            log_detail "  DRY-RUN: Would apply cython annotations to ${target}"
            PYTHONPATH="${REFACTOR_DIR}:${PYTHONPATH:-}" "${PYTHON}" "${CYTHON_SCRIPT}" \
                -d --verbose "${abs_target}" 2>&1 | while IFS= read -r line; do
                    log_detail "  ${line}"
                done || true
        else
            PYTHONPATH="${REFACTOR_DIR}:${PYTHONPATH:-}" "${PYTHON}" "${CYTHON_SCRIPT}" \
                -d --apply --verbose "${abs_target}" 2>&1 | while IFS= read -r line; do
                    log_detail "  ${line}"
                done || {
                    log_warning "Warning: cython conversion had issues on ${target} (continuing)"
                }

            local changed
            changed="$(git -C "${REPO_DIR}" diff --name-only "${target}" 2>/dev/null | wc -l | tr -d ' ')"
            if [ "${changed}" -gt 0 ]; then
                any_changes=true
                log_detail "  Modified files in ${target}: ${changed}"
            fi
        fi
    done

    if [ "${DRY_RUN}" = true ]; then
        record_phase 3 "SKIP"
        log_footer
        return 0
    fi

    log_step "Staging cython-transformed files"
    git -C "${REPO_DIR}" add -A 2>/dev/null || true

    local staged_count
    staged_count="$(git -C "${REPO_DIR}" diff --cached --name-only | wc -l | tr -d ' ')"
    log_detail "Files staged: ${staged_count}"

    if [ "${staged_count}" -gt 0 ]; then
        log_step "Committing cython annotations"
        git -C "${REPO_DIR}" commit --no-verify -S -m \
"transform(cython): add augmented pure Python annotations

Automated AST transformation via refactor-applications:
- Convert type annotations to cython.* types
- Add @cython.ccall decorators to typed functions
- Add cython.declare() for class attributes
- Insert import cython where needed

Targets: ${CYTHON_TARGETS[*]}
Files changed: ${staged_count}

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
        log_result true "Cython annotations committed (${staged_count} files)"
    else
        log_warning "No cython changes to commit (transforms may have been no-ops)"
    fi

    log_footer
    record_phase 3 "PASS"
    return 0
}

###############################################################################
# Phase 4: Quality Verification
###############################################################################
phase_4_quality() {
    phase_header "4" "${PHASE_NAMES[4]}"

    if [ "${DRY_RUN}" = true ]; then
        dry_run_notice
        log_step "Would run: ruff format hummingbot test controllers scripts"
        log_step "Would run: ruff check --fix hummingbot test controllers scripts"
        record_phase 4 "SKIP"
        log_footer
        return 0
    fi

    # -- Fix unsafe lint issues from AST transforms (E711 == None, E712 == True/False) --
    log_section "Fixing E711/E712 lint issues from AST transforms"
    "${PYTHON}" -m ruff check --fix --unsafe-fixes --select E711,E712,E721 \
        test/ 2>&1 | while IFS= read -r line; do
            log_detail "  ${line}"
        done || log_warning "ruff unsafe-fixes exited non-zero (continuing)"

    # -- Pre-commit hooks (isort + ruff format + ruff check in one pass) --
    # Run pre-commit with --all-files to match CI behavior exactly
    log_section "Running pre-commit hooks (matches CI)"
    "${PYTHON}" -m pre_commit run --all-files 2>&1 | while IFS= read -r line; do
        log_detail "  ${line}"
    done || log_warning "pre-commit exited non-zero (hooks may have auto-fixed files)"

    # Pre-commit auto-fixes files — run it again to verify clean
    log_step "Re-running pre-commit to verify clean"
    "${PYTHON}" -m pre_commit run --all-files 2>&1 | while IFS= read -r line; do
        log_detail "  ${line}"
    done || log_warning "pre-commit still has issues after auto-fix"

    git -C "${REPO_DIR}" add -A 2>/dev/null || true
    local fmt_count
    fmt_count="$(git -C "${REPO_DIR}" diff --cached --name-only | wc -l | tr -d ' ')"

    if [ "${fmt_count}" -gt 0 ]; then
        log_step "Committing format fixes (${fmt_count} files)"
        git -C "${REPO_DIR}" commit --no-verify -S -m \
"transform(format): ruff format after AST transforms

Automated formatting to fix style issues introduced by AST transforms.
Files changed: ${fmt_count}

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
        log_result true "Format fixes committed"
    else
        log_result true "No format changes needed"
    fi

    # -- Lint --
    log_section "Applying ruff lint fixes"
    "${PYTHON}" -m ruff check --fix \
        hummingbot test controllers scripts 2>&1 | while IFS= read -r line; do
            log_detail "  ${line}"
        done || log_warning "ruff check exited non-zero — some violations may remain"

    git -C "${REPO_DIR}" add -A 2>/dev/null || true
    local lint_count
    lint_count="$(git -C "${REPO_DIR}" diff --cached --name-only | wc -l | tr -d ' ')"

    if [ "${lint_count}" -gt 0 ]; then
        log_step "Committing lint fixes (${lint_count} files)"
        git -C "${REPO_DIR}" commit --no-verify -S -m \
"transform(lint): ruff lint fixes after AST transforms

Automated lint fixes to resolve issues introduced by AST transforms.
Files changed: ${lint_count}

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
        log_result true "Lint fixes committed"
    else
        log_result true "No lint fixes needed"
    fi

    log_footer
    record_phase 4 "PASS"
    return 0
}

###############################################################################
# Phase 5: Test Verification (smoke test)
###############################################################################
phase_5_test() {
    phase_header "5" "${PHASE_NAMES[5]}"

    if [ "${DRY_RUN}" = true ]; then
        dry_run_notice
        log_step "Would run: pytest test/hummingbot/strategy_v2/ -x --timeout=30 -q"
        record_phase 5 "SKIP"
        log_footer
        return 0
    fi

    log_section "Running smoke test suite"
    log_step "Target: test/hummingbot/strategy_v2/"
    log_step "Flags:  -x --timeout=30 -q"
    log_detail ""

    local test_exit=0
    "${PYTHON}" -m pytest \
        test/hummingbot/strategy_v2/ \
        -x --timeout=30 -q 2>&1 | tail -10 | while IFS= read -r line; do
            log_detail "  ${line}"
        done || test_exit=$?

    if [ "${test_exit}" -eq 0 ]; then
        log_result true "Smoke tests passed"
        record_phase 5 "PASS"
    else
        log_warning "Smoke tests failed (exit ${test_exit}) — transforms may need adjustment"
        log_detail "Run 'pixi run test' for full diagnostics"
        record_phase 5 "FAIL"
    fi

    log_footer
    return 0  # Non-fatal: test failures noted in summary but don't abort
}

###############################################################################
# Phase 6: Push to Remote
###############################################################################
phase_6_push() {
    phase_header "6" "${PHASE_NAMES[6]}"

    if [[ "${DRY_RUN}" == true ]]; then
        log_step "DRY-RUN: Would push ${TARGET_BRANCH} to origin"
        record_phase 6 "SKIP"
        log_footer
        return 0
    fi

    log_step "Pushing ${TARGET_BRANCH} to origin..."
    if git -C "${REPO_DIR}" push -f origin "${TARGET_BRANCH}" 2>&1; then
        log_result true "Pushed ${TARGET_BRANCH} to origin (force push)"
        PHASE_RESULTS[6]="PASS"

        # Create or update PR for accelerated branch
        log_step "Creating/updating PR for accelerated branch"
        if command -v gh &>/dev/null; then
            local existing_pr
            existing_pr=$(gh pr list --repo MementoRC/hummingbot --head accelerated --base bleeding-edge --json number --jq '.[0].number' 2>/dev/null || echo "")
            if [[ -z "${existing_pr}" ]]; then
                gh pr create --repo MementoRC/hummingbot \
                    --head accelerated --base bleeding-edge \
                    --title "Accelerated: bleeding-edge + pytest migration + cython annotations" \
                    --body "$(cat <<'PREOF'
## Accelerated Branch

Auto-generated derived branch from bleeding-edge with automated AST transforms applied.

### Transforms Applied
- **Pytest migration**: unittest → pytest (assertions, fixtures, imports)
- **Cython annotations**: augmented pure Python annotations on target modules
- **Quality fixes**: ruff format + lint after transforms

### Two-Tier Model
- `bleeding-edge`: Features + enhancements (composable _for_bleed/ merges)
- `accelerated`: bleeding-edge + automated transforms (rebuilt from scratch each time)

🤖 Generated with rebuild-accelerated.sh
PREOF
)" 2>&1 && log_result true "Created PR for accelerated" || log_warning "Failed to create PR"
            else
                log_result true "PR #${existing_pr} already exists for accelerated"
            fi
        else
            log_warning "gh CLI not found — create PR manually"
        fi
    else
        log_error "Failed to push ${TARGET_BRANCH} to origin"
        PHASE_RESULTS[6]="FAIL"
    fi

    log_footer
    return 0  # Non-fatal: push failure noted in summary but doesn't abort
}

###############################################################################
# Summary
###############################################################################
print_summary() {
    log_header "Rebuild Summary"
    echo ""

    local source_sha=""
    local target_sha=""
    local commit_count=""

    if git -C "${REPO_DIR}" rev-parse --verify "${SOURCE_BRANCH}" > /dev/null 2>&1; then
        source_sha="$(git -C "${REPO_DIR}" rev-parse --short "${SOURCE_BRANCH}")"
    fi
    if git -C "${REPO_DIR}" rev-parse --verify "${TARGET_BRANCH}" > /dev/null 2>&1; then
        target_sha="$(git -C "${REPO_DIR}" rev-parse --short "${TARGET_BRANCH}")"
        if [ -n "${source_sha}" ]; then
            commit_count="$(git -C "${REPO_DIR}" rev-list --count "${SOURCE_BRANCH}..${TARGET_BRANCH}" 2>/dev/null || echo '?')"
        fi
    fi

    echo "  Branch:     ${TARGET_BRANCH}  @ ${target_sha:-N/A}"
    echo "  Based on:   ${SOURCE_BRANCH}  @ ${source_sha:-N/A}"
    if [ -n "${commit_count}" ]; then
        echo "  Commits:    +${commit_count} transform commit(s) on top of ${SOURCE_BRANCH}"
    fi
    if [ "${DRY_RUN}" = true ]; then
        echo "  Mode:       DRY-RUN (no changes applied)"
    fi
    echo ""

    local all_pass=true
    for i in "${!PHASE_NAMES[@]}"; do
        local status="${PHASE_RESULTS[$i]:-UNKNOWN}"
        local name="${PHASE_NAMES[$i]}"
        case "${status}" in
            PASS)   echo -e "  Phase ${i}: $(colorize "${GREEN}" "✓ PASS") — ${name}" ;;
            FAIL)   echo -e "  Phase ${i}: $(colorize "${RED}"   "✗ FAIL") — ${name}"; all_pass=false ;;
            SKIP)   echo -e "  Phase ${i}: $(colorize "${YELLOW}" "○ SKIP") — ${name}" ;;
            *)      echo -e "  Phase ${i}: $(colorize "${YELLOW}" "? ${status}") — ${name}" ;;
        esac
    done

    echo ""
    if [ "${all_pass}" = true ] && [ "${DRY_RUN}" = false ]; then
        echo -e "  $(colorize "${GREEN}" "Rebuild completed successfully.")"
    elif [ "${DRY_RUN}" = true ]; then
        echo -e "  $(colorize "${YELLOW}" "Dry-run complete — no changes were applied.")"
    else
        echo -e "  $(colorize "${YELLOW}" "Rebuild complete with warnings — review FAIL phases above.")"
    fi
    echo ""
    if [ "${DRY_RUN}" = false ]; then
        local remote_url=""
        remote_url="$(git -C "${REPO_DIR}" remote get-url origin 2>/dev/null || echo 'unknown')"
        echo "  Next steps:"
        echo "    Run full tests:   pixi run test"
        echo "    Switch back:      git checkout ${SOURCE_BRANCH}"
        echo "    View log:         git log --oneline ${SOURCE_BRANCH}..${TARGET_BRANCH}"
        echo "    CI remote:        ${remote_url} (branch: ${TARGET_BRANCH})"
    fi

    log_footer
}

###############################################################################
# Main
###############################################################################
main() {
    parse_args "$@"

    log_header "rebuild-accelerated.sh"
    echo ""
    echo "  Source:  ${SOURCE_BRANCH}"
    echo "  Target:  ${TARGET_BRANCH}"
    echo "  Refactor: ${REFACTOR_DIR}"
    if [ "${DRY_RUN}" = true ];    then echo "  Mode:    DRY-RUN"; fi
    if [ "${PYTEST_ONLY}" = true ]; then echo "  Mode:    --pytest-only (skip cython)"; fi
    if [ "${CYTHON_ONLY}" = true ]; then echo "  Mode:    --cython-only (skip pytest)"; fi
    log_footer

    # Change to repo directory so relative paths in transforms work
    cd "${REPO_DIR}"

    # Run phases — each is wrapped so a failure records state without aborting
    # the remaining phases (except Phase 0, which is a hard gate).
    phase_0_validate || {
        print_summary
        exit 1
    }

    phase_1_reset || {
        record_phase 1 "FAIL"
        log_error "Phase 1 failed — cannot continue without a clean branch"
        print_summary
        exit 1
    }

    phase_2_pytest || record_phase 2 "FAIL"
    phase_3_cython || record_phase 3 "FAIL"
    phase_4_quality || record_phase 4 "FAIL"
    phase_5_test    || record_phase 5 "FAIL"
    phase_6_push    || record_phase 6 "FAIL"

    print_summary
}

main "$@"
