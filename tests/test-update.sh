#!/usr/bin/env bash
# test-update.sh — a simulated update from an established 0.5.1 install, both
# ways it can happen.
#
# Part A is the path an established install takes: the updater that RUNS is
# the installed 0.5.1 copy (tests/fixtures/trellis-update-0.5.1.sh, verbatim),
# and the tree it installs is this repo's template. That old updater deletes
# custom plugins/scripts and db seeds; this test ASSERTS that documented
# behaviour so a future change that fixes it visibly changes this file.
# What must hold: memory/ byte-identical, config untouched but for version,
# the new scripts present, the install-hooks handoff line printed, and
# post-update.sh then working on the result.
#
# Part B is every later update: the NEW updater against a bumped dist. It
# must re-exec into itself exactly once, keep a backup, preserve seeds, name
# the user's own additions, and leave no staging directories behind.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
T="$REPO/template"

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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/trellis-update-test.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT

GIT="git -c user.name=t -c user.email=t@t -c commit.gpgsign=false"

# --- DIST: stands in for the GitHub repo ------------------------------------
DIST="$WORK/dist"
mkdir -p "$DIST"
cp -r "$T" "$DIST/template"
$GIT -C "$DIST" init -q
$GIT -C "$DIST" add -A >/dev/null
$GIT -C "$DIST" commit -q -m "dist" >/dev/null

# --- INSTALL: an established 0.5.1 install with its own additions -----------
INSTALL="$WORK/install"
mkdir -p "$INSTALL"
cp -r "$T/." "$INSTALL/"
cp "$SCRIPT_DIR/fixtures/trellis-update-0.5.1.sh" "$INSTALL/scripts/trellis-update.sh"
chmod +x "$INSTALL/scripts/"*.sh
awk -v url="file://$DIST" '
    /^version:/            { print "version: 0.5.1"; next }
    /^[[:space:]]*repo_url:/ { sub(/repo_url:.*/, "repo_url: \"" url "\""); print; next }
    { print }' "$INSTALL/config.yaml" > "$INSTALL/config.tmp" && mv "$INSTALL/config.tmp" "$INSTALL/config.yaml"
# The template ships starter memories; an established install has its own.
# Keep the untyped core files (MEMORY.md, corrections.md, protocol.md,
# session-log.md) and replace the typed ones with exactly one.
. "$T/scripts/lib/memory-files.sh"
for _typed in $(list_typed_memories "$INSTALL"); do
    rm -f "$INSTALL/memory/$_typed"
done
mk_memory "$INSTALL" feedback-a feedback "The plan gate"
mkdir -p "$INSTALL/plugins/my-plugin"
printf 'name: my-plugin\n' > "$INSTALL/plugins/my-plugin/plugin.yaml"
printf '#!/usr/bin/env bash\necho mine\n' > "$INSTALL/scripts/my-helper.sh"
printf -- "-- health seed\nINSERT INTO health_snapshots(session_number, date, pressure, freshness, coverage, drift, notes) VALUES (1, '2026-06-01', 0.5, 0.9, 1.0, 0.1, 'fixture');\n" \
    > "$INSTALL/scripts/db/data-health.sql"
$GIT -C "$INSTALL" init -q
$GIT -C "$INSTALL" add -A >/dev/null
$GIT -C "$INSTALL" commit -q -m "install" >/dev/null
TRELLIS_HOME="$INSTALL" bash "$INSTALL/scripts/install-hooks.sh" >/dev/null 2>&1 || true

PRE="$WORK/pre"
cp -r "$INSTALL" "$PRE"

# The updater commits inside the install; a CI runner has no git identity.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
update() { TRELLIS_HOME="$INSTALL" bash "$INSTALL/scripts/trellis-update.sh" "$@" 2>&1; }

# ============================================================================
# Part A — the old (0.5.1) updater installs the new template
# ============================================================================
out=$(update --check); rc=$?
assert_eq "0" "$rc" "A --check exits 0" || true
assert_contains "$out" "Update available: v0.5.1 → v0.6.0" "A --check reports 0.5.1 → 0.6.0" || true

out=$(update); rc=$?
assert_eq "0" "$rc" "A update exits 0" || true
assert_eq "" "$(diff -r "$PRE/memory" "$INSTALL/memory" 2>&1)" "A memory/ is byte-identical after the update" || true
assert_eq "version: 0.6.0" "$(grep '^version:' "$INSTALL/config.yaml")" "A config version stamped 0.6.0" || true
assert_eq "" "$(diff <(grep -v '^version' "$PRE/config.yaml") <(grep -v '^version' "$INSTALL/config.yaml"))" \
    "A config otherwise identical" || true
assert_file "$INSTALL/scripts/recall.sh" "A the new scripts are present (recall.sh)" || true
assert_file "$INSTALL/scripts/post-update.sh" "A the new scripts are present (post-update.sh)" || true
assert_contains "$out" "run scripts/post-update.sh" "A install-hooks prints the post-update handoff line" || true
# The documented old-updater behaviour, asserted so a fix is visible:
assert_eq "absent" "$([ -f "$INSTALL/scripts/db/data-health.sql" ] && echo present || echo absent)" \
    "A (documented) the old updater deletes db seeds" || true
assert_eq "absent" "$([ -d "$INSTALL/plugins/my-plugin" ] && echo present || echo absent)" \
    "A (documented) the old updater deletes custom plugins" || true
