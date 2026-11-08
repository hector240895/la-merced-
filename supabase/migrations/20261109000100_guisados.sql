-- =============================================================================
-- Sistema La Merced · Guisados para elegir
--
-- Los platillos con guisado se eligen con botón, como los sabores. Algunos
-- llevan varios (la orden de sopes y la de quesadillitas, 3; la quesadilla de
-- 2 guisados, 2): se elige uno por pieza y pueden repetirse.
--
--   productos.cuantas_opciones  cuántas opciones se eligen (1 por omisión)
--   productos.nombre_opcion     cómo se llaman en pantalla: "sabor" o "guisado"
--
-- La línea del pedido guarda lo elegido en "opcion", separado por comas
-- (por ejemplo "Deshebrada, Pollo, Pollo"), y así sale en la comanda.
-- =============================================================================

alter table public.productos
  add column cuantas_opciones smallint not null default 1
    constraint productos_cuantas_opciones check (cuantas_opciones between 1 and 10),
  add column nombre_opcion text not null default 'sabor'
    constraint productos_nombre_opcion check (length(trim(nombre_opcion)) > 0);

-- Enviar pedido: acepta una opción ("opcion") o varias ("opciones").
-- p_productos: [{"producto_id": "...", "cantidad": 1, "observacion": "Sin cebolla",
--               "opciones": ["Deshebrada", "Pollo", "Pollo"]}, ...]
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
  v_lista text[];
  v_eleccion text;
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
    -- Opciones elegidas: una (sabor) o varias (guisados de una orden).
    v_lista := coalesce(v_item.opciones, case when v_item.opcion is not null then array[v_item.opcion] end);
    if cardinality(v_prod.opciones) = 0 then
      if v_lista is not null and cardinality(v_lista) > 0 then
        raise exception '% no tiene opciones para elegir', v_prod.nombre;
      end if;
      v_eleccion := null;
    else
      if v_lista is null or cardinality(v_lista) <> v_prod.cuantas_opciones
         or exists (select 1 from unnest(v_lista) x where x is null or not (x = any (v_prod.opciones))) then
        if v_prod.cuantas_opciones = 1 then
          raise exception 'Elige el % de %', v_prod.nombre_opcion, v_prod.nombre;
        else
          raise exception 'Elige los % %s de %', v_prod.cuantas_opciones, v_prod.nombre_opcion, v_prod.nombre;
        end if;
      end if;
      v_eleccion := array_to_string(v_lista, ', ');
    end if;

    insert into public.lineas_cuenta (sucursal_id, cuenta_id, producto_id, nombre_producto, precio_unitario,
                                      tasa_iva, cantidad, observacion, opcion, enviada_en)
    values (v_cuenta.sucursal_id, v_cuenta.id, v_prod.id, v_prod.nombre, v_prod.precio, v_prod.tasa_iva,
            v_item.cantidad, nullif(trim(v_item.observacion), ''), v_eleccion, now())
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


-- -----------------------------------------------------------------------------
-- Guisados del menú
-- -----------------------------------------------------------------------------
do $$
declare
  guisados constant text[] := array['Deshebrada', 'Papas con chorizo', 'Chicharrón prensado',
                                    'Requesón con rajas', 'Champiñones', 'Pollo'];
begin
  perform privado.fijar_accion('Instalación: guisados para elegir');

  update public.productos p
     set opciones = guisados, nombre_opcion = 'guisado', cuantas_opciones = x.cuantas, descripcion = x.descripcion
    from (values
      ('Orden de sopes con guisado (3 pz)',   3, 'Llevan pico de gallo. Un guisado por sope'),
      ('Sope con guisado (1 pz)',             1, null),
      ('Orden de quesadillitas (3 pz)',       3, 'Un guisado por quesadillita'),
      ('Quesadilla (1 guisado)',              1, null),
      ('Quesadilla (2 guisados)',             2, null),
      ('Quesadillita individual con guisado', 1, null),
      ('Tostada con guisado',                 1, null),
      ('Guisado extra',                       1, null)
    ) as x(nombre, cuantas, descripcion)
   where p.nombre = x.nombre and p.eliminado_en is null;

  perform privado.fijar_accion(null);
end
$$;
