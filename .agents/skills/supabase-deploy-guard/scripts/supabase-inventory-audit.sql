-- Supabase inventory audit: read-only operational/billing context helper.
-- Run after supabase-db-audit.sql. This does not replace Dashboard/MCP billing checks.

\echo '== project/database basics =='
select now() as audited_at, current_database() as database_name, current_user as current_user, version() as postgres_version;

\echo '== installed extensions =='
select e.extname, n.nspname as schema_name, e.extversion
from pg_extension e
join pg_namespace n on n.oid = e.extnamespace
order by e.extname;

\echo '== largest relations =='
select n.nspname as schema_name,
       c.relname as relation_name,
       c.relkind,
       pg_size_pretty(pg_total_relation_size(c.oid)) as total_size,
       pg_size_pretty(pg_relation_size(c.oid)) as table_size,
       c.reltuples::bigint as estimated_rows
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r','p','m')
  and n.nspname not in ('pg_catalog','information_schema')
order by pg_total_relation_size(c.oid) desc
limit 50;

\echo '== realtime publications =='
select pubname, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate
from pg_publication
order by pubname;

\echo '== publication tables =='
select pubname, schemaname, tablename
from pg_publication_tables
order by pubname, schemaname, tablename;

\echo '== storage buckets =='
select id, name, public, file_size_limit, allowed_mime_types, created_at, updated_at
from storage.buckets
order by public desc, name;

\echo '== non-internal triggers =='
select n.nspname as schema_name, c.relname as table_name, t.tgname as trigger_name, pg_get_triggerdef(t.oid) as trigger_def
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where not t.tgisinternal
  and n.nspname not in ('pg_catalog','information_schema')
order by 1,2,3;

\echo '== roles with bypassrls =='
select rolname, rolbypassrls, rolcanlogin, rolsuper
from pg_roles
where rolbypassrls or rolsuper
order by rolname;
