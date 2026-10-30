-- The query log's hard cap (modules/dns/querylog.nix), run by psql as the
-- superuser `postgres` with -v cap=<bytes>.
--
-- The file size can't be the measure: DELETE frees no file space, and a plain
-- VACUUM only makes it reusable, so the table's size stays near the cap after
-- a clean-up and a size test would delete a little more at every run until
-- nothing was left. So the size only gates (cheaply) whether to look at all;
-- the decision is on an estimate of the live data:
--
--   rows x (average row width + 28 bytes of tuple header and line pointer)
--        x (1 + indexes' size / heap's size)
--
-- The average width comes from the newest 100000 rows (the rows are alike),
-- the index share from the file sizes (bloat hits both alike, so the ratio
-- holds). When the estimate is over the cap, the newest rows that fit in 80%
-- of the cap are kept (the margin absorbs the estimate's error, and means
-- one clean-up buys days, not one run, but never fewer than 1000) and the rest are deleted: everything
-- with `request_ts` at or before the oldest kept row's. Then a plain VACUUM.

\set ON_ERROR_STOP on

SELECT coalesce(pg_total_relation_size(to_regclass('public.log_entries')), 0) > :cap AS over \gset

\if :over
  -- The planner's row estimate (autovacuum keeps it current), not count(*):
  -- after the first trim the file stays over the cap for good, and every run
  -- would otherwise count a multi-gigabyte table. -1 means never analyzed
  -- (PostgreSQL 14 and later), then count once.
  SELECT CASE WHEN reltuples >= 0 THEN reltuples::bigint
              ELSE (SELECT count(*) FROM log_entries) END AS n
  FROM pg_class WHERE oid = to_regclass('public.log_entries') \gset

  -- coalesce: an empty table has no average, and the job must then end
  -- quietly (nothing to delete) rather than fail on a syntax error.
  SELECT coalesce((avg(pg_column_size(l.*)) + 28)
           * (1 + pg_indexes_size('log_entries')::float8 / greatest(pg_relation_size('log_entries'), 1))
           * :n, 0) AS live
  FROM (SELECT * FROM log_entries ORDER BY request_ts DESC LIMIT 100000) l \gset

  SELECT :live > :cap AS trim \gset
  \if :trim
    -- Never fewer than 1000 rows, however small the cap or odd the estimate:
    -- a minimum in the job, not in the option, so a bad cap or estimate can't
    -- empty the log (a tiny cap simply keeps its last 1000 rows).
    SELECT greatest(floor(:n * (0.8 * :cap) / :live)::bigint, 1000) AS keep \gset
    SELECT request_ts AS cutoff FROM log_entries ORDER BY request_ts DESC OFFSET :keep LIMIT 1 \gset
    \if :{?cutoff}
      DELETE FROM log_entries WHERE request_ts <= :'cutoff';
      VACUUM log_entries;
    \endif
  \endif
\endif
