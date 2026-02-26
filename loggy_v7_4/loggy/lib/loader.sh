#!/bin/bash
# loader.sh — Input handler: detect zip/folder/files, extract RACC zips
# Loggy v6.0

# ─── Main Load Function ─────────────────────────────────────────────────────
load_input() {
    local input="$1"

    if [ -z "$input" ]; then
        log_error "No input specified"
        return 1
    fi

    # Clear previous load state (for menu reload)
    : > "$WORK_DIR/log_files.idx" 2>/dev/null
    if [ -d "$WORK_DIR/extracted" ]; then
        rm -rf "$WORK_DIR/extracted"
    fi

    # Detect input type
    if [ -f "$input" ]; then
        case "$input" in
            *.zip|*.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz|*.7z|*.rar)
                INPUT_TYPE="zip"
                INPUT_PATH="$(cd "$(dirname "$input")" && pwd)/$(basename "$input")"
                log_info "Input: Archive ($(basename "$input"))"
                _load_zip "$INPUT_PATH"
                ;;
            *.log|*.log.*|*.properties|*.txt|*.conf|*.json)
                INPUT_TYPE="files"
                INPUT_PATH="$input"
                log_info "Input: Individual file(s)"
                _load_files "$@"
                ;;
            *)
                # Try archive detection via file magic or Python
                local is_arch=0
                command -v file >/dev/null 2>&1 &&                     file "$input" 2>/dev/null | grep -qi "zip\|archive\|compressed\|gzip\|bzip\|xz" &&                     is_arch=1
                if [ "$is_arch" -eq 1 ]; then
                    INPUT_TYPE="zip"
                    INPUT_PATH="$(cd "$(dirname "$input")" && pwd)/$(basename "$input")"
                    log_info "Input: Archive (detected by magic)"
                    _load_zip "$INPUT_PATH"
                else
                    INPUT_TYPE="files"
                    INPUT_PATH="$input"
                    _load_files "$@"
                fi
                ;;
        esac
    elif [ -d "$input" ]; then
        INPUT_TYPE="folder"
        INPUT_PATH="$(cd "$input" && pwd)"
        log_info "Input: Log directory"
        _load_folder "$INPUT_PATH"
    else
        log_error "Input not found: $input"
        return 1
    fi

    # Post-load: discover and register all log files
    _discover_logs
    _extract_device_info

    local lcount
    lcount=$(wc -l < "$WORK_DIR/log_files.idx" 2>/dev/null | tr -d ' ')
    log_ok "Loaded $lcount log sources from $INPUT_TYPE input"
    return 0
}

# ─── Convert path for Python on MSYS2/Cygwin ────────────────────────────────
# Python is a native Windows binary that doesn't understand MSYS2 /tmp/ paths.
# This converts them to Windows paths (C:/msys64/tmp/...) when needed.
_pypath() {
    local p="$1"
    if [ "$OS_TYPE" = "msys" ] || [ "$OS_TYPE" = "cygwin" ]; then
        if command -v cygpath >/dev/null 2>&1; then
            cygpath -m "$p"
            return
        fi
    fi
    echo "$p"
}

# ─── Check if file is a log file by content signature ────────────────────────
# Returns 0 if the file looks like a log, 1 otherwise
_is_log_file() {
    local file="$1"
    [ -f "$file" ] || return 1
    # Skip empty files
    [ -s "$file" ] || return 1
    # Skip known non-log extensions
    case "$file" in
        *.properties|*.properties.*|*.conf|*.cfg|*.json|*.xml|*.csv|*.tsv|*.html|*.htm) return 1 ;;
        *.pem|*.crt|*.key|*.cert|*.der|*.p12|*.pfx) return 1 ;;
        *.db|*.db-shm|*.db-wal|*.sqlite*) return 1 ;;
        *.png|*.jpg|*.jpeg|*.gif|*.bmp|*.ico|*.svg) return 1 ;;
        *.zip|*.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz|*.7z|*.rar|*.gz) return 1 ;;
        *.sh|*.py|*.pl|*.rb|*.js|*.css|*.so|*.o|*.a|*.bin|*.elf|*.fw) return 1 ;;
        *.mon|*.md|*.rst|*.txt.bak) return 1 ;;
    esac
    # Skip binary files: check for null bytes in first 512 bytes
    if command -v head >/dev/null 2>&1 && command -v tr >/dev/null 2>&1; then
        local nulls
        nulls=$(head -c 512 "$file" 2>/dev/null | tr -cd '\0' | wc -c 2>/dev/null | tr -d ' ')
        [ "$(safe_int "$nulls")" -gt 0 ] && return 1
    fi
    # Check first 10 lines for known log patterns
    local sample
    sample=$(head -n 10 "$file" 2>/dev/null)
    [ -z "$sample" ] && return 1
    # IoTecha app log: 2026-02-23 08:19:10.588 [I] component: message
    if echo "$sample" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+ \[(I|W|E|N|C|D)\]'; then
        return 0
    fi
    # Syslog format: Feb 23 08:19:... hostname process[pid]: message
    if echo "$sample" | grep -qE '^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [ 0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} '; then
        return 0
    fi
    # Kernel log: [  300.326187] message
    if echo "$sample" | grep -qE '^\[[ 0-9]+\.[0-9]+\] '; then
        return 0
    fi
    # Generic timestamp log: 2026-02-23T08:19:10 or 2026/02/23 08:19:10
    if echo "$sample" | grep -qE '^[0-9]{4}[-/][0-9]{2}[-/][0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}'; then
        return 0
    fi
    # Lighttpd/Apache access log: IP - - [date] "METHOD ...
    if echo "$sample" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ .* \[.*\] "'; then
        return 0
    fi
    return 1
}

