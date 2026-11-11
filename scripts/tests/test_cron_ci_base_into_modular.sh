#!/usr/bin/env bash
# Harness for merge_ci_base_into_modular (extracted from
# hummingbot-branch-tracking.sh). Local fixture repo only; no network.
# Usage: bash custom_git_setup/scripts/tests/test_cron_ci_base_into_modular.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

log_operation() { echo "$*"; }
log_warning() { echo "$*"; }
log_error() { echo "$*"; }

# shellcheck disable=SC1090
source <(sed -n "/^merge_ci_base_into_modular() {/,/^}/p" "$SCRIPT")
if ! declare -F merge_ci_base_into_modular >/dev/null; then
    echo "FAIL could not load merge_ci_base_into_modular from $SCRIPT"
    exit 1
fi

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false

export RUN_LOG_DIR="$TMPDIR_T/runlog"
mkdir -p "$RUN_LOG_DIR"

# new_fixture: repo on modular at base commit; origin/ci-base == base.
new_fixture() {
    FX="$(mktemp -d "$TMPDIR_T/fx.XXXXXX")"
    git init -q -b modular "$FX"
    cd "$FX" || exit 1
    echo base > f.txt
    git add f.txt
    git commit -q -m base
    git update-ref refs/remotes/origin/ci-base HEAD
    FAILED_MERGES=()
    REBUILD_MODE=false
}

# Commit $1=$2 on a side branch off base, point origin/ci-base at it, return to modular.
ci_base_commit() {
    git checkout -q -b ci-base-side
    echo "$2" > "$1"
    git add "$1"
    git commit -q -m "ci-base $1"
    git update-ref refs/remotes/origin/ci-base HEAD
    git checkout -q modular
    git branch -q -D ci-base-side
}

# Case 1: ci-base ahead, clean merge -> merge commit with origin/ci-base as 2nd parent.
new_fixture
ci_base_commit cfg.txt new
ci_head="$(git rev-parse origin/ci-base)"
merge_ci_base_into_modular >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(git rev-parse HEAD^2 2>/dev/null)" = "$ci_head" ] \
        && [ "${#FAILED_MERGES[@]}" -eq 0 ]; then
    pass "ci-base merged into modular (rc=$rc)"
else
    fail "ci-base merge rc=$rc failed=${#FAILED_MERGES[@]}"
fi

# Case 2: already an ancestor -> no new commit.
before="$(git rev-parse HEAD)"
merge_ci_base_into_modular >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$before" ]; then
    pass "no-op when ci-base already ancestor (rc=$rc)"
else
    fail "ancestor no-op rc=$rc head moved"
fi

# Case 3: same no-op under REBUILD_MODE=true (not skipped, just a no-op).
REBUILD_MODE=true
merge_ci_base_into_modular >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$before" ]; then
    pass "no-op under REBUILD_MODE=true (rc=$rc)"
else
    fail "REBUILD_MODE no-op rc=$rc head moved"
fi

# Case 4: conflict -> aborted, clean tree, failure recorded.
new_fixture
ci_base_commit f.txt ci-base-side
echo modular-side > f.txt
git commit -q -am "modular change"
before="$(git rev-parse HEAD)"
merge_ci_base_into_modular >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ] && [ "$(git rev-parse HEAD)" = "$before" ] \
        && [ -z "$(git status --porcelain)" ] \
        && [ ! -f .git/MERGE_HEAD ] \
        && [ "${#FAILED_MERGES[@]}" -eq 2 ] \
        && [ "${FAILED_MERGES[0]}" = "ci-base -> modular" ] \
        && [[ "${FAILED_MERGES[1]}" == *"conflicted: f.txt"* ]]; then
    pass "conflict aborted and recorded (rc=$rc)"
else
    fail "conflict rc=$rc failed=${#FAILED_MERGES[@]} status=$(git status --porcelain)"
fi

if [ "$fails" -eq 0 ]; then
    echo "ALL PASSED"
    exit 0
fi
echo "$fails FAILED"
exit 1
