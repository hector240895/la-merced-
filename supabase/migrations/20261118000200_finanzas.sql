-- =============================================================================
-- Sistema La Merced · Etapa 9 · Finanzas y reportes
--
--   * Gastos con forma de pago. Si se paga con efectivo de la caja, sale como
--     retiro de la caja abierta y baja el efectivo esperado del corte.
--   * Caja registra gastos pagados con la caja (no renta ni nómina).
--   * Gastos fijos (renta) que se registran solos cada mes.
--   * Empleados con sueldo fijo; el propietario registra lo que pagó a cada uno.
--   * Un gasto no se borra: se anula con motivo (y se regresa el efectivo a la
--     caja o se descuenta la compra del inventario, según el caso).
--   * Reporte de utilidad real: ventas − todos los gastos.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Categorías de gasto (los propietarios agregan las que necesiten)
-- -----------------------------------------------------------------------------
create table public.categorias_gasto (
  id             uuid primary key default gen_random_uuid(),
  sucursal_id    uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  clave          public.categoria_gasto,             -- las de fábrica; null = agregada por un propietario
  nombre         text not null check (length(trim(nombre)) between 1 and 60),
  orden          integer not null default 100,
  eliminado_en   timestamptz,
  eliminado_por  uuid references public.usuarios (id),
  creado_en      timestamptz not null default now(),
  creado_por     uuid references public.usuarios (id) default privado.actor(),
  constraint categorias_gasto_eliminado check ((eliminado_en is null) = (eliminado_por is null))
);
create unique index categorias_gasto_nombre_unico on public.categorias_gasto (sucursal_id, lower(nombre)) where eliminado_en is null;
create unique index categorias_gasto_clave_unica on public.categorias_gasto (sucursal_id, clave) where clave is not null;

insert into public.categorias_gasto (clave, nombre, orden) values
  ('renta', 'Renta', 1), ('nomina', 'Sueldos', 2), ('compras_mercancia', 'Insumos y mercancía', 3),
  ('refrescos', 'Refrescos y bebidas', 4), ('gas', 'Gas', 5), ('electricidad', 'Luz', 6), ('agua', 'Agua', 7),
  ('internet_telefono', 'Internet y teléfono', 8), ('desechables', 'Desechables', 9), ('limpieza', 'Limpieza', 10),
  ('comisiones_terminal', 'Comisiones de la terminal', 11), ('mantenimiento', 'Mantenimiento', 12),
  ('publicidad', 'Publicidad', 13), ('otros', 'Otros', 99);

create trigger categorias_gasto_sin_borrado before delete on public.categorias_gasto for each row execute function privado.prohibir_borrado();
create trigger categorias_gasto_sin_vaciar before truncate on public.categorias_gasto for each statement execute function privado.prohibir_borrado();
create trigger categorias_gasto_auditar after insert or update on public.categorias_gasto for each row execute function privado.auditar_cambios();
create trigger categorias_gasto_inmutables before update on public.categorias_gasto for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'clave', 'creado_en', 'creado_por');
create trigger categorias_gasto_sello before update on public.categorias_gasto for each row
  execute function privado.sellar_columnas('eliminado_en', 'eliminado_por');

-- -----------------------------------------------------------------------------
-- Empleados y gastos fijos
-- -----------------------------------------------------------------------------
create table public.empleados (
  id             uuid primary key default gen_random_uuid(),
  sucursal_id    uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  nombre         text not null check (length(trim(nombre)) between 1 and 80),
  puesto         text check (length(puesto) <= 60),
  sueldo         numeric(12, 2) not null check (sueldo >= 0),
  periodicidad   text not null default 'semanal' check (periodicidad in ('semanal', 'quincenal', 'mensual')),
  eliminado_en   timestamptz,
  eliminado_por  uuid references public.usuarios (id),
  creado_en      timestamptz not null default now(),
  creado_por     uuid references public.usuarios (id) default privado.actor(),
  constraint empleados_eliminado check ((eliminado_en is null) = (eliminado_por is null))
);
create unique index empleados_nombre_unico on public.empleados (sucursal_id, lower(nombre)) where eliminado_en is null;

create table public.gastos_fijos (
  id             uuid primary key default gen_random_uuid(),
  sucursal_id    uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  categoria_id   uuid not null references public.categorias_gasto (id),
  concepto       text not null check (length(trim(concepto)) between 1 and 120),
  monto          numeric(12, 2) not null check (monto > 0),
  dia            smallint not null check (dia between 1 and 31),   -- día del mes en que se registra
  forma_pago     public.forma_pago_gasto not null check (forma_pago <> 'caja'),
  desde          date not null,                                    -- primer mes que cuenta
  eliminado_en   timestamptz,
  eliminado_por  uuid references public.usuarios (id),
  creado_en      timestamptz not null default now(),
  creado_por     uuid references public.usuarios (id) default privado.actor(),
  constraint gastos_fijos_eliminado check ((eliminado_en is null) = (eliminado_por is null))
);

