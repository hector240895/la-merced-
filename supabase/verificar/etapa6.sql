-- Verificación de la Etapa 6. Pégala completa en Supabase → SQL Editor → Run.
-- Solo lee: no cambia nada.
with revisiones(orden, revision, correcto, detalle) as (
  select 1, 'Migración del servicio de impresión aplicada',
         exists (select 1 from supabase_migrations.schema_migrations where version = '20261112000100'), ''
  union all
  select 2, 'Cuenta "impresora" creada (perfil cajero, activa)',
         exists (select 1 from public.usuarios where usuario = 'impresora' and perfil = 'cajero' and activo), ''
  union all
  select 3, 'La computadora de caja está conectada (último aviso hace menos de 1 minuto)',
         exists (select 1 from public.servicio_impresion where ultimo_latido > now() - interval '1 minute'),
         coalesce((select equipo || ' · último aviso ' || to_char(ultimo_latido at time zone 'America/Mexico_City', 'DD/MM HH24:MI:SS')
                   from public.servicio_impresion limit 1), 'todavía no se conecta')
  union all
  select 4, 'Impresoras listas',
         coalesce((select bool_and(i ->> 'estado' = 'lista') from public.servicio_impresion s, jsonb_each(s.impresoras) as x(k, i)), false),
         coalesce((select string_agg(k || ': ' || (i ->> 'nombre') || ' (' || (i ->> 'estado') || ')', ' · ')
                   from public.servicio_impresion s, jsonb_each(s.impresoras) as x(k, i)), '')
  union all
  select 5, 'Comandas y tickets sin imprimir (informativo)', true,
         (select count(*) filter (where estado = 'pendiente') || ' pendientes, ' || count(*) filter (where estado = 'error') || ' con error'
          from public.trabajos_impresion)
)
select case when correcto then '✅' else '❌' end as "Estado", revision as "Revisión", detalle as "Detalle"
from revisiones order by orden;
