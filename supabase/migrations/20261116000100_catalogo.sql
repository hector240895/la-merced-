-- =============================================================================
-- Sistema La Merced · Etapa 7 · Catálogo
--
-- Los propietarios administran el menú sin programador: categorías, productos,
-- precios, descripciones, orden, opciones (sabores, guisados…), fotos,
-- duplicar, ocultar y eliminar (baja lógica: se conserva en el historial).
-- Meseros, caja y propietarios marcan un producto como agotado o disponible.
-- Cada cambio queda en la auditoría; los de un propietario avisan al otro.
-- Los cambios de precio quedan en el historial de precios y no alteran las
-- cuentas ya abiertas (cada línea guarda su precio).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Ayudantes
-- -----------------------------------------------------------------------------
create function privado.validar_nombre_catalogo(p_nombre text, p_que text) returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v text := trim(coalesce(p_nombre, ''));
begin
  if length(v) = 0 or length(v) > 80 then
    raise exception 'Escribe el nombre % (hasta 80 letras)', p_que;
  end if;
  return v;
end
$$;

create function privado.validar_precio(p_precio numeric) returns numeric
language plpgsql immutable
set search_path = ''
as $$
begin
  if p_precio is null or p_precio < 0 or p_precio > 100000 then
    raise exception 'Escribe un precio válido';
  end if;
  return round(p_precio, 2);
end
$$;

-- Opciones de un producto: [{"etiqueta": "Guisado", "opciones": ["Deshebrada", ...]}, ...]
-- Limpia espacios, quita repetidos y valida.
create function privado.validar_selecciones(p_selecciones jsonb) returns jsonb
language plpgsql immutable
set search_path = ''
as $$
declare
  v_sel jsonb;
  v_etiqueta text;
  v_opciones jsonb;
  v_salida jsonb := '[]';
begin
  if p_selecciones is null or p_selecciones = 'null'::jsonb then
    return '[]';
  end if;
  if jsonb_typeof(p_selecciones) <> 'array' then
    raise exception 'Las opciones del producto no son válidas';
  end if;
  if jsonb_array_length(p_selecciones) > 10 then
    raise exception 'Un producto puede tener hasta 10 opciones para elegir';
  end if;
  for v_sel in select * from jsonb_array_elements(p_selecciones) loop
    v_etiqueta := trim(coalesce(v_sel ->> 'etiqueta', ''));
    if length(v_etiqueta) = 0 or length(v_etiqueta) > 40 then
      raise exception 'Cada opción necesita un nombre (por ejemplo "Guisado" o "Sabor")';
    end if;
    if jsonb_typeof(v_sel -> 'opciones') <> 'array' then
      raise exception 'La opción "%" no tiene lista', v_etiqueta;
    end if;
    select coalesce(jsonb_agg(o order by n), '[]') into v_opciones
    from (select distinct on (lower(trim(x))) trim(x) o, n
          from jsonb_array_elements_text(v_sel -> 'opciones') with ordinality as e(x, n)
          where length(trim(x)) > 0
          order by lower(trim(x)), n) d;
    if jsonb_array_length(v_opciones) < 2 then
      raise exception 'La opción "%" necesita al menos 2 elementos para elegir', v_etiqueta;
    end if;
    if jsonb_array_length(v_opciones) > 40 or exists (select 1 from jsonb_array_elements_text(v_opciones) o where length(o) > 60) then
      raise exception 'La lista de "%" es demasiado larga', v_etiqueta;
    end if;
    v_salida := v_salida || jsonb_build_array(jsonb_build_object('etiqueta', v_etiqueta, 'opciones', v_opciones));
  end loop;
  return v_salida;
end
$$;

create function privado.nombre_libre(p_categoria_id uuid, p_nombre text, p_excepto uuid default null) returns text
language plpgsql stable
set search_path = ''
as $$
begin
  if exists (select 1 from public.productos p where p.categoria_id = p_categoria_id and lower(p.nombre) = lower(p_nombre)
             and p.eliminado_en is null and p.id is distinct from p_excepto) then
    raise exception 'Ya existe "%" en esa categoría', p_nombre;
  end if;
  return p_nombre;
end
$$;

-- -----------------------------------------------------------------------------
-- Categorías (propietarios)
-- -----------------------------------------------------------------------------
create function public.crear_categoria(p_nombre text) returns public.categorias
language plpgsql security definer
set search_path = ''
as $$
declare
  v_nombre text := privado.validar_nombre_catalogo(p_nombre, 'de la categoría');
  v_fila public.categorias;
