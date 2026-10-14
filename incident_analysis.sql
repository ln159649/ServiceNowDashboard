-- ServiceNow Incident Management Event Log: analysis (PostgreSQL)
-- Source: UCI ML Repository "Incident management process enriched event log" (CC BY 4.0)
-- Columns, date format and missing-value marker taken from the real file header.
--
-- Facts about the file that drive the cleaning below:
--   * One row per UPDATE to an incident, so each incident (number) appears many times.
--   * Missing values are written as '?'.
--   * Dates are text in day/month/year order with 1- or 2-digit parts, e.g. '5/3/2016 12:00'.
--   * Booleans are lowercase true / false in the file (Excel DISPLAYS them uppercase,
--     so never trust a spreadsheet view for raw values: check with SELECT DISTINCT).
--     ILIKE 'true%' also tolerates stray spaces or carriage returns after the value.
--   * sys_mod_count counts updates, so the highest value per incident is its final row.

-- 1. Raw table: every column as TEXT so the import cannot fail on odd values ------------
CREATE TABLE incident_events_raw (
    number                  TEXT,
    incident_state          TEXT,
    active                  TEXT,
    reassignment_count      TEXT,
    reopen_count            TEXT,
    sys_mod_count           TEXT,
    made_sla                TEXT,
    caller_id               TEXT,
    opened_by               TEXT,
    opened_at               TEXT,
    sys_created_by          TEXT,
    sys_created_at          TEXT,
    sys_updated_by          TEXT,
    sys_updated_at          TEXT,
    contact_type            TEXT,
    location                TEXT,
    category                TEXT,
    subcategory             TEXT,
    u_symptom               TEXT,
    cmdb_ci                 TEXT,
    impact                  TEXT,
    urgency                 TEXT,
    priority                TEXT,
    assignment_group        TEXT,
    assigned_to             TEXT,
    knowledge               TEXT,
    u_priority_confirmation TEXT,
    notify                  TEXT,
    problem_id              TEXT,
    rfc                     TEXT,
    vendor                  TEXT,
    caused_by               TEXT,
    closed_code             TEXT,
    resolved_by             TEXT,
    resolved_at             TEXT,
    closed_at               TEXT
);

-- 2. Import the CSV (pick one) ------------------------------------------------------------
--   pgAdmin: right-click incident_events_raw > Import/Export Data > select the CSV,
--            Header = on, Delimiter = , (comma). If every row lands in one column,
--            the file uses semicolons: re-run the import with Delimiter = ;
--   psql:    \copy incident_events_raw FROM 'D:/path/to/incident_event_log.csv' CSV HEADER
-- Check: SELECT COUNT(*) FROM incident_events_raw;   -- expect about 141,712

-- 3. Clean event table ---------------------------------------------------------------------
-- The log has no timezone. Each timestamp is parsed with an explicit +00 offset and stored as
-- a plain timestamp, so results do not depend on the session's timezone and daylight saving
-- can never shift a resolution time by an hour. This statement needs no SET beforehand.
CREATE TABLE incident_events AS
SELECT
    number                                                     AS incident_id,
    incident_state,
    (active ILIKE 'true%')                                     AS active,
    NULLIF(reassignment_count, '?')::INT                       AS reassignment_count,
    NULLIF(reopen_count, '?')::INT                             AS reopen_count,
    NULLIF(sys_mod_count, '?')::INT                            AS sys_mod_count,
    (made_sla ILIKE 'true%')                                   AS made_sla,
    NULLIF(contact_type, '?')                                  AS contact_type,
    NULLIF(category, '?')                                      AS category,
    NULLIF(subcategory, '?')                                   AS subcategory,
    NULLIF(impact, '?')                                        AS impact,
    NULLIF(urgency, '?')                                       AS urgency,
    NULLIF(priority, '?')                                      AS priority,
    NULLIF(assignment_group, '?')                              AS assignment_group,
    NULLIF(closed_code, '?')                                   AS closed_code,
    to_timestamp(NULLIF(opened_at, '?')      || ' +00', 'DD/MM/YYYY HH24:MI TZH') AT TIME ZONE 'UTC' AS opened_at,
    to_timestamp(NULLIF(sys_updated_at, '?') || ' +00', 'DD/MM/YYYY HH24:MI TZH') AT TIME ZONE 'UTC' AS updated_at,
    to_timestamp(NULLIF(resolved_at, '?')    || ' +00', 'DD/MM/YYYY HH24:MI TZH') AT TIME ZONE 'UTC' AS resolved_at,
    to_timestamp(NULLIF(closed_at, '?')      || ' +00', 'DD/MM/YYYY HH24:MI TZH') AT TIME ZONE 'UTC' AS closed_at
