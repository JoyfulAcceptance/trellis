-- Longmem views — query layer over the schema
-- Depends on: schema.sql (tables + v_memories_decayed via confidence overlay)

-- ============================================================================
-- Legacy memory names — VIEWS over memory_item
-- ============================================================================
-- feedback, projects, "references" and user_profile were tables until 0.6.0.
-- They are now derived from memory_item so that every inherited view and
-- consumer keeps working unedited. Column ORDER of feedback and projects
-- matches the old tables exactly (they feed f.* / p.* below).

CREATE VIEW feedback AS
SELECT mi.id, mi.slug, fd.rule, mi.why, mi.how_to_apply, mi.content, mi.established,
       NULL AS last_triggered, NULL AS source, mi.domain, mi.opsec_level, mi.compaction_tag,
       mi.source_file, mi.created_at, mi.updated_at
FROM memory_item mi JOIN memory_kind mk ON mk.id = mi.kind_id AND mk.name = 'feedback'
LEFT JOIN feedback_detail fd ON fd.item_id = mi.id;

CREATE VIEW projects AS
SELECT mi.id, mi.slug, mi.name, COALESCE(pd.status,'active') AS status, mi.description, mi.why,
       mi.how_to_apply, mi.content, mi.domain, mi.opsec_level, mi.compaction_tag, mi.source_file,
       mi.created_at, mi.updated_at
FROM memory_item mi JOIN memory_kind mk ON mk.id = mi.kind_id AND mk.name = 'project'
LEFT JOIN project_detail pd ON pd.item_id = mi.id;

CREATE VIEW "references" AS
SELECT mi.id, mi.slug, mi.name, NULL AS path_or_url, mi.description, mi.content,
       mi.opsec_level, mi.source_file, mi.created_at, mi.updated_at
FROM memory_item mi JOIN memory_kind mk ON mk.id = mi.kind_id AND mk.name = 'reference';

CREATE VIEW user_profile AS
SELECT mi.id, mi.slug, COALESCE(ud.attribute, mi.name) AS attribute, mi.content AS value,
       COALESCE(ud.context, mi.description) AS context, mi.source_file, mi.created_at, mi.updated_at
FROM memory_item mi JOIN memory_kind mk ON mk.id = mi.kind_id AND mk.name = 'user'
LEFT JOIN user_detail ud ON ud.item_id = mi.id;

-- ============================================================================
-- Foundation: confidence decay computation
-- ============================================================================

CREATE VIEW v_memories_decayed AS
SELECT mc.source_table, mc.source_id, mc.base_confidence, mc.half_life_days,
    mc.pinned, mc.decay_rate, mc.last_accessed, mc.last_reinforced, mc.created_at,
    mc.base_confidence * exp(
        -mc.decay_rate * MAX(0,
            julianday('now') - julianday(COALESCE(mc.last_reinforced, mc.created_at)))
    ) AS effective_confidence
FROM memory_confidence mc;

-- ============================================================================
-- Corrections
-- ============================================================================

-- Data-driven hot corrections: top N by recent violation frequency x severity
CREATE VIEW v_correction_heat AS
SELECT c.id, c.number, c.title, c.cluster, c.domain,
    COUNT(me.id) AS total_violations,
    SUM(CASE WHEN julianday('now') - julianday(me.created_at) <= 30
        THEN 1 ELSE 0 END) AS recent_violations,
    CASE WHEN c.cluster IN ('identity', 'orientation') THEN 2 ELSE 1
    END AS severity_weight,
    MAX(me.session_number) AS last_violated_session,
    COALESCE(SUM(CASE WHEN julianday('now') - julianday(me.created_at) <= 30
        THEN 1 ELSE 0 END), 0)
        * CASE WHEN c.cluster IN ('identity', 'orientation') THEN 2 ELSE 1 END
        AS heat
FROM corrections c
LEFT JOIN memory_evidence me ON me.source_table = 'corrections'
    AND me.source_id = c.id AND me.kind = 'violated'
GROUP BY c.id
ORDER BY heat DESC, total_violations DESC;

CREATE VIEW v_correction_cluster AS
SELECT cluster, COUNT(*) as count,
    GROUP_CONCAT(number || ': ' || title, '; ') as items
FROM corrections GROUP BY cluster;

-- ============================================================================
-- Projects
-- ============================================================================

CREATE VIEW v_active_projects AS
SELECT p.*, COALESCE(vmd.effective_confidence, 1.0) AS effective_confidence
FROM projects p
LEFT JOIN v_memories_decayed vmd
    ON vmd.source_table = 'projects' AND vmd.source_id = p.id
