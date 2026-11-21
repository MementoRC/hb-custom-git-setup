#!/usr/bin/env bash
# Harness for gate_changed_files (extracted from hummingbot-branch-tracking.sh):
# the pre-push pre-commit file list must never contain top-level setup.py.
# Usage: bash custom_git_setup/scripts/tests/test_gate_excludes_setup_py.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# shellcheck disable=SC1090
source <(sed -n "/^gate_changed_files() {/,/^}/p" "$SCRIPT")
if ! declare -F gate_changed_files >/dev/null; then
    echo "FAIL could not load gate_changed_files from $SCRIPT"
    exit 1
fi

REPO="$TMPDIR_T/repo"
git init -q "$REPO"
git -C "$REPO" config user.name "Test"
git -C "$REPO" config user.email "test@example.invalid"
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" config core.hooksPath "$TMPDIR_T/nohooks"
cd "$REPO" || exit 1
mkdir -p hummingbot sub-packages/x nested
printf 'version = "1"\n' > setup.py
printf 'a = 1\n' > hummingbot/foo.py
printf 's = 1\n' > sub-packages/x/m.py
printf 'n = 1\n' > nested/setup.py
printf 'lock\n' > pixi.lock
git add -A
git commit -q -m "base"
git update-ref refs/remotes/origin/development HEAD

REPO_PATH="$REPO"
DEVELOPMENT_BRANCH=development

# 1. Nothing changed: empty list.
out="$(gate_changed_files)"
if [ -z "$out" ]; then pass "no changes yields empty list"; else fail "no-change got '$out'"; fi

# 2. Only setup.py changed: empty list (gate skips pre-commit).
printf 'version = "2"\n' > setup.py
git commit -q -am "bump"
out="$(gate_changed_files)"
if [ -z "$out" ]; then pass "setup.py alone yields empty list"; else fail "setup.py-only got '$out'"; fi

# 3. setup.py plus other changes: setup.py dropped, others kept, nested setup.py kept.
printf 'a = 2\n' > hummingbot/foo.py
printf 's = 2\n' > sub-packages/x/m.py
printf 'n = 2\n' > nested/setup.py
printf 'lock2\n' > pixi.lock
git commit -q -am "more"
out="$(gate_changed_files | sort)"
expected="$(printf 'hummingbot/foo.py\nnested/setup.py\n')"
if [ "$out" = "$expected" ]; then
    pass "gate list drops setup.py, sub-packages, pixi.lock; keeps hummingbot/foo.py"
else
    fail "gate list got '$out'"
fi

[ "$fails" -eq 0 ]