alter table public.gastos
  add column categoria_id   uuid references public.categorias_gasto (id),
  add column forma_pago     public.forma_pago_gasto not null default 'efectivo',
  add column nota           text check (length(nota) <= 300),
  add column movimiento_id  uuid references public.movimientos_efectivo (id),
  add column gasto_fijo_id  uuid references public.gastos_fijos (id),
  add column periodo        date,
  add column empleado_id    uuid references public.empleados (id),
  add constraint gastos_caja check ((forma_pago = 'caja') = (movimiento_id is not null)),
  add constraint gastos_fijo check ((gasto_fijo_id is null) = (periodo is null));
update public.gastos g set categoria_id = c.id from public.categorias_gasto c where c.clave = g.categoria;
alter table public.gastos alter column categoria_id set not null;
-- Si un gasto llega solo con la categoría de fábrica, se completa la categoría.
create function privado.gasto_categoria() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.categoria_id is null then
    new.categoria_id := (select id from public.categorias_gasto where clave = new.categoria and sucursal_id = new.sucursal_id);
  end if;
  return new;
end
$$;
create trigger gastos_categoria before insert on public.gastos for each row execute function privado.gasto_categoria();
create unique index gastos_fijo_periodo on public.gastos (gasto_fijo_id, periodo) where gasto_fijo_id is not null;
create index gastos_empleado_idx on public.gastos (empleado_id) where empleado_id is not null;

create trigger gastos_inmutables_finanzas before update on public.gastos for each row
  execute function privado.proteger_columnas('categoria_id', 'forma_pago', 'nota', 'movimiento_id', 'gasto_fijo_id', 'periodo', 'empleado_id');

create trigger empleados_sin_borrado before delete on public.empleados for each row execute function privado.prohibir_borrado();
create trigger empleados_sin_vaciar before truncate on public.empleados for each statement execute function privado.prohibir_borrado();
create trigger empleados_auditar after insert or update on public.empleados for each row execute function privado.auditar_cambios();
create trigger empleados_inmutables before update on public.empleados for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'creado_en', 'creado_por');
create trigger empleados_sello before update on public.empleados for each row
  execute function privado.sellar_columnas('eliminado_en', 'eliminado_por');

create trigger gastos_fijos_sin_borrado before delete on public.gastos_fijos for each row execute function privado.prohibir_borrado();
create trigger gastos_fijos_sin_vaciar before truncate on public.gastos_fijos for each statement execute function privado.prohibir_borrado();
create trigger gastos_fijos_auditar after insert or update on public.gastos_fijos for each row execute function privado.auditar_cambios();
create trigger gastos_fijos_inmutables before update on public.gastos_fijos for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'creado_en', 'creado_por');
create trigger gastos_fijos_sello before update on public.gastos_fijos for each row
  execute function privado.sellar_columnas('eliminado_en', 'eliminado_por');

-- -----------------------------------------------------------------------------
-- Ayudantes
-- -----------------------------------------------------------------------------
create function privado.hoy() returns date
language sql stable
set search_path = ''
as $$ select (now() at time zone 'America/Mexico_City')::date $$;

create function privado.categoria_por_clave(p public.categoria_gasto) returns uuid
language sql stable
set search_path = ''
as $$
  select id from public.categorias_gasto where clave = p and sucursal_id = privado.sucursal_del_actor()
$$;

-- Crea un gasto. Con forma "caja" saca el dinero de la caja abierta.
create function privado.crear_gasto(
  p_categoria_id uuid, p_concepto text, p_monto numeric, p_fecha date,
  p_forma public.forma_pago_gasto, p_nota text default null,
  p_empleado_id uuid default null, p_gasto_fijo_id uuid default null, p_periodo date default null
) returns public.gastos
language plpgsql
set search_path = ''
as $$
declare
  v_concepto text := left(trim(coalesce(p_concepto, '')), 200);
  v_monto numeric := round(p_monto, 2);
  v_turno public.turnos_caja;
  v_disponible numeric;
  v_mov uuid;
  v_fila public.gastos;
  v_cat public.categorias_gasto;
begin
  select * into v_cat from public.categorias_gasto where id = p_categoria_id and eliminado_en is null;
  if not found then
    raise exception 'Elige la categoría del gasto';
  end if;
  if length(v_concepto) = 0 then
    raise exception 'Escribe en qué se gastó';
  end if;
  if v_monto is null or v_monto <= 0 or v_monto > 10000000 then
    raise exception 'Escribe el monto del gasto';
  end if;
  if p_forma is null then
    raise exception 'Elige cómo se pagó';
  end if;
  if p_fecha is null or p_fecha > privado.hoy() then
    raise exception 'La fecha del gasto no puede ser futura';
  end if;
  if p_forma = 'caja' then
    select * into v_turno from public.turnos_caja
     where sucursal_id = privado.sucursal_del_actor() and estado = 'abierto' for update;
    if not found then
      raise exception 'Abre la caja primero para pagar con su efectivo';
    end if;
    v_disponible := (privado.resumen_turno(v_turno.id) ->> 'efectivo_esperado')::numeric;
    if v_monto > v_disponible then
      raise exception 'En la caja solo debe haber $%', v_disponible;
    end if;
    insert into public.movimientos_efectivo (sucursal_id, turno_id, tipo, importe, motivo)
    values (v_turno.sucursal_id, v_turno.id, 'retiro', v_monto, left('Gasto: ' || v_concepto, 200))
    returning id into v_mov;
  end if;
  insert into public.gastos (sucursal_id, categoria, categoria_id, concepto, monto, fecha, forma_pago, nota, movimiento_id,
                             empleado_id, gasto_fijo_id, periodo)
  values (privado.sucursal_del_actor(), coalesce(v_cat.clave, 'otros'), v_cat.id, v_concepto, v_monto, p_fecha, p_forma, nullif(trim(p_nota), ''), v_mov,
          p_empleado_id, p_gasto_fijo_id, p_periodo)
  returning * into v_fila;
  return v_fila;
