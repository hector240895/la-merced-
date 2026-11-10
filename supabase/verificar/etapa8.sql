-- Verificación de la Etapa 8. Pégala completa en Supabase → SQL Editor → Run.
-- Solo lee: no cambia nada. Cada fila debe decir ✅.
with funciones(n) as (values ('guardar_proveedor'), ('eliminar_proveedor'), ('guardar_insumo'), ('eliminar_insumo'),
  ('registrar_compra'), ('registrar_entrada'), ('registrar_merma'), ('ajustar_existencia'), ('mis_movimientos_inventario')),
revisiones(orden, revision, correcto, detalle) as (
  select 1, 'Migración del inventario aplicada',
         exists (select 1 from supabase_migrations.schema_migrations where version = '20261117000100'), ''
  union all
  select 2, 'Funciones del inventario',
         (select count(*) from funciones f where exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f.n)) = 9,
         (select count(*) from funciones f where exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f.n)) || ' de 9'
  union all
  select 3, 'Tablas protegidas (permisos activos)',
         (select count(*) from pg_class where relnamespace = 'public'::regnamespace
            and relname in ('insumos', 'proveedores', 'movimientos_inventario') and relrowsecurity and relforcerowsecurity) = 3, ''
  union all
  select 4, 'Movimientos no se editan ni se borran',
         (select count(*) from pg_trigger where tgrelid = 'public.movimientos_inventario'::regclass and not tgisinternal) >= 4, ''
  union all
  select 5, 'Inventario en tiempo real',
         (select count(*) from pg_publication_tables where pubname = 'supabase_realtime'
            and tablename in ('insumos', 'proveedores', 'movimientos_inventario')) = 3, ''
  union all
  select 6, 'Inventario actual (informativo)', true,
         (select count(*) from public.insumos where eliminado_en is null) || ' insumos · '
         || (select count(*) from public.insumos where eliminado_en is null and minimo > 0 and existencia <= minimo) || ' por surtir · '
         || (select count(*) from public.proveedores where eliminado_en is null) || ' proveedores'
)
select case when correcto then '✅' else '❌' end as "Estado", revision as "Revisión", detalle as "Detalle"
from revisiones order by orden;
