#!/usr/bin/env bash
# Harness for lint_branch_tracking_parents (extracted from common.sh).
# Fixture YAML plus the real config (asserts zero TIER_ORDER findings).
# Usage: pixi run bt-test test_lint_branch_tracking_parents
set -u

COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
REAL_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/configs/branch-tracking.yaml"

# shellcheck disable=SC1090
source <(sed -n "/^lint_branch_tracking_parents() {/,/^}/p" "$COMMON")
if ! declare -F lint_branch_tracking_parents >/dev/null; then
    echo "FAIL could not load lint_branch_tracking_parents from $COMMON"
    exit 1
fi
log_warning() { echo "WARN $1"; }

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT
fails=0
CFG="$TMPDIR_T/bt.yaml"
OUT="$TMPDIR_T/out.txt"

# expect_finding <label> <substring>   (empty substring = expect no findings)
expect_finding() {
    local label="$1" want="$2" got
    lint_branch_tracking_parents "$CFG" "$OUT" >/dev/null
    got="$(cat "$OUT")"
    if [ -z "$want" ]; then
        [ -z "$got" ] && echo "PASS $label" || { echo "FAIL $label: unexpected '$got'"; fails=$((fails + 1)); }
    elif [[ "$got" == *"$want"* ]]; then
        echo "PASS $label"
    else
        echo "FAIL $label: want '$want' got '$got'"
        fails=$((fails + 1))
    fi
}

cat > "$CFG" <<'EOF'
target_branches:
  modular:
    tracked_branches:
      - {name: feat-parent, enabled: true}
      - {name: feat-child, enabled: true, parent: feat-parent}
EOF
expect_finding "(a) feature child with feature parent: clean" ""

cat > "$CFG" <<'EOF'
target_branches:
  modular:
    tracked_branches:
      - {name: infra-p, tier: infrastructure, enabled: true}
      - {name: feat-child, enabled: true, parent: infra-p}
EOF
expect_finding "(b) feature child with infra parent: clean" ""

cat > "$CFG" <<'EOF'
target_branches:
  modular:
    tracked_branches:
      - {name: feat-p, enabled: true}
      - {name: infra-c, tier: infrastructure, enabled: true, parent: feat-p}
EOF
expect_finding "(c) infra child with feature parent" \
    "TIER_ORDER target=modular branch=infra-c (infrastructure) parent=feat-p (none)"

cat > "$CFG" <<'EOF'
target_branches:
  modular:
    tracked_branches:
      - {name: child, enabled: true, parent: elsewhere}
  bleeding-edge:
    tracked_branches:
      - {name: elsewhere, enabled: true}
EOF
expect_finding "(d) parent only under another target" \
    "PARENT_NOT_IN_LIST target=modular branch=child parent=elsewhere"

cat > "$CFG" <<'EOF'
target_branches:
  modular:
    tracked_branches:
      - {name: child, enabled: true, parent: nowhere}
EOF
expect_finding "(e) parent not registered anywhere" \
    "PARENT_NOT_IN_LIST target=modular branch=child parent=nowhere"

cat > "$CFG" <<'EOF'
target_branches:
  modular:
    tracked_branches:
      - {name: off-parent, enabled: false}
      - {name: child, enabled: true, parent: off-parent}
EOF
expect_finding "(f) enabled child with disabled parent" \
    "PARENT_DISABLED target=modular branch=child parent=off-parent"

lint_branch_tracking_parents "$CFG" "$OUT" >/dev/null
rc=$?
[ "$rc" -eq 0 ] && echo "PASS (g) returns 0 with findings" || { echo "FAIL (g) rc=$rc"; fails=$((fails + 1)); }

lint_branch_tracking_parents "$REAL_CONFIG" "$OUT" >/dev/null
if grep -q '^TIER_ORDER' "$OUT"; then
    echo "FAIL real config has TIER_ORDER findings:"; grep '^TIER_ORDER' "$OUT"
    fails=$((fails + 1))
else
    echo "PASS real config: zero TIER_ORDER findings"
fi
[ -s "$OUT" ] && { echo "INFO other real-config findings:"; sed 's/^/  /' "$OUT"; }

[ "$fails" -eq 0 ] && echo "ALL PASSED"
[ "$fails" -eq 0 ]
