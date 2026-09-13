#!/usr/bin/env bash
# post-update.sh — what to do right after trellis-update.sh, printed for the
# AI instance that is reading it cold.
#
#     scripts/post-update.sh [--from OLD_VERSION]
#
# Three steps, then NEXT STEPS:
#   1/3  rebuild the memory database on the current schema (a full rebuild,
#        not --if-stale: the schema may have changed under the same files)
#   2/3  count typed memory files against database rows — the one-line answer
#        to "did all my memories reach the database"
#   3/3  the governance log (acs-check.sh), including WHY it is starved if it is
#
# Idempotent: a second run repeats the same output and changes nothing but
# the rebuild stamp. Exit 0 always — the findings are in the text; a refusing
# rebuild is REPORTED here, and its own exit code is what a caller checks.
#
# Portability: bash 3.2 / BSD userland.
set -uo pipefail

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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

FROM=""
case "${1:-}" in
    --from) FROM="${2:-}" ;;
    "") ;;
    -h|--help) echo "Usage: $0 [--from OLD_VERSION]" >&2; exit 0 ;;
esac

if [ ! -d "$TRELLIS" ]; then
    echo "post-update: Trellis not found at $TRELLIS" >&2
    exit 1
fi

db_enabled="true"
db_path="$TRELLIS/trellis.db"
version="unknown"
if [ -f "$SCRIPT_DIR/lib/config.sh" ]; then
    . "$SCRIPT_DIR/lib/config.sh"
    config="$TRELLIS/config.yaml"
    version=$(get_config "version" "unknown")
    db_enabled=$(get_config "database.enabled" "true")
    db_path="$TRELLIS/$(get_config "database.path" "trellis.db")"
fi

echo "Trellis ${version} — post-update steps"
echo "======================================"
echo ""

# --- 1/3 rebuild -----------------------------------------------------------
echo "1/3 rebuilding the memory database on the current schema"
rebuild_rc=0
if [ "$db_enabled" != "true" ]; then
    echo "    database.enabled is false — skipped (flat-file mode)"
elif [ -x "$TRELLIS/scripts/rebuild-trellis-db.sh" ]; then
    bash "$TRELLIS/scripts/rebuild-trellis-db.sh" 2>&1 | sed 's/^/    /'
    rebuild_rc=${PIPESTATUS[0]}
    if [ "$rebuild_rc" -ne 0 ]; then
        echo "    ⚠ the rebuild refused (exit $rebuild_rc) — read its reason above; recall is not available until it succeeds"
    fi
else
    echo "    scripts/rebuild-trellis-db.sh is missing or not executable — reinstall scripts/ from the template"
    rebuild_rc=1
fi
echo ""

# --- 2/3 files vs rows -------------------------------------------------------
echo "2/3 memory files vs database rows"
typed=0
untyped=0
if [ -f "$SCRIPT_DIR/lib/memory-files.sh" ]; then
    . "$SCRIPT_DIR/lib/memory-files.sh"
    typed=$(count_typed_memories "$TRELLIS")
    untyped=$(count_untyped_memories "$TRELLIS")
fi
rows="0"
if [ "$db_enabled" = "true" ] && [ -f "$db_path" ] && command -v sqlite3 >/dev/null 2>&1; then
    rows=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM memories;" 2>/dev/null || echo "?")
fi
echo "    ${rows} memories / ${typed} typed files (${untyped} files without type:)"
if [ "$rows" = "?" ]; then
    echo "    ⚠ the database does not answer (schema out of date or unreadable) — the rebuild above must succeed first"
elif [ "$db_enabled" = "true" ] && [ "$rows" -lt "$typed" ]; then
    echo "    ⚠ $((typed - rows)) memory file(s) did not reach the database — the rebuild named them above"
elif [ "$db_enabled" = "true" ]; then
    echo "    every typed memory file is in the database"
fi
if [ "$untyped" -gt 0 ]; then
    echo "    (files without a frontmatter type: are not rows — the rebuild lists them; MEMORY.md, corrections.md, protocol.md and session-log.md are expected there)"
fi
echo ""

# --- 3/3 governance log ------------------------------------------------------
echo "3/3 governance log"
if [ -x "$TRELLIS/scripts/acs-check.sh" ]; then
    bash "$TRELLIS/scripts/acs-check.sh" 2>&1 | sed 's/^/    /'
else
    echo "    scripts/acs-check.sh not found"
fi
echo ""

# --- next steps ----------------------------------------------------------------
cat <<'STEPS'
NEXT STEPS — for the AI reading this:
1. Re-read directives.md now. Two steps changed: Session Start 8b (run scripts/recall.sh before
   answering from memory) and Session End 6 (run scripts/record-session.sh).
2. Prove recall works: scripts/recall.sh <a distinctive word from any memory you know>
   — expect a line with a memory/ path. If it prints "no database" or "out of date", run
   scripts/rebuild-trellis-db.sh and read what it says.
3. At the end of this session, run scripts/record-session.sh, then scripts/memory-sync.sh.
4. Tell the user, in one line, whether all their memory files reached the database (2/3 above).

FEEDBACK (optional):
If you have a minute, we would like to hear how this release behaved on your install. Run
scripts/trellis-diagnostic.sh — it reports structure only (counts, versions, health lines), never
memory content — and send the output, or open an issue at
https://github.com/energyscholar/trellis/issues. After about ten more sessions, scripts/acs-check.sh
should start producing a number instead of "insufficient data"; if it does, or if it still does not,
that is worth a line too. Entirely optional.
STEPS

if [ -n "$FROM" ]; then
    echo ""
    echo "Release notes for this update (from ${FROM}): docs/UPGRADING-${version}.md in the Trellis repo —"
    echo "  https://github.com/energyscholar/trellis/blob/main/docs/UPGRADING-${version}.md"
fi
exit 0
