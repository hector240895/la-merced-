-- =============================================================================
-- Sistema La Merced · Correcciones de la auditoría técnica (2 de noviembre de 2026)
--
-- Críticos
--   1. enviar_pedido: un pedido NULL ya no crea una cuenta vacía.
--   2. enviar_pedido: un solicitud_id usado en otra mesa se rechaza (antes se
--      respondía "repetido" con datos de la otra mesa y el pedido se perdía).
-- Importantes
--   3. unir_mesas: recalcula los grupos después de bloquear y una regla impide
--      mesas unidas en cadena (dos meseros uniendo a la vez).
--   4. Mismo orden de bloqueo (mesa → cuenta) en enviar_pedido, quitar_producto
--      y resolver_autorizacion, para evitar bloqueos cruzados en hora pico.
--   5. Dos envíos simultáneos idénticos: el segundo responde "repetido".
--   6. validar_mesa: una cuenta con cobro anulado (ya no ocupa la mesa) no
--      impide desactivar o eliminar la mesa.
--   7. Nombres únicos de categorías y productos vigentes.
-- Mejoras
--   8. ordenar_mesas valida repetidos, mesas inexistentes y sucursal.
--   9. Observación de hasta 200 letras.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Ayudantes
-- -----------------------------------------------------------------------------

-- Bloquea una mesa y su grupo sin exigir que esté activa (para operar sobre
-- cuentas ya existentes). No hace nada si no hay mesa (pedido para llevar).
create function privado.bloquear_grupo(p_mesa_id uuid) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_principal uuid := privado.mesa_principal(p_mesa_id);
begin
  if v_principal is not null then
    perform 1 from public.mesas where id = v_principal or unida_a = v_principal order by id for update;
  end if;
end
$$;

-- Mesas principales (sin repetir y en orden) de una lista de mesas.
create function privado.raices_de(p_mesa_ids uuid[]) returns uuid[]
language sql stable
set search_path = ''
as $$
  select array_agg(distinct privado.mesa_principal(x) order by privado.mesa_principal(x))
  from unnest(p_mesa_ids) x
$$;

-- Si ya se registró un envío con este identificador en esta mesa (o en su
-- grupo), devuelve lo registrado; si se usó en otra mesa, lo rechaza.
create function privado.envio_previo(p_solicitud_id uuid, p_principal uuid) returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_comanda public.comandas;
  v_mesa uuid;
begin
  select * into v_comanda from public.comandas where solicitud_id = p_solicitud_id;
  if not found then
    return null;
  end if;
  select c.mesa_id into v_mesa from public.cuentas c where c.id = v_comanda.cuenta_id;
  if v_mesa is null or privado.mesa_principal(v_mesa) <> p_principal then
    raise exception 'Este envío ya se usó en otro pedido. Vuelve a enviar el pedido.';
  end if;
  return jsonb_build_object('cuenta_id', v_comanda.cuenta_id, 'comanda_id', v_comanda.id,
                            'numero', v_comanda.numero, 'repetido', true);
end
$$;

