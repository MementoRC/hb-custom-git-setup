#!/usr/bin/env bash
# Harness for get_ci_base_build_mode (extracted from hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_get_ci_base_build_mode.sh
set -u

command -v yq >/dev/null || { echo "FAIL: yq not in PATH" >&2; exit 1; }

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"
REAL_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/configs/branch-tracking.yaml"

# Mirrors the real log_error (common.sh): prints to STDOUT. The helper must
# redirect it to stderr itself so command-substitution captures stay clean.
log_error() { echo "$*"; }

# shellcheck disable=SC1090
source <(sed -n "/^get_ci_base_build_mode() {/,/^}/p" "$SCRIPT")

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

write_cfg() {
    printf 'target_branches:\n  ci-base:\n%s    tracked_branches: []\n' "$1" > "$TMPDIR_T/cfg.yaml"
}

check_value() {
    local name="$1" want="$2" got
    got="$(get_ci_base_build_mode)"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name got='$got' want='$want'"; fi
}

# Runs the helper capturing stdout, stderr and rc separately; asserts rc==1,
# empty stdout and the expected text on stderr.
check_fatal() {
    local name="$1" want_msg="$2" out err rc
    out="$(get_ci_base_build_mode 2>"$TMPDIR_T/err")"; rc=$?
    err="$(cat "$TMPDIR_T/err")"
    if [ "$rc" -eq 1 ] && [ -z "$out" ] && printf '%s' "$err" | grep -q "$want_msg"; then
        pass "$name (rc=$rc)"
    else
        fail "$name rc=$rc out='$out' err='$err'"
    fi
}

BRANCH_CONFIG="$TMPDIR_T/cfg.yaml"

write_cfg "    build_mode: seed
"
check_value "explicit seed" seed

write_cfg "    build_mode: incremental
"
check_value "explicit incremental" incremental

write_cfg ""
check_value "missing key defaults to seed" seed

write_cfg "    build_mode: \"\"
"
check_value "empty string defaults to seed" seed

write_cfg "    build_mode: garbage
"
check_fatal "garbage is fatal" "FATAL: invalid ci-base build_mode"

BRANCH_CONFIG="$TMPDIR_T/does-not-exist.yaml"
check_fatal "nonexistent config is fatal" "FATAL: cannot read"

BRANCH_CONFIG="$REAL_CONFIG"
check_value "real config currently seed (update when flipped in Task 15)" seed

[ "$fails" -eq 0 ]
