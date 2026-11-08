-- Verificación de la Etapa 5. Pégala completa en Supabase → SQL Editor → Run.
-- Solo lee: no cambia nada. Cada fila debe decir ✅.
with funciones(n) as (values ('enviar_pedido_llevar'), ('abrir_caja'), ('registrar_movimiento'), ('agregar_cobro_extra'),
  ('quitar_cobro_extra'), ('cobrar_cuenta'), ('reimprimir_ticket'), ('resumen_caja'), ('cerrar_caja'), ('aprobar_corte'), ('reabrir_corte')),
revisiones(orden, revision, correcto, detalle) as (
  select 1, 'Migración de caja aplicada',
         exists (select 1 from supabase_migrations.schema_migrations where version = '20261110000100'), ''
  union all
  select 2, 'Funciones de caja y pagos',
         (select count(*) from funciones f where exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f.n)) = 11,
         (select count(*) from funciones f where exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f.n)) || ' de 11'
  union all
  select 3, 'Devoluciones protegidas (sin borrar, con permisos)',
         (select relrowsecurity from pg_class where oid = 'public.devoluciones'::regclass)
         and exists (select 1 from pg_trigger where tgname = 'devoluciones_sin_borrado'), ''
  union all
  select 4, 'Datos del negocio para el ticket',
         (select direccion is not null and telefonos is not null from public.sucursales limit 1),
         (select nombre_comercial || ' · ' || direccion from public.sucursales limit 1)
  union all
  select 5, 'Caja en tiempo real',
         (select count(*) from pg_publication_tables where pubname = 'supabase_realtime'
            and tablename in ('cobros_extra', 'turnos_caja', 'pagos', 'movimientos_efectivo')) = 4, ''
  union all
  select 6, 'Caja abierta ahora (informativo)', true,
         coalesce((select 'Sí, desde ' || to_char(abierto_en at time zone 'America/Mexico_City', 'DD/MM/YYYY HH24:MI')
                   from public.turnos_caja where estado = 'abierto'), 'No')
)
select case when correcto then '✅' else '❌' end as "Estado", revision as "Revisión", detalle as "Detalle"
from revisiones order by orden;
