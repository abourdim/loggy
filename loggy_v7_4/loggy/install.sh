#!/bin/bash
# ============================================================================
#  Loggy — Installer
#  Cross-platform: Linux, macOS, MSYS2/UCRT64, Git Bash, Cygwin
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR=""
BIN_LINK=""
VERSION="2.0.0"

# ─── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED=$'\033[31m' GRN=$'\033[32m' YLW=$'\033[33m' CYN=$'\033[36m'
    BLD=$'\033[1m' RST=$'\033[0m'
else
    RED="" GRN="" YLW="" CYN="" BLD="" RST=""
fi

info()  { printf "%s[INFO]%s  %s\n" "$CYN" "$RST" "$*"; }
ok()    { printf "%s[OK]%s    %s\n" "$GRN" "$RST" "$*"; }
warn()  { printf "%s[WARN]%s  %s\n" "$YLW" "$RST" "$*"; }
err()   { printf "%s[ERROR]%s %s\n" "$RED" "$RST" "$*" >&2; }

# ─── Detect OS ──────────────────────────────────────────────────────────────
detect_os() {
    case "$(uname -s 2>/dev/null)" in
        Linux*)       echo "linux" ;;
        Darwin*)      echo "macos" ;;
        MINGW*|MSYS*) echo "msys" ;;
        CYGWIN*)      echo "cygwin" ;;
        *)            echo "unknown" ;;
    esac
}

# ─── Detect Install Paths ──────────────────────────────────────────────────
detect_paths() {
    local os="$1"
    case "$os" in
        linux|macos)
            INSTALL_DIR="$HOME/.local/share/iotecha-log-analyzer"
            BIN_LINK="$HOME/.local/bin/iotecha-analyzer"
            mkdir -p "$HOME/.local/bin" 2>/dev/null || true
            ;;
        msys|cygwin)
            INSTALL_DIR="$HOME/iotecha-log-analyzer"
            BIN_LINK=""  # No symlink on Windows; use alias or PATH
            ;;
        *)
            INSTALL_DIR="$HOME/iotecha-log-analyzer"
            BIN_LINK=""
            ;;
    esac
}

# ─── Check Dependencies ────────────────────────────────────────────────────
check_deps() {
    local os="$1"
    local missing=""

    for tool in bash grep sed awk date; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done

    if [ -n "$missing" ]; then
        err "Missing required tools:$missing"
        case "$os" in
            msys)
                echo ""
                info "On MSYS2/UCRT64, install with:"
                echo "  pacman -S grep sed gawk coreutils unzip gzip"
                echo ""
                info "On Git Bash, most tools are included. If missing:"
                echo "  Install Git for Windows with full Unix tools option"
                ;;
            linux)
                echo ""
                info "On Debian/Ubuntu:  sudo apt install grep sed gawk coreutils unzip gzip"
                info "On RHEL/Fedora:    sudo dnf install grep sed gawk coreutils unzip gzip"
                ;;
            macos)
                echo ""
                info "On macOS: brew install grep gawk coreutils"
                ;;
        esac
        return 1
    fi

    # Check optional but important tools
    if ! command -v unzip >/dev/null 2>&1; then
        warn "unzip not found — RACC zip extraction will not work"
        case "$os" in
            msys) echo "  pacman -S unzip" ;;
            linux) echo "  sudo apt install unzip" ;;
            macos) echo "  brew install unzip" ;;
        esac
    fi

    local gz_ok=0
    command -v gunzip >/dev/null 2>&1 && gz_ok=1
    command -v gzip >/dev/null 2>&1 && gz_ok=1
    command -v python3 >/dev/null 2>&1 && gz_ok=1
    command -v python >/dev/null 2>&1 && gz_ok=1
    if [ "$gz_ok" -eq 0 ]; then
        warn "No gz decompression available (gunzip/gzip/python)"
        warn "Rotated .gz log files will be skipped"
        case "$os" in
            msys) echo "  pacman -S gzip" ;;
            linux) echo "  sudo apt install gzip" ;;
        esac
    fi

    return 0
}

