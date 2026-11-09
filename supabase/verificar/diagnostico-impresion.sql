-- Diagnóstico de impresión. Pégala completa en Supabase → SQL Editor → Run.
-- Solo lee: no cambia nada.
select 1 as orden, 'Migraciones de la precuenta' as que,
       case when exists (select 1 from supabase_migrations.schema_migrations where version = '20261114000100') then '✅ aplicadas'
            else '❌ falta correr npx supabase db push' end as detalle
union all
select 2, 'Programa de la computadora de caja',
       coalesce((select 'versión ' || version || ' · ' || equipo || ' · último aviso '
                        || to_char(ultimo_latido at time zone 'America/Mexico_City', 'DD/MM HH24:MI:SS')
                        || case when ultimo_latido < now() - interval '1 minute' then ' (❌ desconectado)' else ' (✅ conectado)' end
                 from public.servicio_impresion limit 1), '❌ nunca se ha conectado')
union all
select 3, 'Impresoras', coalesce((select string_agg(k || ': ' || (i ->> 'nombre') || ' (' || (i ->> 'estado') || ')', ' · ')
                                  from public.servicio_impresion s, jsonb_each(s.impresoras) as x(k, i)), '—')
union all
select 10 + row_number() over (order by creado_en desc), 'Últimas impresiones de caja',
       to_char(creado_en at time zone 'America/Mexico_City', 'DD/MM HH24:MI:SS') || ' · ' || documento || ' · '
       || coalesce(contenido ->> 'destino', 'folio ' || (contenido ->> 'folio'), '') || ' · ' || estado
       || coalesce(' · ' || ultimo_error, '')
from (select * from public.trabajos_impresion where impresora = 'caja' order by creado_en desc limit 6) t
order by orden;
