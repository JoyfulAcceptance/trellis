# Upgrading an established install to v0.6.0

**Audience: the Trellis instance doing the upgrade, and the person supervising it.**

Read this whole page before running anything. It is written to be read cold, by
an assistant on any platform (Claude Code, Codex, Cursor), and it describes what
will change on disk, what the updater that is *already on your machine* will do,
and the steps that turn a finished update into a working one.

Everything below was verified by simulating this exact upgrade on a scratch copy
of an established 0.5.x install, not read off the source.

---

## 0. Your recall may have been degraded, and your files are fine

On 0.5.x the shipped database rebuild reported `Rebuild complete … integrity OK`
while loading **nothing**: it only regenerated its seeds when a seed already
existed, and no install ever had one. Health reported the empty database as
healthy, because it asked "tables ≥ 15 and integrity ok" and never "rows". Even
once rows loaded, the old four-table schema had nowhere to put a `type: skill`
memory or a feedback typed inside an `insight-*.md`, so those never became rows
at all. Any search over that database answered "no match" for memories that were
sitting on disk.

**Your memory files were never at risk.** They are the source of truth; the
database is a cache rebuilt from them. This upgrade rebuilds it correctly and
refuses, by name, to report success while holding less than the files.

The one-line check, before and after:

```bash
bash ~/.trellis/scripts/health-check.sh | grep sqlite
```

Before: `sqlite: ON (27 tables, integrity OK) [OK]` — no row count at all.
After: `sqlite: ON (T tables, R memories / F typed files, integrity OK) [OK]`
with **R = F**. If R < F the line is `[WARN]` and names the fix.

---

## 1. ⚠ Back up first — on THIS update, the old updater still runs

The updater that performs an update is the copy **already installed** — your
0.5.x one. It swaps in the new tree and then runs its own old finishing steps.
So on this transition, and this transition only:

