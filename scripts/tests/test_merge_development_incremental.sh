#!/usr/bin/env bash
# Harness for merge_development_incremental (extracted from
# hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_merge_development_incremental.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

# Mirror the real common.sh log_* helpers (stdout).
log_operation() { echo "$*"; }
log_error() { echo "ERROR $*"; }
log_warning() { echo "$*"; }

CI_BASE_SEED_TAG=ci-base-seed-test

# shellcheck disable=SC1090
source <(sed -n "/^ci_base_incremental_preconditions() {/,/^}/p;/^compute_for_ci_owned() {/,/^}/p;/^is_logical_conflict_path() {/,/^}/p;/^merge_development_incremental() {/,/^}/p" "$SCRIPT")

for fn in ci_base_incremental_preconditions compute_for_ci_owned merge_development_incremental; do
    if ! declare -F "$fn" >/dev/null; then
        echo "FAIL could not load $fn from $SCRIPT"
        exit 1
    fi
done

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT
RUN_LOG_DIR="$TMPDIR_T/logs"
mkdir -p "$RUN_LOG_DIR"
TAKEN="$RUN_LOG_DIR/incremental_taken_dev.txt"

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

g() { git -c commit.gpgsign=false -c core.hooksPath="$TMPDIR_T/nohooks" "$@"; }
commit_file() { # file content message
    echo "$2" > "$1"
    g add "$1"
    g commit -q --no-verify -m "$3"
}

# new_repo: bare origin; ci-base = seed + Dev-Merged dev merge (D1) + X merge
# (owned.txt) + a ci-base edit of every shared file; pushed. Checked out on ci-base.
new_repo() {
    local root
    root="$(mktemp -d -p "$TMPDIR_T")"
    git init -q --bare -b ci-base "$root/origin.git"
    git clone -q "$root/origin.git" "$root/work" 2>/dev/null
    cd "$root/work" || exit 1
    git config user.name Test
    git config user.email test@example.invalid
    git config commit.gpgsign false
    g checkout -q -b development
    local f
    for f in base.txt owned.txt gen.txt gen2.txt pyproject.toml .pre-commit-config.yaml; do
        echo "0" > "$f"
    done
    g add -A
    g commit -q --no-verify -m "D0"
    g tag -f "$CI_BASE_SEED_TAG" >/dev/null
    g checkout -q -b ci-base
    g checkout -q development
    commit_file dev1.txt 1 "D1"
    g checkout -q ci-base
    D1="$(git rev-parse development)"
    g merge -q --no-verify --no-ff development -m "Sync ci-base with development" -m "Dev-Merged: $D1"
    g checkout -q -b x
    commit_file owned.txt x "work on owned.txt"
    g checkout -q ci-base
    g merge -q --no-verify --no-ff x -m "Auto-merge _for_ci/X into ci-base"
    g branch -q -D x
    for f in gen.txt gen2.txt pyproject.toml .pre-commit-config.yaml; do
        echo "ci" > "$f"
    done
    g add -A
    g commit -q --no-verify -m "ci-base edits"
    g push -q origin ci-base development 2>/dev/null
    : > "$TAKEN"
}

# dev_advance <file>=<content> | <file>=DELETE ...   (commits on development, pushes)
dev_advance() {
    local spec f c
    g checkout -q development
    for spec in "$@"; do
        f="${spec%%=*}"
        c="${spec#*=}"
        if [ "$c" = DELETE ]; then g rm -q "$f"; else echo "$c" > "$f"; fi
    done
    g add -A
    g commit -q --no-verify -m "D2"
    g push -q origin development 2>/dev/null
    g checkout -q ci-base
    g fetch -q origin
}

D2() { git rev-parse origin/development; }
unchanged() { # sha
    [ "$(git rev-parse HEAD)" = "$1" ] && [ -z "$(git status --porcelain)" ] \
        && [ ! -e "$(git rev-parse --git-dir)/MERGE_HEAD" ]
}

