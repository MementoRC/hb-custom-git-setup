#!/bin/bash
###############################################################################
# test_all_subpackages.sh
# -----------------------
# Run `pixi run test` across all 14 hb-* sub-packages.
# Prints per-sub-package PASS/FAIL/SKIP + duration_ms (one line each).
#
# Usage:
#   ./test_all_subpackages.sh
#   ./test_all_subpackages.sh --subpackages async-utils,candles-feed
#   ./test_all_subpackages.sh --fail-fast
#
# Output is greppable: each result line starts with [PASS], [FAIL], or [SKIP].
# Exit 0 if all ran sub-packages pass; exit 1 if any fail.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBPACKAGES_DIR="$(cd "${SCRIPT_DIR}/../../hummingbot/sub-packages" && pwd)"

ALL_SUBPACKAGES=(
    async-utils
    candles-feed
    connector-utils
    data-type-primitives
    event-bus
    liquidations-feed
    logger
    market-connector
    market-data
    market-simulator
    rate-oracle
    remote-iface
    strategy-framework
    web-assistant
)

###############################################################################
# Parse arguments
###############################################################################
FILTER_SUBPACKAGES=()
FAIL_FAST=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subpackages)
            IFS=',' read -ra FILTER_SUBPACKAGES <<< "$2"
            shift 2
            ;;
        --subpackages=*)
            IFS=',' read -ra FILTER_SUBPACKAGES <<< "${1#*=}"
            shift
            ;;
        --fail-fast)
            FAIL_FAST=1
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ ${#FILTER_SUBPACKAGES[@]} -gt 0 ]]; then
    TARGET_SUBPACKAGES=("${FILTER_SUBPACKAGES[@]}")
else
    TARGET_SUBPACKAGES=("${ALL_SUBPACKAGES[@]}")
fi

###############################################################################
# Helper: check whether `test` task exists in pyproject.toml
###############################################################################
has_test_task() {
    local pyproject="$1/pyproject.toml"
    [[ -f "$pyproject" ]] && grep -qE "^\s*(\"test\"|test)\s*[=:{]" "$pyproject"
}

###############################################################################
# Run tests
###############################################################################
declare -a RESULTS_NAME
declare -a RESULTS_STATUS
declare -a RESULTS_DURATION

any_fail=0

for pkg in "${TARGET_SUBPACKAGES[@]}"; do
    pkg_dir="${SUBPACKAGES_DIR}/${pkg}"

    if [[ ! -d "$pkg_dir" ]]; then
        echo "[SKIP] ${pkg} duration_ms=0 reason=no-dir" >&2
        RESULTS_NAME+=("$pkg")
        RESULTS_STATUS+=("SKIP(no-dir)")
        RESULTS_DURATION+=("0")
        continue
    fi

    if ! has_test_task "$pkg_dir"; then
        echo "[SKIP] ${pkg} duration_ms=0 reason=no-test-task" >&2
        RESULTS_NAME+=("$pkg")
        RESULTS_STATUS+=("SKIP(no-task)")
        RESULTS_DURATION+=("0")
        continue
    fi

    echo "[RUN]  ${pkg}: pixi run test" >&2
    t_start="$(date +%s%3N)"

    if (cd "$pkg_dir" && pixi run test 2>&1); then
        t_end="$(date +%s%3N)"
        duration=$(( t_end - t_start ))
        RESULTS_NAME+=("$pkg")
        RESULTS_STATUS+=("PASS")
        RESULTS_DURATION+=("$duration")
    else
        t_end="$(date +%s%3N)"
        duration=$(( t_end - t_start ))
        RESULTS_NAME+=("$pkg")
        RESULTS_STATUS+=("FAIL")
        RESULTS_DURATION+=("$duration")
        any_fail=1
        if [[ $FAIL_FAST -eq 1 ]]; then
            echo "FAIL-FAST triggered on ${pkg}" >&2
            break
        fi
    fi
done

###############################################################################
# Summary table (stdout — greppable)
###############################################################################
printf "\n%-30s %-16s %s\n" "SUBPACKAGE" "STATUS" "DURATION_MS"
printf "%-30s %-16s %s\n" "------------------------------" "----------------" "-----------"
for i in "${!RESULTS_NAME[@]}"; do
    printf "%-30s %-16s %s\n" "${RESULTS_NAME[$i]}" "${RESULTS_STATUS[$i]}" "${RESULTS_DURATION[$i]}"
done

if [[ $any_fail -eq 1 ]]; then
    echo "" >&2
    echo "ERROR: one or more sub-packages failed tests." >&2
    exit 1
fi

echo "" >&2
echo "All tested sub-packages passed." >&2
exit 0
