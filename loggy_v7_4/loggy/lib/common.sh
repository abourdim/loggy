#!/bin/bash
# common.sh -- Colors, logging, utils, terminal/BusyBox detection
# Loggy v6.0

ANALYZER_VERSION="7.2"
ANALYZER_NAME="Loggy"

# --- Environment Detection --------------------------------------------------
IS_BUSYBOX=0
HAS_BASH4=0
HAS_TPUT=0
TERM_COLS=80
TERM_ROWS=24
OS_TYPE="linux"   # linux, msys, gitbash, cygwin, macos, busybox

detect_environment() {
    # OS / shell detection
    case "$(uname -s 2>/dev/null)" in
        Linux*)   OS_TYPE="linux" ;;
        Darwin*)  OS_TYPE="macos" ;;
        MINGW*|MSYS*) OS_TYPE="msys" ;;
        CYGWIN*)  OS_TYPE="cygwin" ;;
        *)        OS_TYPE="unknown" ;;
    esac
    # Git Bash detection (reports MINGW but has limited tools)
    if [ "$OS_TYPE" = "msys" ] && [ -n "$MSYSTEM" ]; then
        OS_TYPE="msys"
    fi

    # MSYS2/Cygwin PATH safety: remove user home directories from PATH.
    # Non-system binaries (e.g. ~/bin/sort.exe) can trigger Windows UAC
    # elevation popups that block execution. Keep only system paths.
    if [ "$OS_TYPE" = "msys" ] || [ "$OS_TYPE" = "cygwin" ]; then
        local _safe_path="" _IFS_save="$IFS" _p _removed=""
        IFS=":"
        for _p in $PATH; do
            case "$_p" in
                /usr/*|/bin|/bin/*|/sbin|/sbin/*|/mingw*|/ucrt*|/clang*|/opt/*|"")
                    _safe_path="${_safe_path:+$_safe_path:}$_p"
                    ;;
                /c/Windows*|/c/Program*|/d/Program*)
                    _safe_path="${_safe_path:+$_safe_path:}$_p"
                    ;;
                /home/*|/c/Users/*)
                    # Skip user home paths — may contain UAC-triggering binaries
                    _removed="${_removed:+$_removed, }$_p"
                    ;;
                *)
                    _safe_path="${_safe_path:+$_safe_path:}$_p"
                    ;;
            esac
        done
        IFS="$_IFS_save"
        if [ -n "$_removed" ]; then
            PATH="$_safe_path"
            export PATH
            # Log after session log is available (deferred via variable)
            _PATH_SANITIZED="$_removed"
        fi
    fi

    if command -v busybox >/dev/null 2>&1; then
        local sh_path
        sh_path=$(readlink -f "$(command -v sh)" 2>/dev/null || true)
        [ "$sh_path" = "$(command -v busybox 2>/dev/null)" ] && IS_BUSYBOX=1 && OS_TYPE="busybox"
    fi
    [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] 2>/dev/null && HAS_BASH4=1
    if command -v tput >/dev/null 2>&1; then
        HAS_TPUT=1
        TERM_COLS=$(tput cols 2>/dev/null || echo 80)
        TERM_ROWS=$(tput lines 2>/dev/null || echo 24)
    elif [ -n "$COLUMNS" ]; then
        TERM_COLS="$COLUMNS"
        TERM_ROWS="${LINES:-24}"
    fi
    # Validate required tools
    local missing=""
    for tool in grep sed awk date; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    [ -n "$missing" ] && { echo "ERROR: Required tools not found:$missing" >&2; return 1; }
    return 0
}

# ─── MSYS2 Tool Path Safety Check ───────────────────────────────────────────
# On MSYS2/Cygwin, non-system executables (e.g. ~/bin/sort.exe) can trigger
# Windows UAC elevation popups when probed. This checks all tools at startup
# and warns about any resolving to non-system locations.
_warn_nonsystem_tools() {
    [ "$OS_TYPE" = "msys" ] || [ "$OS_TYPE" = "cygwin" ] || return 0
    local tool path warned=0 blocked=""

    for tool in $REQUIRED_TOOLS $OPTIONAL_TOOLS; do
        path=$(command -v "$tool" 2>/dev/null) || continue
        case "$path" in
            /usr/bin/*|/bin/*|/usr/local/bin/*|/mingw*/bin/*|/ucrt*/bin/*|/usr/sbin/*|/sbin/*)
                # Known safe system path
                ;;
            *)
                if [ "$warned" -eq 0 ]; then
                    _log_file "WARN" "Non-system tools detected (may trigger Windows Defender):"
                    warned=1
                fi
                _log_file "WARN" "  $tool → $path (expected in /usr/bin or similar)"
                blocked="${blocked:+$blocked, }$tool ($path)"
                ;;
        esac
    done

    # Show console warning if any tools are in unexpected paths
    if [ -n "$blocked" ]; then
        printf "\n  %s⚠  Windows Security may block these tools:%s\n" "${YLW}${BLD}" "${RST}"
        printf "  %s%s%s\n" "${YLW}" "$blocked" "${RST}"
        printf "  %sTip: Add MSYS2/Git Bash to Windows Defender exclusions%s\n\n" "${GRY}" "${RST}"
        _log_file "WARN" "Non-system-path tools: $blocked"
    fi
    return 0
}

# --- Safe Integer Helpers ---------------------------------------------------
# Safely convert value to integer (empty/non-numeric → 0)
safe_int() {
    local val="${1:-0}"
    # Strip whitespace
    val="${val#"${val%%[! ]*}"}"
    val="${val%"${val##*[! ]}"}"
    # Return 0 if empty or non-numeric
    case "$val" in
        ''|*[!0-9-]*) echo "0" ;;
        *) echo "$val" ;;
    esac
}

# Safe integer comparison: int_gt VAL THRESHOLD (returns 0/true if VAL > THRESHOLD)
int_gt() { [ "$(safe_int "$1")" -gt "$(safe_int "$2")" ]; }
int_ge() { [ "$(safe_int "$1")" -ge "$(safe_int "$2")" ]; }
int_eq() { [ "$(safe_int "$1")" -eq "$(safe_int "$2")" ]; }

# safe_run -- Execute a function with error trapping. If the function fails,
# log the error and continue (do not abort the entire analysis).
# Usage: safe_run _analyze_some_detector
safe_run() {
    local fn="$1"; shift
    local start_ts _rc
    start_ts=$(date +%s)
    "$fn" "$@" 2>>"${ANALYZER_ERRLOG:-/dev/null}"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        log_warn "Detector '$fn' failed (exit $_rc) -- skipping, analysis continues"
        add_metric "detector_errors" "$(($(safe_int "$(get_metric detector_errors)") + 1))"
    fi
    local elapsed=$(( $(date +%s) - start_ts ))
    [ "$elapsed" -gt 30 ] && log_warn "Detector '$fn' took ${elapsed}s (slow)"
    _log_file "DEBUG" "Detector $fn completed in ${elapsed}s"
}

# _setup_error_handling -- Initialize error log and trap for cleanup
_setup_error_handling() {
    ANALYZER_ERRLOG="${WORK_DIR:-/tmp}/analyzer_errors.log"
    : > "$ANALYZER_ERRLOG"
    trap '_analyzer_cleanup' EXIT
    trap '_analyzer_interrupt' INT TERM
}

_analyzer_interrupt() {
    log_warn "Analysis interrupted by signal -- saving partial results"
    # Ensure metrics and issues are flushed
    [ -f "${METRICS_FILE:-}" ] && add_metric "analysis_interrupted" "1"
    exit 130
}

_analyzer_cleanup() {
    # Report any detector errors that occurred
    local det_err
    det_err=$(safe_int "$(get_metric detector_errors 2>/dev/null)")
    if [ "$det_err" -gt 0 ]; then
        log_warn "Analysis completed with $det_err detector error(s) -- see $ANALYZER_ERRLOG"
    fi
    # Clean up temp files
    rm -f /tmp/batch_grep_$$.awk 2>/dev/null
    # Chain into main cleanup
    cleanup_all
}

# validate_log_file -- Check if file is a processable text log
# Returns 0 if OK, 1 if should be skipped
# Checks: exists, non-empty, not oversized, not binary, not corrupt
validate_log_file() {
    local f="$1"
    [ -f "$f" ] || return 1

    # Skip empty files
    [ -s "$f" ] || return 1

    # Skip files > 500MB (likely corrupt or wrong file)
    local sz
    sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
    [ "$(safe_int "$sz")" -gt 524288000 ] && {
        log_warn "Skipping oversized file ($(( sz / 1048576 ))MB): $(basename "$f")"
        return 1
    }

    # Binary detection -- check first 512 bytes for null bytes
    # Try multiple methods for cross-platform compatibility
    local is_binary=0

    # Method 1: grep -P (Linux/macOS with PCRE)
    if head -c 512 "$f" 2>/dev/null | grep -qP '\x00' 2>/dev/null; then
        is_binary=1
    # Method 2: Python (MSYS2 / Git Bash where grep -P may not work)
    elif command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
        local pycmd="python3"; command -v python3 >/dev/null 2>&1 || pycmd="python"
        if $pycmd -c "
import sys
with open(sys.argv[1], 'rb') as f:
    chunk = f.read(512)
sys.exit(0 if b'\x00' in chunk else 1)
" "$f" 2>/dev/null; then
            is_binary=1
        fi
    # Method 3: file command
    elif command -v file >/dev/null 2>&1; then
        file "$f" 2>/dev/null | grep -qi "binary\|data\|executable\|ELF\|PE32" && is_binary=1
    fi

    if [ "$is_binary" -eq 1 ]; then
        log_warn "Skipping binary file: $(basename "$f")"
        return 1
    fi

    # Corruption heuristic: file has size but zero readable lines
    local lines
    lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    if [ "$(safe_int "$sz")" -gt 1024 ] && [ "$(safe_int "$lines")" -eq 0 ]; then
        log_warn "Skipping unreadable/corrupt file: $(basename "$f")"
        return 1
    fi

    return 0
}

int_lt() { [ "$(safe_int "$1")" -lt "$(safe_int "$2")" ]; }

# --- Color / ANSI -----------------------------------------------------------
USE_COLOR=1
# UTF-8 capable terminal detection (for block-drawing progress chars)
_USE_UTF8=$(case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}})" in *[Uu][Tt][Ff]8*|*[Uu][Tt][Ff]-8*) echo 1;; *) echo 0;; esac)

# Check if original stdout was a terminal (survives exec > >(tee ...))
_is_tty() { [ "${_STDOUT_IS_TTY:-$([ -t 1 ] && echo 1 || echo 0)}" -eq 1 ]; }

init_colors() {
    if [ "$USE_COLOR" -eq 0 ] || ! _is_tty || [ "$TERM" = "dumb" ]; then
        USE_COLOR=0
        RST="" BLD="" DIM="" UND=""
        RED="" GRN="" YLW="" BLU="" MAG="" CYN="" WHT="" GRY=""
        BRED="" BGRN="" BYLW="" BBLU="" BMAG="" BCYN=""
        BG_RED="" BG_GRN="" BG_YLW="" BG_BLU=""
        return
    fi
    RST=$'\033[0m'    BLD=$'\033[1m'    DIM=$'\033[2m'    UND=$'\033[4m'
    RED=$'\033[31m'   GRN=$'\033[32m'   YLW=$'\033[33m'   BLU=$'\033[34m'
    MAG=$'\033[35m'   CYN=$'\033[36m'   WHT=$'\033[37m'   GRY=$'\033[90m'
    BRED=$'\033[91m'  BGRN=$'\033[92m'  BYLW=$'\033[93m'  BBLU=$'\033[94m'
    BMAG=$'\033[95m'  BCYN=$'\033[96m'
    BG_RED=$'\033[41m' BG_GRN=$'\033[42m' BG_YLW=$'\033[43m' BG_BLU=$'\033[44m'
}

# --- Portable File Size -----------------------------------------------------
file_size() {
    local f="$1"
    if [ "$OS_TYPE" = "macos" ]; then
        stat -f%z "$f" 2>/dev/null || wc -c < "$f" 2>/dev/null | tr -d ' '
    else
        stat -c%s "$f" 2>/dev/null || wc -c < "$f" 2>/dev/null | tr -d ' '
    fi
}

# --- Safe Binary Probe ----------------------------------------------------
# On Windows/MSYS2, executing ANY binary can trigger Defender popups on
# locked-down corporate machines. On Windows, trust path existence only.
# On Linux/macOS, verify sort output correctness.
_safe_probe() {
    local bin="$1"
    [ -x "$bin" ] || return 1
    # On Windows: trust system paths without execution
    if [ "$OS_TYPE" = "msys" ] || [ "$OS_TYPE" = "cygwin" ]; then
        case "$bin" in
            /usr/bin/*|/bin/*|/usr/local/bin/*|/mingw*/bin/*|/ucrt*/bin/*|/usr/sbin/*|/sbin/*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    # On Linux/macOS: verify the binary actually sorts
    printf 'b\na\n' | "$bin" 2>/dev/null | head -1 | grep -q '^a$'
}

# --- Portable Sort (tab-delimited) -----------------------------------------
# MSYS2/Git Bash can have permission issues with /usr/bin/sort, or
# `command sort` may resolve to Windows sort.exe which ignores GNU flags.
# This wrapper validates sort output to ensure data is never lost.
_SORT_BIN=""
_find_sort() {
    # Cache result after first call
    [ -n "$_SORT_BIN" ] && return
    local candidate
    # Trust known system locations without probing — avoids Defender triggers
    for candidate in /usr/bin/sort /bin/sort /usr/local/bin/sort /mingw64/bin/sort /ucrt64/bin/sort; do
        if [ -x "$candidate" ]; then
            _SORT_BIN="$candidate"
            return
        fi
    done 2>/dev/null
    # Fallback: PATH-based sort — only probe on non-Windows or from safe paths
    local resolved
    resolved=$(command -v sort 2>/dev/null)
    if [ -n "$resolved" ]; then
        case "$resolved" in
            /usr/bin/*|/bin/*|/usr/local/bin/*|/mingw*/bin/*|/ucrt*/bin/*)
                [ -x "$resolved" ] && { _SORT_BIN="$resolved"; return; }
                ;;
            *)
                # Non-system path — probe only on non-Windows to avoid Defender
                if [ "$OS_TYPE" != "msys" ] && [ "$OS_TYPE" != "cygwin" ]; then
                    _safe_probe "$resolved" && { _SORT_BIN="$resolved"; return; }
                fi
                ;;
        esac
    fi
    _SORT_BIN="NONE"
}

safe_sort() {
    _find_sort
    # Buffer stdin to temp file so data is never lost
    local _tmpdir="${WORK_DIR:-${TMPDIR:-/tmp}}"
    local _tmp="${_tmpdir}/_safe_sort_$$_${RANDOM:-0}.tmp"
    cat > "$_tmp"
    # Empty input → empty output
    if [ ! -s "$_tmp" ]; then
        rm -f "$_tmp"
        return 0
    fi
    if [ "$_SORT_BIN" != "NONE" ]; then
        local _out="${_tmp}.out"
        if "$_SORT_BIN" "$@" < "$_tmp" > "$_out" 2>/dev/null && [ -s "$_out" ]; then
            cat "$_out"
            rm -f "$_tmp" "$_out"
            return 0
        fi
        rm -f "$_out"
    fi
    # Sort unavailable or failed -- return unsorted data (better than nothing)
    cat "$_tmp"
    rm -f "$_tmp"
}

# --- Pure-awk Sort (no external sort binary) -------------------------------
# Sort tab-separated data by field 1. Uses insertion sort in awk.
# Usage: awk_sort_tsv FILE [n]   -- "n" for numeric sort, default string sort
# Reads from file, outputs to stdout. Safe for up to ~5000 lines.
awk_sort_tsv() {
    local file="$1" numeric="${2:-}"
    [ -f "$file" ] && [ -s "$file" ] || return 0
    awk -F'\t' -v num="$numeric" '
    { lines[NR] = $0; keys[NR] = $1; n = NR }
    END {
        for (i = 2; i <= n; i++) {
            key = keys[i]; line = lines[i]; j = i - 1
            if (num == "n") {
                while (j > 0 && (keys[j]+0) > (key+0)) {
                    keys[j+1] = keys[j]; lines[j+1] = lines[j]; j--
                }
            } else {
                while (j > 0 && keys[j] > key) {
                    keys[j+1] = keys[j]; lines[j+1] = lines[j]; j--
                }
            }
            keys[j+1] = key; lines[j+1] = line
        }
        for (i = 1; i <= n; i++) print lines[i]
    }' "$file"
}

# --- Dependency Check -------------------------------------------------------
REQUIRED_TOOLS="bash grep sed awk date unzip"
OPTIONAL_TOOLS="gunzip zcat sort wc head tail cut tr tput file"

check_dependencies() {
    local all_ok=1
    printf "\n  %s%-20s %-10s %s%s\n" "${BLD}" "Tool" "Status" "Path" "${RST}"
    print_divider

    for tool in $REQUIRED_TOOLS; do
        local path
        path=$(command -v "$tool" 2>/dev/null)
        if [ -n "$path" ]; then
            printf "  %-20s %s%-10s%s %s\n" "$tool" "${GRN}" "OK" "${RST}" "$path"
        else
            printf "  %-20s %s%-10s%s %s\n" "$tool" "${RED}" "MISSING" "${RST}" "(required)"
            all_ok=0
        fi
    done

    printf "\n"
    for tool in $OPTIONAL_TOOLS; do
        local path
        path=$(command -v "$tool" 2>/dev/null)
        if [ -n "$path" ]; then
            printf "  %-20s %s%-10s%s %s\n" "$tool" "${GRN}" "OK" "${RST}" "$path"
        else
            printf "  %-20s %s%-10s%s %s\n" "$tool" "${YLW}" "OPTIONAL" "${RST}" "(not found)"
        fi
    done

    printf "\n"
    # Probe sort binary (critical for timeline & reports)
    _find_sort
    if [ "$_SORT_BIN" = "NONE" ]; then
        printf "  %-20s %s%-10s%s %s\n" "sort (validated)" "${YLW}" "FALLBACK" "${RST}" "(no working GNU sort -- reports will be unsorted)"
    else
        printf "  %-20s %s%-10s%s %s\n" "sort (validated)" "${GRN}" "OK" "${RST}" "$_SORT_BIN"
    fi
    printf "\n"
    print_kv "OS type" "$OS_TYPE"
    print_kv "Shell" "$BASH_VERSION"
    print_kv "Bash 4+" "$([ "$HAS_BASH4" -eq 1 ] && echo 'yes' || echo 'no')"
    print_kv "Terminal" "${TERM_COLS}x${TERM_ROWS}"
    print_kv "Colors" "$([ "$USE_COLOR" -eq 1 ] && echo 'on' || echo 'off')"

    # On MSYS2/Cygwin, show tool safety probe results
    if [ "$OS_TYPE" = "msys" ] || [ "$OS_TYPE" = "cygwin" ]; then
        printf "\n"
        print_section "Windows Tool Safety"
        local nonsystem_count=0
        for tool in $REQUIRED_TOOLS $OPTIONAL_TOOLS; do
            local tpath
            tpath=$(command -v "$tool" 2>/dev/null) || continue
            case "$tpath" in
                /usr/bin/*|/bin/*|/usr/local/bin/*|/mingw*/bin/*|/ucrt*/bin/*|/usr/sbin/*|/sbin/*)
                    ;;
                *)
                    printf "  %-20s %b  %s\n" "$tool" "${YLW}NON-SYSTEM${RST}" "$tpath"
                    nonsystem_count=$((nonsystem_count + 1))
                    ;;
            esac
        done
        if [ "$nonsystem_count" -gt 0 ]; then
            printf "\n  %s⚠  %d tool(s) in non-system paths — may trigger Windows Defender%s\n" "${YLW}${BLD}" "$nonsystem_count" "${RST}"
            printf "  %sFix: Add MSYS2 to Windows Defender exclusions, or remove ~/bin from PATH%s\n" "${GRY}" "${RST}"
        else
            printf "  %s✓  All tools in system paths%s\n" "${GRN}" "${RST}"
        fi
    fi

    printf "\n"

    if [ "$all_ok" -eq 1 ]; then
        log_ok "All required dependencies satisfied"
    else
        log_error "Missing required dependencies. Install them and retry."
    fi
    return $((1 - all_ok))
}

# --- Logging ----------------------------------------------------------------
LOG_LEVEL=2  # 0=quiet, 1=error, 2=info, 3=verbose, 4=debug
LOG_FILE=""

_log_file() {
    [ -n "$LOG_FILE" ] && [ -w "$LOG_FILE" ] 2>/dev/null && \
        printf "[%s] %-5s %s\n" "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null
}

# Clear any in-progress progress bar/spinner before printing a log line
_log_clear_line() { _is_tty && printf "\r%*s\r" "$TERM_COLS" ""; }
log_error()   { _log_file "ERROR" "$*"; [ "$LOG_LEVEL" -ge 1 ] && { _log_clear_line; printf "%s[ERROR]%s %s\n" "${RED}" "${RST}" "$*" >&2; }; }
log_warn()    { _log_file "WARN"  "$*"; [ "$LOG_LEVEL" -ge 2 ] && { _log_clear_line; printf "%s[WARN]%s  %s\n" "${YLW}" "${RST}" "$*" >&2; }; }
log_info()    { _log_file "INFO"  "$*"; [ "$LOG_LEVEL" -ge 2 ] && { _log_clear_line; printf "%s[INFO]%s  %s\n" "${CYN}" "${RST}" "$*"; }; }
log_ok()      { _log_file "OK"    "$*"; [ "$LOG_LEVEL" -ge 2 ] && { _log_clear_line; printf "%s[OK]%s    %s\n" "${GRN}" "${RST}" "$*"; }; }
log_verbose() { _log_file "VERB"  "$*"; [ "$LOG_LEVEL" -ge 3 ] && printf "%s[VERB]%s  %s\n" "${GRY}" "${RST}" "$*"; }
log_debug()   { _log_file "DEBUG" "$*"; [ "$LOG_LEVEL" -ge 4 ] && printf "%s[DBG]%s   %s\n" "${DIM}" "${RST}" "$*"; }

# --- Display Helpers --------------------------------------------------------
print_header() {
    local text="$1" width="${2:-$TERM_COLS}"
    printf "\n%s%s%s\n" "${BLD}${CYN}" "$text" "${RST}"
    printf "%s%s%s\n" "${DIM}" "$(printf '%*s' "$width" '' | tr ' ' '-')" "${RST}"
}

print_section() { printf "\n%s%s▸ %s%s\n" "${BLD}" "${BLU}" "$1" "${RST}"; }

print_divider() {
    local width="${1:-$TERM_COLS}"
    printf "%s%s%s\n" "${DIM}" "$(printf '%*s' "$width" '' | tr ' ' '-')" "${RST}"
}

print_kv() {
    local key="$1" val="$2" width="${3:-22}"
    printf "  %s%-${width}s%s %s\n" "${GRY}" "$key:" "${RST}" "$val"
}

print_badge() {
    case "$1" in
        CRITICAL) printf "%s%s CRITICAL %s" "${BG_RED}${WHT}${BLD}" "" "${RST}" ;;
        HIGH)     printf "%s%sHIGH%s" "${RED}${BLD}" "" "${RST}" ;;
        MEDIUM)   printf "%s%sMEDIUM%s" "${YLW}${BLD}" "" "${RST}" ;;
        LOW)      printf "%s%sLOW%s" "${GRN}" "" "${RST}" ;;
        INFO)     printf "%s%sINFO%s" "${CYN}" "" "${RST}" ;;
        OK)       printf "%s%sOK%s" "${GRN}${BLD}" "" "${RST}" ;;
        *)        printf "%s" "$1" ;;
    esac
}

print_status_icon() {
    case "$1" in
        up|ok|connected)       printf "%s✓%s" "${GRN}" "${RST}" ;;
        degraded|warning|warn) printf "%s⚠%s" "${YLW}" "${RST}" ;;
        down|error|failed)     printf "%s✗%s" "${RED}" "${RST}" ;;
        *)                     printf "%s?%s" "${GRY}" "${RST}" ;;
    esac
}

# --- Progress ---------------------------------------------------------------
# _repeat_str STR COUNT -- repeat a (possibly multi-byte) string N times.
# Unlike `tr`, this handles UTF-8 characters correctly.
_repeat_str() {
    local str="$1" count="$2" result="" i
    for ((i=0; i<count; i++)); do result+="$str"; done
    printf '%s' "$result"
}

_SPINNER_PID=""

spinner_start() {
    local msg="${1:-Working...}"
    if _is_tty && [ "$USE_COLOR" -eq 1 ]; then
        ( local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
          while true; do
              printf "\r%s%s%s %s" "${CYN}" "${chars:$i:1}" "${RST}" "$msg"
              i=$(( (i + 1) % ${#chars} )); sleep 0.1
          done ) &
        _SPINNER_PID=$!; disown "$_SPINNER_PID" 2>/dev/null
    fi
}

spinner_stop() {
    [ -n "$_SPINNER_PID" ] && { kill "$_SPINNER_PID" 2>/dev/null; wait "$_SPINNER_PID" 2>/dev/null; _SPINNER_PID=""; printf "\r%*s\r" "$TERM_COLS" ""; }
}

progress_bar() {
    # Show progress bar on interactive terminals
    _is_tty || return
    local cur="$1" total="$2" label="${3:-Progress}"
    cur=$(safe_int "$cur"); total=$(safe_int "$total")
    cur=${cur:-0}; total=${total:-0}
    (( total <= 0 )) && return 0
    local pct=$((cur * 100 / total))
    local bw=$((TERM_COLS - 30)); [ "$bw" -lt 10 ] && bw=10
    local filled=$((pct * bw / 100))
    local empty=$((bw - filled))
    local _fc _ec
    [ "${_USE_UTF8:-0}" -eq 1 ] && _fc=$'\xe2\x96\x88' || _fc='='
    [ "${_USE_UTF8:-0}" -eq 1 ] && _ec=$'\xe2\x96\x91' || _ec='-'
    printf "\r  %s%-12s%s [%s%s%s%s] %3d%%" \
        "${GRY}" "$label" "${RST}" "${GRN}" "$(_repeat_str "$_fc" "$filled")" \
        "${DIM}" "$(_repeat_str "$_ec" "$empty")" "$pct"
    (( cur == total )) && printf "\n"
}

# Step-based progress: progress_step CURRENT TOTAL "Step label"
progress_step() {
    _is_tty || return
    local cur="$1" total="$2" label="${3:-}"
    cur=$(safe_int "$cur"); total=$(safe_int "$total")
    cur=${cur:-0}; total=${total:-0}
    (( total <= 0 )) && return 0
    local pct=$((cur * 100 / total))
    local bw=$((TERM_COLS - 40)); [ "$bw" -lt 10 ] && bw=10
    local filled=$((pct * bw / 100))
    local empty=$((bw - filled))
    local _fc _ec
    [ "${_USE_UTF8:-0}" -eq 1 ] && _fc=$'\xe2\x96\x93' || _fc='='
    [ "${_USE_UTF8:-0}" -eq 1 ] && _ec=$'\xe2\x96\x91' || _ec='-'
    printf "\r  %s%-20s%s [%s%s%s%s] %d/%d" \
        "${GRY}" "$label" "${RST}" "${CYN}" "$(_repeat_str "$_fc" "$filled")" \
        "${DIM}" "$(_repeat_str "$_ec" "$empty")" "$cur" "$total"
    (( cur == total )) && printf "\n"
}

# --- Utility Functions ------------------------------------------------------
make_temp_dir() {
    local prefix="${1:-iotlog}"
    mktemp -d "/tmp/${prefix}.XXXXXX" 2>/dev/null || { local d="/tmp/${prefix}.$$"; mkdir -p "$d" && echo "$d"; }
}

_CLEANUP_DIRS=()
_CLEANUP_FILES=()
cleanup_register_dir()  { _CLEANUP_DIRS+=("$1"); }
cleanup_register_file() { _CLEANUP_FILES+=("$1"); }
cleanup_all() {
    spinner_stop
    local d f
    for f in "${_CLEANUP_FILES[@]}"; do [ -f "$f" ] && rm -f "$f"; done
    for d in "${_CLEANUP_DIRS[@]}"; do [ -d "$d" ] && rm -rf "$d"; done
}

human_size() {
    local bytes
    bytes=$(safe_int "${1:-0}")
    if [ "$bytes" -ge 1048576 ]; then LC_NUMERIC=C awk "BEGIN{printf \"%.1f MB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ]; then LC_NUMERIC=C awk "BEGIN{printf \"%.1f KB\", $bytes/1024}"
    else printf "%d B" "$bytes"; fi
}

ts_to_epoch() {
    local ts="${1%%.*}"
    # Try GNU date first, then fallback
    date -d "$ts" '+%s' 2>/dev/null && return
    # macOS date
    date -j -f "%Y-%m-%d %H:%M:%S" "$ts" '+%s' 2>/dev/null && return
    echo 0
}

format_duration() {
    local s
    s=$(safe_int "$1")
    if [ "$s" -ge 86400 ]; then printf "%dd %dh %dm" $((s/86400)) $((s%86400/3600)) $((s%3600/60))
    elif [ "$s" -ge 3600 ]; then printf "%dh %dm %ds" $((s/3600)) $((s%3600/60)) $((s%60))
    elif [ "$s" -ge 60 ]; then printf "%dm %ds" $((s/60)) $((s%60))
    else printf "%ds" "$s"; fi
}

count_matches() { local c; c=$(grep -ac "$1" "$2" 2>/dev/null) || true; echo "$(safe_int "$c")"; }

html_escape() {
    local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"; echo "$s"
}

json_escape() {
    local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"; echo "$s"
}

severity_rank() {
    case "$1" in CRITICAL) echo 5;; HIGH) echo 4;; MEDIUM) echo 3;; LOW) echo 2;; INFO) echo 1;; *) echo 0;; esac
}

# --- Issue / Event Management -----------------------------------------------
add_issue() {
    # add_issue SEVERITY COMPONENT TITLE DESCRIPTION [EVIDENCE_FILE]
    local sev="$1" comp="$2" title="$3" desc="$4" evfile="${5:-}"
    # Sanitize: replace tabs and newlines with spaces to protect TSV format
    desc="${desc//$'\t'/ }"
    desc="${desc//$'\n'/ }"
    title="${title//$'\t'/ }"
    title="${title//$'\n'/ }"
    comp="${comp//$'\t'/ }"
    comp="${comp//$'\n'/ }"
    printf "%s\t%s\t%s\t%s\t%s\n" "$sev" "$comp" "$title" "$desc" "$evfile" >> "$ISSUES_FILE"
}

add_timeline_event() {
    printf "%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$4" >> "$TIMELINE_FILE"
}

add_sysinfo() {
    printf "%s=%s\n" "$1" "$2" >> "$SYSINFO_FILE"
}

add_metric() {
    printf "%s=%s\n" "$1" "$2" >> "$METRICS_FILE"
}

get_sysinfo() {
    grep "^${1}=" "$SYSINFO_FILE" 2>/dev/null | head -1 | cut -d= -f2-
}

get_metric() {
    local val
    val=$(grep "^${1}=" "$METRICS_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    echo "${val:-0}"
}

issue_count() {
    [ -f "$ISSUES_FILE" ] || { echo "0"; return; }
    local c
    c=$(wc -l < "$ISSUES_FILE" 2>/dev/null | tr -d ' ')
    echo "$(safe_int "$c")"
}

issue_count_by_severity() {
    [ -f "$ISSUES_FILE" ] || { echo "0"; return; }
    local c
    c=$(awk -F'\t' -v s="$1" '$1==s{n++} END{print n+0}' "$ISSUES_FILE" 2>/dev/null)
    echo "$(safe_int "$c")"
}

# --- Global State -----------------------------------------------------------
WORK_DIR=""
INPUT_TYPE=""
INPUT_PATH=""
EXTRACTED_DIR=""
DEVICE_ID=""
FW_VERSION=""
ANALYSIS_MODE="standard"
EVIDENCE_LEVEL="std"
OUTPUT_DIR="./reports"
REPORT_PREFIX=""
QUIET_MODE=0
VERBOSE_MODE=0
ISSUES_FILE=""
TIMELINE_FILE=""
SYSINFO_FILE=""
METRICS_FILE=""

# --- Log file tracking (populated by loader) --------------------------------
declare -A LOG_FILES 2>/dev/null || true  # component -> filepath
LOG_FILE_LIST=""  # Fallback: newline-delimited list of "component|path"

register_log_file() {
    local comp="$1" path="$2"
    if [ "$HAS_BASH4" -eq 1 ]; then
        LOG_FILES["$comp"]="$path"
    fi
    echo "${comp}|${path}" >> "$WORK_DIR/log_files.idx"
}

get_log_file() {
    local comp="$1"
    if [ "$HAS_BASH4" -eq 1 ] && [ -n "${LOG_FILES[$comp]+x}" ]; then
        echo "${LOG_FILES[$comp]}"
    else
        grep "^${comp}|" "$WORK_DIR/log_files.idx" 2>/dev/null | head -1 | cut -d'|' -f2-
    fi
}

list_log_components() {
    cut -d'|' -f1 "$WORK_DIR/log_files.idx" 2>/dev/null | safe_sort -u
}

# --- Initialize -------------------------------------------------------------
init_common() {
    detect_environment
    _warn_nonsystem_tools
    init_colors

    # Validate sort early and create a safe wrapper function.
    # This overrides PATH-based sort lookups across all scripts, preventing
    # MSYS2 from resolving to a non-system sort that triggers UAC popups.
    _find_sort
    if [ "$_SORT_BIN" != "NONE" ]; then
        eval "sort() { \"$_SORT_BIN\" \"\$@\"; }"
    else
        # No working sort found — define a pass-through wrapper to prevent
        # PATH from resolving to a dangerous binary (e.g. ~/bin/sort on MSYS2).
        # Strips sort flags and just cats the file(s) through unsorted.
        sort() {
            local _f
            for _f in "$@"; do
                [ -f "$_f" ] && cat "$_f" && return
            done
            # No file arg found — pass through stdin
            cat
        }
    fi

    WORK_DIR=$(make_temp_dir "iotlog")
    cleanup_register_dir "$WORK_DIR"
    ISSUES_FILE="$WORK_DIR/issues.dat"
    TIMELINE_FILE="$WORK_DIR/timeline.dat"
    SYSINFO_FILE="$WORK_DIR/sysinfo.dat"
    METRICS_FILE="$WORK_DIR/metrics.dat"
    touch "$ISSUES_FILE" "$TIMELINE_FILE" "$SYSINFO_FILE" "$METRICS_FILE"
    touch "$WORK_DIR/log_files.idx"

    # Session log -- always written to OUTPUT_DIR
    mkdir -p "${OUTPUT_DIR:-.}" 2>/dev/null || true
    LOG_FILE="${OUTPUT_DIR:-.}/analyzer_$(date '+%Y%m%d_%H%M%S').log"
    : > "$LOG_FILE" 2>/dev/null || LOG_FILE="$WORK_DIR/session.log"
    _log_file "INFO" "=== Loggy v$ANALYZER_VERSION ==="
    _log_file "INFO" "OS=$OS_TYPE SHELL=$BASH_VERSION BASH4=$HAS_BASH4 TERM=${TERM_COLS}x${TERM_ROWS}"
    _log_file "INFO" "WORK_DIR=$WORK_DIR"
    # Probe sort binary early so it's logged
    _find_sort
    _log_file "INFO" "SORT_BIN=$_SORT_BIN"
    [ -n "${_PATH_SANITIZED:-}" ] && _log_file "WARN" "PATH sanitized — removed: $_PATH_SANITIZED"
}

# --- Safe grep count --------------------------------------------------------
# count_grep PATTERN FILE -- returns integer count, always safe
count_grep() {
    local pattern="$1" file="$2"
    [ -f "$file" ] || { echo "0"; return; }
    local c
    c=$(grep -aEc "$pattern" "$file" 2>/dev/null || true)
    c="${c:-0}"
    # Strip non-numeric chars (safety for weird grep outputs)
    c=$(printf '%s' "$c" | tr -dc '0-9')
    echo "${c:-0}"
}

# batch_count_grep -- count multiple patterns in a single awk pass over a file.
# Usage: eval "$(batch_count_grep "$file" var1 'pattern1' var2 'pattern2' ...)"
# Sets var1, var2, ... to their respective counts.
batch_count_grep() {
    local file="$1"; shift
    [ -f "$file" ] || {
        while [ $# -ge 2 ]; do echo "$1=0"; shift 2; done
        return
    }
    local awk_prog="" vars="" n=0
    while [ $# -ge 2 ]; do
        local var="$1" pat="$2"; shift 2
        n=$((n+1))
        awk_prog="${awk_prog}/$pat/{c$n++} "
        vars="${vars}$var=c$n "
    done
    awk_prog="${awk_prog}END{"
    local i=1
    for vp in $vars; do
        local v="${vp%%=*}"
        awk_prog="${awk_prog}printf \"$v=%d\\n\", 0+c$i; "
        i=$((i+1))
    done
    awk_prog="${awk_prog}}"
    awk "$awk_prog" "$file" 2>/dev/null
}

# first_grep PATTERN FILE -- returns first matching line
first_grep() {
    local pattern="$1" file="$2"
    [ -f "$file" ] || return
    grep -aEm1 "$pattern" "$file" 2>/dev/null || true
}

# extract_grep PATTERN FILE -- returns all matching content (for -o style)
extract_grep() {
    local pattern="$1" file="$2"
    [ -f "$file" ] || return
    grep -aEo "$pattern" "$file" 2>/dev/null || true
}
