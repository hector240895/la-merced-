-- =============================================================================
-- Sistema La Merced · Etapa 8 · Inventario (manual)
--
-- Las existencias cambian SOLO con movimientos registrados a mano. Vender un
-- platillo nunca descuenta nada del inventario.
--
--   * Insumos (nombre, unidad, mínimo para alerta, proveedor) y proveedores.
--   * Movimientos: compra, entrada, merma y ajuste por conteo físico. No se
--     editan ni se borran: una corrección es un movimiento nuevo.
--   * Una compra registra también el gasto (Compras y mercancía) con su detalle.
--   * Compras y entradas: caja y propietarios. Mermas, ajustes, insumos y
--     proveedores: solo propietarios.
--   * Los costos son información de los propietarios: el cajero los captura
--     al registrar una compra, pero no consulta el historial de costos.
-- =============================================================================

create type public.tipo_movimiento_inventario as enum ('compra', 'entrada', 'merma', 'ajuste');

create table public.proveedores (
  id            uuid primary key default gen_random_uuid(),
  sucursal_id   uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  nombre        text not null check (length(trim(nombre)) between 1 and 80),
  telefono      text check (length(telefono) <= 40),
  notas         text check (length(notas) <= 300),
  eliminado_en  timestamptz,
  eliminado_por uuid references public.usuarios (id),
  creado_en     timestamptz not null default now(),
  creado_por    uuid references public.usuarios (id) default privado.actor(),
  constraint proveedores_eliminado check ((eliminado_en is null) = (eliminado_por is null))
);
create unique index proveedores_nombre_unico on public.proveedores (sucursal_id, lower(nombre)) where eliminado_en is null;

create table public.insumos (
  id            uuid primary key default gen_random_uuid(),
  sucursal_id   uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  nombre        text not null check (length(trim(nombre)) between 1 and 80),
  unidad        text not null check (length(trim(unidad)) between 1 and 20),
  minimo        numeric(12, 3) not null default 0 check (minimo >= 0),
  existencia    numeric(12, 3) not null default 0 check (existencia >= 0),   -- solo la cambian los movimientos
  proveedor_id  uuid references public.proveedores (id),
  eliminado_en  timestamptz,
  eliminado_por uuid references public.usuarios (id),
  creado_en     timestamptz not null default now(),
  creado_por    uuid references public.usuarios (id) default privado.actor(),
  constraint insumos_eliminado check ((eliminado_en is null) = (eliminado_por is null))
);
create unique index insumos_nombre_unico on public.insumos (sucursal_id, lower(nombre)) where eliminado_en is null;

create table public.movimientos_inventario (
  id                   uuid primary key default gen_random_uuid(),
  sucursal_id          uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  insumo_id            uuid not null references public.insumos (id),
  tipo                 public.tipo_movimiento_inventario not null,
  cantidad             numeric(12, 3) not null check (cantidad <> 0),   -- con signo: + entra, − sale
  existencia_anterior  numeric(12, 3) not null,
  existencia_nueva     numeric(12, 3) not null check (existencia_nueva >= 0),
  costo                numeric(12, 2) check (costo >= 0),                -- solo compras (total de ese insumo)
  proveedor_id         uuid references public.proveedores (id),
  gasto_id             uuid references public.gastos (id),
  motivo               text,
  creado_en            timestamptz not null default now(),
  creado_por           uuid references public.usuarios (id) default privado.actor(),
  constraint movimientos_inventario_cuadra check (existencia_nueva = existencia_anterior + cantidad),
  constraint movimientos_inventario_signo check (
    case tipo when 'compra' then cantidad > 0 and costo is not null and gasto_id is not null
              when 'entrada' then cantidad > 0
              when 'merma' then cantidad < 0 and length(trim(motivo)) > 0
              else length(trim(motivo)) > 0 end)
);
create index movimientos_inventario_insumo_idx on public.movimientos_inventario (insumo_id, creado_en desc);
create index movimientos_inventario_fecha_idx on public.movimientos_inventario (sucursal_id, creado_en desc);

-- Reglas: sin borrado; movimientos inmutables; auditoría.
create trigger proveedores_sin_borrado before delete on public.proveedores for each row execute function privado.prohibir_borrado();
create trigger proveedores_sin_vaciar before truncate on public.proveedores for each statement execute function privado.prohibir_borrado();
create trigger proveedores_auditar after insert or update on public.proveedores for each row execute function privado.auditar_cambios();
create trigger proveedores_inmutables before update on public.proveedores for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'creado_en', 'creado_por');
create trigger proveedores_sello before update on public.proveedores for each row
  execute function privado.sellar_columnas('eliminado_en', 'eliminado_por');

