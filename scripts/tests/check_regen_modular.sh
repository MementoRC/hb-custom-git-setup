#!/usr/bin/env bash
# check_regen_modular.sh -- READ-ONLY what-if check for regenerating `modular`.
#
# Question: if `modular` were REGENERATED like bleeding-edge (fresh from
# origin/ci-base, then merging the enabled modular.tracked_branches from
# configs/branch-tracking.yaml in file order), would the result contain
# everything the current persistent origin/modular has?
#
# Nothing is fetched or pushed. The main checkout, its HEAD and all refs are
# untouched; all work happens in a temporary detached worktree that is always
# cleaned up (trap: merge --abort, worktree remove --force, rm -rf).
#
# Run from the hummingbot checkout:
#   pixi run -e ci bash ../custom_git_setup/scripts/tests/check_regen_modular.sh
#
# Categories for each path where origin/modular differs from REGEN
# (pixi.lock excluded):
#   CIBASE_NEWER  REGEN's blob equals origin/ci-base's, and origin/modular's blob
#                 equals the merge-base(origin/modular, origin/ci-base) blob, i.e.
#                 modular is merely older. Expected and harmless.
#   MODULAR_ONLY  origin/modular changed the path relative to the merge-base and
#                 REGEN lacks that content. DANGEROUS: content that lives on
#                 modular but in no tracked branch; regeneration would lose it.
#   OTHER         anything else (e.g. REGEN has extra content, or REGEN differs
#                 from ci-base for a path modular left alone). Inspect manually.
#
# Exit 0 only if conflicted=0, modular_only=0 and other=0; otherwise 1.
# Report file (first 10 MODULAR_ONLY/OTHER diffs): ${REPORT:-/tmp/regen_modular_report.txt}

set -u

BRANCH_CONFIG="${BRANCH_CONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../configs" && pwd)/branch-tracking.yaml}"
REPORT="${REPORT:-/tmp/regen_modular_report.txt}"
TARGET="modular"

CI_SHA="$(git rev-parse --verify origin/ci-base)" || { echo "origin/ci-base missing" >&2; exit 2; }
MOD_SHA="$(git rev-parse --verify origin/modular)" || { echo "origin/modular missing" >&2; exit 2; }
echo "origin/ci-base  $CI_SHA"
echo "origin/modular  $MOD_SHA"

# Same yq read as hummingbot-branch-tracking.sh (modular enabled entries, file order).
BRANCHES="$(yq -r ".target_branches[\"$TARGET\"].tracked_branches // [] | .[] | select(.enabled == true) | .name" "$BRANCH_CONFIG" 2>/dev/null)"
echo "Enabled $TARGET.tracked_branches (file order):"
if [ -n "$BRANCHES" ]; then sed 's/^/  /' <<<"$BRANCHES"; else echo "  (none)"; fi

TMP="$(mktemp -d)"
WT="$TMP/wt"
cleanup() {
    git -C "$WT" merge --abort >/dev/null 2>&1 || true
    git worktree remove --force "$WT" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

git worktree add --detach "$WT" "$CI_SHA" >/dev/null 2>&1 || { echo "worktree add failed" >&2; exit 2; }

wtgit() {
    git -C "$WT" -c user.email=regen-check@localhost -c user.name=regen-check \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

merged=0
conflicted=0
while IFS= read -r br; do
    [ -z "$br" ] && continue
    if git rev-parse --verify -q "refs/heads/$br" >/dev/null; then
        ref="refs/heads/$br"
    elif git rev-parse --verify -q "refs/remotes/origin/$br" >/dev/null; then
        ref="refs/remotes/origin/$br"
    else
        echo "CONFLICT $br: (branch ref not found)"
        conflicted=$((conflicted + 1))
        continue
    fi
    if wtgit merge --no-ff --no-edit "$ref" >/dev/null 2>&1; then
        echo "MERGED $br"
        merged=$((merged + 1))
    else
        paths="$(wtgit diff --name-only --diff-filter=U | tr '\n' ' ')"
        echo "CONFLICT $br: ${paths:-(none listed)}"
        wtgit merge --abort >/dev/null 2>&1 || true
        conflicted=$((conflicted + 1))
    fi
done <<<"$BRANCHES"

REGEN="$(git -C "$WT" rev-parse HEAD)"
BASE="$(git merge-base origin/modular origin/ci-base)"
echo "REGEN $REGEN  merge-base $BASE"

blob() { git rev-parse -q --verify "$1:$2" 2>/dev/null || echo "-"; }

: >"$REPORT"
diff_paths=0 cibase_newer=0 modular_only=0 other=0
flagged=()

echo "Differing paths (origin/modular -> REGEN, excluding pixi.lock):"
while IFS=$'\t' read -r status path; do
    [ -z "$path" ] && continue
    [ "$path" = "pixi.lock" ] && continue
    diff_paths=$((diff_paths + 1))
    echo "  $status $path"
    r="$(blob "$REGEN" "$path")"
    m="$(blob origin/modular "$path")"
    c="$(blob origin/ci-base "$path")"
    b="$(blob "$BASE" "$path")"
    if [ "$r" = "$c" ] && [ "$m" = "$b" ]; then
        cibase_newer=$((cibase_newer + 1))
    elif [ "$m" != "$b" ] && [ "$m" != "$r" ] && [ "$m" != "-" -o "$b" != "-" ]; then
        modular_only=$((modular_only + 1))
        flagged+=("MODULAR_ONLY $path")
    else
        other=$((other + 1))
        flagged+=("OTHER $path")
    fi
done < <(git diff --name-status --no-renames origin/modular "$REGEN" | grep -v -P '\tpixi\.lock$')

echo "diff_paths=$diff_paths"
echo "SUMMARY merged=$merged conflicted=$conflicted diff_paths=$diff_paths cibase_newer=$cibase_newer modular_only=$modular_only other=$other"

n=0
for item in "${flagged[@]+"${flagged[@]}"}"; do
    echo "$item"
    n=$((n + 1))
    if [ "$n" -le 10 ]; then
        {
            echo "=== $item ==="
            git diff origin/modular "$REGEN" -- "${item#* }"
        } >>"$REPORT" 2>&1
    fi
done
[ "$n" -gt 0 ] && echo "Report: $REPORT"

if [ "$conflicted" -eq 0 ] && [ "$modular_only" -eq 0 ] && [ "$other" -eq 0 ]; then
    exit 0
fi
exit 1
