#!/usr/bin/env bash
# Harness for branch_content_present_in_head (extracted from
# hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_noop_guard.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

# shellcheck disable=SC1090
source <(sed -n "/^branch_content_present_in_head() {/,/^}/p" "$SCRIPT")

if ! declare -F branch_content_present_in_head >/dev/null; then
    echo "FAIL could not load branch_content_present_in_head from $SCRIPT"
    exit 1
fi

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

g() { git -c commit.gpgsign=false -c core.hooksPath="$TMPDIR_T/nohooks" "$@"; }

# new_repo: main with a.txt + gone.txt, checked out on main.
new_repo() {
    local root
    root="$(mktemp -d -p "$TMPDIR_T")"
    cd "$root" || exit 1
    git init -q -b main .
    git config user.name Test
    git config user.email test@example.invalid
    echo "a0" > a.txt
    echo "g0" > gone.txt
    g add -A
    g commit -q --no-verify -m "base"
}

# (a) branch content really in HEAD (cherry-pick equivalent) -> 0
new_repo
g checkout -q -b feat
echo "a1" > a.txt
g commit -qam "feat edit" --no-verify
g checkout -q main
echo "a1" > a.txt
g commit -qam "same edit on main" --no-verify
if branch_content_present_in_head feat; then
    pass "(a) content present in HEAD returns 0"
else
    fail "(a) content present in HEAD returned 1 ($NOOP_GUARD_MISMATCH)"
fi

# (b) branch changes a file HEAD lacks -> 1
new_repo
g checkout -q -b feat
echo "a1" > a.txt
g commit -qam "feat edit" --no-verify
g checkout -q main
if branch_content_present_in_head feat; then
    fail "(b) missing content returned 0"
elif [ "$NOOP_GUARD_MISMATCH" = "a.txt" ]; then
    pass "(b) branch changes file HEAD lacks returns 1"
else
    fail "(b) returned 1 but mismatch was '$NOOP_GUARD_MISMATCH'"
fi

# (c) branch deletes a file HEAD still has -> 1
new_repo
g checkout -q -b feat
g rm -q gone.txt
g commit -q --no-verify -m "feat delete"
g checkout -q main
echo "m1" > a.txt
g commit -qam "main moves on" --no-verify
if branch_content_present_in_head feat; then
    fail "(c) undeleted file returned 0"
else
    pass "(c) branch deletes file HEAD still has returns 1"
fi

# (d) branch deletes a file HEAD also deleted -> 0
new_repo
g checkout -q -b feat
g rm -q gone.txt
g commit -q --no-verify -m "feat delete"
g checkout -q main
g rm -q gone.txt
g commit -q --no-verify -m "main delete"
if branch_content_present_in_head feat; then
    pass "(d) both deleted returns 0"
else
    fail "(d) both deleted returned 1 ($NOOP_GUARD_MISMATCH)"
fi

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$fails FAILED"
exit 1
