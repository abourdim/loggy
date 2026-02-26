#!/bin/bash
# comparator.sh — Regression Detection & Comparison
# Loggy v6.0 — Phase 7
#
# Loads baseline + target, runs standard analysis on both,
# compares metrics/issues/status/config, generates diff reports.

# ─── Run Comparison ──────────────────────────────────────────────────────────
run_comparison() {
    local baseline_input="$1"
    local target_input="$2"

    if [ -z "$baseline_input" ] || [ -z "$target_input" ]; then
        log_error "Comparison requires two inputs: baseline and target"
        log_info  "Usage: --compare <baseline.zip> <target.zip>"
        return 1
    fi

    if [ ! -e "$baseline_input" ]; then
        log_error "Baseline not found: $baseline_input"
        return 1
    fi
    if [ ! -e "$target_input" ]; then
        log_error "Target not found: $target_input"
        return 1
    fi

    # ─── Save original state ────────────────────────────────────────────
    local orig_work="$WORK_DIR"
    local orig_issues="$ISSUES_FILE"
    local orig_timeline="$TIMELINE_FILE"
    local orig_sysinfo="$SYSINFO_FILE"
    local orig_metrics="$METRICS_FILE"

    local comp_dir
    comp_dir=$(make_temp_dir "iotcmp")
    cleanup_register_dir "$comp_dir"

    local base_dir="$comp_dir/baseline"
    local tgt_dir="$comp_dir/target"
    mkdir -p "$base_dir" "$tgt_dir"

    # ─── Analyze baseline ───────────────────────────────────────────────
    log_info "Comparing: baseline vs target"
    log_debug "Baseline: $baseline_input"
    log_debug "Target: $target_input"
    printf "\n"
    printf "  %s▸ Analyzing baseline...%s\n" "${BLD}${CYN}" "${RST}"
    spinner_start "Analyzing baseline..."

    _compare_analyze "$baseline_input" "$base_dir"
    local base_rc=$?
    spinner_stop
    log_debug "Baseline analysis rc=$base_rc dir=$base_dir"

    # ─── Analyze target ─────────────────────────────────────────────────
    printf "  %s▸ Analyzing target...%s\n" "${BLD}${CYN}" "${RST}"
    spinner_start "Analyzing target..."

    _compare_analyze "$target_input" "$tgt_dir"
    local tgt_rc=$?
    spinner_stop
    log_debug "Target analysis rc=$tgt_rc dir=$tgt_dir"

    # ─── Restore original state ─────────────────────────────────────────
    WORK_DIR="$orig_work"
    ISSUES_FILE="$orig_issues"
    TIMELINE_FILE="$orig_timeline"
    SYSINFO_FILE="$orig_sysinfo"
    METRICS_FILE="$orig_metrics"

    if [ "$base_rc" -ne 0 ]; then
        log_error "Baseline analysis failed"
        return 1
    fi
    if [ "$tgt_rc" -ne 0 ]; then
        log_error "Target analysis failed"
        return 1
    fi

    # ─── Build comparison data ──────────────────────────────────────────
    printf "  %s▸ Comparing results...%s\n" "${BLD}${CYN}" "${RST}"
    spinner_start "Comparing results..."

    _compare_metrics "$base_dir" "$tgt_dir" "$comp_dir"
    _compare_issues  "$base_dir" "$tgt_dir" "$comp_dir"
    _compare_status  "$base_dir" "$tgt_dir" "$comp_dir"
    _compare_config  "$base_dir" "$tgt_dir" "$comp_dir"
    spinner_stop

    # ─── Display results ────────────────────────────────────────────────
    _compare_display "$base_dir" "$tgt_dir" "$comp_dir"

    # ─── Generate reports ───────────────────────────────────────────────
    local datestamp
    datestamp=$(date +%Y%m%d_%H%M)
    mkdir -p "$OUTPUT_DIR"

    local base_name="${OUTPUT_DIR}/comparison_${datestamp}"
    spinner_start "Generating comparison reports..."
    _compare_gen_markdown "$base_dir" "$tgt_dir" "$comp_dir" "${base_name}.md"
    _compare_gen_html     "$base_dir" "$tgt_dir" "$comp_dir" "${base_name}.html"
    spinner_stop

    log_ok "Comparison complete"
    log_info "Reports: ${base_name}.md, ${base_name}.html"
}

# ─── Analyze a single input into a work directory ────────────────────────────
_compare_analyze() {
    local input="$1"
    local work="$2"

    # Redirect globals to this work dir
    WORK_DIR="$work"
    ISSUES_FILE="$work/issues.dat"
    TIMELINE_FILE="$work/timeline.dat"
    SYSINFO_FILE="$work/sysinfo.dat"
    METRICS_FILE="$work/metrics.dat"
    touch "$ISSUES_FILE" "$TIMELINE_FILE" "$SYSINFO_FILE" "$METRICS_FILE"
    touch "$work/log_files.idx"

    if ! load_input "$input"; then
        log_error "Failed to load: $input"
        return 1
    fi

    parse_all_logs
    run_standard_analysis
    return 0
}

