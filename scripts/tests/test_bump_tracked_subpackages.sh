#!/usr/bin/env bash
# Harness for bump_tracked_subpackages + subpackage_ci_green + read_subpackage_tracking
# (extracted from hummingbot-branch-tracking.sh). Builds a fixture parent repo with a
# real submodule backed by a local bare "origin", and stubs `gh` on PATH (no network).
# Usage: bash custom_git_setup/scripts/tests/test_bump_tracked_subpackages.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

# Mirror the real common.sh log_* helpers (stdout); only the text matters here.
log_operation() { echo "$*"; }
log_warning() { echo "$*"; }
log_error() { echo "$*"; }
log_section() { echo "$*"; }
log_result() { echo "$*"; }

# shellcheck disable=SC1090
for fn in read_subpackage_tracking subpackage_ci_green bump_tracked_subpackages; do
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
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always  # local submodule clone
export GIT_CONFIG_KEY_1=commit.gpgsign GIT_CONFIG_VALUE_1=false

# Seams: the fixture origin is a local path, but subpackage_ci_green derives the
# GitHub slug from `remote get-url origin`, so report a github URL for that one
# call. The script's commit passes --gpg-sign; drop it (no key in the sandbox).
FAKE_URL="https://github.com/acme/foo.git"
git() {
    if [ "${1:-}" = "-C" ] && [ "${3:-}" = "remote" ] && [ "${4:-}" = "get-url" ]; then
        echo "$FAKE_URL"
        return 0
    fi
    if [ "${1:-}" = "commit" ]; then
        local a=() x
        for x in "$@"; do [ "$x" = "--gpg-sign" ] || a+=("$x"); done
        command git "${a[@]}"
        return
    fi
    command git "$@"
}

# gh stub: emits canned (already --jq-filtered) lines; GH_FAIL=check-runs|status
# makes that endpoint exit non-zero. Every call is logged to $GH_LOG.
mkdir -p "$TMPDIR_T/bin"
cat > "$TMPDIR_T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
    *check-runs*) [ "${GH_FAIL:-}" = "check-runs" ] && exit 1; printf '%s\n' "${GH_RUNS:-}" ;;
    *) [ "${GH_FAIL:-}" = "status" ] && exit 1; printf '%s\n' "${GH_STATUS:-}" ;;
esac
EOF
chmod +x "$TMPDIR_T/bin/gh"
export PATH="$TMPDIR_T/bin:$PATH"
export GH_LOG="$TMPDIR_T/gh.log"

# gh_set <check-runs lines> <status line> [fail-endpoint]
gh_set() { export GH_RUNS="$1" GH_STATUS="$2" GH_FAIL="${3:-}"; : > "$GH_LOG"; }

# new_fixture <tracked-branch> [extra config line]: parent repo with sub-packages/foo
# pinned at C1 on origin main. Leaves cwd in the parent, BRANCH_CONFIG set.
new_fixture() {
    FX="$(mktemp -d "$TMPDIR_T/fx.XXXXXX")"
    command git init -q -b main --bare "$FX/sub.git"
    command git clone -q "$FX/sub.git" "$FX/work" 2>/dev/null
    (cd "$FX/work" && echo 1 > f.txt && git add f.txt && git commit -q -m c1 \
        && git push -q origin main)
    C1="$(command git -C "$FX/work" rev-parse HEAD)"
    command git init -q -b main "$FX/parent"
    cd "$FX/parent" || exit 1
    echo p > p.txt
    git add p.txt
    git commit -q -m init
    git submodule add -q -b main "$FX/sub.git" sub-packages/foo
    git commit -q -m "pin foo"
    BRANCH_CONFIG="$FX/branches.yaml"
    printf 'subpackage_tracking:\n  foo: %s\n%s\n' "$1" "${2:-}" > "$BRANCH_CONFIG"
}

# advance_origin: push one new commit to origin main; sets C2.
advance_origin() {
    (cd "$FX/work" && echo 2 >> f.txt && git commit -q -am c2 && git push -q origin main)
    C2="$(command git -C "$FX/work" rev-parse HEAD)"
}

gitlink() { git rev-parse HEAD:sub-packages/foo; }
commits() { git rev-list --count HEAD; }
run_bump() { out="$(bump_tracked_subpackages 2>&1)"; rc=$?; }

# Asserts the pin did not move and no commit was made.
expect_no_bump() {
    local label="$1" before="$2"
    if [ "$rc" -eq 0 ] && [ "$(gitlink)" = "$C1" ] && [ "$(commits)" -eq "$before" ]; then
        pass "$label (rc=$rc)"
    else
        fail "$label rc=$rc gitlink=$(gitlink) want=$C1 commits=$before->$(commits)"
    fi
}

# 1. CI green at the new tip: gitlink bumped, one commit, working tree moved.
new_fixture main
advance_origin
gh_set "completed success" "pending 0"
before=$(commits)
run_bump
subj="$(git log -1 --format=%s)"
live="$(command git -C sub-packages/foo rev-parse HEAD)"
if [ "$rc" -eq 0 ] && [ "$(gitlink)" = "$C2" ] && [ "$(commits)" -eq $((before + 1)) ] \
    && [ "$live" = "$C2" ] && [[ "$subj" == "chore(modular): auto-track"* ]] \
    && grep -q "repos/acme/foo/commits/$C2/check-runs" "$GH_LOG"; then
    pass "green CI bumps gitlink to tracked tip (rc=$rc)"
else
    fail "green CI rc=$rc gitlink=$(gitlink) want=$C2 live=$live commits=$before->$(commits) subject='$subj'"
