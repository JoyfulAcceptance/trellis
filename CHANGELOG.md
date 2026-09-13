# Changelog

## [Unreleased]

## [0.6.1] — 2026-09-13

A count with no names is not actionable. `health-check.sh` had reported
`fragmentation: 0.18 [HIGH]` and told the assistant to "add the unindexed
memory files to the file map" without saying which files — the same shape as
the upstream incident where six governance memories sat on disk unlisted and
were never loaded. This release names them.

### Upgrading

No config keys are added. Everything in
[docs/UPGRADING-0.6.0.md](docs/UPGRADING-0.6.0.md) applies to an install
coming from 0.5.x; `scripts/post-update.sh` now runs the audit for you. See
[docs/UPGRADING-0.6.1.md](docs/UPGRADING-0.6.1.md).

### Added

- `scripts/memory-audit.sh` — names every stranded memory file, where, and the
  one-line fix: not in `MEMORY.md` (A), no `type:` (B), frontmatter not on
  line 1 (C), File Map rows naming a file that is not on disk (F), typed files
  with no database row (G); dangling `[[wiki-links]]` (E, warn — links inside
  code are ignored) and CRLF endings (D, info). Read-only over `memory/`; ends
  with NEXT STEPS for the assistant; exit 1 when something is stranded;
  `--quiet` prints the summary line only; a new install prints
  `new install — nothing to audit`.
- `lib/memory-files.sh` — the one definition of "unindexed" and of the five
  protocol files (`MEMORY.md`, `corrections.md`, `protocol.md`,
  `session-log.md`, `training-primer.md`), shared by the fragmentation metric
  and the audit. `training-primer.md` is on the list because the directives
  read it by name, as they read `protocol.md`: it is a procedure, not a
  memory, never a row — and a fresh blank-profile install must audit clean.

### Changed

- **health-check.sh:** the fragmentation DO-NEXT names the fix — run
  `scripts/memory-audit.sh` — instead of asking for files it did not name;
  `session-log.md` and `training-primer.md` are protocol files and no longer
  count as unindexed.
- **post-update.sh:** four steps — the memory audit is 3/4; NEXT STEPS gain
  "repair what the audit named, then rebuild".
- **Directives:** Session Start step 6 — if fragmentation is HIGH, run the
  audit and repair what it names; Self-Maintenance names the audit for broken
  file references. `trellis-diagnostic.sh` carries the audit's summary line
  (counts only).

## [0.6.0] — 2026-09-13

The memory-layer release. On every install the shipped database rebuild had
been reporting `Rebuild complete … integrity OK` over an empty database, and
even once rows loaded the four-table schema had nowhere to put a `type: skill`
memory or a feedback typed inside an `insight-*.md`. This release makes every
typed memory file one row, gives every row an openable path, adds the search
script that returns those paths, and makes the rebuild refuse — by name —
to report success while holding less than the files.

### Upgrading

No config keys are added and no pinned value changes. After
`trellis-update.sh` finishes, run `scripts/post-update.sh` and follow the
NEXT STEPS it prints. The first update from 0.5.x is performed by the
installed 0.5.x updater, which prints its old summary and deletes custom
plugins/scripts and `scripts/db/data-*.sql` — back those up first. Read
[docs/UPGRADING-0.6.0.md](docs/UPGRADING-0.6.0.md) before updating an
established install.

### Added

- `memories` view (`name, type, description, path`) — every memory with an
  openable address — and `v_memory_addr` (7 columns; the OPSEC boundary).
- `scripts/recall.sh <terms>` — type, path and a one-line description per hit;
  quotes every token (a hyphenated term is no longer an FTS5 syntax error);
  loud on a failed query; exit 4 on no match; logs counts only to
  `health/recall.log`.
- `scripts/record-session.sh [--crash]` — compiles `.session-events` into one
  `memory/session-log.md` row; no-file is a stated no-op; the same session is
  never appended twice. Called by the SessionEnd hook, the Session End
  directive, and the crash-recovery path.
