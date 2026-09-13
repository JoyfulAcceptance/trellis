#!/usr/bin/env bash
# test-memory-audit.sh — scripts/memory-audit.sh names every stranded memory
# file, by class, with its fix, and never writes under memory/.
#
# The defect this file encodes: a count with no names is not actionable.
# health-check.sh reported "fragmentation: 0.18 [HIGH]" and told the assistant
# to add the unindexed files to the file map without saying which files —
# measured upstream, six governance memories sat on disk unlisted and were
# never loaded. The audit names them.
#
# Every class A–G has a "detected" assertion that names a planted file, so
# removing a detector turns this file red. The negative assertions (a protocol
# file is not B, a horizontal rule is not C, a link inside code is not E, a
# prose mention is not F) each sit in a fixture where a positive assertion in
# the same class also holds, so a detector that reports nothing cannot pass.
# No guards: the audit refuses nothing; exit 1 is a finding, not a refusal.
#
# Only section G needs a database, so there is no early exit for sqlite3 —
# the G case skips on its own, with a sanctioned reason.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

. "$SCRIPT_DIR/lib/guard.sh"
. "$SCRIPT_DIR/lib/install-fixture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/trellis-memory-audit.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT

# mk_audit DIR [db_enabled] — an install with the audit script in place.
mk_audit() {
    mk_install "$1" "${2:-true}"
    cp "$FIXTURE_TEMPLATE/memory-audit.sh" "$1/scripts/"
    chmod +x "$1/scripts/memory-audit.sh"
}
# index_row DIR NAME — one File Map table row naming memory/NAME.md.
index_row() { printf '| `memory/%s.md` | about %s | |\n' "$2" "$2" >> "$1/memory/MEMORY.md"; }
# audit DIR [args...] — run the install's audit, stderr folded in.
audit() {
    local dir="$1"
    shift
    TRELLIS_HOME="$dir" bash "$dir/scripts/memory-audit.sh" "$@" 2>&1
}

# --- Z: zero memory files is a new install, not a finding --------------------
FIX="$WORK/zero"
mk_audit "$FIX" false
rm "$FIX/memory/"*.md
out=$(audit "$FIX"); rc=$?
assert_contains "$out" "new install — nothing to audit" "Z an empty memory/ is reported as a new install" || true
assert_eq "0" "$rc" "Z a new install exits 0" || true

# --- K: a clean install names nothing and ends after G -----------------------
FIX="$WORK/clean"
mk_audit "$FIX" false
mk_memory "$FIX" feedback-a feedback
index_row "$FIX" feedback-a
out=$(audit "$FIX"); rc=$?
assert_eq "0" "$rc" "K a clean install exits 0" || true
assert_eq "memory-audit: 0 stranded (A:0 B:0 C:0 F:0 G:0), E:0 dangling links, D:0 CRLF" \
    "$(printf '%s\n' "$out" | head -1)" "K the summary line is the first line and reads all zeros" || true
assert_eq "6" "$(printf '%s\n' "$out" | grep -c '^  none$' || true)" "K sections A-F each print none" || true
assert_contains "$out" "not checked (database.enabled is false)" "K section G is not checked in flat-file mode" || true
assert_not_contains "$out" "NEXT STEPS" "K a clean audit prints no NEXT STEPS" || true
assert_not_contains "$out" "  A  " "K nothing is named — a detector that names everything is caught here" || true
q=$(audit "$FIX" --quiet); qrc=$?
assert_eq "1" "$(printf '%s\n' "$q" | wc -l | tr -d ' ')" "K --quiet prints exactly one line" || true
assert_eq "$(printf '%s\n' "$out" | head -1)" "$q" "K --quiet prints the summary line" || true
assert_eq "0" "$qrc" "K --quiet keeps the exit code" || true

# --- P: a frontmatter-less training-primer.md is a protocol file, not B -----
# The directives read it by name, as they read protocol.md; it is a procedure,
# never a row. A fresh install that ships it must audit clean.
FIX="$WORK/primer"
mk_audit "$FIX" false
mk_memory "$FIX" feedback-a feedback
index_row "$FIX" feedback-a
printf '# Training Primer\n\nOne question per session.\n' > "$FIX/memory/training-primer.md"
out=$(audit "$FIX"); rc=$?
assert_eq "0" "$rc" "P a frontmatter-less training-primer.md does not strand (exit 0)" || true
assert_contains "$out" "(A:0 B:0 C:0 F:0 G:0)" "P nothing is stranded with the primer present" || true
assert_not_contains "$out" "  B  training-primer.md" "P the primer is not named under B" || true
assert_not_contains "$out" "  A  training-primer.md" "P the primer is not named under A" || true
assert_matches "$out" '^  \(expected, not rows: .*training-primer\.md' "P the primer is listed as expected" || true

