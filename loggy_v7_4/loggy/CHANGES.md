# Changelog — Loggy

All notable changes to this project are documented in this file.

---

## v7.2 — 2026-02-25

### Bug Fixes

- **Web server not starting** (`start.sh`): Option 2 used `exec` to launch the server, which replaced the shell process. On MSYS2/Git Bash the terminal window closed immediately when the server exited or failed, making it appear the server never started. Fixed by using `bash` instead of `exec`, so the terminal stays open. Added "Press Ctrl+C to stop" messaging and a "Press Enter to return to menu" prompt after the server exits.

- **Web server port prompt invisible** (`start.sh`): The port prompt was inside a `$()` subshell (`port=$(ask_port)`), which captured stdout and made `printf` invisible to the user. Fixed by inlining the prompt directly in the case block with `read </dev/tty`.

- **`cgi` module crash on Python 3.13** (`server_backend.py`): Python 3.13 removed the `cgi` module. The backend imported it at startup, causing an immediate `ModuleNotFoundError` crash on Python 3.13+. Replaced with a stdlib-only multipart parser using the `email` module, compatible with Python 3.8–3.13+.

- **`python3` not found on MSYS2/Git Bash** (`server.sh`): On MSYS2, Python is often installed as `python` not `python3`. The check only looked for `python3`, silently failing with no actionable error. Now tries `python3` first, then falls back to `python`, with clear install instructions per platform (including `pacman -S python` for MSYS2).

- **Locale-dependent float formatting** (`common.sh` `human_size()`): On systems with a non-English locale (e.g. `fr_FR`), `printf "%.1f"` produced comma decimals (`34,6 KB`) instead of dot decimals, causing `printf: 34,6: invalid number` errors in the log source table. Fixed by replacing shell `printf "%.1f"` with `LC_NUMERIC=C awk "BEGIN{printf ...}"` which always uses C locale regardless of system locale.

- **Progress bar division-by-zero** (`common.sh` `progress_bar()` / `progress_step()`): When `$total` arrived as an empty string, the arithmetic `cur * 100 / total` caused a division-by-zero error. Fixed by running `safe_int` on both `$cur` and `$total` inputs, and returning early when `total <= 0`.

- **Python version check added** (`server.sh`): The web server now verifies Python 3.8+ at startup and shows the detected version. Previously no version check was performed, which could lead to cryptic errors on older Python installs.

---

## V7.0 — Consolidated Stable Release (2026-02-24)

Consolidation of all v5.x/v6.x work into a single clean release.

### Windows Defender Safety (v6.0.2–v6.0.3)
- **Zero binary execution on MSYS2 startup**: `_warn_nonsystem_tools()`, `_safe_probe()`, and `_find_sort()` no longer execute any binary on Windows — path existence checks only
- **Principle**: On MSYS2/Cygwin, trust system paths by `[ -x ]`; execution probes reserved for Linux/macOS

### Deep Analysis — 10 Forensic Modules (v5.7–v6.0)
- Boot timing, Causal chains, Gap detection, Config validation, Error histogram, PMQ map
- **NEW**: Charging sessions, Reboot timeline, Network connectivity, State machine validation
- All 10 modules use normalized `parsed/*.parsed` format consistently
- Webapp JSON emits `deepAnalysis` for any module output (not just causal chains)
- PMQ map exported as `deepAnalysis.pmqMap[]` in JSON

### Bug Fixes
- BootNotification false positive: "isn't accepted" no longer matches "accepted"
- `fleet.sh` printf: 8 format specifiers → 9 (matching arguments)
- `analyzer_deep.sh` printf: added missing `%d` for `$fallback`
- `$discon_files` unguarded grep: empty variable no longer causes hang
- 34 detectors given explicit `return 0` to prevent false failure propagation
- Spinner/log collision: `_log_clear_line()` erases spinner before log output
- Nested archives: `.tar.gz` inside `.zip` now extracted (5 levels deep)
- Content-based log detection: extensionless files (`syslog`, `kern`) now discovered
- Python 3.12+ tar security filter handled with fallback
- Menu reload clears previous load state

### Quality
- 15,023 lines of Bash across 19 source files
- 526 known-issue signatures
- 56 test assertions
- shellcheck clean (0 errors)
- Platforms: Linux, macOS, MSYS2, WSL, BusyBox

---

## V6.0.3 — Windows Defender: Zero Binary Execution on MSYS2 (2026-02-24)

### Critical Fixes
- **`_safe_probe()` no execution on Windows**: On MSYS2/Cygwin, trusts system paths by `-x` check only — never executes binaries. Execution-based sort verification only runs on Linux/macOS
- **`_find_sort()` no probing on Windows**: Trusts system paths (`/usr/bin/sort`, `/mingw64/bin/sort`, `/ucrt64/bin/sort`) by existence check. PATH fallback only probes on non-Windows
- **Complete audit**: Verified all startup code paths — `python3 -c` and `file` in `loader.sh` only run during log loading (not init), confirmed safe

### Principle
On Windows (MSYS2/Cygwin), **never execute any binary during `init_common()`**. Trust system paths by existence. Execution probes reserved for Linux/macOS only.

---

## V6.0.2 — Windows Defender Popup Fix (2026-02-24)

