#!/bin/bash
###############################################################################
# check_all_subpackages_compat.sh
# --------------------------------
# Run compatibility/quality checks across all 14 hb-* sub-packages.
# Replaces the broken candles-feed-only compat-check pixi task.
#
# For each sub-package, tries tasks in priority order:
#   1. compat-check  (if defined in [tool.pixi.tasks])
#   2. check         (if defined — most sub-packages define this)
#   3. quality       (fallback)
#   4. SKIP          (none found)
#
# Usage:
#   ./check_all_subpackages_compat.sh
#   ./check_all_subpackages_compat.sh --subpackages async-utils,candles-feed
#
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
# Helper: detect which pixi task to run for a sub-package dir
###############################################################################
detect_task() {
    local pyproject="$1/pyproject.toml"
    if [[ ! -f "$pyproject" ]]; then
        echo ""
        return
    fi
    for candidate in compat-check check quality; do
        # grep for the task key in the pixi tasks sections (bare key = or quoted key =)
        if grep -qE "^\s*(\"${candidate}\"|${candidate})\s*[=:{]" "$pyproject"; then
            echo "$candidate"
            return
        fi
    done
    echo ""
}

###############################################################################
# Run checks
###############################################################################
declare -a RESULTS_NAME
declare -a RESULTS_TASK
declare -a RESULTS_STATUS

any_fail=0

for pkg in "${TARGET_SUBPACKAGES[@]}"; do
    pkg_dir="${SUBPACKAGES_DIR}/${pkg}"

    if [[ ! -d "$pkg_dir" ]]; then
        echo "[SKIP] ${pkg}: directory not found at ${pkg_dir}" >&2
        RESULTS_NAME+=("$pkg")
        RESULTS_TASK+=("N/A")
        RESULTS_STATUS+=("SKIP(no-dir)")
        continue
    fi

    task="$(detect_task "$pkg_dir")"

    if [[ -z "$task" ]]; then
        echo "[SKIP] ${pkg}: no compat-check/check/quality task found in pyproject.toml" >&2
        RESULTS_NAME+=("$pkg")
        RESULTS_TASK+=("N/A")
        RESULTS_STATUS+=("SKIP(no-task)")
        continue
    fi

    echo "[RUN]  ${pkg}: pixi run ${task}" >&2
    if (cd "$pkg_dir" && pixi run "$task" 2>&1); then
        RESULTS_NAME+=("$pkg")
        RESULTS_TASK+=("$task")
        RESULTS_STATUS+=("PASS")
    else
        RESULTS_NAME+=("$pkg")
        RESULTS_TASK+=("$task")
        RESULTS_STATUS+=("FAIL")
        any_fail=1
    fi
done

###############################################################################
# Summary table (stdout — greppable)
###############################################################################
printf "\n%-30s %-18s %s\n" "SUBPACKAGE" "TASK" "STATUS"
printf "%-30s %-18s %s\n" "------------------------------" "------------------" "------"
for i in "${!RESULTS_NAME[@]}"; do
    printf "%-30s %-18s %s\n" "${RESULTS_NAME[$i]}" "${RESULTS_TASK[$i]}" "${RESULTS_STATUS[$i]}"
done

if [[ $any_fail -eq 1 ]]; then
    echo "" >&2
    echo "ERROR: one or more sub-packages failed compat check." >&2
    exit 1
fi

echo "" >&2
echo "All checked sub-packages passed." >&2
exit 0