# --- P2: the shipped blank profile audits clean, as installed ----------------
FIX="$WORK/blank"
mkdir -p "$FIX"
cp -r "$FIXTURE_REPO/template/profiles/blank/." "$FIX/"
cp -r "$FIXTURE_TEMPLATE" "$FIX/scripts"
chmod +x "$FIX/scripts/"*.sh
out=$(audit "$FIX"); rc=$?
assert_eq "0" "$rc" "P2 a fresh blank-profile install exits 0" || true
assert_matches "$out" '^memory-audit: 0 stranded ' "P2 a fresh blank-profile install has nothing stranded" || true

# --- A: an unindexed file is named under A -----------------------------------
FIX="$WORK/a"
mk_audit "$FIX" false
mk_memory "$FIX" feedback-a feedback
index_row "$FIX" feedback-a
mk_memory "$FIX" orphan-a feedback
out=$(audit "$FIX"); rc=$?
assert_eq "1" "$rc" "A an unindexed file strands (exit 1)" || true
assert_matches "$out" '^  A  orphan-a\.md' "A the unindexed file is named under A" || true
assert_contains "$out" "(A:1 " "A the summary counts it" || true
assert_contains "$out" "NEXT STEPS" "A a finding prints NEXT STEPS" || true

# --- B: an untyped file is named; the protocol files are not -----------------
FIX="$WORK/b"
mk_audit "$FIX" false
mk_memory "$FIX" feedback-a feedback
index_row "$FIX" feedback-a
printf -- '---\nname: untyped-b\ndescription: x\n---\n\nBody.\n' > "$FIX/memory/untyped-b.md"
index_row "$FIX" untyped-b
touch "$FIX/memory/session-log.md"
printf '# Training Primer\n\nOne question per session.\n' > "$FIX/memory/training-primer.md"
out=$(audit "$FIX"); rc=$?
assert_eq "1" "$rc" "B an untyped file strands (exit 1)" || true
assert_matches "$out" '^  B  untyped-b\.md' "B the untyped file is named under B" || true
assert_contains "$out" "B:1" "B the summary counts it" || true
for p in MEMORY.md corrections.md protocol.md session-log.md training-primer.md; do
    assert_not_contains "$out" "  B  $p" "B the protocol file $p is expected, not a finding" || true
done
assert_contains "$out" "expected, not rows: MEMORY.md corrections.md protocol.md session-log.md training-primer.md" \
    "B the protocol files are listed as expected" || true

# --- C: a late frontmatter fence is C, not B; a horizontal rule is B, not C --
FIX="$WORK/c"
mk_audit "$FIX" false
mk_memory "$FIX" feedback-a feedback
index_row "$FIX" feedback-a
printf '# Title\n\nintro\n\n---\nname: late-c\nmetadata:\n  type: feedback\n---\n\nBody.\n' > "$FIX/memory/late-c.md"
index_row "$FIX" late-c
printf '# Rule\n\n---\n\nprose\n' > "$FIX/memory/hr-only.md"
index_row "$FIX" hr-only
out=$(audit "$FIX"); rc=$?
assert_eq "1" "$rc" "C a late fence strands (exit 1)" || true
assert_matches "$out" '^  C  late-c\.md' "C the late-fence file is named under C" || true
assert_contains "$out" "starts at line 5" "C the line of the fence is named" || true
assert_not_contains "$out" "  B  late-c.md" "C a file lands in one class" || true
assert_matches "$out" '^  B  hr-only\.md' "C a horizontal rule with no type: is untyped (B)" || true
assert_not_contains "$out" "  C  hr-only.md" "C a horizontal rule with no type: is not a late fence" || true
assert_contains "$out" "B:1 C:1" "C the summary counts one of each" || true

