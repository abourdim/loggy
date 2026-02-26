#!/bin/bash
# analyzer_deep.sh — Deep Analysis Engine
# Loggy v6.0 — Phase 6
#
# Forensic-level analysis: causal chains, boot timing, gap detection,
# config validation, error rate histograms, and PMQ interaction mapping.

# ─── Main Entry ──────────────────────────────────────────────────────────────
run_deep_analysis() {
    log_info "Starting deep analysis..."
    local _DSTEP=0 _DTOTAL=10

    _DSTEP=$((_DSTEP+1)); progress_step $_DSTEP $_DTOTAL "Boot Timing"
    _deep_boot_timing
    log_debug "Deep: boot timing complete"

    _DSTEP=$((_DSTEP+1)); progress_step $_DSTEP $_DTOTAL "Causal Chains"
    _deep_causal_chains
    log_debug "Deep: causal chains complete"

    _DSTEP=$((_DSTEP+1)); progress_step $_DSTEP $_DTOTAL "Gap Detection"
    _deep_gap_detection
    log_debug "Deep: gap detection complete"

    _DSTEP=$((_DSTEP+1)); progress_step $_DSTEP $_DTOTAL "Config Validation"
    _deep_config_validation
    log_debug "Deep: config validation complete"

    _DSTEP=$((_DSTEP+1)); progress_step $_DSTEP $_DTOTAL "Error Histogram"
    _deep_error_histogram
    log_debug "Deep: error histogram complete"

    _DSTEP=$((_DSTEP+1)); progress_step $_DSTEP $_DTOTAL "PMQ Map"
    _deep_pmq_map
    log_debug "Deep: PMQ map complete"

    _DSTEP=$((_DSTEP+1)); progress_step $_DSTEP $_DTOTAL "Charging Sessions"
    _deep_charging_sessions
    log_debug "Deep: charging sessions complete"

    _DSTEP=$((_DSTEP+1)); progress_step $_DSTEP $_DTOTAL "Reboot Timeline"
    _deep_reboot_timeline
    log_debug "Deep: reboot timeline complete"

    _DSTEP=$((_DSTEP+1)); progress_step $_DSTEP $_DTOTAL "Connectivity"
    _deep_connectivity
    log_debug "Deep: connectivity complete"

    _DSTEP=$((_DSTEP+1)); progress_step $_DSTEP $_DTOTAL "State Machine"
    _deep_state_machine
    log_debug "Deep: state machine complete"

    # Summary
    local _s_boot _s_chains _s_gaps _s_sessions _s_reboots _s_conn _s_sm
    _s_boot=$(wc -l < "$WORK_DIR/deep_boot_timing.dat" 2>/dev/null | tr -d ' ')
    _s_chains=$(grep -c '^CHAIN' "$WORK_DIR/deep_causal.dat" 2>/dev/null)
    : "${_s_chains:=0}"
    _s_gaps=$(wc -l < "$WORK_DIR/deep_gaps.dat" 2>/dev/null | tr -d ' ')
    _s_sessions=$(wc -l < "$WORK_DIR/deep_sessions.dat" 2>/dev/null | tr -d ' ')
    _s_reboots=$(wc -l < "$WORK_DIR/deep_reboots.dat" 2>/dev/null | tr -d ' ')
    _s_conn=$(wc -l < "$WORK_DIR/deep_connectivity.dat" 2>/dev/null | tr -d ' ')
    _s_sm=$(wc -l < "$WORK_DIR/deep_state_machine.dat" 2>/dev/null | tr -d ' ')

    log_ok "Deep analysis complete"
    log_info "  Boot events: ${_s_boot:-0}  Causal chains: ${_s_chains:-0}  Gaps: ${_s_gaps:-0}"
    log_info "  Sessions: ${_s_sessions:-0}  Reboots: ${_s_reboots:-0}  Connectivity: ${_s_conn:-0}  SM transitions: ${_s_sm:-0}"
}

