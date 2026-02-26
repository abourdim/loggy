#!/bin/bash
# fleet.sh — Fleet Mode (Multi-Charger Analysis)
# Loggy v6.0 — Phase 11
#
# Loads a folder of RACC zips, runs standard analysis on each,
# produces fleet dashboard, cross-fleet patterns, digest reports.

run_fleet_analysis() {
    local fleet_dir="$1"

    if [ -z "$fleet_dir" ] || [ ! -d "$fleet_dir" ]; then
        log_error "Fleet directory not found: ${fleet_dir:-<none>}"
        log_info "Usage: --fleet <directory-of-racc-zips>"
        return 1
    fi

    # Find all RACC zips
    local -a zips=()
    for f in "$fleet_dir"/*.zip; do
        [ -f "$f" ] && zips+=("$f")
    done

    if [ ${#zips[@]} -eq 0 ]; then
        log_error "No .zip files found in: $fleet_dir"
        return 1
    fi

    log_info "Fleet analysis: ${#zips[@]} charger(s) in $fleet_dir"

    # Save original state
    local orig_work="$WORK_DIR"
    local orig_issues="$ISSUES_FILE"
    local orig_timeline="$TIMELINE_FILE"
    local orig_sysinfo="$SYSINFO_FILE"
    local orig_metrics="$METRICS_FILE"

    local fleet_work
    fleet_work=$(make_temp_dir "iotfleet")
    cleanup_register_dir "$fleet_work"

    local fleet_data="$fleet_work/fleet.tsv"
    local fleet_issues="$fleet_work/all_issues.tsv"
    : > "$fleet_data"
    : > "$fleet_issues"

    local idx=0 total=${#zips[@]}
    local healthy=0 degraded=0 critical_count=0

    for zip in "${zips[@]}"; do
        idx=$((idx + 1))
        local bname
        bname=$(basename "$zip")
        printf "  %s[%d/%d]%s Analyzing %s..." "${CYN}" "$idx" "$total" "${RST}" "$bname"

        local charger_dir="$fleet_work/charger_$idx"
        mkdir -p "$charger_dir"

        # Redirect globals
        WORK_DIR="$charger_dir"
        ISSUES_FILE="$charger_dir/issues.dat"
        TIMELINE_FILE="$charger_dir/timeline.dat"
        SYSINFO_FILE="$charger_dir/sysinfo.dat"
        METRICS_FILE="$charger_dir/metrics.dat"
        touch "$ISSUES_FILE" "$TIMELINE_FILE" "$SYSINFO_FILE" "$METRICS_FILE"
        touch "$charger_dir/log_files.idx"

        if load_input "$zip" 2>/dev/null && parse_all_logs 2>/dev/null; then
            run_standard_analysis 2>/dev/null

            local dev_id fw score grade issue_total issues_crit issues_high
            dev_id=$(get_sysinfo device_id)
            fw=$(get_sysinfo fw_version)
            score=$(get_metric health_score)
            grade=$(get_metric health_grade)
            issue_total=$(get_metric issues_total)
            issues_crit=$(get_metric issues_critical)
            issues_high=$(get_metric issues_high)

            # Classify health
            local health="healthy"
            if [ "${issues_crit:-0}" -gt 0 ]; then
                health="critical"; critical_count=$((critical_count + 1))
            elif [ "${issues_high:-0}" -gt 0 ] || [ "${score:-100}" -lt 50 ]; then
                health="degraded"; degraded=$((degraded + 1))
            else
                healthy=$((healthy + 1))
            fi

            # Fleet data row: idx, device_id, firmware, score, grade, issues, health, zip, connector_info
            local _mc _c1e _c2e
            _mc=$(safe_int "$(get_metric multi_connector)")
            _c1e=$(safe_int "$(get_metric conn1_errors)")
            _c2e=$(safe_int "$(get_metric conn2_errors)")
            local conn_info="single"
            [ "$_mc" -eq 1 ] && conn_info="dual:${_c1e}/${_c2e}"

            printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$idx" "${dev_id:-unknown}" "${fw:-?}" "${score:-?}" "${grade:-?}" \
                "${issue_total:-0}" "$health" "$bname" "$conn_info" >> "$fleet_data"

            # Collect all issues with device attribution
            if [ -f "$ISSUES_FILE" ] && [ -s "$ISSUES_FILE" ]; then
                while IFS=$'\t' read -r sev comp title desc evfile; do
                    [ -z "$sev" ] && continue
                    printf '%s\t%s\t%s\t%s\t%s\n' "${dev_id:-unknown}" "$sev" "$comp" "$title" "$desc" >> "$fleet_issues"
                done < "$ISSUES_FILE"
            fi

            printf " %s%s (%s/100, %s issues)%s\n" \
                "$([ "$health" = "critical" ] && printf '%s' "${RED}" || ([ "$health" = "degraded" ] && printf '%s' "${YLW}" || printf '%s' "${GRN}"))" \
                "$health" "${score:-?}" "${issue_total:-0}" "${RST}"
        else
            printf " %sFAILED%s\n" "${RED}" "${RST}"
            printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$idx" "unknown" "?" "0" "F" "?" "error" "$bname" "unknown" >> "$fleet_data"
        fi
    done

    # Restore globals
    WORK_DIR="$orig_work"
    ISSUES_FILE="$orig_issues"
    TIMELINE_FILE="$orig_timeline"
    SYSINFO_FILE="$orig_sysinfo"
    METRICS_FILE="$orig_metrics"

    # ─── Fleet Dashboard ────────────────────────────────────────────────
    printf "\n"
    printf "  %s╔══════════════════════════════════════════════╗%s\n" "${CYN}" "${RST}"
    printf "  %s║%s  %s⚡ Fleet Dashboard%s                          %s║%s\n" "${CYN}" "${RST}" "${BLD}" "${RST}" "${CYN}" "${RST}"
    printf "  %s╚══════════════════════════════════════════════╝%s\n" "${CYN}" "${RST}"

    printf "\n  %sFleet Summary:%s %d chargers — " "${BLD}" "${RST}" "$total"
    printf "%s%d healthy%s, " "${GRN}" "$healthy" "${RST}"
    printf "%s%d degraded%s, " "${YLW}" "$degraded" "${RST}"
    printf "%s%d critical%s\n\n" "${RED}" "$critical_count" "${RST}"

    # Charger table (sorted by score ascending = worst first)
    printf "  %-4s %-26s %-16s %5s %5s %6s %-10s %s\n" "#" "DEVICE" "FIRMWARE" "SCORE" "GRADE" "ISSUES" "CONNECTORS" "STATUS"
    printf "  %-4s %-26s %-16s %5s %5s %6s %-10s %s\n" "──" "──────" "────────" "─────" "─────" "──────" "──────────" "──────"

    sort -t$'\t' -k4,4n "$fleet_data" | while IFS=$'\t' read -r num dev fw sc gr iss health zip conn_info; do
        local scolor="${GRN}"
        [ "$health" = "degraded" ] && scolor="${YLW}"
        [ "$health" = "critical" ] && scolor="${RED}"
        [ "$health" = "error" ] && scolor="${RED}"
        local dev_short="${dev:0:24}"
        local conn_disp="${conn_info:-single}"
        printf "  %-4s %-26s %-16s %5s %5s %6s %-10s %s%s%s\n" \
            "$num" "$dev_short" "$fw" "$sc" "$gr" "$iss" "$conn_disp" "$scolor" "$health" "${RST}"
    done

    # ─── Cross-fleet patterns ───────────────────────────────────────────
    if [ -s "$fleet_issues" ]; then
        printf "\n  %sCross-Fleet Patterns:%s\n" "${BLD}" "${RST}"

        # Count how many chargers have each issue title
        local issue_freq
        issue_freq=$(cut -f4 "$fleet_issues" | sort | uniq -c | sort -rn)

        printf "\n  %-4s %-50s %s\n" "COUNT" "ISSUE" "SEVERITY"
        printf "  %-4s %-50s %s\n" "─────" "─────" "────────"
        echo "$issue_freq" | head -15 | while read -r cnt title; do
            local sev
            sev=$(grep "$title" "$fleet_issues" | head -1 | cut -f2)
            local scolor="${RST}"
            [ "$sev" = "CRITICAL" ] && scolor="${RED}"
            [ "$sev" = "HIGH" ] && scolor="${RED}"
            printf "  %s%-4s%s %-50s %s%s%s\n" "${BLD}" "$cnt" "${RST}" "$(echo "$title" | cut -c1-48)" "$scolor" "$sev" "${RST}"
        done

        # Common vs unique
        local shared_issues unique_issues
        shared_issues=$(echo "$issue_freq" | awk '$1 > 1 {print}' | wc -l | tr -d ' ')
        unique_issues=$(echo "$issue_freq" | awk '$1 == 1 {print}' | wc -l | tr -d ' ')
        printf "\n  %sShared issues:%s %d (appear in 2+ chargers)\n" "${GRY}" "${RST}" "${shared_issues:-0}"
        printf "  %sUnique issues:%s %d (single charger only)\n" "${GRY}" "${RST}" "${unique_issues:-0}"

        # Firmware correlation
        local fw_versions
        fw_versions=$(cut -f3 "$fleet_data" | sort -u | grep -v '?' | wc -l | tr -d ' ')
        if [ "${fw_versions:-0}" -gt 1 ]; then
            printf "\n  %sFirmware Versions:%s\n" "${BLD}" "${RST}"
            cut -f3 "$fleet_data" | sort | uniq -c | sort -rn | while read -r cnt fw; do
                printf "    %s× %s\n" "$cnt" "$fw"
            done
        fi
    fi

    # Connector fleet summary
    local dual_count single_count imbalance_count
    dual_count=$(cut -f9 "$fleet_data" 2>/dev/null | grep -c '^dual' || true)
    single_count=$(cut -f9 "$fleet_data" 2>/dev/null | grep -c '^single' || true)
    imbalance_count=$(grep -c 'Connector.*Imbalance\|Disproportionately' "$fleet_issues" 2>/dev/null || true)
    if [ "$dual_count" -gt 0 ]; then
        printf "\n  %sConnector Summary:%s %d dual-connector, %d single-connector\n" "${BLD}" "${RST}" "$dual_count" "$single_count"
        if [ "$imbalance_count" -gt 0 ]; then
            printf "  %s⚠ %d charger(s) with connector imbalance detected%s\n" "${YLW}" "$imbalance_count" "${RST}"
        fi
    fi

    # ─── Cross-charger timeline event correlation ────────────────────────
    _fleet_correlate_timelines "$fleet_work" "$total"

    # ─── Generate fleet reports ──────────────────────────────────────────
    local datestamp
    datestamp=$(date +%Y%m%d_%H%M)
    mkdir -p "$OUTPUT_DIR"

    _fleet_gen_markdown "$fleet_data" "$fleet_issues" "$fleet_work" \
        "${OUTPUT_DIR}/fleet_${datestamp}.md"
    _fleet_gen_html "$fleet_data" "$fleet_issues" "$fleet_work" \
        "${OUTPUT_DIR}/fleet_${datestamp}.html"

    printf "\n"
    log_ok "Fleet analysis complete: $total chargers"
    log_info "Reports: ${OUTPUT_DIR}/fleet_${datestamp}.md, .html"
}

# ─── Cross-charger Timeline Correlation ─────────────────────────────────────
# Finds events within a 5-min window on 2+ chargers → shared infrastructure issues
_fleet_correlate_timelines() {
    local fleet_work="$1" charger_count="$2"
    [ "$charger_count" -lt 2 ] && return

    # Collect all timeline events from all charger subdirs
    local combined="$fleet_work/combined_timeline.dat"
    : > "$combined"

    local cdir dev tfile
    for cdir in "$fleet_work"/*/; do
        [ -d "$cdir" ] || continue
        tfile="$cdir/timeline.dat"
        [ -f "$tfile" ] || continue
        dev=$(basename "$cdir")
        while IFS=$'\t' read -r ts sev comp msg; do
            [ -z "$ts" ] && continue
            printf "%s\t%s\t%s\t%s\t%s\n" "$ts" "$sev" "$comp" "$msg" "$dev"
        done < "$tfile"
    done >> "$combined"

    [ -s "$combined" ] || return

    local sorted="$fleet_work/sorted_timeline.dat"
    sort -t$'\t' -k1,1 "$combined" > "$sorted" 2>/dev/null || cp "$combined" "$sorted"

    local pycmd=""
    command -v python3 >/dev/null 2>&1 && pycmd="python3"
    [ -z "$pycmd" ] && command -v python >/dev/null 2>&1 && pycmd="python"

    if [ -n "$pycmd" ]; then
        local corr_out
        corr_out=$($pycmd "$sorted" 300 2>/dev/null << 'PEOF'
import sys, re
from datetime import datetime, timedelta
fn, window = sys.argv[1], int(sys.argv[2])
def parse_ts(s):
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try: return datetime.strptime(s[:26], fmt)
        except: pass
events = []
with open(fn) as f:
    for line in f:
        p = line.rstrip('\n').split('\t')
        if len(p) < 5: continue
        ts = parse_ts(p[0])
        if ts: events.append((ts, p[1], p[2], p[3], p[4]))
seen, out = set(), []
for i,(ts,sev,comp,msg,dev) in enumerate(events):
    wend = ts + timedelta(seconds=window)
    devs = {dev}
    for j in range(i+1, len(events)):
        ts2,sev2,comp2,msg2,dev2 = events[j]
        if ts2 > wend: break
        if dev2 not in devs: devs.add(dev2)
    if len(devs) >= 2 and sev in ('CRITICAL','HIGH','ERROR','E','C'):
        key = (ts.strftime('%Y-%m-%d %H:%M')[:16], comp, tuple(sorted(devs)))
        if key not in seen:
            seen.add(key)
            print(f"{ts.strftime('%Y-%m-%d %H:%M:%S')}\t{len(devs)}\t{comp}\t{msg[:60]}\t{','.join(sorted(devs))}")
PEOF
)
        if [ -n "$corr_out" ]; then
            printf "\n  %s⚡ Cross-Charger Correlated Events (5-min window):%s\n" "${BLD}${YLW}" "${RST}"
            printf "  %s%-20s %4s  %-20s %s%s\n" "${DIM}" "TIMESTAMP" "CHS" "COMPONENT" "EVENT" "${RST}"
            printf "  %-20s %4s  %-20s %s\n" "────────────────────" "───" "────────────────────" "──────────────────────────────────────────────"
            echo "$corr_out" | head -20 | while IFS=$'\t' read -r ts nd comp msg devs; do
                printf "  %-20s %s%4s%s  %-20s %s\n" \
                    "$ts" "${YLW}${BLD}" "$nd" "${RST}" \
                    "$(echo "$comp" | cut -c1-18)" \
                    "$(echo "$msg"  | cut -c1-46)"
                printf "  %s    Chargers: %s%s\n" "${DIM}" "$devs" "${RST}"
            done
        else
            printf "\n  %sNo correlated cross-charger events found.%s\n" "${DIM}" "${RST}"
        fi
    else
        printf "\n  %sCross-charger correlation skipped (Python not available).%s\n" "${DIM}" "${RST}"
    fi

    rm -f "$combined" "$sorted" 2>/dev/null
}


