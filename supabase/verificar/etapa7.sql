-- Verificación de la Etapa 7. Pégala completa en Supabase → SQL Editor → Run.
-- Solo lee: no cambia nada. Cada fila debe decir ✅.
with funciones(n) as (values ('crear_categoria'), ('renombrar_categoria'), ('ordenar_categorias'), ('activar_categoria'),
  ('eliminar_categoria'), ('crear_producto'), ('editar_producto'), ('duplicar_producto'), ('ordenar_productos'),
  ('ocultar_producto'), ('eliminar_producto'), ('cambiar_foto_producto'), ('marcar_agotado')),
revisiones(orden, revision, correcto, detalle) as (
  select 1, 'Migración del catálogo aplicada',
         exists (select 1 from supabase_migrations.schema_migrations where version = '20261116000100'), ''
  union all
  select 2, 'Funciones del catálogo',
         (select count(*) from funciones f where exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f.n)) = 13,
         (select count(*) from funciones f where exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f.n)) || ' de 13'
  union all
  select 3, 'Espacio privado para fotos', exists (select 1 from storage.buckets where id = 'fotos-productos' and not public), ''
  union all
  select 4, 'Menú en tiempo real (productos y categorías)',
         (select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and tablename in ('productos', 'categorias')) = 2, ''
  union all
  select 5, 'Menú actual (informativo)', true,
         (select count(*) from public.categorias where eliminada_en is null) || ' categorías · '
         || (select count(*) from public.productos where eliminado_en is null) || ' productos · '
         || (select count(*) from public.productos where estado = 'agotado' and eliminado_en is null) || ' agotados'
)
select case when correcto then '✅' else '❌' end as "Estado", revision as "Revisión", detalle as "Detalle"
from revisiones order by orden;
