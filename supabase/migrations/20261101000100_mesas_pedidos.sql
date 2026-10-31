-- =============================================================================
-- Sistema La Merced · Etapa 3 · Mesas y pedidos
-- Funciones del servidor para: ocupar y liberar mesas, enviar pedidos (con
-- pedidos adicionales), quitar productos con motivo, pedir la cuenta, unir y
-- separar mesas, y la administración de mesas del propietario.
--
-- Reglas:
--   * Una mesa unida a otra trabaja con la cuenta de la mesa principal.
--   * La cuenta de una mesa se crea con el primer pedido enviado.
--   * Enviar un pedido es idempotente: si el teléfono reintenta con la misma
--     solicitud_id, no se duplica.
--   * Quitar un producto ya enviado deja el aviso CANCELADO para cocina.
--   * Solo se unen mesas si, a lo más, una de ellas tiene cuenta abierta
--     (las líneas de una cuenta no cambian de cuenta).
-- =============================================================================

-- Una línea se considera enviada a cocina desde enviada_en. Al quitar parte
-- de una línea, la parte que queda es una línea nueva que la reemplaza.
alter table public.lineas_cuenta
  add column enviada_en timestamptz,
  add column reemplaza_linea_id uuid references public.lineas_cuenta (id);

create trigger lineas_sello_envio before update on public.lineas_cuenta for each row
  execute function privado.sellar_columnas('enviada_en');
create trigger lineas_inmutable_reemplazo before update on public.lineas_cuenta for each row
  execute function privado.proteger_columnas('reemplaza_linea_id');

-- Identificador que manda el teléfono para no duplicar un envío.
alter table public.comandas add column solicitud_id uuid unique;

-- Una acción (por ejemplo, enviar un pedido) escribe varias filas de auditoría
-- en la misma operación; el otro propietario recibe un solo aviso por acción.
-- Dentro de una transacción now() es el mismo, así que identifica la operación.
create or replace function privado.avisar_otro_propietario() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.perfil = 'propietario' then
    insert into public.avisos (sucursal_id, para_usuario_id, auditoria_id)
    select new.sucursal_id, u.id, new.id
    from public.usuarios u
    where u.perfil = 'propietario' and u.activo and u.id <> new.usuario_id
      and not exists (
        select 1 from public.avisos a join public.auditoria x on x.id = a.auditoria_id
        where a.para_usuario_id = u.id and x.creado_en = new.creado_en
          and x.usuario_id = new.usuario_id and x.accion = new.accion);
  end if;
  return null;
end
$$;

-- -----------------------------------------------------------------------------
-- Ayudantes internos
-- -----------------------------------------------------------------------------
create function privado.mesa_principal(p_mesa_id uuid) returns uuid
language sql stable
set search_path = ''
as $$
  select coalesce(m.unida_a, m.id) from public.mesas m where m.id = p_mesa_id
$$;

-- Cuenta que ocupa la mesa (abierta o con la cuenta pedida).
create function privado.cuenta_de_mesa(p_principal uuid) returns public.cuentas
language sql stable
set search_path = ''
as $$
  select c.* from public.cuentas c
  where c.mesa_id = p_principal and c.estado in ('abierta', 'por_cobrar') and c.cobro_anulado_en is null
$$;

-- El estado de las mesas unidas sigue al de la principal.
create function privado.fijar_estado_grupo(p_principal uuid, p_estado public.estado_mesa) returns void
language sql
set search_path = ''
as $$
  update public.mesas set estado = p_estado
  where (id = p_principal or unida_a = p_principal) and estado is distinct from p_estado
$$;

create function privado.nombre_grupo(p_principal uuid) returns text
language sql stable
set search_path = ''
as $$
  select string_agg(m.nombre, ' + ' order by m.id <> p_principal, m.orden)
  from public.mesas m where m.id = p_principal or m.unida_a = p_principal
$$;

-- Bloquea la mesa (y su grupo) para operar sin choques entre meseros.
create function privado.bloquear_mesa(p_mesa_id uuid) returns public.mesas
language plpgsql
set search_path = ''
as $$
declare
  v_principal uuid := privado.mesa_principal(p_mesa_id);
  v_mesa public.mesas;
