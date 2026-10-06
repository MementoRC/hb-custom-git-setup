#!/usr/bin/env bash
# Harness for typing-style normalization in the conflict resolvers:
#   conflict_is_format_only          (whole-file equality)
#   conflict_regions_style_only      (region-level; each side may also carry
#   resolve_conflict_regions_theirs   unique non-conflicting edits)
# The tracking script runs main() on source, so extract functions via sed.
#
# Needs `ruff` on PATH. The script's `pixi run -e ci ruff` fallback cannot work
# here because the fixture repo lives in a temp dir with no pixi manifest, so
# run the harness inside the ci env:
#   cd /home/memento/PycharmProjects/Hummingbot/hummingbot && \
#     pixi run -e ci bash ../custom_git_setup/scripts/tests/test_conflict_typing_style.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! command -v ruff >/dev/null 2>&1; then
    echo "FAIL: ruff not on PATH (run via pixi run -e ci, see header)"; exit 1
fi

for fn in conflict_is_format_only conflict_regions_variant \
          conflict_regions_style_only resolve_conflict_regions_theirs; do
    # shellcheck disable=SC1090
    source <(sed -n "/^${fn}() {/,/^}/p" "$SCRIPT")
done

fail=0
check() {  # check <name> <expected rc> <actual rc>
    if [ "$2" -eq "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (expected rc=$2 got rc=$3)"; fail=1; fi
}

# make_conflict <dir> <base> <ours> <theirs> [conflictStyle] : leaves a mod.py
# merge conflict in <dir>.
make_conflict() {
    local d="$1" base_body="$2" ours_body="$3" theirs_body="$4" style="${5:-merge}"
    git init -q -b main "$d"
    (
        cd "$d" || exit 1
        git config user.email t@t; git config user.name t; git config commit.gpgsign false
        git config merge.conflictStyle "$style"
        printf '%s' "$base_body" > mod.py
        git add mod.py; git commit -q -m base
        git checkout -q -b theirs
        printf '%s' "$theirs_body" > mod.py
        git commit -q -am theirs
        git checkout -q main
        printf '%s' "$ours_body" > mod.py
        git commit -q -am ours
        git merge -q --no-edit theirs >/dev/null 2>&1
        true
    )
    if ! (cd "$d" && git ls-files -u -- mod.py | grep -q .); then
        echo "FAIL $(basename "$d"): fixture did not produce a conflict"; fail=1
    fi
}

# run_case <name> <base> <ours> <theirs> <expected rc of conflict_is_format_only>
run_case() {
    local d="$TMP/$1"
    make_conflict "$d" "$2" "$3" "$4"
    ( cd "$d" || exit 9; conflict_is_format_only mod.py )
    check "$1" "$5" $?
}

BASE='from typing import Dict, List, Optional


def f(x: Optional[dict] = None) -> Optional[List[int]]:
    return None
'
# Both sides edit the signature lines. Ours keeps Optional (reflowed, no magic
# trailing comma so ruff format collapses it back to one line).
OURS='from typing import Dict, List, Optional


def f(
    x: Optional[dict] = None
) -> Optional[List[int]]:
    return None
'
THEIRS_OK='from typing import Dict


def f(x: dict | None = None) -> list[int] | None:
    return None
'
THEIRS_BAD='from typing import Dict


def f(x: dict | None = {}) -> list[int] | None:
    return None
'

# 1. Pure typing-style difference -> equivalent (resolvable).
run_case typing_style_only "$BASE" "$OURS" "$THEIRS_OK" 0
# 2. Theirs also changes the default None -> {} -> NOT resolvable.
run_case default_changed "$BASE" "$OURS" "$THEIRS_BAD" 1

# --- Region-level cases. Each side also makes a unique edit that git merges
# --- cleanly (several unchanged lines away from the signature conflict).
RBASE='from typing import Dict, List, Optional

A = 1
B = 1
C = 1
THEIRS_KNOB = 1
D = 1
D2 = 1
D3 = 1


def f(x: Optional[dict] = None) -> Optional[List[int]]:
    return None


E = 1
F = 1
G = 1
H = 1
OURS_KNOB = 1
'
ROURS='from typing import Dict, Optional, List

A = 1
B = 1
C = 1
THEIRS_KNOB = 1
D = 1
D2 = 1
D3 = 1


def f(
    x: Optional[dict] = None
) -> Optional[List[int]]:
    return None


E = 1
F = 1
G = 1
H = 1
OURS_KNOB = 2
'
RTHEIRS='from typing import Dict

A = 1
B = 1
C = 1
THEIRS_KNOB = 2
D = 1
D2 = 1
D3 = 1


def f(x: dict | None = None) -> list[int] | None:
    return None


E = 1
F = 1
G = 1
H = 1
OURS_KNOB = 1
'
EMPTY='{}'
RTHEIRS_BAD="${RTHEIRS/= None)/= $EMPTY)}"

# region_case <name> <theirs> <conflictStyle> <exp format-only rc> <exp regions rc>
region_case() {
    local d="$TMP/$1"
    make_conflict "$d" "$RBASE" "$ROURS" "$2" "$3"
    ( cd "$d" || exit 9; conflict_is_format_only mod.py )
    check "$1: format-only" "$4" $?
    ( cd "$d" || exit 9; conflict_regions_style_only mod.py )
    check "$1: regions-style-only" "$5" $?
}

for style in merge diff3; do
    region_case "regions_ok_$style" "$RTHEIRS" "$style" 1 0
    # Semantic difference inside the region (default None -> {}).
    region_case "regions_semantic_$style" "$RTHEIRS_BAD" "$style" 1 1
done

# The resolve helper keeps BOTH unique edits, takes theirs' signature, and
# leaves no conflict markers.
d="$TMP/regions_ok_merge"
( cd "$d" || exit 9; resolve_conflict_regions_theirs mod.py ); check "resolve helper rc" 0 $?
res="$(cat "$d/mod.py")"
has() { grep -qF -- "$1" <<< "$res"; }
has 'OURS_KNOB = 2'   ; check "resolved keeps ours' unique edit" 0 $?
has 'THEIRS_KNOB = 2' ; check "resolved keeps theirs' unique edit" 0 $?
has 'def f(x: dict | None = None) -> list[int] | None:' ; check "resolved has theirs' signature" 0 $?
grep -qE '^(<<<<<<<|=======|>>>>>>>)' <<< "$res"; check "resolved has no markers" 1 $?

# Undefined-name guard: normalization would hide a still-used Optional in the
# merged (non-conflicting) part, but raw theirs' import region dropped it.
GBASE='from typing import Dict, List, Optional


def g(v: Optional[int]) -> int:
    return v or 0
'
GOURS='from typing import Optional, List, Dict


def g(v: Optional[int]) -> int:
    return v or 0
'
GTHEIRS='from typing import Dict


def g(v: Optional[int]) -> int:
    return v or 0
'
d="$TMP/undefined_name_guard"
make_conflict "$d" "$GBASE" "$GOURS" "$GTHEIRS"
( cd "$d" || exit 9; conflict_regions_style_only mod.py )
check "undefined-name guard (raw theirs lacks Optional import)" 1 $?

# Malformed (unterminated) markers -> not resolvable.
printf '<<<<<<< ours\nx = 1\n=======\nx = 2\n' > "$TMP/bad.py"
conflict_regions_style_only "$TMP/bad.py"; check "malformed markers" 1 $?

exit $fail
