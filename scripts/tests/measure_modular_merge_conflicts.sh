#!/usr/bin/env bash
# Measure how many paths conflict when merging a ci-base ref into a modular ref.
# Usage (read-only; run from anywhere, or pass --repo):
#   measure_modular_merge_conflicts.sh [--repo <path>] <ci_base_ref> <modular_ref>
# Defaults: --repo = git toplevel of the current directory.
#
# Replays of the 2026-10-07 evidence (design doc section 2). The second
# argument must be a MODULAR commit (the sync commit that merged the previous
# ci-base), not an older ci-base build: comparing two ci-base builds directly
# under-counts (44 and 1 for the pairs below). Seed-reset regime:
#   cd /home/memento/PycharmProjects/Hummingbot/hummingbot
#   S=../custom_git_setup/scripts/tests/measure_modular_merge_conflicts.sh
#   bash $S 0f2ddaaad2 ab0f9219fd   # G_b vs modular merge of G_a (2026-10-05)
#                                   # expect 57 (33 hummingbot, 24 test, 0 other), base 19acdab73d
#   bash $S 961f325d71 ae8fd354b0   # G_new vs modular merge of G_old (2026-10-06)
#                                   # expect 57 (32 hummingbot, 24 test, 1 other), base c9294f4e2f
# Incremental regime (previous ci-base + new development, merged into modular)
# has no recorded ref pair: it needs an incrementally built ci-base tip, which
# does not exist until the incremental build lands. Live data point meanwhile
# (0 when modular already contains ci-base):
#   bash $S origin/ci-base origin/modular
#
# Safety: git merge-tree --write-tree only writes objects, so it runs in a
# mktemp scratch `git clone --shared --no-checkout` of the repo with its remote
# removed; the target repo's checkout, HEAD, refs and index are never touched,
# and no object is written into it. The scratch dir is removed on exit.
#
# Output: key=value lines (ci_base, modular, merge_base, conflicts_total,
# conflicts_hummingbot, conflicts_test, conflicts_other, conflict_messages).
# Exit 0 = measured (any count, including 0), 2 = error (bad ref, clone or
# merge-tree failure). Also sets globals MMC_TOTAL/MMC_HB/MMC_TEST/MMC_OTHER/
# MMC_BASE when sourced.
# merge_base is informational: with criss-cross histories it may differ from
# the virtual base that merge-tree actually uses.
# Callers that source the function should set their own
# trap 'rm -rf "${MMC_SCRATCH:-}"' EXIT
set -u

MMC_SCRATCH=""
MMC_TOTAL=0; MMC_HB=0; MMC_TEST=0; MMC_OTHER=0; MMC_BASE=""

# count_merge_conflicts <repo> <ci_base_ref> <modular_ref>
# Prints the report; returns 0 when measured, 2 on error.
count_merge_conflicts() {
    local repo="$1" ci_ref="$2" mod_ref="$3"
    local ci_sha mod_sha out rc paths msgs n_msgs
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
        echo "ERROR: not a git repo: $repo" >&2; return 2; }
    ci_sha="$(git -C "$repo" rev-parse --verify --quiet "${ci_ref}^{commit}")" || {
        echo "ERROR: ref not reachable in $repo: $ci_ref" >&2; return 2; }
    mod_sha="$(git -C "$repo" rev-parse --verify --quiet "${mod_ref}^{commit}")" || {
        echo "ERROR: ref not reachable in $repo: $mod_ref" >&2; return 2; }

    MMC_SCRATCH="$(mktemp -d)" || { echo "ERROR: mktemp failed" >&2; return 2; }
    if ! git clone -q --shared --no-checkout "$repo" "$MMC_SCRATCH/clone" 2>"$MMC_SCRATCH/err"; then
        echo "ERROR: scratch clone failed: $(head -n 3 "$MMC_SCRATCH/err")" >&2
        rm -rf "$MMC_SCRATCH"; MMC_SCRATCH=""; return 2
    fi
    git -C "$MMC_SCRATCH/clone" remote remove origin >/dev/null 2>&1 || true

    MMC_BASE="$(git -C "$MMC_SCRATCH/clone" merge-base "$ci_sha" "$mod_sha" 2>/dev/null)" || MMC_BASE="none"
    [ -n "$MMC_BASE" ] || MMC_BASE="none"

    # Exit status: 0 = clean, 1 = conflicts, anything else = error.
    rc=0
    out="$(git -C "$MMC_SCRATCH/clone" merge-tree --write-tree --name-only "$ci_sha" "$mod_sha" 2>"$MMC_SCRATCH/err")" || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
        echo "ERROR: git merge-tree failed (exit $rc): $(head -n 3 "$MMC_SCRATCH/err")" >&2
        rm -rf "$MMC_SCRATCH"; MMC_SCRATCH=""; return 2
    fi

    # Line 1 = tree OID; then conflicted names up to the first blank line;
    # then informational messages (CONFLICT (...) lines etc.).
    paths="$(awk 'NR == 1 { next } /^$/ { exit } { print }' <<<"$out" | sort -u)"
    msgs="$(awk 'NR == 1 { next } seen { print } /^$/ { seen = 1 }' <<<"$out")"
    n_msgs="$(grep -c '^CONFLICT' <<<"$msgs" || true)"

    MMC_TOTAL="$(grep -c . <<<"$paths" || true)"
    MMC_HB="$(grep -c '^hummingbot/' <<<"$paths" || true)"
    MMC_TEST="$(grep -c '^test/' <<<"$paths" || true)"
    MMC_OTHER=$((MMC_TOTAL - MMC_HB - MMC_TEST))

    echo "ci_base=$ci_ref ($ci_sha)"
    echo "modular=$mod_ref ($mod_sha)"
    echo "merge_base=$MMC_BASE"
    echo "merge_tree_exit=$rc"
    echo "conflicts_total=$MMC_TOTAL"
    echo "conflicts_hummingbot=$MMC_HB"
    echo "conflicts_test=$MMC_TEST"
    echo "conflicts_other=$MMC_OTHER"
    echo "conflict_messages=$n_msgs"

    rm -rf "$MMC_SCRATCH"; MMC_SCRATCH=""
    return 0
}

main() {
    local repo="" refs=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo)
                [ $# -ge 2 ] || { echo "ERROR: --repo needs a value" >&2; return 2; }
                repo="$2"; shift 2 ;;
            *) refs+=("$1"); shift ;;
        esac
    done
    if [ "${#refs[@]}" -ne 2 ]; then
        echo "usage: $0 [--repo <path>] <ci_base_ref> <modular_ref>" >&2
        return 2
    fi
    if [ -z "$repo" ]; then
        repo="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo" >&2; return 2; }
    fi
    trap 'rm -rf "${MMC_SCRATCH:-}"' EXIT
    count_merge_conflicts "$repo" "${refs[0]}" "${refs[1]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
    exit $?
fi
