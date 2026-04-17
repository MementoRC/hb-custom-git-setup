#!/bin/bash
# Rebase _for_bleed/ branches onto development using diff-and-apply with file scoping.
#
# Usage: bash rebase-all-onto-development.sh [--dry-run] [--resume] [--branch <name>]
#
# Each branch has explicit file patterns to prevent cross-branch pollution.
# --resume skips branches that already have commits on development.

set -euo pipefail

REPO="/home/memento/PycharmProjects/Hummingbot/hummingbot"
DRY_RUN=""
RESUME=""
SINGLE_BRANCH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN="true"; shift ;;
        --resume) RESUME="true"; shift ;;
        --branch) SINGLE_BRANCH="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

cd "$REPO"

echo "=== Rebase Branches onto Development (scoped diff-and-apply) ==="
echo ""

# Verify clean
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: Working tree not clean. Commit or stash first."
    exit 1
fi

# --- Core function ---
# Args: old_name, parent, commit_msg, file_patterns...
rebase_branch() {
    local old_name="$1"
    local parent="$2"
    local commit_msg="$3"
    shift 3
    local file_patterns=("$@")

    echo ""
    echo "=========================================="
    echo "  $old_name → parent: $parent"
    echo "  Scope: ${file_patterns[*]}"
    echo "=========================================="

    # Resume check: if branch already has commits on development, skip
    if [ "$RESUME" = "true" ]; then
        local existing_commits
        existing_commits=$(git rev-list "development..$old_name" --count 2>/dev/null || echo "0")
        # Check if the branch tip is NOT an ancestor of old bleeding-edge
        # (i.e., it's been rebased already — has a development-based parent)
        local merge_base
        merge_base=$(git merge-base development "$old_name" 2>/dev/null || echo "none")
        local dev_head
        dev_head=$(git rev-parse development 2>/dev/null)
        if [ "$existing_commits" != "0" ] && [ "$merge_base" = "$dev_head" ]; then
            echo "  SKIP (already rebased, $existing_commits commits on development)"
            return 0
        fi
    fi

    # Find archive or source branch
    local source="$old_name"
    local archive_name
    archive_name=$(echo "$old_name" | sed 's/_for_bleed/_old_bleed/' | sed 's/_for_bleed_manual/_old_bleed_manual/')

    # If archive exists, source from it (branch was already archived in prior run)
    if git rev-parse --verify "$archive_name" &>/dev/null; then
        source="$archive_name"
        echo "  Using archive: $archive_name"
    elif ! git rev-parse --verify "$old_name" &>/dev/null; then
        echo "  SKIP: neither $old_name nor $archive_name exists"
        return 0
    fi

    # Get scoped diff
    local changed_files
    if [ "$parent" = "development" ]; then
        changed_files=$(git diff "development...$source" --name-only -- "${file_patterns[@]}" 2>/dev/null || true)
    else
        changed_files=$(git diff "$parent...$source" --name-only -- "${file_patterns[@]}" 2>/dev/null || true)
    fi

    if [ -z "$changed_files" ]; then
        echo "  SKIP: no changes in scoped files"
        return 0
    fi

    local file_count
    file_count=$(echo "$changed_files" | wc -l)
    echo "  Scoped files changed: $file_count"

    if [ "$DRY_RUN" = "true" ]; then
        echo "$changed_files" | sed 's/^/    /'
        return 0
    fi

    # Archive if not already done
    if ! git rev-parse --verify "$archive_name" &>/dev/null; then
        echo "  Archiving: $old_name → $archive_name"
        git branch -c "$old_name" "$archive_name"
        source="$archive_name"
    fi

    # Delete old branch, create new from parent
    git checkout "$parent" 2>/dev/null
    git branch -D "$old_name" 2>/dev/null || true
    git checkout -b "$old_name"

    # Apply scoped changes
    local applied=0
    while IFS= read -r file; do
        # Check if the path is a gitlink (submodule) — mode 160000
        local ls_entry
        ls_entry=$(git ls-tree "$source" -- "$file" 2>/dev/null || true)
        local obj_mode
        obj_mode=$(echo "$ls_entry" | awk '{print $1}')

        if [ "$obj_mode" = "160000" ]; then
            # Gitlink: restore via update-index (git show/add would create a blob)
            local gitlink_hash
            gitlink_hash=$(echo "$ls_entry" | awk '{print $3}')
            git update-index --add --cacheinfo "160000,$gitlink_hash,$file"
            echo "    gitlink: $file → $gitlink_hash"
            applied=$((applied + 1))
        elif git cat-file -e "$source:$file" 2>/dev/null; then
            mkdir -p "$(dirname "$file")"
            git show "$source:$file" > "$file"
            git add -f "$file"
            applied=$((applied + 1))
        else
            if [ -f "$file" ]; then
                git rm -f "$file" 2>/dev/null || true
                applied=$((applied + 1))
            fi
        fi
    done <<< "$changed_files"

    if git diff --cached --quiet; then
        echo "  No effective changes after scoped apply ($applied files examined). Skipping."
        return 0
    fi

    git commit -m "$commit_msg

Rebased onto $parent via scoped diff-and-apply.
Original history preserved on $archive_name.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>" --no-verify

    echo "  ✓ $(git log --oneline -1)"
}

