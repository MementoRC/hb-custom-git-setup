#!/usr/bin/env bash
# Harness for parse_args (extracted from hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_parse_args.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

# Mirrors the real log_error (common.sh): prints to STDOUT. parse_args must
# redirect it to stderr itself.
log_error() { echo "$*"; }

# shellcheck disable=SC1090
source <(sed -n "/^parse_args() {/,/^}/p" "$SCRIPT")

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# check_args NAME WANT_REBUILD WANT_RESEED WANT_RC ARGS...
check_args() {
    local name="$1" want_rb="$2" want_rs="$3" want_rc="$4"
    shift 4
    local got
    got="$(
        REBUILD_MODE=unset FORCE_RESEED=unset
        parse_args "$@" >/dev/null 2>&1
        rc=$?
        echo "$REBUILD_MODE/$FORCE_RESEED/$rc"
    )"
    if [ "$got" = "$want_rb/$want_rs/$want_rc" ]; then
        pass "$name ($got)"
    else
        fail "$name got='$got' want='$want_rb/$want_rs/$want_rc'"
    fi
}

check_args "no args" false false 0
check_args "--rebuild" true false 0 --rebuild
check_args "--reseed" true true 0 --reseed
check_args "--rebuild --reseed" true true 0 --rebuild --reseed
check_args "--reseed --rebuild" true true 0 --reseed --rebuild

# Unknown arg: rc=1, nothing on stdout, message on stderr.
out="$(parse_args --bogus 2>"$TMPDIR_T/err")"; rc=$?
err="$(cat "$TMPDIR_T/err")"
if [ "$rc" -eq 1 ] && [ -z "$out" ] && printf '%s' "$err" | grep -q "Unknown argument: --bogus"; then
    pass "unknown arg is fatal (rc=$rc)"
else
    fail "unknown arg rc=$rc out='$out' err='$err'"
fi

[ "$fails" -eq 0 ]
