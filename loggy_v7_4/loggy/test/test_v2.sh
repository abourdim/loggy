#!/bin/bash
# test_v2.sh — V2.0 Upgrade Validation Tests
# Loggy v6.0
#
# Tests:
#   1. Registry loading (363 entries, correct columns)
#   2. Detector count and signatures
#   3. Health score weights
#   4. Config validation
#   5. Causal chain definitions
#   6. Report formatting (troubleshooting blocks)
#   7. Syntax validation of all shell scripts

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
TESTS=0

pass() { PASS=$((PASS+1)); TESTS=$((TESTS+1)); printf "  ✅ %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); TESTS=$((TESTS+1)); printf "  ❌ %s\n" "$1"; }
section() { printf "\n═══ %s ═══\n" "$1"; }

# ─── 1. Registry ─────────────────────────────────────────────────────────
section "Registry (error_registry.tsv)"

REG="signatures/error_registry.tsv"
if [ -f "$REG" ]; then
    pass "Registry file exists"
else
    fail "Registry file missing"; exit 1
fi

# Count entries (skip header)
entries=$(tail -n+2 "$REG" | grep -c '.' || echo 0)
if [ "$entries" -ge 360 ]; then
    pass "Registry has $entries entries (≥360)"
else
    fail "Registry has $entries entries (expected ≥360)"
fi

# Check column count (8 columns: module|code|type|name|desc|troubleshoot|onsite|severity)
cols=$(head -1 "$REG" | awk -F'\t' '{print NF}')
if [ "$cols" -eq 8 ]; then
    pass "Registry has $cols columns"
else
    fail "Registry has $cols columns (expected 8)"
fi

# Check severity values
for sev in CRITICAL HIGH MEDIUM LOW; do
    cnt=$(awk -F'\t' -v s="$sev" '$8==s' "$REG" | wc -l)
    if [ "$cnt" -gt 0 ]; then
        pass "Severity $sev: $cnt entries"
    else
        fail "Severity $sev: 0 entries"
    fi
done

# Check known module
hlc_cnt=$(awk -F'\t' '$1=="HLCStateMachine"' "$REG" | wc -l)
if [ "$hlc_cnt" -ge 30 ]; then
    pass "HLCStateMachine: $hlc_cnt entries (≥30)"
else
    fail "HLCStateMachine: $hlc_cnt entries (expected ≥30)"
fi

# Check troubleshooting steps present
ts_cnt=$(awk -F'\t' '$6!=""' "$REG" | wc -l)
if [ "$ts_cnt" -gt 250 ]; then
    pass "Entries with troubleshooting: $ts_cnt (>250)"
else
    fail "Entries with troubleshooting: $ts_cnt (expected >250)"
fi

# ─── 2. Detectors ────────────────────────────────────────────────────────
section "Detectors (analyzer_standard.sh)"

ASH="lib/analyzer_standard.sh"
issue_calls=$(grep -c 'add_issue' "$ASH")
if [ "$issue_calls" -ge 60 ]; then
    pass "add_issue calls: $issue_calls (≥60)"
else
    fail "add_issue calls: $issue_calls (expected ≥60)"
fi

# Check key V2.0 patterns are present
for pat in "OCPP_CONNECTION_ERROR" "Error_PrechargeResTimeout" "MaximalDeratingReached" \
           "StorageFallbackMode" "ProcessRestartedTooOften" "HighCpuUsage" \
           "RequiredMeterMissing" "EICHRECHT_ERROR_STATE_TERMINAL" \
           "LidCloseWaitUnplug" "ExternalEmergencyStop" \
           "NETWORK_NOT_FOUND" "CONN_FAILED" \
           "No3phCurrentFlowDetected" "POWER_IMBALANCE_DETECTED" \
           "PowerBoardFirmwareUpdateFailed" "Temperature1Error"; do
    if grep -q "$pat" "$ASH"; then
        pass "Pattern: $pat"
    else
        fail "Pattern missing: $pat"
    fi
done

# Check new metrics
for met in "temp_critical" "lid_open" "wifi_failures" "em_session_start_err" \
           "monit_too_often" "meter_missing_critical" "evic_reboots" \
           "fw_powerboard_fail" "config_warnings"; do
    if grep -q "\"$met\"" "$ASH"; then
        pass "Metric: $met"
    else
        fail "Metric missing: $met"
    fi
done

# ─── 3. Health Score ─────────────────────────────────────────────────────
section "Health Score (scorer.sh)"

SCR="lib/scorer.sh"

# Check weights sum to 100
w_conn=$(grep '^WEIGHT_CONN=' "$SCR" | cut -d= -f2)
w_hw=$(grep '^WEIGHT_HW=' "$SCR" | cut -d= -f2)
w_svc=$(grep '^WEIGHT_SVC=' "$SCR" | cut -d= -f2)
w_cfg=$(grep '^WEIGHT_CFG=' "$SCR" | cut -d= -f2)
total=$((w_conn + w_hw + w_svc + w_cfg))
if [ "$total" -eq 100 ]; then
    pass "Weights sum to 100 ($w_conn/$w_hw/$w_svc/$w_cfg)"
else
    fail "Weights sum to $total (expected 100)"
fi

# Check V2.0 rebalanced weights
if [ "$w_conn" -eq 30 ] && [ "$w_hw" -eq 25 ] && [ "$w_svc" -eq 25 ]; then
    pass "V2.0 weight balance: 30/25/25/20"
else
    fail "Weights not V2.0 balance (expected 30/25/25/20)"
fi

# Check new penalties exist
for pen in "temp_critical" "temp_max_derating" "lid_open" "fw_powerboard_fail" \
           "wifi_failures" "ocpp_connection_error" "meter_missing_critical" \
           "em_session_start_err" "em_power_imbalance" "monit_too_often" \
           "eichrecht_terminal"; do
    if grep -q "$pen" "$SCR"; then
        pass "Score penalty: $pen"
    else
        fail "Score penalty missing: $pen"
    fi
done

# ─── 4. Config Validation ────────────────────────────────────────────────
section "Config Validation"

for key in "interfaceSelectionManager.enable" "digitalCommunicationTimeout_ms" \
           "csUrl" "OfflineTimeout_s" "ppp0.enabled"; do
    if grep -q "$key" "$ASH"; then
        pass "Config check: $key"
    else
        fail "Config check missing: $key"
    fi
done

# ─── 5. Causal Chains ────────────────────────────────────────────────────
section "Causal Chains (analyzer_deep.sh)"

DSH="lib/analyzer_deep.sh"
chains=$(grep 'printf.*CHAIN' "$DSH" | grep -c 'CHAIN')
if [ "$chains" -ge 10 ]; then
    pass "Causal chain definitions: $chains (≥10)"
else
    fail "Causal chain definitions: $chains (expected ≥10)"
fi

for chain in "Thermal" "Storage Degradation" "Meter.*Eichrecht" "V2G.*HLC" "PMQ"; do
    if grep -q "$chain" "$DSH"; then
        pass "Chain: $chain"
    else
        fail "Chain missing: $chain"
    fi
done

# ─── 6. Reports ──────────────────────────────────────────────────────────
section "Report Formatting"

# Markdown: troubleshooting block
if grep -q 'ts_text\|🔧' "generators/gen_markdown.sh"; then
    pass "Markdown: troubleshooting block"
else
    fail "Markdown: troubleshooting block missing"
fi

# HTML: troubleshooting CSS
if grep -q 'issue-troubleshoot' "generators/gen_html.sh"; then
    pass "HTML: troubleshooting CSS class"
else
    fail "HTML: troubleshooting CSS class missing"
fi

# HTML: on-site flag
if grep -q 'issue-onsite' "generators/gen_html.sh"; then
    pass "HTML: on-site service flag"
else
    fail "HTML: on-site service flag missing"
fi

# Tickets: structured troubleshooting section
if grep -q '## Troubleshooting Steps' "generators/gen_tickets.sh"; then
    pass "Tickets: structured troubleshooting section"
else
    fail "Tickets: troubleshooting section missing"
fi

# Tickets: on-site-service label
if grep -q 'on-site-service' "generators/gen_tickets.sh"; then
    pass "Tickets: on-site-service label"
else
    fail "Tickets: on-site-service label missing"
fi

# ─── 7. Syntax Check ─────────────────────────────────────────────────────
section "Syntax Validation"

for f in lib/*.sh generators/*.sh; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/dev/null; then
        pass "Syntax OK: $f"
    else
        fail "Syntax ERROR: $f"
    fi
done

# Python backend
if python3 -c "import py_compile; py_compile.compile('lib/server_backend.py', doraise=True)" 2>/dev/null; then
    pass "Syntax OK: lib/server_backend.py"
else
    fail "Syntax ERROR: lib/server_backend.py"
fi

# ─── 8. Version ──────────────────────────────────────────────────────────
section "Version"

ver=$(grep -a 'ANALYZER_VERSION=' lib/common.sh | cut -d'"' -f2)
if [ "$ver" = "7.2" ]; then
    pass "Version: $ver"
else
    fail "Version: $ver (expected 7.2)"
fi

# Check no v1.0 remains in core files
stale=$(grep -arl 'v1\.0\|V1\.0' lib/*.sh generators/*.sh 2>/dev/null | wc -l || true)
if [ "$stale" -eq 0 ]; then
    pass "No stale v1.0 references in core"
else
    fail "$stale files still reference v1.0"
fi

# ─── 9. Step A: Module Coverage ──────────────────────────────────────────
section "Module Coverage (Step A)"

for pat in "HARD_OVERCURRENT\|pb_stopcode" "ERROR_UNAVAILABLE\|ism_critical" \
           "CableCheckPrecondition\|dc_evic" "ErrorCIU_\|hal_ciu" \
           "EVDoesNotObey\|ev_disobey"; do
    if grep -q "$(echo "$pat" | cut -d'\' -f1)" "$ASH"; then
        pass "Detector pattern: $(echo "$pat" | head -c 25)"
    else
        fail "Pattern missing: $(echo "$pat" | head -c 25)"
    fi
done

# ─── 10. Step B: Report Troubleshoot ─────────────────────────────────────
section "Mail/Webapp Troubleshoot (Step B)"

if grep -q 'ts_text\|>> .*Troubleshoot' "generators/gen_mail.sh"; then
    pass "Email: troubleshooting split"
else
    fail "Email: troubleshooting split missing"
fi

if grep -q 'issue-ts\|descParts' "generators/gen_webapp.sh"; then
    pass "Webapp: troubleshooting split"
else
    fail "Webapp: troubleshooting split missing"
fi

if grep -q 'onsite-badge' "generators/gen_webapp.sh"; then
    pass "Webapp: on-site badge"
else
    fail "Webapp: on-site badge missing"
fi

# ─── 11. Step C: Batch Grep ──────────────────────────────────────────────
section "Performance (Step C)"

if grep -q 'batch_count_grep' "lib/common.sh"; then
    pass "batch_count_grep function defined"
else
    fail "batch_count_grep missing from common.sh"
fi

if grep -q 'batch_count_grep' "$ASH"; then
    pass "batch_count_grep used in analyzer"
else
    fail "batch_count_grep not used in analyzer"
fi

# ─── 12. Step E: Cross-Reference ─────────────────────────────────────────
section "Signature Cross-Reference (Step E)"

if grep -q 'cross-referenced\|merged_cause\|merged_fix' "lib/searcher.sh"; then
    pass "Searcher: cross-reference merge logic"
else
    fail "Searcher: cross-reference logic missing"
fi

# ─── 13. Step F: Error Handling ──────────────────────────────────────────
section "Error Handling (Step F)"

if grep -q 'safe_run' "lib/common.sh"; then
    pass "safe_run function defined"
else
    fail "safe_run function missing"
fi

safe_run_count=$(grep -c 'safe_run ' "$ASH")
if [ "$safe_run_count" -ge 20 ]; then
    pass "safe_run wraps $safe_run_count detector calls"
else
    fail "Only $safe_run_count safe_run calls (expected ≥20)"
fi

if grep -q '_setup_error_handling\|ANALYZER_ERRLOG' "$ASH"; then
    pass "Error handling initialized"
else
    fail "Error handling not initialized"
fi

# ─── 14. Step G: Server Backend ──────────────────────────────────────────
section "Server Backend (Step G)"

if grep -q 'col_map\|col("name")' "lib/server_backend.py"; then
    pass "Server backend: header-based column lookup"
else
    fail "Server backend: still using hardcoded indexes"
fi

# ─── 15. Step H: Deeper Config ──────────────────────────────────────────
section "Config Validation (Step H)"

cfg_checks=$(grep -c 'cfg_warnings=\$((cfg_warnings + 1))' "$ASH")
if [ "$cfg_checks" -ge 10 ]; then
    pass "Config validation checks: $cfg_checks (≥10)"
else
    fail "Only $cfg_checks config checks (expected ≥10)"
fi

for key in "emmcWearingCheckEnabled" "watchdog.enabled" "SECCRequestTimeoutAfterPause" \
           "ResponseTimeout" "powerLimitEnabled"; do
    if grep -q "$key" "$ASH"; then
        pass "Config check: $key"
    else
        fail "Config check missing: $key"
    fi
done

# ─── 16. Step I: Temporal Chains ─────────────────────────────────────────
section "Temporal Causal Chains (Step I)"

DSH="lib/analyzer_deep.sh"
if grep -q '_timeline_precedes' "$DSH"; then
    pass "Temporal validation helper defined"
else
    fail "Temporal validation helper missing"
fi

if grep -q '_timeline_gap_minutes' "$DSH"; then
    pass "Timeline gap calculator defined"
else
    fail "Timeline gap calculator missing"
fi

tp_uses=$(grep -c '_timeline_precedes' "$DSH")
if [ "$tp_uses" -ge 3 ]; then
    pass "Chains use temporal validation ($tp_uses refs)"
else
    fail "Chains don't use temporal validation ($tp_uses refs, expected ≥3)"
fi

# ─── Summary ──────────────────────────────────────────────────────────────
printf "\n══════════════════════════════════════════════\n"
printf "  V2.0+ Tests: %d passed, %d failed (%d total)\n" "$PASS" "$FAIL" "$TESTS"
printf "══════════════════════════════════════════════\n"

[ "$FAIL" -eq 0 ] && printf "  🎉 ALL TESTS PASSED\n\n" && exit 0
printf "  ⚠️  SOME TESTS FAILED\n\n" && exit 1