### Critical Fix
- **`_warn_nonsystem_tools()` triggered Defender**: During startup, ran `timeout 3 "$path" --version` on every non-system tool, causing "Action bloquée" popup on corporate MSYS2
- **Fix**: Removed all binary execution — now only checks path location via `case` pattern matching

---

## V6.0.1 — README Update (2026-02-24)

### Documentation
- Deep analysis: 6 → 10 modules with full descriptions
- Line counts updated: analyzer_standard 2885, analyzer_deep 1798, scorer 975
- Signatures: 462 → 526, Tests: "84 unit + 29 integration" → "56 assertions"
- Added `--deep` CLI flag, `h` history command, Platform Compatibility section

---

## V6.0.0 — Deep Analysis Production Release (2026-02-24)

### Fixes
- **BootNotification false positive**: Excluded "isn't accepted yet" from matching as "accepted"
- **Webapp JSON trigger**: `deepAnalysis` now emits if ANY deep output exists (was: only causal chains)
- **PMQ map in JSON**: Added `deepAnalysis.pmqMap[]` with source/dest/type
- **State machine JSON brace**: Fixed syntax error in deep analysis output
- **Summary line break**: Fixed `grep -c` returning "0\n0"
- **LOG_LEVEL default**: Fixed settings writing "INFO" instead of numeric "2"

### Improvements
- **Webapp: 4 new deep analysis views** — Sessions, Reboots, Connectivity, State Machine
- **Error histogram spike detection**: >3x average → MEDIUM issue
- **Incomplete charging sessions**: Preparing→nothing and Fault endings detected
- **SC2155 cleanup**: 30 `local var=$(cmd)` split into declare+assign

### Tests
- **56/56 pass** — 3 previously-failing tests fixed by v5.7.1 parsed migration

---

## V5.7.1 — Deep Analysis: Parsed Files Migration (2026-02-24)

### Changes
- **Migrated all deep analysis to parsed files**: `_deep_boot_timing` and `_deep_pmq_map` now read from `$WORK_DIR/parsed/*.parsed` instead of `$WORK_DIR/*_combined.log`. All 10 steps now consistently use normalized parsed format.
- **Updated `_extract_ts`**: Handles both pipe-delimited parsed format and legacy raw format.
- **PMQ map patterns**: Updated grep patterns from `pmq:.*` (raw) to format-agnostic content matching (works with parsed `|` delimiters).

### Why
- Parsed files have normalized timestamps across all components (syslog, kern, ChargerApp, OCPP all use same `YYYY-MM-DD HH:MM:SS.mmm` format)
- Consistent `|` delimiters make sed/awk extraction reliable
- Same data source for all 10 steps

---

## V5.7.0 — Deep Analysis: 4 New Forensic Modules (2026-02-24)

### Features
- **Charging Session Reconstruction** (step 7/10): Extracts connector status transitions (Preparing→Charging→Finishing) from OCPP StatusNotification and ChargerApp logs. Tracks session start/end times, connector ID, charging state reached, and stop reason. Also counts OCPP transaction events (StartTransaction/StopTransaction/Authorize).
- **Reboot / Crash Timeline** (step 8/10): Consolidates all restart events into a single timeline — kernel boots, watchdog resets, OOM kills, kernel panics, monit service restarts/failures, systemd crashes, ChargerApp watchdog kills. Raises HIGH issues for multiple reboots and OOM events.
- **Network Connectivity Timeline** (step 9/10): Maps OCPP WebSocket lifecycle (connecting→disconnected→failed→reconnecting), BootNotification outcomes, DNS failures, TLS/certificate errors, and NetworkBoss interface selections. Raises CRITICAL if BootNotification never accepted, HIGH for persistent DNS/TLS errors.
- **Connector State Machine Validation** (step 10/10): Extracts CPStateMachine and LogicStateMachine transitions, OCPP connector status changes. Detects stuck-in-fault conditions and watchdog escalation patterns (WARNING→CRITICAL→service kill).
- Deep analysis now runs **10 steps** (was 6). All new modules are additive — existing 6 steps untouched.
- Each module writes its own `.dat` file, raises its own issues via `add_issue`, and has console display + markdown report output.

### Issues Auto-Detected
- CRITICAL: Never Connected to Central System (0 accepted BootNotifications)
- HIGH: Multiple Reboots Detected (>1 kernel boot)
- HIGH: OOM Killer Invoked
- HIGH: Persistent DNS Resolution Failures (>3)
- HIGH: TLS/Certificate Errors
- HIGH: Connector Stuck in Fault State
- CRITICAL: Watchdog Killed Service (WARNING→CRITICAL escalation)

---

## V5.6.0 — UAC/Defender Detection (2026-02-24)

### Features
- **Startup UAC detection**: On MSYS2/Cygwin, `_warn_nonsystem_tools` now probes non-system tools with `timeout 3`. Tools that don't respond are flagged as BLOCKED with a visible console warning and tip to add Defender exclusions.
- **Install check (option 0) → Windows Tool Safety section**: Shows probe results for every non-system tool — OK (probed), NON-SYSTEM, or BLOCKED — with path and count of blocked tools.
- Two layers of defense:
  1. **PATH sanitization** (startup): Strips `/home/*` and `/c/Users/*` from PATH
  2. **Timeout probe** (startup + install check): Detects tools that hang >3s (UAC/Defender)