create trigger insumos_sin_borrado before delete on public.insumos for each row execute function privado.prohibir_borrado();
create trigger insumos_sin_vaciar before truncate on public.insumos for each statement execute function privado.prohibir_borrado();
create trigger insumos_auditar after insert or update on public.insumos for each row execute function privado.auditar_cambios();
create trigger insumos_inmutables before update on public.insumos for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'creado_en', 'creado_por');
create trigger insumos_sello before update on public.insumos for each row
  execute function privado.sellar_columnas('eliminado_en', 'eliminado_por');

create trigger movimientos_inventario_sin_cambios before update on public.movimientos_inventario
  for each row execute function privado.prohibir_cambio();
create trigger movimientos_inventario_sin_borrado before delete on public.movimientos_inventario
  for each row execute function privado.prohibir_borrado();
create trigger movimientos_inventario_sin_vaciar before truncate on public.movimientos_inventario
  for each statement execute function privado.prohibir_borrado();
create trigger movimientos_inventario_auditar after insert on public.movimientos_inventario
  for each row execute function privado.auditar_cambios();

-- -----------------------------------------------------------------------------
-- Ayudantes
-- -----------------------------------------------------------------------------
create function privado.validar_cantidad(p numeric) returns numeric
language plpgsql immutable
set search_path = ''
as $$
begin
  if p is null or p <= 0 or p > 1000000 then
    raise exception 'Escribe una cantidad mayor a cero';
  end if;
  return round(p, 3);
end
$$;

-- Aplica un movimiento a un insumo (bloqueado) y deja la existencia al día.
create function privado.mover_inventario(
  p_insumo_id uuid, p_tipo public.tipo_movimiento_inventario, p_cantidad numeric, p_motivo text,
  p_costo numeric default null, p_proveedor_id uuid default null, p_gasto_id uuid default null
) returns public.movimientos_inventario
language plpgsql
set search_path = ''
as $$
declare
  v_insumo public.insumos;
  v_fila public.movimientos_inventario;
begin
  select * into v_insumo from public.insumos where id = p_insumo_id and eliminado_en is null for update;
  if not found then
    raise exception 'El insumo no existe';
  end if;
  if v_insumo.existencia + p_cantidad < 0 then
    raise exception 'Solo hay % % de %', v_insumo.existencia, v_insumo.unidad, v_insumo.nombre;
  end if;
  insert into public.movimientos_inventario (sucursal_id, insumo_id, tipo, cantidad, existencia_anterior, existencia_nueva,
                                             costo, proveedor_id, gasto_id, motivo)
  values (v_insumo.sucursal_id, v_insumo.id, p_tipo, p_cantidad, v_insumo.existencia, v_insumo.existencia + p_cantidad,
          p_costo, p_proveedor_id, p_gasto_id, nullif(trim(p_motivo), ''))
  returning * into v_fila;
  update public.insumos set existencia = v_fila.existencia_nueva where id = v_insumo.id;
  return v_fila;
end
$$;

-- Lo que registra el cajero con dinero (compras) también se avisa a los propietarios.
create function privado.avisar_propietarios(p_accion text, p_tabla text, p_registro text) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_aud bigint;
begin
  if privado.perfil_actual() = 'propietario' then
    return;   -- los movimientos de un propietario ya avisan al otro
  end if;
  v_aud := privado.registrar_auditoria(p_accion, p_tabla, p_registro);
  insert into public.avisos (sucursal_id, para_usuario_id, auditoria_id)
  select u.sucursal_id, u.id, v_aud from public.usuarios u where u.perfil = 'propietario' and u.activo;
end
$$;

-- -----------------------------------------------------------------------------
-- Proveedores (propietarios)
-- -----------------------------------------------------------------------------
create function public.guardar_proveedor(p_id uuid, p_nombre text, p_telefono text default null, p_notas text default null)
returns public.proveedores
language plpgsql security definer
set search_path = ''
as $$
declare
  v_nombre text := trim(coalesce(p_nombre, ''));
  v_fila public.proveedores;
