#!/bin/bash
# scorer.sh — Health Score Calculator
# Loggy v6.0
#
# Calculates a 0–100 health score across 4 weighted categories:
#   Connectivity (30%) — MQTT, PPP, Ethernet, WiFi
#   Hardware (25%)     — PowerBoard, temperature, eMMC, kernel, memory, safety
#   Services (25%)     — OCPP, V2G/HLC, EnergyManager, PMQ, certs, ErrorBoss, meter
#   Configuration (20%) — Config keys, boot count, reboots, registry matches
#
# Severity mapping from error registry:
#   error_block_all_sessions → CRITICAL → -25 to -35 per hit category
#   locked_warning           → HIGH     → -15 to -20
#   warning_reset_current_session → HIGH → -10 to -15
#   error                    → MEDIUM   → -8 to -12
#   warning                  → LOW      → -3 to -5

HEALTH_SCORE=0
HEALTH_GRADE=""
HEALTH_SCORES_CONN=0
HEALTH_SCORES_HW=0
HEALTH_SCORES_SVC=0
HEALTH_SCORES_CFG=0
# Penalty reason arrays — populated during scoring, displayed with score
HEALTH_REASONS_CONN=()
HEALTH_REASONS_HW=()
HEALTH_REASONS_SVC=()
HEALTH_REASONS_CFG=()

# Helper: record a penalty reason
_score_penalty() {
    local category="$1" points="$2" reason="$3"
    case "$category" in
        conn) HEALTH_REASONS_CONN+=("-${points}  ${reason}") ;;
        hw)   HEALTH_REASONS_HW+=("-${points}  ${reason}") ;;
        svc)  HEALTH_REASONS_SVC+=("-${points}  ${reason}") ;;
        cfg)  HEALTH_REASONS_CFG+=("-${points}  ${reason}") ;;
    esac
}

# ─── Category Weights (rebalanced from source registry analysis) ────────────
# Hardware + Services carry more weight now that we detect 363 official errors
WEIGHT_CONN=30
WEIGHT_HW=25
WEIGHT_SVC=25
WEIGHT_CFG=20

