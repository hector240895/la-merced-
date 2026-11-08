-- =============================================================================
-- Sistema La Merced · Etapa 4 · Comandas
--
-- Cada comanda (pedido nuevo, adicional o aviso CANCELADO) genera un trabajo
-- de impresión para la impresora de cocina, con el contenido ya armado:
-- mesa, hora, mesero, productos, sabores y observaciones. Nunca precios.
--
-- El trabajo nace "pendiente". El servicio de impresión de la computadora de
-- caja (Etapa 6) lo imprime e informa "impreso" o "error"; mientras tanto,
-- la app muestra el estado y una vista previa de la comanda.
-- =============================================================================

-- Las comandas nunca llevan precios ni importes: la base lo rechaza.
alter table public.trabajos_impresion
  add constraint trabajos_comanda_sin_precios check (
    documento <> 'comanda'
    or not (contenido::text ~* '"(precio|precio_unitario|importe|total|subtotal|impuestos|pago|propina)[a-z_]*"\s*:'));

-- -----------------------------------------------------------------------------
-- Contenido de la comanda (lo que imprime la impresora de cocina)
-- -----------------------------------------------------------------------------
create function privado.contenido_comanda(p_comanda_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'documento',  'comanda',
    'tipo',       c.tipo,
    'numero',     c.numero,
    'folio',      k.folio,
    'para_llevar', k.tipo = 'llevar',
    'destino',    case when k.tipo = 'llevar' then 'PARA LLEVAR'
                       else coalesce(privado.nombre_grupo(privado.mesa_principal(k.mesa_id)), 'Mesa') end,
    'usuario',    coalesce(u.nombre, 'Sistema'),
    'fecha',      to_char(c.creado_en at time zone s.zona_horaria, 'DD/MM/YYYY'),
    'hora',       to_char(c.creado_en at time zone s.zona_horaria, 'HH24:MI'),
    'lineas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'cantidad',    cl.cantidad,
               'producto',    l.nombre_producto,
               'opcion',      l.opcion,
               'observacion', l.observacion,
               'leyenda',     cl.leyenda)
             order by cl.creado_en, l.nombre_producto)
      from public.comanda_lineas cl join public.lineas_cuenta l on l.id = cl.linea_id
      where cl.comanda_id = c.id), '[]'::jsonb))
  from public.comandas c
  join public.cuentas k on k.id = c.cuenta_id
  join public.sucursales s on s.id = c.sucursal_id
  left join public.usuarios u on u.id = c.creado_por
  where c.id = p_comanda_id
$$;

-- Al terminar la operación que creó la comanda (cuando ya tiene todas sus
-- líneas) se encola su impresión. Sirve igual para mesas y para llevar.
create function privado.encolar_comanda() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.trabajos_impresion t where t.comanda_id = new.id and t.reimpresion_de is null)
     and exists (select 1 from public.comanda_lineas cl where cl.comanda_id = new.id) then
    insert into public.trabajos_impresion (sucursal_id, documento, impresora, comanda_id, cuenta_id, contenido, creado_por)
    values (new.sucursal_id, 'comanda', 'cocina', new.id, new.cuenta_id, privado.contenido_comanda(new.id), new.creado_por);
  end if;
  return null;
end
$$;

create constraint trigger comandas_imprimir
after insert on public.comandas
deferrable initially deferred
for each row execute function privado.encolar_comanda();

-- -----------------------------------------------------------------------------
-- Estado de impresión
-- -----------------------------------------------------------------------------

-- El servicio de impresión (Etapa 6) informa el resultado. Repetir el aviso
-- de "impreso" no cambia nada: así una reconexión no duplica ni confunde.
create function public.reportar_impresion(p_trabajo_id uuid, p_impreso boolean, p_error text default null)
returns public.trabajos_impresion
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fila public.trabajos_impresion;
begin
  perform privado.exigir_perfil('propietario', 'cajero');
  select * into v_fila from public.trabajos_impresion where id = p_trabajo_id for update;
  if not found then
    raise exception 'El trabajo de impresión no existe';
  end if;
  if v_fila.estado = 'impreso' then
    return v_fila;
  end if;
  update public.trabajos_impresion
     set estado = case when p_impreso then 'impreso' else 'error' end::public.estado_impresion,
         intentos = intentos + 1,
         impreso_en = case when p_impreso then now() end,
         ultimo_error = case when p_impreso then null else coalesce(nullif(trim(p_error), ''), 'Error de impresión') end,
         actualizado_en = now()
   where id = p_trabajo_id
  returning * into v_fila;
  return v_fila;
end
$$;

-- Reintentar una comanda que no salió (vuelve a la cola).
create function public.reintentar_impresion(p_trabajo_id uuid) returns public.trabajos_impresion
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fila public.trabajos_impresion;
begin
  perform privado.exigir_perfil('propietario', 'cajero', 'mesero');
  select * into v_fila from public.trabajos_impresion where id = p_trabajo_id for update;
  if not found or (privado.perfil_actual() = 'mesero' and v_fila.documento <> 'comanda') then
    raise exception 'El trabajo de impresión no existe';
  end if;
  if v_fila.estado <> 'error' then
    raise exception 'Solo se reintenta una impresión que falló';
  end if;
  perform privado.registrar_auditoria('Reintentó imprimir la comanda ' || coalesce(v_fila.contenido ->> 'numero', '')
                                      || ' de ' || coalesce(v_fila.contenido ->> 'destino', ''), 'trabajos_impresion', v_fila.id::text);
  update public.trabajos_impresion set estado = 'pendiente', actualizado_en = now()
   where id = p_trabajo_id
  returning * into v_fila;
  return v_fila;
end
$$;

-- Reimpresión manual: un trabajo nuevo con el mismo contenido, marcado como
-- reimpresión y registrado con quién la pidió.
create function public.reimprimir_comanda(p_comanda_id uuid) returns public.trabajos_impresion
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
  -- El mesero solo reimprime comandas de cuentas que puede ver (abiertas).
  if privado.perfil_actual() = 'mesero' and not exists (
       select 1 from public.cuentas c
       where c.id = v_original.cuenta_id and c.tipo = 'mesa' and c.estado in ('abierta', 'por_cobrar')) then
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
-- Permisos y tiempo real
-- -----------------------------------------------------------------------------
revoke execute on function privado.contenido_comanda(uuid), privado.encolar_comanda()
  from public, anon, authenticated;
revoke execute on function public.reportar_impresion(uuid, boolean, text), public.reintentar_impresion(uuid),
  public.reimprimir_comanda(uuid) from public, anon;
grant execute on function public.reportar_impresion(uuid, boolean, text), public.reintentar_impresion(uuid),
  public.reimprimir_comanda(uuid) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'trabajos_impresion') then
    alter publication supabase_realtime add table public.trabajos_impresion;
  end if;
end
$$;
