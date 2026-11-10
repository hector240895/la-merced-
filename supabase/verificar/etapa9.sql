-- Verificación de la Etapa 9. Pégala completa en Supabase → SQL Editor → Run.
-- Solo lee: no cambia nada. Cada fila debe decir ✅.
with funciones(n) as (values ('registrar_gasto'), ('anular_gasto'), ('registrar_compra'), ('guardar_categoria_gasto'),
  ('eliminar_categoria_gasto'), ('guardar_gasto_fijo'), ('eliminar_gasto_fijo'), ('generar_gastos_fijos'),
  ('guardar_empleado'), ('eliminar_empleado'), ('pagar_sueldos'), ('reporte_finanzas'), ('gastos_por_dueno')),
revisiones(orden, revision, correcto, detalle) as (
  select 1, 'Migraciones de finanzas aplicadas',
         (select count(*) from supabase_migrations.schema_migrations where version in ('20261118000100', '20261118000200', '20261118000300', '20261119000100')) = 4, ''
  union all
  select 2, 'Funciones de finanzas',
         (select count(*) from funciones f where exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f.n)) = 13,
         (select count(*) from funciones f where exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f.n)) || ' de 13'
  union all
  select 3, 'Categorías de gasto', (select count(*) from public.categorias_gasto where clave is not null) = 14,
         (select count(*) from public.categorias_gasto where eliminado_en is null) || ' categorías'
  union all
  select 4, 'Tablas protegidas (permisos activos)',
         (select count(*) from pg_class where relnamespace = 'public'::regnamespace
            and relname in ('categorias_gasto', 'empleados', 'gastos_fijos') and relrowsecurity and relforcerowsecurity) = 3, ''
  union all
  select 5, 'Todos los gastos tienen categoría', not exists (select 1 from public.gastos where categoria_id is null), ''
  union all
  select 6, 'Gastos en tiempo real',
         (select count(*) from pg_publication_tables where pubname = 'supabase_realtime'
            and tablename in ('gastos', 'gastos_fijos', 'empleados', 'categorias_gasto')) = 4, ''
  union all
  select 7, 'Datos actuales (informativo)', true,
         (select count(*) from public.empleados where eliminado_en is null) || ' empleados · '
         || (select count(*) from public.gastos_fijos where eliminado_en is null) || ' gastos fijos · '
         || (select count(*) from public.gastos where estado = 'vigente') || ' gastos'
)
select case when correcto then '✅' else '❌' end as "Estado", revision as "Revisión", detalle as "Detalle"
from revisiones order by orden;
