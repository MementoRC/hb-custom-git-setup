#!/bin/bash
###############################################################################
# hummingbot-interface-check.sh
# -----------------------------
# Detects when upstream changes break base classes that the progressive
# executor depends on. Uses pixi env for Python import checks.
#
# Checks:
#   - hummingbot.strategy_v2.executors.executor_base (ExecutorBase)
#   - hummingbot.strategy_v2.executors.executor_orchestrator (ExecutorOrchestrator)
#   - hummingbot.strategy_v2.executors.data_types
#   - hummingbot.strategy_v2.controllers.directional_trading_controller_base
#   - Shimmed overlay surfaces listed in configs/monitored-interfaces.yaml
#     (import + name presence, plus upstream-drift warnings)
#
# Exit codes: 0=COMPATIBLE, 1=error, 2=BREAKING changes
#
# Usage:
#   ./hummingbot-interface-check.sh [--verbose]
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

###############################################################################
# Configuration
###############################################################################
VERBOSE=false
REPORT_FILE="${LOG_PATH}/interface_check_latest.txt"
BREAKING_CHANGES=()
WARNINGS=()
INTERFACES_CONFIG="${INTERFACES_CONFIG:-$CONFIG_PATH/monitored-interfaces.yaml}"
SHIM_SUMMARIES=()

###############################################################################
# Parse Arguments
###############################################################################
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose) VERBOSE=true; shift ;;
        --help)
            echo "Usage: $0 [--verbose]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

###############################################################################
# Python Check Helper
###############################################################################
# Runs a Python snippet via pixi run python (hummingbot pixi environment).
# Returns 0 on success, 1 on import failure.
run_python_check() {
    local description="$1"
    local python_code="$2"

    if [ "$VERBOSE" = true ]; then
        log_detail "Checking: $description" >&2
    fi

    local output
    output=$(pixi run --frozen python -c "$python_code" 2>&1)
    local status=$?

    if [ $status -ne 0 ]; then
        log_error "FAIL: $description"
        if [ "$VERBOSE" = true ]; then
            log_detail "  Output: $output" >&2
        fi
        return 1
    fi

    if [ -n "$output" ]; then
        # Python code printed something (could be a warning)
        echo "$output"
    fi

    return 0
}

