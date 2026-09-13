#!/usr/bin/env bash
# ingest-memories.sh — Parse .md files with YAML frontmatter into SQL INSERT statements.
#
# Every memory file with a frontmatter type: becomes ONE memory_item row, whatever
# the type says. The kind is read from type: and mapped to memory_kind; a value the
# schema does not name lands as 'other' — reported, never dropped.
#
# Usage:
#   ./ingest-memories.sh                     every memory/*.md -> scripts/db/data-memories.sql (the rebuild calls this)
#   ./ingest-memories.sh --all               same, explicitly
#   ./ingest-memories.sh --file memory/feedback-new-rule.md      one file's SQL to stdout
#   ./ingest-memories.sh --check-untagged    list memory files without a type:
#   ./ingest-memories.sh --type T --glob "memory/x-*.md" --output scripts/db/data-x.sql   (type override; compatibility)
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
LOCKFILE="${TRELLIS}/.ingest.lock"

TYPE=""
GLOB_PATTERN=""
OUTPUT=""
SINGLE_FILE=""
CHECK_UNTAGGED=false
ALL_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type) TYPE="$2"; shift 2 ;;
        --glob) GLOB_PATTERN="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --file) SINGLE_FILE="$2"; shift 2 ;;
        --check-untagged) CHECK_UNTAGGED=true; shift ;;
        --all) ALL_MODE=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--all] | --file FILE | --check-untagged | --type TYPE --glob PATTERN --output FILE" >&2
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

# frontmatter_block FILE — the lines between the opening fence on LINE 1 and
# the next fence. A `---` further down a file is a horizontal rule, not a
# fence: the old range match (/^---$/,/^---$/) collected EVERY such pair, so a
# protocol file quoting a frontmatter example was ingested as a memory.
frontmatter_block() {
    # A memory saved with CRLF line endings has a frontmatter fence of "---\r",
    # which never matches /^---$/. The block parsed EMPTY, the file was SKIPPED
    # with no error, and the memory became invisible to every retrieval path.
    # ONE INVISIBLE BYTE = ONE UNRECALLABLE MEMORY. Strip \r before parsing.
    tr -d '\r' < "$1" | awk 'NR == 1 { if ($0 != "---") exit; next } /^---$/ { exit } { print }'
}

extract_frontmatter_field() {
    local file="$1" field="$2"
    local val
    val=$(frontmatter_block "$file" | grep "^${field}:" | head -1 | sed "s/^${field}:[[:space:]]*//")
    if [ -z "$val" ]; then
        # Check nested under metadata:
        val=$(frontmatter_block "$file" | grep -E "^[[:space:]]+${field}:" | head -1 | sed "s/^[[:space:]]*${field}:[[:space:]]*//")
    fi
    printf '%s' "$val"
}

extract_body() {
    local file="$1"
    tr -d '\r' < "$file" | awk '
        NR == 1 && $0 == "---" { fm = 1; next }
        fm == 1 { if ($0 == "---") fm = 2; next }
        { print }'
}

