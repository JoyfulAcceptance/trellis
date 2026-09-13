#!/usr/bin/env bash
# memory-audit.sh — names every memory file that is stranded, where, and the
# one-line fix, so the AI reading it can repair it.
#
#     scripts/memory-audit.sh [--quiet|-q]
#
# A DETECTOR, never a repairer: this script opens nothing under memory/ for
# writing. It reads with grep, awk, sed, tr, comm and sqlite3 SELECT, and its
# output ends with a NEXT STEPS block for the assistant. health-check.sh
# COUNTS unindexed files (the fragmentation metric); this script NAMES them,
# by the same definition (lib/memory-files.sh), so the count and the names
# cannot disagree. A count with no names is not actionable.
#
# Seven classes, one section each, every file in exactly one of A/B/C:
#   A  not in memory/MEMORY.md         — unindexed, unrecallable from the hot cache
#   B  no type: in frontmatter         — never becomes a database row
#   C  frontmatter not on line 1       — a type: the ingest cannot see
#   D  CRLF line endings               — info, not stranded (the ingest strips \r)
#   E  dangling [[wiki-links]]         — warn, not stranded (links in code are ignored)
#   F  File Map rows with no file      — MEMORY.md names a file that is not on disk
#   G  typed files with no database row
#
# Output: the summary line is ALWAYS the first line —
#     memory-audit: N stranded (A:a B:b C:c F:f G:g), E:e dangling links, D:d CRLF
# --quiet prints only that line. Sections print "none" when empty; the NEXT
# STEPS block prints only when there is something to repair. A new install
# (no memory/, or no memory/*.md) prints "new install — nothing to audit".
#
# Exit: 0 when A+B+C+F+G = 0 (D and E may be non-zero); 1 otherwise — a
# finding, not a failure; 2 on a bad argument. Everything goes to stdout;
# stderr only when the environment is broken (a missing lib).
#
# Portability: bash 3.2 / BSD userland — grep, awk, sed, tr, sort, comm.
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

if [ ! -d "$TRELLIS" ]; then
    echo "memory-audit: Trellis not found at $TRELLIS" >&2
    exit 1
fi

# One shared config reader, and the one definition of typed / protocol /
# unindexed. Refusing on defaults is the house rule: a lib that is missing is
# a broken install, not a reason to guess.
if [ ! -f "$SCRIPT_DIR/lib/config.sh" ]; then
    echo "FATAL: missing $SCRIPT_DIR/lib/config.sh" >&2
    echo "Config cannot be read. Refusing to run on default values." >&2
    echo "Fix: cp -r <trellis-repo>/template/scripts/ \"$TRELLIS/scripts/\"" >&2
    exit 1
fi
. "$SCRIPT_DIR/lib/config.sh"
config="$TRELLIS/config.yaml"

if [ ! -f "$SCRIPT_DIR/lib/memory-files.sh" ]; then
    echo "FATAL: missing $SCRIPT_DIR/lib/memory-files.sh" >&2
    echo "The audit cannot tell typed from untyped or indexed from unindexed without it." >&2
    echo "Fix: cp -r <trellis-repo>/template/scripts/ \"$TRELLIS/scripts/\"" >&2
    exit 1
fi
. "$SCRIPT_DIR/lib/memory-files.sh"

usage() { echo "Usage: $0 [--quiet|-q]" >&2; }
QUIET=0
for arg in "$@"; do
    case "$arg" in
        -q|--quiet) QUIET=1 ;;
        -h|--help)  usage; exit 0 ;;
        *)          usage; exit 2 ;;
    esac
done

MEM="$TRELLIS/memory"
INDEX="$MEM/MEMORY.md"

# --- new-install gate ---------------------------------------------------------
# An unmatched glob stays literal (no nullglob), so test the first match with
# -e. Never `ls | wc -l`: an empty output is not a zero.
if [ ! -d "$MEM" ]; then
    echo "memory-audit: new install — nothing to audit"
    exit 0
