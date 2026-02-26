#!/bin/bash
# gen_webapp.sh — Interactive Web App Generator
# Loggy v6.0 — Phase 4
#
# Generates a self-contained single HTML file with embedded JSON data
# and JavaScript for interactive analysis viewing. No server required.

generate_webapp() {
    local outfile="$1"
    [ -z "$outfile" ] && outfile="$OUTPUT_DIR/webapp_$(get_sysinfo device_id)_$(date +%Y%m%d_%H%M).html"

    # ─── Serialize Data to JSON ─────────────────────────────────────────
    local json_data
    json_data=$(_webapp_build_json)

    # ─── Generate HTML ──────────────────────────────────────────────────
    {
        _webapp_head
        _webapp_css
        echo '</style></head><body>'
        _webapp_sidebar
        echo '<main id="main">'
        _webapp_views
        echo '</main>'
        echo "<script>const DATA = $json_data;</script>"
        _webapp_js
        echo '</body></html>'
    } > "$outfile"

    if [ -s "$outfile" ]; then
        local size
        size=$(wc -c < "$outfile" | tr -d ' ')
        log_ok "Web app: $outfile"
        _log_file "INFO" "Web app: $outfile ($size bytes)"
    else
        log_error "Failed to generate web app"
        rm -f "$outfile"
        return 1
    fi
    return 0
}

# ─── JSON Serialization ─────────────────────────────────────────────────────
_webapp_build_json() {
    echo '{'

    # Device info
    echo '"device": {'
    printf '  "id": "%s",\n' "$(get_sysinfo device_id)"
    printf '  "firmware": "%s",\n' "$(get_sysinfo fw_version)"
    printf '  "release": "%s",\n' "$(get_sysinfo release_version)"
    printf '  "scope": "%s",\n' "$(get_sysinfo scope)"
    printf '  "artifact": "%s",\n' "$(get_sysinfo artifact_version)"
    printf '  "build": "%s",\n' "$(get_sysinfo build_info)"
    printf '  "bootSlot": "%s",\n' "$(get_sysinfo boot_slot)"
    printf '  "memTotal": "%s",\n' "$(get_sysinfo mem_total_kb)"
    printf '  "memFree": "%s",\n' "$(get_sysinfo mem_free_kb)"
    printf '  "memAvail": "%s"\n' "$(get_sysinfo mem_available_kb)"
    echo '},'

    # Timestamp
    printf '"generated": "%s",\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '"version": "%s",\n' "$ANALYZER_VERSION"

    # Status
    echo '"status": {'
    local first=1
    local status_file="$WORK_DIR/status.dat"
    if [ -f "$status_file" ]; then
        while IFS=$'\t' read -r name state; do
            [ -z "$name" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '  "%s": "%s"' "$(_json_escape "$name")" "$(_json_escape "$state")"
        done < "$status_file"
    fi
    echo ''
    echo '},'

    # Metrics
    echo '"metrics": {'
    first=1
    if [ -f "$METRICS_FILE" ]; then
        while IFS='=' read -r key val; do
            [ -z "$key" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            # Numeric values without quotes
            if echo "$val" | grep -qE '^[0-9]+$'; then
                printf '  "%s": %s' "$(_json_escape "$key")" "$val"
            else
                printf '  "%s": "%s"' "$(_json_escape "$key")" "$(_json_escape "$val")"
            fi
        done < "$METRICS_FILE"
    fi
    echo ''
    echo '},'

    # Issues
    echo '"issues": ['
    first=1
    if [ -f "$ISSUES_FILE" ] && [ -s "$ISSUES_FILE" ]; then
        while IFS=$'\t' read -r sev comp title desc evfile; do
            [ -z "$sev" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            echo '  {'
            printf '    "severity": "%s",\n' "$(_json_escape "$sev")"
            printf '    "component": "%s",\n' "$(_json_escape "$comp")"
            printf '    "title": "%s",\n' "$(_json_escape "$title")"
            printf '    "description": "%s",\n' "$(_json_escape "$desc")"
            # Embed evidence (capped at 60 lines)
            printf '    "evidence": '
            if [ -n "$evfile" ] && [ -f "$evfile" ]; then
                _json_file_lines "$evfile" 60
            else
                echo '[]'
            fi
            echo '  }'
        done < "$ISSUES_FILE"
    fi
    echo '],'

    # Timeline
    echo '"timeline": ['
    first=1
    if [ -f "$TIMELINE_FILE" ] && [ -s "$TIMELINE_FILE" ]; then
        while IFS=$'\t' read -r ts sev comp msg; do
            [ -z "$ts" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '  ["%s","%s","%s","%s"]' \
                "$(_json_escape "$ts")" "$(_json_escape "$sev")" \
                "$(_json_escape "$comp")" "$(_json_escape "$msg")"
        done < "$TIMELINE_FILE"
    fi
    echo '],'

    # Error summary
    echo '"errors": ['
    first=1
    if [ -f "$WORK_DIR/error_summary.dat" ] && [ -s "$WORK_DIR/error_summary.dat" ]; then
        while IFS='|' read -r comp errs warns crits; do
            [ -z "$comp" ] && continue
            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '  {"component":"%s","errors":%s,"warnings":%s,"critical":%s}' \
                "$(_json_escape "$comp")" "${errs:-0}" "${warns:-0}" "${crits:-0}"
        done < "$WORK_DIR/error_summary.dat"
    fi
    echo '],'

    # Health score
    health_score_json
    echo ','

    # Deep analysis (if available — check any deep output file)
    local _has_deep=0
    for _df in deep_causal.dat deep_boot_timing.dat deep_reboots.dat deep_connectivity.dat deep_state_machine.dat deep_sessions.dat; do
        [ -f "$WORK_DIR/$_df" ] && { _has_deep=1; break; }
    done
    if [ "$_has_deep" -eq 1 ]; then
        deep_analysis_json
    else
        echo '"deepAnalysis": null'
    fi

    echo '}'
}

_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/}"
    printf '%s' "$s"
}

_json_file_lines() {
    local file="$1" max="${2:-60}"
    echo '['
    local n=0 first=1
    while IFS= read -r line; do
        n=$((n + 1))
        [ "$n" -gt "$max" ] && break
        [ "$first" -eq 1 ] && first=0 || echo ','
        printf '    "%s"' "$(_json_escape "$line")"
    done < "$file"
    local total
    total=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    if [ "${total:-0}" -gt "$max" ]; then
        printf ',\n    "... %d more lines"' "$((total - max))"
    fi
    echo ''
    echo '  ]'
}

# ─── HTML Head ───────────────────────────────────────────────────────────────
_webapp_head() {
    local device_id
    device_id=$(get_sysinfo device_id)
    cat << 'ENDHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
ENDHEAD
    printf '<title>IoTecha Analyzer — %s</title>\n' "${device_id:-unknown}"
    echo '<style>'
}

# ─── CSS ─────────────────────────────────────────────────────────────────────
_webapp_css() {
    cat << 'ENDCSS'
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&family=DM+Sans:wght@400;500;600;700&display=swap');
:root {
  --bg: #0b0e14; --bg2: #10141c; --bg3: #171c28; --bg4: #1f2937;
  --bg-hover: #242d3d; --border: #2a3444; --border2: #374151;
  --fg: #d1d5db; --fg2: #9ca3af; --fg3: #6b7280; --fg-bright: #f3f4f6;
  --red: #ef4444; --red-dim: #991b1b; --red-bg: rgba(239,68,68,0.08);
  --orange: #f59e0b; --orange-dim: #92400e; --orange-bg: rgba(245,158,11,0.08);
  --yellow: #eab308; --yellow-bg: rgba(234,179,8,0.06);
  --green: #22c55e; --green-dim: #166534; --green-bg: rgba(34,197,94,0.08);
  --blue: #3b82f6; --blue-dim: #1e40af; --blue-bg: rgba(59,130,246,0.08);
  --cyan: #06b6d4; --purple: #a855f7;
  --font: 'DM Sans', system-ui, -apple-system, sans-serif;
  --mono: 'JetBrains Mono', 'SF Mono', Consolas, monospace;
  --sidebar-w: 240px;
  --radius: 8px; --radius-sm: 5px;
}
*, *::before, *::after { margin:0; padding:0; box-sizing:border-box; }
html { font-size: 14px; }
body { font-family: var(--font); background: var(--bg); color: var(--fg);
  line-height: 1.6; display: flex; min-height: 100vh; overflow: hidden; }

/* ── Scrollbar ── */
::-webkit-scrollbar { width: 6px; height: 6px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
::-webkit-scrollbar-thumb:hover { background: var(--fg3); }

/* ── Sidebar ── */
.sidebar { width: var(--sidebar-w); background: var(--bg2); border-right: 1px solid var(--border);
  display: flex; flex-direction: column; flex-shrink: 0; position: fixed; top: 0; left: 0;
  height: 100vh; z-index: 20; }
.sidebar-brand { padding: 20px 16px 12px; border-bottom: 1px solid var(--border); }
.sidebar-brand h1 { font-size: 15px; font-weight: 700; color: var(--fg-bright);
  display: flex; align-items: center; gap: 8px; letter-spacing: -0.3px; }
.sidebar-brand h1 span { font-size: 20px; }
.sidebar-brand .device-id { font-family: var(--mono); font-size: 10px;
  color: var(--fg3); margin-top: 4px; letter-spacing: 0.5px; }
.sidebar-nav { padding: 12px 8px; flex: 1; overflow-y: auto; }
.nav-item { display: flex; align-items: center; gap: 10px; padding: 9px 12px;
  border-radius: var(--radius-sm); cursor: pointer; color: var(--fg2);
  font-size: 13px; font-weight: 500; transition: all 0.15s;
  user-select: none; margin-bottom: 2px; }
.nav-item:hover { background: var(--bg-hover); color: var(--fg); }
.nav-item.active { background: var(--blue-bg); color: var(--blue); font-weight: 600; }
.nav-item .icon { font-size: 16px; width: 20px; text-align: center; flex-shrink: 0; }
.nav-item .badge { margin-left: auto; background: var(--red); color: #fff;
  font-size: 10px; font-weight: 700; padding: 1px 6px; border-radius: 10px;
  font-family: var(--mono); }
.sidebar-footer { padding: 12px 16px; border-top: 1px solid var(--border);
  font-size: 10px; color: var(--fg3); }

/* ── Main ── */
main { margin-left: var(--sidebar-w); flex: 1; overflow-y: auto; height: 100vh;
  scroll-behavior: smooth; }
.view { display: none; padding: 28px 32px; max-width: 1200px; min-height: 100vh; }
.view.active { display: block; }
.view-header { margin-bottom: 24px; }
.view-header h2 { font-size: 22px; font-weight: 700; color: var(--fg-bright);
  letter-spacing: -0.5px; }
.view-header p { color: var(--fg3); font-size: 13px; margin-top: 4px; }

/* ── Cards ── */
.card { background: var(--bg2); border: 1px solid var(--border); border-radius: var(--radius);
  margin-bottom: 16px; overflow: hidden; }
.card-header { padding: 14px 18px; font-weight: 600; font-size: 13px;
  color: var(--fg2); text-transform: uppercase; letter-spacing: 0.6px;
  border-bottom: 1px solid var(--border); background: var(--bg3); }

/* ── Dashboard Grid ── */
.stat-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 12px;
  margin-bottom: 20px; }
.stat-card { background: var(--bg2); border: 1px solid var(--border); border-radius: var(--radius);
  padding: 18px; text-align: center; transition: border-color 0.2s; }
.stat-card:hover { border-color: var(--border2); }
.stat-val { font-family: var(--mono); font-size: 28px; font-weight: 700; line-height: 1.2; }
.stat-label { font-size: 11px; color: var(--fg3); text-transform: uppercase;
  letter-spacing: 0.8px; margin-top: 4px; }
.stat-card.red .stat-val { color: var(--red); }
.stat-card.orange .stat-val { color: var(--orange); }
.stat-card.yellow .stat-val { color: var(--yellow); }
.stat-card.green .stat-val { color: var(--green); }
.stat-card.blue .stat-val { color: var(--blue); }
.stat-card.purple .stat-val { color: var(--purple); }

/* ── Status Grid ── */
.status-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr));
  gap: 10px; padding: 16px; }
