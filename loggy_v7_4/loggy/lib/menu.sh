#!/bin/bash
# menu.sh — TUI menu system
# Loggy v6.0

# ─── Menu History ───────────────────────────────────────────────────────────
_MENU_LAST=""
_MENU_HISTORY=()
_MENU_LABELS=(
    [1]="Load logs"
    [2]="Run standard analysis"
    [3]="Run deep analysis"
    [4]="Search logs"
    [5]="Select / view log"
    [6]="View results"
    [7]="Generate reports"
    [8]="Settings"
    [9]="Check install"
)

_menu_track() {
    local choice="$1"
    _MENU_LAST="$choice"
    _MENU_HISTORY+=("$(date +%H:%M:%S) [$choice] ${_MENU_LABELS[$choice]:-$choice}")
}

_menu_item() {
    local num="$1" label="$2" extra="${3:-}"
    if [ "$_MENU_LAST" = "$num" ]; then
        printf "  %s▸ %s%s  %s%s%s%s\n" "${YLW}" "${BLD}${CYN}" "$num" "${RST}${BLD}" "$label" "${RST}" "${extra:+ $extra}"
    else
        printf "  %s  %s%s  %s%s\n" " " "${BLD}${CYN}" "$num" "${RST}" "$label${extra:+ $extra}"
    fi
}

# ─── Last Path Persistence ──────────────────────────────────────────────────
_LAST_PATH_FILE="${HOME}/.iotecha_last_path"
_SETTINGS_FILE="${HOME}/.iotecha_settings"

_save_last_path() {
    [ -n "$1" ] && echo "$1" > "$_LAST_PATH_FILE" 2>/dev/null
}

_get_last_path() {
    [ -f "$_LAST_PATH_FILE" ] && cat "$_LAST_PATH_FILE" 2>/dev/null
}

# Persist settings to ~/.iotecha_settings
_save_settings() {
    {
        echo "EVIDENCE_LEVEL=${EVIDENCE_LEVEL:-std}"
        echo "USE_COLOR=${USE_COLOR:-1}"
        echo "OUTPUT_DIR=${OUTPUT_DIR:-./reports}"
        echo "LOG_LEVEL=${LOG_LEVEL:-2}"
    } > "$_SETTINGS_FILE" 2>/dev/null
}

# Load settings from ~/.iotecha_settings
_load_settings() {
    [ -f "$_SETTINGS_FILE" ] || return
    while IFS="=" read -r key val; do
        case "$key" in
            EVIDENCE_LEVEL) EVIDENCE_LEVEL="$val" ;;
            USE_COLOR)      USE_COLOR="$val"; init_colors ;;
            OUTPUT_DIR)     OUTPUT_DIR="$val" ;;
            LOG_LEVEL)      LOG_LEVEL="$val" ;;
        esac
    done < "$_SETTINGS_FILE"
}

# ─── Sanitize + Normalize Input Path ────────────────────────────────────────
# Handles:
#   • Strip surrounding quotes and trailing whitespace
#   • ~ expansion
#   • Windows backslash paths: C:\Users\... → /c/Users/...  (MSYS2/Git Bash)
#   • Windows drive paths pasted into MSYS2: C:/Users/... → /c/Users/...
#   • cygpath conversion when available
_clean_path() {
    local p="$1"

    # Strip surrounding quotes and trailing whitespace
    p=$(printf '%s' "$p" | tr -d "\"'")
    p="${p%"${p##*[! ]}"}"

    # Tilde expansion
    p="${p/#\~/$HOME}"

    # Windows backslash → forward slash
    p="${p//\\//}"

    # cygpath — most reliable on MSYS2/Cygwin
    if command -v cygpath >/dev/null 2>&1; then
        local converted
        converted=$(cygpath -u "$p" 2>/dev/null)
        [ -n "$converted" ] && p="$converted"
    else
        # Manual: C:/Users/... or C:\Users\... → /c/Users/...
        case "$p" in
            [A-Za-z]:*)
                local drive="${p:0:1}"
                drive="${drive,,}"          # lowercase
                p="/${drive}${p:2}"
                ;;
        esac
    fi

    echo "$p"
}

# ─── Load + Parse Helper ────────────────────────────────────────────────────
_do_load() {
    local path="$1"
    path=$(_clean_path "$path")
    [ -z "$path" ] && return 1
    if load_input "$path"; then
        parse_all_logs
        show_load_summary
        show_parse_summary
        _save_last_path "$path"
        return 0
    else
        return 1
    fi
}

