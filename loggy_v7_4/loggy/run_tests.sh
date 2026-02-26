#!/bin/bash
# run_tests.sh — Self-Test Suite
# Loggy v6.0 — Phase 12
#
# Validates analyzer output against expected results.
# Usage: ./run_tests.sh [test_name]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANALYZER="$SCRIPT_DIR/analyzer.sh"
TEST_DIR="$SCRIPT_DIR/test"
PASS=0 FAIL=0 SKIP=0

# ─── Colors ──────────────────────────────────────────────────────────────────
R=$'\033[31m' G=$'\033[32m' Y=$'\033[33m' C=$'\033[36m' B=$'\033[1m' D=$'\033[2m' X=$'\033[0m'

ok()   { PASS=$((PASS + 1)); printf "  ${G}✓${X} %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  ${R}✗${X} %s\n    ${D}expected: %s${X}\n    ${D}     got: %s${X}\n" "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP + 1)); printf "  ${Y}○${X} %s (skipped)\n" "$1"; }
header() { printf "\n${B}${C}━━━ %s ━━━${X}\n" "$1"; }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        ok "$label"
    else
        fail "$label" "$expected" "$actual"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qi "$needle"; then
        ok "$label"
    else
        fail "$label" "contains '$needle'" "$(echo "$haystack" | head -c 120)"
    fi
}

assert_gt() {
    local label="$1" expected="$2" actual="$3"
    if [ "${actual:-0}" -gt "$expected" ] 2>/dev/null; then
        ok "$label ($actual > $expected)"
    else
        fail "$label" "> $expected" "$actual"
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        ok "$label"
    else
        fail "$label" "file exists" "not found: $path"
    fi
}

