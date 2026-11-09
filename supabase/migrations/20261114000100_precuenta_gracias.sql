-- =============================================================================
-- Sistema La Merced · Precuenta con la leyenda de agradecimiento
-- A petición del propietario, la precuenta termina con la misma leyenda del
-- ticket ("¡Gracias por su visita!") en lugar de "CUENTA NO PAGADA".
-- =============================================================================
create or replace function privado.contenido_precuenta(p_cuenta_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'documento', 'precuenta',
    'negocio',   coalesce(s.nombre_comercial, s.nombre),
    'destino',   privado.nombre_cuenta(k),
    'folio',     k.folio,
    'fecha',     to_char(now() at time zone s.zona_horaria, 'DD/MM/YYYY'),
    'hora',      to_char(now() at time zone s.zona_horaria, 'HH24:MI'),
    'lineas', coalesce((select jsonb_agg(jsonb_build_object(
                 'cantidad', l.cantidad, 'producto', l.nombre_producto, 'opcion', l.opcion,
                 'precio_unitario', l.precio_unitario, 'importe', l.precio_unitario * l.cantidad) order by l.creado_en, l.nombre_producto)
               from public.lineas_cuenta l where l.cuenta_id = k.id and l.estado = 'activa'), '[]'::jsonb),
    'extras', coalesce((select jsonb_agg(jsonb_build_object('concepto', x.concepto, 'importe', x.importe) order by x.creado_en)
               from public.cobros_extra x where x.cuenta_id = k.id and x.estado = 'activa'), '[]'::jsonb),
    'total',     privado.total_cuenta(k.id),
    'leyenda',   s.leyenda_ticket)
  from public.cuentas k join public.sucursales s on s.id = k.sucursal_id
  where k.id = p_cuenta_id
$$;
