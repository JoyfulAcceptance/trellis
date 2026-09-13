#!/usr/bin/env bash
# lib/memory-files.sh — which memory files are TYPED, i.e. carry a `type:`
# line in their frontmatter and therefore must become a database row.
#
# One definition, sourced by rebuild-trellis-db.sh, health-check.sh,
# post-update.sh and trellis-diagnostic.sh. The rebuild's refusal ("N typed
# files on disk, 0 rows loaded") and the health line ("R memories / F typed
# files") must count the SAME files by the SAME rule, or one of them lies.
#
# The rule mirrors ingest-memories.sh's frontmatter_block: the frontmatter
# is the block between a `---` fence on LINE 1 and the next `---` (CR-stripped,
# so a CRLF file counts); a `---` further down is a horizontal rule. `type:`
# may sit at the top level or indented under `metadata:`. A file with no
# frontmatter, or frontmatter without `type:`, is not typed and is never
# expected to be a row.
#
# Portability: bash 3.2 / BSD userland — awk and tr only.

# memory_file_is_typed FILE — exit 0 if FILE has a frontmatter type: line.
memory_file_is_typed() {
    local file="$1"
    [ -f "$file" ] || return 1
    tr -d '\r' < "$file" | awk '
        NR == 1 { if ($0 != "---") exit 1; next }
        /^---$/ { exit(found ? 0 : 1) }
        /^[[:space:]]*type:[[:space:]]*[^[:space:]]/ { found = 1; exit 0 }
        END { exit(found ? 0 : 1) }
    '
}

# list_typed_memories DIR — basenames of typed files in DIR/memory, one per
# line, sorted. DIR is the install root.
list_typed_memories() {
    local dir="$1" f
    for f in "$dir"/memory/*.md; do
        [ -f "$f" ] || continue
        if memory_file_is_typed "$f"; then
            basename "$f"
        fi
    done | sort
}

# list_untyped_memories DIR — basenames of memory/*.md WITHOUT a type:, sorted.
list_untyped_memories() {
    local dir="$1" f
    for f in "$dir"/memory/*.md; do
        [ -f "$f" ] || continue
        if ! memory_file_is_typed "$f"; then
            basename "$f"
        fi
    done | sort
}

# count_typed_memories DIR — the number of typed files, as a bare integer.
count_typed_memories() {
    list_typed_memories "$1" | grep -c . || true
}

# count_untyped_memories DIR — the number of memory/*.md without a type:.
count_untyped_memories() {
    list_untyped_memories "$1" | grep -c . || true
}
