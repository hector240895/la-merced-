-- Revisión de seguridad (Etapa 10). Pégala completa en Supabase → SQL Editor → Run.
-- Solo lee: no cambia nada. Cada fila debe decir ✅.
with tablas as (select c.oid, c.relname from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'),
revisiones(orden, revision, correcto, detalle) as (
  select 1, 'Todas las tablas tienen permisos por perfil (RLS forzado)',
         not exists (select 1 from pg_class c join tablas t on t.oid = c.oid where not (c.relrowsecurity and c.relforcerowsecurity)),
         coalesce((select string_agg(c.relname, ', ') from pg_class c join tablas t on t.oid = c.oid
                   where not (c.relrowsecurity and c.relforcerowsecurity)), '')
  union all
  select 2, 'Nadie escribe directo en las tablas (todo pasa por funciones del servidor)',
         not exists (select 1 from information_schema.role_table_grants where table_schema = 'public'
                     and grantee in ('anon', 'authenticated') and privilege_type <> 'SELECT'),
         coalesce((select string_agg(distinct table_name, ', ') from information_schema.role_table_grants where table_schema = 'public'
                   and grantee in ('anon', 'authenticated') and privilege_type <> 'SELECT'), '')
  union all
  select 3, 'Sin iniciar sesión no se ve ninguna tabla',
         not exists (select 1 from information_schema.role_table_grants where table_schema = 'public' and grantee = 'anon'), ''
  union all
  select 4, 'Sin iniciar sesión no se ejecuta ninguna función',
         not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and has_function_privilege('anon', p.oid, 'execute')),
         coalesce((select string_agg(p.proname, ', ') from pg_proc p where p.pronamespace = 'public'::regnamespace
                   and has_function_privilege('anon', p.oid, 'execute')), '')
  union all
  select 5, 'Funciones del servidor protegidas (search_path fijo)',
         not exists (select 1 from pg_proc p where p.pronamespace in ('public'::regnamespace, 'privado'::regnamespace) and p.prosecdef
                     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) x where x like 'search_path=%')), ''
  union all
  select 6, 'Ninguna tabla permite borrar registros',
         not exists (select 1 from tablas t where not exists (select 1 from pg_trigger g join pg_proc p on p.oid = g.tgfoid
                     where g.tgrelid = t.oid and p.proname = 'prohibir_borrado' and g.tgtype::int & 8 = 8)),
         coalesce((select string_agg(t.relname, ', ') from tablas t where not exists (select 1 from pg_trigger g join pg_proc p on p.oid = g.tgfoid
                   where g.tgrelid = t.oid and p.proname = 'prohibir_borrado' and g.tgtype::int & 8 = 8)), '')
  union all
  select 7, 'La auditoría solo admite agregar',
         exists (select 1 from pg_trigger g where g.tgrelid = 'public.auditoria'::regclass and not g.tgisinternal and g.tgtype::int & 16 = 16), ''
  union all
  select 8, 'Fotos del menú en espacio privado', exists (select 1 from storage.buckets where id = 'fotos-productos' and not public), ''
  union all
  select 9, 'Exactamente dos propietarios activos',
         (select count(*) from public.usuarios where perfil = 'propietario' and activo) = 2,
         (select string_agg(nombre, ', ') from public.usuarios where perfil = 'propietario' and activo)
  union all
  select 10, 'Cuentas activas (informativo)', true,
         (select count(*) filter (where perfil = 'mesero') || ' meseros · ' || count(*) filter (where perfil = 'cajero') || ' cajeros'
          from public.usuarios where activo)
)
select case when correcto then '✅' else '❌' end as "Estado", revision as "Revisión", detalle as "Detalle"
from revisiones order by orden;