WHERE p.status NOT IN ('archived', 'complete')
ORDER BY p.updated_at DESC;

CREATE VIEW v_stale_projects AS
SELECT p.*, COALESCE(vmd.effective_confidence, 1.0) AS effective_confidence
FROM projects p
LEFT JOIN v_memories_decayed vmd
    ON vmd.source_table = 'projects' AND vmd.source_id = p.id
WHERE p.status = 'active'
AND p.updated_at < datetime('now', '-21 days');

CREATE VIEW v_project_summary AS
SELECT p.*,
    (SELECT COUNT(*) FROM ptl_items pt
     WHERE pt.description LIKE '%' || p.slug || '%') as related_ptl_count
FROM projects p;

-- ============================================================================
-- PTL (Prioritized Task List)
-- ============================================================================

CREATE VIEW v_ptl_active AS
SELECT * FROM ptl_items
WHERE status NOT IN ('DONE', 'DROPPED', 'SHELF', 'ARCHIVED')
AND tier IN (1, 2)
ORDER BY tier, stable_id;

CREATE VIEW v_ptl_stale AS
SELECT * FROM ptl_items
WHERE status NOT IN ('DONE', 'DROPPED', 'SHELF', 'ARCHIVED')
AND last_touched < datetime('now', '-21 days')
AND decay_exempt = 0;

-- ============================================================================
-- Sessions
-- ============================================================================

CREATE VIEW v_recent_sessions AS
SELECT s.*, GROUP_CONCAT(st.theme, ', ') as themes
FROM sessions s
LEFT JOIN session_themes st ON s.id = st.session_id
GROUP BY s.id
ORDER BY s.number DESC
LIMIT 10;

CREATE VIEW v_paradigm_sessions AS
SELECT s.*, GROUP_CONCAT(st.theme, ', ') as themes
FROM sessions s
LEFT JOIN session_themes st ON s.id = st.session_id
WHERE s.significance = 'PARADIGM'
GROUP BY s.id
ORDER BY s.number DESC;

CREATE VIEW v_provenance_histogram AS
SELECT source, COUNT(*) as count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 1) AS pct
FROM session_events
GROUP BY source;

-- ============================================================================
-- Feedback
-- ============================================================================

CREATE VIEW v_feedback_by_domain AS
SELECT f.*, COALESCE(vmd.effective_confidence, 1.0) AS effective_confidence
FROM feedback f
LEFT JOIN v_memories_decayed vmd
    ON vmd.source_table = 'feedback' AND vmd.source_id = f.id
ORDER BY f.domain, f.last_triggered DESC NULLS LAST;

-- ============================================================================
-- People
-- ============================================================================

CREATE VIEW v_people_active AS
SELECT id, name, tier, role, relationship, description, status
FROM people
WHERE tier IN (1, 2)
ORDER BY tier, name;

CREATE VIEW v_people_safe AS
SELECT id, name, tier, role, relationship, description, status
FROM people
WHERE opsec_level IS NULL OR opsec_level = 'public';

CREATE VIEW v_people_full AS
SELECT * FROM people;

CREATE VIEW v_compartmented AS
SELECT 'people' AS source_table, id, name AS title, opsec_level
FROM people WHERE opsec_level IS NOT NULL
UNION ALL
SELECT 'feedback', id, slug, opsec_level
FROM feedback WHERE opsec_level IS NOT NULL
UNION ALL
SELECT 'projects', id, slug, opsec_level
FROM projects WHERE opsec_level IS NOT NULL
UNION ALL
SELECT 'references', id, name, opsec_level
FROM "references" WHERE opsec_level IS NOT NULL
UNION ALL
SELECT 'memory_item', id, slug, opsec_level
FROM memory_item WHERE opsec_level IS NOT NULL;

-- ============================================================================
-- The service surface: every memory, with an openable address
-- ============================================================================
-- v_memory_addr: 7 columns, in this order —
--   source_table · source_id · in_registry · name · type · description · path
-- The INNER JOIN through memory_kind plus the opsec filter is what makes it
-- the OPSEC boundary: a compartmented row is absent here, so anything that
-- joins memory_fts to this view (scripts/recall.sh) cannot surface it.
CREATE VIEW v_memory_addr AS
SELECT mk.source_table, mi.id AS source_id, mk.in_registry,
       CASE WHEN mk.name IN ('project','reference') THEN mi.name ELSE mi.slug END AS name,
       mk.name AS type,
       CASE WHEN mk.name IN ('feedback','skill') THEN COALESCE(NULLIF(mi.description,''), fd.rule)
            ELSE mi.description END AS description,
       mi.path
