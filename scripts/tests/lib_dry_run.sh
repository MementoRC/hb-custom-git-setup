#!/usr/bin/env bash
# Shared machinery for scripts that run production ci-base builder functions in
# throwaway DETACHED worktrees without mutating any real ref. Source it, do not
# execute it. Extracted from dry_run_incremental_ci_base.sh (plan Task 13); used
# by scripts/check_ci_base_drift.sh (plan Task 14).
#
# Caller contract, before sourcing: define SCRIPT (path of
# hummingbot-branch-tracking.sh), SCRIPT_DIR, COMMON (common.sh), LOG_PATH,
# BRANCH_CONFIG, DEVELOPMENT_BRANCH, CI_BASE_SEED_TAG. After sourcing, call
# dry_run_init, add worktree paths to DRY_RUN_WORKTREES as they are created, and
# load production functions with load_fn.
#
# Deliberately no `set -e` / `set -u` / `pipefail`: the sourced production
# functions are written for a shell with none of them.

TMP=""
REPO=""
DRY_RUN_WORKTREES=()

die() { echo "ERROR: $*" >&2; exit 2; }

dry_run_cleanup() {
    local rc=$?
    cd / || true
    if [ -n "$TMP" ]; then
        local w
        for w in "${DRY_RUN_WORKTREES[@]}"; do
            [ -n "$w" ] && command git -C "$REPO" worktree remove --force "$w" >/dev/null 2>&1
        done
        rm -rf "$TMP"
    fi
    exit "$rc"
}

# Takes the pipeline flock (refuses if held), creates $TMP and RUN_LOG_DIR,
# installs the cleanup traps.
dry_run_init() {
    trap dry_run_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    command -v flock >/dev/null 2>&1 || die "flock not found: cannot verify that no --rebuild is running"
    command -v yq >/dev/null 2>&1 || die "yq not found: run via 'pixi run -e ci bash $0'"
    mkdir -p "$LOG_PATH" || die "cannot create $LOG_PATH"
    exec 9>"$LOG_PATH/.hb_pipeline.lock" || die "cannot open pipeline lock file"
    flock -n 9 || die "pipeline lock held ($LOG_PATH/.hb_pipeline.lock): a --rebuild or cron run is in progress; refusing to start"

    REPO="$(command git rev-parse --show-toplevel)" || die "not in a git repo"
    TMP="$(mktemp -d)" || die "mktemp failed"
    export RUN_LOG_DIR="$TMP/logs"
    mkdir -p "$RUN_LOG_DIR"
    export REPO_PATH="$REPO"
}

# --- logging (stand-ins for common.sh, which would repoint logs/runs/latest) ---
log_operation() { echo "  | $1"; }
log_warning() { echo "  | WARNING: $1"; }
log_error() { echo "  | ERROR: $1"; }
log_detail() { echo "  |     $1"; }
log_step() { echo "  | -> $1"; }
log_section() { echo "== $1"; }
log_result() { if [ "$1" = true ]; then echo "  | OK: $2"; else echo "  | FAIL: $2"; fi; }
indent_push() { :; }
indent_pop() { :; }

# --- load production functions by name -------------------------------------------
# A bare `sed '/^fn() {/,/^}/p'` truncates functions that embed a heredoc with a
# column-0 `}` (run_py312_transforms_for_changed does), so grow the range until
# the text parses as a complete function.
extract_fn() {
    local file="$1" fn="$2" line buf=""
    while IFS= read -r line; do
        buf+="$line"$'\n'
        if [ "$line" = "}" ] && bash -n <<<"$buf" 2>/dev/null; then
            printf '%s' "$buf"
            return 0
        fi
    done < <(sed -n "/^${fn}() {/,\$p" "$file")
    return 1
}
load_fn() {
    local src
    src="$(extract_fn "$1" "$2")" || die "function $2 not found (or unparsable) in $1"
    eval "$src"
}

# --- git isolation ----------------------------------------------------------------
export GIT_CONFIG_COUNT=7
export GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=tag.gpgsign GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=core.hooksPath GIT_CONFIG_VALUE_2=/dev/null
export GIT_CONFIG_KEY_3=merge.ours.driver GIT_CONFIG_VALUE_3=true
export GIT_CONFIG_KEY_4=rerere.enabled GIT_CONFIG_VALUE_4=false
export GIT_CONFIG_KEY_5=gc.auto GIT_CONFIG_VALUE_5=0
export GIT_CONFIG_KEY_6=maintenance.auto GIT_CONFIG_VALUE_6=false
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-dry-run}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-dry-run@localhost}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-dry-run}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-dry-run@localhost}"
export GIT_EDITOR=true GIT_MERGE_AUTOEDIT=no

# Conflicted paths of failed `git merge` calls are appended here (set per stage).
MERGE_CONFLICT_LOG=/dev/null

# Shadows git for the sourced production functions: fetch is a no-op,
# `checkout ci-base` is a no-op (the detached worktree stands in for it), commits
# are never GPG-signed, ref-writing subcommands are refused.
git() {
    case "${1:-}" in
        fetch)
            return 0 ;;
        checkout)
            [ "$#" -eq 2 ] && [ "$2" = "ci-base" ] && return 0
            case "${2:-}" in
                -b|-B) echo "dry-run: refusing 'git $*'" >&2; return 1 ;;
            esac
            command git "$@" ;;
        push|tag|branch|update-ref|symbolic-ref|remote|worktree|config|stash|gc|prune|reflog)
            echo "dry-run: refusing 'git $*'" >&2
            return 1 ;;
        commit)
            local a args=()
            for a in "$@"; do
                case "$a" in
                    -S|--gpg-sign|--gpg-sign=*) ;;
                    *) args+=("$a") ;;
                esac
            done
            command git "${args[@]}" ;;
        merge)
            local rc
            command git "$@"
            rc=$?
            if [ "$rc" -ne 0 ]; then
                command git diff --name-only --diff-filter=U >> "$MERGE_CONFLICT_LOG" 2>/dev/null
            fi
            return "$rc" ;;
        *)
            command git "$@" ;;
    esac
}

# Hash of every ref plus the main checkout's HEAD, compared before/after a run.
snapshot() {
    {
        command git -C "$REPO" for-each-ref --format='%(refname) %(objectname)'
        command git -C "$REPO" symbolic-ref -q HEAD
        command git -C "$REPO" rev-parse HEAD
    } 2>/dev/null | sha256sum | cut -d' ' -f1
}
