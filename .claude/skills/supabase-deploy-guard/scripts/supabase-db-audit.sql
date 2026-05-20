-- Supabase DB Audit Queries
-- Run in Supabase SQL Editor, psql, or read-only MCP SQL before production deploy.
-- Review all rows returned by these queries. Some rows may be valid exceptions, but every exception must be documented.

-- 01. Public/exposed schema tables without RLS.
select
  n.nspname as schema,
  c.relname as object_name,
  case c.relkind when 'r' then 'table' when 'p' then 'partitioned_table' else c.relkind::text end as object_type,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as force_rls
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('public')
  and c.relkind in ('r','p')
  and not c.relrowsecurity
order by 1,2;

-- 02. Grants to anon/authenticated/service_role on non-system schemas.
select
  table_schema,
  table_name,
  grantee,
  privilege_type
from information_schema.role_table_grants
where grantee in ('anon', 'authenticated', 'service_role')
  and table_schema not in ('pg_catalog','information_schema')
order by table_schema, table_name, grantee, privilege_type;

-- 03. Broad grants to anon/authenticated.
select
  table_schema,
  table_name,
  grantee,
  string_agg(privilege_type, ', ' order by privilege_type) as privileges
from information_schema.role_table_grants
where grantee in ('anon', 'authenticated')
  and table_schema not in ('pg_catalog','information_schema')
