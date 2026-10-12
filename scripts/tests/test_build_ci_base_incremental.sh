#!/usr/bin/env bash
# Harness for build_ci_base_incremental + select_ci_base_builder (extracted from
# hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_build_ci_base_incremental.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

# Mirror the real common.sh log_* helpers (stdout).
log_operation() { echo "$*"; }
log_error() { echo "ERROR $*"; }
log_warning() { echo "$*"; }

CI_BASE_SEED_TAG=ci-base-seed-test
DEVELOPMENT_BRANCH=development

# shellcheck disable=SC1090
source <(sed -n "/^ci_base_incremental_preconditions() {/,/^}/p;/^compute_for_ci_owned() {/,/^}/p;/^merge_development_incremental() {/,/^}/p;/^build_ci_base_incremental() {/,/^}/p;/^select_ci_base_builder() {/,/^}/p" "$SCRIPT")

for fn in ci_base_incremental_preconditions compute_for_ci_owned merge_development_incremental build_ci_base_incremental select_ci_base_builder; do
    if ! declare -F "$fn" >/dev/null; then
        echo "FAIL could not load $fn from $SCRIPT"
        exit 1
    fi
done

# Task 8 is covered by its own harness; stub it here and record the call.
REVERT_CALLED=0
REVERT_RC=0
revert_retired_for_ci_merges() { REVERT_CALLED=1; return "$REVERT_RC"; }

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT
RUN_LOG_DIR="$TMPDIR_T/logs"
mkdir -p "$RUN_LOG_DIR"

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

g() { git -c commit.gpgsign=false -c core.hooksPath="$TMPDIR_T/nohooks" "$@"; }
commit_file() { # file content message
    echo "$2" > "$1"
    g add "$1"
    g commit -q --no-verify -m "$3"
}

# new_repo: bare origin; ci-base = seed + Dev-Merged dev merge (D1); pushed.
# Checked out on ci-base.
new_repo() {
    local root
    root="$(mktemp -d -p "$TMPDIR_T")"
    git init -q --bare -b ci-base "$root/origin.git"
    git clone -q "$root/origin.git" "$root/work" 2>/dev/null
    cd "$root/work" || exit 1
    git config user.name Test
    git config user.email test@example.invalid
    git config commit.gpgsign false
    g checkout -q -b development
    echo 0 > base.txt
    g add -A
    g commit -q --no-verify -m "D0"
    g tag -f "$CI_BASE_SEED_TAG" >/dev/null
    g checkout -q -b ci-base
    g checkout -q development
    commit_file dev1.txt 1 "D1"
    g checkout -q ci-base
    D1="$(git rev-parse development)"
    g merge -q --no-verify --no-ff development -m "Sync ci-base with development" -m "Dev-Merged: $D1"
    g push -q origin ci-base development 2>/dev/null
}

dev_advance() { # file content
    g checkout -q development
    commit_file "$1" "$2" "D2"
    g push -q origin development 2>/dev/null
    g checkout -q ci-base
    g fetch -q origin
}

# ---------- (a) happy path: new dev commit -> incremental merge with new Dev-Merged
new_repo
dev_advance new.txt new
D2="$(git rev-parse origin/development)"
origin_tip="$(git rev-parse origin/ci-base)"
# local ci-base drifts (unpushed commit); the builder must reset it to origin
commit_file stray.txt stray "local-only commit"
SEED_PRE_SYNC_SHA=""
REVERT_CALLED=0
REVERT_RC=0
build_ci_base_incremental >/dev/null 2>&1; rc=$?
trailer="$(git log -1 --format='%(trailers:key=Dev-Merged,valueonly)' | tr -d '[:space:]')"
if [ "$rc" -eq 0 ] && [ "$trailer" = "$D2" ] && [ -e new.txt ] && [ ! -e stray.txt ] \
    && [ "$(git rev-parse HEAD^1)" = "$origin_tip" ] \
    && [ "$SEED_PRE_SYNC_SHA" = "$origin_tip" ] && [ "$REVERT_CALLED" -eq 1 ] \
    && [ -z "$(git status --porcelain)" ]; then
    pass "(a) incremental merge carries new Dev-Merged, SEED_PRE_SYNC_SHA = origin tip, revert step ran"
else
    fail "(a) rc=$rc trailer=$trailer pre=$SEED_PRE_SYNC_SHA expected_pre=$origin_tip revert=$REVERT_CALLED"
fi

# ---------- (a2) nothing new on development: succeeds, no new commit
new_repo
origin_tip="$(git rev-parse origin/ci-base)"
build_ci_base_incremental >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$origin_tip" ] && [ "$SEED_PRE_SYNC_SHA" = "$origin_tip" ]; then
    pass "(a2) no new dev commits -> ci-base unchanged, rc 0"
else
    fail "(a2) rc=$rc head=$(git rev-parse HEAD) tip=$origin_tip"
fi

# ---------- (b) failing preconditions: return 1, ci-base ref unchanged
new_repo
dev_advance new.txt new
g tag -d "$CI_BASE_SEED_TAG" >/dev/null
local_before="$(git rev-parse ci-base)"
origin_before="$(git rev-parse origin/ci-base)"
REVERT_CALLED=0
build_ci_base_incremental >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ] && [ "$(git rev-parse ci-base)" = "$local_before" ] \
    && [ "$(git rev-parse origin/ci-base)" = "$origin_before" ] && [ "$REVERT_CALLED" -eq 0 ]; then
    pass "(b) missing seed tag -> rc 1, ci-base unchanged, no later steps"
else
    fail "(b) rc=$rc local=$(git rev-parse ci-base) expected=$local_before revert=$REVERT_CALLED"
fi

# ---------- (b2) revert step failure propagates as rc 1
new_repo
dev_advance new.txt new
REVERT_RC=1
build_ci_base_incremental >/dev/null 2>&1; rc=$?
REVERT_RC=0
if [ "$rc" -eq 1 ]; then
    pass "(b2) revert_retired_for_ci_merges failure -> rc 1"
else
    fail "(b2) rc=$rc"
fi

# ---------- (c) dispatch
FORCE_RESEED=false
r1="$(select_ci_base_builder seed)"
FORCE_RESEED=true
r2="$(select_ci_base_builder seed)"
r3="$(select_ci_base_builder incremental)"
FORCE_RESEED=false
r4="$(select_ci_base_builder incremental)"
if [ "$r1" = seed ]; then pass "(c) build_mode=seed -> seed"; else fail "(c) seed -> $r1"; fi
if [ "$r2" = seed ]; then pass "(c) seed + FORCE_RESEED -> seed"; else fail "(c) seed+reseed -> $r2"; fi
if [ "$r3" = seed ]; then pass "(c) incremental + FORCE_RESEED -> seed"; else fail "(c) incremental+reseed -> $r3"; fi
if [ "$r4" = incremental ]; then pass "(c) incremental -> incremental"; else fail "(c) incremental -> $r4"; fi

echo
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$fails FAILED"
exit 1