# ─── Score Calculation ───────────────────────────────────────────────────────
calculate_health_score() {
    local m  # helper for metric reads

    # ═══ Connectivity (0–100) ═══════════════════════════════════════════════
    local conn_score=100

    # MQTT: fail ratio
    local mqtt_fail mqtt_ok mqtt_total mqtt_ratio
    mqtt_fail=$(safe_int "$(get_metric i2p2_mqtt_fail_count)")
    mqtt_ok=$(safe_int "$(get_metric i2p2_mqtt_ok_count)")
    mqtt_total=$((mqtt_fail + mqtt_ok))
    if [ "$mqtt_total" -gt 0 ]; then
        # Fail ratio: 0% = perfect, 100% = all failing
        mqtt_ratio=$((mqtt_fail * 100 / mqtt_total))
        if [ "$mqtt_ratio" -gt 80 ]; then
            conn_score=$((conn_score - 35)); _score_penalty conn 35 "MQTT failure rate ${mqtt_ratio}% (critical)"
        elif [ "$mqtt_ratio" -gt 50 ]; then
            conn_score=$((conn_score - 25)); _score_penalty conn 25 "MQTT failure rate ${mqtt_ratio}% (high)"
        elif [ "$mqtt_ratio" -gt 20 ]; then
            conn_score=$((conn_score - 15)); _score_penalty conn 15 "MQTT failure rate ${mqtt_ratio}% (elevated)"
        elif [ "$mqtt_ratio" -gt 5 ]; then
            conn_score=$((conn_score - 8)); _score_penalty conn 8 "MQTT failure rate ${mqtt_ratio}% (minor)"
        fi
    elif [ "$(get_status MQTT)" = "down" ]; then
        conn_score=$((conn_score - 35)); _score_penalty conn 35 "MQTT status: down"
    fi

    # PPP: status
    local ppp_status
    ppp_status=$(get_status PPP)
    case "$ppp_status" in
        down)     conn_score=$((conn_score - 30)); _score_penalty conn 30 "PPP link down" ;;
        degraded) conn_score=$((conn_score - 15)); _score_penalty conn 15 "PPP link degraded" ;;
    esac

    # Ethernet: flapping
    local eth_flaps
    eth_flaps=$(safe_int "$(get_metric eth_flap_cycles)")
    if [ "$eth_flaps" -gt 10 ]; then
        conn_score=$((conn_score - 20)); _score_penalty conn 20 "Ethernet flapping x${eth_flaps} (severe)"
    elif [ "$eth_flaps" -gt 5 ]; then
        conn_score=$((conn_score - 12)); _score_penalty conn 12 "Ethernet flapping x${eth_flaps}"
    elif [ "$eth_flaps" -gt 2 ]; then
        conn_score=$((conn_score - 6)); _score_penalty conn 6 "Ethernet flapping x${eth_flaps} (minor)"
    fi

    # Backoff count (connection instability)
    local backoff
    backoff=$(safe_int "$(get_metric i2p2_backoff_count)")
    if [ "$backoff" -gt 50 ]; then
        conn_score=$((conn_score - 10)); _score_penalty conn 10 "Connection backoff x${backoff} (severe)"
    elif [ "$backoff" -gt 20 ]; then
        conn_score=$((conn_score - 5)); _score_penalty conn 5 "Connection backoff x${backoff}"
    fi

    [ "$conn_score" -lt 0 ] && conn_score=0

    # WiFi failures (source-informed: NETWORK_NOT_FOUND, CONN_FAILED, SSID-TEMP-DISABLED)
    local wifi_fail
    wifi_fail=$(safe_int "$(get_metric wifi_failures)")
    wifi_fail=$((wifi_fail + $(safe_int "$(get_metric wifi_ssid_notfound)")))
    wifi_fail=$((wifi_fail + $(safe_int "$(get_metric wifi_conn_failed)")))
    if [ "$wifi_fail" -gt 10 ]; then
        conn_score=$((conn_score - 15)); _score_penalty conn 15 "WiFi failures x${wifi_fail}"
    elif [ "$wifi_fail" -gt 3 ]; then
        conn_score=$((conn_score - 8)); _score_penalty conn 8 "WiFi failures x${wifi_fail} (minor)"
    fi

    # OCPP connection error (registry: OCPP_CONNECTION_ERROR — on-site service required)
    local ocpp_conn_err
    ocpp_conn_err=$(safe_int "$(get_metric ocpp_connection_error)")
    if [ "$ocpp_conn_err" -gt 0 ]; then
        conn_score=$((conn_score - 15)); _score_penalty conn 15 "OCPP connection error x${ocpp_conn_err}"
    fi

    [ "$conn_score" -lt 0 ] && conn_score=0
    HEALTH_SCORES_CONN=$conn_score

    # ═══ Hardware (0–100) ════════════════════════════════════════════════════
    local hw_score=100

    # PowerBoard faults
    local cpstate_faults
    cpstate_faults=$(safe_int "$(get_metric cpstate_fault_count)")
    if [ "$cpstate_faults" -gt 20 ]; then
        hw_score=$((hw_score - 35))
    elif [ "$cpstate_faults" -gt 5 ]; then
        hw_score=$((hw_score - 20))
    elif [ "$cpstate_faults" -gt 0 ]; then
        hw_score=$((hw_score - 10))
    fi

    # PowerBoard status
    local pb_status
    pb_status=$(get_status PowerBoard)
    case "$pb_status" in
        down)     hw_score=$((hw_score - 25)); _score_penalty hw 25 "PowerBoard status: down" ;;
        degraded) hw_score=$((hw_score - 12)); _score_penalty hw 12 "PowerBoard status: degraded" ;;
    esac

    # Kernel errors
    local kern_errs
    kern_errs=$(safe_int "$(get_metric kern_errors)")
    if [ "$kern_errs" -gt 20 ]; then
        hw_score=$((hw_score - 15)); _score_penalty hw 15 "Kernel errors x${kern_errs} (critical)"
    elif [ "$kern_errs" -gt 5 ]; then
        hw_score=$((hw_score - 8)); _score_penalty hw 8 "Kernel errors x${kern_errs}"
    fi

    # GPIO failures (health monitor)
    local gpio_fail
    gpio_fail=$(safe_int "$(get_metric hm_gpio_fail)")
    if [ "$gpio_fail" -gt 5 ]; then
        hw_score=$((hw_score - 10)); _score_penalty hw 10 "GPIO failures x${gpio_fail}"
    elif [ "$gpio_fail" -gt 0 ]; then
        hw_score=$((hw_score - 5)); _score_penalty hw 5 "GPIO failures x${gpio_fail} (minor)"
    fi

    # Memory (if available)
    local mem_total mem_avail mem_pct
    mem_total=$(safe_int "$(get_sysinfo mem_total_kb)")
    mem_avail=$(safe_int "$(get_sysinfo mem_available_kb)")
    if [ "$mem_total" -gt 0 ] && [ "$mem_avail" -gt 0 ]; then
        mem_pct=$((mem_avail * 100 / mem_total))
        if [ "$mem_pct" -lt 10 ]; then
            hw_score=$((hw_score - 15))
        elif [ "$mem_pct" -lt 20 ]; then
            hw_score=$((hw_score - 8))
        fi
    fi

    # Emergency stop events
    local emerg
    emerg=$(safe_int "$(get_metric emergency_stop)")
    if [ "$emerg" -gt 0 ]; then
        hw_score=$((hw_score - 25)); _score_penalty hw 25 "Emergency stop x${emerg}"
    fi

    # Tamper detection
    local tamper
    tamper=$(safe_int "$(get_metric tamper_events)")
    if [ "$tamper" -gt 0 ]; then
        hw_score=$((hw_score - 15)); _score_penalty hw 15 "Tamper events x${tamper}"
    fi

    # eMMC/Storage degradation
    local emmc_wear storage_fb
    emmc_wear=$(safe_int "$(get_metric hm_emmc_wear)")
    storage_fb=$(safe_int "$(get_metric hm_storage_fallback)")
    if [ "$storage_fb" -gt 0 ]; then
        hw_score=$((hw_score - 20)); _score_penalty hw 20 "Storage fallback active"
    elif [ "$emmc_wear" -gt 0 ]; then
        hw_score=$((hw_score - 10)); _score_penalty hw 10 "eMMC wear detected"
    fi

    # Grid code safety events (inverter disconnections)
    local grid_events
    grid_events=$(safe_int "$(get_metric grid_freq_events)")
    grid_events=$((grid_events + $(safe_int "$(get_metric grid_volt_events)")))
    if [ "$grid_events" -gt 5 ]; then
        hw_score=$((hw_score - 20)); _score_penalty hw 20 "Grid code events x${grid_events}"
    elif [ "$grid_events" -gt 0 ]; then
        hw_score=$((hw_score - 10)); _score_penalty hw 10 "Grid code events x${grid_events} (minor)"
    fi

    # HMI board failures
    local hmi_fail
    hmi_fail=$(safe_int "$(get_metric hmi_failures)")
    hmi_fail=$((hmi_fail + $(safe_int "$(get_metric hmi_timeouts)")))
    if [ "$hmi_fail" -gt 5 ]; then
        hw_score=$((hw_score - 10))
    elif [ "$hmi_fail" -gt 0 ]; then
        hw_score=$((hw_score - 5))
    fi

    # Temperature / overtemperature (registry: error_block_all_sessions)
    local temp_crit temp_max
    temp_crit=$(safe_int "$(get_metric temp_critical)")
    temp_max=$(safe_int "$(get_metric temp_max_derating)")
    if [ "$temp_crit" -gt 0 ] || [ "$temp_max" -gt 0 ]; then
        hw_score=$((hw_score - 25)); _score_penalty hw 25 "Overtemperature/max derating (CRITICAL)"
    fi
    local temp_derating
    temp_derating=$(safe_int "$(get_metric temp_derating)")
    if [ "$temp_derating" -gt 5 ]; then
        hw_score=$((hw_score - 10))
    elif [ "$temp_derating" -gt 0 ]; then
        hw_score=$((hw_score - 5))
    fi

    # Lid open / tamper (registry: error_block_all_sessions for LidOpen)
    local lid_open
    lid_open=$(safe_int "$(get_metric lid_open)")
    if [ "$lid_open" -gt 0 ]; then
        hw_score=$((hw_score - 20)); _score_penalty hw 20 "Lid open detected x${lid_open}"
    fi

    # PowerBoard firmware update failed (registry: error_block_all_sessions)
    local fw_pb
    fw_pb=$(safe_int "$(get_metric fw_powerboard_fail)")
    if [ "$fw_pb" -gt 0 ]; then
        hw_score=$((hw_score - 25)); _score_penalty hw 25 "PowerBoard firmware update failed"
    fi

    # HAL hardware errors (CIU/MIU — all CRITICAL/blocks)
    local hal_t
    hal_t=$(safe_int "$(get_metric hal_total)")
    if [ "$hal_t" -gt 5 ]; then
        hw_score=$((hw_score - 25)); _score_penalty hw 25 "HAL hardware errors x${hal_t} (CRITICAL)"
    elif [ "$hal_t" -gt 0 ]; then
        hw_score=$((hw_score - 15)); _score_penalty hw 15 "HAL hardware errors x${hal_t}"
    fi

    # DC EVIC GlobalStop (CableCheck, IMD, Rectifier, Contactor)
    local dc_evic
    dc_evic=$(safe_int "$(get_metric dc_evic_cablecheck)")
    dc_evic=$((dc_evic + $(safe_int "$(get_metric dc_evic_imd)")))
    dc_evic=$((dc_evic + $(safe_int "$(get_metric dc_evic_rectifier)")))
    dc_evic=$((dc_evic + $(safe_int "$(get_metric dc_evic_contactor)")))
    if [ "$dc_evic" -gt 5 ]; then
        hw_score=$((hw_score - 20)); _score_penalty hw 20 "DC EVIC GlobalStop x${dc_evic}"
    elif [ "$dc_evic" -gt 0 ]; then
        hw_score=$((hw_score - 10)); _score_penalty hw 10 "DC EVIC GlobalStop x${dc_evic} (minor)"
    fi

    # PowerBoard stop codes (overcurrent, ground fault, relay, bender)
    local pb_stops
    pb_stops=$(safe_int "$(get_metric pb_stopcode_total)")
    if [ "$pb_stops" -gt 10 ]; then
        hw_score=$((hw_score - 20)); _score_penalty hw 20 "PowerBoard stop codes x${pb_stops}"
    elif [ "$pb_stops" -gt 0 ]; then
        hw_score=$((hw_score - 10)); _score_penalty hw 10 "PowerBoard stop codes x${pb_stops} (minor)"
    fi

    # EVIC reboots (CommonEVIC — hardware instability)
    local evic_rb
    evic_rb=$(safe_int "$(get_metric evic_reboots)")
    if [ "$evic_rb" -gt 3 ]; then
        hw_score=$((hw_score - 10))
    fi

    # Connector imbalance (one connector has disproportionate errors)
    local c1_err c2_err multi_conn
    c1_err=$(safe_int "$(get_metric conn1_errors)")
    c2_err=$(safe_int "$(get_metric conn2_errors)")
    multi_conn=$(safe_int "$(get_metric multi_connector)")
    if [ "$multi_conn" -eq 1 ]; then
        # If one connector has 5x+ more errors → likely hardware fault on that connector
        local worse_err=$c1_err better_err=$c2_err
        [ "$c2_err" -gt "$c1_err" ] && worse_err=$c2_err && better_err=$c1_err
        if [ "$worse_err" -gt 5 ] && [ "$better_err" -gt 0 ] && [ "$((worse_err / (better_err > 0 ? better_err : 1)))" -ge 5 ]; then
            hw_score=$((hw_score - 15))
        elif [ "$worse_err" -gt 3 ] && [ "$better_err" -eq 0 ]; then
            hw_score=$((hw_score - 10))
        fi
    fi

    [ "$hw_score" -lt 0 ] && hw_score=0
    HEALTH_SCORES_HW=$hw_score

    # ═══ Services (0–100) ════════════════════════════════════════════════════
    local svc_score=100

    # OCPP
    local ocpp_conn ocpp_fail
    ocpp_conn=$(safe_int "$(get_metric ocpp_ws_connected)")
    ocpp_fail=$(safe_int "$(get_metric ocpp_ws_failed)")
    if [ "$ocpp_conn" -eq 0 ] && [ "$ocpp_fail" -gt 0 ]; then
        svc_score=$((svc_score - 25))
    fi

    # EVCC watchdog
    local evcc_wd
    evcc_wd=$(safe_int "$(get_metric evcc_watchdog_count)")
    if [ "$evcc_wd" -gt 500 ]; then
        svc_score=$((svc_score - 20))
    elif [ "$evcc_wd" -gt 100 ]; then
        svc_score=$((svc_score - 12))
    elif [ "$evcc_wd" -gt 20 ]; then
        svc_score=$((svc_score - 5))
    fi

    # PMQ subscription failures
    local pmq_fail
    pmq_fail=$(safe_int "$(get_metric em_pmq_sub_fail)")
    if [ "$pmq_fail" -gt 20 ]; then
        svc_score=$((svc_score - 15))
    elif [ "$pmq_fail" -gt 5 ]; then
        svc_score=$((svc_score - 8))
    elif [ "$pmq_fail" -gt 0 ]; then
        svc_score=$((svc_score - 3))
    fi

    # Certificate failures
    local cert_fail
    cert_fail=$(safe_int "$(get_metric cert_load_failures)")
    if [ "$cert_fail" -gt 20 ]; then
        svc_score=$((svc_score - 20))
    elif [ "$cert_fail" -gt 5 ]; then
        svc_score=$((svc_score - 12))
    elif [ "$cert_fail" -gt 0 ]; then
        svc_score=$((svc_score - 5))
    fi

    # Service down count
    local svc_down
    svc_down=$(safe_int "$(get_metric hm_service_down)")
    if [ "$svc_down" -gt 10 ]; then
        svc_score=$((svc_score - 15)); _score_penalty svc 15 "Services down x${svc_down}"
    elif [ "$svc_down" -gt 3 ]; then
        svc_score=$((svc_score - 8)); _score_penalty svc 8 "Services down x${svc_down} (minor)"
    fi

    # Monit process restarts
    local monit_rst
    monit_rst=$(safe_int "$(get_metric monit_restarts)")
    if [ "$monit_rst" -gt 20 ]; then
        svc_score=$((svc_score - 15))
    elif [ "$monit_rst" -gt 5 ]; then
        svc_score=$((svc_score - 8))
    fi

    # Firmware update failures
    local fw_fail
    fw_fail=$(safe_int "$(get_metric fw_update_fail)")
    if [ "$fw_fail" -gt 0 ]; then
        svc_score=$((svc_score - 10)); _score_penalty svc 10 "Firmware update failed x${fw_fail}"
    fi

    # OCPP BootNotification never accepted
    local boot_notif boot_accepted
    boot_notif=$(safe_int "$(get_metric ocpp_boot_notif)")
    boot_accepted=$(safe_int "$(get_metric ocpp_boot_accepted)")
    if [ "$boot_notif" -gt 2 ] && [ "$boot_accepted" -eq 0 ]; then
        svc_score=$((svc_score - 15)); _score_penalty svc 15 "OCPP BootNotification never accepted"
    fi

    # ErrorBoss blocking errors
    local eb_block
    eb_block=$(safe_int "$(get_metric eb_block_errors)")
    if [ "$eb_block" -gt 0 ]; then
        svc_score=$((svc_score - 20)); _score_penalty svc 20 "ErrorBoss blocking errors x${eb_block}"
    fi

    # V2G/HLC errors
    local v2g_err
    v2g_err=$(safe_int "$(get_metric v2g_errors)")
    v2g_err=$((v2g_err + $(safe_int "$(get_metric v2g_timeouts)")))
    if [ "$v2g_err" -gt 20 ]; then
        svc_score=$((svc_score - 15))
    elif [ "$v2g_err" -gt 5 ]; then
        svc_score=$((svc_score - 8))
    fi

    # Cable check / IMD failures (DC charging critical)
    local cable_chk
    cable_chk=$(safe_int "$(get_metric v2g_cable_check_fail)")
    if [ "$cable_chk" -gt 0 ]; then
        svc_score=$((svc_score - 12))
    fi

    # Meter / Eichrecht
    local meter_fail
    meter_fail=$(safe_int "$(get_metric meter_not_found)")
    meter_fail=$((meter_fail + $(safe_int "$(get_metric meter_conn_fail)")))
    if [ "$meter_fail" -gt 5 ]; then
        svc_score=$((svc_score - 12))
    elif [ "$meter_fail" -gt 0 ]; then
        svc_score=$((svc_score - 5))
    fi
    local eich_err
    eich_err=$(safe_int "$(get_metric eichrecht_terminal)")
    eich_err=$((eich_err + $(safe_int "$(get_metric eichrecht_unavail)")))
    if [ "$eich_err" -gt 0 ]; then
        svc_score=$((svc_score - 25)); _score_penalty svc 25 "Eichrecht/billing errors x${eich_err}"
    fi
    local eich_orphan
    eich_orphan=$(safe_int "$(get_metric eichrecht_orphan)")
    if [ "$eich_orphan" -gt 0 ]; then
        svc_score=$((svc_score - 10))
    fi

    # Required meter missing (registry: error_block_all_sessions)
    local meter_miss_crit
    meter_miss_crit=$(safe_int "$(get_metric meter_missing_critical)")
    if [ "$meter_miss_crit" -gt 0 ]; then
        svc_score=$((svc_score - 25)); _score_penalty svc 25 "Required meter missing (CRITICAL — blocks charging)"
    fi

    # EnergyManager session start failure (registry: warning_reset_current_session)
    local em_sess_err
    em_sess_err=$(safe_int "$(get_metric em_session_start_err)")
    if [ "$em_sess_err" -gt 0 ]; then
        svc_score=$((svc_score - 10))
    fi

    # Power imbalance (registry: warning_reset_current_session)
    local em_imbal
    em_imbal=$(safe_int "$(get_metric em_power_imbalance)")
    if [ "$em_imbal" -gt 0 ]; then
        svc_score=$((svc_score - 8))
    fi

    # Monit: ProcessRestartedTooOften (more severe than simple restarts)
    local monit_too_often
    monit_too_often=$(safe_int "$(get_metric monit_too_often)")
    if [ "$monit_too_often" -gt 0 ]; then
        svc_score=$((svc_score - 15))
    fi

    # InnerSM critical (ERROR_UNAVAILABLE, REPEATING_ERRORS — blocks sessions)
    local ism_c
    ism_c=$(safe_int "$(get_metric ism_critical)")
    if [ "$ism_c" -gt 0 ]; then
        svc_score=$((svc_score - 20)); _score_penalty svc 20 "InnerSM critical errors x${ism_c}"
    fi

    # InnerSM charging confirmation failures
    local ism_cf
    ism_cf=$(safe_int "$(get_metric ism_confirm_fail)")
    if [ "$ism_cf" -gt 0 ]; then
        svc_score=$((svc_score - 10))
    fi

    # Compliance: EV disobeys limits / overcurrent
    local ev_dis soft_oc
    ev_dis=$(safe_int "$(get_metric ev_disobey_limit)")
    soft_oc=$(safe_int "$(get_metric soft_overcurrent)")
    if [ "$ev_dis" -gt 0 ] || [ "$soft_oc" -gt 0 ]; then
        svc_score=$((svc_score - 10))
    fi

    # OCPP: transactions rejected before boot accepted
    local txn_rej
    txn_rej=$(safe_int "$(get_metric ocpp_txn_rejected_preboot)")
    if [ "$txn_rej" -gt 0 ]; then
        svc_score=$((svc_score - 8))
    fi

    [ "$svc_score" -lt 0 ] && svc_score=0
    HEALTH_SCORES_SVC=$svc_score

    # ═══ Configuration / Stability (0–100) ══════════════════════════════════
    local cfg_score=100

    # Reboots
    local reboots
    reboots=$(safe_int "$(get_metric hm_reboots)")
    if [ "$reboots" -gt 50 ]; then
        cfg_score=$((cfg_score - 30)); _score_penalty cfg 30 "Reboots x${reboots} (critical)"
    elif [ "$reboots" -gt 20 ]; then
        cfg_score=$((cfg_score - 18)); _score_penalty cfg 18 "Reboots x${reboots} (high)"
    elif [ "$reboots" -gt 5 ]; then
        cfg_score=$((cfg_score - 10)); _score_penalty cfg 10 "Reboots x${reboots}"
    elif [ "$reboots" -gt 0 ]; then
        cfg_score=$((cfg_score - 3)); _score_penalty cfg 3 "Reboots x${reboots} (minor)"
    fi

    # Boot count (many boots = instability)
    local boots
    boots=$(safe_int "$(get_metric boot_count)")
    if [ "$boots" -gt 20 ]; then
        cfg_score=$((cfg_score - 20)); _score_penalty cfg 20 "High boot count x${boots}"
    elif [ "$boots" -gt 10 ]; then
        cfg_score=$((cfg_score - 10)); _score_penalty cfg 10 "Elevated boot count x${boots}"
    elif [ "$boots" -gt 5 ]; then
        cfg_score=$((cfg_score - 5)); _score_penalty cfg 5 "Boot count x${boots}"
    fi

    # Issue severity penalty
    local crit_issues high_issues
    crit_issues=$(safe_int "$(get_metric issues_critical)")
    high_issues=$(safe_int "$(get_metric issues_high)")
    cfg_score=$((cfg_score - crit_issues * 10 - high_issues * 5))

    # TPM errors
    local tpm
    tpm=$(safe_int "$(get_metric kern_tpm)")
    if [ "$tpm" -gt 10 ]; then
        cfg_score=$((cfg_score - 10))
    elif [ "$tpm" -gt 0 ]; then
        cfg_score=$((cfg_score - 4))
    fi

    # Unplanned reboots (worse than planned)
    local unplanned
    unplanned=$(safe_int "$(get_metric hm_unplanned_reboots)")
    if [ "$unplanned" -gt 5 ]; then
        cfg_score=$((cfg_score - 15)); _score_penalty cfg 15 "Unplanned reboots x${unplanned}"
    elif [ "$unplanned" -gt 0 ]; then
        cfg_score=$((cfg_score - 8)); _score_penalty cfg 8 "Unplanned reboot x${unplanned}"
    fi

    # Registry error matches (unique known errors found)
    local reg_matches
    reg_matches=$(safe_int "$(get_metric registry_matches)")
    if [ "$reg_matches" -gt 20 ]; then
        cfg_score=$((cfg_score - 10))
    elif [ "$reg_matches" -gt 5 ]; then
        cfg_score=$((cfg_score - 5))
    fi

    # Config validation warnings (from _analyze_properties)
    local cfg_warn
    cfg_warn=$(safe_int "$(get_metric config_warnings)")
    if [ "$cfg_warn" -gt 3 ]; then
        cfg_score=$((cfg_score - 15))
    elif [ "$cfg_warn" -gt 0 ]; then
        cfg_score=$((cfg_score - 5 * cfg_warn))
    fi

    [ "$cfg_score" -lt 0 ] && cfg_score=0
    HEALTH_SCORES_CFG=$cfg_score

    # ═══ Weighted Final Score ════════════════════════════════════════════════
    HEALTH_SCORE=$(( (HEALTH_SCORES_CONN * WEIGHT_CONN +
                      HEALTH_SCORES_HW * WEIGHT_HW +
                      HEALTH_SCORES_SVC * WEIGHT_SVC +
                      HEALTH_SCORES_CFG * WEIGHT_CFG) / 100 ))

    [ "$HEALTH_SCORE" -gt 100 ] && HEALTH_SCORE=100
    [ "$HEALTH_SCORE" -lt 0 ] && HEALTH_SCORE=0

    # Grade
    if [ "$HEALTH_SCORE" -ge 90 ]; then HEALTH_GRADE="A"
    elif [ "$HEALTH_SCORE" -ge 75 ]; then HEALTH_GRADE="B"
    elif [ "$HEALTH_SCORE" -ge 55 ]; then HEALTH_GRADE="C"
    elif [ "$HEALTH_SCORE" -ge 35 ]; then HEALTH_GRADE="D"
    else HEALTH_GRADE="F"
    fi

    # Store in metrics
    add_metric "health_score" "$HEALTH_SCORE"
    add_metric "health_grade" "$HEALTH_GRADE"
    add_metric "health_connectivity" "$HEALTH_SCORES_CONN"
    add_metric "health_hardware" "$HEALTH_SCORES_HW"
    add_metric "health_services" "$HEALTH_SCORES_SVC"
    add_metric "health_config" "$HEALTH_SCORES_CFG"

    log_verbose "Health score: $HEALTH_SCORE/100 ($HEALTH_GRADE)"
}

