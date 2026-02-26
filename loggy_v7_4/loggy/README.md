# Loggy V7.2

Diagnostic toolkit for EV charger RACC log bundles. Pure Bash — no Python, no Node, no Docker. Runs on Linux, macOS, MSYS2/Git Bash, and WSL.

## Quick Start

```bash
# Launcher menu (guided — easiest way)
./start.sh

# Standard analysis
./analyzer.sh RACC-Report.zip

# Deep analysis + web app + health score
./analyzer.sh --mode deep --web RACC-Report.zip

# Interactive menu
./analyzer.sh
```

## Installation

1. Extract or clone the repository
2. `chmod +x analyzer.sh run_tests.sh`
3. Verify: `./analyzer.sh --check`

**Requirements:** Bash 3.2+, awk, grep, sed, unzip. Optional: tar, p7zip, unrar (for additional archive formats). Python 3 recommended (improves cross-platform compatibility for find, binary detection, and archive extraction fallbacks).

## Usage

### Command Line

```
./analyzer.sh [options] <input.zip|input_dir>
```

| Flag | Description |
|------|-------------|
| `-m, --mode <std\|deep>` | Analysis depth (default: std) |
| `--deep` | Shorthand for `--mode deep` |
| `--web` | Generate interactive web app |
| `--mail` | Generate email brief (plain text + HTML) |
| `--tickets` | Generate issue tickets (MD + Jira CSV + GitLab JSON) |
| `--compare <base> <target>` | Regression detection between two RACCs |
| `--fleet <dir>` | Multi-charger fleet analysis |
| `--watch <dir>` | Live log monitoring |
| `--server` | Launch browser-based UI at http://localhost:8080 |
| `-o, --output <dir>` | Output directory (default: ./reports) |
| `--no-color` | Disable terminal colors |
| `-q, --quiet` | Suppress progress output |
| `--check` | Verify installation and dependencies |
| `-h, --help` | Show help |
| `--version` | Show version |

### Interactive Menu

Run `./analyzer.sh` without arguments to enter the menu:

```
  1  Load logs
  2  Run standard analysis
  3  Run deep analysis
  4  Search logs
  5  Select / view log
  6  View results
  7  Generate reports
  8  Compare / regression
  9  Settings
  0  Check install / system info
  h  History
  q  Quit
```

## Features

### Standard Analysis — 26 Detectors

Detects 65+ issue patterns across all EV charger subsystems:

| Detector | Component | Key Patterns |
|----------|-----------|-------------|
| i2p2/MQTT | Cloud connectivity | Token failure, MQTT disconnect, shadow update, backoff |
| NetworkBoss | PPP/Ethernet/WiFi | Link flapping, PPP down, SSID not found, CONN_FAILED |
| ChargerApp | EVIC/State Machine | CPState faults, EVCC watchdog, connector state tracking |
| OCPP | Central System | WebSocket failure, boot rejection, offline queue, txn reject |
| EnergyManager | Power Management | Session start error, 3ph current flow, power imbalance |
| CertManager | Certificates | Load failures, TPM errors, cert chain issues |
| HealthMonitor | System Health | Reboots, storage fallback, eMMC wear, GPIO, CPU |
| ErrorBoss | Error Coordination | Block-all-sessions, locked warnings |
| Kernel/Syslog | OS Level | Kernel errors, TPM, boot count |
| Firmware/Monit | Updates/Supervisor | FW validation, PowerBoard FW, ProcessRestartedTooOften |
| V2G/HLC | ISO 15118 | 36 Error_* patterns, cable check, precharge timeout |
| Meter/Eichrecht | Billing | RequiredMeterMissing (CRITICAL), terminal/unavailable state |
| Grid Codes | AC Inverter | Frequency/voltage events, inverter disconnection |
| InnerSM | Session State | ERROR_UNAVAILABLE, confirmation timeout, repeating errors |
| EVIC GlobalStop | DC Safety | CableCheck, IMD, rectifier, contactor failures |
| HAL Errors | Hardware Layer | CIU/MIU errors (all CRITICAL) |
| Compliance | EV Behavior | EV disobeys imposed limit, overcurrent |
| PowerBoard Stops | DC Hardware | Overcurrent, ground fault, contactor weld, bender |
| Temperature | Thermal | Overtemperature (CRITICAL), derating, MaximalDerating |
| Tamper | Physical Security | LidOpen (CRITICAL/blocks), LidCloseWaitUnplug |
| Emergency | Safety | EmergencyStop button, ExternalEmergencyStop |
| Config Validation | Properties | 12 checks across 7 config files |
| Error Registry | All Modules | 363-error official registry scan |
| Connector Health | Per-Connector | Dual-connector imbalance detection |
| OCPP Error Codes | Protocol | Official OCPP error code patterns |
| PMQ System Health | IPC | PMQ subscription failures, topic mapping |

