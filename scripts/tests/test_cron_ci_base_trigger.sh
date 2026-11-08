#!/usr/bin/env bash
# Harness for cron_ci_base_trigger and the ci-base STALE / unchanged early
# returns of gate_and_push_branch (extracted from hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_cron_ci_base_trigger.sh
set -u

command -v yq >/dev/null || { echo "FAIL: yq not in PATH" >&2; exit 1; }

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

log_error() { echo "$*"; }
log_warning() { echo "$*"; }
log_detail() { echo "$*"; }

# shellcheck disable=SC1090
source <(sed -n "/^get_ci_base_build_mode() {/,/^}/p;/^select_ci_base_builder() {/,/^}/p;/^cron_ci_base_trigger() {/,/^}/p;/^gate_and_push_branch() {/,/^}/p" "$SCRIPT")
for fn in cron_ci_base_trigger gate_and_push_branch; do
    declare -F "$fn" >/dev/null || { echo "FAIL could not load $fn from $SCRIPT"; exit 1; }
done

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

G() { git -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }
commit_in() { echo "$2" > "$TMPDIR_T/$1/$2"; G -C "$TMPDIR_T/$1" add "$2"; G -C "$TMPDIR_T/$1" commit -q -m "$2"; }

DEVELOPMENT_BRANCH=development
BRANCH_CONFIG="$TMPDIR_T/cfg.yaml"
FORCE_RESEED=false
REBUILD_MODE=false
FAILED_MERGES=()
REPO_PATH="$TMPDIR_T/a"

write_cfg() { printf 'target_branches:\n  ci-base:\n%s    tracked_branches: []\n' "$1" > "$BRANCH_CONFIG"; }

# origin with development and ci-base both at one commit; clone A under test.
# $1 = "ahead" to advance origin/development one commit past ci-base.
setup() {
    rm -rf "$TMPDIR_T/origin.git" "$TMPDIR_T/a" "$TMPDIR_T/b"
    G init -q --bare "$TMPDIR_T/origin.git"
    G clone -q "$TMPDIR_T/origin.git" "$TMPDIR_T/a" 2>/dev/null
    G -C "$TMPDIR_T/a" checkout -q -b development
    commit_in a base
    G -C "$TMPDIR_T/a" push -q origin development 2>/dev/null
    G -C "$TMPDIR_T/a" checkout -q -b ci-base
    G -C "$TMPDIR_T/a" push -q origin ci-base 2>/dev/null
    if [ "${1:-}" = ahead ]; then
        G -C "$TMPDIR_T/a" checkout -q development
        commit_in a newdev
        G -C "$TMPDIR_T/a" push -q origin development 2>/dev/null
        G -C "$TMPDIR_T/a" checkout -q ci-base
    fi
    G -C "$TMPDIR_T/a" fetch -q origin 2>/dev/null
    cd "$REPO_PATH" || exit 1
    FAILED_MERGES=()
}

# --- trigger ------------------------------------------------------------------
setup ahead; write_cfg '    build_mode: incremental
'
out="$(cron_ci_base_trigger)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "1" ]; then pass "(a) dev ahead + incremental -> runs (ahead=1)"; else fail "(a) rc=$rc out='$out'"; fi

setup; write_cfg '    build_mode: incremental
'
out="$(cron_ci_base_trigger)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then pass "(b) dev not ahead -> skipped"; else fail "(b) rc=$rc out='$out'"; fi

setup ahead; write_cfg '    build_mode: seed
'
out="$(cron_ci_base_trigger)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then pass "(c) build_mode seed -> skipped (never seed on cron)"; else fail "(c) rc=$rc out='$out'"; fi

setup ahead; write_cfg '    build_mode: incremental
'
REBUILD_MODE=true
out="$(cron_ci_base_trigger)"; rc=$?
REBUILD_MODE=false
if [ "$rc" -ne 0 ]; then pass "(d) REBUILD_MODE=true -> skipped"; else fail "(d) rc=$rc"; fi

setup ahead; write_cfg '    build_mode: incremental
'
FORCE_RESEED=true
out="$(cron_ci_base_trigger)"; rc=$?
FORCE_RESEED=false
if [ "$rc" -ne 0 ]; then pass "(e) FORCE_RESEED -> skipped"; else fail "(e) rc=$rc"; fi

# --- honest gate reporting ----------------------------------------------------
setup ahead
out="$(gate_and_push_branch ci-base 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "ci-base STALE: origin/development ahead by 1 commits; last ci-base commit .*; run rebuild-now"; then
    pass "(f) stale ci-base -> rc 2 + STALE message"
else
    fail "(f) rc=$rc out='$out'"
fi
# FAILED_MERGES must be updated in the caller's shell (no subshell) for DEGRADED.
setup ahead
gate_and_push_branch ci-base >/dev/null 2>&1
if [ "${#FAILED_MERGES[@]}" -eq 2 ] && [[ "${FAILED_MERGES[1]}" == *"ci-base STALE"* ]]; then
    pass "(g) stale recorded in FAILED_MERGES (-> DEGRADED)"
else
    fail "(g) FAILED_MERGES=(${FAILED_MERGES[*]:-})"
fi

setup
out="$(gate_and_push_branch ci-base 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "ci-base unchanged (.*), not re-gated"; then
    pass "(h) unchanged ci-base -> not re-gated"
else
    fail "(h) rc=$rc out='$out'"
fi

[ "$fails" -eq 0 ]