begin
  if v_principal is null then
    raise exception 'La mesa no existe';
  end if;
  perform 1 from public.mesas where id = v_principal or unida_a = v_principal order by id for update;
  select * into v_mesa from public.mesas where id = v_principal;
  if v_mesa.eliminada_en is not null or not v_mesa.activa then
    raise exception '% no está disponible para servicio', v_mesa.nombre;
  end if;
  return v_mesa;
end
$$;

-- -----------------------------------------------------------------------------
-- Servicio en salón (mesero y propietario)
-- -----------------------------------------------------------------------------

-- Llegaron clientes y aún no piden: la mesa se marca ocupada.
create function public.ocupar_mesa(p_mesa_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_mesa public.mesas;
begin
  perform privado.exigir_perfil('propietario', 'mesero');
  v_mesa := privado.bloquear_mesa(p_mesa_id);
  if v_mesa.estado <> 'disponible' then
    return;
  end if;
  perform privado.fijar_accion('Abrió ' || privado.nombre_grupo(v_mesa.id));
  perform privado.fijar_estado_grupo(v_mesa.id, 'ocupada');
end
$$;

-- Se fueron sin pedir: la mesa vuelve a disponible.
create function public.liberar_mesa(p_mesa_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_mesa public.mesas;
begin
  perform privado.exigir_perfil('propietario', 'mesero');
  v_mesa := privado.bloquear_mesa(p_mesa_id);
  if v_mesa.estado = 'disponible' then
    return;
  end if;
  if (privado.cuenta_de_mesa(v_mesa.id)).id is not null then
    raise exception '% tiene una cuenta abierta; queda libre cuando caja registre el pago', v_mesa.nombre;
  end if;
  perform privado.fijar_accion('Liberó ' || privado.nombre_grupo(v_mesa.id) || ' sin pedido');
  perform privado.fijar_estado_grupo(v_mesa.id, 'disponible');
end
$$;

-- Envía a cocina los productos nuevos de una mesa.
-- p_productos: [{"producto_id": "...", "cantidad": 2, "observacion": "Sin crema"}, ...]
create function public.enviar_pedido(p_mesa_id uuid, p_productos jsonb, p_solicitud_id uuid)
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
    select * from jsonb_to_recordset(p_productos) as x(producto_id uuid, cantidad integer, observacion text)
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

    insert into public.lineas_cuenta (sucursal_id, cuenta_id, producto_id, nombre_producto, precio_unitario,
                                      tasa_iva, cantidad, observacion, enviada_en)
    values (v_cuenta.sucursal_id, v_cuenta.id, v_prod.id, v_prod.nombre, v_prod.precio, v_prod.tasa_iva,
            v_item.cantidad, nullif(trim(v_item.observacion), ''), now())
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

-- Quita un producto (o parte de su cantidad) antes del cobro, con motivo.
-- Lo pueden hacer mesero (cuentas de mesa), cajero y propietario.
create function public.quitar_producto(p_linea_id uuid, p_motivo text, p_cantidad integer default null)
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
    format('Quitó %s × %s de %s', v_qty, v_linea.nombre_producto,
           coalesce(privado.nombre_grupo(v_cuenta.mesa_id), 'el pedido para llevar ' || v_cuenta.folio)),
    p_motivo);

  update public.lineas_cuenta
     set estado = 'cancelada', cancelada_en = now(), cancelada_por = v_actor, cancelacion_motivo = trim(p_motivo)
   where id = v_linea.id;

  -- Lo que queda sigue en la cuenta como una línea que reemplaza a la anterior.
  if v_qty < v_linea.cantidad then
    insert into public.lineas_cuenta (sucursal_id, cuenta_id, producto_id, nombre_producto, precio_unitario, tasa_iva,
                                      cantidad, observacion, enviada_en, reemplaza_linea_id, creado_por)
    values (v_linea.sucursal_id, v_linea.cuenta_id, v_linea.producto_id, v_linea.nombre_producto,
            v_linea.precio_unitario, v_linea.tasa_iva, v_linea.cantidad - v_qty, v_linea.observacion,
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

-- El mesero pide la cuenta: ya no se agregan productos y caja puede cobrar.
create function public.pedir_cuenta(p_mesa_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_mesa public.mesas;
  v_cuenta public.cuentas;
begin
  perform privado.exigir_perfil('propietario', 'mesero');
  v_mesa := privado.bloquear_mesa(p_mesa_id);
  v_cuenta := privado.cuenta_de_mesa(v_mesa.id);
  if v_cuenta.id is null then
    raise exception '% no tiene pedido', privado.nombre_grupo(v_mesa.id);
  end if;
  if v_cuenta.estado = 'por_cobrar' then
    return;
  end if;
  if not exists (select 1 from public.lineas_cuenta l where l.cuenta_id = v_cuenta.id and l.estado = 'activa') then
    raise exception 'La cuenta no tiene productos';
  end if;
  perform privado.fijar_accion('Pidió la cuenta de ' || privado.nombre_grupo(v_mesa.id));
  update public.cuentas set estado = 'por_cobrar', cuenta_pedida_en = now() where id = v_cuenta.id;
  perform privado.fijar_estado_grupo(v_mesa.id, 'por_cobrar');
end
$$;

-- Une dos o más mesas. La principal es la que tiene cuenta (o la primera).
create function public.unir_mesas(p_mesa_ids uuid[]) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_raices uuid[];
  v_principal uuid;
  v_estado public.estado_mesa;
  v_miembros uuid[];
  v_con_cuenta integer;
begin
  perform privado.exigir_perfil('propietario', 'mesero');
  select array_agg(distinct privado.mesa_principal(x)) into v_raices from unnest(p_mesa_ids) x;
  if v_raices is null or array_position(v_raices, null) is not null then
    raise exception 'Una de las mesas no existe';
  end if;
  if cardinality(v_raices) < 2 then
    raise exception 'Elige al menos dos mesas distintas';
  end if;

  perform 1 from public.mesas where id = any (v_raices) or unida_a = any (v_raices) order by id for update;
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

-- Separa un grupo: la principal conserva la cuenta; las demás quedan libres.
create function public.separar_mesas(p_mesa_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_principal uuid;
  v_nombre text;
  v_miembros uuid[];
begin
  perform privado.exigir_perfil('propietario', 'mesero');
  v_principal := privado.mesa_principal(p_mesa_id);
  if v_principal is null then
    raise exception 'La mesa no existe';
  end if;
  perform 1 from public.mesas where id = v_principal or unida_a = v_principal order by id for update;
  select array_agg(id order by id <> v_principal, orden) into v_miembros
  from public.mesas where id = v_principal or unida_a = v_principal;
  if cardinality(v_miembros) < 2 then
    raise exception 'La mesa no está unida a otra';
  end if;
  v_nombre := privado.nombre_grupo(v_principal);
  perform privado.fijar_accion('Separó ' || v_nombre);
  update public.mesas set unida_a = null, estado = 'disponible' where unida_a = v_principal;
  insert into public.uniones_mesas (sucursal_id, operacion, mesa_ids, cuenta_id)
  select m.sucursal_id, 'separacion', v_miembros, (privado.cuenta_de_mesa(v_principal)).id
  from public.mesas m where m.id = v_principal;
end
$$;

-- -----------------------------------------------------------------------------
-- Administración de mesas (propietario)
-- -----------------------------------------------------------------------------
create function privado.validar_nombre_mesa(p_nombre text, p_excepto uuid default null) returns text
language plpgsql stable
set search_path = ''
as $$
declare
  v text := trim(coalesce(p_nombre, ''));
begin
  if length(v) = 0 or length(v) > 40 then
    raise exception 'Escribe un nombre de mesa (hasta 40 letras)';
  end if;
  if exists (select 1 from public.mesas m where lower(m.nombre) = lower(v) and m.eliminada_en is null
             and m.id is distinct from p_excepto) then
    raise exception 'Ya existe una mesa llamada %', v;
  end if;
  return v;
end
$$;

create function public.crear_mesa(p_nombre text) returns public.mesas
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_nombre text := privado.validar_nombre_mesa(p_nombre);
  v_fila public.mesas;
begin
  perform privado.fijar_accion('Agregó la mesa ' || v_nombre);
  insert into public.mesas (sucursal_id, nombre, orden)
  select u.sucursal_id, v_nombre, coalesce((select max(orden) from public.mesas), 0) + 1
  from public.usuarios u where u.id = v_actor
  returning * into v_fila;
  return v_fila;
end
$$;

create function public.renombrar_mesa(p_id uuid, p_nombre text) returns public.mesas
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fila public.mesas;
  v_nombre text;
begin
  perform privado.exigir_perfil('propietario');
  select * into v_fila from public.mesas where id = p_id and eliminada_en is null for update;
  if not found then
    raise exception 'La mesa no existe';
  end if;
  v_nombre := privado.validar_nombre_mesa(p_nombre, p_id);
  perform privado.fijar_accion(format('Renombró %s a %s', v_fila.nombre, v_nombre));
  update public.mesas set nombre = v_nombre where id = p_id returning * into v_fila;
  return v_fila;
end
$$;

-- Orden de visualización: la lista completa de mesas en el orden deseado.
create function public.ordenar_mesas(p_ids uuid[]) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  perform privado.exigir_perfil('propietario');
  perform privado.fijar_accion('Cambió el orden de las mesas');
  update public.mesas m set orden = x.pos
  from unnest(p_ids) with ordinality as x(id, pos)
  where m.id = x.id and m.orden is distinct from x.pos;
end
$$;

create function public.activar_mesa(p_id uuid, p_activa boolean) returns public.mesas
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fila public.mesas;
begin
  perform privado.exigir_perfil('propietario');
  select * into v_fila from public.mesas where id = p_id and eliminada_en is null for update;
  if not found then
    raise exception 'La mesa no existe';
  end if;
  if v_fila.activa = p_activa then
    return v_fila;
  end if;
  if not p_activa and (v_fila.estado <> 'disponible' or v_fila.unida_a is not null
                       or exists (select 1 from public.mesas where unida_a = p_id)) then
    raise exception '% está en servicio o unida a otra. Libérala o sepárala antes de desactivarla.', v_fila.nombre;
  end if;
  perform privado.fijar_accion((case when p_activa then 'Activó ' else 'Desactivó ' end) || v_fila.nombre);
  update public.mesas set activa = p_activa where id = p_id returning * into v_fila;
  return v_fila;
end
$$;

-- Eliminar: deja de aparecer, pero se conserva con todo su historial.
create function public.eliminar_mesa(p_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_fila public.mesas;
begin
  select * into v_fila from public.mesas where id = p_id and eliminada_en is null for update;
  if not found then
    raise exception 'La mesa no existe';
  end if;
  if v_fila.estado <> 'disponible' or v_fila.unida_a is not null
     or exists (select 1 from public.mesas where unida_a = p_id) then
    raise exception '% está en servicio o unida a otra. Libérala o sepárala antes de eliminarla.', v_fila.nombre;
  end if;
  perform privado.fijar_accion('Eliminó ' || v_fila.nombre);
  update public.mesas set activa = false, eliminada_en = now(), eliminada_por = v_actor where id = p_id;
end
$$;

-- -----------------------------------------------------------------------------
-- Permisos y tiempo real
-- -----------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema privado from public, anon, authenticated;

grant execute on function
  privado.actor(), privado.perfil_actual(), privado.es_propietario(),
  privado.tiene_perfil(public.perfil_usuario[])
to authenticated, service_role;

grant execute on function
  public.yo(),
  public.registrar_usuario(uuid, text, text, public.perfil_usuario),
  public.renombrar_usuario(uuid, text),
  public.cambiar_perfil_usuario(uuid, public.perfil_usuario),
  public.dar_de_baja_usuario(uuid, text),
  public.reactivar_usuario(uuid),
  public.registrar_cambio_contrasena(uuid),
  public.marcar_avisos_leidos(bigint[]),
  public.solicitar_autorizacion(public.tipo_autorizacion, uuid, text, uuid, uuid),
  public.resolver_autorizacion(uuid, boolean, text),
  public.ocupar_mesa(uuid),
  public.liberar_mesa(uuid),
  public.enviar_pedido(uuid, jsonb, uuid),
  public.quitar_producto(uuid, text, integer),
  public.pedir_cuenta(uuid),
  public.unir_mesas(uuid[]),
  public.separar_mesas(uuid),
  public.crear_mesa(text),
  public.renombrar_mesa(uuid, text),
  public.ordenar_mesas(uuid[]),
  public.activar_mesa(uuid, boolean),
  public.eliminar_mesa(uuid)
to authenticated;
grant execute on function public.instalar_propietario(uuid, text, text) to service_role;

-- Cambios en vivo para las pantallas (Realtime respeta los mismos permisos).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table
      public.mesas, public.cuentas, public.lineas_cuenta, public.comandas,
      public.avisos, public.autorizaciones, public.usuarios;
  end if;
end
$$;
