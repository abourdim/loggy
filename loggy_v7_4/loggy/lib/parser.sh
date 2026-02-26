#!/bin/bash
# parser.sh — Core log parser engine
# Loggy v6.0
# Handles IoTecha app log format, syslog format, kern.log format, properties files

# ─── Parse IoTecha App Log Line ──────────────────────────────────────────────
# Format: "2026-02-18 17:33:29.617 [N] component: message"
# Output: TIMESTAMP|LEVEL|COMPONENT|MESSAGE
parse_iotecha_line() {
    echo "$1" | awk '{
        if (match($0, /^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+) \[([A-Z])\] ([^:]+): (.*)$/, m)) {
            printf "%s|%s|%s|%s\n", m[1], m[2], m[3], m[4]
        }
    }'
}

# ─── Parse Syslog Line ──────────────────────────────────────────────────────
# Format: "Feb 17 15:23:00 buildroot kernel: [    0.000000] message"
# Output: TIMESTAMP|LEVEL|COMPONENT|MESSAGE
parse_syslog_line() {
    echo "$1" | awk '{
        if (match($0, /^([A-Z][a-z]+ [0-9]+ [0-9]{2}:[0-9]{2}:[0-9]{2}) ([^ ]+) ([^:]+): (.*)$/, m)) {
            printf "%s|I|%s|%s\n", m[1], m[3], m[4]
        }
    }'
}

# ─── Bulk Parse a Log File ───────────────────────────────────────────────────
# Creates parsed output: TIMESTAMP|LEVEL|COMPONENT|MESSAGE per line
parse_log_file() {
    local input="$1" output="$2" format="${3:-auto}"

    if [ ! -f "$input" ]; then
        log_warn "File not found: $input"
        return 1
    fi

    # Auto-detect format from first non-empty line
    if [ "$format" = "auto" ]; then
        local first_line
        first_line=$(head -20 "$input" | grep -m1 .)
        if echo "$first_line" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+ \[[A-Z]\]'; then
            format="iotecha"
        elif echo "$first_line" | grep -qE '^[A-Z][a-z]+ [0-9]+ [0-9]{2}:[0-9]{2}:[0-9]{2}'; then
            format="syslog"
        else
            format="generic"
        fi
    fi

    case "$format" in
        iotecha)
            _parse_iotecha_file "$input" "$output"
            ;;
        syslog)
            _parse_syslog_file "$input" "$output"
            ;;
        generic)
            _parse_generic_file "$input" "$output"
            ;;
    esac
    return 0
}

_parse_iotecha_file() {
    local input="$1" output="$2"
    awk '
    /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+ \[[A-Z]\]/ {
        ts = substr($0, 1, 23)
        level_start = index($0, "[")
        level = substr($0, level_start+1, 1)
        rest = substr($0, level_start+4)
        colon_pos = index(rest, ":")
        if (colon_pos > 0) {
            comp = substr(rest, 1, colon_pos-1)
            msg = substr(rest, colon_pos+2)
        } else {
            comp = "unknown"
            msg = rest
        }
        # Trim whitespace
        gsub(/^[ \t]+|[ \t]+$/, "", comp)
        gsub(/^[ \t]+|[ \t]+$/, "", msg)
        printf "%s|%s|%s|%s\n", ts, level, comp, msg
    }
    ' "$input" > "$output"
}

_parse_syslog_file() {
    local input="$1" output="$2"
    # Need to figure out the year from context (syslog doesn't include year)
    local year
    year=$(date '+%Y')

    awk -v year="$year" '
    /^[A-Z][a-z]+ [0-9]+ [0-9]{2}:[0-9]{2}:[0-9]{2}/ {
        # Extract month day time
        month = $1
        day = $2
        time = $3
        host = $4

        # Convert month name to number
        m = (index("JanFebMarAprMayJunJulAugSepOctNovDec", month) + 2) / 3

        # Reconstruct ISO timestamp
        ts = sprintf("%s-%02d-%02d %s.000", year, m, day+0, time)

        # Component is field after host until colon
        rest = ""
        for (i=5; i<=NF; i++) rest = rest (i>5?" ":"") $i
        colon_pos = index(rest, ":")
        if (colon_pos > 0) {
            comp = substr(rest, 1, colon_pos-1)
            msg = substr(rest, colon_pos+2)
        } else {
            comp = rest
            msg = ""
        }
        gsub(/^[ \t]+|[ \t]+$/, "", comp)
        gsub(/^[ \t]+|[ \t]+$/, "", msg)

        # Detect severity from content
        level = "I"
        if (msg ~ /[Ee]rror|[Ff]ail|FAIL|panic|PANIC|Oops/) level = "E"
        else if (msg ~ /[Ww]arn|WARNING/) level = "W"

        printf "%s|%s|%s|%s\n", ts, level, comp, msg
    }
    ' "$input" > "$output"
}

