-- =============================================================================
-- Sistema La Merced · Etapa 5 · Caja y pagos
--
--   * Pedidos para llevar: los capturan meseros, caja y propietarios; se
--     envían a cocina con la leyenda PARA LLEVAR. Solo caja cobra.
--   * Abrir caja, entradas y retiros de efectivo con motivo.
--   * Cobrar: efectivo, tarjeta, transferencia o combinado; la suma debe
--     igualar el total. Efectivo recibido y cambio. Propina aparte (no es venta
--     y se entrega a los meseros: no cuenta en el efectivo de la caja).
--   * Cobros extra con comentario obligatorio.
--   * Ticket de cobro para la impresora de caja (58 mm).
--   * Devolución al cliente cuando se autoriza quitar un concepto cobrado.
--   * Corte de caja (uno al día): esperado, contado y diferencia; el
--     propietario lo aprueba y solo un propietario lo reabre.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Datos del negocio para el ticket
-- -----------------------------------------------------------------------------
alter table public.sucursales
  add column nombre_comercial text,
  add column direccion text,
  add column telefonos text,
  add column leyenda_ticket text;

do $$
begin
  perform privado.fijar_accion('Instalación: datos del negocio para el ticket');
  update public.sucursales
     set nombre_comercial = 'Cenaduría La Merced',
         direccion = 'Av. Fundición 2103, San Cayetano, 20010 Aguascalientes, Ags.',
         telefonos = '449 940 44 90 / 449 181 31 21',
         leyenda_ticket = '¡Gracias por su visita!'
   where id = '00000000-0000-0000-0000-000000000001';
  perform privado.fijar_accion(null);
end
$$;

-- -----------------------------------------------------------------------------
-- Columnas nuevas
-- -----------------------------------------------------------------------------
-- Efectivo: con cuánto pagó el cliente y cuánto cambio se le dio.
alter table public.pagos
  add column recibido numeric(12, 2),
  add column cambio numeric(12, 2),
  add constraint pagos_efectivo check (
    (recibido is null and cambio is null) or (metodo = 'efectivo' and recibido >= importe and cambio >= 0));
create trigger pagos_inmutable_efectivo before update on public.pagos for each row
  execute function privado.proteger_columnas('recibido', 'cambio');

-- Identificador del cobro que manda la caja: tocar "Cobrar" dos veces no cobra dos veces.
alter table public.cuentas add column cobro_solicitud_id uuid;

-- Cómo se le devuelve el dinero al cliente al quitar un concepto ya cobrado.
alter table public.autorizaciones add column metodo_devolucion public.metodo_pago;
create trigger autorizaciones_inmutable_devolucion before update on public.autorizaciones for each row
  execute function privado.proteger_columnas('metodo_devolucion');

-- -----------------------------------------------------------------------------
-- Devoluciones al cliente (siempre con autorización de los propietarios)
-- -----------------------------------------------------------------------------
create table public.devoluciones (
  id               uuid primary key default gen_random_uuid(),
  sucursal_id      uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  cuenta_id        uuid not null references public.cuentas (id),
  linea_id         uuid references public.lineas_cuenta (id),
  cobro_extra_id   uuid references public.cobros_extra (id),
  metodo           public.metodo_pago not null,
  importe          numeric(12, 2) not null check (importe > 0),
  turno_id         uuid references public.turnos_caja (id),
  autorizacion_id  uuid not null references public.autorizaciones (id),
  creado_en        timestamptz not null default now(),
  creado_por       uuid references public.usuarios (id) default privado.actor(),
  constraint devoluciones_concepto check (num_nonnulls(linea_id, cobro_extra_id) = 1),
  constraint devoluciones_efectivo_en_turno check (metodo <> 'efectivo' or turno_id is not null)
);
create index devoluciones_turno_idx on public.devoluciones (turno_id);
create trigger devoluciones_sin_cambios before update on public.devoluciones
  for each row execute function privado.prohibir_cambio();
create trigger devoluciones_sin_borrado before delete on public.devoluciones
  for each row execute function privado.prohibir_borrado();
create trigger devoluciones_sin_vaciar before truncate on public.devoluciones
  for each statement execute function privado.prohibir_borrado();
create trigger devoluciones_auditar after insert on public.devoluciones
  for each row execute function privado.auditar_cambios();

-- -----------------------------------------------------------------------------
-- Ayudantes
-- -----------------------------------------------------------------------------
create function privado.turno_abierto(p_sucursal_id uuid) returns public.turnos_caja
language sql stable
set search_path = ''
as $$
  select t.* from public.turnos_caja t where t.sucursal_id = p_sucursal_id and t.estado = 'abierto'
$$;

create function privado.sucursal_del_actor() returns uuid
language sql stable
set search_path = ''
as $$
  select coalesce((select u.sucursal_id from public.usuarios u where u.id = privado.actor()),
                  '00000000-0000-0000-0000-000000000001'::uuid)
$$;

-- Total vigente de una cuenta: productos activos más cobros extra activos.
create function privado.total_cuenta(p_cuenta_id uuid) returns numeric
language sql stable
set search_path = ''
as $$
  select coalesce((select sum(l.precio_unitario * l.cantidad) from public.lineas_cuenta l
                   where l.cuenta_id = p_cuenta_id and l.estado = 'activa'), 0)
       + coalesce((select sum(x.importe) from public.cobros_extra x
                   where x.cuenta_id = p_cuenta_id and x.estado = 'activa'), 0)
$$;

create function privado.nombre_cuenta(p_cuenta public.cuentas) returns text
language sql stable
set search_path = ''
as $$
  select case when p_cuenta.tipo = 'llevar' then 'Para llevar #' || p_cuenta.folio
              else coalesce(privado.nombre_grupo(privado.mesa_principal(p_cuenta.mesa_id)), 'Mesa') end
$$;

