#!/usr/bin/env bash
# Harness for merge_ci_base_into_modular (extracted from
# hummingbot-branch-tracking.sh). Local fixture repo only; no network.
# Usage: bash custom_git_setup/scripts/tests/test_cron_ci_base_into_modular.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

log_operation() { echo "$*"; }
log_warning() { echo "$*"; }
log_error() { echo "$*"; }

log_detail() { echo "$*"; }
# modular_owned_paths comes from the live config (yq); no path is owned here.
modular_owns_path() { return 1; }
declare -A MCR_COUNTS=()
declare -A MCR_RESOLVED_BY=()

# The classifier chain the cron merge now shares with sync_modular_branch.
for fn in merge_ci_base_into_modular classify_and_resolve_modular_conflicts \
          ci_base_generated_path conflict_is_format_only py_pair_format_equivalent \
          conflict_gitignore_pattern_subset conflict_side_is_subset \
          conflict_ci_base_is_subset conflict_modular_is_subset \
          conflict_regions_variant conflict_regions_style_only \
          resolve_conflict_regions_theirs conflict_modular_loss_is_upstream_provenance \
          conflict_regions_import_only _modular_f_diagnostics \
          conflict_import_regions_ours resolve_conflict_regions_ours; do
    # shellcheck disable=SC1090
    source <(sed -n "/^${fn}() {/,/^}/p" "$SCRIPT")
    if ! declare -F "$fn" >/dev/null; then
        echo "FAIL could not load $fn from $SCRIPT"
        exit 1
    fi
done

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false

export RUN_LOG_DIR="$TMPDIR_T/runlog"
mkdir -p "$RUN_LOG_DIR"

# new_fixture: repo on modular at base commit; origin/ci-base == base.
new_fixture() {
    FX="$(mktemp -d "$TMPDIR_T/fx.XXXXXX")"
    git init -q -b modular "$FX"
    cd "$FX" || exit 1
    echo base > f.txt
    git add f.txt
    git commit -q -m base
    git update-ref refs/remotes/origin/ci-base HEAD
    FAILED_MERGES=()
    REBUILD_MODE=false
}

# Commit $1=$2 on a side branch off base, point origin/ci-base at it, return to modular.
ci_base_commit() {
    git checkout -q -b ci-base-side
    echo "$2" > "$1"
    git add "$1"
    git commit -q -m "ci-base $1"
    git update-ref refs/remotes/origin/ci-base HEAD
    git checkout -q modular
    git branch -q -D ci-base-side
}

# Case 1: ci-base ahead, clean merge -> merge commit with origin/ci-base as 2nd parent.
new_fixture
ci_base_commit cfg.txt new
ci_head="$(git rev-parse origin/ci-base)"
merge_ci_base_into_modular >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(git rev-parse HEAD^2 2>/dev/null)" = "$ci_head" ] \
        && [ "${#FAILED_MERGES[@]}" -eq 0 ]; then
    pass "ci-base merged into modular (rc=$rc)"
else
    fail "ci-base merge rc=$rc failed=${#FAILED_MERGES[@]}"
fi

# Case 2: already an ancestor -> no new commit.
before="$(git rev-parse HEAD)"
merge_ci_base_into_modular >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$before" ]; then
    pass "no-op when ci-base already ancestor (rc=$rc)"
else
    fail "ancestor no-op rc=$rc head moved"
fi

# Case 3: same no-op under REBUILD_MODE=true (not skipped, just a no-op).
REBUILD_MODE=true
merge_ci_base_into_modular >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$before" ]; then
    pass "no-op under REBUILD_MODE=true (rc=$rc)"
else
    fail "REBUILD_MODE no-op rc=$rc head moved"
fi

# Case 4: conflict -> aborted, clean tree, failure recorded.
new_fixture
ci_base_commit f.txt ci-base-side
echo modular-side > f.txt
git commit -q -am "modular change"
before="$(git rev-parse HEAD)"
merge_ci_base_into_modular >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ] && [ "$(git rev-parse HEAD)" = "$before" ] \
        && [ -z "$(git status --porcelain)" ] \
        && [ ! -f .git/MERGE_HEAD ] \
        && [ "${#FAILED_MERGES[@]}" -eq 2 ] \
        && [ "${FAILED_MERGES[0]}" = "ci-base -> modular" ] \
        && [[ "${FAILED_MERGES[1]}" == *"conflicted: f.txt"* ]]; then
    pass "conflict aborted and recorded (rc=$rc)"
