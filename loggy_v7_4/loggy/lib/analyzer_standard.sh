#!/bin/bash
# analyzer_standard.sh — Standard analysis engine
# Loggy v6.0
# Detects issues across all IoTecha components, builds timeline, creates status dashboard

# ─── Log File Validation ─────────────────────────────────────────────────────
_validate_log_files() {
    local ok=0 missing=0 total=0
    local comp path
    while IFS='|' read -r comp path; do
        # Skip combined, config, metadata entries
        [[ "$comp" == *"_combined"* ]] && continue
        [[ "$comp" == config:* ]] && continue
        [[ "$comp" == "versions_json" || "$comp" == "fw_version" || "$comp" == "build_info" || "$comp" == "info_commands" ]] && continue

        total=$((total + 1))
        if [ -n "$path" ] && [ -f "$path" ]; then
            local sz
            sz=$(file_size "$path")
            sz=$(safe_int "$sz")
            if [ "$sz" -gt 100 ]; then
                ok=$((ok + 1))
            else
                log_warn "$comp: log file too small ($sz bytes) — may miss issues"
                missing=$((missing + 1))
            fi
        else
            log_debug "$comp: no log file found"
            missing=$((missing + 1))
        fi
    done < "$WORK_DIR/log_files.idx"
    log_info "Log validation: $ok components with data, $missing missing/small (of $total loaded)"
}

# ─── Main Analysis Entry ─────────────────────────────────────────────────────
run_standard_analysis() {
    log_info "Running standard analysis..."
    init_evidence
    _setup_error_handling

    # Set LOG_DIR for detectors that scan all combined logs
    LOG_DIR="$WORK_DIR"

    # Reset data files (prevents accumulation on re-run)
    : > "$ISSUES_FILE"
    : > "$TIMELINE_FILE"
    : > "$METRICS_FILE"

    local _ASTEP=0 _ATOTAL=33

    # Validate log files are accessible
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Validating"
    _validate_log_files

    # Phase 2.2: Error scanner
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Error scan"
    safe_run _scan_all_errors

    # Phase 2.3: Component-specific parsers (25 detectors — each wrapped in safe_run)
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "i2p2/MQTT"
    safe_run _analyze_i2p2_mqtt
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "NetworkBoss"
    safe_run _analyze_network_boss
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "ChargerApp"
    safe_run _analyze_charger_app
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "OCPP"
    safe_run _analyze_ocpp
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "EnergyManager"
    safe_run _analyze_energy_manager
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "CertManager"
    safe_run _analyze_cert_manager
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "HealthMonitor"
    safe_run _analyze_health_monitor
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "ErrorBoss"
    safe_run _analyze_error_boss
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Kernel/Syslog"
    safe_run _analyze_kernel_syslog
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "FW/Monit/HMI"
    safe_run _analyze_firmware_monit_hmi
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "V2G/HLC"
    safe_run _analyze_v2g_hlc
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Meter/Eichrecht"
    safe_run _analyze_meter_eichrecht
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Grid Codes"
    safe_run _analyze_grid_codes
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "OCPP Errors"
    safe_run _analyze_ocpp_error_codes
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "PMQ Health"
    safe_run _analyze_pmq_system_health
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Cert Loading"
    safe_run _analyze_cert_loading
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "TokenManager"
    safe_run _analyze_token_manager
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Net Failover"
    safe_run _analyze_interface_selection
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "PowerBoard StopCodes"
    safe_run _analyze_powerboard_stopcodes
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "InnerSM"
    safe_run _analyze_inner_sm
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "EVIC GlobalStop"
    safe_run _analyze_evic_globalstop
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "HAL Errors"
    safe_run _analyze_hal_errors
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Compliance"
    safe_run _analyze_compliance_limits

    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Connectors"
    safe_run _analyze_connector_health
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Registry scan"
    safe_run _scan_error_registry

    # Phase 2.4: Properties analysis
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Config"
    safe_run _analyze_properties

    # Phase 2.5: System info
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "System info"
    _extract_system_info

    # Phase 2.6: Build timeline
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Timeline"
    _build_timeline

    # Phase 2.7: Aggregate issues
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Aggregating"
    _aggregate_issues

    # Phase 2.8: Status summary
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Status"
    _build_status_summary

    # Phase 5: Health score & predictions
    _ASTEP=$((_ASTEP+1)); progress_step $_ASTEP $_ATOTAL "Health Score"
    calculate_health_score
    generate_predictions

    local _issue_total; _issue_total=$(issue_count)
    log_ok "Standard analysis complete: $_issue_total issues found"
    _log_file "INFO" "=== Analysis Summary ==="
    _log_file "INFO" "Issues: $_issue_total total (CRITICAL=$(issue_count_by_severity CRITICAL) HIGH=$(issue_count_by_severity HIGH) MEDIUM=$(issue_count_by_severity MEDIUM) LOW=$(issue_count_by_severity LOW))"
    _log_file "INFO" "Timeline events: $(wc -l < "$TIMELINE_FILE" 2>/dev/null | tr -d ' ')"
    _log_file "INFO" "Metrics: $(wc -l < "$METRICS_FILE" 2>/dev/null | tr -d ' ') entries"

    # Surface detector errors immediately (also reported at EXIT)
    local _det_err
    _det_err=$(safe_int "$(get_metric detector_errors 2>/dev/null)")
    if [ "$_det_err" -gt 0 ]; then
        printf "\n"
        log_warn "$_det_err detector(s) had errors during analysis:"
        if [ -f "${ANALYZER_ERRLOG:-}" ] && [ -s "$ANALYZER_ERRLOG" ]; then
            grep -a "^.*\.sh:" "$ANALYZER_ERRLOG" 2>/dev/null |                 sed 's/^/    /' | head -20
            local total_lines
            total_lines=$(wc -l < "$ANALYZER_ERRLOG" 2>/dev/null | tr -d ' ')
            [ "$(safe_int "$total_lines")" -gt 20 ] &&                 printf "    ... %d more lines in: %s\n"                     "$((total_lines - 20))" "$ANALYZER_ERRLOG"
        fi
        printf "\n"
    fi
    return 0
}

# ─── 2.2: Error Scanner ─────────────────────────────────────────────────────
_scan_all_errors() {
    log_verbose "Scanning all logs for errors..."
    local error_summary="$WORK_DIR/error_summary.dat"
    : > "$error_summary"

    local parsed_dir="$WORK_DIR/parsed"
    for f in "$parsed_dir"/*.parsed; do
        [ -f "$f" ] || continue
        [[ "$(basename "$f")" == *_full.parsed ]] && continue
        local comp
        comp=$(basename "$f" .parsed)

        local errs warns crits
        local errs warns crits
        errs=0; warns=0; crits=0
        if [ -f "$f" ]; then
            errs=$(grep -aFc '|E|' "$f" 2>/dev/null) || errs=0
            warns=$(grep -aFc '|W|' "$f" 2>/dev/null) || warns=0
            crits=$(grep -aFc '|C|' "$f" 2>/dev/null) || crits=0
        fi

        printf "%s|%s|%s|%s\n" "$comp" "$errs" "$warns" "$crits" >> "$error_summary"
    done

    add_metric "error_scan_done" "1"
    return 0
}

# ─── 2.3a: i2p2 / MQTT Analysis ─────────────────────────────────────────────
_analyze_i2p2_mqtt() {
    local comp="i2p2"
    local logfile
    logfile=$(get_log_file "${comp}_combined")
    [ -z "$logfile" ] && logfile=$(get_log_file "$comp")
    [ -z "$logfile" ] || [ ! -f "$logfile" ] && return

    log_verbose "Analyzing i2p2/MQTT..."

    # --- Batch count all patterns in single pass ---
    local mqtt_fail_count=0 mqtt_success=0 ppp_missing=0 pmq_disconn=0 shadow_updates=0 backoff_count=0
    eval "$(batch_count_grep "$logfile" \
        mqtt_fail_count 'Connection token is failed|MQTT.*[Ff]ail|DISCONNECTED|Connect failed|connection failed' \
        mqtt_success    'CONNECTED|Connection established|Successfully connected' \
        ppp_missing     'Failed to find ppp0 interface' \
        pmq_disconn     'Direct queue not connected' \
        shadow_updates  'shadow.*update|ShadowUpdater' \
        backoff_count   'backoff|retry|Reconnect')"
    log_debug "i2p2: mqtt_fail_count=$mqtt_fail_count (file: $logfile)"

    if [ "$mqtt_fail_count" -gt 0 ]; then
        local mqtt_ev
        mqtt_ev=$(extract_evidence "$comp" "Connection token is failed|DISCONNECTED|Connect failed|connection failed" "mqtt_fail")

        local sev="CRITICAL"
        local desc="MQTT/AWS IoT Core connection failing. $mqtt_fail_count failure(s) detected."
        [ "$mqtt_success" -gt 0 ] && sev="HIGH" && desc="$desc Intermittent — $mqtt_success successful connection(s) also seen."

        # Check for specific SSL/TLS endpoint
        local endpoint
        endpoint=$(grep -ao 'ssl://[^ ]*' "$logfile" 2>/dev/null | head -1)
        [ -n "$endpoint" ] && desc="$desc Target: $endpoint"

        add_issue "$sev" "i2p2/MQTT" "MQTT Connection Failure" "$desc" "$mqtt_ev"
        add_metric "i2p2_mqtt_fail_count" "$mqtt_fail_count"
        add_metric "i2p2_mqtt_ok_count" "$mqtt_success"
        add_timeline_event "$(grep -aEm1 'Connection token is failed|DISCONNECTED' "$logfile" | cut -d' ' -f1-2)" "CRITICAL" "i2p2" "MQTT connection failure detected"
    fi

    # --- PPP0 interface missing (affects shadow updater) ---
    if [ "$ppp_missing" -gt 0 ]; then
        add_metric "i2p2_ppp0_missing" "$ppp_missing"
    fi

    # --- PMQ disconnections ---
    [ "$pmq_disconn" -gt 0 ] && add_metric "i2p2_pmq_disconn" "$pmq_disconn"

    # --- Shadow sync status / backoff (already batched above) ---
    add_metric "i2p2_shadow_updates" "$shadow_updates"
    add_metric "i2p2_backoff_count" "$backoff_count"
    return 0
}

# ─── 2.3b: NetworkBoss Analysis ─────────────────────────────────────────────
_analyze_network_boss() {
    local comp="NetworkBoss"
    local logfile
    logfile=$(get_log_file "${comp}_combined")
    [ -z "$logfile" ] && logfile=$(get_log_file "$comp")
    [ -z "$logfile" ] || [ ! -f "$logfile" ] && return

    log_verbose "Analyzing NetworkBoss..."

    # --- Batch count all NetworkBoss patterns in single pass ---
    local ppp_up=0 ppp_down=0 ppp_never=0 ppp_attempts=0
    local eth_up_count=0 eth_down_count=0
    local wifi_up=0 wifi_fail=0 wifi_ssid_notfound=0 wifi_conn_fail=0 wifi_driver_reload=0
    local init_errors=0 stability_checks=0
    eval "$(batch_count_grep "$logfile" \
        ppp_up              'ppp.*[Uu]p|ppp.*connected|ppp.*running' \
        ppp_down            'ppp.*[Dd]own|ppp.*disconnect|ppp.*failed' \
        ppp_never           'ppp.*not.*configured|No.*ppp|ppp.*skip' \
        ppp_attempts        'ppp|PPP|cellular|modem|chat' \
        eth_up_count        'eth0.*[Uu]p|eth0.*link.*up|eth0.*running|carrier.*on.*eth' \
        eth_down_count      'eth0.*[Dd]own|eth0.*link.*down|eth0.*lost|carrier.*off.*eth|no.*carrier.*eth' \
        wifi_up             'wlan0.*up|wifi.*connected|wlan0.*associated|WPA.*COMPLETED' \
        wifi_fail           'wifi.*fail|wlan0.*fail|WiFi.*Invalid|wifi.*error|wpa.*fail' \
        wifi_ssid_notfound  'NETWORK_NOT_FOUND|cannot associate|SSID.*not.*found' \
        wifi_conn_fail      'CONN_FAILED|SSID.*TEMP.*DISABLED|temporarily disabled' \
        wifi_driver_reload  'wifi.*workaround|reload.*driver|wifi.*fail.*counter' \
        init_errors         'Error during interfaces initialization' \
        stability_checks    '[Ss]tability|checking.*link|link.*check')"
    log_debug "NetworkBoss: ppp_up=$ppp_up ppp_down=$ppp_down"

    if [ "$ppp_up" -eq 0 ] && [ "$ppp_attempts" -gt 0 ]; then
        local ppp_ev
        ppp_ev=$(extract_evidence "$comp" "ppp|PPP|modem|chat|cellular" "ppp_fail")
        add_issue "CRITICAL" "NetworkBoss/PPP" "PPP/Cellular Connection Never Established" \
            "PPP interface never came up. $ppp_attempts references found but 0 successful connections. Backup WAN link unavailable." \
            "$ppp_ev"
        add_timeline_event "$(head -1 "$logfile" | cut -d' ' -f1-2)" "CRITICAL" "NetworkBoss" "PPP never established"
    fi

    # --- Ethernet flapping (already batched above) ---
    # Also check syslog/kern for PHY events
    local kern_eth_up=0 kern_eth_down=0
    local kernlog
    kernlog=$(get_log_file "kern")
    if [ -n "$kernlog" ] && [ -f "$kernlog" ]; then
        eval "$(batch_count_grep "$kernlog" \
            kern_eth_up   'eth0.*Link is Up|eth0.*link up' \
            kern_eth_down 'eth0.*Link is Down|eth0.*link down')"
    fi

    local total_up=$((eth_up_count + kern_eth_up))
    local total_down=$((eth_down_count + kern_eth_down))
    local flap_cycles=$((total_down > total_up ? total_down : total_up))

    if [ "$flap_cycles" -gt 2 ]; then
        local eth_ev
        eth_ev=$(extract_evidence "$comp" "eth0.*up|eth0.*down|eth0.*link|carrier|stability" "eth_flap")
        local sev="HIGH"
        [ "$flap_cycles" -gt 10 ] && sev="CRITICAL"

        add_issue "$sev" "NetworkBoss/Ethernet" "Ethernet (eth0) Link Flapping" \
            "Ethernet link going up/down repeatedly. ~$flap_cycles flap cycles detected. Triggers 12-step stability checks each time." \
            "$eth_ev"
        add_timeline_event "$(grep -aEm1 'eth0.*down|eth0.*link' "$logfile" | cut -d' ' -f1-2)" "HIGH" "NetworkBoss" "Ethernet flapping detected"
    fi
    add_metric "eth_flap_cycles" "$flap_cycles"

    # --- WiFi status ---
    # Source: WifiClientControl — scans for SSID, handles WPA events, arping-based connectivity check
    #   Failure reasons: NETWORK_NOT_FOUND, CONN_FAILED, SSID-TEMP-DISABLED (invalid credentials)
    #   WifiApControl — hostapd-based access point
    # --- WiFi (already batched above) ---
    add_metric "wifi_connections" "$wifi_up"
    add_metric "wifi_failures" "$wifi_fail"
    add_metric "wifi_ssid_notfound" "$wifi_ssid_notfound"
    add_metric "wifi_conn_failed" "$wifi_conn_fail"

    # ═══ ISSUE: WiFi Connection Failure ═══
    local wifi_total_fail=$((wifi_fail + wifi_ssid_notfound + wifi_conn_fail))
    if [ "$wifi_total_fail" -gt 3 ]; then
        local ev desc sev="MEDIUM"
        ev=$(collect_evidence "$logfile" "wifi.*fail|NETWORK_NOT_FOUND|CONN_FAILED|SSID.*TEMP.*DISABLED|cannot associate|WiFi.*Invalid|wlan0.*fail|wifi.*workaround" 15)
        desc="WiFi issues ($wifi_total_fail events)."
        [ "$wifi_ssid_notfound" -gt 0 ] && desc="$desc NETWORK_NOT_FOUND ×$wifi_ssid_notfound — configured SSID not visible (AP down or out of range)."
        [ "$wifi_conn_fail" -gt 0 ] && desc="$desc CONN_FAILED/SSID-TEMP-DISABLED ×$wifi_conn_fail — authentication failure (wrong credentials or AP rejecting)."
        [ "$wifi_driver_reload" -gt 0 ] && desc="$desc WiFi driver reloaded ×$wifi_driver_reload (workaround for stuck driver)."
        [ "$wifi_total_fail" -gt 10 ] && sev="HIGH"
        desc="$desc Troubleshooting: 1. Verify SSID (wlan0-ap.ssid in NetworkBoss properties) 2. Check WiFi credentials 3. Check AP is powered and in range 4. Check wlan0.enabled setting 5. For driver reloads: check hardware."
        add_issue "$sev" "NetworkBoss/WiFi" "WiFi Connection Failure" "$desc" "$ev"
        add_timeline_event "$(grep -am1 'NETWORK_NOT_FOUND\|CONN_FAILED\|wifi.*fail\|WiFi.*Invalid' "$logfile" | cut -d' ' -f1-2)" "$sev" "NetworkBoss" "WiFi connection failure"
    fi

    # --- Interface init & stability (already batched above) ---
    add_metric "nb_init_errors" "$init_errors"
    add_metric "stability_checks" "$stability_checks"
    return 0
}

# ─── 2.3c: ChargerApp Analysis ──────────────────────────────────────────────
_analyze_charger_app() {
    local comp="ChargerApp"
    local logfile
    logfile=$(get_log_file "${comp}_combined")
    [ -z "$logfile" ] && logfile=$(get_log_file "$comp")
    [ -z "$logfile" ] || [ ! -f "$logfile" ] && return

    log_verbose "Analyzing ChargerApp..."

    # --- Batch count ChargerApp patterns in single pass ---
    local pb_faults=0 cpstate_f=0 evcc_wd=0
    eval "$(batch_count_grep "$logfile" \
        pb_faults  'POWER_BOARD_FAULT|PB.*[Ff]ault|stop reason.*22|PB Version wait timeout' \
        cpstate_f  'CPState.*F|CPState: F|cpstate.*fault' \
        evcc_wd    'Watchdog WARNING|evcc_communication_module_processing.*not triggered|watchdog.*WARNING')"

    if [ "$pb_faults" -gt 0 ]; then
        local pb_ev
        pb_ev=$(extract_evidence "$comp" "POWER_BOARD_FAULT|PB.*[Ff]ault|stop reason.*22|PB Version wait timeout|CPState.*F" "pb_fault")
        local sev="MEDIUM"
        [ "$pb_faults" -gt 5 ] && sev="HIGH"

        add_issue "$sev" "ChargerApp/PowerBoard" "Power Board Fault at Boot" \
            "Power Board fault detected ($pb_faults occurrences). Stop reason 22 (POWER_BOARD_FAULT) and/or CPState F (Fault) seen." \
            "$pb_ev"
        add_timeline_event "$(grep -aEm1 'POWER_BOARD_FAULT|PB.*[Ff]ault|stop reason.*22' "$logfile" | cut -d' ' -f1-2)" "MEDIUM" "ChargerApp" "Power Board fault"
    fi

    # --- CPState (already batched) ---
    add_metric "cpstate_fault_count" "$cpstate_f"

    if [ "$evcc_wd" -gt 0 ]; then
        local wd_ev
        wd_ev=$(extract_evidence "$comp" "Watchdog WARNING|evcc_communication_module_processing" "evcc_watchdog")
        add_issue "LOW" "ChargerApp/EVCC" "EVCC Watchdog Warnings" \
            "EVCC communication module watchdog triggered $evcc_wd time(s). Processing not triggered for ~45-60s intervals." \
            "$wd_ev"
    fi
    add_metric "evcc_watchdog_count" "$evcc_wd"

    # --- Connector state tracking ---
    local connector_states
    connector_states=$(grep -aEo "ConnectorState[[:space:]]*=[[:space:]]*[A-Za-z]*|connectorState.*=[[:space:]]*[A-Za-z]*" "$logfile" 2>/dev/null | safe_sort | uniq -c | safe_sort -rn)
    [ -n "$connector_states" ] && add_metric "connector_states" "$(echo "$connector_states" | head -5 | tr '\n' ';')"
    return 0
}

# ─── 2.3d: OCPP Analysis ────────────────────────────────────────────────────
_analyze_ocpp() {
    local comp="OCPP"
    local logfile
    logfile=$(get_log_file "${comp}_combined")
    [ -z "$logfile" ] && logfile=$(get_log_file "$comp")
    [ -z "$logfile" ] || [ ! -f "$logfile" ] && return

    log_verbose "Analyzing OCPP..."

    # --- Batch count all OCPP patterns in single pass ---
    local ws_connected=0 ws_failed=0 boot_notif=0 boot_accepted=0 boot_rejected=0
    local ocpp_conn_err=0 offline_queued=0 cert_issues=0 boot_source_err=0 txn_rejected=0
    eval "$(batch_count_grep "$logfile" \
        ws_connected   'WebSocket.*[Cc]onnect|WS.*connected|websocket.*open' \
        ws_failed      'WebSocket.*[Ff]ail|WS.*error|websocket.*close|websocket.*fail' \
        boot_notif     'BootNotification|bootNotification' \
        boot_accepted  'BootNotification.*Accepted|bootNotification.*accept|status.*Accepted' \
        boot_rejected  'BootNotification.*Reject|rejected.*BootNotification|BootNotification isn.t accepted' \
        ocpp_conn_err  'OCPP_CONNECTION_ERROR|OCPP cannot connect|ocpp.*cannot.*connect' \
        offline_queued 'OfflineMessageQueue|offline.*queue|queued.*offline' \
        cert_issues    'Unexpected response.*Certificate|cert.*error|certificate.*fail' \
        boot_source_err 'Boot source file.*doesn.t exist|boot_source' \
        txn_rejected   'rejected.*BootNotification isn.t accepted|rejected.*boot')"
    add_metric "ocpp_ws_connected" "$ws_connected"
    add_metric "ocpp_ws_failed" "$ws_failed"
    add_metric "ocpp_boot_notif" "$boot_notif"
    add_metric "ocpp_boot_accepted" "$boot_accepted"
    add_metric "ocpp_boot_rejected" "$boot_rejected"
    add_metric "ocpp_connection_error" "$ocpp_conn_err"
    add_metric "ocpp_offline_queued" "$offline_queued"
    add_metric "ocpp_cert_issues" "$cert_issues"
    add_metric "ocpp_boot_source_err" "$boot_source_err"
    add_metric "ocpp_txn_rejected_preboot" "$txn_rejected"

    # ═══ ISSUE: OCPP Connection Failure ═══
    # Official troubleshooting from registry (ocpp-cmd/OCPP_CONNECTION_ERROR):
    # 1. Check and fix OCPP Central System settings
    # 2. Check and fix network configuration and settings
    # 3. Restart charging station
    # 4. Replace Main AC board
    local ocpp_ts="Troubleshooting: 1. Check OCPP Central System URL/settings 2. Check network configuration 3. Restart charging station 4. Replace Main AC board [On-site service required]"

    if [ "$ws_failed" -gt 3 ] && [ "$ws_connected" -lt 2 ]; then
        local desc="OCPP WebSocket connection failing. $ws_failed failure(s), only $ws_connected successful connection(s)."
        if [ "$boot_notif" -gt 0 ] && [ "$boot_accepted" -eq 0 ]; then
            desc="$desc BootNotification sent ($boot_notif) but never accepted — charger not registered with Central System."
        fi
        [ "$ocpp_conn_err" -gt 0 ] && desc="$desc OCPP_CONNECTION_ERROR raised $ocpp_conn_err time(s)."
        [ "$txn_rejected" -gt 0 ] && desc="$desc $txn_rejected transaction(s) rejected before boot accepted."
        desc="$desc $ocpp_ts"
        local ev
        ev=$(collect_evidence "$logfile" "WebSocket.*[Ff]ail|WS.*error|websocket.*close|BootNotification.*Reject|OCPP_CONNECTION_ERROR|rejected.*BootNotification" 30)
        add_issue "HIGH" "OCPP/WebSocket" "OCPP Connection Failure" "$desc" "$ev"
        add_timeline_event "$(grep -am1 'WebSocket.*[Ff]ail\|websocket.*close\|OCPP_CONNECTION_ERROR' "$logfile" | cut -d' ' -f1-2)" "HIGH" "OCPP" "WebSocket connection failure"
    elif [ "$ocpp_conn_err" -gt 0 ]; then
        local ev
        ev=$(collect_evidence "$logfile" "OCPP_CONNECTION_ERROR|OCPP cannot connect|ocpp.*cannot.*connect" 20)
        add_issue "HIGH" "OCPP/Connection" "OCPP Connection Error (ErrorBoss)" \
            "OCPP_CONNECTION_ERROR raised $ocpp_conn_err time(s). Cannot connect to Central System. $ocpp_ts" "$ev"
    elif [ "$boot_notif" -gt 2 ] && [ "$boot_accepted" -eq 0 ]; then
        local ev
        ev=$(collect_evidence "$logfile" "BootNotification|bootNotification|rejected|Rejected" 20)
        add_issue "HIGH" "OCPP/BootNotif" "OCPP BootNotification Rejected" \
            "BootNotification sent $boot_notif time(s) but never accepted. Charger cannot operate — all transactions rejected until boot accepted. $ocpp_ts" "$ev"
        add_timeline_event "$(grep -am1 'BootNotification\|bootNotification' "$logfile" | cut -d' ' -f1-2)" "HIGH" "OCPP" "BootNotification never accepted"
    fi

    # ═══ ISSUE: Transactions rejected pre-boot (source pattern) ═══
    if [ "$txn_rejected" -gt 5 ] && [ "$boot_accepted" -gt 0 ]; then
        local ev
        ev=$(collect_evidence "$logfile" "rejected.*BootNotification isn't accepted" 15)
        add_issue "MEDIUM" "OCPP/Transactions" "Transactions Rejected Before Boot Accepted" \
            "$txn_rejected transactions rejected because BootNotification wasn't accepted yet. Slow boot acceptance causing revenue loss." "$ev"
    fi
    return 0
}

# ─── 2.3e: EnergyManager Analysis ───────────────────────────────────────────
_analyze_energy_manager() {
    local comp="EnergyManager"
    local logfile
    logfile=$(get_log_file "${comp}_combined")
    [ -z "$logfile" ] && logfile=$(get_log_file "$comp")
    [ -z "$logfile" ] || [ ! -f "$logfile" ] && return

    log_verbose "Analyzing EnergyManager..."

    # --- Batch count EnergyManager patterns in single pass ---
    local pmq_sub_fail=0 em_state_err=0 em_session_err=0 em_3ph_err=0
    eval "$(batch_count_grep "$logfile" \
        pmq_sub_fail  'subscription.*fail|subscribe.*fail|PMQ.*not connected|Direct queue not connected' \
        em_state_err  'EM_state_change_error|state.*change.*error' \
        em_session_err 'EM_start_session_error|start.*session.*fail|Start session failed' \
        em_3ph_err    'No3phCurrentFlowDetected|no.*current.*flow.*3ph|3phase.*no.*current')"

    if [ "$pmq_sub_fail" -gt 0 ]; then
        local pmq_ev
        pmq_ev=$(extract_evidence "$comp" "subscription.*fail|subscribe.*fail|PMQ.*not connected|Direct queue not connected" "pmq_sub_fail")

        # Check which targets failed
        local failed_targets
        failed_targets=$(grep -aE "Direct queue not connected|subscribe.*fail" "$logfile" 2>/dev/null | grep -oE 'destination: [^ ]+|to [^ ]+' | safe_sort -u | head -5 | tr '\n' ',' | sed 's/,$//' | sed 's/,,*/,/g')

        add_issue "LOW" "EnergyManager/PMQ" "PMQ Subscription Failures" \
            "EnergyManager cannot subscribe to upstream components. $pmq_sub_fail failures detected. Failed targets: ${failed_targets:-unknown}. Retrying periodically." \
            "$pmq_ev"
    fi
    add_metric "em_pmq_sub_fail" "$pmq_sub_fail"

    # --- Power limit values ---
    local power_limits
    power_limits=$(grep -aEo "limit.*=[[:space:]]*[0-9]*|PowerLimit[[:space:]]*=[[:space:]]*[0-9]*" "$logfile" 2>/dev/null | tail -3)
    [ -n "$power_limits" ] && add_metric "em_power_limits" "$(echo "$power_limits" | tr '\n' ';')"

    # --- Registry metrics (already batched above) ---
    add_metric "em_state_change_err" "$em_state_err"
    add_metric "em_session_start_err" "$em_session_err"
    add_metric "em_3ph_no_current" "$em_3ph_err"

    # --- Registry: ENERGY_MANAGER_POWER_IMBALANCE_DETECTED (warning_reset_current_session) ---
    local em_imbalance=0
    for f in "$LOG_DIR"/*_combined.log "$LOG_DIR"/*.log; do
        [ -f "$f" ] || continue
        em_imbalance=$((em_imbalance + $(count_grep "POWER_IMBALANCE_DETECTED|power.*imbalance|phase.*imbalance" "$f")))
    done
    add_metric "em_power_imbalance" "$em_imbalance"

    # ═══ ISSUE: Energy Manager Session Start Failure ═══
    if [ "$em_session_err" -gt 0 ]; then
        local ev
        ev=$(collect_evidence "$logfile" "EM_start_session_error|start.*session.*fail|Start session failed" 10)
        add_issue "HIGH" "EnergyManager/Session" "Energy Manager Session Start Failure" \
            "EM_start_session_error ×$em_session_err — charging sessions failing to start. Resets current session. Troubleshooting: 1. Restart charging session 2. Reboot charging station 3. Use another EV/consumer." "$ev"
    fi

    # ═══ ISSUE: 3-Phase Current Flow Missing ═══
    if [ "$em_3ph_err" -gt 0 ]; then
        local ev
        ev=$(collect_evidence "$logfile" "No3phCurrentFlowDetected|no.*current.*flow" 10)
        add_issue "MEDIUM" "EnergyManager/3Phase" "No 3-Phase Current Flow in BPT Session" \
            "No3phCurrentFlowDetectedIn3phBptSession ×$em_3ph_err — some phases have no current during 3-phase bidirectional session. Troubleshooting: 1. Check charging cable is 3-phase 2. Check socket on EV and EVSE sides 3. Use another cable 4. Use another EV/consumer." "$ev"
    fi

    # ═══ ISSUE: Phase Power Imbalance ═══
    if [ "$em_imbalance" -gt 0 ]; then
        local ev=""
        for f in "$LOG_DIR"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "POWER_IMBALANCE_DETECTED|power.*imbalance|phase.*imbalance" 10)
            [ -n "$ev" ] && break
        done
        add_issue "HIGH" "EnergyManager/Imbalance" "Phase Power Imbalance Detected" \
            "ENERGY_MANAGER_POWER_IMBALANCE_DETECTED ×$em_imbalance — resets current session. Phase power imbalance between L1/L2/L3. Troubleshooting: No special action required (auto-recovers), but check wiring if persistent." "$ev"
    fi

    # ═══ ISSUE: State Change Errors (informational) ═══
    if [ "$em_state_err" -gt 3 ]; then
        local ev
        ev=$(collect_evidence "$logfile" "EM_state_change_error|state.*change.*error" 10)
        add_issue "LOW" "EnergyManager/State" "Energy Manager State Change Errors" \
            "EM_state_change_error ×$em_state_err. Troubleshooting: 1. Restart charging session 2. Reboot charging station." "$ev"
    fi
    return 0
}

# ─── 2.3f: CertificateManager Analysis ──────────────────────────────────────
_analyze_cert_manager() {
    local comp="CertManager"
    local logfile
    logfile=$(get_log_file "${comp}_combined")
    [ -z "$logfile" ] && logfile=$(get_log_file "$comp")
    [ -z "$logfile" ] || [ ! -f "$logfile" ] && return

    log_verbose "Analyzing CertificateManager..."

    # --- Batch count CertManager patterns ---
    local cert_fail=0 slots_ok=0 slots_fail=0
    eval "$(batch_count_grep "$logfile" \
        cert_fail   'Failed to read cert|cert.*fail|certificate.*error|Failed.*cert.*config' \
        slots_ok    'slot.*ok|cert.*loaded|certificate.*success' \
        slots_fail  'slot.*fail|slot.*empty|cert.*missing')"

    if [ "$cert_fail" -gt 0 ]; then
        local cert_ev
        cert_ev=$(extract_evidence "$comp" "Failed to read cert|cert.*fail|Failed.*cert.*config" "cert_fail")

        # Which certs failed
        local failed_certs
        failed_certs=$(grep -aE "Failed to read cert|Failed.*cert.*config" "$logfile" 2>/dev/null | grep -oE '[A-Za-z]*Certificate[^ ]*|[^ ]*\.pem' | safe_sort -u | head -10 | tr '\n' ',' | sed 's/,$//' | sed 's/,,*/,/g')

        add_issue "MEDIUM" "CertManager" "Certificate Manager Warnings" \
            "Several certificate config files failed to load ($cert_fail failures). Missing: ${failed_certs:-unknown}" \
            "$cert_ev"
        add_timeline_event "$(grep -aEm1 'Failed to read cert|Failed.*cert.*config' "$logfile" | cut -d' ' -f1-2)" "MEDIUM" "CertManager" "Certificate load failures"
    fi
    add_metric "cert_load_failures" "$cert_fail"

    # --- Cert slot status (already batched above) ---
    add_metric "cert_slots_ok" "$slots_ok"
    add_metric "cert_slots_fail" "$slots_fail"
    return 0
}

