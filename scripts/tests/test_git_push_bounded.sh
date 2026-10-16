#!/usr/bin/env bash
# Harness for git_push_bounded (scripts/git_push_bounded.sh).
# Usage: bash custom_git_setup/scripts/tests/test_git_push_bounded.sh
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/git_push_bounded.sh"

log_error() { echo "$*"; }

# shellcheck disable=SC1090
source "$LIB"

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

G() { git -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }

G init -q --bare "$TMPDIR_T/origin.git"
G clone -q "$TMPDIR_T/origin.git" "$TMPDIR_T/a" 2>/dev/null
G -C "$TMPDIR_T/a" checkout -q -b main
echo one > "$TMPDIR_T/a/f"
G -C "$TMPDIR_T/a" add f
G -C "$TMPDIR_T/a" commit -q -m one

# (a) a normal push succeeds.
git_push_bounded "$TMPDIR_T/a" origin main >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(git --git-dir="$TMPDIR_T/origin.git" rev-parse main)" = "$(G -C "$TMPDIR_T/a" rev-parse HEAD)" ]; then
    pass "(a) normal push succeeds"
else
    fail "(a) normal push rc=$rc"
fi

# (b) a stubbed timeout returning 124 -> non-zero and a "timed out" log.
echo two > "$TMPDIR_T/a/f"
G -C "$TMPDIR_T/a" commit -q -am two
timeout() { return 124; }
out="$(git_push_bounded "$TMPDIR_T/a" origin main 2>&1)"; rc=$?
unset -f timeout
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "timed out" \
    && [ "$(git --git-dir="$TMPDIR_T/origin.git" rev-parse main)" != "$(G -C "$TMPDIR_T/a" rev-parse HEAD)" ]; then
    pass "(b) timeout -> rc=$rc and logged"
else
    fail "(b) timeout rc=$rc out='$out'"
fi

# (c) GIT_TERMINAL_PROMPT=0 / GCM_INTERACTIVE=never and the low-speed config are
# present in the env/args of the git call. timeout is stubbed to run its command
# (skipping --kill-after=N and the duration) and git is stubbed to record them.
rec="$TMPDIR_T/rec"
timeout() { shift 2; "$@"; }
git() { echo "prompt=${GIT_TERMINAL_PROMPT-unset} gcm=${GCM_INTERACTIVE-unset} args=$*" > "$rec"; }
git_push_bounded "$TMPDIR_T/a" origin main >/dev/null 2>&1; rc=$?
unset -f timeout git
if [ "$rc" -eq 0 ] && grep -q "prompt=0 gcm=never" "$rec" \
    && grep -q "http.lowSpeedLimit=1000" "$rec" && grep -q "http.lowSpeedTime=120" "$rec"; then
    pass "(c) prompt-disabling env and low-speed config present"
else
    fail "(c) env check rc=$rc rec='$(cat "$rec" 2>/dev/null)'"
fi

[ "$fails" -eq 0 ]