begin
  perform privado.exigir_perfil('propietario');
  if exists (select 1 from public.categorias where lower(nombre) = lower(v_nombre) and eliminada_en is null) then
    raise exception 'Ya existe la categoría %', v_nombre;
  end if;
  perform privado.fijar_accion('Agregó la categoría ' || v_nombre);
  insert into public.categorias (sucursal_id, nombre, orden)
  values (privado.sucursal_del_actor(), v_nombre, coalesce((select max(orden) from public.categorias where eliminada_en is null), 0) + 1)
  returning * into v_fila;
  return v_fila;
end
$$;

create function public.renombrar_categoria(p_id uuid, p_nombre text) returns public.categorias
language plpgsql security definer
set search_path = ''
as $$
declare
  v_nombre text := privado.validar_nombre_catalogo(p_nombre, 'de la categoría');
  v_fila public.categorias;
begin
  perform privado.exigir_perfil('propietario');
  select * into v_fila from public.categorias where id = p_id and eliminada_en is null for update;
  if not found then
    raise exception 'La categoría no existe';
  end if;
  if exists (select 1 from public.categorias where lower(nombre) = lower(v_nombre) and eliminada_en is null and id <> p_id) then
    raise exception 'Ya existe la categoría %', v_nombre;
  end if;
  perform privado.fijar_accion(format('Renombró la categoría %s a %s', v_fila.nombre, v_nombre));
  update public.categorias set nombre = v_nombre where id = p_id returning * into v_fila;
  return v_fila;
end
$$;

create function public.ordenar_categorias(p_ids uuid[]) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  perform privado.exigir_perfil('propietario');
  if p_ids is null or array_position(p_ids, null) is not null
     or (select count(distinct x) from unnest(p_ids) x) <> cardinality(p_ids) then
    raise exception 'Indica el orden de las categorías sin repetir';
  end if;
  perform privado.fijar_accion('Cambió el orden de las categorías');
  update public.categorias c set orden = x.pos
  from unnest(p_ids) with ordinality as x(id, pos)
  where c.id = x.id and c.eliminada_en is null and c.orden is distinct from x.pos;
end
$$;

-- Ocultar o mostrar una categoría completa (por ejemplo, de temporada).
create function public.activar_categoria(p_id uuid, p_activa boolean) returns public.categorias
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fila public.categorias;
begin
  perform privado.exigir_perfil('propietario');
  select * into v_fila from public.categorias where id = p_id and eliminada_en is null for update;
  if not found then
    raise exception 'La categoría no existe';
  end if;
  perform privado.fijar_accion((case when p_activa then 'Mostró la categoría ' else 'Ocultó la categoría ' end) || v_fila.nombre);
  update public.categorias set activa = p_activa where id = p_id returning * into v_fila;
  return v_fila;
end
$$;