# --- D: CRLF is information, not stranding -----------------------------------
FIX="$WORK/d"
mk_audit "$FIX" false
mk_memory "$FIX" feedback-a feedback
index_row "$FIX" feedback-a
printf -- '---\r\nname: crlf-d\r\ndescription: x\r\nmetadata:\r\n  type: feedback\r\n---\r\n\r\nBody.\r\n' > "$FIX/memory/crlf-d.md"
index_row "$FIX" crlf-d
out=$(audit "$FIX"); rc=$?
assert_eq "0" "$rc" "D CRLF alone does not strand (exit 0)" || true
assert_matches "$out" '^  D  crlf-d\.md' "D the CRLF file is named under D" || true
assert_matches "$out" '^memory-audit: .*D:1 CRLF$' "D the summary ends with the CRLF count" || true
assert_not_contains "$out" "  B  crlf-d.md" "D the CR-stripped frontmatter is still typed" || true

# --- E: a dangling link is named; links inside code are ignored --------------
FIX="$WORK/e"
mk_audit "$FIX" false
mk_memory "$FIX" feedback-a feedback
index_row "$FIX" feedback-a
mk_memory "$FIX" links-e feedback
index_row "$FIX" links-e
{
    printf 'See [[really-missing]] and [[feedback-a]].\n'
    printf '\n```\n[[in-fence]]\n```\n'
    printf 'Quoted: `[[in-span]]` is an example.\n'
} >> "$FIX/memory/links-e.md"
out=$(audit "$FIX"); rc=$?
assert_eq "0" "$rc" "E dangling links alone do not strand (exit 0)" || true
assert_contains "$out" "links-e.md: [[really-missing]]" "E a real dangling link is named" || true
assert_not_contains "$out" "in-fence" "E a link inside a fenced block is ignored" || true
assert_not_contains "$out" "in-span" "E a link inside a code span is ignored" || true
assert_not_contains "$out" "[[feedback-a]]" "E a resolvable link is not reported" || true
assert_contains "$out" "E:1 dangling" "E the summary counts it" || true

# --- F: a File Map row with no file is named; prose is not an index entry ----
FIX="$WORK/f"
mk_audit "$FIX" false
mk_memory "$FIX" feedback-a feedback
index_row "$FIX" feedback-a
index_row "$FIX" ghost-f
printf -- '- planned: memory/planned-x.md (not yet written)\n' >> "$FIX/memory/MEMORY.md"
out=$(audit "$FIX"); rc=$?
assert_eq "1" "$rc" "F a row with no file strands (exit 1)" || true
assert_matches "$out" '^  F  ghost-f\.md' "F the ghost row is named under F" || true
assert_not_contains "$out" "planned-x" "F prose is not an index entry" || true
assert_contains "$out" "F:1" "F the summary counts it" || true

# --- G: typed files with no row; a database with no registry view ------------
if command -v sqlite3 >/dev/null 2>&1 && fts5_available; then
    FIX="$WORK/g"
    mk_audit "$FIX" true
    mk_memory "$FIX" feedback-a feedback
    index_row "$FIX" feedback-a
    tr_rebuild "$FIX" >/dev/null 2>&1
    out=$(audit "$FIX"); rc=$?
    assert_contains "$out" "(1 rows / 1 typed files)" "G rows and typed files are both counted" || true
    assert_contains "$out" "G:0" "G a rebuilt database strands nothing" || true
    assert_eq "0" "$rc" "G a rebuilt database exits 0" || true

    mk_memory "$FIX" late-g feedback
    index_row "$FIX" late-g
    out=$(audit "$FIX"); rc=$?
    assert_eq "1" "$rc" "G a typed file with no row strands (exit 1)" || true
    assert_matches "$out" '^  G  late-g\.md' "G the row-less file is named under G" || true
    assert_contains "$out" "G:1" "G the summary counts it" || true

    sqlite3 "$(fixture_db "$FIX")" "DROP VIEW memories;"
    out=$(audit "$FIX"); rc=$?
    assert_contains "$out" "predates the memories view" "G a database with no registry view is named" || true
    assert_contains "$out" "G:2" "G a database with no registry view counts every typed file" || true
    assert_eq "1" "$rc" "G a database with no registry view strands (exit 1)" || true
else
    skip_test "sqlite3 absent or lacks FTS5: memory-audit section G not exercised"
fi

guard_summary
