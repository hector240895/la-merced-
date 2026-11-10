-- =============================================================================
-- Etapa 9 · Quién pagó cada gasto (Hector, Wendy o la caja) y gastos por dueño.
--
-- Por defecto lo pagó el propietario que lo registra; se puede elegir al otro.
-- Lo pagado con el efectivo de la caja no es de ningún dueño.
-- =============================================================================

alter table public.gastos add column pagado_por uuid references public.usuarios (id);
alter table public.gastos_fijos add column pagado_por uuid references public.usuarios (id);

-- Gastos anteriores: los pagó quien los registró (si era propietario y no salió de la caja).
update public.gastos g set pagado_por = g.creado_por
  from public.usuarios u
 where u.id = g.creado_por and u.perfil = 'propietario' and g.forma_pago <> 'caja' and g.pagado_por is null;

create trigger gastos_pagado_por_fijo before update on public.gastos for each row
  execute function privado.proteger_columnas('pagado_por');
alter table public.gastos add constraint gastos_pagado_caja check (forma_pago <> 'caja' or pagado_por is null);

-- Quién pagó, elegido en la operación en curso (solo dentro de la transacción).
create function privado.fijar_quien_pago(p_usuario uuid) returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_usuario is not null and not exists (select 1 from public.usuarios where id = p_usuario and perfil = 'propietario' and activo) then
    raise exception 'Quien pagó debe ser uno de los propietarios';
  end if;
  perform set_config('lamerced.pagado_por', coalesce(p_usuario::text, ''), true);
end
$$;

create function privado.gasto_pagado_por() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_elegido uuid := nullif(current_setting('lamerced.pagado_por', true), '')::uuid;
begin
  if new.pagado_por is not null or new.forma_pago = 'caja' then
    return new;
  end if;
  if new.gasto_fijo_id is not null then
    -- Los automáticos: el que se eligió para ese gasto fijo.
    new.pagado_por := coalesce((select pagado_por from public.gastos_fijos where id = new.gasto_fijo_id), v_elegido);
  else
    new.pagado_por := coalesce(v_elegido,
      (select u.id from public.usuarios u where u.id = privado.actor() and u.perfil = 'propietario'));
  end if;
  return new;
end
$$;
create trigger gastos_pagado_por before insert on public.gastos for each row execute function privado.gasto_pagado_por();

-- Las funciones que registran gastos aceptan ahora "quién lo pagó". La versión
-- anterior queda como interna y la nueva fija quién pagó antes de llamarla.
alter function public.registrar_gasto(uuid, text, numeric, public.forma_pago_gasto, date, text) rename to registrar_gasto_base;
alter function public.registrar_gasto_base(uuid, text, numeric, public.forma_pago_gasto, date, text) set schema privado;
alter function public.pagar_sueldos(jsonb, text, public.forma_pago_gasto, date) rename to pagar_sueldos_base;
alter function public.pagar_sueldos_base(jsonb, text, public.forma_pago_gasto, date) set schema privado;
alter function public.guardar_gasto_fijo(uuid, uuid, text, numeric, integer, public.forma_pago_gasto, date) rename to guardar_gasto_fijo_base;
alter function public.guardar_gasto_fijo_base(uuid, uuid, text, numeric, integer, public.forma_pago_gasto, date) set schema privado;

create function public.registrar_gasto(
  p_categoria_id uuid, p_concepto text, p_monto numeric, p_forma_pago public.forma_pago_gasto,
  p_fecha date default null, p_nota text default null, p_pagado_por uuid default null
) returns public.gastos
language plpgsql security definer
set search_path = ''
as $$
begin
  perform privado.exigir_perfil('propietario', 'cajero');
  if p_pagado_por is not null and privado.perfil_actual() <> 'propietario' then
    raise exception 'Desde caja los gastos se pagan con el efectivo de la caja';
  end if;
  perform privado.fijar_quien_pago(case when p_forma_pago = 'caja' then null else p_pagado_por end);
  return privado.registrar_gasto_base(p_categoria_id, p_concepto, p_monto, p_forma_pago, p_fecha, p_nota);
end
$$;

