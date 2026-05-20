-- Supabase Deploy Guard: read-only SQL audit
-- Run in staging first. This script only SELECTs metadata.

\echo '== 01. Tables in public with RLS disabled =='
select n.nspname as schema_name, c.relname as table_name, c.relkind, c.relrowsecurity, c.relforcerowsecurity
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r','p') and n.nspname in ('public') and c.relrowsecurity = false
order by 1,2;

\echo '== 02. RLS-enabled tables with zero policies =='
select n.nspname as schema_name, c.relname as table_name
from pg_class c join pg_namespace n on n.oid = c.relnamespace
left join pg_policy p on p.polrelid = c.oid
where c.relkind in ('r','p') and n.nspname in ('public','storage') and c.relrowsecurity = true
group by n.nspname, c.relname having count(p.oid) = 0
order by 1,2;

\echo '== 03. Broad or anonymous policies =='
select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname in ('public','storage')
  and (roles::text ilike '%anon%' or roles::text = '{}')
  and (coalesce(qual,'') ~* '^\(?\s*true\s*\)?$' or coalesce(with_check,'') ~* '^\(?\s*true\s*\)?$' or cmd = 'ALL')
order by 1,2,3;

\echo '== 04. Grants to anon/authenticated on tables =='
select grantee, table_schema, table_name, privilege_type
from information_schema.role_table_grants
where grantee in ('anon','authenticated') and table_schema not in ('pg_catalog','information_schema')
order by table_schema, table_name, grantee, privilege_type;

\echo '== 05. Views in public without security_invoker =='
select n.nspname as schema_name, c.relname as view_name, c.relkind, c.reloptions
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('v','m') and n.nspname = 'public'
  and (c.reloptions is null or array_to_string(c.reloptions, ',') not ilike '%security_invoker=true%')
order by 1,2;

\echo '== 06. SECURITY DEFINER functions =='
select n.nspname as schema_name, p.proname as function_name, pg_get_function_identity_arguments(p.oid) as args,
       p.prosecdef, p.proconfig,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where p.prosecdef = true and n.nspname not in ('pg_catalog','information_schema')
order by 1,2;

\echo '== 07. SECURITY DEFINER functions missing fixed search_path =='
select n.nspname as schema_name, p.proname as function_name, pg_get_function_identity_arguments(p.oid) as args, p.proconfig
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where p.prosecdef = true and n.nspname not in ('pg_catalog','information_schema')
  and not exists (select 1 from unnest(coalesce(p.proconfig, array[]::text[])) cfg where cfg like 'search_path=%')
order by 1,2;

\echo '== 08. Functions executable by anon/authenticated in public =='
select n.nspname as schema_name, p.proname as function_name, pg_get_function_identity_arguments(p.oid) as args,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
order by 1,2;

\echo '== 09. Storage buckets =='
select id, name, public, file_size_limit, allowed_mime_types, created_at, updated_at
from storage.buckets
order by public desc, name;

\echo '== 10. Storage policies =='
select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies where schemaname = 'storage'
order by tablename, policyname;

\echo '== 11. Realtime publication tables =='
select pubname, schemaname, tablename
from pg_publication_tables
where pubname ilike '%realtime%' or pubname = 'supabase_realtime'
order by pubname, schemaname, tablename;

\echo '== 12. Largest tables =='
select schemaname, relname as relation_name,
       pg_size_pretty(pg_total_relation_size(relid)) as total_size,
       pg_size_pretty(pg_relation_size(relid)) as table_size,
       pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid)) as index_or_toast_size
from pg_catalog.pg_statio_user_tables
order by pg_total_relation_size(relid) desc
limit 30;

\echo '== 13. Unindexed foreign keys =='
with fk as (select conrelid, conname, conkey from pg_constraint where contype = 'f'),
indexed as (select indrelid, indkey::smallint[] as indkey from pg_index)
select n.nspname as schema_name, c.relname as table_name, fk.conname, fk.conkey
from fk join pg_class c on c.oid = fk.conrelid join pg_namespace n on n.oid = c.relnamespace
where n.nspname not in ('pg_catalog','information_schema')
  and not exists (select 1 from indexed i where i.indrelid = fk.conrelid and i.indkey[0:array_length(fk.conkey,1)-1] = fk.conkey)
order by 1,2,3;

\echo '== 14. RLS policies using raw_user_meta_data =='
select schemaname, tablename, policyname, qual, with_check
from pg_policies
where coalesce(qual,'') ilike '%raw_user_meta_data%' or coalesce(with_check,'') ilike '%raw_user_meta_data%'
order by 1,2,3;

\echo '== 15. Default privileges exposing anon/authenticated =='
select defaclrole::regrole as role, defaclnamespace::regnamespace as schema_name, defaclobjtype as object_type, defaclacl as acl
from pg_default_acl
where defaclacl::text ilike '%anon%' or defaclacl::text ilike '%authenticated%'
order by 1,2,3;

\echo '== 16. Replication slots and WAL retention =='
select slot_name, plugin, slot_type, database, active, restart_lsn, confirmed_flush_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as retained_wal
from pg_replication_slots
order by active desc, slot_name;

\echo '== Done. Review all non-empty result sets before deploy. =='