# ─── Recursively extract nested archives ─────────────────────────────────────
# Scans extracted directory for inner archives, extracts each in place,
# removes the archive, and loops until no more archives are found.
_extract_nested_archives() {
    local dir="$1"
    local max_depth=5
    local depth=0
    spinner_start "Extracting nested archives..."

    while [ "$depth" -lt "$max_depth" ]; do
        local found=0
        local f

        # Collect nested archives using globs (up to 4 levels deep)
        local archives=()
        local pattern
        for pattern in "$dir"/* "$dir"/*/* "$dir"/*/*/* "$dir"/*/*/*/* ; do
            [ -f "$pattern" ] || continue
            case "$pattern" in
                *.zip|*.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz|*.tar|*.7z|*.rar)
                    archives+=("$pattern")
                    ;;
                *)
                    # Check via file magic for extensionless archives
                    if command -v file >/dev/null 2>&1; then
                        local ftype
                        ftype=$(file -b "$pattern" 2>/dev/null)
                        case "$ftype" in
                            *Zip*|*zip*|*gzip*|*tar*|*bzip2*|*XZ*|*7-zip*|*RAR*|*compressed*)
                                archives+=("$pattern")
                                ;;
                        esac
                    fi
                    ;;
            esac
        done

        [ ${#archives[@]} -eq 0 ] && break

        for f in "${archives[@]}"; do
            [ -f "$f" ] || continue
            local target_dir
            target_dir=$(dirname "$f")
            local bn
            bn=$(basename "$f")
            local rc=1

            _log_file "INFO" "Extracting nested archive: $bn"

            case "$f" in
                *.zip)
                    if command -v unzip >/dev/null 2>&1; then
                        unzip -o "$f" -d "$target_dir" >/dev/null 2>&1; rc=$?
                    fi
                    ;;
                *.tar.gz|*.tgz)
                    if command -v tar >/dev/null 2>&1; then
                        tar -xzf "$f" -C "$target_dir" 2>/dev/null; rc=$?
                    fi
                    if [ "$rc" -ne 0 ]; then
                        local pycmd=""
                        command -v python3 >/dev/null 2>&1 && pycmd="python3"
                        [ -z "$pycmd" ] && command -v python >/dev/null 2>&1 && pycmd="python"
                        if [ -n "$pycmd" ]; then
                            $pycmd -c "
import tarfile, sys
with tarfile.open(sys.argv[1], 'r:gz') as t:
    t.extractall(sys.argv[2], filter='fully_trusted') if hasattr(tarfile, 'fully_trusted_filter') else t.extractall(sys.argv[2])
" "$(_pypath "$f")" "$(_pypath "$target_dir")" 2>/dev/null; rc=$?
                        fi
                    fi
                    ;;
                *.tar)
                    if command -v tar >/dev/null 2>&1; then
                        tar -xf "$f" -C "$target_dir" 2>/dev/null; rc=$?
                    fi
                    if [ "$rc" -ne 0 ]; then
                        local pycmd=""
                        command -v python3 >/dev/null 2>&1 && pycmd="python3"
                        [ -z "$pycmd" ] && command -v python >/dev/null 2>&1 && pycmd="python"
                        if [ -n "$pycmd" ]; then
                            $pycmd -c "
import tarfile, sys
with tarfile.open(sys.argv[1], 'r:') as t:
    t.extractall(sys.argv[2], filter='fully_trusted') if hasattr(tarfile, 'fully_trusted_filter') else t.extractall(sys.argv[2])
" "$(_pypath "$f")" "$(_pypath "$target_dir")" 2>/dev/null; rc=$?
                        fi
                    fi
                    ;;
                *.tar.bz2|*.tbz2)
                    if command -v tar >/dev/null 2>&1; then
                        tar -xjf "$f" -C "$target_dir" 2>/dev/null; rc=$?
                    fi
                    if [ "$rc" -ne 0 ]; then
                        local pycmd=""
                        command -v python3 >/dev/null 2>&1 && pycmd="python3"
                        [ -z "$pycmd" ] && command -v python >/dev/null 2>&1 && pycmd="python"
                        if [ -n "$pycmd" ]; then
                            $pycmd -c "
import tarfile, sys
with tarfile.open(sys.argv[1], 'r:bz2') as t:
    t.extractall(sys.argv[2], filter='fully_trusted') if hasattr(tarfile, 'fully_trusted_filter') else t.extractall(sys.argv[2])
" "$(_pypath "$f")" "$(_pypath "$target_dir")" 2>/dev/null; rc=$?
                        fi
                    fi
                    ;;
                *.tar.xz|*.txz)
                    if command -v tar >/dev/null 2>&1; then
                        tar -xJf "$f" -C "$target_dir" 2>/dev/null; rc=$?
                    fi
                    if [ "$rc" -ne 0 ]; then
                        local pycmd=""
                        command -v python3 >/dev/null 2>&1 && pycmd="python3"
                        [ -z "$pycmd" ] && command -v python >/dev/null 2>&1 && pycmd="python"
                        if [ -n "$pycmd" ]; then
                            $pycmd -c "
import tarfile, sys
with tarfile.open(sys.argv[1], 'r:xz') as t:
    t.extractall(sys.argv[2], filter='fully_trusted') if hasattr(tarfile, 'fully_trusted_filter') else t.extractall(sys.argv[2])
" "$(_pypath "$f")" "$(_pypath "$target_dir")" 2>/dev/null; rc=$?
                        fi
                    fi
                    ;;
                *.7z)
                    if command -v 7z >/dev/null 2>&1; then
                        7z x "$f" -o"$target_dir" -y >/dev/null 2>&1; rc=$?
                    elif command -v 7za >/dev/null 2>&1; then
                        7za x "$f" -o"$target_dir" -y >/dev/null 2>&1; rc=$?
                    fi
                    ;;
                *.rar)
                    if command -v unrar >/dev/null 2>&1; then
                        unrar x -y "$f" "$target_dir/" >/dev/null 2>&1; rc=$?
                    fi
                    ;;
                *)
                    # Extensionless archive detected by file magic — try tar then unzip, with Python fallbacks
                    local ftype
                    ftype=$(file -b "$f" 2>/dev/null)
                    case "$ftype" in
                        *gzip*|*tar*)
                            if command -v tar >/dev/null 2>&1; then
                                tar -xzf "$f" -C "$target_dir" 2>/dev/null; rc=$?
                                [ "$rc" -ne 0 ] && tar -xf "$f" -C "$target_dir" 2>/dev/null; rc=$?
                            fi
                            if [ "$rc" -ne 0 ]; then
                                local pycmd=""
                                command -v python3 >/dev/null 2>&1 && pycmd="python3"
                                [ -z "$pycmd" ] && command -v python >/dev/null 2>&1 && pycmd="python"
                                [ -n "$pycmd" ] && $pycmd -c "
import tarfile, sys
with tarfile.open(sys.argv[1]) as t:
    t.extractall(sys.argv[2], filter='fully_trusted') if hasattr(tarfile, 'fully_trusted_filter') else t.extractall(sys.argv[2])
" "$(_pypath "$f")" "$(_pypath "$target_dir")" 2>/dev/null; rc=$?
                            fi
                            ;;
                        *Zip*|*zip*)
                            if command -v unzip >/dev/null 2>&1; then
                                unzip -o "$f" -d "$target_dir" >/dev/null 2>&1; rc=$?
                            fi
                            if [ "$rc" -ne 0 ]; then
                                local pycmd=""
                                command -v python3 >/dev/null 2>&1 && pycmd="python3"
                                [ -z "$pycmd" ] && command -v python >/dev/null 2>&1 && pycmd="python"
                                [ -n "$pycmd" ] && $pycmd -c "
import zipfile, sys
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
" "$(_pypath "$f")" "$(_pypath "$target_dir")" 2>/dev/null; rc=$?
                            fi
                            ;;
                        *bzip2*)
                            if command -v tar >/dev/null 2>&1; then
                                tar -xjf "$f" -C "$target_dir" 2>/dev/null; rc=$?
                            fi
                            if [ "$rc" -ne 0 ]; then
                                local pycmd=""
                                command -v python3 >/dev/null 2>&1 && pycmd="python3"
                                [ -z "$pycmd" ] && command -v python >/dev/null 2>&1 && pycmd="python"
                                [ -n "$pycmd" ] && $pycmd -c "
import tarfile, sys
with tarfile.open(sys.argv[1], 'r:bz2') as t:
    t.extractall(sys.argv[2], filter='fully_trusted') if hasattr(tarfile, 'fully_trusted_filter') else t.extractall(sys.argv[2])
" "$(_pypath "$f")" "$(_pypath "$target_dir")" 2>/dev/null; rc=$?
                            fi
                            ;;
                        *XZ*)
                            if command -v tar >/dev/null 2>&1; then
                                tar -xJf "$f" -C "$target_dir" 2>/dev/null; rc=$?
                            fi
                            if [ "$rc" -ne 0 ]; then
                                local pycmd=""
                                command -v python3 >/dev/null 2>&1 && pycmd="python3"
                                [ -z "$pycmd" ] && command -v python >/dev/null 2>&1 && pycmd="python"
                                [ -n "$pycmd" ] && $pycmd -c "
import tarfile, sys
with tarfile.open(sys.argv[1], 'r:xz') as t:
    t.extractall(sys.argv[2], filter='fully_trusted') if hasattr(tarfile, 'fully_trusted_filter') else t.extractall(sys.argv[2])
" "$(_pypath "$f")" "$(_pypath "$target_dir")" 2>/dev/null; rc=$?
                            fi
                            ;;
                    esac
                    ;;
            esac

            if [ "$rc" -eq 0 ]; then
                rm -f "$f"
                found=$((found + 1))
                _log_file "INFO" "Nested archive extracted and removed: $bn"
            else
                _log_file "WARN" "Failed to extract nested archive: $bn"
            fi
        done

        [ "$found" -eq 0 ] && break
        depth=$((depth + 1))
    done

    [ "$depth" -gt 0 ] && _log_file "INFO" "Nested archive extraction: $depth pass(es)"
    spinner_stop
}

# ─── Load Archive (zip / tar.gz / tar.bz2 / tar.xz / 7z / rar) ──────────────
_load_zip() {
    local archive="$1"
    EXTRACTED_DIR="$WORK_DIR/extracted"
    mkdir -p "$EXTRACTED_DIR"

    local bn
    bn=$(basename "$archive")
    log_verbose "Extracting: $bn"
    spinner_start "Extracting archive..."

    local rc=1

    # ── Detect format and extract ─────────────────────────────────────────────
    case "$archive" in

        # ── ZIP ──────────────────────────────────────────────────────────────
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                # Check for password protection
                if unzip -t "$archive" >/dev/null 2>&1; then
                    unzip -o "$archive" -d "$EXTRACTED_DIR" >/dev/null 2>&1; rc=$?
                else
                    spinner_stop
                    log_warn "Archive may be password-protected: $bn"
                    printf "  %sPassword (leave blank to skip):%s " "${GRY}" "${RST}"
                    local pw; read -r pw
                    spinner_start "Extracting archive..."
                    if [ -n "$pw" ]; then
                        unzip -o -P "$pw" "$archive" -d "$EXTRACTED_DIR" >/dev/null 2>&1; rc=$?
                    else
                        log_error "Skipped password-protected archive: $bn"
                        spinner_stop; return 1
                    fi
                fi
            fi
            # Python fallback
            if [ "$rc" -ne 0 ] && { command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; }; then
                local pycmd="python3"; command -v python3 >/dev/null 2>&1 || pycmd="python"
                $pycmd -c "
import zipfile, sys
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
" "$(_pypath "$archive")" "$(_pypath "$EXTRACTED_DIR")" 2>/dev/null; rc=$?
            fi
            ;;

        # ── TAR.GZ / TGZ ─────────────────────────────────────────────────────
        *.tar.gz|*.tgz)
            if command -v tar >/dev/null 2>&1; then
                tar -xzf "$archive" -C "$EXTRACTED_DIR" 2>/dev/null; rc=$?
            fi
            if [ "$rc" -ne 0 ] && { command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; }; then
                local pycmd="python3"; command -v python3 >/dev/null 2>&1 || pycmd="python"
                $pycmd -c "
import tarfile, sys
with tarfile.open(sys.argv[1], 'r:gz') as t:
    t.extractall(sys.argv[2], filter='fully_trusted') if hasattr(tarfile, 'fully_trusted_filter') else t.extractall(sys.argv[2])
" "$(_pypath "$archive")" "$(_pypath "$EXTRACTED_DIR")" 2>/dev/null; rc=$?
            fi
            ;;

        # ── TAR.BZ2 / TBZ2 ───────────────────────────────────────────────────
        *.tar.bz2|*.tbz2)
            if command -v tar >/dev/null 2>&1; then
                tar -xjf "$archive" -C "$EXTRACTED_DIR" 2>/dev/null; rc=$?
            fi
            if [ "$rc" -ne 0 ] && { command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; }; then
                local pycmd="python3"; command -v python3 >/dev/null 2>&1 || pycmd="python"
                $pycmd -c "
import tarfile, sys
with tarfile.open(sys.argv[1], 'r:bz2') as t:
    t.extractall(sys.argv[2], filter='fully_trusted') if hasattr(tarfile, 'fully_trusted_filter') else t.extractall(sys.argv[2])
" "$(_pypath "$archive")" "$(_pypath "$EXTRACTED_DIR")" 2>/dev/null; rc=$?
            fi
            ;;

        # ── TAR.XZ / TXZ ─────────────────────────────────────────────────────
        *.tar.xz|*.txz)
            if command -v tar >/dev/null 2>&1; then
                tar -xJf "$archive" -C "$EXTRACTED_DIR" 2>/dev/null; rc=$?
            fi
            if [ "$rc" -ne 0 ] && { command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; }; then
                local pycmd="python3"; command -v python3 >/dev/null 2>&1 || pycmd="python"
                $pycmd -c "
import tarfile, sys
with tarfile.open(sys.argv[1], 'r:xz') as t:
    t.extractall(sys.argv[2], filter='fully_trusted') if hasattr(tarfile, 'fully_trusted_filter') else t.extractall(sys.argv[2])
" "$(_pypath "$archive")" "$(_pypath "$EXTRACTED_DIR")" 2>/dev/null; rc=$?
            fi
            ;;

        # ── 7Z ───────────────────────────────────────────────────────────────
        *.7z)
            if command -v 7z >/dev/null 2>&1; then
                7z x "$archive" -o"$EXTRACTED_DIR" -y >/dev/null 2>&1; rc=$?
            elif command -v 7za >/dev/null 2>&1; then
                7za x "$archive" -o"$EXTRACTED_DIR" -y >/dev/null 2>&1; rc=$?
            elif command -v 7zr >/dev/null 2>&1; then
                7zr x "$archive" -o"$EXTRACTED_DIR" -y >/dev/null 2>&1; rc=$?
            fi
            if [ "$rc" -ne 0 ]; then
                spinner_stop
                log_error "7z extraction failed — install p7zip: $bn"
                return 1
            fi
            ;;

        # ── RAR ───────────────────────────────────────────────────────────────
        *.rar)
            if command -v unrar >/dev/null 2>&1; then
                unrar x -y "$archive" "$EXTRACTED_DIR/" >/dev/null 2>&1; rc=$?
            elif command -v rar >/dev/null 2>&1; then
                rar x -y "$archive" "$EXTRACTED_DIR/" >/dev/null 2>&1; rc=$?
            fi
            if [ "$rc" -ne 0 ]; then
                spinner_stop
                log_error "RAR extraction failed — install unrar: $bn"
                return 1
            fi
            ;;

        *)
            # Unknown extension — try unzip then tar as generic fallback
            if command -v unzip >/dev/null 2>&1; then
                unzip -o "$archive" -d "$EXTRACTED_DIR" >/dev/null 2>&1; rc=$?
            fi
            if [ "$rc" -ne 0 ] && command -v tar >/dev/null 2>&1; then
                tar -xf "$archive" -C "$EXTRACTED_DIR" 2>/dev/null; rc=$?
            fi
            ;;
    esac

    spinner_stop

    if [ "$rc" -ne 0 ]; then
        log_error "Failed to extract archive: $bn"
        _log_file "ERROR" "All extraction attempts failed (rc=$rc) for $archive"
        return 1
    fi

    _log_file "DEBUG" "Extracted to: $EXTRACTED_DIR"
    _log_file "DEBUG" "Top-level: $(ls -1 "$EXTRACTED_DIR" 2>/dev/null | tr '\n' ' ')"

    # Extract nested archives, decompress .gz logs, then extract again
    # (handles: zip→tar.gz directly, and zip→file.gz→file.tar after decompress)
    _extract_nested_archives "$EXTRACTED_DIR"
    _decompress_gz_logs "$EXTRACTED_DIR"
    _extract_nested_archives "$EXTRACTED_DIR"
    return 0
}

# ─── Load Folder ─────────────────────────────────────────────────────────────
_load_folder() {
    local folder="$1"
    EXTRACTED_DIR="$folder"

    # ── Detect RACC structure ─────────────────────────────────────────────────
    if [ -d "$folder/var/aux" ] || [ -d "$folder/etc/iotecha" ]; then
        log_verbose "RACC directory structure detected"
    else
        log_verbose "Non-RACC directory — scanning for log files"

        # Stage loose log files (detected by content, not extension) into var/aux/manual
        local stage="$WORK_DIR/extracted"
        local staged=0
        local f
        spinner_start "Scanning for log files..."
        for f in "$folder"/*; do
            [ -f "$f" ] || continue
            case "$f" in *.gz) continue ;; esac
            if _is_log_file "$f"; then
                mkdir -p "$stage/var/aux/manual"
                cp "$f" "$stage/var/aux/manual/" 2>/dev/null && staged=$((staged + 1))
            fi
        done
        spinner_stop
        if [ "$staged" -gt 0 ]; then
            _log_file "INFO" "Staged $staged loose log file(s) into manual component"
            EXTRACTED_DIR="$stage"
        fi
    fi

    # ── Reassemble Linux log rotation sequences ───────────────────────────────
    # Rotation patterns: app.log, app.log.1, app.log.2.gz, app.log.2026-02-17 ...
    # Strategy: group by base name, sort oldest→newest, concat into _combined
    _reassemble_rotations "$EXTRACTED_DIR"

    # ── Decompress .gz files ──────────────────────────────────────────────────
    local has_gz=0
    local gf
    for gf in "$EXTRACTED_DIR"/*.gz "$EXTRACTED_DIR"/*/*.gz "$EXTRACTED_DIR"/*/*/*.gz; do
        [ -f "$gf" ] && has_gz=1 && break
    done
    if [ "$has_gz" -eq 1 ]; then
        if [ "$EXTRACTED_DIR" = "$folder" ]; then
            # Don't decompress in-place — copy first
            local tmp="$WORK_DIR/extracted"
            cp -r "$folder/." "$tmp/" 2>/dev/null
            EXTRACTED_DIR="$tmp"
        fi
        _decompress_gz_logs "$EXTRACTED_DIR"
        # Reassemble again after decompression (gz rotations now available)
        _reassemble_rotations "$EXTRACTED_DIR"
    fi
    return 0
}