end
$$;

-- Registra los gastos fijos que ya tocan (cada mes, en su día). Si nadie abrió
-- el sistema en un tiempo, se ponen al corriente. Nunca se repite un mes.
create function privado.generar_gastos_fijos() returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_fijo public.gastos_fijos;
  v_mes date;
  v_fecha date;
  v_hoy date := privado.hoy();
  v_n integer := 0;
begin
  for v_fijo in select * from public.gastos_fijos where eliminado_en is null and desde <= v_hoy order by creado_en for update loop
    v_mes := date_trunc('month', v_fijo.desde)::date;
    while v_mes <= v_hoy loop
      v_fecha := least(v_mes + (v_fijo.dia - 1), (v_mes + interval '1 month' - interval '1 day')::date);
      if v_fecha >= v_fijo.desde and v_fecha <= v_hoy
         and not exists (select 1 from public.gastos where gasto_fijo_id = v_fijo.id and periodo = v_mes) then
        perform privado.fijar_accion(format('Se registró solo el gasto fijo "%s" de %s: $%s', v_fijo.concepto,
                                            to_char(v_mes, 'MM/YYYY'), v_fijo.monto));
        insert into public.gastos (sucursal_id, categoria, categoria_id, concepto, monto, fecha, forma_pago, gasto_fijo_id, periodo)
        values (v_fijo.sucursal_id, coalesce((select clave from public.categorias_gasto where id = v_fijo.categoria_id), 'otros'),
                v_fijo.categoria_id, v_fijo.concepto, v_fijo.monto, v_fecha, v_fijo.forma_pago, v_fijo.id, v_mes);
        v_n := v_n + 1;
      end if;
      v_mes := (v_mes + interval '1 month')::date;
    end loop;
  end loop;
  return v_n;
end
$$;

-- -----------------------------------------------------------------------------
-- Gastos
-- -----------------------------------------------------------------------------

-- Propietarios: cualquier gasto. Caja: solo con efectivo de la caja, del día,
-- y no renta ni sueldos.
create function public.registrar_gasto(
  p_categoria_id uuid, p_concepto text, p_monto numeric, p_forma_pago public.forma_pago_gasto,
  p_fecha date default null, p_nota text default null
) returns public.gastos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fecha date := coalesce(p_fecha, privado.hoy());
  v_fila public.gastos;
  v_cat public.categorias_gasto;
begin
  perform privado.exigir_perfil('propietario', 'cajero');
  select * into v_cat from public.categorias_gasto where id = p_categoria_id and eliminado_en is null;
  if not found then
    raise exception 'Elige la categoría del gasto';
  end if;
  if privado.perfil_actual() = 'cajero' then
    if p_forma_pago is distinct from 'caja' then
      raise exception 'Desde caja solo se registran gastos pagados con el efectivo de la caja';
    end if;
    if v_cat.clave in ('renta', 'nomina') then
      raise exception 'La renta y los sueldos los registran los propietarios';
    end if;
    if v_fecha <> privado.hoy() then
      raise exception 'Desde caja solo se registran gastos de hoy';
    end if;
  end if;
  perform privado.fijar_accion(format('Registró un gasto de $%s: %s (%s)', round(p_monto, 2), trim(p_concepto),
                                      v_cat.nombre), p_nota);
  v_fila := privado.crear_gasto(p_categoria_id, p_concepto, p_monto, v_fecha, p_forma_pago, p_nota);
  perform privado.avisar_propietarios(format('Registró un gasto de $%s pagado con la caja: %s', v_fila.monto, v_fila.concepto),
                                      'gastos', v_fila.id::text);
  return v_fila;
end
$$;

-- Anular un gasto (propietarios). Si salió de una caja todavía abierta, el
-- efectivo regresa a la caja. Si era una compra, se descuenta del inventario.
create function public.anular_gasto(p_gasto_id uuid, p_motivo text) returns public.gastos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_gasto public.gastos;
  v_mov public.movimientos_efectivo;
  v_inv record;
  v_existencia numeric;