else
    fail "conflict rc=$rc failed=${#FAILED_MERGES[@]} status=$(git status --porcelain)"
fi

###############################################################################
# Classifier chain in the cron merge (needs ruff on PATH: run via bt-test).
###############################################################################
if ! command -v ruff >/dev/null 2>&1; then
    fail "ruff not on PATH (run via: pixi run bt-test test_cron_ci_base_into_modular)"
fi

# py_conflict_fixture <base> <ours> <theirs>: modular holds <ours>, origin/ci-base
# holds <theirs>, both derived from <base> in mod.py.
py_conflict_fixture() {
    new_fixture
    printf '%s' "$1" > mod.py
    git add mod.py
    git commit -q -m "base mod.py"
    git checkout -q -b ci-base-side
    printf '%s' "$3" > mod.py
    git commit -q -am "ci-base mod.py"
    git update-ref refs/remotes/origin/ci-base HEAD
    git checkout -q modular
    git branch -q -D ci-base-side
    printf '%s' "$2" > mod.py
    git commit -q -am "modular mod.py"
}

OUT="$TMPDIR_T/merge.out"
# check_aborted <label>: merge must abort, record the conflict, leave modular alone.
check_aborted() {
    if [ "$rc" -eq 1 ] && [ "$(git rev-parse HEAD)" = "$before" ] \
            && [ -z "$(git status --porcelain)" ] && [ ! -f .git/MERGE_HEAD ] \
            && [ "${#FAILED_MERGES[@]}" -eq 2 ] \
            && [ "${FAILED_MERGES[0]}" = "ci-base -> modular" ] \
            && [[ "${FAILED_MERGES[1]}" == *"conflicted: mod.py"* ]]; then
        pass "$1 (rc=$rc)"
    else
        fail "$1 rc=$rc by=${MCR_RESOLVED_BY[mod.py]:-none} failed=${#FAILED_MERGES[@]} head_moved=$([ "$(git rev-parse HEAD)" = "$before" ] && echo no || echo yes)"
    fi
}

# Case 5 (a): import-only conflict; ours' import block is ruff-clean -> merged.
A_BASE='from typing import Any, Dict, List
from unittest.mock import patch


def keep_a():
    return 1


def keep_b():
    return 2


def keep_c(x: Any):
    return patch
'
A_OURS='from typing import Any
from unittest.mock import AsyncMock, patch


def keep_a():
    return 1


def keep_b():
    return AsyncMock


def keep_c(x: Any):
    return patch
'
A_THEIRS='from typing import Any, Callable, Dict
from unittest.mock import patch


def keep_a():
    return 11


def keep_b():
    return 2


def keep_c(x: Any):
    return patch
