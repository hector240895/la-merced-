-- =============================================================================
-- Sistema La Merced · Precuenta (cuenta informativa antes de cobrar)
--
-- Se imprime en la impresora de caja (NE-510X):
--   * sola, cuando el mesero toca "Pedir la cuenta";
--   * cuando la piden de nuevo el mesero, la caja o un propietario.
-- Lleva la mesa (o "Para llevar #folio") para saber de dónde es, los productos,
-- los cobros extra, el total y la leyenda CUENTA NO PAGADA.
-- No cambia la mesa, no registra pagos y no entra al corte. Queda en la
-- auditoría quién la imprimió.
-- =============================================================================

create function privado.contenido_precuenta(p_cuenta_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'documento', 'precuenta',
    'negocio',   coalesce(s.nombre_comercial, s.nombre),
    'destino',   privado.nombre_cuenta(k),
    'folio',     k.folio,
    'fecha',     to_char(now() at time zone s.zona_horaria, 'DD/MM/YYYY'),
    'hora',      to_char(now() at time zone s.zona_horaria, 'HH24:MI'),
    'lineas', coalesce((select jsonb_agg(jsonb_build_object(
                 'cantidad', l.cantidad, 'producto', l.nombre_producto, 'opcion', l.opcion,
                 'precio_unitario', l.precio_unitario, 'importe', l.precio_unitario * l.cantidad) order by l.creado_en, l.nombre_producto)
               from public.lineas_cuenta l where l.cuenta_id = k.id and l.estado = 'activa'), '[]'::jsonb),
    'extras', coalesce((select jsonb_agg(jsonb_build_object('concepto', x.concepto, 'importe', x.importe) order by x.creado_en)
               from public.cobros_extra x where x.cuenta_id = k.id and x.estado = 'activa'), '[]'::jsonb),
    'total',     privado.total_cuenta(k.id),
    'leyenda',   'CUENTA NO PAGADA')
  from public.cuentas k join public.sucursales s on s.id = k.sucursal_id
  where k.id = p_cuenta_id
$$;

-- Encola la precuenta de una cuenta (uso interno).
create function privado.encolar_precuenta(p_cuenta public.cuentas) returns public.trabajos_impresion
language plpgsql
set search_path = ''
as $$
declare
  v_fila public.trabajos_impresion;
begin
  insert into public.trabajos_impresion (sucursal_id, documento, impresora, cuenta_id, contenido)
  values (p_cuenta.sucursal_id, 'precuenta', 'caja', p_cuenta.id, privado.contenido_precuenta(p_cuenta.id))
  returning * into v_fila;
  return v_fila;
end
$$;

-- Imprimir (o volver a imprimir) la cuenta: mesero, caja o propietarios.
create function public.imprimir_precuenta(p_cuenta_id uuid) returns public.trabajos_impresion
language plpgsql security definer
set search_path = ''
as $$
declare
  v_cuenta public.cuentas;
begin
  perform privado.exigir_perfil('propietario', 'cajero', 'mesero');
  select * into v_cuenta from public.cuentas where id = p_cuenta_id;
  if not found or v_cuenta.estado not in ('abierta', 'por_cobrar') then
    raise exception 'La cuenta no está abierta';
  end if;
  if privado.total_cuenta(v_cuenta.id) <= 0 then
    raise exception 'La cuenta no tiene productos';
  end if;
  perform privado.fijar_accion('Imprimió la cuenta de ' || privado.nombre_cuenta(v_cuenta));
  return privado.encolar_precuenta(v_cuenta);
end
$$;

-- Pedir la cuenta: además de dejar la mesa por cobrar, imprime la precuenta en caja.
create or replace function public.pedir_cuenta(p_mesa_id uuid) returns void
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
  update public.cuentas set estado = 'por_cobrar', cuenta_pedida_en = now() where id = v_cuenta.id
  returning * into v_cuenta;
  perform privado.fijar_estado_grupo(v_mesa.id, 'por_cobrar');
  perform privado.encolar_precuenta(v_cuenta);
end
$$;

-- El mesero ve el estado de impresión de las comandas y precuentas de sus cuentas.
drop policy trabajos_leer on public.trabajos_impresion;
create policy trabajos_leer on public.trabajos_impresion for select to authenticated
  using ((select privado.tiene_perfil('propietario', 'cajero'))
         or ((select privado.tiene_perfil('mesero')) and documento in ('comanda', 'precuenta')
             and exists (select 1 from public.cuentas c where c.id = cuenta_id)));

revoke execute on function privado.contenido_precuenta(uuid), privado.encolar_precuenta(public.cuentas)
  from public, anon, authenticated;
revoke execute on function public.imprimir_precuenta(uuid) from public, anon;
grant execute on function public.imprimir_precuenta(uuid) to authenticated;
