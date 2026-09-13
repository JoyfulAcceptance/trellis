#!/usr/bin/env bash
# test-record-session.sh — the session-log row is a mechanism.
#
# scripts/record-session.sh compiles .session-events into one row of
# memory/session-log.md. It is the only writer to memory/ among the shipped
# scripts, so its contract is pinned here: one row per session, the events
# file removed, a second run for the same session appends nothing, no events
# file is a stated no-op (hook-safe), --crash annotates every event, and
# acs-check.sh explains its starvation by counting session ends without a row.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
T="$REPO/template"

. "$SCRIPT_DIR/lib/guard.sh"
. "$SCRIPT_DIR/lib/install-fixture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/trellis-record.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT

FIX="$WORK/install"
mk_install "$FIX"
cp "$T/scripts/record-session.sh" "$T/scripts/acs-check.sh" "$T/scripts/trellis-hook-session-end.sh" "$FIX/scripts/"
chmod +x "$FIX/scripts/"*.sh
cp "$T/memory/session-log.md" "$FIX/memory/session-log.md"
printf '| S1 | 2026-06-01 | general | correction | plan | l0 |\n' >> "$FIX/memory/session-log.md"
printf '| S2 | 2026-06-02 | general | save | follow | l0 |\n' >> "$FIX/memory/session-log.md"

# Two "Memory sync:" commits dated after the last row — two session ends
# that produced no row.
git -C "$FIX" init -q
git -C "$FIX" -c user.name=t -c user.email=t@t add -A >/dev/null
git -C "$FIX" -c user.name=t -c user.email=t@t commit -q -m "initial" >/dev/null
for d in 2026-06-10 2026-06-11; do
    printf '%s\n' "$d" > "$FIX/memory/MEMORY.md"
    git -C "$FIX" -c user.name=t -c user.email=t@t add -A >/dev/null
    GIT_AUTHOR_DATE="${d}T12:00:00" GIT_COMMITTER_DATE="${d}T12:00:00" \
        git -C "$FIX" -c user.name=t -c user.email=t@t commit -q -m "Memory sync: $d" >/dev/null
done

rows() { grep -cE '^\| S?[0-9]' "$FIX/memory/session-log.md" || true; }
record() { TRELLIS_HOME="$FIX" bash "$FIX/scripts/record-session.sh" "$@" 2>&1; }

# --- three events become one row, the events file is gone -------------------
printf 'S3 2026-06-12 domain:general\nM: correction\nS: plan(0001)\nE: l0\n' > "$FIX/.session-events"
out=$(record); rc=$?
assert_eq "0" "$rc" "record: exits 0" || true
assert_contains "$out" "S3 recorded (M:1 S:1 E:1 events)" "record: reports the row and the counts" || true
assert_eq "3" "$(rows)" "record: one row appended" || true
assert_eq "| S3 | 2026-06-12 | general | correction | plan(0001) | l0 |" \
    "$(tail -1 "$FIX/memory/session-log.md")" "record: the row has the six columns" || true
assert_eq "absent" "$([ -f "$FIX/.session-events" ] && echo present || echo absent)" \
    "record: the events file is removed" || true

# --- the same session again is not a second row -----------------------------
printf 'S3 2026-06-12 domain:general\nM: save\n' > "$FIX/.session-events"
out=$(record); rc=$?
assert_eq "0" "$rc" "record dedup: exits 0" || true
assert_contains "$out" "already recorded" "record dedup: says so" || true
assert_eq "3" "$(rows)" "record dedup: row count unchanged" || true
assert_eq "absent" "$([ -f "$FIX/.session-events" ] && echo present || echo absent)" \
    "record dedup: the events file is still removed" || true

# --- no events file is a stated no-op ---------------------------------------
out=$(record); rc=$?
assert_eq "0" "$rc" "record no-file: exits 0" || true
assert_contains "$out" "nothing to record" "record no-file: says so" || true
assert_eq "3" "$(rows)" "record no-file: row count unchanged" || true

# --- --crash annotates every event; no header ⇒ next id, today, unknown ------
printf 'M: save\nS: transition\n' > "$FIX/.session-events"
out=$(record --crash); rc=$?
assert_eq "0" "$rc" "record --crash: exits 0" || true
assert_eq "4" "$(rows)" "record --crash: one row appended" || true
last=$(tail -1 "$FIX/memory/session-log.md")
assert_contains "$last" "| S4 |" "record --crash: the id follows the last row" || true
assert_contains "$last" "save(crash)" "record --crash: memory event annotated" || true
assert_contains "$last" "transition(crash)" "record --crash: structure event annotated" || true
assert_contains "$last" "| unknown |" "record --crash: domain defaults to unknown" || true
assert_contains "$last" "| — |" "record --crash: an axis with no events is —" || true

# --- acs-check explains its starvation --------------------------------------
# Rows are S1..S4 now; the two sync commits are dated after S2 but before the
# rows just appended, so restore the two-row log to measure the count.
cp "$T/memory/session-log.md" "$FIX/memory/session-log.md"
printf '| S1 | 2026-06-01 | general | correction | plan | l0 |\n' >> "$FIX/memory/session-log.md"
printf '| S2 | 2026-06-02 | general | save | follow | l0 |\n' >> "$FIX/memory/session-log.md"
out=$(ACS_MIN_SESSIONS=10 TRELLIS_HOME="$FIX" bash "$FIX/scripts/acs-check.sh" 2>&1)
assert_contains "$out" "need 10+ sessions, have 2" "acs: still insufficient" || true
assert_contains "$out" "last row: S2 2026-06-02" "acs: names the last row" || true
assert_contains "$out" "Session ends since then with no row: 2" "acs: counts the sync commits since the last row" || true
assert_contains "$out" "record-session.sh" "acs: names the fix" || true
out=$(ACS_MIN_SESSIONS=10 TRELLIS_HOME="$FIX" bash "$FIX/scripts/acs-check.sh" --oneliner 2>&1)
assert_contains "$out" "no row: 2" "acs --oneliner: carries the count as a suffix" || true

# --- the SessionEnd hook calls record-session before syncing ----------------
assert_contains "$(cat "$FIX/scripts/trellis-hook-session-end.sh")" "record-session.sh" \
    "hook: names record-session.sh" || true
before=$(rows)
printf 'S3 2026-06-12 domain:general\nM: correction\n' > "$FIX/.session-events"
# memory-sync.sh is absent from the fixture: the hook must still append.
TRELLIS_HOME="$FIX" bash "$FIX/scripts/trellis-hook-session-end.sh" >/dev/null 2>&1 || true
assert_eq "$((before + 1))" "$(rows)" "hook: appends the row" || true

guard_summary