### Console Output Example (MSYS2 with blocked tools)
```
⚠  Windows Security may block these tools:
sort (/home/user/bin/sort)
Tip: Add MSYS2/Git Bash to Windows Defender exclusions
```

---

## V5.5.0 — Debug Verbosity Toggle (2026-02-24)

### Features
- **Settings menu option 6**: Cycle log level — info → verbose → DEBUG → info
- **`--debug` CLI flag**: Already existed, now documented alongside menu toggle
- **Debug logging added to silent modules**: comparator (baseline/target/rc), searcher (pattern/results), deep analyzer (per-step completion), report generation (output paths)
- Log level display in settings shows name (info/verbose/DEBUG) instead of number

### How to use
- **Menu**: Settings → 6 (cycle through info/verbose/DEBUG)
- **CLI**: `./analyzer.sh --debug -i bundle.zip`
- At DEBUG level, `[DBG]` lines appear on console showing internal operations
- All levels always write to session log file regardless of console verbosity

---

## V5.4.0 — Codebase-wide Return Code Audit (2026-02-24)

### Bug Fixes
- **Explicit `return 0` added to 12 more functions**: `run_standard_analysis`, `generate_predictions`, `health_score_markdown`, `display_health_score`, `_deep_gap_detection`, `_deep_error_histogram`, `deep_analysis_markdown`, `_autoopen_report`, `generate_webapp`, `_extract_component_versions`, `_compare_config`, `parse_log_file`, `parse_properties`.
- **Full audit**: All functions called via `safe_run`, in analysis/report flow, or whose exit code propagates to callers now have explicit `return 0`. Remaining functions (utilities, evidence, menu) are safe — either used in `$()` subshells or intentionally return non-zero.

---

## V5.3.0 — Progress/Log Collision + Detector Exit Codes (2026-02-24)

### Bug Fixes
- **Progress/log message collision**: `log_info`, `log_warn`, `log_error`, `log_ok` now clear the current terminal line before printing. Prevents `[] 1/33[INFO] ...` collisions when a progress bar is active.
- **Registry scan false failure**: `_scan_error_registry` returned non-zero when the last registry hit did not meet issue thresholds (if/elif fell through with exit 1). `safe_run` reported this as a detector failure.
- **All 22 detectors**: Added explicit `return 0` to every detector function called via `safe_run`. Prevents false "failed (exit N)" warnings from bash's implicit exit code (last command's exit status).

---

## V5.2.0 — Loader Progress (2026-02-24)

### Improvements
- **Nested archive extraction**: Spinner during `_extract_nested_archives` (runs twice per load — once before and once after gz decompression)
- **Folder log scanning**: Spinner during content-based `_is_log_file` scanning for non-RACC directories
- Full load pipeline now fully covered: extraction → nested archives → decompression → reassembly → registration — all with visual feedback

---

## V5.1.0 — Universal Progress Feedback (2026-02-24)

### Improvements
- **Searcher**: Spinner during log search operations
- **Comparator**: Spinners for baseline analysis, target analysis, comparison, and report generation phases
- **Standalone generators**: Spinners when calling web app, email brief, or ticket generators directly from menu
- **Log rotation reassembly**: Spinner during `_reassemble_rotations` (can be slow with many rotation files)

### Coverage Summary
All lengthy operations now have visual progress:
- Archive extraction: spinner
- Decompression: progress bar
- Rotation reassembly: spinner (new)
- Registration: step progress
- Parsing: progress bar
- Standard analysis: step progress (33 steps)
- Deep analysis: step progress (6 steps)
- Search: spinner (new)
- Comparison: spinners (new)
- Report generation: step progress + spinners (standalone: new)

---

## V5.0.0 — Shellcheck Clean (2026-02-24)

### Bug Fixes (shellcheck)
- **`local export` in menu.sh**: `export` is a bash keyword — using it as a variable name with `local` shadows the builtin. Renamed to `export_path`.
- **printf format mismatch in fleet.sh**: 8 format specifiers but 9 arguments — missing `%s` for the conn_info field. Data was silently dropped.
- **printf format mismatch in analyzer_deep.sh**: StorageFallbackMode printf had no `%d` but passed `$fallback` as argument. Count was silently ignored.
- **Bare redirections in analyzer_deep.sh**: `> "$outfile"` without command — works but undefined behavior. Changed to `: > "$outfile"`.
- **Shellcheck clean**: Zero errors, zero warnings across all 20+ scripts (excluding SC2154 false positives from `eval "$(batch_count_grep ...)"`)

---

## V4.9.0 — Sort Fallback Stdin Fix (2026-02-24)

### Bug Fixes
- **`sort()` fallback read stdin instead of file**: When `_SORT_BIN=NONE`, `sort() { cat; }` ignored all arguments including the filename, causing `sort -u "$file"` to read stdin and hang. New implementation skips flags, finds the file argument, and cats it. Falls through to stdin only when no file arg is present (pipe usage).

---

## V4.8.0 — Stdin Hang Audit (2026-02-24)

