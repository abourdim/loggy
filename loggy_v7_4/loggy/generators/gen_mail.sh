#!/bin/bash
# gen_mail.sh — Email Brief Report Generator
# Loggy v6.0 — Phase 9
#
# Generates concise email-ready reports (plain text + HTML).
# Outlook/Gmail/Apple Mail safe inline CSS.

generate_mail_report() {
    local dev_id datestamp base
    dev_id=$(get_sysinfo device_id)
    [ -z "$dev_id" ] || [ "$dev_id" = "unknown" ] && dev_id="unknown"
    datestamp=$(date +%Y%m%d_%H%M)
    base="${OUTPUT_DIR}/mail_${dev_id}_${datestamp}"
    mkdir -p "$OUTPUT_DIR"

    _gen_mail_text "${base}.txt"
    _gen_mail_html "${base}.html"

    log_ok "Mail brief: ${base}.txt, ${base}.html"
}

# Build auto subject line
_mail_subject() {
    local dev_id score grade total_issues
    dev_id=$(get_sysinfo device_id)
    score=$(get_metric health_score)
    grade=$(get_metric health_grade)
    total_issues=$(get_metric issues_total)
    local prefix="${dev_id:0:12}"

    local urgency="INFO"
    [ "$(get_metric issues_critical)" -gt 0 ] 2>/dev/null && urgency="CRITICAL"
    [ "$urgency" = "INFO" ] && [ "$(get_metric issues_high)" -gt 0 ] 2>/dev/null && urgency="HIGH"

    printf "[%s] IoTecha %s — %s issues, Score %s/100 (%s)" \
        "$urgency" "$prefix" "${total_issues:-0}" "${score:-?}" "${grade:-?}"
}