# ─── 2.3g: HealthMonitor Analysis ───────────────────────────────────────────
_analyze_health_monitor() {
    local comp="HealthMonitor"
    local logfile
    logfile=$(get_log_file "${comp}_combined")
    [ -z "$logfile" ] && logfile=$(get_log_file "$comp")
    [ -z "$logfile" ] || [ ! -f "$logfile" ] && return

    log_verbose "Analyzing HealthMonitor..."

    # --- Batch count all HealthMonitor patterns in single pass ---
    local reboots=0 wd_issues=0 gpio_fail=0 svc_down=0
    local emmc_wear=0 storage_fallback=0 fs_ro=0
    local unplanned_reboots=0 planned_reboots=0 soft_resets=0
    eval "$(batch_count_grep "$logfile" \
        reboots            'reboot|Reboot|restart|system.*reset' \
        wd_issues          'watchdog|Watchdog|WATCHDOG' \
        gpio_fail          'GPIORebooter.*[Ff]ail|Can.t create GPIORebooter' \
        svc_down           'service.*down|service.*stopped|process.*died|monit.*restart' \
        emmc_wear          'eMMC.*wear|wearing.*high|wearing.*critical|EmmcHighWearing|EmmcCriticalWearing' \
        storage_fallback   'FallbackMode|StorageFallbackMode|fallback.*mode' \
        fs_ro              'FSSwitchToRO|[Rr]ead.only|remount.*ro' \
        unplanned_reboots  'UnPlannedReboot|unplanned.*reboot|unexpected.*reboot|watchdog.*reboot' \
        planned_reboots    'PlannedReboot|planned.*reboot|reboot.*source.*HealthMonitor|reboot.*source.*OCPP|reboot.*source.*FirmwareUpdate' \
        soft_resets        'SoftReset|soft.*reset.*uptime|Going to initiate reboot')"
    add_metric "hm_reboots" "$reboots"
    add_metric "hm_watchdog" "$wd_issues"
    [ "$gpio_fail" -gt 0 ] && add_metric "hm_gpio_fail" "$gpio_fail"
    add_metric "hm_service_down" "$svc_down"
    add_metric "hm_emmc_wear" "$emmc_wear"
    add_metric "hm_storage_fallback" "$storage_fallback"
    add_metric "hm_fs_ro" "$fs_ro"

    # ═══ ISSUE: Unplanned Reboots ═══
    # Source: RebootedStateDetector reads reboot.id/reason/type/source from marker file
    # RebootSource: HealthMonitor, OCPP, FirmwareUpdate, etc.
    # RebootType: Regular, Emergency
    # SoftResetUptimeMonitor triggers reboot after threshold uptime when disconnected
    # --- Reboot counts (already batched above) ---
    local evic_reboots
    add_metric "hm_unplanned_reboots" "$unplanned_reboots"
    add_metric "hm_planned_reboots" "$planned_reboots"
    add_metric "hm_soft_resets" "$soft_resets"

    # Also check for EVIC reboots (from CommonEVIC registry: "Unintended Evic reboot detected")
    evic_reboots=0
    for f in "$all_logs"/*_combined.log; do
        [ -f "$f" ] || continue
        evic_reboots=$((evic_reboots + $(count_grep "Unintended Evic reboot|CommonEVIC.*Reboot|evic.*reboot" "$f")))
    done
    add_metric "evic_reboots" "$evic_reboots"

    if [ "$unplanned_reboots" -gt 0 ]; then
        local ev desc
        ev=$(collect_evidence "$logfile" "UnPlannedReboot|unplanned.*reboot|unexpected.*reboot|watchdog.*reboot|reboot.*reason|reboot.*source|reboot.*type" 20)
        desc="$unplanned_reboots unplanned reboot(s) — crashes, watchdog triggers, or power loss."
        [ "$evic_reboots" -gt 0 ] && desc="$desc Also $evic_reboots EVIC reboot(s) (CommonEVIC: Unintended Evic reboot)."
        desc="$desc Troubleshooting: 1. Check reboot.reason/source/type markers 2. Check kernel syslog for OOM/panic 3. Check power supply stability 4. If watchdog, identify hung process."
        add_issue "HIGH" "HealthMonitor/Reboot" "Unplanned Reboots Detected" "$desc" "$ev"
        add_timeline_event "$(grep -am1 'UnPlannedReboot\|unplanned.*reboot' "$logfile" | cut -d' ' -f1-2)" "HIGH" "HealthMonitor" "Unplanned reboot"
    elif [ "$evic_reboots" -gt 0 ]; then
        local ev
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "Unintended Evic reboot|CommonEVIC.*Reboot|evic.*reboot" 10)
            [ -n "$ev" ] && break
        done
        add_issue "MEDIUM" "EVIC/Reboot" "Unintended EVIC Reboot" \
            "$evic_reboots EVIC reboot(s) detected. Charging controller restarted unexpectedly. Troubleshooting: 1. Restart charging session 2. Reboot charging station." "$ev"
    elif [ "$reboots" -gt 3 ]; then
        local ev
        ev=$(collect_evidence "$logfile" "reboot|Reboot|restart|system.*reset|SoftReset" 20)
        local desc="$reboots reboot events in log period."
        [ "$soft_resets" -gt 0 ] && desc="$desc Includes $soft_resets SoftReset(s) (uptime threshold reached while disconnected — normal maintenance)."
        [ "$planned_reboots" -gt 0 ] && desc="$desc $planned_reboots planned reboot(s)."
        add_issue "MEDIUM" "HealthMonitor/Reboot" "Excessive Reboots" "$desc" "$ev"
    fi

    # ═══ ISSUE: eMMC Storage Degradation ═══
    # Registry: StorageFallbackMode (CRITICAL/blocks all), EmmcHighWearing (LOW),
    #           EmmcCriticalWearing (MEDIUM/error), FSSwitchToRO (MEDIUM/error)
    # Source: WearingMonitor checks EXT_CSD_PRE_EOL_INFO + EXT_CSD_DEVICE_LIFE_TIME_EST_TYP_B every 600s
    #         FallbackMonitor checks every 30s, reboot timeout 1hr
    #         FsRoMonitor watches /var/aux and /etc/iotecha/configs partitions
    if [ "$emmc_wear" -gt 0 ] || [ "$storage_fallback" -gt 0 ] || [ "$fs_ro" -gt 0 ]; then
        local sev="MEDIUM" desc="Storage health warning."

        # Distinguish high vs critical wearing
        local wear_high=0 wear_crit=0
        eval "$(batch_count_grep "$logfile" \
            wear_high 'EmmcHighWearing|wearing.*high' \
            wear_crit 'EmmcCriticalWearing|wearing.*critical')"

        if [ "$storage_fallback" -gt 0 ]; then
            sev="CRITICAL"
            desc="StorageFallbackMode active — blocks ALL sessions. Charger is in read-only emergency mode, cannot store configs/logs/transactions."
        fi
        if [ "$fs_ro" -gt 0 ]; then
            [ "$sev" != "CRITICAL" ] && sev="HIGH"
            desc="$desc FSSwitchToRO: filesystem partition (/var/aux or /etc/iotecha/configs) switched to read-only unexpectedly ($fs_ro events). Health monitor will attempt UBI filesystem recreation."
        fi
        if [ "$wear_crit" -gt 0 ]; then
            [ "$sev" != "CRITICAL" ] && sev="HIGH"
            desc="$desc EmmcCriticalWearing: eMMC flash wearing is critical ($wear_crit) — storage failure imminent. Replace main board."
        elif [ "$wear_high" -gt 0 ]; then
            desc="$desc EmmcHighWearing: eMMC flash wearing is elevated ($wear_high) — plan preventive maintenance."
        fi
        desc="$desc Troubleshooting: 1. Check eMMC health (EXT_CSD_PRE_EOL_INFO + DEVICE_LIFE_TIME) 2. Reduce unnecessary writes 3. For fallback mode: power cycle, if persistent replace Main AC board. [On-site service required for replacement]"
        local ev
        ev=$(collect_evidence "$logfile" "eMMC|wearing|EmmcHighWearing|EmmcCriticalWearing|FallbackMode|StorageFallbackMode|FSSwitchToRO|[Rr]ead.only" 15)
        add_issue "$sev" "Health/Storage" "eMMC/Storage Degradation" "$desc" "$ev"
        add_timeline_event "$(grep -am1 'eMMC\|wearing\|FallbackMode\|FSSwitchToRO' "$logfile" | cut -d' ' -f1-2)" "$sev" "HealthMonitor" "Storage degradation"
    fi

    # ═══ ISSUE: GPIO Rebooter Failure ═══
    if [ "$gpio_fail" -gt 0 ]; then
        local ev
        ev=$(collect_evidence "$logfile" "GPIORebooter|GPIO.*[Ff]ail" 10)
        add_issue "MEDIUM" "HealthMonitor/GPIO" "GPIO Rebooter Failure" \
            "Cannot create GPIO rebooter ($gpio_fail). Hardware watchdog may not function — system cannot self-recover from hangs." "$ev"
    fi
    return 0
}

# ─── 2.3i: ErrorBoss Analysis ───────────────────────────────────────────────
_analyze_error_boss() {
    local logfile
    logfile=$(get_log_file "ErrorBoss_combined")
    [ -z "$logfile" ] && logfile=$(get_log_file "ErrorBoss")
    [ -z "$logfile" ] || [ ! -f "$logfile" ] && return

    log_verbose "Analyzing ErrorBoss..."

    local block_errors=0 error_reports=0 errors_cleared=0
    eval "$(batch_count_grep "$logfile" \
        block_errors   'error_block_all_sessions|Locked_Error_Blocks_All|ErrorType_Locked_Error' \
        error_reports  'ErrorSetInfo|injectErrors|ErrorReport' \
        errors_cleared 'ErrorClearInfo|clearErrors|error.*cleared')"
    add_metric "eb_block_errors" "$block_errors"
    add_metric "eb_error_reports" "$error_reports"
    add_metric "eb_errors_cleared" "$errors_cleared"

    if [ "$block_errors" -gt 0 ]; then
        local ev
        ev=$(collect_evidence "$logfile" "error_block_all_sessions|Locked_Error_Blocks_All|ErrorType_Locked_Error" 20)
        add_issue "CRITICAL" "ErrorBoss" "Session-Blocking Errors Active" \
            "ErrorBoss reports $block_errors session-blocking error(s). All charging sessions blocked until errors cleared. Check EVIC, PowerBoard, grid code modules." "$ev"
        add_timeline_event "$(grep -am1 'error_block_all_sessions\|Locked_Error_Blocks_All' "$logfile" | cut -d' ' -f1-2)" "CRITICAL" "ErrorBoss" "Session-blocking errors active"
    fi
    return 0
}

# ─── 2.3j: Firmware Update / Monit / HMI Analysis ──────────────────────────
_analyze_firmware_monit_hmi() {
    log_verbose "Analyzing FW update, Monit, HMI..."
    local all_logs="$LOG_DIR"

    # --- Firmware Update ---
    local fwlog
    fwlog=$(get_log_file "iotc-fw-update_combined")
    [ -z "$fwlog" ] && fwlog=$(get_log_file "iotc-fw-update")
    if [ -n "$fwlog" ] && [ -f "$fwlog" ]; then
        local fw_fail fw_success fw_sig fw_chk fw_cert fw_rootfs fw_variant fw_pb
        eval "$(batch_count_grep "$fwlog" \
            fw_fail    'UpdateValidationFailed|signature.*failed|checksum.*failed|[Ff]irmware.*[Ff]ail|update.*fail' \
            fw_success '[Ff]irmware.*success|update.*complete|installed.*success|mark.*good' \
            fw_sig     'UpdateValidationFailedInvalidSignature' \
            fw_chk     'UpdateValidationFailedInvalidChecksum' \
            fw_cert    'UpdateValidationFailedInvalidCertificate' \
            fw_rootfs  'UpdateValidationFailedInvalidRootFsSignature' \
            fw_variant 'UpdateValidationFailedInvalidUpdateVariant')"
        add_metric "fw_update_fail" "$fw_fail"
        add_metric "fw_update_success" "$fw_success"

        # Also scan all logs for PowerBoard firmware update failure
        fw_pb=0
        for f in "$all_logs"/*_combined.log "$all_logs"/*.log; do
            [ -f "$f" ] || continue
            fw_pb=$((fw_pb + $(count_grep "PowerBoardFirmwareUpdateFailed|power.*board.*firmware.*fail" "$f")))
        done
        add_metric "fw_powerboard_fail" "$fw_pb"

        if [ "$fw_fail" -gt 0 ]; then
            local ev desc
            ev=$(collect_evidence "$fwlog" "UpdateValidationFailed|signature.*failed|checksum.*failed|[Ff]irmware.*[Ff]ail" 15)
            desc="$fw_fail firmware update failure(s)."
            # Source-informed breakdown
            [ "$fw_sig" -gt 0 ] && desc="$desc InvalidSignature ×$fw_sig."
            [ "$fw_chk" -gt 0 ] && desc="$desc InvalidChecksum ×$fw_chk."
            [ "$fw_cert" -gt 0 ] && desc="$desc InvalidCertificate ×$fw_cert."
            [ "$fw_rootfs" -gt 0 ] && desc="$desc InvalidRootFsSignature ×$fw_rootfs."
            [ "$fw_variant" -gt 0 ] && desc="$desc InvalidUpdateVariant ×$fw_variant (wrong firmware for this hardware)."
            desc="$desc Troubleshooting: 1. Make sure the update bundle is correct 2. Verify checksum matches 3. Check signing certificate 4. Retry update 5. Contact support."
            add_issue "HIGH" "FirmwareUpdate" "Firmware Update Validation Failure" "$desc" "$ev"
            add_timeline_event "$(grep -am1 'UpdateValidationFailed\|firmware.*[Ff]ail' "$fwlog" | cut -d' ' -f1-2)" "HIGH" "FirmwareUpdate" "Update validation failed"
        fi

        # ═══ ISSUE: Power Board Firmware Update Failed (CRITICAL — blocks all sessions) ═══
        if [ "$fw_pb" -gt 0 ]; then
            local ev=""
            for f in "$all_logs"/*_combined.log; do
                [ -f "$f" ] || continue
                ev=$(collect_evidence "$f" "PowerBoardFirmwareUpdateFailed|power.*board.*firmware.*fail" 10)
                [ -n "$ev" ] && break
            done
            add_issue "CRITICAL" "FirmwareUpdate/PowerBoard" "Power Board Firmware Update Failed" \
                "PowerBoardFirmwareUpdateFailed — blocks ALL sessions. Troubleshooting: 1. Reboot charger 2. Power cycle with 10 minute pause after power off 3. Replace Power Board. [On-site service required]" "$ev"
        fi
    fi

    # --- Monit (process supervisor) ---
    # Registry: AppHasRestarted (warning), ProcessRestartedTooOften (warning), HighCpuUsage (warning)
    local monit_restarts=0 monit_cpu=0 monit_too_often=0
    for f in "$all_logs"/*_combined.log "$all_logs"/*.log; do
        [ -f "$f" ] || continue
        eval "$(batch_count_grep "$f" \
            _mr 'monit.*restart|AppHasRestarted' \
            _mt 'ProcessRestartedTooOften' \
            _mc 'HighCpuUsage|high.*cpu.*usage')"
        monit_restarts=$((monit_restarts + _mr))
        monit_too_often=$((monit_too_often + _mt))
        monit_cpu=$((monit_cpu + _mc))
    done
    add_metric "monit_restarts" "$monit_restarts"
    add_metric "monit_too_often" "$monit_too_often"
    add_metric "monit_high_cpu" "$monit_cpu"

    # ═══ ISSUE: Process Restarted Too Often ═══
    if [ "$monit_too_often" -gt 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "ProcessRestartedTooOften" 15)
            [ -n "$ev" ] && break
        done
        add_issue "HIGH" "Monit/ProcessCrash" "Process Restarted Too Often (Monit)" \
            "ProcessRestartedTooOften ×$monit_too_often — a service is crash-looping. Monit keeps restarting it but it won't stay up. Identify which process from evidence lines. Troubleshooting: 1. Check syslog for segfault/OOM 2. Review core dumps 3. Check disk space 4. Restart charger." "$ev"
    elif [ "$monit_restarts" -gt 3 ]; then
        local ev="" desc
        desc="Monit restarted processes $monit_restarts times (AppHasRestarted). Indicates unstable services."
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "monit.*restart|AppHasRestarted" 15)
            [ -n "$ev" ] && break
        done
        add_issue "MEDIUM" "Monit/ProcessSupervisor" "Excessive Process Restarts" "$desc" "$ev"
    fi

    # ═══ ISSUE: High CPU Usage ═══
    if [ "$monit_cpu" -gt 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "HighCpuUsage|high.*cpu" 10)
            [ -n "$ev" ] && break
        done
        local cpu_desc="HighCpuUsage ×$monit_cpu."
        cpu_desc="$cpu_desc Troubleshooting: 1. If charging session active, no action needed 2. If idle, recheck in 30 minutes 3. If persistent, reboot device 4. If still present, contact support."
        local cpu_sev="LOW"
        [ "$monit_cpu" -gt 5 ] && cpu_sev="MEDIUM"
        add_issue "$cpu_sev" "Monit/CPU" "High CPU Usage Detected" "$cpu_desc" "$ev"
    fi

    # --- HMI Board ---
    # Registry: HMIBboardIsNotReady (warning), HMIBoardInitTimeout (warning)
    # Troubleshooting: 1. Check HMI board connection 2. Replace HMI board cable 3. Replace HMI board 4. Replace Main AC
    local hmilog
    hmilog=$(get_log_file "HMIBoss_combined")
    [ -z "$hmilog" ] && hmilog=$(get_log_file "HMIBoss")
    if [ -n "$hmilog" ] && [ -f "$hmilog" ]; then
        local hmi_fail=0 hmi_timeout=0
        eval "$(batch_count_grep "$hmilog" \
            hmi_fail    'HMIBboardIsNotReady|HMI.*not.*ready' \
            hmi_timeout 'HMIBoardInitTimeout|HMI.*init.*timeout')"
        add_metric "hmi_failures" "$hmi_fail"
        add_metric "hmi_timeouts" "$hmi_timeout"

        if [ "$hmi_fail" -gt 0 ] || [ "$hmi_timeout" -gt 0 ]; then
            local total=$((hmi_fail + hmi_timeout))
            local ev desc sev="MEDIUM"
            ev=$(collect_evidence "$hmilog" "HMIBboardIsNotReady|HMIBoardInitTimeout|HMI.*not.*ready|HMI.*init.*timeout" 10)
            desc="HMI board issues ($total events)."
            [ "$hmi_fail" -gt 0 ] && desc="$desc HMIBboardIsNotReady ×$hmi_fail — display cannot communicate."
            [ "$hmi_timeout" -gt 0 ] && desc="$desc HMIBoardInitTimeout ×$hmi_timeout — display failed to initialize in time."
            [ "$total" -gt 5 ] && sev="HIGH"
            desc="$desc User display may not show charger status/instructions. Troubleshooting: 1. Check HMI board connection cable 2. Replace HMI board cable 3. Replace HMI board 4. Replace Main AC board."
            add_issue "$sev" "HMI/Display" "HMI Board Communication Failure" "$desc" "$ev"
        fi
    fi

    # --- Emergency Stop + Tamper + Temperature (batched single pass) ---
    local emergency=0 ext_estop=0
    local tamper=0 lid_open=0 lid_close_wait=0
    local temp_critical=0 temp_overtemp=0 temp_derating=0 temp_max_derating=0 temp_low=0
    for f in "$all_logs"/*_combined.log "$all_logs"/*.log; do
        [ -f "$f" ] || continue
        eval "$(batch_count_grep "$f" \
            _em  'EmergencyStop|emergency.*stop' \
            _ee  'ExternalEmergencyStop|external.*emergency' \
            _lo  'LidOpen|lid.*open' \
            _lcw 'LidCloseWaitUnplug|lid.*close.*wait.*unplug' \
            _td  'TamperDetection|tamper.*detect' \
            _tc  'Temperature1Error|Temperature2Error|OVERTEMPERATURE_[1-4]' \
            _to  'Overtemperature[12]|Overtemperature[^D]|overtemp.*fault|HeatsinkOverTemp' \
            _tdr 'DeratingApplied|DeratingActivated|DeratingRemoved' \
            _tmd 'MaximalDeratingReached' \
            _tl  'LOW_TEMP_FAULT|LessThanLowerLimit|UndTempShutdown')"
        emergency=$((emergency + _em))
        ext_estop=$((ext_estop + _ee))
        lid_open=$((lid_open + _lo))
        lid_close_wait=$((lid_close_wait + _lcw))
        tamper=$((tamper + _td))
        temp_critical=$((temp_critical + _tc))
        temp_overtemp=$((temp_overtemp + _to))
        temp_derating=$((temp_derating + _tdr))
        temp_max_derating=$((temp_max_derating + _tmd))
        temp_low=$((temp_low + _tl))
    done
    add_metric "emergency_stop" "$emergency"
    add_metric "external_emergency_stop" "$ext_estop"
    if [ "$emergency" -gt 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "EmergencyStop|emergency.*stop|ExternalEmergencyStop" 10)
            [ -n "$ev" ] && break
        done
        local desc="$emergency emergency stop event(s). All sessions halted."
        [ "$ext_estop" -gt 0 ] && desc="$desc ExternalEmergencyStop ×$ext_estop — external E-stop line was triggered (wired input)."
        desc="$desc Troubleshooting: 1. Remove emergency condition 2. Check E-stop button state 3. Verify external E-stop wiring 4. Power cycle after clearing. [On-site service required]"
        add_issue "CRITICAL" "Safety/EmergencyStop" "Emergency Stop Triggered" "$desc" "$ev"
        add_timeline_event "$(grep -rm1 'EmergencyStop\|emergency.*stop' "$all_logs"/*_combined.log 2>/dev/null | head -1 | cut -d' ' -f1-2)" "CRITICAL" "Safety" "Emergency stop triggered"
    fi

    # --- Tamper Detection ---
    # Registry: LidOpen (error_block_all_sessions), LidClose (error), LidCloseWaitUnplug (error_block_all_sessions)
    local tamper_total=$((lid_open + lid_close_wait + tamper))
    add_metric "tamper_events" "$tamper_total"
    add_metric "lid_open" "$lid_open"
    add_metric "lid_close_wait_unplug" "$lid_close_wait"

    if [ "$tamper_total" -gt 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "LidOpen|LidClose|TamperDetection|tamper|lid.*open" 10)
            [ -n "$ev" ] && break
        done
        local sev="HIGH" desc="Tamper detection events ($tamper_total total)."
        if [ "$lid_open" -gt 0 ]; then
            sev="CRITICAL"
            desc="$desc LidOpen ×$lid_open — blocks ALL sessions until lid closed."
        fi
        if [ "$lid_close_wait" -gt 0 ]; then
            sev="CRITICAL"
            desc="$desc LidCloseWaitUnplug ×$lid_close_wait — blocks ALL sessions, lid closed but cable still plugged (must unplug to clear)."
        fi
        desc="$desc Troubleshooting: 1. Check charger lid is properly closed 2. Unplug charging cable 3. Check lid sensor 4. Power cycle."
        add_issue "$sev" "Safety/Tamper" "Tamper Detection — Lid Open" "$desc" "$ev"
    fi

    # --- Temperature / Overtemperature / Derating ---
    # (counted in combined emergency+tamper+temperature batch above)
    add_metric "temp_critical" "$temp_critical"
    add_metric "temp_overtemp" "$temp_overtemp"
    add_metric "temp_derating" "$temp_derating"
    add_metric "temp_max_derating" "$temp_max_derating"
    add_metric "temp_low" "$temp_low"

    local temp_total=$((temp_critical + temp_overtemp + temp_max_derating + temp_low))
    if [ "$temp_total" -gt 0 ]; then
        local ev="" desc="" sev="MEDIUM"
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "Temperature.*Error|OVERTEMPERATURE|Overtemperature|MaximalDeratingReached|LOW_TEMP_FAULT|LessThanLowerLimit|HeatsinkOverTemp|UndTempShutdown" 15)
            [ -n "$ev" ] && break
        done

        if [ "$temp_critical" -gt 0 ] || [ "$temp_max_derating" -gt 0 ]; then
            sev="CRITICAL"
            desc="CRITICAL temperature errors — blocks ALL sessions."
            [ "$temp_critical" -gt 0 ] && desc="$desc Temperature sensor errors ×$temp_critical (Temperature1Error/Temperature2Error/OVERTEMPERATURE)."
            [ "$temp_max_derating" -gt 0 ] && desc="$desc MaximalDeratingReached ×$temp_max_derating — derating limit exhausted, charging stopped."
        elif [ "$temp_overtemp" -gt 0 ]; then
            sev="HIGH"
            desc="Overtemperature events ×$temp_overtemp."
        fi
        [ "$temp_low" -gt 0 ] && desc="$desc Low temperature faults ×$temp_low (below operating range)."
        desc="$desc Troubleshooting: 1. Power off charging station 2. Check temperature of charger components 3. Find and remove cause of overheating 4. Check/fix cooling system 5. Verify wiring is properly secured 6. Wait until station cools 7. Replace Power Board if persistent. [On-site service required]"
        add_issue "$sev" "Safety/Temperature" "Temperature / Overtemperature Error" "$desc" "$ev"
        add_timeline_event "$(grep -rm1 'Temperature.*Error\|OVERTEMPERATURE\|Overtemperature\|MaximalDeratingReached' "$all_logs"/*_combined.log 2>/dev/null | head -1 | cut -d' ' -f1-2)" "$sev" "Safety" "Temperature error"
    elif [ "$temp_derating" -gt 3 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "DeratingApplied|DeratingActivated|DeratingRemoved" 10)
            [ -n "$ev" ] && break
        done
        add_issue "LOW" "Safety/Derating" "Temperature Derating Active" \
            "Temperature derating applied $temp_derating time(s). Charger reducing power output to manage heat. Troubleshooting: 1. Check charger for overheating 2. Verify wiring connections are tight." "$ev"
    fi
    return 0
}

# ─── 2.3i: V2G / HLC (ISO 15118) Analysis ──────────────────────────────────
_analyze_v2g_hlc() {
    log_verbose "Analyzing V2G/HLC (ISO 15118)..."
    local all_logs="$LOG_DIR"

    # Scan ChargerApp and any V2G/HLC-specific logs
    local v2g_errors=0 v2g_timeouts=0 v2g_cable_check=0 v2g_sessions=0
    local v2g_cert=0 v2g_schema=0 v2g_sequence=0
    local v2g_power_delivery=0 v2g_car_not_ready=0 v2g_exi=0

    for f in "$all_logs"/*_combined.log "$all_logs"/*.log; do
        [ -f "$f" ] || continue
        eval "$(batch_count_grep "$f" \
            _ve  'V2G.*[Cc]onnection[Cc]losed|Error_V2G_TCP_ConnectionClosed|V2G.*error|HLCStateMachine.*Error|Error_V2G' \
            _vt  'Error_PrechargeResTimeout|Error_CurrentDemandResTimeout|Error_WeldingDetectionResTimeout|Error_CableCheckResTimeout|Error_SessionSetupResTimeout|Error_PowerDeliveryStartResTimeout|Error_PowerDeliveryStopResTimeout|Error_AuthorizationResTimeout|Error_ServiceDiscoveryResTimeout|Error_ServiceSelectionResTimeout|Error_ServiceDetailResTimeout|Error_SupportedAppProtocolResTimeout|Error_ChargeParameterDiscoveryResTimeout|Error_SessionStopResTimeout|Error_CableCheck_NoActivityTimeout|Error_Precharge_NoActivityTimeout|Error_CertificateInstallation_NoActivityTimeout|Error_CertificateUpdate_NoActivityTimeout|V2G.*[Tt]imeout' \
            _vcc 'CableCheck.*[Ff]ail|CableCheck.*[Pp]recondition|IMD.*[Ff]ail|IMD.*[Ff]ault|rectifier.*[Ff]ail|Error_PreComVoltageCheck' \
            _vs  'Info_V2G_SessionStop|V2G.*[Ss]ession[Ss]top|SessionStop' \
            _vcr 'Error_CertificateInstallationReq_EmptyExi|Error_CertificateUpdateReq_EmptyExi|CertificateInstallation.*[Ff]ail|CertificateUpdate.*[Ff]ail|V2G.*[Cc]ertificate.*[Ee]rror' \
            _vsc 'Error_SupportedSchemaNotFound|Error_Wrong_ChargeParameters' \
            _vsq 'Error_V2G_SessionSequenceError' \
            _vpd 'Error_PowerDeliveryStartTimeout|Error_DcBpt_SendPowerDeliveryReplyError|Error_DcBpt_SendCurrentDemandError|Error_NoCurrentDemandRequest|Error_PowerDeliveryStartAC_CarIsNotReadyForPD' \
            _vnr 'CarIsNotReadyForPowerDelivery|Error_Precharge_CarIsNotReady|Error_ReadyToCharge_CarIsNotReady|Error_CurrentDemand_CarIsNotReady' \
            _vex 'Error_V2G_ExiDocProcessing|ExiDoc.*error')"
        v2g_errors=$((v2g_errors + _ve))
        v2g_timeouts=$((v2g_timeouts + _vt))
        v2g_cable_check=$((v2g_cable_check + _vcc))
        v2g_sessions=$((v2g_sessions + _vs))
        v2g_cert=$((v2g_cert + _vcr))
        v2g_schema=$((v2g_schema + _vsc))
        v2g_sequence=$((v2g_sequence + _vsq))
        v2g_power_delivery=$((v2g_power_delivery + _vpd))
        v2g_car_not_ready=$((v2g_car_not_ready + _vnr))
        v2g_exi=$((v2g_exi + _vex))
    done

    add_metric "v2g_errors" "$v2g_errors"
    add_metric "v2g_timeouts" "$v2g_timeouts"
    add_metric "v2g_cable_check_fail" "$v2g_cable_check"
    add_metric "v2g_sessions" "$v2g_sessions"
    add_metric "v2g_cert_issues" "$v2g_cert"
    add_metric "v2g_power_delivery_err" "$v2g_power_delivery"
    add_metric "v2g_car_not_ready" "$v2g_car_not_ready"

    # ═══ ISSUE: V2G Connection/Protocol Errors ═══
    if [ "$v2g_errors" -gt 0 ] || [ "$v2g_timeouts" -gt 3 ]; then
        local desc="V2G/HLC errors detected: $v2g_errors connection errors, $v2g_timeouts timeouts."
        [ "$v2g_schema" -gt 0 ] && desc="$desc Schema mismatch ($v2g_schema): vehicle requested unsupported protocol version."
        [ "$v2g_sequence" -gt 0 ] && desc="$desc Sequence errors ($v2g_sequence): message received in wrong session state."
        [ "$v2g_exi" -gt 0 ] && desc="$desc EXI document processing errors ($v2g_exi)."
        [ "$v2g_power_delivery" -gt 0 ] && desc="$desc Power delivery errors ($v2g_power_delivery)."
        [ "$v2g_car_not_ready" -gt 0 ] && desc="$desc Vehicle not ready for power delivery ($v2g_car_not_ready)."
        desc="$desc Troubleshooting: 1. Check PLC communication (SLAC) 2. Verify V2G certificates 3. Review digitalCommunicationTimeout_ms setting (current: 50000ms) 4. Check vehicle compatibility 5. Check SECCRequestTimeoutAfterPause_ms."
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "Error_V2G|HLCStateMachine.*Error|V2G.*[Tt]imeout|Error_.*Timeout|Error_.*NotReady|SupportedSchemaNotFound|SessionSequenceError|ExiDocProcessing" 20)
            [ -n "$ev" ] && break
        done
        local sev="MEDIUM"
        [ "$v2g_errors" -gt 5 ] || [ "$v2g_timeouts" -gt 10 ] && sev="HIGH"
        add_issue "$sev" "HLC/V2G" "V2G/ISO 15118 Communication Errors" "$desc" "$ev"
        add_timeline_event "$(grep -rm1 'Error_V2G\|HLCStateMachine.*Error\|V2G.*timeout' "$all_logs"/*_combined.log 2>/dev/null | head -1 | cut -d' ' -f1-2)" "$sev" "HLC" "V2G protocol error"
    fi

    # ═══ ISSUE: DC Cable Check / IMD Failure ═══
    if [ "$v2g_cable_check" -gt 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "CableCheck.*[Ff]ail|CableCheck.*[Pp]recondition|IMD.*[Ff]ail|IMD.*[Ff]ault|rectifier.*[Ff]ail|Error_PreComVoltageCheck" 15)
            [ -n "$ev" ] && break
        done
        add_issue "HIGH" "HLC/CableCheck" "DC Cable Check / IMD Failure" \
            "$v2g_cable_check cable check or IMD failure(s). Preconditions not met for DC charging. Troubleshooting: 1. Check IMD module 2. Verify cable/connector 3. Check rectifier output 4. Review contactor state. [On-site service required]" "$ev"
    fi

    # ═══ ISSUE: V2G Certificate Problems ═══
    if [ "$v2g_cert" -gt 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "CertificateInstallation|CertificateUpdate|Error_Certificate|V2G.*[Cc]ertificate" 10)
            [ -n "$ev" ] && break
        done
        add_issue "MEDIUM" "HLC/V2GCert" "V2G Certificate Issue" \
            "$v2g_cert V2G certificate issue(s). ISO 15118 Plug&Charge or certificate operations failing. Troubleshooting: 1. Check V2G root certs 2. Verify CertManager V2GEVSE slot 3. Review cert chain 4. Check CertificateManager.ResponseTimeout (current: 9000ms)." "$ev"
    fi

    # ═══ ISSUE: Power Delivery Failures (source-specific) ═══
    if [ "$v2g_power_delivery" -gt 2 ] && [ "$v2g_errors" -eq 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "Error_PowerDelivery|Error_DcBpt|Error_NoCurrentDemand|CarIsNotReadyForPowerDelivery" 10)
            [ -n "$ev" ] && break
        done
        add_issue "MEDIUM" "HLC/PowerDelivery" "V2G Power Delivery Failure" \
            "$v2g_power_delivery power delivery error(s). Vehicle failed to start/sustain energy transfer. Troubleshooting: 1. Check EV compatibility 2. Review contactor timing 3. Check rectifier health 4. Verify current demand messages." "$ev"
    fi
    return 0
}

# ─── 2.3j: Meter / Eichrecht Analysis ──────────────────────────────────────
_analyze_meter_eichrecht() {
    log_verbose "Analyzing meter/Eichrecht..."
    local all_logs="$LOG_DIR"

    local meterlog
    meterlog=$(get_log_file "MeterDispatcher_combined")
    [ -z "$meterlog" ] && meterlog=$(get_log_file "MeterDispatcher")

    # Registry entries by module:
    # MeterListener: RequiredMeterNotFound (warning), RequiredMeterMissing (CRITICAL/blocks), PreferredMeterMissing (warning)
    # MeterECR380D: DataUnavailable (warning), ConnectionFailed (warning)
    # IotcMeterModbusGeneral: DataUnavailable (warning), ConnectionFailed (warning), AutoDetectionFailed (warning)
    # MeterQiPower: MeterIsMissing (error)
    # Eichrecht: EICHRECHT_ERROR_STATE_TERMINAL (CRITICAL/blocks), EICHRECHT_ERROR_STATE_UNAVAILABLE (CRITICAL/blocks), EICHRECHT_ERROR_STATE_ORPHAN_SESSION (HIGH/reset)

    local meter_not_found=0 meter_missing_critical=0 meter_preferred=0
    local meter_conn_fail=0 meter_data_unavail=0 meter_autodetect=0 meter_qipower=0
    local eichrecht_terminal=0 eichrecht_unavail=0 eichrecht_orphan=0

    for f in "$all_logs"/*_combined.log "$all_logs"/*.log; do
        [ -f "$f" ] || continue
        eval "$(batch_count_grep "$f" \
            _mnf 'RequiredMeterNotFound' \
            _mmc 'RequiredMeterMissing' \
            _mpf 'PreferredMeterMissing' \
            _mcf 'ConnectionFailed.*[Mm]eter|[Mm]eter.*ConnectionFailed' \
            _mdu 'DataUnavailable' \
            _mad 'AutoDetectionFailed' \
            _mqp 'MeterIsMissing' \
            _et  'EICHRECHT_ERROR_STATE_TERMINAL' \
            _eu  'EICHRECHT_ERROR_STATE_UNAVAILABLE' \
            _eo  'EICHRECHT_ERROR_STATE_ORPHAN_SESSION|orphan.*session')"
        meter_not_found=$((meter_not_found + _mnf))
        meter_missing_critical=$((meter_missing_critical + _mmc))
        meter_preferred=$((meter_preferred + _mpf))
        meter_conn_fail=$((meter_conn_fail + _mcf))
        meter_data_unavail=$((meter_data_unavail + _mdu))
        meter_autodetect=$((meter_autodetect + _mad))
        meter_qipower=$((meter_qipower + _mqp))
        eichrecht_terminal=$((eichrecht_terminal + _et))
        eichrecht_unavail=$((eichrecht_unavail + _eu))
        eichrecht_orphan=$((eichrecht_orphan + _eo))
    done

    add_metric "meter_not_found" "$meter_not_found"
    add_metric "meter_missing_critical" "$meter_missing_critical"
    add_metric "meter_conn_fail" "$meter_conn_fail"
    add_metric "meter_data_unavail" "$meter_data_unavail"
    add_metric "meter_autodetect_fail" "$meter_autodetect"
    add_metric "eichrecht_terminal" "$eichrecht_terminal"
    add_metric "eichrecht_unavail" "$eichrecht_unavail"
    add_metric "eichrecht_orphan" "$eichrecht_orphan"

    # ═══ ISSUE: Required Meter Missing (CRITICAL — blocks all sessions) ═══
    if [ "$meter_missing_critical" -gt 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "RequiredMeterMissing" 10)
            [ -n "$ev" ] && break
        done
        add_issue "CRITICAL" "Meter/Required" "Required Meter Missing — Blocks All Sessions" \
            "RequiredMeterMissing ×$meter_missing_critical — blocks ALL charging sessions. Troubleshooting: 1. Verify Meter.preferred.type and Meter.preferred.disableChargingOnAbsence in ChargerApp properties 2. Reboot charging station 3. Check/fix meter connection (RS485/Modbus) 4. Check/replace meter. [On-site service required]" "$ev"
    elif [ "$meter_not_found" -gt 0 ] || [ "$meter_qipower" -gt 0 ]; then
        local total=$((meter_not_found + meter_qipower))
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "RequiredMeterNotFound|MeterIsMissing|PreferredMeterMissing" 10)
            [ -n "$ev" ] && break
        done
        local desc="Meter not found ($total events)."
        [ "$meter_not_found" -gt 0 ] && desc="$desc RequiredMeterNotFound ×$meter_not_found."
        [ "$meter_qipower" -gt 0 ] && desc="$desc MeterIsMissing ×$meter_qipower (QiPower)."
        [ "$meter_preferred" -gt 0 ] && desc="$desc PreferredMeterMissing ×$meter_preferred."
        desc="$desc Troubleshooting: 1. Verify Meter.preferred.type in ChargerApp properties 2. Reboot station 3. Check meter connection 4. Replace meter. [On-site service required]"
        add_issue "HIGH" "Meter/NotFound" "Energy Meter Not Found" "$desc" "$ev"
    fi

    # ═══ ISSUE: Meter Communication Failure ═══
    local comm_total=$((meter_conn_fail + meter_data_unavail + meter_autodetect))
    if [ "$comm_total" -gt 0 ] && [ "$meter_missing_critical" -eq 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "ConnectionFailed|DataUnavailable|AutoDetectionFailed" 10)
            [ -n "$ev" ] && break
        done
        local desc="Meter communication issues ($comm_total events)."
        [ "$meter_conn_fail" -gt 0 ] && desc="$desc ConnectionFailed ×$meter_conn_fail."
        [ "$meter_data_unavail" -gt 0 ] && desc="$desc DataUnavailable ×$meter_data_unavail (register read failures)."
        [ "$meter_autodetect" -gt 0 ] && desc="$desc AutoDetectionFailed ×$meter_autodetect (Modbus meter not detected)."
        desc="$desc Troubleshooting: 1. Check meter wiring (RS485) 2. Verify Modbus address/baud rate 3. Check bus termination 4. Reboot charger 5. Replace meter. [On-site service required]"
        add_issue "MEDIUM" "Meter/Communication" "Energy Meter Communication Failure" "$desc" "$ev"
    fi

    # ═══ ISSUE: Eichrecht Errors ═══
    local eichrecht_total=$((eichrecht_terminal + eichrecht_unavail + eichrecht_orphan))
    if [ "$eichrecht_total" -gt 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "EICHRECHT_ERROR_STATE|orphan.*session" 10)
            [ -n "$ev" ] && break
        done
        local sev="HIGH" desc="Eichrecht legal metering error(s)."
        [ "$eichrecht_terminal" -gt 0 ] && sev="CRITICAL" && desc="$desc EICHRECHT_ERROR_STATE_TERMINAL ×$eichrecht_terminal — blocks ALL sessions, fatal metering state."
        [ "$eichrecht_unavail" -gt 0 ] && sev="CRITICAL" && desc="$desc EICHRECHT_ERROR_STATE_UNAVAILABLE ×$eichrecht_unavail — blocks ALL sessions, metering unavailable."
        [ "$eichrecht_orphan" -gt 0 ] && desc="$desc EICHRECHT_ERROR_STATE_ORPHAN_SESSION ×$eichrecht_orphan — orphan metering session (resets current session)."
        desc="$desc Legal metering integrity compromised — billing affected. Troubleshooting: 1. Check meter status 2. Verify calibration seal 3. Power cycle 4. Contact metering authority. [On-site service REQUIRED]"
        add_issue "$sev" "Meter/Eichrecht" "Eichrecht Legal Metering Error" "$desc" "$ev"
    fi
    return 0
}

# ─── 2.3k: Grid Codes / Inverter Analysis ──────────────────────────────────
_analyze_grid_codes() {
    log_verbose "Analyzing grid codes..."
    local all_logs="$LOG_DIR"

    local grid_freq=0 grid_volt=0 grid_comm=0

    for f in "$all_logs"/*_combined.log "$all_logs"/*.log; do
        [ -f "$f" ] || continue
        local _gf=0 _gv=0 _gc=0
        eval "$(batch_count_grep "$f" \
            _gf 'UnderFrequency|OverFrequency|[Ff]requency.*[Dd]isconnect' \
            _gv 'GridFault.*[Vv]oltage|[Uu]nder[Vv]oltage.*[Ss]hutdown|[Oo]ver[Vv]oltage.*[Ss]hutdown|GridFaultUnderVoltage|GridFaultOverVoltage' \
            _gc 'ErrorCIU.*CriticalCommError|ErrorMIU.*CommError|CriticalCommError')"
        grid_freq=$((grid_freq + _gf))
        grid_volt=$((grid_volt + _gv))
        grid_comm=$((grid_comm + _gc))
    done

    add_metric "grid_freq_events" "$grid_freq"
    add_metric "grid_volt_events" "$grid_volt"
    add_metric "grid_comm_errors" "$grid_comm"

    # ═══ ISSUE: Grid Code Violations ═══
    local total=$((grid_freq + grid_volt + grid_comm))
    if [ "$total" -gt 0 ]; then
        local desc="Grid code events ($total): $grid_freq frequency trips, $grid_volt voltage faults, $grid_comm communication errors."
        desc="$desc Inverter disconnected from grid for safety. Troubleshooting: 1. Check grid connection 2. Verify frequency/voltage at service entrance 3. Contact utility if persistent."
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "UnderFrequency|OverFrequency|GridFault|Voltage.*Shutdown|CriticalCommError" 15)
            [ -n "$ev" ] && break
        done
        add_issue "CRITICAL" "GridCodes/Safety" "Grid Code Protection Triggered" "$desc" "$ev"
    fi
    return 0
}

# ─── 2.3l: OCPP Error Code Analysis ────────────────────────────────────────
_analyze_ocpp_error_codes() {
    log_verbose "Analyzing OCPP error codes..."
    local all_logs="$LOG_DIR"

    # OCPP StatusNotification error codes from source
    local ocpp_errors=""
    for f in "$all_logs"/*_combined.log "$all_logs"/*.log; do
        [ -f "$f" ] || continue
        ocpp_errors="$ocpp_errors$(grep -aoE '"errorCode"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | grep -v 'NoError')"
    done

    if [ -n "$ocpp_errors" ]; then
        local unique_codes
        unique_codes=$(echo "$ocpp_errors" | grep -oE '"[A-Za-z]*"$' | tr -d '"' | sort | uniq -c | sort -rn)
        local code_count
        code_count=$(echo "$unique_codes" | grep -c '[A-Za-z]' 2>/dev/null || echo 0)

        if [ "$code_count" -gt 0 ]; then
            add_metric "ocpp_error_codes" "$(echo "$unique_codes" | tr '\n' ';' | head -c 200)"

            # Map OCPP error codes to descriptions (from OCPP 1.6/2.0.1 spec)
            local desc="OCPP StatusNotification error codes detected:"
            echo "$unique_codes" | while IFS= read -r line; do
                [ -z "$line" ] && continue
                local cnt code
                cnt=$(echo "$line" | awk '{print $1}')
                code=$(echo "$line" | awk '{print $2}')
                case "$code" in
                    ConnectorLockFailure)  desc="$desc ConnectorLockFailure ×$cnt (connector locking mechanism failed);" ;;
                    GroundFailure)         desc="$desc GroundFailure ×$cnt (ground fault detected);" ;;
                    HighTemperature)       desc="$desc HighTemperature ×$cnt (temperature sensor triggered);" ;;
                    OverCurrentFailure)    desc="$desc OverCurrentFailure ×$cnt (over-current protection triggered);" ;;
                    OverVoltage)           desc="$desc OverVoltage ×$cnt (over-voltage detected);" ;;
                    UnderVoltage)          desc="$desc UnderVoltage ×$cnt (under-voltage detected);" ;;
                    PowerMeterFailure)     desc="$desc PowerMeterFailure ×$cnt (energy meter communication lost);" ;;
                    PowerSwitchFailure)    desc="$desc PowerSwitchFailure ×$cnt (contactor/relay failure);" ;;
                    ReaderFailure)         desc="$desc ReaderFailure ×$cnt (RFID reader malfunction);" ;;
                    ResetFailure)          desc="$desc ResetFailure ×$cnt (reset command failed);" ;;
                    WeakSignal)            desc="$desc WeakSignal ×$cnt (cellular/WiFi signal weak);" ;;
                    InternalError)         desc="$desc InternalError ×$cnt (internal software error);" ;;
                esac
            done
        fi
    fi
    return 0
}

# ─── 2.3n: PMQ System Health (Thread Alarms, Queue Overflow, IPC) ────────
# Source: pmq-Sb-v1.13 — ThreadAlarm fires when PMQ FD poll exceeds 1000 ms.
# Thousands of these indicate CPU starvation or I/O blocking. Queue overflow
# means messages are being dropped between components.
_analyze_pmq_system_health() {
    log_verbose "Analyzing PMQ system health..."

    local total_alarms=0 queue_overflow=0 disconnected_queues=0
    local alarm_files="" overflow_files="" discon_files=""

    for f in "$LOG_DIR"/*_combined.log; do
        [ -f "$f" ] || continue
        local a=0 q=0 d=0
        eval "$(batch_count_grep "$f" \
            a 'ThreadAlarm.*timeout detected' \
            q 'Cant send message.*queue size limit|Can.t send.*queue.*limit' \
            d 'Direct queue not connected')"
        total_alarms=$((total_alarms + a))
        queue_overflow=$((queue_overflow + q))
        disconnected_queues=$((disconnected_queues + d))
        [ "$a" -gt 0 ] && alarm_files="${alarm_files:+$alarm_files }$f"
        [ "$q" -gt 0 ] && overflow_files="${overflow_files:+$overflow_files }$f"
        [ "$d" -gt 0 ] && discon_files="${discon_files:+$discon_files }$f"
    done

    add_metric "pmq_thread_alarms" "$total_alarms"
    add_metric "pmq_queue_overflow" "$queue_overflow"
    add_metric "pmq_disconnected_queues" "$disconnected_queues"

    # ═══ ISSUE: PMQ Thread Alarm Storm ═══
    if [ "$total_alarms" -gt 100 ]; then
        local sev="MEDIUM"
        [ "$total_alarms" -gt 1000 ] && sev="HIGH"
        [ "$total_alarms" -gt 5000 ] && sev="CRITICAL"
        local ev
        ev=$(collect_evidence "${alarm_files%% *}" "ThreadAlarm.*timeout detected" 15)
        add_issue "$sev" "PMQ/ThreadAlarm" "PMQ Thread Alarm Storm" \
            "$total_alarms PMQ thread alarm timeouts detected (threshold 1000ms). Indicates CPU starvation, I/O blocking, or system overload. Inter-process messaging is delayed.
Troubleshooting: 1. Check CPU usage (top/htop) for runaway processes 2. Check storage I/O (iostat) for high iowait 3. Review Monit for crashed services consuming restart cycles 4. Power cycle if persistent" "$ev"
        add_timeline_event "$([ -n "${alarm_files}" ] && grep -am1 'ThreadAlarm' "${alarm_files%% *}" 2>/dev/null | cut -d' ' -f1-2)" "$sev" "PMQ" "Thread alarm storm"
    fi

    # ═══ ISSUE: PMQ Queue Overflow ═══
    if [ "$queue_overflow" -gt 5 ]; then
        local sev="MEDIUM"
        [ "$queue_overflow" -gt 50 ] && sev="HIGH"
        local ev
        ev=$(collect_evidence "${overflow_files%% *}" "Cant send message|Can't send.*queue" 15)
        add_issue "$sev" "PMQ/QueueOverflow" "PMQ Message Queue Overflow" \
            "$queue_overflow messages dropped due to PMQ queue size limits. Components are producing messages faster than consumers can process. May cause missed state updates between services.
Troubleshooting: 1. Identify slowest consumer from PMQ logs 2. Check if ErrorBoss or ConfigManager are blocked 3. Review thread alarm counts — overflow often follows alarm storms" "$ev"
    fi

    # ═══ ISSUE: PMQ Boot IPC Failures ═══
    if [ "$disconnected_queues" -gt 10 ]; then
        local sev="LOW"
        [ "$disconnected_queues" -gt 30 ] && sev="MEDIUM"
        local ev discon_targets
        ev=$(collect_evidence "${discon_files%% *}" "Direct queue not connected" 20)
        discon_targets=""
        [ -n "$discon_files" ] && discon_targets=$(grep -roh 'Direct queue not connected: /[^ ]*' $discon_files 2>/dev/null | sed 's/.*: //' | sort -u | head -10 | tr '\n' ', ')
        add_issue "$sev" "PMQ/BootIPC" "PMQ Inter-Process Connections Delayed" \
            "$disconnected_queues IPC queue-not-connected events during boot. Services started before their dependencies were ready. Queues: ${discon_targets%. }. Usually self-resolves within 30s; persistent disconnections indicate a service that never started.
Troubleshooting: 1. Check Monit for services that failed to start 2. Verify boot order in init scripts (S00-S99) 3. Check if crashed services left stale PMQ queues" "$ev"
    fi
    return 0
}

# ─── 2.3o: Certificate Loading Analysis ──────────────────────────────────
# Source: iotc-cert-mgr-Sb-v1.13 — logs [E] CertsConfig: Failed to read cert config
_analyze_cert_loading() {
    log_verbose "Analyzing certificate loading..."

    local cert_log
    cert_log=$(get_log_file "CertManager_combined")
    [ -z "$cert_log" ] && cert_log=$(get_log_file "CertManager")
    [ -z "$cert_log" ] || [ ! -f "$cert_log" ] && return

    local cert_read_fail
    cert_read_fail=$(count_grep "Failed to read cert config" "$cert_log")
    add_metric "cert_read_failures" "$cert_read_fail"

    if [ "$cert_read_fail" -gt 0 ]; then
        local failed_certs ev
        failed_certs=$(grep -o 'Failed to read cert config, skip:.*' "$cert_log" 2>/dev/null | sed 's/.*skip:  *//' | sort -u | tr '\n' ', ')
        ev=$(collect_evidence "$cert_log" "Failed to read cert config" 15)
        local sev="MEDIUM"
        # V2G and ChargingStation certs are high-severity
        echo "$failed_certs" | grep -qiE 'V2G|ChargingStation|I2P2' && sev="HIGH"
        add_issue "$sev" "CertManager/Loading" "Certificate Config Loading Failures" \
            "$cert_read_fail certificate configurations could not be loaded: ${failed_certs%, }. Missing root CA chains may prevent TLS connections to cloud (I2P2/MQTT), OCPP central system, or V2G communication.
Troubleshooting: 1. Check /etc/iotecha/certs/ for missing .pem files 2. Verify certificate paths in CertManager config 3. Re-provision certificates via OCPP InstallCertificate or factory reset 4. Check certificate expiration dates" "$ev"
        add_timeline_event "$(grep -am1 'Failed to read cert config' "$cert_log" | cut -d' ' -f1-2)" "$sev" "CertManager" "Cert loading failure"
    fi
    return 0
}