### Connector-Level Analysis

For dual-connector chargers, the analyzer attributes errors to specific connectors:

- Identifies connector via: `connector=N`, `ConnectorId=N`, `InnerSM-N`, `evseId=N`, `M1/M2`
- Per-connector error, warning, and session counts
- Imbalance detection: raises targeted issue when one connector has 3x+ more errors
- Connector data flows to: health score, webapp, HTML/MD reports, email, tickets, fleet

### Health Score

Weighted 0–100 score across four dimensions:

| Category | Weight | Covers |
|----------|--------|--------|
| Connectivity | 30% | MQTT success rate, PPP status, Ethernet stability, WiFi, OCPP |
| Hardware | 25% | PowerBoard, temperature, eMMC, kernel, memory, safety, HAL, connectors |
| Services | 25% | OCPP, V2G/HLC, EnergyManager, PMQ, certs, ErrorBoss, meter, InnerSM |
| Configuration | 20% | Config keys, boot count, reboots, registry matches, issue severity |

Grades: A (90+), B (75+), C (55+), D (35+), F (<35)

Connector imbalance on dual-connector chargers penalizes the Hardware category.

### Deep Analysis

`--mode deep` adds 10 forensic investigation modules:

- **Boot timing** — boot event sequence, stage durations, slow boot detection
- **Causal chains** — 10 linked event chains with temporal validation
- **Gap detection** — timeline discontinuities (crashes, power loss, log rotation)
- **Config validation** — .properties file checks for missing keys, suspicious values
- **Error histogram** — error distribution by time bucket with spike detection (>3× average)
- **PMQ interaction map** — inter-process message queue connections, failed subscriptions
- **Charging session reconstruction** — OCPP StatusNotification lifecycle (Preparing→Charging→Finishing), incomplete/faulted session detection, transaction event tracking
- **Reboot / crash timeline** — kernel boots, watchdog resets, OOM kills, kernel panics, monit restarts, systemd crashes, ChargerApp watchdog kills
- **Network connectivity timeline** — OCPP WebSocket lifecycle, BootNotification outcomes, DNS failures, TLS errors, NetworkBoss interface changes
- **Connector state machine validation** — CPStateMachine + LogicStateMachine transitions, OCPP connector status, stuck-in-fault detection, watchdog escalation patterns

All modules produce console display, markdown report sections, and webapp JSON data.

### Reports

| Format | Flag | Description |
|--------|------|-------------|
| Markdown | (default) | Full analysis with evidence, connector breakdown |
| HTML | (default) | Styled report with charts, connector table |
| Web App | `--web` | Interactive SPA with search, filters, connector card |
| Email Brief | `--mail` | Outlook/Gmail-safe inline HTML + plain text, connector stats |
| Tickets | `--tickets` | Per-issue MD + Jira CSV + GitLab JSON, connector attribution |
| Comparison | `--compare` | Side-by-side regression report |
| Fleet | `--fleet` | Multi-charger dashboard with connector column |

### Recursive Directory Scan

`./start.sh` → Load logs → Scan directory recursively finds:
- All supported archives at any depth
- Extracted RACC dirs (`var/aux/` structure)
- Directories containing `.log` files