### Bug Fixes
- **Guarded remaining unquoted grep calls in PMQ**: `grep -am1 ... ${alarm_files%% *}` now checks `[ -n "$alarm_files" ]` before running. `grep -roh ... $discon_files` now guarded with `[ -n "$discon_files" ]`. Prevents grep from reading stdin if variables are unexpectedly empty.
- **Full codebase audit**: Checked all 7 scripts with raw grep/awk/sed calls. No other stdin-hang patterns found.

---

## V4.7.0 — PMQ Hang Fix (2026-02-24)

### Bug Fixes
- **PMQ grep hangs on stdin**: `alarm_files`, `overflow_files`, `discon_files` were built with `"$var $f"` which creates a leading space. `${var%% *}` then yields an empty string, causing `grep -am1 pattern` with no file argument to read stdin forever. Fixed by using `"${var:+$var }$f"` which avoids the leading space.

---

## V4.6.0 — PATH Sanitization Logging (2026-02-24)

### Improvements
- **Session log records PATH changes**: When user home directories are stripped from PATH, the removed paths are logged as a WARN in the session log (e.g. `PATH sanitized — removed: /home/user/bin`). Makes debugging transparent.

---

## V4.5.0 — PATH Sanitization (2026-02-24)

### Security
- **MSYS2/Cygwin PATH cleanup**: `detect_environment()` now strips user home directories (`/home/*`, `/c/Users/*`) from PATH on MSYS2 and Cygwin. This prevents any binary in `~/bin/` from shadowing system tools and triggering UAC elevation popups. Applies to all commands (sort, grep, awk, etc.), not just sort.
- Three layers of defense now active: (1) PATH sanitization, (2) `_safe_probe()` with timeout, (3) `sort()` wrapper function

---

## V4.4.0 — Sort Wrapper Fallback (2026-02-24)

### Bug Fixes
- **`sort()` passthrough when NONE**: When no working GNU sort is found (`_SORT_BIN=NONE`), the sort wrapper was not created, leaving 26 raw `sort` calls to resolve via PATH to `~/bin/sort` — triggering UAC. Now defines `sort() { cat; }` as a safe no-op passthrough that prevents PATH resolution. Output will be unsorted but analysis completes without hanging.

---

## V4.3.0 — Global Sort Override (2026-02-24)

### Bug Fixes
- **`sort()` shell wrapper**: After `_find_sort()` validates a safe sort binary, a `sort()` function is defined that overrides all PATH-based `sort` lookups across every script. This prevents 26 raw `sort` calls (in analyzers, comparator, fleet, generators) from resolving to a non-system binary that could trigger UAC popups on MSYS2.
- **Root cause**: PMQ Health analysis hung at step 17/33 because `sort -u` in a pipe resolved to `~/bin/sort` on MSYS2, triggering a UAC elevation popup that blocked execution.

---

## V4.2.0 — UAC Timeout Detection (2026-02-24)

### Improvements
- **`_safe_probe()` helper**: Universal binary safety check using `timeout 3`. Any tool probe that takes >3 seconds (indicating a Windows UAC popup is blocking) is automatically skipped. Works regardless of binary location — catches UAC from any path, not just user-home directories.
- **`_find_sort()`**: Now uses `_safe_probe()` for all candidate binaries instead of path-based filtering.

---

## V4.1.0 — Sort UAC Fix (2026-02-24)

### Bug Fixes
- **`_find_sort()` UAC popup on MSYS2**: When probing for a working `sort` binary, the fallback `command sort` could resolve to a non-system binary in the user's home directory (e.g. `/home/user/bin/sort`), which on Windows triggers a UAC elevation popup. Now resolves the path first and only probes binaries in known system locations (`/usr/bin`, `/bin`, `/usr/local/bin`, `/mingw*/bin`, `/ucrt*/bin`).

---

## V4.0.0 — Nested Archives, Content Detection & MSYS2 Fixes (2026-02-23)

### Rebrand
- **Renamed to Loggy**: All user-facing display text, banners, report footers, and documentation updated from "IoTecha Log Analyzer" to "Loggy". Internal logic, detection paths, and settings file paths unchanged.
- **Version jump**: 2.4 → 4.0 (v3.x skipped)

### MSYS2/Windows Compatibility
- **`_pypath()` helper**: Python on MSYS2 is a native Windows binary that cannot resolve MSYS2 paths like `/tmp/`. New `_pypath()` uses `cygpath -m` to convert all paths passed to Python fallback commands
- **Python 3.12+ tarfile security filter**: RACC tarballs contain symlinks (e.g. `etc/dropbear` → `/var/run/dropbear`) that trigger `LinkOutsideDestinationError` on Python 3.12+. All `extractall()` calls now use `filter='fully_trusted'` where supported
- **Python fallback for all tar formats**: `_extract_nested_archives` now has Python `tarfile` fallback for `.tar.gz`, `.tar`, `.tar.bz2`, `.tar.xz` (matching `_load_zip` which already had them)
- **Two-pass extraction**: Runs nested extraction both before and after `.gz` decompression, handling the case where `gunzip` produces a `.tar` that needs a second pass