# ─── 2.3p: Token Manager Analysis ────────────────────────────────────────
# Source: iotc-token-manager — logs registration errors and auth token issues
_analyze_token_manager() {
    log_verbose "Analyzing Token Manager..."

    local tm_log
    tm_log=$(get_log_file "TokenManager_combined")
    [ -z "$tm_log" ] && tm_log=$(get_log_file "TokenManager")
    [ -z "$tm_log" ] || [ ! -f "$tm_log" ] && return

    local reg_errors=0 auth_errors=0
    eval "$(batch_count_grep "$tm_log" \
        reg_errors  'App registering [0-9]|registration.*fail|register error' \
        auth_errors 'Unknown auth token|auth.*fail|token.*reject|token.*invalid')"
    add_metric "tm_registration_errors" "$reg_errors"
    add_metric "tm_auth_errors" "$auth_errors"

    if [ "$auth_errors" -gt 0 ]; then
        local ev
        ev=$(collect_evidence "$tm_log" "Unknown auth token|auth.*fail|token.*reject|token.*invalid" 10)
        add_issue "MEDIUM" "TokenManager/Auth" "Authentication Token Errors" \
            "$auth_errors authentication token error(s) detected. Unknown or invalid tokens may prevent RFID card authorization for charging sessions.
Troubleshooting: 1. Verify token whitelist in OCPP LocalAuthList 2. Check OCPP Authorize request/response flow 3. Ensure TokenManager can reach AuthManager via PMQ 4. Review offline auth mode settings" "$ev"
    fi
    return 0
}

