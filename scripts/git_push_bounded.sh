#!/usr/bin/env bash
# git_push_bounded <repo_dir> <git push args...>
#
# Single entry point for EVERY `git push` in the pipeline. A push over HTTPS
# once hung >20 min inside git-remote-https during --rebuild; this turns a hang
# into a bounded, logged, non-zero failure. Side-effect free so it can be sourced
# by common.sh and by standalone scripts (regenerate-*-pr.sh) alike.
#
#   - GIT_TERMINAL_PROMPT=0 / GCM_INTERACTIVE=never: a credential prompt fails
#     immediately instead of waiting on the TTY.
#   - http.lowSpeedLimit/lowSpeedTime: a stalled transfer aborts.
#   - timeout --kill-after=30 ${HB_PUSH_TIMEOUT_S:-900}: hard wall-clock bound.
# stdout/stderr of git pass through unchanged. No retry. Exit 124/137 are logged
# as a timeout (also appended to $RUN_LOG_DIR/push_timeout.log, since callers
# commonly discard output) and returned as-is (non-zero).
git_push_bounded() {
    local repo="$1"
    shift
    local limit="${HB_PUSH_TIMEOUT_S:-900}" rc=0 msg
    GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never \
        timeout --kill-after=30 "$limit" \
        git -C "$repo" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=120 push "$@" || rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        msg="push timed out after ${limit}s: $*"
        if declare -F log_error > /dev/null; then
            log_error "$msg"
        else
            echo "$msg" >&2
        fi
        if [ -n "${RUN_LOG_DIR:-}" ] && [ -d "$RUN_LOG_DIR" ]; then
            echo "$msg" >> "$RUN_LOG_DIR/push_timeout.log"
        fi
    fi
    return "$rc"
}
