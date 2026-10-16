#!/bin/bash
###############################################################################
# pixi-launch.sh
# --------------
# Launcher used by custom_git_setup pixi tasks. Strips the outer pixi/conda
# environment so nested `pixi run -e ci` calls inside ../hummingbot resolve
# hummingbot's own manifest.
#
# Usage: bash scripts/pixi-launch.sh {rebuild|drift-check|bt-test <name>|dry-run} [args...]
###############################################################################
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CGS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HB_REPO="/home/memento/PycharmProjects/Hummingbot/hummingbot"

# Drop the outer environment.
while IFS= read -r _var; do
    unset "$_var"
done < <(compgen -v | grep -E '^(PIXI_|CONDA_)')
unset VIRTUAL_ENV

# Remove custom_git_setup/.pixi/ entries from PATH.
_new_path=""
IFS=':' read -ra _entries <<< "$PATH"
for _p in "${_entries[@]}"; do
    case "$_p" in
        "$CGS_DIR"/.pixi/*|"$CGS_DIR"/.pixi) continue ;;
    esac
    _new_path="${_new_path:+$_new_path:}$_p"
done
export PATH="$_new_path"

cmd="${1:-}"
[ $# -gt 0 ] && shift

run_hb_test() {
    local script="$1"
    cd "$HB_REPO" || exit 1
    pixi run -e ci bash "../custom_git_setup/scripts/tests/${script}.sh" "${@:2}"
}

case "$cmd" in
    rebuild)
        cd "$HB_REPO" || exit 1
        # Same cwd as cron-wrapper (REPO_PATH); the script locks itself when run standalone.
        "$CGS_DIR/scripts/hummingbot-branch-tracking.sh" --rebuild "$@" 2>&1 | tee /tmp/rebuild.log
        exit "${PIPESTATUS[0]}"
        ;;
    drift-check)
        cd "$HB_REPO" || exit 1
        git fetch origin || exit $?
        pixi run -e ci bash ../custom_git_setup/scripts/check_ci_base_drift.sh "$@"
        exit $?
        ;;
    bt-test)
        name="${1:-}"
        if [[ ! "$name" =~ ^[A-Za-z0-9_]+$ ]]; then
            echo "pixi-launch: invalid or missing test name: '$name'" >&2
            exit 2
        fi
        if [ ! -f "$CGS_DIR/scripts/tests/${name}.sh" ]; then
            echo "pixi-launch: no such test: scripts/tests/${name}.sh" >&2
            exit 2
        fi
        shift
        run_hb_test "$name" "$@"
        exit $?
        ;;
    dry-run)
        run_hb_test dry_run_incremental_ci_base "$@"
        exit $?
        ;;
    *)
        echo "Usage: $0 {rebuild|drift-check|bt-test <name>|dry-run} [args...]" >&2
        exit 2
        ;;
esac