### Nested Archive Extraction
- **Recursive archive unpacking**: `_load_zip` now scans extracted contents for inner archives (`.zip`, `.tar.gz`, `.tgz`, `.tar`, `.tar.bz2`, `.tar.xz`, `.7z`, `.rar`) and extracts them in place — loops until no more archives are found, up to 5 nesting levels
- **Extensionless archive detection**: Inner archives without recognized extensions are detected via `file` magic
- **Previously**: A zip containing `logs.tar.gz` would yield 0 log sources — the inner tarball was ignored

### Content-Based Log Discovery
- **`_is_log_file()` helper**: Identifies log files by content signature (first 10 lines), not file extension. Matches IoTecha app, syslog, kernel, generic timestamp, and HTTP access log formats
- **`_register_component_logs()`**: Uses `_is_log_file()` instead of globbing `*.log *.log.* *.txt`
- **System logs auto-detected**: Replaced hardcoded `kern.log`/`syslog`/`auth.log` with content-based scan of `var/aux/log/*`
- **`_load_folder()` loose staging**: Uses `_is_log_file()` instead of extension filtering

### Bug Fixes
- **`_check_loaded()` false negative**: Used `DEVICE_ID != unknown` which fails for RACCs without `info_commands.txt`. Now checks actual log count
- **Duplicate logs on menu reload**: `load_input()` now clears previous state before loading

---

## V2.3.0 — Bug Fixes & Console Logging (2026-02-21)

### Bug Fixes
- **`cleanup_all()` re-enabled**: Removed debug `return 0; #TMP` that prevented temp directory cleanup — `/tmp/iotlog.*` directories were leaking on every run
- **`get_metric()` stale reads fixed**: Changed `head -1` → `tail -1` so updated metrics return the latest value instead of the first (stale) one
- **Timeline `grep -am1` missing `-E` flag**: 4 `add_timeline_event` calls used `|` alternation without `-E`, causing grep to match a literal pipe instead of OR — affected MQTT, Ethernet, PowerBoard, and CertManager timeline timestamps (always empty)
- **Trap chain restored**: `_analyzer_cleanup()` now calls `cleanup_all()` so the EXIT trap set by `_setup_error_handling` doesn't silently discard the main cleanup registered in `main()`
- **Health score weights in `--help`**: Corrected from 40/20/20/20 to 30/25/25/20 to match actual `scorer.sh` weights
- **`menu.sh` parse errors fixed**: Removed single-quotes inside `$(...)` command substitutions that caused `unexpected EOF while looking for matching` errors on source — affected `_clean_path` (line 81-82) and `_menu_settings` (line 937/957)
- **Config validator performance**: Replaced O(lines × patterns) grep-per-key loop with single awk pass per file — eliminates ~26,000 subprocess spawns, critical for MSYS2/ucrt64 where it caused multi-minute hangs

### Console Logging
- **Full console capture**: All stdout and stderr is now tee'd to `*_console.log` alongside the structured session log — faithful replay of everything printed, including ANSI codes, spinners, and progress bars
- Console log path printed at session start and end in batch, fleet, and compare modes

### Version Housekeeping
- `ANALYZER_VERSION` bumped to 2.3
- All file header comments updated to v2.3 (previously a mix of v1.0 and v2.0)

---

## V2.2.0 — Major Enhancement Release (2026-02-21)

### Scan & Loading
- **Recursive scan**: `_menu_scan_dir` now scans all depths (not just 2 levels) using `find` → Python `os.walk` → deep glob fallback chain — works on Linux, macOS, WSL, MSYS2/Git Bash
- **All archive formats**: Supports zip, tar.gz/tgz, tar.bz2/tbz2, tar.xz/txz, 7z, rar — with native tool → Python fallback for each
- **Password-protected zip**: Detects password-protected zips, prompts user for password before extraction
- **Log rotation reassembly**: `_load_folder` now detects numbered and date-stamped Linux log rotation sequences (e.g. `app.log`, `app.log.1`, `app.log.2.gz`), decompresses gz rotations, sorts chronologically and concatenates into a single combined log per component
- **Loose log staging**: Non-RACC directories with `.log` files now automatically stage them into `var/aux/manual` so `_discover_logs` can find them
- **Relative paths in scan**: Scan results show paths relative to the scanned directory instead of full absolute paths
- **Scan summary**: Shows count of archives/RACC dirs/log dirs found; clear "nothing found" message with hints when empty
- **Archive type tags**: Scan displays `[ZIP]`, `[TGZ]`, `[TBZ]`, `[TXZ]`, `[7Z]`, `[RAR]` labels

### Path Normalization
- **MSYS2/Windows**: `_clean_path` now handles Windows paths — `C:\Users\...` and `C:/Users/...` → `/c/Users/...` using `cygpath` when available, manual conversion as fallback

### Analysis Fixes
- **Detector silent-fail audit**: Fixed `_analyze_i2p2_mqtt`, `_analyze_network_boss`, `_analyze_cert_manager` — all missing `return 0` on last line, causing `safe_run` to flag them as failed
- **`_analyze_charger_app`**: Fixed spurious failure exit code (previously triggered "detector failed" warning on every clean run)
- **`safe_run` exit code**: Fixed — old `if ! "$fn"` pattern captured post-negation `$?` (always 0); now captures real exit code in `$_rc`
- **Config severity scaling**: Config validation now raises MEDIUM (not just LOW) when 3+ issues are found; unknown/extra config keys are now detected and reported

