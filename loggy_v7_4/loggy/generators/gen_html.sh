#!/bin/bash
# gen_html.sh — HTML report generator (self-contained, dark theme)
# Loggy v6.0

generate_html() {
    local outfile="$1"
    [ -z "$outfile" ] && outfile="$OUTPUT_DIR/analysis_$(get_sysinfo device_id)_$(date +%Y%m%d).html"

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
        _html_head "$device_id" "$fw_version"

        # ─── Header Bar ─────────────────────────────────────────
        cat <<'HEADER'
<div class="header">
  <div class="header-left">
    <span class="logo">⚡</span>
    <h1>Loggy</h1>
  </div>
  <div class="header-right">Diagnostic Report</div>
</div>
<div class="container">
HEADER

        # ─── Device Info Card ───────────────────────────────────
        printf '<div class="card">\n'
        printf '<div class="card-header">📋 Device Information</div>\n'
        printf '<div class="info-grid">\n'
        printf '<div class="info-item"><span class="info-label">Device</span><span class="info-value">IOTMP%s</span></div>\n' "$device_id"
        printf '<div class="info-item"><span class="info-label">Firmware</span><span class="info-value">%s</span></div>\n' "$fw_version"
        printf '<div class="info-item"><span class="info-label">Analysis</span><span class="info-value">Standard</span></div>\n'
        printf '<div class="info-item"><span class="info-label">Date</span><span class="info-value">%s</span></div>\n' "$(date '+%Y-%m-%d %H:%M')"
        printf '</div>\n</div>\n\n'

        # ─── Issue Summary Cards ────────────────────────────────
        printf '<div class="summary-cards">\n'
        _html_summary_card "$total_issues" "Total" "total"
        _html_summary_card "$crit_count" "Critical" "critical"
        _html_summary_card "$high_count" "High" "high"
        _html_summary_card "$med_count" "Medium" "medium"
        _html_summary_card "$low_count" "Low" "low"
        printf '</div>\n\n'

        # ─── Health Score ───────────────────────────────────────
        if [ "$HEALTH_SCORE" -gt 0 ] || [ -n "$HEALTH_GRADE" ]; then
            health_score_html
        fi

        # ─── Subsystem Status ───────────────────────────────────
        local status_file="$WORK_DIR/status.dat"
        if [ -f "$status_file" ] && [ -s "$status_file" ]; then
            printf '<div class="card">\n'
            printf '<div class="card-header">🔌 Subsystem Status</div>\n'
            printf '<div class="status-grid">\n'
            while IFS=$'\t' read -r sub stat; do
                [ -z "$sub" ] && continue
                local css_class icon
                case "$stat" in
                    up)       css_class="status-up";       icon="✓" ;;
                    down)     css_class="status-down";     icon="✗" ;;
                    degraded) css_class="status-degraded"; icon="△" ;;
                    *)        css_class="status-unknown";  icon="?" ;;
                esac
                printf '<div class="status-item %s"><span class="status-icon">%s</span><span class="status-name">%s</span><span class="status-label">%s</span></div>\n' \
                    "$css_class" "$icon" "$sub" "$(echo "$stat" | tr '[:lower:]' '[:upper:]')"
            done < "$status_file"
            printf '</div>\n</div>\n\n'
        fi

        # ─── Issues ─────────────────────────────────────────────
        printf '<div class="card">\n'
        printf '<div class="card-header">🔍 Issues (%s found)</div>\n' "$total_issues"

        if [ "$total_issues" -eq 0 ]; then
            printf '<p class="no-issues">✅ No issues detected. The charger appears healthy.</p>\n'
        else
            local n=0
            while IFS=$'\t' read -r sev comp title desc evfile; do
                [ -z "$sev" ] && continue
                n=$((n + 1))
                local sev_lower
                sev_lower=$(echo "$sev" | tr '[:upper:]' '[:lower:]')

                printf '<div class="issue issue-%s">\n' "$sev_lower"
                printf '<div class="issue-header">\n'
                printf '<span class="issue-num">#%d</span>\n' "$n"
                printf '<span class="badge badge-%s">%s</span>\n' "$sev_lower" "$sev"
                printf '<span class="issue-title">%s</span>\n' "$(_html_escape "$title")"
                printf '<span class="issue-comp">%s</span>\n' "$(_html_escape "$comp")"
                printf '</div>\n'

                # Split description: main text vs troubleshooting vs on-site flag
                local main_desc="" ts_text="" onsite_flag=""
                if echo "$desc" | grep -q 'Troubleshooting:'; then
                    main_desc=$(echo "$desc" | sed 's/ *Troubleshooting:.*//')
                    ts_text=$(echo "$desc" | grep -oP 'Troubleshooting:.*' | sed 's/\[On-site service.*//;s/ *$//')
                else
                    main_desc="$desc"
                fi
                echo "$desc" | grep -q '\[On-site service' && onsite_flag="yes"

                printf '<div class="issue-desc">%s</div>\n' "$(_html_escape "$main_desc")"
                if [ -n "$ts_text" ]; then
                    printf '<div class="issue-troubleshoot"><strong>🔧 %s</strong></div>\n' "$(_html_escape "$ts_text")"
                fi
                if [ -n "$onsite_flag" ]; then
                    printf '<div class="issue-onsite"><strong>🚨 On-site service required</strong></div>\n'
                fi

                # Evidence (capped at 50 lines)
                if [ -n "$evfile" ] && [ -f "$evfile" ]; then
                    local ev_lines
                    ev_lines=$(wc -l < "$evfile" 2>/dev/null | tr -d ' ') || ev_lines=0
                    printf '<details class="evidence">\n'
                    printf '<summary>📋 Evidence (%s lines — click to expand)</summary>\n' "$ev_lines"
                    printf '<pre class="evidence-code">'
                    _html_evidence "$evfile" 50
                    if [ "$ev_lines" -gt 50 ]; then
                        printf '<span class="ev-sep">\n... %d more lines (see full evidence in work directory)</span>\n' "$((ev_lines - 50))"
                    fi
                    printf '</pre>\n'
                    printf '</details>\n'
                fi
                printf '</div>\n\n'
            done < "$ISSUES_FILE"
        fi
        printf '</div>\n\n'

        # ─── Error Summary ──────────────────────────────────────
        local err_file="$WORK_DIR/error_summary.dat"
        if [ -f "$err_file" ] && [ -s "$err_file" ]; then
            printf '<div class="card">\n'
            printf '<div class="card-header">📊 Error Summary by Component</div>\n'
            printf '<table class="data-table">\n'
            printf '<thead><tr><th>Component</th><th>Errors</th><th>Warnings</th><th>Critical</th></tr></thead>\n'
            printf '<tbody>\n'
            while IFS='|' read -r comp errs warns crits; do
                [ -z "$comp" ] && continue
                local e_class="" w_class=""
                [ "$(safe_int "$errs")" -gt 0 ] && e_class=' class="cell-warn"'
                [ "$(safe_int "$warns")" -gt 50 ] && w_class=' class="cell-warn"'
                printf '<tr><td>%s</td><td%s>%s</td><td%s>%s</td><td>%s</td></tr>\n' \
                    "$comp" "$e_class" "$errs" "$w_class" "$warns" "$crits"
            done < "$err_file"
            printf '</tbody></table>\n'
            printf '</div>\n\n'
        fi

        # ─── System Info ────────────────────────────────────────
        printf '<div class="card">\n'
        printf '<div class="card-header">🖥️ System Information</div>\n'
        printf '<table class="data-table">\n'
        printf '<thead><tr><th>Property</th><th>Value</th></tr></thead>\n<tbody>\n'
        _html_info_row "Device ID" "IOTMP${device_id}"
        _html_info_row "Firmware" "$fw_version"
        _html_info_row "Release" "$(get_sysinfo release_version)"
        _html_info_row "Scope" "$(get_sysinfo scope)"
        _html_info_row "Artifact" "$(get_sysinfo artifact_version)"
        _html_info_row "Build" "$(get_sysinfo build_info)"
        _html_info_row "Boot Slot" "$(get_sysinfo boot_slot)"
        local mem_total; mem_total=$(get_sysinfo mem_total_kb)
        [ -n "$mem_total" ] && [ "$mem_total" != "MemTotal:" ] && _html_info_row "Memory" "${mem_total} KB"
        _html_info_row "Memory Available" "$(get_sysinfo mem_available_kb) KB"
        printf '</tbody></table>\n'

        # Component versions
        local has_ver=0
        while IFS='=' read -r k v; do
            case "$k" in ver_*) has_ver=1; break ;; esac
        done < "$SYSINFO_FILE" 2>/dev/null
        if [ "$has_ver" -eq 1 ]; then
            printf '<h3 class="subsection">Component Versions</h3>\n'
            printf '<table class="data-table">\n<thead><tr><th>Component</th><th>Version</th></tr></thead>\n<tbody>\n'
            while IFS='=' read -r k v; do
                case "$k" in ver_*) printf '<tr><td>%s</td><td><code>%s</code></td></tr>\n' "${k#ver_}" "$v" ;; esac
            done < "$SYSINFO_FILE"
            printf '</tbody></table>\n'
        fi
        printf '</div>\n\n'

        # ─── Key Metrics ────────────────────────────────────────
        printf '<div class="card">\n'
        printf '<div class="card-header">📈 Key Metrics</div>\n'
        printf '<div class="metrics-grid">\n'
        _html_metric "MQTT Failures" "$(get_metric i2p2_mqtt_fail_count)" "warn"
        _html_metric "MQTT Successes" "$(get_metric i2p2_mqtt_ok_count)" "ok"
        _html_metric "Eth Flaps" "$(get_metric eth_flap_cycles)" "warn"
        _html_metric "OCPP Connected" "$(get_metric ocpp_ws_connected)" "ok"
        _html_metric "OCPP Failed" "$(get_metric ocpp_ws_failed)" "warn"
        _html_metric "Boot Notifications" "$(get_metric ocpp_boot_notif)" "info"
        _html_metric "CPState Faults" "$(get_metric cpstate_fault_count)" "warn"
        _html_metric "EVCC Watchdog" "$(get_metric evcc_watchdog_count)" "warn"
        _html_metric "Cert Failures" "$(get_metric cert_load_failures)" "warn"
        _html_metric "PMQ Sub Failures" "$(get_metric em_pmq_sub_fail)" "warn"
        _html_metric "Shadow Updates" "$(get_metric i2p2_shadow_updates)" "info"
        _html_metric "Backoff Count" "$(get_metric i2p2_backoff_count)" "warn"
        printf '</div>\n</div>\n\n'

        # ─── Timeline ───────────────────────────────────────────
        if [ -f "$TIMELINE_FILE" ] && [ -s "$TIMELINE_FILE" ]; then
            printf '<div class="card">\n'
            printf '<div class="card-header">📅 Timeline (%s events)</div>\n' "$timeline_count"

            # Critical/High events: max 5 per component, 30 total
            local ch_events
            ch_events=$(awk -F'\t' '
                ($2=="CRITICAL" || $2=="HIGH") {
                    comp_count[$3]++
                    if (comp_count[$3] > 5) next
                    if (total >= 30) next
                    total++
                    print
                }
            ' "$TIMELINE_FILE" 2>/dev/null)
            if [ -n "$ch_events" ]; then
                printf '<details open class="timeline-section">\n'
                printf '<summary>⚠️ Critical &amp; High Events</summary>\n'
                printf '<div class="timeline">\n'
                echo "$ch_events" | while IFS=$'\t' read -r ts sev comp msg; do
                    local sev_lower; sev_lower=$(echo "$sev" | tr '[:upper:]' '[:lower:]')
                    [ -z "$ts" ] || [ "$ts" = "0000-00-00 00:00:00.000" ] && ts="—"
                    printf '<div class="tl-event tl-%s"><span class="tl-ts">%s</span><span class="badge badge-%s">%s</span><span class="tl-comp">%s</span><span class="tl-msg">%s</span></div>\n' \
                        "$sev_lower" "$(_html_escape "$ts")" "$sev_lower" "$sev" "$(_html_escape "$comp")" "$(_html_escape "$msg")"
                done
                printf '</div>\n</details>\n'
            fi

            # Last 50 events: diverse mix across components (most recent)
            printf '<details class="timeline-section">\n'
            printf '<summary>📜 Last 50 Events</summary>\n'
            printf '<div class="timeline">\n'
            awk -F'\t' '
            {
                all[NR] = $0
                comp[NR] = $3
            }
            END {
                total = 0
                for (i = NR; i >= 1 && total < 50; i--) {
                    c = comp[i]
                    if (picked[c]+0 >= 8) continue
                    picked[c]++
                    total++
                    result[total] = all[i]
                }
                for (i = total; i >= 1; i--) print result[i]
            }
            ' "$TIMELINE_FILE" | while IFS=$'\t' read -r ts sev comp msg; do
                local sev_lower; sev_lower=$(echo "$sev" | tr '[:upper:]' '[:lower:]')
                [ -z "$ts" ] || [ "$ts" = "0000-00-00 00:00:00.000" ] && ts="—"
                printf '<div class="tl-event tl-%s"><span class="tl-ts">%s</span><span class="badge badge-%s">%s</span><span class="tl-comp">%s</span><span class="tl-msg">%s</span></div>\n' \
                    "$sev_lower" "$(_html_escape "$ts")" "$sev_lower" "$sev" "$(_html_escape "$comp")" "$(_html_escape "$msg")"
            done
            printf '</div>\n</details>\n'
            printf '</div>\n\n'
        fi

        # ─── Deep Analysis (if available) ──────────────────────────
        if [ -f "$WORK_DIR/deep_causal.dat" ] && [ -s "$WORK_DIR/deep_causal.dat" ]; then
            deep_analysis_html
        fi

        # ─── Footer ─────────────────────────────────────────────
        printf '<div class="footer">Generated by Loggy v%s on %s</div>\n' \
            "$ANALYZER_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '</div>\n</body>\n</html>\n'

    } > "$outfile"

    log_ok "HTML report: $outfile"
    _log_file "INFO" "HTML report: $outfile ($(wc -c < "$outfile" | tr -d ' ') bytes)"
}