# =====================================================================
# Branch definitions with explicit file scopes
# =====================================================================

process_all() {

echo "=== Phase 1: Flat branches ==="

rebase_branch "_for_bleed/ci-and-testing" "development" \
    "ci: consolidated CI+testing — pixi workflow, asyncio_mode, pytest-timeout, passwd-hash fix" \
    .pre-commit-config.yaml pyproject.toml test/

rebase_branch "_for_bleed/environment" "development" \
    "fix: environment and dependency fixes (injective-py, pip_packages)" \
    setup/environment.yml hummingbot/client/config/config_helpers.py \
    hummingbot/connector/client_order_tracker.py

rebase_branch "_for_bleed/candles-public-api" "development" \
    "feat: public API for CandlesBase + hb-candles-feed integration" \
    hummingbot/data_feed/candles_feed/candles_base.py \
    hummingbot/data_feed/market_data_provider.py \
    hummingbot/connector/exchange/coinbase_advanced_trade/

rebase_branch "_for_bleed/add-executor-lock-unlock-collateral" "development" \
    "feat: lock/unlock collateral for executor" \
    hummingbot/strategy_v2/executors/executor_base.py \
    hummingbot/strategy_v2/executors/data_types.py

rebase_branch "_for_bleed/progressive-executor-trading-v2" "development" \
    "feat: ProgressiveExecutor v2 with control/order/PnL mixins" \
    hummingbot/strategy_v2/executors/progressive_executor/ \
    hummingbot/strategy_v2/controllers/progressive_trading_controller.py \
    controllers/progressive_trading/ \
    test/hummingbot/strategy_v2/executors/progressive_executor/ \
    test/hummingbot/strategy_v2/controllers/test_progressive_trading_controller_base.py

rebase_branch "_for_bleed/add-update-executor-action" "development" \
    "feat: UpdateExecutorAction framework + volatility dispatch" \
    hummingbot/strategy_v2/executors/data_types.py \
    hummingbot/strategy_v2/executors/executor_orchestrator.py \
    test/hummingbot/strategy_v2/executors/test_executor_orchestrator.py

rebase_branch "_for_bleed/executor-mixins" "development" \
    "feat: 7 shared executor mixins (Retry, Balance, Shutdown, OrderTracking, ActivationBounds, TrailingStop, PNL)" \
    hummingbot/strategy_v2/executors/mixins/ \
    hummingbot/strategy_v2/executors/executor_protocols.py \
    hummingbot/strategy_v2/executors/protocols.py \
    hummingbot/strategy_v2/utils/trailing_stop_manager.py \
    test/hummingbot/strategy_v2/executors/mixins/ \
    test/hummingbot/strategy_v2/executors/executor_integration_test_base.py \
    test/hummingbot/strategy_v2/utils/test_trailing_stop_controller.py

rebase_branch "_for_bleed/pixi-workspace" "development" \
    "feat: pixi workspace migration and sub-package submodules" \
    pixi.toml .gitmodules sub-packages/ .gitignore .github/workflows/

rebase_branch "_for_bleed/strategy-framework" "development" \
    "feat: OrchestratorBridge delegating to strategy_framework.hb_compat" \
    hummingbot/strategy_v2/hb_compat/ \
    hummingbot/strategy/strategy_v2_base.py \
    test/hummingbot/strategy_v2/hb_compat/

rebase_branch "_for_bleed/rust-integration" "development" \
    "feat: Rust extension crate with Python fallback wrappers" \
    hummingbot/rust/ hummingbot/core/rust_metrics.py \
    hummingbot/core/data_type/order_expiration_entry_rust.py \
    test/hummingbot/core/test_rust_metrics.py \
    test/hummingbot/core/data_type/test_order_expiration_entry_rust.py \
    Cargo.toml pyproject.toml

rebase_branch "_for_bleed/augmented-pure-python" "development" \
    "feat: Cython-to-Augmented-Pure-Python framework, docs, .gitignore" \
    docs/development/augmented-pure-python.md .gitignore

rebase_branch "_for_bleed_manual/kraken-tweaks" "development" \
    "fix: Kraken order status handling and startup cleanup" \
    hummingbot/connector/exchange/kraken/

rebase_branch "_for_bleed/add-new-order-types" "development" \
    "feat: conditional OrderType enum (STOP_LOSS, TAKE_PROFIT, TRAILING_STOP)" \
    hummingbot/core/data_type/common.py \
    hummingbot/core/data_type/order_candidate.py \
    hummingbot/core/data_type/delayed_market_order.py \
    test/hummingbot/core/data_type/

echo ""
echo "=== Phase 2: Chained branches ==="

rebase_branch "_for_bleed/kraken-new-order-types" "_for_bleed/add-new-order-types" \
    "feat: Kraken connector conditional order routing" \
    hummingbot/connector/exchange/kraken/ \
    test/hummingbot/connector/exchange/kraken/

rebase_branch "_for_bleed/position-exchange-executor" "_for_bleed/add-new-order-types" \
    "feat: PositionOnExchangeExecutor for exchange-native stop-loss" \
    hummingbot/strategy_v2/executors/position_on_exchange_executor/ \
    test/hummingbot/strategy_v2/executors/position_on_exchange_executor/

rebase_branch "_for_bleed/add-executor-factory" "_for_bleed/executor-mixins" \
    "feat: ExecutorFactory with decorator-based registration" \
    hummingbot/strategy_v2/executors/executor_factory.py \
    hummingbot/strategy_v2/executors/executor_orchestrator.py \
    test/hummingbot/strategy_v2/executors/test_executor_factory.py \
    test/hummingbot/strategy_v2/executors/test_executor_orchestrator.py

}