group by table_schema, table_name, grantee
having bool_or(privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'))
order by table_schema, table_name, grantee;

-- 04. Default privileges that may auto-grant future access.
select
  coalesce(n.nspname, '<all schemas>') as schema,
  defaclrole::regrole as grantor_role,
  defaclobjtype as object_type,
  defaclacl::text as acl
from pg_default_acl d
left join pg_namespace n on n.oid = d.defaclnamespace
where defaclacl::text ~ '(anon|authenticated)'
order by 1,2,3;

-- 05. RLS policies that look overly permissive.
select
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual as using_expression,
  with_check as with_check_expression
from pg_policies
where schemaname not in ('pg_catalog','information_schema')
  and (
    coalesce(qual, '') ~* '^\s*true\s*$'
    or coalesce(with_check, '') ~* '^\s*true\s*$'
    or roles::text ~ '(public|anon|authenticated)'
  )
order by schemaname, tablename, policyname;

-- 06. Tables with RLS enabled but no policy. This may block access unexpectedly; review intentionally private tables.
select
  n.nspname as schema,
  c.relname as table_name
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_policies p on p.schemaname = n.nspname and p.tablename = c.relname
where n.nspname in ('public')
  and c.relkind in ('r','p')
  and c.relrowsecurity
  and p.policyname is null
order by 1,2;

-- 07. Views/materialized views in public. Review security_invoker and sensitive data exposure.
select
  n.nspname as schema,
  c.relname as view_name,
  case c.relkind when 'v' then 'view' when 'm' then 'materialized_view' else c.relkind::text end as view_type,
  coalesce(array_to_string(c.reloptions, ', '), '') as reloptions
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('public')
  and c.relkind in ('v','m')
order by 1,2;

-- 08. SECURITY DEFINER functions.
select
  n.nspname as schema,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as args,
  p.prosecdef as security_definer,
  coalesce(array_to_string(p.proconfig, ', '), '') as function_config,
  case
    when exists (select 1 from unnest(coalesce(p.proconfig, array[]::text[])) cfg where cfg like 'search_path=%') then 'has_search_path'
    else 'missing_search_path_review_required'
  end as search_path_status
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname not in ('pg_catalog','information_schema')
  and p.prosecdef
order by 1,2;

-- 09. Function EXECUTE grants to anon/authenticated.
select
  routine_schema,
  routine_name,
  grantee,
  privilege_type
from information_schema.routine_privileges
where grantee in ('anon','authenticated')
  and routine_schema not in ('pg_catalog','information_schema')
order by routine_schema, routine_name, grantee;

-- 10. Extensions installed in public schema.
select
  e.extname,
  n.nspname as schema,
  e.extversion
from pg_extension e
join pg_namespace n on n.oid = e.extnamespace
where n.nspname = 'public'
order by e.extname;

-- 11. Extensions that can introduce external access, loop, queue, graphql, or FDW risk. Review schema and grants.
select
  e.extname,
  n.nspname as schema,
  e.extversion
from pg_extension e
join pg_namespace n on n.oid = e.extnamespace
where e.extname in ('http','pg_net','pg_cron','pgmq','postgres_fdw','dblink','wrappers','pg_graphql','file_fdw')
order by e.extname;

-- 12. Auth schema grants. auth.users should not be exposed to anon/authenticated.
select
  table_schema,
  table_name,
  grantee,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'auth'
  and grantee in ('anon','authenticated')
order by table_name, grantee, privilege_type;

-- 13. Potential sensitive columns in public schema. Review whether these are exposed through Data API or views.
select
  table_schema,
  table_name,
  column_name,
  data_type
from information_schema.columns
where table_schema in ('public')
  and column_name ~* '(password|passcode|token|secret|api[_-]?key|private|ssn|credit|card|address|phone|email|otp|session|jwt)'
order by table_schema, table_name, column_name;

-- 14. Storage buckets. Review public=true, file size limit, MIME limits.
select
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types,
  created_at,
  updated_at
from storage.buckets
order by public desc, id;

-- 15. Storage policies.
select
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual as using_expression,
  with_check as with_check_expression
from pg_policies
where schemaname = 'storage'
order by tablename, policyname;

-- 16. Storage policies that may allow public listing or broad access.
select
  schemaname,
  tablename,
  policyname,
  roles,
  cmd,
  qual,
  with_check
from pg_policies
where schemaname = 'storage'
  and tablename = 'objects'
  and (
    roles::text ~ '(public|anon)'
    or coalesce(qual,'') ~* '^\s*true\s*$'
    or coalesce(with_check,'') ~* '^\s*true\s*$'
  )
order by policyname;

-- 17. Realtime publications. Review table scope and fan-out risk.
select
  pubname,
  schemaname,
  tablename
from pg_publication_tables
where pubname ilike '%realtime%'
   or pubname = 'supabase_realtime'
order by pubname, schemaname, tablename;

-- 18. Publications for all tables or broad replication.
select
  pubname,
  puballtables,
  pubinsert,
  pubupdate,
  pubdelete,
  pubtruncate
from pg_publication
order by pubname;

-- 19. Foreign tables in public/exposed schema.
select
  foreign_table_schema,
  foreign_table_name,
  foreign_server_name
from information_schema.foreign_tables
where foreign_table_schema in ('public')
order by 1,2;

-- 20. Tables without primary key in public schema. This is performance/data-integrity risk.
select
  n.nspname as schema,
  c.relname as table_name
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('public')
  and c.relkind in ('r','p')
  and not exists (
    select 1
    from pg_index i
    where i.indrelid = c.oid and i.indisprimary
  )
order by 1,2;

-- 21. Unindexed foreign keys in public schema.
with fk as (
  select
    conrelid,
    conname,
    conkey
  from pg_constraint
  where contype = 'f'
), idx as (
  select
    indrelid,
    indkey
  from pg_index
)
select
  n.nspname as schema,
  c.relname as table_name,
  fk.conname as foreign_key_name,
  fk.conkey as fk_columns
from fk
join pg_class c on c.oid = fk.conrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and not exists (
    select 1
    from idx
    where idx.indrelid = fk.conrelid
      and fk.conkey::int2[] <@ idx.indkey::int2[]
  )
order by 1,2,3;

-- 22. Active triggers in public schema. Review side effects, external calls, recursion.
select
  event_object_schema,
  event_object_table,
  trigger_name,
  action_timing,
  event_manipulation,
  action_statement
from information_schema.triggers
where event_object_schema in ('public')
order by event_object_schema, event_object_table, trigger_name;

-- 23. Hints for optional extension tables. Run the printed SELECTs manually if present.
do $$
begin
  if to_regclass('cron.job') is not null then
    raise notice 'pg_cron detected. Review with: select jobid, schedule, command, active, jobname from cron.job order by jobid;';
  end if;
  if to_regclass('net.http_request_queue') is not null then
    raise notice 'pg_net detected. Review net schema queues and failed requests.';
  end if;
  if to_regclass('pgmq.meta') is not null then
    raise notice 'pgmq detected. Review queues, grants, and API exposure.';
  end if;
end $$;
