-- PayloadCMS Postgres read-only audit queries.
-- Run on staging first. These queries do not modify data.

\echo '== Payload migrations table, if present =='
select
  case when to_regclass('public.payload_migrations') is null then 'payload_migrations table not found'
       else 'payload_migrations table exists'
  end as status;

\echo '== Largest non-system tables =='
select
  schemaname,
  relname as table_name,
  n_live_tup as estimated_rows,
  pg_size_pretty(pg_total_relation_size(relid)) as total_size,
  pg_size_pretty(pg_relation_size(relid)) as table_size,
  pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid)) as index_size
from pg_stat_user_tables
order by pg_total_relation_size(relid) desc
limit 30;

\echo '== Tables without primary key =='
select
  n.nspname as schema_name,
  c.relname as table_name
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where c.relkind = 'r'
  and n.nspname not in ('pg_catalog', 'information_schema')
  and not exists (
    select 1
    from pg_constraint con
    where con.conrelid = c.oid
      and con.contype = 'p'
  )
order by 1, 2;

\echo '== Index overview =='
select
  schemaname,
  tablename,
  count(*) as index_count,
  string_agg(indexname, ', ' order by indexname) as indexes
from pg_indexes
where schemaname not in ('pg_catalog', 'information_schema')
group by schemaname, tablename
order by schemaname, tablename;

\echo '== Potential Payload version/draft tables =='
select
  schemaname,
  relname as table_name,
  n_live_tup as estimated_rows,
  pg_size_pretty(pg_total_relation_size(relid)) as total_size
from pg_stat_user_tables
where relname ilike '%version%'
   or relname ilike '%draft%'
   or relname ilike '%payload%'
order by pg_total_relation_size(relid) desc;

\echo '== Sequential scan heavy tables since stats reset =='
select
  schemaname,
  relname as table_name,
  seq_scan,
  seq_tup_read,
  idx_scan,
  n_live_tup,
  pg_size_pretty(pg_total_relation_size(relid)) as total_size
from pg_stat_user_tables
where seq_scan > 0
order by seq_tup_read desc
limit 30;

\echo '== Dead tuples / vacuum pressure =='
select
  schemaname,
  relname as table_name,
  n_live_tup,
  n_dead_tup,
  last_vacuum,
  last_autovacuum,
  last_analyze,
  last_autoanalyze
from pg_stat_user_tables
order by n_dead_tup desc
limit 30;

\echo '== Current connection count by database/user =='
select datname, usename, state, count(*)
from pg_stat_activity
where datname is not null
group by datname, usename, state
order by count(*) desc;