# Portable file mtime as 'YYYY-MM-DD HH:MM:SS'.
# GNU/Linux: stat --format=%Y, date --date=@<epoch>. BSD/macOS: stat -f %m,
# date -r <epoch>. GNU is tried first: on GNU, `stat -f` means "filesystem
# status" and would SUCCEED with the wrong output (mount point, not epoch).
file_mtime_datetime() {
    local file="$1" epoch
    epoch=$(stat --format='%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null) || true
    case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
    date --date="@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
        || date -r "$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
        || true
}

get_created_at() {
    local file="$1" established="$2"
    if [ -n "$established" ]; then echo "$established"; return; fi
    local oldest
    oldest=$(git log --date=format:'%Y-%m-%d %H:%M:%S' --format='%ad' -- "$file" 2>/dev/null | tail -1) || true
    if [ -n "$oldest" ]; then echo "$oldest"; return; fi
    file_mtime_datetime "$file"
}

get_updated_at() {
    local file="$1"
    local latest
    latest=$(git log -1 --date=format:'%Y-%m-%d %H:%M:%S' --format='%ad' -- "$file" 2>/dev/null) || true
    if [ -n "$latest" ]; then echo "$latest"; return; fi
    file_mtime_datetime "$file"
}

extract_body_field() {
    local body="$1" marker="$2"
    # Portable equivalent of a PCRE lookbehind (grep -P is GNU-only; on macOS
    # the extraction would return SILENTLY EMPTY).
    echo "$body" | sed -n "s/^.*\*\*${marker}:\*\*[[:space:]]*//p" | head -1
}

extract_first_paragraph() {
    local body="$1"
    echo "$body" | awk '
        /^$/ { if (found) exit; next }
        /^\*\*[A-Z]/ { next }
        /^#/ { next }
        { found=1; print }
    '
}

process_file() {
    local file="$1"
    local filename=$(basename "$file")

    local fm_name=$(extract_frontmatter_field "$file" "name")
    local fm_desc=$(extract_frontmatter_field "$file" "description")
    local fm_domain=$(extract_frontmatter_field "$file" "domain")
    local fm_established=$(extract_frontmatter_field "$file" "established")
    local fm_type=$(extract_frontmatter_field "$file" "type")
    local body=$(extract_body "$file")
    local body_escaped=$(sql_escape "$body")

    local created_at=$(get_created_at "$file" "$fm_established")
    local updated_at=$(get_updated_at "$file")
    local ca_sql; [ -n "$created_at" ] && ca_sql="'${created_at}'" || ca_sql="datetime('now')"
    local ua_sql; [ -n "$updated_at" ] && ua_sql="'${updated_at}'" || ua_sql="datetime('now')"

    local effective_type="${TYPE:-$fm_type}"
    if [ -z "$effective_type" ]; then
        echo "SKIP: $file — no type" >&2
        return
    fi

    # kind: the frontmatter type:, mapped to memory_kind. Anything the schema
    # does not name is 'other' — a row, searchable and openable, never dropped.
    local kind
    case "$effective_type" in
        feedback|skill|project|reference|user) kind="$effective_type" ;;
        *)
            kind="other"
            echo "ingest: $filename: type '$effective_type' is not a known kind — landed as 'other' (searchable, openable)" >&2
            ;;
    esac

    # slug: filename stem, minus a leading "<kind>-" if present
    # (feedback-plan-gate -> plan-gate; insight-x stays insight-x).
    local slug
    slug="${filename%.md}"
    case "$slug" in
        "${kind}-"*) slug="${slug#"${kind}-"}" ;;
    esac

    local fm_opsec fm_status
    fm_opsec=$(extract_frontmatter_field "$file" "opsec")
    fm_status=$(extract_frontmatter_field "$file" "status")
    local opsec_sql
    [ -n "$fm_opsec" ] && opsec_sql="'$(sql_escape "$fm_opsec")'" || opsec_sql="NULL"
    local est_sql
    [ -n "$fm_established" ] && est_sql="'$(sql_escape "$fm_established")'" || est_sql="NULL"

    local why=$(sql_escape "$(extract_body_field "$body" "Why")")
    local how=$(sql_escape "$(extract_body_field "$body" "How to apply")")
    local name_esc; name_esc=$(sql_escape "${fm_name:-$slug}")
    local slug_esc; slug_esc=$(sql_escape "$slug")
    local file_esc; file_esc=$(sql_escape "$filename")

    cat <<EOSQL
-- $filename
INSERT INTO memory_item(kind_id, slug, name, description, content, why, how_to_apply, domain,
    opsec_level, established, source_file, path, created_at, updated_at)