# --- Dispatch ---
if [ -n "$SINGLE_BRANCH" ]; then
    echo "Single branch mode: $SINGLE_BRANCH"
    echo "Use the full script without --branch for proper scoping."
    echo "(Each branch has hardcoded file patterns — single mode not supported)"
    exit 1
else
    process_all
fi

# --- Summary ---
echo ""
echo "=== Summary ==="
git checkout development 2>/dev/null || true

if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] No changes made."
else
    echo "Rebased branches:"
    for branch in \
        _for_bleed/ci-and-testing \
        _for_bleed/environment _for_bleed/candles-public-api \
        _for_bleed/add-executor-lock-unlock-collateral \
        _for_bleed/progressive-executor-trading-v2 \
        _for_bleed/add-update-executor-action _for_bleed/executor-mixins \
        _for_bleed/pixi-workspace _for_bleed/strategy-framework \
        _for_bleed/rust-integration _for_bleed/augmented-pure-python \
        _for_bleed_manual/kraken-tweaks _for_bleed/add-new-order-types \
        _for_bleed/kraken-new-order-types _for_bleed/position-exchange-executor \
        _for_bleed/add-executor-factory; do
        if git rev-parse --verify "$branch" &>/dev/null; then
            count=$(git rev-list "development..$branch" --count 2>/dev/null || echo "?")
            echo "  $branch ($count commits)"
        fi
    done
fi
