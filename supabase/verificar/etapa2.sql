-- Verificación de la Etapa 2. Pégala completa en Supabase → SQL Editor → Run.
-- Solo lee: no cambia nada. Cada fila debe decir ✅.
with
tablas_esperadas(t) as (values
  ('sucursales'),('usuarios'),('auditoria'),('avisos'),('autorizaciones'),('categorias'),('productos'),
  ('historial_precios'),('mesas'),('uniones_mesas'),('turnos_caja'),('movimientos_efectivo'),('cuentas'),
  ('lineas_cuenta'),('cobros_extra'),('comandas'),('comanda_lineas'),('pagos'),('propinas'),
  ('trabajos_impresion'),('gastos'),('gasto_productos')),
tablas as (
  select e.t, c.oid, c.relrowsecurity as rls
  from tablas_esperadas e
  left join pg_class c on c.relname = e.t and c.relnamespace = 'public'::regnamespace and c.relkind = 'r'),
revisiones(orden, revision, correcto, detalle) as (
  select 1, 'Las 22 tablas existen',
         count(oid) = 22,
         count(oid) || ' de 22' || coalesce(' · faltan: ' || string_agg(t, ', ') filter (where oid is null), '')
  from tablas
  union all
  select 2, 'Todas tienen permisos por perfil (RLS)',
         bool_and(rls), coalesce('sin RLS: ' || string_agg(t, ', ') filter (where not rls), 'todas')
  from tablas where oid is not null
  union all
  select 3, 'Ninguna tabla se puede borrar',
         count(*) filter (where exists (select 1 from pg_trigger g join pg_proc p on p.oid = g.tgfoid
                                        where g.tgrelid = tablas.oid and p.proname = 'prohibir_borrado')) = count(*),
         count(*) filter (where exists (select 1 from pg_trigger g join pg_proc p on p.oid = g.tgfoid
                                        where g.tgrelid = tablas.oid and p.proname = 'prohibir_borrado')) || ' de ' || count(*) || ' protegidas'
  from tablas where oid is not null
  union all
  select 4, 'La auditoría no se puede editar',
         exists (select 1 from pg_trigger where tgname = 'auditoria_sin_cambios'), ''
  union all
  select 5, 'Las 5 migraciones están aplicadas',
         (select count(*) from supabase_migrations.schema_migrations where version like '20261031%') = 5,
         (select count(*) from supabase_migrations.schema_migrations where version like '20261031%') || ' de 5'
  union all
  select 6, 'Las 7 mesas iniciales',
         (select count(*) from public.mesas where eliminada_en is null) = 7,
         (select count(*) from public.mesas where eliminada_en is null) || ' mesas'
  union all
  select 7, 'Los 2 propietarios creados',
         (select count(*) from public.usuarios where perfil = 'propietario') = 2,
         coalesce((select string_agg(nombre || ' (' || usuario || ')', ', ') from public.usuarios where perfil = 'propietario'),
                  'ninguno todavía: falta el paso npm run propietario')
  union all
  select 8, 'Sin accesos sueltos (solo los registrados)',
         not exists (select 1 from auth.users a where not exists (select 1 from public.usuarios u where u.id = a.id)),
         (select count(*) from auth.users) || ' accesos en Authentication'
)
select case when correcto then '✅' else '❌' end as "Estado", revision as "Revisión", detalle as "Detalle"
from revisiones order by orden;
