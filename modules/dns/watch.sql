-- The queries behind the dns-watch metrics (modules/dns/watch.nix), run with
-- `psql -At` as the read-only role `dns-watch`. The output is the body of a
-- Prometheus text file: each family's HELP and TYPE lines, then its samples.
-- Every family is one statement, so its lines stay together, as the format
-- requires.
--
-- Label values are escaped here (backslash, double quote, line break), so a
-- hostile or odd client name can't break the file. A client is named by its
-- name where Blocky found one, and by its address where not.
--
-- What Blocky 0.29 writes (observed in tests/dns.py): `reason` reads
-- "BLOCKED (threats)" for a lookup refused by the group `threats`, and
-- `response_code` is the DNS response code's name, "NXDOMAIN" for no such
-- name.

SELECT line FROM (
  SELECT 1 AS ord, '# HELP homeserver_dns_threat_blocks Lookups blocked by a threat list in the last 5 minutes.' AS line
  UNION ALL SELECT 2, '# TYPE homeserver_dns_threat_blocks gauge'
  UNION ALL
  SELECT 3, format('homeserver_dns_threat_blocks{client="%s",domain="%s"} %s', e.client, e.domain, t.n)
  FROM (
    SELECT coalesce(nullif(client_name, ''), client_ip::text) AS client,
           rtrim(question_name, '.') AS domain,
           count(*) AS n
    FROM log_entries
    WHERE request_ts > now() - interval '5 minutes'
      AND reason ILIKE '%threats%'
    GROUP BY 1, 2
  ) t
  CROSS JOIN LATERAL (
    SELECT replace(replace(replace(t.client, E'\\', E'\\\\'), '"', E'\\"'), E'\n', ' ') AS client,
           replace(replace(replace(t.domain, E'\\', E'\\\\'), '"', E'\\"'), E'\n', ' ') AS domain
  ) e
) q ORDER BY ord, line;

-- NXDOMAIN answers per minute: the last 10 minutes against the 7 days before
-- them, or the log's span if that is shorter (at least 10 minutes, so a log
-- that just started doesn't divide by almost nothing). Only for clients that
-- had one in the last 10 minutes; the baseline is then always there for the
-- rule to compare with, 0 for a client with no history.
SELECT line FROM (
  SELECT 1 AS ord, '# HELP homeserver_dns_nxdomain_recent NXDOMAIN answers per minute over the last 10 minutes.' AS line
  UNION ALL SELECT 2, '# TYPE homeserver_dns_nxdomain_recent gauge'
  UNION ALL
  SELECT 3, format('homeserver_dns_nxdomain_recent{client="%s"} %s', e.client, round(t.recent / 10.0, 2))
  FROM (
    SELECT coalesce(nullif(client_name, ''), client_ip::text) AS client,
           count(*) FILTER (WHERE request_ts > now() - interval '10 minutes') AS recent
    FROM log_entries
    WHERE response_code IN ('NXDOMAIN', '3')
      AND request_ts > now() - interval '10 minutes'
    GROUP BY 1
  ) t
  CROSS JOIN LATERAL (
    SELECT replace(replace(replace(t.client, E'\\', E'\\\\'), '"', E'\\"'), E'\n', ' ') AS client
  ) e
  UNION ALL SELECT 4, '# HELP homeserver_dns_nxdomain_baseline NXDOMAIN answers per minute over the 7 days before the last 10 minutes.'
  UNION ALL SELECT 5, '# TYPE homeserver_dns_nxdomain_baseline gauge'
  UNION ALL
  SELECT 6, format('homeserver_dns_nxdomain_baseline{client="%s"} %s', e.client, round(t.older / w.minutes, 2))
  FROM (
    SELECT coalesce(nullif(client_name, ''), client_ip::text) AS client,
           count(*) FILTER (WHERE request_ts <= now() - interval '10 minutes') AS older
    FROM log_entries
    WHERE response_code IN ('NXDOMAIN', '3')
      AND request_ts > now() - interval '7 days'
    GROUP BY 1
    HAVING count(*) FILTER (WHERE request_ts > now() - interval '10 minutes') > 0
  ) t
  CROSS JOIN (
    SELECT greatest(
             extract(epoch FROM (now() - interval '10 minutes'
                                 - greatest(min(request_ts), now() - interval '7 days'))) / 60,
             10) AS minutes
    FROM log_entries
  ) w
  CROSS JOIN LATERAL (
    SELECT replace(replace(replace(t.client, E'\\', E'\\\\'), '"', E'\\"'), E'\n', ' ') AS client
  ) e
) q ORDER BY ord, line;

-- A client whose first entry in the whole log (14 days) is under 10 minutes
-- old. Identity is the address, which a device keeps while its name may
-- change. Reads the table once a minute; at a household's volume that is
-- a fraction of a second.
SELECT line FROM (
  SELECT 1 AS ord, '# HELP homeserver_dns_new_client 1 for a client whose first query in the log is under 10 minutes old.' AS line
  UNION ALL SELECT 2, '# TYPE homeserver_dns_new_client gauge'
  UNION ALL
  SELECT 3, format('homeserver_dns_new_client{client="%s"} 1', e.client)
  FROM (
    SELECT coalesce(nullif(max(client_name), ''), client_ip::text) AS client
    FROM log_entries
    GROUP BY client_ip
    HAVING min(request_ts) > now() - interval '10 minutes'
  ) t
  CROSS JOIN LATERAL (
    SELECT replace(replace(replace(t.client, E'\\', E'\\\\'), '"', E'\\"'), E'\n', ' ') AS client
  ) e
) q ORDER BY ord, line;

-- The table and its indexes, the number DnsQueryLogLarge and the hard cap
-- (querylog-cap.sql) look at.
SELECT '# HELP homeserver_dns_querylog_bytes Size of the query log table with its indexes.';
SELECT '# TYPE homeserver_dns_querylog_bytes gauge';
SELECT 'homeserver_dns_querylog_bytes '
       || coalesce(pg_total_relation_size(to_regclass('public.log_entries')), 0);
