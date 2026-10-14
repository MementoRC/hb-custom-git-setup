#!/usr/bin/env bash
# ci-base drift oracle (incremental ci-base plan, Task 14).
#
# Builds ci-base from the SEED (build_ci_base_from_seed + the same generated
# steps sync_base_branch runs in a seed --rebuild: _for_ci merges, ruff
# external=["mock"] injection, py312 transform, whole-tree final ruff pass,
# aiomqtt pin) in a throwaway detached worktree, then compares its TREE against
# the target ref. Inputs are whatever origin/* currently is (no fetch is done:
# fetch first for fresh refs) and the _for_ci branches enabled in
# branch-tracking.yaml.
#
# Usage (needs ruff + yq + flock + python3 on PATH; run when no --rebuild or cron
# run is active):
#   cd /home/memento/PycharmProjects/Hummingbot/hummingbot && \
#     pixi run -e ci bash ../custom_git_setup/scripts/check_ci_base_drift.sh [target-ref]
# target-ref defaults to origin/ci-base. Override the config with BRANCH_CONFIG.
#
# Comparison: `git diff --stat <target> <seed-build> -- . ':!pixi.lock'`. The
# only exclusion is pixi.lock (plan Task 14 and the pixi.lock risk row: the
# network solve makes the lock commit non-deterministic). Commit metadata and
# trailers are not in the tree, so they cannot cause a difference.
#
# Isolation is the same as dry_run_incremental_ci_base.sh (see lib_dry_run.sh):
# detached scratch worktree, refusing git wrapper, ref/HEAD snapshot compared at
# the end, pipeline flock held for the run. Writes
# $LOG_PATH/ci_base_drift_latest.txt and, if $LOG_PATH/cron exists, appends one
# line to $LOG_PATH/cron/latest_summary.txt (plan Task 14).
#
# Exit 0 iff the diff is empty. Exit 1 if it is not. Exit 2 if the oracle could
# not complete (setup/build/tooling error). Last stdout line:
#   DRIFT-ORACLE: target=<ref> target_tree=<sha> seed_tree=<sha> files_differing=N

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/hummingbot-branch-tracking.sh"
COMMON="$SCRIPT_DIR/common.sh"
CUSTOM_GIT_PATH="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_PATH="${LOG_PATH:-$CUSTOM_GIT_PATH/logs}"
BRANCH_CONFIG="${BRANCH_CONFIG:-$CUSTOM_GIT_PATH/configs/branch-tracking.yaml}"
DEVELOPMENT_BRANCH="${DEVELOPMENT_BRANCH:-development}"
CI_BASE_SEED_TAG="${CI_BASE_SEED_TAG:-ci-base-seed-v5}"
TARGET="${1:-origin/ci-base}"

# shellcheck source=tests/lib_dry_run.sh
source "$SCRIPT_DIR/tests/lib_dry_run.sh" || { echo "ERROR: cannot source lib_dry_run.sh" >&2; exit 2; }

dry_run_init
WT_SEED="$TMP/drift-seed"
DRY_RUN_WORKTREES+=("$WT_SEED")

for fn in branch_exists git_operation log_merge_failure; do
    load_fn "$COMMON" "$fn"
done
for fn in is_logical_conflict_path build_ci_base_from_seed get_enabled_for_ci_branches \
          merge_for_ci_branches get_branch_parent mark_branch_not_landed branch_did_not_land \
          skip_if_parent_failed take_merge_stage branch_reverts_upstream_content \
          branch_content_present_in_head noop_guard_abort commit_if_changed \
          run_py312_transforms_for_changed py312_tooling_trailer ci_base_ruff_version_trailer \
          pin_aiomqtt_transport ci_base_generated_path read_modular_owned_paths \
          modular_owns_path conflict_is_format_only conflict_gitignore_pattern_subset \
          conflict_side_is_subset conflict_ci_base_is_subset conflict_modular_is_subset \
          conflict_regions_variant conflict_regions_style_only; do
    load_fn "$SCRIPT" "$fn"
done

FAILED_MERGES=()
ATTEMPTED_MERGES=0
NOT_LANDED_BRANCHES=""

SNAP_BEFORE="$(snapshot)"

target_sha="$(command git -C "$REPO" rev-parse --verify --quiet "$TARGET^{commit}")" \
    || die "target ref '$TARGET' not found: run 'git fetch origin' in $REPO first"
target_tree="$(command git -C "$REPO" rev-parse "$target_sha^{tree}")" || die "cannot resolve tree of $TARGET"
echo "target $TARGET = $target_sha (tree $target_tree)"

for ref in "origin/$DEVELOPMENT_BRANCH" "refs/tags/$CI_BASE_SEED_TAG"; do
    command git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
        || die "$ref not found: run 'git fetch origin --tags' in $REPO first"
done
while IFS= read -r b; do
    [ -z "$b" ] && continue
    command git -C "$REPO" rev-parse --verify --quiet "$b^{commit}" >/dev/null \
        || command git -C "$REPO" rev-parse --verify --quiet "origin/$b^{commit}" >/dev/null \
        || die "enabled _for_ci branch $b has no local or origin/ ref: run 'git fetch origin' in $REPO first"
done < <(get_enabled_for_ci_branches)

command git -C "$REPO" worktree add -q --detach "$WT_SEED" "$CI_BASE_SEED_TAG" || die "worktree add failed"
cd "$WT_SEED" || die "cannot cd to $WT_SEED"

