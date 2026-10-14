#!/usr/bin/env bash
# Harness for is_logical_conflict_path (extracted from hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_is_logical_conflict_path.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

# shellcheck disable=SC1090
source <(sed -n "/^is_logical_conflict_path() {/,/^}/p" "$SCRIPT")

if ! declare -F is_logical_conflict_path >/dev/null; then
    echo "FAIL could not load is_logical_conflict_path from $SCRIPT"
    exit 1
fi

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

expect_match() {
    if is_logical_conflict_path "$1"; then pass "match: $1"; else fail "should match: $1"; fi
}
expect_no_match() {
    if is_logical_conflict_path "$1"; then fail "should not match: $1"; else pass "no match: $1"; fi
}

expect_match pyproject.toml
expect_match conftest.py
expect_match test/conftest.py
expect_match .github/workflows/x.yml
expect_match .github/CODEOWNERS

expect_no_match hummingbot/foo.py
expect_no_match docs/pyproject.toml.md
expect_no_match docs/pyproject.toml
expect_no_match hummingbot/conftest.py
expect_no_match test/hummingbot/conftest.py
expect_no_match test/conftest.pyc
expect_no_match sub/.github/workflows/x.yml
expect_no_match .githubx/foo
expect_no_match .pre-commit-config.yaml
expect_no_match ""

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$fails FAILED"
exit 1
