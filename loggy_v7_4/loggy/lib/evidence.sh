#!/bin/bash
# evidence.sh — Log snippet extractor
# Loggy v6.0

EVIDENCE_DIR=""

init_evidence() {
    EVIDENCE_DIR="$WORK_DIR/evidence"
    mkdir -p "$EVIDENCE_DIR"
}

# ─── Extract Evidence Snippet ────────────────────────────────────────────────
# Returns evidence file path; stores contextual log lines around a match
# ─── Collect Evidence from a File Path ─────────────────────────────────────
# Lightweight wrapper: takes a file path directly, returns evidence file path
# Args: $1=log_file  $2=pattern  $3=max_lines (default 30)
collect_evidence() {
    local logfile="$1"
    local pattern="$2"
    local max_lines="${3:-30}"

    [ -z "$logfile" ] || [ ! -f "$logfile" ] && return 1
    [ -z "$pattern" ] && return 1

    local context=3
    case "${EVIDENCE_LEVEL:-std}" in
        min)  context=1 ;;
        std)  context=3 ;;
        full) context=8 ;;
    esac

    local ev_file="$EVIDENCE_DIR/collect_${RANDOM}_$$.txt"
    grep -aEn -m"$max_lines" -B"$context" -A"$context" "$pattern" "$logfile" 2>/dev/null > "$ev_file"

    if [ -s "$ev_file" ]; then
        echo "$ev_file"
    else
        rm -f "$ev_file"
        return 1
    fi
}

extract_evidence() {
    local component="$1"   # Component name
    local pattern="$2"     # grep pattern to find
    local label="${3:-evidence}"  # Label for filename
    local context="${4:-3}" # Context lines before/after

    # Adjust context by evidence level
    case "$EVIDENCE_LEVEL" in
        min)  context=1 ;;
        std)  context=3 ;;
        full) context=8 ;;
    esac

    local source_file
    source_file=$(get_log_file "${component}_combined")
    [ -z "$source_file" ] && source_file=$(get_log_file "$component")
    [ -z "$source_file" ] || [ ! -f "$source_file" ] && return 1

    local ev_file="$EVIDENCE_DIR/${component}_${label}_$$.txt"
    local ev_idx=0

    # Find matching lines with context (use -E for extended regex patterns with |)
    # Cap at 200 matches to prevent bloated evidence files
    grep -aEn -m200 -B"$context" -A"$context" "$pattern" "$source_file" 2>/dev/null > "$ev_file"

    if [ -s "$ev_file" ]; then
        echo "$ev_file"
    else
        rm -f "$ev_file"
        return 1
    fi
}

# ─── Extract Time-Window Evidence ────────────────────────────────────────────
# Get all lines from a component within a time window
extract_time_window() {
    local component="$1"
    local start_ts="$2"     # "2026-02-18 15:21:33"
    local end_ts="$3"       # "2026-02-18 15:22:00"
    local label="${4:-timewindow}"

    local source_file
    source_file=$(get_log_file "${component}_combined")
    [ -z "$source_file" ] && source_file=$(get_log_file "$component")
    [ -z "$source_file" ] || [ ! -f "$source_file" ] && return 1

    local ev_file="$EVIDENCE_DIR/${component}_${label}_$$.txt"

    awk -v start="$start_ts" -v end="$end_ts" '
    /^[0-9]{4}-[0-9]{2}-[0-9]{2}/ {
        ts = substr($0, 1, 19)
        if (ts >= start && ts <= end) print
    }
    ' "$source_file" > "$ev_file"

    if [ -s "$ev_file" ]; then
        echo "$ev_file"
    else
        rm -f "$ev_file"
        return 1
    fi
}

# ─── Extract Multi-Source Evidence ───────────────────────────────────────────
# Correlate across multiple components within a time window
extract_cross_ref() {
    local label="$1"
    local start_ts="$2"
    local end_ts="$3"
    shift 3
    local components=("$@")

    local ev_file="$EVIDENCE_DIR/xref_${label}_$$.txt"
    : > "$ev_file"

    for comp in "${components[@]}"; do
        local source_file
        source_file=$(get_log_file "${comp}_combined")
        [ -z "$source_file" ] && source_file=$(get_log_file "$comp")
        [ -z "$source_file" ] || [ ! -f "$source_file" ] && continue

        echo "--- [$comp] ---" >> "$ev_file"
        awk -v start="$start_ts" -v end="$end_ts" '
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}/ {
            ts = substr($0, 1, 19)
            if (ts >= start && ts <= end) print
        }
        ' "$source_file" >> "$ev_file"
        echo "" >> "$ev_file"
    done

    if [ -s "$ev_file" ]; then
        echo "$ev_file"
    else
        rm -f "$ev_file"
        return 1
    fi
}