VALUES ((SELECT id FROM memory_kind WHERE name='${kind}'), '${slug_esc}', '${name_esc}', '$(sql_escape "$fm_desc")',
    '${body_escaped}', '${why}', '${how}', '$(sql_escape "${fm_domain:-general}")',
    ${opsec_sql}, ${est_sql}, '${file_esc}', '${file_esc}', ${ca_sql}, ${ua_sql})
ON CONFLICT(kind_id, slug) DO UPDATE SET name=excluded.name, description=excluded.description,
    content=excluded.content, why=excluded.why, how_to_apply=excluded.how_to_apply,
    domain=excluded.domain, opsec_level=excluded.opsec_level, established=excluded.established,
    source_file=excluded.source_file, path=excluded.path, updated_at=excluded.updated_at;
EOSQL

    case "$kind" in
        feedback|skill)
            local rule=$(sql_escape "$(extract_first_paragraph "$body")")
            cat <<EOSQL
INSERT INTO feedback_detail(item_id, rule)
VALUES ((SELECT id FROM memory_item WHERE source_file='${file_esc}'), '${rule}')
ON CONFLICT(item_id) DO UPDATE SET rule=excluded.rule;
EOSQL
            ;;
        project)
            cat <<EOSQL
INSERT INTO project_detail(item_id, status)
VALUES ((SELECT id FROM memory_item WHERE source_file='${file_esc}'), '$(sql_escape "${fm_status:-active}")')
ON CONFLICT(item_id) DO UPDATE SET status=excluded.status;
EOSQL
            ;;
        user)
            cat <<EOSQL
INSERT INTO user_detail(item_id, attribute, context)
VALUES ((SELECT id FROM memory_item WHERE source_file='${file_esc}'), '${name_esc}', '$(sql_escape "$fm_desc")')
ON CONFLICT(item_id) DO UPDATE SET attribute=excluded.attribute, context=excluded.context;
EOSQL
            ;;
    esac
    echo ""
}

# frontmatter_keys FILE — every top-level or metadata-nested key in the
# frontmatter block, one per line (the metadata: key itself excluded).
frontmatter_keys() {
    frontmatter_block "$1" | awk '
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:/ {
            k = $0; sub(/^[[:space:]]*/, "", k); sub(/:.*$/, "", k)
            if (k != "metadata") print k
        }'
}

scan_pii() {
    local file="$1"
    local issues=0
    if grep -qiE '(api[_-]?key|password|secret|token|credential)\s*[:=]' "$file" 2>/dev/null; then
        echo "PII WARNING: $file may contain credentials" >&2
        issues=$((issues + 1))
    fi
    if grep -qE '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b' "$file" 2>/dev/null; then
        echo "PII WARNING: $file may contain email addresses" >&2
        issues=$((issues + 1))
    fi
    return $issues
}