'
py_conflict_fixture "$A_BASE" "$A_OURS" "$A_THEIRS"
before="$(git rev-parse HEAD)"
merge_ci_base_into_modular > "$OUT" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(git rev-parse HEAD)" != "$before" ] \
        && git merge-base --is-ancestor origin/ci-base HEAD \
        && [ "$(git rev-parse HEAD^2)" = "$(git rev-parse origin/ci-base)" ] \
        && [ "${#FAILED_MERGES[@]}" -eq 0 ] && [ -z "$(git status --porcelain)" ] \
        && ! grep -qE '^(<<<<<<<|=======|>>>>>>>)' mod.py \
        && grep -q 'from unittest.mock import AsyncMock, patch' mod.py \
        && grep -q 'return 11' mod.py && grep -q 'return AsyncMock' mod.py \
        && ! grep -q 'Callable' mod.py \
        && [ "${MCR_RESOLVED_BY[mod.py]:-}" = "import-only-region" ] \
        && grep -q 'mod.py: resolved by import-only-region classifier' "$OUT" \
        && ruff check --select F821,F811 --no-cache --quiet mod.py >/dev/null 2>&1; then
    pass "import-only conflict resolved to modular's imports (rc=$rc)"
else
    fail "import-only conflict rc=$rc failed=${#FAILED_MERGES[@]} by=${MCR_RESOLVED_BY[mod.py]:-none}"
fi

# Case 6 (b1): import-only conflict, but ci-base's merged code needs a name
# ours' import block dropped (F821 after taking ours) -> abort as before.
B1_BASE='from typing import Any, Callable


def keep_a():
    return 1


def keep_b():
    return 2


def keep_c(x: Any):
    return x
'
B1_OURS='import os
from typing import Any


def keep_a():
    return 1


def keep_b():
    return 2


def keep_c(x: Any):
    return os.sep
'
B1_THEIRS='from typing import Any, Callable, Dict


def keep_a():
    return 1


def keep_b(cb: Callable):
    return cb


def keep_c(x: Any):
    return x
'
py_conflict_fixture "$B1_BASE" "$B1_OURS" "$B1_THEIRS"
before="$(git rev-parse HEAD)"
merge_ci_base_into_modular > "$OUT" 2>&1
rc=$?
check_aborted "import-only conflict declined when ours leaves an undefined name (F821)"

# Case 7 (b2): ci-base's merged code re-imports a name ours' block already
# imports (F811 after taking ours) -> abort as before.
B2_BASE='from typing import Any


def keep_a():
    return 1


def keep_b():
    return 2


def keep_c(x: Any):
    return x
'
B2_OURS='from os import path
from typing import Any


def keep_a():
    return 1


def keep_b():
    return path


def keep_c(x: Any):
    return x
'
B2_THEIRS='from typing import Any, Dict


def keep_a():
    return 11


def keep_b():
    return 2


def keep_c(x: Any):
    return x


from os import path
'
py_conflict_fixture "$B2_BASE" "$B2_OURS" "$B2_THEIRS"
before="$(git rev-parse HEAD)"
merge_ci_base_into_modular > "$OUT" 2>&1
rc=$?
check_aborted "import-only conflict declined when ours leaves a duplicate import (F811)"

# Case 8 (c): a conflict region holding code (LIMIT), not only imports -> abort.
C_BASE='from typing import Any
LIMIT = 5


def keep_a(x: Any):
    return x
'
C_OURS='from typing import Any
LIMIT = 6


def keep_a(x: Any):
    return x
'
C_THEIRS='from typing import Any
LIMIT = 7


def keep_a(x: Any):
    return x
'
py_conflict_fixture "$C_BASE" "$C_OURS" "$C_THEIRS"
before="$(git rev-parse HEAD)"
merge_ci_base_into_modular > "$OUT" 2>&1
rc=$?
check_aborted "conflict region with a code line is not import-only (aborted)"

# Case 9: ruff unusable -> the import-only rule declines, never guesses.
py_conflict_fixture "$A_BASE" "$A_OURS" "$A_THEIRS"
before="$(git rev-parse HEAD)"
(
    ruff() { return 2; }
    merge_ci_base_into_modular > "$OUT" 2>&1
    echo "rc=$? head_moved=$([ "$(git rev-parse HEAD)" = "$before" ] && echo no || echo yes) failed=${#FAILED_MERGES[@]} merge_head=$([ -f .git/MERGE_HEAD ] && echo yes || echo no)"
) > "$TMPDIR_T/ruff_broken.res"
if [ "$(cat "$TMPDIR_T/ruff_broken.res")" = "rc=1 head_moved=no failed=2 merge_head=no" ]; then
    pass "import-only rule declines when ruff is unusable"
else
    fail "ruff-unusable: $(cat "$TMPDIR_T/ruff_broken.res")"
fi

# Case 10 (d): regressions. Conflicts the rebuild's existing chain resolves
# resolve identically through the shared function (precedence + side taken).
# d1: generated file takes ci-base's version.
new_fixture
echo base > pixi.lock
git add pixi.lock
git commit -q -m "lock base"
ci_base_commit pixi.lock lock-ci-base
echo lock-modular > pixi.lock
git commit -q -am "modular lock"
merge_ci_base_into_modular > "$OUT" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat pixi.lock)" = "lock-ci-base" ] \
        && [ "${MCR_RESOLVED_BY[pixi.lock]:-}" = "generated-file" ] \
        && [ "${MCR_COUNTS[generated-file]}" -eq 1 ] && [ "${MCR_COUNTS[import-only-region]}" -eq 0 ]; then
    pass "generated-file conflict still takes ci-base (rc=$rc)"
