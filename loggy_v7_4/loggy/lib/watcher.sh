#!/bin/bash
# watcher.sh — Live Log Monitoring
# Loggy v6.0 — Phase 10
#
# Tails a log directory, detects changes, matches patterns,
# triggers alerts. Session recording for later analysis.

# ─── Start Watch Mode ────────────────────────────────────────────────────────
start_watch() {
    local watch_dir="$1"

    if [ -z "$watch_dir" ] || [ ! -d "$watch_dir" ]; then
        log_error "Watch directory not found: ${watch_dir:-<none>}"
        log_info "Usage: --watch <directory>"
        return 1
    fi

    local session_file="${OUTPUT_DIR}/watch_$(date +%Y%m%d_%H%M%S).log"
    mkdir -p "$OUTPUT_DIR"

    printf "\n"
    printf "  %s╔══════════════════════════════════════════════╗%s\n" "${CYN}" "${RST}"
    printf "  %s║%s  %s⚡ Live Monitor%s                              %s║%s\n" "${CYN}" "${RST}" "${BLD}" "${RST}" "${CYN}" "${RST}"
    printf "  %s╚══════════════════════════════════════════════╝%s\n" "${CYN}" "${RST}"
    printf "\n"
    printf "  %sWatching:%s %s\n" "${BLD}" "${RST}" "$watch_dir"
    printf "  %sSession:%s  %s\n" "${BLD}" "${RST}" "$session_file"
    printf "  %sPress Ctrl+C to stop%s\n\n" "${GRY}" "${RST}"
    printf "  %s─── Alert Feed ────────────────────────────────%s\n\n" "${DIM}" "${RST}"

    # Session header
    {
        printf "# IoTecha Live Monitor Session\n"
        printf "# Started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf "# Directory: %s\n\n" "$watch_dir"
    } > "$session_file"

    # Track file positions
    local pos_dir
    pos_dir=$(mktemp -d "${TMPDIR:-/tmp}/iotwatch.XXXXXX")

    # Initialize positions for existing files
    shopt -s nullglob 2>/dev/null; for f in "$watch_dir"/*.log "$watch_dir"/*.txt; do
        [ -f "$f" ] || continue
        local bname
        bname=$(basename "$f")
        wc -l < "$f" > "$pos_dir/$bname.pos" 2>/dev/null
    done

    local alert_count=0 line_count=0
    local poll_interval=2

    # Check for inotifywait
    local use_inotify=0
    if command -v inotifywait >/dev/null 2>&1; then
        use_inotify=1
    fi

    # Trap cleanup
    trap '_watch_cleanup "$pos_dir" "$session_file" "$alert_count" "$line_count"' INT TERM

    if [ "$use_inotify" -eq 1 ]; then
        _watch_inotify "$watch_dir" "$pos_dir" "$session_file"
    else
        _watch_poll "$watch_dir" "$pos_dir" "$session_file" "$poll_interval"
    fi
}

# ─── Poll-based watcher ─────────────────────────────────────────────────────
_watch_poll() {
    local watch_dir="$1" pos_dir="$2" session_file="$3" interval="${4:-2}"
    local alert_count=0 line_count=0

    while true; do
        shopt -s nullglob 2>/dev/null; for f in "$watch_dir"/*.log "$watch_dir"/*.txt; do
            [ -f "$f" ] || continue
            local bname
            bname=$(basename "$f")
            local pos_file="$pos_dir/$bname.pos"
            local old_lines=0

            if [ -f "$pos_file" ]; then
                old_lines=$(cat "$pos_file" 2>/dev/null)
                old_lines="${old_lines:-0}"
            fi

            local cur_lines
            cur_lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
            cur_lines="${cur_lines:-0}"

            if [ "$cur_lines" -gt "$old_lines" ]; then
                local new_count=$((cur_lines - old_lines))
                tail -n "$new_count" "$f" | while IFS= read -r line; do
                    line_count=$((line_count + 1))
                    _watch_process_line "$line" "$bname" "$session_file"
                done
                echo "$cur_lines" > "$pos_file"
            fi
        done

        sleep "$interval"
    done
}

# ─── inotifywait-based watcher ──────────────────────────────────────────────
_watch_inotify() {
    local watch_dir="$1" pos_dir="$2" session_file="$3"

    inotifywait -m -r -e modify --format '%w%f' "$watch_dir" 2>/dev/null | while IFS= read -r filepath; do
        [ -f "$filepath" ] || continue
        local bname
        bname=$(basename "$filepath")

        case "$bname" in
            *.log|*.txt) ;;
            *) continue ;;
        esac

        local pos_file="$pos_dir/$bname.pos"
        local old_lines=0
        [ -f "$pos_file" ] && old_lines=$(cat "$pos_file" 2>/dev/null)
        old_lines="${old_lines:-0}"

        local cur_lines
        cur_lines=$(wc -l < "$filepath" 2>/dev/null | tr -d ' ')
        cur_lines="${cur_lines:-0}"

        if [ "$cur_lines" -gt "$old_lines" ]; then
            local new_count=$((cur_lines - old_lines))
            tail -n "$new_count" "$filepath" | while IFS= read -r line; do
                _watch_process_line "$line" "$bname" "$session_file"
            done
            echo "$cur_lines" > "$pos_file"
        fi
    done
}

# ─── Process a single log line ───────────────────────────────────────────────
_watch_process_line() {
    local line="$1" source="$2" session_file="$3"

    # Record to session
    printf "%s | %s | %s\n" "$(date '+%H:%M:%S')" "$source" "$line" >> "$session_file"

    # Detect log level
    local level=""
    case "$line" in
        *"[C]"*|*CRITICAL*) level="C" ;;
        *"[E]"*|*ERROR*)    level="E" ;;
        *"[W]"*|*WARN*)     level="W" ;;
        *"[N]"*|*NOTICE*)   level="N" ;;
        *"[I]"*|*INFO*)     level="I" ;;
    esac

    # Pattern matching for alerts
    local alert=""
    local alert_sev=""

    # Critical patterns
    if echo "$line" | grep -qi 'panic\|segfault\|core dump\|fatal'; then
        alert="SYSTEM CRITICAL"; alert_sev="CRITICAL"
    elif echo "$line" | grep -qi 'DISCONNECTED\|connection.*lost\|link.*down'; then
        alert="CONNECTION LOST"; alert_sev="HIGH"
    elif echo "$line" | grep -qi 'PPP.*fail\|ppp.*down\|modem.*error'; then
        alert="PPP FAILURE"; alert_sev="HIGH"
    elif echo "$line" | grep -qi 'cert.*fail\|certificate.*error'; then
        alert="CERT ERROR"; alert_sev="MEDIUM"
    elif echo "$line" | grep -qi 'reboot\|watchdog.*reset\|restart'; then
        alert="REBOOT DETECTED"; alert_sev="HIGH"
    fi

    # Display based on level/alert
    local ts
    ts=$(date '+%H:%M:%S')

    if [ -n "$alert" ]; then
        # Alert line — prominent display with bell
        local acolor="${RED}"
        [ "$alert_sev" = "MEDIUM" ] && acolor="${YLW}"
        printf "  %s%s ⚠ [%s] %s%s\n" "$acolor" "$ts" "$alert" "$source" "${RST}"
        printf "  %s  → %s%s\n" "${GRY}" "$(echo "$line" | cut -c1-120)" "${RST}"
        printf "  %s%s%s >> %s\n" "$acolor" "$alert_sev" "${RST}" "$line" >> "$session_file.alerts"
        # Terminal bell for critical/high
        [ "$alert_sev" = "CRITICAL" ] || [ "$alert_sev" = "HIGH" ] && printf '\a'
    elif [ "$level" = "C" ] || [ "$level" = "E" ]; then
        printf "  %s%s%s [%s] %s%s %s%s\n" "${RED}" "$ts" "${RST}" "$level" "${CYN}" "$source" "$(echo "$line" | cut -c1-100)" "${RST}"
    elif [ "$level" = "W" ]; then
        printf "  %s%s%s [%s] %s%s %s%s\n" "${YLW}" "$ts" "${RST}" "$level" "${CYN}" "$source" "$(echo "$line" | cut -c1-100)" "${RST}"
    fi
    # Info lines suppressed in alert feed (too noisy)
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────
_watch_cleanup() {
    local pos_dir="$1" session_file="$2" alerts="${3:-0}" lines="${4:-0}"
    rm -rf "$pos_dir"

    printf "\n\n  %s─── Monitor Stopped ────────────────────────────%s\n" "${DIM}" "${RST}"
    printf "  %sSession saved:%s %s\n" "${BLD}" "${RST}" "$session_file"

    if [ -f "${session_file}.alerts" ]; then
        local alert_count
        alert_count=$(wc -l < "${session_file}.alerts" 2>/dev/null | tr -d ' ')
        printf "  %sAlerts:%s %s\n" "${BLD}" "${RST}" "${alert_count:-0}"
    fi

    printf "\n"
    trap - INT TERM
}
