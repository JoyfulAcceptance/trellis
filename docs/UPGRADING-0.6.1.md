# Upgrading an established install to v0.6.1

**Audience: the Trellis instance doing the upgrade, and the person supervising it.**

Read this whole page before running anything. It is short because almost
everything that matters about this update is on the 0.6.0 page.

---

## 1. Everything in UPGRADING-0.6.0.md applies

If you are coming from 0.5.x, read [UPGRADING-0.6.0.md](UPGRADING-0.6.0.md)
first — all of it. Its backup step (§1) still applies, because the updater
that RUNS is your installed 0.5.x copy, and that copy deletes custom plugins,
custom scripts and database seeds before the new updater is in place. Its §0
(your recall may have been degraded, and your files are fine), §2 (check, then
apply) and §4 (config: no new keys) are all still true of this update.

If you are coming from 0.6.0, the new updater is already on your machine: it
keeps a backup under `.update-backup/`, preserves your additions, and names
what it changed. Run `scripts/trellis-update.sh --check`, then
`scripts/trellis-update.sh`.

---

## 2. What 0.6.1 adds: `scripts/memory-audit.sh`

0.6.0 made every typed memory file a database row and gave `health-check.sh`
a fragmentation metric. That metric was a COUNT: "0.18 [HIGH], add the
unindexed memory files to the file map" — without saying which files. A count
with no names is not actionable, and the same shape of gap is how governance
memories end up on disk, unlisted, and never loaded.

`scripts/memory-audit.sh` names them. It reads every file under `memory/`
and reports seven classes, one section each, every file in exactly one of the
first three:

- **A** not in `memory/MEMORY.md` — unindexed, unrecallable from the hot cache
- **B** no `type:` in its frontmatter — never becomes a database row (the
  five protocol files — `MEMORY.md`, `corrections.md`, `protocol.md`,
  `session-log.md`, `training-primer.md` — are expected here and never reported)
- **C** frontmatter not on line 1 — a `type:` the ingest cannot see
- **D** CRLF line endings — information only, nothing is stranded
- **E** dangling `[[wiki-links]]` — a warning, nothing is stranded (links
  inside code blocks and `code spans` are ignored)
- **F** File Map table rows naming a file that is not on disk
- **G** typed files with no database row (or a database that predates the
  `memories` view)

Every line names the file and the one-line fix. It is **read-only**: the
script never writes under `memory/`. It names; you repair. The output ends
with a NEXT STEPS block that says how, class by class. Exit 1 means something
is stranded (A+B+C+F+G > 0); D and E alone exit 0.

---

## 3. `scripts/post-update.sh` runs it for you

`post-update.sh` is now four steps: 1/4 rebuild, 2/4 files vs rows, **3/4 the
memory audit**, 4/4 governance log. The audit's full output, names included,
is indented under 3/4. The NEXT STEPS block it prints gained one step; here it
is in full, in case the output scrolled away:

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

---

## 4. The one-line check

```bash
bash ~/.trellis/scripts/memory-audit.sh --quiet
```

Expect `memory-audit: 0 stranded (A:0 B:0 C:0 F:0 G:0), …` once you have
repaired what the full run named. An established install commonly shows a
handful of files under A on the first run — memories written over months that
never got a File Map row. Those are real findings, not upgrade damage: the
files were always there; the index did not know it. Add the rows, run
`scripts/rebuild-trellis-db.sh`, run the audit again.

`scripts/trellis-diagnostic.sh` now carries the audit's summary line (counts
only — the file names never leave your machine).

---

## 5. Config: no new keys

Nothing is added to `config.yaml`. The updater stamps `version: 0.6.1` and
touches nothing else in it.

---

## 6. Feedback

If you have a minute, we would like to hear how this release behaved on your
install. Run `scripts/trellis-diagnostic.sh` — it reports structure only
(counts, versions, health lines), never memory content — and send the output,
or open an issue at https://github.com/energyscholar/trellis/issues. After
about ten more sessions, `scripts/acs-check.sh` should start producing a
number instead of "insufficient data"; if it does, or if it still does not,
that is worth a line too. Entirely optional.
