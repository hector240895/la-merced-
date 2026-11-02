-- =============================================================================
-- Sistema La Merced · Opciones para elegir en un producto (sabores)
-- Algunos productos tienen el mismo precio pero el cliente elige una opción:
-- el sabor del agua o del refresco. El mesero la elige con un botón, queda
-- guardada en la línea del pedido (columna opcion) y saldrá en la comanda.
-- Si un producto tiene opciones, elegir una es obligatorio.
-- =============================================================================

alter table public.productos
  add column opciones text[] not null default '{}'
  constraint productos_opciones_validas check (array_position(opciones, null) is null);

alter table public.lineas_cuenta add column opcion text;

create trigger lineas_inmutable_opcion before update on public.lineas_cuenta for each row
  execute function privado.proteger_columnas('opcion');

-- Enviar pedido: cada producto puede traer la opción elegida.
-- p_productos: [{"producto_id": "...", "cantidad": 2, "observacion": "Sin hielo", "opcion": "Horchata"}, ...]
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
begin
  if p_solicitud_id is null then
    raise exception 'Falta el identificador de la solicitud';
  end if;
  -- Reintento del mismo envío: se devuelve lo ya registrado.
  select * into v_comanda from public.comandas where solicitud_id = p_solicitud_id;
  if found then
    return jsonb_build_object('cuenta_id', v_comanda.cuenta_id, 'comanda_id', v_comanda.id,
                              'numero', v_comanda.numero, 'repetido', true);
  end if;
  if jsonb_typeof(p_productos) <> 'array' or jsonb_array_length(p_productos) = 0 then
    raise exception 'El pedido no tiene productos';
  end if;

  v_mesa := privado.bloquear_mesa(p_mesa_id);
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


-- Quitar producto: la parte que queda conserva la opción elegida.
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
  select * into v_cuenta from public.cuentas where id = v_linea.cuenta_id for update;
  if v_cuenta.mesa_id is not null then
    perform privado.bloquear_mesa(v_cuenta.mesa_id);
  end if;
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
-- Sabores del menú
-- -----------------------------------------------------------------------------
do $$
begin
  perform privado.fijar_accion('Instalación: sabores de aguas y refrescos');
  update public.productos set descripcion = null, opciones = array['Horchata', 'Jamaica']
   where nombre in ('Agua de sabor (500 ml)', 'Agua de sabor (900 ml)') and eliminado_en is null;
  update public.productos set descripcion = null,
         opciones = array['Pepsi', 'Pepsi Black', 'Agua mineral', 'Mirinda', 'Jumex', '7UP',
                          'Jarrito tamarindo', 'Jarrito tutti frutti', 'Jarrito piña', 'Manzanita', 'Sangría']
   where nombre = 'Refresco de vidrio (355 ml)' and eliminado_en is null;
  update public.productos set descripcion = null, opciones = array['Coca-Cola', 'Coca-Cola Light']
   where nombre = 'Refresco desechable (600 ml)' and eliminado_en is null;
  perform privado.fijar_accion(null);
end
$$;