# ═══════════════════════════════════════════════════════════════════════════
# 6.2: Boot Timing Analysis
# ═══════════════════════════════════════════════════════════════════════════
_deep_boot_timing() {
    local outfile="$WORK_DIR/deep_boot_timing.dat"
    : > "$outfile"

    # Scan parsed logs for earliest timestamps per component
    local comp ts
    local boot_events=""

    # NetworkBoss init
    ts=$(grep -h 'NetworkBoss.*init\|Process.*reinit' "$WORK_DIR"/parsed/NetworkBoss.parsed 2>/dev/null | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\tNetworkBoss\tinit\tNetwork manager initialization\n" "$ts" >> "$outfile"

    # Modem init
    ts=$(grep -h 'Reinit modem\|modem.*init' "$WORK_DIR"/parsed/NetworkBoss.parsed 2>/dev/null | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\tNetworkBoss\tmodem\tModem initialization\n" "$ts" >> "$outfile"

    # SIM detection
    ts=$(grep -h 'SIM status\|PIN required\|ICCID' "$WORK_DIR"/parsed/NetworkBoss.parsed 2>/dev/null | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\tNetworkBoss\tSIM\tSIM card detected\n" "$ts" >> "$outfile"

    # Data channel
    ts=$(grep -h 'data channel done\|Channel initialization' "$WORK_DIR"/parsed/NetworkBoss.parsed 2>/dev/null | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\tNetworkBoss\tdata_channel\tData channel initialized\n" "$ts" >> "$outfile"

    # PPP attempt
    ts=$(grep -h 'pppd\|PPP.*start\|ppp0' "$WORK_DIR"/parsed/NetworkBoss.parsed 2>/dev/null | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\tNetworkBoss\tPPP\tPPP connection attempt\n" "$ts" >> "$outfile"

    # Ethernet link
    ts=$(grep -h 'eth0.*up\|Link is Up\|carrier' "$WORK_DIR"/parsed/NetworkBoss.parsed 2>/dev/null | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\tNetworkBoss\tEthernet\tEthernet link event\n" "$ts" >> "$outfile"

    # CertManager start
    ts=$(grep -h 'read slot\|cert-mgr.*start\|Initialize' "$WORK_DIR"/parsed/CertManager.parsed 2>/dev/null | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\tCertManager\tinit\tCertificate manager started\n" "$ts" >> "$outfile"

    # OCPP WebSocket
    ts=$(grep -h 'WebSocket\|WS.*connect\|ws://' "$WORK_DIR"/parsed/OCPP.parsed 2>/dev/null | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\tOCPP\twebsocket\tWebSocket connection attempt\n" "$ts" >> "$outfile"

    # OCPP BootNotification
    ts=$(grep -h 'BootNotif.*Call\|Sending Boot' "$WORK_DIR"/parsed/OCPP.parsed 2>/dev/null | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\tOCPP\tboot_notif\tBootNotification sent\n" "$ts" >> "$outfile"

    # OCPP BootNotification accepted
    ts=$(grep -h 'Accepted\|BootNotif.*Accepted\|status.*Accepted' "$WORK_DIR"/parsed/OCPP.parsed 2>/dev/null | grep -i 'boot\|accept' | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\tOCPP\tboot_accepted\tBootNotification accepted\n" "$ts" >> "$outfile"

    # MQTT/i2p2 connection
    ts=$(grep -h 'connect\|CONNECTED\|broker' "$WORK_DIR"/parsed/i2p2.parsed 2>/dev/null | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\ti2p2\tmqtt_connect\tMQTT broker connection\n" "$ts" >> "$outfile"

    # ChargerApp init
    ts=$(grep -h 'ChargerApp.*init\|Starting.*ChargerApp\|MainLoop' "$WORK_DIR"/parsed/ChargerApp.parsed 2>/dev/null | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\tChargerApp\tinit\tCharger application started\n" "$ts" >> "$outfile"

    # EnergyManager init
    ts=$(grep -h 'EnergyManager.*init\|Starting.*Energy\|pmq.*Register' "$WORK_DIR"/parsed/EnergyManager.parsed 2>/dev/null | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\tEnergyManager\tinit\tEnergy manager started\n" "$ts" >> "$outfile"

    # HealthMonitor init
    ts=$(grep -h 'HealthMonitor\|health.*monitor\|pmq.*Register' "$WORK_DIR"/parsed/HealthMonitor.parsed 2>/dev/null | head -1 | _extract_ts)
    [ -n "$ts" ] && printf "%s\tHealthMonitor\tinit\tHealth monitor started\n" "$ts" >> "$outfile"

    # Sort by timestamp using pure awk
    if [ -s "$outfile" ]; then
        awk_sort_tsv "$outfile" > "$outfile.sorted"
        mv "$outfile.sorted" "$outfile"
    fi

    # Calculate deltas between consecutive boot events
    local boot_delta_file="$WORK_DIR/deep_boot_deltas.dat"
    if [ -s "$outfile" ]; then
        awk -F'\t' '
        {
            ts = $1
            # Extract seconds from HH:MM:SS.mmm
            split(ts, parts, " ")
            split(parts[2], tparts, ":")
            secs = tparts[1]*3600 + tparts[2]*60
            split(tparts[3], sfrac, ".")
            secs += sfrac[1]
            if (sfrac[2] != "") secs += sfrac[2] / 1000

            if (NR > 1) {
                delta = secs - prev_secs
                if (delta < 0) delta += 86400  # day wrap
                printf "%s\t%s\t%s\t%.1f\t%s\n", $1, $2, $3, delta, $4
            } else {
                printf "%s\t%s\t%s\t0.0\t%s\n", $1, $2, $3, $4
            }
            prev_secs = secs
        }' "$outfile" > "$boot_delta_file"
    fi

    add_metric "deep_boot_events" "$(wc -l < "$outfile" 2>/dev/null | tr -d ' ')"
}

_extract_ts() {
    # Extract timestamp from parsed or raw log line
    # Parsed: "2026-02-18 15:21:47.153|I|Component|..."
    # Raw:    "2026-02-18 15:21:47.153 [I] ..."
    awk '{
        # Strip pipe-delimited suffix if present
        sub(/\|.*/, "", $2)
        if ($1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ && $2 ~ /^[0-9]{2}:/) {
            print $1 " " $2
        }
    }' | head -1
}

# ═══════════════════════════════════════════════════════════════════════════
# 6.1: Causal Chain Analysis
# ═══════════════════════════════════════════════════════════════════════════
_deep_causal_chains() {
    local outfile="$WORK_DIR/deep_causal.dat"
    : > "$outfile"

    # ─── Temporal validation helper ─────────────────────────────────────
    # _timeline_precedes PATTERN_A PATTERN_B
    # Returns 0 (true) if any timeline event matching A appears before any matching B.
    # Falls back to metric-only check if timeline is empty/missing.
    _timeline_precedes() {
        local pat_a="$1" pat_b="$2"
        [ -f "$TIMELINE_FILE" ] && [ -s "$TIMELINE_FILE" ] || return 0  # no timeline → assume true
        local line_a line_b
        line_a=$(grep -nm1 "$pat_a" "$TIMELINE_FILE" 2>/dev/null | head -1 | cut -d: -f1)
        line_b=$(grep -nm1 "$pat_b" "$TIMELINE_FILE" 2>/dev/null | head -1 | cut -d: -f1)
        [ -z "$line_a" ] || [ -z "$line_b" ] && return 0  # can't determine → assume true
        [ "$line_a" -le "$line_b" ]
    }

    # _timeline_gap_minutes PATTERN_A PATTERN_B
    # Returns the gap in minutes between first occurrence of A and first occurrence of B.
    # Returns 0 if cannot determine.
    _timeline_gap_minutes() {
        local pat_a="$1" pat_b="$2"
        [ -f "$TIMELINE_FILE" ] && [ -s "$TIMELINE_FILE" ] || { echo "0"; return; }
        local ts_a ts_b
        ts_a=$(grep -m1 "$pat_a" "$TIMELINE_FILE" 2>/dev/null | cut -f1 | head -1)
        ts_b=$(grep -m1 "$pat_b" "$TIMELINE_FILE" 2>/dev/null | cut -f1 | head -1)
        [ -z "$ts_a" ] || [ -z "$ts_b" ] && { echo "0"; return; }
        # Parse timestamps (YYYY-MM-DD HH:MM:SS or similar)
        local epoch_a epoch_b
        epoch_a=$(date -d "$ts_a" +%s 2>/dev/null || echo "0")
        epoch_b=$(date -d "$ts_b" +%s 2>/dev/null || echo "0")
        [ "$epoch_a" -eq 0 ] || [ "$epoch_b" -eq 0 ] && { echo "0"; return; }
        echo "$(( (epoch_b - epoch_a) / 60 ))"
    }

    # Chain 1: PPP failure → MQTT backoff → cloud disconnect → BootNotif fail
    local ppp_down mqtt_fail ocpp_fail
    ppp_down=$(type -t get_status &>/dev/null && get_status PPP || echo "unknown")
    mqtt_fail=$(safe_int "$(get_metric i2p2_mqtt_fail_count)")
    ocpp_fail=$(safe_int "$(get_metric ocpp_ws_failed)")
    local boot_rejected
    boot_rejected=$(($(safe_int "$(get_metric ocpp_boot_notif)") - $(safe_int "$(get_metric ocpp_boot_accepted)")))

    if [ "$ppp_down" = "down" ] && [ "$mqtt_fail" -gt 0 ]; then
        printf "CHAIN\tNetwork→Cloud Cascade\tCRITICAL\n" >> "$outfile"
        printf "CAUSE\tPPP/Cellular connection never established\n" >> "$outfile"
        printf "EFFECT\tNo backup WAN link available\n" >> "$outfile"
        [ "$mqtt_fail" -gt 0 ] && printf "EFFECT\tMQTT connection unstable (%d failures, falling back to Ethernet)\n" "$mqtt_fail" >> "$outfile"
        local backoff
        backoff=$(safe_int "$(get_metric i2p2_backoff_count)")
        [ "$backoff" -gt 0 ] && printf "EFFECT\tConnection backoff triggered %d times\n" "$backoff" >> "$outfile"
        [ "$boot_rejected" -gt 0 ] && printf "EFFECT\tOCPP BootNotification rejected/timeout %d times\n" "$boot_rejected" >> "$outfile"
        printf "ROOT\tCheck SIM card, APN configuration, modem hardware, cellular coverage\n" >> "$outfile"
        printf "%s\n" "---" >> "$outfile"
    fi

    # Chain 2: Ethernet flapping → stability checks → service disruption
    local eth_flaps
    eth_flaps=$(safe_int "$(get_metric eth_flap_cycles)")
    if [ "$eth_flaps" -gt 2 ]; then
        printf "CHAIN\tEthernet Instability Cascade\tHIGH\n" >> "$outfile"
        printf "CAUSE\tEthernet link flapping (%d cycles)\n" "$eth_flaps" >> "$outfile"
        printf "EFFECT\tNetwork stability checks triggered repeatedly\n" >> "$outfile"
        printf "EFFECT\tDNS resolution intermittent during flap events\n" >> "$outfile"
        printf "EFFECT\tOCPP/MQTT connections disrupted during transitions\n" >> "$outfile"
        printf "ROOT\tCheck Ethernet cable, switch port, PHY negotiation settings\n" >> "$outfile"
        printf "%s\n" "---" >> "$outfile"
    fi

    # Chain 3: Cert failures → OCPP auth issues → BootNotif rejection
    local cert_fail
    cert_fail=$(safe_int "$(get_metric cert_load_failures)")
    local ocpp_cert
    ocpp_cert=$(safe_int "$(get_metric ocpp_cert_issues)")
    if [ "$cert_fail" -gt 5 ] && [ "$ocpp_cert" -gt 0 ]; then
        printf "CHAIN\tCertificate→Authentication Cascade\tHIGH\n" >> "$outfile"
        printf "CAUSE\tCertificate load failures (%d)\n" "$cert_fail" >> "$outfile"
        printf "EFFECT\tOCPP certificate delivery issues (%d)\n" "$ocpp_cert" >> "$outfile"
        [ "$boot_rejected" -gt 5 ] && printf "EFFECT\tBootNotification acceptance delayed (%d rejected before success)\n" "$boot_rejected" >> "$outfile"
        printf "ROOT\tCheck certificate slots, storage integrity, certificate validity dates\n" >> "$outfile"
        printf "%s\n" "---" >> "$outfile"
    fi

    # Chain 4: PowerBoard faults → EVCC watchdog → charging impact
    local cpstate
    cpstate=$(safe_int "$(get_metric cpstate_fault_count)")
    local evcc_wd
    evcc_wd=$(safe_int "$(get_metric evcc_watchdog_count)")
    if [ "$cpstate" -gt 0 ] && [ "$evcc_wd" -gt 50 ]; then
        printf "CHAIN\tHardware→Charging Cascade\tHIGH\n" >> "$outfile"
        printf "CAUSE\tCPState faults from PowerBoard (%d)\n" "$cpstate" >> "$outfile"
        printf "EFFECT\tEVCC watchdog triggered repeatedly (%d times)\n" "$evcc_wd" >> "$outfile"
        printf "EFFECT\tCharging sessions may be interrupted or prevented\n" >> "$outfile"
        printf "ROOT\tCheck PowerBoard firmware, connector wiring, pilot signal circuit\n" >> "$outfile"
        printf "%s\n" "---" >> "$outfile"
    fi

    # Chain 5: Excessive reboots → service instability
    local reboots
    reboots=$(safe_int "$(get_metric hm_reboots)")
    local boots
    boots=$(safe_int "$(get_metric boot_count)")
    if [ "$reboots" -gt 10 ]; then
        printf "CHAIN\tReboot Instability\tHIGH\n" >> "$outfile"
        printf "CAUSE\t%d reboots detected across %d boot cycles\n" "$reboots" "$boots" >> "$outfile"
        local svc_down
        svc_down=$(safe_int "$(get_metric hm_service_down)")
        [ "$svc_down" -gt 0 ] && printf "EFFECT\t%d service-down events between reboots\n" "$svc_down" >> "$outfile"
        printf "EFFECT\tAll connections and sessions reset on each reboot\n" >> "$outfile"
        local gpio_fail
        gpio_fail=$(safe_int "$(get_metric hm_gpio_fail)")
        [ "$gpio_fail" -gt 0 ] && printf "EFFECT\tGPIO failures (%d) suggest hardware watchdog involvement\n" "$gpio_fail" >> "$outfile"
        printf "ROOT\tCheck panic logs, watchdog timeout configuration, power supply stability\n" >> "$outfile"
        printf "%s\n" "---" >> "$outfile"
    fi

    # Chain 6: PMQ subscription failures → inter-component communication breakdown
    # Source: PMQ bus topics — ChargePoint, ErrorBoss_PMQ, HealthMonitor_PMQ, NetworkBoss_PMQ,
    #   AuthManager_PMQ, BasicCharging_PMQ, ConfigManager_PMQ, EnergyManager_PMQ, OCPP_PMQ
    #   EVPLCCom_PMQ sub-topics: ACBasicCmd, Authorization, Availability, CableCheck, CableState,
    #   CertificateOperations, ChargeParameters, ChargingFlowCtrl, ChargingStatus, etc.
    local pmq_fail
    pmq_fail=$(safe_int "$(get_metric em_pmq_sub_fail)")
    local pmq_thread
    pmq_thread=$(safe_int "$(get_metric pmq_thread_alarm)")
    local pmq_overflow
    pmq_overflow=$(safe_int "$(get_metric pmq_queue_overflow)")
    if [ "$pmq_fail" -gt 3 ] || [ "$pmq_overflow" -gt 0 ]; then
        printf "CHAIN\tPMQ Communication Breakdown\tMEDIUM\n" >> "$outfile"
        printf "CAUSE\tPMQ subscription failures (%d) / queue overflow (%d)\n" "$pmq_fail" "$pmq_overflow" >> "$outfile"
        [ "$pmq_thread" -gt 0 ] && printf "EFFECT\tPMQ thread alarms (%d) — processing backlog\n" "$pmq_thread" >> "$outfile"
        printf "EFFECT\tEnergyManager may not receive power limit updates from ChargePoint PMQ\n" >> "$outfile"
        printf "EFFECT\tErrorBoss_PMQ may miss error injection/reports from EVIC\n" >> "$outfile"
        printf "EFFECT\tOCPP_PMQ may not receive StatusNotification triggers\n" >> "$outfile"
        printf "EFFECT\tCharging flow control (EVPLCCom_PMQ) may lose sync with state machine\n" >> "$outfile"
        printf "ROOT\tCheck PMQ queue sizes (/dev/mqueue), component startup order, POSIX queue limits (fs.mqueue.msg_max)\n" >> "$outfile"
        printf "%s\n" "---" >> "$outfile"
    fi

    # Chain 7: Temperature → derating → power reduction → session impact
    local temp_crit
    temp_crit=$(safe_int "$(get_metric temp_critical)")
    local temp_derating
    temp_derating=$(safe_int "$(get_metric temp_derating)")
    local temp_max
    temp_max=$(safe_int "$(get_metric temp_max_derating)")
    if [ "$temp_derating" -gt 0 ] || [ "$temp_crit" -gt 0 ]; then
        printf "CHAIN\tThermal→Power Cascade\tHIGH\n" >> "$outfile"
        [ "$temp_crit" -gt 0 ] && printf "CAUSE\tCritical temperature errors (%d) — hardware overheating\n" "$temp_crit" >> "$outfile"
        [ "$temp_derating" -gt 0 ] && printf "CAUSE\tTemperature derating activated (%d events)\n" "$temp_derating" >> "$outfile"
        printf "EFFECT\tCharging power output reduced (TemperatureDerating module)\n" >> "$outfile"
        [ "$temp_max" -gt 0 ] && printf "EFFECT\tMaximalDeratingReached (%d) — blocks ALL sessions, charger at thermal limit\n" "$temp_max" >> "$outfile"
        printf "EFFECT\tEnergyManager power balancing affected, slower charging\n" >> "$outfile"
        printf "ROOT\tCheck cooling system, ventilation, ambient temperature, wiring connections, enclosure airflow\n" >> "$outfile"
        printf "%s\n" "---" >> "$outfile"
    fi

    # Chain 8: Storage degradation → fallback → limited operation
    # Temporal validation: eMMC wear should precede filesystem issues
    local emmc
    emmc=$(safe_int "$(get_metric hm_emmc_wear)")
    local fallback
    fallback=$(safe_int "$(get_metric hm_storage_fallback)")
    local fs_ro
    fs_ro=$(safe_int "$(get_metric hm_fs_ro)")
    if [ "$fallback" -gt 0 ] || [ "$fs_ro" -gt 0 ]; then
        local temporal_confirmed=""
        if [ "$emmc" -gt 0 ] && _timeline_precedes "eMMC\|EmmcHigh\|Wearing" "Fallback\|fallback\|ReadOnly\|SwitchToRO"; then
            temporal_confirmed="(temporal order confirmed: wear → fallback)"
        fi
        printf "CHAIN\tStorage Degradation Cascade\tCRITICAL\n" >> "$outfile"
        [ "$emmc" -gt 0 ] && printf "CAUSE\teMMC wearing alerts (%d) — flash memory degrading %s\n" "$emmc" "$temporal_confirmed" >> "$outfile"
        [ "$fs_ro" -gt 0 ] && printf "EFFECT\tFilesystem switched to read-only (%d) — /var/aux or /etc/iotecha/configs affected\n" "$fs_ro" >> "$outfile"
        [ "$fallback" -gt 0 ] && printf "EFFECT\tStorageFallbackMode active (%d) — blocks ALL sessions\n" "$fallback" >> "$outfile"
        printf "EFFECT\tConfigs cannot be updated, logs cannot be written, OCPP offline queue unusable\n" >> "$outfile"
        printf "EFFECT\tFirmware updates impossible in fallback mode\n" >> "$outfile"
        printf "ROOT\tReplace Main AC board (eMMC is soldered). Power cycle may temporarily clear fallback.\n" >> "$outfile"
        printf "%s\n" "---" >> "$outfile"
    fi

    # Chain 9: Meter missing → Eichrecht failure → billing impact
    # Temporal validation: meter failure should precede Eichrecht error
    local meter_miss
    meter_miss=$(safe_int "$(get_metric meter_missing_critical)")
    local eich_term
    eich_term=$(safe_int "$(get_metric eichrecht_terminal)")
    local eich_unavail
    eich_unavail=$(safe_int "$(get_metric eichrecht_unavail)")
    if [ "$meter_miss" -gt 0 ] && [ "$((eich_term + eich_unavail))" -gt 0 ] && _timeline_precedes "Meter\|meter" "Eichrecht\|EICHRECHT"; then
        local gap
        gap=$(_timeline_gap_minutes "Meter\|meter" "Eichrecht\|EICHRECHT")
        printf "CHAIN\tMeter→Eichrecht→Billing Cascade\tCRITICAL\n" >> "$outfile"
        printf "CAUSE\tRequiredMeterMissing (%d) — meter communication lost\n" "$meter_miss" >> "$outfile"
        [ "$eich_term" -gt 0 ] && printf "EFFECT\tEICHRECHT_ERROR_STATE_TERMINAL (%d) — fatal metering state\n" "$eich_term" >> "$outfile"
        [ "$eich_unavail" -gt 0 ] && printf "EFFECT\tEICHRECHT_ERROR_STATE_UNAVAILABLE (%d) — metering unavailable\n" "$eich_unavail" >> "$outfile"
        printf "EFFECT\tBilling records invalid, legal compliance violated\n" >> "$outfile"
        printf "EFFECT\tAll sessions blocked until meter restored\n" >> "$outfile"
        printf "ROOT\tCheck meter wiring (RS485), Modbus address, verify Meter.preferred.type in ChargerApp properties\n" >> "$outfile"
        printf "%s\n" "---" >> "$outfile"
    fi

    # Chain 10: V2G errors → session failures → revenue loss
    local v2g_err
    v2g_err=$(safe_int "$(get_metric v2g_errors)")
    local v2g_to
    v2g_to=$(safe_int "$(get_metric v2g_timeouts)")
    local v2g_cert
    v2g_cert=$(safe_int "$(get_metric v2g_cert_issues)")
    if [ "$v2g_err" -gt 3 ] && [ "$v2g_to" -gt 3 ]; then
        printf "CHAIN\tV2G/HLC Communication Breakdown\tHIGH\n" >> "$outfile"
        printf "CAUSE\tV2G protocol errors (%d) + timeouts (%d)\n" "$v2g_err" "$v2g_to" >> "$outfile"
        [ "$v2g_cert" -gt 0 ] && printf "CAUSE\tV2G certificate issues (%d) — Plug&Charge affected\n" "$v2g_cert" >> "$outfile"
        printf "EFFECT\tISO 15118 sessions failing, fallback to IEC 61851 basic charging\n" >> "$outfile"
        printf "EFFECT\tDC charging may be completely blocked (CableCheck/Precharge failures)\n" >> "$outfile"
        printf "EFFECT\tChargingFlowCtrl and EVPLCCom_PMQ reporting errors to ErrorBoss\n" >> "$outfile"
        printf "ROOT\tCheck SLAC/PLC communication, V2G certificates, vehicle compatibility, digitalCommunicationTimeout_ms\n" >> "$outfile"
        printf "%s\n" "---" >> "$outfile"
    fi

    local chains
    chains=$(grep -c '^CHAIN' "$outfile" 2>/dev/null || echo "0")
    add_metric "deep_causal_chains" "$chains"
}

# ═══════════════════════════════════════════════════════════════════════════
# 6.3: Gap Detection (Silent Periods)
# ═══════════════════════════════════════════════════════════════════════════
_deep_gap_detection() {
    local outfile="$WORK_DIR/deep_gaps.dat"
    : > "$outfile"

    # Scan timeline for gaps > 5 minutes between consecutive events
    if [ ! -f "$TIMELINE_FILE" ] || [ ! -s "$TIMELINE_FILE" ]; then
        add_metric "deep_gaps" "0"
        return
    fi

    awk -F'\t' '
    {
        ts = $1
        # Parse "YYYY-MM-DD HH:MM:SS.mmm"
        split(ts, dp, " ")
        split(dp[1], d, "-")
        split(dp[2], t, ":")
        split(t[3], sf, ".")

        # Epoch-like calculation (day * 86400 + seconds)
        day = d[3] + 0
        secs = day * 86400 + (t[1]+0)*3600 + (t[2]+0)*60 + (sf[1]+0)

        if (NR > 1 && secs > prev_secs) {
            gap = secs - prev_secs
            if (gap > 300) {  # > 5 minutes
                mins = int(gap / 60)
                printf "%s\t%s\t%d\t%d\t%s\t%s\n", prev_ts, ts, gap, mins, prev_comp, $3
            }
        }
        prev_ts = ts
        prev_secs = secs
        prev_comp = $3
    }' "$TIMELINE_FILE" > "$outfile"

    local gap_count
    gap_count=$(wc -l < "$outfile" 2>/dev/null | tr -d ' ')
    add_metric "deep_gaps" "$gap_count"

    # Find the longest gap
    if [ -s "$outfile" ]; then
        local max_gap
        max_gap=$(awk -F'\t' 'BEGIN{max=0} {if($3+0>max){max=$3+0; line=$0}} END{print line}' "$outfile")
        if [ -n "$max_gap" ]; then
            local gap_mins
            gap_mins=$(echo "$max_gap" | cut -f4)
            add_metric "deep_max_gap_minutes" "$gap_mins"
        fi
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# 6.5: Config vs Runtime Validation
# ═══════════════════════════════════════════════════════════════════════════
_deep_config_validation() {
    local outfile="$WORK_DIR/deep_config_check.dat"
    : > "$outfile"

    local props_dir="$WORK_DIR/properties"
    [ -d "$props_dir" ] || { add_metric "deep_config_checks" "0"; return; }

    # Check 1: i2p2 connection timeout vs actual disconnect behavior
    local conn_timeout
    conn_timeout=$(_read_prop "i2p2.props" "i2p2.connectionMonitor.Timeout_s")
    local conn_action
    conn_action=$(_read_prop "i2p2.props" "i2p2.connectionMonitor.Action")
    if [ -n "$conn_timeout" ]; then
        local mqtt_fail
        mqtt_fail=$(safe_int "$(get_metric i2p2_mqtt_fail_count)")
        local status="OK"
        local note="Timeout=${conn_timeout}s, Action=${conn_action:-unknown}"
        if [ "$conn_action" = "CloseApp" ] && [ "$mqtt_fail" -gt 100 ]; then
            status="WARN"
            note="$note — App will self-terminate after ${conn_timeout}s of cloud disconnect. With $mqtt_fail MQTT failures, this is high risk."
        fi
        printf "%s\ti2p2\ti2p2.connectionMonitor\t%s\n" "$status" "$note" >> "$outfile"
    fi

    # Check 2: OCPP reconnect interval
    local ocpp_reconnect
    ocpp_reconnect=$(_read_prop "ocpp-cmd.props" "ocpp.Core.ReconnectInterval")
    if [ -n "$ocpp_reconnect" ]; then
        local status="OK"
        local note="ReconnectInterval=${ocpp_reconnect}s"
        if [ "$ocpp_reconnect" -lt 30 ] 2>/dev/null; then
            status="WARN"
            note="$note — Very aggressive reconnect may cause server-side rate limiting"
        fi
        printf "%s\tOCPP\tocpp.ReconnectInterval\t%s\n" "$status" "$note" >> "$outfile"
    fi

    # Check 3: BootNotification retry intervals
    local boot_min boot_max
    boot_min=$(_read_prop "ocpp-cmd.props" "timeout.BootMinRetryInterval")
    boot_max=$(_read_prop "ocpp-cmd.props" "timeout.BootMaxRetryInterval")
    if [ -n "$boot_min" ] && [ -n "$boot_max" ]; then
        local boot_accepted
        boot_accepted=$(safe_int "$(get_metric ocpp_boot_accepted)")
        local boot_total
        boot_total=$(safe_int "$(get_metric ocpp_boot_notif)")
        local status="OK"
        local note="Retry interval: ${boot_min}s–${boot_max}s"
        if [ "$boot_total" -gt 50 ] && [ "$boot_accepted" -lt 20 ]; then
            status="WARN"
            note="$note — Low acceptance rate ($boot_accepted/$boot_total). Server may be rejecting."
        fi
        printf "%s\tOCPP\tBootNotification retry\t%s\n" "$status" "$note" >> "$outfile"
    fi

    # Check 4: Health monitor OCPP alive timeout
    local ocpp_alive
    ocpp_alive=$(_read_prop "iotc-health-monitor.props" "health-monitor.OCPPAliveTimeout_s")
    if [ -n "$ocpp_alive" ]; then
        local status="OK"
        local note="OCPPAliveTimeout=${ocpp_alive}s"
        local reboots
        reboots=$(safe_int "$(get_metric hm_reboots)")
        if [ "$reboots" -gt 10 ]; then
            status="WARN"
            note="$note — $reboots reboots suggest timeout is triggering frequently"
        fi
        printf "%s\tHealthMonitor\tOCPP alive timeout\t%s\n" "$status" "$note" >> "$outfile"
    fi

    # Check 5: Watchdog connection timeout
    local wd_conn
    wd_conn=$(_read_prop "i2p2.props" "watchdog.connectionTimeout")
    if [ -n "$wd_conn" ]; then
        local status="OK"
        local note="Watchdog connectionTimeout=${wd_conn}s"
        printf "%s\ti2p2\twatchdog.connectionTimeout\t%s\n" "$status" "$note" >> "$outfile"
    fi

    # Check 6: EV communication timeouts
    local dcomm
    dcomm=$(_read_prop "ChargerApp.props" "EVPLCCom.digitalCommunicationTimeout_ms")
    if [ -n "$dcomm" ]; then
        local status="OK"
        local note="EV digital comm timeout=${dcomm}ms"
        if [ "$dcomm" -gt 60000 ] 2>/dev/null; then
            status="INFO"
            note="$note — Relatively long timeout, may delay fault detection"
        fi
        printf "%s\tChargerApp\tEV communication timeout\t%s\n" "$status" "$note" >> "$outfile"
    fi

    # Check 7: Log rotation settings vs log sizes
    for comp in ChargerApp NetworkBoss OCPP i2p2; do
        local propfile=""
        case "$comp" in
            ChargerApp) propfile="ChargerApp.props" ;;
            NetworkBoss) propfile="NetworkBoss.props" ;;
            OCPP) propfile="ocpp-cmd.props" ;;
            i2p2) propfile="i2p2.props" ;;
        esac
        local rotation
        rotation=$(_read_prop "$propfile" "logger.channel.file.rotation")
        if [ -n "$rotation" ]; then
            printf "INFO\t%s\tLog rotation\tRotation: %s\n" "$comp" "$rotation" >> "$outfile"
        fi
    done

    local checks
    checks=$(wc -l < "$outfile" 2>/dev/null | tr -d ' ')
    add_metric "deep_config_checks" "$checks"
}

_read_prop() {
    local file="$1" key="$2"
    local propfile="$WORK_DIR/properties/$file"
    [ -f "$propfile" ] || return
    grep "^${key}=" "$propfile" 2>/dev/null | head -1 | cut -d= -f2-
}

# ═══════════════════════════════════════════════════════════════════════════
# 6.8: Error Rate Histogram
# ═══════════════════════════════════════════════════════════════════════════
_deep_error_histogram() {
    local outfile="$WORK_DIR/deep_error_histogram.dat"
    : > "$outfile"

    # Bucket errors by hour from timeline
    if [ ! -f "$TIMELINE_FILE" ] || [ ! -s "$TIMELINE_FILE" ]; then
        add_metric "deep_histogram_buckets" "0"
        return
    fi

    # Count events per hour-bucket, split by severity
    awk -F'\t' '
    {
        # Extract hour bucket: "YYYY-MM-DD HH"
        split($1, dp, " ")
        split(dp[2], tp, ":")
        bucket = dp[1] " " tp[1] ":00"
        sev = $2

        total[bucket]++
        counts[bucket, sev]++
        if (!(bucket in seen)) {
            order[++n] = bucket
            seen[bucket] = 1
        }
    }
    END {
        for (i = 1; i <= n; i++) {
            b = order[i]
            c = counts[b,"CRITICAL"]+0
            h = counts[b,"HIGH"]+0
            m = counts[b,"MEDIUM"]+0
            l = counts[b,"LOW"]+0
            inf = counts[b,"INFO"]+0
            printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\n", b, total[b], c, h, m, l, inf
        }
    }' "$TIMELINE_FILE" > "$outfile"

    local buckets
    buckets=$(wc -l < "$outfile" 2>/dev/null | tr -d ' ')
    add_metric "deep_histogram_buckets" "$buckets"

    # Find peak hour and detect spikes
    if [ -s "$outfile" ]; then
        local peak
        peak=$(awk -F'\t' 'BEGIN{max=0} {if($2+0>max){max=$2+0; bucket=$1}} END{printf "%s (%d events)", bucket, max}' "$outfile")
        add_metric "deep_peak_hour" "$peak"

        # Spike detection: hour with >3x the average
        local spike_info
        spike_info=$(awk -F'\t' '
        { total[NR]=$2+0; bucket[NR]=$1; sum+=$2+0; n=NR }
        END {
            if (n < 2) exit
            avg = sum / n
            if (avg < 1) exit
            spikes = 0
            for (i=1; i<=n; i++) {
                if (total[i] > avg * 3) {
                    printf "%s: %d events (%.0fx avg)\n", bucket[i], total[i], total[i]/avg
                    spikes++
                }
            }
            if (spikes > 0) printf "SPIKES:%d\n", spikes
        }' "$outfile")

        local spike_count
        spike_count=$(echo "$spike_info" | grep -c '^SPIKES:' 2>/dev/null || echo 0)
        if [ "$(safe_int "$spike_count")" -gt 0 ]; then
            local spike_detail
            spike_detail=$(echo "$spike_info" | grep -v '^SPIKES:' | head -3 | tr '\n' '; ')
            add_issue "MEDIUM" "Timeline" "Error Rate Spike Detected" \
                "One or more hours had >3x the average event rate. $spike_detail" \
                "Evidence: histogram spike in timeline"
        fi
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# 6.6: PMQ Interaction Map
# ═══════════════════════════════════════════════════════════════════════════
_deep_pmq_map() {
    local outfile="$WORK_DIR/deep_pmq_map.dat"
    : > "$outfile"

    # Scan parsed logs for PMQ subscribe/publish patterns
    # Use sed for extraction (awk match with 3 args not portable)
    grep -rh 'Subscribing from:' "$WORK_DIR"/parsed/*.parsed 2>/dev/null | \
        sed -n 's/.*Subscribing from: \([^ ]*\) to: \([^ |]*\).*/\1\t\2\tsubscribe/p' | \
        sort -u > "$outfile" 2>/dev/null || true

    grep -rh 'Direct queue created:' "$WORK_DIR"/parsed/*.parsed 2>/dev/null | \
        sed -n 's/.*created: \([^ ,|]*\).*destination.*: \([^ |]*\).*/\1\t\2\tdirect/p' | \
        sort -u >> "$outfile" 2>/dev/null || true

    grep -rh 'Subscriber queue created:' "$WORK_DIR"/parsed/*.parsed 2>/dev/null | \
        sed -n 's/.*created: \([^ |]*\).*/\1\t\tqueue/p' | \
        sort -u >> "$outfile" 2>/dev/null || true

    local pmq_links
    pmq_links=$(wc -l < "$outfile" 2>/dev/null | tr -d ' ')
    add_metric "deep_pmq_links" "$pmq_links"
}

# ═══════════════════════════════════════════════════════════════════════════
# 6.8: Charging Session Reconstruction
# ═══════════════════════════════════════════════════════════════════════════
_deep_charging_sessions() {
    local outfile="$WORK_DIR/deep_sessions.dat"
    : > "$outfile"

    # Use parsed files (normalized timestamps)
    local ca_parsed="$WORK_DIR/parsed/ChargerApp.parsed"
    [ -f "$ca_parsed" ] || ca_parsed="$WORK_DIR/parsed/ChargerApp_full.parsed"
    local ocpp_parsed="$WORK_DIR/parsed/OCPP.parsed"
    [ -f "$ocpp_parsed" ] || ocpp_parsed="$WORK_DIR/parsed/OCPP_full.parsed"

    # --- Extract connector status changes from OCPP StatusNotification ---
    local status_file="$WORK_DIR/_deep_status_events.tmp"
    : > "$status_file"
    if [ -f "$ocpp_parsed" ]; then
        grep -a 'StatusNotification.*Call' "$ocpp_parsed" 2>/dev/null | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*"connectorId" *: *\([0-9]*\).*"status" *: *"\([^"]*\)".*/\1\t\2\t\3/p' \
            >> "$status_file" 2>/dev/null || true
    fi
    # Also look in ChargerApp for connector status
    if [ -f "$ca_parsed" ]; then
        grep -a 'Remote connector status change:' "$ca_parsed" 2>/dev/null | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*status change: *\([0-9]*\) *\(.*\)/\1\t\2\t\3/p' \
            >> "$status_file" 2>/dev/null || true
    fi

    # --- Reconstruct sessions: Preparing -> Charging -> Finishing/Available ---
    if [ -s "$status_file" ]; then
        sort "$status_file" 2>/dev/null | awk -F'\t' '
        BEGIN { state="idle"; start=""; cid="" }
        {
            ts=$1; c=$2; st=$3
            if (c == "0") next  # skip charge point status
            if (st == "Preparing") {
                # Flush any prior incomplete session
                if (start != "" && state != "idle") {
                    print start "\t" ts "\t" cid "\t" state "\tincomplete"
                }
                start=ts; cid=c; state="preparing"
            } else if (st ~ /Charging|SuspendedEV|SuspendedEVSE/) {
                if (state == "preparing" && c == cid) { state="charging" }
                else if (state == "idle" || start == "") { start=ts; cid=c; state="charging" }
            } else if (st ~ /Finishing|Available|Faulted|Unavailable/) {
                if (start != "" && c == cid) {
                    print start "\t" ts "\t" cid "\t" state "\t" st
                    start=""; state="idle"
                }
            }
        }
        END {
            if (start != "" && state != "idle") {
                print start "\t(ongoing)\t" cid "\t" state "\tincomplete"
            }
        }' >> "$outfile" 2>/dev/null || true
    fi

    # --- Extract OCPP transaction events ---
    local tx_file="$WORK_DIR/deep_transactions.dat"
    : > "$tx_file"
    if [ -f "$ocpp_parsed" ]; then
        grep -aE 'StartTransaction|StopTransaction|Authorize' "$ocpp_parsed" 2>/dev/null | \
            grep -v 'Key added\|Key overriden\|StopTransaction.*default' | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*|\([^|]*\(StartTransaction\|StopTransaction\|Authorize\)[^|]*\)|.*/\1\t\2/p' \
            >> "$tx_file" 2>/dev/null || true
    fi

    local session_count tx_count
    session_count=$(wc -l < "$outfile" 2>/dev/null | tr -d ' ')
    tx_count=$(wc -l < "$tx_file" 2>/dev/null | tr -d ' ')
    add_metric "deep_sessions" "$session_count"
    add_metric "deep_transactions" "$tx_count"

    # Detect failed/incomplete sessions
    local incomplete_count faulted_count
    incomplete_count=$(grep -c 'incomplete' "$outfile" 2>/dev/null || echo 0)
    faulted_count=$(grep -c 'Faulted' "$outfile" 2>/dev/null || echo 0)
    if [ "$(safe_int "$faulted_count")" -gt 0 ]; then
        add_issue "HIGH" "ChargerApp/Charging" "Charging Sessions Ended in Fault" \
            "$faulted_count session(s) terminated by Faulted state. Connector entered fault during active charge." \
            "Evidence: $faulted_count faulted sessions in OCPP StatusNotification"
    fi
    if [ "$(safe_int "$incomplete_count")" -gt 0 ]; then
        add_issue "MEDIUM" "ChargerApp/Charging" "Incomplete Charging Sessions" \
            "$incomplete_count session(s) started (Preparing) but never completed. May indicate EV communication failure or user abort." \
            "Evidence: $incomplete_count incomplete sessions in OCPP StatusNotification"
    fi
    rm -f "$status_file"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# 6.9: Reboot / Crash Timeline
# ═══════════════════════════════════════════════════════════════════════════
_deep_reboot_timeline() {
    local outfile="$WORK_DIR/deep_reboots.dat"
    : > "$outfile"

    local kern_parsed="$WORK_DIR/parsed/kern.parsed"
    [ -f "$kern_parsed" ] || kern_parsed="$WORK_DIR/parsed/kern_full.parsed"
    local syslog_parsed="$WORK_DIR/parsed/syslog.parsed"
    [ -f "$syslog_parsed" ] || syslog_parsed="$WORK_DIR/parsed/syslog_full.parsed"

    # --- Detect kernel boots ---
    if [ -f "$kern_parsed" ]; then
        grep -a 'Booting Linux' "$kern_parsed" 2>/dev/null | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*/\1\tkernel_boot\tLinux boot detected/p' \
            >> "$outfile" 2>/dev/null || true

        # --- Detect watchdog resets ---
        grep -ai 'watchdog.*reset\|watchdog.*expired\|watchdog.*reboot\|SysRq.*reboot' "$kern_parsed" 2>/dev/null | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*/\1\twatchdog\tWatchdog reset/p' \
            >> "$outfile" 2>/dev/null || true

        # --- Detect OOM kills ---
        grep -ai 'Out of memory\|oom-killer\|oom_kill' "$kern_parsed" 2>/dev/null | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*/\1\toom_kill\tOOM killer invoked/p' \
            >> "$outfile" 2>/dev/null || true

        # --- Detect kernel panics ---
        grep -ai 'Kernel panic\|kernel BUG\|Oops:' "$kern_parsed" 2>/dev/null | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*/\1\tkernel_panic\tKernel panic/p' \
            >> "$outfile" 2>/dev/null || true
    fi

    if [ -f "$syslog_parsed" ]; then
        # --- Detect monit restarts ---
        grep -a "monit.*trying to restart" "$syslog_parsed" 2>/dev/null | \
            sed -n "s/^\([0-9-]* [0-9:.]*\).*monit.*'\([^']*\)'.*restart.*/\1\tmonit_restart\tMonit restarted: \2/p" \
            >> "$outfile" 2>/dev/null || true

        # --- Detect monit failed restarts ---
        grep -a "monit.*failed to restart" "$syslog_parsed" 2>/dev/null | \
            sed -n "s/^\([0-9-]* [0-9:.]*\).*monit.*'\([^']*\)'.*failed.*/\1\tmonit_fail\tMonit restart failed: \2/p" \
            >> "$outfile" 2>/dev/null || true

        # --- Detect systemd/service crashes ---
        grep -a 'systemd.*exited\|systemd.*failed' "$syslog_parsed" 2>/dev/null | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*systemd.*: \(.*\) \(exited\|failed\).*/\1\tservice_crash\tService \2 \3/p' \
            >> "$outfile" 2>/dev/null || true
    fi

    # --- Detect ChargerApp watchdog kills ---
    local ca_parsed="$WORK_DIR/parsed/ChargerApp.parsed"
    [ -f "$ca_parsed" ] || ca_parsed="$WORK_DIR/parsed/ChargerApp_full.parsed"
    if [ -f "$ca_parsed" ]; then
        grep -a 'Watchdog CRITICAL' "$ca_parsed" 2>/dev/null | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*/\1\twatchdog_app\tApp watchdog kill/p' \
            >> "$outfile" 2>/dev/null || true
    fi

    sort "$outfile" -o "$outfile" 2>/dev/null || true

    local reboot_count boot_count
    reboot_count=$(wc -l < "$outfile" 2>/dev/null | tr -d ' ')
    boot_count=$(grep -c 'kernel_boot' "$outfile" 2>/dev/null || echo 0)
    add_metric "deep_reboot_events" "$reboot_count"
    add_metric "deep_boot_count" "$boot_count"

    if [ "$(safe_int "$boot_count")" -gt 1 ]; then
        add_issue "HIGH" "System" "Multiple Reboots Detected" \
            "$boot_count kernel boots detected in log window. Indicates instability or watchdog resets." \
            "Evidence: $boot_count boots in kern log"
    fi

    local oom_count
    oom_count=$(grep -c 'oom_kill' "$outfile" 2>/dev/null || echo 0)
    if [ "$(safe_int "$oom_count")" -gt 0 ]; then
        add_issue "HIGH" "System" "OOM Killer Invoked" \
            "Out-of-memory killer triggered $oom_count time(s). System ran out of RAM." \
            "Evidence: $oom_count OOM events in kern log"
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# 6.10: Network Connectivity Timeline
# ═══════════════════════════════════════════════════════════════════════════
_deep_connectivity() {
    local outfile="$WORK_DIR/deep_connectivity.dat"
    : > "$outfile"

    local ocpp_parsed="$WORK_DIR/parsed/OCPP.parsed"
    [ -f "$ocpp_parsed" ] || ocpp_parsed="$WORK_DIR/parsed/OCPP_full.parsed"
    local nb_parsed="$WORK_DIR/parsed/NetworkBoss.parsed"
    [ -f "$nb_parsed" ] || nb_parsed="$WORK_DIR/parsed/NetworkBoss_full.parsed"

    # --- OCPP WebSocket connection events ---
    if [ -f "$ocpp_parsed" ]; then
        grep -a 'NetConnection\|Connection.*established\|Connection.*lost\|Connection.*failed\|Reconnect' "$ocpp_parsed" 2>/dev/null | \
            grep -v 'SafeCloser\|Key added\|Key overriden' | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*Trying to establish.*/\1\tocpp\tconnecting/p
                    s/^\([0-9-]* [0-9:.]*\).*Connection lost.*/\1\tocpp\tdisconnected/p
                    s/^\([0-9-]* [0-9:.]*\).*Connection failed.*/\1\tocpp\tfailed/p
                    s/^\([0-9-]* [0-9:.]*\).*Reconnection try.*/\1\tocpp\treconnecting/p' \
            >> "$outfile" 2>/dev/null || true

        # BootNotification outcomes (specific patterns only)
        grep -a 'BootNotification' "$ocpp_parsed" 2>/dev/null | \
            grep -v "isn't accepted" | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*Sending.*BootNotification.*is failed.*/\1\tboot_notif\tfailed/p
                    s/^\([0-9-]* [0-9:.]*\).*BootNotification.*[Aa]ccepted.*/\1\tboot_notif\taccepted/p
                    s/^\([0-9-]* [0-9:.]*\).*BootNotification.*[Rr]ejected.*/\1\tboot_notif\trejected/p' \
            >> "$outfile" 2>/dev/null || true

        # DNS failures
        grep -a 'DNS error' "$ocpp_parsed" 2>/dev/null | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*DNS error.*resolving: *\([^ ]*\).*/\1\tdns\tfailed:\2/p' \
            >> "$outfile" 2>/dev/null || true

        # Certificate errors (strict pattern)
        grep -a "Certificate isn't received\|certificate.*expired\|certificate.*invalid\|SSL.*error\|TLS.*error" "$ocpp_parsed" 2>/dev/null | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*/\1\ttls\terror/p' \
            >> "$outfile" 2>/dev/null || true
    fi

    # --- NetworkBoss interface changes ---
    if [ -f "$nb_parsed" ]; then
        grep -a 'InterfaceSelectionManager.*interface.*set to\|InterfaceSelectionManager.*Initial interface' "$nb_parsed" 2>/dev/null | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*interface.*set to: *\(.*\)/\1\tinterface\t\2/p
                    s/^\([0-9-]* [0-9:.]*\).*Initial interface.*: *\(.*\)/\1\tinterface\tinitial:\2/p' \
            >> "$outfile" 2>/dev/null || true
    fi

    sort "$outfile" -o "$outfile" 2>/dev/null || true

    # --- Compute stats ---
    local total_events conn_count disconn_count fail_count dns_fails tls_errs
    total_events=$(wc -l < "$outfile" 2>/dev/null | tr -d ' ')
    conn_count=$(grep -c 'ocpp.*connecting$' "$outfile" 2>/dev/null || echo 0)
    disconn_count=$(grep -c 'disconnected' "$outfile" 2>/dev/null || echo 0)
    fail_count=$(grep -c 'ocpp.*failed' "$outfile" 2>/dev/null || echo 0)
    dns_fails=$(grep -c 'dns' "$outfile" 2>/dev/null || echo 0)
    tls_errs=$(grep -c 'tls' "$outfile" 2>/dev/null || echo 0)

    add_metric "deep_conn_events" "$total_events"
    add_metric "deep_conn_connected" "$conn_count"
    add_metric "deep_conn_disconnected" "$disconn_count"
    add_metric "deep_conn_failed" "$fail_count"
    add_metric "deep_dns_failures" "$dns_fails"
    add_metric "deep_tls_errors" "$tls_errs"

    # Check: BootNotification never accepted
    local boot_accepted boot_failed
    boot_accepted=$(grep -c 'boot_notif.*accepted' "$outfile" 2>/dev/null || echo 0)
    boot_failed=$(grep -c 'boot_notif.*failed' "$outfile" 2>/dev/null || echo 0)
    if [ "$(safe_int "$boot_accepted")" -eq 0 ] && [ "$(safe_int "$boot_failed")" -gt 0 ]; then
        add_issue "CRITICAL" "OCPP/Network" "Never Connected to Central System" \
            "OCPP BootNotification never accepted. $boot_failed attempts failed. DNS failures: $dns_fails, TLS errors: $tls_errs." \
            "Evidence: 0 accepted, $boot_failed failed BootNotifications"
    fi

    if [ "$(safe_int "$dns_fails")" -gt 3 ]; then
        add_issue "HIGH" "Network" "Persistent DNS Resolution Failures" \
            "DNS resolution failed $dns_fails times. Check network configuration and DNS server settings." \
            "Evidence: $dns_fails DNS error entries in OCPP log"
    fi

    if [ "$(safe_int "$tls_errs")" -gt 0 ]; then
        add_issue "HIGH" "Network/TLS" "TLS/Certificate Errors" \
            "$tls_errs TLS or certificate errors detected. Connection cannot be secured." \
            "Evidence: $tls_errs TLS-related errors in OCPP log"
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# 6.11: Connector State Machine Validation
# ═══════════════════════════════════════════════════════════════════════════
_deep_state_machine() {
    local outfile="$WORK_DIR/deep_state_machine.dat"
    : > "$outfile"

    local ca_parsed="$WORK_DIR/parsed/ChargerApp.parsed"
    [ -f "$ca_parsed" ] || ca_parsed="$WORK_DIR/parsed/ChargerApp_full.parsed"
    [ -f "$ca_parsed" ] || { add_metric "deep_sm_transitions" "0"; return 0; }

    # --- Extract CP state transitions ---
    grep -a 'CPStateMachine.*Created state\|CPStateMachine.*Got event\|LogicStateMachine.*Created state\|LogicStateMachine.*Got event' "$ca_parsed" 2>/dev/null | \
        sed -n 's/^\([0-9-]* [0-9:.]*\).*\[ *\([0-9]*\) *\] *\[\(.*\)\] Created state \(.*\)/\1\t\2\t\3\tstate\t\4/p
                s/^\([0-9-]* [0-9:.]*\).*\[ *\([0-9]*\) *\] *\[\(.*\)\] Got event \(.*\) in state .*/\1\t\2\t\3\tevent\t\4/p' \
        >> "$outfile" 2>/dev/null || true

    # --- Extract OCPP connector status ---
    local ocpp_parsed="$WORK_DIR/parsed/OCPP.parsed"
    [ -f "$ocpp_parsed" ] || ocpp_parsed="$WORK_DIR/parsed/OCPP_full.parsed"
    if [ -f "$ocpp_parsed" ]; then
        grep -a 'StatusNotification.*Call' "$ocpp_parsed" 2>/dev/null | \
            sed -n 's/^\([0-9-]* [0-9:.]*\).*"connectorId" *: *\([0-9]*\).*"status" *: *"\([^"]*\)".*/\1\t\2\tOCPP\tstatus\t\3/p' \
            >> "$outfile" 2>/dev/null || true
    fi

    sort "$outfile" -o "$outfile" 2>/dev/null || true

    local sm_transitions
    sm_transitions=$(wc -l < "$outfile" 2>/dev/null | tr -d ' ')
    add_metric "deep_sm_transitions" "$sm_transitions"

    # --- Detect stuck in Fault state ---
    local fault_count available_after_fault
    fault_count=$(grep -c 'CPStateFChargerNotAvailable\|Faulted' "$outfile" 2>/dev/null || echo 0)
    available_after_fault=$(grep 'Faulted\|CPStateFChargerNotAvailable' "$outfile" 2>/dev/null | tail -1 | grep -c 'Available' 2>/dev/null || echo 0)
    # Check: was last known state a fault?
    local last_state
    last_state=$(grep 'state' "$outfile" 2>/dev/null | tail -1 | awk -F'\t' '{print $5}')
    if [ "$(safe_int "$fault_count")" -gt 0 ]; then
        case "$last_state" in
            *Fault*|*NotAvailable*)
                add_issue "HIGH" "ChargerApp/Connector" "Connector Stuck in Fault State" \
                    "Connector entered Fault state ($fault_count events) and did not recover. Last state: $last_state" \
                    "Evidence: $fault_count fault transitions, last state=$last_state"
                ;;
        esac
    fi

    # --- Detect watchdog escalation pattern ---
    local watchdog_warns=0 watchdog_crits=0
    watchdog_warns=$(grep -c 'Watchdog WARNING' "$ca_parsed" 2>/dev/null || echo 0)
    watchdog_crits=$(grep -c 'Watchdog CRITICAL' "$ca_parsed" 2>/dev/null || echo 0)
    if [ "$(safe_int "$watchdog_crits")" -gt 0 ]; then
        add_issue "CRITICAL" "ChargerApp" "Watchdog Killed Service" \
            "$watchdog_warns warnings escalated to $watchdog_crits CRITICAL — service stopped. EVCC communication module unresponsive." \
            "Evidence: $watchdog_warns warns, $watchdog_crits criticals in ChargerApp"
    fi
    add_metric "deep_watchdog_warns" "$watchdog_warns"
    add_metric "deep_watchdog_crits" "$watchdog_crits"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Display Functions
# ═══════════════════════════════════════════════════════════════════════════
show_deep_results() {
    _show_boot_waterfall
    _show_causal_chains
    _show_gaps
    _show_config_validation
    _show_error_histogram
    _show_charging_sessions
    _show_reboot_timeline
    _show_connectivity
    _show_state_machine
}

_show_boot_waterfall() {
    local file="$WORK_DIR/deep_boot_deltas.dat"
    [ -f "$file" ] && [ -s "$file" ] || return

    print_section "Boot Sequence Waterfall"
    printf "  %s%-23s  %-16s  %-14s  %s%s%s\n" "${BLD}" "Timestamp" "Component" "Phase" "Delta" "${RST}" ""
    printf "  %s%.80s%s\n" "${DIM}" "────────────────────────────────────────────────────────────────────────────────" "${RST}"

    while IFS=$'\t' read -r ts comp phase delta desc; do
        [ -z "$ts" ] && continue
        local delta_color="$GRN"
        local delta_num="${delta%.*}"
        [ "${delta_num:-0}" -gt 5 ] && delta_color="$YLW"
        [ "${delta_num:-0}" -gt 30 ] && delta_color="$RED"

        printf "  %-23s  %s%-16s%s  %-14s  %s+%ss%s\n" \
            "$ts" "${CYN}" "$comp" "${RST}" "$phase" "$delta_color" "$delta" "${RST}"
    done < "$file"
    printf "\n"
}

_show_causal_chains() {
    local file="$WORK_DIR/deep_causal.dat"
    [ -f "$file" ] && [ -s "$file" ] || return

    print_section "Causal Chains"
    local chain_num=0
    while IFS=$'\t' read -r type content rest; do
        case "$type" in
            CHAIN)
                chain_num=$((chain_num + 1))
                local severity="${rest:-MEDIUM}"
                printf "\n  %s⛓ Chain #%d: %s%s" "${BLD}" "$chain_num" "$content" "${RST}"
                printf " ["
                print_badge "$severity"
                printf "]\n"
                ;;
            CAUSE)
                printf "  %s├─ ❌ CAUSE:%s %s\n" "${RED}" "${RST}" "$content"
                ;;
            EFFECT)
                printf "  %s├─ → EFFECT:%s %s\n" "${YLW}" "${RST}" "$content"
                ;;
            ROOT)
                printf "  %s└─ 💡 FIX:%s %s\n" "${GRN}" "${RST}" "$content"
                ;;
        esac
    done < "$file"
    printf "\n"
}

_show_gaps() {
    local file="$WORK_DIR/deep_gaps.dat"
    [ -f "$file" ] && [ -s "$file" ] || return

    local count
    count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    print_section "Log Gaps (>5 min): $count detected"

    # Show top 10 by duration
    sort -t$'\t' -k3 -rn "$file" 2>/dev/null | head -10 | while IFS=$'\t' read -r from to secs mins comp_from comp_to; do
        [ -z "$from" ] && continue
        printf "  %s%s%s → %s%s%s  %s%dm%s  (%s → %s)\n" \
            "${DIM}" "$from" "${RST}" "${DIM}" "$to" "${RST}" \
            "${RED}${BLD}" "$mins" "${RST}" "$comp_from" "$comp_to"
    done
    printf "\n"
}

_show_config_validation() {
    local file="$WORK_DIR/deep_config_check.dat"
    [ -f "$file" ] && [ -s "$file" ] || return

    print_section "Configuration Validation"
    while IFS=$'\t' read -r status comp key note; do
        [ -z "$status" ] && continue
        local icon="✅" color="$GRN"
        case "$status" in
            WARN) icon="⚠️" ; color="$YLW" ;;
            FAIL) icon="❌"; color="$RED" ;;
            INFO) icon="ℹ️" ; color="$BLU" ;;
        esac
        printf "  %s %s%-14s%s %s%s%s  %s\n" "$icon" "${CYN}" "$comp" "${RST}" "${BLD}" "$key" "${RST}" "$note"
    done < "$file"
    printf "\n"
}

_show_error_histogram() {
    local file="$WORK_DIR/deep_error_histogram.dat"
    [ -f "$file" ] && [ -s "$file" ] || return

    print_section "Error Rate by Hour"

    # Find max for scaling
    local max_val
    max_val=$(awk -F'\t' 'BEGIN{m=0} {if($2+0>m)m=$2+0} END{print m}' "$file")
    [ "${max_val:-0}" -eq 0 ] && return

    local bar_max=40
    while IFS=$'\t' read -r bucket total crit high med low info; do
        [ -z "$bucket" ] && continue
        local bar_len
        bar_len=$((total * bar_max / max_val))
        [ "$bar_len" -lt 1 ] && bar_len=1

        printf "  %s%-16s%s " "${DIM}" "$bucket" "${RST}"

        # Color-coded bar
        local i=0
        local crit_len
        crit_len=$((crit * bar_max / max_val))
        local high_len
        high_len=$((high * bar_max / max_val))
        local rest_len
        rest_len=$((bar_len - crit_len - high_len))
        [ "$rest_len" -lt 0 ] && rest_len=0

        local j
        for ((j=0; j<crit_len; j++)); do printf "%s█%s" "$RED" "${RST}"; done
        for ((j=0; j<high_len; j++)); do printf "%s█%s" "$YLW" "${RST}"; done
        for ((j=0; j<rest_len; j++)); do printf "%s█%s" "$BLU" "${RST}"; done

        printf " %s%d%s\n" "${DIM}" "$total" "${RST}"
    done < "$file"
    printf "  %sLegend: %s█%sCritical %s█%sHigh %s█%sOther%s\n\n" "${DIM}" "$RED" "${DIM}" "$YLW" "${DIM}" "$BLU" "${DIM}" "${RST}"
}

_show_charging_sessions() {
    local file="$WORK_DIR/deep_sessions.dat"
    local tx_file="$WORK_DIR/deep_transactions.dat"

    local sessions=0 txns=0
    [ -f "$file" ] && sessions=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    [ -f "$tx_file" ] && txns=$(wc -l < "$tx_file" 2>/dev/null | tr -d ' ')

    print_section "Charging Sessions"
    if [ "$(safe_int "$sessions")" -eq 0 ] && [ "$(safe_int "$txns")" -eq 0 ]; then
        printf "  %sNo charging sessions detected in log window%s\n\n" "${GRY}" "${RST}"
        return
    fi

    printf "  %sSessions: %s%d%s   OCPP transactions: %s%d%s\n\n" \
        "${GRY}" "${BLD}" "$sessions" "${RST}" "${BLD}" "$txns" "${RST}"

    if [ -s "$file" ]; then
        printf "  %s%-22s %-22s %s %-12s %s%s\n" "${BLD}" "Start" "End" "C#" "Reached" "Stop Reason" "${RST}"
        printf "  %s%.80s%s\n" "${DIM}" "────────────────────────────────────────────────────────────────────────────────" "${RST}"
        while IFS=$'\t' read -r start_ts end_ts cid state stop_reason; do
            [ -z "$start_ts" ] && continue
            local color="${GRN}"
            case "$stop_reason" in Faulted) color="${RED}" ;; Unavailable) color="${YLW}" ;; esac
            printf "  %-22s %-22s %s  %-12s %b%s%s\n" \
                "$start_ts" "$end_ts" "$cid" "$state" "$color" "$stop_reason" "${RST}"
        done < "$file"
        printf "\n"
    fi
}

_show_reboot_timeline() {
    local file="$WORK_DIR/deep_reboots.dat"
    [ -f "$file" ] && [ -s "$file" ] || return

    print_section "Reboot / Crash Timeline"
    printf "  %s%-22s %-16s %s%s\n" "${BLD}" "Timestamp" "Type" "Description" "${RST}"
    printf "  %s%.80s%s\n" "${DIM}" "────────────────────────────────────────────────────────────────────────────────" "${RST}"
    while IFS=$'\t' read -r ts etype desc; do
        [ -z "$ts" ] && continue
        local color="${GRY}"
        case "$etype" in
            kernel_boot)   color="${CYN}" ;;
            kernel_panic)  color="${RED}" ;;
            oom_kill)      color="${RED}" ;;
            watchdog*)     color="${YLW}" ;;
            monit_fail)    color="${RED}" ;;
            monit_restart) color="${YLW}" ;;
            service_crash) color="${RED}" ;;
        esac
        printf "  %-22s %b%-16s%s %s\n" "$ts" "$color" "$etype" "${RST}" "$desc"
    done < "$file"
    printf "\n"
}

