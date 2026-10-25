#!/usr/bin/env bash
# Harness for conflict_modular_loss_is_upstream_provenance.
# The tracking script runs main() on source, so extract the function via sed.
# Usage: bash scripts/tests/test_conflict_upstream_provenance.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"
HB=/home/memento/PycharmProjects/Hummingbot/hummingbot
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
source <(sed -n "/^conflict_modular_loss_is_upstream_provenance() {/,/^}/p" "$SCRIPT")

fail=0
check() {  # check <name> <expected rc> <actual rc>
    if [ "$2" -eq "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (expected rc=$2 got rc=$3)"; fail=1; fi
}

bash -n "$SCRIPT"; check "bash -n hummingbot-branch-tracking.sh" 0 $?

# Synthetic repo: development history holds 'old_upstream'; base holds 'shared'.
D="$TMP/synth"
git init -q -b main "$D"
(
    cd "$D" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    printf 'old_upstream\n' > f.txt; git add f.txt; git commit -q -m up1
    printf 'new_upstream\nresult = compute("alpha", "beta")\n' > f.txt; git commit -q -am up2
    git update-ref refs/remotes/origin/development HEAD
    git checkout -q -b base_b; printf 'shared\nnew_upstream\n' > f.txt; git commit -q -am base
    git checkout -q -b modular_ok;  printf 'shared\nold_upstream\n' > f.txt; git commit -q -am m_ok
    git checkout -q base_b
    git checkout -q -b modular_reflow; printf "shared\nresult = compute(\n    'alpha',\n    'beta',\n)\n" > f.txt; git commit -q -am m_rf
    git checkout -q base_b
    git checkout -q -b modular_bad; printf 'shared\nmodular_authored\n' > f.txt; git commit -q -am m_bad
    git checkout -q base_b
    git checkout -q -b cibase;      printf 'shared\nnew_upstream\ntransformed\n' > f.txt; git commit -q -am ci
)

run_synth() {  # run_synth <ours_ref>
    ( cd "$D" || exit 9
      conflict_modular_loss_is_upstream_provenance f.txt "$1:f.txt" "cibase:f.txt" "base_b:f.txt" )
}

run_synth modular_ok;  check "synthetic: dropped lines are upstream history -> 0" 0 $?
run_synth modular_reflow; check "synthetic: reflowed+requoted upstream line -> 0" 0 $?
run_synth modular_bad; check "synthetic: dropped modular-authored line -> 1" 1 $?
( cd "$D" && conflict_modular_loss_is_upstream_provenance f.txt "cibase:f.txt" "cibase:f.txt" "base_b:f.txt" )
check "synthetic: nothing discarded -> 1" 1 $?

# Real refs: Derive v3 rewrite, modular side is stale upstream text.
F=test/hummingbot/connector/exchange/derive/test_derive_exchange.py
if git -C "$HB" rev-parse --verify --quiet origin/modular >/dev/null \
   && git -C "$HB" rev-parse --verify --quiet origin/ci-base >/dev/null \
   && git -C "$HB" rev-parse --verify --quiet origin/development >/dev/null; then
    MB="$(git -C "$HB" merge-base origin/modular origin/ci-base)"
    ( cd "$HB" || exit 9
      conflict_modular_loss_is_upstream_provenance "$F" "origin/modular:$F" "origin/ci-base:$F" "$MB:$F"
      rc=$?
      if [ "$rc" -ne 0 ]; then
          echo "  loss=$MODULAR_LOSS_COUNT unique=$MODULAR_UNIQUE_COUNT; non-provenance lines:"
          printf '%s\n' "$MODULAR_UNIQUE_LINES" | sed 's/^/    | /'
      fi
      exit $rc )
    check "real refs: derive test_derive_exchange.py -> 0" 0 $?
else
    echo "SKIP real refs: origin/modular, origin/ci-base or origin/development missing in $HB"
fi

exit $fail