# ─── HTML Helpers ────────────────────────────────────────────────────────────
_html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    echo "$s"
}

_html_summary_card() {
    local count="$1" label="$2" css="$3"
    printf '<div class="summary-card sc-%s"><span class="sc-count">%s</span><span class="sc-label">%s</span></div>\n' \
        "$css" "$(safe_int "$count")" "$label"
}

_html_info_row() {
    local label="$1" val="$2"
    [ -z "$val" ] || [ "$val" = " KB" ] && return
    printf '<tr><td>%s</td><td><code>%s</code></td></tr>\n' "$label" "$(_html_escape "$val")"
}

_html_metric() {
    local label="$1" val="$2" type="$3"
    [ -z "$val" ] && return
    local v; v=$(safe_int "$val")
    [ "$v" -eq 0 ] && [ "$type" = "warn" ] && return
    local css="metric-${type}"
    [ "$type" = "warn" ] && [ "$v" -gt 0 ] && css="metric-bad"
    printf '<div class="metric-item %s"><span class="metric-val">%s</span><span class="metric-label">%s</span></div>\n' \
        "$css" "$v" "$label"
}

_html_evidence() {
    local evfile="$1"
    local max_lines="${2:-0}"
    local line_num=0
    # Color-code evidence lines: matching lines vs context
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        [ "$max_lines" -gt 0 ] && [ "$line_num" -gt "$max_lines" ] && break
        local escaped
        escaped=$(_html_escape "$line")
        if echo "$line" | grep -qE '^\d+:|-\-$'; then
            # Context separator
            if [ "$line" = "--" ]; then
                printf '<span class="ev-sep">%s</span>\n' "$escaped"
            elif echo "$line" | grep -qE '^[0-9]+:.*\[E\]|^[0-9]+:.*\[C\]|^[0-9]+:.*ERROR'; then
                printf '<span class="ev-error">%s</span>\n' "$escaped"
            elif echo "$line" | grep -qE '^[0-9]+:.*\[W\]|^[0-9]+:.*WARN'; then
                printf '<span class="ev-warn">%s</span>\n' "$escaped"
            else
                printf '<span class="ev-ctx">%s</span>\n' "$escaped"
            fi
        else
            printf '%s\n' "$escaped"
        fi
    done < "$evfile"
}