- `scripts/post-update.sh [--from OLD]` — rebuilds on the current schema,
  counts typed files against rows, prints the governance-log status and the
  NEXT STEPS for the assistant reading it cold.
- Population report at rebuild: every all-empty column named; a kind census;
  files without `type:` and frontmatter keys that reach no column listed.
- `.update-backup/<old-version>-<timestamp>/` — the previous `scripts/` and
  `plugins/`, kept by the updater (gitignored).
- `lib/memory-files.sh` — the one definition of "a typed memory file".
- CI prints bash and sqlite3 versions and whether FTS5 is present.

### Changed

- **Schema:** `memory_item` supertype with `memory_kind` (feedback, skill,
  project, reference, user, other); `feedback`, `projects`, `"references"`,
  `user_profile` are now views over it — every inherited view and consumer
  runs unedited. `"references"` gains `content`. `memory_fts` carries `path`
  (last, unindexed). `confidence_config` gains `skill` and `other`.
- **One FTS insert** over the supertype, with `path`, excluding compartmented rows.
- **Ingest:** the bare call (or `--all`) emits every typed memory file into one
  derived seed, `scripts/db/data-memories.sql` (gitignored). An unknown
  `type:` lands as kind `other` and is named, never dropped. Frontmatter is
  the block after a fence on line 1 — a `---` further down is a horizontal
  rule, which is how `protocol.md` had been ingested as a memory.
- **Rebuild:** regenerates the seed on every run; removes legacy per-type
  seeds by name; populates `memory_confidence` (the staleness pre-flight and
  the decay views become live for the first time — a behaviour change);
  `--if-stale` says when it does nothing; the staleness key covers the
  pipeline (schema, views, ingest, rebuild), from PR #24; final line states
  `R memories / F typed files`.
- **health-check.sh / trellis-profile.sh** show the rebuild's stderr and keep
  its exit; the sqlite line reads `R memories / F typed files` and warns when
  R < F or the schema predates the `memories` view.
- **Directives:** `directives-base.md` carries the three blocks it had drifted
  behind `directives.md` on; the assembled file opens with a GENERATED marker
  and `assemble-directives.sh` emits exactly one. Session Start step 8 runs
  the rebuild and reports a refusal; new 8b: recall before you guess; Session
  End step 6 runs `record-session.sh`; the Updates section routes to
  `post-update.sh`. `protocol.md` and the platform activation blocks name
  `record-session.sh`.
