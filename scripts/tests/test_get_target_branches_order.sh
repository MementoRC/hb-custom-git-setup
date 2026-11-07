#!/usr/bin/env bash
# Harness for get_target_branches (extracted from hummingbot-branch-tracking.sh).
# Asserts pipeline order, no dropped keys, no duplicates. Fixture YAML only.
# Usage: bash custom_git_setup/scripts/tests/test_get_target_branches_order.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

# shellcheck disable=SC1090
source <(sed -n "/^get_target_branches() {/,/^}/p" "$SCRIPT")
if ! declare -F get_target_branches >/dev/null; then
    echo "FAIL could not load get_target_branches from $SCRIPT"
    exit 1
fi

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

BRANCH_CONFIG="$TMPDIR_T/bt.yaml"
cat > "$BRANCH_CONFIG" <<'EOF'
target_branches:
  accelerated: {}
  bleeding-edge: {}
  ci-base: {}
  modular: {}
  overlay: {}
EOF

got="$(get_target_branches | tr '\n' ' ')"
want="ci-base modular bleeding-edge accelerated overlay "
if [ "$got" = "$want" ]; then
    echo "PASS full set in pipeline order"
else
    echo "FAIL full set: got '$got' want '$want'"
    exit 1
fi

cat > "$BRANCH_CONFIG" <<'EOF'
target_branches:
  zeta: {}
  modular: {}
  bleeding-edge: {}
EOF
got="$(get_target_branches | tr '\n' ' ')"
want="modular bleeding-edge zeta "
if [ "$got" = "$want" ]; then
    echo "PASS missing tiers omitted, unknown appended"
else
    echo "FAIL subset: got '$got' want '$want'"
    exit 1
fi
echo "ALL PASSED"
