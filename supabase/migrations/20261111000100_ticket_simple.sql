-- =============================================================================
-- Sistema La Merced · Ticket más simple
-- A petición del propietario, el ticket ya no lleva mesa, mesero, quién
-- atendió en caja, dirección ni teléfonos. Queda: nombre del negocio, fecha,
-- hora, folio, "Para llevar" cuando aplica, productos con precio, cobros
-- extra, total, pagos, cambio, propina y la leyenda de agradecimiento.
-- Los tickets ya emitidos no cambian (son el registro de lo que se imprimió).
-- =============================================================================
create or replace function privado.contenido_ticket(p_cuenta_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'documento', 'ticket',
    'negocio',   coalesce(s.nombre_comercial, s.nombre),
    'leyenda',   s.leyenda_ticket,
    'folio',     k.folio,
    'para_llevar', k.tipo = 'llevar',
    'fecha',     to_char(coalesce(k.cobrada_en, now()) at time zone s.zona_horaria, 'DD/MM/YYYY'),
    'hora',      to_char(coalesce(k.cobrada_en, now()) at time zone s.zona_horaria, 'HH24:MI'),
    'lineas', coalesce((select jsonb_agg(jsonb_build_object(
                 'cantidad', l.cantidad, 'producto', l.nombre_producto, 'opcion', l.opcion,
                 'precio_unitario', l.precio_unitario, 'importe', l.precio_unitario * l.cantidad) order by l.creado_en, l.nombre_producto)
               from public.lineas_cuenta l where l.cuenta_id = k.id and l.estado = 'activa'), '[]'::jsonb),
    'extras', coalesce((select jsonb_agg(jsonb_build_object('concepto', x.concepto, 'importe', x.importe) order by x.creado_en)
               from public.cobros_extra x where x.cuenta_id = k.id and x.estado = 'activa'), '[]'::jsonb),
    'subtotal',  k.subtotal,
    'impuestos', k.impuestos,
    'total',     k.total,
    'pagos', coalesce((select jsonb_agg(jsonb_build_object('metodo', p.metodo, 'importe', p.importe,
                                                           'recibido', p.recibido, 'cambio', p.cambio) order by p.creado_en)
               from public.pagos p where p.cuenta_id = k.id and p.estado = 'vigente'), '[]'::jsonb),
    'propina', (select jsonb_build_object('metodo', t.metodo, 'importe', t.importe)
                from public.propinas t where t.cuenta_id = k.id and t.estado = 'vigente' order by t.creado_en desc limit 1))
  from public.cuentas k join public.sucursales s on s.id = k.sucursal_id
  where k.id = p_cuenta_id
$$;