_show_connectivity() {
    local file="$WORK_DIR/deep_connectivity.dat"
    [ -f "$file" ] && [ -s "$file" ] || return

    print_section "Network Connectivity Timeline"

    local conn
    conn=$(grep -c 'connected$' "$file" 2>/dev/null || echo 0)
    local disc
    disc=$(grep -c 'disconnected' "$file" 2>/dev/null || echo 0)
    local fail
    fail=$(grep -c 'failed' "$file" 2>/dev/null || echo 0)
    local dns
    dns=$(grep -c 'dns' "$file" 2>/dev/null || echo 0)
    local tls
    tls=$(grep -c 'tls' "$file" 2>/dev/null || echo 0)

    printf "  Connected: %s%d%s  Disconnected: %s%d%s  Failed: %s%d%s" \
        "${GRN}" "$conn" "${RST}" "${YLW}" "$disc" "${RST}" "${RED}" "$fail" "${RST}"
    [ "$(safe_int "$dns")" -gt 0 ] && printf "  DNS errors: %s%d%s" "${RED}" "$dns" "${RST}"
    [ "$(safe_int "$tls")" -gt 0 ] && printf "  TLS errors: %s%d%s" "${RED}" "$tls" "${RST}"
    printf "\n\n"

    printf "  %s%-22s %-14s %s%s\n" "${BLD}" "Timestamp" "Service" "Event" "${RST}"
    printf "  %s%.80s%s\n" "${DIM}" "────────────────────────────────────────────────────────────────────────────────" "${RST}"

    head -40 "$file" | while IFS=$'\t' read -r ts svc event; do
        [ -z "$ts" ] && continue
        local color="${GRY}"
        case "$event" in
            connected)    color="${GRN}" ;;
            disconnected) color="${YLW}" ;;
            failed*|error) color="${RED}" ;;
            reconnecting|connecting) color="${CYN}" ;;
        esac
        printf "  %-22s %-14s %b%s%s\n" "$ts" "$svc" "$color" "$event" "${RST}"
    done
    local total
    total=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    [ "$(safe_int "$total")" -gt 40 ] && printf "  %s... and %d more events%s\n" "${DIM}" "$((total - 40))" "${RST}"
    printf "\n"
}