### Health Score Explanation
- **Per-category penalty reasons**: Each health score category now shows the specific reasons for point deductions (e.g. `↳ -30  MQTT failure rate 85% (critical)`)
- **`_score_penalty` helper**: New function tracks penalty reasons in per-category arrays during scoring; displayed by `_display_category`
- **All 4 categories annotated**: Connectivity (6 penalties), Hardware (13 penalties), Services (7 penalties), Configuration (3 penalties)

### File Detection
- **Binary/corrupt file detection**: `validate_log_file` now uses a 3-method cascade — `grep -P` → Python → `file` command — for cross-platform null-byte detection; also detects unreadable/corrupt files by checking size vs readable line count; uses `stat -f%z` fallback for macOS

### UX & Menu
- **Settings persistence**: Settings (evidence level, colors, output dir, log level) now saved to `~/.iotecha_settings` and loaded on startup
- **Progress for reports**: `generate_reports` now shows spinner feedback for each report type being generated
- **History with findings**: Session history now shows loaded device ID, total issues by severity, and health score/grade
- **Clear empty-scan messaging**: Scan with no results shows specific hints (check path, try parent dir, list supported formats)

### Reporting
- **Report filename fallback**: When device ID is unknown, report filename now falls back to input filename + timestamp instead of `analysis_unknown_...`
- **HTML auto-open**: After generating reports, HTML report is automatically opened in the system browser (macOS: `open`, Linux: `xdg-open`, Windows/MSYS2: `start`)
- **Email Outlook/Gmail compatibility**: HTML email template updated with MSO conditional comments, `role="presentation"` tables, `border-collapse:collapse`, removed `border-radius` (not supported in Outlook), added `mso-table-lspace/rspace` resets

### Search
- **Paginated results**: `search_logs` now paginates at 50 results/page with `[n]ext / [p]rev / [a]ll / [q]uit` navigation instead of hard-cutting at 100

### Fleet
- **Cross-charger timeline correlation**: `_fleet_correlate_timelines` finds ERROR/CRITICAL events within a 5-minute window across multiple chargers — indicates shared infrastructure issues (grid, network, backend outage). Requires Python; skipped gracefully if unavailable.

### Bug Fixes
- `progress_bar` / `progress_step`: Fixed division-by-zero when `$total` arrives as empty string (now runs `safe_int` on inputs first)
- `validate_log_file`: `stat -c%s` fallback added for macOS (`stat -f%z`)

---

## V2.2.1 — Post-V2.2 Improvements (2026-02-20)

### Performance Optimization
- **Batch grep**: Converted 85 individual `count_grep` calls to 26 `batch_count_grep` calls
- Each batch uses single `awk` pass with multiple pattern counters instead of separate `grep` processes
- ~2.5–3x faster analysis on large log bundles
- 5 remaining single `count_grep` calls are loop-based (1 pattern/file) where batching provides no benefit

### Connector-Level Analysis (New Detector)
- New `_analyze_connector_health` detector — single awk pass per log file
- Identifies connector-attributed events via: `connector=N`, `ConnectorId=N`, `InnerSM-N`, `evseId=N`, `evse-N`, `socket N`, `M1/M2`, `Connector[N]`
- Per-connector metrics: `conn1_errors`, `conn1_warnings`, `conn1_sessions`, `conn2_*`
- Imbalance detection: raises targeted issue when one connector has 3x+ more errors (minimum 3)
- Total detectors: 25 → 26, analysis steps: 28 → 29

### Connector Data Integration
- **Health score**: Connector imbalance penalizes Hardware category (-10 to -15)
- **Webapp**: New "🔌 Connector Health" dashboard card with per-connector error/warning bars
- **HTML report**: Connector breakdown table in health score section
- **Markdown report**: Connector breakdown table
- **TUI**: Connector line in health summary display
- **Email** (text + HTML): Connector stats in header metrics
- **Tickets**: Auto-detected `| Connector | Connector N |` metadata row

### Search Enhancement
- New `-n <connector>` flag for `search_logs` — filters results to specific connector
- Matches all IoTecha connector identification patterns
- Works in combination with all existing filters (-p, -s, -c, -a, -b)

### Fleet Connector Aggregation
- Per-charger connector info in fleet data (9th column: `single` or `dual:C1err/C2err`)
- TUI dashboard: "Connectors" column in charger table
- Fleet summary: dual/single count + imbalance warning count
- Markdown report: "Connectors" column in charger table
- HTML report: "Connectors" column in charger table

### Test Expansion
- Integration tests: 22 → 29 assertions
- New: config validation trigger scenarios (low timeout, disabled eMMC monitoring)
- New: `multi_connector` and `config_warnings` metric assertions
- New: connector imbalance issue detection assertion
- New: config validation issue detection assertion
- New: `_analyze_properties` in detector run list

---

## V2.2 — Source-Informed Upgrade (2026-02-20)

### Error Registry Integration
- Imported official **363-error registry** from IoTecha firmware source (44 modules, 8 severity types)
- Registry loaded by searcher, analyzer, and web backend
- All detectors now reference official error names, descriptions, and troubleshooting steps

