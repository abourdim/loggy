#!/bin/bash
# ============================================================================
#  Loggy v6.0
#  Diagnostic & forensic tool for IoTecha EV charger logs
# ============================================================================

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Source Modules ──────────────────────────────────────────────────────────
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/loader.sh"
source "$SCRIPT_DIR/lib/parser.sh"
source "$SCRIPT_DIR/lib/evidence.sh"
source "$SCRIPT_DIR/lib/analyzer_standard.sh"
source "$SCRIPT_DIR/lib/analyzer_deep.sh"
source "$SCRIPT_DIR/lib/scorer.sh"
source "$SCRIPT_DIR/lib/comparator.sh"
source "$SCRIPT_DIR/lib/searcher.sh"
source "$SCRIPT_DIR/lib/watcher.sh"
source "$SCRIPT_DIR/lib/fleet.sh"
source "$SCRIPT_DIR/lib/menu.sh"
source "$SCRIPT_DIR/lib/server.sh"

source "$SCRIPT_DIR/generators/gen_markdown.sh"
source "$SCRIPT_DIR/generators/gen_html.sh"
source "$SCRIPT_DIR/generators/gen_webapp.sh"
source "$SCRIPT_DIR/generators/gen_mail.sh"
source "$SCRIPT_DIR/generators/gen_tickets.sh"

# Generate both MD + HTML reports (+ optional web app)
generate_reports() {
    local dev_id
    dev_id=$(get_sysinfo device_id)

    # Step 19: Fallback filename when device ID unknown — use input filename + timestamp
    if [ -z "$dev_id" ] || [ "$dev_id" = "unknown" ]; then
        local input_base
        input_base=$(basename "${INPUT_PATH:-unknown}" | sed 's/\.zip$//;s/\.tar\..*$//;s/[^A-Za-z0-9_-]/_/g')
        dev_id="${input_base:-unknown}"
    fi

    local datestamp
    datestamp=$(date +%Y%m%d_%H%M)
    local base="${OUTPUT_DIR}/analysis_${dev_id}_${datestamp}"
    REPORT_FILE="${base}.md"

    mkdir -p "$OUTPUT_DIR"

    local total=2
    [ "${GENERATE_WEBAPP:-0}"   -eq 1 ] && total=$((total + 1))
    [ "${GENERATE_MAIL:-0}"     -eq 1 ] && total=$((total + 1))
    [ "${GENERATE_TICKETS:-0}"  -eq 1 ] && total=$((total + 1))

    local step=0
    # Step 13: Show what is being generated with spinner feedback
    step=$((step + 1)); progress_step "$step" "$total" "Reports"
    spinner_start "Generating Markdown report..."
    generate_markdown "${base}.md"
    spinner_stop
    log_debug "Report: Markdown → ${base}.md"

    step=$((step + 1)); progress_step "$step" "$total" "Reports"
    spinner_start "Generating HTML report..."
    generate_html "${base}.html"
    spinner_stop
    log_debug "Report: HTML → ${base}.html"

    if [ "${GENERATE_WEBAPP:-0}" -eq 1 ]; then
        step=$((step + 1)); progress_step "$step" "$total" "Reports"
        spinner_start "Generating web app..."
        generate_webapp "${OUTPUT_DIR}/webapp_${dev_id}_${datestamp}.html"
        spinner_stop
    fi
    if [ "${GENERATE_MAIL:-0}" -eq 1 ]; then
        step=$((step + 1)); progress_step "$step" "$total" "Reports"
        spinner_start "Generating email brief..."
        generate_mail_report
        spinner_stop
    fi
    if [ "${GENERATE_TICKETS:-0}" -eq 1 ]; then
        step=$((step + 1)); progress_step "$step" "$total" "Reports"
        spinner_start "Generating tickets..."
        generate_tickets
        spinner_stop
    fi

    log_info "Reports saved to: $OUTPUT_DIR"

    # Step 20: Auto-open HTML report where supported
    _autoopen_report "${base}.html"
}

# Open a file with the system default viewer (best-effort, silent on failure)
_autoopen_report() {
    local file="$1"
    [ -f "$file" ] || return
    # Only auto-open if running interactively
    _is_tty || return
    case "$(uname -s 2>/dev/null)" in
        Darwin)   open "$file" 2>/dev/null & ;;
        Linux)
            if command -v xdg-open >/dev/null 2>&1; then
                xdg-open "$file" 2>/dev/null &
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            # Windows / Git Bash / MSYS2
            if command -v start >/dev/null 2>&1; then
                start "" "$file" 2>/dev/null
            elif command -v cmd.exe >/dev/null 2>&1; then
                cmd.exe /c start "" "$(cygpath -w "$file" 2>/dev/null || echo "$file")" 2>/dev/null &
            fi
            ;;
    esac
    return 0
}

