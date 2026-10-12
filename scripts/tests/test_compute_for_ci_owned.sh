#!/usr/bin/env bash
# Harness for compute_for_ci_owned (extracted from hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_compute_for_ci_owned.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

# Mirror the real common.sh log_* helpers (stdout).
log_operation() { echo "$*"; }
log_error() { echo "ERROR $*"; }
log_warning() { echo "$*"; }

CI_BASE_SEED_TAG=ci-base-seed-test

# shellcheck disable=SC1090
source <(sed -n "/^compute_for_ci_owned() {/,/^}/p" "$SCRIPT")

if ! declare -F compute_for_ci_owned >/dev/null; then
    echo "FAIL could not load compute_for_ci_owned from $SCRIPT"
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

# merge_branch <tmp-branch> <file> <subject> [extra -m args...]
# Cuts <tmp-branch> from the current branch, commits <file>, merges it --no-ff.
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

publish() { git push -q -f origin ci-base 2>/dev/null; git fetch -q origin; }

check() { # description expected-lines...
    local desc="$1" got want
    shift
    publish
    got="$(compute_for_ci_owned 2>&1)"
    want="$(printf '%s\n' "$@")"
    if [ "$got" = "$want" ]; then pass "$desc"; else fail "$desc: got [$(echo "$got" | tr '\n' ' ')] want [$(echo "$want" | tr '\n' ' ')]"; fi
}

root="$TMPDIR_T/w"
mkdir -p "$root"
git init -q --bare -b ci-base "$root/origin.git"
git clone -q "$root/origin.git" "$root/clone" 2>/dev/null
cd "$root/clone" || exit 1
git config user.name Test
git config user.email test@example.invalid
g checkout -q -b ci-base
commit_file base.txt 0 "D0"

# (e) _for_ci merge BELOW the seed tag
merge_branch old old.txt "Auto-merge _for_ci/Old into ci-base"
git tag "$CI_BASE_SEED_TAG"
check "no merges above seed -> empty"

# (a) two _for_ci merges
merge_branch x a.txt "Auto-merge _for_ci/X into ci-base"
merge_branch y b.txt "Auto-merge _for_ci/Y into ci-base"
check "(a) two merges listed, pre-seed merge not listed (e)" a.txt b.txt

# (d) non-_for_ci first-parent merge
merge_branch dev d.txt "Sync ci-base with development"
check "(d) non-_for_ci merge not listed" a.txt b.txt

# (f) _for_ci-looking merge reachable only via a second parent
g checkout -q -b devside
merge_branch z z.txt "Auto-merge _for_ci/Z into ci-base"
g checkout -q ci-base
g merge -q --no-verify --no-ff devside -m "Sync ci-base with development"
check "(f) second-parent-only merge not listed" a.txt b.txt

# (b) X reverted via trailer
commit_file a.txt reverted "Revert X from ci-base" -m "Reverts-For-Ci: _for_ci/X"
check "(b) revert drops X" b.txt

# (c) X re-merged, now touching c.txt
merge_branch x2 c.txt "Auto-merge _for_ci/X into ci-base"
check "(c) re-merge starts fresh" b.txt c.txt

# (g) conflict-resolved merge: same subject with a git-generated body
merge_branch w e.txt "Auto-merge _for_ci/W into ci-base" -m "# Conflicts:" -m "#	e.txt"
check "(g) conflict-resolved subject with body listed" b.txt c.txt e.txt

# error paths
if compute_for_ci_owned nonexistent/ref >/dev/null 2>&1; then fail "missing ref should return 1"; else pass "missing ref -> 1"; fi
git tag -d "$CI_BASE_SEED_TAG" >/dev/null
if compute_for_ci_owned >/dev/null 2>&1; then fail "missing seed tag should return 1"; else pass "missing seed tag -> 1"; fi

[ "$fails" -eq 0 ]
