#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  Loggy — Launcher                               ║
# ║  Quick-start menu for all analyzer modes                       ║
# ╚══════════════════════════════════════════════════════════════════╝

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER="$SCRIPT_DIR/analyzer.sh"

# ── Colors ──────────────────────────────────────────────────────────
if [ -t 1 ]; then
    B=$'\033[1m'; D=$'\033[2m'; U=$'\033[4m'
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; M=$'\033[35m'
    BG=$'\033[44m'; RST=$'\033[0m'
else
    B="" D="" U="" R="" G="" Y="" C="" M="" BG="" RST=""
fi

# ── Banner ──────────────────────────────────────────────────────────
clear
cat << EOF

  ${C}╔══════════════════════════════════════════════════════════╗${RST}
  ${C}║${RST}  ${B}⚡ Loggy${RST}                                  ${C}║${RST}
  ${C}║${RST}  ${D}Diagnostic toolkit for EV charger RACC logs${RST}              ${C}║${RST}
  ${C}╚══════════════════════════════════════════════════════════╝${RST}

  ${B}How would you like to start?${RST}

  ${B}${C}1${RST}  ${G}▶ Interactive Menu${RST} ${D}(TUI)${RST}
     ${D}Full terminal interface — load, analyze, search, compare${RST}

  ${B}${C}2${RST}  ${G}▶ Web Browser UI${RST} ${D}(--server)${RST}
     ${D}Same features in your browser — http://localhost:8080${RST}

  ${B}${C}3${RST}  ${G}▶ Quick Analysis${RST} ${D}(batch)${RST}
     ${D}Analyze a RACC zip and generate reports immediately${RST}

  ${B}${C}4${RST}  ${G}▶ Full Analysis${RST} ${D}(deep + all outputs)${RST}
     ${D}Deep analysis + web app + email + tickets${RST}

  ${B}${C}5${RST}  ${G}▶ Compare Two RACCs${RST} ${D}(regression)${RST}
     ${D}Side-by-side comparison of before/after captures${RST}

  ${B}${C}6${RST}  ${G}▶ Fleet Analysis${RST} ${D}(multi-charger)${RST}
     ${D}Analyze all RACC zips in a folder${RST}

  ${B}${C}7${RST}  ${G}▶ Live Monitoring${RST} ${D}(--watch)${RST}
     ${D}Real-time log tail with alert feed${RST}

  ${D}────────────────────────────────────────────────────────${RST}
  ${B}${C}8${RST}  Check Installation
  ${B}${C}9${RST}  Run Self-Tests
  ${B}${C}0${RST}  Show Help
  ${B}${C}q${RST}  Quit

EOF

# ── Helpers ─────────────────────────────────────────────────────────
ask_path() {
    local prompt="$1" default="$2" result
    printf "  ${B}%s${RST}" "$prompt"
    [ -n "$default" ] && printf " ${D}[%s]${RST}" "$default"
    printf ": "
    read -r result
    result="${result:-$default}"
    echo "$result"
}

ask_port() {
    local port
    printf "  ${B}Port${RST} ${D}[8080]${RST}: "
    read -r port
    echo "${port:-8080}"
}

ask_mode() {
    printf "\n  ${B}Analysis mode:${RST}\n"
    printf "  ${C}1${RST} Standard ${D}(34+ detectors + health score)${RST}\n"
    printf "  ${C}2${RST} Deep ${D}(+ boot timing, causal chains, gaps, config, PMQ)${RST}\n"
    printf "  ${D}[1]${RST}: "
    local choice; read -r choice
    [ "$choice" = "2" ] && echo "deep" || echo "standard"
}

ask_outputs() {
    local flags=""
    printf "\n  ${B}Extra outputs:${RST} ${D}(y/n for each)${RST}\n"
    printf "  Web app?   ${D}[n]${RST}: "; read -r a; [ "$a" = "y" ] && flags="$flags --web"
    printf "  Email?     ${D}[n]${RST}: "; read -r a; [ "$a" = "y" ] && flags="$flags --mail"
    printf "  Tickets?   ${D}[n]${RST}: "; read -r a; [ "$a" = "y" ] && flags="$flags --tickets"
    echo "$flags"
}

