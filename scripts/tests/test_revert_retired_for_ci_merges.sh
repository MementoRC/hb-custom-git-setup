#!/usr/bin/env bash
# Harness for revert_retired_for_ci_merges + get_enabled_for_ci_branches
# (extracted from hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_revert_retired_for_ci_merges.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

# Mirror the real common.sh log_* helpers (stdout).
log_operation() { echo "$*"; }
log_error() { echo "ERROR $*"; }
log_warning() { echo "$*"; }

CI_BASE_SEED_TAG=ci-base-seed-test

# shellcheck disable=SC1090
source <(sed -n "/^compute_for_ci_owned() {/,/^}/p;/^get_enabled_for_ci_branches() {/,/^}/p;/^revert_retired_for_ci_merges() {/,/^}/p" "$SCRIPT")

for fn in compute_for_ci_owned get_enabled_for_ci_branches revert_retired_for_ci_merges; do
    if ! declare -F "$fn" >/dev/null; then
        echo "FAIL could not load $fn from $SCRIPT"
        exit 1
    fi
done

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

# merge_branch <tmp-branch> <file> <subject> [extra -m args...]
merge_branch() {
    local br="$1" f="$2" subj="$3" cur
    shift 3
    cur="$(git rev-parse --abbrev-ref HEAD)"
    g checkout -q -b "$br"
    commit_file "$f" "$br" "work on $f"
    g checkout -q "$cur"
    g merge -q --no-verify --no-ff "$br" -m "$subj" "$@"
    g branch -q -D "$br"
}

# write_cfg <name:enabled-token>...   enabled-token: true | false | missing
write_cfg() {
    {
        echo "target_branches:"
        echo "  ci-base:"
        echo "    tracked_branches:"
        local spec n e
        for spec in "$@"; do
            n="${spec%%:*}"
            e="${spec##*:}"
            echo "      - name: $n"
            [ "$e" = missing ] || echo "        enabled: $e"
        done
    } > "$BRANCH_CONFIG"
}

BRANCH_CONFIG="$TMPDIR_T/cfg.yaml"

# new_repo: fresh repo on ci-base with seed tag, X and Y merged.
new_repo() {
    local root
    root="$(mktemp -d -p "$TMPDIR_T")"
    cd "$root" || exit 1
    git init -q -b ci-base .
    git config user.name Test
    git config user.email test@example.invalid
    git config commit.gpgsign false
    commit_file base.txt 0 "D0"
    git tag -f "$CI_BASE_SEED_TAG" >/dev/null
    merge_branch x x.txt "Auto-merge _for_ci/X into ci-base"
    merge_branch y y.txt "Auto-merge _for_ci/Y into ci-base"
}

owned() { compute_for_ci_owned HEAD 2>&1 | tr '\n' ' '; }

# ---------- (a) both enabled -> no-op
new_repo
write_cfg _for_ci/X:true _for_ci/Y:true
before="$(git rev-parse HEAD)"
revert_retired_for_ci_merges >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$before" ]; then pass "(a) all enabled -> no-op"; else fail "(a) rc=$rc"; fi

# ---------- (b) X disabled -> reverted
write_cfg _for_ci/X:false _for_ci/Y:true
revert_retired_for_ci_merges >/dev/null 2>&1; rc=$?
trailer="$(git log -1 --format='%(trailers:key=Reverts-For-Ci,valueonly)' | tr -d '[:space:]')"
subj="$(git log -1 --format=%s)"
if [ "$rc" -eq 0 ] && [ ! -e x.txt ] && [ -e y.txt ] && [ "$trailer" = "_for_ci/X" ] \
    && [ "$subj" = "Revert retired _for_ci/X from ci-base" ] \
    && [ "$(git rev-list --count "$before..HEAD")" -eq 1 ]; then
    pass "(b) disabled X reverted in one trailer commit, Y intact"
else
    fail "(b) rc=$rc trailer=$trailer subj=$subj"
