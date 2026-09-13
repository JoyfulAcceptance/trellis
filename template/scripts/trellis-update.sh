#!/usr/bin/env bash
set -euo pipefail

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

if [ ! -d "$TRELLIS" ]; then
    echo "Trellis not found at $TRELLIS" >&2
    exit 1
fi

if [ -f "$TRELLIS/.trellis-distribution" ]; then
    echo "REFUSED: This is the Trellis distribution repo, not your install." >&2
    exit 1
fi
if [ -d "$TRELLIS/template" ] && [ -d "$TRELLIS/tests" ]; then
    echo "REFUSED: This looks like the distribution repo (has template/ and tests/)." >&2
    exit 1
fi

CHECK_ONLY=false
# --post-swap OLD NEW: this process IS the freshly installed updater, re-exec'd
# by the one that did the swap. Guarded on the FLAG, never on an env var, so
# nothing in the environment can make a normal run skip the swap.
POST_SWAP=false
OLD_VERSION=""
NEW_VERSION=""
if [ "${1:-}" = "--post-swap" ]; then
    POST_SWAP=true
    OLD_VERSION="${2:-}"
    NEW_VERSION="${3:-}"
    if [ -z "$OLD_VERSION" ] || [ -z "$NEW_VERSION" ]; then
        echo "trellis-update: --post-swap needs OLD and NEW versions" >&2
        exit 1
    fi
else
    for arg in "$@"; do
        case "$arg" in
            --check) CHECK_ONLY=true ;;
        esac
    done
fi

REPO_URL=$(grep -E '^\s*repo_url:' "$TRELLIS/config.yaml" 2>/dev/null \
    | head -1 | sed 's/.*repo_url:[[:space:]]*//' | tr -d '\r"'"'" || true)
: "${REPO_URL:=https://github.com/energyscholar/trellis.git}"

# Portable in-place sed (bare `sed -i` is GNU-only; BSD sed requires a suffix)
sed_inplace() {
    local expr="$1" file="$2" tmp
    tmp=$(mktemp)
    sed "$expr" "$file" > "$tmp" && mv "$tmp" "$file"
}

TEMP="/tmp/trellis-update-$$"
cleanup() { rm -rf "$TEMP" "$TRELLIS/scripts.new" "$TRELLIS/plugins.new"; }
trap cleanup EXIT

if ! $POST_SWAP; then
echo "Fetching updates from $REPO_URL..." >&2
if ! git clone --depth 1 -q "$REPO_URL" "$TEMP" 2>/dev/null; then
    echo "Could not reach update server. Check your internet connection." >&2
    exit 1
fi

if [ ! -f "$TEMP/template/config.yaml" ] || [ ! -d "$TEMP/template/scripts" ]; then
    echo "Downloaded repo doesn't look like Trellis." >&2
    exit 1
fi

NEW_VERSION=$(grep -E '^\s*version:' "$TEMP/template/config.yaml" | head -1 \
    | sed 's/.*version:[[:space:]]*//' | tr -d '\r"'"'")
OLD_VERSION=$(grep -E '^\s*version:' "$TRELLIS/config.yaml" | head -1 \
    | sed 's/.*version:[[:space:]]*//' | tr -d '\r"'"'")

if [ "$OLD_VERSION" = "$NEW_VERSION" ]; then
    echo "Already up to date (v${OLD_VERSION})." >&2
    exit 0
fi

if $CHECK_ONLY; then
    echo "Update available: v${OLD_VERSION} → v${NEW_VERSION}" >&2
    exit 0
fi

if [ ! -f "$TRELLIS/config.yaml" ] || [ ! -d "$TRELLIS/memory" ]; then
    echo "Install directory doesn't look like Trellis (missing config.yaml or memory/)." >&2
    exit 1
fi

cd "$TRELLIS"

if git rev-parse --git-dir &>/dev/null; then
    git add -A && git commit -m "Pre-update snapshot" 2>/dev/null || true
fi

# STAGE-AND-SWAP. Never `rm -rf scripts/` before the copy: a crash in that
# window leaves an install with NO SCRIPTS AT ALL, and any armed git hooks
# (the memory deletion wall) vanish mid-flight. Stage the new trees fully,
# then swap with mv — the install always has a complete scripts/ directory.
rm -rf "$TRELLIS/scripts.new" "$TRELLIS/plugins.new"
cp -r "$TEMP/template/scripts" "$TRELLIS/scripts.new"
cp -r "$TEMP/template/plugins" "$TRELLIS/plugins.new"
chmod +x "$TRELLIS/scripts.new/"*.sh
chmod +x "$TRELLIS/scripts.new/git-hooks/"* 2>/dev/null || true

# PRESERVE THE DATABASE SEEDS. scripts/db/data-*.sql are written by the
# install (health history, the derived memory seed); the template has none.
# Replacing scripts/ wholesale deleted them on every update (#23).
mkdir -p "$TRELLIS/scripts.new/db"
SEEDS_KEPT=0
for _seed in "$TRELLIS"/scripts/db/data-*.sql; do
    [ -f "$_seed" ] || continue
    cp "$_seed" "$TRELLIS/scripts.new/db/"
    SEEDS_KEPT=$((SEEDS_KEPT + 1))
done