### Detectors: 7 → 53 issue detection points
**Enhanced existing:**
- OCPP: +OCPP_CONNECTION_ERROR, +boot rejection pattern, +offline queue, +txn rejected pre-boot
- V2G/HLC: all 36 Error_* names (18 timeouts, power delivery, car-not-ready, EXI errors)
- Firmware: 5 specific validation errors + PowerBoardFirmwareUpdateFailed (CRITICAL)
- eMMC: high vs critical wearing distinguished, FSSwitchToRO, StorageFallbackMode
- Monit: split into ProcessRestartedTooOften (HIGH) + AppHasRestarted + HighCpuUsage
- Reboot: planned vs unplanned, SoftReset, EVIC reboot from CommonEVIC
- HMI: HMIBboardIsNotReady + HMIBoardInitTimeout with official troubleshooting
- Emergency: ExternalEmergencyStop distinguished from button press
- Meter: 12 registry entries (RequiredMeterMissing CRITICAL, Eichrecht TERMINAL/UNAVAILABLE/ORPHAN)
- Tamper: LidOpen (CRITICAL/blocks) + LidCloseWaitUnplug (must unplug to clear)
- EnergyManager: +session start failure, +3ph current flow, +power imbalance, +state errors

**New detectors:**
- Temperature/Overtemperature: 12+ patterns (CRITICAL blockers through LOW derating)
- WiFi AP/client: NETWORK_NOT_FOUND, CONN_FAILED, SSID-TEMP-DISABLED, driver reload

### Reports
- Troubleshooting steps extracted into dedicated styled blocks (MD, HTML, tickets)
- On-site service flag (🚨) displayed prominently
- Jira/GitLab tickets auto-tagged with `on-site-service` label

### Causal Chains: 6 → 10
- PMQ chain: names all PMQ topics from source IDL
- +Thermal→Power cascade
- +Storage degradation cascade
- +Meter→Eichrecht→Billing cascade
- +V2G/HLC communication breakdown

### Health Score
- Rebalanced weights: Connectivity 30%, Hardware 25%, Services 25%, Config 20%
- New penalties: temperature, lid open, PowerBoard FW fail, WiFi, OCPP_CONNECTION_ERROR, meter missing, EnergyManager, power imbalance, Monit crash-loop

### Config Validation
- Validates real config keys from Layer 4 product configurations
- Checks: interfaceSelectionManager, ppp0/eth0 enabled, digitalCommunicationTimeout_ms, OCPP csUrl, OfflineTimeout_s

---

## V1.0 — Full Release (2026-02-20)

### Phase 13 — Web Server Mode
- **`--server`** flag launches browser-based UI at `http://localhost:8080`
- **`--port`** flag for custom port
- Python3 HTTP backend (`lib/server_backend.py`) — REST API, stdlib only, no pip
- Single-page HTML frontend (`lib/server_frontend.html`) — dark theme, sidebar, keyboard shortcuts
- **11 browser views**: Load Logs, Run Analysis, Results, Search, Components, Signatures, Compare, Fleet, Reports, Check Install, Help
- Drag-and-drop RACC upload or server-path loading
- Session management for concurrent analyses
- Full REST API (14 endpoints) for programmatic access
- **Help view** — complete reference (flags, detectors, scores, reports, shortcuts) built into web UI
- **`start.sh`** launcher menu — guided start for all modes, no flags to remember

### Phase 12 — Self-Test & Packaging
- `run_tests.sh` — 56 automated tests across 8 categories
- Test suites: syntax (22 files), dependencies (12 tools), help/version, signatures, standard analysis, comparison, mail/tickets, web app
- `README.md` quick reference
- `README.html` comprehensive documentation (1200+ lines, 26 sections, sidebar nav)
- `install.sh` installation script
- `CHANGES.html` visual changelog

### Phase 11 — Fleet Mode
- **`--fleet <dir>`** analyzes all RACC .zip files in a directory
- Fleet dashboard sorted by health score (worst first)
- Cross-fleet pattern detection: shared vs unique issues
- Firmware version correlation across chargers
- Fleet MD + HTML reports (`fleet.sh`, 315 lines)

### Phase 10 — Live Monitoring
- **`--watch <dir>`** tails log directory in real time
- Uses `inotifywait` when available, falls back to 2-second polling
- Color-coded alert feed: errors red, warnings orange, criticals flash
- Pattern matching against signature database
- Session recording to `watch_*.log` for later analysis
- Graceful Ctrl+C with session summary (`watcher.sh`, 209 lines)

### Phase 9 — Mail & Tickets
- **`--mail`** generates email brief:
  - Plain text (.txt) with auto subject line including severity + score
  - Inline-CSS HTML safe for Outlook, Gmail, Apple Mail
- **`--tickets`** generates per-issue tickets:
  - Individual Markdown file per issue with root cause + fix
  - Jira CSV for bulk import (Summary, Priority, Component, Labels, Description)
  - GitLab JSON array for API issue creation
- Signature auto-match populates root cause and fix in tickets
- `gen_mail.sh` (210 lines), `gen_tickets.sh` (111 lines)

