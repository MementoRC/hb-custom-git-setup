#!/usr/bin/env bash
# Harness for the plain-text (.gitignore) path of conflict_side_is_subset.
# The tracking script runs main() on source, so extract the functions via sed.
# Usage: bash scripts/tests/test_conflict_subset_gitignore.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log_detail() { :; }
for fn in conflict_side_is_subset conflict_ci_base_is_subset conflict_modular_is_subset; do
    # shellcheck disable=SC1090
    source <(sed -n "/^${fn}() {/,/^}/p" "$SCRIPT")
done

fail=0
check() {  # check <name> <expected rc> <actual rc>
    if [ "$2" -eq "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (expected rc=$2 got rc=$3)"; fail=1; fi
}

# make_conflict <dir> <ours_extra_lines> <theirs_extra_lines> : leaves a .gitignore merge conflict
make_conflict() {
    local d="$1" ours_lines="$2" theirs_lines="$3"
    git init -q -b main "$d"
    (
        cd "$d" || exit 1
        git config user.email t@t; git config user.name t; git config commit.gpgsign false
        printf 'base\n' > .gitignore
        git add .gitignore; git commit -q -m base
        git checkout -q -b theirs
        printf 'base\n%b' "$theirs_lines" > .gitignore
        git commit -q -am theirs
        git checkout -q main
        printf 'base\n%b' "$ours_lines" > .gitignore
        git commit -q -am ours
        git merge -q --no-edit theirs >/dev/null 2>&1
        true
    )
}

run_case() {  # run_case <name> <ours> <theirs> <exp_theirs_subset_rc> <exp_ours_subset_rc>
    local d="$TMP/$1"
    make_conflict "$d" "$2" "$3"
    ( cd "$d" || exit 9
      conflict_ci_base_is_subset .gitignore; a=$?
      conflict_modular_is_subset .gitignore; b=$?
      exit $((a * 10 + b)) )
    local rc=$?
    check "$1: ci-base-subset(keep ours)" "$4" $((rc / 10))
    check "$1: modular-subset(keep theirs)" "$5" $((rc % 10))
}

# 1. ours subset of theirs -> modular is the subset (keep theirs)
run_case ours_subset 'x\n' 'x\ny\n' 1 0
# 2. theirs subset of ours -> ci-base is the subset (keep ours)
run_case theirs_subset 'x\ny\n' 'x\n' 0 1
# 3. each side has a unique line -> unresolved both ways
run_case mixed 'x\n' 'y\n' 1 1

exit $fail