# ─── Plain Text Email ────────────────────────────────────────────────────────
_gen_mail_text() {
    local outfile="$1"
    local subject
    subject=$(_mail_subject)

    {
        printf "Subject: %s\n" "$subject"
        printf "Date: %s\n\n" "$(date '+%Y-%m-%d %H:%M')"

        printf "Loggy — Diagnostic Brief\n"
        printf "========================================\n\n"

        printf "Device:    %s\n" "$(get_sysinfo device_id)"
        printf "Firmware:  %s\n" "$(get_sysinfo fw_version)"
        printf "Score:     %s/100 (%s)\n" "$(get_metric health_score)" "$(get_metric health_grade)"
        printf "Issues:    %s (%s Critical, %s High, %s Medium, %s Low)\n" \
            "$(get_metric issues_total)" "$(get_metric issues_critical)" \
            "$(get_metric issues_high)" "$(get_metric issues_medium)" \
            "$(get_metric issues_low)"
        local _mc
        _mc=$(safe_int "$(get_metric multi_connector)")
        if [ "$_mc" -eq 1 ]; then
            printf "Connector 1: %dE %dW (%d sessions)  |  Connector 2: %dE %dW (%d sessions)\n" \
                "$(safe_int "$(get_metric conn1_errors)")" "$(safe_int "$(get_metric conn1_warnings)")" "$(safe_int "$(get_metric conn1_sessions)")" \
                "$(safe_int "$(get_metric conn2_errors)")" "$(safe_int "$(get_metric conn2_warnings)")" "$(safe_int "$(get_metric conn2_sessions)")"
        fi
        printf "\n"

        # Status
        printf "SUBSYSTEM STATUS\n"
        printf "%-14s %s\n" "────────────" "──────"
        if [ -f "$WORK_DIR/status.dat" ]; then
            while IFS=$'\t' read -r name state; do
                [ -z "$name" ] && continue
                local icon="?"
                [ "$state" = "up" ] && icon="OK"
                [ "$state" = "down" ] && icon="DOWN"
                [ "$state" = "degraded" ] && icon="WARN"
                printf "%-14s %s\n" "$name" "$icon"
            done < "$WORK_DIR/status.dat"
        fi

        # Issues
        printf "\nISSUES\n"
        if [ -f "$ISSUES_FILE" ] && [ -s "$ISSUES_FILE" ]; then
            local n=0
            while IFS=$'\t' read -r sev comp title desc evfile; do
                [ -z "$sev" ] && continue
                n=$((n + 1))
                printf "\n%d. [%s] %s\n" "$n" "$sev" "$title"
                printf "   Component: %s\n" "$comp"
                # Split desc vs troubleshooting
                local main_desc="" ts_text="" onsite_flag=""
                if echo "$desc" | grep -q 'Troubleshooting:'; then
                    main_desc=$(echo "$desc" | sed 's/ *Troubleshooting:.*//')
                    ts_text=$(echo "$desc" | grep -oP 'Troubleshooting:.*' | sed 's/\[On-site service.*//;s/ *$//')
                else
                    main_desc="$desc"
                fi
                echo "$desc" | grep -q '\[On-site service' && onsite_flag="yes"
                printf "   %s\n" "$main_desc"
                [ -n "$ts_text" ] && printf "   >> %s\n" "$ts_text"
                [ -n "$onsite_flag" ] && printf "   !! ON-SITE SERVICE REQUIRED\n"
            done < "$ISSUES_FILE"
        else
            printf "  No issues detected.\n"
        fi

        # Key metrics
        printf "\nKEY METRICS\n"
        local metrics="i2p2_mqtt_fail_count i2p2_mqtt_ok_count eth_flap_cycles cert_load_failures hm_reboots evcc_watchdog_count boot_count timeline_events"
        for m in $metrics; do
            local val
            val=$(get_metric "$m")
            [ -z "$val" ] || [ "$val" = "0" ] && continue
            local label
            case "$m" in
                i2p2_mqtt_fail_count) label="MQTT Failures" ;;
                i2p2_mqtt_ok_count) label="MQTT Successes" ;;
                eth_flap_cycles) label="Eth Flaps" ;;
                cert_load_failures) label="Cert Failures" ;;
                hm_reboots) label="Reboots" ;;
                evcc_watchdog_count) label="EVCC Watchdog" ;;
                boot_count) label="Boot Cycles" ;;
                timeline_events) label="Timeline Events" ;;
                *) label="$m" ;;
            esac
            printf "  %-20s %s\n" "$label" "$val"
        done

        printf "\n---\nGenerated by Loggy v%s at %s\n" "$ANALYZER_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$outfile"
}