fi
set -- "$MEM"/*.md
if [ ! -e "$1" ]; then
    echo "memory-audit: new install — nothing to audit"
    exit 0
fi

# Each class writes its already-formatted lines to one temp file; the report
# reads them back. Temp files live under TMPDIR — never under the install.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/memory-audit.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
for c in A B C D E F G; do : > "$TMP/$c"; done
: > "$TMP/c_names"

count_lines() { grep -c . "$1" 2>/dev/null || true; }

# --- A: unindexed -------------------------------------------------------------
while IFS= read -r b; do
    [ -n "$b" ] || continue
    printf '  A  %s  → add a File Map row in memory/MEMORY.md\n' "$b" >> "$TMP/A"
done <<< "$(list_unindexed_memories "$TRELLIS")"

# --- C: frontmatter fence not on line 1, and a type: inside it ---------------
# A file whose first --- is merely a horizontal rule (no type: in the block
# that follows) is NOT class C; it is untyped, and B names it.
for f in "$MEM"/*.md; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    memory_file_is_protocol "$b" && continue
    if tr -d '\r' < "$f" | awk '
        NR == 1 && $0 == "---" { exit 1 }
        !open && $0 == "---"   { open = 1; next }
        open && $0 == "---"    { exit(found ? 0 : 1) }
        open && /^[[:space:]]*type:[[:space:]]*[^[:space:]]/ { found = 1 }
        END { exit(found ? 0 : 1) }'; then
        n=$(tr -d '\r' < "$f" | awk '$0 == "---" { print NR; exit }')
        printf '  C  %s  → its frontmatter starts at line %s, not line 1 — move or delete what is above it\n' "$b" "$n" >> "$TMP/C"
        printf '%s\n' "$b" >> "$TMP/c_names"
    fi
done

# --- B: untyped, minus the protocol files, minus C ---------------------------
while IFS= read -r b; do
    [ -n "$b" ] || continue
    memory_file_is_protocol "$b" && continue
    grep -qxF "$b" "$TMP/c_names" && continue
    printf '  B  %s  → add "type: <kind>" under metadata: in its frontmatter\n' "$b" >> "$TMP/B"
done <<< "$(list_untyped_memories "$TRELLIS")"

# --- D: CRLF ------------------------------------------------------------------
cr=$(printf '\r')
d_fix="CRLF line endings (info — the ingest strips \\r; convert with tr -d '\\r' only if you are editing it anyway)"
for f in "$MEM"/*.md; do
    [ -f "$f" ] || continue
    if grep -q "$cr" "$f" 2>/dev/null; then
        printf '  D  %s  → %s\n' "$(basename "$f")" "$d_fix" >> "$TMP/D"
    fi
done

# --- E: dangling [[wiki-links]] ----------------------------------------------
# Fenced blocks (``` or ~~~) and inline `code spans` are stripped first, so a
# link that is quoted as an example is not reported. [[name|alias]],
# [[name#section]] and [[name.md]] all normalise to name.
for f in "$MEM"/*.md; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    tr -d '\r' < "$f" \
        | awk '/^[[:space:]]*(```|~~~)/ { fence = !fence; next } !fence { print }' \
        | sed 's/`[^`]*`//g' \
        | grep -o '\[\[[^]]*\]\]' \
        | sed 's/^\[\[//; s/\]\]$//; s/|.*$//; s/#.*$//; s/\.md$//' \
        | sort -u > "$TMP/links" || true
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        [ -f "$MEM/$n.md" ] && continue
        printf '  E  %s: [[%s]]  → no memory/%s.md — fix the link or remove it\n' "$b" "$n" "$n" >> "$TMP/E"
    done < "$TMP/links"
done

# --- F: File Map rows naming a file that is not on disk ----------------------
# TABLE ROWS ONLY (lines beginning with |), never prose: a planned file
# mentioned in a bullet was never supposed to exist yet.
f_checked=1
if [ -f "$INDEX" ]; then
    grep -E '^[[:space:]]*\|' "$INDEX" 2>/dev/null \
        | grep -oE '[A-Za-z0-9_./-]+\.md' \
        | sort -u > "$TMP/tokens" || true
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        case "$tok" in
            memory/*) name="${tok#memory/}" ;;
            */*)      continue ;;
            *)        name="$tok" ;;
        esac
        [ -f "$MEM/$name" ] && continue
        printf '  F  %s  → named in the MEMORY.md File Map but not on disk — fix the row, delete it, or restore the file from git\n' "$name" >> "$TMP/F"
    done < "$TMP/tokens"
else
    f_checked=0
fi

# --- G: typed files with no database row -------------------------------------
db_enabled=$(get_config "database.enabled" "true")
db_path="$TRELLIS/$(get_config "database.path" "trellis.db")"
g_note=""
g_rows=""
g_typed=$(count_typed_memories "$TRELLIS")
if [ "$db_enabled" != "true" ]; then
    g_note="  not checked (database.enabled is false)"
elif [ ! -f "$db_path" ]; then
    g_note="  not checked (no database yet — scripts/rebuild-trellis-db.sh builds it)"
elif ! command -v sqlite3 >/dev/null 2>&1; then
    g_note="  not checked (sqlite3 not installed)"