press_enter() {
    printf "\n  ${D}Press Enter to return to menu...${RST}"
    read -r
}

run_cmd() {
    printf "\n  ${Y}▸${RST} ${D}%s${RST}\n\n" "$*"
    "$@"
}

# ── Main Loop ───────────────────────────────────────────────────────
while true; do
    printf "  ${B}Choice [1-9,0,q]:${RST} "
    read -r choice

    case "$choice" in

        1)  # Interactive Menu
            printf "\n  ${G}Launching interactive menu...${RST}\n\n"
            exec bash "$ANALYZER"
            ;;

        2)  # Web Server
            printf "\n  ${B}Port${RST} ${D}[8080]${RST}: "
            read -r port </dev/tty
            port="${port:-8080}"
            printf "\n  ${G}Starting web server on port %s...${RST}\n" "$port"
            printf "  ${B}Open:${RST} ${U}http://localhost:%s${RST}\n" "$port"
            printf "  ${D}Press Ctrl+C to stop the server.${RST}\n\n"
            bash "$ANALYZER" --server --port "$port"
            printf "\n  ${D}Server stopped. Press Enter to return to menu...${RST}"
            read -r _unused </dev/tty
            exec bash "$0"
            ;;

        3)  # Quick Analysis
            path=$(ask_path "RACC zip or log directory")
            if [ -z "$path" ]; then printf "  ${R}No path entered${RST}\n"; continue; fi
            mode=$(ask_mode)
            printf "\n  ${G}Running %s analysis...${RST}\n" "$mode"
            run_cmd bash "$ANALYZER" --mode "$mode" "$path"
            press_enter
            # Re-show menu
            exec bash "$0"
            ;;

        4)  # Full Analysis
            path=$(ask_path "RACC zip or log directory")
            if [ -z "$path" ]; then printf "  ${R}No path entered${RST}\n"; continue; fi
            outputs=$(ask_outputs)
            printf "\n  ${G}Running deep analysis with all outputs...${RST}\n"
            run_cmd bash "$ANALYZER" --mode deep $outputs "$path"
            press_enter
            exec bash "$0"
            ;;

        5)  # Compare
            base=$(ask_path "Baseline RACC (before)")
            if [ -z "$base" ]; then printf "  ${R}No path entered${RST}\n"; continue; fi
            target=$(ask_path "Target RACC (after)")
            if [ -z "$target" ]; then printf "  ${R}No path entered${RST}\n"; continue; fi
            printf "\n  ${G}Comparing...${RST}\n"
            run_cmd bash "$ANALYZER" --compare "$base" "$target"
            press_enter
            exec bash "$0"
            ;;

        6)  # Fleet
            dir=$(ask_path "Directory containing RACC zips")
            if [ -z "$dir" ]; then printf "  ${R}No path entered${RST}\n"; continue; fi
            printf "\n  ${G}Running fleet analysis...${RST}\n"
            run_cmd bash "$ANALYZER" --fleet "$dir"
            press_enter
            exec bash "$0"
            ;;

        7)  # Live Monitoring
            dir=$(ask_path "Directory to monitor")
            if [ -z "$dir" ]; then printf "  ${R}No path entered${RST}\n"; continue; fi
            printf "\n  ${G}Starting live monitor (Ctrl+C to stop)...${RST}\n\n"
            exec bash "$ANALYZER" --watch "$dir"
            ;;

        8)  # Check
            run_cmd bash "$ANALYZER" --check
            press_enter
            exec bash "$0"
            ;;

        9)  # Self-Test
            if [ -f "$SCRIPT_DIR/run_tests.sh" ]; then
                run_cmd bash "$SCRIPT_DIR/run_tests.sh"
            else
                printf "  ${R}run_tests.sh not found${RST}\n"
            fi
            press_enter
            exec bash "$0"
            ;;

        0|h|H)  # Help
            bash "$ANALYZER" --help
            press_enter
            exec bash "$0"
            ;;

        q|Q|quit|exit)
            printf "\n  ${C}Goodbye!${RST}\n\n"
            exit 0
            ;;

        *)
            printf "  ${R}Invalid choice.${RST} Enter 1-9, 0, or q\n"
            ;;
    esac
done