# NAME THE USER'S OWN ADDITIONS. Anything at the top level of scripts/ or
# plugins/ that the new tree does not carry is theirs; it goes to the backup
# below and is listed in the summary so nothing vanishes unnamed (#27).
CUSTOM=""
for _entry in "$TRELLIS"/scripts/* "$TRELLIS"/scripts/.[!.]*; do
    [ -e "$_entry" ] || continue
    _name=$(basename "$_entry")
    [ -e "$TRELLIS/scripts.new/$_name" ] || CUSTOM="${CUSTOM}scripts/${_name} "
done
for _entry in "$TRELLIS"/plugins/* "$TRELLIS"/plugins/.[!.]*; do
    [ -e "$_entry" ] || continue
    _name=$(basename "$_entry")
    [ -e "$TRELLIS/plugins.new/$_name" ] || CUSTOM="${CUSTOM}plugins/${_name} "
done
CUSTOM="${CUSTOM% }"

# KEEP A BACKUP. The previous scripts/ and plugins/ are moved, not deleted,
# into .update-backup/<old-version>-<UTC timestamp>/ — a fresh directory
# every time, so no earlier backup is ever overwritten. Gitignored.
BACKUP="$TRELLIS/.update-backup/${OLD_VERSION}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"
rm -rf "$TRELLIS/scripts.old" "$TRELLIS/plugins.old"
mv "$TRELLIS/scripts" "$TRELLIS/scripts.old"
mv "$TRELLIS/scripts.new" "$TRELLIS/scripts"
mv "$TRELLIS/plugins" "$TRELLIS/plugins.old"
mv "$TRELLIS/plugins.new" "$TRELLIS/plugins"
mv "$TRELLIS/scripts.old" "$BACKUP/scripts"
mv "$TRELLIS/plugins.old" "$BACKUP/plugins"

# The BASE is the base: directives-base.md, not the assembled file. (Older
# updaters copied directives.md here; assemble-directives.sh strips the
# GENERATED marker it would otherwise inherit.)
cp "$TEMP/template/directives-base.md" "$TRELLIS/directives-base.md"
[ -f "$TEMP/template/.gitignore" ] && cp "$TEMP/template/.gitignore" "$TRELLIS/.gitignore"
[ -f "$TEMP/template/RECOVERY.md" ] && cp "$TEMP/template/RECOVERY.md" "$TRELLIS/RECOVERY.md"
[ -f "$TEMP/template/BOOTSTRAP.md" ] && cp "$TEMP/template/BOOTSTRAP.md" "$TRELLIS/BOOTSTRAP.md"

# Stamp the new version into the user's config. Without this the version gate
# never advances and every future run re-applies the same update.
sed_inplace "s|^version:.*|version: ${NEW_VERSION}|" "$TRELLIS/config.yaml"

# RE-EXEC INTO THE NEW SCRIPT. Everything from here on runs from the
# updater that was just installed, not the one that started (#13): the
# post-swap steps of THIS release are what run, not the previous release's
# idea of them. An exec does not run the EXIT trap, so the clone is removed
# first; the swap left no scripts.new/plugins.new behind.
rm -rf "$TEMP"
export SEEDS_KEPT CUSTOM BACKUP
exec bash "$TRELLIS/scripts/trellis-update.sh" --post-swap "$OLD_VERSION" "$NEW_VERSION"
fi  # !POST_SWAP

# ---------------------------------------------------------------------------
# POST-SWAP: runs from the NEW updater.
# ---------------------------------------------------------------------------
cd "$TRELLIS"
SEEDS_KEPT="${SEEDS_KEPT:-0}"
CUSTOM="${CUSTOM:-}"
BACKUP="${BACKUP:-}"

if [ -x "$TRELLIS/scripts/assemble-directives.sh" ]; then
    bash "$TRELLIS/scripts/assemble-directives.sh" --write || echo "Warning: assemble-directives.sh failed — directives.md not reassembled." >&2
fi

if git rev-parse --git-dir &>/dev/null; then
    git add -A && git commit -m "Trellis update: v${OLD_VERSION} → v${NEW_VERSION}"

    AUTO_PUSH=$(grep -E '^\s*auto_push:' "$TRELLIS/config.yaml" 2>/dev/null \
        | head -1 | sed 's/.*auto_push:[[:space:]]*//' | tr -d '\r' || true)
    if [ "$AUTO_PUSH" = "true" ] && git remote get-url origin &>/dev/null; then
        git push 2>/dev/null || echo "Warning: push failed (offline?). Local commit preserved." >&2
    fi
fi

# Re-arm the deletion wall. core.hooksPath is local git config and the
# freshly swapped scripts/ must be re-activated after every update.
if [ -x "$TRELLIS/scripts/install-hooks.sh" ]; then
    bash "$TRELLIS/scripts/install-hooks.sh" || echo "Warning: install-hooks.sh failed — wall not armed." >&2
fi

# This release's next steps: rebuild the database on the new schema, count
# files against rows, print what the agent should do now.
if [ -x "$TRELLIS/scripts/post-update.sh" ]; then
    bash "$TRELLIS/scripts/post-update.sh" --from "$OLD_VERSION" \
        || echo "Warning: post-update.sh exited non-zero — read its output above." >&2
fi

echo "Updated: v${OLD_VERSION} → v${NEW_VERSION}" >&2
echo "  scripts/    — replaced (staged swap)" >&2
echo "  plugins/    — replaced" >&2
echo "  directives  — reassembled" >&2
echo "  config      — version stamped: ${NEW_VERSION}" >&2
echo "  wall        — install-hooks.sh run" >&2
echo "  backup      — ${BACKUP#$TRELLIS/}/ (scripts, plugins). Your own additions: ${CUSTOM:-none}" >&2
echo "  db seeds    — ${SEEDS_KEPT} preserved" >&2
echo "  next steps  — printed by scripts/post-update.sh above" >&2