FROM memory_item mi
JOIN memory_kind mk ON mk.id = mi.kind_id
LEFT JOIN feedback_detail fd ON fd.item_id = mi.id
WHERE mi.opsec_level IS NULL OR mi.opsec_level != 'compartmented';

-- memories: 4 columns — name · type · description · path. The registry.
CREATE VIEW memories AS
    SELECT name, type, description, path FROM v_memory_addr WHERE in_registry = 1;

-- ============================================================================
-- Health & diagnostics
-- ============================================================================

CREATE VIEW v_health_current AS
SELECT * FROM health_snapshots
ORDER BY id DESC
LIMIT 1;

CREATE VIEW v_health_shift AS
SELECT cur.id AS current_id, prev.id AS prev_id,
    cur.session_number AS current_session, prev.session_number AS prev_session,
    ABS(cur.pressure - prev.pressure) AS p_delta,
    ABS(cur.freshness - prev.freshness) AS f_delta,
    ABS(cur.coverage - prev.coverage) AS v_delta,
    ABS(cur.drift - prev.drift) AS d_delta,
    CASE WHEN ABS(cur.pressure - prev.pressure) > 0.2
        OR ABS(cur.freshness - prev.freshness) > 0.2
        OR ABS(cur.coverage - prev.coverage) > 0.2
        OR ABS(cur.drift - prev.drift) > 0.2
    THEN 1 ELSE 0 END AS has_significant_shift
FROM health_snapshots cur
JOIN health_snapshots prev ON prev.id = (
    SELECT id FROM health_snapshots WHERE id < cur.id ORDER BY id DESC LIMIT 1)
WHERE cur.id = (SELECT MAX(id) FROM health_snapshots);

CREATE VIEW v_memory_stats AS
SELECT 'corrections' as tbl, COUNT(*) as rows FROM corrections
UNION ALL SELECT 'people', COUNT(*) FROM people
UNION ALL SELECT 'feedback', COUNT(*) FROM feedback
UNION ALL SELECT 'projects', COUNT(*) FROM projects
UNION ALL SELECT 'references', COUNT(*) FROM "references"
UNION ALL SELECT 'user_profile', COUNT(*) FROM user_profile
UNION ALL SELECT 'sessions', COUNT(*) FROM sessions
UNION ALL SELECT 'decisions', COUNT(*) FROM decisions
UNION ALL SELECT 'breakthroughs', COUNT(*) FROM breakthroughs
UNION ALL SELECT 'ptl_items', COUNT(*) FROM ptl_items
UNION ALL SELECT 'pending_items', COUNT(*) FROM pending_items
UNION ALL SELECT 'associations', COUNT(*) FROM associations
UNION ALL SELECT 'memory_confidence', COUNT(*) FROM memory_confidence
UNION ALL SELECT 'memory_evidence', COUNT(*) FROM memory_evidence
UNION ALL SELECT 'memory_item', COUNT(*) FROM memory_item
UNION ALL SELECT 'memories', COUNT(*) FROM memories;

CREATE VIEW v_ingest_recent AS
SELECT source_file, table_name, action, MAX(timestamp) as last_ingest
FROM ingest_log
GROUP BY source_file;

-- ============================================================================
-- Entity graph
-- ============================================================================

CREATE VIEW v_associations AS
SELECT a.*,
    CASE a.source_type
        WHEN 'correction' THEN (SELECT title FROM corrections WHERE id = a.source_id)
        WHEN 'feedback' THEN (SELECT slug FROM feedback WHERE id = a.source_id)
        WHEN 'project' THEN (SELECT slug FROM projects WHERE id = a.source_id)
        WHEN 'person' THEN (SELECT name FROM people WHERE id = a.source_id)
        WHEN 'reference' THEN (SELECT name FROM "references" WHERE id = a.source_id)
        WHEN 'session' THEN (SELECT CAST(number AS TEXT) FROM sessions WHERE id = a.source_id)
        WHEN 'decision' THEN (SELECT topic FROM decisions WHERE id = a.source_id)
        WHEN 'breakthrough' THEN (SELECT title FROM breakthroughs WHERE id = a.source_id)
    END as source_name,
    CASE a.target_type
        WHEN 'correction' THEN (SELECT title FROM corrections WHERE id = a.target_id)
        WHEN 'feedback' THEN (SELECT slug FROM feedback WHERE id = a.target_id)
        WHEN 'project' THEN (SELECT slug FROM projects WHERE id = a.target_id)
        WHEN 'person' THEN (SELECT name FROM people WHERE id = a.target_id)
        WHEN 'reference' THEN (SELECT name FROM "references" WHERE id = a.target_id)
        WHEN 'session' THEN (SELECT CAST(number AS TEXT) FROM sessions WHERE id = a.target_id)
        WHEN 'decision' THEN (SELECT topic FROM decisions WHERE id = a.target_id)
        WHEN 'breakthrough' THEN (SELECT title FROM breakthroughs WHERE id = a.target_id)
    END as target_name
