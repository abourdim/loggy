#!/bin/bash
# searcher.sh — Log Search, Component Investigation & Signature Matching
# Loggy v6.0 — Phase 8
#
# Enhanced search with: keyword, regex, severity filter, time range,
# component filter, context lines, result export.
# Component deep dive. Error fingerprint database.

# ═══════════════════════════════════════════════════════════════════════════════
# SEARCH ENGINE
# ═══════════════════════════════════════════════════════════════════════════════

# Search across all parsed logs with full filtering
# Usage: search_logs [options]
#   -p pattern    Search pattern (keyword or regex)
#   -s severity   E/W/I/C/N or ALL
#   -c component  Component name filter
#   -a after      Start time (YYYY-MM-DD HH:MM)
#   -b before     End time (YYYY-MM-DD HH:MM)
#   -x context    Context lines (0-5)
#   -r            Regex mode
#   -m max        Max results (default 200)
#   -o file       Export results to file
#   -n connector  Connector number (1, 2, ...) — filters to connector-specific lines
search_logs() {
    local pattern="" severity="" component="" time_after="" time_before=""
    local context=0 regex_mode=0 max_results=200 export_file="" connector=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -p) pattern="$2"; shift 2 ;;
            -s) severity="$2"; shift 2 ;;
            -c) component="$2"; shift 2 ;;
            -a) time_after="$2"; shift 2 ;;
            -b) time_before="$2"; shift 2 ;;
            -x) context="$2"; shift 2 ;;
            -r) regex_mode=1; shift ;;
            -m) max_results="$2"; shift 2 ;;
            -o) export_file="$2"; shift 2 ;;
            -n) connector="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [ -z "$pattern" ]; then
        log_error "Search pattern required (-p)"
        return 1
    fi

    local parsed_dir="$WORK_DIR/parsed"
    [ -d "$parsed_dir" ] || { log_error "No parsed logs found"; return 1; }

    local results_file
    results_file=$(mktemp "${TMPDIR:-/tmp}/search.XXXXXX")
    local count=0

    # Build grep flags
    local grep_flags="-i"
    [ "$regex_mode" -eq 1 ] && grep_flags="-E -i"
    [ "$context" -gt 0 ] && grep_flags="$grep_flags -B$context -A$context"

    log_debug "Search: pattern='$pattern' severity=$severity component=$component max=$max_results flags=$grep_flags"
    spinner_start "Searching logs..."
    for f in "$parsed_dir"/*.parsed; do
        [ -f "$f" ] || continue
        case "$f" in *_full.parsed) continue ;; esac

        local comp
        comp=$(basename "$f" .parsed)

        # Component filter
        if [ -n "$component" ]; then
            # Case-insensitive match
            local comp_lower="${comp,,}"
            local filter_lower="${component,,}"
            case "$comp_lower" in
                *"$filter_lower"*) ;;
                *) continue ;;
            esac
        fi

        # Search within file, apply filters with awk
        # Build connector filter pattern if specified
        local conn_filter=""
        if [ -n "$connector" ]; then
            case "$connector" in
                1) conn_filter='[Cc]onnector[=: ]*1|[Cc]onnectorId[=: ]*1|evseId[=: ]*1|evse[-_]1|InnerSM[-_]1|[Ss]ocket *1|Connector\[0\]' ;;
                2) conn_filter='[Cc]onnector[=: ]*2|[Cc]onnectorId[=: ]*2|evseId[=: ]*2|evse[-_]2|InnerSM[-_]2|[Ss]ocket *2|Connector\[1\]' ;;
                *) conn_filter="[Cc]onnector[=: ]*${connector}|[Cc]onnectorId[=: ]*${connector}|evseId[=: ]*${connector}" ;;
            esac
        fi

        {
            if [ -n "$conn_filter" ]; then
                grep $grep_flags "$pattern" "$f" 2>/dev/null | grep -aE "$conn_filter"
            else
                grep $grep_flags "$pattern" "$f" 2>/dev/null
            fi
        } | \
        awk -F'|' -v sev="$severity" -v ta="$time_after" -v tb="$time_before" \
                  -v comp="$comp" -v max="$max_results" -v cnt="$count" '
        BEGIN { n = cnt }
        /^--$/ { print "---"; next }
        {
            ts = $1; lvl = $2
            # Message is field 3+ (sub-component:message)
            msg = ""
            for (i = 3; i <= NF; i++) msg = msg (i>3?"|":"") $i

            # Severity filter
            if (sev != "" && sev != "ALL") {
                if (toupper(lvl) != toupper(sev)) next
            }

            # Time range filter (string comparison works for ISO timestamps)
            if (ta != "" && ts < ta) next
            if (tb != "" && ts > tb) next

            n++
            if (n > max) exit

            printf "%s|%s|%s|%s\n", ts, lvl, comp, msg
        }
        END { print "COUNT=" n > "/dev/stderr" }
        ' 2>/dev/null >> "$results_file"

        count=$(wc -l < "$results_file" | tr -d ' ')
        [ "$count" -ge "$max_results" ] && break
    done
    spinner_stop
    log_debug "Search complete: $count results in $results_file"

    # Output results
    local total
    total=$(grep -cv '^---$' "$results_file" 2>/dev/null || echo 0)

    if [ "$total" -eq 0 ]; then
        printf "  %sNo results found for '%s'%s\n" "${GRY}" "$pattern" "${RST}"
        rm -f "$results_file"
        return 1
    fi

    # Export if requested
    if [ -n "$export_file" ]; then
        cp "$results_file" "$export_file"
        log_ok "Exported $total results to: $export_file"
    fi

    # Display results
    printf "  %s%d results%s" "${GRN}" "$total" "${RST}"
    [ -n "$severity" ] && printf " [%s]" "$severity"
    [ -n "$component" ] && printf " [%s]" "$component"
    [ -n "$time_after" ] && printf " [after %s]" "$time_after"
    [ -n "$time_before" ] && printf " [before %s]" "$time_before"
    printf "\n\n"

    # Paginated display (50 results per page)
    local page_size=50
    local all_lines=()
    while IFS= read -r line; do
        all_lines+=("$line")
    done < "$results_file"
    rm -f "$results_file"
    local total_lines=${#all_lines[@]}
    local page_start=0

    while true; do
        local page_end=$((page_start + page_size))
        [ "$page_end" -gt "$total_lines" ] && page_end=$total_lines

        local i
        for ((i=page_start; i<page_end; i++)); do
            local line="${all_lines[$i]}"
            if [ "$line" = "---" ]; then
                printf "  %s--%s\n" "${DIM}" "${RST}"
                continue
            fi

            local ts lvl comp rest
            ts=$(echo   "$line" | cut -d'|' -f1)
            lvl=$(echo  "$line" | cut -d'|' -f2)
            comp=$(echo "$line" | cut -d'|' -f3)
            rest=$(echo "$line" | cut -d'|' -f4-)

            local color=""
            case "$lvl" in
                E|C) color="${RED}" ;;
                W)   color="${YLW}" ;;
                N)   color="${MAG}" ;;
                I)   color="${RST}" ;;
                *)   color="${GRY}" ;;
            esac

            printf "  %s%-23s%s [%s%s%s] %s%-15s%s %s\n" \
                "${GRY}" "$ts" "${RST}" "$color" "$lvl" "${RST}" "${CYN}" "$comp" "${RST}" \
                "$(echo "$rest" | cut -c1-120)"
        done

        # Pagination controls
        if [ "$page_end" -lt "$total_lines" ] || [ "$page_start" -gt 0 ]; then
            local showing_from=$((page_start + 1))
            local showing_to=$page_end
            printf "\n  %sShowing %d-%d of %d results%s\n"                 "${DIM}" "$showing_from" "$showing_to" "$total" "${RST}"
            printf "  %s[n]ext  [p]rev  [a]ll  [q]uit%s  " "${DIM}" "${RST}"
            local nav; read -r nav
            case "$nav" in
                n|N|"")
                    [ "$page_end" -lt "$total_lines" ] && page_start=$page_end ||                         printf "  %s(already at last page)%s\n" "${GRY}" "${RST}"
                    ;;
                p|P)
                    page_start=$((page_start - page_size))
                    [ "$page_start" -lt 0 ] && page_start=0
                    ;;
                a|A)
                    page_size=$total_lines
                    ;;
                q|Q|b|B) break ;;
            esac
        else
            # All results fit on one page
            break
        fi
    done
    rm -f "$results_file"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# COMPONENT INVESTIGATION
# ═══════════════════════════════════════════════════════════════════════════════

# Deep dive into a single component
investigate_component() {
    local comp="$1"
    [ -z "$comp" ] && { log_error "Component name required"; return 1; }

    local parsed_dir="$WORK_DIR/parsed"
    local parsed_file=""

    # Find matching parsed file (case-insensitive)
    for f in "$parsed_dir"/*.parsed; do
        [ -f "$f" ] || continue
        case "$f" in *_full.parsed) continue ;; esac
        local name
        name=$(basename "$f" .parsed)
        if [ "${name,,}" = "${comp,,}" ] || echo "$name" | grep -qi "$comp"; then
            parsed_file="$f"
            comp=$(basename "$f" .parsed)
            break
        fi
    done

    if [ -z "$parsed_file" ] || [ ! -f "$parsed_file" ]; then
        log_error "Component not found: $comp"
        printf "  Available: "
        ls "$parsed_dir"/*.parsed 2>/dev/null | xargs -I{} basename {} .parsed | grep -v _full | tr '\n' ' '
        printf "\n"
        return 1
    fi

    local total errors warnings crits infos
    total=$(wc -l < "$parsed_file" | tr -d ' ')
    errors=$(grep -c '|E|' "$parsed_file" 2>/dev/null || echo 0)
    warnings=$(grep -c '|W|' "$parsed_file" 2>/dev/null || echo 0)
    crits=$(grep -c '|C|' "$parsed_file" 2>/dev/null || echo 0)
    infos=$(grep -c '|I|' "$parsed_file" 2>/dev/null || echo 0)

    printf "\n"
    print_header "Component Investigation: $comp"

    # ── Summary ──
    printf "\n  %sLog Stats:%s\n" "${BLD}" "${RST}"
    printf "    Total lines:  %s\n" "$total"
    printf "    Critical:     %s%s%s\n" "${RED}" "$crits" "${RST}"
    printf "    Errors:       %s%s%s\n" "${RED}" "$errors" "${RST}"
    printf "    Warnings:     %s%s%s\n" "${YLW}" "$warnings" "${RST}"
    printf "    Info:         %s\n" "$infos"

    # ── Status ──
    local status_file="$WORK_DIR/status.dat"
    if [ -f "$status_file" ]; then
        local status
        status=$(grep -i "^${comp}" "$status_file" 2>/dev/null | head -1 | cut -f2)
        if [ -n "$status" ]; then
            local scolor="${GRN}"
            [ "$status" = "down" ] && scolor="${RED}"
            [ "$status" = "degraded" ] && scolor="${YLW}"
            printf "\n  %sStatus:%s %s%s%s\n" "${BLD}" "${RST}" "$scolor" "$status" "${RST}"
        fi
    fi

    # ── Related issues ──
    if [ -f "$ISSUES_FILE" ] && [ -s "$ISSUES_FILE" ]; then
        local related
        related=$(grep -i "$comp" "$ISSUES_FILE" 2>/dev/null)
        if [ -n "$related" ]; then
            local rcount
            rcount=$(echo "$related" | wc -l)
            printf "\n  %sRelated Issues (%d):%s\n" "${BLD}" "$rcount" "${RST}"
            echo "$related" | while IFS=$'\t' read -r sev icomp title desc evfile; do
                local scolor=""
                case "$sev" in CRITICAL) scolor="${RED}" ;; HIGH) scolor="${RED}" ;; MEDIUM) scolor="${YLW}" ;; LOW) scolor="${GRN}" ;; esac
                printf "    %s%-8s%s %s (%s)\n" "$scolor" "$sev" "${RST}" "$title" "$icomp"
            done
        fi
    fi

    # ── Timeline events ──
    if [ -f "$TIMELINE_FILE" ] && [ -s "$TIMELINE_FILE" ]; then
        local tl_count
        tl_count=$(grep -ic "$comp" "$TIMELINE_FILE" 2>/dev/null || echo 0)
        if [ "$tl_count" -gt 0 ]; then
            printf "\n  %sTimeline Events (%d):%s\n" "${BLD}" "$tl_count" "${RST}"
            grep -i "$comp" "$TIMELINE_FILE" | head -15 | while IFS=$'\t' read -r ts sev tcomp msg; do
                local scolor="${GRY}"
                case "$sev" in CRITICAL) scolor="${RED}" ;; HIGH) scolor="${RED}" ;; MEDIUM) scolor="${YLW}" ;; esac
                printf "    %s%-23s%s %s%-8s%s %s\n" "${GRY}" "$ts" "${RST}" "$scolor" "$sev" "${RST}" "$(echo "$msg" | cut -c1-90)"
            done
            [ "$tl_count" -gt 15 ] && printf "    %s... %d more%s\n" "${GRY}" "$((tl_count - 15))" "${RST}"
        fi
    fi

    # ── Top error messages ──
    printf "\n  %sTop Error Messages:%s\n" "${BLD}" "${RST}"
    grep -E '\|E\||\|C\|' "$parsed_file" 2>/dev/null | \
        awk -F'|' '{
            msg = $NF
            # Normalize: strip timestamps, numbers, hex
            gsub(/[0-9]+/, "N", msg)
            gsub(/0x[0-9a-fA-F]+/, "0xN", msg)
            count[msg]++
        }
        END {
            for (msg in count) printf "%6d  %s\n", count[msg], msg
        }' | sort -rn | head -10 | while read -r cnt msg; do
            printf "    %s%5d×%s  %s\n" "${RED}" "$cnt" "${RST}" "$(echo "$msg" | cut -c1-100)"
        done

    # ── Time span ──
    local first_ts last_ts
    first_ts=$(head -1 "$parsed_file" | cut -d'|' -f1)
    last_ts=$(tail -1 "$parsed_file" | cut -d'|' -f1)
    if [ -n "$first_ts" ] && [ -n "$last_ts" ]; then
        printf "\n  %sTime Span:%s %s → %s\n" "${BLD}" "${RST}" "$first_ts" "$last_ts"
    fi

    # ── Signature matches ──
    _check_signatures_for_component "$comp"

    printf "\n"
}

# List all available components
list_components() {
    local parsed_dir="$WORK_DIR/parsed"
    printf "\n  %sAvailable Components:%s\n\n" "${BLD}" "${RST}"
    printf "  %-22s %8s %8s %8s\n" "COMPONENT" "LINES" "ERRORS" "WARNINGS"
    printf "  %-22s %8s %8s %8s\n" "─────────" "─────" "──────" "────────"

    for f in "$parsed_dir"/*.parsed; do
        [ -f "$f" ] || continue
        case "$f" in *_full.parsed) continue ;; esac
        local comp
        comp=$(basename "$f" .parsed)
        local total errors warnings crit_count
        total=$(wc -l < "$f" | tr -d ' \r\n')
        errors=$(grep -cF '|E|' "$f" 2>/dev/null | tr -d ' \r\n')
        errors="${errors:-0}"
        crit_count=$(grep -cF '|C|' "$f" 2>/dev/null | tr -d ' \r\n')
        crit_count="${crit_count:-0}"
        errors=$((errors + crit_count))
        warnings=$(grep -cF '|W|' "$f" 2>/dev/null | tr -d ' \r\n')
        warnings="${warnings:-0}"

        local ecolor="${RST}"
        [ "$errors" -gt 0 ] && ecolor="${RED}"
        printf "  %-22s %8s %s%8s%s %8s\n" "$comp" "$total" "$ecolor" "$errors" "${RST}" "$warnings"
    done
    printf "\n"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SIGNATURE DATABASE
# ═══════════════════════════════════════════════════════════════════════════════

# Signature format (TSV file):
#   pattern<TAB>component<TAB>severity<TAB>title<TAB>root_cause<TAB>fix<TAB>kb_url
# Lines starting with # are comments.

SIGNATURES_DIR=""

_init_signatures() {
    SIGNATURES_DIR="${SCRIPT_DIR:-$(dirname "$0")}/signatures"
    [ -d "$SIGNATURES_DIR" ] || mkdir -p "$SIGNATURES_DIR" 2>/dev/null
}

# Load and search the signature database
match_signatures() {
    _init_signatures

    local sig_file="$SIGNATURES_DIR/known_signatures.tsv"
    [ -f "$sig_file" ] || { _generate_default_signatures; }
    local reg_file="$SIGNATURES_DIR/error_registry.tsv"

    if [ ! -f "$sig_file" ] && [ ! -f "$reg_file" ]; then
        log_warn "No signature database found"
        return 1
    fi

    local match_count=0
    local unmatched_count=0
    local matched_issues=""
    local unmatched_issues=""

    # For each issue, try to find a matching signature
    if [ -f "$ISSUES_FILE" ] && [ -s "$ISSUES_FILE" ]; then
        while IFS=$'\t' read -r sev comp title desc evfile; do
            [ -z "$sev" ] && continue
            local found=0
            local sig_cause="" sig_fix="" sig_url="" reg_ts="" reg_onsite="" reg_desc=""

            # Pass 1: match against known_signatures.tsv
            if [ -f "$sig_file" ]; then
                while IFS=$'\t' read -r sig_pattern sig_comp sig_sev sig_title s_cause s_fix s_url; do
                    [ -z "$sig_pattern" ] && continue
                    [[ "$sig_pattern" == \#* ]] && continue
                    if echo "$title $desc" | grep -qi "$sig_pattern"; then
                        found=1
                        sig_cause="$s_cause"
                        sig_fix="$s_fix"
                        sig_url="$s_url"
                        break
                    fi
                done < "$sig_file"
            fi

            # Pass 2: match against 363-error registry (always, for cross-reference enrichment)
            if [ -f "$reg_file" ]; then
                while IFS=$'\t' read -r rmod rcode retype rname rdesc_r rts ronsite rsev; do
                    [ -z "$rname" ] && continue
                    [[ "$rmod" == "module" ]] && continue
                    if echo "$title $desc" | grep -qiF "$rname"; then
                        reg_ts="$rts"
                        reg_onsite="$ronsite"
                        reg_desc="$rdesc_r ($rmod)"
                        [ "$found" -eq 0 ] && found=1
                        break
                    fi
                done < "$reg_file"
            fi

            if [ "$found" -eq 1 ]; then
                match_count=$((match_count + 1))
                # Merge: prefer known_sig root_cause, enrich with registry troubleshooting
                local merged_cause="${sig_cause:-$reg_desc}"
                local merged_fix="$sig_fix"
                # Append registry troubleshooting if not already in sig_fix
                if [ -n "$reg_ts" ] && [ -z "$sig_fix" ]; then
                    merged_fix="$reg_ts"
                elif [ -n "$reg_ts" ] && [ -n "$sig_fix" ]; then
                    # Only append if registry has different info
                    echo "$sig_fix" | grep -qF "$(echo "$reg_ts" | cut -d'|' -f1 | head -c30)" 2>/dev/null || \
                        merged_fix="${sig_fix}. Official: ${reg_ts}"
                fi
                [ "$reg_onsite" = "true" ] && merged_fix="${merged_fix:+$merged_fix }[On-site service required]"
                matched_issues="${matched_issues}${sev}\t${comp}\t${title}\t${merged_cause}\t${merged_fix}\t${sig_url}\n"
            else
                unmatched_count=$((unmatched_count + 1))
                unmatched_issues="${unmatched_issues}${sev}\t${comp}\t${title}\n"
            fi
        done < "$ISSUES_FILE"
    fi

    # Display
    local total
    total=$(issue_count)
    local reg_count=0
    [ -f "$reg_file" ] && reg_count=$(($(wc -l < "$reg_file") - 1))
    printf "\n"
    print_header "Signature Matching"

    printf "\n  %sDatabase:%s %s known patterns + %s%d%s official error registry entries (cross-referenced)\n" \
        "${BLD}" "${RST}" "$(wc -l < "$sig_file" 2>/dev/null | tr -d ' ')" "${CYN}" "$reg_count" "${RST}"
    printf "  %sMatched:%s %s%d%s / %d issues have known signatures\n" \
        "${BLD}" "${RST}" "${GRN}" "$match_count" "${RST}" "$total"

    if [ "$match_count" -gt 0 ]; then
        printf "\n  %sKnown Issues:%s\n" "${BLD}" "${RST}"
        printf '%b' "$matched_issues" | while IFS=$'\t' read -r sev comp title cause fix url; do
            [ -z "$sev" ] && continue
            local scolor=""
            case "$sev" in CRITICAL) scolor="${RED}" ;; HIGH) scolor="${RED}" ;; MEDIUM) scolor="${YLW}" ;; LOW) scolor="${GRN}" ;; esac
            printf "\n    %s%-8s%s %s\n" "$scolor" "$sev" "${RST}" "$title"
            [ -n "$cause" ] && printf "    %sRoot cause:%s %s\n" "${GRY}" "${RST}" "$cause"
            [ -n "$fix" ] && printf "    %sFix:%s %s\n" "${GRY}" "${RST}" "$fix"
            [ -n "$url" ] && printf "    %sKB:%s %s\n" "${GRY}" "${RST}" "$url"
        done
    fi

    if [ "$unmatched_count" -gt 0 ]; then
        printf "\n  %s⚠ Unknown Issues (%d):%s\n" "${YLW}" "$unmatched_count" "${RST}"
        printf '%b' "$unmatched_issues" | while IFS=$'\t' read -r sev comp title; do
            [ -z "$sev" ] && continue
            printf "    %s%-8s%s %s (%s)\n" "${YLW}" "$sev" "${RST}" "$title" "$comp"
        done
        printf "\n  %sTip:%s Add patterns with: option 4 → 5 (Manage signatures)\n" "${GRY}" "${RST}"
    fi

    printf "\n"

    # Store results as metrics
    add_metric "sig_matched" "$match_count"
    add_metric "sig_unmatched" "$unmatched_count"
}

# Check signatures for a specific component
_check_signatures_for_component() {
    local comp="$1"
    _init_signatures

    local sig_file="$SIGNATURES_DIR/known_signatures.tsv"
    [ -f "$sig_file" ] || return

    local matches=0
    printf "\n  %sSignature Matches:%s\n" "${BLD}" "${RST}"

    while IFS=$'\t' read -r sig_pattern sig_comp sig_sev sig_title sig_cause sig_fix sig_url; do
        [ -z "$sig_pattern" ] && continue
        [[ "$sig_pattern" == \#* ]] && continue

        # Match by component
        if echo "$sig_comp" | grep -qi "$comp"; then
            matches=$((matches + 1))
            printf "    %s•%s %s%s%s — %s\n" "${CYN}" "${RST}" "${BLD}" "$sig_title" "${RST}" "$sig_cause"
            [ -n "$sig_fix" ] && printf "      %sFix:%s %s\n" "${GRY}" "${RST}" "$sig_fix"
        fi
    done < "$sig_file"

    [ "$matches" -eq 0 ] && printf "    %sNo known signatures for this component%s\n" "${GRY}" "${RST}"
}

# Generate default signature database from known IoTecha patterns
_generate_default_signatures() {
    _init_signatures
    local sig_file="$SIGNATURES_DIR/known_signatures.tsv"

    cat > "$sig_file" << 'ENDSIG'
# Loggy — Known Error Signatures
# Format: pattern<TAB>component<TAB>severity<TAB>title<TAB>root_cause<TAB>fix<TAB>kb_url
#
# Connectivity
MQTT.*fail	i2p2/MQTT	HIGH	MQTT Connection Failure	AWS IoT Core connection interrupted by network instability or credential issues	Check network path to AWS endpoint, verify certificates and thing policy	
MQTT.*DISCONNECTED	i2p2/MQTT	MEDIUM	MQTT Disconnect Events	Broker disconnects due to keep-alive timeout or network interruption	Review connectionMonitor.Timeout, check network stability	
PPP.*never.*established	NetworkBoss/PPP	CRITICAL	PPP/Cellular Not Established	Cellular modem fails to establish PPP link — SIM, signal, or modem chat failure	Check SIM status, signal strength (AT+CSQ), modem chat script	
PPP.*down	NetworkBoss/PPP	HIGH	PPP Link Down	Cellular backup link offline	Verify SIM active, check APN config, inspect modem logs	
ppp0.*missing	i2p2	MEDIUM	PPP Interface Missing	ppp0 interface not present when expected	Check NetworkBoss PPP configuration, modem initialization	
#
# Network
eth.*flap	NetworkBoss/Ethernet	HIGH	Ethernet Link Flapping	PHY link toggling up/down, possibly bad cable, switch port, or PHY negotiation	Check cable/connector, try fixed speed (ethtool), inspect switch port	
WiFi.*fail	NetworkBoss/WiFi	MEDIUM	WiFi Connection Failure	WiFi association or authentication failing	Verify SSID/password, check signal strength, review wpa_supplicant	
#
# Charging
CPState.*fault	ChargerApp	HIGH	CPState Fault	Control Pilot state machine detected fault condition	Check CP circuit, EVCC board, vehicle compatibility	
EVCC.*watchdog	ChargerApp/EVCC	LOW	EVCC Watchdog Warnings	EVCC communication watchdog triggered — may indicate timing issues	Usually non-critical; check if charging completes normally	
PowerBoard.*fault	ChargerApp/PowerBoard	HIGH	Power Board Fault	Power board reporting fault at boot or during operation	Inspect PB firmware, check relay/contactor state, review HW diagnostics	
#
# Certificates
cert.*fail	CertManager	MEDIUM	Certificate Load Failure	Certificate loading from TPM or filesystem failed	Check TPM access, verify cert slots, review failsafe chain	
cert.*slot	CertManager	LOW	Certificate Slot Warning	Certificate slot status issue	Verify certificate provisioning completed	
#
# OCPP
WebSocket.*fail	OCPP	HIGH	OCPP WebSocket Failure	WebSocket connection to CSMS failing	Check CSMS endpoint, TLS certificates, network connectivity	
BootNotification.*reject	OCPP	HIGH	Boot Notification Rejected	CSMS rejected BootNotification — charger not authorized	Verify charger registration with CSMS, check serial/model	
#
# System
PMQ.*sub.*fail	EnergyManager/PMQ	LOW	PMQ Subscription Failure	Inter-process message queue subscription failing	Usually resolves on retry; persistent failures indicate component crash	
reboot	HealthMonitor	MEDIUM	Excessive Reboots	Multiple system reboots detected	Check watchdog config, investigate crash logs, review power supply stability	
gpio.*fail	HealthMonitor	LOW	GPIO Access Failure	Hardware GPIO pin access failed	Check hardware connections, driver loaded, permissions	
#
# Kernel
kernel.*panic	kernel	CRITICAL	Kernel Panic Configured	Kernel configured to panic on errors (panic=60, panic_on_oops=1)	Review if intentional for watchdog recovery; may cause unexpected reboots	
PHY.*down	kernel	MEDIUM	PHY Link Down	Network PHY reporting link down	Check physical cable, switch port, PHY driver	
TPM.*error	kernel	LOW	TPM Communication Warning	TPM chip communication issue	Usually transient; persistent errors may indicate HW issue	
ENDSIG

    log_ok "Generated default signature database: $sig_file"
}

# Add a custom signature interactively
add_signature() {
    _init_signatures
    local sig_file="$SIGNATURES_DIR/known_signatures.tsv"
    [ -f "$sig_file" ] || _generate_default_signatures

    printf "\n  %sAdd New Signature%s\n\n" "${BLD}" "${RST}"

    printf "  %sPattern (grep):%s " "${GRY}" "${RST}"
    local pattern; read -r pattern
    [ -z "$pattern" ] && { log_warn "Cancelled"; return; }

    printf "  %sComponent:%s " "${GRY}" "${RST}"
    local comp; read -r comp

    printf "  %sSeverity (CRITICAL/HIGH/MEDIUM/LOW):%s " "${GRY}" "${RST}"
    local sev; read -r sev
    sev="${sev^^}"

    printf "  %sTitle:%s " "${GRY}" "${RST}"
    local title; read -r title

    printf "  %sRoot cause:%s " "${GRY}" "${RST}"
    local cause; read -r cause

    printf "  %sFix/recommendation:%s " "${GRY}" "${RST}"
    local fix; read -r fix

    printf "  %sKB URL (optional):%s " "${GRY}" "${RST}"
    local url; read -r url

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$pattern" "$comp" "$sev" "$title" "$cause" "$fix" "$url" >> "$sig_file"

    log_ok "Signature added: $title"
}

# List all signatures
list_signatures() {
    _init_signatures
    local sig_file="$SIGNATURES_DIR/known_signatures.tsv"
    [ -f "$sig_file" ] || _generate_default_signatures

    printf "\n  %sKnown Signatures:%s\n\n" "${BLD}" "${RST}"
    printf "  %-8s %-22s %s\n" "SEVERITY" "COMPONENT" "TITLE"
    printf "  %-8s %-22s %s\n" "────────" "─────────" "─────"

    local count=0
    while IFS=$'\t' read -r pattern comp sev title cause fix url; do
        [ -z "$pattern" ] && continue
        [[ "$pattern" == \#* ]] && continue
        count=$((count + 1))

        local scolor=""
        case "$sev" in CRITICAL) scolor="${RED}" ;; HIGH) scolor="${RED}" ;; MEDIUM) scolor="${YLW}" ;; LOW) scolor="${GRN}" ;; esac
        printf "  %s%-8s%s %-22s %s\n" "$scolor" "$sev" "${RST}" "$comp" "$title"
    done < "$sig_file"

    printf "\n  %sTotal: %d signatures + 363 official error registry entries%s\n\n" "${GRY}" "$count" "${RST}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SIGNATURE REPORT INTEGRATION
# ═══════════════════════════════════════════════════════════════════════════════

# Generate signature match data for reports
signatures_markdown() {
    _init_signatures
    local sig_file="$SIGNATURES_DIR/known_signatures.tsv"
    [ -f "$sig_file" ] || return

    local has_match=0

    printf "\n## Signature Analysis\n\n"

    if [ -f "$ISSUES_FILE" ] && [ -s "$ISSUES_FILE" ]; then
        printf "| Issue | Status | Root Cause | Fix |\n"
        printf "|---|---|---|---|\n"

        while IFS=$'\t' read -r sev comp title desc evfile; do
            [ -z "$sev" ] && continue
            local found=0 sig_cause="" sig_fix=""

            while IFS=$'\t' read -r sig_pattern sig_comp sig_sev sig_title sig_c sig_f sig_url; do
                [ -z "$sig_pattern" ] && continue
                [[ "$sig_pattern" == \#* ]] && continue
                if echo "$title $desc" | grep -qi "$sig_pattern"; then
                    found=1; has_match=1
                    sig_cause="$sig_c"; sig_fix="$sig_f"
                    break
                fi
            done < "$sig_file"

            if [ "$found" -eq 1 ]; then
                printf "| **%s** %s | ✅ Known | %s | %s |\n" "$sev" "$title" "$sig_cause" "$sig_fix"
            else
                printf "| **%s** %s | ⚠️ Unknown | — | — |\n" "$sev" "$title"
            fi
        done < "$ISSUES_FILE"
    fi
    printf "\n"
}

signatures_html() {
    _init_signatures
    local sig_file="$SIGNATURES_DIR/known_signatures.tsv"
    [ -f "$sig_file" ] || return

    printf '<h2>Signature Analysis</h2>\n'
    printf '<table class="dtable"><thead><tr><th>Issue</th><th>Status</th><th>Root Cause</th><th>Fix</th></tr></thead><tbody>\n'

    if [ -f "$ISSUES_FILE" ] && [ -s "$ISSUES_FILE" ]; then
        while IFS=$'\t' read -r sev comp title desc evfile; do
            [ -z "$sev" ] && continue
            local found=0 sig_cause="" sig_fix=""

            while IFS=$'\t' read -r sig_pattern sig_comp sig_sev sig_title sig_c sig_f sig_url; do
                [ -z "$sig_pattern" ] && continue
                [[ "$sig_pattern" == \#* ]] && continue
                if echo "$title $desc" | grep -qi "$sig_pattern"; then
                    found=1; sig_cause="$sig_c"; sig_fix="$sig_f"
                    break
                fi
            done < "$sig_file"

            local sclass=""
            case "$sev" in CRITICAL|HIGH) sclass="warn" ;; esac

            if [ "$found" -eq 1 ]; then
                printf '<tr><td class="%s"><strong>%s</strong> %s</td><td style="color:var(--green)">✅ Known</td><td>%s</td><td>%s</td></tr>\n' \
                    "$sclass" "$sev" "$title" "$sig_cause" "$sig_fix"
            else
                printf '<tr><td class="%s"><strong>%s</strong> %s</td><td style="color:var(--orange)">⚠️ Unknown</td><td>—</td><td>—</td></tr>\n' \
                    "$sclass" "$sev" "$title"
            fi
        done < "$ISSUES_FILE"
    fi

    printf '</tbody></table>\n'
}

signatures_json() {
    _init_signatures
    local sig_file="$SIGNATURES_DIR/known_signatures.tsv"

    echo '"signatures": ['
    local first=1

    if [ -f "$sig_file" ] && [ -f "$ISSUES_FILE" ] && [ -s "$ISSUES_FILE" ]; then
        while IFS=$'\t' read -r sev comp title desc evfile; do
            [ -z "$sev" ] && continue
            local found=0 sig_cause="" sig_fix=""

            if [ -f "$sig_file" ]; then
                while IFS=$'\t' read -r sig_pattern sig_comp sig_sev sig_title sig_c sig_f sig_url; do
                    [ -z "$sig_pattern" ] && continue
                    [[ "$sig_pattern" == \#* ]] && continue
                    if echo "$title $desc" | grep -qi "$sig_pattern"; then
                        found=1; sig_cause="$sig_c"; sig_fix="$sig_f"
                        break
                    fi
                done < "$sig_file"
            fi

            [ "$first" -eq 1 ] && first=0 || echo ','
            printf '  {"severity":"%s","title":"%s","known":%s' \
                "$(_json_escape "$sev")" "$(_json_escape "$title")" \
                "$([ "$found" -eq 1 ] && echo 'true' || echo 'false')"
            [ "$found" -eq 1 ] && printf ',"cause":"%s","fix":"%s"' \
                "$(_json_escape "$sig_cause")" "$(_json_escape "$sig_fix")"
            printf '}'
        done < "$ISSUES_FILE"
    fi

    echo ''
    echo ']'
}
