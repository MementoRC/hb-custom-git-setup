#!/usr/bin/env bash
# Harness for ci_base_generated_path (extracted from hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_ci_base_generated_path.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"
# shellcheck disable=SC1090
source <(sed -n "/^ci_base_generated_path() {/,/^}/p" "$SCRIPT")

fails=0
check() {
    local path="$1" want="$2" rc
    ci_base_generated_path "$path"; rc=$?
    if [ "$rc" -eq "$want" ]; then
        echo "PASS $path rc=$rc"
    else
        echo "FAIL $path rc=$rc want=$want"; fails=$((fails + 1))
    fi
}

check pixi.lock 0
check pyproject.toml 1
check sub/pixi.lock 1
check pixi.lock.bak 1

[ "$fails" -eq 0 ]
