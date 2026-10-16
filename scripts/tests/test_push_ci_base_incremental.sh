#!/usr/bin/env bash
# Harness for push_ci_base (extracted from hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_push_ci_base_incremental.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

log_error() { echo "$*"; }

# push_ci_base routes through git_push_bounded.
# shellcheck disable=SC1091
source "$(dirname "$SCRIPT")/git_push_bounded.sh"

# shellcheck disable=SC1090
source <(sed -n "/^push_ci_base() {/,/^}/p" "$SCRIPT")

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

G() { git -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }

# Fresh bare origin + two clones (A = REPO_PATH under test, B = other writer),
# all on ci-base with one shared base commit.
setup() {
    rm -rf "$TMPDIR_T/origin.git" "$TMPDIR_T/a" "$TMPDIR_T/b"
    G init -q --bare "$TMPDIR_T/origin.git"
    G clone -q "$TMPDIR_T/origin.git" "$TMPDIR_T/a" 2>/dev/null
    G -C "$TMPDIR_T/a" checkout -q -b ci-base
    echo base > "$TMPDIR_T/a/f"
    G -C "$TMPDIR_T/a" add f
    G -C "$TMPDIR_T/a" commit -q -m base
    G -C "$TMPDIR_T/a" push -q origin ci-base 2>/dev/null
    G clone -q -b ci-base "$TMPDIR_T/origin.git" "$TMPDIR_T/b" 2>/dev/null
    REPO_PATH="$TMPDIR_T/a"
}

origin_sha() { git --git-dir="$TMPDIR_T/origin.git" rev-parse ci-base; }
commit_in() { echo "$2" > "$TMPDIR_T/$1/$2"; G -C "$TMPDIR_T/$1" add "$2"; G -C "$TMPDIR_T/$1" commit -q -m "$2"; }

# (a) incremental, local descends from origin -> plain push succeeds.
setup
commit_in a ahead
push_ci_base incremental >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(origin_sha)" = "$(G -C "$TMPDIR_T/a" rev-parse HEAD)" ]; then
    pass "(a) incremental fast-forward push succeeds"
else
    fail "(a) incremental fast-forward rc=$rc"
fi

# (b) incremental, origin moved -> rejected, non-zero, origin unchanged.
setup
commit_in b theirs
G -C "$TMPDIR_T/b" push -q origin ci-base 2>/dev/null
before="$(origin_sha)"
commit_in a mine
out="$(push_ci_base incremental 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(origin_sha)" = "$before" ] \
    && printf '%s' "$out" | grep -q "incremental ci-base push rejected (non-fast-forward)"; then
    pass "(b) incremental non-ff push refused (rc=$rc)"
else
    fail "(b) incremental non-ff rc=$rc origin_changed=$([ "$(origin_sha)" = "$before" ] && echo no || echo yes) out='$out'"
fi

# (c) seed, same divergence -> --force-with-lease succeeds. The real script
# fetches before pushing, so refresh the remote-tracking ref (else the lease
# is stale and git refuses).
setup
commit_in b theirs
G -C "$TMPDIR_T/b" push -q origin ci-base 2>/dev/null
commit_in a mine
G -C "$TMPDIR_T/a" fetch -q origin 2>/dev/null
push_ci_base seed >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(origin_sha)" = "$(G -C "$TMPDIR_T/a" rev-parse HEAD)" ]; then
    pass "(c) seed mode force-with-lease push succeeds"
else
    fail "(c) seed mode rc=$rc"
fi

[ "$fails" -eq 0 ]