# ─── 2.3q: Network Interface Selection Analysis ─────────────────────────
# Source: iotc-network-boss — InterfaceSelectionManager handles LTE/WiFi/Eth failover
_analyze_interface_selection() {
    log_verbose "Analyzing network interface selection..."

    local nb_log
    nb_log=$(get_log_file "NetworkBoss_combined")
    [ -z "$nb_log" ] && nb_log=$(get_log_file "NetworkBoss")
    [ -z "$nb_log" ] || [ ! -f "$nb_log" ] && return

    local metric_reapply=0 init_errors=0
    eval "$(batch_count_grep "$nb_log" \
        metric_reapply 'Re-apply metric for interface' \
        init_errors    'Error during interfaces initialization')"
    add_metric "nb_metric_reapply" "$metric_reapply"
    add_metric "nb_init_errors" "$init_errors"

    # ═══ ISSUE: Interface instability ═══
    if [ "$metric_reapply" -gt 50 ]; then
        local sev="LOW"
        [ "$metric_reapply" -gt 200 ] && sev="MEDIUM"
        [ "$metric_reapply" -gt 500 ] && sev="HIGH"
        local affected_ifaces ev
        affected_ifaces=$(grep -o 'Re-apply metric for interface [^ ]*' "$nb_log" 2>/dev/null | sed 's/.*interface //' | sort | uniq -c | sort -rn | head -3 | awk '{print $2"("$1"x)"}' | tr '\n' ' ')
        ev=$(collect_evidence "$nb_log" "Re-apply metric|interface.*down|interface.*up" 15)
        add_issue "$sev" "NetworkBoss/InterfaceSelection" "Network Interface Instability" \
            "$metric_reapply interface metric re-applications. Affected: ${affected_ifaces}. NetworkBoss repeatedly adjusts routing metrics, indicating interfaces are flapping or connectivity checks are failing.
Troubleshooting: 1. Check which interface keeps losing connectivity (wlan0/eth0/ppp0) 2. For WiFi: check signal strength and AP availability 3. For LTE: check signal with AT commands (AT+CSQ) 4. Review interfaceSelectionManager.availabilityChecker settings" "$ev"
    fi

    # ═══ ISSUE: Network initialization failure ═══
    if [ "$init_errors" -gt 0 ]; then
        local ev
        ev=$(collect_evidence "$nb_log" "Error during interfaces initialization|initialization.*fail" 10)
        add_issue "HIGH" "NetworkBoss/Init" "Network Interfaces Initialization Failure" \
            "NetworkBoss failed to initialize network interfaces ($init_errors error(s)). May affect all connectivity (OCPP, MQTT, remote management).
Troubleshooting: 1. Check eth0 cable connection 2. Verify modem presence (lsusb) and SIM card 3. Review NetworkBoss.properties for interface configuration 4. Check kernel dmesg for driver errors 5. Power cycle the charger" "$ev"
    fi
    return 0
}