_parse_generic_file() {
    local input="$1" output="$2"
    # Best-effort: treat each line as a message
    awk '
    {
        level = "I"
        if ($0 ~ /[Ee]rror|[Ff]ail|FAIL/) level = "E"
        else if ($0 ~ /[Ww]arn|WARNING/) level = "W"
        printf "0000-00-00 00:00:00.000|%s|generic|%s\n", level, $0
    }
    ' "$input" > "$output"
}

# ─── Parse Properties File ──────────────────────────────────────────────────
# Outputs: KEY=VALUE pairs with ${} substitution resolved
parse_properties() {
    local input="$1" output="$2"

    if [ ! -f "$input" ]; then
        return 1
    fi

    # First pass: collect all key=value, stripping comments
    awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /=/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        # Handle line continuations
        key = val = ""
        eq = index($0, "=")
        if (eq > 0) {
            key = substr($0, 1, eq-1)
            val = substr($0, eq+1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (key != "") print key "=" val
        }
    }
    ' "$input" > "$output"

    # Second pass: resolve ${} references (simple one-level)
    if grep -q '${' "$output" 2>/dev/null; then
        local tmp="${output}.tmp"
        while IFS='=' read -r key val; do
            while [[ "$val" == *'${'*'}'* ]]; do
                local ref="${val#*\$\{}"
                ref="${ref%%\}*}"
                local ref_val
                ref_val=$(grep "^${ref}=" "$output" 2>/dev/null | head -1 | cut -d= -f2-)
                val="${val/\$\{${ref}\}/${ref_val}}"
            done
            echo "${key}=${val}"
        done < "$output" > "$tmp"
        mv "$tmp" "$output"
    fi
    return 0
}

# ─── Parse info_commands.txt ─────────────────────────────────────────────────
parse_info_commands() {
    local input="$1"
    [ -f "$input" ] || return 1

    # Extract structured data from info_commands.txt
    awk '
    /^[a-z_]/ && !/^result:/ && !/^stdout:/ && !/^stderr:/ {
        cmd = $0
        next
    }
    /^stdout:/ {
        val = substr($0, 9)
        if (cmd != "" && val != "") {
            gsub(/[[:space:]]+$/, "", val)
            print cmd "|" val
        }
    }
    ' "$input"
}

# ─── Bulk Parse All Loaded Logs ──────────────────────────────────────────────
parse_all_logs() {
    local parsed_dir="$WORK_DIR/parsed"
    mkdir -p "$parsed_dir"

    local count=0 total
    total=$(grep -v "^config:\|_combined\|versions_json\|fw_version\|build_info\|info_commands" "$WORK_DIR/log_files.idx" 2>/dev/null | wc -l | tr -d ' ')

    while IFS='|' read -r comp path; do
        # Skip configs, combined (we parse primary), metadata files
        [[ "$comp" == config:* ]] && continue
        [[ "$comp" == *_combined* ]] && continue
        [[ "$comp" == "versions_json" || "$comp" == "fw_version" || "$comp" == "build_info" || "$comp" == "info_commands" ]] && continue

        local out="$parsed_dir/${comp}.parsed"

        case "$comp" in
            kern|syslog|auth)
                parse_log_file "$path" "$out" "syslog"
                ;;
            *)
                parse_log_file "$path" "$out" "auto"
                ;;
        esac
        count=$((count + 1))
        progress_bar "$count" "$total" "Parsing"
    done < "$WORK_DIR/log_files.idx"

    # Parse combined logs for analysis (these have full history)
    while IFS='|' read -r comp path; do
        [[ "$comp" == *_combined* ]] || continue
        local base="${comp%_combined}"
        local out="$parsed_dir/${base}_full.parsed"
        parse_log_file "$path" "$out" "auto"
    done < "$WORK_DIR/log_files.idx"

    # Parse properties files
    local props_dir="$WORK_DIR/properties"
    mkdir -p "$props_dir"
    while IFS='|' read -r comp path; do
        [[ "$comp" == config:* ]] || continue
        local name="${comp#config:}"
        parse_properties "$path" "$props_dir/${name}.props"
    done < "$WORK_DIR/log_files.idx"

    # Parse info_commands
    local info_file
    info_file=$(get_log_file "info_commands")
    if [ -n "$info_file" ] && [ -f "$info_file" ]; then
        parse_info_commands "$info_file" > "$WORK_DIR/info_commands.parsed"
    fi

    log_ok "Parsed $count log files"
    add_metric "parsed_count" "$count"
}

# ─── Query Parsed Data ──────────────────────────────────────────────────────
# Get all errors from a component's parsed log
get_errors() {
    local comp="$1" level="${2:-E}"
    local parsed="$WORK_DIR/parsed/${comp}.parsed"
    local parsed_full="$WORK_DIR/parsed/${comp}_full.parsed"

    # Prefer full (combined) log if available
    local target="$parsed"
    [ -f "$parsed_full" ] && target="$parsed_full"
    [ -f "$target" ] || return

    grep "|${level}|" "$target" 2>/dev/null
}