# ─── Status Helper ───────────────────────────────────────────────────────────
get_status() {
    local name="$1"
    local status_file="$WORK_DIR/status.dat"
    [ -f "$status_file" ] || return
    awk -F'\t' -v n="$name" '$1==n{print $2; exit}' "$status_file" 2>/dev/null
}

# ─── Predictive Alerts ──────────────────────────────────────────────────────
generate_predictions() {
    local alerts=""
    local alert_count=0

    # MQTT connection degradation
    local mqtt_fail mqtt_ok mqtt_total
    mqtt_fail=$(safe_int "$(get_metric i2p2_mqtt_fail_count)")
    mqtt_ok=$(safe_int "$(get_metric i2p2_mqtt_ok_count)")
    mqtt_total=$((mqtt_fail + mqtt_ok))
    if [ "$mqtt_total" -gt 0 ]; then
        local ratio=$((mqtt_fail * 100 / mqtt_total))
        if [ "$ratio" -gt 40 ] && [ "$ratio" -lt 80 ]; then
            alerts="${alerts}WARN\tMQTT failure rate at ${ratio}%. If trend continues, cloud connectivity will be lost.\n"
            alert_count=$((alert_count + 1))
        fi
    fi

    # Reboot frequency → watchdog risk
    local reboots boots
    reboots=$(safe_int "$(get_metric hm_reboots)")
    boots=$(safe_int "$(get_metric boot_count)")
    if [ "$reboots" -gt 30 ] && [ "$boots" -gt 5 ]; then
        alerts="${alerts}CRIT\tHigh reboot frequency ($reboots reboots across $boots boots). Charger may be in a crash loop.\n"
        alert_count=$((alert_count + 1))
    fi

    # Ethernet flapping → network instability
    local eth_flaps
    eth_flaps=$(safe_int "$(get_metric eth_flap_cycles)")
    if [ "$eth_flaps" -gt 3 ]; then
        alerts="${alerts}WARN\tEthernet flapping ($eth_flaps cycles). Physical connection or switch port may be failing.\n"
        alert_count=$((alert_count + 1))
    fi

    # Certificate expiry risk
    local cert_fail
    cert_fail=$(safe_int "$(get_metric cert_load_failures)")
    if [ "$cert_fail" -gt 10 ]; then
        alerts="${alerts}WARN\t$cert_fail certificate load failures. OCPP and cloud auth may fail if not resolved.\n"
        alert_count=$((alert_count + 1))
    fi

    # EVCC watchdog saturation
    local evcc_wd
    evcc_wd=$(safe_int "$(get_metric evcc_watchdog_count)")
    if [ "$evcc_wd" -gt 200 ]; then
        alerts="${alerts}WARN\tEVCC watchdog triggered $evcc_wd times. Charging sessions may be interrupted.\n"
        alert_count=$((alert_count + 1))
    fi

    # PPP never connected + no WiFi → isolated charger
    local ppp_status wifi_status
    ppp_status=$(get_status PPP)
    wifi_status=$(get_status WiFi)
    if [ "$ppp_status" = "down" ] && [ "$wifi_status" != "up" ]; then
        local eth_status
        eth_status=$(get_status Ethernet)
        if [ "$eth_status" != "up" ]; then
            alerts="${alerts}CRIT\tNo WAN connectivity (PPP down, WiFi unavailable, Ethernet ${eth_status:-unknown}). Charger is isolated.\n"
            alert_count=$((alert_count + 1))
        fi
    fi

    # Store
    add_metric "prediction_count" "$alert_count"
    if [ -n "$alerts" ]; then
        printf "%b" "$alerts" > "$WORK_DIR/predictions.dat"
    fi
    return 0
}