# ─── Argument Parsing ────────────────────────────────────────────────────────
INPUT_ARGS=()

_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -m|--mode)
                shift; ANALYSIS_MODE="${1:-standard}"
                ;;
            -e|--evidence)
                shift; EVIDENCE_LEVEL="${1:-std}"
                ;;
            -o|--output)
                shift; OUTPUT_DIR="${1:-./reports}"
                ;;
            -q|--quiet)
                QUIET_MODE=1; LOG_LEVEL=1
                ;;
            -v|--verbose)
                VERBOSE_MODE=1; LOG_LEVEL=3
                ;;
            --debug)
                LOG_LEVEL=4
                ;;
            --no-color)
                USE_COLOR=0
                ;;
            --cache) ;;
            --web) GENERATE_WEBAPP=1 ;;
            --mail) GENERATE_MAIL=1 ;;
            --tickets) GENERATE_TICKETS=1 ;;
            --deep) RUN_DEEP=1 ;;
            --check)
                init_colors
                print_header "System / Install Check"
                check_dependencies
                exit $?
                ;;
            --compare)
                COMPARE_MODE=1
                ;;
            --fleet) FLEET_MODE=1 ;;
            --watch) WATCH_MODE=1 ;;
            --server) SERVER_MODE=1 ;;
            --port) SERVER_PORT="${2:-8080}"; shift ;;
            -h|--help)
                _show_help
                exit 0
                ;;
            --version)
                echo "$ANALYZER_NAME v$ANALYZER_VERSION"
                exit 0
                ;;
            -*)
                echo "Unknown option: $1" >&2
                _show_help
                exit 1
                ;;
            *)
                INPUT_ARGS+=("$1")
                ;;
        esac
        shift
    done
}

