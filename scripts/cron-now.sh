#!/bin/bash
###############################################################################
# cron-now.sh
# -----------
# Run hummingbot-cron-wrapper.sh in its OWN transient systemd user unit so it
# escapes the calling session's cgroup (e.g. shell-runner's MemoryMax=4G; a
# shell-runner restart kills its whole control group, including any child run).
#
# Usage: scripts/cron-now.sh [wrapper args...]     (e.g. --rebuild)
###############################################################################
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CGS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_PATH="${LOG_PATH:-$CGS_DIR/logs}"
LOCK_FILE="${LOG_PATH}/.hb_pipeline.lock"   # same file the wrapper flocks on fd 9

if [ -e "$LOCK_FILE" ]; then
    if ! flock -n "$LOCK_FILE" -c true; then
        echo "cron-now: pipeline lock is held ($LOCK_FILE); refusing to launch." >&2
        holder=""
        command -v lsof >/dev/null 2>&1 && holder="$(lsof -- "$LOCK_FILE" 2>/dev/null | tail -n +2)"
        if [ -z "$holder" ] && command -v fuser >/dev/null 2>&1; then
            holder="$(fuser -v "$LOCK_FILE" 2>&1)"
        fi
        echo "Holder: ${holder:-(unknown)}" >&2
        latest="$(readlink -f "$LOG_PATH/runs/latest" 2>/dev/null)"
        [ -n "$latest" ] && echo "Latest run dir: $latest" >&2
        exit 1
    fi
fi

unit="hb-cron-$(date +%Y%m%d%H%M%S)"
systemd-run --user --unit="$unit" --collect \
    -p MemoryMax=16G -p TasksMax=infinity \
    --working-directory="$CGS_DIR" \
    -- "$CGS_DIR/scripts/hummingbot-cron-wrapper.sh" "$@" || exit $?

echo "Unit:   $unit"
echo "Status: systemctl --user status $unit"
echo "Follow: journalctl --user -u $unit -f"
echo "Logs:   $LOG_PATH/cron/"