Shows relative paths, archive type tags (`[ZIP]`, `[TGZ]`, etc.), and file sizes.

### Search & Signatures

```bash
search_logs -p "error" -s E              # Errors containing "error"
search_logs -p "timeout" -c OCPP         # OCPP timeouts
search_logs -p "fault" -n 1              # Connector 1 faults only
search_logs -p ".*" -n 2 -s W            # All Connector 2 warnings
```

| Flag | Description |
|------|-------------|
| `-p` | Search pattern (keyword or regex) |
| `-s` | Severity filter (E/W/I/C/N or ALL) |
| `-c` | Component name filter |
| `-n` | Connector number (1, 2, ...) |
| `-a` / `-b` | Time range (after / before) |
| `-x` | Context lines (0–5) |
| `-r` | Regex mode |
| `-m` | Max results (default 200) |
| `-o` | Export results to file |

526 built-in error signatures + 363-error official registry.

### Archive Support

Supported archive formats for input:

| Format | Extension(s) | Tool Required |
|--------|-------------|---------------|
| ZIP | `.zip` | `unzip` or Python |
| TAR+GZ | `.tar.gz`, `.tgz` | `tar` or Python |
| TAR+BZ2 | `.tar.bz2`, `.tbz2` | `tar` or Python |
| TAR+XZ | `.tar.xz`, `.txz` | `tar` or Python |
| 7-Zip | `.7z` | `p7zip` (`7z`/`7za`) |
| RAR | `.rar` | `unrar` or `rar` |

**Nested archives**: Archives inside archives (e.g. a `.tar.gz` inside a `.zip`) are extracted automatically and recursively, up to 5 levels deep. Extensionless archives are detected via `file` magic.

Password-protected ZIPs: the analyzer will prompt for a password at load time.

### Log Rotation Support

When loading a folder, the analyzer automatically detects and reassembles Linux log rotation sequences:

```
app.log          ← current (newest)
app.log.1        ← yesterday
app.log.2.gz     ← older (decompressed automatically)
app.log.2026-02-17  ← date-stamped rotation
```

All files in a sequence are sorted chronologically and concatenated into a single `_rotation_combined.log` for analysis.

### Content-Based Log Detection

Log files are identified by their content, not their extension. The analyzer reads the first lines of each file and matches against known log signatures:

- IoTecha app format: `2026-02-23 08:19:10.588 [I] component: message`
- Syslog format: `Feb 23 08:19:... hostname process[pid]: message`
- Kernel format: `[  300.326187] message`
- Generic timestamp: `2026-02-23T08:19:10 ...`
- HTTP access log: `127.0.0.1 - - [23/Feb/2026:08:19:10] "GET ..."`

This means extensionless files like `syslog` are detected automatically, and non-log files (binaries, certificates, databases, configs) are skipped regardless of extension.

### Health Score Explanation

Each health score category now shows the specific reasons for deductions:

```
  Connectivity    ████████████░░░░░░░░   63/100  (weight: 30%)
    ↳ -25  MQTT failure rate 82% (critical)
    ↳ -12  Ethernet flapping x8

  Hardware        ████████████████████  100/100  (weight: 25%)
```

### Settings Persistence

Settings are saved to `~/.iotecha_settings` between sessions:

```
evidence level, colors on/off, output directory, log level (info/verbose/DEBUG)
```

Use **Settings → 5 Reset** to restore defaults.

### Fleet Mode

```bash
./analyzer.sh --fleet /path/to/racc-folder/
```

Dashboard: per-charger score, grade, issues, connector info (`single` or `dual:C1err/C2err`), cross-fleet patterns, firmware correlation, connector fleet summary.

### Regression Comparison

```bash
./analyzer.sh --compare before.zip after.zip
```

Detects: new/resolved/persistent issues, metric deltas, status changes, config diffs. Auto verdict.

### Live Monitoring

```bash
./analyzer.sh --watch /path/to/log-dir/
```

Real-time alert feed with signature matching and session recording.

### Web Server