# ─── Reassemble log rotation sequences ───────────────────────────────────────
# Finds groups like: app.log, app.log.1, app.log.2, app.log.2026-02-17
# Sorts chronologically (highest rotation number = oldest) and concatenates
# into app_combined.log for analysis
_reassemble_rotations() {
    local dir="$1"
    local f base_name base_dir rotation_key
    spinner_start "Reassembling log rotations..."

    # Collect all rotation candidates (*.log.* that are plain files, not .gz)
    local processed_bases=()
    _base_seen() {
        local t="$1" e
        for e in "${processed_bases[@]+"${processed_bases[@]}"}"; do [ "$e" = "$t" ] && return 0; done
        return 1
    }

    while IFS= read -r f; do
        [ -f "$f" ] || continue
        case "$f" in *.gz) continue ;; esac

        base_dir=$(dirname "$f")
        base_name=$(basename "$f")

        # Extract the root log name (strip .N or .YYYY-MM-DD suffix)
        local root_name=""
        case "$base_name" in
            *.log.[0-9]*)
                root_name="${base_name%.log.*}.log"
                ;;
            *.log.*-*-*)
                # Date-stamped: app.log.2026-02-17
                root_name="${base_name%%.log.*}.log"
                ;;
            *)
                continue
                ;;
        esac

        [ -z "$root_name" ] && continue
        local base_key="$base_dir/$root_name"
        _base_seen "$base_key" && continue
        processed_bases+=("$base_key")

        # Gather all files in this rotation group
        local group=()
        local gf
        for gf in "$base_dir"/"${root_name%.*}"*.log "$base_dir"/"${root_name%.*}"*.log.*; do
            [ -f "$gf" ] || continue
            case "$gf" in *.gz) continue ;; esac
            group+=("$gf")
        done
        [ "${#group[@]}" -le 1 ] && continue

        # Sort: numbered rotations (higher = older), date rotations (older date = older)
        # Use Python for reliable sort if available; otherwise sort -V
        local sorted_group
        if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
            local pycmd="python3"; command -v python3 >/dev/null 2>&1 || pycmd="python"
            sorted_group=$($pycmd -c "
import sys, re, os
files = sys.argv[1:]
def sort_key(p):
    b = os.path.basename(p)
    # numbered rotation: app.log.3 → sort descending (3 is oldest)
    m = re.search(r'\.log\.(\d+)$', b)
    if m: return (1, -int(m.group(1)))
    # date rotation: app.log.2026-02-17 → sort ascending by date
    m = re.search(r'\.log\.(\d{4}-\d{2}-\d{2})', b)
    if m: return (2, m.group(1))
    # plain .log → newest, goes last
    if b.endswith('.log'): return (3, '')
    return (4, b)
for f in sorted(files, key=sort_key):
    print(f)
" "${group[@]}" 2>/dev/null)
        else
            # Fallback: sort -V (version sort handles numbers well)
            sorted_group=$(printf '%s\n' "${group[@]}" | sort -V 2>/dev/null || printf '%s\n' "${group[@]}")
        fi

        [ -z "$sorted_group" ] && continue

        # Concatenate into a _rotation_combined file alongside the primary log
        local combined="$base_dir/${root_name%.log}_rotation_combined.log"
        : > "$combined"
        while IFS= read -r gf; do
            [ -f "$gf" ] && cat "$gf" >> "$combined" 2>/dev/null
        done <<< "$sorted_group"

        local line_count
        line_count=$(wc -l < "$combined" 2>/dev/null | tr -d ' ')
        _log_file "INFO" "Rotation reassembly: $root_name → ${#group[@]} files, $line_count lines → $(basename "$combined")"
    done < <(_find_recursive "$dir" "f" "*.log.*")
    spinner_stop
}

