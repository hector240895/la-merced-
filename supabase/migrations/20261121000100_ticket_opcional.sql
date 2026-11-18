-- =============================================================================
-- Sistema La Merced · El ticket de cobro se imprime solo si se pide
--
-- Al cobrar ya no sale el ticket automáticamente (la precuenta ya se imprimió
-- al pedir la cuenta). Se imprime si caja marca "Imprimir ticket" al cobrar,
-- o después con "Imprimir ticket" en la cuenta cobrada.
-- =============================================================================

-- Durante un cobro sin ticket, el ticket que arma el cobro no se manda a imprimir.
create function privado.omitir_ticket() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.documento = 'ticket' and new.reimpresion_de is null
     and coalesce(current_setting('lamerced.sin_ticket', true), '') = '1' then
    return null;
  end if;
  return new;
end
$$;
create trigger trabajos_omitir_ticket before insert on public.trabajos_impresion
  for each row execute function privado.omitir_ticket();

alter function public.cobrar_cuenta(uuid, jsonb, uuid, numeric, public.metodo_pago) rename to cobrar_cuenta_base;
alter function public.cobrar_cuenta_base(uuid, jsonb, uuid, numeric, public.metodo_pago) set schema privado;

create function public.cobrar_cuenta(
  p_cuenta_id uuid, p_pagos jsonb, p_solicitud_id uuid,
  p_propina numeric default 0, p_propina_metodo public.metodo_pago default null,
  p_imprimir_ticket boolean default false
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_res jsonb;
begin
  perform privado.exigir_perfil('propietario', 'cajero');
  perform set_config('lamerced.sin_ticket', case when coalesce(p_imprimir_ticket, false) then '' else '1' end, true);
  v_res := privado.cobrar_cuenta_base(p_cuenta_id, p_pagos, p_solicitud_id, p_propina, p_propina_metodo);
  perform set_config('lamerced.sin_ticket', '', true);
  return v_res || jsonb_build_object('ticket_impreso', coalesce(p_imprimir_ticket, false) and v_res ->> 'ticket_id' is not null);
end
$$;

-- Imprimir el ticket de una cuenta cobrada: la primera vez sale normal; las
-- siguientes, marcadas como REIMPRESIÓN.
create or replace function public.reimprimir_ticket(p_cuenta_id uuid) returns public.trabajos_impresion
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario', 'cajero');
  v_cuenta public.cuentas;
  v_original public.trabajos_impresion;
  v_fila public.trabajos_impresion;
begin
  select * into v_original from public.trabajos_impresion
   where cuenta_id = p_cuenta_id and documento = 'ticket' and reimpresion_de is null
   order by creado_en desc limit 1;
  if not found then
    select * into v_cuenta from public.cuentas where id = p_cuenta_id;
    if not found or v_cuenta.estado <> 'cobrada' then
      raise exception 'La cuenta no está cobrada';
    end if;
    perform privado.fijar_accion('Imprimió el ticket del folio ' || v_cuenta.folio);
    insert into public.trabajos_impresion (sucursal_id, documento, impresora, cuenta_id, turno_id, contenido, creado_por)
    values (v_cuenta.sucursal_id, 'ticket', 'caja', v_cuenta.id, v_cuenta.turno_id, privado.contenido_ticket(v_cuenta.id), v_actor)
    returning * into v_fila;
    return v_fila;
  end if;
  perform privado.fijar_accion('Reimprimió el ticket del folio ' || (v_original.contenido ->> 'folio'));
  insert into public.trabajos_impresion (sucursal_id, documento, impresora, cuenta_id, turno_id, contenido, reimpresion_de, creado_por)
  values (v_original.sucursal_id, 'ticket', 'caja', v_original.cuenta_id, v_original.turno_id,
          v_original.contenido || jsonb_build_object('reimpresion', true,
            'reimprimio', (select u.nombre from public.usuarios u where u.id = v_actor)),
          v_original.id, v_actor)
  returning * into v_fila;
  return v_fila;
end
$$;

-- Ver el ticket en pantalla aunque no se haya impreso.
create function public.ver_ticket(p_cuenta_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_contenido jsonb;
begin
  perform privado.exigir_perfil('propietario', 'cajero');
  select contenido into v_contenido from public.trabajos_impresion
   where cuenta_id = p_cuenta_id and documento = 'ticket' and reimpresion_de is null
   order by creado_en desc limit 1;
  if v_contenido is null then
    if not exists (select 1 from public.cuentas where id = p_cuenta_id and estado = 'cobrada') then
      raise exception 'La cuenta no está cobrada';
    end if;
    v_contenido := privado.contenido_ticket(p_cuenta_id);
  end if;
  return v_contenido;
end
$$;

revoke execute on function privado.omitir_ticket(),
  privado.cobrar_cuenta_base(uuid, jsonb, uuid, numeric, public.metodo_pago) from public, anon, authenticated;
revoke execute on function public.cobrar_cuenta(uuid, jsonb, uuid, numeric, public.metodo_pago, boolean),
  public.ver_ticket(uuid) from public, anon;
grant execute on function public.cobrar_cuenta(uuid, jsonb, uuid, numeric, public.metodo_pago, boolean),
  public.ver_ticket(uuid) to authenticated;