fi

# 2. Commit scope argument is honoured.
new_fixture main
advance_origin
gh_set "completed success" "success 2"
bump_tracked_subpackages overlay >/dev/null 2>&1
subj="$(git log -1 --format=%s)"
if [[ "$subj" == "chore(overlay): auto-track"* ]] && [ "$(gitlink)" = "$C2" ]; then
    pass "scope arg used in commit subject, green status accepted"
else
    fail "scope arg subject='$subj' gitlink=$(gitlink)"
fi

# 3. Red / pending / non-green outcomes: no bump (each on a fresh fixture).
red_case() {
    local label="$1" runs="$2" status="$3" before
    new_fixture main
    advance_origin
    gh_set "$runs" "$status"
    before=$(commits)
    run_bump
    expect_no_bump "$label" "$before"
}
red_case "failed check-run blocks bump" "completed success
completed failure" "pending 0"
red_case "in-progress check-run blocks bump" "in_progress none" "pending 0"
red_case "cancelled check-run blocks bump" "completed cancelled" "pending 0"
red_case "failing commit status blocks bump" "completed success" "failure 1"
red_case "pending commit status blocks bump" "completed success" "pending 1"
red_case "no checks at all blocks bump" "" "pending 0"

# 4. skipped/neutral conclusions count as green.
new_fixture main
advance_origin
gh_set "completed skipped
completed neutral
completed success" "pending 0"
run_bump
if [ "$rc" -eq 0 ] && [ "$(gitlink)" = "$C2" ]; then
    pass "skipped/neutral/success check-runs are green"
else
    fail "skipped/neutral rc=$rc gitlink=$(gitlink) want=$C2"
fi

# 5. gh failure or unparseable output fails closed.
new_fixture main
advance_origin
gh_set "completed success" "success 1" check-runs
before=$(commits); run_bump
expect_no_bump "check-runs API error fails closed" "$before"

gh_set "completed success" "success 1" status
before=$(commits); run_bump
expect_no_bump "commit status API error fails closed" "$before"

gh_set "<html>502 Bad Gateway</html>" "garbage"
before=$(commits); run_bump
expect_no_bump "unparseable check-runs output fails closed" "$before"

FAKE_URL="foo.git"  # no owner/repo shape -> slug underivable
gh_set "completed success" "success 1"
before=$(commits); run_bump
if [ ! -s "$GH_LOG" ]; then
    expect_no_bump "non-GitHub origin URL fails closed without calling gh" "$before"
else
    fail "non-GitHub origin URL still called gh: $(cat "$GH_LOG")"
fi
FAKE_URL="https://github.com/acme/foo.git"

# 6. Already at tip: no-op, no empty commit, gh never consulted.
new_fixture main
gh_set "completed failure" "failure 1"
before=$(commits)
run_bump
if [ "$rc" -eq 0 ] && [ "$(gitlink)" = "$C1" ] && [ "$(commits)" -eq "$before" ] \
    && [ ! -s "$GH_LOG" ] && printf '%s' "$out" | grep -q "already at development tip"; then
    pass "already at tip is a no-op (rc=$rc)"
else
    fail "already at tip rc=$rc commits=$before->$(commits) gh_calls=$(wc -l < "$GH_LOG")"
fi

# 7. Recorded pin at tip but working tree stale: re-synced, still no commit.
new_fixture main
command git -C sub-packages/foo commit -q --allow-empty -m drift
before=$(commits)
run_bump
live="$(command git -C sub-packages/foo rev-parse HEAD)"
if [ "$rc" -eq 0 ] && [ "$live" = "$C1" ] && [ "$(commits)" -eq "$before" ]; then
    pass "stale working tree re-synced to recorded pin, no commit"
else
    fail "stale tree rc=$rc live=$live want=$C1 commits=$before->$(commits)"
fi

# 8. require_ci disabled: red CI is ignored and gh is not called.
new_fixture main "subpackage_tracking_require_ci: false"
advance_origin
gh_set "completed failure" "failure 1"
run_bump
if [ "$rc" -eq 0 ] && [ "$(gitlink)" = "$C2" ] && [ ! -s "$GH_LOG" ]; then
    pass "require_ci=false bumps without consulting gh"
else
    fail "require_ci=false rc=$rc gitlink=$(gitlink) want=$C2 gh_calls=$(wc -l < "$GH_LOG")"
fi

# 9. Tracked branch missing on origin: fetch fails, pin kept.
new_fixture nosuchbranch
advance_origin
gh_set "completed success" "success 1"
before=$(commits); run_bump
expect_no_bump "missing remote branch keeps pin" "$before"

# 10. No subpackage_tracking entries: skipped, rc 0.
new_fixture main
advance_origin
printf 'tracked_branches: []\n' > "$BRANCH_CONFIG"
before=$(commits); run_bump
if printf '%s' "$out" | grep -q "no subpackage_tracking entries"; then
    expect_no_bump "empty tracking config is skipped" "$before"
else
    fail "empty tracking config out='$out'"
fi

# 11. Tracked name whose sub-package dir is absent: skipped, rc 0.
new_fixture main
advance_origin
printf 'subpackage_tracking:\n  ghost: main\n' > "$BRANCH_CONFIG"
before=$(commits); run_bump
if printf '%s' "$out" | grep -q "not initialized"; then
    expect_no_bump "uninitialized sub-package is skipped" "$before"
else
    fail "uninitialized sub-package out='$out'"
fi

[ "$fails" -eq 0 ]