-- -----------------------------------------------------------------------------
-- Pedidos
-- -----------------------------------------------------------------------------
create or replace function public.enviar_pedido(p_mesa_id uuid, p_productos jsonb, p_solicitud_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario', 'mesero');
  v_mesa public.mesas;
  v_cuenta public.cuentas;
  v_comanda public.comandas;
  v_item record;
  v_prod public.productos;
  v_linea uuid;
  v_n integer := 0;
  v_repetido jsonb;
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

  perform privado.fijar_accion(
    case when exists (select 1 from public.comandas c where c.cuenta_id = v_cuenta.id and c.tipo in ('nueva', 'adicional'))
         then 'Envió un pedido adicional de ' else 'Envió el pedido de ' end
    || privado.nombre_grupo(v_mesa.id));
  insert into public.comandas (sucursal_id, cuenta_id, numero, tipo, solicitud_id)
  select v_cuenta.sucursal_id, v_cuenta.id, coalesce(max(c.numero), 0) + 1,
         case when count(c.id) filter (where c.tipo in ('nueva', 'adicional')) = 0 then 'nueva' else 'adicional' end::public.tipo_comanda,
         p_solicitud_id
  from public.comandas c where c.cuenta_id = v_cuenta.id
  returning * into v_comanda;

  for v_item in
    select * from jsonb_to_recordset(p_productos) as x(producto_id uuid, cantidad integer, observacion text, opcion text)
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
    if cardinality(v_prod.opciones) > 0 and (v_item.opcion is null or not (v_item.opcion = any (v_prod.opciones))) then
      raise exception 'Elige el sabor de %', v_prod.nombre;
    end if;
    if cardinality(v_prod.opciones) = 0 and v_item.opcion is not null then
      raise exception '% no tiene opciones para elegir', v_prod.nombre;
    end if;

    insert into public.lineas_cuenta (sucursal_id, cuenta_id, producto_id, nombre_producto, precio_unitario,
                                      tasa_iva, cantidad, observacion, opcion, enviada_en)
    values (v_cuenta.sucursal_id, v_cuenta.id, v_prod.id, v_prod.nombre, v_prod.precio, v_prod.tasa_iva,
            v_item.cantidad, nullif(trim(v_item.observacion), ''), v_item.opcion, now())
    returning id into v_linea;
    insert into public.comanda_lineas (sucursal_id, comanda_id, linea_id, cantidad)
    values (v_cuenta.sucursal_id, v_comanda.id, v_linea, v_item.cantidad);
    v_n := v_n + 1;
  end loop;

  perform privado.fijar_estado_grupo(v_mesa.id, 'pedido_enviado');
  return jsonb_build_object('cuenta_id', v_cuenta.id, 'comanda_id', v_comanda.id,
                            'numero', v_comanda.numero, 'productos', v_n, 'repetido', false);
end
$$;


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
  if privado.perfil_actual() = 'mesero' and v_cuenta.tipo <> 'mesa' then
    raise exception 'Los pedidos para llevar los maneja caja' using errcode = '42501';
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


-- -----------------------------------------------------------------------------
-- Autorizaciones
-- -----------------------------------------------------------------------------
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
  end if;

  return v_aut;
end
$$;


-- -----------------------------------------------------------------------------
-- Mesas
-- -----------------------------------------------------------------------------
create or replace function public.unir_mesas(p_mesa_ids uuid[]) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_raices uuid[];
  v_principal uuid;
  v_estado public.estado_mesa;
  v_miembros uuid[];
  v_con_cuenta integer;
  v_intento integer;
begin
  perform privado.exigir_perfil('propietario', 'mesero');
  -- Los grupos se calculan, se bloquean y se vuelven a calcular: si otro
  -- mesero unió o separó alguna de estas mesas mientras tanto, se repite
  -- con los grupos ya actualizados (evita mesas unidas en cadena).
  for v_intento in 1..5 loop
    v_raices := privado.raices_de(p_mesa_ids);
    if v_raices is null or array_position(v_raices, null) is not null then
      raise exception 'Una de las mesas no existe';
    end if;
    if cardinality(v_raices) < 2 then
      raise exception 'Elige al menos dos mesas distintas';
    end if;
    perform 1 from public.mesas where id = any (v_raices) or unida_a = any (v_raices) order by id for update;
    exit when privado.raices_de(p_mesa_ids) = v_raices;
    if v_intento = 5 then
      raise exception 'Las mesas cambiaron mientras se unían; intenta de nuevo';
    end if;
  end loop;
  if exists (select 1 from public.mesas where id = any (v_raices) and (not activa or eliminada_en is not null)) then
    raise exception 'Una de las mesas no está disponible para servicio';
  end if;
  if exists (select 1 from public.mesas where id = any (v_raices) and estado = 'por_cobrar') then
    raise exception 'No se une una mesa que ya pidió la cuenta';
  end if;
  select count(*) into v_con_cuenta from unnest(v_raices) r where (privado.cuenta_de_mesa(r)).id is not null;
  if v_con_cuenta > 1 then
    raise exception 'Solo se puede unir si a lo más una de las mesas tiene pedido';
  end if;

  select m.id into v_principal from public.mesas m
  where m.id = any (v_raices)
  order by (privado.cuenta_de_mesa(m.id)).id is null, m.estado = 'disponible', m.orden, m.nombre
  limit 1;

  v_estado := (select m.estado from public.mesas m where m.id = v_principal);
  if v_estado = 'disponible' and exists (select 1 from public.mesas where id = any (v_raices) and estado <> 'disponible') then
    v_estado := 'ocupada';
  end if;

  select array_agg(id order by orden) into v_miembros from public.mesas
  where id = any (v_raices) or unida_a = any (v_raices);

  perform privado.fijar_accion('Unió ' || (select string_agg(m.nombre, ' + ' order by m.id <> v_principal, m.orden)
                                           from public.mesas m where m.id = any (v_miembros)));
  update public.mesas set unida_a = v_principal
  where id = any (v_miembros) and id <> v_principal and unida_a is distinct from v_principal;
  perform privado.fijar_estado_grupo(v_principal, v_estado);
  insert into public.uniones_mesas (sucursal_id, operacion, mesa_ids, cuenta_id)
  select m.sucursal_id, 'union', v_miembros, (privado.cuenta_de_mesa(v_principal)).id
  from public.mesas m where m.id = v_principal;
  return v_principal;
end
$$;


-- Una mesa solo puede unirse a una mesa principal (que no esté unida a otra),
-- y una mesa con otras unidas a ella no puede unirse a una tercera.
-- Se revisa al final de la operación, cuando el grupo ya quedó acomodado.
create function privado.validar_union() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.unida_a is not null and (
       exists (select 1 from public.mesas p where p.id = new.unida_a and p.unida_a is not null)
       or exists (select 1 from public.mesas h where h.unida_a = new.id)) then
    raise exception 'Unión de mesas inválida: una mesa solo se une a una mesa principal';
  end if;
  return null;
end
$$;

create constraint trigger mesas_union_valida
after insert or update of unida_a on public.mesas
deferrable initially deferred
for each row execute function privado.validar_union();

-- Una cuenta con el cobro anulado ya no ocupa la mesa: no impide desactivarla
-- ni eliminarla (la cuenta sigue en caja para cobrarse).
create or replace function privado.validar_mesa() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if ((old.activa and not new.activa) or (old.eliminada_en is null and new.eliminada_en is not null))
     and exists (select 1 from public.cuentas c
                 where c.mesa_id = new.id and c.estado in ('abierta', 'por_cobrar') and c.cobro_anulado_en is null) then
    raise exception '% tiene una cuenta abierta. No se puede desactivar ni eliminar.', old.nombre;
  end if;
  return new;
end
$$;

create or replace function public.ordenar_mesas(p_ids uuid[]) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
begin
  if p_ids is null or cardinality(p_ids) = 0 or array_position(p_ids, null) is not null then
    raise exception 'Indica el orden de las mesas';
  end if;
  if (select count(distinct x) from unnest(p_ids) x) <> cardinality(p_ids) then
    raise exception 'Una mesa aparece dos veces en el orden';
  end if;
  if exists (select 1 from unnest(p_ids) x
             where not exists (select 1 from public.mesas m join public.usuarios u on u.id = v_actor
                               where m.id = x and m.eliminada_en is null and m.sucursal_id = u.sucursal_id)) then
    raise exception 'Una de las mesas no existe';
  end if;
  perform privado.fijar_accion('Cambió el orden de las mesas');
  update public.mesas m set orden = x.pos
  from unnest(p_ids) with ordinality as x(id, pos)
  where m.id = x.id and m.orden is distinct from x.pos;
end
$$;


-- -----------------------------------------------------------------------------
-- Catálogo: no se repiten nombres vigentes
-- -----------------------------------------------------------------------------
create unique index categorias_nombre_unico on public.categorias (sucursal_id, lower(nombre)) where eliminada_en is null;
create unique index productos_nombre_unico on public.productos (categoria_id, lower(nombre)) where eliminado_en is null;

-- -----------------------------------------------------------------------------
-- Permisos: las funciones reemplazadas conservan los suyos; los ayudantes
-- nuevos son internos (esquema privado, sin acceso desde la app).
-- -----------------------------------------------------------------------------
revoke execute on function privado.bloquear_grupo(uuid), privado.raices_de(uuid[]),
  privado.envio_previo(uuid, uuid), privado.validar_union() from public, anon, authenticated;