# ─── HTML Head with Inline CSS ──────────────────────────────────────────────
_html_head() {
    local device_id="$1" fw_version="$2"
    cat <<'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
HTMLHEAD
    printf '<title>IoTecha Report — IOTMP%s</title>\n' "$device_id"
    cat <<'CSS'
<style>
:root {
  --bg: #0d1117; --bg2: #161b22; --bg3: #21262d; --bg4: #30363d;
  --fg: #c9d1d9; --fg2: #8b949e; --fg3: #6e7681;
  --red: #f85149; --orange: #d29922; --yellow: #e3b341; --green: #3fb950;
  --blue: #58a6ff; --purple: #bc8cff; --cyan: #39d353;
  --crit-bg: #3d1114; --high-bg: #3d2a12; --med-bg: #3d3512; --low-bg: #12261e;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
  background: var(--bg); color: var(--fg); line-height: 1.6; }
.header { background: var(--bg2); border-bottom: 1px solid var(--bg4); padding: 16px 24px;
  display: flex; justify-content: space-between; align-items: center; position: sticky; top: 0; z-index: 10; }
.header-left { display: flex; align-items: center; gap: 12px; }
.logo { font-size: 28px; }
h1 { font-size: 20px; font-weight: 600; color: var(--fg); }
.header-right { color: var(--fg2); font-size: 14px; }
.container { max-width: 1100px; margin: 0 auto; padding: 24px; }
.card { background: var(--bg2); border: 1px solid var(--bg4); border-radius: 8px; margin-bottom: 20px; overflow: hidden; }
.card-header { background: var(--bg3); padding: 12px 16px; font-weight: 600; font-size: 15px; border-bottom: 1px solid var(--bg4); }
.info-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 12px; padding: 16px; }
.info-item { display: flex; flex-direction: column; }
.info-label { font-size: 12px; color: var(--fg3); text-transform: uppercase; letter-spacing: 0.5px; }
.info-value { font-size: 14px; color: var(--fg); font-family: 'SF Mono', Consolas, monospace; }
.summary-cards { display: grid; grid-template-columns: repeat(5, 1fr); gap: 12px; margin-bottom: 20px; }
.summary-card { background: var(--bg2); border: 1px solid var(--bg4); border-radius: 8px; padding: 16px;
  text-align: center; display: flex; flex-direction: column; gap: 4px; }
