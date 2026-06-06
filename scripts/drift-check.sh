#!/bin/bash
###############################################################################
# drift-check.sh — Drift detection for hummingbot bleeding-edge tracked branches
#
# For each ENABLED branch in branch-tracking.yaml matching _for_bleed/,
# _for_bleed_manual/, or _for_ci/ prefixes:
#   - merge-base distance vs development
#   - branch unique commits
#   - dry-run merge conflict file count (via temp worktree)
#   - last commit date
# Emits markdown table to drift_check_latest.txt. Always exits 0.
###############################################################################

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_PATH="${1:-$(pwd)}"
CUSTOM_GIT_PATH="$(dirname "$SCRIPT_DIR")"
CONFIG_PATH="$CUSTOM_GIT_PATH/configs"
LOG_PATH="$CUSTOM_GIT_PATH/logs"
BRANCH_CONFIG="$CONFIG_PATH/branch-tracking.yaml"
DRIFT_LOG="$LOG_PATH/drift_check_latest.txt"
MERGE_TIMEOUT="${DRIFT_MERGE_TIMEOUT:-30}"
TEMP_WORKTREE_PREFIX="/tmp/drift-check-$$"

mkdir -p "$LOG_PATH"

if ! git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1; then
    echo "FATAL: Not a git repository: $REPO_PATH" >&2
    exit 1
fi
if [ ! -f "$BRANCH_CONFIG" ]; then
    echo "FATAL: Config not found: $BRANCH_CONFIG" >&2
    exit 1
fi

get_tracked_branches() {
    if command -v yq >/dev/null 2>&1; then
        yq -r '.. | objects | select(has("tracked_branches")) | .tracked_branches[] | select(.enabled == true) | .name' "$BRANCH_CONFIG" 2>/dev/null
    else
        # Fallback: pair name+enabled by line proximity (within 5 lines)
        awk '
            /^[[:space:]]*-?[[:space:]]*name:[[:space:]]*(_for_bleed|_for_ci|_for_bleed_manual)/ {
                gsub(/.*name:[[:space:]]*/, ""); gsub(/[[:space:]]+$/, "");
                name=$0; have_name=1; lines_since_name=0; next
            }
            have_name { lines_since_name++ }
            have_name && /enabled:[[:space:]]*true/ && lines_since_name < 8 { print name; have_name=0 }
            have_name && /enabled:[[:space:]]*false/ && lines_since_name < 8 { have_name=0 }
            have_name && lines_since_name >= 8 { have_name=0 }
        ' "$BRANCH_CONFIG"
    fi
}

cleanup_wt() {
    local p="$1"
    [ -n "$p" ] && [ -d "$p" ] || return 0
    git -C "$REPO_PATH" worktree remove --force "$p" 2>/dev/null || rm -rf "$p"
    git -C "$REPO_PATH" worktree prune 2>/dev/null || true
}

count_conflicts() {
    local branch="$1"
    local baseline="$2"
    local safe_branch="${branch//\//_}"
    local wt="$TEMP_WORKTREE_PREFIX-$safe_branch"
    cleanup_wt "$wt"
    if ! timeout 10 git -C "$REPO_PATH" worktree add --detach "$wt" "$baseline" >/dev/null 2>&1; then
        cleanup_wt "$wt"
        echo "wt-err"
        return
    fi
    local conflicts=0
    if timeout "$MERGE_TIMEOUT" git -C "$wt" merge --no-commit --no-ff "$branch" >/dev/null 2>&1; then
        conflicts=0
    else
        conflicts=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')
    fi
    git -C "$wt" merge --abort 2>/dev/null || true
    cleanup_wt "$wt"
    echo "$conflicts"
}

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
HEAD_BRANCH=$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
HEAD_SHA=$(git -C "$REPO_PATH" rev-parse --short HEAD 2>/dev/null || echo ????)
DEV_SHA=$(git -C "$REPO_PATH" rev-parse --short development 2>/dev/null || echo ????)
CIBASE_SHA=$(git -C "$REPO_PATH" rev-parse --short ci-base 2>/dev/null || echo ????)

{
    echo "# Drift Check --- $TIMESTAMP"
    echo ""
    echo "Repo HEAD: $HEAD_BRANCH @ $HEAD_SHA"
    echo "Development @ $DEV_SHA | ci-base @ $CIBASE_SHA"
    echo ""
    echo "| Branch | Base | Stale (vs base) | Branch cmts | Conflicts | Last touched |"
    echo "|--------|------|-----------------|-------------|-----------|--------------|"
} > "$DRIFT_LOG"

total=0; stale_clean=0; conflicting=0; fresh=0

while IFS= read -r branch; do
    [ -z "$branch" ] && continue
    # Determine baseline per branch prefix
    case "$branch" in
        _for_ci/*)
            baseline="development"
            ;;
        _for_bleed/*|_for_bleed_manual/*)
            baseline="ci-base"
            ;;
        *)
            baseline="development"
            ;;
    esac
    if ! git -C "$REPO_PATH" rev-parse --verify "$branch" >/dev/null 2>&1; then
        echo "| $branch | $baseline | (missing) | (missing) | (missing) | (missing) |" >> "$DRIFT_LOG"
        continue
    fi
    mb=$(git -C "$REPO_PATH" merge-base "$baseline" "$branch" 2>/dev/null || echo "")
    if [ -z "$mb" ]; then
        echo "| $branch | $baseline | (no-mb) | (no-mb) | (no-mb) | (no-mb) |" >> "$DRIFT_LOG"
        continue
    fi
    total=$((total+1))
    stale=$(git -C "$REPO_PATH" rev-list --count "$mb..$baseline" 2>/dev/null || echo 0)
    bcm=$(git -C "$REPO_PATH" rev-list --count "$mb..$branch" 2>/dev/null || echo 0)
    last=$(git -C "$REPO_PATH" log -1 --format=%ai "$branch" 2>/dev/null | cut -d' ' -f1)
    conflicts=$(count_conflicts "$branch" "$baseline")
    if [ "$conflicts" = "0" ]; then
        fresh=$((fresh+1))
        [ "$stale" -gt 50 ] && stale_clean=$((stale_clean+1))
    elif [ "$conflicts" = "wt-err" ]; then
        : # do not classify
    else
        conflicting=$((conflicting+1))
    fi
    echo "| $branch | $baseline | $stale | $bcm | $conflicts | $last |" >> "$DRIFT_LOG"
done < <(get_tracked_branches)

{
    echo ""
    echo "## Summary"
    echo "- Total enabled branches checked: $total"
    echo "- Stale-but-clean (>50 commits behind, 0 conflicts): $stale_clean — rebase candidates"
    echo "- Conflicting (any): $conflicting — manual triage"
    echo "- Fresh: $fresh"
} >> "$DRIFT_LOG"

tail -n 8 "$DRIFT_LOG"

rm -rf "$TEMP_WORKTREE_PREFIX"* 2>/dev/null
exit 0
