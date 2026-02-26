#!/bin/bash
# gen_markdown.sh — Markdown report generator
# Loggy v6.0

generate_markdown() {
    local outfile="$1"
    [ -z "$outfile" ] && outfile="$OUTPUT_DIR/analysis_$(get_sysinfo device_id)_$(date +%Y%m%d).md"

    # Sort issues by severity: CRITICAL > HIGH > MEDIUM > LOW (pure awk, no external sort)
    local sorted_issues="$WORK_DIR/issues_sorted.dat"
    if [ -f "$ISSUES_FILE" ] && [ -s "$ISSUES_FILE" ]; then
        awk -F'\t' '{
            prio = 9
            if ($1 == "CRITICAL") prio = 1
            else if ($1 == "HIGH") prio = 2
            else if ($1 == "MEDIUM") prio = 3
            else if ($1 == "LOW") prio = 4
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
        }' "$ISSUES_FILE" > "$sorted_issues"
    else
        : > "$sorted_issues"
    fi
    local ISSUES_FILE="$sorted_issues"

    local device_id fw_version
    device_id=$(get_sysinfo device_id)
    fw_version=$(get_sysinfo fw_version)
    [ -z "$device_id" ] || [ "$device_id" = "unknown" ] && device_id="Unknown"
    [ -z "$fw_version" ] && fw_version="Unknown"

    local total_issues crit_count high_count med_count low_count
    total_issues=$(issue_count)
    crit_count=$(issue_count_by_severity "CRITICAL")
    high_count=$(issue_count_by_severity "HIGH")
    med_count=$(issue_count_by_severity "MEDIUM")
    low_count=$(issue_count_by_severity "LOW")

    local timeline_count=0
    [ -f "$TIMELINE_FILE" ] && timeline_count=$(wc -l < "$TIMELINE_FILE" | tr -d ' ')

    {
        # ─── Header ─────────────────────────────────────────────────
        cat <<HEADER
# Loggy — Diagnostic Report

| | |
|---|---|
| **Device** | IOTMP${device_id} |
| **Firmware** | ${fw_version} |
| **Analysis** | Standard |
| **Date** | $(date '+%Y-%m-%d %H:%M') |
| **Issues** | ${total_issues} (${crit_count} Critical, ${high_count} High, ${med_count} Medium, ${low_count} Low) |
| **Timeline** | ${timeline_count} events |

---

HEADER

        # ─── Executive Summary ──────────────────────────────────────
        printf "## Executive Summary\n\n"
        if [ "$crit_count" -gt 0 ]; then
            printf "**⛔ CRITICAL issues detected.** This charger has significant connectivity and/or hardware problems requiring immediate attention.\n\n"
        elif [ "$high_count" -gt 0 ]; then
            printf "**⚠️ HIGH severity issues detected.** The charger has problems that should be investigated promptly.\n\n"
        elif [ "$total_issues" -gt 0 ]; then
            printf "**ℹ️ Issues detected.** The charger has minor issues that should be monitored.\n\n"
        else
            printf "**✅ No issues detected.** The charger appears to be operating normally.\n\n"
        fi

        # Quick issue list
        if [ "$total_issues" -gt 0 ]; then
            printf "| # | Severity | Component | Issue |\n"
            printf "|---|----------|-----------|-------|\n"
            local n=0
            while IFS=$'\t' read -r sev comp title desc evfile; do
                [ -z "$sev" ] && continue
                n=$((n + 1))
                local badge=""
                case "$sev" in
                    CRITICAL) badge="🔴 CRITICAL" ;;
                    HIGH)     badge="🟠 HIGH" ;;
                    MEDIUM)   badge="🟡 MEDIUM" ;;
                    LOW)      badge="🟢 LOW" ;;
                esac
                printf "| %d | %s | %s | %s |\n" "$n" "$badge" "$comp" "$title"
            done < "$ISSUES_FILE"
            printf "\n"
        fi

        # ─── Health Score ───────────────────────────────────────────
        if [ "$HEALTH_SCORE" -gt 0 ] || [ -n "$HEALTH_GRADE" ]; then
            printf "%s\n\n" "---"
            health_score_markdown
        fi

        # ─── Subsystem Status ───────────────────────────────────────
        printf "%s\n\n## Subsystem Status\n\n" "---"
        local status_file="$WORK_DIR/status.dat"
        if [ -f "$status_file" ]; then
            printf "| Subsystem | Status |\n"
            printf "|-----------|--------|\n"
            while IFS=$'\t' read -r sub stat; do
                [ -z "$sub" ] && continue
                local icon=""
                case "$stat" in
                    up)       icon="✅ UP" ;;
                    down)     icon="❌ DOWN" ;;
                    degraded) icon="⚠️ DEGRADED" ;;
                    unknown)  icon="❓ UNKNOWN" ;;
                    *)        icon="$stat" ;;
                esac
                printf "| %s | %s |\n" "$sub" "$icon"
            done < "$status_file"
            printf "\n"
        fi

        # ─── System Information ─────────────────────────────────────
        printf "%s\n\n## System Information\n\n" "---"
        printf "| Property | Value |\n"
        printf "|----------|-------|\n"
        _md_sysinfo_row "Device ID" "IOTMP${device_id}"
        _md_sysinfo_row "Firmware" "$fw_version"
        _md_sysinfo_row "Release" "$(get_sysinfo release_version)"
        _md_sysinfo_row "Build Scope" "$(get_sysinfo scope)"
        _md_sysinfo_row "Artifact" "$(get_sysinfo artifact_version)"
        _md_sysinfo_row "Build Info" "$(get_sysinfo build_info)"
        _md_sysinfo_row "Boot Slot" "$(get_sysinfo boot_slot)"

        local mem_total mem_free mem_avail
        mem_total=$(get_sysinfo mem_total_kb)
        mem_free=$(get_sysinfo mem_free_kb)
        mem_avail=$(get_sysinfo mem_available_kb)
        [ -n "$mem_total" ] && [ "$mem_total" != "MemTotal:" ] && _md_sysinfo_row "Memory Total" "${mem_total} KB"
        [ -n "$mem_free" ] && _md_sysinfo_row "Memory Free" "${mem_free} KB"
        [ -n "$mem_avail" ] && _md_sysinfo_row "Memory Available" "${mem_avail} KB"
        printf "\n"

        # Component versions
        local has_versions=0
        while IFS='=' read -r k v; do
            case "$k" in ver_*) has_versions=1; break ;; esac
        done < "$SYSINFO_FILE" 2>/dev/null

        if [ "$has_versions" -eq 1 ]; then
            printf "### Component Versions\n\n"
            printf "| Component | Version |\n"
            printf "|-----------|--------|\n"
            while IFS='=' read -r k v; do
                case "$k" in
                    ver_*) printf "| %s | \`%s\` |\n" "${k#ver_}" "$v" ;;
                esac
            done < "$SYSINFO_FILE"
            printf "\n"
        fi

        # ─── Detailed Issues ────────────────────────────────────────
        printf "%s\n\n## Detailed Issues\n\n" "---"
        if [ "$total_issues" -eq 0 ]; then
            printf "*No issues detected.*\n\n"
        else
            local n=0
            while IFS=$'\t' read -r sev comp title desc evfile; do
                [ -z "$sev" ] && continue
                n=$((n + 1))

                local badge=""
                case "$sev" in
                    CRITICAL) badge="🔴 CRITICAL" ;;
                    HIGH)     badge="🟠 HIGH" ;;
                    MEDIUM)   badge="🟡 MEDIUM" ;;
                    LOW)      badge="🟢 LOW" ;;
                esac

                printf "### #%d %s — %s\n\n" "$n" "$badge" "$title"
                printf "**Component:** %s  \n" "$comp"
                printf "**Severity:** %s\n\n" "$sev"

                # Split description: main text vs troubleshooting vs on-site flag
                local main_desc ts_text onsite_flag=""
                if echo "$desc" | grep -q 'Troubleshooting:'; then
                    main_desc=$(echo "$desc" | sed 's/ *Troubleshooting:.*//')
                    ts_text=$(echo "$desc" | grep -oP 'Troubleshooting:.*' | sed 's/\[On-site service.*//;s/ *$//')
                else
                    main_desc="$desc"
                    ts_text=""
                fi
                echo "$desc" | grep -q '\[On-site service' && onsite_flag="yes"

                printf "%s\n\n" "$main_desc"

                if [ -n "$ts_text" ]; then
                    printf "> **🔧 %s**\n\n" "$ts_text"
                fi
                if [ -n "$onsite_flag" ]; then
                    printf "> **🚨 On-site service required**\n\n"
                fi

                # Evidence (capped at 50 lines)
                if [ -n "$evfile" ] && [ -f "$evfile" ]; then
                    local ev_lines
                    ev_lines=$(wc -l < "$evfile" 2>/dev/null | tr -d ' ') || ev_lines=0
                    printf "<details>\n<summary>📋 Evidence (%s lines — click to expand)</summary>\n\n" "$ev_lines"
                    printf '```\n'
                    head -50 "$evfile" 2>/dev/null
                    if [ "$ev_lines" -gt 50 ]; then
                        printf "\n... %d more lines (see full evidence in work directory)\n" "$((ev_lines - 50))"
                    fi
                    printf '\n```\n\n'
                    printf "</details>\n\n"
                fi
            done < "$ISSUES_FILE"
        fi

        # ─── Error Summary ──────────────────────────────────────────
        local err_file="$WORK_DIR/error_summary.dat"
        if [ -f "$err_file" ] && [ -s "$err_file" ]; then
            printf "%s\n\n## Error Summary by Component\n\n" "---"
            printf "| Component | Errors | Warnings | Critical |\n"
            printf "|-----------|--------|----------|----------|\n"
            while IFS='|' read -r comp errs warns crits; do
                [ -z "$comp" ] && continue
                local e_flag="" w_flag=""
                [ "$(safe_int "$errs")" -gt 0 ] && e_flag=" ⚠️"
                [ "$(safe_int "$warns")" -gt 50 ] && w_flag=" ⚠️"
                printf "| %s | %s%s | %s%s | %s |\n" "$comp" "$errs" "$e_flag" "$warns" "$w_flag" "$crits"
            done < "$err_file"
            printf "\n"
        fi

        # ─── Timeline (condensed + deduplicated) ────────────────────
        printf "%s\n\n## Timeline (Recent Events)\n\n" "---"
        if [ -f "$TIMELINE_FILE" ] && [ -s "$TIMELINE_FILE" ]; then
            # Critical & High: deduplicated, max 5 per component, 30 total
            local crit_high
            crit_high=$(awk -F'\t' '$2=="CRITICAL" || $2=="HIGH"' "$TIMELINE_FILE" 2>/dev/null)
            if [ -n "$crit_high" ]; then
                printf "### Critical & High Events\n\n"
                printf '```\n'
                echo "$crit_high" | awk -F'\t' '
                {
                    comp_count[$3]++
                    if (comp_count[$3] > 5) next   # max 5 per component
                    if (total >= 30) next            # max 30 total
                    total++
                    printf "[%s] %-8s %-15s %s\n", $1, $2, $3, $4
                }
                END {
                    for (c in comp_count)
                        if (comp_count[c] > 5)
                            printf "  ... %s: %d more events omitted\n", c, comp_count[c] - 5
                }
                '
                printf '```\n\n'
            fi

            # Last 30 Events: diverse mix across components (most recent)
            printf "### Last 30 Events\n\n"
            printf '```\n'
            awk -F'\t' '
            {
                comp_last[$3]++
                # Store all events; we will pick from the end
                all[NR] = sprintf("[%s] %-8s %-15s %s", $1, $2, $3, $4)
                comp[NR] = $3
            }
            END {
                # Walk backward, picking max 5 per component, 30 total
                total = 0
                for (i = NR; i >= 1 && total < 30; i--) {
                    c = comp[i]
                    if (picked[c]+0 >= 5) continue
                    picked[c]++
                    total++
                    result[total] = all[i]
                }
                for (i = total; i >= 1; i--) print result[i]
            }
            ' "$TIMELINE_FILE"
            printf '```\n\n'

            printf "*%s total timeline events.*\n\n" "$timeline_count"
        else
            printf "*No timeline events recorded.*\n\n"
        fi

        # ─── Key Metrics ────────────────────────────────────────────
        printf "%s\n\n## Key Metrics\n\n" "---"
        printf "| Metric | Value |\n"
        printf "|--------|-------|\n"
        _md_metric_row "MQTT Failures" "$(get_metric i2p2_mqtt_fail_count)"
        _md_metric_row "MQTT Successes" "$(get_metric i2p2_mqtt_ok_count)"
        _md_metric_row "PPP Missing" "$(get_metric i2p2_ppp0_missing)"
        _md_metric_row "Eth Flap Cycles" "$(get_metric eth_flap_cycles)"
        _md_metric_row "WiFi Connections" "$(get_metric wifi_connections)"
        _md_metric_row "OCPP WS Connected" "$(get_metric ocpp_ws_connected)"
        _md_metric_row "OCPP WS Failed" "$(get_metric ocpp_ws_failed)"
        _md_metric_row "OCPP Boot Notifications" "$(get_metric ocpp_boot_notif)"
        _md_metric_row "CPState Faults" "$(get_metric cpstate_fault_count)"
        _md_metric_row "EVCC Watchdog" "$(get_metric evcc_watchdog_count)"
        _md_metric_row "Cert Load Failures" "$(get_metric cert_load_failures)"
        _md_metric_row "PMQ Sub Failures" "$(get_metric em_pmq_sub_fail)"
        _md_metric_row "Shadow Updates" "$(get_metric i2p2_shadow_updates)"
        _md_metric_row "Backoff Count" "$(get_metric i2p2_backoff_count)"
        printf "\n"

        # ─── Deep Analysis (if available) ──────────────────────────
        if [ -f "$WORK_DIR/deep_causal.dat" ] && [ -s "$WORK_DIR/deep_causal.dat" ]; then
            printf "%s\n\n" "---"
            deep_analysis_markdown
        fi

        # ─── Recommended Actions ────────────────────────────────────
        printf "%s\n\n## Recommended Actions\n\n" "---"
        if [ "$total_issues" -gt 0 ]; then
            local n=0
            while IFS=$'\t' read -r sev comp title desc evfile; do
                [ -z "$sev" ] && continue
                n=$((n + 1))
                printf "%d. **[%s]** %s — %s\n" "$n" "$sev" "$comp" "$title"
            done < "$ISSUES_FILE"
            printf "\n"
        else
            printf "*No actions required at this time.*\n\n"
        fi

        # ─── Footer ────────────────────────────────────────────────
        printf "%s\n\n" "---"
        printf "*Generated by Loggy v%s on %s*\n" "$ANALYZER_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')"

    } > "$outfile"

    log_ok "Markdown report: $outfile"
    _log_file "INFO" "MD report: $outfile ($(wc -c < "$outfile" | tr -d ' ') bytes)"
}

# ─── Helpers ─────────────────────────────────────────────────────────────────
_md_sysinfo_row() {
    local label="$1" val="$2"
    [ -z "$val" ] && return
    printf "| %s | \`%s\` |\n" "$label" "$val"
}

_md_metric_row() {
    local label="$1" val="$2"
    [ -z "$val" ] || [ "$val" = "0" ] && return
    printf "| %s | %s |\n" "$label" "$val"
}

# Deduplicate consecutive identical timeline messages
_md_timeline_dedup() {
    awk -F'\t' '
    {
        msg = $2 FS $3 FS $4
        if (msg == prev_msg) { dup++; next }
        if (NR > 1 && dup > 0) printf "  ... x%d identical\n", dup + 1
        dup = 0; prev_msg = msg
        ts = $1
        if (ts == "" || ts == "0000-00-00 00:00:00.000") ts = "(no timestamp)"
        printf "[%s] %-8s %-15s %s\n", ts, $2, $3, $4
    }
    END { if (dup > 0) printf "  ... x%d identical\n", dup + 1 }
    '
}