begin
  if coalesce(length(trim(p_motivo)), 0) = 0 then
    raise exception 'Escribe por qué se anula el gasto';
  end if;
  select * into v_gasto from public.gastos where id = p_gasto_id for update;
  if not found then
    raise exception 'El gasto no existe';
  end if;
  if v_gasto.estado = 'anulado' then
    raise exception 'El gasto ya estaba anulado';
  end if;
  perform privado.fijar_accion(format('Anuló el gasto de $%s: %s', v_gasto.monto, v_gasto.concepto), p_motivo);
  update public.gastos set estado = 'anulado', anulado_en = now(), anulado_por = v_actor, anulacion_motivo = trim(p_motivo)
   where id = p_gasto_id returning * into v_gasto;

  if v_gasto.movimiento_id is not null then
    select m.* into v_mov from public.movimientos_efectivo m join public.turnos_caja t on t.id = m.turno_id
     where m.id = v_gasto.movimiento_id and t.estado = 'abierto';
    if found then
      insert into public.movimientos_efectivo (sucursal_id, turno_id, tipo, importe, motivo)
      values (v_mov.sucursal_id, v_mov.turno_id, 'entrada', v_mov.importe, left('Se anuló el gasto: ' || v_gasto.concepto, 200));
    end if;
  end if;

  for v_inv in select insumo_id, sum(cantidad) cantidad from public.movimientos_inventario
                where gasto_id = p_gasto_id and tipo = 'compra' group by insumo_id loop
    select existencia into v_existencia from public.insumos where id = v_inv.insumo_id;
    if least(v_inv.cantidad, v_existencia) > 0 then
      perform privado.mover_inventario(v_inv.insumo_id, 'ajuste', -least(v_inv.cantidad, v_existencia), 'Se anuló la compra: ' || trim(p_motivo));
    end if;
  end loop;
  return v_gasto;
end
$$;

-- Compra de inventario: ahora con forma de pago (caja descuenta del efectivo).
drop function public.registrar_compra(uuid, jsonb, text);
create function public.registrar_compra(p_proveedor_id uuid, p_productos jsonb, p_nota text default null,
                                        p_forma_pago public.forma_pago_gasto default null)
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
  v_forma public.forma_pago_gasto;
begin
  perform privado.exigir_perfil('propietario', 'cajero');
  v_forma := coalesce(p_forma_pago, case when privado.perfil_actual() = 'cajero' then 'caja' else 'efectivo' end::public.forma_pago_gasto);
  if privado.perfil_actual() = 'cajero' and v_forma <> 'caja' then
    raise exception 'Desde caja solo se registran compras pagadas con el efectivo de la caja';
  end if;
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
  v_gasto := privado.crear_gasto(privado.categoria_por_clave('compras_mercancia'), 'Compra' || coalesce(' a ' || v_proveedor, ''), v_total, privado.hoy(), v_forma, p_nota);

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

-- -----------------------------------------------------------------------------
-- Categorías (propietarios)
-- -----------------------------------------------------------------------------
create function public.guardar_categoria_gasto(p_id uuid, p_nombre text) returns public.categorias_gasto
language plpgsql security definer
set search_path = ''
as $$
declare
  v_nombre text := trim(coalesce(p_nombre, ''));
  v_fila public.categorias_gasto;
begin
  perform privado.exigir_perfil('propietario');
  if length(v_nombre) = 0 or length(v_nombre) > 60 then
    raise exception 'Escribe el nombre de la categoría';
  end if;
  if exists (select 1 from public.categorias_gasto where lower(nombre) = lower(v_nombre) and eliminado_en is null and id is distinct from p_id) then
    raise exception 'Ya existe la categoría %', v_nombre;
  end if;
  if p_id is null then
    perform privado.fijar_accion('Agregó la categoría de gasto ' || v_nombre);
    insert into public.categorias_gasto (sucursal_id, nombre, orden) values (privado.sucursal_del_actor(), v_nombre, 50)
    returning * into v_fila;
  else
    perform privado.fijar_accion('Renombró una categoría de gasto a ' || v_nombre);
    update public.categorias_gasto set nombre = v_nombre where id = p_id and eliminado_en is null returning * into v_fila;
    if not found then
      raise exception 'La categoría no existe';
    end if;
  end if;
  return v_fila;
end
$$;