elif ! rows=$(sqlite3 "$db_path" "SELECT path FROM memories;" 2>/dev/null); then
    printf '  G  %s typed files  → the database predates the memories view — run scripts/rebuild-trellis-db.sh\n' "$g_typed" >> "$TMP/G"
else
    list_typed_memories "$TRELLIS" > "$TMP/typed"
    printf '%s\n' "$rows" | sed 's|^memory/||' | grep . | sort > "$TMP/rows" || true
    g_rows=$(count_lines "$TMP/rows")
    comm -23 "$TMP/typed" "$TMP/rows" | while IFS= read -r b; do
        [ -n "$b" ] || continue
        printf '  G  %s  → typed, but no database row — run scripts/rebuild-trellis-db.sh and read what it says\n' "$b"
    done >> "$TMP/G"
    g_note="  ($g_rows rows / $g_typed typed files)"
fi

# --- counts and the summary line ---------------------------------------------
a=$(count_lines "$TMP/A"); b_=$(count_lines "$TMP/B"); c=$(count_lines "$TMP/C")
d=$(count_lines "$TMP/D"); e=$(count_lines "$TMP/E"); f_=$(count_lines "$TMP/F")
g=$(count_lines "$TMP/G")
# G's "predates the view" line stands for every typed file.
if [ "$g" -eq 1 ] && grep -q 'predates the memories view' "$TMP/G"; then
    g=$g_typed
fi
stranded=$((a + b_ + c + f_ + g))

summary="memory-audit: $stranded stranded (A:$a B:$b_ C:$c F:$f_ G:$g), E:$e dangling links, D:$d CRLF"
echo "$summary"
if [ "$QUIET" -eq 1 ]; then
    [ "$stranded" -eq 0 ] && exit 0
    exit 1
fi
echo "  read-only: this script never writes under memory/ — the fixes are for the AI reading this"
echo ""

section() {  # section HEADER FILE
    echo "$1"
    if [ -s "$2" ]; then cat "$2"; else echo "  none"; fi
}

section "A. not in memory/MEMORY.md — unindexed, unrecallable from the hot cache [$a]" "$TMP/A"
section "B. no type: in frontmatter — never becomes a database row [$b_]" "$TMP/B"
echo "  (expected, not rows: $MEMORY_PROTOCOL_FILES)"
section "C. frontmatter not on line 1 — a type: the ingest cannot see [$c]" "$TMP/C"
section "D. CRLF line endings — info, not stranded [$d]" "$TMP/D"
section 'E. dangling [[wiki-links]] — warn, not stranded (links inside code blocks and `code spans` are ignored) ['"$e"']' "$TMP/E"
if [ "$f_checked" -eq 1 ]; then
    section "F. File Map rows naming a file that is not on disk [$f_]" "$TMP/F"
else
    echo "F. File Map rows naming a file that is not on disk [0]"
    echo "  not checked (memory/MEMORY.md is missing — health-check reports it)"
fi
echo "G. typed files with no database row [$g]"
if [ -s "$TMP/G" ]; then
    cat "$TMP/G"
elif [ -z "$g_note" ] || [ -n "$g_rows" ]; then
    echo "  none"
fi
[ -n "$g_note" ] && echo "$g_note"

if [ $((stranded + e)) -gt 0 ]; then
    echo ""
    cat <<'STEPS'
NEXT STEPS — for the AI reading this:
This script is read-only. It names; you repair. For each file named above:
  A  unindexed:  add one row to the File Map table in memory/MEMORY.md —
                 | `memory/<file>` | <one-line purpose, from its description:> | |
                 Keep MEMORY.md under its line cap; if the cap is near, compress per memory/protocol.md first.
  B  no type:    open the file; add `type: <kind>` under `metadata:` in its frontmatter
                 (kinds: user, feedback, project, reference, skill). Decide the kind from the
                 content — never from the filename alone.
  C  late fence: the file has content ABOVE its frontmatter. Move that content below the closing
                 `---`, or delete it, so the opening `---` is line 1.
  D  CRLF:       nothing is stranded; convert only if you are editing the file anyway.
  E  dangling:   point the link at the file that exists, or remove it. If the memory is genuinely
                 missing, that is a memory to write, not a link to delete — ask the user. A link to
                 something outside memory/ is reported here too — leave it if it is intentional.
  F  no file:    the File Map names a file that is not on disk. Renamed → fix the row. Deleted on
                 purpose → delete the row. Neither → restore it: git -C <trellis> log --all -- memory/<file>
  G  no row:     run scripts/rebuild-trellis-db.sh and read what it says.
Then run scripts/rebuild-trellis-db.sh, then scripts/memory-audit.sh again — expect exit 0.
STEPS
fi

[ "$stranded" -eq 0 ] && exit 0
exit 1
