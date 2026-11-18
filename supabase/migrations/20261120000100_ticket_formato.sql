-- =============================================================================
-- Sistema La Merced · Ticket con formato de tienda y sin aviso de cancelación
--
--   * Ticket de cobro: datos del negocio (dirección y teléfonos del menú),
--     folio, fecha y hora con segundos, mesa o "para llevar", tabla con
--     cantidad / descripción / importe, total, importe con letra y
--     "Este no es un comprobante fiscal".
--   * Quitar un producto que ya se mandó a cocina ya no imprime un aviso de
--     cancelación. Queda registrado en la cuenta y en la auditoría como siempre.
-- =============================================================================

-- Importe con letra: 276 → "DOSCIENTOS SETENTA Y SEIS PESOS 00/100 M.N."
create function privado.letras_cientos(p integer) returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  u text[] := array['UNO','DOS','TRES','CUATRO','CINCO','SEIS','SIETE','OCHO','NUEVE'];
  e text[] := array['DIEZ','ONCE','DOCE','TRECE','CATORCE','QUINCE','DIECISÉIS','DIECISIETE','DIECIOCHO','DIECINUEVE',
                    'VEINTE','VEINTIUNO','VEINTIDÓS','VEINTITRÉS','VEINTICUATRO','VEINTICINCO','VEINTISÉIS','VEINTISIETE',
                    'VEINTIOCHO','VEINTINUEVE'];
  d text[] := array['TREINTA','CUARENTA','CINCUENTA','SESENTA','SETENTA','OCHENTA','NOVENTA'];
  c text[] := array['CIENTO','DOSCIENTOS','TRESCIENTOS','CUATROCIENTOS','QUINIENTOS','SEISCIENTOS','SETECIENTOS',
                    'OCHOCIENTOS','NOVECIENTOS'];
  v_c integer := p / 100;
  v_r integer := p % 100;
  v text := '';
begin
  if p = 100 then return 'CIEN'; end if;
  if v_c > 0 then v := c[v_c]; end if;
  if v_r > 0 then
    v := v || case when v = '' then '' else ' ' end ||
         case when v_r < 10 then u[v_r]
              when v_r < 30 then e[v_r - 9]
              else d[v_r / 10 - 2] || case when v_r % 10 > 0 then ' Y ' || u[v_r % 10] else '' end end;
  end if;
  return v;
end
$$;

create function privado.importe_con_letra(p numeric) returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v_entero bigint := floor(coalesce(p, 0));
  v_centavos integer := round((coalesce(p, 0) - floor(coalesce(p, 0))) * 100);
  v_millones integer;
  v_miles integer;
  v_resto integer;
  v text := '';
begin
  if v_centavos = 100 then v_entero := v_entero + 1; v_centavos := 0; end if;
  v_millones := (v_entero / 1000000)::integer;
  v_miles := ((v_entero / 1000) % 1000)::integer;
  v_resto := (v_entero % 1000)::integer;
  if v_millones > 0 then
    v := case when v_millones = 1 then 'UN MILLÓN'
              else regexp_replace(privado.letras_cientos(v_millones), 'UNO$', 'UN') || ' MILLONES' end;
  end if;
  if v_miles > 0 then
    v := v || case when v = '' then '' else ' ' end ||
         case when v_miles = 1 then 'MIL' else regexp_replace(privado.letras_cientos(v_miles), 'UNO$', 'ÚN') || ' MIL' end;
    v := regexp_replace(v, '([^I])ÚN MIL', '\1UN MIL');
  end if;
  if v_resto > 0 then
    v := v || case when v = '' then '' else ' ' end || privado.letras_cientos(v_resto);
  end if;
  if v = '' then v := 'CERO'; end if;
  v := regexp_replace(regexp_replace(v, 'VEINTIUNO$', 'VEINTIÚN'), 'UNO$', 'UN');
  return v
    || case when v_entero = 1 then ' PESO'
            when v_millones > 0 and v_miles = 0 and v_resto = 0 then ' DE PESOS'
            else ' PESOS' end
    || ' ' || lpad(v_centavos::text, 2, '0') || '/100 M.N.';
end
$$;

