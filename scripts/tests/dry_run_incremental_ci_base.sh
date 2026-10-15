#!/usr/bin/env bash
# Dry-run of the INCREMENTAL ci-base build (plan Task 13), end to end:
#   1. development -> origin/ci-base conflict pre-scan (git merge-tree, read-only)
#   2. build_ci_base_incremental   (dev merge + retired _for_ci reverts)
#   3. merge_for_ci_branches       (the real _for_ci merge path)
#   4. py312 transform + scoped final ruff pass + aiomqtt pin
#   5. merge of the resulting ci-base into origin/modular, classified with the
#      same classifier chain as sync_modular_branch
#
# Usage (from the hummingbot checkout, needs ruff + yq + flock on PATH; run when
# no --rebuild or cron run is active):
#   cd /home/memento/PycharmProjects/Hummingbot/hummingbot && \
#     pixi run -e ci bash ../custom_git_setup/scripts/tests/dry_run_incremental_ci_base.sh
# Override the config with BRANCH_CONFIG=<file>.
#
# Nothing real is mutated: all work happens in two throwaway DETACHED worktrees
# under a mktemp dir (removed by an EXIT trap). The shared harness (lib_dry_run.sh)
# shadows git for the sourced production functions: fetch is a no-op (the run uses
# origin/* as of the last fetch -- fetch first if you want fresh refs),
# `checkout ci-base` is a no-op and the literal ref `ci-base` resolves to the
# worktree HEAD (the detached worktree stands in for it), commits are never
# GPG-signed, and push/tag/branch/update-ref/symbolic-ref/remote/worktree/config/
# stash/gc are refused. Commits and merges only move the detached HEAD of the
# scratch worktrees. A before/after snapshot of every ref and of the main
# checkout's HEAD is compared at the end.
# Refuses to start while the pipeline flock (the one --rebuild and cron take) is
# held, and holds it for the duration of the run.
#
# Deliberately NOT `set -e` / `set -u` / `pipefail`: the sourced production
# functions are written for a shell with none of them (hummingbot-branch-
# tracking.sh sets none), so enabling them would change their behaviour. This
# script checks return codes explicitly.
#
# Exit 0 only if logical_conflicts=0 AND classifier_resolutions=0.
# Exit 1 if either is non-zero (offending paths printed).
# Exit 2 if the dry run itself could not complete (setup/build/tooling error,
# or the harness caught merge_for_ci_branches falsely skipping a branch).

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"
SCRIPT_DIR="$(dirname "$SCRIPT")"
COMMON="$SCRIPT_DIR/common.sh"
CUSTOM_GIT_PATH="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_PATH="${LOG_PATH:-$CUSTOM_GIT_PATH/logs}"
BRANCH_CONFIG="${BRANCH_CONFIG:-$CUSTOM_GIT_PATH/configs/branch-tracking.yaml}"
DEVELOPMENT_BRANCH="${DEVELOPMENT_BRANCH:-development}"
CI_BASE_SEED_TAG="${CI_BASE_SEED_TAG:-ci-base-seed-v5}"

# shellcheck source=lib_dry_run.sh
source "$SCRIPT_DIR/tests/lib_dry_run.sh" || { echo "ERROR: cannot source lib_dry_run.sh" >&2; exit 2; }

dry_run_init
WT_CI="$TMP/dryrun-ci"
WT_MOD="$TMP/dryrun-mod"
DRY_RUN_WORKTREES+=("$WT_CI" "$WT_MOD")
logical_count=0
classifier_count=0
logical_paths=()
classifier_paths=()
ci_tree="NONE"

# --- load production functions by name (same approach as the sibling tests) ----
for fn in branch_exists git_operation log_merge_failure; do
    load_fn "$COMMON" "$fn"
done
for fn in is_logical_conflict_path merge_development_incremental build_ci_base_incremental \
          ci_base_incremental_preconditions compute_for_ci_owned revert_retired_for_ci_merges \
          get_enabled_for_ci_branches merge_for_ci_branches get_branch_parent \
          mark_branch_not_landed branch_did_not_land skip_if_parent_failed take_merge_stage \
          branch_reverts_upstream_content branch_content_present_in_head noop_guard_abort \
          commit_if_changed run_py312_transforms_for_changed py312_tooling_trailer \
          ci_base_format_targets ci_base_ruff_version_trailer pin_aiomqtt_transport \
          ci_base_generated_path read_modular_owned_paths modular_owns_path \
          conflict_is_format_only py_pair_format_equivalent conflict_gitignore_pattern_subset conflict_side_is_subset \
          conflict_ci_base_is_subset conflict_modular_is_subset \
          conflict_regions_variant conflict_regions_style_only; do
    load_fn "$SCRIPT" "$fn"