```bash
./analyzer.sh --server [--port 9090]
```

Browser UI with 11 views. REST API (14 endpoints) for programmatic access.

## Platform Compatibility

| Platform | Status | Notes |
|----------|--------|-------|
| Linux (Ubuntu, Debian, etc.) | ✅ Full support | Primary target |
| macOS | ✅ Full support | BSD awk/sed compatible |
| MSYS2 / Git Bash (Windows) | ✅ Full support | PATH sanitization, UAC popup prevention, stdin hang protection |
| WSL | ✅ Full support | Native Linux behavior |
| BusyBox / Alpine | ⚠️ Partial | Core analysis works, some features limited |

**Windows-specific handling:** On MSYS2/Git Bash, the analyzer automatically sanitizes PATH to prevent UAC popups from Windows system directories, uses timeout-protected binary probing, and provides `sort()` wrapper with fallback to avoid stdin hangs from missing MSYS2 packages.

## Error Handling

- All detectors wrapped in `safe_run()` — individual failures don't halt analysis
- EXIT/INT/TERM signal traps with graceful cleanup
- Detector error count tracked in metrics
- Input validation: file size, binary detection, encoding checks

## Performance

- **Batch grep**: `batch_count_grep` uses single awk pass per file instead of individual grep calls. 85 → 26 file scans. ~2.5–3x faster on large log bundles.

## Project Structure

```
loggy/
├── analyzer.sh              # Main entry point
├── start.sh                 # Launcher menu
├── run_tests.sh             # Self-test suite (56 assertions)
├── install.sh               # Installation script
├── CHANGES.md               # Version history
├── README.md                # This file
├── lib/
│   ├── common.sh            # Core utilities, logging, error handling
│   ├── loader.sh            # Input loading (zip, dir, file)
│   ├── parser.sh            # Log parsing engine
│   ├── evidence.sh          # Evidence collection
│   ├── analyzer_standard.sh # Standard analysis (26 detectors, 2885 lines)
│   ├── analyzer_deep.sh     # Deep analysis (10 modules, 1798 lines)
│   ├── scorer.sh            # Health score calculator (975 lines)
│   ├── comparator.sh        # Regression comparison engine
│   ├── searcher.sh          # Search, investigation, signatures
│   ├── watcher.sh           # Live monitoring
│   ├── fleet.sh             # Multi-charger fleet analysis
│   ├── menu.sh              # Interactive menu system
│   ├── server.sh            # Web server launcher
│   └── server_backend.py    # REST API backend (Python3 stdlib)
├── generators/
│   ├── gen_markdown.sh      # Markdown report (with connector breakdown)
│   ├── gen_html.sh          # HTML report (with connector table)
│   ├── gen_webapp.sh        # Interactive web app (with connector card)
│   ├── gen_mail.sh          # Email brief (with connector stats)
│   └── gen_tickets.sh       # Tickets (with connector attribution)
├── signatures/
│   ├── known_signatures.tsv # 526 error signatures
│   └── error_registry.tsv   # 363-error official registry (44 modules)
├── test/
│   ├── test_v2.sh           # Unit tests (84 assertions)
│   ├── test_integration.sh  # Integration tests (29 assertions)
│   └── sample_logs/         # Synthetic test data
└── reports/                 # Generated output
```

## Self-Test

```bash
./run_tests.sh              # Run all tests (56 assertions)
```

Covers: syntax validation (19 files), dependency checks, help/version output, signature counts, standard analysis end-to-end, comparison mode, mail/ticket generation, webapp output. Additional unit tests in `test/test_v2.sh` and integration tests in `test/test_integration.sh`.

## Extending Signatures

Edit `signatures/known_signatures.tsv` or use the interactive menu:

```
# pattern<TAB>component<TAB>severity<TAB>title<TAB>root_cause<TAB>fix<TAB>kb_url
my_pattern	MyComponent	HIGH	My Issue	Root cause	How to fix	https://...
```

## License

Open diagnostic tool for EV charger logs.

---
*Loggy V7.2 — Built 2026*
