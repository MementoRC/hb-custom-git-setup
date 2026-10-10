#!/usr/bin/env bash
# Harness for commit_if_changed (extracted from hummingbot-branch-tracking.sh),
# plus a static check that build_ci_base_from_seed writes the Dev-Merged trailer.
# Usage: bash custom_git_setup/scripts/tests/test_commit_if_changed.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

# Mirror the real common.sh log_* helpers: they print to STDOUT, so the
# helper itself must redirect its log line to stderr.
log_operation() { echo "$*"; }
log_error() { echo "$*"; }

# shellcheck disable=SC1090
source <(sed -n "/^commit_if_changed() {/,/^}/p" "$SCRIPT")

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

if ! declare -F commit_if_changed >/dev/null; then
    echo "FAIL could not load commit_if_changed from $SCRIPT"
    exit 1
fi

REPO="$TMPDIR_T/repo"
git init -q "$REPO"
cd "$REPO" || exit 1
git config user.name "Test"
git config user.email "test@example.invalid"
git config commit.gpgsign false
git config core.hooksPath "$TMPDIR_T/nohooks"  # isolate from any global hooks
echo base > f.txt
git add f.txt
git commit -q -m "init"

count() { git rev-list --count HEAD; }

# 1. Clean index: rc 0, no commit, nothing on stdout.
before=$(count)
out="$(commit_if_changed "empty msg" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(count)" -eq "$before" ] && [ -z "$out" ]; then
    pass "clean index skipped (rc=$rc)"
else
    fail "clean index rc=$rc commits=$before->$(count) stdout='$out'"
fi

# 2. Staged change: rc 0, exactly one commit with the given message.
echo two >> f.txt
git add f.txt
before=$(count)
commit_if_changed "staged msg" >/dev/null 2>&1; rc=$?
subj="$(git log -1 --format=%s)"
if [ "$rc" -eq 0 ] && [ "$(count)" -eq $((before + 1)) ] && [ "$subj" = "staged msg" ]; then
    pass "staged change committed (rc=$rc)"
else
    fail "staged change rc=$rc commits=$before->$(count) subject='$subj'"
fi

# 3. Extra args pass through: --no-verify plus a body paragraph.
echo three >> f.txt
git add f.txt
before=$(count)
commit_if_changed "subject line" --no-verify -m "Body-Line: xyz" >/dev/null 2>&1; rc=$?
subj="$(git log -1 --format=%s)"
body="$(git log -1 --format=%b)"
if [ "$rc" -eq 0 ] && [ "$(count)" -eq $((before + 1)) ] && [ "$subj" = "subject line" ] \
    && printf '%s' "$body" | grep -q '^Body-Line: xyz$'; then
    pass "extra args passed through (rc=$rc)"
else
    fail "extra args rc=$rc commits=$before->$(count) subject='$subj' body='$body'"
fi

# 4. Modified but UNSTAGED file: skipped (helper looks at the index only).
echo four >> f.txt
before=$(count)
commit_if_changed "unstaged msg" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(count)" -eq "$before" ]; then
    pass "unstaged change skipped (rc=$rc)"
else
    fail "unstaged change rc=$rc commits=$before->$(count)"
fi

# 5. Static: build_ci_base_from_seed puts Dev-Merged on both the clean merge
#    and the conflict-resolution commit.
fn="$(sed -n "/^build_ci_base_from_seed() {/,/^}/p" "$SCRIPT")"
n=$(printf '%s\n' "$fn" | grep -c -- '-m "Dev-Merged: \$dev_sha"')
merge_ok=$(printf '%s\n' "$fn" | grep -A3 'git merge --no-verify "origin/' | grep -c 'Dev-Merged:')
commit_ok=$(printf '%s\n' "$fn" | grep -A3 'git commit --no-verify' | grep -c 'Dev-Merged:')
rev_ok=$(printf '%s\n' "$fn" | grep -c 'dev_sha=$(git rev-parse "origin/$DEVELOPMENT_BRANCH")')
if [ "$n" -eq 2 ] && [ "$merge_ok" -ge 1 ] && [ "$commit_ok" -ge 1 ] && [ "$rev_ok" -eq 1 ]; then
    pass "Dev-Merged trailer on clean + conflict paths"
else
    fail "Dev-Merged static check n=$n merge=$merge_ok commit=$commit_ok rev=$rev_ok"
fi

[ "$fails" -eq 0 ]