FROM associations a;

-- ============================================================================
-- Confidence layer views
-- ============================================================================

CREATE VIEW v_confidence_overview AS
SELECT source_table,
    COUNT(*) AS total,
    SUM(CASE WHEN pinned = 1 THEN 1 ELSE 0 END) AS pinned_count,
    ROUND(AVG(effective_confidence), 3) AS avg_confidence,
    SUM(CASE WHEN effective_confidence < 0.2 THEN 1 ELSE 0 END) AS below_threshold
FROM v_memories_decayed
GROUP BY source_table;

-- Pre-joined FTS + confidence for ranked search
CREATE VIEW v_fts_confidence AS
SELECT mf.source_table, mf.source_id, mf.title, mf.content,
    COALESCE(vmd.effective_confidence, 1.0) AS effective_confidence,
    COALESCE(vmd.last_accessed, vmd.created_at) AS last_active,
    vmd.pinned, vmd.half_life_days
FROM memory_fts mf
LEFT JOIN v_memories_decayed vmd
    ON vmd.source_table = mf.source_table AND vmd.source_id = mf.source_id;

-- Staleness detection: memories below 50% confidence needing verification
CREATE VIEW v_memories_stale AS
SELECT md.source_table, md.source_id,
    CASE md.source_table
        WHEN 'feedback' THEN (SELECT slug FROM feedback WHERE id = md.source_id)
        WHEN 'projects' THEN (SELECT slug FROM projects WHERE id = md.source_id)
        WHEN 'references' THEN (SELECT name FROM "references" WHERE id = md.source_id)
        WHEN 'people' THEN (SELECT name FROM people WHERE id = md.source_id)
        WHEN 'decisions' THEN (SELECT topic FROM decisions WHERE id = md.source_id)
        WHEN 'breakthroughs' THEN (SELECT title FROM breakthroughs WHERE id = md.source_id)
    END AS name,
    ROUND(md.effective_confidence, 3) AS confidence,
    md.half_life_days,
    CAST(julianday('now') - julianday(
        COALESCE(md.last_reinforced, md.created_at)) AS INTEGER) AS days_stale
FROM v_memories_decayed md
WHERE md.effective_confidence < 0.5
    AND md.pinned = 0
    AND md.source_table NOT IN ('sessions')
ORDER BY md.effective_confidence ASC;

-- Progressive compression candidates based on confidence
CREATE VIEW v_compression_candidates AS
SELECT vmd.source_table, vmd.source_id, vmd.effective_confidence,
    vmd.half_life_days, vmd.last_reinforced, vmd.created_at,
    CASE
        WHEN vmd.effective_confidence > 0.5 THEN 'FULL'
        WHEN vmd.effective_confidence > 0.2 THEN 'SUMMARY'
        WHEN vmd.effective_confidence > 0.05 THEN 'ONE-LINER'
        ELSE 'ARCHIVE'
    END AS recommended_stage,
    ROUND(julianday('now') - julianday(
        COALESCE(vmd.last_reinforced, vmd.created_at)), 0) AS days_since_reinforced
FROM v_memories_decayed vmd
WHERE vmd.pinned = 0
AND vmd.effective_confidence <= 0.5
ORDER BY vmd.effective_confidence ASC;

-- ============================================================================
-- Indexes
-- ============================================================================

CREATE INDEX idx_ptl_tier_status ON ptl_items(tier, status);
CREATE INDEX idx_ptl_stable_id ON ptl_items(stable_id);
CREATE INDEX idx_sessions_number ON sessions(number);
CREATE INDEX idx_sessions_significance ON sessions(significance);
CREATE INDEX idx_corrections_number ON corrections(number);
CREATE INDEX idx_corrections_cluster ON corrections(cluster);
CREATE INDEX idx_people_tier ON people(tier);
CREATE INDEX idx_associations_source ON associations(source_type, source_id);
CREATE INDEX idx_associations_target ON associations(target_type, target_id);
CREATE INDEX idx_ingest_log_file ON ingest_log(source_file);
CREATE INDEX idx_evidence_source ON memory_evidence(source_table, source_id);
