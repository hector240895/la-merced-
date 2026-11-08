-- Verificación de la Etapa 3. Pégala completa en Supabase → SQL Editor → Run.
-- Solo lee: no cambia nada. Cada fila debe decir ✅.
with revisiones(orden, revision, correcto, detalle) as (
  select 1, 'Las 10 migraciones están aplicadas',
         (select count(*) from supabase_migrations.schema_migrations where version like '202611%' or version like '20261031%') = 10,
         (select count(*) from supabase_migrations.schema_migrations where version like '202611%' or version like '20261031%') || ' de 10'
  union all
  select 2, 'Correcciones de la auditoría aplicadas',
         exists (select 1 from supabase_migrations.schema_migrations where version = '20261103000100'), ''
  union all
  select 3, 'Funciones de mesas y pedidos',
         (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in
           ('ocupar_mesa','liberar_mesa','enviar_pedido','quitar_producto','pedir_cuenta','unir_mesas','separar_mesas',
            'crear_mesa','renombrar_mesa','ordenar_mesas','activar_mesa','eliminar_mesa')) = 12,
         (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in
           ('ocupar_mesa','liberar_mesa','enviar_pedido','quitar_producto','pedir_cuenta','unir_mesas','separar_mesas',
            'crear_mesa','renombrar_mesa','ordenar_mesas','activar_mesa','eliminar_mesa')) || ' de 12'
  union all
  select 4, 'Menú: 10 categorías',
         (select count(*) from public.categorias where eliminada_en is null) = 10,
         (select count(*) from public.categorias where eliminada_en is null) || ' categorías'
  union all
  select 5, 'Menú: 57 productos',
         (select count(*) from public.productos where eliminado_en is null) = 57,
         (select count(*) from public.productos where eliminado_en is null) || ' productos'
  union all
  select 6, 'Sabores en aguas, refrescos y Arizona',
         (select count(*) from public.productos where cardinality(opciones) > 0) = 5,
         (select string_agg(nombre || ' (' || cardinality(opciones) || ')', ', ') from public.productos where cardinality(opciones) > 0)
  union all
  select 7, 'Tiempo real activado en 7 tablas',
         (select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public'
            and tablename in ('mesas','cuentas','lineas_cuenta','comandas','avisos','autorizaciones','usuarios')) = 7,
         (select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public'
            and tablename in ('mesas','cuentas','lineas_cuenta','comandas','avisos','autorizaciones','usuarios')) || ' de 7'
  union all
  select 8, 'Los 2 propietarios siguen',
         (select count(*) from public.usuarios where perfil = 'propietario' and activo) = 2,
         (select string_agg(nombre, ', ') from public.usuarios where perfil = 'propietario')
)
select case when correcto then '✅' else '❌' end as "Estado", revision as "Revisión", detalle as "Detalle"
from revisiones order by orden;