done

FAILED_MERGES=()
ATTEMPTED_MERGES=0
NOT_LANDED_BRANCHES=""

report_and_exit() {
    local stage="$1" p
    local after
    after="$(snapshot)"
    if [ "$after" != "$SNAP_BEFORE" ]; then
        echo "ERROR: refs or HEAD of $REPO changed during the dry run (before=$SNAP_BEFORE after=$after)" >&2
        exit 2
    fi
    echo "Refs/HEAD unchanged (snapshot $SNAP_BEFORE)"
    for p in "${logical_paths[@]}"; do echo "LOGICAL $p"; done
    for p in "${classifier_paths[@]}"; do echo "CLASSIFIER $p"; done
    if [ -n "$stage" ]; then
        echo "DRY-RUN incremental ci-base: INCOMPLETE at stage '$stage' (logical_conflicts=$logical_count classifier_resolutions=$classifier_count tree=$ci_tree)"
        if [ "$logical_count" -ne 0 ] || [ "$classifier_count" -ne 0 ]; then exit 1; fi
        exit 2
    fi
    echo "DRY-RUN incremental ci-base: logical_conflicts=$logical_count classifier_resolutions=$classifier_count tree=$ci_tree"
    [ "$logical_count" -eq 0 ] && [ "$classifier_count" -eq 0 ]
    exit $?
}

# --- preflight ------------------------------------------------------------------
SNAP_BEFORE="$(snapshot)"
for ref in origin/ci-base origin/modular "origin/$DEVELOPMENT_BRANCH"; do
    sha="$(command git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}")" \
        || die "$ref not found: run 'git fetch origin' in $REPO first"
    echo "$ref = $sha"
done
while IFS= read -r b; do
    [ -z "$b" ] && continue
    command git -C "$REPO" rev-parse --verify --quiet "$b^{commit}" >/dev/null \
        || command git -C "$REPO" rev-parse --verify --quiet "origin/$b^{commit}" >/dev/null \
        || die "enabled _for_ci branch $b has no local or origin/ ref: run 'git fetch origin' in $REPO first"
done < <(get_enabled_for_ci_branches)

command git -C "$REPO" worktree add -q --detach "$WT_CI" origin/ci-base || die "worktree add (ci) failed"

# --- stage 1: development -> ci-base conflict pre-scan (read-only) ---------------
echo "== stage 1: development merge pre-scan (git merge-tree)"
mt_out="$TMP/merge-tree.out"
command git -C "$WT_CI" merge-tree --write-tree --name-only -z origin/ci-base "origin/$DEVELOPMENT_BRANCH" \
    >"$mt_out" 2>"$TMP/merge-tree.err"
mt_rc=$?
[ "$mt_rc" -le 1 ] || die "git merge-tree failed (rc=$mt_rc): $(head -c 400 "$TMP/merge-tree.err")"
idx=0
dev_conflicts=()
while IFS= read -r -d '' item; do
    if [ "$idx" -gt 0 ]; then
        [ -z "$item" ] && break
        dev_conflicts+=("$item")
    fi
    idx=$((idx + 1))
done < "$mt_out"
echo "development conflicts vs origin/ci-base: ${#dev_conflicts[@]}"
for f in "${dev_conflicts[@]}"; do
    if is_logical_conflict_path "$f"; then
        logical_count=$((logical_count + 1))
        logical_paths+=("dev-merge $f")
    fi
done
if [ "$logical_count" -gt 0 ]; then
    echo "build_ci_base_incremental would abort on the logical paths above; later stages skipped"
    report_and_exit "development-merge"
fi

# --- stage 2: incremental builder ------------------------------------------------
echo "== stage 2: build_ci_base_incremental"
cd "$WT_CI" || die "cannot cd to $WT_CI"
build_ci_base_incremental || report_and_exit "build_ci_base_incremental"
pre_sync_sha="$SEED_PRE_SYNC_SHA"
[ -s "$RUN_LOG_DIR/incremental_taken_dev.txt" ] \
    && echo "taken from development (rule-based, informational): $(wc -l < "$RUN_LOG_DIR/incremental_taken_dev.txt") path(s)"
post_build="$(git rev-parse HEAD)"