-- Los gastos ya registrados conservan su categoría.
create function public.eliminar_categoria_gasto(p_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_fila public.categorias_gasto;
begin
  select * into v_fila from public.categorias_gasto where id = p_id and eliminado_en is null for update;
  if not found then
    raise exception 'La categoría no existe';
  end if;
  if v_fila.clave in ('nomina', 'compras_mercancia', 'otros') then
    raise exception 'La categoría % la usa el sistema y no se puede quitar', v_fila.nombre;
  end if;
  if exists (select 1 from public.gastos_fijos where categoria_id = p_id and eliminado_en is null) then
    raise exception 'Un gasto fijo usa la categoría %: cámbialo primero', v_fila.nombre;
  end if;
  perform privado.fijar_accion('Quitó la categoría de gasto ' || v_fila.nombre);
  update public.categorias_gasto set eliminado_en = now(), eliminado_por = v_actor where id = p_id;
end
$$;

-- -----------------------------------------------------------------------------
-- Gastos fijos (propietarios)
-- -----------------------------------------------------------------------------
create function public.guardar_gasto_fijo(
  p_id uuid, p_categoria_id uuid, p_concepto text, p_monto numeric, p_dia integer,
  p_forma_pago public.forma_pago_gasto, p_desde date default null
) returns public.gastos_fijos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fila public.gastos_fijos;
begin
  perform privado.exigir_perfil('propietario');
  if not exists (select 1 from public.categorias_gasto where id = p_categoria_id and eliminado_en is null) then
    raise exception 'Elige la categoría del gasto';
  end if;
  if coalesce(length(trim(p_concepto)), 0) = 0 then
    raise exception 'Escribe el concepto (por ejemplo, "Renta del local")';
  end if;
  if p_monto is null or p_monto <= 0 then
    raise exception 'Escribe el monto';
  end if;
  if p_dia is null or p_dia not between 1 and 31 then
    raise exception 'Escribe el día del mes (1 a 31)';
  end if;
  if p_forma_pago is null or p_forma_pago = 'caja' then
    raise exception 'Un gasto fijo no se paga con el efectivo de la caja';
  end if;
  if p_id is null then
    perform privado.fijar_accion(format('Agregó el gasto fijo "%s": $%s cada mes, día %s', trim(p_concepto), round(p_monto, 2), p_dia));
    insert into public.gastos_fijos (sucursal_id, categoria_id, concepto, monto, dia, forma_pago, desde)
    values (privado.sucursal_del_actor(), p_categoria_id, trim(p_concepto), round(p_monto, 2), p_dia, p_forma_pago,
            coalesce(p_desde, privado.hoy()))
    returning * into v_fila;
  else
    -- Los meses ya registrados no cambian; el cambio cuenta para los siguientes.
    perform privado.fijar_accion(format('Cambió el gasto fijo "%s": $%s cada mes, día %s', trim(p_concepto), round(p_monto, 2), p_dia));
    update public.gastos_fijos set categoria_id = p_categoria_id, concepto = trim(p_concepto), monto = round(p_monto, 2), dia = p_dia,
                                   forma_pago = p_forma_pago
     where id = p_id and eliminado_en is null returning * into v_fila;
    if not found then
      raise exception 'El gasto fijo no existe';
    end if;
  end if;
  perform privado.generar_gastos_fijos();
  return v_fila;
end
$$;

create function public.eliminar_gasto_fijo(p_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_fila public.gastos_fijos;
begin
  select * into v_fila from public.gastos_fijos where id = p_id and eliminado_en is null for update;
  if not found then
    raise exception 'El gasto fijo no existe';
  end if;
  perform privado.fijar_accion(format('Quitó el gasto fijo "%s" (ya no se registrará solo)', v_fila.concepto));
  update public.gastos_fijos set eliminado_en = now(), eliminado_por = v_actor where id = p_id;
end
$$;

create function public.generar_gastos_fijos() returns integer
language plpgsql security definer
set search_path = ''
as $$
begin
  perform privado.exigir_perfil('propietario');
  return privado.generar_gastos_fijos();
end
$$;

-- -----------------------------------------------------------------------------
-- Empleados y sueldos (propietarios)
-- -----------------------------------------------------------------------------
create function public.guardar_empleado(p_id uuid, p_nombre text, p_puesto text, p_sueldo numeric, p_periodicidad text default 'semanal')
returns public.empleados
language plpgsql security definer
set search_path = ''
as $$
declare
  v_nombre text := trim(coalesce(p_nombre, ''));
  v_fila public.empleados;
begin
  perform privado.exigir_perfil('propietario');
  if length(v_nombre) = 0 or length(v_nombre) > 80 then
    raise exception 'Escribe el nombre del empleado';
  end if;
  if p_sueldo is null or p_sueldo < 0 then
    raise exception 'Escribe el sueldo';
  end if;
  if p_periodicidad not in ('semanal', 'quincenal', 'mensual') then
    raise exception 'Elige cada cuándo se paga';
  end if;
  if exists (select 1 from public.empleados where lower(nombre) = lower(v_nombre) and eliminado_en is null and id is distinct from p_id) then
    raise exception 'Ya existe el empleado %', v_nombre;
  end if;
  if p_id is null then
    perform privado.fijar_accion(format('Agregó al empleado %s con sueldo %s de $%s', v_nombre, p_periodicidad, round(p_sueldo, 2)));
    insert into public.empleados (sucursal_id, nombre, puesto, sueldo, periodicidad)
    values (privado.sucursal_del_actor(), v_nombre, nullif(trim(p_puesto), ''), round(p_sueldo, 2), p_periodicidad)
    returning * into v_fila;
  else
    perform privado.fijar_accion(format('Cambió los datos del empleado %s: sueldo %s de $%s', v_nombre, p_periodicidad, round(p_sueldo, 2)));
    update public.empleados set nombre = v_nombre, puesto = nullif(trim(p_puesto), ''), sueldo = round(p_sueldo, 2), periodicidad = p_periodicidad
     where id = p_id and eliminado_en is null returning * into v_fila;
    if not found then
      raise exception 'El empleado no existe';
    end if;
  end if;
  return v_fila;
end
$$;

create function public.eliminar_empleado(p_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_fila public.empleados;
begin
  select * into v_fila from public.empleados where id = p_id and eliminado_en is null for update;
  if not found then
    raise exception 'El empleado no existe';
  end if;
  perform privado.fijar_accion('Quitó de la lista al empleado ' || v_fila.nombre);
  update public.empleados set eliminado_en = now(), eliminado_por = v_actor where id = p_id;
end
$$;

-- Registra lo que se pagó a cada empleado: un gasto de "Sueldos" por persona.
-- p_pagos: [{"empleado_id": "...", "monto": 1800}, ...]; monto 0 = no se le pagó.
create function public.pagar_sueldos(p_pagos jsonb, p_periodo text, p_forma_pago public.forma_pago_gasto, p_fecha date default null)
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_item record;
  v_emp public.empleados;
  v_n integer := 0;
  v_total numeric := 0;
begin
  perform privado.exigir_perfil('propietario');
  if p_pagos is null or jsonb_typeof(p_pagos) <> 'array' then
    raise exception 'No hay sueldos que registrar';
  end if;
  if coalesce(length(trim(p_periodo)), 0) = 0 then
    raise exception 'Escribe qué periodo se paga (por ejemplo, "Semana del 3 al 9 de noviembre")';
  end if;
  for v_item in select * from jsonb_to_recordset(p_pagos) as x(empleado_id uuid, monto numeric) where coalesce(x.monto, 0) > 0 loop
    select * into v_emp from public.empleados where id = v_item.empleado_id and eliminado_en is null;
    if not found then
      raise exception 'Un empleado de la lista no existe';
    end if;
    perform privado.fijar_accion(format('Pagó sueldo a %s: $%s (%s)', v_emp.nombre, round(v_item.monto, 2), trim(p_periodo)));
    perform privado.crear_gasto(privado.categoria_por_clave('nomina'), 'Sueldo de ' || v_emp.nombre || ' · ' || trim(p_periodo), v_item.monto,
                                coalesce(p_fecha, privado.hoy()), p_forma_pago, null, v_emp.id);
    v_n := v_n + 1;
    v_total := v_total + round(v_item.monto, 2);
  end loop;
  if v_n = 0 then
    raise exception 'Escribe al menos un sueldo';
  end if;
  return v_n;
end
$$;

-- -----------------------------------------------------------------------------
-- Reporte de finanzas (propietarios)
-- -----------------------------------------------------------------------------
create function privado.ventas_entre(p_desde date, p_hasta date) returns numeric
language sql stable
set search_path = ''
as $$
  select coalesce((select sum(importe) from public.pagos where estado = 'vigente'
                    and (creado_en at time zone 'America/Mexico_City')::date between p_desde and p_hasta), 0)
       - coalesce((select sum(importe) from public.devoluciones
                    where (creado_en at time zone 'America/Mexico_City')::date between p_desde and p_hasta), 0)
$$;

create function privado.gastos_entre(p_desde date, p_hasta date) returns numeric
language sql stable
set search_path = ''
as $$
  select coalesce(sum(monto), 0) from public.gastos where estado = 'vigente' and fecha between p_desde and p_hasta
$$;

create function public.reporte_finanzas(p_desde date, p_hasta date) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_dias integer;
  v_ant_desde date;
  v_ant_hasta date;
  v_ventas numeric;
  v_gastos numeric;
  v_res jsonb;
begin
  perform privado.exigir_perfil('propietario');
  if p_desde is null or p_hasta is null or p_hasta < p_desde then
    raise exception 'Elige un periodo válido';
  end if;
  if p_hasta - p_desde > 366 then
    raise exception 'El periodo puede ser de hasta un año';
  end if;
  perform privado.generar_gastos_fijos();

  v_dias := p_hasta - p_desde + 1;
  v_ant_hasta := p_desde - 1;
  v_ant_desde := p_desde - v_dias;
  -- Si el periodo es un mes completo, se compara con el mes anterior completo.
  if p_desde = date_trunc('month', p_desde)::date and p_hasta = (date_trunc('month', p_desde) + interval '1 month' - interval '1 day')::date then
    v_ant_desde := (p_desde - interval '1 month')::date;
  end if;
  v_ventas := privado.ventas_entre(p_desde, p_hasta);
  v_gastos := privado.gastos_entre(p_desde, p_hasta);

  with
  pg as (select p.*, (p.creado_en at time zone 'America/Mexico_City') local from public.pagos p
         where p.estado = 'vigente' and (p.creado_en at time zone 'America/Mexico_City')::date between p_desde and p_hasta),
  dv as (select d.* from public.devoluciones d where (d.creado_en at time zone 'America/Mexico_City')::date between p_desde and p_hasta),
  pr as (select pp.* from public.propinas pp where pp.estado = 'vigente'
         and (pp.creado_en at time zone 'America/Mexico_City')::date between p_desde and p_hasta),
  cc as (select c.* from public.cuentas c where c.estado = 'cobrada'
         and (c.cobrada_en at time zone 'America/Mexico_City')::date between p_desde and p_hasta),
  gs as (select g.* from public.gastos g where g.estado = 'vigente' and g.fecha between p_desde and p_hasta),
  dias as (select d::date fecha from generate_series(p_desde, p_hasta, interval '1 day') d)
  select jsonb_build_object(
    'desde', p_desde, 'hasta', p_hasta,
    'ventas', jsonb_build_object(
      'efectivo', coalesce((select sum(importe) from pg where metodo = 'efectivo'), 0),
      'tarjeta', coalesce((select sum(importe) from pg where metodo = 'tarjeta'), 0),
      'transferencia', coalesce((select sum(importe) from pg where metodo = 'transferencia'), 0),
      'cobrado', coalesce((select sum(importe) from pg), 0),
      'devoluciones', coalesce((select sum(importe) from dv), 0),
      'netas', v_ventas,
      'cuentas', (select count(*) from cc),
      'ticket_promedio', case when (select count(*) from cc) > 0 then round(v_ventas / (select count(*) from cc), 2) else 0 end),
    'propinas', jsonb_build_object(
      'efectivo', coalesce((select sum(importe) from pr where metodo = 'efectivo'), 0),
      'tarjeta', coalesce((select sum(importe) from pr where metodo = 'tarjeta'), 0),
      'total', coalesce((select sum(importe) from pr), 0)),
    'gastos', jsonb_build_object(
      'total', v_gastos,
      'por_categoria', coalesce((select jsonb_agg(x order by x.total desc) from (
          select c.id categoria_id, c.nombre, sum(g.monto) total, count(*) n
          from gs g join public.categorias_gasto c on c.id = g.categoria_id group by c.id, c.nombre) x), '[]')),
    'utilidad', v_ventas - v_gastos,
    'margen', case when v_ventas > 0 then round((v_ventas - v_gastos) * 100 / v_ventas, 1) end,
    'anterior', jsonb_build_object(
      'desde', v_ant_desde, 'hasta', v_ant_hasta,
      'ventas', privado.ventas_entre(v_ant_desde, v_ant_hasta),
      'gastos', privado.gastos_entre(v_ant_desde, v_ant_hasta),
      'utilidad', privado.ventas_entre(v_ant_desde, v_ant_hasta) - privado.gastos_entre(v_ant_desde, v_ant_hasta)),
    'por_dia', (select jsonb_agg(jsonb_build_object(
        'fecha', d.fecha,
        'ventas', coalesce((select sum(importe) from pg where local::date = d.fecha), 0)
                  - coalesce((select sum(importe) from dv where (dv.creado_en at time zone 'America/Mexico_City')::date = d.fecha), 0),
        'gastos', coalesce((select sum(monto) from gs where gs.fecha = d.fecha), 0),
        'cuentas', (select count(*) from cc where (cc.cobrada_en at time zone 'America/Mexico_City')::date = d.fecha))
        order by d.fecha) from dias d),
    'por_hora', coalesce((select jsonb_agg(x order by x.hora) from (
        select extract(hour from local)::int hora, sum(importe) ventas, count(distinct cuenta_id) cuentas
        from pg group by 1) x), '[]'),
    'productos', coalesce((select jsonb_agg(x order by x.cantidad desc, x.importe desc) from (
        select l.nombre_producto producto, sum(l.cantidad) cantidad, sum(l.cantidad * l.precio_unitario) importe
        from public.lineas_cuenta l join cc on cc.id = l.cuenta_id
        where l.estado = 'activa' group by l.nombre_producto) x), '[]'),
    'meseros', coalesce((select jsonb_agg(x order by x.ventas desc) from (
        select coalesce(u.nombre, 'Caja (para llevar)') mesero, count(*) cuentas, sum(cc.total) ventas,
               coalesce(sum((select sum(importe) from pr where pr.cuenta_id = cc.id)), 0) propinas
        from cc left join public.usuarios u on u.id = cc.mesero_id
        group by u.nombre) x), '[]'),
    'formas_pago_gastos', coalesce((select jsonb_object_agg(forma_pago, total) from (
        select forma_pago, sum(monto) total from gs group by forma_pago) x), '{}'),
    'gastos_lista', coalesce((select jsonb_agg(jsonb_build_object(
        'id', g.id, 'fecha', g.fecha, 'categoria', c.nombre, 'concepto', g.concepto,
        'monto', g.monto, 'forma_pago', g.forma_pago, 'quien', u.nombre) order by g.fecha desc, g.creado_en desc)
        from gs g join public.categorias_gasto c on c.id = g.categoria_id left join public.usuarios u on u.id = g.creado_por), '[]'),
    'cancelaciones', (
      select jsonb_build_object(
        'productos_quitados', (select count(*) from public.lineas_cuenta l
                               where l.estado = 'cancelada' and (l.cancelada_en at time zone 'America/Mexico_City')::date between p_desde and p_hasta),
        'cuentas_canceladas', (select count(*) from public.cuentas c
                               where c.estado = 'cancelada' and (c.cancelada_en at time zone 'America/Mexico_City')::date between p_desde and p_hasta),
        'cobros_anulados', (select count(*) from public.pagos p
                            where p.estado = 'anulado' and (p.anulado_en at time zone 'America/Mexico_City')::date between p_desde and p_hasta),
        'devoluciones', (select count(*) from dv),
        'detalle', coalesce((select jsonb_agg(x order by x.cuando desc) from (
            select l.cancelada_en cuando, 'Quitó ' || l.cantidad || ' × ' || l.nombre_producto que,
                   l.cantidad * l.precio_unitario importe, l.cancelacion_motivo motivo, u.nombre quien
            from public.lineas_cuenta l left join public.usuarios u on u.id = l.cancelada_por
            where l.estado = 'cancelada' and (l.cancelada_en at time zone 'America/Mexico_City')::date between p_desde and p_hasta
            union all
            select c.cancelada_en, 'Canceló la cuenta folio ' || c.folio, privado.total_cuenta(c.id), c.cancelacion_motivo, u.nombre
            from public.cuentas c left join public.usuarios u on u.id = c.cancelada_por
            where c.estado = 'cancelada' and (c.cancelada_en at time zone 'America/Mexico_City')::date between p_desde and p_hasta
            union all
            select p.anulado_en, 'Anuló un cobro (' || p.metodo || ')', p.importe, p.anulacion_motivo, u.nombre
            from public.pagos p left join public.usuarios u on u.id = p.anulado_por
            where p.estado = 'anulado' and (p.anulado_en at time zone 'America/Mexico_City')::date between p_desde and p_hasta
            order by 1 desc limit 200) x), '[]'))))
  into v_res;
  return v_res;
end
$$;

-- -----------------------------------------------------------------------------
-- Permisos y tiempo real
-- -----------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['empleados', 'gastos_fijos', 'categorias_gasto'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('revoke delete, truncate on public.%I from service_role', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end
$$;
create policy empleados_leer on public.empleados for select to authenticated using ((select privado.es_propietario()));
create policy categorias_gasto_leer on public.categorias_gasto for select to authenticated
  using ((select privado.tiene_perfil('propietario', 'cajero')) and (eliminado_en is null or (select privado.es_propietario())));
create policy gastos_fijos_leer on public.gastos_fijos for select to authenticated using ((select privado.es_propietario()));

-- Caja ve solo los gastos que ella misma registró hoy.
drop policy gastos_leer on public.gastos;
create policy gastos_leer on public.gastos for select to authenticated
  using ((select privado.es_propietario())
         or ((select privado.tiene_perfil('cajero')) and creado_por = (select auth.uid())
             and (creado_en at time zone 'America/Mexico_City')::date = (select privado.hoy())));

revoke execute on function privado.gasto_categoria(), privado.categoria_por_clave(public.categoria_gasto),
  privado.crear_gasto(uuid, text, numeric, date, public.forma_pago_gasto, text, uuid, uuid, date),
  privado.generar_gastos_fijos(), privado.ventas_entre(date, date), privado.gastos_entre(date, date)
  from public, anon, authenticated;
revoke execute on function
  public.registrar_gasto(uuid, text, numeric, public.forma_pago_gasto, date, text),
  public.guardar_categoria_gasto(uuid, text), public.eliminar_categoria_gasto(uuid),
  public.anular_gasto(uuid, text),
  public.registrar_compra(uuid, jsonb, text, public.forma_pago_gasto),
  public.guardar_gasto_fijo(uuid, uuid, text, numeric, integer, public.forma_pago_gasto, date),
  public.eliminar_gasto_fijo(uuid), public.generar_gastos_fijos(),
  public.guardar_empleado(uuid, text, text, numeric, text), public.eliminar_empleado(uuid),
  public.pagar_sueldos(jsonb, text, public.forma_pago_gasto, date),
  public.reporte_finanzas(date, date)
  from public, anon;
grant execute on function
  public.registrar_gasto(uuid, text, numeric, public.forma_pago_gasto, date, text),
  public.guardar_categoria_gasto(uuid, text), public.eliminar_categoria_gasto(uuid),
  public.anular_gasto(uuid, text),
  public.registrar_compra(uuid, jsonb, text, public.forma_pago_gasto),
  public.guardar_gasto_fijo(uuid, uuid, text, numeric, integer, public.forma_pago_gasto, date),
  public.eliminar_gasto_fijo(uuid), public.generar_gastos_fijos(),
  public.guardar_empleado(uuid, text, text, numeric, text), public.eliminar_empleado(uuid),
  public.pagar_sueldos(jsonb, text, public.forma_pago_gasto, date),
  public.reporte_finanzas(date, date)
  to authenticated;

do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['gastos', 'gastos_fijos', 'empleados', 'categorias_gasto'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end
$$;
