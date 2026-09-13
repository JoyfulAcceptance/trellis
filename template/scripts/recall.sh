#!/usr/bin/env bash
# recall.sh — given a question, the memories that answer it, each with an
# openable path.
#
#     scripts/recall.sh [-n N] [-q] <terms...>
#
#     -n N   at most N hits (default 10)
#     -q     paths only, one per line (for scripting)
#
# Output, per hit:      <type>       memory/<path>
#                                    <description, one line>
# Last line:            -- N hit(s)
#
# Exit: 0 hits · 1 no database / out-of-date schema / query failed
#       3 no usable search term · 4 no match
#
# THE ROUTE IS A SCRIPT. Before this existed the only way to find a memory
# was to read MEMORY.md and guess, or grep memory/ — ~430 KB of files for a
# question a 2 KB answer settles. This queries memory_fts and joins
# v_memory_addr, which is the OPSEC boundary: a compartmented memory has no
# address there and cannot be returned. Every search appends ONE line of
# counts (never the terms) to health/recall.log, so the diagnostic can say
# whether the route is used at all.
#
# Portability: bash 3.2 / BSD userland. No GNU timeout — sqlite3's own
# .timeout (busy-wait on a locked database) is the one that matters.
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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/lib/config.sh" ]; then
    . "$SCRIPT_DIR/lib/config.sh"
    config="$TRELLIS/config.yaml"
    DB="$TRELLIS/$(get_config "database.path" "trellis.db")"
else
    DB="$TRELLIS/trellis.db"
fi

usage() {
    echo "Usage: $0 [-n N] [-q] <terms...>" >&2
    echo "  -n N   at most N hits (default 10)" >&2
    echo "  -q     paths only, one per line" >&2
}

LIMIT=10
QUIET=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -n) LIMIT="${2:-}"; shift 2 ;;
        -q) QUIET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "recall.sh: unknown option $1" >&2; usage; exit 3 ;;
        *) break ;;
    esac
done
case "$LIMIT" in ''|*[!0-9]*) echo "recall.sh: -n wants a number, got '$LIMIT'" >&2; exit 3 ;; esac

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "recall.sh: sqlite3 is not installed — the memory database cannot be searched" >&2
    exit 1
fi
if [ ! -f "$DB" ]; then
    echo "recall.sh: no database at $DB — run scripts/rebuild-trellis-db.sh" >&2
    exit 1
fi
if ! sqlite3 "$DB" "SELECT 1 FROM memories LIMIT 1;" >/dev/null 2>&1; then
    echo "recall.sh: database schema is out of date — run scripts/rebuild-trellis-db.sh" >&2
    exit 1
fi

# --- query build -----------------------------------------------------------
# Lowercase; keep [a-z0-9_-]; drop tokens under 3 chars and stopwords; QUOTE
# every token. A bare hyphenated token (i-corps) is an FTS5 syntax error;
# "i-corps" is a phrase and works. Tokens are OR'd: recall is a lead, and a
# lead that needs every word present is a lead that misses.
STOP=" the and for with that this from into are was were you your our its not but has have had been will can all any one two use used using how what when where why who "
q=""
for raw in "$@"; do
    for tok in $(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n-' ' '); do
        tok=$(printf '%s' "$tok" | tr -d '"')
        [ "${#tok}" -ge 3 ] || continue
        case "$STOP" in *" $tok "*) continue ;; esac
        if [ -z "$q" ]; then q="\"$tok\""; else q="$q OR \"$tok\""; fi
    done
done
if [ -z "$q" ]; then
    echo "recall.sh: no usable search term in: $*" >&2
    echo "  (tokens under 3 characters and common words are dropped)" >&2
    exit 3
fi

# --- search ---------------------------------------------------------------
# INNER JOIN v_memory_addr is the OPSEC filter — a compartmented row has no
# address and so no hit. The description is trimmed to one line, 150 chars.
sql="SELECT a.type, a.path, replace(substr(COALESCE(a.description,''),1,150), char(10), ' ')
FROM memory_fts m JOIN v_memory_addr a ON a.source_table = m.source_table AND a.source_id = m.source_id
WHERE memory_fts MATCH '$(printf '%s' "$q" | sed "s/'/''/g")' ORDER BY rank LIMIT $LIMIT;"

err_file=$(mktemp "${TMPDIR:-/tmp}/trellis-recall.XXXXXXXX")
rc=0
rows=$(sqlite3 -cmd ".timeout 2000" -separator '|' "$DB" "$sql" 2>"$err_file") || rc=$?
if [ "$rc" -ne 0 ]; then
    # Loud on purpose: a silent empty result reads as "not in memory".
    echo "recall.sh: query failed: $(cat "$err_file")" >&2
    rm -f "$err_file"
    exit 1
fi
rm -f "$err_file"

# --- log (counts only — never the terms) ------------------------------------
log_search() {
    local n="$1" top="$2"
    mkdir -p "$TRELLIS/health" 2>/dev/null || return 0
    printf '%s\tsearch\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" "$top" \
        >> "$TRELLIS/health/recall.log" 2>/dev/null || true
}

if [ -z "$rows" ]; then
    log_search 0 "-"
    echo "recall.sh: no match for $q" >&2
    exit 4
fi

n=0
top=""
while IFS='|' read -r type path desc; do
    [ -n "$path" ] || continue
    n=$((n + 1))
    [ -n "$top" ] || top="$type"
    if [ "$QUIET" -eq 1 ]; then
        printf 'memory/%s\n' "$path"
    else
        printf '%-10s memory/%s\n' "$type" "$path"
        [ -n "$desc" ] && printf '           %s\n' "$desc"
    fi
done <<EOF
$rows
EOF
log_search "$n" "$top"
[ "$QUIET" -eq 1 ] || echo "-- $n hit(s)"
exit 0