# ─── Menu Display ────────────────────────────────────────────────────────────
show_main_menu() {
    while true; do
        printf "\n"
        print_header "$ANALYZER_NAME v$ANALYZER_VERSION"
        local loaded=""
        [ -n "$DEVICE_ID" ] && [ "$DEVICE_ID" != "unknown" ] && loaded=" ${GRN}[IOTMP${DEVICE_ID}]${RST}"

        printf "\n"
        _menu_item 1 "Load logs" "$loaded"
        _menu_item 2 "Run standard analysis"
        _menu_item 3 "Run deep analysis"
        _menu_item 4 "Search logs"
        _menu_item 5 "Select / view log"
        _menu_item 6 "View results"
        _menu_item 7 "Generate reports"
        _menu_item 8 "Compare / regression"
        _menu_item 9 "Settings"
        _menu_item 0 "Check install / system info"
        printf "    %sq%s  Quit\n" "${BLD}${RED}" "${RST}"
        printf "    %sh%s  History\n" "${DIM}" "${RST}"

        # Show last action
        if [ -n "$_MENU_LAST" ]; then
            printf "\n  %sLast: [%s] %s%s\n" "${DIM}" "$_MENU_LAST" "${_MENU_LABELS[$_MENU_LAST]:-}" "${RST}"
        fi

        printf "\n  %sChoice:%s " "${BLD}" "${RST}"

        local choice
        read -r choice
        case "$choice" in
            1) _menu_track 1; _menu_load ;;
            2)
                if _check_loaded; then
                    _menu_track 2
                    ANALYSIS_MODE="standard"
                    run_standard_analysis
                    generate_reports
                    show_analysis_results
                fi
                ;;
            3)
                if _check_loaded; then
                    _menu_track 3
                    ANALYSIS_MODE="deep"
                    run_standard_analysis
                    run_deep_analysis
                    generate_reports
                    show_analysis_results
                    show_deep_results
                fi
                ;;
            4) _check_loaded && { _menu_track 4; _menu_search; } ;;
            5) _check_loaded && { _menu_track 5; _menu_select_log; } ;;
            6)
                if [ -s "$ISSUES_FILE" ]; then
                    _menu_track 6
                    show_analysis_results
                else
                    log_warn "No analysis results. Run analysis first (option 2)."
                fi
                ;;
            7)
                if [ -s "$ISSUES_FILE" ] || [ -s "$METRICS_FILE" ] || [ -s "$STATUS_FILE" ]; then
                    _menu_track 7
                    _menu_reports
                else
                    log_warn "No analysis results to report. Run analysis first (option 2)."
                fi
                ;;
            8) _menu_track 8; _menu_compare ;;
            9) _menu_track 9; _menu_settings ;;
            0)
                _menu_track 0
                print_header "System / Install Check"
                check_dependencies
                ;;
            h|H|history)
                _menu_show_history
                ;;
            q|Q|quit|exit)
                printf "\n  %sGoodbye!%s\n\n" "${CYN}" "${RST}"
                return 0
                ;;
            *)
                log_warn "Invalid choice: $choice"
                ;;
        esac
    done
}

# ─── Check Loaded ────────────────────────────────────────────────────────────
_check_loaded() {
    local lcount=0
    [ -f "$WORK_DIR/log_files.idx" ] && lcount=$(wc -l < "$WORK_DIR/log_files.idx" 2>/dev/null | tr -d ' ')
    if [ "$(safe_int "$lcount")" -eq 0 ]; then
        log_warn "No logs loaded. Please load logs first (option 1)."
        return 1
    fi
    return 0
}

# --- Session History ---
_menu_show_history() {
    print_section "Session History"
    if [ ${#_MENU_HISTORY[@]} -eq 0 ]; then
        printf "\n  %s(no actions yet)%s\n" "${DIM}" "${RST}"
    else
        printf "\n"
        printf "  %s#   Time      Action%s\n" "${DIM}" "${RST}"
        printf "  %s--- -------- ----------------------------------------%s\n" "${DIM}" "${RST}"
        local i
        for i in "${!_MENU_HISTORY[@]}"; do
            local num=$((i + 1))
            printf "  %s%-3d%s %s\n" "${BLD}" "$num" "${RST}" "${_MENU_HISTORY[$i]}"
        done
        printf "\n  %s%d action(s) this session%s\n" "${DIM}" "${#_MENU_HISTORY[@]}" "${RST}"
    fi

    # Session findings summary
    printf "\n"
    if [ -n "${DEVICE_ID:-}" ] && [ "$DEVICE_ID" != "unknown" ]; then
        printf "  %sLoaded device:%s IOTMP%s  FW:%s\n"             "${DIM}" "${RST}" "$DEVICE_ID" "${FW_VERSION:-unknown}"
    fi
    if [ -f "${ISSUES_FILE:-}" ] && [ -s "$ISSUES_FILE" ]; then
        local total crit high med low
        total=$(issue_count 2>/dev/null || echo 0)
        crit=$(issue_count_by_severity  CRITICAL 2>/dev/null || echo 0)
        high=$(issue_count_by_severity  HIGH     2>/dev/null || echo 0)
        med=$(issue_count_by_severity   MEDIUM   2>/dev/null || echo 0)
        low=$(issue_count_by_severity   LOW      2>/dev/null || echo 0)
        printf "  %sIssues found:%s %s%d total%s" "${DIM}" "${RST}" "${BLD}" "$total" "${RST}"
        [ "$crit" -gt 0 ] && printf "  %sCRIT:%d%s" "${RED}${BLD}"   "$crit" "${RST}"
        [ "$high" -gt 0 ] && printf "  %sHIGH:%d%s" "${YLW}${BLD}"  "$high" "${RST}"
        [ "$med"  -gt 0 ] && printf "  %sMED:%d%s"  "${YLW}"        "$med"  "${RST}"
        [ "$low"  -gt 0 ] && printf "  %sLOW:%d%s"  "${DIM}"        "$low"  "${RST}"
        printf "\n"
    fi
    if [ -n "${HEALTH_SCORE:-}" ]; then
        local hcolor="$RED"
        [ "${HEALTH_SCORE:-0}" -ge 55 ] && hcolor="$YLW"
        [ "${HEALTH_SCORE:-0}" -ge 75 ] && hcolor="$GRN"
        printf "  %sHealth score:%s %s%d/100%s  Grade: %s%s%s\n"             "${DIM}" "${RST}" "${BLD}${hcolor}" "${HEALTH_SCORE:-0}" "${RST}"             "${BLD}${hcolor}" "${HEALTH_GRADE:-?}" "${RST}"
    fi
    if [ -f "${REPORT_FILE:-}" ]; then
        printf "  %sLast report:%s %s\n" "${DIM}" "${RST}" "$REPORT_FILE"
    fi

    printf "\n  Press Enter to continue..."
    read -r
}

# ─── 1: Load Logs Submenu ───────────────────────────────────────────────────
_menu_load() {
    local last_path
    last_path=$(_get_last_path)

    print_section "Load Logs"

    # Show last path option if available
    if [ -n "$last_path" ]; then
        local last_exists=""
        if [ -f "$last_path" ] || [ -d "$last_path" ]; then
            last_exists="${GRN}(exists)${RST}"
        else
            last_exists="${RED}(not found)${RST}"
        fi
        printf "\n  %s1%s  Reload last: %s%s%s %s\n" "${BLD}${CYN}" "${RST}" "${BLD}" "$last_path" "${RST}" "$last_exists"
    fi
    printf "  %s2%s  Enter path to RACC zip\n" "${BLD}${CYN}" "${RST}"
    printf "  %s3%s  Enter path to log directory\n" "${BLD}${CYN}" "${RST}"
    printf "  %s4%s  Scan current directory for zips\n" "${BLD}${CYN}" "${RST}"
    printf "  %sb%s  Back\n" "${BLD}" "${RST}"
    printf "\n  %sChoice:%s " "${BLD}" "${RST}"

    local choice
    read -r choice
    case "$choice" in
        1)
            if [ -n "$last_path" ]; then
                if [ -f "$last_path" ] || [ -d "$last_path" ]; then
                    _do_load "$last_path"
                else
                    log_error "Last path no longer exists: $last_path"
                fi
            else
                log_warn "No previous path saved."
            fi
            ;;
        2)
            printf "  %sPath to RACC zip:%s " "${GRY}" "${RST}"
            local p; read -r p
            [ -n "$p" ] && _do_load "$p"
            ;;
        3)
            printf "  %sPath to log directory:%s " "${GRY}" "${RST}"
            local d; read -r d
            d=$(_clean_path "$d")
            if [ -n "$d" ] && [ -d "$d" ]; then
                _do_load "$d"
            elif [ -n "$d" ]; then
                log_error "Not a directory: $d"
            fi
            ;;
        4) _menu_scan_dir ;;
        b|B) return ;;
    esac
}

