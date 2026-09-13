#!/usr/bin/env bash
# lib/memory-files.sh — which memory files are TYPED, i.e. carry a `type:`
# line in their frontmatter and therefore must become a database row; which
# are PROTOCOL files (five, never rows, never expected in the index); and which
# are UNINDEXED (memory/MEMORY.md does not name them).
#
# One definition of each, sourced by rebuild-trellis-db.sh, health-check.sh,
# post-update.sh, trellis-diagnostic.sh and memory-audit.sh. The rebuild's
# refusal ("N typed files on disk, 0 rows loaded") and the health line
# ("R memories / F typed files") must count the SAME files by the SAME rule,
# or one of them lies — and the fragmentation metric (a count) and the audit
# (the names) must agree the same way, or the count and the names disagree.
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

# --- the protocol files: MEMORY.md and its four companions ----------------
# These carry no type: and are never rows, and MEMORY.md cannot index itself.
# training-primer.md is here because the directives read it BY NAME ("if
# memory/training-primer.md exists and sessions < 10: read it"), exactly as
# they read protocol.md — it is a procedure, not a memory, and a fresh
# blank-profile install must audit clean. ONE list, used by the fragmentation
# metric (health-check.sh) and by memory-audit.sh's classes A and B, so the
# count and the names agree.
MEMORY_PROTOCOL_FILES="MEMORY.md corrections.md protocol.md session-log.md training-primer.md"

# memory_file_is_protocol NAME — exit 0 if the basename is a protocol file.
memory_file_is_protocol() {
    local name="$1" p
    for p in $MEMORY_PROTOCOL_FILES; do
        [ "$name" = "$p" ] && return 0
    done
    return 1
}

# list_indexable_memories DIR — basenames of memory/*.md that MEMORY.md is
# expected to index (everything but the protocol files), sorted.
list_indexable_memories() {
    local dir="$1" f b
    for f in "$dir"/memory/*.md; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        memory_file_is_protocol "$b" || printf '%s\n' "$b"
    done | sort
}

# list_unindexed_memories DIR — indexable files whose basename does not
# appear anywhere in memory/MEMORY.md (a literal substring test, exactly the
# rule the fragmentation metric has always used; a mention of `feedback-a.md`
# therefore "indexes" `a.md` — the audit's class A must agree with the
# metric, so it inherits that coarseness). If MEMORY.md is missing, every
# indexable file is unindexed — that is the truth, and health-check already
# reports the missing file as [FAIL] on its own line.
list_unindexed_memories() {
    local dir="$1" index="$1/memory/MEMORY.md" b
    list_indexable_memories "$dir" | while IFS= read -r b; do
        [ -n "$b" ] || continue
        if [ ! -f "$index" ] || ! grep -qF "$b" "$index" 2>/dev/null; then
            printf '%s\n' "$b"
        fi
    done
}

# count_indexable_memories DIR — indexable files, as a bare integer.
count_indexable_memories() { list_indexable_memories "$1" | grep -c . || true; }

# count_unindexed_memories DIR — indexable files MEMORY.md does not name.
count_unindexed_memories() { list_unindexed_memories "$1" | grep -c . || true; }