_show_state_machine() {
    local file="$WORK_DIR/deep_state_machine.dat"
    [ -f "$file" ] && [ -s "$file" ] || return

    print_section "Connector State Machine"
    local sm_count
    sm_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    local wd_warns wd_crits
    wd_warns=$(get_metric "deep_watchdog_warns" 2>/dev/null || echo 0)
    wd_crits=$(get_metric "deep_watchdog_crits" 2>/dev/null || echo 0)

    printf "  Transitions: %s%d%s" "${BLD}" "$sm_count" "${RST}"
    [ "$(safe_int "$wd_warns")" -gt 0 ] && printf "  Watchdog warns: %s%d%s" "${YLW}" "$wd_warns" "${RST}"
    [ "$(safe_int "$wd_crits")" -gt 0 ] && printf "  Watchdog kills: %s%d%s" "${RED}" "$wd_crits" "${RST}"
    printf "\n\n"

    # Show last 20 state transitions
    printf "  %s%-22s %s %-18s %-6s %s%s\n" "${BLD}" "Timestamp" "C" "Machine" "Type" "State/Event" "${RST}"
    printf "  %s%.80s%s\n" "${DIM}" "────────────────────────────────────────────────────────────────────────────────" "${RST}"
    tail -20 "$file" | while IFS=$'\t' read -r ts cid machine etype detail; do
        [ -z "$ts" ] && continue
        local color="${GRY}"
        case "$detail" in
            *Fault*|*Error*) color="${RED}" ;;
            *Available*|*Idle*) color="${GRN}" ;;
            *Charging*) color="${CYN}" ;;
        esac
        printf "  %-22s %s %-18s %-6s %b%s%s\n" "$ts" "$cid" "$machine" "$etype" "$color" "$detail" "${RST}"
    done
    [ "$(safe_int "$sm_count")" -gt 20 ] && printf "  %s... showing last 20 of %d transitions%s\n" "${DIM}" "$sm_count" "${RST}"
    printf "\n"
}