begin
  perform privado.exigir_perfil('propietario');
  if length(v_nombre) = 0 then
    raise exception 'Escribe el nombre del proveedor';
  end if;
  if exists (select 1 from public.proveedores where lower(nombre) = lower(v_nombre) and eliminado_en is null and id is distinct from p_id) then
    raise exception 'Ya existe el proveedor %', v_nombre;
  end if;
  if p_id is null then
    perform privado.fijar_accion('Agregó el proveedor ' || v_nombre);
    insert into public.proveedores (sucursal_id, nombre, telefono, notas)
    values (privado.sucursal_del_actor(), v_nombre, nullif(trim(p_telefono), ''), nullif(trim(p_notas), ''))
    returning * into v_fila;
  else
    perform privado.fijar_accion('Cambió los datos del proveedor ' || v_nombre);
    update public.proveedores set nombre = v_nombre, telefono = nullif(trim(p_telefono), ''), notas = nullif(trim(p_notas), '')
     where id = p_id and eliminado_en is null
    returning * into v_fila;
    if not found then
      raise exception 'El proveedor no existe';
    end if;
  end if;
  return v_fila;
end
$$;

create function public.eliminar_proveedor(p_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_fila public.proveedores;
begin
  select * into v_fila from public.proveedores where id = p_id and eliminado_en is null for update;
  if not found then
    raise exception 'El proveedor no existe';
  end if;
  perform privado.fijar_accion('Eliminó el proveedor ' || v_fila.nombre);
  update public.proveedores set eliminado_en = now(), eliminado_por = v_actor where id = p_id;
  update public.insumos set proveedor_id = null where proveedor_id = p_id and eliminado_en is null;
end
$$;

-- -----------------------------------------------------------------------------
-- Insumos (propietarios)
-- -----------------------------------------------------------------------------
create function public.guardar_insumo(
  p_id uuid, p_nombre text, p_unidad text, p_minimo numeric, p_proveedor_id uuid default null, p_existencia_inicial numeric default 0
) returns public.insumos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_nombre text := trim(coalesce(p_nombre, ''));
  v_unidad text := lower(trim(coalesce(p_unidad, '')));
  v_fila public.insumos;
begin
  perform privado.exigir_perfil('propietario');
  if length(v_nombre) = 0 or length(v_nombre) > 80 then
    raise exception 'Escribe el nombre del insumo';
  end if;
  if length(v_unidad) = 0 or length(v_unidad) > 20 then
    raise exception 'Escribe la unidad (kg, pieza, litro…)';
  end if;
  if p_minimo is null or p_minimo < 0 then
    raise exception 'Escribe la existencia mínima (0 si no quieres alerta)';
  end if;
  if p_proveedor_id is not null and not exists (select 1 from public.proveedores where id = p_proveedor_id and eliminado_en is null) then
    raise exception 'El proveedor no existe';
  end if;
  if exists (select 1 from public.insumos where lower(nombre) = lower(v_nombre) and eliminado_en is null and id is distinct from p_id) then
    raise exception 'Ya existe el insumo %', v_nombre;
  end if;
  if p_id is null then
    perform privado.fijar_accion(format('Agregó el insumo %s (%s)', v_nombre, v_unidad));
    insert into public.insumos (sucursal_id, nombre, unidad, minimo, proveedor_id)
    values (privado.sucursal_del_actor(), v_nombre, v_unidad, round(p_minimo, 3), p_proveedor_id)
    returning * into v_fila;
    if coalesce(p_existencia_inicial, 0) > 0 then
      perform privado.fijar_accion(format('Existencia inicial de %s: %s %s', v_nombre, p_existencia_inicial, v_unidad));
      perform privado.mover_inventario(v_fila.id, 'ajuste', privado.validar_cantidad(p_existencia_inicial), 'Existencia inicial');
      select * into v_fila from public.insumos where id = v_fila.id;
    end if;
  else
    perform privado.fijar_accion('Cambió los datos del insumo ' || v_nombre);
    update public.insumos set nombre = v_nombre, unidad = v_unidad, minimo = round(p_minimo, 3), proveedor_id = p_proveedor_id
     where id = p_id and eliminado_en is null
    returning * into v_fila;
    if not found then
      raise exception 'El insumo no existe';
    end if;
  end if;
  return v_fila;
end
$$;

create function public.eliminar_insumo(p_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_fila public.insumos;
begin
  select * into v_fila from public.insumos where id = p_id and eliminado_en is null for update;
  if not found then
    raise exception 'El insumo no existe';
  end if;
  perform privado.fijar_accion('Eliminó el insumo ' || v_fila.nombre);
  update public.insumos set eliminado_en = now(), eliminado_por = v_actor where id = p_id;
end
$$;

-- -----------------------------------------------------------------------------
-- Movimientos
-- -----------------------------------------------------------------------------

-- Compra (caja y propietarios): suma al inventario y registra el gasto con su
-- detalle. p_productos: [{"insumo_id": "...", "cantidad": 10, "costo": 250}, ...]
create function public.registrar_compra(p_proveedor_id uuid, p_productos jsonb, p_nota text default null)
returns public.gastos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_item record;
  v_insumo public.insumos;
  v_total numeric;
  v_gasto public.gastos;
  v_proveedor text;
  v_n integer;
begin
  perform privado.exigir_perfil('propietario', 'cajero');
  if p_productos is null or jsonb_typeof(p_productos) <> 'array' or jsonb_array_length(p_productos) = 0 then
    raise exception 'Agrega al menos un insumo a la compra';
  end if;
  if p_proveedor_id is not null then
    select nombre into v_proveedor from public.proveedores where id = p_proveedor_id and eliminado_en is null;
    if not found then
      raise exception 'El proveedor no existe';
    end if;
  end if;
  if exists (select 1 from jsonb_to_recordset(p_productos) as x(insumo_id uuid, cantidad numeric, costo numeric)
             where x.insumo_id is null or x.cantidad is null or x.cantidad <= 0 or x.costo is null or x.costo < 0) then
    raise exception 'Cada insumo de la compra necesita cantidad y costo';
  end if;
  if (select count(*) from jsonb_array_elements(p_productos)) <> (select count(distinct x ->> 'insumo_id') from jsonb_array_elements(p_productos) x) then
    raise exception 'Un insumo aparece dos veces en la compra';
  end if;
  select sum(round(x.costo, 2)), count(*) into v_total, v_n from jsonb_to_recordset(p_productos) as x(costo numeric);
  if v_total <= 0 then
    raise exception 'Escribe el costo de la compra';
  end if;

  perform privado.fijar_accion(format('Registró una compra de $%s%s (%s insumos)', v_total,
                                      coalesce(' a ' || v_proveedor, ''), v_n), p_nota);
  insert into public.gastos (sucursal_id, categoria, concepto, monto)
  values (privado.sucursal_del_actor(), 'compras_mercancia',
          left('Compra' || coalesce(' a ' || v_proveedor, '') || coalesce(': ' || nullif(trim(p_nota), ''), ''), 200), v_total)
  returning * into v_gasto;

  for v_item in select * from jsonb_to_recordset(p_productos) as x(insumo_id uuid, cantidad numeric, costo numeric) loop
    select * into v_insumo from public.insumos where id = v_item.insumo_id and eliminado_en is null;
    if not found then
      raise exception 'Un insumo de la compra no existe';
    end if;
    insert into public.gasto_productos (sucursal_id, gasto_id, producto, cantidad, costo)
    values (v_gasto.sucursal_id, v_gasto.id, v_insumo.nombre || ' (' || v_insumo.unidad || ')',
            privado.validar_cantidad(v_item.cantidad), round(v_item.costo, 2));
    perform privado.mover_inventario(v_insumo.id, 'compra', privado.validar_cantidad(v_item.cantidad), p_nota,
                                     round(v_item.costo, 2), p_proveedor_id, v_gasto.id);
  end loop;

  perform privado.avisar_propietarios(format('Registró una compra de $%s%s', v_total, coalesce(' a ' || v_proveedor, '')),
                                      'gastos', v_gasto.id::text);
  return v_gasto;
end
$$;

-- Entrada sin compra (regalo, devolución…): caja y propietarios.
create function public.registrar_entrada(p_insumo_id uuid, p_cantidad numeric, p_motivo text)
returns public.movimientos_inventario
language plpgsql security definer
set search_path = ''
as $$
declare
  v_insumo public.insumos;
begin
  perform privado.exigir_perfil('propietario', 'cajero');
  if coalesce(length(trim(p_motivo)), 0) = 0 then
    raise exception 'Escribe de dónde viene la entrada';
  end if;
  select * into v_insumo from public.insumos where id = p_insumo_id and eliminado_en is null;
  if not found then
    raise exception 'El insumo no existe';
  end if;
  perform privado.fijar_accion(format('Registró una entrada de %s %s de %s', privado.validar_cantidad(p_cantidad), v_insumo.unidad, v_insumo.nombre), p_motivo);
  return privado.mover_inventario(p_insumo_id, 'entrada', privado.validar_cantidad(p_cantidad), p_motivo);
end
$$;

-- Merma (se echó a perder, caducó…): propietarios, con motivo.
create function public.registrar_merma(p_insumo_id uuid, p_cantidad numeric, p_motivo text)
returns public.movimientos_inventario
language plpgsql security definer
set search_path = ''
as $$
declare
  v_insumo public.insumos;
begin
  perform privado.exigir_perfil('propietario');
  if coalesce(length(trim(p_motivo)), 0) = 0 then
    raise exception 'Escribe el motivo de la merma';
  end if;
  select * into v_insumo from public.insumos where id = p_insumo_id and eliminado_en is null;
  if not found then
    raise exception 'El insumo no existe';
  end if;
  perform privado.fijar_accion(format('Registró una merma de %s %s de %s', privado.validar_cantidad(p_cantidad), v_insumo.unidad, v_insumo.nombre), p_motivo);
  return privado.mover_inventario(p_insumo_id, 'merma', -privado.validar_cantidad(p_cantidad), p_motivo);
end
$$;

-- Ajuste por conteo físico: propietarios. Registra la diferencia con lo anotado.
create function public.ajustar_existencia(p_insumo_id uuid, p_contado numeric, p_motivo text default 'Conteo físico')
returns public.movimientos_inventario
language plpgsql security definer
set search_path = ''
as $$
declare
  v_insumo public.insumos;
  v_dif numeric;
begin
  perform privado.exigir_perfil('propietario');
  if p_contado is null or p_contado < 0 then
    raise exception 'Escribe cuánto contaste';
  end if;
  select * into v_insumo from public.insumos where id = p_insumo_id and eliminado_en is null;
  if not found then
    raise exception 'El insumo no existe';
  end if;
  v_dif := round(p_contado, 3) - v_insumo.existencia;
  if v_dif = 0 then
    raise exception 'El conteo coincide con lo anotado: no hay nada que ajustar';
  end if;
  perform privado.fijar_accion(format('Ajustó %s por conteo: anotado %s, contado %s %s', v_insumo.nombre, v_insumo.existencia,
                                      round(p_contado, 3), v_insumo.unidad), coalesce(nullif(trim(p_motivo), ''), 'Conteo físico'));
  return privado.mover_inventario(p_insumo_id, 'ajuste', v_dif, coalesce(nullif(trim(p_motivo), ''), 'Conteo físico'));
end
$$;

-- Lo que registró el cajero (sin costos), para su propia pantalla.
create function public.mis_movimientos_inventario()
returns table (creado_en timestamptz, tipo public.tipo_movimiento_inventario, insumo text, unidad text, cantidad numeric, motivo text)
language sql stable security definer
set search_path = ''
as $$
  select m.creado_en, m.tipo, i.nombre, i.unidad, m.cantidad, m.motivo
  from public.movimientos_inventario m join public.insumos i on i.id = m.insumo_id
  where m.creado_por = auth.uid() and privado.perfil_actual() is not null
  order by m.creado_en desc limit 30
$$;

-- -----------------------------------------------------------------------------
-- Permisos y tiempo real
-- -----------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['proveedores', 'insumos', 'movimientos_inventario'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('revoke delete, truncate on public.%I from service_role', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end
$$;

-- Caja ve insumos y proveedores para registrar compras y entradas.
create policy proveedores_leer on public.proveedores for select to authenticated
  using ((select privado.tiene_perfil('propietario', 'cajero')) and (eliminado_en is null or (select privado.es_propietario())));
create policy insumos_leer on public.insumos for select to authenticated
  using ((select privado.tiene_perfil('propietario', 'cajero')) and (eliminado_en is null or (select privado.es_propietario())));
-- El historial con costos es solo de los propietarios.
create policy movimientos_inventario_leer on public.movimientos_inventario for select to authenticated
  using ((select privado.es_propietario()));

revoke execute on function privado.validar_cantidad(numeric),
  privado.mover_inventario(uuid, public.tipo_movimiento_inventario, numeric, text, numeric, uuid, uuid),
  privado.avisar_propietarios(text, text, text) from public, anon, authenticated;
revoke execute on function public.guardar_proveedor(uuid, text, text, text), public.eliminar_proveedor(uuid),
  public.guardar_insumo(uuid, text, text, numeric, uuid, numeric), public.eliminar_insumo(uuid),
  public.registrar_compra(uuid, jsonb, text), public.registrar_entrada(uuid, numeric, text),
  public.registrar_merma(uuid, numeric, text), public.ajustar_existencia(uuid, numeric, text),
  public.mis_movimientos_inventario() from public, anon;
grant execute on function public.guardar_proveedor(uuid, text, text, text), public.eliminar_proveedor(uuid),
  public.guardar_insumo(uuid, text, text, numeric, uuid, numeric), public.eliminar_insumo(uuid),
  public.registrar_compra(uuid, jsonb, text), public.registrar_entrada(uuid, numeric, text),
  public.registrar_merma(uuid, numeric, text), public.ajustar_existencia(uuid, numeric, text),
  public.mis_movimientos_inventario() to authenticated;

do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['insumos', 'proveedores', 'movimientos_inventario'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end
$$;
