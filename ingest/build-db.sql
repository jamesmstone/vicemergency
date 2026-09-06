-- All time-of-day questions are about Victoria, so the database is built and
-- read in Melbourne local time rather than the builder's zone.
SET TimeZone='Australia/Melbourne';

-- Turn the per-snapshot observations into the shapes the questions are asked in.
-- Set `shards` to the parquet glob before running:
--   duckdb events.duckdb -c "SET VARIABLE shards='...'" -f build-db.sql

-- A view, not a table: obs still carries web_body, text and full geometry, and
-- materialising 3M of those rows would bloat the database file that ships.
CREATE OR REPLACE VIEW obs AS
SELECT
  to_timestamp(snapshot_ts)                          AS seen_at,
  commit,
  id,
  feed_type, source_org, source_feed, source_title, source,
  category1, category2, status, name, action, statewide, location,
  TRY_CAST(created AS TIMESTAMPTZ)                   AS created_at,
  TRY_CAST(updated AS TIMESTAMPTZ)                   AS updated_at,
  TRY_CAST(resources AS INTEGER)                     AS resources,
  -- `size` is hectares on fire feeds and a word ("Small") elsewhere; sizeFmt
  -- carries the same number as "0.68 Ha.". Take whichever parses.
  COALESCE(TRY_CAST(size AS DOUBLE),
           TRY_CAST(regexp_extract(size_fmt, '^([0-9]+\.?[0-9]*)', 1) AS DOUBLE))
                                                     AS size_ha,
  size                                               AS size_raw,
  TRY_CAST(magnitude AS DOUBLE)                      AS magnitude,
  cap_category, cap_event, cap_event_code, cap_urgency,
  cap_severity, cap_certainty, cap_response_type, cap_sender_name,
  incident_ids,
  event_id, ses_id, esta_id, cfa_id, url,
  geom_type, lon, lat, n_polygons, geometry,
  web_headline, text, web_body
FROM read_parquet(getvariable('shards'));

-- One row per scrape. Gaps here are feed or scraper outages, and the interval
-- is the resolution limit on every duration derived below.
CREATE OR REPLACE TABLE snapshots AS
SELECT seen_at,
       any_value(commit)                                   AS commit,
       count(*)                                            AS n_features,
       row_number() OVER (ORDER BY seen_at)                AS seq,
       seen_at - lag(seen_at) OVER (ORDER BY seen_at)      AS since_prev
FROM obs GROUP BY seen_at;

-- An incident can leave the feed and come back under the same id, so presence
-- is split into spells: a break in the global snapshot sequence means absent,
-- not unchanged.
CREATE OR REPLACE TABLE presence AS
WITH o AS (
  SELECT obs.id, obs.seen_at, s.seq
  FROM obs JOIN snapshots s USING (seen_at)
),
g AS (
  SELECT *, seq - lag(seq) OVER (PARTITION BY id ORDER BY seq) AS gap FROM o
),
sp AS (
  SELECT *, sum(CASE WHEN gap IS NULL OR gap > 1 THEN 1 ELSE 0 END)
              OVER (PARTITION BY id ORDER BY seq) AS spell
  FROM g
)
SELECT id, spell, min(seen_at) AS first_seen, max(seen_at) AS last_seen,
       count(*) AS n_snapshots
FROM sp GROUP BY id, spell;

-- SCD-2 over the substantive fields: a row only where the payload actually
-- changed, so 3M observations collapse to the moments something happened.
CREATE OR REPLACE TABLE versions AS
WITH h AS (
  SELECT *, md5(concat_ws('|',
           coalesce(status,''), coalesce(category1,''), coalesce(category2,''),
           coalesce(action,''), coalesce(location,''), coalesce(name,''),
           coalesce(resources::VARCHAR,''), coalesce(size_ha::VARCHAR,''),
           coalesce(cap_urgency,''), coalesce(cap_severity,''),
           coalesce(cap_certainty,''), coalesce(cap_response_type,''),
           coalesce(source_title,''), coalesce(updated_at::VARCHAR,''),
           coalesce(lon::VARCHAR,''), coalesce(lat::VARCHAR,''),
           coalesce(n_polygons::VARCHAR,''), coalesce(text,''))) AS payload_hash
  FROM obs
),
c AS (
  SELECT *,
         lag(payload_hash) OVER (PARTITION BY id ORDER BY seen_at) AS prev_hash
  FROM h
),
v AS (SELECT * FROM c WHERE prev_hash IS NULL OR payload_hash <> prev_hash)
SELECT
  id, seen_at AS valid_from,
  lead(seen_at) OVER (PARTITION BY id ORDER BY seen_at) AS valid_to,
  row_number() OVER (PARTITION BY id ORDER BY seen_at)  AS version,
  feed_type, source_org, source_feed, source_title,
  category1, category2, status, name, action, location,
  created_at, updated_at, resources, size_ha, magnitude,
  cap_category, cap_event, cap_urgency, cap_severity, cap_certainty,
  cap_response_type, incident_ids, lon, lat, n_polygons, payload_hash
FROM v;