assert_eq "1" "$(grep -c '^<!-- GENERATED from directives-base.md' "$INSTALL/directives.md" || true)" \
    "A the assembled directives carry the GENERATED marker exactly once" || true

out=$(TRELLIS_HOME="$INSTALL" bash "$INSTALL/scripts/post-update.sh" --from 0.5.1 2>&1); rc=$?
assert_eq "0" "$rc" "A post-update.sh exits 0" || true
assert_contains "$out" "NEXT STEPS" "A post-update prints NEXT STEPS" || true
assert_contains "$out" "1 memories / 1 typed files" "A post-update counts the one memory against the one typed file" || true
assert_contains "$out" "Re-read directives.md" "A post-update tells the agent to re-read directives" || true
assert_contains "$out" "FEEDBACK" "A post-update carries the feedback paragraph" || true
assert_contains "$out" "UPGRADING-0.6.0.md" "A post-update --from links the release notes" || true
assert_eq "1" "$(sqlite3 "$INSTALL/trellis.db" 'SELECT COUNT(*) FROM memories;' 2>/dev/null)" \
    "A the database on the new schema holds the memory" || true

# The derived seed never reaches the install's git history (A1).
TRELLIS_HOME="$INSTALL" bash "$INSTALL/scripts/memory-sync.sh" >/dev/null 2>&1 || true
assert_not_contains "$(git -C "$INSTALL" status --porcelain 2>/dev/null)" "data-memories.sql" \
    "A data-memories.sql is ignored by the install's git after a rebuild + sync" || true
assert_eq "" "$(git -C "$INSTALL" ls-files scripts/db/data-memories.sql 2>/dev/null)" \
    "A data-memories.sql is not tracked" || true

out=$(update); rc=$?
assert_contains "$out" "Already up to date (v0.6.0)" "A a second run is a no-op" || true

# ============================================================================
# Part B — the new updater (0.6.0 → 0.6.1)
# ============================================================================
mkdir -p "$INSTALL/plugins/my-plugin"
printf 'name: my-plugin\n' > "$INSTALL/plugins/my-plugin/plugin.yaml"
printf '#!/usr/bin/env bash\necho mine\n' > "$INSTALL/scripts/my-helper.sh"
printf -- "-- health seed\nINSERT INTO health_snapshots(session_number, date, pressure, freshness, coverage, drift, notes) VALUES (1, '2026-06-01', 0.5, 0.9, 1.0, 0.1, 'fixture');\n" \
    > "$INSTALL/scripts/db/data-health.sql"
$GIT -C "$INSTALL" add -A >/dev/null
$GIT -C "$INSTALL" commit -q -m "re-add additions" >/dev/null
rm -rf "$PRE"; cp -r "$INSTALL" "$PRE"

awk '/^version:/ { print "version: 0.6.1"; next } { print }' "$DIST/template/config.yaml" \
    > "$DIST/template/config.tmp" && mv "$DIST/template/config.tmp" "$DIST/template/config.yaml"
$GIT -C "$DIST" add -A >/dev/null
$GIT -C "$DIST" commit -q -m "0.6.1" >/dev/null

out=$(update); rc=$?
assert_eq "0" "$rc" "B update exits 0" || true
assert_contains "$out" "Updated: v0.6.0 → v0.6.1" "B the summary names the versions" || true
assert_contains "$out" "next steps" "B the summary points at the next steps" || true
assert_contains "$out" "backup" "B the summary names the backup" || true
assert_contains "$out" "my-plugin" "B the summary names the user's own plugin" || true
# Two seeds: data-health.sql (re-added above) and data-memories.sql, the
# derived one Part A's rebuild wrote. Both are the install's, both survive.
assert_contains "$out" "db seeds    — 2 preserved" "B the summary counts the preserved seeds" || true
backup_manifest=$(ls "$INSTALL"/.update-backup/0.6.0-*/plugins/my-plugin/plugin.yaml 2>/dev/null | head -1)
assert_eq "present" "$([ -n "$backup_manifest" ] && [ -f "$backup_manifest" ] && echo present || echo absent)" \
    "B the previous plugins/ is in .update-backup/0.6.0-<timestamp>/" || true
assert_file "$INSTALL/scripts/db/data-health.sql" "B data-health.sql survives the swap" || true
assert_eq "" "$(diff -r "$PRE/memory" "$INSTALL/memory" 2>&1)" "B memory/ is byte-identical after the update" || true
assert_eq "" "$(ls -d "$INSTALL"/scripts.new "$INSTALL"/scripts.old "$INSTALL"/plugins.new "$INSTALL"/plugins.old 2>/dev/null)" \
    "B no staging directories are left behind" || true
assert_eq "1" "$(printf '%s\n' "$out" | grep -c 'post-update steps' || true)" \
    "B the post-swap ran exactly once (one post-update header)" || true
assert_eq "version: 0.6.1" "$(grep '^version:' "$INSTALL/config.yaml")" "B config version stamped 0.6.1" || true
assert_eq "0" "$(grep -c '^<!-- GENERATED from directives-base.md' "$INSTALL/directives-base.md" || true)" \
    "B the new updater copies the base, not the marked file, as directives-base.md" || true

out=$(update); rc=$?
assert_contains "$out" "Already up to date (v0.6.1)" "B a second run is a no-op" || true

guard_summary