.status-pill { display: flex; flex-direction: column; align-items: center;
  padding: 14px 10px; border-radius: var(--radius); background: var(--bg);
  border: 1px solid var(--border); gap: 4px; transition: transform 0.15s; }
.status-pill:hover { transform: translateY(-1px); }
.status-pill .dot { width: 10px; height: 10px; border-radius: 50%; }
.status-pill .name { font-size: 13px; font-weight: 600; }
.status-pill .label { font-size: 10px; text-transform: uppercase; letter-spacing: 0.8px; font-weight: 600; }
.status-pill.up .dot { background: var(--green); box-shadow: 0 0 8px var(--green); }
.status-pill.up .label { color: var(--green); }
.status-pill.down .dot { background: var(--red); box-shadow: 0 0 8px var(--red); animation: pulse 2s infinite; }
.status-pill.down .label { color: var(--red); }
.status-pill.degraded .dot { background: var(--orange); box-shadow: 0 0 8px var(--orange); }
.status-pill.degraded .label { color: var(--orange); }
.status-pill.unknown .dot { background: var(--fg3); }
.status-pill.unknown .label { color: var(--fg3); }
@keyframes pulse { 0%,100% { opacity:1; } 50% { opacity:0.5; } }

/* ── Issue Cards ── */
.issue-card { border: 1px solid var(--border); border-radius: var(--radius);
  margin-bottom: 12px; overflow: hidden; cursor: pointer; transition: border-color 0.2s; }
.issue-card:hover { border-color: var(--border2); }
.issue-card.critical { border-left: 4px solid var(--red); }
.issue-card.high { border-left: 4px solid var(--orange); }
.issue-card.medium { border-left: 4px solid var(--yellow); }
.issue-card.low { border-left: 4px solid var(--green); }
.issue-head { padding: 14px 18px; display: flex; align-items: center; gap: 10px;
  flex-wrap: wrap; background: var(--bg2); }
.issue-head .num { font-family: var(--mono); font-size: 12px; color: var(--fg3);
  font-weight: 600; min-width: 28px; }
.issue-head .sev-badge { padding: 2px 8px; border-radius: 4px; font-size: 10px;
  font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; }