# ─── 2.3m: Error Registry Scanner ─────────────────────────────────────────
# Scans parsed log lines for error names from the official 363-error registry.
# Only matches in error/warning context lines ([E],[W],[C],Error,Warning)
# to avoid false positives from config definitions and PMQ queue names.
# ─── 2.3p: PowerBoard Stop Codes (76 errors, 75 CRITICAL) ──────────────────
_analyze_powerboard_stopcodes() {
    log_verbose "Analyzing PowerBoard stop codes..."
    local all_logs="$LOG_DIR"

    # HWPowerBoardStopCode: 76 entries. Most are error_block_all_sessions (CRITICAL).
    # Group by category for meaningful reporting.
    local pb_overcurrent=0 pb_overvoltage=0 pb_undervoltage=0 pb_ground=0
    local pb_bender=0 pb_relay=0 pb_phase=0 pb_frequency=0 pb_power=0
    local pb_meter=0 pb_mc2=0 pb_other=0 pb_total=0

    for f in "$all_logs"/*_combined.log "$all_logs"/*.log; do
        [ -f "$f" ] || continue
        eval "$(batch_count_grep "$f" \
            _oc  'HARD_OVERCURRENT|SOFT_OVERCURRENT|IDLE_CURRENT' \
            _ov  'OVERVOLTAGE[^_]|OVERVOLTAGE_10_MIN' \
            _uv  'UNDERVOLTAGE[^_]' \
            _gnd 'GROUND_FAULT|CT_RCM_FAULT|CT_TEST_FAULT' \
            _bnd 'BENDER_ERROR|BENDER_FAULT|BENDER_INIT|BENDER_SELF_TEST' \
            _rly 'RELAY.*STUCK|CONTACTORS_WELDED|CONTACTORS_ERROR|UNEXPECTED.*RELAY' \
            _ph  'PHASE.*MISSING|PHASE_SEQUENCE_ERROR|SINGLE_PHASE_MODE' \
            _frq 'HIGH_FREQUENCY|LOW_FREQUENCY|ROCOF_FAULT' \
            _pwr 'POWER_FAILURE|HOST_COMMAND_TIMEOUT|CODE_INTEGRITY' \
            _mtr 'METER_FAULT|METER_CONFIGURATION_RESET' \
            _mc2 'MC2_')"
        pb_overcurrent=$((pb_overcurrent + _oc))
        pb_overvoltage=$((pb_overvoltage + _ov))
        pb_undervoltage=$((pb_undervoltage + _uv))
        pb_ground=$((pb_ground + _gnd))
        pb_bender=$((pb_bender + _bnd))
        pb_relay=$((pb_relay + _rly))
        pb_phase=$((pb_phase + _ph))
        pb_frequency=$((pb_frequency + _frq))
        pb_power=$((pb_power + _pwr))
        pb_meter=$((pb_meter + _mtr))
        pb_mc2=$((pb_mc2 + _mc2))
    done

    pb_total=$((pb_overcurrent + pb_overvoltage + pb_undervoltage + pb_ground + pb_bender + pb_relay + pb_phase + pb_frequency + pb_power + pb_meter + pb_mc2))
    add_metric "pb_stopcode_total" "$pb_total"
    add_metric "pb_overcurrent" "$pb_overcurrent"
    add_metric "pb_ground_fault" "$pb_ground"
    add_metric "pb_relay_fault" "$pb_relay"
    add_metric "pb_bender" "$pb_bender"

    if [ "$pb_total" -gt 0 ]; then
        local ev="" desc="" sev="CRITICAL"
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "OVERCURRENT|OVERVOLTAGE|UNDERVOLTAGE|GROUND_FAULT|BENDER|RELAY.*STUCK|CONTACTORS|PHASE.*MISSING|FREQUENCY|POWER_FAILURE|MC2_|METER_FAULT|HOST_COMMAND_TIMEOUT" 20)
            [ -n "$ev" ] && break
        done
        desc="PowerBoard stop codes ($pb_total events) — blocks ALL sessions."
        [ "$pb_overcurrent" -gt 0 ] && desc="$desc Overcurrent ×$pb_overcurrent."
        [ "$pb_overvoltage" -gt 0 ] && desc="$desc Overvoltage ×$pb_overvoltage."
        [ "$pb_undervoltage" -gt 0 ] && desc="$desc Undervoltage ×$pb_undervoltage."
        [ "$pb_ground" -gt 0 ] && desc="$desc Ground/RCM fault ×$pb_ground."
        [ "$pb_bender" -gt 0 ] && desc="$desc Bender IMD fault ×$pb_bender."
        [ "$pb_relay" -gt 0 ] && desc="$desc Relay/contactor fault ×$pb_relay."
        [ "$pb_phase" -gt 0 ] && desc="$desc Phase fault ×$pb_phase."
        [ "$pb_frequency" -gt 0 ] && desc="$desc Frequency fault ×$pb_frequency."
        [ "$pb_power" -gt 0 ] && desc="$desc Power/host fault ×$pb_power."
        [ "$pb_meter" -gt 0 ] && desc="$desc Meter fault ×$pb_meter."
        [ "$pb_mc2" -gt 0 ] && desc="$desc MC2 secondary board ×$pb_mc2."
        desc="$desc Troubleshooting: 1. Power cycle with 10 minute pause 2. Check wiring/connections 3. For relay faults: check contactor resistance 4. For ground faults: check RCD/Bender IMD 5. Replace Power Board. [On-site service required]"
        add_issue "$sev" "PowerBoard/StopCode" "PowerBoard Hardware Stop Code" "$desc" "$ev"
        add_timeline_event "$(grep -rm1 'OVERCURRENT\|OVERVOLTAGE\|GROUND_FAULT\|BENDER\|RELAY.*STUCK\|CONTACTORS\|POWER_FAILURE' "$all_logs"/*_combined.log 2>/dev/null | head -1 | cut -d' ' -f1-2)" "CRITICAL" "PowerBoard" "Hardware stop code"
    fi
    return 0
}

# ─── 2.3q: InnerSM — Charging State Machine (23 errors, 3 CRITICAL) ────────
_analyze_inner_sm() {
    log_verbose "Analyzing InnerSM state machine..."
    local all_logs="$LOG_DIR"

    # CRITICAL: ERROR_UNAVAILABLE (exit), ERROR_UNAVAILABLE_STATE_F, REPEATING_ERRORS
    # HIGH: CHARGING_CONFIRMATION_TIMEOUT, CHARGING_CONFIRMATION_DECLINED
    # MEDIUM: ERROR_COMMUNICATION_BLOCKED, STUCK_IN_UNDEFINED_LOGIC_STATE
    # LOW: remaining warnings
    local ism_critical=0 ism_confirm=0 ism_comm=0 ism_other=0

    for f in "$all_logs"/*_combined.log "$all_logs"/*.log; do
        [ -f "$f" ] || continue
        eval "$(batch_count_grep "$f" \
            _ic 'ERROR_UNAVAILABLE|ERROR_UNAVAILABLE_STATE_F|REPEATING_ERRORS' \
            _if 'CHARGING_CONFIRMATION_TIMEOUT|CHARGING_CONFIRMATION_DECLINED' \
            _im 'ERROR_COMMUNICATION_BLOCKED|STUCK_IN_UNDEFINED_LOGIC_STATE' \
            _io 'ERROR_STATE_RECOVER|ERROR_SERVER_CREATE_FAILED|ERROR_MESSAGE_IN_WRONG_STATE|ERROR_EXI_ENCODING_FAILED|ERROR_PRECHARGE_VOLTAGE_RAISE_TIMEOUT|ERROR_NEGATIVE_CURRENT|ERROR_OVERLOAD|ERROR_CANT_UNPAUSE|ERROR_RESTART_NOT_ALLOWED|ERROR_PWM_CONTROL|ERROR_NEGATIVE_VOLTAGE|BasicChargingCurrentDecreaseAtStart')"
        ism_critical=$((ism_critical + _ic))
        ism_confirm=$((ism_confirm + _if))
        ism_comm=$((ism_comm + _im))
        ism_other=$((ism_other + _io))
    done

    local ism_total=$((ism_critical + ism_confirm + ism_comm + ism_other))
    add_metric "ism_critical" "$ism_critical"
    add_metric "ism_confirm_fail" "$ism_confirm"
    add_metric "ism_comm_blocked" "$ism_comm"
    add_metric "ism_total" "$ism_total"

    if [ "$ism_critical" -gt 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "ERROR_UNAVAILABLE|REPEATING_ERRORS" 15)
            [ -n "$ev" ] && break
        done
        add_issue "CRITICAL" "InnerSM/Fatal" "Charging State Machine Fatal Error" \
            "InnerSM CRITICAL errors ×$ism_critical — ERROR_UNAVAILABLE/STATE_F/REPEATING_ERRORS. State machine exited, blocks ALL sessions. Troubleshooting: 1. Restart charging session 2. Reboot charging station 3. Use another EV/consumer." "$ev"
    fi

    if [ "$ism_confirm" -gt 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "CHARGING_CONFIRMATION_TIMEOUT|CHARGING_CONFIRMATION_DECLINED" 10)
            [ -n "$ev" ] && break
        done
        add_issue "HIGH" "InnerSM/Confirmation" "Charging Confirmation Failed" \
            "CHARGING_CONFIRMATION_TIMEOUT/DECLINED ×$ism_confirm — charging was not confirmed or was declined by confirmers. Resets current session. Troubleshooting: 1. Restart charging session 2. Reboot station 3. Use another EV/consumer. [On-site service required]" "$ev"
    fi

    if [ "$ism_comm" -gt 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "ERROR_COMMUNICATION_BLOCKED|STUCK_IN_UNDEFINED_LOGIC_STATE" 10)
            [ -n "$ev" ] && break
        done
        add_issue "MEDIUM" "InnerSM/Communication" "State Machine Communication Blocked" \
            "ERROR_COMMUNICATION_BLOCKED/STUCK ×$ism_comm. Troubleshooting: 1. Restart charging session 2. Reboot station 3. Use another EV/consumer." "$ev"
    fi
    return 0
}

# ─── 2.3r: EVIC GlobalStop — DC + AC (21 errors) ───────────────────────────
_analyze_evic_globalstop() {
    log_verbose "Analyzing EVIC GlobalStop..."
    local all_logs="$LOG_DIR"

    # DcEvicGlobalStop: CableCheck preconditions, IMD, Rectifier, Contactor faults
    # AcEvicGlobalStop: PowerBoardFault, NotChargingWatchdogInterruption
    local dc_cablecheck=0 dc_imd=0 dc_rectifier=0 dc_contactor=0 ac_stop=0

    for f in "$all_logs"/*_combined.log "$all_logs"/*.log; do
        [ -f "$f" ] || continue
        eval "$(batch_count_grep "$f" \
            _dcc 'CableCheckPrecondition' \
            _dim 'IMDFailure|IMDSelftest' \
            _drc 'RectifierConnectionFailed|RectifierFailure|RectifierTemperatureFault|RectifierModeMismatch|RectifierNotReady' \
            _dcn 'ContactorDidNotOpen|ContactorDidNotClose|CurrentRampDownTimeout' \
            _acs 'NotChargingWatchdogInterruption|AcEvicGlobalStop.*PowerBoardFault')"
        dc_cablecheck=$((dc_cablecheck + _dcc))
        dc_imd=$((dc_imd + _dim))
        dc_rectifier=$((dc_rectifier + _drc))
        dc_contactor=$((dc_contactor + _dcn))
        ac_stop=$((ac_stop + _acs))
    done

    local dc_total=$((dc_cablecheck + dc_imd + dc_rectifier + dc_contactor))
    add_metric "dc_evic_cablecheck" "$dc_cablecheck"
    add_metric "dc_evic_imd" "$dc_imd"
    add_metric "dc_evic_rectifier" "$dc_rectifier"
    add_metric "dc_evic_contactor" "$dc_contactor"
    add_metric "ac_evic_stop" "$ac_stop"

    if [ "$dc_total" -gt 0 ]; then
        local ev="" desc sev="HIGH"
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "CableCheckPrecondition|IMDFailure|RectifierFail|RectifierConnection|ContactorDid|CurrentRampDown|RectifierTemperature" 15)
            [ -n "$ev" ] && break
        done
        desc="DC EVIC GlobalStop ($dc_total events) — DC charging halted."
        [ "$dc_cablecheck" -gt 0 ] && desc="$desc CableCheck precondition failures ×$dc_cablecheck (CP/PP state, IMD, voltage)."
        [ "$dc_imd" -gt 0 ] && desc="$desc IMD (insulation) failure ×$dc_imd."
        [ "$dc_rectifier" -gt 0 ] && desc="$desc Rectifier failure ×$dc_rectifier." && sev="CRITICAL"
        [ "$dc_contactor" -gt 0 ] && desc="$desc Contactor failure ×$dc_contactor (stuck open/closed)." && sev="CRITICAL"
        desc="$desc Troubleshooting: 1. Check rectifier connection to dispenser 2. Reboot rectifier 3. Check IMD/Bender device 4. For contactor faults: check DC contactors. [On-site service required]"
        add_issue "$sev" "EVIC/DC/GlobalStop" "DC EVIC Global Stop" "$desc" "$ev"
    fi

    if [ "$ac_stop" -gt 0 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "NotChargingWatchdogInterruption|AcEvicGlobalStop" 10)
            [ -n "$ev" ] && break
        done
        add_issue "HIGH" "EVIC/AC/GlobalStop" "AC EVIC Global Stop" \
            "AC EVIC GlobalStop ×$ac_stop — AC charging halted. NotChargingWatchdogInterruption or PowerBoardFault. Troubleshooting: 1. Check PowerBoard 2. Reboot station 3. Check AC wiring. [On-site service required]" "$ev"
    fi
    return 0
}

# ─── 2.3s: HAL Hardware Errors (HWHalArCIU/MIU1-5/Mg — 58 errors) ─────────
_analyze_hal_errors() {
    log_verbose "Analyzing HAL hardware errors..."
    local all_logs="$LOG_DIR"

    # All are CRITICAL (error_block_all_sessions). Group by subsystem.
    local hal_ciu=0 hal_miu=0 hal_mg=0 hal_base=0 hal_zr=0 hal_short=0

    for f in "$all_logs"/*_combined.log "$all_logs"/*.log; do
        [ -f "$f" ] || continue
        eval "$(batch_count_grep "$f" \
            _hc  'ErrorCIU_' \
            _hm  'ErrorMIU[0-9]_' \
            _hg  'GridFault|Disconnection|SoftDisconnection|SoftReconnection' \
            _hb  'Error_Battery_Overvoltage|EvicBlocked|ErrorStartingChargingOnInactiveConnector' \
            _hz  'ErrorM2LowCurrent' \
            _hs  'ErrorShortCircuitTestFailed|DcSourceCommError|DcSourceErrorInverter|RectifierUnavailableOnStartup')"
        hal_ciu=$((hal_ciu + _hc))
        hal_miu=$((hal_miu + _hm))
        hal_mg=$((hal_mg + _hg))
        hal_base=$((hal_base + _hb))
        hal_zr=$((hal_zr + _hz))
        hal_short=$((hal_short + _hs))
    done

    local hal_total=$((hal_ciu + hal_miu + hal_mg + hal_base + hal_zr + hal_short))
    add_metric "hal_ciu_errors" "$hal_ciu"
    add_metric "hal_miu_errors" "$hal_miu"
    add_metric "hal_total" "$hal_total"

    if [ "$hal_total" -gt 0 ]; then
        local ev="" desc sev="CRITICAL"
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "ErrorCIU_|ErrorMIU|GridFault|Disconnection|Error_Battery|ErrorShortCircuit|DcSource|RectifierUnavailable|ErrorM2|EvicBlocked" 15)
            [ -n "$ev" ] && break
        done
        desc="HAL hardware errors ($hal_total events) — blocks ALL sessions."
        [ "$hal_ciu" -gt 0 ] && desc="$desc CIU (charger interface unit) errors ×$hal_ciu."
        [ "$hal_miu" -gt 0 ] && desc="$desc MIU (module interface unit) errors ×$hal_miu."
        [ "$hal_mg" -gt 0 ] && desc="$desc Grid disconnect events ×$hal_mg."
        [ "$hal_short" -gt 0 ] && desc="$desc Short circuit / DC source errors ×$hal_short."
        [ "$hal_base" -gt 0 ] && desc="$desc Base HAL errors ×$hal_base."
        desc="$desc Troubleshooting: 1. Check rectifier module connections 2. Check CIU/MIU communication bus 3. Power cycle all modules 4. Replace faulty module. [On-site service required]"
        add_issue "$sev" "HAL/Hardware" "HAL Hardware Module Error" "$desc" "$ev"
    fi
    return 0
}

# ─── 2.3t: Compliance / Limits Monitors ─────────────────────────────────────
_analyze_compliance_limits() {
    log_verbose "Analyzing compliance limits..."
    local all_logs="$LOG_DIR"

    # LimitsComplianceMonitor: EVDoesNotObeyImposedLimit, SoftOvercurrentDetected, MeterValuesNotReceived
    # SoftLimitMonitor: MeterValuesNotReceived, OvercurrentDetected
    # PlazaCommunication: NoScheduleResponse
    # VASServer: VAS_SERVER_RECEIVE_TIMEOUT
    # iotc-eebus-evcs: EEBUS_LOST_CONNECTION
    local ev_disobey=0 soft_oc=0 meter_norx=0 plaza=0 vas=0 eebus=0

    for f in "$all_logs"/*_combined.log "$all_logs"/*.log; do
        [ -f "$f" ] || continue
        eval "$(batch_count_grep "$f" \
            _ed 'EVDoesNotObeyImposedLimit|DoesNotObey' \
            _so 'SoftOvercurrentDetected|OvercurrentDetected' \
            _mn 'MeterValuesNotReceived' \
            _pl 'NoScheduleResponse' \
            _va 'VAS_SERVER_RECEIVE_TIMEOUT' \
            _eb 'EEBUS_LOST_CONNECTION')"
        ev_disobey=$((ev_disobey + _ed))
        soft_oc=$((soft_oc + _so))
        meter_norx=$((meter_norx + _mn))
        plaza=$((plaza + _pl))
        vas=$((vas + _va))
        eebus=$((eebus + _eb))
    done

    add_metric "ev_disobey_limit" "$ev_disobey"
    add_metric "soft_overcurrent" "$soft_oc"
    add_metric "meter_norx" "$meter_norx"

    if [ "$ev_disobey" -gt 0 ] || [ "$soft_oc" -gt 0 ]; then
        local ev="" desc sev="HIGH"
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "EVDoesNotObey|OvercurrentDetected|SoftOvercurrent" 10)
            [ -n "$ev" ] && break
        done
        local total=$((ev_disobey + soft_oc))
        desc="Current/power limit compliance violations ($total events). Resets current session."
        [ "$ev_disobey" -gt 0 ] && desc="$desc EVDoesNotObeyImposedLimit ×$ev_disobey — EV drawing more than allowed."
        [ "$soft_oc" -gt 0 ] && desc="$desc SoftOvercurrentDetected ×$soft_oc."
        desc="$desc Troubleshooting: 1. Restart charging session 2. Use another EV/consumer 3. Check if EV firmware supports current limits."
        add_issue "$sev" "Compliance/Limits" "EV Current Limit Violation" "$desc" "$ev"
    fi

    if [ "$meter_norx" -gt 3 ]; then
        local ev=""
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "MeterValuesNotReceived" 10)
            [ -n "$ev" ] && break
        done
        add_issue "MEDIUM" "Compliance/Meter" "Meter Values Not Received" \
            "MeterValuesNotReceived ×$meter_norx — compliance monitor not receiving energy readings. Troubleshooting: 1. Check meter communication 2. Verify meter configuration 3. Reboot charger." "$ev"
    fi

    if [ "$plaza" -gt 0 ] || [ "$vas" -gt 0 ] || [ "$eebus" -gt 0 ]; then
        local total=$((plaza + vas + eebus))
        local ev="" desc="External communication issues ($total events)."
        [ "$plaza" -gt 0 ] && desc="$desc NoScheduleResponse ×$plaza (Plaza/CSMS schedule)."
        [ "$vas" -gt 0 ] && desc="$desc VAS_SERVER_RECEIVE_TIMEOUT ×$vas (value-added services)."
        [ "$eebus" -gt 0 ] && desc="$desc EEBUS_LOST_CONNECTION ×$eebus (EEBus smart home link)."
        desc="$desc Troubleshooting: 1. Check network connectivity 2. Verify backend service availability 3. Restart charging session."
        for f in "$all_logs"/*_combined.log; do
            [ -f "$f" ] || continue
            ev=$(collect_evidence "$f" "NoScheduleResponse|VAS_SERVER|EEBUS_LOST" 10)
            [ -n "$ev" ] && break
        done
        add_issue "LOW" "External/Communication" "External Service Communication Issue" "$desc" "$ev"
    fi
    return 0
}

# ─── 2.3v: Connector-Level Health Analysis ───────────────────────────────
# Dual-connector chargers may have issues isolated to one connector.
# This detector attributes errors to specific connectors and identifies
# which connector (if any) is disproportionately affected.
_analyze_connector_health() {
    log_verbose "Analyzing per-connector health..."
    local all_logs="$LOG_DIR"

    # Connector identification patterns in IoTecha logs:
    #   connector=1, connector=2, ConnectorId=1, connectorId:1
    #   evseId=1, evse-1, EVSE 1
    #   InnerSM-1, InnerSM-2 (state machine per connector)
    #   Connector[0], Connector[1] (0-indexed in some components)
    #   M1/M2 (connector aliases in HWSpecificHAL)
    #   socket 1, socket 2

    local c1_errors=0 c2_errors=0 c1_warnings=0 c2_warnings=0
    local c1_sessions=0 c2_sessions=0 total_lines=0

    for f in "$all_logs"/*_combined.log; do
        [ -f "$f" ] || continue
        # Single awk pass: classify lines by connector AND severity
        eval "$(awk '
        /[Cc]onnector[=: ]*1|[Cc]onnectorId[=: ]*1|evseId[=: ]*1|evse[-_]1|EVSE *1|InnerSM[-_]1|[Ss]ocket *1|\bM1\b|Connector\[0\]/ {
            if (/\[E\]|\[C\]|\[F\]|Error|CRITICAL|error_block|[Ff]ault|[Ff]ailed/) c1e++
            else if (/\[W\]|Warning|[Ww]arning/) c1w++
            if (/[Ss]ession.*[Ss]tart|StartTransaction|start.*charging/) c1s++
        }
        /[Cc]onnector[=: ]*2|[Cc]onnectorId[=: ]*2|evseId[=: ]*2|evse[-_]2|EVSE *2|InnerSM[-_]2|[Ss]ocket *2|\bM2\b|Connector\[1\]/ {
            if (/\[E\]|\[C\]|\[F\]|Error|CRITICAL|error_block|[Ff]ault|[Ff]ailed/) c2e++
            else if (/\[W\]|Warning|[Ww]arning/) c2w++
            if (/[Ss]ession.*[Ss]tart|StartTransaction|start.*charging/) c2s++
        }
        END {
            printf "c1e=%d c2e=%d c1w=%d c2w=%d c1s=%d c2s=%d\n", c1e+0, c2e+0, c1w+0, c2w+0, c1s+0, c2s+0
        }' "$f" 2>/dev/null)"
        c1_errors=$((c1_errors + c1e))
        c2_errors=$((c2_errors + c2e))
        c1_warnings=$((c1_warnings + c1w))
        c2_warnings=$((c2_warnings + c2w))
        c1_sessions=$((c1_sessions + c1s))
        c2_sessions=$((c2_sessions + c2s))
    done

    local c1_total=$((c1_errors + c1_warnings))
    local c2_total=$((c2_errors + c2_warnings))
    local both_total=$((c1_total + c2_total))

    add_metric "conn1_errors" "$c1_errors"
    add_metric "conn1_warnings" "$c1_warnings"
    add_metric "conn1_sessions" "$c1_sessions"
    add_metric "conn2_errors" "$c2_errors"
    add_metric "conn2_warnings" "$c2_warnings"
    add_metric "conn2_sessions" "$c2_sessions"
    add_metric "connector_events_total" "$both_total"

    # Only report if we detected a multi-connector charger (events on both connectors)
    if [ "$c1_total" -gt 0 ] && [ "$c2_total" -gt 0 ]; then
        add_metric "multi_connector" "1"

        # Check for disproportionate errors on one connector
        local ratio=0 worse="" worse_err=0 worse_warn=0 better="" better_err=0
        if [ "$c1_errors" -gt "$c2_errors" ] && [ "$c2_errors" -gt 0 ]; then
            ratio=$((c1_errors * 100 / (c2_errors > 0 ? c2_errors : 1)))
            worse="Connector 1" worse_err=$c1_errors worse_warn=$c1_warnings
            better="Connector 2" better_err=$c2_errors
        elif [ "$c2_errors" -gt "$c1_errors" ] && [ "$c1_errors" -gt 0 ]; then
            ratio=$((c2_errors * 100 / (c1_errors > 0 ? c1_errors : 1)))
            worse="Connector 2" worse_err=$c2_errors worse_warn=$c2_warnings
            better="Connector 1" better_err=$c1_errors
        elif [ "$c1_errors" -gt 0 ] && [ "$c2_errors" -eq 0 ]; then
            ratio=999
            worse="Connector 1" worse_err=$c1_errors worse_warn=$c1_warnings
            better="Connector 2" better_err=0
        elif [ "$c2_errors" -gt 0 ] && [ "$c1_errors" -eq 0 ]; then
            ratio=999
            worse="Connector 2" worse_err=$c2_errors worse_warn=$c2_warnings
            better="Connector 1" better_err=0
        fi

        if [ "$ratio" -gt 300 ] && [ "$worse_err" -gt 3 ]; then
            # One connector has 3x+ more errors
            local ev="" sev="MEDIUM"
            [ "$worse_err" -gt 10 ] && sev="HIGH"
            for f in "$all_logs"/*_combined.log; do
                [ -f "$f" ] || continue
                local conn_pat
                if [ "$worse" = "Connector 1" ]; then
                    conn_pat='[Cc]onnector[=: ]*1|InnerSM[-_]1|evse[-_]1|M1'
                else
                    conn_pat='[Cc]onnector[=: ]*2|InnerSM[-_]2|evse[-_]2|M2'
                fi
                ev=$(collect_evidence "$f" "$conn_pat" 15)
                [ -n "$ev" ] && break
            done
            add_issue "$sev" "Connector/Imbalance" "$worse Disproportionately Affected" \
                "Dual-connector charger: $worse has $worse_err errors + $worse_warn warnings vs $better with $better_err errors. $worse may have a hardware issue (cable, connector, power module) independent of $better. Troubleshooting: 1. Inspect $worse cable and plug for damage 2. Check connector-specific hardware (relay, contactor, PP/CP circuit) 3. Compare charging sessions on both connectors 4. If $worse-only: replace connector-specific components. [On-site service required]" "$ev"
        fi
    elif [ "$c1_total" -gt 0 ] || [ "$c2_total" -gt 0 ]; then
        # Only one connector seen — single-connector charger or only one active
        add_metric "multi_connector" "0"
        local active_conn="1" active_err=$c1_errors
        [ "$c2_total" -gt "$c1_total" ] && active_conn="2" && active_err=$c2_errors
        add_sysinfo "active_connector" "$active_conn"
    fi
    return 0
}

_scan_error_registry() {
    local registry_file="$SCRIPT_DIR/signatures/error_registry.tsv"
    [ -f "$registry_file" ] || return

    log_verbose "Scanning logs against 363-error registry..."

    local all_logs="$LOG_DIR"
    local match_count=0

    # Build pattern file from registry error names (skip short/ambiguous names <8 chars)
    local pattern_file="$WORK_DIR/registry_patterns.txt"
    : > "$pattern_file"
    while IFS=$'\t' read -r rmod rcode retype name rdesc rts ronsite rsev; do
        [[ "$rmod" == "module" ]] && continue  # Skip header
        [[ "$rmod" == \#* ]] && continue
        [ -z "$name" ] && continue
        [ "${#name}" -lt 8 ] && continue  # Skip short names like "Reboot","NotReady"
        echo "$name" >> "$pattern_file"
    done < "$registry_file"

    # First pass: extract only error/warning context lines from combined logs
    local error_lines="$WORK_DIR/registry_error_lines.txt"
    : > "$error_lines"
    for f in "$all_logs"/*_combined.log; do
        [ -f "$f" ] || continue
        # Only lines with error/warning markers — not info, not config, not queue names
        grep -aE '\[(E|W|C|F)\]|Error[: ]|Warning[: ]|CRITICAL|error_block|[Ff]ault|[Ff]ailed' "$f" 2>/dev/null >> "$error_lines"
    done

    # Second pass: match registry patterns only against error-context lines
    local hits_file="$WORK_DIR/registry_hits.txt"
    : > "$hits_file"
    if [ -s "$error_lines" ]; then
        grep -ohF -f "$pattern_file" "$error_lines" 2>/dev/null >> "$hits_file"
    fi

    if [ -s "$hits_file" ]; then
        local unique_hits unique_count
        unique_hits=$(sort -u "$hits_file")
        unique_count=$(echo "$unique_hits" | wc -l | tr -d ' ')
        add_metric "registry_matches" "$unique_count"

        while IFS= read -r hit_name; do
            [ -z "$hit_name" ] && continue
            local hit_count
            hit_count=$(grep -cF "$hit_name" "$hits_file" 2>/dev/null || echo 0)

            # Look up registry entry (match on name column = field 2)
            local reg_line
            reg_line=$(awk -F'\t' -v n="$hit_name" '$4 == n {print; exit}' "$registry_file")
            # Fallback: substring match
            [ -z "$reg_line" ] && reg_line=$(grep -F "$hit_name" "$registry_file" | head -1)
            [ -z "$reg_line" ] && continue

            local reg_mod reg_etype reg_sev reg_desc reg_ts reg_onsite
            reg_mod=$(echo "$reg_line" | cut -f1)
            reg_etype=$(echo "$reg_line" | cut -f3)
            reg_sev=$(echo "$reg_line" | cut -f8)
            reg_desc=$(echo "$reg_line" | cut -f5)
            reg_ts=$(echo "$reg_line" | cut -f6)
            reg_onsite=$(echo "$reg_line" | cut -f7)

            # Skip if this error was already caught by a specific detector
            if grep -qF "$hit_name" "$ISSUES_FILE" 2>/dev/null; then
                continue
            fi

            # Build issue description with official troubleshooting steps
            local desc="Registry error '$hit_name' ($reg_mod) ×$hit_count — $reg_desc"
            if [ -n "$reg_ts" ] && [ "$reg_ts" != " " ]; then
                desc="$desc | Troubleshooting: $reg_ts"
            fi
            [ "$reg_onsite" = "true" ] && desc="$desc [On-site service required]"

            # Collect evidence from error lines
            local ev=""
            for f in "$all_logs"/*_combined.log; do
                [ -f "$f" ] || continue
                ev=$(collect_evidence "$f" "$hit_name" 10)
                [ -n "$ev" ] && break
            done

            # Raise issues: blockers always, errors if frequent, warnings if very frequent
            if [ "$reg_etype" = "error_block_all_sessions" ] || [ "$reg_etype" = "locked_warning" ]; then
                add_issue "$reg_sev" "$reg_mod" "$hit_name" "$desc" "$ev"
                match_count=$((match_count + 1))
            elif [ "$reg_etype" = "error" ] && [ "$hit_count" -gt 3 ]; then
                add_issue "HIGH" "$reg_mod" "$hit_name" "$desc" "$ev"
                match_count=$((match_count + 1))
            elif [ "$reg_etype" = "warning_reset_current_session" ] && [ "$hit_count" -gt 5 ]; then
                add_issue "MEDIUM" "$reg_mod" "$hit_name" "$desc" "$ev"
                match_count=$((match_count + 1))
            fi
        done <<< "$unique_hits"

        log_verbose "Registry scan: $unique_count unique errors matched in error-context lines, $match_count new issues raised"
    else
        add_metric "registry_matches" "0"
    fi
    return 0
}

# ─── 2.3h: Kernel / Syslog Analysis ─────────────────────────────────────────
_analyze_kernel_syslog() {
    local kernlog syslog_file
    kernlog=$(get_log_file "kern")
    syslog_file=$(get_log_file "syslog")

    log_verbose "Analyzing kernel/syslog..."

    # Check kernel log — batch all kernel patterns in single pass
    if [ -n "$kernlog" ] && [ -f "$kernlog" ]; then
        local phy_link_up=0 phy_link_down=0 kern_errors=0 driver_issues=0 tpm_issues=0 kern_panics=0
        eval "$(batch_count_grep "$kernlog" \
            phy_link_up   'Link is Up|link up|carrier on' \
            phy_link_down 'Link is Down|link down|carrier off' \
            kern_errors   'error|Error|ERROR|Oops|panic|BUG|segfault' \
            driver_issues 'driver.*fail|probe.*fail|firmware.*fail|timeout.*driver' \
            tpm_issues    'tpm|TPM' \
            kern_panics   'Kernel panic|kernel panic|Oops|BUG:|segfault')"
        add_metric "kern_phy_up" "$phy_link_up"
        add_metric "kern_phy_down" "$phy_link_down"
        add_metric "kern_errors" "$kern_errors"
        add_metric "kern_driver_issues" "$driver_issues"
        add_metric "kern_tpm" "$tpm_issues"
    fi

    # Check syslog for boot count / restarts
    if [ -n "$syslog_file" ] && [ -f "$syslog_file" ]; then
        local boot_count
        boot_count=$(count_grep "Linux version|Booting Linux" "$syslog_file")
        add_metric "boot_count" "$boot_count"
    fi

    # ═══ ISSUE: Kernel Panics / Oops (already counted above) ═══
    if [ -n "$kernlog" ] && [ -f "$kernlog" ]; then
        if [ "$kern_panics" -gt 0 ]; then
            local ev
            ev=$(collect_evidence "$kernlog" "Kernel panic|Oops|BUG:|segfault|Call Trace" 20)
            add_issue "CRITICAL" "Kernel" "Kernel Panic / Oops Detected" \
                "$kern_panics kernel panic or oops event(s). System stability compromised. Troubleshooting: 1. Check for memory issues (memtest) 2. Verify kernel module compatibility 3. Check for hardware faults 4. Review core dumps." "$ev"
            add_timeline_event "$(grep -am1 'Kernel panic\|Oops\|BUG:' "$kernlog" | cut -d' ' -f1-2)" "CRITICAL" "Kernel" "Kernel panic/oops"
        fi

        # ═══ ISSUE: Driver Failures (already counted above) ═══
        if [ "$driver_issues" -gt 3 ]; then
            local ev
            ev=$(collect_evidence "$kernlog" "driver.*fail|probe.*fail|firmware.*fail|timeout.*driver" 15)
            add_issue "HIGH" "Kernel/Drivers" "Driver Initialization Failures" \
                "$driver_issues driver failure(s) in kernel log. Hardware components may not function. Check modem, WiFi, PLC, and power board drivers." "$ev"
        fi
    fi
    return 0
}

# ─── 2.4: Properties Analysis ───────────────────────────────────────────────
_analyze_properties() {
    log_verbose "Analyzing configuration properties..."
    local props_dir="$WORK_DIR/properties"
    [ -d "$props_dir" ] || return

    # ─── i2p2 / MQTT Config ───
    local i2p2_props="$props_dir/i2p2.props"
    if [ -f "$i2p2_props" ]; then
        local conn_timeout
        conn_timeout=$(grep "connectionMonitor.Timeout" "$i2p2_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$conn_timeout" ] && add_sysinfo "i2p2_conn_timeout" "$conn_timeout"

        local close_app_timeout
        close_app_timeout=$(grep "connectionMonitor.CloseApp.Timeout" "$i2p2_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$close_app_timeout" ] && add_sysinfo "i2p2_closeapp_timeout" "$close_app_timeout"

        local mqtt_endpoint
        mqtt_endpoint=$(grep "amazonConnection.endpoint" "$i2p2_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$mqtt_endpoint" ] && add_sysinfo "mqtt_endpoint" "$mqtt_endpoint"

        local cert_source
        cert_source=$(grep "mqtt.certificateSource" "$i2p2_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$cert_source" ] && add_sysinfo "mqtt_cert_source" "$cert_source"
    fi

    # ─── NetworkBoss Config ───
    local nb_props="$props_dir/NetworkBoss.props"
    if [ -f "$nb_props" ]; then
        # Check PPP enabled
        local ppp_enabled
        ppp_enabled=$(grep "ppp0.enabled" "$nb_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$ppp_enabled" ] && add_sysinfo "ppp0_enabled" "$ppp_enabled"

        # Check APN
        local apn
        apn=$(grep "ppp0.apname" "$nb_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$apn" ] && add_sysinfo "ppp0_apn" "$apn"

        # Check modem vendor
        local modem_vendor
        modem_vendor=$(grep "lte.vendorName" "$nb_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$modem_vendor" ] && add_sysinfo "lte_vendor" "$modem_vendor"

        # Check WiFi AP
        local wifi_ssid
        wifi_ssid=$(grep "wlan0-ap.ssid" "$nb_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$wifi_ssid" ] && add_sysinfo "wifi_ap_ssid" "$wifi_ssid"

        # Check WiFi enabled
        local wifi_enabled
        wifi_enabled=$(grep "wlan0.enabled" "$nb_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$wifi_enabled" ] && add_sysinfo "wifi_enabled" "$wifi_enabled"

        # Check InterfaceSelectionManager
        local ism_enable
        ism_enable=$(grep "interfaceSelectionManager.enable" "$nb_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$ism_enable" ] && add_sysinfo "ism_enabled" "$ism_enable"

        local ism_ping
        ism_ping=$(grep "availabilityChecker.ping" "$nb_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$ism_ping" ] && add_sysinfo "ism_ping_url" "$ism_ping"
    fi

    # ─── ChargerApp Config ───
    local ca_props="$props_dir/ChargerApp.props"
    [ -f "$ca_props" ] || ca_props="$props_dir/ChargerAppConfig.props"
    if [ -f "$ca_props" ]; then
        local unlock_on_disc
        unlock_on_disc=$(grep "UnlockConnectorOnEVSideDisconnect" "$ca_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$unlock_on_disc" ] && add_sysinfo "unlock_on_disconnect" "$unlock_on_disc"

        local digital_timeout
        digital_timeout=$(grep "digitalCommunicationTimeout_ms" "$ca_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$digital_timeout" ] && add_sysinfo "v2g_digital_timeout_ms" "$digital_timeout"

        local prolonged_suspended
        prolonged_suspended=$(grep "prolongedSuspendedPeriod_ms" "$ca_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$prolonged_suspended" ] && add_sysinfo "prolonged_suspended_ms" "$prolonged_suspended"

        # Check ErrorBoss integration
        local eb_enabled
        eb_enabled=$(grep "Communication.ErrorBoss" "$ca_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$eb_enabled" ] && add_sysinfo "error_boss_enabled" "$eb_enabled"
    fi

    # ─── OCPP Config ───
    local ocpp_props="$props_dir/ocpp-cmd.props"
    if [ -f "$ocpp_props" ]; then
        local cp_id
        cp_id=$(grep "cp.id\|chargePointId" "$ocpp_props" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' ')
        [ -n "$cp_id" ] && add_sysinfo "ocpp_cp_id" "$cp_id"

        local tls_mode
        tls_mode=$(grep "verificationMode" "$ocpp_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$tls_mode" ] && add_sysinfo "ocpp_tls_mode" "$tls_mode"

        local offline_timeout
        offline_timeout=$(grep "OfflineTimeout_s" "$ocpp_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        [ -n "$offline_timeout" ] && add_sysinfo "ocpp_offline_timeout" "$offline_timeout"
    fi

    # Count total config keys
    local total_keys=0
    for f in "$props_dir"/*.props; do
        [ -f "$f" ] || continue
        local k
        k=$(wc -l < "$f" | tr -d ' ')
        total_keys=$((total_keys + k))
    done
    add_metric "config_keys_total" "$total_keys"

    # ─── Config Validation (Layer 4 source-informed) ────────────────────
    # Validate critical config values against known ranges from product configs
    log_verbose "Validating config values against Layer 4 known ranges..."
    local cfg_warnings=0 cfg_warn_list=""

    # NetworkBoss critical settings
    local nb_props="$props_dir/NetworkBoss.props"
    [ -f "$nb_props" ] || nb_props="$props_dir/NetworkBossConfig.props"
    if [ -f "$nb_props" ]; then
        # Check interfaceSelectionManager.enable (should be true for failover)
        local ism_en
        ism_en=$(grep "interfaceSelectionManager.enable" "$nb_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        if [ "$ism_en" = "false" ]; then
            cfg_warnings=$((cfg_warnings + 1))
            cfg_warn_list="${cfg_warn_list}interfaceSelectionManager.enable=false (no automatic WAN failover); "
        fi

        # Check ppp0.enabled
        local ppp_en
        ppp_en=$(grep "ppp0.enabled" "$nb_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        local eth_en
        eth_en=$(grep "eth0.enabled" "$nb_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        if [ "$ppp_en" = "false" ] && [ "$eth_en" = "false" ]; then
            cfg_warnings=$((cfg_warnings + 1))
            cfg_warn_list="${cfg_warn_list}Both ppp0 and eth0 disabled (no WAN connectivity); "
        fi
    fi

    # ChargerApp critical settings
    local ca_props="$props_dir/ChargerApp.props"
    [ -f "$ca_props" ] || ca_props="$props_dir/ChargerAppConfig.props"
    if [ -f "$ca_props" ]; then
        # digitalCommunicationTimeout_ms (default 50000, too low causes V2G failures)
        local dct
        dct=$(grep "digitalCommunicationTimeout_ms" "$ca_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        if [ -n "$dct" ] && [ "$(safe_int "$dct")" -lt 20000 ]; then
            cfg_warnings=$((cfg_warnings + 1))
            cfg_warn_list="${cfg_warn_list}digitalCommunicationTimeout_ms=$dct (too low, default 50000, may cause V2G timeouts); "
        fi

        # Meter.preferred.disableChargingOnAbsence
        local meter_disable
        meter_disable=$(grep "disableChargingOnAbsence" "$ca_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        if [ "$meter_disable" = "true" ]; then
            add_sysinfo "meter_blocks_on_absence" "true"
        fi
    fi

    # OCPP critical settings
    local ocpp_props="$props_dir/ocpp-cmd.props"
    if [ -f "$ocpp_props" ]; then
        # CS URL should not be empty or default
        local cs_url
        cs_url=$(grep "csUrl" "$ocpp_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        if [ -z "$cs_url" ] || [ "$cs_url" = "ws://localhost" ] || [ "$cs_url" = "wss://example.com" ]; then
            cfg_warnings=$((cfg_warnings + 1))
            cfg_warn_list="${cfg_warn_list}OCPP csUrl not configured or default value ('$cs_url'); "
        fi

        # OfflineTimeout_s (0 = infinite, very large may cause stale queues)
        local offline_to
        offline_to=$(grep "OfflineTimeout_s" "$ocpp_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        if [ -n "$offline_to" ] && [ "$(safe_int "$offline_to")" -gt 604800 ]; then
            cfg_warnings=$((cfg_warnings + 1))
            cfg_warn_list="${cfg_warn_list}OCPP OfflineTimeout_s=$offline_to (>7 days, may cause stale offline queue); "
        fi
    fi

    # CertManager settings
    local cert_props="$props_dir/CertManager.props"
    [ -f "$cert_props" ] || cert_props="$props_dir/CertManagerConfig.props"
    if [ -f "$cert_props" ]; then
        # ResponseTimeout (default 30s, too low causes V2G cert install failures)
        local cert_to
        cert_to=$(grep "ResponseTimeout" "$cert_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        if [ -n "$cert_to" ] && [ "$(safe_int "$cert_to")" -lt 10 ]; then
            cfg_warnings=$((cfg_warnings + 1))
            cfg_warn_list="${cfg_warn_list}CertManager ResponseTimeout=$cert_to (too low, default 30, may cause cert failures); "
        fi
    fi

    # HealthMonitor settings
    local hm_props="$props_dir/iotc-health-monitor.props"
    [ -f "$hm_props" ] || hm_props="$props_dir/HealthMonitor.props"
    if [ -f "$hm_props" ]; then
        # emmcWearingCheckEnabled (should be true)
        local emmc_en
        emmc_en=$(grep "emmcWearingCheckEnabled" "$hm_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        if [ "$emmc_en" = "false" ]; then
            cfg_warnings=$((cfg_warnings + 1))
            cfg_warn_list="${cfg_warn_list}emmcWearingCheckEnabled=false (eMMC wear monitoring disabled); "
        fi

        # watchdog.enabled (should be true for auto-recovery)
        local wd_en
        wd_en=$(grep "watchdog.enabled" "$hm_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        if [ "$wd_en" = "false" ]; then
            cfg_warnings=$((cfg_warnings + 1))
            cfg_warn_list="${cfg_warn_list}watchdog.enabled=false (no automatic reboot on hang); "
        fi
    fi

    # EnergyManager settings
    local em_props="$props_dir/EnergyManager.props"
    [ -f "$em_props" ] || em_props="$props_dir/EnergyManagerConfig.props"
    if [ -f "$em_props" ]; then
        # powerLimitEnabled (must be true for grid compliance)
        local pl_en
        pl_en=$(grep "powerLimitEnabled\|powerLimit.enabled" "$em_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        if [ "$pl_en" = "false" ]; then
            cfg_warnings=$((cfg_warnings + 1))
            cfg_warn_list="${cfg_warn_list}EnergyManager powerLimitEnabled=false (no grid power limit enforcement); "
        fi
    fi

    # Monit check intervals (properties or monit.d config)
    local monit_props="$props_dir/monit.props"
    if [ -f "$monit_props" ]; then
        local monit_interval
        monit_interval=$(grep "cycle" "$monit_props" 2>/dev/null | grep -oE '[0-9]+' | head -1)
        if [ -n "$monit_interval" ] && [ "$(safe_int "$monit_interval")" -gt 120 ]; then
            cfg_warnings=$((cfg_warnings + 1))
            cfg_warn_list="${cfg_warn_list}Monit check cycle=${monit_interval}s (>120s, slow failure detection); "
        fi
    fi

    # V2G / HLC timeout
    local hlc_props="$props_dir/evplccom.props"
    [ -f "$hlc_props" ] || hlc_props="$props_dir/HLCStateMachine.props"
    if [ -f "$hlc_props" ]; then
        # SECCRequestTimeoutAfterPause_ms (default 60000)
        local secc_to
        secc_to=$(grep "SECCRequestTimeoutAfterPause" "$hlc_props" 2>/dev/null | cut -d= -f2- | tr -d ' ')
        if [ -n "$secc_to" ] && [ "$(safe_int "$secc_to")" -lt 10000 ]; then
            cfg_warnings=$((cfg_warnings + 1))
            cfg_warn_list="${cfg_warn_list}SECCRequestTimeoutAfterPause=$secc_to (too low, default 60000, may cause V2G resume failures); "
        fi
    fi

    add_metric "config_warnings" "$cfg_warnings"

    # ─── Unknown / Extra Keys Detection ──────────────────────────────────────
    # Detect keys present in .props files that are not in the known-good set.
    # This catches typos, leftover debug keys, or unsupported overrides.
    # Uses a single awk pass per file instead of per-key grep spawns.
    local unknown_keys=0 unknown_key_list=""
    local _known_keys_re="connectionMonitor\.|amazonConnection\.|mqtt\.|ppp0\.|eth0\.|wlan0|lte\.|interfaceSelectionManager\.|availabilityChecker\.|UnlockConnector|digitalCommunicationTimeout|prolongedSuspended|Communication\.|Meter\.|csUrl|cp\.id|chargePointId|verificationMode|OfflineTimeout|TxnExtendedTrigger|powerLimit|powerImbalance|SECCRequestTimeout|cycle"
    local propfile
    for propfile in "$props_dir"/*.props; do
        [ -f "$propfile" ] || continue
        local fn; fn=$(basename "$propfile")
        local result
        result=$(awk -F= -v pat="$_known_keys_re" -v fn="$fn" '
            /^#/ || /^[[:space:]]*$/ { next }
            {
                key = $1
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                if (key == "") next
                if (key !~ pat) {
                    count++
                    list = list fn ":" key "; "
                }
            }
            END { printf "%d\t%s", count+0, list }
        ' "$propfile" 2>/dev/null)
        local file_unknown="${result%%	*}"
        local file_list="${result#*	}"
        unknown_keys=$((unknown_keys + $(safe_int "$file_unknown")))
        unknown_key_list="${unknown_key_list}${file_list}"
    done
    if [ "$unknown_keys" -gt 0 ]; then
        cfg_warnings=$((cfg_warnings + 1))
        # Truncate key list — show first 10 samples, not all 1000+
        local sample_list
        sample_list=$(printf '%s' "$unknown_key_list" | tr ';' '\n' | head -10 | tr '\n' ';' | sed 's/;$//')
        local shown=10
        if [ "$unknown_keys" -le "$shown" ]; then
            cfg_warn_list="${cfg_warn_list}${unknown_keys} unrecognized config key(s): ${sample_list}"
        else
            cfg_warn_list="${cfg_warn_list}${unknown_keys} unrecognized config key(s) (showing first ${shown}): ${sample_list}; ... and $((unknown_keys - shown)) more"
        fi
        add_metric "config_unknown_keys" "$unknown_keys"
    fi
    # ─────────────────────────────────────────────────────────────────────────

    if [ "$cfg_warnings" -gt 0 ]; then
        local sev="LOW"
        [ "$cfg_warnings" -gt 3 ] && sev="MEDIUM"
        add_issue "$sev" "Config/Validation" "Configuration Warnings ($cfg_warnings)"             "Config validation found $cfg_warnings issue(s): $cfg_warn_list" ""
    fi
    return 0
}

# ─── 2.5: System Info Extraction ────────────────────────────────────────────
_extract_system_info() {
    log_verbose "Extracting system information..."

    local info_parsed="$WORK_DIR/info_commands.parsed"
    if [ -f "$info_parsed" ]; then
        while IFS='|' read -r cmd val; do
            case "$cmd" in
                "cat /proc/meminfo")
                    # Extract MemTotal from multiline
                    local memtotal
                    memtotal=$(echo "$val" | grep -o "MemTotal:[[:space:]]*[0-9]* kB" | awk '{print $2}')
                    [ -n "$memtotal" ] && add_sysinfo "mem_total_kb" "$memtotal"
                    ;;
                "cat /proc/cmdline")
                    add_sysinfo "boot_cmdline" "$val"
                    local slot
                    slot=$(echo "$val" | grep -o 'rauc.slot=[A-Z]' | cut -d= -f2)
                    [ -n "$slot" ] && add_sysinfo "boot_slot" "$slot"
                    ;;
                "get_devid")
                    [ -z "$DEVICE_ID" ] || [ "$DEVICE_ID" = "unknown" ] && DEVICE_ID="$val" && add_sysinfo "device_id" "$val"
                    ;;
            esac
        done < "$info_parsed"
    fi

    # Memory info from info_commands.txt directly
    local info_raw
    info_raw=$(get_log_file "info_commands")
    if [ -n "$info_raw" ] && [ -f "$info_raw" ]; then
        local memtotal memfree memavail
        memtotal=$(grep "MemTotal:" "$info_raw" 2>/dev/null | awk '{print $2}')
        memfree=$(grep "MemFree:" "$info_raw" 2>/dev/null | awk '{print $2}')
        memavail=$(grep "MemAvailable:" "$info_raw" 2>/dev/null | awk '{print $2}')
        [ -n "$memtotal" ] && add_sysinfo "mem_total_kb" "$memtotal"
        [ -n "$memfree" ] && add_sysinfo "mem_free_kb" "$memfree"
        [ -n "$memavail" ] && add_sysinfo "mem_available_kb" "$memavail"

        # SIM info
        local sim_info
        sim_info=$(grep -A2 "AT+CIMI|AT+CCID" "$info_raw" 2>/dev/null | grep "stdout:" | head -1 | sed 's/stdout: //')
        [ -n "$sim_info" ] && [ "$sim_info" != " " ] && add_sysinfo "sim_info" "$sim_info"
    fi

    # Version info from versions.json
    local ver_file
    ver_file=$(get_log_file "versions_json")
    if [ -n "$ver_file" ] && [ -f "$ver_file" ]; then
        local release scope artifact
        release=$(grep '"ReleaseVersion"' "$ver_file" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/')
        scope=$(grep '"Scope"' "$ver_file" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/')
        artifact=$(grep '"ArtifactVersion"' "$ver_file" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/')
        [ -n "$release" ] && add_sysinfo "release_version" "$release"
        [ -n "$scope" ] && add_sysinfo "scope" "$scope"
        [ -n "$artifact" ] && add_sysinfo "artifact_version" "$artifact"
    fi

    # Build info
    local build_file
    build_file=$(get_log_file "build_info")
    if [ -n "$build_file" ] && [ -f "$build_file" ]; then
        local build_info
        build_info=$(cat "$build_file" 2>/dev/null)
        [ -n "$build_info" ] && add_sysinfo "build_info" "$build_info"
    fi

    # Component versions from log headers
    _extract_component_versions
}

_extract_component_versions() {
    # Extract version strings from log file headers (IoTecha apps print version at startup)
    local parsed_dir="$WORK_DIR/parsed"
    for f in "$parsed_dir"/*.parsed; do
        [ -f "$f" ] || continue
        [[ "$(basename "$f")" == *_full.parsed ]] && continue
        local comp
        comp=$(basename "$f" .parsed)

        # Look for version lines
        local ver
        ver=$(grep -m1 "version:|Version:" "$f" 2>/dev/null | grep -o '[Ss]b-v[^ ]*|v[0-9][^ ]*' | head -1)
        [ -n "$ver" ] && add_sysinfo "ver_${comp}" "$ver"
    done
    return 0
}

# ─── 2.6: Timeline Builder ──────────────────────────────────────────────────
_build_timeline() {
    log_verbose "Building event timeline..."

    local parsed_dir="$WORK_DIR/parsed"
    local raw_timeline="$TIMELINE_FILE.raw"

    # Build list of components that have dedicated parsed files (not syslog/kern)
    local known_comps=""
    for f in "$parsed_dir"/*.parsed; do
        [ -f "$f" ] || continue
        local bn
        bn=$(basename "$f" .parsed)
        [[ "$bn" == *_full ]] && continue
        [[ "$bn" == "syslog" || "$bn" == "kern" ]] && continue
        known_comps="$known_comps $bn"
    done

    # Collect significant events from all parsed logs
    for f in "$parsed_dir"/*.parsed; do
        [ -f "$f" ] || continue
        [[ "$(basename "$f")" == *_full.parsed ]] && continue

        local src
        src=$(basename "$f" .parsed)

        # For syslog/kern: skip entries whose component matches a dedicated parsed file
        # This prevents duplicate hmi-boss, NetworkBoss, etc. entries
        if [[ "$src" == "syslog" || "$src" == "kern" ]]; then
            awk -F'|' -v comps="$known_comps" '
            BEGIN {
                n = split(comps, arr, " ")
                for (i = 1; i <= n; i++) {
                    # Match component name at start of field 3 (e.g. "hmi-boss[2054]" matches "HMIBoss")
                    lc = tolower(arr[i])
                    known[lc] = 1
                }
            }
            $2 == "E" || $2 == "W" || $2 == "C" {
                # Extract process name from component field (strip [pid])
                comp = $3
                sub(/\[.*/, "", comp)
                lc_comp = tolower(comp)
                # Skip if this process has a dedicated parsed file
                skip = 0
                for (k in known) {
                    # Fuzzy match: hmi-boss → hmiboss, network-boss → networkboss
                    test_comp = lc_comp
                    gsub(/-/, "", test_comp)
                    if (test_comp == k || index(k, test_comp) || index(test_comp, k)) {
                        skip = 1; break
                    }
                }
                if (skip) next

                sev = "INFO"
                if ($2 == "E") sev = "HIGH"
                if ($2 == "C") sev = "CRITICAL"
                if ($2 == "W") sev = "MEDIUM"
                ts = $1
                msg = $4
                if (ts ~ /^0000-00-00/) {
                    if (match(msg, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
                        ts = substr(msg, RSTART, RLENGTH) ".000"
                        sub(/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}[.0-9]* */, "", msg)
                    } else next
                }
                printf "%s\t%s\t%s\t%s\n", ts, sev, $3, msg
            }
            ' "$f" >> "$raw_timeline"
        else
            awk -F'|' '
            $2 == "E" || $2 == "W" || $2 == "C" {
                sev = "INFO"
                if ($2 == "E") sev = "HIGH"
                if ($2 == "C") sev = "CRITICAL"
                if ($2 == "W") sev = "MEDIUM"
                ts = $1
                msg = $4
                comp = $3

                # Handle 0000-00-00 timestamps: extract real ts from message
                if (ts ~ /^0000-00-00/) {
                    if (match(msg, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
                        ts = substr(msg, RSTART, RLENGTH) ".000"
                        # Strip embedded timestamp (+optional ms) from message
                        sub(/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}[.0-9]* */, "", msg)
                    } else next
                }

                # If component is "generic", extract real name from [ComponentName]
                if (comp == "generic" && match(msg, /\[([A-Za-z][A-Za-z0-9_-]+)\]/)) {
                    comp = substr(msg, RSTART+1, RLENGTH-2)
                }

                # Strip leading [ComponentName] tag from message (now redundant)
                sub(/^\[[A-Za-z][A-Za-z0-9_ -]+\] */, "", msg)
                # Strip log-level prefix: [ERROR], [WARNING], etc.
                sub(/^\[(ERROR|WARNING|WARN|INFO|DEBUG|CRITICAL)\] */, "", msg)

                printf "%s\t%s\t%s\t%s\n", ts, sev, comp, msg
            }
            ' "$f" >> "$raw_timeline"
        fi
    done

    # Add boot events from syslog
    local syslog_parsed="$parsed_dir/syslog.parsed"
    if [ -f "$syslog_parsed" ]; then
        grep "Booting Linux|Linux version" "$syslog_parsed" 2>/dev/null | \
        awk -F'|' '{printf "%s\tINFO\tkernel\tSystem boot: %s\n", $1, $4}' >> "$raw_timeline"
    fi

    # Sort by timestamp, then deduplicate in two passes:
    # Pass 1: Collapse consecutive identical (normalized) messages
    # Pass 2: Global collapse — merge non-consecutive identical messages
    if [ -s "$raw_timeline" ]; then
        local dedup1="$TIMELINE_FILE.dedup1"

        # Pass 1: Sort by timestamp then consecutive dedup with normalization
        # Use awk_sort_tsv (pure awk) to avoid /usr/bin/sort permission issues on MSYS2
        local sorted_timeline="$raw_timeline.sorted"
        awk_sort_tsv "$raw_timeline" > "$sorted_timeline"
        awk -F'\t' '
        {
            # Normalize message for dedup:
            # 1. Strip numbers 3+ digits (timeout ms, PIDs, etc.)
            # 2. Strip hex codes (0x...)
            # 3. Strip JWT/base64 tokens
            # 4. Collapse whitespace
            norm = $4
            gsub(/[0-9]{3,}/, "N", norm)
            gsub(/0x[0-9a-fA-F]+/, "0xH", norm)
            gsub(/[A-Za-z0-9_-]{40,}[.][A-Za-z0-9_-]{20,}[.][A-Za-z0-9_=-]{20,}/, "JWT", norm)
            gsub(/[A-Za-z0-9+\/=]{32,}/, "B64", norm)
            gsub(/[[:space:]]+/, " ", norm)

            key = $2 FS $3 FS norm
            if (key == prev_key) { dup_count++; last_ts = $1; next }
            if (NR > 1 && prev_key != "") {
                if (dup_count > 0)
                    printf "%s\t%s\t%s\t%s (x%d, last: %s)\n", first_ts, prev_sev, prev_comp, prev_msg, dup_count+1, last_ts
                else
                    printf "%s\t%s\t%s\t%s\n", first_ts, prev_sev, prev_comp, prev_msg
            }
            first_ts = $1; last_ts = $1
            prev_key = key; prev_sev = $2; prev_comp = $3; prev_msg = $4
            dup_count = 0
        }
        END {
            if (prev_key != "") {
                if (dup_count > 0)
                    printf "%s\t%s\t%s\t%s (x%d, last: %s)\n", first_ts, prev_sev, prev_comp, prev_msg, dup_count+1, last_ts
                else
                    printf "%s\t%s\t%s\t%s\n", first_ts, prev_sev, prev_comp, prev_msg
            }
        }
        ' "$sorted_timeline" > "$dedup1"
        rm -f "$sorted_timeline"

        # Pass 2: Global dedup — merge repeated messages that weren't consecutive
        # Groups by normalized key, keeps first occurrence, sums counts
        awk -F'\t' '
        {
            norm = $4
            gsub(/[0-9]{3,}/, "N", norm)
            gsub(/0x[0-9a-fA-F]+/, "0xH", norm)
            gsub(/[A-Za-z0-9_-]{40,}[.][A-Za-z0-9_-]{20,}[.][A-Za-z0-9_=-]{20,}/, "JWT", norm)
            gsub(/[A-Za-z0-9+\/=]{32,}/, "B64", norm)
            gsub(/ \(x[0-9]+, last: [^)]+\)/, "", norm)
            gsub(/[[:space:]]+/, " ", norm)
            key = $2 FS $3 FS norm

            if (!(key in first_line)) {
                first_line[key] = NR
                order[++idx] = key
                first_ts[key] = $1
                sev[key] = $2
                comp[key] = $3
                # Store message without existing count suffix
                msg[key] = $4
                sub(/ \(x[0-9]+, last: [^)]+\)/, "", msg[key])
                count[key] = 1
                last_ts[key] = $1
            } else {
                count[key]++
                last_ts[key] = $1
            }
            # Extract existing count if present (from pass 1)
            if ($4 ~ /\(x[0-9]+, last:/) {
                # Parse count from "(xN, last: ...)" suffix
                tmp = $4
                sub(/.*\(x/, "", tmp)
                sub(/,.*/, "", tmp)
                extra = int(tmp) - 1  # Already counted 1 above
                if (extra > 0) count[key] += extra
            }
        }
        END {
            for (i = 1; i <= idx; i++) {
                k = order[i]
                if (count[k] > 1)
                    printf "%s\t%s\t%s\t%s (x%d, last: %s)\n", first_ts[k], sev[k], comp[k], msg[k], count[k], last_ts[k]
                else
                    printf "%s\t%s\t%s\t%s\n", first_ts[k], sev[k], comp[k], msg[k]
            }
        }
        ' "$dedup1" > "$TIMELINE_FILE"

        rm -f "$raw_timeline" "$dedup1"
    else
        : > "$TIMELINE_FILE"
    fi

    local event_count
    event_count=$(wc -l < "$TIMELINE_FILE" | tr -d ' ')
    add_metric "timeline_events" "$event_count"
    log_verbose "Timeline: $event_count events"
}