# ─── Display: ASCII Gauge ───────────────────────────────────────────────────
display_health_score() {
    local score=$HEALTH_SCORE
    local grade=$HEALTH_GRADE
    local bar_width=40
    local filled=$((score * bar_width / 100))
    local empty=$((bar_width - filled))

    # Color based on score
    local color="$RED"
    [ "$score" -ge 35 ] && color="$YLW"
    [ "$score" -ge 55 ] && color="$YLW"
    [ "$score" -ge 75 ] && color="$GRN"
    [ "$score" -ge 90 ] && color="$GRN"

    printf "\n"
    printf "  %s╔══════════════════════════════════════════════════╗%s\n" "${BLD}${color}" "${RST}"
    printf "  %s║%s  Health Score: %s%-3d/100  Grade: %s%s%s" "${BLD}${color}" "${RST}" "${BLD}${color}" "$score" "${BLD}${color}" "$grade" "${RST}"

    # Pad to align closing box
    local label_len=$((26 + ${#score} + ${#grade}))
    local pad=$((50 - label_len))
    printf "%*s" "$pad" ""
    printf "  %s║%s\n" "${BLD}${color}" "${RST}"

    # Bar
    printf "  %s║%s  [" "${BLD}${color}" "${RST}"
    local i
    for ((i=0; i<filled; i++)); do printf "%s█%s" "$color" "${RST}"; done
    for ((i=0; i<empty; i++)); do printf "%s░%s" "${DIM}" "${RST}"; done
    printf "]"
    local bar_pad=$((50 - bar_width - 4))
    printf "%*s" "$bar_pad" ""
    printf "  %s║%s\n" "${BLD}${color}" "${RST}"

    printf "  %s╚══════════════════════════════════════════════════╝%s\n" "${BLD}${color}" "${RST}"

    # Category breakdown
    printf "\n"
    _display_category "Connectivity"  "$HEALTH_SCORES_CONN" "$WEIGHT_CONN" "HEALTH_REASONS_CONN"
    _display_category "Hardware"      "$HEALTH_SCORES_HW"   "$WEIGHT_HW"   "HEALTH_REASONS_HW"
    _display_category "Services"      "$HEALTH_SCORES_SVC"  "$WEIGHT_SVC"  "HEALTH_REASONS_SVC"
    _display_category "Configuration" "$HEALTH_SCORES_CFG"  "$WEIGHT_CFG"  "HEALTH_REASONS_CFG"
    printf "\n"

    # Connector breakdown (if dual-connector)
    local _mc
    _mc=$(safe_int "$(get_metric multi_connector)")
    if [ "$_mc" -eq 1 ]; then
        printf "  %s🔌 Connector Health:%s\n" "${BLD}" "${RST}"
        printf "     Connector 1:  %s%dE%s  %s%dW%s  %d sessions\n" \
            "${RED}" "$(safe_int "$(get_metric conn1_errors)")" "${RST}" \
            "${YLW}" "$(safe_int "$(get_metric conn1_warnings)")" "${RST}" \
            "$(safe_int "$(get_metric conn1_sessions)")"
        printf "     Connector 2:  %s%dE%s  %s%dW%s  %d sessions\n" \
            "${RED}" "$(safe_int "$(get_metric conn2_errors)")" "${RST}" \
            "${YLW}" "$(safe_int "$(get_metric conn2_warnings)")" "${RST}" \
            "$(safe_int "$(get_metric conn2_sessions)")"
        printf "\n"
    fi

    # Predictions
    if [ -f "$WORK_DIR/predictions.dat" ] && [ -s "$WORK_DIR/predictions.dat" ]; then
        printf "  %s⚠ Predictive Alerts:%s\n" "${BLD}${YLW}" "${RST}"
        while IFS=$'\t' read -r level msg; do
            [ -z "$level" ] && continue
            local icon="⚠"
            local clr="$YLW"
            [ "$level" = "CRIT" ] && icon="🔴" && clr="$RED"
            printf "  %s%s %s%s\n" "$clr" "$icon" "$msg" "${RST}"
        done < "$WORK_DIR/predictions.dat"
        printf "\n"
    fi
    return 0
}

_display_category() {
    local name="$1" score="$2" weight="$3"
    # reasons_ref is the name of the array variable holding penalty reasons
    local reasons_ref="$4"
    local bar_w=20
    local filled=$((score * bar_w / 100))
    local empty=$((bar_w - filled))

    local color="$RED"
    [ "$score" -ge 35 ] && color="$YLW"
    [ "$score" -ge 55 ] && color="$YLW"
    [ "$score" -ge 75 ] && color="$GRN"

    printf "  %-16s " "$name"
    printf "%s" "$color"
    local i
    for ((i=0; i<filled; i++)); do printf "█"; done
    printf "%s" "${RST}${DIM}"
    for ((i=0; i<empty; i++)); do printf "░"; done
    printf "%s" "${RST}"
    printf "  %s%3d%s/100  (weight: %d%%)" "${BLD}${color}" "$score" "${RST}" "$weight"

    # Show penalty reasons if score is not perfect
    if [ "$score" -lt 100 ] && [ -n "$reasons_ref" ]; then
        # Use nameref-style indirect expansion (bash 3.2+ compatible)
        local reasons_var="${reasons_ref}[@]"
        local has_reasons=0
        local reason
        for reason in "${!reasons_var+"${!reasons_var}"}"; do
            has_reasons=1; break
        done
        if [ "$has_reasons" -eq 1 ]; then
            printf "\n"
            for reason in "${!reasons_var}"; do
                printf "    %s↳ %s%s\n" "${DIM}" "$reason" "${RST}"
            done
            return
        fi
    fi
    printf "\n"
}

# ─── Markdown Output ────────────────────────────────────────────────────────
health_score_markdown() {
    local score=$HEALTH_SCORE
    local grade=$HEALTH_GRADE

    local emoji="🔴"
    [ "$score" -ge 35 ] && emoji="🟠"
    [ "$score" -ge 55 ] && emoji="🟡"
    [ "$score" -ge 75 ] && emoji="🟢"

    printf "## Health Score\n\n"
    printf "%s **%d/100** — Grade **%s**\n\n" "$emoji" "$score" "$grade"

    printf "| Category | Score | Weight | Weighted |\n"
    printf "|----------|-------|--------|----------|\n"
    printf "| Connectivity | %d/100 | %d%% | %d |\n" "$HEALTH_SCORES_CONN" "$WEIGHT_CONN" "$((HEALTH_SCORES_CONN * WEIGHT_CONN / 100))"
    printf "| Hardware | %d/100 | %d%% | %d |\n" "$HEALTH_SCORES_HW" "$WEIGHT_HW" "$((HEALTH_SCORES_HW * WEIGHT_HW / 100))"
    printf "| Services | %d/100 | %d%% | %d |\n" "$HEALTH_SCORES_SVC" "$WEIGHT_SVC" "$((HEALTH_SCORES_SVC * WEIGHT_SVC / 100))"
    printf "| Configuration | %d/100 | %d%% | %d |\n" "$HEALTH_SCORES_CFG" "$WEIGHT_CFG" "$((HEALTH_SCORES_CFG * WEIGHT_CFG / 100))"
    printf "| **Total** | | | **%d** |\n\n" "$score"

    # Predictions
    if [ -f "$WORK_DIR/predictions.dat" ] && [ -s "$WORK_DIR/predictions.dat" ]; then
        printf "### ⚠ Predictive Alerts\n\n"
        while IFS=$'\t' read -r level msg; do
            [ -z "$level" ] && continue
            local icon="⚠️"
            [ "$level" = "CRIT" ] && icon="🔴"
            printf "%s %s\n\n" "$icon" "$msg"
        done < "$WORK_DIR/predictions.dat"
    fi

    # Connector breakdown
    local _mc
    _mc=$(safe_int "$(get_metric multi_connector)")
    if [ "$_mc" -eq 1 ]; then
        printf "### 🔌 Connector Health\n\n"
        printf "| Connector | Errors | Warnings | Sessions |\n"
        printf "|-----------|--------|----------|----------|\n"
        printf "| Connector 1 | %d | %d | %d |\n" \
            "$(safe_int "$(get_metric conn1_errors)")" \
            "$(safe_int "$(get_metric conn1_warnings)")" \
            "$(safe_int "$(get_metric conn1_sessions)")"
        printf "| Connector 2 | %d | %d | %d |\n\n" \
            "$(safe_int "$(get_metric conn2_errors)")" \
            "$(safe_int "$(get_metric conn2_warnings)")" \
            "$(safe_int "$(get_metric conn2_sessions)")"
    fi
    return 0
}

# ─── HTML Output ─────────────────────────────────────────────────────────────
health_score_html() {
    local score=$HEALTH_SCORE
    local grade=$HEALTH_GRADE

    local color="var(--red)"
    [ "$score" -ge 35 ] && color="var(--orange)"
    [ "$score" -ge 55 ] && color="var(--yellow)"
    [ "$score" -ge 75 ] && color="var(--green)"

    cat << ENDHTML
<div class="card">
<div class="card-header">🏥 Health Score</div>
<div style="padding: 24px; text-align: center;">
  <div style="font-size: 56px; font-weight: 800; color: ${color}; font-family: monospace; line-height: 1;">${score}</div>
  <div style="font-size: 14px; color: var(--fg2); margin-top: 4px;">out of 100 — Grade <strong style="color: ${color};">${grade}</strong></div>
  <div style="margin: 16px auto; max-width: 400px; height: 12px; background: var(--bg); border-radius: 6px; overflow: hidden; border: 1px solid var(--bg4);">
    <div style="width: ${score}%; height: 100%; background: ${color}; border-radius: 6px; transition: width 0.5s;"></div>
  </div>
</div>
<table class="data-table">
<thead><tr><th>Category</th><th>Score</th><th>Weight</th><th>Contribution</th></tr></thead>
<tbody>
ENDHTML

    _health_html_row "Connectivity" "$HEALTH_SCORES_CONN" "$WEIGHT_CONN"
    _health_html_row "Hardware" "$HEALTH_SCORES_HW" "$WEIGHT_HW"
    _health_html_row "Services" "$HEALTH_SCORES_SVC" "$WEIGHT_SVC"
    _health_html_row "Configuration" "$HEALTH_SCORES_CFG" "$WEIGHT_CFG"

    echo '</tbody></table>'

    # Predictions
    if [ -f "$WORK_DIR/predictions.dat" ] && [ -s "$WORK_DIR/predictions.dat" ]; then
        echo '<div style="padding: 16px; border-top: 1px solid var(--bg4);">'
        echo '<div style="font-weight: 600; font-size: 14px; color: var(--orange); margin-bottom: 8px;">⚠ Predictive Alerts</div>'
        while IFS=$'\t' read -r level msg; do
            [ -z "$level" ] && continue
            local clr="var(--orange)"
            [ "$level" = "CRIT" ] && clr="var(--red)"
            printf '<div style="color: %s; font-size: 13px; margin-bottom: 6px; padding-left: 12px; border-left: 3px solid %s;">%s</div>\n' "$clr" "$clr" "$(_html_escape "$msg")"
        done < "$WORK_DIR/predictions.dat"
        echo '</div>'
    fi

    # Connector breakdown (if dual-connector charger)
    local _mc
    _mc=$(safe_int "$(get_metric multi_connector)")
    if [ "$_mc" -eq 1 ]; then
        local _c1e _c1w _c1s _c2e _c2w _c2s
        _c1e=$(safe_int "$(get_metric conn1_errors)")
        _c1w=$(safe_int "$(get_metric conn1_warnings)")
        _c1s=$(safe_int "$(get_metric conn1_sessions)")
        _c2e=$(safe_int "$(get_metric conn2_errors)")
        _c2w=$(safe_int "$(get_metric conn2_warnings)")
        _c2s=$(safe_int "$(get_metric conn2_sessions)")
        cat << CONNHTML
<div style="padding: 16px; border-top: 1px solid var(--bg4);">
  <div style="font-weight: 600; font-size: 14px; margin-bottom: 10px;">🔌 Connector Health</div>
  <table class="data-table"><thead><tr><th>Connector</th><th>Errors</th><th>Warnings</th><th>Sessions</th></tr></thead>
  <tbody>
  <tr><td style="font-weight:600;">Connector 1</td><td style="color:var(--red);font-weight:600;">${_c1e}</td><td style="color:var(--yellow);">${_c1w}</td><td>${_c1s}</td></tr>
  <tr><td style="font-weight:600;">Connector 2</td><td style="color:var(--red);font-weight:600;">${_c2e}</td><td style="color:var(--yellow);">${_c2w}</td><td>${_c2s}</td></tr>
  </tbody></table>
</div>
CONNHTML
    fi
    echo '</div>'
}

_health_html_row() {
    local name="$1" score="$2" weight="$3"
    local contribution=$((score * weight / 100))
    local color="var(--red)"
    [ "$score" -ge 35 ] && color="var(--orange)"
    [ "$score" -ge 55 ] && color="var(--yellow)"
    [ "$score" -ge 75 ] && color="var(--green)"

    cat << ENDROW
<tr>
  <td>${name}</td>
  <td>
    <div style="display:flex;align-items:center;gap:8px;">
      <div style="flex:1;height:8px;background:var(--bg);border-radius:4px;overflow:hidden;max-width:100px;">
        <div style="width:${score}%;height:100%;background:${color};border-radius:4px;"></div>
      </div>
      <span style="color:${color};font-weight:600;font-family:monospace;min-width:40px;">${score}</span>
    </div>
  </td>
  <td>${weight}%</td>
  <td style="font-weight:600;">${contribution}</td>
</tr>
ENDROW
}

# ─── JSON Output (for web app) ──────────────────────────────────────────────
health_score_json() {
    echo '"healthScore": {'
    printf '  "score": %d,\n' "$HEALTH_SCORE"
    printf '  "grade": "%s",\n' "$HEALTH_GRADE"
    echo '  "categories": {'
    printf '    "connectivity": {"score": %d, "weight": %d},\n' "$HEALTH_SCORES_CONN" "$WEIGHT_CONN"
    printf '    "hardware": {"score": %d, "weight": %d},\n' "$HEALTH_SCORES_HW" "$WEIGHT_HW"
    printf '    "services": {"score": %d, "weight": %d},\n' "$HEALTH_SCORES_SVC" "$WEIGHT_SVC"
    printf '    "configuration": {"score": %d, "weight": %d}\n' "$HEALTH_SCORES_CFG" "$WEIGHT_CFG"
    echo '  },'

    # Connector breakdown (if dual-connector charger detected)
    local _mc
    _mc=$(safe_int "$(get_metric multi_connector)")
    echo '  "connectors": {'
    printf '    "detected": %s,\n' "$([ "$_mc" -eq 1 ] && echo 'true' || echo 'false')"
    printf '    "c1": {"errors": %d, "warnings": %d, "sessions": %d},\n' \
        "$(safe_int "$(get_metric conn1_errors)")" \
        "$(safe_int "$(get_metric conn1_warnings)")" \
        "$(safe_int "$(get_metric conn1_sessions)")"
    printf '    "c2": {"errors": %d, "warnings": %d, "sessions": %d}\n' \
        "$(safe_int "$(get_metric conn2_errors)")" \
        "$(safe_int "$(get_metric conn2_warnings)")" \
        "$(safe_int "$(get_metric conn2_sessions)")"
    echo '  },'

    # Predictions
    echo '  "predictions": ['
    local first=1
    if [ -f "$WORK_DIR/predictions.dat" ] && [ -s "$WORK_DIR/predictions.dat" ]; then
        while IFS=$'\t' read -r level msg; do
            [ -z "$level" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '    {"level": "%s", "message": "%s"}' "$level" "$(_json_escape "$msg")"
        done < "$WORK_DIR/predictions.dat"
    fi
    echo ''
    echo '  ]'
    echo '}'
}
