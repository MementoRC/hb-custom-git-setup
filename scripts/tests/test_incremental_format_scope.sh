#!/usr/bin/env bash
# Harness for ci_base_format_targets / ci_base_ruff_version_trailer /
# py312_tooling_trailer (extracted from hummingbot-branch-tracking.sh).
# Usage: bash custom_git_setup/scripts/tests/test_incremental_format_scope.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# py312_tooling_trailer reads SCRIPT_DIR; point it at a temp "custom_git_setup".
CGS="$TMPDIR_T/cgs"
SCRIPT_DIR="$CGS/scripts"

# shellcheck disable=SC1090
source <(sed -n "/^ci_base_format_targets() {/,/^}/p;/^ci_base_ruff_version_trailer() {/,/^}/p;/^py312_tooling_trailer() {/,/^}/p" "$SCRIPT")

for fn in ci_base_format_targets ci_base_ruff_version_trailer py312_tooling_trailer; do
    if ! declare -F "$fn" >/dev/null; then
        echo "FAIL could not load $fn from $SCRIPT"
        exit 1
    fi
done

init_repo() {
    git init -q "$1"
    git -C "$1" config user.name "Test"
    git -C "$1" config user.email "test@example.invalid"
    git -C "$1" config commit.gpgsign false
    git -C "$1" config core.hooksPath "$TMPDIR_T/nohooks"
}

REPO="$TMPDIR_T/repo"
init_repo "$REPO"
cd "$REPO" || exit 1
mkdir -p hummingbot
printf 'a = 1\n' > hummingbot/mod.py
printf 'b = 1\n' > hummingbot/gone.py
printf 'c = 1\n' > hummingbot/old_name.py
printf 'x\n' > notes.txt
git add -A
git commit -q -m "base"
PRE="$(git rev-parse HEAD)"

# 1. Seed mode: ALL, regardless of changes.
out="$(ci_base_format_targets seed "$PRE")"
if [ "$out" = "ALL" ]; then pass "seed mode prints ALL"; else fail "seed mode got '$out'"; fi

# 2. Incremental, no changes since PRE: empty.
out="$(ci_base_format_targets incremental "$PRE")"
if [ -z "$out" ]; then pass "incremental with no changes is empty"; else fail "incremental no-change got '$out'"; fi

# 3. Incremental with add/modify/rename/delete plus a non-.py change.
printf 'a = 2\n' > hummingbot/mod.py
printf 'd = 1\n' > hummingbot/new.py
git rm -q hummingbot/gone.py
git mv hummingbot/old_name.py hummingbot/renamed.py
printf 'y\n' >> notes.txt
git add -A
git commit -q -m "changes"
out="$(ci_base_format_targets incremental "$PRE" | sort)"
expected="$(printf 'hummingbot/mod.py\nhummingbot/new.py\nhummingbot/renamed.py\n')"
if [ "$out" = "$expected" ]; then
    pass "incremental lists added+modified+renamed, excludes deleted and non-py"
else
    fail "incremental changes got '$out'"
fi

# 4. Ruff-Version trailer uses the stubbed ruff's --version output.
STUB="$TMPDIR_T/ruff-stub"
printf '#!/usr/bin/env bash\necho "ruff 9.9.9"\n' > "$STUB"
chmod +x "$STUB"
out="$(ci_base_ruff_version_trailer "$STUB")"
if [ "$out" = "Ruff-Version: ruff 9.9.9" ]; then
    pass "Ruff-Version trailer carries stub --version output"
else
    fail "Ruff-Version trailer got '$out'"
fi

# 5. Py312-Tooling trailer is the short sha of the custom_git_setup HEAD.
mkdir -p "$SCRIPT_DIR"
init_repo "$CGS"
git -C "$CGS" commit -q --allow-empty -m "cgs init"
want="$(git -C "$CGS" rev-parse --short HEAD)"
out="$(py312_tooling_trailer)"
if [ "$out" = "Py312-Tooling: $want" ]; then
    pass "Py312-Tooling trailer is custom_git_setup short HEAD"
else
    fail "Py312-Tooling trailer got '$out' want '$want'"
fi

[ "$fails" -eq 0 ]
