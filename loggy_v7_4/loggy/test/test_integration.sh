#!/bin/bash
# test_integration.sh — Integration test with synthetic logs
# Runs actual analysis pipeline against synthetic log data and verifies output
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
TESTS=0

pass() { PASS=$((PASS+1)); TESTS=$((TESTS+1)); printf "  ✅ %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); TESTS=$((TESTS+1)); printf "  ❌ %s\n" "$1"; }
section() { printf "\n═══ %s ═══\n" "$1"; }

# ─── Setup: create work directory with synthetic log ─────────────────────
WORK="/tmp/ila_integ_$$"
mkdir -p "$WORK/logs" "$WORK/properties" "$WORK/report"

# Copy synthetic log — multiple names so detectors find their expected files
cp test/sample_logs/synthetic_combined.log "$WORK/logs/charger_combined.log"
cp test/sample_logs/synthetic_combined.log "$WORK/logs/iotc-health-monitor_combined.log"
cp test/sample_logs/synthetic_combined.log "$WORK/logs/HealthMonitor_combined.log"
cp test/sample_logs/synthetic_combined.log "$WORK/logs/iotc-fw-update_combined.log"
cp test/sample_logs/synthetic_combined.log "$WORK/logs/iotc-charger-app_combined.log"

# Create minimal properties files
cat > "$WORK/properties/ocpp-cmd.props" << 'EOF'
csUrl=wss://ocpp.example.com/cp001
OfflineTimeout_s=3600
EOF

cat > "$WORK/properties/NetworkBoss.props" << 'EOF'
interfaceSelectionManager.enable=true
ppp0.enabled=true
eth0.enabled=true
wlan0.enabled=false
EOF

cat > "$WORK/properties/ChargerApp.props" << 'EOF'
digitalCommunicationTimeout_ms=15000
Meter.preferred.type=ECR380D
Meter.preferred.disableChargingOnAbsence=true
EOF

cat > "$WORK/properties/iotc-health-monitor.props" << 'EOF'
emmcWearingCheckEnabled=false
watchdog.enabled=true
EOF

# ─── Source the analyzer libraries ───────────────────────────────────────
source lib/common.sh 2>/dev/null
VERBOSE=0
LOG_DIR="$WORK/logs"
WORK_DIR="$WORK"
SCRIPT_DIR="$(pwd)"
SIGNATURES_DIR="$(pwd)/signatures"
ISSUES_FILE="$WORK/issues.tsv"
TIMELINE_FILE="$WORK/timeline.tsv"
METRICS_FILE="$WORK/metrics.tsv"
SYSINFO_FILE="$WORK/sysinfo.tsv"
ANALYZER_ERRLOG="$WORK/errors.log"
: > "$ISSUES_FILE"
: > "$TIMELINE_FILE"
: > "$METRICS_FILE"
: > "$SYSINFO_FILE"
: > "$ANALYZER_ERRLOG"

# Load helper libraries
for f in lib/evidence.sh lib/scorer.sh; do
    [ -f "$f" ] && source "$f" 2>/dev/null
done

# Initialize logging/colors
LOG_LEVEL=0
LOG_FILE="${WORK}/analyzer.log"
: > "$LOG_FILE"
init_colors 2>/dev/null || true

# Mock functions that may not be available in test context
get_log_file() {
    local name="$1"
    local f="$LOG_DIR/${name}.log"
    [ -f "$f" ] && echo "$f" && return
    f="$LOG_DIR/${name}_combined.log"
    [ -f "$f" ] && echo "$f" && return
    for g in "$LOG_DIR"/*"${name}"*.log; do
        [ -f "$g" ] && echo "$g" && return
    done
    echo ""
}

progress_step() { :; }

section "Integration Test: Run Detectors"

# Source and run the analyzer
source lib/analyzer_standard.sh 2>/dev/null

# Run individual detectors
for fn in _analyze_health_monitor _analyze_firmware_monit_hmi _analyze_v2g_hlc \
          _analyze_energy_manager _analyze_meter_eichrecht _analyze_network_boss \
          _analyze_inner_sm _analyze_evic_globalstop _analyze_hal_errors \
          _analyze_compliance_limits _analyze_powerboard_stopcodes \
          _analyze_connector_health _analyze_properties; do
    if type "$fn" >/dev/null 2>&1; then
        "$fn" 2>>"$ANALYZER_ERRLOG" || true
    fi
done

# Properties analysis
if type "_analyze_properties" >/dev/null 2>&1; then
    _analyze_properties 2>>"$ANALYZER_ERRLOG" || true
fi

# Registry scan
if type "_scan_error_registry" >/dev/null 2>&1; then
    _scan_error_registry 2>>"$ANALYZER_ERRLOG" || true
fi

section "Verify Metrics"

check_metric() {
    local name="$1" expected="$2"
    local val
    val=$(get_metric "$name" 2>/dev/null || echo "MISSING")
    if [ "$val" = "MISSING" ] || [ -z "$val" ]; then
        fail "Metric $name: not set (expected ≥$expected)"
    elif [ "$(safe_int "$val")" -ge "$(safe_int "$expected")" ]; then
        pass "Metric $name=$val (≥$expected)"
    else
        fail "Metric $name=$val (expected ≥$expected)"
    fi
}

# Temperature
check_metric "temp_critical" "2"
check_metric "temp_max_derating" "1"
check_metric "temp_derating" "1"

# V2G/HLC
check_metric "v2g_errors" "1"
check_metric "v2g_timeouts" "2"

# InnerSM
check_metric "ism_critical" "1"
check_metric "ism_confirm_fail" "1"

# Tamper
check_metric "lid_open" "1"

# Emergency
check_metric "emergency_stop" "1"

# EVIC
check_metric "dc_evic_cablecheck" "1"

# HAL
check_metric "hal_ciu_errors" "1"
check_metric "hal_miu_errors" "1"

# Monit
check_metric "monit_too_often" "1"

# Storage
check_metric "hm_storage_fallback" "1"

# Firmware
check_metric "fw_powerboard_fail" "1"

# Compliance
check_metric "ev_disobey_limit" "1"

# Connector-level
check_metric "conn1_errors" "1"
check_metric "conn2_warnings" "1"
check_metric "connector_events_total" "1"
check_metric "multi_connector" "1"

# Config validation (digitalCommunicationTimeout_ms=15000 < 20000 + emmcWearingCheckEnabled=false)
check_metric "config_warnings" "1"

section "Verify Issues"

issue_count=$(wc -l < "$ISSUES_FILE" | tr -d ' ')
if [ "$issue_count" -ge 5 ]; then
    pass "Issues found: $issue_count (≥5)"
else
    fail "Issues found: $issue_count (expected ≥5)"
fi

# Check specific severities
crit_count=$(grep -c '^CRITICAL' "$ISSUES_FILE" || echo 0)
if [ "$crit_count" -ge 2 ]; then
    pass "CRITICAL issues: $crit_count (≥2)"
else
    fail "CRITICAL issues: $crit_count (expected ≥2)"
fi

# Check troubleshooting text
ts_count=$(grep -c 'Troubleshooting:' "$ISSUES_FILE" || echo 0)
if [ "$ts_count" -ge 3 ]; then
    pass "Issues with troubleshooting: $ts_count (≥3)"
else
    fail "Issues with troubleshooting: $ts_count (expected ≥3)"
fi

# Connector imbalance issue
conn_issue=$(grep -c 'Connector.*Imbalance\|Disproportionately' "$ISSUES_FILE" || echo 0)
if [ "$conn_issue" -ge 1 ]; then
    pass "Connector imbalance issue detected"
else
    fail "Connector imbalance issue not detected"
fi

# Config validation issue
cfg_issue=$(grep -c 'Configuration Warning\|Config.*Validation' "$ISSUES_FILE" || echo 0)
if [ "$cfg_issue" -ge 1 ]; then
    pass "Config validation issue detected"
else
    fail "Config validation issue not detected"
fi

section "Verify Health Score"

if type "calculate_health_score" >/dev/null 2>&1; then
    calculate_health_score 2>/dev/null
fi

score=$(get_metric health_score 2>/dev/null || echo "")
grade=$(get_metric health_grade 2>/dev/null || echo "")

if [ -n "$score" ] && [ "$(safe_int "$score")" -ge 0 ] && [ "$(safe_int "$score")" -le 100 ]; then
    pass "Health score: $score/100 (valid range)"
else
    fail "Health score: ${score:-MISSING} (expected 0-100)"
fi

if [ -n "$grade" ]; then
    pass "Grade: $grade"
else
    fail "Grade not set"
fi

section "Detector Errors"

det_err=$(get_metric detector_errors 2>/dev/null || echo "0")
if [ "$(safe_int "$det_err")" -eq 0 ]; then
    pass "No detector errors"
else
    fail "$det_err detector(s) failed — see $WORK/errors.log"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────
rm -rf "$WORK"

# ─── Summary ─────────────────────────────────────────────────────────────
printf "\n══════════════════════════════════════════════\n"
printf "  Integration: %d passed, %d failed (%d total)\n" "$PASS" "$FAIL" "$TESTS"
printf "══════════════════════════════════════════════\n"

[ "$FAIL" -eq 0 ] && printf "  🎉 ALL TESTS PASSED\n\n" && exit 0
printf "  ⚠️  SOME TESTS FAILED\n\n" && exit 1
