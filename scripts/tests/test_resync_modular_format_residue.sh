#!/usr/bin/env bash
# Harness for resync_modular_format_residue (+ py_pair_format_equivalent and
# commit_if_changed), extracted from hummingbot-branch-tracking.sh via sed.
#
# Needs `ruff` on PATH (the pixi fallback cannot work in a temp repo):
#   cd /home/memento/PycharmProjects/Hummingbot/hummingbot && \
#     pixi run -e ci bash ../custom_git_setup/scripts/tests/test_resync_modular_format_residue.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

if ! command -v ruff >/dev/null 2>&1; then
    echo "FAIL: ruff not on PATH (run via pixi run -e ci, see header)"; exit 1
fi

log_operation() { :; }
log_error() { echo "log_error: $*" >&2; }
# Stub: only paths under owned/ are modular-owned.
modular_owns_path() { case "$1" in owned/*) return 0 ;; esac; return 1; }

for fn in commit_if_changed py_pair_format_equivalent py_pair_semantically_equal \
          resync_modular_format_residue; do
    # shellcheck disable=SC1090
    source <(sed -n "/^${fn}() {/,/^}/p" "$SCRIPT")
    if ! declare -F "$fn" >/dev/null; then
        echo "FAIL could not load $fn from $SCRIPT"; exit 1
    fi
done

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

SPACED=$'def f():\n\n    return 1\n'
TIGHT=$'def f():\n    return 1\n'
SEMANTIC_A=$'def f():\n    return 1\n'
SEMANTIC_B=$'def f():\n    return 2\n'
COMMENT_A=$'def f():\n    # old note\n    return 1\n'
COMMENT_B=$'def f():\n    # new note\n    return 1\n'
STRING_A=$'def f():\n    return """a\n\nb"""\n'
STRING_B=$'def f():\n    return """a\nb"""\n'

# new_repo: ci-base has the "base side" content, modular (checked out) has the
# "modular side" content. Sets RUN_LOG_DIR and cd's into the repo.
#   files: owned/o.py, a.py, sem.py, cfg.yaml, ok.py
new_repo() {
    local root
    root="$(mktemp -d -p "$TMPDIR_T")"
    RUN_LOG_DIR="$root/runlog"
    mkdir -p "$RUN_LOG_DIR"
    root="$root/repo"
    mkdir -p "$root/owned"
    cd "$root" || exit 1
    git init -q -b ci-base .
    git config user.name Test
    git config user.email test@example.invalid
    git config commit.gpgsign false
    git config core.hooksPath "$TMPDIR_T/nohooks"
    printf '%s' "$SPACED" > a.py
    printf '%s' "$SPACED" > owned/o.py
    printf '%s' "$SEMANTIC_A" > sem.py
    printf 'k: 1\n\n' > cfg.yaml
    printf '%s' "$SPACED" > ok.py
    printf '%s' "$COMMENT_A" > cm.py
    printf '%s' "$STRING_A" > st.py
    git add -A
    git commit -q --no-verify -m "ci-base"
    git checkout -q -b modular
}

modular_commits() { git rev-list --count ci-base..HEAD; }

# (a) whitespace-only residue is resynced; (b) semantic diff left alone;
# (c) owned left alone; (d) yaml left alone; (f) count line written.
new_repo
printf '%s' "$TIGHT" > a.py
printf '%s' "$TIGHT" > owned/o.py
printf '%s' "$SEMANTIC_B" > sem.py
printf 'k: 1\n' > cfg.yaml
printf '%s' "$COMMENT_B" > cm.py
printf '%s' "$STRING_B" > st.py
git commit -qam "modular drift" --no-verify
before="$(modular_commits)"
resync_modular_format_residue ci-base

if [ "$(cat a.py)" = "$(printf '%s' "$SPACED")" ] && [ "$(git status --porcelain | wc -l)" -eq 0 ]; then
    pass "(a) whitespace-only residue file resynced to ci-base"
else
    fail "(a) a.py not resynced"
fi
if [ "$(cat sem.py)" = "$(printf '%s' "$SEMANTIC_B")" ]; then
    pass "(b) semantically different file left alone"
else
    fail "(b) sem.py was overwritten"
fi
if [ "$(cat cm.py)" = "$(printf '%s' "$COMMENT_B")" ]; then
    pass "(g) comment-text-only difference left alone"
else
    fail "(g) cm.py was overwritten"
fi
if [ "$(cat st.py)" = "$(printf '%s' "$STRING_B")" ]; then
    pass "(h) blank-line change inside triple-quoted string left alone"
else
    fail "(h) st.py was overwritten"
fi
if [ "$(cat owned/o.py)" = "$(printf '%s' "$TIGHT")" ]; then
    pass "(c) modular-owned file left alone"
else
    fail "(c) owned/o.py was overwritten"
fi
if [ "$(cat cfg.yaml)" = "k: 1" ]; then
    pass "(d) .yaml file left alone"
else
    fail "(d) cfg.yaml was overwritten"
fi
if [ "$(( $(modular_commits) - before ))" -eq 1 ] &&
   [ "$(git log -1 --format=%s)" = "sync(modular): resync 1 format-only residue files to ci-base" ]; then
    pass "(a2) single commit with count in message"
else
    fail "(a2) expected one commit 'resync 1 ...', got '$(git log -1 --format=%s)'"
fi
if grep -qx 'format-residue-resynced=1' "$RUN_LOG_DIR/modular_classifier_counts.txt"; then
    pass "(f) count line written"
else
    fail "(f) count line missing: $(cat "$RUN_LOG_DIR/modular_classifier_counts.txt" 2>&1)"
fi

# (e) no residue -> no commit, count 0
new_repo
printf '%s' "$SEMANTIC_B" > sem.py
git commit -qam "semantic only" --no-verify
before="$(modular_commits)"
resync_modular_format_residue ci-base
if [ "$(modular_commits)" -eq "$before" ] && [ "$(cat sem.py)" = "$(printf '%s' "$SEMANTIC_B")" ]; then
    pass "(e) no residue gives no commit"
else
    fail "(e) unexpected commit or change"
fi
if grep -qx 'format-residue-resynced=0' "$RUN_LOG_DIR/modular_classifier_counts.txt"; then
    pass "(e2) zero count line written"
else
    fail "(e2) zero count line missing"
fi

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$fails FAILED"
exit 1
