#!/usr/bin/env bash
# Harness for _gate_failed_ids and _gate_new_ids (extracted from
# hummingbot-branch-tracking.sh).
# Usage: pixi run bt-test test_gate_new_failures
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbot-branch-tracking.sh"

# shellcheck disable=SC1090
source <(sed -n "/^_gate_failed_ids() {/,/^}/p;/^_gate_new_ids() {/,/^}/p" "$SCRIPT")

for fn in _gate_failed_ids _gate_new_ids; do
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

# (a) junit XML: pass, failure, error, collection error -> 3 sorted ids
cat > "$TMPDIR_T/r.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<testsuites><testsuite name="pytest" tests="4">
<testcase classname="tests.test_a" name="test_ok" time="0.1"/>
<testcase classname="tests.test_a" name="test_bad" time="0.1"><failure message="boom">tb</failure></testcase>
<testcase classname="tests.test_b" name="test_err" time="0.1"><error message="fixture">tb</error></testcase>
<testcase classname="" name="tests.test_c" time="0"><error message="collection">tb</error></testcase>
</testsuite></testsuites>
EOF
expected=$'tests.test_a::test_bad\ntests.test_b::test_err\ntests.test_c'
got="$(_gate_failed_ids "$TMPDIR_T/r.xml" /nonexistent)"
if [ "$got" = "$(printf '%s\n' "$expected" | sort)" ]; then
    pass "(a) xml: failure, error and collection error ids"
else
    fail "(a) xml ids wrong: $got"
fi

# (b) missing xml -> log fallback, trailing " - msg" stripped, deduped
cat > "$TMPDIR_T/r.log" <<'EOF'
tests/test_a.py::test_ok PASSED
=========== short test summary info ===========
FAILED tests/test_a.py::test_bad - AssertionError: x - y
ERROR tests/test_b.py::test_err
FAILED tests/test_a.py::test_bad - AssertionError: x - y
EOF
got="$(_gate_failed_ids "$TMPDIR_T/missing.xml" "$TMPDIR_T/r.log")"
if [ "$got" = $'tests/test_a.py::test_bad\ntests/test_b.py::test_err' ]; then
    pass "(b) log fallback when xml missing"
else
    fail "(b) log fallback wrong: $got"
fi

# (c) unparseable xml -> log fallback
echo "not xml" > "$TMPDIR_T/bad.xml"
got="$(_gate_failed_ids "$TMPDIR_T/bad.xml" "$TMPDIR_T/r.log")"
if [ "$got" = $'tests/test_a.py::test_bad\ntests/test_b.py::test_err' ]; then
    pass "(c) log fallback when xml unparseable"
else
    fail "(c) unparseable fallback wrong: $got"
fi

# (d) all-passing xml and a log without FAILED/ERROR lines -> unusable (1, no output)
cat > "$TMPDIR_T/ok.xml" <<'EOF'
<testsuites><testsuite><testcase classname="t" name="ok"/></testsuite></testsuites>
EOF
echo "no failures here" > "$TMPDIR_T/ok.log"
got="$(_gate_failed_ids "$TMPDIR_T/ok.xml" "$TMPDIR_T/ok.log")"
rc=$?
if [ "$rc" -eq 1 ] && [ -z "$got" ]; then
    pass "(d) no ids returns 1 with no output"
else
    fail "(d) expected rc=1/empty, got rc=$rc out='$got'"
fi

# (e) set difference: post minus baseline
printf 'a\nb\nc\n' > "$TMPDIR_T/post.ids"
printf 'b\nz\n' > "$TMPDIR_T/base.ids"
got="$(_gate_new_ids "$TMPDIR_T/post.ids" "$TMPDIR_T/base.ids")"
if [ "$got" = $'a\nc' ]; then
    pass "(e) new ids = post minus baseline"
else
    fail "(e) new ids wrong: $got"
fi

# (f) all post ids pre-existing -> empty; empty baseline -> everything new
printf 'a\n' > "$TMPDIR_T/post2.ids"
printf 'a\nb\n' > "$TMPDIR_T/base2.ids"
got="$(_gate_new_ids "$TMPDIR_T/post2.ids" "$TMPDIR_T/base2.ids")"
if [ -z "$got" ]; then
    pass "(f) all pre-existing yields empty"
else
    fail "(f) expected empty, got: $got"
fi
: > "$TMPDIR_T/empty.ids"
got="$(_gate_new_ids "$TMPDIR_T/post.ids" "$TMPDIR_T/empty.ids")"
if [ "$got" = $'a\nb\nc' ]; then
    pass "(f) empty baseline yields all post ids"
else
    fail "(f) empty baseline wrong: $got"
fi

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$fails FAILED"
exit 1