# ─── 2.7: Issue Aggregator ──────────────────────────────────────────────────
_aggregate_issues() {
    log_verbose "Aggregating issues..."

    # Clean: remove lines without valid severity prefix (corruption guard)
    if [ -s "$ISSUES_FILE" ]; then
        awk -F'\t' '$1 ~ /^(CRITICAL|HIGH|MEDIUM|LOW|INFO)$/' "$ISSUES_FILE" > "$ISSUES_FILE.clean" 2>/dev/null
        if [ -s "$ISSUES_FILE.clean" ]; then
            mv "$ISSUES_FILE.clean" "$ISSUES_FILE"
        else
            rm -f "$ISSUES_FILE.clean"
        fi
    fi

    # Sort issues by severity (CRITICAL first) — pure awk, no external sort
    if [ -s "$ISSUES_FILE" ]; then
        awk -F'\t' -v OFS='\t' '
        BEGIN { order["CRITICAL"]=1; order["HIGH"]=2; order["MEDIUM"]=3; order["LOW"]=4; order["INFO"]=5 }
        {
            prio = order[$1]+0; if (prio == 0) prio = 9
            keys[NR] = prio; lines[NR] = $0; n = NR
        }
        END {
            for (i = 2; i <= n; i++) {
                key = keys[i]; line = lines[i]; j = i - 1
                while (j > 0 && keys[j] > key) {
                    keys[j+1] = keys[j]; lines[j+1] = lines[j]; j--
                }
                keys[j+1] = key; lines[j+1] = line
            }
            for (i = 1; i <= n; i++) print lines[i]
        }' "$ISSUES_FILE" > "$ISSUES_FILE.tmp"
        if [ -s "$ISSUES_FILE.tmp" ]; then
            mv "$ISSUES_FILE.tmp" "$ISSUES_FILE"
        else
            rm -f "$ISSUES_FILE.tmp"
        fi
    fi

    # Store counts
    add_metric "issues_critical" "$(issue_count_by_severity CRITICAL)"
    add_metric "issues_high" "$(issue_count_by_severity HIGH)"
    add_metric "issues_medium" "$(issue_count_by_severity MEDIUM)"
    add_metric "issues_low" "$(issue_count_by_severity LOW)"
    add_metric "issues_total" "$(issue_count)"
}

