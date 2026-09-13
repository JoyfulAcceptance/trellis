#!/usr/bin/env bash
# test-recall.sh — scripts/recall.sh returns memories with openable paths,
# never a syntax error, never a silent empty result.
#
# The route to a memory used to be "read MEMORY.md and guess" or grep the
# whole memory/ directory. recall.sh is that route as a script; these
# assertions pin its contract: hits carry a path under memory/, a hyphenated
# term is not an FTS5 syntax error, no match is exit 4 and says so, a missing
# database names the rebuild, and every search leaves one line of COUNTS in
# health/recall.log — never the terms.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

. "$SCRIPT_DIR/lib/guard.sh"
. "$SCRIPT_DIR/lib/install-fixture.sh"

if ! command -v sqlite3 >/dev/null 2>&1; then
    skip_test "sqlite3 absent: rebuild-trellis-db.sh cannot be exercised"
    exit 0
fi
if ! fts5_available; then
    skip_test "sqlite3 lacks FTS5: memory-layer tests not exercised"
    exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/trellis-recall.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT

FIX="$WORK/install"
mk_install "$FIX"
cp "$FIXTURE_TEMPLATE/recall.sh" "$FIX/scripts/"
chmod +x "$FIX/scripts/recall.sh"
mk_memory "$FIX" feedback-a feedback "The plan gate: no implementation before a plan file exists"
mk_memory "$FIX" skill-c    skill    "Skill C about dk-anchoring"
mk_memory "$FIX" project-d  project  "Project D tracks the widget"
tr_rebuild "$FIX" >/dev/null 2>&1

recall() { TRELLIS_HOME="$FIX" bash "$FIX/scripts/recall.sh" "$@" 2>&1; }

# --- a hit carries type and an openable path --------------------------------
out=$(recall plan gate); rc=$?
assert_eq "0" "$rc" "recall: a matching query exits 0" || true
assert_contains "$out" "feedback" "recall: the hit's type is printed" || true
assert_contains "$out" "memory/feedback-a.md" "recall: the hit's path is printed" || true
assert_matches "$out" '[0-9]+ hit\(s\)$' "recall: the hit count closes the output" || true

# --- a hyphenated term is never an FTS5 syntax error ------------------------
out=$(recall "dk-anchoring"); rc=$?
assert_not_contains "$out" "syntax error" "recall: a hyphenated term is quoted, not a syntax error" || true
case "$rc" in
    0|4) assert_eq "1" "1" "recall: a hyphenated term exits 0 or 4" || true ;;
    *)   assert_eq "0 or 4" "$rc" "recall: a hyphenated term exits 0 or 4" || true ;;
esac

# --- no match is exit 4 and says so -----------------------------------------
out=$(recall zzqx); rc=$?
assert_eq "4" "$rc" "recall: no match exits 4" || true
assert_contains "$out" "no match" "recall: no match is stated" || true

# --- -q prints only paths ---------------------------------------------------
out=$(recall -q widget); rc=$?
assert_eq "0" "$rc" "recall -q: exits 0 on a hit" || true
assert_eq "memory/project-d.md" "$out" "recall -q: prints the path and nothing else" || true

# --- the log holds counts, never terms --------------------------------------
log="$FIX/health/recall.log"
assert_file "$log" "recall: health/recall.log exists after searches" || true
log_lines=$(grep -c "	search	" "$log" 2>/dev/null || true)
# four searches above (plan gate, dk-anchoring, zzqx, widget) = four lines
assert_eq "4" "$log_lines" "recall: one log line per search" || true
assert_not_contains "$(cat "$log")" "widget" "recall: the log never holds a query term" || true
assert_not_contains "$(cat "$log")" "zzqx" "recall: ...not even a missed one" || true

# --- no database names the rebuild ------------------------------------------
rm -f "$FIX/trellis.db"
out=$(recall plan gate); rc=$?
assert_eq "1" "$rc" "recall: no database exits 1" || true
assert_contains "$out" "rebuild-trellis-db.sh" "recall: no database names the rebuild" || true

# --- an old-schema database names the rebuild -------------------------------
sqlite3 "$FIX/trellis.db" "CREATE TABLE feedback(id INTEGER PRIMARY KEY);"
out=$(recall plan gate); rc=$?
assert_eq "1" "$rc" "recall: an out-of-date schema exits 1" || true
assert_contains "$out" "out of date" "recall: ...and says the schema is out of date" || true

guard_summary