create or replace function privado.contenido_ticket(p_cuenta_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'documento', 'ticket',
    'formato',   2,
    'negocio',   coalesce(s.nombre_comercial, s.nombre),
    'direccion', s.direccion,
    'telefonos', s.telefonos,
    'leyenda',   s.leyenda_ticket,
    'folio',     k.folio,
    'para_llevar', k.tipo = 'llevar',
    'destino',   case when k.tipo = 'llevar' then 'Para llevar' else privado.nombre_grupo(k.mesa_id) end,
    'fecha',     to_char(coalesce(k.cobrada_en, now()) at time zone s.zona_horaria, 'DD/MM/YYYY'),
    'hora',      to_char(coalesce(k.cobrada_en, now()) at time zone s.zona_horaria, 'HH12:MI:SS AM'),
    'lineas', coalesce((select jsonb_agg(jsonb_build_object(
                 'cantidad', l.cantidad, 'producto', l.nombre_producto, 'opcion', null,
                 'precio_unitario', l.precio_unitario, 'importe', l.precio_unitario * l.cantidad) order by l.creado_en, l.nombre_producto)
               from public.lineas_cuenta l where l.cuenta_id = k.id and l.estado = 'activa'), '[]'::jsonb),
    'extras', coalesce((select jsonb_agg(jsonb_build_object('concepto', x.concepto, 'importe', x.importe) order by x.creado_en)
               from public.cobros_extra x where x.cuenta_id = k.id and x.estado = 'activa'), '[]'::jsonb),
    'total',     k.total,
    'total_letra', privado.importe_con_letra(k.total),
    'recibido', (select p.recibido from public.pagos p
                 where p.cuenta_id = k.id and p.estado = 'vigente' and p.metodo = 'efectivo' order by p.creado_en desc limit 1),
    'cambio',   (select p.cambio from public.pagos p
                 where p.cuenta_id = k.id and p.estado = 'vigente' and p.metodo = 'efectivo' order by p.creado_en desc limit 1))
  from public.cuentas k join public.sucursales s on s.id = k.sucursal_id
  where k.id = p_cuenta_id
$$;

revoke execute on function privado.letras_cientos(integer), privado.importe_con_letra(numeric) from public, anon, authenticated;

-- Quitar producto: ahora también el mesero en pedidos para llevar.
create or replace function public.quitar_producto(p_linea_id uuid, p_motivo text, p_cantidad integer default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario', 'mesero', 'cajero');
  v_linea public.lineas_cuenta;
  v_cuenta public.cuentas;
  v_qty integer;
  v_comanda uuid;
begin
  if coalesce(length(trim(p_motivo)), 0) = 0 then
    raise exception 'Escribe el motivo para quitar el producto';
  end if;
  select * into v_linea from public.lineas_cuenta where id = p_linea_id;
  if not found then
    raise exception 'El producto no existe';
  end if;
  -- Mismo orden de bloqueo que enviar_pedido: primero la mesa, después la cuenta.
  perform privado.bloquear_grupo((select c.mesa_id from public.cuentas c where c.id = v_linea.cuenta_id));
  select * into v_cuenta from public.cuentas where id = v_linea.cuenta_id for update;
  select * into v_linea from public.lineas_cuenta where id = p_linea_id for update;

  if v_cuenta.estado = 'cobrada' then
    raise exception 'La cuenta ya está cobrada: quitar un producto requiere la autorización de los propietarios'
      using errcode = '42501';
  end if;
  if v_cuenta.estado <> 'abierta' and v_cuenta.estado <> 'por_cobrar' then
    raise exception 'La cuenta no está abierta';
  end if;
  if v_linea.estado <> 'activa' then
    raise exception 'El producto ya estaba quitado';
  end if;
  v_qty := coalesce(p_cantidad, v_linea.cantidad);
  if v_qty < 1 or v_qty > v_linea.cantidad then
    raise exception 'Cantidad inválida';
  end if;

  perform privado.fijar_accion(
    format('Quitó %s × %s de %s', v_qty, v_linea.nombre_producto || coalesce(' · ' || v_linea.opcion, ''),
           coalesce(privado.nombre_grupo(v_cuenta.mesa_id), 'el pedido para llevar ' || v_cuenta.folio)),
    p_motivo);

  update public.lineas_cuenta
     set estado = 'cancelada', cancelada_en = now(), cancelada_por = v_actor, cancelacion_motivo = trim(p_motivo)
   where id = v_linea.id;

  -- Lo que queda sigue en la cuenta como una línea que reemplaza a la anterior.
  if v_qty < v_linea.cantidad then
    insert into public.lineas_cuenta (sucursal_id, cuenta_id, producto_id, nombre_producto, precio_unitario, tasa_iva,
                                      cantidad, observacion, opcion, enviada_en, reemplaza_linea_id, creado_por)
    values (v_linea.sucursal_id, v_linea.cuenta_id, v_linea.producto_id, v_linea.nombre_producto,
            v_linea.precio_unitario, v_linea.tasa_iva, v_linea.cantidad - v_qty, v_linea.observacion, v_linea.opcion,
            v_linea.enviada_en, v_linea.id, v_linea.creado_por);
  end if;
  -- Ya no se imprime aviso de cancelación para cocina.
end
$$;