.sev-badge.critical { background: var(--red); color: #fff; }
.sev-badge.high { background: var(--orange); color: #000; }
.sev-badge.medium { background: var(--yellow); color: #000; }
.sev-badge.low { background: var(--green); color: #000; }
.issue-head .title { font-weight: 600; font-size: 14px; color: var(--fg-bright); flex: 1; }
.issue-head .comp { font-family: var(--mono); font-size: 11px; color: var(--fg3);
  background: var(--bg); padding: 2px 8px; border-radius: 3px; }
.issue-head .chevron { color: var(--fg3); font-size: 12px; transition: transform 0.2s; margin-left: 8px; }
.issue-card.open .chevron { transform: rotate(90deg); }
.issue-body { display: none; padding: 0 18px 16px; background: var(--bg2); }
.issue-card.open .issue-body { display: block; }
.issue-desc { color: var(--fg2); font-size: 13px; line-height: 1.6; margin-bottom: 12px;
  padding-top: 4px; border-top: 1px solid var(--border); }
.issue-ts { font-size: 12px; color: var(--fg); background: rgba(59,130,246,.08);
  border-left: 3px solid #3b82f6; padding: 6px 10px; margin-bottom: 8px; border-radius: 0 4px 4px 0; line-height: 1.5; }
.issue-onsite { font-size: 12px; font-weight: 600; color: #dc2626; margin-bottom: 8px; }
.onsite-badge { font-size: 10px; padding: 2px 6px; border-radius: 3px; background: #fef2f2; color: #dc2626; }
.evidence-block { background: var(--bg); border: 1px solid var(--border);
  border-radius: var(--radius-sm); padding: 12px; overflow-x: auto;
  font-family: var(--mono); font-size: 11px; line-height: 1.6;
  max-height: 320px; overflow-y: auto; color: var(--fg2); }
.ev-error { color: var(--red); font-weight: 500; }
.ev-warn { color: var(--orange); }
.ev-ctx { color: var(--fg3); }
.ev-sep { color: var(--border); display: block; }
.ev-label { font-size: 11px; color: var(--fg3); margin-bottom: 6px; font-weight: 600;
  text-transform: uppercase; letter-spacing: 0.5px; }

/* ── Timeline ── */
.tl-controls { display: flex; gap: 8px; margin-bottom: 14px; flex-wrap: wrap; align-items: center; }
.tl-controls input, .tl-controls select { background: var(--bg2); border: 1px solid var(--border);
  color: var(--fg); padding: 7px 12px; border-radius: var(--radius-sm); font-size: 12px;
  font-family: var(--font); outline: none; }
.tl-controls input:focus, .tl-controls select:focus { border-color: var(--blue); }
.tl-controls input { flex: 1; min-width: 200px; }
.tl-list { max-height: calc(100vh - 220px); overflow-y: auto; }
.tl-row { display: flex; gap: 8px; align-items: baseline; padding: 5px 10px;
  font-size: 12px; border-bottom: 1px solid var(--bg3); transition: background 0.1s; }
.tl-row:hover { background: var(--bg-hover); }
.tl-row.critical { background: var(--red-bg); }
.tl-row.high { background: var(--orange-bg); }
.tl-ts { font-family: var(--mono); font-size: 11px; color: var(--fg3);
  min-width: 175px; flex-shrink: 0; }
.tl-sev { font-size: 10px; font-weight: 700; text-transform: uppercase;
  min-width: 60px; flex-shrink: 0; }
.tl-sev.critical { color: var(--red); }
.tl-sev.high { color: var(--orange); }
.tl-sev.medium { color: var(--yellow); }
.tl-sev.low { color: var(--green); }
.tl-sev.info { color: var(--fg3); }
.tl-comp { font-family: var(--mono); font-size: 11px; color: var(--cyan);
  min-width: 140px; flex-shrink: 0; }
.tl-msg { color: var(--fg2); white-space: nowrap; overflow: hidden;
  text-overflow: ellipsis; flex: 1; }
.tl-count { font-family: var(--mono); font-size: 11px; color: var(--fg3);
  text-align: right; min-width: 30px; }

/* ── Search ── */
.search-box { display: flex; gap: 8px; margin-bottom: 16px; }
.search-box input { flex: 1; background: var(--bg2); border: 1px solid var(--border);
  color: var(--fg); padding: 10px 16px; border-radius: var(--radius); font-size: 13px;
  font-family: var(--font); outline: none; }
.search-box input:focus { border-color: var(--blue); box-shadow: 0 0 0 2px rgba(59,130,246,0.15); }
.search-box button { background: var(--blue); color: #fff; border: none; padding: 10px 20px;
  border-radius: var(--radius); font-weight: 600; cursor: pointer; font-size: 13px;
  font-family: var(--font); transition: background 0.15s; }
.search-box button:hover { background: #2563eb; }
.search-results { max-height: calc(100vh - 240px); overflow-y: auto; }
.search-hit { padding: 12px 16px; border-bottom: 1px solid var(--border);
  background: var(--bg2); border-radius: var(--radius-sm); margin-bottom: 6px; }
.search-hit .hit-source { font-size: 11px; color: var(--cyan); font-weight: 600;
  text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 4px; }
.search-hit .hit-text { font-family: var(--mono); font-size: 12px; color: var(--fg2);
  line-height: 1.5; white-space: pre-wrap; word-break: break-all; }
.search-hit mark { background: rgba(59,130,246,0.25); color: var(--fg-bright);
  padding: 0 2px; border-radius: 2px; }

/* ── Data Table ── */
.dtable { width: 100%; border-collapse: collapse; font-size: 13px; }
.dtable th { background: var(--bg3); padding: 10px 14px; text-align: left;
  font-weight: 600; color: var(--fg3); font-size: 11px; text-transform: uppercase;
  letter-spacing: 0.5px; }
.dtable td { padding: 10px 14px; border-top: 1px solid var(--border); }
.dtable code { font-family: var(--mono); background: var(--bg); padding: 2px 6px;
  border-radius: 3px; font-size: 12px; }
.dtable .warn { color: var(--orange); font-weight: 600; }
.dtable tr:hover td { background: var(--bg-hover); }

/* ── Metrics Grid ── */
.metrics-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
  gap: 10px; padding: 16px; }
.metric-box { background: var(--bg); border: 1px solid var(--border); padding: 14px;
  border-radius: var(--radius); text-align: center; }
.metric-box .val { font-family: var(--mono); font-size: 24px; font-weight: 700; display: block; }
.metric-box .lbl { font-size: 10px; color: var(--fg3); text-transform: uppercase;
  letter-spacing: 0.5px; margin-top: 2px; }
.metric-box.bad .val { color: var(--orange); }
.metric-box.ok .val { color: var(--green); }
.metric-box.info .val { color: var(--blue); }

/* ── Info Table ── */
.info-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
  gap: 12px; padding: 16px; }
.info-row { display: flex; justify-content: space-between; padding: 8px 0;
  border-bottom: 1px solid var(--border); }
.info-row .key { color: var(--fg3); font-size: 12px; text-transform: uppercase;
  letter-spacing: 0.5px; }
.info-row .val { font-family: var(--mono); font-size: 12px; color: var(--fg); text-align: right; }

/* ── Empty State ── */
.empty-state { text-align: center; padding: 48px; color: var(--fg3); }
.empty-state .icon { font-size: 48px; margin-bottom: 12px; display: block; }

/* ── Filter Chips ── */
.chip-group { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 12px; }
.chip { padding: 4px 12px; border-radius: 20px; font-size: 11px; font-weight: 600;
  cursor: pointer; border: 1px solid var(--border); background: var(--bg2);
  color: var(--fg2); transition: all 0.15s; user-select: none; }
.chip:hover { border-color: var(--fg3); }
.chip.active { background: var(--blue-bg); border-color: var(--blue); color: var(--blue); }
.chip.active.red { background: var(--red-bg); border-color: var(--red); color: var(--red); }
.chip.active.orange { background: var(--orange-bg); border-color: var(--orange); color: var(--orange); }
.chip.active.yellow { background: var(--yellow-bg); border-color: var(--yellow); color: var(--yellow); }
.chip.active.green { background: var(--green-bg); border-color: var(--green); color: var(--green); }

/* ── Responsive ── */
@media (max-width: 900px) {
  .sidebar { width: 60px; }
  .sidebar .nav-label, .sidebar-brand .device-id, .sidebar-footer { display: none; }
  .sidebar-brand h1 span { margin: 0 auto; }
  .sidebar-brand h1 { justify-content: center; }
  main { margin-left: 60px; }
  .view { padding: 20px 16px; }
}
@media print {
  body { background: #fff; color: #000; }
  .sidebar { display: none; }
  main { margin-left: 0; }
  .view { display: block !important; page-break-before: always; }
  .issue-body { display: block !important; }
}
ENDCSS
}

# ─── Sidebar HTML ────────────────────────────────────────────────────────────
_webapp_sidebar() {
    local device_id
    device_id=$(get_sysinfo device_id)
    local prefix="${device_id:0:8}"
    [ ${#device_id} -gt 8 ] && prefix="${prefix}…"

    local issue_count
    issue_count=$(get_metric issues_total)
    [ -z "$issue_count" ] && issue_count=0

    cat << ENDSIDEBAR
<nav class="sidebar">
  <div class="sidebar-brand">
    <h1><span>⚡</span> IoTecha Analyzer</h1>
    <div class="device-id">$prefix</div>
  </div>
  <div class="sidebar-nav">
    <div class="nav-item active" data-view="dashboard"><span class="icon">📊</span><span class="nav-label">Dashboard</span></div>
    <div class="nav-item" data-view="issues"><span class="icon">🔍</span><span class="nav-label">Issues</span>$([ "$issue_count" -gt 0 ] && printf '<span class="badge">%s</span>' "$issue_count")</div>
    <div class="nav-item" data-view="timeline"><span class="icon">📈</span><span class="nav-label">Timeline</span></div>
    <div class="nav-item" data-view="errors"><span class="icon">📋</span><span class="nav-label">Error Summary</span></div>
    <div class="nav-item" data-view="search"><span class="icon">🔎</span><span class="nav-label">Search</span></div>
    <div class="nav-item" data-view="system"><span class="icon">🖥️</span><span class="nav-label">System Info</span></div>
    <div class="nav-item" data-view="deep" id="nav-deep" style="display:none;"><span class="icon">🔬</span><span class="nav-label">Deep Analysis</span></div>
  </div>
  <div class="sidebar-footer">Loggy v$ANALYZER_VERSION</div>
</nav>
ENDSIDEBAR
}

# ─── View Shells ─────────────────────────────────────────────────────────────
_webapp_views() {
    cat << 'ENDVIEWS'
<!-- Dashboard -->
<div id="v-dashboard" class="view active">
  <div class="view-header"><h2>Dashboard</h2><p id="dash-subtitle"></p></div>
  <div id="dash-stats" class="stat-grid"></div>
  <div class="card"><div class="card-header">Subsystem Status</div>
    <div id="dash-status" class="status-grid"></div></div>
  <div class="card"><div class="card-header">Key Metrics</div>
    <div id="dash-metrics" class="metrics-grid"></div></div>
</div>

<!-- Issues -->
<div id="v-issues" class="view">
  <div class="view-header"><h2>Issues</h2><p id="issues-subtitle"></p></div>
  <div id="issues-filters" class="chip-group"></div>
  <div id="issues-list"></div>
</div>

<!-- Timeline -->
<div id="v-timeline" class="view">
  <div class="view-header"><h2>Event Timeline</h2><p id="tl-subtitle"></p></div>
  <div class="tl-controls">
    <input type="text" id="tl-search" placeholder="Filter events…">
    <select id="tl-sev-filter">
      <option value="">All severities</option>
      <option value="CRITICAL">Critical</option>
      <option value="HIGH">High</option>
      <option value="MEDIUM">Medium</option>
      <option value="LOW">Low</option>
      <option value="INFO">Info</option>
    </select>
    <select id="tl-comp-filter"><option value="">All components</option></select>
  </div>
  <div id="tl-list" class="tl-list"></div>
</div>

<!-- Error Summary -->
<div id="v-errors" class="view">
  <div class="view-header"><h2>Error Summary</h2><p>Error, warning, and critical counts by component</p></div>
  <div class="card"><table class="dtable" id="err-table">
    <thead><tr><th>Component</th><th>Errors</th><th>Warnings</th><th>Critical</th><th>Total</th></tr></thead>
    <tbody id="err-body"></tbody>
  </table></div>
</div>

<!-- Search -->
<div id="v-search" class="view">
  <div class="view-header"><h2>Search</h2><p>Search across all issues, timeline events, and evidence</p></div>
  <div class="search-box">
    <input type="text" id="search-input" placeholder="Search logs, issues, timeline…">
    <button id="search-btn">Search</button>
  </div>
  <div id="search-info" style="color:var(--fg3);font-size:12px;margin-bottom:12px;"></div>
  <div id="search-results" class="search-results"></div>
</div>

<!-- System -->
<div id="v-system" class="view">
  <div class="view-header"><h2>System Information</h2><p>Device details, firmware, and configuration</p></div>
  <div class="card"><div class="card-header">Device</div>
    <div id="sys-device" style="padding:16px;"></div></div>
</div>

<!-- Deep Analysis -->
<div id="v-deep" class="view">
  <div class="view-header"><h2>Deep Analysis</h2><p>Forensic-level investigation</p></div>
  <div id="deep-boot"></div>
  <div id="deep-chains"></div>
  <div id="deep-histogram"></div>
  <div id="deep-gaps"></div>
  <div id="deep-config"></div>
  <div id="deep-sessions"></div>
  <div id="deep-reboots"></div>
  <div id="deep-conn"></div>
  <div id="deep-sm"></div>
</div>
ENDVIEWS
}

# ─── JavaScript ──────────────────────────────────────────────────────────────
_webapp_js() {
    cat << 'ENDJS'
<script>
(function() {
  const D = DATA;

  // ── Navigation ──
  document.querySelectorAll('.nav-item').forEach(el => {
    el.addEventListener('click', () => {
      document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
      document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
      el.classList.add('active');
      const vw = document.getElementById('v-' + el.dataset.view);
      if (vw) vw.classList.add('active');
    });
  });

  // ── Helpers ──
  function esc(s) {
    if (!s) return '';
    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }
  function sevColor(s) {
    const m = {CRITICAL:'red',HIGH:'orange',MEDIUM:'yellow',LOW:'green',INFO:'blue'};
    return m[(s||'').toUpperCase()] || 'blue';
  }
  function sevOrder(s) {
    const m = {CRITICAL:0,HIGH:1,MEDIUM:2,LOW:3,INFO:4};
    return m[(s||'').toUpperCase()] ?? 5;
  }

  // ── Dashboard ──
  const m = D.metrics || {};
  document.getElementById('dash-subtitle').textContent =
    `${D.device.id} · ${D.device.firmware} · Generated ${D.generated}`;

  // Health score gauge
  const hs = D.healthScore || {};
  if (hs.score !== undefined) {
    const hsColor = hs.score >= 75 ? 'var(--green)' : hs.score >= 55 ? 'var(--yellow)' : hs.score >= 35 ? 'var(--orange)' : 'var(--red)';
    const cats = hs.categories || {};
    const catHtml = ['connectivity','hardware','services','configuration'].map(c => {
      const cat = cats[c] || {score:0, weight:0};
      const cc = cat.score >= 75 ? 'var(--green)' : cat.score >= 55 ? 'var(--yellow)' : cat.score >= 35 ? 'var(--orange)' : 'var(--red)';
      return `<div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;">
        <span style="min-width:110px;font-size:12px;color:var(--fg2);text-transform:capitalize;">${c}</span>
        <div style="flex:1;height:6px;background:var(--bg);border-radius:3px;overflow:hidden;max-width:140px;">
          <div style="width:${cat.score}%;height:100%;background:${cc};border-radius:3px;"></div>
        </div>
        <span style="font-family:var(--mono);font-size:12px;color:${cc};min-width:32px;font-weight:600;">${cat.score}</span>
        <span style="font-size:10px;color:var(--fg3);">(${cat.weight}%)</span>
      </div>`;
    }).join('');
    const predHtml = (hs.predictions || []).map(p => {
      const pc = p.level === 'CRIT' ? 'var(--red)' : 'var(--orange)';
      return `<div style="font-size:12px;color:${pc};margin-top:6px;padding-left:10px;border-left:2px solid ${pc};">${esc(p.message)}</div>`;
    }).join('');
    document.getElementById('dash-stats').insertAdjacentHTML('beforebegin',
      `<div class="card" style="margin-bottom:20px;">
        <div class="card-header">🏥 Health Score</div>
        <div style="display:flex;gap:24px;padding:20px;align-items:center;flex-wrap:wrap;">
          <div style="text-align:center;min-width:120px;">
            <div style="font-size:52px;font-weight:800;font-family:var(--mono);color:${hsColor};line-height:1;">${hs.score}</div>
            <div style="font-size:12px;color:var(--fg3);margin-top:4px;">Grade <strong style="color:${hsColor};">${hs.grade}</strong></div>
            <div style="margin-top:10px;height:8px;width:120px;background:var(--bg);border-radius:4px;overflow:hidden;">
              <div style="width:${hs.score}%;height:100%;background:${hsColor};border-radius:4px;"></div>
            </div>
          </div>
          <div style="flex:1;min-width:250px;">${catHtml}</div>
        </div>
        ${predHtml ? '<div style="padding:0 20px 16px;border-top:1px solid var(--border);padding-top:12px;"><div style="font-size:11px;font-weight:600;color:var(--orange);text-transform:uppercase;letter-spacing:0.5px;margin-bottom:6px;">⚠ Predictive Alerts</div>' + predHtml + '</div>' : ''}
      </div>`);
  }

  // Connector breakdown (dual-connector chargers)
  const conn = D.healthScore && D.healthScore.connectors;
  if (conn && conn.detected) {
    const mkBar = (errs, warns, maxVal) => {
      const eW = maxVal > 0 ? Math.round(errs/maxVal*100) : 0;
      const wW = maxVal > 0 ? Math.round(warns/maxVal*100) : 0;
      return `<div style="display:flex;height:8px;border-radius:4px;overflow:hidden;background:var(--bg);flex:1;max-width:160px;">
        <div style="width:${eW}%;background:var(--red);"></div>
        <div style="width:${wW}%;background:var(--yellow);"></div>
      </div>`;
    };
    const maxEv = Math.max(conn.c1.errors+conn.c1.warnings, conn.c2.errors+conn.c2.warnings, 1);
    document.getElementById('dash-stats').insertAdjacentHTML('beforebegin',
      `<div class="card" style="margin-bottom:20px;">
        <div class="card-header">🔌 Connector Health</div>
        <div style="padding:16px 20px;">
          <div style="display:flex;align-items:center;gap:10px;margin-bottom:10px;">
            <span style="min-width:90px;font-size:13px;font-weight:600;">Connector 1</span>
            ${mkBar(conn.c1.errors, conn.c1.warnings, maxEv)}
            <span style="font-family:var(--mono);font-size:12px;"><span style="color:var(--red);">${conn.c1.errors}E</span> <span style="color:var(--yellow);">${conn.c1.warnings}W</span></span>
            <span style="font-size:11px;color:var(--fg3);">${conn.c1.sessions} sessions</span>
          </div>
          <div style="display:flex;align-items:center;gap:10px;">
            <span style="min-width:90px;font-size:13px;font-weight:600;">Connector 2</span>
            ${mkBar(conn.c2.errors, conn.c2.warnings, maxEv)}
            <span style="font-family:var(--mono);font-size:12px;"><span style="color:var(--red);">${conn.c2.errors}E</span> <span style="color:var(--yellow);">${conn.c2.warnings}W</span></span>
            <span style="font-size:11px;color:var(--fg3);">${conn.c2.sessions} sessions</span>
          </div>
        </div>
      </div>`);
  }

  const stats = [
    {v: m.issues_total||0, l: 'Issues', c: (m.issues_total||0) > 0 ? 'red':'green'},
    {v: m.issues_critical||0, l: 'Critical', c: (m.issues_critical||0) > 0 ? 'red':'green'},
    {v: m.issues_high||0, l: 'High', c: (m.issues_high||0) > 0 ? 'orange':'green'},
    {v: m.issues_medium||0, l: 'Medium', c: (m.issues_medium||0) > 0 ? 'yellow':'green'},
    {v: m.issues_low||0, l: 'Low', c: 'green'},
    {v: m.timeline_events||0, l: 'Timeline Events', c: 'blue'},
  ];
  document.getElementById('dash-stats').innerHTML = stats.map(s =>
    `<div class="stat-card ${s.c}"><div class="stat-val">${s.v}</div><div class="stat-label">${s.l}</div></div>`
  ).join('');

  // Status pills
  const statusMap = D.status || {};
  document.getElementById('dash-status').innerHTML = Object.entries(statusMap).map(([name, state]) => {
    const s = state.toLowerCase();
    const icon = s === 'up' ? '✓' : s === 'down' ? '✗' : s === 'degraded' ? '△' : '?';
    return `<div class="status-pill ${s}"><span class="dot"></span><span class="name">${esc(name)}</span><span class="label">${esc(state)}</span></div>`;
  }).join('');

  // Key metrics
  const metricDefs = [
    {k:'i2p2_mqtt_fail_count', l:'MQTT Failures', c:'bad'},
    {k:'i2p2_mqtt_ok_count', l:'MQTT Successes', c:'ok'},
    {k:'eth_flap_cycles', l:'Eth Flaps', c:'bad'},
    {k:'ocpp_ws_connected', l:'OCPP Connected', c:'ok'},
    {k:'ocpp_boot_notif', l:'Boot Notifications', c:'info'},
    {k:'cpstate_fault_count', l:'CPState Faults', c:'bad'},
    {k:'evcc_watchdog_count', l:'EVCC Watchdog', c:'bad'},
    {k:'cert_load_failures', l:'Cert Failures', c:'bad'},
    {k:'em_pmq_sub_fail', l:'PMQ Sub Failures', c:'bad'},
    {k:'i2p2_shadow_updates', l:'Shadow Updates', c:'info'},
    {k:'i2p2_backoff_count', l:'Backoff Count', c:'bad'},
    {k:'hm_reboots', l:'Reboots', c:'bad'},
  ];
  document.getElementById('dash-metrics').innerHTML = metricDefs
    .filter(d => m[d.k] !== undefined && m[d.k] !== 0)
    .map(d => `<div class="metric-box ${d.c}"><span class="val">${m[d.k]}</span><span class="lbl">${d.l}</span></div>`)
    .join('');

  // ── Issues ──
  const issues = D.issues || [];
  document.getElementById('issues-subtitle').textContent =
    `${issues.length} issue${issues.length !== 1 ? 's' : ''} detected`;

  // Severity filter chips
  const sevCounts = {};
  issues.forEach(i => { sevCounts[i.severity] = (sevCounts[i.severity]||0) + 1; });
  const activeSevs = new Set(['CRITICAL','HIGH','MEDIUM','LOW','INFO']);

  function renderIssueFilters() {
    document.getElementById('issues-filters').innerHTML =
      ['CRITICAL','HIGH','MEDIUM','LOW'].filter(s => sevCounts[s])
        .map(s => `<span class="chip ${activeSevs.has(s)?'active':''} ${sevColor(s)}" data-sev="${s}">${s} (${sevCounts[s]})</span>`)
        .join('');
    document.querySelectorAll('#issues-filters .chip').forEach(el => {
      el.addEventListener('click', () => {
        const s = el.dataset.sev;
        if (activeSevs.has(s)) activeSevs.delete(s); else activeSevs.add(s);
        renderIssueFilters();
        renderIssues();
      });
    });
  }

  function colorEvidence(line) {
    const e = esc(line);
    if (/^\d+:.*\[E\]|^\d+:.*\[C\]|^\d+:.*ERROR/.test(line))
      return `<span class="ev-error">${e}</span>`;
    if (/^\d+:.*\[W\]|^\d+:.*WARN/.test(line))
      return `<span class="ev-warn">${e}</span>`;
    if (/^--$/.test(line))
      return `<span class="ev-sep">──</span>`;
    if (/^\d+[:-]/.test(line))
      return `<span class="ev-ctx">${e}</span>`;
    return e;
  }

  function renderIssues() {
    const filtered = issues.filter(i => activeSevs.has(i.severity));
    if (filtered.length === 0) {
      document.getElementById('issues-list').innerHTML =
        '<div class="empty-state"><span class="icon">✅</span>No issues match the current filter</div>';
      return;
    }
    document.getElementById('issues-list').innerHTML = filtered.map((issue, idx) => {
      const sev = issue.severity.toLowerCase();
      const evHtml = (issue.evidence && issue.evidence.length > 0)
        ? `<div class="ev-label">Evidence (${issue.evidence.length} lines)</div>
           <div class="evidence-block">${issue.evidence.map(colorEvidence).join('\n')}</div>`
        : '';
      const descParts = (function(d) {
        const tsIdx = d.indexOf('Troubleshooting:');
        const onsiteIdx = d.indexOf('[On-site service');
        let main = tsIdx > -1 ? d.substring(0, tsIdx).trim() : d;
        let ts = tsIdx > -1 ? d.substring(tsIdx, onsiteIdx > -1 ? onsiteIdx : undefined).trim() : '';
        let onsite = onsiteIdx > -1;
        return {main, ts, onsite};
      })(issue.description || '');
      return `<div class="issue-card ${sev}" onclick="this.classList.toggle('open')">
        <div class="issue-head">
          <span class="num">#${idx+1}</span>
          <span class="sev-badge ${sev}">${esc(issue.severity)}</span>
          <span class="title">${esc(issue.title)}</span>
          <span class="comp">${esc(issue.component)}</span>
          ${descParts.onsite ? '<span class="onsite-badge">🚨 On-site</span>' : ''}
          <span class="chevron">▶</span>
        </div>
        <div class="issue-body">
          <div class="issue-desc">${esc(descParts.main)}</div>
          ${descParts.ts ? '<div class="issue-ts">' + esc(descParts.ts) + '</div>' : ''}
          ${descParts.onsite ? '<div class="issue-onsite">🚨 On-site service required</div>' : ''}
          ${evHtml}
        </div>
      </div>`;
    }).join('');
  }
  renderIssueFilters();
  renderIssues();

  // ── Timeline ──
  const timeline = D.timeline || [];
  document.getElementById('tl-subtitle').textContent = `${timeline.length} events`;

  // Populate component filter
  const tlComps = [...new Set(timeline.map(e => e[2]))].sort();
  document.getElementById('tl-comp-filter').innerHTML =
    '<option value="">All components</option>' +
    tlComps.map(c => `<option value="${esc(c)}">${esc(c)}</option>`).join('');

  function renderTimeline() {
    const q = (document.getElementById('tl-search').value || '').toLowerCase();
    const sevF = document.getElementById('tl-sev-filter').value;
    const compF = document.getElementById('tl-comp-filter').value;

    const filtered = timeline.filter(e => {
      if (sevF && e[1] !== sevF) return false;
      if (compF && e[2] !== compF) return false;
      if (q && !e.join(' ').toLowerCase().includes(q)) return false;
      return true;
    });

    if (filtered.length === 0) {
      document.getElementById('tl-list').innerHTML =
        '<div class="empty-state"><span class="icon">📭</span>No events match the current filter</div>';
      return;
    }

    // Render visible chunk (virtual scroll lite — render first 500)
    const visible = filtered.slice(0, 500);
    document.getElementById('tl-list').innerHTML = visible.map(e => {
      const sev = (e[1]||'').toLowerCase();
      return `<div class="tl-row ${sev}">
        <span class="tl-ts">${esc(e[0])}</span>
        <span class="tl-sev ${sev}">${esc(e[1])}</span>
        <span class="tl-comp">${esc(e[2])}</span>
        <span class="tl-msg" title="${esc(e[3])}">${esc(e[3])}</span>
      </div>`;
    }).join('') + (filtered.length > 500
      ? `<div style="text-align:center;padding:12px;color:var(--fg3);font-size:12px;">Showing 500 of ${filtered.length} events. Use filters to narrow.</div>` : '');
  }

  document.getElementById('tl-search').addEventListener('input', renderTimeline);
  document.getElementById('tl-sev-filter').addEventListener('change', renderTimeline);
  document.getElementById('tl-comp-filter').addEventListener('change', renderTimeline);
  renderTimeline();

  // ── Error Summary ──
  const errors = (D.errors || []).sort((a,b) =>
    (b.errors + b.warnings + b.critical) - (a.errors + a.warnings + a.critical));
  document.getElementById('err-body').innerHTML = errors.map(e => {
    const total = e.errors + e.warnings + e.critical;
    return `<tr>
      <td><code>${esc(e.component)}</code></td>
      <td class="${e.errors>0?'warn':''}">${e.errors}</td>
      <td class="${e.warnings>50?'warn':''}">${e.warnings}</td>
      <td class="${e.critical>0?'warn':''}">${e.critical}</td>
      <td><strong>${total}</strong></td>
    </tr>`;
  }).join('');

  // ── Search ──
  function doSearch() {
    const q = (document.getElementById('search-input').value || '').trim().toLowerCase();
    if (!q || q.length < 2) {
      document.getElementById('search-results').innerHTML =
        '<div class="empty-state"><span class="icon">🔎</span>Enter at least 2 characters to search</div>';
      document.getElementById('search-info').textContent = '';
      return;
    }

    const results = [];
    // Search issues
    issues.forEach((issue, i) => {
      const hay = [issue.title, issue.description, issue.component, issue.severity,
        ...(issue.evidence||[])].join('\n').toLowerCase();
      if (hay.includes(q)) {
        results.push({
          source: `Issue #${i+1} — ${issue.severity}`,
          text: issue.title + '\n' + issue.description,
          type: 'issue'
        });
        // Evidence matches
        (issue.evidence||[]).forEach(line => {
          if (line.toLowerCase().includes(q)) {
            results.push({ source: `Evidence — Issue #${i+1}`, text: line, type: 'evidence' });
          }
        });
      }
    });
    // Search timeline
    timeline.forEach(e => {
      if (e.join(' ').toLowerCase().includes(q)) {
        results.push({ source: `Timeline — ${e[2]}`, text: `[${e[0]}] ${e[1]} ${e[3]}`, type: 'timeline' });
      }
    });

    const maxShow = 100;
    document.getElementById('search-info').textContent =
      `${results.length} result${results.length!==1?'s':''} found` +
      (results.length > maxShow ? ` (showing first ${maxShow})` : '');

    document.getElementById('search-results').innerHTML = results.slice(0, maxShow).map(r => {
      // Highlight matches
      const re = new RegExp(`(${q.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')})`, 'gi');
      const highlighted = esc(r.text).replace(re, '<mark>$1</mark>');
      return `<div class="search-hit">
        <div class="hit-source">${esc(r.source)}</div>
        <div class="hit-text">${highlighted}</div>
      </div>`;
    }).join('') || '<div class="empty-state"><span class="icon">📭</span>No results found</div>';
  }

  document.getElementById('search-btn').addEventListener('click', doSearch);
  document.getElementById('search-input').addEventListener('keydown', e => {
    if (e.key === 'Enter') doSearch();
  });

  // ── System Info ──
  const dev = D.device || {};
  const infoRows = [
    ['Device ID', dev.id], ['Firmware', dev.firmware], ['Release', dev.release],
    ['Build Scope', dev.scope], ['Artifact', dev.artifact],
    ['Build Info', dev.build], ['Boot Slot', dev.bootSlot],
    ['Memory Total', dev.memTotal ? dev.memTotal + ' KB' : ''],
    ['Memory Free', dev.memFree ? dev.memFree + ' KB' : ''],
    ['Memory Available', dev.memAvail ? dev.memAvail + ' KB' : ''],
  ].filter(r => r[1] && r[1] !== 'unknown');

  document.getElementById('sys-device').innerHTML = infoRows.map(r =>
    `<div class="info-row"><span class="key">${esc(r[0])}</span><span class="val">${esc(r[1])}</span></div>`
  ).join('');

  // ── Deep Analysis ──
  const deep = D.deepAnalysis;
  if (deep) {
    document.getElementById('nav-deep').style.display = '';

    // Boot waterfall
    if (deep.bootTiming && deep.bootTiming.length > 0) {
      document.getElementById('deep-boot').innerHTML = `<div class="card"><div class="card-header">🚀 Boot Sequence Waterfall</div>
        <table class="dtable"><thead><tr><th>Timestamp</th><th>Component</th><th>Phase</th><th>Delta</th></tr></thead><tbody>
        ${deep.bootTiming.map(e => {
          const dc = parseFloat(e.delta) > 30 ? 'var(--red)' : parseFloat(e.delta) > 5 ? 'var(--yellow)' : 'var(--green)';
          return `<tr><td><code>${esc(e.ts)}</code></td><td>${esc(e.component)}</td><td>${esc(e.phase)}</td><td style="color:${dc};font-weight:600;">+${e.delta}s</td></tr>`;
        }).join('')}
        </tbody></table></div>`;
    }

    // Causal chains
    if (deep.causalChains && deep.causalChains.length > 0) {
      document.getElementById('deep-chains').innerHTML = `<div class="card"><div class="card-header">⛓ Causal Chains (${deep.causalChains.length})</div>
        <div style="padding:16px;">
        ${deep.causalChains.map((chain, i) => {
          const sevColor = {CRITICAL:'var(--red)',HIGH:'var(--orange)',MEDIUM:'var(--yellow)'}[chain.severity] || 'var(--blue)';
          return `<div style="margin-bottom:14px;padding:12px;background:var(--bg);border-radius:6px;border-left:3px solid ${sevColor};">
            <div style="font-weight:700;margin-bottom:6px;">⛓ #${i+1}: ${esc(chain.name)} <span style="font-size:10px;padding:2px 6px;border-radius:3px;background:${sevColor};color:#000;margin-left:6px;">${chain.severity}</span></div>
            ${(chain.steps||[]).map(s => {
              const sc = s.type==='CAUSE'?'var(--red)':s.type==='ROOT'?'var(--green)':'var(--yellow)';
              const si = s.type==='CAUSE'?'❌':s.type==='ROOT'?'💡':'→';
              return `<div style="color:${sc};font-size:12px;margin:3px 0 0 10px;">${si} ${esc(s.text)}</div>`;
            }).join('')}
          </div>`;
        }).join('')}
        </div></div>`;
    }

    // Error histogram
    if (deep.errorHistogram && deep.errorHistogram.length > 0) {
      const maxH = Math.max(...deep.errorHistogram.map(h => h.total));
      document.getElementById('deep-histogram').innerHTML = `<div class="card"><div class="card-header">📊 Error Rate by Hour</div>
        <div style="padding:16px;">
        ${deep.errorHistogram.map(h => {
          const pct = Math.max(2, h.total * 100 / maxH);
          return `<div style="display:flex;align-items:center;gap:8px;margin-bottom:2px;">
            <code style="font-size:10px;min-width:110px;color:var(--fg3);">${esc(h.hour)}</code>
            <div style="flex:1;height:12px;background:var(--bg);border-radius:3px;overflow:hidden;max-width:400px;">
              <div style="width:${pct}%;height:100%;background:linear-gradient(90deg,var(--red),var(--orange),var(--blue));border-radius:3px;"></div>
            </div>
            <span style="font-family:var(--mono);font-size:10px;color:var(--fg3);min-width:28px;">${h.total}</span>
          </div>`;
        }).join('')}
        </div></div>`;
    }

    // Gaps
    if (deep.gaps && deep.gaps.length > 0) {
      document.getElementById('deep-gaps').innerHTML = `<div class="card"><div class="card-header">⏸ Log Gaps (&gt;5 min): ${deep.gaps.length} detected</div>
        <table class="dtable"><thead><tr><th>From</th><th>To</th><th>Duration</th></tr></thead><tbody>
        ${deep.gaps.slice(0,15).map(g => `<tr><td><code>${esc(g.from)}</code></td><td><code>${esc(g.to)}</code></td><td style="color:var(--red);font-weight:600;">${g.minutes}m</td></tr>`).join('')}
        </tbody></table></div>`;
    }

    // Config checks
    if (deep.configChecks && deep.configChecks.length > 0) {
      document.getElementById('deep-config').innerHTML = `<div class="card"><div class="card-header">⚙️ Configuration Validation</div>
        <table class="dtable"><thead><tr><th>Status</th><th>Component</th><th>Setting</th><th>Details</th></tr></thead><tbody>
        ${deep.configChecks.map(c => {
          const icon = c.status==='WARN'?'⚠️':c.status==='FAIL'?'❌':c.status==='INFO'?'ℹ️':'✅';
          return `<tr><td>${icon}</td><td><code>${esc(c.component)}</code></td><td>${esc(c.key)}</td><td style="font-size:12px;">${esc(c.note)}</td></tr>`;
        }).join('')}
        </tbody></table></div>`;
    }

    // Charging Sessions
    if (deep.chargingSessions && deep.chargingSessions.length > 0) {
      document.getElementById('deep-sessions').innerHTML = `<div class="card"><div class="card-header">🔌 Charging Sessions (${deep.chargingSessions.length})</div>
        <table class="dtable"><thead><tr><th>Start</th><th>End</th><th>Connector</th><th>State</th><th>Stop Reason</th></tr></thead><tbody>
        ${deep.chargingSessions.map(s => {
          const cls = s.stopReason==='Faulted'||s.stopReason==='Unavailable'?'color:#e74c3c':s.state==='charging'?'color:#27ae60':'';
          return `<tr><td><code>${esc(s.start)}</code></td><td><code>${esc(s.end)}</code></td><td>${s.connector}</td><td style="${cls}">${esc(s.state)}</td><td>${esc(s.stopReason)}</td></tr>`;
        }).join('')}
        </tbody></table></div>`;
    }

    // Reboot Timeline
    if (deep.rebootTimeline && deep.rebootTimeline.length > 0) {
      document.getElementById('deep-reboots').innerHTML = `<div class="card"><div class="card-header">🔄 Reboot / Crash Timeline (${deep.rebootTimeline.length} events)</div>
        <table class="dtable"><thead><tr><th>Time</th><th>Type</th><th>Description</th></tr></thead><tbody>
        ${deep.rebootTimeline.map(r => {
          const cls = r.type==='kernel_panic'||r.type==='oom_kill'||r.type==='watchdog_app'?'color:#e74c3c':r.type==='kernel_boot'?'color:#3498db':r.type.startsWith('monit')?'color:#f39c12':'';
          return `<tr><td><code>${esc(r.ts)}</code></td><td style="${cls};font-weight:bold">${esc(r.type)}</td><td>${esc(r.desc)}</td></tr>`;
        }).join('')}
        </tbody></table></div>`;
    }

    // Connectivity
    if (deep.connectivity && deep.connectivity.events && deep.connectivity.events.length > 0) {
      const c = deep.connectivity;
      document.getElementById('deep-conn').innerHTML = `<div class="card"><div class="card-header">🌐 Network Connectivity (${c.events.length} events)</div>
        <div style="display:flex;gap:20px;margin:10px 0;flex-wrap:wrap;">
          <div class="metric-card"><div class="metric-val">${c.connected}</div><div class="metric-lbl">Connecting</div></div>
          <div class="metric-card"><div class="metric-val" style="color:#e74c3c">${c.disconnected}</div><div class="metric-lbl">Disconnected</div></div>
          <div class="metric-card"><div class="metric-val" style="color:#e74c3c">${c.failed}</div><div class="metric-lbl">Failed</div></div>
          <div class="metric-card"><div class="metric-val" style="color:#e67e22">${c.dnsErrors}</div><div class="metric-lbl">DNS Errors</div></div>
          <div class="metric-card"><div class="metric-val" style="color:#e67e22">${c.tlsErrors}</div><div class="metric-lbl">TLS Errors</div></div>
        </div>
        <table class="dtable"><thead><tr><th>Time</th><th>Service</th><th>Event</th></tr></thead><tbody>
        ${c.events.map(e => {
          const cls = e.event==='disconnected'||e.event==='failed'||e.event.startsWith('failed')?'color:#e74c3c':e.event==='connecting'?'color:#3498db':e.event==='accepted'?'color:#27ae60':e.service==='dns'||e.service==='tls'?'color:#e67e22':'';
          return `<tr><td><code>${esc(e.ts)}</code></td><td>${esc(e.service)}</td><td style="${cls}">${esc(e.event)}</td></tr>`;
        }).join('')}
        </tbody></table></div>`;
    }

    // State Machine
    if (deep.stateMachine && deep.stateMachine.events && deep.stateMachine.events.length > 0) {
      const sm = deep.stateMachine;
      document.getElementById('deep-sm').innerHTML = `<div class="card"><div class="card-header">⚡ State Machine (${sm.transitions} transitions)</div>
        <div style="display:flex;gap:20px;margin:10px 0;flex-wrap:wrap;">
          <div class="metric-card"><div class="metric-val">${sm.transitions}</div><div class="metric-lbl">Transitions</div></div>
          <div class="metric-card"><div class="metric-val" style="color:#e67e22">${sm.watchdogWarns}</div><div class="metric-lbl">WD Warns</div></div>
          <div class="metric-card"><div class="metric-val" style="color:#e74c3c">${sm.watchdogCrits}</div><div class="metric-lbl">WD Critical</div></div>
        </div>
        <table class="dtable"><thead><tr><th>Time</th><th>Conn</th><th>Machine</th><th>Type</th><th>Detail</th></tr></thead><tbody>
        ${sm.events.map(e => {
          const cls = e.detail&&(e.detail.includes('Fault')||e.detail.includes('NotAvailable'))?'color:#e74c3c':e.detail&&e.detail.includes('Available')?'color:#27ae60':'';
          return `<tr><td><code>${esc(e.ts)}</code></td><td>${e.connector}</td><td><code>${esc(e.machine)}</code></td><td>${esc(e.type)}</td><td style="${cls}">${esc(e.detail)}</td></tr>`;
        }).join('')}
        </tbody></table></div>`;
    }
  }

  // ── Keyboard shortcuts ──
  document.addEventListener('keydown', e => {
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') return;
    const map = {'1':'dashboard','2':'issues','3':'timeline','4':'errors','5':'search','6':'system','7':'deep'};
    if (map[e.key]) {
      document.querySelector(`.nav-item[data-view="${map[e.key]}"]`)?.click();
    }
  });
})();
</script>
ENDJS
}