-- One row per incident: the lifecycle summary most questions start from.
-- The two sides are aggregated before they meet: joining versions to presence
-- on id alone fans every version out across an incident's spells, which
-- silently multiplies the version count for anything that left the feed and
-- came back.
CREATE OR REPLACE TABLE incidents AS
WITH pres AS (
  SELECT id,
         min(first_seen)                                   AS first_seen,
         max(last_seen)                                    AS last_seen,
         to_seconds(sum(epoch(last_seen - first_seen))::BIGINT) AS present_duration,
         count(*)                                          AS spells
  FROM presence GROUP BY id
),
vers AS (
  SELECT id,
         min(created_at)                                   AS created_at,
         count(*)                                          AS versions,
         arg_min(feed_type, valid_from)                    AS feed_type,
         arg_min(source_org, valid_from)                   AS source_org,
         arg_min(source_feed, valid_from)                  AS source_feed,
         arg_min(category1, valid_from)                    AS first_category1,
         arg_max(category1, valid_from)                    AS last_category1,
         arg_min(category2, valid_from)                    AS category2,
         arg_min(status, valid_from)                       AS first_status,
         arg_max(status, valid_from)                       AS last_status,
         arg_max(location, valid_from)                     AS location,
         arg_max(lon, valid_from)                          AS lon,
         arg_max(lat, valid_from)                          AS lat,
         max(resources)                                    AS max_resources,
         max(size_ha)                                      AS max_size_ha,
         max(magnitude)                                    AS magnitude,
         max(n_polygons) > 0                               AS had_polygon,
         list(DISTINCT status)                             AS statuses,
         list(DISTINCT source_title)                       AS warning_levels
  FROM versions GROUP BY id
)
SELECT
  v.id,
  p.first_seen,
  p.last_seen,
  p.last_seen - p.first_seen                               AS feed_duration,
  -- The span above counts the gaps an incident was absent for; this is the
  -- time it was actually in the feed, which is what a lifetime means when 2%
  -- of incidents leave and come back.
  p.present_duration,
  p.spells,
  v.created_at,
  -- How long the feed took to publish something already stamped as created.
  p.first_seen - v.created_at                              AS publish_lag,
  v.versions,
  v.feed_type, v.source_org, v.source_feed,
  v.first_category1, v.last_category1, v.category2,
  v.first_status, v.last_status, v.location, v.lon, v.lat,
  v.max_resources, v.max_size_ha, v.magnitude, v.had_polygon,
  v.statuses, v.warning_levels
FROM vers v JOIN pres p USING (id);


-- Every status transition, with how long the previous status actually held.
-- Versions are collapsed into runs of constant status first: a version row is
-- emitted whenever any field changes, so measuring back to the previous version
-- would time the last unrelated edit (a resource count, a size revision) rather
-- than the status itself, and understates every hold.
CREATE OR REPLACE TABLE status_changes AS
WITH s AS (
  SELECT id, valid_from, status, source_title, feed_type, category1, source_org,
         lag(status) OVER (PARTITION BY id ORDER BY valid_from) AS prev_status
  FROM versions
),
runs AS (
  SELECT *,
         sum(CASE WHEN prev_status IS NULL OR prev_status IS DISTINCT FROM status
                  THEN 1 ELSE 0 END)
           OVER (PARTITION BY id ORDER BY valid_from) AS run
  FROM s
),
run_starts AS (
  SELECT id, run,
         min(valid_from)                    AS started_at,
         arg_min(status, valid_from)        AS status,
         arg_min(source_title, valid_from)  AS source_title,
         arg_min(feed_type, valid_from)     AS feed_type,
         arg_min(category1, valid_from)     AS category1,
         arg_min(source_org, valid_from)    AS source_org
  FROM runs GROUP BY id, run
),
t AS (
  SELECT *,
         lag(status)     OVER (PARTITION BY id ORDER BY run) AS from_status,
         lag(started_at) OVER (PARTITION BY id ORDER BY run) AS prev_at
  FROM run_starts
)
SELECT id, from_status, status AS to_status,
       started_at AS at, prev_at, started_at - prev_at AS held_for,
       source_title, feed_type, category1, source_org
FROM t
WHERE prev_at IS NOT NULL;

-- Retroactive edits: the feed restating a `created` or `updated` stamp that
-- moves backwards, or an id whose category changes after first publication.
-- Only git history can see these.
CREATE OR REPLACE TABLE rewrites AS
SELECT id, valid_from AS at,
       lag(created_at) OVER (PARTITION BY id ORDER BY valid_from) AS prev_created,
       created_at,
       lag(category1) OVER (PARTITION BY id ORDER BY valid_from)  AS prev_category1,
       category1,
       lag(location) OVER (PARTITION BY id ORDER BY valid_from)   AS prev_location,
       location,
       lag(valid_from) OVER (PARTITION BY id ORDER BY valid_from)  AS prev_at
FROM versions
QUALIFY prev_at IS NOT NULL
   AND (prev_created IS DISTINCT FROM created_at
     OR prev_category1 IS DISTINCT FROM category1
     OR prev_location IS DISTINCT FROM location);

DROP VIEW obs;