# ─── HTML Email ──────────────────────────────────────────────────────────────
_gen_mail_html() {
    local outfile="$1"
    local subject
    subject=$(_mail_subject)
    local score grade
    score=$(get_metric health_score)
    grade=$(get_metric health_grade)

    {
        cat << 'MAILHEAD'
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta http-equiv="X-UA-Compatible" content="IE=edge">
  <!--[if mso]>
  <xml><o:OfficeDocumentSettings><o:AllowPNG/><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml>
  <![endif]-->
  <style type="text/css">
    body, table, td, p, a { -webkit-text-size-adjust:100%; -ms-text-size-adjust:100%; }
    table, td { mso-table-lspace:0pt; mso-table-rspace:0pt; border-collapse:collapse!important; }
    img { border:0; height:auto; line-height:100%; outline:none; text-decoration:none; -ms-interpolation-mode:bicubic; }
    body { margin:0!important; padding:0!important; background-color:#f5f5f5; }
  </style>
</head>
<body style="margin:0;padding:0;background-color:#f5f5f5;font-family:Arial,Helvetica,sans-serif;-webkit-font-smoothing:antialiased;">
<!--[if mso | IE]><table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%"><tr><td><![endif]-->
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f5f5f5;padding:20px 0;">
<tr><td align="center">
<!--[if mso | IE]></td></tr></table><table role="presentation" align="center" border="0" cellpadding="0" cellspacing="0" width="600"><tr><td><![endif]-->
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" align="center" style="background:#ffffff;border:1px solid #e0e0e0;max-width:600px;width:100%;">
MAILHEAD

        # Header banner
        local hdr_color="#1a73e8"
        [ "$(get_metric issues_critical)" -gt 0 ] 2>/dev/null && hdr_color="#d32f2f"
        [ "$(get_metric issues_critical)" -eq 0 ] 2>/dev/null && [ "$(get_metric issues_high)" -gt 0 ] 2>/dev/null && hdr_color="#f57c00"

        printf '<tr><td style="background:%s;padding:24px 32px;">\n' "$hdr_color"
        printf '<h1 style="margin:0;color:#fff;font-size:20px;">⚡ IoTecha Diagnostic Brief</h1>\n'
        printf '<p style="margin:4px 0 0;color:rgba(255,255,255,0.85);font-size:13px;">%s — %s</p>\n' \
            "$(get_sysinfo device_id)" "$(date '+%Y-%m-%d %H:%M')"
        printf '</td></tr>\n'

        # Score + Summary row
        printf '<tr><td style="padding:24px 32px;">\n'
        printf '<table width="100%%" cellpadding="0" cellspacing="0"><tr>\n'

        # Score circle
        local score_color="#4caf50"
        [ "${score:-0}" -lt 70 ] && score_color="#ff9800"
        [ "${score:-0}" -lt 40 ] && score_color="#f44336"
        printf '<td width="100" style="text-align:center;vertical-align:top;">\n'
        printf '<div style="width:80px;height:80px;border-radius:50%%;border:4px solid %s;display:inline-flex;align-items:center;justify-content:center;">\n' "$score_color"
        printf '<span style="font-size:28px;font-weight:bold;color:%s;">%s</span></div>\n' "$score_color" "${score:-?}"
        printf '<div style="font-size:11px;color:#888;margin-top:4px;">Health Score</div></td>\n'

        # Quick stats
        printf '<td style="vertical-align:top;padding-left:20px;">\n'
        printf '<table cellpadding="4" cellspacing="0" style="font-size:13px;">\n'
        printf '<tr><td style="color:#888;">Firmware</td><td style="font-weight:600;">%s</td></tr>\n' "$(get_sysinfo fw_version)"
        printf '<tr><td style="color:#888;">Issues</td><td style="font-weight:600;">%s</td></tr>\n' "$(get_metric issues_total)"
        printf '<tr><td style="color:#888;">Timeline</td><td style="font-weight:600;">%s events</td></tr>\n' "$(get_metric timeline_events)"
        local _mc
        _mc=$(safe_int "$(get_metric multi_connector)")
        if [ "$_mc" -eq 1 ]; then
            printf '<tr><td style="color:#888;">Connector 1</td><td><span style="color:#d32f2f;font-weight:600;">%dE</span> <span style="color:#f57c00;">%dW</span> (%d sess)</td></tr>\n' \
                "$(safe_int "$(get_metric conn1_errors)")" "$(safe_int "$(get_metric conn1_warnings)")" "$(safe_int "$(get_metric conn1_sessions)")"
            printf '<tr><td style="color:#888;">Connector 2</td><td><span style="color:#d32f2f;font-weight:600;">%dE</span> <span style="color:#f57c00;">%dW</span> (%d sess)</td></tr>\n' \
                "$(safe_int "$(get_metric conn2_errors)")" "$(safe_int "$(get_metric conn2_warnings)")" "$(safe_int "$(get_metric conn2_sessions)")"
        fi
        printf '</table></td></tr></table>\n'
        printf '</td></tr>\n'

        # Status pills
        printf '<tr><td style="padding:0 32px 20px;">\n'
        printf '<p style="font-size:12px;color:#888;text-transform:uppercase;letter-spacing:1px;margin:0 0 8px;">Subsystem Status</p>\n'
        if [ -f "$WORK_DIR/status.dat" ]; then
            while IFS=$'\t' read -r name state; do
                [ -z "$name" ] && continue
                local bg="#e8f5e9" fg="#2e7d32"
                [ "$state" = "down" ] && bg="#ffebee" && fg="#c62828"
                [ "$state" = "degraded" ] && bg="#fff3e0" && fg="#e65100"
                [ "$state" = "unknown" ] && bg="#f5f5f5" && fg="#9e9e9e"
                printf '<span style="display:inline-block;padding:4px 12px;margin:2px;border-radius:12px;background:%s;color:%s;font-size:12px;font-weight:600;">%s: %s</span>\n' \
                    "$bg" "$fg" "$name" "$state"
            done < "$WORK_DIR/status.dat"
        fi
        printf '</td></tr>\n'

        # Issues table
        if [ -f "$ISSUES_FILE" ] && [ -s "$ISSUES_FILE" ]; then
            printf '<tr><td style="padding:0 32px 20px;">\n'
            printf '<p style="font-size:12px;color:#888;text-transform:uppercase;letter-spacing:1px;margin:0 0 8px;">Issues</p>\n'
            printf '<table width="100%%" cellpadding="8" cellspacing="0" style="border:1px solid #e0e0e0;font-size:13px;border-collapse:collapse;">\n'
            printf '<tr style="background:#f5f5f5;"><th style="text-align:left;border-bottom:1px solid #e0e0e0;">Severity</th><th style="text-align:left;border-bottom:1px solid #e0e0e0;">Issue</th><th style="text-align:left;border-bottom:1px solid #e0e0e0;">Component</th></tr>\n'

            while IFS=$'\t' read -r sev comp title desc evfile; do
                [ -z "$sev" ] && continue
                local sev_color="#888"
                [ "$sev" = "CRITICAL" ] && sev_color="#d32f2f"
                [ "$sev" = "HIGH" ] && sev_color="#f57c00"
                [ "$sev" = "MEDIUM" ] && sev_color="#fbc02d"
                [ "$sev" = "LOW" ] && sev_color="#4caf50"
                printf '<tr><td style="border-bottom:1px solid #f0f0f0;color:%s;font-weight:700;vertical-align:top;">%s</td>' "$sev_color" "$sev"
                printf '<td style="border-bottom:1px solid #f0f0f0;vertical-align:top;">'
                printf '<strong>%s</strong>' "$title"
                local main_desc="" ts_text="" onsite_flag=""
                if echo "$desc" | grep -q 'Troubleshooting:'; then
                    main_desc=$(echo "$desc" | sed 's/ *Troubleshooting:.*//')
                    ts_text=$(echo "$desc" | grep -oP 'Troubleshooting:.*' | sed 's/\[On-site service.*//;s/ *$//')
                else
                    main_desc="$desc"
                fi
                echo "$desc" | grep -q '\[On-site service' && onsite_flag="yes"
                printf '<div style="font-size:12px;color:#555;margin-top:4px;">%s</div>' "$main_desc"
                [ -n "$ts_text" ] && printf '<div style="font-size:11px;color:#1565c0;background:#e3f2fd;padding:6px 10px;margin-top:6px;border-left:3px solid #1976d2;border-radius:3px;">🔧 %s</div>' "$ts_text"
                [ -n "$onsite_flag" ] && printf '<div style="font-size:11px;color:#d32f2f;font-weight:700;margin-top:4px;">🚨 On-site service required</div>'
                printf '</td>'
                printf '<td style="border-bottom:1px solid #f0f0f0;color:#888;font-size:12px;vertical-align:top;">%s</td></tr>\n' "$comp"
            done < "$ISSUES_FILE"

            printf '</table></td></tr>\n'
        fi

        # Footer
        printf '<tr><td style="padding:16px 32px;background:#f9f9f9;border-top:1px solid #e0e0e0;font-size:11px;color:#999;">\n'
        printf 'Loggy v%s — %s</td></tr>\n' "$ANALYZER_VERSION" "$(date '+%Y-%m-%d %H:%M')"

        printf '</table></td></tr></table></body></html>\n'
    } > "$outfile"
}
