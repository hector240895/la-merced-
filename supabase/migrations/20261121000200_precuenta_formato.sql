-- =============================================================================
-- Sistema La Merced · La precuenta ("Pedir la cuenta" / "Imprimir cuenta") con
-- el mismo formato del ticket estilo tienda: datos del negocio, folio, fecha y
-- hora, mesa, CANT / DESCRIPCION / IMPORTE, total, importe con letra y
-- "Este no es un comprobante fiscal".
-- =============================================================================
create or replace function privado.contenido_precuenta(p_cuenta_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'documento', 'precuenta',
    'formato',   2,
    'negocio',   coalesce(s.nombre_comercial, s.nombre),
    'direccion', s.direccion,
    'telefonos', s.telefonos,
    'destino',   privado.nombre_cuenta(k),
    'para_llevar', k.tipo = 'llevar',
    'folio',     k.folio,
    'fecha',     to_char(now() at time zone s.zona_horaria, 'DD/MM/YYYY'),
    'hora',      to_char(now() at time zone s.zona_horaria, 'HH12:MI:SS AM'),
    'lineas', coalesce((select jsonb_agg(jsonb_build_object(
                 'cantidad', l.cantidad, 'producto', l.nombre_producto, 'opcion', null,
                 'precio_unitario', l.precio_unitario, 'importe', l.precio_unitario * l.cantidad) order by l.creado_en, l.nombre_producto)
               from public.lineas_cuenta l where l.cuenta_id = k.id and l.estado = 'activa'), '[]'::jsonb),
    'extras', coalesce((select jsonb_agg(jsonb_build_object('concepto', x.concepto, 'importe', x.importe) order by x.creado_en)
               from public.cobros_extra x where x.cuenta_id = k.id and x.estado = 'activa'), '[]'::jsonb),
    'total',     privado.total_cuenta(k.id),
    'total_letra', privado.importe_con_letra(privado.total_cuenta(k.id)),
    'leyenda',   s.leyenda_ticket)
  from public.cuentas k join public.sucursales s on s.id = k.sucursal_id
  where k.id = p_cuenta_id
$$;
