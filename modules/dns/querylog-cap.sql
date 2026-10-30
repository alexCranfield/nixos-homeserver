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
-- one clean-up buys days, not one run) and the rest are deleted: everything
-- with `request_ts` at or before the oldest kept row's. Then a plain VACUUM.

\set ON_ERROR_STOP on

SELECT coalesce(pg_total_relation_size(to_regclass('public.log_entries')), 0) > :cap AS over \gset

\if :over
  SELECT count(*) AS n FROM log_entries \gset

  SELECT (avg(pg_column_size(l.*)) + 28)
           * (1 + pg_indexes_size('log_entries')::float8 / greatest(pg_relation_size('log_entries'), 1))
           * :n AS live
  FROM (SELECT * FROM log_entries ORDER BY request_ts DESC LIMIT 100000) l \gset

  SELECT :live > :cap AS trim \gset
  \if :trim
    SELECT floor(:n * (0.8 * :cap) / :live)::bigint AS keep \gset
    SELECT request_ts AS cutoff FROM log_entries ORDER BY request_ts DESC OFFSET :keep LIMIT 1 \gset
    \if :{?cutoff}
      DELETE FROM log_entries WHERE request_ts <= :'cutoff';
      VACUUM log_entries;
    \endif
  \endif
\endif
