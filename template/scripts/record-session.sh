#!/usr/bin/env bash
# record-session.sh — compile .session-events into ONE row of
# memory/session-log.md, then remove the events file.
#
#     scripts/record-session.sh            at session end (directive step 6,
#                                          and the Claude Code SessionEnd hook)
#     scripts/record-session.sh --crash    at session start, when .session-active
#                                          was left behind: every event is
#                                          annotated (crash)
#
# THE ROW WAS A DIRECTIVE; NOW IT IS A MECHANISM. The session-log row is what
# scripts/acs-check.sh reads, and "ACS: insufficient data" on an install with
# dozens of sessions meant the directive to append the row was not being
# followed. A script that appends it is followable by a hook, by a Codex
# session that has no hook, and by a crash-recovery path alike.
#
# Input format (.session-events), as directives §Mid-Session Event Logging
# specifies:
#     S{N} {YYYY-MM-DD} domain:{d}          header (first line)
#     M: event[(detail)]                    one event per line, axis-prefixed
#     S: ...
#     E: ...
#
# Contracts:
#   no .session-events        -> says so, exit 0, writes nothing (hook-safe:
#                                the agent may have run this already)
#   this session's id is already the last row -> says so, removes the events
#                                file, exit 0 (dedup)
#   otherwise                 -> appends | S{N} | date | domain | m | s | e |
#
# Only writer to memory/ in the shipped scripts. Portable: awk/printf only,
# no sed -i. bash 3.2 / BSD userland.
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
EVENTS="$TRELLIS/.session-events"
LOG="$TRELLIS/memory/session-log.md"

CRASH=0
case "${1:-}" in
    --crash) CRASH=1 ;;
    "") ;;
    -h|--help) echo "Usage: $0 [--crash]" >&2; exit 0 ;;
    *) echo "record-session: unknown argument $1" >&2; exit 2 ;;
esac

if [ ! -f "$EVENTS" ]; then
    echo "record-session: no .session-events in $TRELLIS — nothing to record. (The session-start directive creates it; this runs at session end.)"
    exit 0
fi

# --- last data row of the log (id and date), tolerant of bare numeric ids ---
last_row_id=""
if [ -f "$LOG" ]; then
    last_row_id=$(awk -F'|' '/^\| S?[0-9]/ { id=$2 } END { gsub(/^[ \t]+|[ \t]+$/, "", id); print id }' "$LOG")
fi

# --- parse the events file ------------------------------------------------
header=$(tr -d '\r' < "$EVENTS" | head -1)
session_id=""
session_date=""
domain=""
case "$header" in
    S[0-9]*|[0-9]*)
        session_id=$(printf '%s' "$header" | awk '{print $1}')
        session_date=$(printf '%s' "$header" | awk '{print $2}')
        domain=$(printf '%s' "$header" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^domain:/) { sub(/^domain:/, "", $i); print $i } }')
        ;;
esac
case "$session_id" in
    S[0-9]*) ;;
    [0-9]*)  session_id="S${session_id}" ;;
    *)
        # No header: the next number after the last row.
        n=$(printf '%s' "$last_row_id" | tr -cd '0-9')
        [ -n "$n" ] || n=0
        session_id="S$((n + 1))"
        ;;
esac
case "$session_date" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) session_date=$(date -u +%Y-%m-%d) ;;
esac
[ -n "$domain" ] || domain="unknown"

# events per axis, comma-joined; "—" when none; (crash) appended when asked
axis_events() {
    local axis="$1"
    tr -d '\r' < "$EVENTS" | awk -v axis="$axis" -v crash="$CRASH" '
        $0 ~ ("^" axis ":[ \t]*") {
            ev = $0
            sub("^" axis ":[ \t]*", "", ev)
            gsub(/[ \t]+$/, "", ev)
            if (ev == "") next
            if (crash == 1) ev = ev "(crash)"
            out = (out == "") ? ev : out ", " ev
            n++
        }
        END { if (n == 0) print "—"; else print out }'
}
m_events=$(axis_events M)
s_events=$(axis_events S)
e_events=$(axis_events E)
count_axis() { [ "$1" = "—" ] && echo 0 || printf '%s\n' "$1" | awk -F', ' '{print NF}'; }
m_n=$(count_axis "$m_events")
s_n=$(count_axis "$s_events")
e_n=$(count_axis "$e_events")

# --- dedup: the same session recorded twice is one row -----------------------
if [ -n "$last_row_id" ] && [ "S${last_row_id#S}" = "$session_id" ]; then
    echo "record-session: $session_id already recorded — not appending twice"
    rm -f "$EVENTS"
    exit 0
fi

# --- append ---------------------------------------------------------------
if [ ! -f "$LOG" ]; then
    mkdir -p "$(dirname "$LOG")"
    {
        echo "# Session Log"
        echo ""
        echo "Append one row per session at session end. The ACS check script reads this"
        echo "table to compute cross-axis catalysis and governance resilience."
        echo ""
        echo "<!-- Event taxonomy — do not edit this block -->"
        echo "<!-- M (Memory):    correction, save, compress, staleness-caught -->"
        echo "<!-- S (Structure): plan, follow, transition, drift-flag, drift-resolved -->"
        echo "<!-- E (Ethics):    l0, l1, l2, l3, l4, l5, storm, divergence -->"
        echo ""
        echo "| Session | Date | Domain | Memory | Structure | Ethics |"
        echo "|---------|------|--------|--------|-----------|--------|"
    } > "$LOG"
fi
# The table must end in a newline before the row is appended. ($(...) strips
# a trailing newline, so a non-empty result means the last byte is not one.)
if [ -s "$LOG" ] && [ -n "$(tail -c 1 "$LOG")" ]; then
    printf '\n' >> "$LOG"
fi
printf '| %s | %s | %s | %s | %s | %s |\n' \
    "$session_id" "$session_date" "$domain" "$m_events" "$s_events" "$e_events" >> "$LOG"
rm -f "$EVENTS"
echo "record-session: $session_id recorded (M:$m_n S:$s_n E:$e_n events)"