### Phase 8 — Search, Investigation & Signatures
- **Search engine** with filters: keyword/regex, severity (E/W/I/C/N), component, time range, context lines, max results, export to file
- **Component investigation** — deep dive: log stats, related issues, timeline events, top error messages (normalized, deduplicated), signature matches
- **Signature database** (`signatures/known_signatures.tsv`) — 80 built-in error signatures + 363-error registry:
  - TSV format (no YAML/jq dependency)
  - Each pattern: regex → component → severity → title → root cause → fix → KB URL
  - Covers: MQTT, PPP, Ethernet, WiFi, OCPP, Certs, PMQ, Reboots, Kernel, GPIO, TPM, PowerBoard, EVCC
  - Auto-match: all detected issues matched against database
  - Interactive signature management: list, add, reset
- `searcher.sh` (674 lines)

### Phase 7 — Regression Comparison
- **`--compare <baseline> <target>`** — side-by-side analysis of two RACC captures
- Issue diff: new issues, resolved issues, persistent issues
- Metric deltas: 13 key metrics with delta and % change
- Smart color coding: MQTT failures up = red, MQTT successes up = green
- Subsystem status changes with ▲ improved / ▼ regressed indicators
- Config (.properties) diff: added/removed/changed keys
- Auto-verdict engine: Improvement / Regression / Mixed / No change / Clean
- Comparison MD + HTML reports
- `comparator.sh` (782 lines)

### Phase 6 — Deep Analysis
- **`--mode deep`** adds 6 investigation modules:
  - **Boot timing** — boot event sequence, stage durations, slow boot detection
  - **Causal chains** — links events across components (PPP down → MQTT fail → OCPP disconnect)
  - **Gap detection** — timeline discontinuities (crashes, power loss, log rotation)
  - **Config validation** — .properties file checks for missing keys, suspicious values
  - **Error histogram** — error distribution by time bucket (boot, steady-state, storms)
  - **PMQ interaction map** — inter-process message queue connections, failed subscriptions
- `analyzer_deep.sh` (460 lines)

### Phase 5 — Health Score & Predictions
- Automatic **0–100 health score** with weighted categories:
  - Connectivity 40% (MQTT, PPP, Ethernet, WiFi)
  - Hardware 20% (Power board, GPIO, boot, reboots)
  - Services 20% (OCPP, EVCC, PMQ, components)
  - Configuration 20% (Certificates, config validation)
- Letter grades: A (90+), B (75+), C (60+), D (40+), F (<40)
- Predictive alerts — forward-looking warnings based on metric trends
- `scorer.sh` (350 lines)

### Phase 4 — Interactive Web App
- **`--web`** generates self-contained HTML SPA (~130KB, works offline)
- 6 interactive views: Dashboard, Issues, Timeline (301+ events), Error Summary, Search, System Info
- Embedded JSON data — no server needed
- Dark theme, DM Sans + JetBrains Mono fonts
- Keyboard shortcuts (1–6), responsive, print-friendly
- `gen_webapp.sh` (1200+ lines — largest generator)

### Phase 3 — Report Generation
- **Markdown reports** — full analysis with issues, status, metrics, evidence, timeline
- **HTML reports** — styled dark-theme, collapsible evidence blocks, print-friendly
- Reports auto-generated on every analysis run
- `gen_markdown.sh` (380 lines), `gen_html.sh` (520 lines)

### Phase 2 — Standard Analysis
- **34+ issue detectors** across all EV charger subsystems:
  1. MQTT connection failure (AWS IoT Core)
  2. PPP/Cellular not established (modem/SIM)
  3. Ethernet link flapping (PHY/cable)
  4. Certificate manager warnings (TPM/cert)
  5. EVCC watchdog warnings (timing)
  6. Power board fault at boot (relay/contactor)
  7. PMQ subscription failures (IPC)
- **Subsystem status** for 7 systems (MQTT, OCPP, PPP, Ethernet, WiFi, Certs, PowerBoard)
- **37+ metrics** collected (error counts, connection rates, boot events, etc.)
- **Timeline** generation (301+ events from all log sources)
- `analyzer_standard.sh` (2200+ lines — largest module)

### Phase 1 — Foundation
- **Pure Bash** architecture — no Python, Node, Docker, jq, or yq
- **MSYS2/Git Bash** compatible (pure-awk sort, no GNU extensions)
- Auto-detection of input format: RACC .zip, directory, individual files
- **Log parser** — handles IoTecha app format, syslog, kern.log, .properties, info_commands.txt
- 19+ component log files recognized
- **Evidence collection** — min/std/full levels
- Color output with `--no-color` support
- Session logging, temp directory management, cleanup traps
- `common.sh`, `loader.sh`, `parser.sh`, `evidence.sh`

---

## Project Statistics

| Metric | Value |
|--------|-------|
| Total lines of code | ~13,600 |
| Shell scripts (.sh) | 25 |
| Python files | 1 (server backend) |
| HTML files | 9 (reports, web app, frontend, docs) |
| Self-tests | 113 (84 unit + 29 integration) |
| Error signatures | 462 (+363 registry) |
| Issue detectors | 26 |
| Report formats | 9 |
| Deep analysis modules | 6 |
| Causal chains | 10 |
| Config validation checks | 12 |
| Platforms supported | 6 (Linux, macOS, WSL, MSYS2, Docker, BusyBox) |
| External dependencies | 0 (bash + coreutils only) |

---

*IoTecha Log Analyzer V1.0 — Built 2026*