# ─── Metric Comparison ───────────────────────────────────────────────────────
_compare_metrics() {
    local base_dir="$1" tgt_dir="$2" comp_dir="$3"
    local outfile="$comp_dir/metrics_diff.dat"
    : > "$outfile"

    # Collect all metric keys
    local keys
    keys=$(cat "$base_dir/metrics.dat" "$tgt_dir/metrics.dat" 2>/dev/null \
        | grep -v '^$' | cut -d= -f1 | sort -u)

    while IFS= read -r key; do
        [ -z "$key" ] && continue
        local bval tval
        bval=$(grep "^${key}=" "$base_dir/metrics.dat" 2>/dev/null | head -1 | cut -d= -f2-)
        tval=$(grep "^${key}=" "$tgt_dir/metrics.dat" 2>/dev/null | head -1 | cut -d= -f2-)
        bval="${bval:-0}"
        tval="${tval:-0}"

        # Calculate delta for numeric values
        local delta="" pct=""
        if echo "$bval" | grep -qE '^[0-9]+$' && echo "$tval" | grep -qE '^[0-9]+$'; then
            delta=$((tval - bval))
            if [ "$bval" -gt 0 ]; then
                # Integer percentage
                if [ "$delta" -ge 0 ]; then
                    pct=$((delta * 100 / bval))
                else
                    pct=$(( (0 - delta) * 100 / bval))
                    pct="-$pct"
                fi
            fi
        fi

        # TSV: key, baseline, target, delta, pct
        printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$bval" "$tval" "$delta" "$pct" >> "$outfile"
    done <<< "$keys"
}

# ─── Issue Diff ──────────────────────────────────────────────────────────────
_compare_issues() {
    local base_dir="$1" tgt_dir="$2" comp_dir="$3"

    # Extract issue titles (field 3) for comparison
    local base_titles="$comp_dir/base_titles.tmp"
    local tgt_titles="$comp_dir/tgt_titles.tmp"

    cut -f3 "$base_dir/issues.dat" 2>/dev/null | sort > "$base_titles"
    cut -f3 "$tgt_dir/issues.dat"  2>/dev/null | sort > "$tgt_titles"

    # New issues (in target but not baseline)
    comm -13 "$base_titles" "$tgt_titles" > "$comp_dir/issues_new.dat" 2>/dev/null
    # Resolved issues (in baseline but not target)
    comm -23 "$base_titles" "$tgt_titles" > "$comp_dir/issues_resolved.dat" 2>/dev/null
    # Persistent issues (in both)
    comm -12 "$base_titles" "$tgt_titles" > "$comp_dir/issues_persistent.dat" 2>/dev/null

    rm -f "$base_titles" "$tgt_titles"
}

# ─── Status Comparison ───────────────────────────────────────────────────────
_compare_status() {
    local base_dir="$1" tgt_dir="$2" comp_dir="$3"
    local outfile="$comp_dir/status_diff.dat"
    : > "$outfile"

    # Collect all subsystem names
    local names
    names=$(cat "$base_dir/status.dat" "$tgt_dir/status.dat" 2>/dev/null \
        | cut -f1 | sort -u)

    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local bstate tstate
        bstate=$(grep "^${name}"$'\t' "$base_dir/status.dat" 2>/dev/null | head -1 | cut -f2)
        tstate=$(grep "^${name}"$'\t' "$tgt_dir/status.dat" 2>/dev/null | head -1 | cut -f2)
        bstate="${bstate:-n/a}"
        tstate="${tstate:-n/a}"

        local change=""
        if [ "$bstate" != "$tstate" ]; then
            change="CHANGED"
        fi

        printf '%s\t%s\t%s\t%s\n' "$name" "$bstate" "$tstate" "$change" >> "$outfile"
    done <<< "$names"
}