FROM incident_events_raw;

-- Quick data-quality checks to document in your README ----------------------------------
-- SELECT COUNT(*) AS rows, COUNT(DISTINCT incident_id) AS incidents FROM incident_events;
-- SELECT COUNT(*) FROM incident_events WHERE resolved_at IS NULL;          -- rows never resolved
-- SELECT COUNT(*) FROM incident_events WHERE resolved_at < opened_at;      -- impossible times

-- 4. One row per incident: its final state, with resolution time ------------------------
CREATE VIEW incidents AS
WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY incident_id
                              ORDER BY sys_mod_count DESC, updated_at DESC) AS rn
    FROM incident_events
)
SELECT
    incident_id, category, subcategory, priority, assignment_group, closed_code,
    reassignment_count, reopen_count, sys_mod_count, made_sla,
    opened_at, resolved_at, closed_at,
    EXTRACT(EPOCH FROM (resolved_at - opened_at)) / 3600.0 AS resolution_hours
FROM ranked
WHERE rn = 1;

-- 5. Q1: How long do incidents take to resolve, by priority? -----------------------------
SELECT priority,
       COUNT(*)                                                   AS incidents,
       ROUND(AVG(resolution_hours)::NUMERIC, 1)                   AS avg_hours,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY resolution_hours)::NUMERIC, 1) AS median_hours,
       ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY resolution_hours)::NUMERIC, 1) AS p90_hours
FROM incidents
WHERE resolution_hours IS NOT NULL AND resolution_hours >= 0
GROUP BY priority
ORDER BY priority;

-- 6. Q2: Monthly volume and median resolution time (trend) -------------------------------
SELECT DATE_TRUNC('month', opened_at)                             AS month,
       COUNT(*)                                                   AS incidents,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY resolution_hours)::NUMERIC, 1) AS median_hours
FROM incidents
WHERE resolution_hours IS NOT NULL AND resolution_hours >= 0
GROUP BY 1
ORDER BY 1;

-- 7. Q3: Do reassignments and reopens slow incidents down? ------------------------------
SELECT CASE WHEN reassignment_count = 0 THEN '0'
            WHEN reassignment_count BETWEEN 1 AND 2 THEN '1-2'
            WHEN reassignment_count BETWEEN 3 AND 5 THEN '3-5'
            ELSE '6+' END                                         AS reassignments,
       COUNT(*)                                                   AS incidents,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY resolution_hours)::NUMERIC, 1) AS median_hours,
       ROUND(100.0 * AVG(CASE WHEN reopen_count > 0 THEN 1 ELSE 0 END), 1) AS pct_reopened
FROM incidents
WHERE resolution_hours IS NOT NULL AND resolution_hours >= 0
GROUP BY 1
ORDER BY 1;

-- 8. Q4: Which assignment groups miss SLA most (min 100 incidents)? ---------------------
SELECT assignment_group,
       COUNT(*)                                                   AS incidents,
       ROUND(100.0 * AVG(CASE WHEN made_sla THEN 1 ELSE 0 END), 1) AS sla_met_pct
FROM incidents
GROUP BY assignment_group
HAVING COUNT(*) >= 100
ORDER BY sla_met_pct ASC
LIMIT 15;

-- 9. Q5: Where do incidents wait? Time spent in each state (window function) ------------
WITH steps AS (
    SELECT incident_id, incident_state, updated_at, sys_mod_count,
           LEAD(updated_at) OVER (PARTITION BY incident_id ORDER BY sys_mod_count, updated_at) AS next_at
    FROM incident_events
)
SELECT incident_state,
       COUNT(*)                                                   AS events,
       ROUND(AVG(EXTRACT(EPOCH FROM (next_at - updated_at)) / 3600.0)::NUMERIC, 1) AS avg_hours_in_state
FROM steps
WHERE next_at IS NOT NULL
GROUP BY incident_state
ORDER BY avg_hours_in_state DESC;
