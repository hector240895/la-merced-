-- =============================================================================
-- Sistema La Merced · Ticket y precuenta sin opciones
-- A petición del propietario, el ticket del cliente y la precuenta tampoco
-- muestran el sabor de las bebidas: solo cantidad, producto e importe.
-- La comanda de cocina no cambia: sigue mostrando guisados y sabores.
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
                 'cantidad', l.cantidad, 'producto', l.nombre_producto, 'opcion', null,
                 'precio_unitario', l.precio_unitario, 'importe', l.precio_unitario * l.cantidad) order by l.creado_en, l.nombre_producto)
               from public.lineas_cuenta l where l.cuenta_id = k.id and l.estado = 'activa'), '[]'::jsonb),
    'extras', coalesce((select jsonb_agg(jsonb_build_object('concepto', x.concepto, 'importe', x.importe) order by x.creado_en)
               from public.cobros_extra x where x.cuenta_id = k.id and x.estado = 'activa'), '[]'::jsonb),
    'total',     k.total,
    -- Solo cuando se pagó en efectivo: con cuánto pagó y el cambio.
    'recibido', (select p.recibido from public.pagos p
                 where p.cuenta_id = k.id and p.estado = 'vigente' and p.metodo = 'efectivo' order by p.creado_en desc limit 1),
    'cambio',   (select p.cambio from public.pagos p
                 where p.cuenta_id = k.id and p.estado = 'vigente' and p.metodo = 'efectivo' order by p.creado_en desc limit 1))
  from public.cuentas k join public.sucursales s on s.id = k.sucursal_id
  where k.id = p_cuenta_id
$$;


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
                 'cantidad', l.cantidad, 'producto', l.nombre_producto, 'opcion', null,
                 'precio_unitario', l.precio_unitario, 'importe', l.precio_unitario * l.cantidad) order by l.creado_en, l.nombre_producto)
               from public.lineas_cuenta l where l.cuenta_id = k.id and l.estado = 'activa'), '[]'::jsonb),
    'extras', coalesce((select jsonb_agg(jsonb_build_object('concepto', x.concepto, 'importe', x.importe) order by x.creado_en)
               from public.cobros_extra x where x.cuenta_id = k.id and x.estado = 'activa'), '[]'::jsonb),
    'total',     privado.total_cuenta(k.id),
    'leyenda',   s.leyenda_ticket)
  from public.cuentas k join public.sucursales s on s.id = k.sucursal_id
  where k.id = p_cuenta_id
$$;