# ─── Load Individual Files ───────────────────────────────────────────────────
_load_files() {
    EXTRACTED_DIR="$WORK_DIR/extracted"
    mkdir -p "$EXTRACTED_DIR/var/aux/manual" "$EXTRACTED_DIR/etc/iotecha/configs/manual"

    for f in "$@"; do
        [ -f "$f" ] || continue
        local bn
        bn=$(basename "$f")
        case "$bn" in
            *.properties)
                cp "$f" "$EXTRACTED_DIR/etc/iotecha/configs/manual/" 2>/dev/null
                ;;
            *.log*|*.txt)
                cp "$f" "$EXTRACTED_DIR/var/aux/manual/" 2>/dev/null
                ;;
            *)
                cp "$f" "$EXTRACTED_DIR/var/aux/manual/" 2>/dev/null
                ;;
        esac
        # Decompress if gz
        case "$bn" in
            *.gz) _decompress_gz_logs "$EXTRACTED_DIR" ;;
        esac
    done
    return 0
}

# ─── Decompress .gz logs ────────────────────────────────────────────────────
_decompress_gz_logs() {
    local dir="$1"
    local gz_count=0

    # Collect gz files using glob (find broken on MSYS2)
    local gz_files=()
    local f
    # Direct children
    for f in "$dir"/*.gz; do
        [ -f "$f" ] || continue
        case "$f" in *core-*) continue ;; esac
        gz_files+=("$f")
    done
    # One level deep (var/aux/ComponentDir/*.gz)
    for f in "$dir"/*/*.gz; do
        [ -f "$f" ] || continue
        case "$f" in *core-*) continue ;; esac
        gz_files+=("$f")
    done
    # Two levels deep (var/aux/ComponentDir/sub/*.gz)
    for f in "$dir"/*/*/*.gz; do
        [ -f "$f" ] || continue
        case "$f" in *core-*) continue ;; esac
        gz_files+=("$f")
    done
    # Three levels deep
    for f in "$dir"/*/*/*/*.gz; do
        [ -f "$f" ] || continue
        case "$f" in *core-*) continue ;; esac
        gz_files+=("$f")
    done

    _log_file "DEBUG" "GZ: found ${#gz_files[@]} .gz files to decompress"

    local gz_total=${#gz_files[@]}
    local gz_idx=0
    for gzfile in "${gz_files[@]}"; do
        gz_idx=$((gz_idx + 1))
        local base="${gzfile%.gz}"
        local decompressed=0
        # Try multiple decompression methods
        if [ "$decompressed" -eq 0 ] && command -v gunzip >/dev/null 2>&1; then
            gunzip -f "$gzfile" 2>/dev/null && decompressed=1
        fi
        if [ "$decompressed" -eq 0 ] && command -v gzip >/dev/null 2>&1; then
            gzip -d -f "$gzfile" 2>/dev/null && decompressed=1
        fi
        if [ "$decompressed" -eq 0 ] && command -v zcat >/dev/null 2>&1; then
            zcat "$gzfile" > "$base" 2>/dev/null && rm -f "$gzfile" && decompressed=1
        fi
        # Python fallback (works on MSYS2/Git Bash)
        if [ "$decompressed" -eq 0 ] && command -v python3 >/dev/null 2>&1; then
            python3 -c "
import gzip, shutil
with gzip.open('$gzfile', 'rb') as f_in, open('$base', 'wb') as f_out:
    shutil.copyfileobj(f_in, f_out)
" 2>/dev/null && rm -f "$gzfile" && decompressed=1
        fi
        if [ "$decompressed" -eq 0 ] && command -v python >/dev/null 2>&1; then
            python -c "
import gzip, shutil
with gzip.open('$gzfile', 'rb') as f_in, open('$base', 'wb') as f_out:
    shutil.copyfileobj(f_in, f_out)
" 2>/dev/null && rm -f "$gzfile" && decompressed=1
        fi
        if [ "$decompressed" -eq 1 ]; then
            gz_count=$((gz_count + 1))
        else
            _log_file "WARN" "GZ: cannot decompress $(basename "$gzfile")"
        fi
        progress_bar "$gz_idx" "$gz_total" "Decompress"
    done

    [ "$gz_count" -gt 0 ] && log_verbose "Decompressed $gz_count .gz log files"
    [ "$gz_count" -eq 0 ] && [ ${#gz_files[@]} -gt 0 ] && log_warn "Failed to decompress ${#gz_files[@]} .gz files (no gunzip/gzip/python)"
    _log_file "DEBUG" "GZ: decompressed $gz_count of ${#gz_files[@]}"
}

# ─── Discover and Register Logs ─────────────────────────────────────────────
_discover_logs() {
    local dir="$EXTRACTED_DIR"

    # Log what we're working with
    _log_file "DEBUG" "EXTRACTED_DIR=$dir"
    _log_file "DEBUG" "Contents of EXTRACTED_DIR: $(ls -1 "$dir" 2>/dev/null | tr '\n' ' ')"

    # Check if var/aux exists - may be nested in a subdirectory
    if [ ! -d "$dir/var/aux" ]; then
        _log_file "WARN" "var/aux not found directly in $dir — scanning for it"
        # Try common nesting patterns
        local found_aux=""
        for candidate in "$dir"/*/var/aux "$dir"/*/*/var/aux "$dir"/*/*/*/var/aux; do
            if [ -d "$candidate" ]; then
                found_aux="$candidate"
                break
            fi
        done
        if [ -n "$found_aux" ]; then
            local found_root
            found_root=$(dirname "$(dirname "$found_aux")")
            _log_file "INFO" "Found RACC structure at: $found_root"
            dir="$found_root"
        else
            _log_file "WARN" "No var/aux found anywhere under $EXTRACTED_DIR"
        fi
    fi
    _log_file "DEBUG" "Using base dir: $dir"
    _log_file "DEBUG" "var/aux exists: $([ -d "$dir/var/aux" ] && echo YES || echo NO)"
    _log_file "DEBUG" "var/aux contents: $(ls -1 "$dir/var/aux" 2>/dev/null | tr '\n' ' ')"

    # IoTecha app logs in var/aux/
    local _RSTEP=0 _RTOTAL=16
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/i2p2"                "i2p2"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/NetworkBoss"         "NetworkBoss"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/ChargerApp"          "ChargerApp"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/ocpp-framework"      "OCPP"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/EnergyManager"       "EnergyManager"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/iotc-cert-mgr"       "CertManager"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/iotc-health-monitor" "HealthMonitor"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/ConfigManager"       "ConfigManager"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/AuthManagerApp"      "AuthManager"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/TokenManagerApp"     "TokenManager"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/hmi-boss"            "HMIBoss"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/iotc-racc"           "RACC"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/iotc-meter-dispatcher" "MeterDispatcher"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/netlogger"           "NetLogger"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/lighttpd"            "Lighttpd"
    _RSTEP=$((_RSTEP+1)); progress_step $_RSTEP $_RTOTAL "Registering"
    _register_component_logs "$dir/var/aux/iotc-power-board-firmware-updater" "PowerBoardUpdater"

    # System logs — scan var/aux/log/ by content, not hardcoded filenames
    if [ -d "$dir/var/aux/log" ]; then
        local sysfile
        for sysfile in "$dir/var/aux/log"/*; do
            [ -f "$sysfile" ] || continue
            case "$sysfile" in *.gz) continue ;; esac
            if _is_log_file "$sysfile"; then
                local sysname
                sysname=$(basename "$sysfile")
                # Strip .log extension for component name if present
                sysname="${sysname%.log}"
                register_log_file "$sysname" "$sysfile"
            fi
        done
    fi

    # Info commands
    [ -f "$dir/var/aux/reports/info_commands.txt" ] && register_log_file "info_commands" "$dir/var/aux/reports/info_commands.txt"

    # Config / properties files
    if [ -d "$dir/etc/iotecha/configs" ]; then
        local propfile
        for propfile in "$dir"/etc/iotecha/configs/*/*.properties "$dir"/etc/iotecha/configs/*.properties; do
            [ -f "$propfile" ] || continue
            local comp_name
            comp_name=$(basename "$(dirname "$propfile")")
            register_log_file "config:${comp_name}" "$propfile"
        done
    fi

    # Version files
    [ -f "$dir/etc/iotecha.versions.json" ] && register_log_file "versions_json" "$dir/etc/iotecha.versions.json"
    [ -f "$dir/etc/itch_fw_version" ] && register_log_file "fw_version" "$dir/etc/itch_fw_version"
    [ -f "$dir/etc/itch_build_info" ] && register_log_file "build_info" "$dir/etc/itch_build_info"

    # Manual/standalone files
    _register_component_logs "$dir/var/aux/manual" "manual"
}

_register_component_logs() {
    local dir="$1" component="$2"
    if [ ! -d "$dir" ]; then
        _log_file "DEBUG" "REG $component: dir not found ($dir)"
        return
    fi

    # Discover log files by content signature (not just extension)
    local log_files=()
    local f
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        # Skip .gz files
        case "$f" in *.gz) continue ;; esac
        if _is_log_file "$f"; then
            log_files+=("$f")
        fi
    done

    if [ ${#log_files[@]} -eq 0 ]; then
        _log_file "DEBUG" "REG $component: dir exists but no log files in $dir"
        _log_file "DEBUG" "REG $component: dir contents: $(ls -1 "$dir" 2>/dev/null | head -10 | tr '\n' ' ')"
        return
    fi
    _log_file "DEBUG" "REG $component: found ${#log_files[@]} log files"

    # Select primary: prefer the largest file whose name starts with the dir basename
    # (e.g., ChargerApp.log over derate.log in ChargerApp/ dir)
    local primary="" primary_size=0
    local dir_base
    dir_base=$(basename "$dir")
    for f in "${log_files[@]}"; do
        local bn size
        bn=$(basename "$f")
        size=$(file_size "$f" 2>/dev/null)
        # Prefer file that matches directory name (case-insensitive)
        if echo "$bn" | grep -qi "^${dir_base}"; then
            if [ "$(safe_int "$size")" -gt "$primary_size" ]; then
                primary="$f"
                primary_size="$(safe_int "$size")"
            fi
        fi
    done
    # Fallback: just pick the largest file (all entries are already validated as logs)
    if [ -z "$primary" ]; then
        for f in "${log_files[@]}"; do
            local bn size
            bn=$(basename "$f")
            size=$(file_size "$f" 2>/dev/null)
            if [ "$(safe_int "$size")" -gt "$primary_size" ]; then
                primary="$f"
                primary_size="$(safe_int "$size")"
            fi
        done
    fi
    # Ultimate fallback
    [ -z "$primary" ] && primary="${log_files[0]}"

    register_log_file "$component" "$primary"

    # Register combined log for analysis (all logs concatenated chronologically)
    local combined="$WORK_DIR/${component}_combined.log"
    cat "${log_files[@]}" > "$combined" 2>/dev/null
    register_log_file "${component}_combined" "$combined"
}

# ─── Extract Device Info ─────────────────────────────────────────────────────
_extract_device_info() {
    local dir="$EXTRACTED_DIR"

    # Device ID from info_commands.txt
    local info_file="$dir/var/aux/reports/info_commands.txt"
    if [ -f "$info_file" ]; then
        DEVICE_ID=$(awk '/^get_devid/{found=1} found && /^stdout:/{print $2; exit}' "$info_file" 2>/dev/null)
        [ -z "$DEVICE_ID" ] && DEVICE_ID=$(grep -A2 'get_devid' "$info_file" 2>/dev/null | grep 'stdout:' | awk '{print $2}')
    fi
    [ -z "$DEVICE_ID" ] && DEVICE_ID="unknown"

    # Firmware version
    local ver_json="$dir/etc/iotecha.versions.json"
    if [ -f "$ver_json" ]; then
        FW_VERSION=$(grep '"ReleaseVersion"' "$ver_json" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/')
    fi
    [ -z "$FW_VERSION" ] && FW_VERSION="unknown"

    # Set report prefix
    REPORT_PREFIX="analysis_${DEVICE_ID}_$(date '+%Y%m%d_%H%M%S')"

    # Store as sysinfo
    add_sysinfo "device_id" "$DEVICE_ID"
    add_sysinfo "fw_version" "$FW_VERSION"
    add_sysinfo "input_type" "$INPUT_TYPE"
    add_sysinfo "input_path" "$INPUT_PATH"
}

# ─── Display Load Summary ───────────────────────────────────────────────────
show_load_summary() {
    print_header "$ANALYZER_NAME — Load Summary"

    print_kv "Device ID" "${BLD}IOTMP${DEVICE_ID}${RST}"
    print_kv "Firmware" "$FW_VERSION"
    print_kv "Input" "$INPUT_TYPE ($INPUT_PATH)"

    print_section "Log Sources"
    local total=0 components=0
    while IFS='|' read -r comp path; do
        # Skip combined and config entries for display
        [[ "$comp" == *"_combined"* ]] && continue
        [[ "$comp" == config:* ]] && continue
        [[ "$comp" == "versions_json" || "$comp" == "fw_version" || "$comp" == "build_info" ]] && continue

        local size
        size=$(file_size "$path" 2>/dev/null)
        local lines
        lines=$(wc -l < "$path" 2>/dev/null | tr -d ' ')
        printf "  %s%-22s%s %s%6s lines%s  %s\n" \
            "${GRY}" "$comp" "${RST}" "${DIM}" "$(safe_int "$lines")" "${RST}" "$(human_size "$size")"
        total=$((total + $(safe_int "$lines")))
        components=$((components + 1))
    done < "$WORK_DIR/log_files.idx"

    print_divider
    printf "  %s%-22s%s %s%6s lines%s across %s components\n" \
        "${BLD}" "TOTAL" "${RST}" "${DIM}" "$total" "${RST}" "$components"

    # Config files count
    local config_count
    config_count=$(grep -c "^config:" "$WORK_DIR/log_files.idx" 2>/dev/null || echo "0")
    config_count=$(safe_int "$config_count")
    [ "$config_count" -gt 0 ] && printf "  %s%-22s%s %s files\n" "${GRY}" "Config files" "${RST}" "$config_count"

    echo ""
    add_metric "total_log_lines" "$total"
    add_metric "component_count" "$components"
    add_metric "config_count" "$config_count"
}
