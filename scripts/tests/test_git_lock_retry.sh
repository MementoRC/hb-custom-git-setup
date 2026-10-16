#!/usr/bin/env bash
# Harness for git_lock_retry (extracted from common.sh).
# Usage: bash custom_git_setup/scripts/tests/test_git_lock_retry.sh
set -u

COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

SLEEP_LOG="$TMPDIR_T/sleeps"
RETRY_LOG="$TMPDIR_T/retries"
LOCK=""   # lock file removed by the sleep stub when REMOVE_LOCK_ON_SLEEP=1
REMOVE_LOCK_ON_SLEEP=0

log_operation() { echo "$*" >> "$RETRY_LOG"; }
sleep() {
    echo "$1" >> "$SLEEP_LOG"
    if [ "$REMOVE_LOCK_ON_SLEEP" = "1" ]; then rm -f "$LOCK"; fi
}

# shellcheck disable=SC1090
source <(sed -n "/^git_lock_retry() {/,/^}/p" "$COMMON")

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

if ! declare -F git_lock_retry >/dev/null; then
    echo "FAIL could not load git_lock_retry from $COMMON"
    exit 1
fi

REPO="$TMPDIR_T/repo"
git init -q "$REPO"
cd "$REPO" || exit 1
git config user.name "Test"
git config user.email "test@example.invalid"
git config commit.gpgsign false
echo base > f.txt
git add f.txt
git commit -q -m "init"
git branch other
LOCK="$REPO/.git/index.lock"

reset_logs() { : > "$SLEEP_LOG"; : > "$RETRY_LOG"; }

# (a) transient lock cleared during the first backoff: succeeds on retry
reset_logs
touch "$LOCK"
REMOVE_LOCK_ON_SLEEP=1
git_lock_retry git checkout other >/dev/null 2>"$TMPDIR_T/err_a"
rc=$?
REMOVE_LOCK_ON_SLEEP=0
if [ $rc -eq 0 ] && [ "$(git rev-parse --abbrev-ref HEAD)" = "other" ] \
    && [ "$(wc -l < "$RETRY_LOG")" -eq 1 ] && grep -q "attempt 1/5" "$RETRY_LOG"; then
    pass "(a) transient lock: retried once and succeeded"
else
    fail "(a) rc=$rc retries=$(wc -l < "$RETRY_LOG")"
fi

# (b) persistent lock: 5 attempts (4 backoffs 1,2,4,8), original error preserved
reset_logs
git checkout -q development 2>/dev/null || git checkout -q master 2>/dev/null || git checkout -q main
touch "$LOCK"
git_lock_retry git checkout other >/dev/null 2>"$TMPDIR_T/err_b"
rc=$?
rm -f "$LOCK"
if [ $rc -ne 0 ] && [ "$(tr '\n' ' ' < "$SLEEP_LOG")" = "1 2 4 8 " ] \
    && grep -q "index.lock': File exists" "$TMPDIR_T/err_b"; then
    pass "(b) persistent lock: failed after 5 attempts with original error"
else
    fail "(b) rc=$rc sleeps=$(tr '\n' ' ' < "$SLEEP_LOG")"
fi

# (c) non-lock failure: immediate, no retry
reset_logs
git_lock_retry git checkout no-such-branch >/dev/null 2>"$TMPDIR_T/err_c"
rc=$?
if [ $rc -ne 0 ] && [ ! -s "$SLEEP_LOG" ] && [ ! -s "$RETRY_LOG" ] && [ -s "$TMPDIR_T/err_c" ]; then
    pass "(c) non-lock failure: no retry"
else
    fail "(c) rc=$rc sleeps=$(wc -l < "$SLEEP_LOG")"
fi

[ "$fails" -eq 0 ]