# --- stage 3: _for_ci merges ---------------------------------------------------------
echo "== stage 3: merge_for_ci_branches"
MERGE_CONFLICT_LOG="$TMP/for_ci_conflicts.txt"
: > "$MERGE_CONFLICT_LOG"
merge_for_ci_branches ci-base
for_ci_rc=$?
MERGE_CONFLICT_LOG=/dev/null
while IFS= read -r f; do
    [ -z "$f" ] && continue
    if is_logical_conflict_path "$f"; then
        logical_count=$((logical_count + 1))
        logical_paths+=("for_ci-merge $f")
    else
        classifier_count=$((classifier_count + 1))
        classifier_paths+=("for_ci-merge $f")
    fi
done < <(sort -u "$TMP/for_ci_conflicts.txt")
for m in "${FAILED_MERGES[@]}"; do echo "FAILED_MERGE $m"; done
[ "$for_ci_rc" -eq 0 ] || report_and_exit "merge_for_ci_branches"

# --- stage 4: generated steps (py312, scoped ruff, aiomqtt pin) ----------------------
echo "== stage 4: py312 transform, final ruff, aiomqtt pin"
ruff_cmd=""
if command -v ruff >/dev/null 2>&1; then
    ruff_cmd="ruff"
elif [ -x "$REPO/.pixi/envs/default/bin/ruff" ]; then
    ruff_cmd="$REPO/.pixi/envs/default/bin/ruff"
fi
[ -n "$ruff_cmd" ] || die "ruff not found: the resulting tree would not match a real run; use 'pixi run -e ci bash $0'"

py_changed=()
while IFS= read -r f; do
    [[ "$f" == sub-packages/* ]] && continue
    [ -f "$f" ] && py_changed+=("$f")
done < <(git diff --name-only "${pre_sync_sha}..HEAD" -- '*.py')
if [ "${#py_changed[@]}" -gt 0 ]; then
    run_py312_transforms_for_changed "${py_changed[@]}" || report_and_exit "py312-transform"
fi

fmt_paths=()
while IFS= read -r f; do
    case "$f" in
        hummingbot/*|test/*|controllers/*|scripts/*) fmt_paths+=("$f") ;;
    esac
done < <(ci_base_format_targets incremental "$pre_sync_sha")
if [ "${#fmt_paths[@]}" -gt 0 ]; then
    "$ruff_cmd" format "${fmt_paths[@]}" >/dev/null 2>&1 || true
    "$ruff_cmd" check --select I --fix "${fmt_paths[@]}" >/dev/null 2>&1 || true
    "$ruff_cmd" check --fix "${fmt_paths[@]}" >/dev/null 2>&1 || true
    if ! git diff --quiet -- "${fmt_paths[@]}" ':!sub-packages' 2>/dev/null; then
        git add -- "${fmt_paths[@]}" ':!sub-packages'
        commit_if_changed "style: final ruff format + import sort after _for_ci merges (ci-base compliance)" --no-verify \
            -m "$(ci_base_ruff_version_trailer "$ruff_cmd")" >/dev/null 2>&1 \
            || report_and_exit "final-ruff-commit"
    fi
fi
pin_aiomqtt_transport "ci-base" || report_and_exit "pin_aiomqtt_transport"

ci_sha="$(git rev-parse HEAD)"
ci_tree="$(git rev-parse 'HEAD^{tree}')"
echo "simulated ci-base: commit=$ci_sha tree=$ci_tree"

# --- stage 5: ci-base -> modular merge, classified like sync_modular_branch ----------
echo "== stage 5: merge simulated ci-base into origin/modular"
command git -C "$REPO" worktree add -q --detach "$WT_MOD" origin/modular || die "worktree add (modular) failed"
cd "$WT_MOD" || die "cannot cd to $WT_MOD"
if git merge-base --is-ancestor "$ci_sha" HEAD; then
    echo "origin/modular already contains the simulated ci-base: no merge needed"
else
    git merge --no-ff --no-commit "$ci_sha" >/dev/null 2>&1
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        name=""
        if is_logical_conflict_path "$file" || [ "$file" = ".pre-commit-config.yaml" ]; then
            name=""
        elif ci_base_generated_path "$file"; then
            name="generated-file"
        elif modular_owns_path "$file"; then
            name="modular-owned"
        elif conflict_is_format_only "$file"; then
            name="format-only"
        elif conflict_ci_base_is_subset "$file"; then
            name="ci-base-subset"
        elif conflict_modular_is_subset "$file"; then
            name="modular-subset"
        elif conflict_regions_style_only "$file"; then
            name="style-only-region"
        fi
        if [ -n "$name" ]; then
            classifier_count=$((classifier_count + 1))
            classifier_paths+=("modular-merge $name $file")
        else
            logical_count=$((logical_count + 1))
            logical_paths+=("modular-merge $file")
        fi
    done < <(git diff --name-only --diff-filter=U)
    git merge --abort >/dev/null 2>&1
fi

report_and_exit ""