_show_help() {
    local B=$'\033[1m' D=$'\033[2m' U=$'\033[4m' C=$'\033[36m' G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' M=$'\033[35m' X=$'\033[0m'
    # Detect if piped / no color
    if ! _is_tty || [ "${USE_COLOR:-1}" -eq 0 ]; then
        B="" D="" U="" C="" G="" Y="" R="" M="" X=""
    fi

    cat << EOF
${B}${C}⚡ Loggy v${ANALYZER_VERSION}${X}
${D}Diagnostic & forensic toolkit for IoTecha EV charger RACC log bundles${X}
${D}Pure Bash — no Python, no Node, no Docker${X}

${B}USAGE${X}
  ${G}./analyzer.sh${X}                              Interactive menu
  ${G}./analyzer.sh${X} [OPTIONS] <input>            Batch analysis
  ${G}./analyzer.sh${X} ${Y}--compare${X} <base> <target>    Regression comparison
  ${G}./analyzer.sh${X} ${Y}--fleet${X} <directory>          Multi-charger analysis
  ${G}./analyzer.sh${X} ${Y}--watch${X} <directory>          Live monitoring
  ${G}./analyzer.sh${X} ${Y}--server${X}                     Web UI (browser)

${B}INPUT${X} ${D}(auto-detected)${X}
  ${G}./analyzer.sh${X} report.zip                   RACC zip archive
  ${G}./analyzer.sh${X} /path/to/logs/               Directory of log files
  ${G}./analyzer.sh${X} *.log *.properties            Individual files

${B}ANALYSIS OPTIONS${X}
  ${Y}-m, --mode${X} <standard|deep>     Analysis depth (default: standard)
                                   ${D}standard${X}: 25 issue detectors + health score
                                   ${D}deep${X}: + boot timing, causal chains, gap
                                          detection, config validation, error
                                          histogram, PMQ interaction map
  ${Y}-e, --evidence${X} <min|std|full>  Evidence collection level (default: std)
                                   ${D}min${X}:  first/last occurrence only
                                   ${D}std${X}:  representative sample (~30 lines)
                                   ${D}full${X}: all matching lines (can be large)

${B}OUTPUT OPTIONS${X}
  ${Y}-o, --output${X} <dir>             Output directory (default: ./reports/)
  ${Y}--web${X}                           Generate interactive web app (single HTML,
                                   works offline, ~130KB)
  ${Y}--mail${X}                          Generate email brief:
                                   • Plain text (.txt) with auto subject line
                                   • Inline-CSS HTML safe for Outlook/Gmail
  ${Y}--tickets${X}                       Generate issue tickets:
                                   • One Markdown file per issue
                                   • Jira CSV for bulk import
                                   • GitLab JSON for API creation

${B}MODES${X}
  ${Y}--compare${X} <baseline> <target>  Compare two RACC captures. Detects:
                                   • New / resolved / persistent issues
                                   • Metric deltas (13 key metrics)
                                   • Subsystem status changes (▲/▼)
                                   • Config (.properties) diffs
                                   • Firmware / sysinfo changes
                                   Outputs: comparison MD + HTML with verdict

  ${Y}--fleet${X} <directory>            Analyze all .zip files in directory:
                                   • Per-charger analysis + health score
                                   • Fleet dashboard sorted worst-first
                                   • Cross-fleet pattern detection
                                   • Shared vs unique issues
                                   Outputs: fleet MD + HTML

  ${Y}--watch${X} <directory>            Live monitoring of log directory:
                                   • Tails all .log files in real time
                                   • Uses inotifywait (or polling fallback)
                                   • Color-coded alert feed
                                   • Pattern matching against signatures
                                   • Session recording for later analysis
                                   Stop: Ctrl+C

  ${Y}--server${X}                        Launch web UI (browser-based TUI):
                                   • Upload & analyze RACC zips
                                   • Dashboard, Issues, Status, Health
                                   • Timeline, Search, Components
                                   • Regression Comparison
                                   • Signatures database browser
                                   Requires: python3
  ${Y}--port${X} <port>                   Web server port (default: 8080)

${B}DISPLAY OPTIONS${X}
  ${Y}-q, --quiet${X}                    Suppress progress output (CI/batch friendly)
  ${Y}-v, --verbose${X}                  Show detailed parsing progress
  ${Y}--debug${X}                        Show all debug messages on console
  ${Y}--no-color${X}                     Disable ANSI color codes

${B}ANALYSIS OPTIONS${X}
  ${Y}--deep${X}                         Run deep forensic analysis after standard analysis

${B}WEB SERVER${X}
  ${Y}--server${X}                        Launch browser-based UI (requires python3)
  ${Y}--port${X} <number>                 Server port (default: 8080)

${B}INFO${X}
  ${Y}--check${X}                        Verify dependencies & system info
  ${Y}-h, --help${X}                     Show this help
  ${Y}--version${X}                      Show version

${B}INTERACTIVE MENU${X} ${D}(run with no arguments)${X}
  ${C}1${X}  Load logs          ${C}5${X}  Select / view log
  ${C}2${X}  Standard analysis   ${C}6${X}  View results
  ${C}3${X}  Deep analysis       ${C}7${X}  Generate reports
  ${C}4${X}  Search & investigate ${C}8${X}  Compare / regression
  ${C}9${X}  Settings            ${C}0${X}  Check install

  ${B}Search submenu (4):${X}
  ${C}1${X} Quick search  ${C}2${X} Advanced search  ${C}3${X} Investigate component
  ${C}4${X} Match signatures  ${C}5${X} Manage signatures  ${C}6${X} List components

  ${B}Reports submenu (7):${X}
  ${C}1${X} MD+HTML  ${C}2${X} Web app  ${C}3${X} All  ${C}4${X} Email brief  ${C}5${X} Tickets

${B}ISSUE DETECTORS${X} ${D}(standard analysis)${X}
  ${R}CRITICAL${X}  PPP/Cellular not established (modem/SIM failure)
  ${R}HIGH${X}      MQTT connection failure (AWS IoT Core)
  ${R}HIGH${X}      Ethernet (eth0) link flapping (PHY/cable)
  ${R}HIGH${X}      Power board fault at boot (relay/contactor)
  ${Y}MEDIUM${X}    Certificate manager warnings (TPM/cert load)
  ${G}LOW${X}       EVCC watchdog warnings (timing issues)
  ${G}LOW${X}       PMQ subscription failures (IPC issues)

${B}HEALTH SCORE${X} ${D}(0–100, weighted)${X}
  Connectivity  30%  │ MQTT, PPP, Ethernet, WiFi
  Hardware      25%  │ Power board, GPIO, boot, reboots
  Services      25%  │ OCPP, EVCC, PMQ, component health
  Configuration 20%  │ Certificates, config validation
  ${D}Grades: A (90+) B (75+) C (60+) D (40+) F (<40)${X}

${B}SIGNATURES${X} ${D}(21 built-in error fingerprints)${X}
  Auto-matched against detected issues. Each provides:
  • Root cause explanation
  • Recommended fix / remediation
  Edit: ${U}signatures/known_signatures.tsv${X}
  Format: pattern<TAB>component<TAB>severity<TAB>title<TAB>cause<TAB>fix<TAB>url

${B}REPORT OUTPUTS${X}
  Format       Flag         File
  ─────────    ──────────   ─────────────────────────
  Markdown     ${D}(default)${X}    analysis_{device}_{date}.md
  HTML         ${D}(default)${X}    analysis_{device}_{date}.html
  Web App      --web        webapp_{device}_{date}.html
  Email text   --mail       mail_{device}_{date}.txt
  Email HTML   --mail       mail_{device}_{date}.html
  Tickets      --tickets    tickets_{device}_{date}/
  Comparison   --compare    comparison_{date}.md, .html
  Fleet        --fleet      fleet_{date}.md, .html

${B}EXAMPLES${X}
  ${D}# Standard analysis${X}
  ${G}./analyzer.sh${X} RACC-Report.zip

  ${D}# Deep analysis + web app${X}
  ${G}./analyzer.sh${X} ${Y}--mode deep${X} ${Y}--web${X} RACC-Report.zip

  ${D}# Everything — deep + all outputs${X}
  ${G}./analyzer.sh${X} ${Y}--mode deep${X} ${Y}--web${X} ${Y}--mail${X} ${Y}--tickets${X} RACC.zip

  ${D}# Custom output dir${X}
  ${G}./analyzer.sh${X} ${Y}-o /tmp/diag${X} RACC-Report.zip

  ${D}# Regression comparison${X}
  ${G}./analyzer.sh${X} ${Y}--compare${X} before.zip after.zip

  ${D}# Fleet analysis${X}
  ${G}./analyzer.sh${X} ${Y}--fleet${X} /path/to/racc-folder/

  ${D}# Live monitoring${X}
  ${G}./analyzer.sh${X} ${Y}--watch${X} /path/to/live-logs/

  ${D}# Quiet mode for CI/CD${X}
  ${G}./analyzer.sh${X} ${Y}-q -o artifacts/${X} RACC.zip

  ${D}# Analyze a directory${X}
  ${G}./analyzer.sh${X} /opt/iotecha/logs/

  ${D}# Verify installation${X}
  ${G}./analyzer.sh${X} ${Y}--check${X}

  ${D}# Run self-tests${X}
  ${G}./run_tests.sh${X}

  ${D}# Launch web UI${X}
  ${G}./analyzer.sh${X} ${Y}--server${X}
  ${G}./analyzer.sh${X} ${Y}--server${X} ${Y}--port 9090${X}

  ${D}# Launcher menu (guided start)${X}
  ${G}./start.sh${X}

${B}PLATFORMS${X}
  Linux, macOS, WSL, MSYS2/Git Bash, Docker, BusyBox (degraded)
  Requirements: bash 3.2+, awk, grep, sed, unzip

${D}Full documentation: README.html${X}
EOF
}


# ─── Banner ──────────────────────────────────────────────────────────────────
_show_banner() {
    [ "$QUIET_MODE" -eq 1 ] && return
    printf "\n"
    printf "  %s╔══════════════════════════════════════════════╗%s\n" "${CYN}" "${RST}"
    printf "  %s║%s  %s⚡ Loggy v%-34s%s%s║%s\n" "${CYN}" "${RST}" "${BLD}" "$ANALYZER_VERSION" "${RST}" "${CYN}" "${RST}"
    printf "  %s╚══════════════════════════════════════════════╝%s\n" "${CYN}" "${RST}"
    printf "\n"
}

# ─── Main ────────────────────────────────────────────────────────────────────
_relocate_logs_if_needed() {
    local log_dir; log_dir=$(dirname "$LOG_FILE")
    # Normalize both to absolute paths for comparison
    local cur; cur=$(cd "$log_dir" 2>/dev/null && pwd)
    local dst; dst=$(mkdir -p "$OUTPUT_DIR" 2>/dev/null && cd "$OUTPUT_DIR" && pwd)
    [ "$cur" = "$dst" ] && return 0

    # Move session log
    local new_log="$dst/$(basename "$LOG_FILE")"
    mv "$LOG_FILE" "$new_log" 2>/dev/null && LOG_FILE="$new_log"

    # Move console log (tee still has fd open — mv preserves the inode)
    local new_con="$dst/$(basename "$CONSOLE_LOG")"
    mv "$CONSOLE_LOG" "$new_con" 2>/dev/null && CONSOLE_LOG="$new_con"

    # Remove empty default dir left by init_common
    rmdir "$cur" 2>/dev/null || true

    _log_file "INFO" "Logs relocated to: $dst"
}

main() {
    # Initialize
    init_common

    # ── Capture all console output (stdout + stderr) to a raw log ────────
    # Separate from $LOG_FILE (structured) — this is a faithful replay of
    # everything the user saw, including ANSI codes and spinner output.
    CONSOLE_LOG="${LOG_FILE%.log}_console.log"
    : > "$CONSOLE_LOG" 2>/dev/null || CONSOLE_LOG="$WORK_DIR/console.log"
    # Save tty state BEFORE tee redirect (tee turns fd1 into a pipe,
    # which would cause init_colors to think stdout is not a terminal)
    [ -t 1 ] && _STDOUT_IS_TTY=1 || _STDOUT_IS_TTY=0
    exec > >(tee -a "$CONSOLE_LOG") 2>&1
    _log_file "INFO" "Console capture: $CONSOLE_LOG"

    # Trap cleanup
    trap cleanup_all EXIT INT TERM

    # Load persisted settings (before arg parsing so args can override)
    _load_settings

    # Parse arguments
    _parse_args "$@"

    # ── Relocate session/console logs if -o changed OUTPUT_DIR ──────────
    # LOG_FILE was created in init_common() before args were parsed, so it
    # may be in the default ./reports/ while the user asked for -o elsewhere.
    _relocate_logs_if_needed

    # Apply color settings after parsing (may have been overridden by args)
    init_colors

    if [ "${SERVER_MODE:-0}" -eq 1 ]; then
        # Web server mode
        start_server "${SERVER_PORT:-8080}"

    elif [ "${WATCH_MODE:-0}" -eq 1 ]; then
        # Live monitoring mode
        WATCH_DIR="${INPUT_ARGS[0]:-}"
        _show_banner
        start_watch "$WATCH_DIR"

    elif [ "${FLEET_MODE:-0}" -eq 1 ]; then
        # Fleet analysis mode
        FLEET_DIR="${INPUT_ARGS[0]:-}"
        _show_banner
        log_info "Fleet mode"
        log_info "Session log: $LOG_FILE"
        log_info "Console log: $CONSOLE_LOG"
        run_fleet_analysis "$FLEET_DIR"
        _log_file "INFO" "=== Session complete ==="
        log_info "Full session log: $LOG_FILE"
        log_info "Full console log: $CONSOLE_LOG"

    elif [ "${COMPARE_MODE:-0}" -eq 1 ]; then
        # Comparison mode: two inputs
        COMPARE_BASELINE="${INPUT_ARGS[0]:-}"
        COMPARE_TARGET="${INPUT_ARGS[1]:-}"
        _show_banner
        log_info "Comparison mode"
        log_info "Session log: $LOG_FILE"
        log_info "Console log: $CONSOLE_LOG"
        run_comparison "$COMPARE_BASELINE" "$COMPARE_TARGET"
        _log_file "INFO" "=== Session complete ==="
        log_info "Full session log: $LOG_FILE"
        log_info "Full console log: $CONSOLE_LOG"

    elif [ ${#INPUT_ARGS[@]} -gt 0 ]; then
        # Batch mode: load + analyze + report
        _show_banner
        log_info "Batch mode"
        log_info "Session log: $LOG_FILE"
        log_info "Console log: $CONSOLE_LOG"

        # Load input
        if ! load_input "${INPUT_ARGS[0]}"; then
            log_error "Failed to load input"
            exit 1
        fi

        # Parse
        parse_all_logs

        [ "$QUIET_MODE" -eq 0 ] && show_load_summary
        [ "$QUIET_MODE" -eq 0 ] && show_parse_summary

        # Analyze
        run_standard_analysis
        if [ "$ANALYSIS_MODE" = "deep" ] || [ "${RUN_DEEP:-0}" -eq 1 ]; then
            run_deep_analysis
        fi
        show_analysis_results
        if [ "$ANALYSIS_MODE" = "deep" ] || [ "${RUN_DEEP:-0}" -eq 1 ]; then
            show_deep_results
        fi

        # Auto-generate reports
        generate_reports

        # Final log path reminder
        _log_file "INFO" "=== Session complete ==="
        log_info "Full session log: $LOG_FILE"
        log_info "Full console log: $CONSOLE_LOG"

    else
        # Interactive mode
        _show_banner
        show_main_menu
    fi
}

main "$@"
