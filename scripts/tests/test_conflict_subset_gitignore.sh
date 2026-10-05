#!/usr/bin/env bash
# Harness for the .gitignore pattern-set path of conflict_side_is_subset.
# The tracking script runs main() on source, so extract the functions via sed.
# Usage: bash scripts/tests/test_conflict_subset_gitignore.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log_detail() { :; }
for fn in conflict_gitignore_pattern_subset conflict_side_is_subset \
          conflict_ci_base_is_subset conflict_modular_is_subset; do
    # shellcheck disable=SC1090
    source <(sed -n "/^${fn}() {/,/^}/p" "$SCRIPT")
done

fail=0
check() {  # check <name> <expected rc> <actual rc>
    if [ "$2" -eq "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (expected rc=$2 got rc=$3)"; fail=1; fi
}

# make_conflict <dir> <base_body> <ours_body> <theirs_body> : leaves a .gitignore
# merge conflict. Bodies are printf '%b'-style strings (full file contents).
make_conflict() {
    local d="$1" base_body="$2" ours_body="$3" theirs_body="$4"
    git init -q -b main "$d"
    (
        cd "$d" || exit 1
        git config user.email t@t; git config user.name t; git config commit.gpgsign false
        printf '%b' "$base_body" > .gitignore
        git add .gitignore; git commit -q -m base
        git checkout -q -b theirs
        printf '%b' "$theirs_body" > .gitignore
        git commit -q -am theirs
        git checkout -q main
        printf '%b' "$ours_body" > .gitignore
        git commit -q -am ours
        git merge -q --no-edit theirs >/dev/null 2>&1
        true
    )
    # The fixture is only valid if it really left an unmerged .gitignore.
    if ! (cd "$d" && git ls-files -u -- .gitignore | grep -q .); then
        echo "FAIL $(basename "$d"): fixture did not produce a conflict"; fail=1
    fi
}

# run_case <name> <base> <ours> <theirs> <exp ci-base-subset rc> <exp modular-subset rc>
run_case() {
    local d="$TMP/$1"
    make_conflict "$d" "$2" "$3" "$4"
    ( cd "$d" || exit 9
      conflict_ci_base_is_subset .gitignore; a=$?
      conflict_modular_is_subset .gitignore; b=$?
      exit $((a * 10 + b)) )
    local rc=$?
    check "$1: ci-base-subset(keep ours)" "$5" $((rc / 10))
    check "$1: modular-subset(keep theirs)" "$6" $((rc % 10))
}

# 1. ours subset of theirs -> modular is the subset (keep theirs)
run_case ours_subset 'base\n' 'base\nx\n' 'base\nx\ny\n' 1 0
# 2. theirs subset of ours -> ci-base is the subset (keep ours)
run_case theirs_subset 'base\n' 'base\nx\ny\n' 'base\nx\n' 0 1
# 3. each side has a unique line -> unresolved both ways
run_case mixed 'base\n' 'base\nx\n' 'base\ny\n' 1 1

# 4. Real-case shape: modular's copy is stale vs the base (dropped two lines,
#    moved .mcp.json) but every one of its patterns exists in ci-base's copy.
BASE4='.idea/\n*.log\n\n/gateway-files/\n.compose.env\n.mcp.json\n'
OURS4='# agent\n.mcp.json\n.idea/\n*.log\n.serena/\n\n# rust\n/hummingbot/rust/target/\n/hummingbot/rust/Cargo.lock\n'
THEIRS4="${BASE4}"'.serena/\n/hummingbot/rust/target/\n/hummingbot/rust/Cargo.lock\n/sub-packages/logs/\n'
run_case stale_modular_copy "$BASE4" "$OURS4" "$THEIRS4" 1 0

# 5. Same pattern set, but the ordered '!' negation lines differ -> unresolved.
run_case negation_order 'a\n' 'a\n!x\nb\n!y\n' 'a\nb\n!y\n!x\n' 1 1

exit $fail