# ─── Install ────────────────────────────────────────────────────────────────
do_install() {
    local os
    os=$(detect_os)
    detect_paths "$os"

    echo ""
    printf "  %s╔══════════════════════════════════════════╗%s\n" "$CYN" "$RST"
    printf "  %s║%s  %s⚡ Loggy v%s Installer%s  %s║%s\n" "$CYN" "$RST" "$BLD" "$VERSION" "$RST" "$CYN" "$RST"
    printf "  %s╚══════════════════════════════════════════╝%s\n" "$CYN" "$RST"
    echo ""

    info "OS detected: $os ($(uname -s))"
    info "Install to:  $INSTALL_DIR"
    [ -n "$BIN_LINK" ] && info "Symlink:     $BIN_LINK"
    echo ""

    # Check dependencies
    info "Checking dependencies..."
    if ! check_deps "$os"; then
        err "Fix missing dependencies and retry."
        exit 1
    fi
    ok "All required dependencies found"
    echo ""

    # Copy files
    info "Installing files..."
    if [ "$SCRIPT_DIR" = "$INSTALL_DIR" ]; then
        ok "Already in install location"
    else
        mkdir -p "$INSTALL_DIR"
        cp -r "$SCRIPT_DIR/analyzer.sh" "$INSTALL_DIR/"
        cp -r "$SCRIPT_DIR/lib" "$INSTALL_DIR/"
        cp -r "$SCRIPT_DIR/config" "$INSTALL_DIR/"
        [ -d "$SCRIPT_DIR/generators" ] && cp -r "$SCRIPT_DIR/generators" "$INSTALL_DIR/"
        [ -d "$SCRIPT_DIR/signatures" ] && cp -r "$SCRIPT_DIR/signatures" "$INSTALL_DIR/"
        [ -d "$SCRIPT_DIR/test" ] && cp -r "$SCRIPT_DIR/test" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/analyzer.sh"
        ok "Files installed to $INSTALL_DIR"
    fi

    # Create symlink or alias
    if [ -n "$BIN_LINK" ]; then
        ln -sf "$INSTALL_DIR/analyzer.sh" "$BIN_LINK"
        chmod +x "$BIN_LINK"
        ok "Symlink created: $BIN_LINK"

        # Check if ~/.local/bin is in PATH
        if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
            warn "$HOME/.local/bin is not in PATH"
            echo ""
            info "Add to your shell profile (~/.bashrc or ~/.zshrc):"
            echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        fi
    else
        # Windows: suggest adding to PATH or creating alias
        echo ""
        info "To use from anywhere, add to your shell profile:"
        case "$os" in
            msys|cygwin)
                echo ""
                echo "  # Add to ~/.bashrc:"
                echo "  alias iotecha-analyzer='$INSTALL_DIR/analyzer.sh'"
                echo ""
                echo "  # Or add to PATH:"
                echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
                ;;
        esac
    fi

    echo ""
    ok "Installation complete!"
    echo ""
    info "Usage:"
    if [ -n "$BIN_LINK" ]; then
        echo "  iotecha-analyzer RACC-Report.zip       # Batch analysis"
        echo "  iotecha-analyzer                        # Interactive menu"
        echo "  iotecha-analyzer --check                # Verify install"
    else
        echo "  bash $INSTALL_DIR/analyzer.sh RACC-Report.zip"
        echo "  bash $INSTALL_DIR/analyzer.sh"
        echo "  bash $INSTALL_DIR/analyzer.sh --check"
    fi
    echo ""
}

# ─── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    local os
    os=$(detect_os)
    detect_paths "$os"

    info "Uninstalling Loggy..."

    if [ -n "$BIN_LINK" ] && [ -L "$BIN_LINK" ]; then
        rm -f "$BIN_LINK"
        ok "Removed symlink: $BIN_LINK"
    fi

    if [ -d "$INSTALL_DIR" ] && [ "$INSTALL_DIR" != "$SCRIPT_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        ok "Removed: $INSTALL_DIR"
    fi

    ok "Uninstall complete"
}

# ─── Main ───────────────────────────────────────────────────────────────────
case "${1:-install}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    check)
        os=$(detect_os)
        info "OS: $os"
        check_deps "$os"
        ;;
    *)
        echo "Usage: $0 [install|uninstall|check]"
        exit 1
        ;;
esac