# ─── Fleet Markdown Report ───────────────────────────────────────────────────
_fleet_gen_markdown() {
    local fleet_data="$1" fleet_issues="$2" fleet_work="$3" outfile="$4"

    local total healthy degraded crit_count
    total=$(wc -l < "$fleet_data" | tr -d ' ')
    healthy=$(grep -c 'healthy' "$fleet_data" || true)
    degraded=$(grep -c 'degraded' "$fleet_data" || true)
    crit_count=$(grep -c 'critical' "$fleet_data" || true)

    {
        printf "# Fleet Analysis Report\n\n"
        printf "Generated: %s | Loggy v%s\n\n" "$(date '+%Y-%m-%d %H:%M')" "$ANALYZER_VERSION"

        printf "## Summary\n\n"
        printf "| Metric | Value |\n|---|---|\n"
        printf "| Total Chargers | %d |\n" "$total"
        printf "| Healthy | %d |\n" "${healthy:-0}"
        printf "| Degraded | %d |\n" "${degraded:-0}"
        printf "| Critical | %d |\n\n" "${crit_count:-0}"

        printf "## Charger Status\n\n"
        printf "| # | Device | Firmware | Score | Issues | Connectors | Status |\n"
        printf "|---|---|---|---|---|---|---|\n"
        sort -t$'\t' -k4,4n "$fleet_data" | while IFS=$'\t' read -r num dev fw sc gr iss health zip conn_info; do
            local icon="✅"
            [ "$health" = "degraded" ] && icon="⚠️"
            [ "$health" = "critical" ] && icon="🔴"
            [ "$health" = "error" ] && icon="❌"
            printf "| %s | \`%s\` | %s | %s | %s | %s | %s %s |\n" \
                "$num" "$dev" "$fw" "$sc" "$iss" "${conn_info:-single}" "$icon" "$health"
        done

        if [ -s "$fleet_issues" ]; then
            printf "\n## Cross-Fleet Issues\n\n"
            printf "| Count | Issue | Severity |\n|---|---|---|\n"
            cut -f4 "$fleet_issues" | sort | uniq -c | sort -rn | head -20 | while read -r cnt title; do
                local sev
                sev=$(grep "$title" "$fleet_issues" | head -1 | cut -f2)
                printf "| %s | %s | **%s** |\n" "$cnt" "$title" "$sev"
            done
        fi

        printf "\n---\n*Loggy v%s*\n" "$ANALYZER_VERSION"
    } > "$outfile"

    [ -s "$outfile" ] && log_ok "Fleet MD: $outfile"
}

