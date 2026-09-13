-- Longmem DB schema — SQLite acceleration layer
-- Flat files (.longmem/memory/*.md) remain source of truth.
-- This DB is a read cache rebuilt from those files via ingest + rebuild.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ============================================================================
-- Core memory tables
-- ============================================================================

CREATE TABLE corrections(
    id INTEGER PRIMARY KEY,
    number INTEGER UNIQUE NOT NULL,
    title TEXT NOT NULL,
    context TEXT,
    type TEXT CHECK(type IN ('domain', 'epistemic', 'architecture', 'identity')),
    depth TEXT CHECK(depth IN ('routing-change', 'nuance', 'addition')),
    cluster TEXT CHECK(cluster IN ('orientation', 'epistemic', 'technical', 'identity')),
    notice TEXT,
    source TEXT,
    domain TEXT,
    established TEXT,
    last_violated TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE correction_connections(
    correction_id INTEGER NOT NULL REFERENCES corrections(id),
    connected_id INTEGER NOT NULL REFERENCES corrections(id),
    relationship TEXT,
    PRIMARY KEY (correction_id, connected_id)
);

-- ============================================================================
-- Memory supertype: one row per memory FILE, whatever its kind
-- ============================================================================
-- Every memory file with a frontmatter type: is exactly one memory_item row.
-- The kind is data (memory_kind), not a table name, so a type: the schema has
-- never heard of still lands (as 'other'), is still searchable, and is still
-- openable by path. Kind-specific fields live in *_detail tables keyed by
-- item_id. The legacy names feedback / projects / "references" / user_profile
-- are VIEWS over this table (views.sql), so every inherited query still runs.

CREATE TABLE memory_kind (
    id           INTEGER PRIMARY KEY,
    name         TEXT NOT NULL UNIQUE,     -- the frontmatter type: value
    source_table TEXT NOT NULL,            -- legacy name reported by memory_fts / v_memory_addr
    in_registry  INTEGER NOT NULL CHECK (in_registry IN (0,1)),
    file_backed  INTEGER NOT NULL CHECK (file_backed IN (0,1))
);
INSERT INTO memory_kind(id, name, source_table, in_registry, file_backed) VALUES
    (1,'feedback', 'feedback',     1, 1),
    (2,'skill',    'skill',        1, 1),
    (3,'project',  'projects',     1, 1),
    (4,'reference','references',   1, 1),
    (5,'user',     'user_profile', 1, 1),
    (6,'other',    'other',        1, 1);   -- any type: this table does not name. Landed, reported, never dropped.

CREATE TABLE memory_item (
    id             INTEGER PRIMARY KEY,
    kind_id        INTEGER NOT NULL REFERENCES memory_kind(id),
    slug           TEXT NOT NULL,
    name           TEXT NOT NULL,          -- frontmatter name:, else slug
    description    TEXT,                   -- frontmatter description:
    content        TEXT,                   -- the whole body. Every kind. This is what makes search work.
    why            TEXT,
    how_to_apply   TEXT,
    domain         TEXT NOT NULL DEFAULT 'general',
    opsec_level    TEXT CHECK (opsec_level IS NULL OR opsec_level IN ('public','trusted','restricted','compartmented')),
    compaction_tag TEXT,
    established    TEXT,
    source_file    TEXT NOT NULL,          -- basename ingest read
    path           TEXT NOT NULL,          -- openable address, relative to memory/ (= source_file for file-backed kinds)
    created_at     TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at     TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (kind_id, slug)
);
CREATE INDEX idx_memory_item_kind   ON memory_item(kind_id);
CREATE INDEX idx_memory_item_slug   ON memory_item(slug);
CREATE INDEX idx_memory_item_domain ON memory_item(domain);
CREATE INDEX idx_memory_item_source ON memory_item(source_file);

CREATE TABLE feedback_detail ( item_id INTEGER PRIMARY KEY REFERENCES memory_item(id) ON DELETE CASCADE, rule TEXT );
CREATE TABLE project_detail  ( item_id INTEGER PRIMARY KEY REFERENCES memory_item(id) ON DELETE CASCADE, status TEXT NOT NULL DEFAULT 'active' );
CREATE TABLE user_detail     ( item_id INTEGER PRIMARY KEY REFERENCES memory_item(id) ON DELETE CASCADE, attribute TEXT, context TEXT );

CREATE TRIGGER memory_item_updated AFTER UPDATE ON memory_item
BEGIN UPDATE memory_item SET updated_at = datetime('now') WHERE id = NEW.id; END;

CREATE TABLE people(
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    tier INTEGER,
    tier_notes TEXT,
    role TEXT,
    relationship TEXT,
    description TEXT,
    email TEXT,
    handles TEXT,
    approach_notes TEXT,
    opsec_level TEXT CHECK(opsec_level IN ('public', 'trusted', 'restricted', 'compartmented')),
    status TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE person_projects(
    person_id INTEGER NOT NULL REFERENCES people(id),
    project_slug TEXT NOT NULL,
    PRIMARY KEY (person_id, project_slug)
);

-- ============================================================================
-- Session tracking
-- ============================================================================

CREATE TABLE sessions(
    id INTEGER PRIMARY KEY,
    number INTEGER UNIQUE NOT NULL,
    date TEXT,
    significance TEXT NOT NULL DEFAULT 'PARADIGM'
        CHECK(significance IN ('PARADIGM', 'ROUTINE')),
    register TEXT,
    summary TEXT,
    reconstruction_priority INTEGER,
    handoff TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE session_themes(
    session_id INTEGER NOT NULL REFERENCES sessions(id),
    theme TEXT NOT NULL,
    PRIMARY KEY (session_id, theme)
);

CREATE TABLE session_events(
    id INTEGER PRIMARY KEY,
    session_id INTEGER NOT NULL REFERENCES sessions(id),
    axis TEXT NOT NULL CHECK(axis IN ('memory', 'structure', 'ethics')),
    event TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'human'
        CHECK(source IN ('human', 'environment', 'system')),
    set_point TEXT,
    set_point_provenance TEXT
        CHECK(set_point_provenance IS NULL OR set_point_provenance IN ('human', 'consequence')),
    created_at TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Knowledge tracking
-- ============================================================================

CREATE TABLE decisions(
    id INTEGER PRIMARY KEY,
    topic TEXT NOT NULL,
    decision TEXT,
    rationale TEXT,
    date TEXT,
    status TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE breakthroughs(
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK(status IN ('active', 'killed')),
    date TEXT,
    killed_date TEXT,
    killed_reason TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Task tracking
-- ============================================================================

CREATE TABLE ptl_items(
    id INTEGER PRIMARY KEY,
    stable_id TEXT UNIQUE NOT NULL,
    title TEXT NOT NULL,
    tier INTEGER NOT NULL CHECK(tier IN (1, 2, 3, 4, 5)),
    status TEXT NOT NULL CHECK(status IN (
        'READY', 'ACTIVE', 'IN_PROGRESS', 'BLOCKED', 'REVIEW',
        'NEEDS_PLAN', 'TODO', 'DONE', 'DROPPED', 'SHELF',
        'WAITING', 'ARCHIVED', 'STALE'
    )),
    owner TEXT,
    created TEXT,
    last_touched TEXT,
    decay_exempt INTEGER DEFAULT 0,
    description TEXT,
    detail_file TEXT,
    blocked_by TEXT,
    source TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE pending_items(
    id INTEGER PRIMARY KEY,
    description TEXT NOT NULL,
    status TEXT,
    tier TEXT CHECK(tier IN ('NOW', 'SOON', 'LATER')),
    created TEXT,
    last_touched TEXT,
    category TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Entity graph
-- ============================================================================

CREATE TABLE associations(
    id INTEGER PRIMARY KEY,
    source_type TEXT NOT NULL,
    source_id INTEGER NOT NULL,
    target_type TEXT NOT NULL,
    target_id INTEGER NOT NULL,
    relationship TEXT NOT NULL CHECK(relationship IN (
        'relates_to', 'contradicts', 'supersedes', 'exemplifies', 'derives_from'
    )),
    basis TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Health monitoring
-- ============================================================================

CREATE TABLE health_snapshots(
    id INTEGER PRIMARY KEY,
    session_number INTEGER,
    date TEXT,
    pressure REAL,
    freshness REAL,
    coverage REAL,
    drift REAL,
    notes TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Confidence decay overlay
-- ============================================================================
-- Metadata pattern: keyed by (source_table, source_id), bolted onto any table.
-- Branchless exponential decay via generated column.
-- Pinned items: decay_rate=0 so exp(0)=1.0 naturally.

CREATE TABLE memory_confidence(
    id INTEGER PRIMARY KEY,
    source_table TEXT NOT NULL,
    source_id INTEGER NOT NULL,
    base_confidence REAL NOT NULL DEFAULT 1.0,
    half_life_days INTEGER CHECK(half_life_days IS NULL OR half_life_days > 0),
    pinned INTEGER NOT NULL DEFAULT 0,
    decay_rate REAL GENERATED ALWAYS AS (
        CASE WHEN half_life_days IS NULL THEN 0.0
             -- ln(2) as a literal — math functions are optional in sqlite3 builds
             ELSE 0.6931471805599453 / half_life_days
        END
    ) STORED,
    last_accessed TEXT,
    last_reinforced TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(source_table, source_id)
);

CREATE TABLE confidence_config(
    source_table TEXT PRIMARY KEY,
    default_half_life_days INTEGER CHECK(default_half_life_days IS NULL OR default_half_life_days > 0),
    default_pinned INTEGER NOT NULL DEFAULT 0,
    description TEXT
);

-- ============================================================================
-- Evidence / provenance (append-only audit trail)
-- ============================================================================

CREATE TABLE memory_evidence(
    id INTEGER PRIMARY KEY,
    source_table TEXT NOT NULL,
    source_id INTEGER NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN (
        'established', 'violated', 'referenced', 'observed', 'corrected'
    )),
    evidence_text TEXT,
    session_number INTEGER,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ============================================================================
-- Pipeline tracking
-- ============================================================================

CREATE TABLE ingest_log(
    id INTEGER PRIMARY KEY,
    source_file TEXT NOT NULL,
    table_name TEXT NOT NULL,
    action TEXT NOT NULL,
    timestamp TEXT DEFAULT (datetime('now'))
);

-- ============================================================================
-- Triggers: auto-update timestamps
-- ============================================================================

CREATE TRIGGER corrections_updated AFTER UPDATE ON corrections
BEGIN UPDATE corrections SET updated_at = datetime('now') WHERE id = NEW.id; END;

CREATE TRIGGER people_updated AFTER UPDATE ON people
BEGIN UPDATE people SET updated_at = datetime('now') WHERE id = NEW.id; END;

CREATE TRIGGER sessions_updated AFTER UPDATE ON sessions
BEGIN UPDATE sessions SET updated_at = datetime('now') WHERE id = NEW.id; END;

CREATE TRIGGER decisions_updated AFTER UPDATE ON decisions
BEGIN UPDATE decisions SET updated_at = datetime('now') WHERE id = NEW.id; END;

CREATE TRIGGER breakthroughs_updated AFTER UPDATE ON breakthroughs
BEGIN UPDATE breakthroughs SET updated_at = datetime('now') WHERE id = NEW.id; END;

CREATE TRIGGER ptl_items_updated AFTER UPDATE ON ptl_items
BEGIN UPDATE ptl_items SET updated_at = datetime('now') WHERE id = NEW.id; END;

CREATE TRIGGER pending_items_updated AFTER UPDATE ON pending_items
BEGIN UPDATE pending_items SET updated_at = datetime('now') WHERE id = NEW.id; END;

-- ============================================================================
-- Triggers: guardrails
-- ============================================================================

CREATE TRIGGER corrections_count_warn AFTER INSERT ON corrections
WHEN (SELECT COUNT(*) FROM corrections) > 25
BEGIN
    INSERT OR IGNORE INTO pending_items(description, status, tier, category)
    VALUES ('Corrections count high: ' || (SELECT COUNT(*) FROM corrections) ||
            ' rows — consider compacting', 'open', 'LATER', 'memory');
END;


-- ============================================================================
-- FTS5 full-text search
-- ============================================================================

-- Column order is a contract: snippet(memory_fts, 3, ...) means the body.
-- path is LAST and UNINDEXED — an address, not searchable text.
CREATE VIRTUAL TABLE memory_fts USING fts5(
    source_table,
    source_id UNINDEXED,
    title,
    content,
    path UNINDEXED,
    tokenize='porter unicode61'
);

-- ============================================================================
-- Default confidence config
-- ============================================================================

INSERT INTO confidence_config VALUES ('user_profile', 365, 0, 'User facts — slow decay');
INSERT INTO confidence_config VALUES ('feedback', 90, 0, 'Behavioral rules — moderate decay');
INSERT INTO confidence_config VALUES ('projects', 60, 0, 'Project state — fast decay');
INSERT INTO confidence_config VALUES ('references', 180, 0, 'External resources — moderate decay');
INSERT INTO confidence_config VALUES ('skill', 180, 0, 'Procedures — moderate decay');
INSERT INTO confidence_config VALUES ('other', 180, 0, 'Unclassified kinds — moderate decay');
INSERT INTO confidence_config VALUES ('corrections', NULL, 1, 'Corrections — pinned, no decay');
INSERT INTO confidence_config VALUES ('decisions', 90, 0, 'Decision context — moderate decay');
INSERT INTO confidence_config VALUES ('breakthroughs', 180, 0, 'Analytical advances persist');
INSERT INTO confidence_config VALUES ('people', 365, 0, 'Relationships are durable');
INSERT INTO confidence_config VALUES ('sessions', 30, 0, 'Ephemeral by nature');