# ─── 2.8: Status Summary ────────────────────────────────────────────────────
_build_status_summary() {
    log_verbose "Building status summary..."

    local status_file="$WORK_DIR/status.dat"
    : > "$status_file"

    # Determine subsystem status based on findings
    # MQTT/Cloud
    local mqtt_status="unknown"
    local mqtt_fails
    mqtt_fails=$(safe_int "$(get_metric "i2p2_backoff_count")")
    if grep -qE "MQTT Connection Failure" "$ISSUES_FILE" 2>/dev/null; then
        mqtt_status="down"
    elif [ "$mqtt_fails" -gt 0 ]; then
        mqtt_status="degraded"
    else
        mqtt_status="up"
    fi
    printf "%s\t%s\n" "MQTT" "$mqtt_status" >> "$status_file"

    # OCPP
    local ocpp_status="unknown"
    if [ "$(safe_int "$(get_metric ocpp_ws_connected)")" -gt 0 ]; then
        ocpp_status="up"
    fi
    printf "%s\t%s\n" "OCPP" "$ocpp_status" >> "$status_file"

    # PPP/Cellular
    local ppp_status="unknown"
    if grep -qE "PPP.*Never Established|PPP.*Connection Never" "$ISSUES_FILE" 2>/dev/null; then
        ppp_status="down"
    else
        ppp_status="up"
    fi
    printf "%s\t%s\n" "PPP" "$ppp_status" >> "$status_file"

    # Ethernet
    local eth_status="up"
    local flaps
    flaps=$(safe_int "$(get_metric "eth_flap_cycles")")
    if [ "$flaps" -gt 2 ]; then
        eth_status="degraded"
    fi
    printf "%s\t%s\n" "Ethernet" "$eth_status" >> "$status_file"

    # WiFi
    local wifi_conns
    wifi_conns=$(safe_int "$(get_metric wifi_connections)")
    printf "%s\t%s\n" "WiFi" "$([ "$wifi_conns" -gt 0 ] && echo up || echo unknown)" >> "$status_file"

    # Certificates
    local cert_status="up"
    local cert_fails
    cert_fails=$(safe_int "$(get_metric cert_load_failures)")
    [ "$cert_fails" -gt 0 ] && cert_status="degraded"
    printf "%s\t%s\n" "Certs" "$cert_status" >> "$status_file"

    # Power Board
    local pb_status="up"
    grep -qE "Power Board Fault" "$ISSUES_FILE" 2>/dev/null && pb_status="degraded"
    printf "%s\t%s\n" "PowerBoard" "$pb_status" >> "$status_file"

    add_metric "status_summary_done" "1"
}

