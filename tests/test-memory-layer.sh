#!/usr/bin/env bash
# test-memory-layer.sh — every typed memory file is a row, every row is
# openable, and a database that holds less than the files REFUSES to swap.
#
# THE DEFECT THIS FILE ENCODES (measured on an established install, not
# theorised): 32 typed memory files, a rebuild that printed "integrity OK",
# and 0 rows. Then, once rows loaded at all, 10 of 32 files still reached no
# row because the old four-table schema had nowhere to put `type: skill` or a
# feedback typed inside an insight-*.md. Search over that database answered
# "no match" for memories that were sitting on disk.
#
# M1 and M2 are GUARDS: each strips its check out of a throwaway install's
# rebuild script and requires the assertions to go red. M4/M5/M6 and the
# legacy-seed assertion are plain.
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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/trellis-memlayer.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT

# mk_corpus DIR — the six-kind fixture plus one unknown type: and one untyped.
mk_corpus() {
    mk_install "$1"
    mk_memory "$1" feedback-a  feedback  "Rule A about plan gates"
    mk_memory "$1" insight-b   feedback  "Insight B"
    mk_memory "$1" skill-c     skill     "Skill C about dk-anchoring"
    mk_memory "$1" project-d   project   "Project D"
    mk_memory "$1" reference-e reference "Reference E"
    mk_memory "$1" user-f      user      "User F"
    mk_memory "$1" weird-g     decision  "A decision"
    printf '# Notes H\n\nNo frontmatter at all.\n' > "$1/memory/notes-h.md"
}

q() { sqlite3 "$1/trellis.db" "$2" 2>/dev/null; }

# --- M4: every typed file is a row with an openable path --------------------
FIX4="$WORK/m4"
mk_corpus "$FIX4"
m4_out=$(tr_rebuild "$FIX4" 2>&1)
m4_rc=$?
assert_eq "0" "$m4_rc" "M4 the corpus rebuilds (exit 0)" || true
assert_eq "7" "$(q "$FIX4" 'SELECT COUNT(*) FROM memories;')" \
    "M4 seven typed files are seven rows in memories" || true
assert_contains "$m4_out" "7 memories / 7 typed files" \
    "M4 the final line states memories against typed files" || true

m4_paths_ok=1
while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "$FIX4/memory/$p" ] || m4_paths_ok=0
done <<EOF
$(q "$FIX4" 'SELECT path FROM memories;')
EOF
assert_eq "1" "$m4_paths_ok" "M4 every memories.path resolves to a file under memory/" || true

assert_eq "name,type,description,path" \
    "$(q "$FIX4" 'PRAGMA table_info(memories);' | awk -F'|' '{print $2}' | tr '\n' ',' | sed 's/,$//')" \
    "M4 memories has exactly name,type,description,path in that order" || true
assert_eq "source_table,source_id,in_registry,name,type,description,path" \
    "$(q "$FIX4" 'PRAGMA table_info(v_memory_addr);' | awk -F'|' '{print $2}' | tr '\n' ',' | sed 's/,$//')" \
    "M4 v_memory_addr has the seven-column contract" || true
assert_contains "$m4_out" "notes-h.md" "M4 the untyped file is named" || true
assert_contains "$m4_out" "no type:" "M4 ...as carrying no type:" || true
assert_contains "$m4_out" "weird-g.md: type 'decision' is not a known kind" \
    "M4 the unknown type is named as landed 'other'" || true
assert_contains "$m4_out" "other 1 (weird-g.md)" "M4 the kind census names the 'other' file" || true
assert_contains "$m4_out" "feedback 2 · skill 1 · project 1 · reference 1 · user 1" \
    "M4 the kind census counts every kind" || true

# --- M5: legacy names resolve, inherited views still SELECT -----------------
assert_eq "2" "$(q "$FIX4" 'SELECT COUNT(*) FROM feedback;')" "M5 feedback = 2 (feedback-a + insight-b)" || true
assert_eq "1" "$(q "$FIX4" 'SELECT COUNT(*) FROM projects;')" "M5 projects = 1" || true
assert_eq "1" "$(q "$FIX4" 'SELECT COUNT(*) FROM "references" WHERE length(content) > 0;')" \
    "M5 references = 1 and carries content" || true
assert_eq "1" "$(q "$FIX4" 'SELECT COUNT(*) FROM user_profile WHERE length(value) > 0;')" \
    "M5 user_profile = 1 and carries a value" || true
for v in v_feedback_by_domain v_active_projects v_compartmented v_memory_stats v_memories_stale v_fts_confidence; do
    v_rc=0
    sqlite3 "$FIX4/trellis.db" "SELECT * FROM $v LIMIT 1;" >/dev/null 2>&1 || v_rc=$?
    assert_eq "0" "$v_rc" "M5 inherited view $v still SELECTs" || true
done

# --- M5b: confidence rows exist (the staleness pre-flight is live) ----------
assert_eq "7" "$(q "$FIX4" 'SELECT COUNT(*) FROM memory_confidence;')" \
    "M5b memory_confidence has one row per memory" || true

# --- M6: the population report names an empty column -----------------------
assert_contains "$m4_out" "memory_item.established is empty (0/7)" \
    "M6 the report names memory_item.established as empty" || true