# ─── Config Comparison ───────────────────────────────────────────────────────
_compare_config() {
    local base_dir="$1" tgt_dir="$2" comp_dir="$3"
    local outfile="$comp_dir/config_diff.dat"
    : > "$outfile"

    local base_props="$base_dir/properties"
    local tgt_props="$tgt_dir/properties"

    # Compare each properties file that exists in either
    local all_props=""
    [ -d "$base_props" ] && all_props=$(ls "$base_props"/*.props 2>/dev/null | xargs -I{} basename {} .props)
    [ -d "$tgt_props" ] && all_props="$all_props
$(ls "$tgt_props"/*.props 2>/dev/null | xargs -I{} basename {} .props)"
    all_props=$(echo "$all_props" | sort -u | grep -v '^$')

    while IFS= read -r config_name; do
        [ -z "$config_name" ] && continue
        local bf="$base_props/${config_name}.props"
        local tf="$tgt_props/${config_name}.props"

        if [ ! -f "$bf" ] && [ -f "$tf" ]; then
            printf '%s\t(new config)\t\t\tADDED\n' "$config_name" >> "$outfile"
            continue
        fi
        if [ -f "$bf" ] && [ ! -f "$tf" ]; then
            printf '%s\t(removed config)\t\t\tREMOVED\n' "$config_name" >> "$outfile"
            continue
        fi

        # Both exist — diff key=value pairs
        # Use awk to handle = in values properly
        awk -F= -v tf="$tf" -v cn="$config_name" -v OFS='\t' '
        NR==FNR && /^[^#]/ && /=/ {
            key = $1; val = substr($0, length($1)+2)
            tgt[key] = val; next
        }
        /^[^#]/ && /=/ {
            key = $1; val = substr($0, length($1)+2)
            if (key in tgt) {
                if (val != tgt[key]) print cn "/" key, val, tgt[key], "", "CHANGED"
                delete tgt[key]
            } else {
                print cn "/" key, val, "<removed>", "", "REMOVED"
            }
        }
        END {
            for (key in tgt) print cn "/" key, "<added>", tgt[key], "", "ADDED"
        }' "$tf" "$bf" >> "$outfile"
    done <<< "$all_props"

    # Compare firmware/sysinfo
    local sysfile="$comp_dir/sysinfo_diff.dat"
    : > "$sysfile"

    for key in device_id fw_version release_version scope artifact_version build_info boot_slot; do
        local bv tv
        bv=$(grep "^${key}=" "$base_dir/sysinfo.dat" 2>/dev/null | head -1 | cut -d= -f2-)
        tv=$(grep "^${key}=" "$tgt_dir/sysinfo.dat" 2>/dev/null | head -1 | cut -d= -f2-)
        local change=""
        [ "$bv" != "$tv" ] && change="CHANGED"
        printf '%s\t%s\t%s\t%s\n' "$key" "${bv:-n/a}" "${tv:-n/a}" "$change" >> "$sysfile"
    done
    return 0
}

# ─── Display Results ─────────────────────────────────────────────────────────
_compare_display() {
    local base_dir="$1" tgt_dir="$2" comp_dir="$3"

    printf "\n"
    printf "  %s╔══════════════════════════════════════════════╗%s\n" "${CYN}" "${RST}"
    printf "  %s║%s  %s⚡ Regression Comparison Report%s              %s║%s\n" "${CYN}" "${RST}" "${BLD}" "${RST}" "${CYN}" "${RST}"
    printf "  %s╚══════════════════════════════════════════════╝%s\n" "${CYN}" "${RST}"

    # Sysinfo summary
    printf "\n  %sDevice / Firmware:%s\n" "${BLD}" "${RST}"
    if [ -f "$comp_dir/sysinfo_diff.dat" ]; then
        while IFS=$'\t' read -r key bv tv change; do
            [ -z "$key" ] && continue
            if [ "$change" = "CHANGED" ]; then
                printf "    %-20s %s%s%s → %s%s%s\n" "$key" "${RED}" "$bv" "${RST}" "${GRN}" "$tv" "${RST}"
            else
                printf "    %-20s %s\n" "$key" "$bv"
            fi
        done < "$comp_dir/sysinfo_diff.dat"
    fi

    # Status changes
    printf "\n  %sSubsystem Status:%s\n" "${BLD}" "${RST}"
    if [ -f "$comp_dir/status_diff.dat" ]; then
        printf "    %-16s %-12s %-12s %s\n" "SUBSYSTEM" "BASELINE" "TARGET" ""
        printf "    %-16s %-12s %-12s %s\n" "─────────" "────────" "──────" ""
        while IFS=$'\t' read -r name bstate tstate change; do
            [ -z "$name" ] && continue
            local color="${RST}"
            local arrow=""
            if [ "$change" = "CHANGED" ]; then
                if [ "$tstate" = "up" ]; then
                    color="${GRN}"; arrow="▲ improved"
                elif [ "$tstate" = "down" ]; then
                    color="${RED}"; arrow="▼ regressed"
                else
                    color="${YLW}"; arrow="◆ changed"
                fi
            fi
            printf "    %-16s %-12s ${color}%-12s %s${RST}\n" "$name" "$bstate" "$tstate" "$arrow"
        done < "$comp_dir/status_diff.dat"
    fi

    # Issue diff
    local n_new n_resolved n_persistent
    n_new=$(wc -l < "$comp_dir/issues_new.dat" 2>/dev/null | tr -d ' ')
    n_resolved=$(wc -l < "$comp_dir/issues_resolved.dat" 2>/dev/null | tr -d ' ')
    n_persistent=$(wc -l < "$comp_dir/issues_persistent.dat" 2>/dev/null | tr -d ' ')

    local base_total tgt_total
    base_total=$(wc -l < "$base_dir/issues.dat" 2>/dev/null | tr -d ' ')
    tgt_total=$(wc -l < "$tgt_dir/issues.dat" 2>/dev/null | tr -d ' ')

    printf "\n  %sIssue Summary:%s  Baseline: %s → Target: %s\n" "${BLD}" "${RST}" "${base_total:-0}" "${tgt_total:-0}"

    if [ "${n_new:-0}" -gt 0 ]; then
        printf "    %s⊕ New issues (%d):%s\n" "${RED}" "$n_new" "${RST}"
        while IFS= read -r title; do
            [ -z "$title" ] && continue
            printf "      %s• %s%s\n" "${RED}" "$title" "${RST}"
        done < "$comp_dir/issues_new.dat"
    fi

    if [ "${n_resolved:-0}" -gt 0 ]; then
        printf "    %s✓ Resolved issues (%d):%s\n" "${GRN}" "$n_resolved" "${RST}"
        while IFS= read -r title; do
            [ -z "$title" ] && continue
            printf "      %s• %s%s\n" "${GRN}" "$title" "${RST}"
        done < "$comp_dir/issues_resolved.dat"
    fi

    if [ "${n_persistent:-0}" -gt 0 ]; then
        printf "    %s◆ Persistent issues (%d):%s\n" "${YLW}" "$n_persistent" "${RST}"
        while IFS= read -r title; do
            [ -z "$title" ] && continue
            printf "      • %s\n" "$title"
        done < "$comp_dir/issues_persistent.dat"
    fi

    if [ "${n_new:-0}" -eq 0 ] && [ "${n_resolved:-0}" -eq 0 ] && [ "${n_persistent:-0}" -eq 0 ]; then
        printf "    %s✅ No issues in either capture%s\n" "${GRN}" "${RST}"
    fi

    # Key metrics delta
    printf "\n  %sKey Metric Changes:%s\n" "${BLD}" "${RST}"
    printf "    %-30s %10s %10s %10s\n" "METRIC" "BASELINE" "TARGET" "DELTA"
    printf "    %-30s %10s %10s %10s\n" "──────" "────────" "──────" "─────"

    local important_metrics="issues_total issues_critical issues_high i2p2_mqtt_fail_count i2p2_mqtt_ok_count eth_flap_cycles cert_load_failures hm_reboots evcc_watchdog_count cpstate_fault_count timeline_events boot_count health_score"
    for mkey in $important_metrics; do
        local line
        line=$(grep "^${mkey}"$'\t' "$comp_dir/metrics_diff.dat" 2>/dev/null | head -1)
        [ -z "$line" ] && continue

        local bval tval delta pct
        bval=$(echo "$line" | cut -f2)
        tval=$(echo "$line" | cut -f3)
        delta=$(echo "$line" | cut -f4)
        pct=$(echo "$line" | cut -f5)

        [ "$bval" = "$tval" ] && [ "$bval" = "0" ] && continue

        local color="${RST}" sign=""
        if [ -n "$delta" ] && [ "$delta" != "0" ]; then
            if [ "$delta" -gt 0 ] 2>/dev/null; then
                sign="+"; color="${RED}"
                # Some metrics are good when they go up
                case "$mkey" in
                    i2p2_mqtt_ok_count|ocpp_ws_connected|health_score) color="${GRN}" ;;
                esac
            elif [ "$delta" -lt 0 ] 2>/dev/null; then
                sign=""; color="${GRN}"
                case "$mkey" in
                    i2p2_mqtt_ok_count|ocpp_ws_connected|health_score) color="${RED}" ;;
                esac
            fi
        fi

        local delta_str=""
        if [ -n "$delta" ] && [ "$delta" != "0" ]; then
            delta_str="${sign}${delta}"
            [ -n "$pct" ] && [ "$pct" != "0" ] && delta_str="${delta_str} (${pct}%)"
        fi

        local label
        label=$(_metric_label "$mkey")
        printf "    %-30s %10s %10s ${color}%10s${RST}\n" "$label" "$bval" "$tval" "$delta_str"
    done

    # Config changes
    local n_config
    n_config=$(wc -l < "$comp_dir/config_diff.dat" 2>/dev/null | tr -d ' ')
    if [ "${n_config:-0}" -gt 0 ]; then
        printf "\n  %sConfiguration Changes (%d):%s\n" "${BLD}" "$n_config" "${RST}"
        local shown=0
        while IFS=$'\t' read -r key bval tval _ change; do
            [ -z "$key" ] && continue
            shown=$((shown + 1))
            [ "$shown" -gt 15 ] && { printf "    ... and %d more\n" "$((n_config - 15))"; break; }
            printf "    %s%-40s%s %s → %s\n" "${CYN}" "$key" "${RST}" "$bval" "$tval"
        done < "$comp_dir/config_diff.dat"
    else
        printf "\n  %sConfiguration:%s No changes detected\n" "${BLD}" "${RST}"
    fi

    printf "\n"
}

_metric_label() {
    case "$1" in
        issues_total)          echo "Total Issues" ;;
        issues_critical)       echo "Critical Issues" ;;
        issues_high)           echo "High Issues" ;;
        i2p2_mqtt_fail_count)  echo "MQTT Failures" ;;
        i2p2_mqtt_ok_count)    echo "MQTT Successes" ;;
        eth_flap_cycles)       echo "Ethernet Flaps" ;;
        cert_load_failures)    echo "Certificate Failures" ;;
        hm_reboots)            echo "Reboots" ;;
        evcc_watchdog_count)   echo "EVCC Watchdog" ;;
        cpstate_fault_count)   echo "CPState Faults" ;;
        timeline_events)       echo "Timeline Events" ;;
        boot_count)            echo "Boot Cycles" ;;
        health_score)          echo "Health Score" ;;
        *)                     echo "$1" ;;
    esac
}

# ─── Markdown Report ─────────────────────────────────────────────────────────
_compare_gen_markdown() {
    local base_dir="$1" tgt_dir="$2" comp_dir="$3" outfile="$4"

    local base_fw tgt_fw base_dev tgt_dev
    base_fw=$(grep '^fw_version=' "$base_dir/sysinfo.dat" 2>/dev/null | cut -d= -f2-)
    tgt_fw=$(grep '^fw_version=' "$tgt_dir/sysinfo.dat" 2>/dev/null | cut -d= -f2-)
    base_dev=$(grep '^device_id=' "$base_dir/sysinfo.dat" 2>/dev/null | cut -d= -f2-)
    tgt_dev=$(grep '^device_id=' "$tgt_dir/sysinfo.dat" 2>/dev/null | cut -d= -f2-)

    local n_new n_resolved n_persistent
    n_new=$(wc -l < "$comp_dir/issues_new.dat" 2>/dev/null | tr -d ' ')
    n_resolved=$(wc -l < "$comp_dir/issues_resolved.dat" 2>/dev/null | tr -d ' ')
    n_persistent=$(wc -l < "$comp_dir/issues_persistent.dat" 2>/dev/null | tr -d ' ')

    {
        printf "%s\n" "# Regression Comparison Report"
        printf "%s\n\n" "Generated: $(date '+%Y-%m-%d %H:%M:%S') | Loggy v${ANALYZER_VERSION}"

        printf "%s\n\n" "## Overview"
        printf "| | Baseline | Target |\n"
        printf "|---|---|---|\n"
        printf "| Device | %s | %s |\n" "${base_dev:-unknown}" "${tgt_dev:-unknown}"
        printf "| Firmware | %s | %s |\n" "${base_fw:-unknown}" "${tgt_fw:-unknown}"

        local bi ti
        bi=$(wc -l < "$base_dir/issues.dat" 2>/dev/null | tr -d ' ')
        ti=$(wc -l < "$tgt_dir/issues.dat" 2>/dev/null | tr -d ' ')
        printf "| Issues | %s | %s |\n" "${bi:-0}" "${ti:-0}"

        local bs ts
        bs=$(grep '^health_score=' "$base_dir/metrics.dat" 2>/dev/null | cut -d= -f2-)
        ts=$(grep '^health_score=' "$tgt_dir/metrics.dat" 2>/dev/null | cut -d= -f2-)
        printf "| Health Score | %s | %s |\n\n" "${bs:-n/a}" "${ts:-n/a}"

        # Verdict
        printf "%s\n\n" "## Verdict"
        if [ "${n_new:-0}" -eq 0 ] && [ "${n_resolved:-0}" -gt 0 ]; then
            printf "%s\n\n" "✅ **Improvement detected** — ${n_resolved} issue(s) resolved, no new regressions."
        elif [ "${n_new:-0}" -gt 0 ] && [ "${n_resolved:-0}" -eq 0 ]; then
            printf "%s\n\n" "🔴 **Regression detected** — ${n_new} new issue(s) found."
        elif [ "${n_new:-0}" -gt 0 ] && [ "${n_resolved:-0}" -gt 0 ]; then
            printf "%s\n\n" "⚠️ **Mixed results** — ${n_resolved} resolved, ${n_new} new issue(s)."
        elif [ "${n_persistent:-0}" -gt 0 ]; then
            printf "%s\n\n" "◆ **No change** — ${n_persistent} issue(s) persist."
        else
            printf "%s\n\n" "✅ **Clean** — No issues in either capture."
        fi

        # Status changes
        printf "%s\n\n" "## Subsystem Status"
        printf "| Subsystem | Baseline | Target | Change |\n"
        printf "|---|---|---|---|\n"
        if [ -f "$comp_dir/status_diff.dat" ]; then
            while IFS=$'\t' read -r name bstate tstate change; do
                [ -z "$name" ] && continue
                local arrow=""
                if [ "$change" = "CHANGED" ]; then
                    [ "$tstate" = "up" ] && arrow="▲ improved"
                    [ "$tstate" = "down" ] && arrow="▼ regressed"
                    [ "$tstate" = "degraded" ] && arrow="◆ changed"
                fi
                printf "| %s | %s | %s | %s |\n" "$name" "$bstate" "$tstate" "$arrow"
            done < "$comp_dir/status_diff.dat"
        fi
        printf "\n"

        # Issue diff
        printf "%s\n\n" "## Issue Changes"

        if [ "${n_new:-0}" -gt 0 ]; then
            printf "%s\n\n" "### 🔴 New Issues (${n_new})"
            while IFS= read -r title; do
                [ -z "$title" ] && continue
                # Find full issue details from target
                local sev comp desc
                sev=$(grep "$title" "$tgt_dir/issues.dat" 2>/dev/null | head -1 | cut -f1)
                comp=$(grep "$title" "$tgt_dir/issues.dat" 2>/dev/null | head -1 | cut -f2)
                desc=$(grep "$title" "$tgt_dir/issues.dat" 2>/dev/null | head -1 | cut -f4)
                printf "%s **%s** — %s\n" "- **${sev:-?}**" "$title" "${comp:-?}"
                [ -n "$desc" ] && printf "  %s\n" "$desc"
                printf "\n"
            done < "$comp_dir/issues_new.dat"
        fi

        if [ "${n_resolved:-0}" -gt 0 ]; then
            printf "%s\n\n" "### ✅ Resolved Issues (${n_resolved})"
            while IFS= read -r title; do
                [ -z "$title" ] && continue
                printf "%s\n" "- ~~${title}~~"
            done < "$comp_dir/issues_resolved.dat"
            printf "\n"
        fi

        if [ "${n_persistent:-0}" -gt 0 ]; then
            printf "%s\n\n" "### ◆ Persistent Issues (${n_persistent})"
            while IFS= read -r title; do
                [ -z "$title" ] && continue
                printf "%s\n" "- ${title}"
            done < "$comp_dir/issues_persistent.dat"
            printf "\n"
        fi

        # Key metrics
        printf "%s\n\n" "## Key Metrics"
        printf "| Metric | Baseline | Target | Delta |\n"
        printf "|---|---|---|---|\n"
        local important_metrics="issues_total issues_critical issues_high i2p2_mqtt_fail_count i2p2_mqtt_ok_count eth_flap_cycles cert_load_failures hm_reboots evcc_watchdog_count cpstate_fault_count timeline_events boot_count health_score"
        for mkey in $important_metrics; do
            local line bval tval delta
            line=$(grep "^${mkey}"$'\t' "$comp_dir/metrics_diff.dat" 2>/dev/null | head -1)
            [ -z "$line" ] && continue
            bval=$(echo "$line" | cut -f2)
            tval=$(echo "$line" | cut -f3)
            delta=$(echo "$line" | cut -f4)
            [ "$bval" = "$tval" ] && [ "$bval" = "0" ] && continue

            local delta_str=""
            [ -n "$delta" ] && [ "$delta" != "0" ] && delta_str="$delta"

            printf "| %s | %s | %s | %s |\n" "$(_metric_label "$mkey")" "$bval" "$tval" "$delta_str"
        done
        printf "\n"

        # Config diff
        local n_config
        n_config=$(wc -l < "$comp_dir/config_diff.dat" 2>/dev/null | tr -d ' ')
        if [ "${n_config:-0}" -gt 0 ]; then
            printf "%s\n\n" "## Configuration Changes (${n_config})"
            printf "| Setting | Baseline | Target | Status |\n"
            printf "|---|---|---|---|\n"
            local shown=0
            while IFS=$'\t' read -r key bval tval _ change; do
                [ -z "$key" ] && continue
                shown=$((shown + 1))
                [ "$shown" -gt 30 ] && break
                printf "| \`%s\` | %s | %s | %s |\n" "$key" "$bval" "$tval" "$change"
            done < "$comp_dir/config_diff.dat"
            [ "$n_config" -gt 30 ] && printf "\n*... and %d more changes*\n" "$((n_config - 30))"
        fi

        printf "\n---\n*Loggy v%s*\n" "$ANALYZER_VERSION"
    } > "$outfile"

    [ -s "$outfile" ] && log_ok "Comparison MD: $outfile"
}

# ─── HTML Report ─────────────────────────────────────────────────────────────
_compare_gen_html() {
    local base_dir="$1" tgt_dir="$2" comp_dir="$3" outfile="$4"

    local base_fw tgt_fw base_dev tgt_dev
    base_fw=$(grep '^fw_version=' "$base_dir/sysinfo.dat" 2>/dev/null | cut -d= -f2-)
    tgt_fw=$(grep '^fw_version=' "$tgt_dir/sysinfo.dat" 2>/dev/null | cut -d= -f2-)
    base_dev=$(grep '^device_id=' "$base_dir/sysinfo.dat" 2>/dev/null | cut -d= -f2-)
    tgt_dev=$(grep '^device_id=' "$tgt_dir/sysinfo.dat" 2>/dev/null | cut -d= -f2-)

    local n_new n_resolved n_persistent
    n_new=$(wc -l < "$comp_dir/issues_new.dat" 2>/dev/null | tr -d ' ')
    n_resolved=$(wc -l < "$comp_dir/issues_resolved.dat" 2>/dev/null | tr -d ' ')
    n_persistent=$(wc -l < "$comp_dir/issues_persistent.dat" 2>/dev/null | tr -d ' ')

    {
        cat << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Regression Comparison</title>
<style>
:root{--bg:#0f1117;--bg2:#1a1d27;--bg3:#242836;--border:#2e3348;--fg:#d1d5db;--fg2:#9ca3af;--fg3:#6b7280;
--red:#ef4444;--green:#22c55e;--orange:#f59e0b;--yellow:#eab308;--blue:#3b82f6;--cyan:#06b6d4;}
*{margin:0;padding:0;box-sizing:border-box;}
body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--fg);padding:32px;line-height:1.6;max-width:1100px;margin:0 auto;}
h1{font-size:24px;margin-bottom:4px;color:#fff;}
h2{font-size:18px;margin:28px 0 14px;color:#fff;border-bottom:1px solid var(--border);padding-bottom:8px;}
h3{font-size:15px;margin:16px 0 8px;color:var(--fg);}
.subtitle{color:var(--fg3);font-size:13px;margin-bottom:24px;}
table{width:100%;border-collapse:collapse;font-size:13px;margin-bottom:16px;}
th{background:var(--bg3);padding:10px 14px;text-align:left;color:var(--fg3);font-size:11px;text-transform:uppercase;letter-spacing:.5px;}
td{padding:10px 14px;border-top:1px solid var(--border);}
tr:hover td{background:var(--bg2);}
.card{background:var(--bg2);border:1px solid var(--border);border-radius:8px;padding:16px;margin-bottom:16px;}
.verdict{padding:16px 20px;border-radius:8px;font-size:15px;font-weight:600;margin-bottom:20px;}
.verdict.regression{background:rgba(239,68,68,.1);border:1px solid var(--red);color:var(--red);}
.verdict.improvement{background:rgba(34,197,94,.1);border:1px solid var(--green);color:var(--green);}
.verdict.mixed{background:rgba(245,158,11,.1);border:1px solid var(--orange);color:var(--orange);}
.verdict.neutral{background:var(--bg2);border:1px solid var(--border);color:var(--fg2);}
.chip{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:700;}
.up{color:var(--green);} .down{color:var(--red);} .degraded{color:var(--orange);} .unknown{color:var(--fg3);}
.improved{background:rgba(34,197,94,.12);color:var(--green);}
.regressed{background:rgba(239,68,68,.12);color:var(--red);}
.changed{background:rgba(245,158,11,.12);color:var(--orange);}
.new-issue{color:var(--red);} .resolved{color:var(--green);text-decoration:line-through;}
.persistent{color:var(--fg2);}
.delta-pos{color:var(--red);} .delta-neg{color:var(--green);} .delta-good{color:var(--green);} .delta-bad{color:var(--red);}
code{font-family:'JetBrains Mono',Consolas,monospace;background:var(--bg);padding:2px 6px;border-radius:3px;font-size:12px;}
@media print{body{background:#fff;color:#000;}th{background:#eee;}}
</style></head><body>
HTMLHEAD

        printf '<h1>⚡ Regression Comparison Report</h1>\n'
        printf '<div class="subtitle">Generated %s — Loggy v%s</div>\n' "$(date '+%Y-%m-%d %H:%M')" "$ANALYZER_VERSION"

        # Overview cards
        printf '<table><tr><th></th><th>Baseline</th><th>Target</th></tr>\n'
        printf '<tr><td>Device</td><td><code>%s</code></td><td><code>%s</code></td></tr>\n' "${base_dev:-?}" "${tgt_dev:-?}"
        printf '<tr><td>Firmware</td><td><code>%s</code></td><td><code>%s</code></td></tr>\n' "${base_fw:-?}" "${tgt_fw:-?}"
        local bi ti bs ts
        bi=$(wc -l < "$base_dir/issues.dat" 2>/dev/null | tr -d ' ')
        ti=$(wc -l < "$tgt_dir/issues.dat" 2>/dev/null | tr -d ' ')
        bs=$(grep '^health_score=' "$base_dir/metrics.dat" 2>/dev/null | cut -d= -f2-)
        ts=$(grep '^health_score=' "$tgt_dir/metrics.dat" 2>/dev/null | cut -d= -f2-)
        printf '<tr><td>Issues</td><td>%s</td><td>%s</td></tr>\n' "${bi:-0}" "${ti:-0}"
        printf '<tr><td>Health Score</td><td>%s</td><td>%s</td></tr>\n' "${bs:-n/a}" "${ts:-n/a}"
        printf '</table>\n'

        # Verdict
        local vclass="neutral" vtext
        if [ "${n_new:-0}" -eq 0 ] && [ "${n_resolved:-0}" -gt 0 ]; then
            vclass="improvement"; vtext="✅ Improvement — ${n_resolved} issue(s) resolved, no new regressions"
        elif [ "${n_new:-0}" -gt 0 ] && [ "${n_resolved:-0}" -eq 0 ]; then
            vclass="regression"; vtext="🔴 Regression — ${n_new} new issue(s) detected"
        elif [ "${n_new:-0}" -gt 0 ] && [ "${n_resolved:-0}" -gt 0 ]; then
            vclass="mixed"; vtext="⚠️ Mixed — ${n_resolved} resolved, ${n_new} new issue(s)"
        elif [ "${n_persistent:-0}" -gt 0 ]; then
            vclass="neutral"; vtext="◆ No change — ${n_persistent} issue(s) persist"
        else
            vclass="improvement"; vtext="✅ Clean — no issues in either capture"
        fi
        printf '<div class="verdict %s">%s</div>\n' "$vclass" "$vtext"

        # Status
        printf '<h2>Subsystem Status</h2>\n<table>\n'
        printf '<tr><th>Subsystem</th><th>Baseline</th><th>Target</th><th>Change</th></tr>\n'
        if [ -f "$comp_dir/status_diff.dat" ]; then
            while IFS=$'\t' read -r name bstate tstate change; do
                [ -z "$name" ] && continue
                local arrow="" aclass=""
                if [ "$change" = "CHANGED" ]; then
                    [ "$tstate" = "up" ] && { arrow="▲ improved"; aclass="improved"; }
                    [ "$tstate" = "down" ] && { arrow="▼ regressed"; aclass="regressed"; }
                    [ "$tstate" = "degraded" ] && { arrow="◆ changed"; aclass="changed"; }
                fi
                printf '<tr><td><strong>%s</strong></td><td class="%s">%s</td><td class="%s">%s</td><td><span class="chip %s">%s</span></td></tr>\n' \
                    "$name" "$bstate" "$bstate" "$tstate" "$tstate" "$aclass" "$arrow"
            done < "$comp_dir/status_diff.dat"
        fi
        printf '</table>\n'

        # Issues
        printf '<h2>Issue Changes</h2>\n'
        if [ "${n_new:-0}" -gt 0 ]; then
            printf '<h3>🔴 New Issues (%d)</h3><ul>\n' "$n_new"
            while IFS= read -r title; do
                [ -z "$title" ] && continue
                local sev comp
                sev=$(grep "$title" "$tgt_dir/issues.dat" 2>/dev/null | head -1 | cut -f1)
                comp=$(grep "$title" "$tgt_dir/issues.dat" 2>/dev/null | head -1 | cut -f2)
                printf '<li class="new-issue"><strong>%s</strong> %s <code>%s</code></li>\n' "${sev:-?}" "$(_html_esc "$title")" "${comp:-?}"
            done < "$comp_dir/issues_new.dat"
            printf '</ul>\n'
        fi
        if [ "${n_resolved:-0}" -gt 0 ]; then
            printf '<h3>✅ Resolved Issues (%d)</h3><ul>\n' "$n_resolved"
            while IFS= read -r title; do
                [ -z "$title" ] && continue
                printf '<li class="resolved">%s</li>\n' "$(_html_esc "$title")"
            done < "$comp_dir/issues_resolved.dat"
            printf '</ul>\n'
        fi
        if [ "${n_persistent:-0}" -gt 0 ]; then
            printf '<h3>◆ Persistent Issues (%d)</h3><ul>\n' "$n_persistent"
            while IFS= read -r title; do
                [ -z "$title" ] && continue
                printf '<li class="persistent">%s</li>\n' "$(_html_esc "$title")"
            done < "$comp_dir/issues_persistent.dat"
            printf '</ul>\n'
        fi

        # Key metrics
        printf '<h2>Key Metrics</h2>\n<table>\n'
        printf '<tr><th>Metric</th><th>Baseline</th><th>Target</th><th>Delta</th></tr>\n'
        local important_metrics="issues_total issues_critical issues_high i2p2_mqtt_fail_count i2p2_mqtt_ok_count eth_flap_cycles cert_load_failures hm_reboots evcc_watchdog_count cpstate_fault_count timeline_events boot_count health_score"
        for mkey in $important_metrics; do
            local line bval tval delta
            line=$(grep "^${mkey}"$'\t' "$comp_dir/metrics_diff.dat" 2>/dev/null | head -1)
            [ -z "$line" ] && continue
            bval=$(echo "$line" | cut -f2)
            tval=$(echo "$line" | cut -f3)
            delta=$(echo "$line" | cut -f4)
            [ "$bval" = "$tval" ] && [ "$bval" = "0" ] && continue

            local dclass=""
            if [ -n "$delta" ] && [ "$delta" != "0" ]; then
                if [ "$delta" -gt 0 ] 2>/dev/null; then
                    dclass="delta-bad"
                    case "$mkey" in i2p2_mqtt_ok_count|ocpp_ws_connected|health_score) dclass="delta-good" ;; esac
                else
                    dclass="delta-good"
                    case "$mkey" in i2p2_mqtt_ok_count|ocpp_ws_connected|health_score) dclass="delta-bad" ;; esac
                fi
            fi

            local delta_str=""
            [ -n "$delta" ] && [ "$delta" != "0" ] && delta_str="$delta"

            printf '<tr><td>%s</td><td>%s</td><td>%s</td><td class="%s"><strong>%s</strong></td></tr>\n' \
                "$(_metric_label "$mkey")" "$bval" "$tval" "$dclass" "$delta_str"
        done
        printf '</table>\n'

        # Config changes
        local n_config
        n_config=$(wc -l < "$comp_dir/config_diff.dat" 2>/dev/null | tr -d ' ')
        if [ "${n_config:-0}" -gt 0 ]; then
            printf '<h2>Configuration Changes (%d)</h2>\n<table>\n' "$n_config"
            printf '<tr><th>Setting</th><th>Baseline</th><th>Target</th><th>Status</th></tr>\n'
            local shown=0
            while IFS=$'\t' read -r key bval tval _ change; do
                [ -z "$key" ] && continue
                shown=$((shown + 1))
                [ "$shown" -gt 30 ] && break
                printf '<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td><span class="chip changed">%s</span></td></tr>\n' \
                    "$(_html_esc "$key")" "$(_html_esc "$bval")" "$(_html_esc "$tval")" "$change"
            done < "$comp_dir/config_diff.dat"
            printf '</table>\n'
        fi

        printf '</body></html>\n'
    } > "$outfile"

    [ -s "$outfile" ] && log_ok "Comparison HTML: $outfile"
}

_html_esc() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}
