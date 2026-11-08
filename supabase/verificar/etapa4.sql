-- Verificación de la Etapa 4. Pégala completa en Supabase → SQL Editor → Run.
-- Solo lee: no cambia nada. Cada fila debe decir ✅.
with revisiones(orden, revision, correcto, detalle) as (
  select 1, 'Migración de comandas aplicada',
         exists (select 1 from supabase_migrations.schema_migrations where version = '20261108000100'), ''
  union all
  select 2, 'Cada pedido encola su comanda',
         exists (select 1 from pg_trigger where tgname = 'comandas_imprimir'), ''
  union all
  select 3, 'La base rechaza comandas con precios',
         exists (select 1 from pg_constraint where conname = 'trabajos_comanda_sin_precios'), ''
  union all
  select 4, 'Funciones de impresión',
         (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
            and proname in ('reportar_impresion', 'reintentar_impresion', 'reimprimir_comanda')) = 3,
         (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
            and proname in ('reportar_impresion', 'reintentar_impresion', 'reimprimir_comanda')) || ' de 3'
  union all
  select 5, 'Estado de impresión en tiempo real',
         exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'trabajos_impresion'), ''
  union all
  select 6, 'Comandas encoladas hasta ahora (informativo)', true,
         (select count(*) from public.trabajos_impresion where documento = 'comanda') || ' comandas'
)
select case when correcto then '✅' else '❌' end as "Estado", revision as "Revisión", detalle as "Detalle"
from revisiones order by orden;