# ─── Fleet HTML Report ───────────────────────────────────────────────────────
_fleet_gen_html() {
    local fleet_data="$1" fleet_issues="$2" fleet_work="$3" outfile="$4"

    local total healthy degraded crit_count
    total=$(wc -l < "$fleet_data" | tr -d ' ')
    healthy=$(grep -c 'healthy' "$fleet_data" || true)
    degraded=$(grep -c 'degraded' "$fleet_data" || true)
    crit_count=$(grep -c 'critical' "$fleet_data" || true)

    {
        cat << 'FLEETHEAD'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Fleet Analysis</title>
<style>
:root{--bg:#0f1117;--bg2:#1a1d27;--bg3:#242836;--border:#2e3348;--fg:#d1d5db;--fg2:#9ca3af;
--red:#ef4444;--green:#22c55e;--orange:#f59e0b;--blue:#3b82f6;}
*{margin:0;padding:0;box-sizing:border-box;}
body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--fg);padding:32px;line-height:1.6;max-width:1200px;margin:0 auto;}
h1{font-size:24px;color:#fff;margin-bottom:4px;}h2{font-size:18px;color:#fff;margin:28px 0 14px;border-bottom:1px solid var(--border);padding-bottom:8px;}
.subtitle{color:var(--fg2);font-size:13px;margin-bottom:24px;}
.stats{display:flex;gap:16px;margin-bottom:24px;flex-wrap:wrap;}
.stat{background:var(--bg2);border:1px solid var(--border);border-radius:8px;padding:20px;text-align:center;min-width:120px;flex:1;}
.stat .num{font-size:32px;font-weight:700;}.stat .label{font-size:11px;color:var(--fg2);text-transform:uppercase;letter-spacing:.5px;margin-top:4px;}
.stat.green .num{color:var(--green);}.stat.orange .num{color:var(--orange);}.stat.red .num{color:var(--red);}.stat.blue .num{color:var(--blue);}
table{width:100%;border-collapse:collapse;font-size:13px;margin-bottom:16px;}
th{background:var(--bg3);padding:10px 14px;text-align:left;color:var(--fg2);font-size:11px;text-transform:uppercase;letter-spacing:.5px;}
td{padding:10px 14px;border-top:1px solid var(--border);}
tr:hover td{background:var(--bg2);}
code{font-family:Consolas,monospace;background:var(--bg3);padding:2px 6px;border-radius:3px;font-size:12px;}
.healthy{color:var(--green);font-weight:600;}.degraded{color:var(--orange);font-weight:600;}.critical{color:var(--red);font-weight:600;}
</style></head><body>
FLEETHEAD

        printf '<h1>⚡ Fleet Analysis Report</h1>\n'
        printf '<div class="subtitle">%d chargers — %s</div>\n' "$total" "$(date '+%Y-%m-%d %H:%M')"

        printf '<div class="stats">\n'
        printf '<div class="stat blue"><div class="num">%d</div><div class="label">Total</div></div>\n' "$total"
        printf '<div class="stat green"><div class="num">%d</div><div class="label">Healthy</div></div>\n' "${healthy:-0}"
        printf '<div class="stat orange"><div class="num">%d</div><div class="label">Degraded</div></div>\n' "${degraded:-0}"
        printf '<div class="stat red"><div class="num">%d</div><div class="label">Critical</div></div>\n' "${crit_count:-0}"
        printf '</div>\n'

        printf '<h2>Charger Status</h2>\n<table>\n'
        printf '<tr><th>#</th><th>Device</th><th>Firmware</th><th>Score</th><th>Issues</th><th>Connectors</th><th>Status</th></tr>\n'
        sort -t$'\t' -k4,4n "$fleet_data" | while IFS=$'\t' read -r num dev fw sc gr iss health zip conn_info; do
            printf '<tr><td>%s</td><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td class="%s">%s</td></tr>\n' \
                "$num" "$dev" "$fw" "$sc" "$iss" "${conn_info:-single}" "$health" "$health"
        done
        printf '</table>\n'

        if [ -s "$fleet_issues" ]; then
            printf '<h2>Cross-Fleet Issues</h2>\n<table>\n'
            printf '<tr><th>Count</th><th>Issue</th><th>Severity</th></tr>\n'
            cut -f4 "$fleet_issues" | sort | uniq -c | sort -rn | head -20 | while read -r cnt title; do
                local sev
                sev=$(grep "$title" "$fleet_issues" | head -1 | cut -f2)
                local sclass=""
                [ "$sev" = "CRITICAL" ] || [ "$sev" = "HIGH" ] && sclass="critical"
                printf '<tr><td><strong>%s</strong></td><td>%s</td><td class="%s">%s</td></tr>\n' \
                    "$cnt" "$title" "$sclass" "$sev"
            done
            printf '</table>\n'
        fi

        printf '</body></html>\n'
    } > "$outfile"

    [ -s "$outfile" ] && log_ok "Fleet HTML: $outfile"
}