# ─── Archive format list (used by scan and loader) ───────────────────────────
_ARCHIVE_EXTS="zip tar.gz tgz tar.bz2 tbz2 tar.xz txz 7z rar"

# Check if a filename matches a supported archive extension
_is_archive() {
    local fn="$1"
    local ext
    for ext in $_ARCHIVE_EXTS; do
        case "$fn" in *."$ext") return 0 ;; esac
    done
    return 1
}

# _find_recursive DIR TYPE PATTERN
# Recursive file/dir finder. Tries: find → Python os.walk → deep glob (8 lvl)
# TYPE: f=file, d=directory. PATTERN: shell glob e.g. "*.log" or "aux"
_find_recursive() {
    local dir="$1" ftype="$2" pattern="$3"

    # 1. find (Linux/macOS/WSL)
    if command -v find >/dev/null 2>&1; then
        local out rc
        out=$(find "$dir" -type "$ftype" -name "$pattern" 2>/dev/null)
        rc=$?
        if [ $rc -eq 0 ] && [ -n "$out" ]; then
            echo "$out"
            return
        fi
    fi

    # 2. Python os.walk (MSYS2 / Git Bash where find is broken)
    local pycmd=""
    command -v python3 >/dev/null 2>&1 && pycmd="python3"
    [ -z "$pycmd" ] && command -v python >/dev/null 2>&1 && pycmd="python"
    if [ -n "$pycmd" ]; then
        $pycmd -c "
import sys, os, fnmatch
root=sys.argv[1]; ftype=sys.argv[2]; pat=sys.argv[3]
for dp, dirs, files in os.walk(root):
    items = files if ftype=='f' else dirs
    for name in items:
        if fnmatch.fnmatch(name, pat):
            print(os.path.join(dp, name))
" "$dir" "$ftype" "$pattern" 2>/dev/null
        return
    fi

    # 3. Deep glob fallback (8 levels)
    local f
    for f in \
        "$dir"/$pattern \
        "$dir"/*/$pattern \
        "$dir"/*/*/$pattern \
        "$dir"/*/*/*/$pattern \
        "$dir"/*/*/*/*/$pattern \
        "$dir"/*/*/*/*/*/$pattern \
        "$dir"/*/*/*/*/*/*/$pattern \
        "$dir"/*/*/*/*/*/*/*/$pattern; do
        if   [ "$ftype" = "f" ] && [ -f "$f" ]; then echo "$f"
        elif [ "$ftype" = "d" ] && [ -d "$f" ]; then echo "$f"
        fi
    done
}

# ─── Scan Directory for Zips / Log Dirs ─────────────────────────────────────
_menu_scan_dir() {
    printf "  %sDirectory to scan (. for current):%s " "${GRY}" "${RST}"
    local scandir
    read -r scandir
    scandir=$(_clean_path "${scandir:-.}")

    if [ ! -d "$scandir" ]; then
        log_error "Not a directory: $scandir"
        return
    fi

    print_section "Found in: $scandir"
    printf "  %sScanning recursively...%s\n" "${DIM}" "${RST}"

    local items=()
    local idx=0
    local found_archives=0 found_racc=0 found_logs=0

    # Dedup helper
    _scan_seen() {
        local t="$1" e
        for e in "${items[@]+"${items[@]}"}"; do [ "$e" = "$t" ] && return 0; done
        return 1
    }

    # Relative path for display
    _scan_rel() {
        local r="${1#$scandir/}"
        [ "$r" = "$1" ] && r="$(basename "$1")"
        [ -z "$r" ] && r="."
        echo "$r"
    }

    # ── 1. Archives — all supported formats, fully recursive ─────────────────
    local ext f
    for ext in $_ARCHIVE_EXTS; do
        while IFS= read -r f; do
            [ -f "$f" ] || continue
            _scan_seen "$f" && continue
            idx=$((idx + 1)); found_archives=$((found_archives + 1))
            items+=("$f")
            local sz tag relpath
            sz=$(file_size "$f")
            relpath=$(_scan_rel "$f")
            tag="ZIP"
            case "$f" in
                *.tar.gz|*.tgz)   tag="TGZ" ;;
                *.tar.bz2|*.tbz2) tag="TBZ" ;;
                *.tar.xz|*.txz)   tag="TXZ" ;;
                *.7z)             tag=" 7Z" ;;
                *.rar)            tag="RAR" ;;
            esac
            printf "  %s%3d%s  %s[%s]%s  %-55s %s(%s)%s\n" \
                "${BLD}${CYN}" "$idx" "${RST}" "${YLW}" "$tag" "${RST}" \
                "$relpath" "${DIM}" "$(human_size "$sz")" "${RST}"
        done < <(_find_recursive "$scandir" "f" "*.$ext")
    done

    # ── 2. RACC extracted dirs — contain var/aux ─────────────────────────────
    local d parent
    while IFS= read -r d; do
        [ -d "$d" ] || continue
        # Must match path ending in var/aux
        case "$d" in */var/aux) : ;; *) continue ;; esac
        parent=$(dirname "$(dirname "$d")")
        _scan_seen "$parent" && continue
        idx=$((idx + 1)); found_racc=$((found_racc + 1))
        items+=("$parent")
        local relpath
        relpath=$(_scan_rel "$parent")
        printf "  %s%3d%s  %s[DIR]%s  %-55s %s(RACC structure)%s\n" \
            "${BLD}${CYN}" "$idx" "${RST}" "${BLU}" "${RST}" \
            "$relpath" "${DIM}" "${RST}"
    done < <(_find_recursive "$scandir" "d" "aux")

    # ── 3. Dirs with .log files — fully recursive ────────────────────────────
    local seen_log_dirs=()
    _log_dir_seen() {
        local t="$1" e
        for e in "${seen_log_dirs[@]+"${seen_log_dirs[@]}"}"; do [ "$e" = "$t" ] && return 0; done
        return 1
    }
    _register_log_dir() {
        local d="$1"
        _scan_seen "$d" && return
        _log_dir_seen "$d" && return
        # Count real .log files (skip .gz rotations)
        local lcount=0 lf
        for lf in "$d"/*.log "$d"/*.log.*; do
            [ -f "$lf" ] || continue
            case "$lf" in *.gz) continue ;; esac
            lcount=$((lcount + 1))
        done
        [ "$lcount" -eq 0 ] && return
        seen_log_dirs+=("$d")
        idx=$((idx + 1)); found_logs=$((found_logs + 1))
        items+=("$d")
        local relpath
        relpath=$(_scan_rel "$d")
        printf "  %s%3d%s  %s[LOG]%s  %-55s %s(%d log file(s))%s\n" \
            "${BLD}${CYN}" "$idx" "${RST}" "${GRN}" "${RST}" \
            "$relpath" "${DIM}" "$lcount" "${RST}"
    }
    # Find via *.log and *.log.* (rotated logs)
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        case "$f" in *.gz) continue ;; esac
        _register_log_dir "$(dirname "$f")"
    done < <(
        _find_recursive "$scandir" "f" "*.log"
        _find_recursive "$scandir" "f" "*.log.*"
    )

    # ── Summary ───────────────────────────────────────────────────────────────
    printf "\n"
    if [ "$idx" -eq 0 ]; then
        printf "  %s✗  Nothing found in:%s %s\n" "${RED}" "${RST}" "$scandir"
        printf "\n  %sHints:%s\n" "${YLW}" "${RST}"
        printf "  %s  • Check the path is correct\n" "${DIM}"
        printf "  %s  • Files may not have been downloaded yet\n" "${DIM}"
        printf "  %s  • Try scanning a parent directory\n" "${DIM}"
        printf "  %s  • Supported archives: %s%s\n" "${DIM}" "$_ARCHIVE_EXTS" "${RST}"
        return
    fi

    local summary=""
    [ "$found_archives" -gt 0 ] && summary="${summary}${found_archives} archive(s)  "
    [ "$found_racc"     -gt 0 ] && summary="${summary}${found_racc} RACC dir(s)  "
    [ "$found_logs"     -gt 0 ] && summary="${summary}${found_logs} log dir(s)"
    printf "  %sTotal: %s%s\n" "${DIM}" "$summary" "${RST}"
    [ "$found_archives" -eq 0 ] && \
        printf "  %s(no archives found — showing raw directories only)%s\n" "${YLW}" "${RST}"

    printf "\n  %sb%s  Back\n" "${BLD}" "${RST}"
    printf "\n  %sSelect #:%s " "${BLD}" "${RST}"
    local sel
    read -r sel
    [ "$sel" = "b" ] || [ "$sel" = "B" ] && return
    sel=$(safe_int "$sel")
    if [ "$sel" -ge 1 ] && [ "$sel" -le "$idx" ]; then
        _do_load "${items[$((sel - 1))]}"
    else
        log_warn "Invalid selection: $sel"
    fi
}

# ─── 5: Select / View Log ───────────────────────────────────────────────────
_menu_select_log() {
    print_section "Select Component Log"

    local comps=()
    local idx=0
    while IFS='|' read -r comp path; do
        [[ "$comp" == *_combined* ]] && continue
        [[ "$comp" == config:* ]] && continue
        [[ "$comp" == "versions_json" || "$comp" == "fw_version" || "$comp" == "build_info" ]] && continue

        idx=$((idx + 1))
        comps+=("$comp|$path")

        local lines=0 sz=0 errs=0 warns=0 crits=0 color="${GRN}"
        lines=$(wc -l < "$path" 2>/dev/null | tr -d ' ') || lines=0
        sz=$(file_size "$path")
        local parsed="$WORK_DIR/parsed/${comp}.parsed"
        if [ -f "$parsed" ]; then
            crits=$(grep -aFc '|C|' "$parsed" 2>/dev/null) || crits=0
            errs=$(grep -aFc '|E|' "$parsed" 2>/dev/null) || errs=0
            warns=$(grep -aFc '|W|' "$parsed" 2>/dev/null) || warns=0
            errs=$((errs + crits))
        fi
        [ "$errs" -gt 0 ] && color="${RED}"
        [ "$errs" -eq 0 ] && [ "$warns" -gt 10 ] && color="${YLW}"

        printf "  %s%2d%s  %s%-22s%s %5s lines  %8s" \
            "${BLD}${CYN}" "$idx" "${RST}" \
            "$color" "$comp" "${RST}" \
            "$(safe_int "$lines")" "$(human_size "$sz")"
        [ "$errs" -gt 0 ] && printf "  %s%d err%s" "${RED}" "$errs" "${RST}"
        [ "$warns" -gt 0 ] && printf "  %s%d warn%s" "${YLW}" "$warns" "${RST}"
        printf "\n"
    done < "$WORK_DIR/log_files.idx"

    [ "$idx" -eq 0 ] && { log_warn "No log files loaded."; return; }

    printf "\n  %sb%s  Back\n" "${BLD}" "${RST}"
    printf "\n  %sSelect #:%s " "${BLD}" "${RST}"
    local sel
    read -r sel
    [ "$sel" = "b" ] || [ "$sel" = "B" ] && return

    sel=$(safe_int "$sel")
    if [ "$sel" -ge 1 ] && [ "$sel" -le "$idx" ]; then
        local entry="${comps[$((sel - 1))]}"
        local comp="${entry%%|*}"
        local path="${entry#*|}"
        _view_log "$comp" "$path"
    else
        log_warn "Invalid selection"
    fi
}

# ─── View Single Log ─────────────────────────────────────────────────────────
_view_log() {
    local comp="$1" path="$2"
    local parsed="$WORK_DIR/parsed/${comp}.parsed"

    while true; do
        print_section "$comp — $(basename "$path")"

        local lines=0 sz=0
        lines=$(wc -l < "$path" 2>/dev/null | tr -d ' ') || lines=0
        sz=$(file_size "$path")
        print_kv "File" "$path"
        print_kv "Size" "$(human_size "$sz")"
        print_kv "Lines" "$lines"

        if [ -f "$parsed" ]; then
            local c=0 e=0 w=0 n=0 i=0
            c=$(grep -aFc '|C|' "$parsed" 2>/dev/null) || c=0
            e=$(grep -aFc '|E|' "$parsed" 2>/dev/null) || e=0
            w=$(grep -aFc '|W|' "$parsed" 2>/dev/null) || w=0
            n=$(grep -aFc '|N|' "$parsed" 2>/dev/null) || n=0
            i=$(grep -aFc '|I|' "$parsed" 2>/dev/null) || i=0
            printf "  "
            [ "$c" -gt 0 ] && printf "%sCrit: %s%d%s  " "${GRY}" "${RED}${BLD}" "$c" "${RST}"
            printf "%sErrors: %s%d%s  Warns: %s%d%s  " \
                "${GRY}" "${RED}" "$e" "${RST}" "${YLW}" "$w" "${RST}"
            [ "$n" -gt 0 ] && printf "%sNotice: %s%d%s  " "${GRY}" "${MAG}" "$n" "${RST}"
            printf "%sInfo: %s%d%s\n" "${GRY}" "${CYN}" "$i" "${RST}"
        fi

        printf "\n"
        printf "  %s1%s  First 30 lines\n" "${BLD}${CYN}" "${RST}"
        printf "  %s2%s  Last 30 lines\n" "${BLD}${CYN}" "${RST}"
        printf "  %s3%s  Errors + Critical\n" "${BLD}${CYN}" "${RST}"
        printf "  %s4%s  Warnings\n" "${BLD}${CYN}" "${RST}"
        printf "  %s5%s  Info + Notice\n" "${BLD}${CYN}" "${RST}"
        printf "  %s6%s  All lines (raw)\n" "${BLD}${CYN}" "${RST}"
        printf "  %s7%s  Search in this log\n" "${BLD}${CYN}" "${RST}"
        printf "  %s8%s  Line range\n" "${BLD}${CYN}" "${RST}"
        printf "  %sb%s  Back\n" "${BLD}" "${RST}"
        printf "\n  %sChoice:%s " "${BLD}" "${RST}"

        local ch
        read -r ch
        case "$ch" in
            1)
                print_section "First 30 lines"
                head -30 "$path" | while IFS= read -r line; do _color_log_line "$line"; done
                ;;
            2)
                print_section "Last 30 lines"
                tail -30 "$path" | while IFS= read -r line; do _color_log_line "$line"; done
                ;;
            3)
                print_section "Errors in $comp"
                local found=0
                if [ -f "$parsed" ]; then
                    found=$(grep -aEc '\|E\||\|C\|' "$parsed" 2>/dev/null) || found=0
                    grep -aE '\|E\||\|C\|' "$parsed" 2>/dev/null | head -50 | while IFS='|' read -r ts lvl _ msg; do
                        local lc="${RED}"
                        [ "$lvl" = "C" ] && lc="${RED}${BLD}"
                        printf "  %s%s%s %s[%s]%s %s\n" "${GRY}" "$ts" "${RST}" "$lc" "$lvl" "${RST}" "$msg"
                    done
                else
                    found=$(grep -aEic 'error|\[E\]|\[C\]|CRITICAL' "$path" 2>/dev/null) || found=0
                    grep -aEi 'error|\[E\]|\[C\]|CRITICAL' "$path" 2>/dev/null | head -50 | while IFS= read -r line; do
                        printf "  %s%s%s\n" "${RED}" "$line" "${RST}"
                    done
                fi
                [ "$found" -gt 50 ] && printf "\n  %s... %d more%s\n" "${GRY}" "$((found - 50))" "${RST}"
                [ "$found" -eq 0 ] && printf "  %s(no errors found)%s\n" "${DIM}" "${RST}"
                ;;
            4)
                print_section "Warnings in $comp"
                local found=0
                if [ -f "$parsed" ]; then
                    found=$(grep -aFc '|W|' "$parsed" 2>/dev/null) || found=0
                    grep -aF '|W|' "$parsed" 2>/dev/null | head -50 | while IFS='|' read -r ts lvl _ msg; do
                        printf "  %s%s%s %s%s%s\n" "${GRY}" "$ts" "${RST}" "${YLW}" "$msg" "${RST}"
                    done
                else
                    found=$(grep -aEic 'warn|\[W\]' "$path" 2>/dev/null) || found=0
                    grep -aEi 'warn|\[W\]' "$path" 2>/dev/null | head -50 | while IFS= read -r line; do
                        printf "  %s%s%s\n" "${YLW}" "$line" "${RST}"
                    done
                fi
                [ "$found" -gt 50 ] && printf "\n  %s... %d more%s\n" "${GRY}" "$((found - 50))" "${RST}"
                [ "$found" -eq 0 ] && printf "  %s(no warnings found)%s\n" "${DIM}" "${RST}"
                ;;
            5)
                print_section "Info / Notice in $comp"
                local found=0
                if [ -f "$parsed" ]; then
                    found=$(grep -aEc '\|I\||\|N\|' "$parsed" 2>/dev/null) || found=0
                    grep -aE '\|I\||\|N\|' "$parsed" 2>/dev/null | head -50 | while IFS='|' read -r ts lvl _ msg; do
                        local lc=""
                        [ "$lvl" = "N" ] && lc="${MAG}"
                        printf "  %s%s%s %s%s%s%s\n" "${GRY}" "$ts" "${RST}" "$lc" "$msg" "${lc:+${RST}}" ""
                    done
                else
                    grep -aEi 'info|\[I\]|\[N\]|notice' "$path" 2>/dev/null | head -50 | while IFS= read -r line; do
                        _color_log_line "$line"
                    done
                fi
                [ "$found" -gt 50 ] && printf "\n  %s... %d more%s\n" "${GRY}" "$((found - 50))" "${RST}"
                [ "$found" -eq 0 ] && printf "  %s(no info/notice messages found)%s\n" "${DIM}" "${RST}"
                ;;
            6)
                print_section "All lines in $comp (first 60)"
                head -60 "$path" | nl -ba -w5 | while IFS= read -r line; do _color_log_line "$line"; done
                [ "$lines" -gt 60 ] && printf "\n  %s... %d more lines%s\n" "${GRY}" "$((lines - 60))" "${RST}"
                ;;
            7)
                printf "  %sPattern:%s " "${GRY}" "${RST}"
                local pat; read -r pat
                [ -z "$pat" ] && continue
                print_section "Search: $pat"
                local hits=0
                hits=$(grep -ac "$pat" "$path" 2>/dev/null) || hits=0
                printf "  %s%s matches%s\n\n" "${GRN}" "$hits" "${RST}"
                grep -an "$pat" "$path" 2>/dev/null | head -30 | while IFS=: read -r num line; do
                    printf "  %s%5s:%s %s\n" "${DIM}" "$num" "${RST}" "$line"
                done
                [ "$hits" -gt 30 ] && printf "\n  %s... %d more%s\n" "${GRY}" "$((hits - 30))" "${RST}"
                ;;
            8)
                printf "  %sStart line:%s " "${GRY}" "${RST}"
                local sl; read -r sl; sl=$(safe_int "$sl")
                printf "  %sEnd line:%s " "${GRY}" "${RST}"
                local el; read -r el; el=$(safe_int "$el")
                if [ "$sl" -gt 0 ] && [ "$el" -ge "$sl" ]; then
                    print_section "Lines $sl–$el"
                    sed -n "${sl},${el}p" "$path" | while IFS= read -r line; do _color_log_line "$line"; done
                fi
                ;;
            b|B) return ;;
        esac
    done
}

# ─── Color a log line for display ────────────────────────────────────────────
_color_log_line() {
    local line="$1"
    if echo "$line" | grep -qE '\[E\]|\[C\]|[Ee]rror|FAIL'; then
        printf "  %s%s%s\n" "${RED}" "$line" "${RST}"
    elif echo "$line" | grep -qE '\[W\]|[Ww]arn|WARNING'; then
        printf "  %s%s%s\n" "${YLW}" "$line" "${RST}"
    else
        printf "  %s\n" "$line"
    fi
}

# ─── Search ──────────────────────────────────────────────────────────────────
_menu_search() {
    while true; do
        printf "\n"
        print_section "Search & Investigate"
        printf "\n"
        _menu_item 1 "Quick search (keyword)"
        _menu_item 2 "Advanced search (filters)"
        _menu_item 3 "Investigate component"
        _menu_item 4 "Match signatures"
        _menu_item 5 "Manage signatures"
        _menu_item 6 "List components"
        printf "    %sb%s  Back\n" "${BLD}" "${RST}"
        printf "\n  %sChoice:%s " "${BLD}" "${RST}"
        local choice
        read -r choice
        case "$choice" in
            1)  # Quick search
                printf "  %sSearch pattern:%s " "${GRY}" "${RST}"
                local pattern; read -r pattern
                [ -z "$pattern" ] && continue
                printf "  %sLevel filter (E/W/I/C/N/all):%s " "${GRY}" "${RST}"
                local level; read -r level
                [ "$level" = "all" ] || [ -z "$level" ] && level=""
                level="${level^^}"
                printf "\n"
                if [ -n "$level" ]; then
                    search_logs -p "$pattern" -s "$level"
                else
                    search_logs -p "$pattern"
                fi
                ;;
            2)  # Advanced search
                _menu_search_advanced
                ;;
            3)  # Investigate component
                list_components
                printf "  %sComponent name:%s " "${GRY}" "${RST}"
                local comp; read -r comp
                [ -z "$comp" ] && continue
                investigate_component "$comp"
                ;;
            4)  # Match signatures
                match_signatures
                ;;
            5)  # Manage signatures
                _menu_signatures
                ;;
            6)  # List components
                list_components
                ;;
            b|B) return ;;
        esac
    done
}

_menu_search_advanced() {
    printf "\n  %s── Advanced Search ──%s\n\n" "${BLD}" "${RST}"

    printf "  %sPattern (required):%s " "${GRY}" "${RST}"
    local pattern; read -r pattern
    [ -z "$pattern" ] && return

    printf "  %sSeverity (E/W/I/C/N or blank for all):%s " "${GRY}" "${RST}"
    local sev; read -r sev
    sev="${sev^^}"

    printf "  %sComponent (blank for all):%s " "${GRY}" "${RST}"
    local comp; read -r comp

    printf "  %sAfter time (YYYY-MM-DD HH:MM or blank):%s " "${GRY}" "${RST}"
    local after; read -r after

    printf "  %sBefore time (YYYY-MM-DD HH:MM or blank):%s " "${GRY}" "${RST}"
    local before; read -r before

    printf "  %sContext lines (0-5, default 0):%s " "${GRY}" "${RST}"
    local ctx; read -r ctx
    [ -z "$ctx" ] && ctx=0

    printf "  %sExport to file? (path or blank):%s " "${GRY}" "${RST}"
    local export_path; read -r export_path

    printf "\n"

    local args="-p" 
    args="$pattern"
    local cmd="search_logs -p \"$pattern\""

    # Build search args
    local search_args=(-p "$pattern")
    [ -n "$sev" ] && search_args+=(-s "$sev")
    [ -n "$comp" ] && search_args+=(-c "$comp")
    [ -n "$after" ] && search_args+=(-a "$after")
    [ -n "$before" ] && search_args+=(-b "$before")
    [ "$ctx" -gt 0 ] 2>/dev/null && search_args+=(-x "$ctx")
    [ -n "$export_path" ] && search_args+=(-o "$export_path")

    search_logs "${search_args[@]}"
}

_menu_signatures() {
    while true; do
        printf "\n"
        print_section "Signature Database"
        _menu_item 1 "List all signatures"
        _menu_item 2 "Add new signature"
        _menu_item 3 "Reset to defaults"
        printf "    %sb%s  Back\n" "${BLD}" "${RST}"
        printf "\n  %sChoice:%s " "${BLD}" "${RST}"
        local choice; read -r choice
        case "$choice" in
            1) list_signatures ;;
            2) add_signature ;;
            3)
                _init_signatures
                rm -f "$SIGNATURES_DIR/known_signatures.tsv"
                _generate_default_signatures
                ;;
            b|B) return ;;
        esac
    done
}

# ─── Compare / Regression ────────────────────────────────────────────────────
_menu_compare() {
    printf "\n  %sRegression Comparison%s\n" "${BLD}" "${RST}"
    printf "  Compare two RACC reports to detect regressions.\n\n"
    printf "  %sBaseline%s (before): " "${BLD}" "${RST}"
    local baseline
    read -r baseline
    if [ -z "$baseline" ] || [ ! -e "$baseline" ]; then
        log_error "File not found: ${baseline:-<empty>}"
        return 1
    fi
    printf "  %sTarget%s   (after):  " "${BLD}" "${RST}"
    local target
    read -r target
    if [ -z "$target" ] || [ ! -e "$target" ]; then
        log_error "File not found: ${target:-<empty>}"
        return 1
    fi
    printf "\n"
    run_comparison "$baseline" "$target"
}

# ─── Reports ─────────────────────────────────────────────────────────────────
_menu_reports() {
    printf "\n  Report generation:\n"
    printf "  %s1%s  Generate MD + HTML (default)\n" "${BLD}${CYN}" "${RST}"
    printf "  %s2%s  Generate interactive web app\n" "${BLD}${CYN}" "${RST}"
    printf "  %s3%s  Generate all (MD + HTML + Web App)\n" "${BLD}${CYN}" "${RST}"
    printf "  %s4%s  Generate email brief\n" "${BLD}${CYN}" "${RST}"
    printf "  %s5%s  Generate issue tickets\n" "${BLD}${CYN}" "${RST}"
    printf "  %sb%s  Back\n" "${BLD}" "${RST}"
    printf "  %sChoice:%s " "${BLD}" "${RST}"
    local choice
    read -r choice
    case "$choice" in
        1) generate_reports ;;
        2)
            local dev_id datestamp base
            dev_id=$(get_sysinfo device_id)
            [ -z "$dev_id" ] || [ "$dev_id" = "unknown" ] && dev_id="unknown"
            datestamp=$(date +%Y%m%d_%H%M)
            base="${OUTPUT_DIR}/webapp_${dev_id}_${datestamp}"
            mkdir -p "$OUTPUT_DIR"
            spinner_start "Generating web app..."
            generate_webapp "${base}.html"
            spinner_stop
            ;;
        3)
            GENERATE_WEBAPP=1
            generate_reports
            ;;
        4)
            spinner_start "Generating email brief..."
            generate_mail_report
            spinner_stop
            ;;
        5)
            spinner_start "Generating issue tickets..."
            generate_tickets
            spinner_stop
            ;;
        b|B) return ;;
    esac
}

# ─── Settings ────────────────────────────────────────────────────────────────
_menu_settings() {
    printf "\n  Settings:\n"
    print_kv "Evidence level" "$EVIDENCE_LEVEL"
    print_kv "Analysis mode" "$ANALYSIS_MODE"
    print_kv "Output dir" "$OUTPUT_DIR"
    print_kv "Colors" "$([ "$USE_COLOR" -eq 1 ] && echo on || echo off)"
    print_kv "Log level" "$(case $LOG_LEVEL in 1) echo quiet;; 2) echo info;; 3) echo verbose;; 4) echo DEBUG;; esac)"
    print_kv "Session log" "$LOG_FILE"
    local lp; lp=$(_get_last_path)
    [ -n "$lp" ] && print_kv "Last path" "$lp"
    printf "\n  %s1%s  Evidence: min/std/full\n" "${BLD}${CYN}" "${RST}"
    printf "  %s2%s  Toggle colors\n" "${BLD}${CYN}" "${RST}"
    printf "  %s3%s  Set output directory\n" "${BLD}${CYN}" "${RST}"
    printf "  %s4%s  Clear last path\n" "${BLD}${CYN}" "${RST}"
    printf "  %s5%s  Reset settings to defaults\n" "${BLD}${CYN}" "${RST}"
    printf "  %s6%s  Log level: %s\n" "${BLD}${CYN}" "${RST}" "$(case $LOG_LEVEL in 1) echo quiet;; 2) echo info;; 3) echo verbose;; 4) echo "${YLW}DEBUG${RST}";; esac)"
    printf "  %sb%s  Back\n" "${BLD}" "${RST}"
    printf "  %sChoice:%s " "${BLD}" "${RST}"
    local choice
    read -r choice
    case "$choice" in
        1)
            printf "  %sEvidence level (min/std/full):%s " "${GRY}" "${RST}"
            local el; read -r el
            case "$el" in min|std|full) EVIDENCE_LEVEL="$el"; _save_settings; log_ok "Evidence level: $el (saved)" ;; esac
            ;;
        2) USE_COLOR=$((1 - USE_COLOR)); init_colors; _save_settings; log_ok "Colors: $([ "$USE_COLOR" -eq 1 ] && echo on || echo off) (saved)" ;;
        3) printf "  %sOutput dir:%s " "${GRY}" "${RST}"; local d; read -r d; [ -n "$d" ] && OUTPUT_DIR="$d" && _save_settings && log_ok "Output: $d (saved)" ;;
        4) rm -f "$_LAST_PATH_FILE" 2>/dev/null; log_ok "Last path cleared" ;;
        5) rm -f "$_SETTINGS_FILE" 2>/dev/null; log_ok "Settings reset to defaults" ;;
        6)
            case "$LOG_LEVEL" in
                2) LOG_LEVEL=3; log_ok "Log level: verbose (saved)" ;;
                3) LOG_LEVEL=4; log_ok "Log level: DEBUG (saved)" ;;
                4) LOG_LEVEL=2; log_ok "Log level: info (saved)" ;;
                *) LOG_LEVEL=2; log_ok "Log level: info (saved)" ;;
            esac
            _save_settings
            ;;
    esac
}