fi
if [ "$(owned)" = "y.txt " ]; then pass "(b) compute_for_ci_owned no longer lists X"; else fail "(b) owned=[$(owned)]"; fi

# ---------- (c) re-run -> no-op
before="$(git rev-parse HEAD)"
revert_retired_for_ci_merges >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$before" ]; then pass "(c) re-run is a no-op"; else fail "(c) rc=$rc"; fi

# ---------- (d) X removed from yaml entirely
new_repo
write_cfg _for_ci/Y:true
revert_retired_for_ci_merges >/dev/null 2>&1; rc=$?
trailer="$(git log -1 --format='%(trailers:key=Reverts-For-Ci,valueonly)' | tr -d '[:space:]')"
if [ "$rc" -eq 0 ] && [ ! -e x.txt ] && [ -e y.txt ] && [ "$trailer" = "_for_ci/X" ]; then
    pass "(d) X removed from yaml -> reverted"
else
    fail "(d) rc=$rc trailer=$trailer"
fi

# ---------- (e) X merged twice, then disabled
new_repo
merge_branch x2 x2.txt "Auto-merge _for_ci/X into ci-base"
write_cfg _for_ci/X:false _for_ci/Y:true
before="$(git rev-parse HEAD)"
revert_retired_for_ci_merges >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e x.txt ] && [ ! -e x2.txt ] && [ -e y.txt ] \
    && [ "$(git rev-list --count "$before..HEAD")" -eq 1 ]; then
    pass "(e) both X merges reverted in one commit"
else
    fail "(e) rc=$rc"
fi

# ---------- (f) revert conflict -> return 1, HEAD/tree unchanged
new_repo
commit_file x.txt "edited after merge" "later edit of x.txt"
write_cfg _for_ci/X:false _for_ci/Y:true
before="$(git rev-parse HEAD)"
out="$(revert_retired_for_ci_merges 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$(git rev-parse HEAD)" = "$before" ] && [ -z "$(git status --porcelain)" ] \
    && [ -e x.txt ] && echo "$out" | grep -q '_for_ci/X' && echo "$out" | grep -q 'x.txt'; then
    pass "(f) conflict -> 1, tree restored, error names branch and path"
else
    fail "(f) rc=$rc out=[$out]"
fi

# ---------- (h) missing config file -> fail closed
new_repo
before="$(git rev-parse HEAD)"
good_cfg="$BRANCH_CONFIG"
BRANCH_CONFIG="$TMPDIR_T/does-not-exist.yaml"
revert_retired_for_ci_merges >/dev/null 2>&1; rc=$?
BRANCH_CONFIG="$good_cfg"
if [ "$rc" -eq 1 ] && [ "$(git rev-parse HEAD)" = "$before" ] && [ -e x.txt ]; then pass "(h) missing config -> 1, HEAD unchanged"; else fail "(h) rc=$rc"; fi

# ---------- (i) all disabled while X,Y active -> safety valve
write_cfg _for_ci/X:false _for_ci/Y:false
out="$(revert_retired_for_ci_merges 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$(git rev-parse HEAD)" = "$before" ] && [ -e x.txt ] && [ -e y.txt ] \
    && echo "$out" | grep -q 'refusing to revert all 2 active'; then
    pass "(i) empty enabled list -> 1, HEAD unchanged"
else
    fail "(i) rc=$rc out=[$out]"
fi

# ---------- (g) enabled-list helper: enabled / disabled / missing key
write_cfg _for_ci/A:true _for_ci/B:false _for_ci/C:missing _for_ci/D:true
got="$(get_enabled_for_ci_branches | tr '\n' ' ')"
want="$(yq -r '.target_branches["ci-base"].tracked_branches // [] | .[] | select(.enabled == true) | .name' "$BRANCH_CONFIG" | tr '\n' ' ')"
if [ "$got" = "$want" ] && [ "$got" = "_for_ci/A _for_ci/D " ]; then
    pass "(g) enabled list matches original expression (missing key = not enabled)"
else
    fail "(g) got=[$got] want=[$want]"
fi

[ "$fails" -eq 0 ]
