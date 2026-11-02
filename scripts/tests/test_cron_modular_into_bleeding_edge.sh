#!/usr/bin/env bash
# Harness for merge_modular_into_feature_branch (extracted from
# hummingbot-branch-tracking.sh). Local fixture repo only; no network.
# Usage: bash custom_git_setup/scripts/tests/test_cron_modular_into_bleeding_edge.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

log_operation() { echo "$*"; }
log_warning() { echo "$*"; }
log_error() { echo "$*"; }

# shellcheck disable=SC1090
source <(sed -n "/^merge_modular_into_feature_branch() {/,/^}/p" "$SCRIPT")
if ! declare -F merge_modular_into_feature_branch >/dev/null; then
    echo "FAIL could not load merge_modular_into_feature_branch from $SCRIPT"
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

export FEATURE_BRANCH=bleeding-edge
export RUN_LOG_DIR="$TMPDIR_T/runlog"
mkdir -p "$RUN_LOG_DIR"

# new_fixture: repo on bleeding-edge cut from modular at base commit.
new_fixture() {
    FX="$(mktemp -d "$TMPDIR_T/fx.XXXXXX")"
    git init -q -b modular "$FX"
    cd "$FX" || exit 1
    echo base > f.txt
    git add f.txt
    git commit -q -m base
    git checkout -q -b bleeding-edge
    FAILED_MERGES=()
    REBUILD_MODE=false
}

# Commit on modular (file $1 = content $2), then return to bleeding-edge.
modular_commit() {
    git checkout -q modular
    echo "$2" > "$1"
    git add "$1"
    git commit -q -m "modular $1"
    git checkout -q bleeding-edge
}

# Case 1: modular ahead -> merged, becomes an ancestor.
new_fixture
modular_commit pin.txt bump
merge_modular_into_feature_branch >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && git merge-base --is-ancestor modular bleeding-edge \
        && [ "${#FAILED_MERGES[@]}" -eq 0 ]; then
    pass "modular merged into bleeding-edge (rc=$rc)"
else
    fail "modular merge rc=$rc failed=${#FAILED_MERGES[@]}"
fi

# Case 2: already an ancestor -> no new commit.
before="$(git rev-parse HEAD)"
merge_modular_into_feature_branch >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$before" ]; then
    pass "no-op when modular already ancestor (rc=$rc)"
else
    fail "ancestor no-op rc=$rc head moved"
fi

# Case 3: REBUILD_MODE=true -> skipped even if modular is ahead.
new_fixture
modular_commit pin.txt bump
REBUILD_MODE=true
merge_modular_into_feature_branch >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && ! git merge-base --is-ancestor modular bleeding-edge; then
    pass "skipped under REBUILD_MODE=true (rc=$rc)"
else
    fail "REBUILD_MODE skip rc=$rc"
fi

# Case 4: conflict -> aborted, clean tree, failure recorded.
new_fixture
modular_commit f.txt modular-side
echo be-side > f.txt
git commit -q -am "be change"
before="$(git rev-parse HEAD)"
merge_modular_into_feature_branch >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ] && [ "$(git rev-parse HEAD)" = "$before" ] \
        && [ -z "$(git status --porcelain)" ] \
        && [ ! -f .git/MERGE_HEAD ] \
        && [ "${#FAILED_MERGES[@]}" -eq 2 ] \
        && [ "${FAILED_MERGES[0]}" = "modular -> bleeding-edge" ] \
        && [[ "${FAILED_MERGES[1]}" == *"gate tests stale pins"* ]] \
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