- **Updater:** re-executes its freshly installed self for the post-swap steps
  (#13), keeps a backup (#27), preserves `scripts/db/data-*.sql` (#23), names
  the user's own additions, copies `directives-base.md` as the base, and runs
  `post-update.sh`.
- **acs-check.sh:** "insufficient data" now says why — the last row and the
  number of session ends since it with no row.
- `ln(2)` is a literal in `schema.sql` (math functions are optional in sqlite3 builds).

### Fixed

- #17 — the rebuild no longer destroys health history and no longer ignores
  pipeline changes (PR #24, folded in).
- #25 — a sqlite3 without FTS5 is one named refusal (exit 2) with the fix
  stated, not six unrelated failures.
- #23 — `scripts/db/data-*.sql` survive an update (from the 0.6.0 updater onward).
- #27 — the previous `scripts/` and `plugins/` are kept in `.update-backup/`
  and custom additions are named (from the 0.6.0 updater onward).
- #13 — the updater re-execs into the new script so the new release's
  finishing steps run (from the 0.6.0 updater onward).
- #20 (partial) — base and assembled directives reconciled, generated-file
  header, heading-set test. Refuse-on-divergence detection is not built.
- #12 — documented in UPGRADING-0.6.0 (no keys added by this release); stays open.

### Removed

- FTS arms for `corrections`, `people`, `sessions`, `decisions`,
  `breakthroughs` — nothing in the shipped scripts writes those tables; a
  future writer goes through `memory_item`.
- The four per-type ingest globs and their seeds (`data-feedback.sql`,
  `data-projects.sql`, `data-references.sql`, `data-user.sql`); the rebuild
  removes any it finds, by name.

### Feedback

If you have a minute, we would like to hear how this release behaved on your
install. Run `scripts/trellis-diagnostic.sh` — it reports structure only
(counts, versions, health lines), never memory content — and send the output,
or open an issue at https://github.com/energyscholar/trellis/issues. After
about ten more sessions, `scripts/acs-check.sh` should start producing a
number instead of "insufficient data"; if it does, or if it still does not,
that is worth a line too. Entirely optional.

## [0.5.1] — 2026-08-07

Interim release. It ships work that had been merged since 0.5.0 but was
undeliverable: the version line never moved, and `trellis-update.sh` returns
early when the installed and template versions match, so every install reported
"Already up to date (v0.5.0)" while missing all of the below — including a
Dignity Net version change.

**Upgrading from 0.5.0 requires three manual edits to `config.yaml`.** The
updater replaces `scripts/` and `plugins/` but stamps only the `version:` line in
your config; it does not backfill new or changed keys (#12). Because
`plugins/dignity-net/` becomes v1.4 while your config still pins v1.2,
`health-check.sh` will report the canon **DRIFTED** on every run until you set:

```yaml
plugins:
  dn_version: "1.4"
  dn_checksum: "f6a43a8844232410cdd27069ead0ef49afed41e4a28c5e6c9345d6c35a6cb5fc"
health:
  volatility_review: 0.50        # new key
```

### Added
- **Dignity Net v1.4 is now canon** (#14), replacing v1.2. Adds asymmetry as an explicit ontological and governance concern ("unchecked asymmetry magnifies distortion"), a risk-magnitude check — *can affected people correct, refuse, and recover?* — the North Star "Hold a coherent container", and "identity is rhythmic". The canon pin in `config.yaml` moves to `1.4` with a new checksum; see the upgrade note above.
- **Section-aware config resolution** (#21). `template/scripts/lib/config.sh` is now the single implementation of `get_config`, which had been copy-pasted five times. Bare keys keep their existing behaviour; `SECTION.KEY` resolves within the named block, and surrounding quotes are stripped.

### Fixed
- **`database.enabled: false` was ignored — the documented flat-file mode had never worked** (#21). Every copy of `get_config` grepped `^\s*KEY:` and took `head -1`, i.e. the first match at *any* nesting depth, so `memory.enabled` (line 24) shadowed `database.enabled` (line 104). `health-check.sh` rebuilt the database and reported `sqlite: ON` against a config that disables it. Four of the five old copies also could never return their own default, because the pipeline's exit status was the wrong one to test.
- **Memory health mechanics** (#9): unindexed memories now warn instead of passing silently, the volatility review trigger is defined (`health.volatility_review`), and the last `bc` dependency is gone from the health check — it had been printing `0.00 [OK]` for every metric on any install without `bc`.
- ACS and every other reader of `session-log.md` now accept the pre-v0.5 bare-numeric session id (`| 17 |`) alongside the current `| S22 |` form. The strict `^\| S[0-9]` matcher in `acs-check.sh`, `proprioceptive-check.sh`, `trellis-profile.sh`, and `stress-test-compare.sh` silently excluded an installation's entire pre-update history, reporting "insufficient data (have 0)" against a log with 18 valid rows. (#8)
- `tests/test-integrity.sh` no longer passes when it cannot run its own checks. The plugin and manifest checks piped `python3` output into `for` with stderr discarded, so a missing PyYAML produced an empty list, an unexecuted loop body, and a green result meaning "skipped". Extraction failure is now a test failure, and a repo with manifests that checked none of them fails too. (#6)
- `tests/run-all.sh` and `CONTRIBUTING.md` now offer install routes that work on externally-managed Python (PEP 668 — Debian 12+, Ubuntu 23.04+, Homebrew), where the previously documented `pip install -r requirements-test.txt` is refused outright. (#7)
- `acs-check.sh` no longer aborts on macOS. Line 403 interpolated an unbraced `$first_session` immediately followed by an en-dash; bash 3.2 folds the multi-byte character into the variable name, so `set -u` killed the script with `first_session…: unbound variable` after printing two lines of header. Every macOS install with enough sessions to reach the report was affected — it went unseen only because the sole known macOS install short-circuited earlier on the #8 bug, which means fixing #8 is what would have walked it into this crash.
- `CONTRIBUTING.md` no longer instructs contributors to run `tests/test-hashes.sh --reset`; no such script exists in the repo.

### Added (testing)
- `tests/test-acs-session-formats.sh`: regression coverage for numeric-only, `S`-prefixed-only, and mixed session logs, asserting session count, first/last identifier, and provenance parsing across `acs-check.sh` and `proprioceptive-check.sh`.
- CI (`.github/workflows/tests.yml`): the suite on ubuntu and macOS, a job asserting the suite fails *loudly* without PyYAML rather than skipping (#4's last criterion), and a standalone portability lint. The macOS `acs-check.sh` abort above was caught by this workflow's first run.
- `tests/test-portability.sh` now flags an unbraced `$var` followed by a byte outside printable ASCII — the bash 3.2 unbound-variable trap, which is invisible on inspection and invisible on Linux.

## [0.5.0] — 2026-07-13

### Added
- Memory deletion wall (`scripts/git-hooks/pre-commit` + `scripts/install-hooks.sh`): commits that delete a top-level `memory/*.md`, or move one out of the read path (e.g. into `memory/archive/`), are blocked. In-place renames allowed. Deliberate override via `ALLOW_MEMORY_DELETE=1` is permitted and logged to `health/deletion-attempts.log`.
- Recovery UX: `RECOVERY.md` (one-page restore guide, lives in the install so it travels in the private memory repo), `BOOTSTRAP.md` (browser-only bootstrap prompt), `scripts/restore.sh` (one-command restore: recover → update → arm wall → wire → health-check).
- `health-check.sh`: re-arms the wall idempotently on every run and reports "wall: armed"; identity check (config `ai_name` vs active profile); Dignity Net canon pin check (`plugins.dn_version` + `plugins.dn_checksum` in config); one imperative DO-NEXT line per non-OK check.
- `rebuild-trellis-db.sh` snapshot freshness gate: never rebuild from a `data-*.sql` snapshot older than the memory files — regenerate from markdown first (a frozen snapshot silently strands every memory written after it).
- `tests/test-wall.sh` (wall behavior) and `tests/test-portability.sh` (macOS/BSD lint: no `grep -P`, `md5sum`, `stat -c`, `date -d`, bare `sed -i`, `realpath` in `template/scripts/`).

### Changed
- `trellis-update.sh`: stage-and-swap replacement of `scripts/` and `plugins/` (no window with scripts deleted; a crash mid-update can no longer strip an install or its wall); stamps the new version into the user's `config.yaml` (the version gate otherwise never advances); runs `install-hooks.sh` as the final step.
- `ingest-memories.sh`: CRLF-tolerant frontmatter parsing (a `\r` on the fence made memories silently unrecallable); absolute `--output` paths honored (was silently writing nothing); portable mtime/date handling; `flock` fallback for macOS; SQL-escaping fixes.
- `memory-sync.sh`: portable SHA-256 hashing that fails loud when no hash tool exists; explicit per-path staging (no `git add -A`, and no all-or-nothing pathspec list); pulls the current branch instead of assuming `main`.
- `github-setup.sh`, `trellis-profile.sh`: portable in-place sed; no hardcoded branch names; profile load passes the wall via logged override (the swap is deliberate and auto-saved first).
- Version bumped to 0.5.0.

## [0.4.0] — 2026-05-27

### Added
- Update mechanism (`scripts/trellis-update.sh`): pull latest from GitHub, overwrite system files, preserve user data. `--check` flag for dry run.
- Diagnostic report (`scripts/trellis-diagnostic.sh`): structured metadata report for alpha tester feedback. No personal data, user-initiated copy-paste only.
- Alpha testing guide (`docs/alpha-testing.md`): setup, session workflow, feedback prompts, troubleshooting
- Directives-base.md pattern: `assemble-directives.sh` reads from unassembled base template, writes to assembled directives.md. Idempotent reassembly.
- `config.yaml`: `update.repo_url` field for configurable update source
- Codex install notes in `docs/install.md` (Tier 2, auto_push/pull, AGENTS.md)
- Update/diagnostic awareness in `directives.md`

### Changed
- `assemble-directives.sh`: reads from `directives-base.md` if present (fixes duplicate assembly bug)
- `docs/install.md`: directives-base.md step, Codex notes, update section
- `docs/uninstall.md`: SessionEnd hook removal step, Codex-specific notes
- Version bumped to 0.4.0

## [0.3.1] — 2026-05-27

### Added
- Memory profile system (`scripts/trellis-profile.sh`): save, load, list, delete, current, interactive menu
- Profile pin/unpin: protect test baselines from session-end auto-save
- Profile export/import: portable .tar.gz archives for moving profiles between machines
- SessionEnd hook (`scripts/trellis-hook-session-end.sh`): auto-sync memory + auto-save profile
- Training primer (`memory/training-primer.md`): 5 guided deduction questions targeting weak K3 edges
- Session start directive: training primer loaded for sessions < 10

### Changed
- `directives.md`: Memory Profiles section expanded with pin/unpin/export/import commands
- SessionEnd hook respects pinned profiles (routes auto-save to `_autosave`)
- `memory/MEMORY.md` template: file map includes training-primer.md
- Install verification checklist includes training-primer.md

## [0.3.0] — 2026-05-27

### Added
- ACS governance measurement (`scripts/acs-check.sh`): cross-axis catalysis matrix on K3, depressed cubic eigenvalue solver in awk, self-healing recommendations per weak edge
- Session event log (`memory/session-log.md`): append-only markdown table, three axis columns, machine-parseable
- 4 starter corrections seeding cross-axis catalysis at install time
- ACS one-liner integrated into `health-check.sh` output
- ACS config section in `config.yaml` (window size, thresholds, check interval)
- Self-healing directives: weak-edge recommendations fed back through protocol

### Changed
- `directives.md`: session-end step 6 now includes event logging; ACS governance health section added
- `protocol.md`: session-end step 6 (log events), self-maintenance trigger for ACS check every ~10 sessions
- `corrections.md`: ships with 4 generic starter corrections instead of empty
- Uninstall reset preserves starter corrections and session-log format

## [0.2.0] — 2026-05-25

### Added
- Central install architecture (`~/.trellis/`)
- Memory layer ported from longmem v2.2.0 (protocol, directives, corrections, sessions, health)
- SQLite acceleration layer (schema, views, rebuild, ingest, FTS5, confidence decay, evidence)
- OPSEC compartmentation (optional `opsec_level` on people, feedback, projects, references)
- Dignity Net ethics plugin v1.0.0 (Genevieve Prentice, DN License)
- Triad structure plugin v1.0.0 (MIT)
- Plugin architecture with YAML manifests and directives assembly
- Platform adapters: Claude Code, Codex, Cursor
- `memory-sync.sh` — local commit + optional remote push with public repo guard
- `health-check.sh` — pressure, fragmentation, volatility, drift metrics
- `topology-check.sh` — governance axis counting vs threshold
- `assemble-directives.sh` — plugin directives assembly
- `wire-platform.sh` — activation block generator
- `rebuild-trellis-db.sh` — atomic SQLite rebuild with verification
- `ingest-memories.sh` — .md frontmatter to SQL parser
- Storage tiers (T0-T3) with security documentation
- LLM-executable install and uninstall flows
- Restore-from-backup install path
- Comprehensive config.yaml with 13 parameter sections
- Architecture reference document
- Test suite (7 tests: smoke, integrity, config, licenses, install, uninstall)
- TRELLIS_HOME resolution (env > breadcrumb > default) in all scripts

### Changed
- Restructured from per-project (`.trellis/`) to central install (`~/.trellis/`)
- Distribution uses `template/` directory (copied, not cloned)
- Install/uninstall docs moved to `docs/`

## [0.1.0] — 2026-05-21

Initial release. Per-project architecture.
