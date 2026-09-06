-- Consistency assertions over a database built by build-db.sql. `shards` must
-- be the same parquet glob it was built from:
--   duckdb events.duckdb -c "SET VARIABLE shards='...'" -f assert.sql

CREATE OR REPLACE TEMP TABLE observed AS
SELECT count(*) AS n, count(DISTINCT snapshot_ts) AS n_ts
FROM read_parquet(getvariable('shards'));

CREATE OR REPLACE TEMP TABLE assertions AS
  SELECT 'snapshots non-empty' AS name, (SELECT count(*) FROM snapshots) > 0 AS ok
  UNION ALL SELECT 'presence non-empty', (SELECT count(*) FROM presence) > 0
  UNION ALL SELECT 'versions non-empty', (SELECT count(*) FROM versions) > 0
  UNION ALL SELECT 'incidents non-empty', (SELECT count(*) FROM incidents) > 0
  UNION ALL SELECT 'status_changes non-empty', (SELECT count(*) FROM status_changes) > 0
  UNION ALL SELECT 'rewrites non-empty', (SELECT count(*) FROM rewrites) > 0

  UNION ALL SELECT 'one snapshot per observed timestamp',
    (SELECT count(*) FROM snapshots) = (SELECT n_ts FROM observed)
  UNION ALL SELECT 'snapshots account for every observation',
    (SELECT sum(n_features) FROM snapshots) = (SELECT n FROM observed)
  UNION ALL SELECT 'versions collapse observations',
    (SELECT count(*) FROM versions) <= (SELECT n FROM observed)

  UNION ALL SELECT 'every status_changes.id is an incident',
    (SELECT count(*) FROM status_changes LEFT JOIN incidents USING (id)
     WHERE incidents.id IS NULL) = 0
  UNION ALL SELECT 'every rewrites.id is an incident',
    (SELECT count(*) FROM rewrites LEFT JOIN incidents USING (id)
     WHERE incidents.id IS NULL) = 0
  UNION ALL SELECT 'every versions.id is an incident',
    (SELECT count(*) FROM versions LEFT JOIN incidents USING (id)
     WHERE incidents.id IS NULL) = 0
  UNION ALL SELECT 'every incident has a presence spell',
    (SELECT count(*) FROM incidents LEFT JOIN presence USING (id)
     WHERE presence.id IS NULL) = 0

  -- One open version per id and no others: the SCD-2 chain is closed by lead(),
  -- so a second null valid_to would mean two chains for one id.
  UNION ALL SELECT 'exactly one open version per id',
    (SELECT count(*) FROM versions WHERE valid_to IS NULL)
      = (SELECT count(DISTINCT id) FROM versions)
  UNION ALL SELECT 'version intervals move forward',
    (SELECT count(*) FROM versions WHERE valid_to <= valid_from) = 0
  UNION ALL SELECT 'presence spells move forward',
    (SELECT count(*) FROM presence WHERE last_seen < first_seen OR n_snapshots < 1) = 0
  UNION ALL SELECT 'incident lifecycles move forward',
    (SELECT count(*) FROM incidents WHERE last_seen < first_seen) = 0
  UNION ALL SELECT 'status_changes hold for a non-negative time',
    (SELECT count(*) FROM status_changes WHERE held_for < INTERVAL 0 SECOND) = 0
  UNION ALL SELECT 'a status change actually changes status',
    (SELECT count(*) FROM status_changes WHERE from_status IS NOT DISTINCT FROM to_status) = 0

  UNION ALL SELECT 'incidents.versions matches versions',
    (SELECT count(*) FROM incidents i
     JOIN (SELECT id, count(*) AS n FROM versions GROUP BY id) v USING (id)
     WHERE i.versions <> v.n) = 0
  UNION ALL SELECT 'incidents.spells matches presence',
    (SELECT count(*) FROM incidents i
     JOIN (SELECT id, count(*) AS n FROM presence GROUP BY id) p USING (id)
     WHERE i.spells <> p.n) = 0
  UNION ALL SELECT 'incident lifecycles span every spell',
    (SELECT count(*) FROM incidents i
     JOIN (SELECT id, min(first_seen) AS f, max(last_seen) AS l FROM presence GROUP BY id) p
       USING (id)
     WHERE i.first_seen <> p.f OR i.last_seen <> p.l) = 0
  -- The three above are the ones a fan-out between versions and presence breaks,
  -- so they are only worth anything while the fixture holds a returning id.
  UNION ALL SELECT 'fixture covers ids that leave the feed and return',
    (SELECT count(*) FROM incidents WHERE spells > 1) > 0

  UNION ALL SELECT 'present_duration never exceeds feed_duration',
    (SELECT count(*) FROM incidents WHERE present_duration > feed_duration) = 0
  UNION ALL SELECT 'present_duration sums the presence spells',
    (SELECT count(*) FROM incidents i
     JOIN (SELECT id, to_seconds(sum(epoch(last_seen - first_seen))::BIGINT) AS d
           FROM presence GROUP BY id) p USING (id)
     WHERE i.present_duration <> p.d) = 0
  UNION ALL SELECT 'an unbroken incident is present for its whole span',
    (SELECT count(*) FROM incidents
     WHERE spells = 1 AND present_duration <> feed_duration) = 0

  UNION ALL SELECT 'status_changes chain up',
    (SELECT count(*) FROM (
       SELECT prev_at, from_status,
              lag("at")        OVER (PARTITION BY id ORDER BY "at") AS prev_row_at,
              lag(to_status) OVER (PARTITION BY id ORDER BY "at") AS prev_row_to
       FROM status_changes)
     WHERE prev_row_at IS NOT NULL
       AND (prev_at IS DISTINCT FROM prev_row_at
         OR from_status IS DISTINCT FROM prev_row_to)) = 0
  UNION ALL SELECT 'a hold covers only versions carrying from_status',
    (SELECT count(*) FROM status_changes sc
     WHERE EXISTS (SELECT 1 FROM versions v
                   WHERE v.id = sc.id
                     AND v.valid_from > sc.prev_at AND v.valid_from < sc.at
                     AND v.status IS DISTINCT FROM sc.from_status)) = 0
  -- The regression guard: held_for must run from the start of the from_status
  -- run, not from the previous version. Timing back to the previous version
  -- instead makes prev_at land on a same-status row, which is what this fails on.
  UNION ALL SELECT 'a hold is timed from the start of its status run',
    (SELECT count(*) FROM status_changes sc
     WHERE EXISTS (SELECT 1 FROM versions v
                   WHERE v.id = sc.id AND v.valid_from < sc.prev_at)
       AND (SELECT arg_max(v.status, v.valid_from) FROM versions v
            WHERE v.id = sc.id AND v.valid_from < sc.prev_at)
           IS NOT DISTINCT FROM sc.from_status) = 0
  -- Which is only worth anything while some hold in the fixture is interrupted
  -- by a version that changed something other than the status.
  UNION ALL SELECT 'fixture covers holds edited mid-status',
    (SELECT count(*) FROM status_changes sc
     WHERE EXISTS (SELECT 1 FROM versions v
                   WHERE v.id = sc.id
                     AND v.valid_from > sc.prev_at AND v.valid_from < sc.at)) > 0

  -- Coordinates land in Victoria, which is what a lon/lat swap in the
  -- GeometryCollection unwrap would break first.
  UNION ALL SELECT 'incident coordinates are in Victoria',
    (SELECT count(*) FROM incidents
     WHERE lon IS NOT NULL AND (lon NOT BETWEEN 140 AND 151
                            OR lat NOT BETWEEN -40 AND -33)) = 0;

SELECT name, ok FROM assertions ORDER BY ok NULLS FIRST, name;

SELECT CASE WHEN count(*) = 0
            THEN format('{} assertions passed', (SELECT count(*) FROM assertions))
            ELSE error(format('failed: {}', string_agg(name, '; ')))
       END AS result
FROM assertions WHERE ok IS NOT TRUE;