###############################################################################
# Interface Checks
###############################################################################
check_executor_base() {
    log_section "$(colorize "$BLUE" "ExecutorBase")"

    # Check import
    if ! run_python_check "Import ExecutorBase" \
        "from hummingbot.strategy_v2.executors.executor_base import ExecutorBase"; then
        BREAKING_CHANGES+=("ExecutorBase: cannot import")
        log_result false "Import failed"
        return 1
    fi
    log_step "Import: OK"

    # Check __init__ signature has expected params
    local init_check
    init_check=$(run_python_check "ExecutorBase.__init__ signature" "
import inspect
from hummingbot.strategy_v2.executors.executor_base import ExecutorBase
sig = inspect.signature(ExecutorBase.__init__)
params = list(sig.parameters.keys())
# Expected core params (self is always first)
expected = ['self', 'strategy', 'config', 'connectors']
missing = [p for p in expected if p not in params]
if missing:
    print('MISSING_PARAMS:' + ','.join(missing))
else:
    print('OK')
extra = [p for p in params if p not in expected and p != 'update_interval']
if extra:
    print('NEW_PARAMS:' + ','.join(extra))
")

    if echo "$init_check" | grep -q "^MISSING_PARAMS:"; then
        local missing_params="${init_check#MISSING_PARAMS:}"
        BREAKING_CHANGES+=("ExecutorBase.__init__: missing params: $missing_params")
        log_error "Missing parameters: $missing_params"
        log_result false "Signature changed"
        return 1
    fi

    if echo "$init_check" | grep -q "^NEW_PARAMS:"; then
        local new_params
        new_params=$(echo "$init_check" | grep "^NEW_PARAMS:" | sed 's/^NEW_PARAMS://')
        WARNINGS+=("ExecutorBase.__init__: new params added: $new_params")
        log_warning "New parameters added: $new_params"
    fi

    # Check key methods exist (actual methods from executor_base.py)
    local methods_check
    methods_check=$(run_python_check "ExecutorBase methods" "
from hummingbot.strategy_v2.executors.executor_base import ExecutorBase
expected_methods = ['start', 'stop', 'early_stop', 'validate_sufficient_balance', 'place_order', 'executor_info']
missing = [m for m in expected_methods if not hasattr(ExecutorBase, m)]
if missing:
    print('MISSING_METHODS:' + ','.join(missing))
else:
    print('OK')
")

    if echo "$methods_check" | grep -q "^MISSING_METHODS:"; then
        local missing_methods="${methods_check#MISSING_METHODS:}"
        BREAKING_CHANGES+=("ExecutorBase: missing methods: $missing_methods")
        log_error "Missing methods: $missing_methods"
        log_result false "Methods removed"
        return 1
    fi

    log_result true "ExecutorBase compatible"
    return 0
}

check_executor_orchestrator() {
    log_section "$(colorize "$BLUE" "ExecutorOrchestrator")"

    if ! run_python_check "Import ExecutorOrchestrator" \
        "from hummingbot.strategy_v2.executors.executor_orchestrator import ExecutorOrchestrator"; then
        BREAKING_CHANGES+=("ExecutorOrchestrator: cannot import")
        log_result false "Import failed"
        return 1
    fi
    log_step "Import: OK"

    # Check key methods
    local methods_check
    methods_check=$(run_python_check "ExecutorOrchestrator methods" "
from hummingbot.strategy_v2.executors.executor_orchestrator import ExecutorOrchestrator
expected = ['execute_action', 'execute_actions']
missing = [m for m in expected if not hasattr(ExecutorOrchestrator, m)]
if missing:
    print('MISSING_METHODS:' + ','.join(missing))
else:
    print('OK')
")

    if echo "$methods_check" | grep -q "^MISSING_METHODS:"; then
        local missing_methods="${methods_check#MISSING_METHODS:}"
        BREAKING_CHANGES+=("ExecutorOrchestrator: missing methods: $missing_methods")
        log_error "Missing methods: $missing_methods"
        log_result false "Methods removed"
        return 1
    fi

    log_result true "ExecutorOrchestrator compatible"
    return 0
}

check_data_types() {
    log_section "$(colorize "$BLUE" "Executor Data Types")"

    local check_output
    local check_status
    check_output=$(run_python_check "Import data_types" "
try:
    from hummingbot.strategy_v2.executors.data_types import ExecutorConfigBase, ConnectorPair
    print('OK')
except Exception as e:
    print('IMPORT_ERROR:' + str(e))
")
    check_status=$?

    if [ $check_status -ne 0 ]; then
        BREAKING_CHANGES+=("data_types: probe failed (non-ImportError crash or environment failure)")
        log_result false "Probe failed"
        return 1
    fi

    if echo "$check_output" | grep -q "^IMPORT_ERROR:"; then
        local err="${check_output#IMPORT_ERROR:}"
        BREAKING_CHANGES+=("data_types: import error: $err")
        log_result false "Import failed: $err"
        return 1
    fi

    log_step "Import: OK"
    log_result true "Data types compatible"
    return 0
}

check_directional_controller() {
    log_section "$(colorize "$BLUE" "DirectionalTradingControllerBase")"

    local check_output
    local check_status
    check_output=$(run_python_check "Import DirectionalTradingControllerBase" "
try:
    from hummingbot.strategy_v2.controllers.directional_trading_controller_base import (
        DirectionalTradingControllerBase,
        DirectionalTradingControllerConfigBase
    )
    print('OK')
except Exception as e:
    print('IMPORT_ERROR:' + str(e))
")
    check_status=$?

    if [ $check_status -ne 0 ]; then
        BREAKING_CHANGES+=("DirectionalTradingController: probe failed (non-ImportError crash or environment failure)")
        log_result false "Probe failed"
        return 1
    fi

    if echo "$check_output" | grep -q "^IMPORT_ERROR:"; then
        local err="${check_output#IMPORT_ERROR:}"
        BREAKING_CHANGES+=("DirectionalTradingController: import error: $err")
        log_result false "Import failed: $err"
        return 1
    fi
    log_step "Import: OK"

    # Check config base has expected fields (Pydantic model_fields includes inherited)
    local fields_check
    local fields_status
    fields_check=$(run_python_check "Config fields" "
from hummingbot.strategy_v2.controllers.directional_trading_controller_base import DirectionalTradingControllerConfigBase
# Use Pydantic model_fields to get all fields including inherited ones
all_fields = set(DirectionalTradingControllerConfigBase.model_fields.keys())
# Also check class attributes for non-field attrs
for attr in dir(DirectionalTradingControllerConfigBase):
    if not attr.startswith('_'):
        all_fields.add(attr)
expected_fields = ['controller_name', 'connector_name', 'trading_pair', 'controller_type']
missing = [f for f in expected_fields if f not in all_fields]
if missing:
    print('MISSING_FIELDS:' + ','.join(missing))
else:
    print('OK')
")
    fields_status=$?

    if [ $fields_status -ne 0 ]; then
        BREAKING_CHANGES+=("DirectionalTradingControllerConfigBase: fields probe failed")
        log_result false "Probe failed"
        return 1
    fi

    if echo "$fields_check" | grep -q "^MISSING_FIELDS:"; then
        local missing_fields="${fields_check#MISSING_FIELDS:}"
        BREAKING_CHANGES+=("DirectionalTradingControllerConfigBase: missing fields: $missing_fields")
        log_error "Missing fields: $missing_fields"
        log_result false "Config fields changed"
        return 1
    fi

    log_result true "DirectionalTradingController compatible"
    return 0
}

check_shimmed_surfaces() {
    log_section "$(colorize "$BLUE" "Shimmed Surfaces")"

    if [ ! -s "$INTERFACES_CONFIG" ]; then
        WARNINGS+=("shimmed surfaces: $INTERFACES_CONFIG missing or empty, skipped")
        log_warning "Monitored-interface list missing or empty, skipping"
        return 0
    fi

    # Output protocol (one record per line):
    #   EMPTY | BREAKING:<msg> | WARNING:<msg> | SUMMARY:<pkg>|<modules>|<names>|<breaking>|<warnings>
    local check_output
    local check_status
    check_output=$(MI_CONFIG="$INTERFACES_CONFIG" MI_REPO="$REPO_PATH" \
        run_python_check "Shimmed surfaces" "
import ast
import importlib
import os
import subprocess
import yaml

with open(os.environ['MI_CONFIG']) as fh:
    doc = yaml.safe_load(fh) or {}
surfaces = doc.get('shimmed_surfaces') or {}
internal = {m: set(v or []) for m, v in (doc.get('internal_names') or {}).items()}
if not surfaces:
    print('EMPTY')
    raise SystemExit(0)
repo = os.environ['MI_REPO']

def public_names(source):
    names = set()
    exported = set()
    for node in ast.parse(source).body:
        targets = []
        if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            names.add(node.name)
        elif isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, ast.AnnAssign):
            targets = [node.target]
        for target in targets:
            if not isinstance(target, ast.Name):
                continue
            names.add(target.id)
            if target.id == '__all__' and isinstance(node.value, (ast.List, ast.Tuple)):
                exported.update(e.value for e in node.value.elts if isinstance(e, ast.Constant))
    return {n for n in names if not n.startswith('_')} | exported

def upstream_source(module):
    base = module.replace('.', '/')
    for candidate in (base + '.py', base + '/__init__.py'):
        res = subprocess.run(['git', 'show', 'origin/development:' + candidate],
                             cwd=repo, capture_output=True, text=True)
        if res.returncode == 0:
            return res.stdout
        if 'does not exist' not in res.stderr and 'exists on disk' not in res.stderr:
            raise RuntimeError(res.stderr.strip())
    return None

for package, modules in surfaces.items():
    n_mod = n_names = n_break = n_warn = 0
    for module, listed in (modules or {}).items():
        n_mod += 1
        listed = list(listed or [])
        try:
            mod = importlib.import_module(module)
        except Exception as e:
            print('BREAKING:%s: cannot import %s: %s' % (package, module, e))
            n_break += 1
            mod = None
        if mod is not None:
            for name in listed:
                n_names += 1
                if not hasattr(mod, name):
                    print('BREAKING:%s: %s.%s missing' % (package, module, name))
                    n_break += 1
        try:
            source = upstream_source(module)
            if source is None:
                print('WARNING:%s: %s removed/moved upstream' % (package, module))
                n_warn += 1
                continue
            for name in sorted(public_names(source) - set(listed) - internal.get(module, set())):
                print('WARNING:%s: upstream added %s.%s not in monitored list' % (package, module, name))
                n_warn += 1
        except Exception as e:
            print('WARNING:%s: upstream drift check failed for %s: %s' % (package, module, e))
            n_warn += 1
    print('SUMMARY:%s|%d|%d|%d|%d' % (package, n_mod, n_names, n_break, n_warn))
")
    check_status=$?

    if [ $check_status -ne 0 ]; then
        BREAKING_CHANGES+=("shimmed surfaces: probe failed (non-ImportError crash or environment failure)")
        log_result false "Probe failed"
        return 1
    fi

    if echo "$check_output" | grep -q "^EMPTY$"; then
        WARNINGS+=("shimmed surfaces: no shimmed_surfaces entries in $INTERFACES_CONFIG, skipped")
        log_warning "Monitored-interface list is empty, skipping"
        return 0
    fi

    local line
    local breaking_before=${#BREAKING_CHANGES[@]}
    while IFS= read -r line; do
        case "$line" in
            BREAKING:*)
                BREAKING_CHANGES+=("${line#BREAKING:}")
                log_error "${line#BREAKING:}"
                ;;
            WARNING:*)
                WARNINGS+=("${line#WARNING:}")
                log_warning "${line#WARNING:}"
                ;;
            SUMMARY:*)
                local pkg modules names brk warn
                IFS='|' read -r pkg modules names brk warn <<< "${line#SUMMARY:}"
                SHIM_SUMMARIES+=("${pkg}: ${modules} modules, ${names} names checked, ${brk} breaking, ${warn} warnings")
                log_step "${pkg}: ${modules} modules, ${names} names, ${brk} breaking, ${warn} warnings"
                ;;
        esac
    done <<< "$check_output"

    if [ ${#BREAKING_CHANGES[@]} -gt "$breaking_before" ]; then
        log_result false "Shimmed surfaces changed"
        return 1
    fi

    log_result true "Shimmed surfaces compatible"
    return 0
}

###############################################################################
# Report Generation
###############################################################################
write_report() {
    local status_label="COMPATIBLE"
    [ ${#BREAKING_CHANGES[@]} -gt 0 ] && status_label="BREAKING"

    cat > "$REPORT_FILE" <<EOF
Interface Compatibility Report
==============================
Date:     $(date '+%Y-%m-%d %H:%M:%S')
Branch:   $(cd "$REPO_PATH" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
Commit:   $(cd "$REPO_PATH" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
Status:   ${status_label}

EOF

    if [ ${#BREAKING_CHANGES[@]} -gt 0 ]; then
        echo "Breaking Changes:" >> "$REPORT_FILE"
        for change in "${BREAKING_CHANGES[@]}"; do
            echo "  [BREAK] ${change}" >> "$REPORT_FILE"
        done
        echo "" >> "$REPORT_FILE"
    fi

    if [ ${#WARNINGS[@]} -gt 0 ]; then
        echo "Warnings:" >> "$REPORT_FILE"
        for warn in "${WARNINGS[@]}"; do
            echo "  [WARN]  ${warn}" >> "$REPORT_FILE"
        done
        echo "" >> "$REPORT_FILE"
    fi

    if [ ${#SHIM_SUMMARIES[@]} -gt 0 ]; then
        echo "Shimmed Surfaces:" >> "$REPORT_FILE"
        for summary in "${SHIM_SUMMARIES[@]}"; do
            echo "  ${summary}" >> "$REPORT_FILE"
        done
        echo "" >> "$REPORT_FILE"
    fi

    if [ ${#BREAKING_CHANGES[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ]; then
        echo "All interface checks passed. No breaking changes detected." >> "$REPORT_FILE"
    fi
}

###############################################################################
# Main Execution
###############################################################################
log_header "$(colorize "$BLUE" "Interface Compatibility Check")"

# Ensure we're in the repo
cd "$REPO_PATH" || {
    log_error "Failed to change to repository directory: $REPO_PATH"
    exit 1
}

###############################################################################
# Build Cython Extensions
###############################################################################
# Build is handled by cron wrapper Step 2.75 before this script is invoked.
# When run standalone (outside cron), callers should run `pixi run build`
# manually before invoking this script, or the probes may reflect stale .so.
log_section "$(colorize "$BLUE" "Building Cython extensions")"
# Build skipped: handled by cron wrapper Step 2.75
echo "[interface-check] Build skipped: handled by cron wrapper Step 2.75"
build_output=""
build_status=0

# pixi run automatically activates the hummingbot environment
# Run all interface checks
check_executor_base
check_executor_orchestrator
check_data_types
check_directional_controller
check_shimmed_surfaces

# Write report
write_report

log_footer

# Display summary
if [ ${#BREAKING_CHANGES[@]} -gt 0 ]; then
    echo ""
    colorize "$RED" "BREAKING: ${#BREAKING_CHANGES[@]} breaking change(s) detected"
    echo "See: $REPORT_FILE"
    exit 2
elif [ ${#WARNINGS[@]} -gt 0 ]; then
    echo ""
    colorize "$YELLOW" "COMPATIBLE with ${#WARNINGS[@]} warning(s)"
    echo "See: $REPORT_FILE"
    exit 0
else
    echo ""
    colorize "$GREEN" "COMPATIBLE: All interface checks passed"
    exit 0
fi