create function public.eliminar_categoria(p_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_fila public.categorias;
begin
  select * into v_fila from public.categorias where id = p_id and eliminada_en is null for update;
  if not found then
    raise exception 'La categoría no existe';
  end if;
  if exists (select 1 from public.productos where categoria_id = p_id and eliminado_en is null) then
    raise exception 'La categoría % todavía tiene productos. Muévelos o elimínalos primero.', v_fila.nombre;
  end if;
  perform privado.fijar_accion('Eliminó la categoría ' || v_fila.nombre);
  update public.categorias set activa = false, eliminada_en = now(), eliminada_por = v_actor where id = p_id;
end
$$;

-- -----------------------------------------------------------------------------
-- Productos (propietarios)
-- -----------------------------------------------------------------------------
create function public.crear_producto(
  p_categoria_id uuid, p_nombre text, p_precio numeric, p_descripcion text default null, p_selecciones jsonb default '[]'
) returns public.productos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_nombre text := privado.validar_nombre_catalogo(p_nombre, 'del producto');
  v_fila public.productos;
begin
  perform privado.exigir_perfil('propietario');
  if not exists (select 1 from public.categorias where id = p_categoria_id and eliminada_en is null) then
    raise exception 'Elige una categoría';
  end if;
  perform privado.nombre_libre(p_categoria_id, v_nombre);
  perform privado.fijar_accion(format('Agregó el producto %s a $%s', v_nombre, privado.validar_precio(p_precio)));
  insert into public.productos (sucursal_id, categoria_id, nombre, descripcion, precio, orden, selecciones)
  values (privado.sucursal_del_actor(), p_categoria_id, v_nombre, nullif(trim(p_descripcion), ''), privado.validar_precio(p_precio),
          coalesce((select max(orden) from public.productos where categoria_id = p_categoria_id and eliminado_en is null), 0) + 1,
          privado.validar_selecciones(p_selecciones))
  returning * into v_fila;
  return v_fila;
end
$$;

create function public.editar_producto(
  p_id uuid, p_categoria_id uuid, p_nombre text, p_precio numeric, p_descripcion text, p_selecciones jsonb
) returns public.productos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_nombre text := privado.validar_nombre_catalogo(p_nombre, 'del producto');
  v_precio numeric := privado.validar_precio(p_precio);
  v_sel jsonb := privado.validar_selecciones(p_selecciones);
  v_antes public.productos;
  v_fila public.productos;
  v_cambios text[] := '{}';
begin
  perform privado.exigir_perfil('propietario');
  select * into v_antes from public.productos where id = p_id and eliminado_en is null for update;
  if not found then
    raise exception 'El producto no existe';
  end if;
  if not exists (select 1 from public.categorias where id = p_categoria_id and eliminada_en is null) then
    raise exception 'Elige una categoría';
  end if;
  perform privado.nombre_libre(p_categoria_id, v_nombre, p_id);

  if v_nombre <> v_antes.nombre then v_cambios := v_cambios || format('nombre a "%s"', v_nombre); end if;
  if v_precio <> v_antes.precio then v_cambios := v_cambios || format('precio de $%s a $%s', v_antes.precio, v_precio); end if;
  if p_categoria_id <> v_antes.categoria_id then
    v_cambios := v_cambios || ('categoría a ' || (select nombre from public.categorias where id = p_categoria_id));
  end if;
  if nullif(trim(p_descripcion), '') is distinct from v_antes.descripcion then v_cambios := v_cambios || 'descripción'::text; end if;
  if v_sel <> v_antes.selecciones then v_cambios := v_cambios || 'opciones para elegir'::text; end if;
  if cardinality(v_cambios) = 0 then
    return v_antes;
  end if;

  perform privado.fijar_accion(format('Cambió %s: %s', v_antes.nombre, array_to_string(v_cambios, ', ')));
  update public.productos
     set nombre = v_nombre, precio = v_precio, descripcion = nullif(trim(p_descripcion), ''), selecciones = v_sel,
         categoria_id = p_categoria_id,
         orden = case when p_categoria_id <> v_antes.categoria_id
                      then coalesce((select max(orden) from public.productos where categoria_id = p_categoria_id and eliminado_en is null), 0) + 1
                      else orden end
   where id = p_id
  returning * into v_fila;
  return v_fila;
end
$$;

create function public.duplicar_producto(p_id uuid) returns public.productos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_origen public.productos;
  v_nombre text;
  v_n integer := 1;
  v_fila public.productos;
begin
  perform privado.exigir_perfil('propietario');
  select * into v_origen from public.productos where id = p_id and eliminado_en is null;
  if not found then
    raise exception 'El producto no existe';
  end if;
  loop
    v_nombre := left(v_origen.nombre, 70) || case when v_n = 1 then ' (copia)' else format(' (copia %s)', v_n) end;
    exit when not exists (select 1 from public.productos where categoria_id = v_origen.categoria_id
                          and lower(nombre) = lower(v_nombre) and eliminado_en is null);
    v_n := v_n + 1;
  end loop;
  perform privado.fijar_accion(format('Duplicó %s como %s', v_origen.nombre, v_nombre));
  insert into public.productos (sucursal_id, categoria_id, nombre, descripcion, precio, tasa_iva, orden, selecciones, foto_url)
  values (v_origen.sucursal_id, v_origen.categoria_id, v_nombre, v_origen.descripcion, v_origen.precio, v_origen.tasa_iva,
          v_origen.orden, v_origen.selecciones, v_origen.foto_url)
  returning * into v_fila;
  return v_fila;
end
$$;

create function public.ordenar_productos(p_categoria_id uuid, p_ids uuid[]) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  perform privado.exigir_perfil('propietario');
  if p_ids is null or array_position(p_ids, null) is not null
     or (select count(distinct x) from unnest(p_ids) x) <> cardinality(p_ids) then
    raise exception 'Indica el orden de los productos sin repetir';
  end if;
  perform privado.fijar_accion('Cambió el orden de los productos de ' || (select nombre from public.categorias where id = p_categoria_id));
  update public.productos p set orden = x.pos
  from unnest(p_ids) with ordinality as x(id, pos)
  where p.id = x.id and p.categoria_id = p_categoria_id and p.eliminado_en is null and p.orden is distinct from x.pos;
end
$$;

-- Ocultar un producto (no aparece a meseros ni caja) o volver a mostrarlo.
create function public.ocultar_producto(p_id uuid, p_oculto boolean) returns public.productos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fila public.productos;
begin
  perform privado.exigir_perfil('propietario');
  select * into v_fila from public.productos where id = p_id and eliminado_en is null for update;
  if not found then
    raise exception 'El producto no existe';
  end if;
  perform privado.fijar_accion((case when p_oculto then 'Ocultó ' else 'Volvió a mostrar ' end) || v_fila.nombre);
  update public.productos set estado = case when p_oculto then 'inactivo' else 'activo' end::public.estado_producto
   where id = p_id
  returning * into v_fila;
  return v_fila;
end
$$;

create function public.eliminar_producto(p_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_fila public.productos;
begin
  select * into v_fila from public.productos where id = p_id and eliminado_en is null for update;
  if not found then
    raise exception 'El producto no existe';
  end if;
  perform privado.fijar_accion('Eliminó el producto ' || v_fila.nombre);
  update public.productos set estado = 'inactivo', eliminado_en = now(), eliminado_por = v_actor where id = p_id;
end
$$;

-- Foto del producto: la app la sube al almacenamiento y aquí se guarda la ruta
-- (o se quita con null). Las fotos solo se ven en el catálogo.
create function public.cambiar_foto_producto(p_id uuid, p_ruta text) returns public.productos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fila public.productos;
begin
  perform privado.exigir_perfil('propietario');
  select * into v_fila from public.productos where id = p_id and eliminado_en is null for update;
  if not found then
    raise exception 'El producto no existe';
  end if;
  if p_ruta is not null and p_ruta !~ ('^' || p_id::text || '/[A-Za-z0-9._-]+$') then
    raise exception 'Foto no válida';
  end if;
  perform privado.fijar_accion((case when p_ruta is null then 'Quitó la foto de ' else 'Cambió la foto de ' end) || v_fila.nombre);
  update public.productos set foto_url = p_ruta where id = p_id returning * into v_fila;
  return v_fila;
end
$$;

-- -----------------------------------------------------------------------------
-- Disponibilidad: meseros, caja y propietarios
-- -----------------------------------------------------------------------------
create function public.marcar_agotado(p_id uuid, p_agotado boolean) returns public.productos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fila public.productos;
begin
  perform privado.exigir_perfil('propietario', 'cajero', 'mesero');
  select * into v_fila from public.productos where id = p_id and eliminado_en is null for update;
  if not found or v_fila.estado = 'inactivo' then
    raise exception 'El producto no está en el menú';
  end if;
  if (v_fila.estado = 'agotado') = p_agotado then
    return v_fila;
  end if;
  perform privado.fijar_accion((case when p_agotado then 'Marcó agotado: ' else 'Marcó disponible: ' end) || v_fila.nombre);
  update public.productos set estado = case when p_agotado then 'agotado' else 'activo' end::public.estado_producto
   where id = p_id
  returning * into v_fila;
  return v_fila;
end
$$;

-- -----------------------------------------------------------------------------
-- Almacenamiento de fotos (privado: solo propietarios)
-- -----------------------------------------------------------------------------
do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('fotos-productos', 'fotos-productos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
    on conflict (id) do nothing;

    -- Las fotos no se borran: al cambiarla, la anterior queda guardada.
    execute $p$create policy fotos_productos_leer on storage.objects for select to authenticated
      using (bucket_id = 'fotos-productos' and (select privado.es_propietario()))$p$;
    execute $p$create policy fotos_productos_subir on storage.objects for insert to authenticated
      with check (bucket_id = 'fotos-productos' and (select privado.es_propietario()))$p$;
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- Permisos y tiempo real
-- -----------------------------------------------------------------------------
revoke execute on function privado.validar_nombre_catalogo(text, text), privado.validar_precio(numeric),
  privado.validar_selecciones(jsonb), privado.nombre_libre(uuid, text, uuid) from public, anon, authenticated;

revoke execute on function public.crear_categoria(text), public.renombrar_categoria(uuid, text), public.ordenar_categorias(uuid[]),
  public.activar_categoria(uuid, boolean), public.eliminar_categoria(uuid),
  public.crear_producto(uuid, text, numeric, text, jsonb), public.editar_producto(uuid, uuid, text, numeric, text, jsonb),
  public.duplicar_producto(uuid), public.ordenar_productos(uuid, uuid[]), public.ocultar_producto(uuid, boolean),
  public.eliminar_producto(uuid), public.cambiar_foto_producto(uuid, text), public.marcar_agotado(uuid, boolean)
  from public, anon;
grant execute on function public.crear_categoria(text), public.renombrar_categoria(uuid, text), public.ordenar_categorias(uuid[]),
  public.activar_categoria(uuid, boolean), public.eliminar_categoria(uuid),
  public.crear_producto(uuid, text, numeric, text, jsonb), public.editar_producto(uuid, uuid, text, numeric, text, jsonb),
  public.duplicar_producto(uuid), public.ordenar_productos(uuid, uuid[]), public.ocultar_producto(uuid, boolean),
  public.eliminar_producto(uuid), public.cambiar_foto_producto(uuid, text), public.marcar_agotado(uuid, boolean)
  to authenticated;

-- El menú se actualiza en vivo en los celulares (por ejemplo, al marcar agotado).
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['productos', 'categorias'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end
$$;