# ─── Count Pattern Occurrences ───────────────────────────────────────────────
count_pattern() {
    local component="$1" pattern="$2"
    local source_file
    source_file=$(get_log_file "${component}_combined")
    [ -z "$source_file" ] && source_file=$(get_log_file "$component")
    [ -z "$source_file" ] || [ ! -f "$source_file" ] && echo 0 && return
    { grep -aEc "$pattern" "$source_file" 2>/dev/null || true; }
}

# ─── Get First/Last Occurrence ───────────────────────────────────────────────
first_occurrence() {
    local component="$1" pattern="$2"
    local source_file
    source_file=$(get_log_file "${component}_combined")
    [ -z "$source_file" ] && source_file=$(get_log_file "$component")
    [ -z "$source_file" ] || [ ! -f "$source_file" ] && return
    grep -aEm1 "$pattern" "$source_file" 2>/dev/null
}

last_occurrence() {
    local component="$1" pattern="$2"
    local source_file
    source_file=$(get_log_file "${component}_combined")
    [ -z "$source_file" ] && source_file=$(get_log_file "$component")
    [ -z "$source_file" ] || [ ! -f "$source_file" ] && return
    grep -a "$pattern" "$source_file" 2>/dev/null | tail -1
}

# ─── Format Evidence for Display ─────────────────────────────────────────────
display_evidence() {
    local ev_file="$1" max_lines="${2:-20}"

    [ -f "$ev_file" ] || return

    local lines
    lines=$(wc -l < "$ev_file" | tr -d ' ')

    printf "\n  %s┌─ Evidence (%s lines) ─────────────────────%s\n" "${DIM}" "$lines" "${RST}"

    local count=0
    while IFS= read -r line; do
        count=$((count + 1))
        [ "$count" -gt "$max_lines" ] && break

        # Color-code by log level
        local colored="$line"
        if echo "$line" | grep -q '\[E\]'; then
            colored="${RED}${line}${RST}"
        elif echo "$line" | grep -q '\[W\]'; then
            colored="${YLW}${line}${RST}"
        elif echo "$line" | grep -q '\[C\]'; then
            colored="${BRED}${line}${RST}"
        elif echo "$line" | grep -q '^\-\-'; then
            colored="${DIM}${line}${RST}"
        elif echo "$line" | grep -q '^--- \['; then
            colored="${BLD}${CYN}${line}${RST}"
        else
            colored="${GRY}${line}${RST}"
        fi
        printf "  %s│%s %s\n" "${DIM}" "${RST}" "$colored"
    done < "$ev_file"

    if [ "$lines" -gt "$max_lines" ]; then
        printf "  %s│%s %s... (%d more lines)%s\n" "${DIM}" "${RST}" "${GRY}" "$((lines - max_lines))" "${RST}"
    fi
    printf "  %s└──────────────────────────────────────────%s\n" "${DIM}" "${RST}"
}

# ─── Evidence to Markdown ────────────────────────────────────────────────────
evidence_to_markdown() {
    local ev_file="$1" max_lines="${2:-30}"
    [ -f "$ev_file" ] || return

    echo '```'
    head -"$max_lines" "$ev_file"
    local lines
    lines=$(wc -l < "$ev_file" | tr -d ' ')
    [ "$lines" -gt "$max_lines" ] && echo "... ($((lines - max_lines)) more lines)"
    echo '```'
}

# ─── Evidence to HTML ────────────────────────────────────────────────────────
evidence_to_html() {
    local ev_file="$1" max_lines="${2:-30}"
    [ -f "$ev_file" ] || return

    echo '<pre class="evidence">'
    local count=0
    while IFS= read -r line; do
        count=$((count + 1))
        [ "$count" -gt "$max_lines" ] && break
        local escaped
        escaped=$(html_escape "$line")
        # Add CSS classes for coloring
        if echo "$line" | grep -q '\[E\]'; then
            echo "<span class=\"log-error\">$escaped</span>"
        elif echo "$line" | grep -q '\[W\]'; then
            echo "<span class=\"log-warn\">$escaped</span>"
        elif echo "$line" | grep -q '\[C\]'; then
            echo "<span class=\"log-critical\">$escaped</span>"
        elif echo "$line" | grep -q '^--- \['; then
            echo "<span class=\"log-header\">$escaped</span>"
        else
            echo "$escaped"
        fi
    done < "$ev_file"
    local lines
    lines=$(wc -l < "$ev_file" | tr -d ' ')
    [ "$lines" -gt "$max_lines" ] && echo "<span class=\"log-dim\">... ($((lines - max_lines)) more lines)</span>"
    echo '</pre>'
}