# ═══════════════════════════════════════════════════════════════════════════
# Markdown Output
# ═══════════════════════════════════════════════════════════════════════════
deep_analysis_markdown() {
    printf "## Deep Analysis\n\n"

    # Boot waterfall
    local bf="$WORK_DIR/deep_boot_deltas.dat"
    if [ -f "$bf" ] && [ -s "$bf" ]; then
        printf "### Boot Sequence Waterfall\n\n"
        printf "| Timestamp | Component | Phase | Delta | Description |\n"
        printf "|-----------|-----------|-------|-------|-------------|\n"
        while IFS=$'\t' read -r ts comp phase delta desc; do
            [ -z "$ts" ] && continue
            printf "| %s | %s | %s | +%ss | %s |\n" "$ts" "$comp" "$phase" "$delta" "$desc"
        done < "$bf"
        printf "\n"
    fi

    # Causal chains
    local cf="$WORK_DIR/deep_causal.dat"
    if [ -f "$cf" ] && [ -s "$cf" ]; then
        printf "### Causal Chains\n\n"
        local cn=0
        while IFS=$'\t' read -r type content rest; do
            case "$type" in
                CHAIN) cn=$((cn+1)); printf "#### Chain #%d: %s [%s]\n\n" "$cn" "$content" "${rest:-MEDIUM}" ;;
                CAUSE) printf "%s\n" "- ❌ **CAUSE:** $content" ;;
                EFFECT) printf "%s\n" "- → **EFFECT:** $content" ;;
                ROOT) printf "%s\n\n" "- 💡 **FIX:** $content" ;;
                "---") ;;
            esac
        done < "$cf"
    fi

    # Gaps
    local gf="$WORK_DIR/deep_gaps.dat"
    if [ -f "$gf" ] && [ -s "$gf" ]; then
        local gc
        gc=$(wc -l < "$gf" | tr -d ' ')
        printf "### Log Gaps (>5 min): %d detected\n\n" "$gc"
        printf "| From | To | Duration | Components |\n"
        printf "|------|----|----------|------------|\n"
        sort -t$'\t' -k3 -rn "$gf" 2>/dev/null | head -10 | while IFS=$'\t' read -r from to secs mins cf ct; do
            printf "| %s | %s | %dm | %s → %s |\n" "$from" "$to" "$mins" "$cf" "$ct"
        done
        printf "\n"
    fi

    # Config validation
    local cvf="$WORK_DIR/deep_config_check.dat"
    if [ -f "$cvf" ] && [ -s "$cvf" ]; then
        printf "### Configuration Validation\n\n"
        printf "| Status | Component | Setting | Details |\n"
        printf "|--------|-----------|---------|----------|\n"
        while IFS=$'\t' read -r status comp key note; do
            [ -z "$status" ] && continue
            local icon="✅"
            case "$status" in WARN) icon="⚠️" ;; FAIL) icon="❌" ;; INFO) icon="ℹ️" ;; esac
            printf "| %s | %s | %s | %s |\n" "$icon" "$comp" "$key" "$note"
        done < "$cvf"
        printf "\n"
    fi

    # Error histogram
    local hf="$WORK_DIR/deep_error_histogram.dat"
    if [ -f "$hf" ] && [ -s "$hf" ]; then
        printf "### Error Rate by Hour\n\n"
        printf "| Hour | Total | Critical | High | Medium | Low |\n"
        printf "|------|-------|----------|------|--------|-----|\n"
        while IFS=$'\t' read -r bucket total crit high med low info; do
            [ -z "$bucket" ] && continue
            printf "| %s | %d | %d | %d | %d | %d |\n" "$bucket" "$total" "$crit" "$high" "$med" "$low"
        done < "$hf"
        printf "\n"
    fi

    # Charging sessions
    local sf="$WORK_DIR/deep_sessions.dat"
    if [ -f "$sf" ] && [ -s "$sf" ]; then
        printf "### Charging Sessions\n\n"
        printf "| Start | End | Connector | Reached | Stop Reason |\n"
        printf "|-------|-----|-----------|---------|-------------|\n"
        while IFS=$'\t' read -r s_ts e_ts cid state stop; do
            [ -z "$s_ts" ] && continue
            printf "| %s | %s | %s | %s | %s |\n" "$s_ts" "$e_ts" "$cid" "$state" "$stop"
        done < "$sf"
        printf "\n"
    else
        printf "### Charging Sessions\n\nNo charging sessions detected in log window.\n\n"
    fi

    # Reboot timeline
    local rf="$WORK_DIR/deep_reboots.dat"
    if [ -f "$rf" ] && [ -s "$rf" ]; then
        printf "### Reboot / Crash Timeline\n\n"
        printf "| Timestamp | Type | Description |\n"
        printf "|-----------|------|-------------|\n"
        while IFS=$'\t' read -r ts etype desc; do
            [ -z "$ts" ] && continue
            printf "| %s | %s | %s |\n" "$ts" "$etype" "$desc"
        done < "$rf"
        printf "\n"
    fi

    # Connectivity
    local cf="$WORK_DIR/deep_connectivity.dat"
    if [ -f "$cf" ] && [ -s "$cf" ]; then
        local _conn _disc _fail _dns _tls
        _conn=$(grep -c 'connected$' "$cf" 2>/dev/null || echo 0)
        _disc=$(grep -c 'disconnected' "$cf" 2>/dev/null || echo 0)
        _fail=$(grep -c 'failed' "$cf" 2>/dev/null || echo 0)
        _dns=$(grep -c 'dns' "$cf" 2>/dev/null || echo 0)
        _tls=$(grep -c 'tls' "$cf" 2>/dev/null || echo 0)
        printf "### Network Connectivity\n\n"
        printf "Connected: **%d** | Disconnected: **%d** | Failed: **%d** | DNS errors: **%d** | TLS errors: **%d**\n\n" \
            "$_conn" "$_disc" "$_fail" "$_dns" "$_tls"
        printf "| Timestamp | Service | Event |\n"
        printf "|-----------|---------|-------|\n"
        head -30 "$cf" | while IFS=$'\t' read -r ts svc event; do
            [ -z "$ts" ] && continue
            printf "| %s | %s | %s |\n" "$ts" "$svc" "$event"
        done
        local _total
        _total=$(wc -l < "$cf" 2>/dev/null | tr -d ' ')
        [ "$(safe_int "$_total")" -gt 30 ] && printf "\n*... and %d more events*\n" "$((_total - 30))"
        printf "\n"
    fi

    # State machine
    local smf="$WORK_DIR/deep_state_machine.dat"
    if [ -f "$smf" ] && [ -s "$smf" ]; then
        local _sm_count _wd_w _wd_c
        _sm_count=$(wc -l < "$smf" 2>/dev/null | tr -d ' ')
        _wd_w=$(get_metric "deep_watchdog_warns" 2>/dev/null || echo 0)
        _wd_c=$(get_metric "deep_watchdog_crits" 2>/dev/null || echo 0)
        printf "### Connector State Machine\n\n"
        printf "Transitions: **%d**" "$_sm_count"
        [ "$(safe_int "$_wd_w")" -gt 0 ] && printf " | Watchdog warns: **%d**" "$_wd_w"
        [ "$(safe_int "$_wd_c")" -gt 0 ] && printf " | Watchdog kills: **%d**" "$_wd_c"
        printf "\n\n"
        printf "| Timestamp | C# | Machine | Type | State/Event |\n"
        printf "|-----------|----|---------|----- |-------------|\n"
        tail -20 "$smf" | while IFS=$'\t' read -r ts cid machine etype detail; do
            [ -z "$ts" ] && continue
            printf "| %s | %s | %s | %s | %s |\n" "$ts" "$cid" "$machine" "$etype" "$detail"
        done
        printf "\n"
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# HTML Output
# ═══════════════════════════════════════════════════════════════════════════
deep_analysis_html() {
    printf '<div class="card"><div class="card-header">🔬 Deep Analysis</div>\n'
    printf '<div style="padding:16px;">\n'

    # Boot waterfall
    local bf="$WORK_DIR/deep_boot_deltas.dat"
    if [ -f "$bf" ] && [ -s "$bf" ]; then
        printf '<h3 style="font-size:15px;margin-bottom:10px;color:var(--fg);">Boot Sequence Waterfall</h3>\n'
        printf '<table class="data-table"><thead><tr><th>Timestamp</th><th>Component</th><th>Phase</th><th>Delta</th></tr></thead><tbody>\n'
        while IFS=$'\t' read -r ts comp phase delta desc; do
            [ -z "$ts" ] && continue
            local dnum="${delta%.*}"
            local dcolor="var(--green)"
            [ "${dnum:-0}" -gt 5 ] && dcolor="var(--yellow)"
            [ "${dnum:-0}" -gt 30 ] && dcolor="var(--red)"
            printf '<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td style="color:%s;font-weight:600;">+%ss</td></tr>\n' \
                "$(_html_escape "$ts")" "$(_html_escape "$comp")" "$(_html_escape "$phase")" "$dcolor" "$delta"
        done < "$bf"
        printf '</tbody></table>\n'
    fi

    # Causal chains
    local cf="$WORK_DIR/deep_causal.dat"
    if [ -f "$cf" ] && [ -s "$cf" ]; then
        printf '<h3 style="font-size:15px;margin:16px 0 10px;color:var(--fg);">Causal Chains</h3>\n'
        while IFS=$'\t' read -r type content rest; do
            case "$type" in
                CHAIN) printf '<div style="margin-top:12px;padding:12px;background:var(--bg);border-radius:6px;border-left:3px solid var(--orange);">\n'
                       printf '<strong>⛓ %s</strong> <span class="sev-badge" style="font-size:10px;padding:2px 6px;border-radius:3px;background:var(--orange);color:#000;">%s</span>\n' "$(_html_escape "$content")" "${rest:-MEDIUM}" ;;
                CAUSE) printf '<div style="color:var(--red);font-size:13px;margin:4px 0 0 12px;">❌ %s</div>\n' "$(_html_escape "$content")" ;;
                EFFECT) printf '<div style="color:var(--yellow);font-size:13px;margin:2px 0 0 12px;">→ %s</div>\n' "$(_html_escape "$content")" ;;
                ROOT) printf '<div style="color:var(--green);font-size:13px;margin:4px 0 0 12px;">💡 %s</div>\n' "$(_html_escape "$content")"
                      printf '</div>\n' ;;
            esac
        done < "$cf"
    fi

    # Error histogram as inline bar chart
    local hf="$WORK_DIR/deep_error_histogram.dat"
    if [ -f "$hf" ] && [ -s "$hf" ]; then
        printf '<h3 style="font-size:15px;margin:16px 0 10px;color:var(--fg);">Error Rate by Hour</h3>\n'
        local max_val
        max_val=$(awk -F'\t' 'BEGIN{m=0} {if($2+0>m)m=$2+0} END{print m}' "$hf")
        while IFS=$'\t' read -r bucket total crit high med low info; do
            [ -z "$bucket" ] && continue
            local pct
            pct=$((total * 100 / max_val))
            [ "$pct" -lt 2 ] && pct=2
            printf '<div style="display:flex;align-items:center;gap:8px;margin-bottom:2px;"><code style="font-size:11px;min-width:120px;color:var(--fg3);">%s</code>' "$bucket"
            printf '<div style="flex:1;height:14px;background:var(--bg);border-radius:3px;overflow:hidden;max-width:400px;">'
            printf '<div style="width:%d%%;height:100%%;background:linear-gradient(90deg,var(--red) 0%%,var(--orange) 40%%,var(--blue) 100%%);border-radius:3px;"></div>' "$pct"
            printf '</div><span style="font-family:monospace;font-size:11px;color:var(--fg3);min-width:30px;">%d</span></div>\n' "$total"
        done < "$hf"
    fi

    printf '</div></div>\n'

    # Charging Sessions
    local sf="$WORK_DIR/deep_sessions.dat"
    if [ -f "$sf" ] && [ -s "$sf" ]; then
        printf '<div class="card"><div class="card-header">🔌 Charging Sessions (%d)</div>\n' "$(wc -l < "$sf" | tr -d ' ')"
        printf '<table class="data-table"><thead><tr><th>Start</th><th>End</th><th>Conn</th><th>State</th><th>Stop Reason</th></tr></thead><tbody>\n'
        while IFS=$'\t' read -r s_ts e_ts cid state stop; do
            [ -z "$s_ts" ] && continue
            local scolor="var(--fg)"
            case "$stop" in
                *Faulted*) scolor="var(--red)" ;;
                *incomplete*) scolor="var(--orange)" ;;
                *Available*|*Finishing*) scolor="var(--green)" ;;
            esac
            printf '<tr><td><code>%s</code></td><td><code>%s</code></td><td>%s</td><td>%s</td><td style="color:%s;">%s</td></tr>\n' \
                "$(_html_escape "$s_ts")" "$(_html_escape "$e_ts")" "${cid:-?}" "$(_html_escape "$state")" "$scolor" "$(_html_escape "$stop")"
        done < "$sf"
        printf '</tbody></table></div>\n'
    fi

    # Reboot Timeline
    local rtf="$WORK_DIR/deep_reboots.dat"
    if [ -f "$rtf" ] && [ -s "$rtf" ]; then
        printf '<div class="card"><div class="card-header">🔄 Reboot / Crash Timeline (%d events)</div>\n' "$(wc -l < "$rtf" | tr -d ' ')"
        printf '<table class="data-table"><thead><tr><th>Timestamp</th><th>Type</th><th>Description</th></tr></thead><tbody>\n'
        while IFS=$'\t' read -r ts etype desc; do
            [ -z "$ts" ] && continue
            local tcolor="var(--fg)"
            case "$etype" in
                kernel_boot) tcolor="var(--blue)" ;;
                kernel_panic|oom_kill|watchdog_app) tcolor="var(--red)" ;;
                monit_fail|service_crash) tcolor="var(--orange)" ;;
                monit_restart) tcolor="var(--yellow)" ;;
            esac
            printf '<tr><td><code>%s</code></td><td style="color:%s;font-weight:600;">%s</td><td>%s</td></tr>\n' \
                "$(_html_escape "$ts")" "$tcolor" "$(_html_escape "$etype")" "$(_html_escape "$desc")"
        done < "$rtf"
        printf '</tbody></table></div>\n'
    fi

    # Network Connectivity
    local ctf="$WORK_DIR/deep_connectivity.dat"
    if [ -f "$ctf" ] && [ -s "$ctf" ]; then
        local _hconn _hdisc _hfail _hdns _htls
        _hconn=$(grep -c 'ocpp.*connecting$' "$ctf" 2>/dev/null || echo 0)
        _hdisc=$(grep -c 'disconnected' "$ctf" 2>/dev/null || echo 0)
        _hfail=$(grep -c 'ocpp.*failed' "$ctf" 2>/dev/null || echo 0)
        _hdns=$(grep -c 'dns' "$ctf" 2>/dev/null || echo 0)
        _htls=$(grep -c 'tls' "$ctf" 2>/dev/null || echo 0)
        printf '<div class="card"><div class="card-header">🌐 Network Connectivity (%d events)</div>\n' "$(wc -l < "$ctf" | tr -d ' ')"
        printf '<div style="padding:12px 16px;font-size:13px;color:var(--fg3);">Connecting: %d · Disconnected: %d · Failed: %d · DNS errors: %d · TLS errors: %d</div>\n' \
            "$_hconn" "$_hdisc" "$_hfail" "$_hdns" "$_htls"
        printf '<table class="data-table"><thead><tr><th>Timestamp</th><th>Service</th><th>Event</th></tr></thead><tbody>\n'
        head -40 "$ctf" | while IFS=$'\t' read -r ts svc event; do
            [ -z "$ts" ] && continue
            local ecolor="var(--fg)"
            case "$event" in
                connecting) ecolor="var(--blue)" ;;
                disconnected|failed*) ecolor="var(--red)" ;;
                reconnecting) ecolor="var(--orange)" ;;
                accepted) ecolor="var(--green)" ;;
            esac
            printf '<tr><td><code>%s</code></td><td>%s</td><td style="color:%s;">%s</td></tr>\n' \
                "$(_html_escape "$ts")" "$(_html_escape "$svc")" "$ecolor" "$(_html_escape "$event")"
        done
        printf '</tbody></table></div>\n'
    fi

    # State Machine
    local smf="$WORK_DIR/deep_state_machine.dat"
    if [ -f "$smf" ] && [ -s "$smf" ]; then
        local _hsm _hww _hwc
        _hsm=$(wc -l < "$smf" | tr -d ' ')
        _hww=$(get_metric "deep_watchdog_warns" 2>/dev/null || echo 0)
        _hwc=$(get_metric "deep_watchdog_crits" 2>/dev/null || echo 0)
        printf '<div class="card"><div class="card-header">⚡ State Machine (%d transitions)</div>\n' "$_hsm"
        [ "$(safe_int "$_hww")" -gt 0 ] || [ "$(safe_int "$_hwc")" -gt 0 ] && \
            printf '<div style="padding:12px 16px;font-size:13px;color:var(--fg3);">Watchdog: %s warns, %s criticals</div>\n' "$_hww" "$_hwc"
        printf '<table class="data-table"><thead><tr><th>Timestamp</th><th>Conn</th><th>Machine</th><th>Type</th><th>Detail</th></tr></thead><tbody>\n'
        tail -20 "$smf" | while IFS=$'\t' read -r ts cid machine etype detail; do
            [ -z "$ts" ] && continue
            local dcolor="var(--fg)"
            case "$detail" in
                *Fault*|*NotAvailable*) dcolor="var(--red)" ;;
                *Available*) dcolor="var(--green)" ;;
                *Charging*) dcolor="var(--blue)" ;;
            esac
            printf '<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s</td><td style="color:%s;">%s</td></tr>\n' \
                "$(_html_escape "$ts")" "${cid:-?}" "$(_html_escape "$machine")" "$(_html_escape "$etype")" "$dcolor" "$(_html_escape "$detail")"
        done
        printf '</tbody></table></div>\n'
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# JSON Output (for web app)
# ═══════════════════════════════════════════════════════════════════════════
deep_analysis_json() {
    echo '"deepAnalysis": {'

    # Boot timing
    echo '  "bootTiming": ['
    local first=1
    local bf="$WORK_DIR/deep_boot_deltas.dat"
    if [ -f "$bf" ] && [ -s "$bf" ]; then
        while IFS=$'\t' read -r ts comp phase delta desc; do
            [ -z "$ts" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '    {"ts":"%s","component":"%s","phase":"%s","delta":%s,"desc":"%s"}' \
                "$(_json_escape "$ts")" "$(_json_escape "$comp")" "$(_json_escape "$phase")" "${delta:-0}" "$(_json_escape "$desc")"
        done < "$bf"
    fi
    echo ''
    echo '  ],'

    # Causal chains
    echo '  "causalChains": ['
    first=1
    local cf="$WORK_DIR/deep_causal.dat"
    if [ -f "$cf" ] && [ -s "$cf" ]; then
        local in_chain=0
        while IFS=$'\t' read -r type content rest; do
            case "$type" in
                CHAIN)
                    [ "$in_chain" -eq 1 ] && echo '    ]},'
                    [ "$first" -eq 1 ] && first=0
                    in_chain=1
                    printf '    {"name":"%s","severity":"%s","steps":[' "$(_json_escape "$content")" "$(_json_escape "${rest:-MEDIUM}")"
                    local step_first=1
                    ;;
                CAUSE|EFFECT|ROOT)
                    [ "$step_first" -eq 1 ] && step_first=0 || printf ','
                    printf '{"type":"%s","text":"%s"}' "$type" "$(_json_escape "$content")"
                    ;;
                "---") ;;
            esac
        done < "$cf"
        [ "$in_chain" -eq 1 ] && echo '    ]}'
    fi
    echo ''
    echo '  ],'

    # Error histogram
    echo '  "errorHistogram": ['
    first=1
    local hf="$WORK_DIR/deep_error_histogram.dat"
    if [ -f "$hf" ] && [ -s "$hf" ]; then
        while IFS=$'\t' read -r bucket total crit high med low info; do
            [ -z "$bucket" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '    {"hour":"%s","total":%d,"critical":%d,"high":%d,"medium":%d,"low":%d}' \
                "$(_json_escape "$bucket")" "$total" "$crit" "$high" "$med" "$low"
        done < "$hf"
    fi
    echo ''
    echo '  ],'

    # Gaps
    echo '  "gaps": ['
    first=1
    local gf="$WORK_DIR/deep_gaps.dat"
    if [ -f "$gf" ] && [ -s "$gf" ]; then
        sort -t$'\t' -k3 -rn "$gf" 2>/dev/null | head -20 | while IFS=$'\t' read -r from to secs mins cf ct; do
            [ -z "$from" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '    {"from":"%s","to":"%s","seconds":%d,"minutes":%d}' \
                "$(_json_escape "$from")" "$(_json_escape "$to")" "$secs" "$mins"
        done
    fi
    echo ''
    echo '  ],'

    # Config checks
    echo '  "configChecks": ['
    first=1
    local cvf="$WORK_DIR/deep_config_check.dat"
    if [ -f "$cvf" ] && [ -s "$cvf" ]; then
        while IFS=$'\t' read -r status comp key note; do
            [ -z "$status" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '    {"status":"%s","component":"%s","key":"%s","note":"%s"}' \
                "$status" "$(_json_escape "$comp")" "$(_json_escape "$key")" "$(_json_escape "$note")"
        done < "$cvf"
    fi
    echo ''
    echo '  ],'

    # Charging sessions
    echo '  "chargingSessions": ['
    first=1
    local sf="$WORK_DIR/deep_sessions.dat"
    if [ -f "$sf" ] && [ -s "$sf" ]; then
        while IFS=$'\t' read -r s_ts e_ts cid state stop; do
            [ -z "$s_ts" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '    {"start":"%s","end":"%s","connector":%s,"state":"%s","stopReason":"%s"}' \
                "$(_json_escape "$s_ts")" "$(_json_escape "$e_ts")" "${cid:-0}" "$(_json_escape "$state")" "$(_json_escape "$stop")"
        done < "$sf"
    fi
    echo ''
    echo '  ],'

    # Reboot timeline
    echo '  "rebootTimeline": ['
    first=1
    local rtf="$WORK_DIR/deep_reboots.dat"
    if [ -f "$rtf" ] && [ -s "$rtf" ]; then
        while IFS=$'\t' read -r ts etype desc; do
            [ -z "$ts" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '    {"ts":"%s","type":"%s","desc":"%s"}' \
                "$(_json_escape "$ts")" "$(_json_escape "$etype")" "$(_json_escape "$desc")"
        done < "$rtf"
    fi
    echo ''
    echo '  ],'

    # Connectivity
    echo '  "connectivity": {'
    local ctf="$WORK_DIR/deep_connectivity.dat"
    local _jconn=0 _jdisc=0 _jfail=0 _jdns=0 _jtls=0
    if [ -f "$ctf" ] && [ -s "$ctf" ]; then
        _jconn=$(grep -c 'ocpp.*connecting$' "$ctf" 2>/dev/null || echo 0)
        _jdisc=$(grep -c 'disconnected' "$ctf" 2>/dev/null || echo 0)
        _jfail=$(grep -c 'ocpp.*failed' "$ctf" 2>/dev/null || echo 0)
        _jdns=$(grep -c 'dns' "$ctf" 2>/dev/null || echo 0)
        _jtls=$(grep -c 'tls' "$ctf" 2>/dev/null || echo 0)
    fi
    printf '    "connected":%d,"disconnected":%d,"failed":%d,"dnsErrors":%d,"tlsErrors":%d,' \
        "$_jconn" "$_jdisc" "$_jfail" "$_jdns" "$_jtls"
    echo ''
    echo '    "events": ['
    first=1
    if [ -f "$ctf" ] && [ -s "$ctf" ]; then
        head -50 "$ctf" | while IFS=$'\t' read -r ts svc event; do
            [ -z "$ts" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '      {"ts":"%s","service":"%s","event":"%s"}' \
                "$(_json_escape "$ts")" "$(_json_escape "$svc")" "$(_json_escape "$event")"
        done
    fi
    echo ''
    echo '    ]'
    echo '  },'

    # State machine
    echo '  "stateMachine": {'
    local smf="$WORK_DIR/deep_state_machine.dat"
    local _jsm=0 _jww=0 _jwc=0
    if [ -f "$smf" ]; then
        _jsm=$(wc -l < "$smf" 2>/dev/null | tr -d ' ')
    fi
    _jww=$(get_metric "deep_watchdog_warns" 2>/dev/null || echo 0)
    _jwc=$(get_metric "deep_watchdog_crits" 2>/dev/null || echo 0)
    printf '    "transitions":%d,"watchdogWarns":%d,"watchdogCrits":%d,' \
        "$_jsm" "$(safe_int "$_jww")" "$(safe_int "$_jwc")"
    echo ''
    echo '    "events": ['
    first=1
    if [ -f "$smf" ] && [ -s "$smf" ]; then
        tail -30 "$smf" | while IFS=$'\t' read -r ts cid machine etype detail; do
            [ -z "$ts" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '      {"ts":"%s","connector":%s,"machine":"%s","type":"%s","detail":"%s"}' \
                "$(_json_escape "$ts")" "${cid:-0}" "$(_json_escape "$machine")" "$(_json_escape "$etype")" "$(_json_escape "$detail")"
        done
    fi
    echo ''
    echo '    ]'
    echo '  },'

    # PMQ map
    echo '  "pmqMap": ['
    first=1
    local pf="$WORK_DIR/deep_pmq_map.dat"
    if [ -f "$pf" ] && [ -s "$pf" ]; then
        head -100 "$pf" | while IFS=$'\t' read -r src dst ptype; do
            [ -z "$src" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '    {"source":"%s","dest":"%s","type":"%s"}' \
                "$(_json_escape "$src")" "$(_json_escape "$dst")" "$(_json_escape "$ptype")"
        done
    fi
    echo ''
    echo '  ]'

    echo '}'
}
