#!/bin/bash
# server.sh — Web Server Mode (Phase 13)
# Loggy v7.2

start_server() {
    local port="${1:-8080}"
    local host="${2:-0.0.0.0}"

    # Find python3 — on MSYS2/Git Bash it may be called 'python' not 'python3'
    local PYTHON=""
    if command -v python3 >/dev/null 2>&1; then
        PYTHON="python3"
    elif command -v python >/dev/null 2>&1 && python -c "import sys; exit(0 if sys.version_info[0]==3 else 1)" 2>/dev/null; then
        PYTHON="python"
    else
        log_error "Python 3 is required for web server mode but was not found."
        log_info ""
        log_info "  Linux:        sudo apt install python3"
        log_info "  macOS:        brew install python3"
        log_info "  MSYS2:        pacman -S python"
        log_info "  Git Bash:     Install Python from https://python.org and add to PATH"
        log_info ""
        log_info "  Verify with:  python3 --version"
        return 1
    fi

    # Check Python version (3.8+ required)
    local py_ver
    py_ver=$($PYTHON -c "import sys; print('{}.{}'.format(*sys.version_info[:2]))" 2>/dev/null)
    local py_major
    py_major=$($PYTHON -c "import sys; print(sys.version_info[0])" 2>/dev/null)
    local py_minor
    py_minor=$($PYTHON -c "import sys; print(sys.version_info[1])" 2>/dev/null)
    if [ "${py_major:-0}" -lt 3 ] || { [ "${py_major:-0}" -eq 3 ] && [ "${py_minor:-0}" -lt 8 ]; }; then
        log_error "Python 3.8+ required (found Python ${py_ver})"
        return 1
    fi
    log_info "Using Python ${py_ver} (${PYTHON})"

    local server_dir
    server_dir=$(make_temp_dir "iotsrv")
    cleanup_register_dir "$server_dir"
    mkdir -p "$server_dir/uploads" "$server_dir/sessions"

    # Copy backend + frontend
    cp "$SCRIPT_DIR/lib/server_backend.py" "$server_dir/server.py"
    cp "$SCRIPT_DIR/lib/server_frontend.html" "$server_dir/index.html"

    export IOTECHA_PORT="$port"
    export IOTECHA_HOST="$host"
    export IOTECHA_ANALYZER="$SCRIPT_DIR/analyzer.sh"
    export IOTECHA_FRONTEND="$server_dir/index.html"

    printf "\n"
    printf "  %s╔══════════════════════════════════════════════╗%s\n" "${CYN}" "${RST}"
    printf "  %s║%s  %s⚡ IoTecha Web Server%s                       %s║%s\n" "${CYN}" "${RST}" "${BLD}" "${RST}" "${CYN}" "${RST}"
    printf "  %s╚══════════════════════════════════════════════╝%s\n" "${CYN}" "${RST}"
    printf "\n"
    printf "  %sURL:%s       http://localhost:%s\n" "${BLD}" "${RST}" "$port"
    printf "  %sAnalyzer:%s  %s/analyzer.sh\n" "${BLD}" "${RST}" "$SCRIPT_DIR"
    printf "  %sUploads:%s   %s/uploads/\n" "${BLD}" "${RST}" "$server_dir"
    printf "\n"
    printf "  %sPress Ctrl+C to stop%s\n\n" "${GRY}" "${RST}"

    cd "$server_dir" && $PYTHON server.py
}
