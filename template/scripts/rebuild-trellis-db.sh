#!/usr/bin/env bash
# rebuild-trellis-db.sh — Build trellis.db from schema + data. Atomic swap.
# Flat files remain source of truth. DB is a read cache.
#
# Usage:
#   rebuild-trellis-db.sh              Force rebuild
#   rebuild-trellis-db.sh --if-stale   Only rebuild if memory files changed since last build
set -euo pipefail

# --- TRELLIS_HOME resolution (canonical — see docs/architecture.md) ---
resolve_trellis_home() {
    if [ -n "${TRELLIS_HOME:-}" ]; then
        echo "$TRELLIS_HOME"
    elif [ -f "$HOME/.config/trellis/home" ]; then
        cat "$HOME/.config/trellis/home"
    else
        echo "$HOME/.trellis"
    fi
}

TRELLIS="$(resolve_trellis_home)"
SCRIPT_DIR="$TRELLIS/scripts"
DB="${TRELLIS}/trellis.db"
DB_NEW="${DB}.new"
DB_BAK="${DB}.bak"
DB_DIR="${SCRIPT_DIR}/db"
DB_CHECKSUM="${TRELLIS}/.db-memory-checksum"

# --- The database this script builds is a SEARCH layer -------------------
# >>> CHECK-F5
# memory_fts is an FTS5 virtual table and scripts/recall.sh queries it. A
# sqlite3 built without FTS5 would fail the schema load with an error about
# an unknown module — or, worse, a hand-edited schema would build a database
# that "works except search". Name the condition and the fix, and stop.
if [ "${TRELLIS_DB_CHECK:-on}" != "off" ] \
   && ! sqlite3 :memory: "CREATE VIRTUAL TABLE _p USING fts5(x);" >/dev/null 2>&1; then
    echo "rebuild-trellis-db: REFUSED — this sqlite3 ($(sqlite3 --version 2>/dev/null | awk '{print $1}')) has no FTS5." >&2
    echo "  The memory search layer (memory_fts, scripts/recall.sh) needs it." >&2
    echo "  Fix: macOS — brew install sqlite && put it first on PATH; Linux — install a sqlite3 with FTS5." >&2
    echo "  Or set database.enabled: false in config.yaml to run flat-file only." >&2
    exit 2
fi
# <<< CHECK-F5

# lib/memory-files.sh — the one definition of "a typed memory file".
if [ -f "${SCRIPT_DIR}/lib/memory-files.sh" ]; then
    . "${SCRIPT_DIR}/lib/memory-files.sh"
else
    echo "rebuild-trellis-db: missing ${SCRIPT_DIR}/lib/memory-files.sh — reinstall scripts/ from the template" >&2
    exit 1
fi

# --- Portable SHA-256 (macOS ships shasum; most Linux ships both) ---
hash_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$@"
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    else
        echo "ERROR: no SHA-256 tool found (need shasum or sha256sum)" >&2
        return 1
    fi
}