.sc-count { font-size: 32px; font-weight: 700; }
.sc-label { font-size: 12px; color: var(--fg2); text-transform: uppercase; }
.sc-total .sc-count { color: var(--blue); }
.sc-critical .sc-count { color: var(--red); }
.sc-high .sc-count { color: var(--orange); }
.sc-medium .sc-count { color: var(--yellow); }
.sc-low .sc-count { color: var(--green); }
.sc-critical { border-left: 3px solid var(--red); }
.sc-high { border-left: 3px solid var(--orange); }
.sc-medium { border-left: 3px solid var(--yellow); }
.sc-low { border-left: 3px solid var(--green); }
.status-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 12px; padding: 16px; }
.status-item { display: flex; flex-direction: column; align-items: center; padding: 12px; border-radius: 6px;
  background: var(--bg3); border: 1px solid var(--bg4); gap: 4px; }
.status-icon { font-size: 20px; font-weight: 700; }
.status-name { font-size: 14px; font-weight: 500; }
.status-label { font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; }
.status-up .status-icon { color: var(--green); }
.status-up .status-label { color: var(--green); }
.status-down .status-icon { color: var(--red); }
.status-down .status-label { color: var(--red); }
.status-degraded .status-icon { color: var(--orange); }
.status-degraded .status-label { color: var(--orange); }
.status-unknown .status-icon { color: var(--fg3); }
.status-unknown .status-label { color: var(--fg3); }
.issue { border: 1px solid var(--bg4); border-radius: 6px; margin: 12px 16px; overflow: hidden; }
.issue-critical { border-left: 4px solid var(--red); background: var(--crit-bg); }
.issue-high { border-left: 4px solid var(--orange); background: var(--high-bg); }
.issue-medium { border-left: 4px solid var(--yellow); background: var(--med-bg); }
.issue-low { border-left: 4px solid var(--green); background: var(--low-bg); }
.issue-header { padding: 12px 16px; display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.issue-num { font-weight: 700; color: var(--fg2); font-size: 14px; }
.badge { padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; }
.badge-critical { background: var(--red); color: #fff; }
.badge-high { background: var(--orange); color: #000; }
.badge-medium { background: var(--yellow); color: #000; }
.badge-low { background: var(--green); color: #000; }
.badge-info { background: var(--blue); color: #000; }
.issue-title { font-weight: 600; font-size: 15px; flex: 1; }
.issue-comp { font-size: 12px; color: var(--fg3); font-family: monospace; background: var(--bg4); padding: 2px 6px; border-radius: 3px; }
.issue-desc { padding: 8px 16px 12px; font-size: 14px; color: var(--fg2); line-height: 1.5; }
.issue-troubleshoot { padding: 6px 16px 8px; font-size: 13px; color: var(--fg); background: rgba(59,130,246,.08); border-left: 3px solid #3b82f6; margin: 0 16px 8px; border-radius: 0 4px 4px 0; line-height: 1.5; }
.issue-onsite { padding: 6px 16px 10px; font-size: 13px; font-weight: 600; color: #dc2626; }
.evidence { margin: 0 16px 12px; }
.evidence summary { cursor: pointer; font-size: 13px; color: var(--blue); padding: 6px 0; }
.evidence summary:hover { color: var(--cyan); }
.evidence-code { background: var(--bg); border: 1px solid var(--bg4); border-radius: 4px; padding: 12px;
  font-size: 12px; line-height: 1.5; overflow-x: auto; font-family: 'SF Mono', Consolas, 'Liberation Mono', monospace; color: var(--fg2); }
.ev-error { color: var(--red); font-weight: 500; }
.ev-warn { color: var(--orange); }
.ev-ctx { color: var(--fg3); }
.ev-sep { color: var(--bg4); display: block; }
.data-table { width: 100%; border-collapse: collapse; font-size: 13px; }
.data-table th { background: var(--bg3); padding: 8px 12px; text-align: left; font-weight: 600; color: var(--fg2);
  font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; }
.data-table td { padding: 8px 12px; border-top: 1px solid var(--bg4); }
.data-table code { background: var(--bg3); padding: 1px 5px; border-radius: 3px; font-size: 12px; }
.cell-warn { color: var(--orange); font-weight: 600; }
.subsection { padding: 12px 16px 4px; font-size: 14px; color: var(--fg2); }
.metrics-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 10px; padding: 16px; }
.metric-item { background: var(--bg3); padding: 12px; border-radius: 6px; text-align: center; }
.metric-val { display: block; font-size: 22px; font-weight: 700; font-family: monospace; }
.metric-label { font-size: 11px; color: var(--fg3); text-transform: uppercase; }
.metric-ok .metric-val { color: var(--green); }
.metric-info .metric-val { color: var(--blue); }
.metric-bad .metric-val { color: var(--orange); }
.metric-warn .metric-val { color: var(--fg2); }
.timeline-section { margin: 8px 16px 12px; }
.timeline-section summary { cursor: pointer; font-size: 14px; color: var(--blue); padding: 8px 0; font-weight: 500; }
.timeline { max-height: 500px; overflow-y: auto; }
.tl-event { display: flex; gap: 8px; align-items: baseline; padding: 3px 0; font-size: 12px; border-bottom: 1px solid var(--bg3); }
.tl-ts { color: var(--fg3); font-family: monospace; font-size: 11px; min-width: 180px; flex-shrink: 0; }
.tl-comp { color: var(--cyan); font-family: monospace; font-size: 11px; min-width: 120px; flex-shrink: 0; }
.tl-msg { color: var(--fg2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.tl-critical { background: rgba(248,81,73,0.08); }
.tl-high { background: rgba(210,153,34,0.08); }
.no-issues { padding: 24px; text-align: center; color: var(--green); font-size: 16px; }
.footer { text-align: center; padding: 24px; color: var(--fg3); font-size: 12px; border-top: 1px solid var(--bg4); margin-top: 20px; }
@media (max-width: 768px) {
  .summary-cards { grid-template-columns: repeat(3, 1fr); }
  .tl-ts { min-width: 100px; }
  .tl-comp { min-width: 80px; }
}
@media print {
  body { background: #fff; color: #000; }
  .header { position: static; background: #f5f5f5; }
  .card { break-inside: avoid; border-color: #ddd; }
  details { open; }
}
</style>
</head>
<body>
CSS
}
