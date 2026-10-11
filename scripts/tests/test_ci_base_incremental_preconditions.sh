#!/usr/bin/env bash
# Harness for ci_base_incremental_preconditions (extracted from hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_ci_base_incremental_preconditions.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

# Mirror the real common.sh log_* helpers (stdout).
log_operation() { echo "$*"; }
log_error() { echo "ERROR $*"; }
log_warning() { echo "$*"; }

DEVELOPMENT_BRANCH=development
CI_BASE_SEED_TAG=ci-base-seed-test

# shellcheck disable=SC1090
source <(sed -n "/^ci_base_incremental_preconditions() {/,/^}/p" "$SCRIPT")

if ! declare -F ci_base_incremental_preconditions >/dev/null; then
    echo "FAIL could not load ci_base_incremental_preconditions from $SCRIPT"
    exit 1
fi

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

g() { git -c commit.gpgsign=false -c core.hooksPath="$TMPDIR_T/nohooks" "$@"; }
commit_file() { # file content message [extra -m args...]
    local f="$1" c="$2" m="$3"
    shift 3
    echo "$c" > "$f"
    g add "$f"
    g commit -q --no-verify -m "$m" "$@"
}

# Builds a world in $1: bare origin + clone (cwd = clone) with
# development: D0-D1-D2, ci-base: D0-S(seed)-M(merges D1, Dev-Merged: D1), modular = ci-base + 1.
build_world() {
    local root="$1"
    mkdir -p "$root"
    git init -q --bare -b development "$root/origin.git"
    git clone -q "$root/origin.git" "$root/clone" 2>/dev/null
    cd "$root/clone" || exit 1
    git config user.name Test
    git config user.email test@example.invalid
    g checkout -q -b development
    commit_file base.txt 0 "D0"
    D0=$(git rev-parse HEAD)
    g checkout -q -b ci-base
    commit_file ci.txt seed "S"
    git tag "$CI_BASE_SEED_TAG"
    g checkout -q development
    commit_file base.txt 1 "D1"
    D1=$(git rev-parse HEAD)
    commit_file base.txt 2 "D2"
    D2=$(git rev-parse HEAD)
    g checkout -q ci-base
    g merge -q --no-verify --no-ff "$D1" -m "Sync" -m "Dev-Merged: $D1"
    g checkout -q -b modular
    commit_file mod.txt m "modular extra"
    g checkout -q ci-base
    git push -q origin development ci-base modular 2>/dev/null
    git fetch -q origin
}

run_case() { # sets rc and out
    out="$(ci_base_incremental_preconditions 2>&1)"; rc=$?
}

# (a) happy path
build_world "$TMPDIR_T/a"
CI_BASE_LAST_DEV_MERGED=""
ci_base_incremental_preconditions >"$TMPDIR_T/a.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$CI_BASE_LAST_DEV_MERGED" = "$D1" ] && ! grep -q WARNING "$TMPDIR_T/a.out"; then
    pass "happy path (rc=0, D set)"
else
    fail "happy path rc=$rc D='$CI_BASE_LAST_DEV_MERGED' expected=$D1"
fi

# (b) origin/ci-base missing
build_world "$TMPDIR_T/b"
git push -q origin --delete ci-base 2>/dev/null
git fetch -q --prune origin
run_case
if [ "$rc" -eq 1 ]; then pass "ci-base missing -> 1"; else fail "ci-base missing rc=$rc: $out"; fi

# (c) seed tag not an ancestor of origin/ci-base
build_world "$TMPDIR_T/c"
g checkout -q --orphan stray
commit_file x.txt x "stray"
git tag -f "$CI_BASE_SEED_TAG" >/dev/null
g checkout -q ci-base
run_case
if [ "$rc" -eq 1 ]; then pass "seed not ancestor -> 1"; else fail "seed not ancestor rc=$rc: $out"; fi

# (d) no Dev-Merged trailer
build_world "$TMPDIR_T/d"
git push -q -f origin "${D0}:refs/heads/ci-base" 2>/dev/null
g checkout -q ci-base
g reset -q --hard "$CI_BASE_SEED_TAG"
git push -q -f origin ci-base 2>/dev/null
git fetch -q origin
run_case
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q -- '--reseed'; then
    pass "no trailer -> 1 (mentions --reseed)"
else
    fail "no trailer rc=$rc: $out"
fi

# (e) D not an ancestor of origin/development (history rewritten)
build_world "$TMPDIR_T/e"
g checkout -q development
g reset -q --hard "$D0"
commit_file base.txt rewritten "D1-rewritten"
git push -q -f origin development 2>/dev/null
git fetch -q origin
g checkout -q ci-base
run_case
if [ "$rc" -eq 1 ]; then pass "D not ancestor of development -> 1"; else fail "rewritten dev rc=$rc: $out"; fi

# (f) D newer than merge-base (trailer points past what ci-base merged)
build_world "$TMPDIR_T/f"
g checkout -q ci-base
commit_file ci.txt fix "claims D2" -m "Dev-Merged: $D2"
git push -q origin ci-base 2>/dev/null
git fetch -q origin
run_case
if [ "$rc" -eq 1 ]; then pass "D newer than merge-base -> 1"; else fail "D > merge-base rc=$rc: $out"; fi

# (g) origin/ci-base not an ancestor of origin/modular -> warning, rc 0
build_world "$TMPDIR_T/g"
g checkout -q "$D0" 2>/dev/null
g checkout -q -B modular "$D0"
commit_file other.txt o "modular diverged"
git push -q -f origin modular 2>/dev/null
git fetch -q origin
g checkout -q ci-base
CI_BASE_LAST_DEV_MERGED=""
ci_base_incremental_preconditions >"$TMPDIR_T/g.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q WARNING "$TMPDIR_T/g.out" && [ "$CI_BASE_LAST_DEV_MERGED" = "$D1" ]; then
    pass "modular diverged -> 0 with warning"
else
    fail "modular diverged rc=$rc: $(cat "$TMPDIR_T/g.out")"
fi

[ "$fails" -eq 0 ]
