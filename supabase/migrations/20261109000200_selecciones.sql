-- =============================================================================
-- Sistema La Merced · Selecciones con su propia lista
--
-- Hasta ahora todas las opciones de un platillo salían de una misma lista.
-- El Plato Aguascalientes’n necesita tres listas distintas (guisado del sope,
-- guisado de la quesadillita, y pata o cueritos), así que cada selección
-- tiene ahora su nombre y su lista:
--
--   productos.selecciones = [{"etiqueta": "Guisado del sope", "opciones": [...]}, ...]
--
-- Los sabores y guisados que ya existían se pasan tal cual a este formato.
-- En la comanda:
--   * si todas las selecciones se llaman igual: "Deshebrada, Pollo, Pollo"
--   * si tienen nombres distintos: "Guisado del sope: Deshebrada, ..."
--
-- Además: Taco de guisado ($12, en Extras) y Quesadillitas sencillas ($70).
-- =============================================================================

alter table public.productos
  add column selecciones jsonb not null default '[]'
    constraint productos_selecciones_lista check (jsonb_typeof(selecciones) = 'array');

-- Pasar los sabores y guisados al formato nuevo.
do $$
begin
  perform privado.fijar_accion('Instalación: opciones de cada platillo con su propia lista');
  update public.productos p
     set selecciones = (select jsonb_agg(jsonb_build_object('etiqueta', initcap(p.nombre_opcion), 'opciones', to_jsonb(p.opciones), 'n', g) - 'n'
                                         order by g)
                        from generate_series(1, p.cuantas_opciones) g)
   where cardinality(p.opciones) > 0;
  perform privado.fijar_accion(null);
end
$$;

-- Valida lo elegido contra las selecciones del producto y lo convierte en el
-- texto que se guarda en la línea y sale en la comanda.
create function privado.texto_selecciones(p_prod public.productos, p_lista text[]) returns text
language plpgsql stable
set search_path = ''
as $$
declare
  v_sel jsonb := p_prod.selecciones;
  v_n integer := jsonb_array_length(p_prod.selecciones);
  v_etiquetas integer;
begin
  if v_n = 0 then
    if p_lista is not null and cardinality(p_lista) > 0 then
      raise exception '% no tiene opciones para elegir', p_prod.nombre;
    end if;
    return null;
  end if;

  select count(distinct s ->> 'etiqueta') into v_etiquetas from jsonb_array_elements(v_sel) s;
  if p_lista is null or cardinality(p_lista) <> v_n
     or exists (select 1 from generate_series(1, v_n) i
                where p_lista[i] is null or not ((v_sel -> (i - 1) -> 'opciones') ? p_lista[i])) then
    if v_n = 1 then
      raise exception 'Elige el % de %', lower(v_sel -> 0 ->> 'etiqueta'), p_prod.nombre;
    elsif v_etiquetas = 1 then
      raise exception 'Elige los % %s de %', v_n, lower(v_sel -> 0 ->> 'etiqueta'), p_prod.nombre;
    else
      raise exception 'Completa las opciones de %', p_prod.nombre;
    end if;
  end if;

  if v_etiquetas = 1 then
    return array_to_string(p_lista, ', ');
  end if;
  return (select string_agg((v_sel -> (i - 1) ->> 'etiqueta') || ': ' || p_lista[i], ', ' order by i)
          from generate_series(1, v_n) i);
end
$$;
revoke execute on function privado.texto_selecciones(public.productos, text[]) from public, anon, authenticated;

-- Enviar pedido con selecciones.
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
    -- Lo elegido: una opción por cada selección del producto, en orden.
    v_lista := coalesce(v_item.opciones, case when v_item.opcion is not null then array[v_item.opcion] end);
    v_eleccion := privado.texto_selecciones(v_prod, v_lista);

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


-- Las columnas anteriores ya no se usan.
alter table public.productos drop column opciones, drop column cuantas_opciones, drop column nombre_opcion;

-- -----------------------------------------------------------------------------
-- Menú
-- -----------------------------------------------------------------------------
do $$
declare
  guisados constant jsonb := '["Deshebrada", "Papas con chorizo", "Chicharrón prensado", "Requesón con rajas", "Champiñones", "Pollo"]';
  v_extras uuid := (select id from public.categorias where nombre = 'Extras' and eliminada_en is null);
  v_quesadillas uuid := (select id from public.categorias where nombre = 'Quesadillas' and eliminada_en is null);
begin
  perform privado.fijar_accion('Instalación: plato Aguascalientes’n con sus opciones');
  update public.productos
     set selecciones = jsonb_build_array(
           jsonb_build_object('etiqueta', 'Guisado del sope', 'opciones', guisados),
           jsonb_build_object('etiqueta', 'Guisado de la quesadillita', 'opciones', guisados),
           jsonb_build_object('etiqueta', 'Pata o cueritos', 'opciones', '["Cueritos", "Pata curtida"]'::jsonb)),
         descripcion = '1 sope con guisado, 1 flauta, 1 enchilada roja, 1 taco dorado, 1 quesadillita con guisado y media orden de pata o cueritos'
   where nombre = 'Plato Aguascalientes’n' and eliminado_en is null;

  perform privado.fijar_accion('Instalación: Taco de guisado en Extras');
  insert into public.productos (categoria_id, nombre, precio, orden, selecciones)
  values (v_extras, 'Taco de guisado', 12, 6, jsonb_build_array(jsonb_build_object('etiqueta', 'Guisado', 'opciones', guisados)));

  perform privado.fijar_accion('Instalación: Quesadillitas sencillas');
  update public.productos set orden = orden + 1 where categoria_id = v_quesadillas and orden >= 2;
  insert into public.productos (categoria_id, nombre, precio, orden) values (v_quesadillas, 'Quesadillitas sencillas', 70, 2);

  perform privado.fijar_accion(null);
end
$$;