create function public.pagar_sueldos(p_pagos jsonb, p_periodo text, p_forma_pago public.forma_pago_gasto,
                                     p_fecha date default null, p_pagado_por uuid default null)
returns integer
language plpgsql security definer
set search_path = ''
as $$
begin
  perform privado.exigir_perfil('propietario');
  perform privado.fijar_quien_pago(case when p_forma_pago = 'caja' then null else p_pagado_por end);
  return privado.pagar_sueldos_base(p_pagos, p_periodo, p_forma_pago, p_fecha);
end
$$;

create function public.guardar_gasto_fijo(
  p_id uuid, p_categoria_id uuid, p_concepto text, p_monto numeric, p_dia integer,
  p_forma_pago public.forma_pago_gasto, p_desde date default null, p_pagado_por uuid default null
) returns public.gastos_fijos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_quien uuid := coalesce(p_pagado_por, privado.actor());
  v_fila public.gastos_fijos;
begin
  perform privado.exigir_perfil('propietario');
  perform privado.fijar_quien_pago(v_quien);
  v_fila := privado.guardar_gasto_fijo_base(p_id, p_categoria_id, p_concepto, p_monto, p_dia, p_forma_pago, p_desde);
  update public.gastos_fijos set pagado_por = v_quien where id = v_fila.id and pagado_por is distinct from v_quien
  returning * into v_fila;
  return coalesce(v_fila, (select f from public.gastos_fijos f where f.id = v_fila.id));
end
$$;

-- Los gastos fijos que ya existían: los paga quien los dio de alta.
update public.gastos_fijos f set pagado_por = f.creado_por
  from public.usuarios u where u.id = f.creado_por and u.perfil = 'propietario' and f.pagado_por is null;
update public.gastos g set pagado_por = f.pagado_por
  from public.gastos_fijos f where f.id = g.gasto_fijo_id and g.pagado_por is null and g.forma_pago <> 'caja';

-- Gastos por dueño en un periodo: total y por categoría de cada quien.
create function public.gastos_por_dueno(p_desde date, p_hasta date) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
begin
  perform privado.exigir_perfil('propietario');
  return coalesce((
    select jsonb_agg(x order by x.orden, x.total desc) from (
      select case when g.forma_pago = 'caja' then 'Caja' else coalesce(u.nombre, 'Sin asignar') end quien,
             case when g.forma_pago = 'caja' then 2 when u.id is null then 3 else 1 end orden,
             sum(g.monto) total, count(*) n,
             jsonb_agg(jsonb_build_object('categoria', c.nombre, 'monto', g.monto)) detalle
      from public.gastos g
      join public.categorias_gasto c on c.id = g.categoria_id
      left join public.usuarios u on u.id = g.pagado_por
      where g.estado = 'vigente' and g.fecha between p_desde and p_hasta
      group by 1, 2) x), '[]');
end
$$;

revoke execute on function privado.fijar_quien_pago(uuid), privado.gasto_pagado_por(),
  privado.registrar_gasto_base(uuid, text, numeric, public.forma_pago_gasto, date, text),
  privado.pagar_sueldos_base(jsonb, text, public.forma_pago_gasto, date),
  privado.guardar_gasto_fijo_base(uuid, uuid, text, numeric, integer, public.forma_pago_gasto, date)
  from public, anon, authenticated;
revoke execute on function
  public.registrar_gasto(uuid, text, numeric, public.forma_pago_gasto, date, text, uuid),
  public.pagar_sueldos(jsonb, text, public.forma_pago_gasto, date, uuid),
  public.guardar_gasto_fijo(uuid, uuid, text, numeric, integer, public.forma_pago_gasto, date, uuid),
  public.gastos_por_dueno(date, date)
  from public, anon;
grant execute on function
  public.registrar_gasto(uuid, text, numeric, public.forma_pago_gasto, date, text, uuid),
  public.pagar_sueldos(jsonb, text, public.forma_pago_gasto, date, uuid),
  public.guardar_gasto_fijo(uuid, uuid, text, numeric, integer, public.forma_pago_gasto, date, uuid),
  public.gastos_por_dueno(date, date)
  to authenticated;