# ---------- (a) clean dev advance
new_repo
dev_advance new.txt=new
before="$(git rev-parse HEAD)"
merge_development_incremental >/dev/null 2>&1; rc=$?
trailer="$(git log -1 --format='%(trailers:key=Dev-Merged,valueonly)' | tr -d '[:space:]')"
subj="$(git log -1 --format=%s)"
if [ "$rc" -eq 0 ] && [ "$trailer" = "$(D2)" ] && [ "$subj" = "Sync ci-base with development (incremental)" ] \
    && [ "$(git rev-list --count --merges "$before..HEAD")" -eq 1 ] && [ -e new.txt ] \
    && [ -z "$(git status --porcelain)" ]; then
    pass "(a) clean advance -> merge commit with Dev-Merged = new dev sha"
else
    fail "(a) rc=$rc trailer=$trailer subj=$subj"
fi
g push -q origin ci-base 2>/dev/null
g fetch -q origin
if ci_base_incremental_preconditions >/dev/null 2>&1 && [ "$CI_BASE_LAST_DEV_MERGED" = "$(D2)" ]; then
    pass "(a) preconditions pass after push"
else
    fail "(a) preconditions failed after merge"
fi

# ---------- (b) already merged -> no-op
before="$(git rev-parse HEAD)"
out="$(merge_development_incremental 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$before" ] && echo "$out" | grep -q 'development already merged'; then
    pass "(b) already merged -> no-op"
else
    fail "(b) rc=$rc out=[$out]"
fi

# ---------- (c) generated-only conflict -> dev side taken, recorded
new_repo
dev_advance gen.txt=dev
echo stale.txt > "$TAKEN"
merge_development_incremental >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat gen.txt)" = dev ] && [ "$(cat "$TAKEN")" = gen.txt ] \
    && [ "$(git log -1 --format=%P | wc -w)" -eq 2 ] && [ -z "$(git status --porcelain)" ]; then
    pass "(c) generated conflict -> dev side taken and recorded"
else
    fail "(c) rc=$rc gen=$(cat gen.txt)"
fi

# ---------- (d) owned conflict -> abort
new_repo
dev_advance owned.txt=dev
before="$(git rev-parse HEAD)"
out="$(merge_development_incremental 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && unchanged "$before" && echo "$out" | grep -q 'owned.txt'; then
    pass "(d) owned conflict -> 1, unchanged"
else
    fail "(d) rc=$rc out=[$out]"
fi

# ---------- (e) pyproject.toml conflict -> abort
new_repo
dev_advance pyproject.toml=dev
before="$(git rev-parse HEAD)"
out="$(merge_development_incremental 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && unchanged "$before" && echo "$out" | grep -q 'pyproject.toml'; then
    pass "(e) pyproject.toml conflict -> 1, unchanged"
else
    fail "(e) rc=$rc out=[$out]"
fi

# ---------- (f) .pre-commit-config.yaml -> ours
new_repo
dev_advance .pre-commit-config.yaml=dev
merge_development_incremental >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat .pre-commit-config.yaml)" = ci ] && ! grep -Fxq .pre-commit-config.yaml "$TAKEN"; then
    pass "(f) .pre-commit-config.yaml keeps ours"
else
    fail "(f) rc=$rc content=$(cat .pre-commit-config.yaml)"
fi

# ---------- (g) delete/modify: dev deletes gen2.txt, ci-base modified it
new_repo
dev_advance gen2.txt=DELETE
merge_development_incremental >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e gen2.txt ] && [ -z "$(git ls-files gen2.txt)" ] && grep -Fxq gen2.txt "$TAKEN" \
    && [ -z "$(git status --porcelain)" ]; then
    pass "(g) deleted by development -> deleted in result"
else
    fail "(g) rc=$rc"
fi

# ---------- (h) mixed generated + owned conflict -> abort, nothing half-resolved
new_repo
dev_advance gen.txt=dev owned.txt=dev
before="$(git rev-parse HEAD)"
out="$(merge_development_incremental 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && unchanged "$before" && [ "$(cat gen.txt)" = ci ] && [ ! -s "$TAKEN" ]; then
    pass "(h) mixed -> 1, nothing half-resolved"
else
    fail "(h) rc=$rc out=[$out]"
fi

[ "$fails" -eq 0 ]
