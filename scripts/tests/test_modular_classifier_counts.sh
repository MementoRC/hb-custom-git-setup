#!/usr/bin/env bash
# Harness for format_modular_classifier_summary (extracted from hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_modular_classifier_counts.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

# shellcheck disable=SC1090
source <(sed -n "/^format_modular_classifier_summary() {/,/^}/p" "$SCRIPT")

declare -F format_modular_classifier_summary >/dev/null || {
    echo "FAIL: format_modular_classifier_summary not extracted from $SCRIPT"
    exit 1
}

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# check <name> <array_name> <expected_output>
check() {
    local name="$1" arr="$2" want="$3" got
    got="$(format_modular_classifier_summary "$arr")"
    if [ "$got" = "$want" ]; then
        pass "$name"
    else
        fail "$name"
        echo "--- want"; printf '%s\n' "$want"
        echo "--- got"; printf '%s\n' "$got"
    fi
}

# Inserted out of order on purpose: output must be C-locale sorted.
declare -A populated=(
    ["style-only-region"]=0 ["modular-owned"]=2 ["ci-base-subset"]=54
    ["generated-file"]=1 ["format-only"]=0 ["modular-subset"]=0
)
check "populated: sorted, zeros kept, total" populated "modular-merge classifier: ci-base-subset=54
modular-merge classifier: format-only=0
modular-merge classifier: generated-file=1
modular-merge classifier: modular-owned=2
modular-merge classifier: modular-subset=0
modular-merge classifier: style-only-region=0
modular-merge classifier total=57"

declare -A all_zero=(
    ["format-only"]=0 ["ci-base-subset"]=0 ["modular-subset"]=0
    ["modular-owned"]=0 ["style-only-region"]=0 ["generated-file"]=0
)
check "all zero: every classifier listed, total=0" all_zero "modular-merge classifier: ci-base-subset=0
modular-merge classifier: format-only=0
modular-merge classifier: generated-file=0
modular-merge classifier: modular-owned=0
modular-merge classifier: modular-subset=0
modular-merge classifier: style-only-region=0
modular-merge classifier total=0"

declare -A empty=()
check "empty array: total line only" empty "modular-merge classifier total=0"

# Guard against a check helper that ignores its inputs: two different arrays
# must yield different output.
if [ "$(format_modular_classifier_summary populated)" != "$(format_modular_classifier_summary all_zero)" ]; then
    pass "inputs are honoured (populated != all_zero)"
else
    fail "inputs are honoured (populated != all_zero)"
fi

[ "$fails" -eq 0 ]