# ─── Test: Syntax Check ─────────────────────────────────────────────────────
test_syntax() {
    header "Syntax Check"
    local errors=0
    for f in "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR"/generators/*.sh "$ANALYZER"; do
        [ -f "$f" ] || continue
        if bash -n "$f" 2>/dev/null; then
            ok "$(basename "$f")"
        else
            fail "$(basename "$f")" "valid syntax" "syntax error"
            errors=$((errors + 1))
        fi
    done
    return $errors
}

# ─── Test: Dependencies ─────────────────────────────────────────────────────
test_deps() {
    header "Dependencies"
    for cmd in bash awk grep sed wc cut head tail sort uniq date tr; do
        if command -v "$cmd" >/dev/null 2>&1; then
            ok "$cmd available"
        else
            fail "$cmd" "available" "missing"
        fi
    done
}

# ─── Test: Analysis on sample data ──────────────────────────────────────────
test_analysis() {
    header "Standard Analysis"

    local sample=""
    # Try to find a sample RACC
    for f in "$TEST_DIR"/sample*.zip "$TEST_DIR"/*.zip /mnt/user-data/uploads/*.zip; do
        [ -f "$f" ] && { sample="$f"; break; }
    done

    if [ -z "$sample" ]; then
        skip "No sample RACC zip found — place one in $TEST_DIR/"
        return 0
    fi

    printf "  ${D}Using: %s${X}\n" "$(basename "$sample")"

    local tmp_out
    tmp_out=$(mktemp -d "${TMPDIR:-/tmp}/iottest.XXXXXX")

    local output
    output=$(bash "$ANALYZER" -o "$tmp_out" "$sample" 2>&1)
    local rc=$?

    assert_eq "Exit code 0" "0" "$rc"
    assert_contains "Analysis complete" "analysis complete" "$output"
    assert_contains "Issues found" "issues found" "$output"

    # Check output files
    local md_file html_file
    md_file=$(ls "$tmp_out"/*.md 2>/dev/null | head -1)
    html_file=$(ls "$tmp_out"/*.html 2>/dev/null | head -1)

    [ -n "$md_file" ] && assert_file_exists "Markdown report" "$md_file" || fail "Markdown report" "exists" "not generated"
    [ -n "$html_file" ] && assert_file_exists "HTML report" "$html_file" || fail "HTML report" "exists" "not generated"

    # Check MD content (grep file directly — variable can exceed echo buffer)
    if [ -n "$md_file" ] && [ -f "$md_file" ]; then
        if grep -qi "Issues" "$md_file"; then ok "MD has issues section"; else fail "MD has issues section" "contains 'Issues'" "$(head -c 120 "$md_file")"; fi
        if grep -qi "Metrics\|Metric" "$md_file"; then ok "MD has metrics"; else fail "MD has metrics" "contains 'Metrics'" "$(head -c 120 "$md_file")"; fi
    fi

    # Check issue count from output
    local issue_count
    issue_count=$(echo "$output" | grep -o '[0-9]* issues found' | grep -o '[0-9]*')
    assert_gt "At least 1 issue" 0 "${issue_count:-0}"

    rm -rf "$tmp_out"
}

# ─── Test: Comparison mode ───────────────────────────────────────────────────
test_comparison() {
    header "Comparison Mode"

    local sample=""
    for f in "$TEST_DIR"/sample*.zip "$TEST_DIR"/*.zip /mnt/user-data/uploads/*.zip; do
        [ -f "$f" ] && { sample="$f"; break; }
    done

    if [ -z "$sample" ]; then
        skip "No sample RACC for comparison test"
        return 0
    fi

    local tmp_out
    tmp_out=$(mktemp -d "${TMPDIR:-/tmp}/iottest.XXXXXX")

    local output
    output=$(bash "$ANALYZER" -o "$tmp_out" --compare "$sample" "$sample" 2>&1)
    local rc=$?

    assert_eq "Comparison exit code 0" "0" "$rc"
    assert_contains "Comparison complete" "Comparison complete" "$output"
    assert_contains "Persistent issues" "Persistent" "$output"

    local cmp_md
    cmp_md=$(ls "$tmp_out"/comparison_*.md 2>/dev/null | head -1)
    [ -n "$cmp_md" ] && assert_file_exists "Comparison MD" "$cmp_md" || fail "Comparison MD" "exists" "not generated"

    rm -rf "$tmp_out"
}

# ─── Test: Mail & Tickets ───────────────────────────────────────────────────
test_mail_tickets() {
    header "Mail & Tickets"

    local sample=""
    for f in "$TEST_DIR"/sample*.zip "$TEST_DIR"/*.zip /mnt/user-data/uploads/*.zip; do
        [ -f "$f" ] && { sample="$f"; break; }
    done

    if [ -z "$sample" ]; then
        skip "No sample RACC for mail/tickets test"
        return 0
    fi

    local tmp_out
    tmp_out=$(mktemp -d "${TMPDIR:-/tmp}/iottest.XXXXXX")

    local output
    output=$(bash "$ANALYZER" -o "$tmp_out" --mail --tickets "$sample" 2>&1)
    local rc=$?

    assert_eq "Mail/tickets exit code 0" "0" "$rc"

    local mail_file
    mail_file=$(ls "$tmp_out"/mail_*.txt 2>/dev/null | head -1)
    [ -n "$mail_file" ] && assert_file_exists "Mail text report" "$mail_file" || fail "Mail text" "exists" "not generated"

    local ticket_dir
    ticket_dir=$(ls -d "$tmp_out"/tickets_* 2>/dev/null | head -1)
    if [ -n "$ticket_dir" ] && [ -d "$ticket_dir" ]; then
        ok "Tickets directory exists"
        local jira_csv="$ticket_dir/jira_import.csv"
        [ -f "$jira_csv" ] && assert_file_exists "Jira CSV" "$jira_csv" || fail "Jira CSV" "exists" "not generated"
    else
        fail "Tickets directory" "exists" "not generated"
    fi

    rm -rf "$tmp_out"
}

# ─── Test: Webapp ────────────────────────────────────────────────────────────
test_webapp() {
    header "Web App"

    local sample=""
    for f in "$TEST_DIR"/sample*.zip "$TEST_DIR"/*.zip /mnt/user-data/uploads/*.zip; do
        [ -f "$f" ] && { sample="$f"; break; }
    done

    if [ -z "$sample" ]; then
        skip "No sample RACC for webapp test"
        return 0
    fi

    local tmp_out
    tmp_out=$(mktemp -d "${TMPDIR:-/tmp}/iottest.XXXXXX")

    local output
    output=$(bash "$ANALYZER" -o "$tmp_out" --web "$sample" 2>&1)
    local rc=$?

    assert_eq "Webapp exit code 0" "0" "$rc"

    local webapp_file
    webapp_file=$(ls "$tmp_out"/webapp_*.html 2>/dev/null | head -1)
    [ -n "$webapp_file" ] && assert_file_exists "Webapp HTML" "$webapp_file" || fail "Webapp" "exists" "not generated"

    if [ -n "$webapp_file" ] && [ -f "$webapp_file" ]; then
        if grep -q 'v-dashboard' "$webapp_file"; then
            ok "Webapp has dashboard view"
        else
            fail "Webapp has dashboard" "contains v-dashboard" "not found"
        fi
        if grep -q '"issues"' "$webapp_file"; then
            ok "Webapp has JSON data"
        else
            fail "Webapp has JSON data" "contains issues JSON" "not found"
        fi
    fi

    rm -rf "$tmp_out"
}

# ─── Test: Signatures ───────────────────────────────────────────────────────
test_signatures() {
    header "Signatures"

    local sig_file="$SCRIPT_DIR/signatures/known_signatures.tsv"
    assert_file_exists "Default signatures file" "$sig_file"

    if [ -f "$sig_file" ]; then
        local count
        count=$(grep -cv '^#\|^$' "$sig_file" 2>/dev/null || echo 0)
        assert_gt "At least 10 signatures" 10 "$count"
    fi
}

# ─── Test: Help ──────────────────────────────────────────────────────────────
test_help() {
    header "Help & Version"
    local output
    output=$(bash "$ANALYZER" --help 2>&1)
    assert_contains "Help shows usage" "Usage" "$output"
    assert_contains "Help shows --compare" "compare" "$output"

    output=$(bash "$ANALYZER" --version 2>&1)
    assert_contains "Version output" "7.2" "$output"
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    printf "\n${B}Loggy — Self-Test Suite${X}\n"
    printf "${D}%s${X}\n" "$(date '+%Y-%m-%d %H:%M:%S')"

    local test_filter="${1:-}"

    if [ -n "$test_filter" ]; then
        # Run specific test
        if type "test_$test_filter" >/dev/null 2>&1; then
            "test_$test_filter"
        else
            printf "${R}Unknown test: %s${X}\n" "$test_filter"
            printf "Available: syntax deps analysis comparison mail_tickets webapp signatures help\n"
            exit 1
        fi
    else
        # Run all tests
        test_syntax
        test_deps
        test_help
        test_signatures
        test_analysis
        test_comparison
        test_mail_tickets
        test_webapp
    fi

    printf "\n${B}━━━ Results ━━━${X}\n"
    printf "  ${G}Passed: %d${X}  ${R}Failed: %d${X}  ${Y}Skipped: %d${X}\n\n" "$PASS" "$FAIL" "$SKIP"

    if [ "$FAIL" -gt 0 ]; then
        printf "  ${R}${B}FAIL${X}\n\n"
        exit 1
    else
        printf "  ${G}${B}PASS${X}\n\n"
        exit 0
    fi
}

main "$@"