- `scripts/` and `plugins/` are **replaced wholesale and the staged backup
  deleted** (#27). Any plugin or script you wrote yourself is gone.
- `scripts/db/data-*.sql` — the seeds — are deleted with them (#23). The memory
  seed is derived and regenerates; a `data-health.sql` (health history) does not.

**Before you upgrade:**

```bash
cp -r ~/.trellis/plugins    ~/trellis-plugins-backup-$(date +%Y%m%d)
cp -r ~/.trellis/scripts    ~/trellis-scripts-backup-$(date +%Y%m%d)
```

Restore your own plugin directories and scripts afterwards, **by name** — never
wholesale, or you put the old distribution files back.

From 0.6.0 onward the updater keeps the previous `scripts/` and `plugins/` in
`.update-backup/<old-version>-<timestamp>/`, preserves `scripts/db/data-*.sql`,
names your own additions in its summary, and re-executes its freshly installed
self so the finishing steps of the *new* release are the ones that run (#13).
Every later update gets that; this one does not, because the code that does it
is what this update installs.

### What is NOT touched

`memory/` and `profiles/` are left completely alone — verified by `diff -r`
before and after on the scratch copy. Your memories, session log, corrections
and profiles survive untouched. `config.yaml` has only its `version:` line
changed.

---

## 2. Check, then apply

```bash
bash ~/.trellis/scripts/trellis-update.sh --check      # expect: Update available: v0.5.x → v0.6.0
bash ~/.trellis/scripts/trellis-update.sh              # apply
```

The old updater's summary ends with `wall — install-hooks.sh run`. The new
`install-hooks.sh` adds one line after that:

```
install-hooks: if you have just updated, run scripts/post-update.sh for this release's next steps.
```

That line is the handoff. Do what it says.

---

## 3. Run `scripts/post-update.sh` and follow its NEXT STEPS

```bash
bash ~/.trellis/scripts/post-update.sh --from 0.5.1
```

It rebuilds the memory database on the new schema (1/4 — a full rebuild; the
schema changed under the same files), counts typed memory files against
database rows (2/4), runs the stranded-file audit (3/4 — every memory file the
index or the database cannot see, by name, with its fix), prints the
governance-log status with a reason if it is starved (4/4), and ends with the
steps below. They are repeated here in case the output scrolled away:

```
NEXT STEPS — for the AI reading this:
1. Re-read directives.md now. The steps that changed since 0.5.x: Session Start 8b (run
   scripts/recall.sh before answering from memory), Session Start 6 (run scripts/memory-audit.sh
   when fragmentation is HIGH) and Session End 6 (run scripts/record-session.sh).
2. Prove recall works: scripts/recall.sh <a distinctive word from any memory you know>
   — expect a line with a memory/ path. If it prints "no database" or "out of date", run
   scripts/rebuild-trellis-db.sh and read what it says.
3. If 3/4 above named stranded files, repair them as its own NEXT STEPS say — the file, the
   class, the fix — then run scripts/rebuild-trellis-db.sh. Touch no memory file it did not name.
4. At the end of this session, run scripts/record-session.sh, then scripts/memory-sync.sh.
5. Tell the user, in one line, whether all their memory files reached the database (2/4 above)
   and how many files the audit named (3/4 above).
```

If you did not run the updater by hand (the user said "check for updates and
run the update"), this is still the step to run next, and the directives you
re-read in step 1 say so under *Updates & Diagnostics*.

---

## 4. Config: no new keys

This release adds **zero** config keys and changes no pinned value, so there is
nothing to reconcile for 0.5.1 → 0.6.0. Config backfill (#12) is still not
built; it is not needed here.

**If you are still on 0.5.0**, the three 0.5.1 edits are still owed, quoted from
[UPGRADING-0.5.1 §3](UPGRADING-0.5.1.md):

```yaml
plugins:
  dn_version: "1.4"
  dn_checksum: "f6a43a8844232410cdd27069ead0ef49afed41e4a28c5e6c9345d6c35a6cb5fc"

health:
  volatility_review: 0.50        # new key — review when one commit touches this
                                 # fraction of memory files
```

---

## 5. What changed in behaviour

- **The staleness pre-flight is live.** `memory_confidence` had no writer before
  0.6.0, so `SELECT * FROM v_memories_stale` and the "N stale memories" line
  were reporting over an empty table. They are populated now, with defaults per
  kind and the file's last git date as `last_reinforced`. A mature install may
  see stale-memory findings it has never seen before; they are real findings,
  not upgrade damage. Frontmatter decay overrides (`half_life_days:` and the
  like) are reported as unmapped keys and not yet honoured.
- **Untyped and unindexed files are named.** The rebuild prints which memory
  files carry no `type:` and so are not rows (MEMORY.md, corrections.md,
  protocol.md and session-log.md are expected there), which frontmatter keys
  reach no column, and which table columns are empty across every row.
- **A refusing rebuild is a feature.** If `rebuild-trellis-db.sh` exits 2 or 3
  it says why, keeps the previous database, and names the fix or the escape
  hatch (`TRELLIS_DB_CHECK=off`, once). Report it; do not silence it. The four
  refusals: no FTS5 in sqlite3; typed files on disk with zero rows loaded; a
  typed file that reached no row (by name); a search table that indexes less
  than the memories.
- **`.session-events` → `scripts/record-session.sh`.** The session-log row is
  appended by a script now (Session End step 6, the Claude Code SessionEnd hook,
  and the crash-recovery path all call it). On Codex there is no hook: the
  directive is the mechanism.
- **Legacy table names are views.** `feedback`, `projects`, `"references"` and
  `user_profile` are views over `memory_item`; every query that read them still
  works. New code should read `memories` (name, type, description, path) or
  `v_memory_addr`.
- **`ln(2)` is a literal in the schema**, so a sqlite3 built without math
  functions loads it; FTS5 is still required, and its absence is one named
  refusal instead of six unrelated errors.

---

## 6. Feedback

If you have a minute, we would like to hear how this release behaved on your
install. Run `scripts/trellis-diagnostic.sh` — it reports structure only
(counts, versions, health lines), never memory content — and send the output, or
open an issue at https://github.com/energyscholar/trellis/issues. After about
ten more sessions, `scripts/acs-check.sh` should start producing a number
instead of "insufficient data"; if it does, or if it still does not, that is
worth a line too. Entirely optional.

---

## 7. Known-open, so you are not surprised later

- **#12** — config keys are not backfilled. Not needed for this release (no new
  keys); §4 covers the 0.5.1 edits if you skipped that release.
- **#15** — no health-snapshot writer yet; `health_snapshots` stays empty unless
  something appends to `scripts/db/data-health.sql`.
- **#16** — `health-check.sh`'s remaining metrics are not all measured yet
  (drift prints 0.00).
- **#18** — topology FULL-over-warning.
- **#19** — several config keys are declared but not read.
- **#20** — the two directives files are reconciled and a generated-file header
  marks the assembled one; the refuse-on-divergence detection is not built.