# Get all lines from a component
get_parsed_log() {
    local comp="$1"
    local parsed="$WORK_DIR/parsed/${comp}.parsed"
    local parsed_full="$WORK_DIR/parsed/${comp}_full.parsed"
    local target="$parsed"
    [ -f "$parsed_full" ] && target="$parsed_full"
    [ -f "$target" ] && cat "$target"
}

# Count errors per level for a component
count_errors_by_level() {
    local comp="$1"
    local parsed="$WORK_DIR/parsed/${comp}.parsed"
    local parsed_full="$WORK_DIR/parsed/${comp}_full.parsed"
    local target="$parsed"
    [ -f "$parsed_full" ] && target="$parsed_full"
    [ -f "$target" ] || return

    awk -F'|' '{count[$2]++} END {for (l in count) printf "%s=%d\n", l, count[l]}' "$target"
}

# Get property value
get_property() {
    local config_name="$1" key="$2"
    local props_file="$WORK_DIR/properties/${config_name}.props"
    [ -f "$props_file" ] || return
    grep "^${key}=" "$props_file" 2>/dev/null | head -1 | cut -d= -f2-
}

# Search all parsed logs
search_all_parsed() {
    local pattern="$1" level_filter="${2:-}" comp_filter="${3:-}"
    local parsed_dir="$WORK_DIR/parsed"

    for f in "$parsed_dir"/*.parsed; do
        [ -f "$f" ] || continue
        case "$f" in *_full.parsed) continue ;; esac
        local comp
        comp=$(basename "$f" .parsed)
        [ -n "$comp_filter" ] && [ "$comp" != "$comp_filter" ] && continue

        if [ -n "$level_filter" ]; then
            grep "|${level_filter}|" "$f" 2>/dev/null | grep -i "$pattern"
        else
            grep -i "$pattern" "$f" 2>/dev/null
        fi | while IFS='|' read -r ts lvl component msg; do
            printf "%s|%s|%s|%s|%s\n" "$ts" "$lvl" "$comp" "$component" "$msg"
        done
    done
}

# ─── Show Parse Summary ─────────────────────────────────────────────────────
show_parse_summary() {
    print_section "Parse Summary"

    local parsed_dir="$WORK_DIR/parsed"
    local total_lines=0 total_errors=0 total_warnings=0

    printf "  %s%-22s %6s %6s %6s %6s%s\n" "${GRY}" "Component" "Lines" "Errors" "Warns" "Info" "${RST}"
    print_divider

    for f in "$parsed_dir"/*.parsed; do
        [ -f "$f" ] || continue
        [[ "$(basename "$f")" == *_full.parsed ]] && continue

        local comp
        comp=$(basename "$f" .parsed)
        local lines crits errors warns notices infos
        lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ') || lines=0
        lines=${lines:-0}
        crits=0; errors=0; warns=0; notices=0; infos=0
        if [ -f "$f" ]; then
            crits=$(grep -aFc '|C|' "$f" 2>/dev/null) || crits=0
            errors=$(grep -aFc '|E|' "$f" 2>/dev/null) || errors=0
            warns=$(grep -aFc '|W|' "$f" 2>/dev/null) || warns=0
            notices=$(grep -aFc '|N|' "$f" 2>/dev/null) || notices=0
            infos=$(grep -aFc '|I|' "$f" 2>/dev/null) || infos=0
        fi

        # Merge: Errors = E+C, Info = I+N
        local err_total=$((errors + crits))
        local info_total=$((infos + notices))

        local err_color=""
        [ "$err_total" -gt 0 ] && err_color="${RED}"
        [ "$crits" -gt 0 ] && err_color="${RED}${BLD}"
        local warn_color=""
        [ "$warns" -gt 0 ] && warn_color="${YLW}"

        # Show error count (crits are included in err_total)
        local err_display="$err_total"

        printf "  %-22s %6d %s%6d%s %s%6d%s %6d\n" \
            "$comp" "$lines" "$err_color" "$err_display" "${RST}" \
            "$warn_color" "$warns" "${RST}" "$info_total"

        total_lines=$((total_lines + lines))
        total_errors=$((total_errors + err_total))
        total_warnings=$((total_warnings + warns))
    done

    print_divider
    printf "  %s%-22s %6d %s%6d%s %s%6d%s%s\n" \
        "${BLD}" "TOTAL" "$total_lines" "${RED}" "$total_errors" "${RST}${BLD}" \
        "${YLW}" "$total_warnings" "${RST}" ""

    add_metric "total_parsed_lines" "$total_lines"
    add_metric "total_errors" "$total_errors"
    add_metric "total_warnings" "$total_warnings"
    echo ""
}