-- -----------------------------------------------------------------------------
-- Envío a cocina (común para mesas y para llevar)
-- -----------------------------------------------------------------------------
create function privado.registrar_envio(p_cuenta public.cuentas, p_productos jsonb, p_solicitud_id uuid, p_destino text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_comanda public.comandas;
  v_item record;
  v_prod public.productos;
  v_linea uuid;
  v_n integer := 0;
  v_lista text[];
  v_eleccion text;
begin
  perform privado.fijar_accion(
    case when exists (select 1 from public.comandas c where c.cuenta_id = p_cuenta.id and c.tipo in ('nueva', 'adicional'))
         then 'Envió un pedido adicional de ' else 'Envió el pedido de ' end || p_destino);
  insert into public.comandas (sucursal_id, cuenta_id, numero, tipo, solicitud_id)
  select p_cuenta.sucursal_id, p_cuenta.id, coalesce(max(c.numero), 0) + 1,
         case when count(c.id) filter (where c.tipo in ('nueva', 'adicional')) = 0 then 'nueva' else 'adicional' end::public.tipo_comanda,
         p_solicitud_id
  from public.comandas c where c.cuenta_id = p_cuenta.id
  returning * into v_comanda;

  for v_item in
    select * from jsonb_to_recordset(p_productos) as x(producto_id uuid, cantidad integer, observacion text, opcion text, opciones text[])
  loop
    if v_item.cantidad is null or v_item.cantidad < 1 or v_item.cantidad > 99 then
      raise exception 'Cantidad inválida';
    end if;
    if length(v_item.observacion) > 200 then
      raise exception 'La observación es muy larga (máximo 200 letras)';
    end if;
    select p.* into v_prod from public.productos p
    join public.categorias k on k.id = p.categoria_id
    where p.id = v_item.producto_id and p.eliminado_en is null and k.activa and k.eliminada_en is null;
    if not found or v_prod.estado = 'inactivo' then
      raise exception 'Un producto del pedido ya no está en el menú';
    end if;
    if v_prod.estado = 'agotado' then
      raise exception '% está agotado', v_prod.nombre;
    end if;
    -- Lo elegido: una opción por cada selección del producto, en orden.
    v_lista := coalesce(v_item.opciones, case when v_item.opcion is not null then array[v_item.opcion] end);
    v_eleccion := privado.texto_selecciones(v_prod, v_lista);

    insert into public.lineas_cuenta (sucursal_id, cuenta_id, producto_id, nombre_producto, precio_unitario,
                                      tasa_iva, cantidad, observacion, opcion, enviada_en)
    values (p_cuenta.sucursal_id, p_cuenta.id, v_prod.id, v_prod.nombre, v_prod.precio, v_prod.tasa_iva,
            v_item.cantidad, nullif(trim(v_item.observacion), ''), v_eleccion, now())
    returning id into v_linea;
    insert into public.comanda_lineas (sucursal_id, comanda_id, linea_id, cantidad)
    values (p_cuenta.sucursal_id, v_comanda.id, v_linea, v_item.cantidad);
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('cuenta_id', p_cuenta.id, 'folio', p_cuenta.folio, 'comanda_id', v_comanda.id,
                            'numero', v_comanda.numero, 'productos', v_n, 'repetido', false);
end
$$;

-- Pedidos de mesa: misma lógica, usando el registro común.
create or replace function public.enviar_pedido(p_mesa_id uuid, p_productos jsonb, p_solicitud_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario', 'mesero');
  v_mesa public.mesas;
  v_cuenta public.cuentas;
  v_repetido jsonb;
  v_res jsonb;
begin
  if p_solicitud_id is null then
    raise exception 'Falta el identificador de la solicitud';
  end if;
  if p_productos is null or jsonb_typeof(p_productos) <> 'array' or jsonb_array_length(p_productos) = 0 then
    raise exception 'El pedido no tiene productos';
  end if;

  v_mesa := privado.bloquear_mesa(p_mesa_id);

  -- Reintento del mismo envío: se devuelve lo ya registrado. Se busca después
  -- de bloquear la mesa, así dos envíos simultáneos idénticos no chocan.
  -- Un identificador usado en otra mesa se rechaza: nunca se descarta en
  -- silencio un pedido ni se devuelven datos de otra cuenta.
  v_repetido := privado.envio_previo(p_solicitud_id, v_mesa.id);
  if v_repetido is not null then
    return v_repetido;
  end if;
  v_cuenta := privado.cuenta_de_mesa(v_mesa.id);
  if v_cuenta.estado = 'por_cobrar' then
    raise exception 'Ya se pidió la cuenta de %; ya no se agregan productos', privado.nombre_grupo(v_mesa.id);
  end if;

  if v_cuenta.id is null then
    perform privado.fijar_accion('Abrió la cuenta de ' || privado.nombre_grupo(v_mesa.id));
    insert into public.cuentas (sucursal_id, tipo, mesa_id, mesero_id)
    values (v_mesa.sucursal_id, 'mesa', v_mesa.id, v_actor)
    returning * into v_cuenta;
  end if;

  v_res := privado.registrar_envio(v_cuenta, p_productos, p_solicitud_id, privado.nombre_grupo(v_mesa.id));
  perform privado.fijar_estado_grupo(v_mesa.id, 'pedido_enviado');
  return v_res;
end
$$;


-- Pedidos para llevar. Sin cuenta: crea el pedido (folio nuevo). Con cuenta:
-- agrega una comanda adicional. Reintentos con la misma solicitud no duplican.
create function public.enviar_pedido_llevar(p_cuenta_id uuid, p_productos jsonb, p_solicitud_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario', 'cajero', 'mesero');
  v_cuenta public.cuentas;
  v_previa public.comandas;
begin
  if p_solicitud_id is null then
    raise exception 'Falta el identificador de la solicitud';
  end if;
  if p_productos is null or jsonb_typeof(p_productos) <> 'array' or jsonb_array_length(p_productos) = 0 then
    raise exception 'El pedido no tiene productos';
  end if;

  if p_cuenta_id is not null then
    select * into v_cuenta from public.cuentas where id = p_cuenta_id for update;
    if not found or v_cuenta.tipo <> 'llevar' then
      raise exception 'El pedido para llevar no existe';
    end if;
  end if;

  select * into v_previa from public.comandas where solicitud_id = p_solicitud_id;
  if found then
    if exists (select 1 from public.cuentas c where c.id = v_previa.cuenta_id and c.tipo = 'llevar'
               and (p_cuenta_id is null or c.id = p_cuenta_id)) then
      return jsonb_build_object('cuenta_id', v_previa.cuenta_id, 'comanda_id', v_previa.id, 'numero', v_previa.numero,
                                'folio', (select c.folio from public.cuentas c where c.id = v_previa.cuenta_id), 'repetido', true);
    end if;
    raise exception 'Este envío ya se usó en otro pedido. Vuelve a enviar el pedido.';
  end if;

  if v_cuenta.id is null then
    perform privado.fijar_accion('Abrió un pedido para llevar');
    insert into public.cuentas (sucursal_id, tipo, mesero_id)
    values (privado.sucursal_del_actor(), 'llevar', case when privado.perfil_actual() = 'mesero' then v_actor end)
    returning * into v_cuenta;
  elsif v_cuenta.estado <> 'abierta' then
    raise exception 'El pedido para llevar #% ya no admite productos', v_cuenta.folio;
  end if;

  return privado.registrar_envio(v_cuenta, p_productos, p_solicitud_id, 'Para llevar #' || v_cuenta.folio);
end
$$;

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

  -- Si cocina ya lo había recibido, se le avisa con CANCELADO.
  if v_linea.enviada_en is not null then
    insert into public.comandas (sucursal_id, cuenta_id, numero, tipo)
    select v_cuenta.sucursal_id, v_cuenta.id, coalesce(max(c.numero), 0) + 1, 'cancelacion'
    from public.comandas c where c.cuenta_id = v_cuenta.id
    returning id into v_comanda;
    insert into public.comanda_lineas (sucursal_id, comanda_id, linea_id, cantidad, leyenda)
    values (v_cuenta.sucursal_id, v_comanda, v_linea.id, v_qty, 'CANCELADO');
  end if;
end
$$;


-- Reimprimir comanda: el mesero también en pedidos para llevar abiertos.
create or replace function public.reimprimir_comanda(p_comanda_id uuid) returns public.trabajos_impresion
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario', 'cajero', 'mesero');
  v_original public.trabajos_impresion;
  v_fila public.trabajos_impresion;
begin
  select * into v_original from public.trabajos_impresion
   where comanda_id = p_comanda_id and reimpresion_de is null;
  if not found then
    raise exception 'La comanda no existe';
  end if;
  -- El mesero solo reimprime comandas de cuentas abiertas (de mesa o para llevar).
  if privado.perfil_actual() = 'mesero' and not exists (
       select 1 from public.cuentas c
       where c.id = v_original.cuenta_id and c.estado in ('abierta', 'por_cobrar')) then
    raise exception 'La comanda no existe';
  end if;
  if v_original.estado <> 'impreso' then
    raise exception 'La comanda aún no se imprime; si falló, usa Reintentar';
  end if;
  perform privado.fijar_accion('Reimprimió la comanda ' || (v_original.contenido ->> 'numero')
                               || ' de ' || (v_original.contenido ->> 'destino'));
  insert into public.trabajos_impresion (sucursal_id, documento, impresora, comanda_id, cuenta_id, contenido, reimpresion_de, creado_por)
  values (v_original.sucursal_id, 'comanda', 'cocina', v_original.comanda_id, v_original.cuenta_id,
          v_original.contenido || jsonb_build_object('reimpresion', true,
            'hora_reimpresion', to_char(now() at time zone 'America/Mexico_City', 'HH24:MI'),
            'reimprimio', (select u.nombre from public.usuarios u where u.id = v_actor)),
          v_original.id, v_actor)
  returning * into v_fila;
  return v_fila;
end
$$;


-- -----------------------------------------------------------------------------
-- Caja
-- -----------------------------------------------------------------------------
create function public.abrir_caja(p_fondo numeric) returns public.turnos_caja
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario', 'cajero');
  v_fila public.turnos_caja;
begin
  if p_fondo is null or p_fondo < 0 then
    raise exception 'Escribe el fondo inicial';
  end if;
  if (privado.turno_abierto(privado.sucursal_del_actor())).id is not null then
    raise exception 'La caja ya está abierta';
  end if;
  perform privado.fijar_accion('Abrió la caja con un fondo de $' || p_fondo);
  insert into public.turnos_caja (sucursal_id, cajero_id, fondo_inicial)
  values (privado.sucursal_del_actor(), v_actor, p_fondo)
  returning * into v_fila;
  return v_fila;
end
$$;

create function public.registrar_movimiento(p_tipo public.tipo_movimiento, p_importe numeric, p_motivo text)
returns public.movimientos_efectivo
language plpgsql security definer
set search_path = ''
as $$
declare
  v_turno public.turnos_caja;
  v_fila public.movimientos_efectivo;
begin
  perform privado.exigir_perfil('propietario', 'cajero');
  if coalesce(length(trim(p_motivo)), 0) = 0 then
    raise exception 'Escribe el motivo del movimiento';
  end if;
  if p_importe is null or p_importe <= 0 then
    raise exception 'Escribe el importe';
  end if;
  select * into v_turno from public.turnos_caja
   where sucursal_id = privado.sucursal_del_actor() and estado = 'abierto' for update;
  if not found then
    raise exception 'Abre la caja primero';
  end if;
  perform privado.fijar_accion(case p_tipo when 'entrada' then 'Registró una entrada de efectivo de $'
                                            else 'Registró un retiro de efectivo de $' end || p_importe, p_motivo);
  insert into public.movimientos_efectivo (sucursal_id, turno_id, tipo, importe, motivo)
  values (v_turno.sucursal_id, v_turno.id, p_tipo, p_importe, trim(p_motivo))
  returning * into v_fila;
  return v_fila;
end
$$;

-- Cobro extra: algo que se cobra fuera del menú, con comentario obligatorio.
create function public.agregar_cobro_extra(p_cuenta_id uuid, p_concepto text, p_importe numeric)
returns public.cobros_extra
language plpgsql security definer
set search_path = ''
as $$
declare
  v_cuenta public.cuentas;
  v_fila public.cobros_extra;
begin
  perform privado.exigir_perfil('propietario', 'cajero');
  if coalesce(length(trim(p_concepto)), 0) = 0 then
    raise exception 'Escribe qué se cobra';
  end if;
  if length(trim(p_concepto)) > 120 then
    raise exception 'El comentario es muy largo (máximo 120 letras)';
  end if;
  if p_importe is null or p_importe <= 0 or p_importe > 100000 then
    raise exception 'Escribe un monto válido';
  end if;
  perform privado.bloquear_grupo((select c.mesa_id from public.cuentas c where c.id = p_cuenta_id));
  select * into v_cuenta from public.cuentas where id = p_cuenta_id for update;
  if not found or v_cuenta.estado not in ('abierta', 'por_cobrar') then
    raise exception 'La cuenta no está abierta';
  end if;
  perform privado.fijar_accion(format('Agregó un cobro extra de $%s a %s: %s', p_importe, privado.nombre_cuenta(v_cuenta), trim(p_concepto)));
  insert into public.cobros_extra (sucursal_id, cuenta_id, concepto, importe)
  values (v_cuenta.sucursal_id, v_cuenta.id, trim(p_concepto), p_importe)
  returning * into v_fila;
  return v_fila;
end
$$;

create function public.quitar_cobro_extra(p_cobro_extra_id uuid, p_motivo text) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario', 'cajero');
  v_extra public.cobros_extra;
  v_cuenta public.cuentas;
begin
  if coalesce(length(trim(p_motivo)), 0) = 0 then
    raise exception 'Escribe el motivo';
  end if;
  select * into v_extra from public.cobros_extra where id = p_cobro_extra_id;
  if not found then
    raise exception 'El cobro extra no existe';
  end if;
  perform privado.bloquear_grupo((select c.mesa_id from public.cuentas c where c.id = v_extra.cuenta_id));
  select * into v_cuenta from public.cuentas where id = v_extra.cuenta_id for update;
  if v_cuenta.estado = 'cobrada' then
    raise exception 'La cuenta ya está cobrada: quitarlo requiere la autorización de los propietarios' using errcode = '42501';
  end if;
  if v_cuenta.estado not in ('abierta', 'por_cobrar') then
    raise exception 'La cuenta no está abierta';
  end if;
  perform privado.fijar_accion(format('Quitó el cobro extra "%s" de %s', v_extra.concepto, privado.nombre_cuenta(v_cuenta)), p_motivo);
  update public.cobros_extra
     set estado = 'cancelada', cancelada_en = now(), cancelada_por = v_actor, cancelacion_motivo = trim(p_motivo)
   where id = p_cobro_extra_id and estado = 'activa';
end
$$;

-- -----------------------------------------------------------------------------
-- Ticket
-- -----------------------------------------------------------------------------
create function privado.contenido_ticket(p_cuenta_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'documento', 'ticket',
    'negocio',   coalesce(s.nombre_comercial, s.nombre),
    'direccion', s.direccion,
    'telefonos', s.telefonos,
    'leyenda',   s.leyenda_ticket,
    'folio',     k.folio,
    'destino',   case when k.tipo = 'llevar' then 'Para llevar' else privado.nombre_cuenta(k) end,
    'para_llevar', k.tipo = 'llevar',
    'mesero',    (select u.nombre from public.usuarios u where u.id = k.mesero_id),
    'cajero',    (select u.nombre from public.usuarios u where u.id = k.cajero_id),
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

-- -----------------------------------------------------------------------------
-- Cobrar
-- p_pagos: [{"metodo": "efectivo", "importe": 300, "recibido": 500}, {"metodo": "tarjeta", "importe": 200}]
-- -----------------------------------------------------------------------------
create function public.cobrar_cuenta(
  p_cuenta_id uuid, p_pagos jsonb, p_solicitud_id uuid,
  p_propina numeric default 0, p_propina_metodo public.metodo_pago default null
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario', 'cajero');
  v_cuenta public.cuentas;
  v_turno public.turnos_caja;
  v_total numeric;
  v_suma numeric;
  v_subtotal numeric;
  v_pago record;
  v_cambio numeric := 0;
  v_principal uuid;
  v_miembros uuid[];
  v_ticket uuid;
begin
  if p_solicitud_id is null then
    raise exception 'Falta el identificador del cobro';
  end if;

  perform privado.bloquear_grupo((select c.mesa_id from public.cuentas c where c.id = p_cuenta_id));
  select * into v_cuenta from public.cuentas where id = p_cuenta_id for update;
  if not found then
    raise exception 'La cuenta no existe';
  end if;
  if v_cuenta.estado = 'cobrada' then
    if v_cuenta.cobro_solicitud_id = p_solicitud_id then
      return jsonb_build_object('cuenta_id', v_cuenta.id, 'folio', v_cuenta.folio, 'total', v_cuenta.total, 'repetido', true);
    end if;
    raise exception 'La cuenta ya está cobrada';
  end if;
  if v_cuenta.estado = 'cancelada' then
    raise exception 'La cuenta está cancelada';
  end if;
  if v_cuenta.tipo = 'mesa' and v_cuenta.estado <> 'por_cobrar' then
    raise exception 'El mesero aún no pide la cuenta de %', privado.nombre_cuenta(v_cuenta);
  end if;

  select * into v_turno from public.turnos_caja
   where sucursal_id = v_cuenta.sucursal_id and estado = 'abierto' for update;
  if not found then
    raise exception 'Abre la caja antes de cobrar';
  end if;

  v_total := privado.total_cuenta(v_cuenta.id);
  if v_total <= 0 then
    raise exception 'La cuenta no tiene productos';
  end if;

  if p_pagos is null or jsonb_typeof(p_pagos) <> 'array' or jsonb_array_length(p_pagos) = 0 then
    raise exception 'Agrega al menos un pago';
  end if;
  if (select count(*) from jsonb_array_elements(p_pagos)) <> (select count(distinct x ->> 'metodo') from jsonb_array_elements(p_pagos) x) then
    raise exception 'Junta en una sola línea los pagos del mismo método';
  end if;
  if exists (select 1 from jsonb_to_recordset(p_pagos) as x(metodo text, importe numeric)
             where x.importe is null or x.importe <= 0 or x.metodo is null
                or x.metodo not in ('efectivo', 'tarjeta', 'transferencia')) then
    raise exception 'Revisa los pagos: cada uno necesita método e importe';
  end if;
  select sum(x.importe) into v_suma from jsonb_to_recordset(p_pagos) as x(importe numeric);
  if round(v_suma, 2) <> round(v_total, 2) then
    raise exception 'Los pagos suman $% y la cuenta es de $%', round(v_suma, 2), round(v_total, 2);
  end if;

  p_propina := coalesce(p_propina, 0);
  if p_propina < 0 then
    raise exception 'La propina no puede ser negativa';
  end if;
  if p_propina > 0 and (p_propina_metodo is null or p_propina_metodo = 'transferencia') then
    raise exception 'Indica si la propina fue con tarjeta o en efectivo';
  end if;

  perform privado.fijar_accion(format('Cobró %s (folio %s): $%s', privado.nombre_cuenta(v_cuenta), v_cuenta.folio, v_total));

  for v_pago in select * from jsonb_to_recordset(p_pagos) as x(metodo public.metodo_pago, importe numeric, recibido numeric)
  loop
    if v_pago.metodo = 'efectivo' and v_pago.recibido is not null then
      -- La propina en efectivo puede venir incluida en lo que entregó el cliente.
      v_cambio := v_pago.recibido - v_pago.importe - case when p_propina_metodo = 'efectivo' then p_propina else 0 end;
      if v_cambio < 0 then
        raise exception 'El efectivo recibido no alcanza: faltan $%', -v_cambio;
      end if;
      insert into public.pagos (sucursal_id, cuenta_id, turno_id, metodo, importe, recibido, cambio)
      values (v_cuenta.sucursal_id, v_cuenta.id, v_turno.id, 'efectivo', v_pago.importe, v_pago.recibido, v_cambio);
    else
      insert into public.pagos (sucursal_id, cuenta_id, turno_id, metodo, importe)
      values (v_cuenta.sucursal_id, v_cuenta.id, v_turno.id, v_pago.metodo, v_pago.importe);
    end if;
  end loop;

  if p_propina > 0 then
    insert into public.propinas (sucursal_id, cuenta_id, turno_id, metodo, importe)
    values (v_cuenta.sucursal_id, v_cuenta.id, v_turno.id, p_propina_metodo, p_propina);
  end if;

  -- Desglose para facturar en el futuro: los precios incluyen IVA.
  select coalesce(sum(round(l.precio_unitario * l.cantidad / (1 + l.tasa_iva), 2)), 0) into v_subtotal
    from public.lineas_cuenta l where l.cuenta_id = v_cuenta.id and l.estado = 'activa';
  v_subtotal := v_subtotal + coalesce((select sum(round(x.importe / (1 + x.tasa_iva), 2)) from public.cobros_extra x
                                       where x.cuenta_id = v_cuenta.id and x.estado = 'activa'), 0);

  update public.cuentas
     set estado = 'cobrada', cobrada_en = now(), cajero_id = v_actor, turno_id = v_turno.id,
         subtotal = v_subtotal, impuestos = v_total - v_subtotal, total = v_total, cobro_solicitud_id = p_solicitud_id
   where id = v_cuenta.id
  returning * into v_cuenta;

  -- La mesa (y las unidas a ella) queda libre y separada. Una cuenta con el
  -- cobro anulado ya no ocupaba la mesa: no se toca.
  if v_cuenta.mesa_id is not null and v_cuenta.cobro_anulado_en is null then
    v_principal := privado.mesa_principal(v_cuenta.mesa_id);
    select array_agg(id order by id <> v_principal, orden) into v_miembros
      from public.mesas where id = v_principal or unida_a = v_principal;
    update public.mesas set estado = 'disponible', unida_a = null where id = any (v_miembros);
    if cardinality(v_miembros) > 1 then
      insert into public.uniones_mesas (sucursal_id, operacion, mesa_ids, cuenta_id)
      values (v_cuenta.sucursal_id, 'separacion', v_miembros, v_cuenta.id);
    end if;
  end if;

  insert into public.trabajos_impresion (sucursal_id, documento, impresora, cuenta_id, turno_id, contenido)
  values (v_cuenta.sucursal_id, 'ticket', 'caja', v_cuenta.id, v_turno.id, privado.contenido_ticket(v_cuenta.id))
  returning id into v_ticket;

  return jsonb_build_object('cuenta_id', v_cuenta.id, 'folio', v_cuenta.folio, 'total', v_total,
                            'cambio', v_cambio, 'ticket_id', v_ticket, 'repetido', false);
end
$$;

create function public.reimprimir_ticket(p_cuenta_id uuid) returns public.trabajos_impresion
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario', 'cajero');
  v_original public.trabajos_impresion;
  v_fila public.trabajos_impresion;
begin
  select * into v_original from public.trabajos_impresion
   where cuenta_id = p_cuenta_id and documento = 'ticket' and reimpresion_de is null
   order by creado_en desc limit 1;
  if not found then
    raise exception 'La cuenta no tiene ticket';
  end if;
  perform privado.fijar_accion('Reimprimió el ticket del folio ' || (v_original.contenido ->> 'folio'));
  insert into public.trabajos_impresion (sucursal_id, documento, impresora, cuenta_id, turno_id, contenido, reimpresion_de, creado_por)
  values (v_original.sucursal_id, 'ticket', 'caja', v_original.cuenta_id, v_original.turno_id,
          v_original.contenido || jsonb_build_object('reimpresion', true,
            'reimprimio', (select u.nombre from public.usuarios u where u.id = v_actor)),
          v_original.id, v_actor)
  returning * into v_fila;
  return v_fila;
end
$$;

-- -----------------------------------------------------------------------------
-- Corte de caja
-- -----------------------------------------------------------------------------
create function privado.resumen_turno(p_turno_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  with t as (select * from public.turnos_caja where id = p_turno_id),
  ventas as (select metodo, sum(importe) s from public.pagos where turno_id = p_turno_id and estado = 'vigente' group by metodo),
  props as (select metodo, sum(importe) s from public.propinas where turno_id = p_turno_id and estado = 'vigente' group by metodo),
  devs as (select metodo, sum(importe) s from public.devoluciones where turno_id = p_turno_id group by metodo),
  movs as (select tipo, sum(importe) s from public.movimientos_efectivo where turno_id = p_turno_id group by tipo),
  r as (
    select
      (select fondo_inicial from t) fondo,
      coalesce((select s from ventas where metodo = 'efectivo'), 0) v_ef,
      coalesce((select s from ventas where metodo = 'tarjeta'), 0) v_ta,
      coalesce((select s from ventas where metodo = 'transferencia'), 0) v_tr,
      coalesce((select s from props where metodo = 'efectivo'), 0) p_ef,
      coalesce((select s from props where metodo = 'tarjeta'), 0) p_ta,
      coalesce((select s from devs where metodo = 'efectivo'), 0) d_ef,
      coalesce((select s from devs where metodo = 'tarjeta'), 0) d_ta,
      coalesce((select s from devs where metodo = 'transferencia'), 0) d_tr,
      coalesce((select s from movs where tipo = 'entrada'), 0) ent,
      coalesce((select s from movs where tipo = 'retiro'), 0) ret)
  select jsonb_build_object(
    'fondo_inicial', fondo,
    'ventas_efectivo', v_ef, 'ventas_tarjeta', v_ta, 'ventas_transferencia', v_tr,
    'ventas_total', v_ef + v_ta + v_tr,
    'propinas_efectivo', p_ef, 'propinas_tarjeta', p_ta,
    'devoluciones_efectivo', d_ef, 'devoluciones_tarjeta', d_ta, 'devoluciones_transferencia', d_tr,
    'entradas', ent, 'retiros', ret,
    -- Las propinas se entregan aparte a los meseros: no cuentan en el efectivo de la caja.
    'efectivo_esperado', fondo + v_ef + ent - ret - d_ef,
    -- Lo que debe marcar la terminal: ventas con tarjeta más propinas con tarjeta.
    'terminal_esperada', v_ta + p_ta - d_ta,
    'cuentas_cobradas', (select count(*) from public.cuentas c where c.turno_id = p_turno_id and c.estado = 'cobrada'),
    'cobros_extra', coalesce((select sum(x.importe) from public.cobros_extra x join public.cuentas c on c.id = x.cuenta_id
                              where c.turno_id = p_turno_id and c.estado = 'cobrada' and x.estado = 'activa'), 0),
    'cuentas_abiertas', (select count(*) from public.cuentas c where c.sucursal_id = (select sucursal_id from t)
                         and c.estado in ('abierta', 'por_cobrar')))
  from r
$$;

-- Vista previa del corte de la caja abierta (para la pantalla de caja).
create function public.resumen_caja() returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_turno public.turnos_caja;
begin
  perform privado.exigir_perfil('propietario', 'cajero');
  v_turno := privado.turno_abierto(privado.sucursal_del_actor());
  if v_turno.id is null then
    return null;
  end if;
  return privado.resumen_turno(v_turno.id) || jsonb_build_object('turno_id', v_turno.id, 'abierto_en', v_turno.abierto_en);
end
$$;

create function public.cerrar_caja(p_efectivo_contado numeric) returns public.turnos_caja
language plpgsql security definer
set search_path = ''
as $$
declare
  v_turno public.turnos_caja;
  v_resumen jsonb;
  v_esperado numeric;
begin
  perform privado.exigir_perfil('propietario', 'cajero');
  if p_efectivo_contado is null or p_efectivo_contado < 0 then
    raise exception 'Captura el efectivo contado';
  end if;
  select * into v_turno from public.turnos_caja
   where sucursal_id = privado.sucursal_del_actor() and estado = 'abierto' for update;
  if not found then
    raise exception 'La caja no está abierta';
  end if;
  v_resumen := privado.resumen_turno(v_turno.id);
  v_esperado := (v_resumen ->> 'efectivo_esperado')::numeric;
  perform privado.fijar_accion(format('Hizo el corte de caja: esperado $%s, contado $%s, diferencia $%s',
                                      v_esperado, p_efectivo_contado, p_efectivo_contado - v_esperado));
  update public.turnos_caja
     set estado = 'cerrado', cerrado_en = now(), efectivo_esperado = v_esperado,
         efectivo_contado = p_efectivo_contado, diferencia = p_efectivo_contado - v_esperado, resumen = v_resumen
   where id = v_turno.id
  returning * into v_turno;
  insert into public.trabajos_impresion (sucursal_id, documento, impresora, turno_id, contenido)
  values (v_turno.sucursal_id, 'corte', 'caja', v_turno.id,
          v_resumen || jsonb_build_object('documento', 'corte',
            'cajero', (select u.nombre from public.usuarios u where u.id = v_turno.cajero_id),
            'abierto_en', to_char(v_turno.abierto_en at time zone 'America/Mexico_City', 'DD/MM/YYYY HH24:MI'),
            'cerrado_en', to_char(v_turno.cerrado_en at time zone 'America/Mexico_City', 'DD/MM/YYYY HH24:MI'),
            'efectivo_contado', p_efectivo_contado, 'diferencia', p_efectivo_contado - v_esperado));
  return v_turno;
end
$$;

create function public.aprobar_corte(p_turno_id uuid) returns public.turnos_caja
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_turno public.turnos_caja;
begin
  select * into v_turno from public.turnos_caja where id = p_turno_id for update;
  if not found then
    raise exception 'El corte no existe';
  end if;
  if v_turno.estado <> 'cerrado' then
    raise exception 'Solo se aprueba un corte cerrado';
  end if;
  perform privado.fijar_accion('Aprobó el corte de caja del ' || to_char(v_turno.abierto_en at time zone 'America/Mexico_City', 'DD/MM/YYYY'));
  update public.turnos_caja set estado = 'aprobado', aprobado_en = now(), aprobado_por = v_actor
   where id = p_turno_id
  returning * into v_turno;
  return v_turno;
end
$$;

-- Reabrir un corte (cerrado o aprobado): solo propietarios, con motivo.
-- Los datos del corte anterior quedan en la auditoría.
create function public.reabrir_corte(p_turno_id uuid, p_motivo text) returns public.turnos_caja
language plpgsql security definer
set search_path = ''
as $$
declare
  v_turno public.turnos_caja;
begin
  perform privado.exigir_perfil('propietario');
  if coalesce(length(trim(p_motivo)), 0) = 0 then
    raise exception 'Escribe el motivo para reabrir el corte';
  end if;
  select * into v_turno from public.turnos_caja where id = p_turno_id for update;
  if not found or v_turno.estado = 'abierto' then
    raise exception 'El corte no está cerrado';
  end if;
  if (privado.turno_abierto(v_turno.sucursal_id)).id is not null then
    raise exception 'Hay otra caja abierta; ciérrala antes de reabrir este corte';
  end if;
  perform privado.fijar_accion('Reabrió el corte de caja del ' || to_char(v_turno.abierto_en at time zone 'America/Mexico_City', 'DD/MM/YYYY'), p_motivo);
  update public.turnos_caja
     set estado = 'abierto', cerrado_en = null, efectivo_esperado = null, efectivo_contado = null, diferencia = null,
         resumen = null, aprobado_en = null, aprobado_por = null
   where id = p_turno_id
  returning * into v_turno;
  return v_turno;
end
$$;

-- -----------------------------------------------------------------------------
-- Autorizaciones: ahora con la devolución del dinero
-- -----------------------------------------------------------------------------
drop function public.solicitar_autorizacion(public.tipo_autorizacion, uuid, text, uuid, uuid);
create function public.solicitar_autorizacion(
  p_tipo public.tipo_autorizacion,
  p_cuenta_id uuid,
  p_motivo text,
  p_linea_id uuid default null,
  p_cobro_extra_id uuid default null,
  p_metodo_devolucion public.metodo_pago default null
) returns public.autorizaciones
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_cuenta public.cuentas;
  v_desc text;
  v_fila public.autorizaciones;
begin
  if coalesce(length(trim(p_motivo)), 0) = 0 then
    raise exception 'Escribe el motivo de la solicitud';
  end if;
  select * into v_cuenta from public.cuentas where id = p_cuenta_id;
  if not found then
    raise exception 'La cuenta no existe';
  end if;
  v_desc := case when v_cuenta.tipo = 'mesa'
                 then 'la cuenta de ' || coalesce((select m.nombre from public.mesas m where m.id = v_cuenta.mesa_id), 'mesa')
                 else 'el pedido para llevar' end || ' (folio ' || v_cuenta.folio || ')';

  if p_tipo = 'cancelar_cuenta' then
    if v_cuenta.estado not in ('abierta', 'por_cobrar') then
      raise exception 'Solo se cancela una cuenta abierta o por cobrar; si ya se cobró, primero se anula el cobro';
    end if;
    v_desc := 'Solicitó cancelar ' || v_desc;
  elsif p_tipo = 'anular_cobro' then
    if v_cuenta.estado <> 'cobrada' then
      raise exception 'La cuenta no tiene un cobro registrado';
    end if;
    v_desc := 'Solicitó anular el cobro de ' || v_desc;
  else
    if v_cuenta.estado <> 'cobrada' then
      raise exception 'La cuenta aún no se cobra: el producto se quita sin autorización, con motivo';
    end if;
    if p_metodo_devolucion is null then
      raise exception 'Indica cómo se le devuelve el dinero al cliente';
    end if;
    if num_nonnulls(p_linea_id, p_cobro_extra_id) <> 1 then
      raise exception 'Indica el producto o el cobro extra que se quita';
    end if;
    if p_linea_id is not null and not exists (
         select 1 from public.lineas_cuenta l
         where l.id = p_linea_id and l.cuenta_id = p_cuenta_id and l.estado = 'activa') then
      raise exception 'El producto no pertenece a la cuenta o ya está cancelado';
    end if;
    if p_cobro_extra_id is not null and not exists (
         select 1 from public.cobros_extra x
         where x.id = p_cobro_extra_id and x.cuenta_id = p_cuenta_id and x.estado = 'activa') then
      raise exception 'El cobro extra no pertenece a la cuenta o ya está cancelado';
    end if;
    v_desc := 'Solicitó quitar ' ||
              coalesce((select l.cantidad || ' × ' || l.nombre_producto from public.lineas_cuenta l where l.id = p_linea_id),
                       (select 'el cobro extra "' || x.concepto || '"' from public.cobros_extra x where x.id = p_cobro_extra_id)) ||
              ' de ' || v_desc;
  end if;

  if exists (select 1 from public.autorizaciones a
             where a.estado = 'pendiente' and a.tipo = p_tipo
               and coalesce(a.linea_id, a.cobro_extra_id, a.cuenta_id) = coalesce(p_linea_id, p_cobro_extra_id, p_cuenta_id)) then
    raise exception 'Ya hay una solicitud pendiente para esto';
  end if;

  perform privado.fijar_accion(v_desc, p_motivo);
  insert into public.autorizaciones (sucursal_id, tipo, cuenta_id, linea_id, cobro_extra_id, motivo, solicitada_por,
                                     metodo_devolucion)
  values (v_cuenta.sucursal_id, p_tipo, p_cuenta_id, p_linea_id, p_cobro_extra_id, trim(p_motivo), v_actor,
          case when p_tipo = 'cancelar_linea_cobrada' then p_metodo_devolucion end)
  returning * into v_fila;
  return v_fila;
end
$$;


create or replace function public.resolver_autorizacion(
  p_id uuid, p_aprobar boolean, p_comentario text default null
) returns public.autorizaciones
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_aut public.autorizaciones;
  v_cuenta public.cuentas;
  v_importe numeric;
  v_turno public.turnos_caja;
begin
  select * into v_aut from public.autorizaciones where id = p_id for update;
  if not found then
    raise exception 'La solicitud no existe';
  end if;
  if v_aut.estado <> 'pendiente' then
    raise exception 'La solicitud ya fue resuelta';
  end if;
  if v_aut.solicitada_por = v_actor then
    raise exception 'Nadie puede aprobar ni rechazar su propia solicitud' using errcode = '42501';
  end if;

  -- Mismo orden de bloqueo que enviar_pedido: primero la mesa, después la cuenta.
  perform privado.bloquear_grupo((select c.mesa_id from public.cuentas c where c.id = v_aut.cuenta_id));
  select * into v_cuenta from public.cuentas where id = v_aut.cuenta_id for update;

  if not p_aprobar then
    perform privado.fijar_accion('Rechazó la solicitud: ' || v_aut.tipo, p_comentario);
    update public.autorizaciones
       set estado = 'rechazada', resuelta_por = v_actor, resuelta_en = now(), comentario = nullif(trim(p_comentario), '')
     where id = p_id
    returning * into v_aut;
    return v_aut;
  end if;

  perform privado.fijar_accion('Aprobó la solicitud: ' || v_aut.tipo, p_comentario);
  update public.autorizaciones
     set estado = 'aprobada', resuelta_por = v_actor, resuelta_en = now(), comentario = nullif(trim(p_comentario), '')
   where id = p_id
  returning * into v_aut;

  if v_aut.tipo = 'cancelar_cuenta' then
    if v_cuenta.estado not in ('abierta', 'por_cobrar') then
      raise exception 'La cuenta ya no está abierta; la solicitud ya no aplica, recházala para cerrarla';
    end if;
    perform privado.fijar_accion('Cuenta cancelada con autorización', v_aut.motivo);
    update public.cuentas
       set estado = 'cancelada', cancelada_en = now(), cancelada_por = v_aut.solicitada_por,
           cancelacion_motivo = v_aut.motivo, autorizacion_id = v_aut.id
     where id = v_cuenta.id;
    -- La mesa (y las unidas a ella) queda libre; la cuenta conserva todo su detalle.
    if v_cuenta.mesa_id is not null and v_cuenta.cobro_anulado_en is null then
      update public.mesas set estado = 'disponible', unida_a = null
       where id = v_cuenta.mesa_id or unida_a = v_cuenta.mesa_id;
    end if;

  elsif v_aut.tipo = 'anular_cobro' then
    if v_cuenta.estado <> 'cobrada' then
      raise exception 'La cuenta ya no está cobrada; la solicitud ya no aplica, recházala para cerrarla';
    end if;
    perform privado.fijar_accion('Cobro anulado con autorización', v_aut.motivo);
    update public.pagos
       set estado = 'anulado', anulado_en = now(), anulado_por = v_aut.solicitada_por,
           anulacion_motivo = v_aut.motivo, autorizacion_id = v_aut.id
     where cuenta_id = v_cuenta.id and estado = 'vigente';
    update public.propinas
       set estado = 'anulado', anulado_en = now(), anulado_por = v_aut.solicitada_por,
           anulacion_motivo = v_aut.motivo, autorizacion_id = v_aut.id
     where cuenta_id = v_cuenta.id and estado = 'vigente';
    -- La cuenta vuelve a "por cobrar" en caja con su mismo detalle.
    update public.cuentas
       set estado = 'por_cobrar', cobrada_en = null, subtotal = null, impuestos = null, total = null,
           cobro_anulado_en = now()
     where id = v_cuenta.id;

  else
    if v_cuenta.estado <> 'cobrada' then
      raise exception 'La cuenta ya no está cobrada; la solicitud ya no aplica, recházala para cerrarla';
    end if;
    perform privado.fijar_accion('Concepto quitado de una cuenta cobrada, con autorización', v_aut.motivo);
    if v_aut.linea_id is not null then
      update public.lineas_cuenta
         set estado = 'cancelada', cancelada_en = now(), cancelada_por = v_aut.solicitada_por,
             cancelacion_motivo = v_aut.motivo, autorizacion_id = v_aut.id
       where id = v_aut.linea_id and estado = 'activa';
    else
      update public.cobros_extra
         set estado = 'cancelada', cancelada_en = now(), cancelada_por = v_aut.solicitada_por,
             cancelacion_motivo = v_aut.motivo, autorizacion_id = v_aut.id
       where id = v_aut.cobro_extra_id and estado = 'activa';
    end if;
    if not found then
      raise exception 'El concepto ya estaba cancelado; la solicitud ya no aplica, recházala para cerrarla';
    end if;
    -- Se le devuelve el dinero al cliente: queda registrado y entra en el corte.
    v_importe := coalesce((select l.precio_unitario * l.cantidad from public.lineas_cuenta l where l.id = v_aut.linea_id),
                          (select x.importe from public.cobros_extra x where x.id = v_aut.cobro_extra_id));
    v_turno := privado.turno_abierto(v_cuenta.sucursal_id);
    if v_aut.metodo_devolucion = 'efectivo' and v_turno.id is null then
      raise exception 'Para devolver efectivo la caja debe estar abierta';
    end if;
    perform privado.fijar_accion('Devolución al cliente por concepto quitado de una cuenta cobrada', v_aut.motivo);
    insert into public.devoluciones (sucursal_id, cuenta_id, linea_id, cobro_extra_id, metodo, importe, turno_id, autorizacion_id)
    values (v_cuenta.sucursal_id, v_cuenta.id, v_aut.linea_id, v_aut.cobro_extra_id, v_aut.metodo_devolucion, v_importe,
            v_turno.id, v_aut.id);
  end if;

  return v_aut;
end
$$;


-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------
-- El mesero ve también los pedidos para llevar abiertos (los puede capturar).
drop policy cuentas_leer on public.cuentas;
create policy cuentas_leer on public.cuentas for select to authenticated
  using ((select privado.es_propietario())
         or ((select privado.tiene_perfil('mesero'))
             and ((tipo = 'mesa' and estado in ('abierta', 'por_cobrar')) or (tipo = 'llevar' and estado = 'abierta')))
         or ((select privado.tiene_perfil('cajero'))
             and (estado in ('abierta', 'por_cobrar')
                  or exists (select 1 from public.turnos_caja t
                             where t.id = turno_id and t.cajero_id = (select auth.uid()) and t.estado = 'abierto'))));

alter table public.devoluciones enable row level security;
alter table public.devoluciones force row level security;
revoke all on public.devoluciones from public, anon, authenticated;
revoke delete, truncate on public.devoluciones from service_role;
grant select on public.devoluciones to authenticated;
create policy devoluciones_leer on public.devoluciones for select to authenticated
  using ((select privado.es_propietario())
         or ((select privado.tiene_perfil('cajero'))
             and exists (select 1 from public.turnos_caja t
                         where t.id = turno_id and t.cajero_id = (select auth.uid()) and t.estado = 'abierto')));

revoke execute on function privado.turno_abierto(uuid), privado.sucursal_del_actor(), privado.total_cuenta(uuid),
  privado.nombre_cuenta(public.cuentas), privado.registrar_envio(public.cuentas, jsonb, uuid, text),
  privado.contenido_ticket(uuid), privado.resumen_turno(uuid) from public, anon, authenticated;

revoke execute on function public.enviar_pedido_llevar(uuid, jsonb, uuid), public.abrir_caja(numeric),
  public.registrar_movimiento(public.tipo_movimiento, numeric, text), public.agregar_cobro_extra(uuid, text, numeric),
  public.quitar_cobro_extra(uuid, text), public.cobrar_cuenta(uuid, jsonb, uuid, numeric, public.metodo_pago),
  public.reimprimir_ticket(uuid), public.resumen_caja(), public.cerrar_caja(numeric), public.aprobar_corte(uuid),
  public.reabrir_corte(uuid, text),
  public.solicitar_autorizacion(public.tipo_autorizacion, uuid, text, uuid, uuid, public.metodo_pago)
  from public, anon;
grant execute on function public.enviar_pedido_llevar(uuid, jsonb, uuid), public.abrir_caja(numeric),
  public.registrar_movimiento(public.tipo_movimiento, numeric, text), public.agregar_cobro_extra(uuid, text, numeric),
  public.quitar_cobro_extra(uuid, text), public.cobrar_cuenta(uuid, jsonb, uuid, numeric, public.metodo_pago),
  public.reimprimir_ticket(uuid), public.resumen_caja(), public.cerrar_caja(numeric), public.aprobar_corte(uuid),
  public.reabrir_corte(uuid, text),
  public.solicitar_autorizacion(public.tipo_autorizacion, uuid, text, uuid, uuid, public.metodo_pago)
  to authenticated;

-- Cambios en vivo para la pantalla de caja.
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['cobros_extra', 'turnos_caja', 'pagos', 'movimientos_efectivo'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end
$$;