# --check-untagged mode: find .md files without frontmatter type
if [ "$CHECK_UNTAGGED" = true ]; then
    cd "$TRELLIS"
    found=0
    for f in memory/*.md; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        case "$base" in MEMORY.md|corrections.md|session-details.md|decisions.md|people.md) continue ;; esac
        fm_type=$(extract_frontmatter_field "$f" "type")
        if [ -z "$fm_type" ]; then
            echo "UNTAGGED: $f (no type in frontmatter)" >&2
            found=$((found + 1))
        fi
        scan_pii "$f" || true
    done
    echo "Found $found untagged files"
    exit 0
fi

# The bare call is --all: every typed memory file into one seed. This used
# to print usage and exit 1, which is how a rebuild that called it with no
# arguments regenerated nothing while reporting success.
if [ -z "$SINGLE_FILE" ] && [ -z "$TYPE" ] && [ -z "$GLOB_PATTERN" ] && [ -z "$OUTPUT" ]; then
    ALL_MODE=true
fi
if [ "$ALL_MODE" = false ] && [ -z "$SINGLE_FILE" ] && { [ -z "$TYPE" ] || [ -z "$GLOB_PATTERN" ] || [ -z "$OUTPUT" ]; }; then
    echo "Usage: $0 [--all]" >&2
    echo "       $0 --file FILE" >&2
    echo "       $0 --check-untagged" >&2
    echo "       $0 --type TYPE --glob PATTERN --output FILE" >&2
    exit 1
fi

# Acquire lock (flock where available; mkdir fallback — macOS has no flock)
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCKFILE"
    if ! flock -n 9; then
        echo "ERROR: Another ingest is running" >&2
        exit 1
    fi
    trap 'rm -f "$LOCKFILE"' EXIT
else
    if ! mkdir "${LOCKFILE}.d" 2>/dev/null; then
        echo "ERROR: Another ingest is running (${LOCKFILE}.d exists)" >&2
        exit 1
    fi
    trap 'rmdir "${LOCKFILE}.d" 2>/dev/null || true' EXIT
fi

cd "$TRELLIS"

if [ -n "$SINGLE_FILE" ]; then
    [ ! -f "$SINGLE_FILE" ] && echo "ERROR: $SINGLE_FILE not found" >&2 && exit 1
    process_file "$SINGLE_FILE"
elif [ "$ALL_MODE" = true ]; then
    output_rel="scripts/db/data-memories.sql"
    output_path="${TRELLIS}/${output_rel}"
    mkdir -p "$(dirname "$output_path")" || { echo "ERROR: cannot create $(dirname "$output_path")" >&2; exit 1; }
    {
        echo "-- Generated by ingest-memories.sh --all; derived — never edit; regenerated on every rebuild"
        echo "-- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""
    } > "$output_path"

    typed=0
    untyped=""
    all_keys=""
    for file in memory/*.md; do
        [ -f "$file" ] || continue
        fm_type=$(extract_frontmatter_field "$file" "type")
        if [ -z "$fm_type" ]; then
            untyped="${untyped} $(basename "$file")"
            continue
        fi
        all_keys="${all_keys}
$(frontmatter_keys "$file")"
        process_file "$file" >> "$output_path"
        typed=$((typed + 1))
    done

    # Files with no type: are not rows. Say which, once — this is the honest
    # one-line check for anyone whose memory files predate frontmatter typing.
    if [ -n "$untyped" ]; then
        n_untyped=$(printf '%s\n' $untyped | grep -c . || true)
        echo "ingest: ${n_untyped} file(s) carry no type: and are not rows:${untyped}" >&2
    fi

    # Frontmatter keys that reach no column: reported, not refused.
    # (Decay overrides such as half_life_days: show up here — not honoured yet.)
    printf '%s\n' "$all_keys" | grep -v '^$' | sort | uniq -c | while read -r n key; do
        case "$key" in
            name|description|type|domain|opsec|established|status) ;;
            *) echo "ingest: frontmatter key '${key}' (${n} files) reaches no column" >&2 ;;
        esac
    done

    echo "ingest: ${typed} typed file(s) → ${output_rel}"
else
    # An absolute --output path must be used as-is. Unconditionally prepending
    # TRELLIS produced a bogus path — the script then printed "Processed N
    # files" and exited 0 WHILE WRITING NOTHING.
    case "$OUTPUT" in
        /*) output_path="$OUTPUT" ;;
        *)  output_path="${TRELLIS}/${OUTPUT}" ;;
    esac
    mkdir -p "$(dirname "$output_path")" || { echo "ERROR: cannot create $(dirname "$output_path")" >&2; exit 1; }
    {
        echo "-- Generated by ingest-memories.sh"
        echo "-- Type: $TYPE | Pattern: $GLOB_PATTERN"
        echo "-- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""
    } > "$output_path"

    count=0
    for file in $GLOB_PATTERN; do
        [ -f "$file" ] || continue
        process_file "$file" >> "$output_path"
        count=$((count + 1))
    done
    echo "Processed $count files → $OUTPUT"
fi