else
    fail "generated-file regression rc=$rc by=${MCR_RESOLVED_BY[pixi.lock]:-none}"
fi

# d2: style-only regions take ci-base's regions and keep both sides' unique
# edits (same fixture as test_conflict_typing_style.sh). Its first region is an
# import block, so this also pins precedence: style-only-region beats the
# import-only rule.
R_BASE='from typing import Dict, List, Optional

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
R_OURS='from typing import Dict, Optional, List

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
R_THEIRS='from typing import Dict

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
py_conflict_fixture "$R_BASE" "$R_OURS" "$R_THEIRS"
merge_ci_base_into_modular > "$OUT" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "${MCR_RESOLVED_BY[mod.py]:-}" = "style-only-region" ] \
        && [ "${MCR_COUNTS[style-only-region]}" -eq 1 ] && [ "${MCR_COUNTS[import-only-region]}" -eq 0 ] \
        && grep -q 'def f(x: dict | None = None) -> list\[int\] | None:' mod.py \
        && grep -q 'OURS_KNOB = 2' mod.py && grep -q 'THEIRS_KNOB = 2' mod.py \
        && ! grep -qE '^(<<<<<<<|=======|>>>>>>>)' mod.py; then
    pass "style-only-region conflict resolved as in the rebuild (rc=$rc)"
else
    fail "style-only-region regression rc=$rc by=${MCR_RESOLVED_BY[mod.py]:-none}"
fi

# d3: the shared function itself (what sync_modular_branch calls): rc 1 with
# the merge left for the caller to abort when a path is logical, rc 0 with the
# resolution staged (not committed) otherwise.
py_conflict_fixture "$C_BASE" "$C_OURS" "$C_THEIRS"
git merge --no-ff --no-commit origin/ci-base >/dev/null 2>&1
classify_and_resolve_modular_conflicts origin/ci-base modular > "$OUT" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && [ -f .git/MERGE_HEAD ] && grep -q 'Logical conflicts merging origin/ci-base into modular' "$OUT"; then
    pass "shared function: logical conflict rc=1, merge left for caller to abort"
else
    fail "shared function logical rc=$rc"
fi
git merge --abort >/dev/null 2>&1

py_conflict_fixture "$A_BASE" "$A_OURS" "$A_THEIRS"
git merge --no-ff --no-commit origin/ci-base >/dev/null 2>&1
classify_and_resolve_modular_conflicts origin/ci-base modular > "$OUT" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ -f .git/MERGE_HEAD ] && [ -z "$(git diff --name-only --diff-filter=U)" ] \
        && [ "${MCR_COUNTS[import-only-region]}" -eq 1 ] \
        && grep -q 'import-only regions mod.py' "$OUT"; then
    pass "shared function: resolved + staged, counts record import-only-region"
else
    fail "shared function resolved rc=$rc counts=${MCR_COUNTS[import-only-region]:-?}"
fi
git merge --abort >/dev/null 2>&1

if [ "$fails" -eq 0 ]; then
    echo "ALL PASSED"
    exit 0
fi
echo "$fails FAILED"
exit 1