# --- seed build: same order as sync_base_branch with REBUILD_MODE=true ------------
echo "== seed build: build_ci_base_from_seed"
build_ci_base_from_seed ci-base || die "build_ci_base_from_seed failed"
pre_sync_sha="$SEED_PRE_SYNC_SHA"

echo "== seed build: merge_for_ci_branches"
merge_for_ci_branches ci-base || die "merge_for_ci_branches failed (FAILED_MERGES: ${FAILED_MERGES[*]})"
if [ "${#FAILED_MERGES[@]}" -gt 0 ]; then
    # Skipped/unlanded branches make the seed build differ from a real one.
    die "some enabled _for_ci branches did not land: ${FAILED_MERGES[*]}"
fi

echo "== seed build: ruff external=[\"mock\"] injection"
if [ -f "pyproject.toml" ] && ! grep -q 'external = \["mock"\]' pyproject.toml; then
    python3 - <<'PYEOF'
import re
path = "pyproject.toml"
c = open(path).read()
c = re.sub(
    r'(\[tool\.ruff\.lint\](?:.*?\n)*?ignore\s*=\s*\[[^\]]*\]\n)',
    r'\1external = ["mock"]\n',
    c
)
open(path, "w").write(c)
PYEOF
    if ! git diff --quiet pyproject.toml; then
        git add pyproject.toml
        commit_if_changed 'fix(ruff): inject external=["mock"] to suppress # noqa: mock warnings' --no-verify >/dev/null 2>&1 \
            || log_warning "Failed to commit ruff external=[\"mock\"] fix"
    fi
fi

echo "== seed build: py312 transform, final ruff, aiomqtt pin"
ruff_cmd=""
if command -v ruff >/dev/null 2>&1; then
    ruff_cmd="ruff"
elif [ -x "$REPO/.pixi/envs/default/bin/ruff" ]; then
    ruff_cmd="$REPO/.pixi/envs/default/bin/ruff"
fi
[ -n "$ruff_cmd" ] || die "ruff not found: the seed tree would not match a real run; use 'pixi run -e ci bash $0'"

py_changed=()
while IFS= read -r f; do
    [[ "$f" == sub-packages/* ]] && continue
    [ -f "$f" ] && py_changed+=("$f")
done < <(git diff --name-only "${pre_sync_sha}..HEAD" -- '*.py')
if [ "${#py_changed[@]}" -gt 0 ]; then
    run_py312_transforms_for_changed "${py_changed[@]}" || die "py312 transform failed"
fi

fmt_paths=(hummingbot test controllers scripts)
"$ruff_cmd" format "${fmt_paths[@]}" >/dev/null 2>&1 || true
"$ruff_cmd" check --select I --fix "${fmt_paths[@]}" >/dev/null 2>&1 || true
"$ruff_cmd" check --fix "${fmt_paths[@]}" >/dev/null 2>&1 || true
if ! git diff --quiet -- "${fmt_paths[@]}" ':!sub-packages' 2>/dev/null; then
    git add -- "${fmt_paths[@]}" ':!sub-packages'
    commit_if_changed "style: final ruff format + import sort after _for_ci merges (ci-base compliance)" --no-verify \
        -m "$(ci_base_ruff_version_trailer "$ruff_cmd")" >/dev/null 2>&1 \
        || die "final ruff commit failed"
fi
pin_aiomqtt_transport "ci-base" || die "pin_aiomqtt_transport failed"

seed_sha="$(git rev-parse HEAD)" || die "cannot resolve seed build HEAD"
seed_tree="$(git rev-parse 'HEAD^{tree}')" || die "cannot resolve seed build tree"
echo "seed build: commit=$seed_sha tree=$seed_tree"

# --- compare ---------------------------------------------------------------------------
# The seed build is a commit, so a pathspec diff between the two commits is exact.
diff_names="$TMP/drift_names.txt"
diff_stat="$TMP/drift_stat.txt"
command git diff --name-only "$target_sha" "$seed_sha" -- . ':!pixi.lock' >"$diff_names" || die "git diff --name-only failed"
command git diff --stat=200 "$target_sha" "$seed_sha" -- . ':!pixi.lock' >"$diff_stat" || die "git diff --stat failed"
files_differing="$(grep -c . "$diff_names")"
files_differing="${files_differing:-0}"

# --- verify nothing real moved ------------------------------------------------------------
SNAP_AFTER="$(snapshot)"
if [ "$SNAP_AFTER" != "$SNAP_BEFORE" ]; then
    echo "ERROR: refs or HEAD of $REPO changed during the oracle run (before=$SNAP_BEFORE after=$SNAP_AFTER)" >&2
    exit 2
fi
echo "Refs/HEAD unchanged (snapshot $SNAP_BEFORE)"

final="DRIFT-ORACLE: target=$TARGET target_tree=$target_tree seed_tree=$seed_tree files_differing=$files_differing"
if [ "$files_differing" -gt 0 ]; then
    echo "== git diff --stat $TARGET <seed build> -- . ':!pixi.lock'"
    cat "$diff_stat"
fi
{
    date -u +%Y-%m-%dT%H:%M:%SZ
    [ "$files_differing" -gt 0 ] && cat "$diff_stat"
    echo "$final"
} >"$LOG_PATH/ci_base_drift_latest.txt" 2>/dev/null
if [ -d "$LOG_PATH/cron" ]; then
    echo "$final" >>"$LOG_PATH/cron/latest_summary.txt" 2>/dev/null
fi
echo "$final"
[ "$files_differing" -eq 0 ]
exit $?