# --- Staleness check ---
#
# THE KEY MUST COVER THE PIPELINE, NOT JUST ITS INPUT.
#
# This used to hash memory/*.md and nothing else, so every part of the machine
# that TRANSFORMS memory into the database was outside the staleness key.
# Measured: change db/schema.sql and run --if-stale, and you get silence and
# exit 0 — no rebuild. The consequence is not cosmetic. Ship a schema column, a
# new view or a parser change to an existing install and none of it installs,
# because the memory files did not move. The check written to detect the new
# condition then reports zero occurrences — green — having never been built.
#
# So the key is memory content AND pipeline content. A product change to either
# forces exactly one rebuild, and the next --if-stale is a no-op again.
compute_memory_checksum() {
    hash_sha256 "$TRELLIS"/memory/*.md 2>/dev/null | sort | hash_sha256 | awk '{print $1}'
}

compute_pipeline_checksum() {
    local f
    for f in "${DB_DIR}/schema.sql" "${DB_DIR}/views.sql" \
             "${SCRIPT_DIR}/ingest-memories.sh" "${SCRIPT_DIR}/rebuild-trellis-db.sh"; do
        [ -f "$f" ] || continue
        hash_sha256 "$f" 2>/dev/null | awk '{print $1}'
    done | sort | hash_sha256 | awk '{print $1}'
}

compute_staleness_key() {
    printf 'memory:%s\npipeline:%s\n' \
        "$(compute_memory_checksum)" "$(compute_pipeline_checksum)" \
        | hash_sha256 | awk '{print $1}'
}

if [ "${1:-}" = "--if-stale" ]; then
    current_checksum=$(compute_staleness_key)
    if [ ! -f "$DB" ]; then
        echo "DB stale (no database at $DB). Building..."
    elif [ ! -f "$DB_CHECKSUM" ]; then
        echo "DB stale (no staleness stamp at $DB_CHECKSUM). Rebuilding..."
    else
        stored_checksum=$(cat "$DB_CHECKSUM" 2>/dev/null || echo "")
        if [ "$current_checksum" = "$stored_checksum" ]; then
            # A decision NOT to act is still a decision, and it says so. The
            # silent exit 0 this replaces was indistinguishable from a rebuild
            # that ran, from a crash, and from a staleness key that had gone
            # blind to the thing that changed.
            echo "db: fresh (memory + pipeline unchanged) — no rebuild"
            exit 0
        fi
        echo "DB stale (memory files or pipeline changed). Rebuilding..."
    fi
fi

cleanup() { rm -f "$DB_NEW" "${DB_NEW}-shm" "${DB_NEW}-wal"; }
# restore_backup [EXIT_CODE] — discard the new database, put the previous one
# back, exit. 1 = verification failed (default); 3 = a check REFUSED the
# build because the database would be wrong. Either way the previous DB is
# what stays on disk.
restore_backup() {
    local code="${1:-1}"
    echo "rebuild-trellis-db: not swapping; previous database restored." >&2
    rm -f "$DB_NEW" "${DB_NEW}-shm" "${DB_NEW}-wal"
    [ -f "$DB_BAK" ] && mv "$DB_BAK" "$DB"
    exit "$code"
}

# Step 1: Back up existing DB
[ -f "$DB" ] && cp "$DB" "$DB_BAK"

# Step 2: Build schema
trap cleanup EXIT
# stdout silenced: `PRAGMA journal_mode = WAL` answers "wal", which is not a
# report line. Errors still reach stderr and abort under set -e.
sqlite3 "$DB_NEW" < "${DB_DIR}/schema.sql" >/dev/null
sqlite3 "$DB_NEW" < "${DB_DIR}/views.sql" >/dev/null

#-----------------------------------------------------------------------------
# SNAPSHOT FRESHNESS GATE.
#
# If scripts/db/data-*.sql are generated once and never regenerated, every
# rebuild loads a frozen snapshot and any memory written after that date NEVER
# reaches the DB — silently. Memories stranded this way stay invisible to
# every DB-backed retrieval path while the flat files look perfectly healthy.
#
# A rebuild must NEVER run against a snapshot older than the memory files.
# Regenerate first. This makes that failure structurally impossible.
#-----------------------------------------------------------------------------
_TR_INGEST="${SCRIPT_DIR}/ingest-memories.sh"

# run_ingest LABEL COMMAND... — run one ingest pass and SHOW WHAT IT SAID.
# These calls used to send both streams to /dev/null and `|| true`, throwing away
# ingest's own "SKIP: <file> — no type" and "PII WARNING" lines. A memory file
# skipped for a malformed frontmatter block was therefore absent from the
# database while both the file and the rebuild looked perfectly healthy.
# Every line is prefixed, so a SKIP from ingest cannot be mistaken by the test
# runner for a SKIP emitted by a test.
run_ingest() {
    local label="$1"
    shift
    local out rc=0
    out=$("$@" 2>&1) || rc=$?
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r _line; do
            printf 'rebuild-trellis-db: ingest[%s]: %s\n' "$label" "$_line"
        done
    fi
    if [ "$rc" -ne 0 ]; then
        echo "rebuild-trellis-db: ingest[$label] exited $rc — the $label snapshot was NOT regenerated" >&2
    fi
    return 0
}

# REGENERATE ON EVERY REBUILD. The previous gate compared mtimes of the
# memory files against db/data-*.sql — and only fired if a seed already
# existed. On an install that had never generated one, nothing was generated,
# nothing was loaded, and "Rebuild complete" printed over an empty database.
# A rebuild is by definition the moment the seeds should reflect the files.
if [ -x "$_TR_INGEST" ]; then
    echo "rebuild-trellis-db: regenerating the memory seed from markdown."
    # NOTE: regenerate ONLY where markdown is the superset. If rows exist
    # only in SQL, extract them to markdown FIRST — or this DELETES them.
    run_ingest all "$_TR_INGEST" --all
else
    echo "rebuild-trellis-db: ${_TR_INGEST} is not executable — no memory seed regenerated" >&2
fi

# Legacy per-type seeds (pre-0.6.0) INSERT into tables that are now views.
# Loading one would fail the build. They are derived files — regenerable from
# the markdown — so removing them loses nothing. Named, so the removal is seen.
for _legacy in data-feedback.sql data-projects.sql data-references.sql data-user.sql; do
    if [ -f "${DB_DIR}/${_legacy}" ]; then
        rm -f "${DB_DIR}/${_legacy}"
        echo "rebuild-trellis-db: removed legacy seed ${_legacy} (superseded by data-memories.sql)"
    fi
done

# Step 3: Load data (if data scripts exist)
#
# This glob is what carries every table that has no other source across a
# rebuild, health_snapshots included — see scripts/lib/health-seed.sh. Loading
# nothing is a legitimate state (a fresh install) but never a silent one.
_TR_SEEDS=0
for f in "${SCRIPT_DIR}"/db/data-*.sql; do
    [ -f "$f" ] || continue
    # sqlite3 keeps going past a rejected statement and exits 1 at the end.
    # The rejection is printed above; the per-file check (CHECK-M1) below
    # names which memory it cost, and refuses. Aborting here would leave
    # the .bak in place with no verdict.
    sqlite3 "$DB_NEW" < "$f" \
        || echo "rebuild-trellis-db: $(basename "$f") had statement(s) rejected — see the sqlite3 error(s) above" >&2
    _TR_SEEDS=$((_TR_SEEDS + 1))
done
if [ "$_TR_SEEDS" -eq 0 ]; then
    echo "rebuild-trellis-db: no db/data-*.sql seeds found — building from schema only (tables that have no markdown source will be EMPTY)"
else
    _TR_HEALTH=$(sqlite3 "$DB_NEW" "SELECT COUNT(*) FROM health_snapshots;" 2>/dev/null || echo 0)
    echo "rebuild-trellis-db: loaded ${_TR_SEEDS} seed file(s); health history: ${_TR_HEALTH} snapshot(s)"
fi

# How many rows the database OWES: the typed memory files on disk.
_TR_TYPED=$(count_typed_memories "$TRELLIS")

# >>> CHECK-L2
# A database that holds nothing reports "integrity OK". If typed memory files
# exist on disk and no row was loaded, the pipeline is broken, and shipping
# the empty database would make every DB-backed retrieval report "not in
# memory" while the files sit there. Refuse; keep the previous database.
if [ "${TRELLIS_DB_CHECK:-on}" != "off" ]; then
    _TR_ROWS=$(sqlite3 "$DB_NEW" "SELECT COUNT(*) FROM memory_item;" 2>/dev/null || echo 0)
    if [ "$_TR_TYPED" -gt 0 ] && [ "$_TR_ROWS" -eq 0 ]; then
        echo "rebuild-trellis-db: REFUSED — ${_TR_TYPED} typed memory file(s) on disk, 0 rows loaded." >&2
        echo "  A database that holds nothing would report \"integrity OK\". Not swapping; previous DB restored." >&2
        echo "  Check: scripts/ingest-memories.sh --check-untagged   Override once: TRELLIS_DB_CHECK=off" >&2
        restore_backup 3
    fi
fi
if [ "$_TR_TYPED" -eq 0 ]; then
    echo "rebuild-trellis-db: no typed memory files yet (new install) — database built empty, nothing to load"
fi
# <<< CHECK-L2

# >>> CHECK-M1
# Every typed file is a row. The coarse check above catches "nothing loaded";
# this one catches "all but one" — an INSERT rejected by a CHECK constraint,
# or never emitted — by name. Same rule for "typed" on both sides
# (lib/memory-files.sh), so the two lists are comparable.
if [ "${TRELLIS_DB_CHECK:-on}" != "off" ] && [ "$_TR_TYPED" -gt 0 ]; then
    _TR_EXPECTED=$(list_typed_memories "$TRELLIS")
    _TR_GOT=$(sqlite3 "$DB_NEW" "SELECT source_file FROM memory_item;" 2>/dev/null | sort)
    # comm -23: lines only in the first (expected) list. Both sides sorted by
    # the same sort, so the comparison is exact.
    _TR_MISSING=$(comm -23 <(printf '%s\n' "$_TR_EXPECTED" | sort) <(printf '%s\n' "$_TR_GOT"))
    if [ -n "$_TR_MISSING" ]; then
        _TR_NMISS=$(printf '%s\n' "$_TR_MISSING" | grep -c . || true)
        echo "rebuild-trellis-db: REFUSED — ${_TR_NMISS} typed memory file(s) reached no row: $(printf '%s\n' "$_TR_MISSING" | tr '\n' ' ')" >&2
        echo "  Their INSERT was rejected or never emitted. Run: scripts/ingest-memories.sh --file memory/<name> | sqlite3 :memory: to see why." >&2
        echo "  Not swapping; previous DB restored.   Override once: TRELLIS_DB_CHECK=off" >&2
        restore_backup 3
    fi
fi
# <<< CHECK-M1

# Step 4: Populate FTS5
# ONE statement, over the supertype. The old UNION had arms for corrections,
# people, sessions, decisions and breakthroughs; nothing in the shipped
# scripts writes those tables (measured), and a future writer should go
# through memory_item so it is searchable AND openable by path.
sqlite3 "$DB_NEW" <<'FTS'
DELETE FROM memory_fts;
INSERT INTO memory_fts(source_table, source_id, title, content, path)
SELECT mk.source_table, mi.id, mi.name,
       TRIM(COALESCE(mi.content,'') || ' ' || COALESCE(mi.description,'')), mi.path
FROM memory_item mi JOIN memory_kind mk ON mk.id = mi.kind_id
WHERE mi.opsec_level IS NULL OR mi.opsec_level != 'compartmented';
FTS

# Step 4b: Confidence rows. memory_confidence had no writer before 0.6.0, so
# the decay views and the staleness pre-flight were reporting over an empty
# table. Defaults come from confidence_config by legacy table name.
sqlite3 "$DB_NEW" <<'CONF'
INSERT OR IGNORE INTO memory_confidence(source_table, source_id, base_confidence, half_life_days, pinned)
SELECT mk.source_table, mi.id, 1.0, cc.default_half_life_days, COALESCE(cc.default_pinned,0)
FROM memory_item mi JOIN memory_kind mk ON mk.id = mi.kind_id
LEFT JOIN confidence_config cc ON cc.source_table = mk.source_table;
CONF

# Step 5: Git-based confidence reinforcement — one loop over every memory file
cd "$TRELLIS"
for f in memory/*.md; do
    [ -f "$f" ] || continue
    git_date=$(git log -1 --date=format:'%Y-%m-%d %H:%M:%S' --format='%ad' -- "$f" 2>/dev/null) || true
    [ -z "$git_date" ] && continue
    base=$(basename "$f")
    escaped_base=$(echo "$base" | sed "s/'/''/g")
    sqlite3 "$DB_NEW" "UPDATE memory_confidence SET last_reinforced = '${git_date}' WHERE last_reinforced IS NULL AND source_id = (SELECT id FROM memory_item WHERE source_file = '${escaped_base}') AND source_table = (SELECT mk.source_table FROM memory_item mi JOIN memory_kind mk ON mk.id = mi.kind_id WHERE mi.source_file = '${escaped_base}');" 2>/dev/null || true
done

# Step 5b: Session-summary reinforcement for non-file-backed tables
sqlite3 "$DB_NEW" <<'REINFORCE'
UPDATE memory_confidence SET last_reinforced = sub.max_date
FROM (
    SELECT p.id, MAX(COALESCE(s.date, s.created_at)) as max_date
    FROM people p, sessions s
    WHERE s.summary LIKE '%' || p.name || '%'
    GROUP BY p.id
) sub
WHERE source_table = 'people' AND source_id = sub.id
AND (last_reinforced IS NULL OR last_reinforced < sub.max_date);

UPDATE memory_confidence SET last_reinforced = sub.max_date
FROM (
    SELECT d.id, MAX(COALESCE(s.date, s.created_at)) as max_date
    FROM decisions d, sessions s
    WHERE s.summary LIKE '%' || d.topic || '%'
    GROUP BY d.id
) sub
WHERE source_table = 'decisions' AND source_id = sub.id
AND (last_reinforced IS NULL OR last_reinforced < sub.max_date);
REINFORCE

# >>> CHECK-M2
# FTS is populated — in ROWS and in BYTES. A search table with a row per
# memory and no body behind it answers every query "no match", which reads
# as "not in memory". Every row must carry a path, or a hit cannot be opened.
if [ "${TRELLIS_DB_CHECK:-on}" != "off" ]; then
    _TR_ITEMS=$(sqlite3 "$DB_NEW" "SELECT COUNT(*) FROM memory_item WHERE opsec_level IS NULL OR opsec_level != 'compartmented';")
    _TR_FTS_ROWS=$(sqlite3 "$DB_NEW" "SELECT COUNT(*) FROM memory_fts;")
    _TR_ITEM_BYTES=$(sqlite3 "$DB_NEW" "SELECT COALESCE(SUM(length(content)),0) FROM memory_item WHERE opsec_level IS NULL OR opsec_level != 'compartmented';")
    _TR_FTS_BYTES=$(sqlite3 "$DB_NEW" "SELECT COALESCE(SUM(length(content)),0) FROM memory_fts;")
    _TR_FTS_NOPATH=$(sqlite3 "$DB_NEW" "SELECT COUNT(*) FROM memory_fts WHERE path IS NULL OR path = '';")
    _TR_FTS_OK=1
    [ "$_TR_FTS_ROWS" -eq "$_TR_ITEMS" ] || _TR_FTS_OK=0
    [ "$_TR_FTS_NOPATH" -eq 0 ] || _TR_FTS_OK=0
    # bytes: fts >= 0.9 * items, in integer arithmetic
    [ $((_TR_FTS_BYTES * 10)) -ge $((_TR_ITEM_BYTES * 9)) ] || _TR_FTS_OK=0
    if [ "$_TR_FTS_OK" -eq 0 ]; then
        echo "rebuild-trellis-db: REFUSED — memory_fts is under-populated: ${_TR_FTS_ROWS} rows for ${_TR_ITEMS} memories, ${_TR_FTS_BYTES} bytes indexed of ${_TR_ITEM_BYTES}, ${_TR_FTS_NOPATH} row(s) without a path." >&2
        echo "  A search table that holds less than the memories answers 'no match' for what is on disk." >&2
        echo "  Not swapping; previous DB restored.   Override once: TRELLIS_DB_CHECK=off" >&2
        restore_backup 3
    fi
fi
# <<< CHECK-M2

# Population report — REPORT, not refuse. A column that is empty across every
# row is either a parser defect or intentionally so; either way it is named.
for _tbl in memory_item feedback_detail project_detail user_detail memory_confidence; do
    _n=$(sqlite3 "$DB_NEW" "SELECT COUNT(*) FROM ${_tbl};" 2>/dev/null || echo 0)
    [ "$_n" -gt 0 ] || continue
    sqlite3 "$DB_NEW" "PRAGMA table_info(${_tbl});" | awk -F'|' '{print $2}' | while IFS= read -r _col; do
        [ -n "$_col" ] || continue
        _filled=$(sqlite3 "$DB_NEW" "SELECT COUNT(*) FROM ${_tbl} WHERE ${_col} IS NOT NULL AND CAST(${_col} AS TEXT) != '';" 2>/dev/null || echo "$_n")
        if [ "$_filled" -eq 0 ]; then
            echo "rebuild-trellis-db: column ${_tbl}.${_col} is empty (0/${_n}) — a defect or intentionally so"
        fi
    done
done
_TR_CENSUS=$(sqlite3 "$DB_NEW" "SELECT mk.name || ' ' || COUNT(mi.id) FROM memory_kind mk LEFT JOIN memory_item mi ON mi.kind_id = mk.id GROUP BY mk.id ORDER BY mk.id;" | tr '\n' '|' | sed 's/|$//; s/|/ · /g')
_TR_OTHERS=$(sqlite3 "$DB_NEW" "SELECT mi.source_file FROM memory_item mi JOIN memory_kind mk ON mk.id = mi.kind_id WHERE mk.name = 'other' ORDER BY mi.source_file;" | tr '\n' ' ')
if [ -n "$_TR_OTHERS" ]; then
    echo "rebuild-trellis-db: kinds — ${_TR_CENSUS} (${_TR_OTHERS% })"
else
    echo "rebuild-trellis-db: kinds — ${_TR_CENSUS}"
fi

# Step 6: Verify
integrity=$(sqlite3 "$DB_NEW" "PRAGMA integrity_check;")
if [ "$integrity" != "ok" ]; then
    echo "rebuild-trellis-db: PRAGMA integrity_check FAILED: $integrity" >&2
    restore_backup 1
fi

fk_check=$(sqlite3 "$DB_NEW" "PRAGMA foreign_keys = ON; PRAGMA foreign_key_check;" 2>&1)
if [ -n "$fk_check" ]; then
    echo "rebuild-trellis-db: PRAGMA foreign_key_check FAILED: $fk_check" >&2
    restore_backup 1
fi

table_count=$(sqlite3 "$DB_NEW" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'memory_fts%';")
if [ "$table_count" -lt 15 ]; then
    echo "rebuild-trellis-db: table count check FAILED: expected >=15, got $table_count" >&2
    restore_backup 1
fi

# Step 7: Checkpoint WAL and clean sidecars before atomic swap
sqlite3 "$DB_NEW" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
sqlite3 "$DB_NEW" "PRAGMA journal_mode=DELETE;" >/dev/null
rm -f "${DB_NEW}-shm" "${DB_NEW}-wal"

trap - EXIT
mv "$DB_NEW" "$DB"
rm -f "${DB}-shm" "${DB}-wal"

# Step 8: Verify final DB after swap (not the temp — the actual artifact)
final_tables=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'memory_fts%';" 2>/dev/null || echo "0")
final_integrity=$(sqlite3 "$DB" "PRAGMA integrity_check;" 2>/dev/null || echo "FAIL")
if [ "$final_integrity" != "ok" ] || [ "$final_tables" -lt 15 ]; then
    echo "ERROR: Final DB verification failed (tables: $final_tables, integrity: $final_integrity)" >&2
    [ -f "$DB_BAK" ] && mv "$DB_BAK" "$DB"
    exit 1
fi
rm -f "$DB_BAK"

# Step 9: Stamp the staleness key (memory AND pipeline) so --if-stale knows
# this build is fresh. Stamping only the memory half is what let a schema
# change sit uninstalled forever.
compute_staleness_key > "$DB_CHECKSUM"

final_memories=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories;" 2>/dev/null || echo "?")
echo "Rebuild complete: $DB (${final_tables} tables, ${final_memories} memories / ${_TR_TYPED} typed files, integrity OK)"