# ─── Display Analysis Results ────────────────────────────────────────────────
show_analysis_results() {
    print_header "$ANALYZER_NAME — Analysis Results"
    print_kv "Device" "IOTMP${DEVICE_ID}"
    print_kv "Firmware" "$FW_VERSION"
    print_kv "Analysis Mode" "$ANALYSIS_MODE"
    echo ""

    # Health score
    display_health_score

    # Status dashboard
    _show_status_dashboard

    # Issues
    _show_issues

    # Timeline summary
    _show_timeline_summary
}

_show_status_dashboard() {
    print_section "Subsystem Status"

    local status_file="$WORK_DIR/status.dat"
    [ -f "$status_file" ] || return

    while IFS=$'\t' read -r name status; do
        printf "  "
        print_status_icon "$status"
        printf " %-14s %s\n" "$name" "$(echo "$status" | tr '[:lower:]' '[:upper:]')"
    done < "$status_file"
    echo ""
}

_show_issues() {
    local total
    total=$(issue_count)
    local crit high med low
    crit=$(issue_count_by_severity CRITICAL)
    high=$(issue_count_by_severity HIGH)
    med=$(issue_count_by_severity MEDIUM)
    low=$(issue_count_by_severity LOW)

    print_section "Issues ($total found)"
    printf "  "
    [ "$crit" -gt 0 ] && printf "%s%d Critical%s  " "${RED}${BLD}" "$crit" "${RST}"
    [ "$high" -gt 0 ] && printf "%s%d High%s  " "${RED}" "$high" "${RST}"
    [ "$med" -gt 0 ] && printf "%s%d Medium%s  " "${YLW}" "$med" "${RST}"
    [ "$low" -gt 0 ] && printf "%s%d Low%s  " "${GRN}" "$low" "${RST}"
    echo ""

    local idx=0
    while IFS=$'\t' read -r sev comp title desc ev_file; do
        idx=$((idx + 1))
        printf "\n  %s#%d%s " "${BLD}" "$idx" "${RST}"
        print_badge "$sev"
        printf " %s%s%s\n" "${BLD}" "$title" "${RST}"
        printf "     %sComponent:%s %s\n" "${GRY}" "${RST}" "$comp"
        printf "     %s\n" "$desc"

        # Show evidence if available and not in quiet mode
        if [ -n "$ev_file" ] && [ -f "$ev_file" ] && [ "$QUIET_MODE" -eq 0 ]; then
            display_evidence "$ev_file" 12
        fi
    done < "$ISSUES_FILE"
    echo ""
}

_show_timeline_summary() {
    local event_count
    event_count=$(wc -l < "$TIMELINE_FILE" 2>/dev/null | tr -d ' ')

    print_section "Timeline ($event_count events)"

    # Show first and last timestamps
    local first_ts last_ts
    first_ts=$(head -1 "$TIMELINE_FILE" 2>/dev/null | cut -f1)
    last_ts=$(tail -1 "$TIMELINE_FILE" 2>/dev/null | cut -f1)

    if [ -n "$first_ts" ] && [ -n "$last_ts" ]; then
        print_kv "Time range" "${first_ts} → ${last_ts}"

        local start_epoch end_epoch
        start_epoch=$(safe_int "$(ts_to_epoch "$first_ts")")
        end_epoch=$(safe_int "$(ts_to_epoch "$last_ts")")
        if [ "$start_epoch" -gt 0 ] && [ "$end_epoch" -gt 0 ]; then
            local dur=$((end_epoch - start_epoch))
            print_kv "Duration" "$(format_duration $dur)"
        fi
    fi

    # Show recent critical events
    local crits
    crits=$(awk -F'\t' '$2=="CRITICAL"' "$TIMELINE_FILE" 2>/dev/null | tail -5)
    if [ -n "$crits" ]; then
        printf "\n  %sRecent critical events:%s\n" "${RED}" "${RST}"
        echo "$crits" | while IFS=$'\t' read -r ts sev comp msg; do
            printf "    %s%s%s %s%s%s: %s\n" "${GRY}" "$ts" "${RST}" "${RED}" "$comp" "${RST}" "$msg"
        done
    fi
    echo ""
}