# --- Legacy seed: removed by name, not loaded into a table that is a view ---
FIXS="$WORK/seed"
mk_corpus "$FIXS"
printf -- "-- legacy\nINSERT OR REPLACE INTO feedback(slug, rule, content) VALUES ('old', 'r', 'c');\n" \
    > "$FIXS/scripts/db/data-feedback.sql"
seed_out=$(tr_rebuild "$FIXS" 2>&1)
seed_rc=$?
assert_eq "0" "$seed_rc" "legacy seed: the rebuild still completes" || true
assert_contains "$seed_out" "removed legacy seed data-feedback.sql" \
    "legacy seed: the removal is named" || true
assert_eq "absent" "$([ -f "$FIXS/scripts/db/data-feedback.sql" ] && echo present || echo absent)" \
    "legacy seed: the file is gone" || true

# --- M1 GUARD: a typed file that reached no row is a REFUSAL, by name -------
register_guard M1 "a typed memory file that reached no row refuses the rebuild by name"

FIX1="$WORK/m1"
mk_corpus "$FIX1"

assert_m1() {
    # Self-resetting: a clean corpus builds; then one file whose INSERT the
    # schema rejects (opsec: bogus violates the CHECK) is added.
    rm -f "$FIX1/memory/bad-i.md" "$FIX1/trellis.db" "$FIX1/.db-memory-checksum"
    tr_rebuild "$FIX1" >/dev/null 2>&1
    assert_eq "7" "$(q "$FIX1" 'SELECT COUNT(*) FROM memories;')" "M1 the clean corpus loads 7"

    printf -- '---\nname: bad-i\ndescription: bad\nopsec: bogus\nmetadata:\n  type: feedback\n---\n\nBody.\n' \
        > "$FIX1/memory/bad-i.md"
    local out rc=0
    out=$(tr_rebuild "$FIX1" 2>&1) || rc=$?
    assert_eq "3" "$rc" "M1 exit 3"
    assert_contains "$out" "REFUSED" "M1 the refusal is named"
    assert_contains "$out" "reached no row: bad-i.md" "M1 the missing file is named"
    assert_eq "7" "$(q "$FIX1" 'SELECT COUNT(*) FROM memories;')" "M1 the previous database survives"
}

# Strip M1 AND L2: the coarse check cannot fire (7 of 8 loaded) but stripping
# both makes the guard's claim unambiguous.
patch_m1() {
    awk '/^# >>> CHECK-M1/{skip=1} /^# <<< CHECK-M1/{skip=0; next}
         /^# >>> CHECK-L2/{skip=1} /^# <<< CHECK-L2/{skip=0; next} !skip' \
        "$FIX1/scripts/rebuild-trellis-db.sh" > "$FIX1/scripts/rebuild-trellis-db.stripped"
    mv "$FIX1/scripts/rebuild-trellis-db.stripped" "$FIX1/scripts/rebuild-trellis-db.sh"
    chmod +x "$FIX1/scripts/rebuild-trellis-db.sh"
}

prove_guard M1 patch_m1 assert_m1 || true

# --- M2 GUARD: an under-populated FTS table is a REFUSAL --------------------
register_guard M2 "a memory_fts that indexes less than the memories refuses the rebuild"

FIX2="$WORK/m2"
mk_corpus "$FIX2"
# The rebuild script as the fixture currently carries it (with or without the
# check, depending on whether patch_m2 has run). assert_m2 breaks the FTS
# INSERT on a COPY of that script each time, so the strip persists and the
# breakage is fresh.
break_fts_insert() {
    sed "s/TRIM(COALESCE(mi.content,'') || ' ' || COALESCE(mi.description,''))/''/" \
        "$FIX2/scripts/rebuild-trellis-db.sh" > "$FIX2/scripts/rebuild-broken.sh"
    chmod +x "$FIX2/scripts/rebuild-broken.sh"
}

assert_m2() {
    rm -f "$FIX2/trellis.db" "$FIX2/.db-memory-checksum"
    tr_rebuild "$FIX2" >/dev/null 2>&1
    assert_eq "7" "$(q "$FIX2" 'SELECT COUNT(*) FROM memories;')" "M2 the clean corpus loads 7"

    break_fts_insert
    local out rc=0
    out=$(TRELLIS_HOME="$FIX2" bash "$FIX2/scripts/rebuild-broken.sh" 2>&1) || rc=$?
    assert_eq "3" "$rc" "M2 exit 3"
    assert_contains "$out" "REFUSED" "M2 the refusal is named"
    assert_contains "$out" "memory_fts" "M2 the refusal names memory_fts"
}

patch_m2() {
    awk '/^# >>> CHECK-M2/{skip=1} /^# <<< CHECK-M2/{skip=0; next} !skip' \
        "$FIX2/scripts/rebuild-trellis-db.sh" > "$FIX2/scripts/rebuild-trellis-db.stripped"
    mv "$FIX2/scripts/rebuild-trellis-db.stripped" "$FIX2/scripts/rebuild-trellis-db.sh"
    chmod +x "$FIX2/scripts/rebuild-trellis-db.sh"
}

prove_guard M2 patch_m2 assert_m2 || true

guard_summary
