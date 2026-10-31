-- =============================================================================
-- Sistema La Merced · Etapa 2 · 4/5
-- Autorización cruzada entre propietarios y funciones del servidor de esta
-- etapa: perfil propio, administración de usuarios y avisos.
--
-- Se pide autorización del otro propietario solo para:
--   * cancelar la cuenta de una mesa (o un pedido para llevar) → cancelar_cuenta
--   * anular un cobro registrado                                → anular_cobro
--   * quitar un producto o cobro extra de una cuenta ya cobrada → cancelar_linea_cobrada
-- Nadie aprueba su propia solicitud. Aprobar marca como cancelado o anulado;
-- nunca borra.
-- =============================================================================

create type public.tipo_autorizacion   as enum ('cancelar_cuenta', 'anular_cobro', 'cancelar_linea_cobrada');
create type public.estado_autorizacion as enum ('pendiente', 'aprobada', 'rechazada');

create table public.autorizaciones (
  id               uuid primary key default gen_random_uuid(),
  sucursal_id      uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  tipo             public.tipo_autorizacion not null,
  cuenta_id        uuid not null references public.cuentas (id),
  linea_id         uuid references public.lineas_cuenta (id),
  cobro_extra_id   uuid references public.cobros_extra (id),
  motivo           text not null check (length(trim(motivo)) > 0),
  estado           public.estado_autorizacion not null default 'pendiente',
  solicitada_por   uuid not null references public.usuarios (id),
  solicitada_en    timestamptz not null default now(),
  resuelta_por     uuid references public.usuarios (id),
  resuelta_en      timestamptz,
  comentario       text,
  constraint autorizaciones_no_propia check (resuelta_por is null or resuelta_por <> solicitada_por),
  constraint autorizaciones_resuelta check ((estado = 'pendiente') = (resuelta_por is null and resuelta_en is null)),
  constraint autorizaciones_objetivo check (
    case tipo
      when 'cancelar_linea_cobrada' then num_nonnulls(linea_id, cobro_extra_id) = 1
      else linea_id is null and cobro_extra_id is null
    end)
);
-- Una sola solicitud pendiente por objetivo.
create unique index autorizaciones_una_pendiente on public.autorizaciones
  (tipo, coalesce(linea_id, cobro_extra_id, cuenta_id)) where estado = 'pendiente';
create index autorizaciones_estado_idx on public.autorizaciones (sucursal_id, estado, solicitada_en desc);

alter table public.cuentas       add constraint cuentas_autorizacion_fk       foreign key (autorizacion_id) references public.autorizaciones (id);
alter table public.lineas_cuenta add constraint lineas_autorizacion_fk        foreign key (autorizacion_id) references public.autorizaciones (id);
alter table public.cobros_extra  add constraint cobros_extra_autorizacion_fk  foreign key (autorizacion_id) references public.autorizaciones (id);
alter table public.pagos         add constraint pagos_autorizacion_fk         foreign key (autorizacion_id) references public.autorizaciones (id);
alter table public.propinas      add constraint propinas_autorizacion_fk      foreign key (autorizacion_id) references public.autorizaciones (id);

create trigger autorizaciones_inmutables before update on public.autorizaciones for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'tipo', 'cuenta_id', 'linea_id', 'cobro_extra_id',
                                             'motivo', 'solicitada_por', 'solicitada_en');
create trigger autorizaciones_sello before update on public.autorizaciones for each row
  execute function privado.sellar_columnas('resuelta_por', 'resuelta_en', 'comentario');
create trigger autorizaciones_sin_borrado before delete on public.autorizaciones
  for each row execute function privado.prohibir_borrado();
create trigger autorizaciones_sin_vaciar before truncate on public.autorizaciones
  for each statement execute function privado.prohibir_borrado();
create trigger autorizaciones_auditar after insert or update on public.autorizaciones
  for each row execute function privado.auditar_cambios();

-- =============================================================================
-- Funciones del servidor (se llaman como /rest/v1/rpc/<nombre>)
-- =============================================================================

-- Perfil del usuario con sesión. Vacío si la cuenta está dada de baja.
create function public.yo()
returns table (id uuid, usuario text, nombre text, perfil public.perfil_usuario, sucursal_id uuid)
language sql stable security definer
set search_path = ''
as $$
  select u.id, u.usuario, u.nombre, u.perfil, u.sucursal_id
  from public.usuarios u
  where u.id = auth.uid() and u.activo
$$;

-- -----------------------------------------------------------------------------
-- Administración de usuarios (solo propietarios)
-- El alta del acceso (correo interno y contraseña) la hace la función
-- admin-usuarios con la llave de servicio; aquí se registra el perfil.
-- -----------------------------------------------------------------------------
create function public.registrar_usuario(
  p_id uuid, p_usuario text, p_nombre text, p_perfil public.perfil_usuario
) returns public.usuarios
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_usuario text := lower(trim(p_usuario));
  v_fila public.usuarios;
begin
  if p_perfil not in ('cajero', 'mesero') then
    raise exception 'Solo se agregan cuentas de mesero o cajero' using errcode = '42501';
  end if;
  if not exists (select 1 from auth.users a where a.id = p_id and split_part(a.email, '@', 1) = v_usuario) then
    raise exception 'No existe el acceso para el usuario %', v_usuario;
  end if;

  perform privado.fijar_accion(format('Creó la cuenta de %s (%s)', trim(p_nombre), p_perfil));
  insert into public.usuarios (id, sucursal_id, usuario, nombre, perfil, creado_por)
  values (p_id, (select u.sucursal_id from public.usuarios u where u.id = v_actor),
          v_usuario, trim(p_nombre), p_perfil, v_actor)
  returning * into v_fila;
  return v_fila;
end
$$;

create function public.renombrar_usuario(p_id uuid, p_nombre text) returns public.usuarios
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fila public.usuarios;
begin
  perform privado.exigir_perfil('propietario');
  select * into v_fila from public.usuarios where id = p_id for update;
  if not found then
    raise exception 'El usuario no existe';
  end if;
  perform privado.fijar_accion(format('Cambió el nombre de %s a %s', v_fila.nombre, trim(p_nombre)));
  update public.usuarios set nombre = trim(p_nombre) where id = p_id returning * into v_fila;
  return v_fila;
end
$$;

create function public.cambiar_perfil_usuario(p_id uuid, p_perfil public.perfil_usuario) returns public.usuarios
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fila public.usuarios;
begin
  perform privado.exigir_perfil('propietario');
  select * into v_fila from public.usuarios where id = p_id for update;
  if not found then
    raise exception 'El usuario no existe';
  end if;
  if v_fila.perfil = 'propietario' or p_perfil = 'propietario' then
    raise exception 'Solo se cambia entre mesero y cajero' using errcode = '42501';
  end if;
  perform privado.fijar_accion(format('Cambió el perfil de %s de %s a %s', v_fila.nombre, v_fila.perfil, p_perfil));
  update public.usuarios set perfil = p_perfil where id = p_id returning * into v_fila;
  return v_fila;
end
$$;

create function public.dar_de_baja_usuario(p_id uuid, p_motivo text) returns public.usuarios
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_fila public.usuarios;
begin
  if coalesce(length(trim(p_motivo)), 0) = 0 then
    raise exception 'Escribe el motivo de la baja';
  end if;
  select * into v_fila from public.usuarios where id = p_id for update;
  if not found then
    raise exception 'El usuario no existe';
  end if;
  if v_fila.perfil = 'propietario' then
    raise exception 'Las cuentas de propietario no se dan de baja' using errcode = '42501';
  end if;
  if not v_fila.activo then
    raise exception '% ya está dado de baja', v_fila.nombre;
  end if;
  perform privado.fijar_accion(format('Dio de baja la cuenta de %s (%s)', v_fila.nombre, v_fila.perfil), p_motivo);
  update public.usuarios
     set activo = false, baja_en = now(), baja_por = v_actor, baja_motivo = trim(p_motivo)
   where id = p_id
  returning * into v_fila;
  return v_fila;
end
$$;

create function public.reactivar_usuario(p_id uuid) returns public.usuarios
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fila public.usuarios;
begin
  perform privado.exigir_perfil('propietario');
  select * into v_fila from public.usuarios where id = p_id for update;
  if not found then
    raise exception 'El usuario no existe';
  end if;
  if v_fila.activo then
    raise exception '% ya está activo', v_fila.nombre;
  end if;
  -- La baja anterior queda en la auditoría.
  perform privado.fijar_accion(format('Reactivó la cuenta de %s (%s)', v_fila.nombre, v_fila.perfil));
  update public.usuarios
     set activo = true, baja_en = null, baja_por = null, baja_motivo = null
   where id = p_id
  returning * into v_fila;
  return v_fila;
end
$$;

-- Un propietario cambia la contraseña de meseros, cajeros o la suya.
-- Nunca la del otro propietario (podría aprobar en su nombre).
create function public.registrar_cambio_contrasena(p_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_fila public.usuarios;
begin
  select * into v_fila from public.usuarios where id = p_id;
  if not found then
    raise exception 'El usuario no existe';
  end if;
  if v_fila.perfil = 'propietario' and v_fila.id <> v_actor then
    raise exception 'Cada propietario cambia solo su propia contraseña' using errcode = '42501';
  end if;
  perform privado.registrar_auditoria(
    format('Cambió la contraseña de %s', v_fila.nombre), 'usuarios', p_id::text);
end
$$;

-- Alta de las dos cuentas de propietario durante la instalación.
-- Solo con la llave de servicio (script scripts/crear-propietario.mjs).
create function public.instalar_propietario(p_id uuid, p_usuario text, p_nombre text) returns public.usuarios
language plpgsql security definer
set search_path = ''
as $$
declare
  v_usuario text := lower(trim(p_usuario));
  v_fila public.usuarios;
begin
  if not exists (select 1 from auth.users a where a.id = p_id and split_part(a.email, '@', 1) = v_usuario) then
    raise exception 'No existe el acceso para el usuario %', v_usuario;
  end if;
  perform privado.fijar_accion(format('Instalación: se creó la cuenta de propietario de %s', trim(p_nombre)));
  insert into public.usuarios (id, usuario, nombre, perfil)
  values (p_id, v_usuario, trim(p_nombre), 'propietario')
  returning * into v_fila;
  return v_fila;
end
$$;

-- -----------------------------------------------------------------------------
-- Avisos
-- -----------------------------------------------------------------------------
create function public.marcar_avisos_leidos(p_ids bigint[] default null) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_n integer;
begin
  update public.avisos
     set leido_en = now()
   where para_usuario_id = v_actor and leido_en is null
     and (p_ids is null or id = any (p_ids));
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

-- -----------------------------------------------------------------------------
-- Autorizaciones
-- -----------------------------------------------------------------------------
create function public.solicitar_autorizacion(
  p_tipo public.tipo_autorizacion,
  p_cuenta_id uuid,
  p_motivo text,
  p_linea_id uuid default null,
  p_cobro_extra_id uuid default null
) returns public.autorizaciones
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_cuenta public.cuentas;
  v_desc text;
  v_fila public.autorizaciones;
begin
  if coalesce(length(trim(p_motivo)), 0) = 0 then
    raise exception 'Escribe el motivo de la solicitud';
  end if;
  select * into v_cuenta from public.cuentas where id = p_cuenta_id;
  if not found then
    raise exception 'La cuenta no existe';
  end if;
  v_desc := case when v_cuenta.tipo = 'mesa'
                 then 'la cuenta de ' || coalesce((select m.nombre from public.mesas m where m.id = v_cuenta.mesa_id), 'mesa')
                 else 'el pedido para llevar' end || ' (folio ' || v_cuenta.folio || ')';

  if p_tipo = 'cancelar_cuenta' then
    if v_cuenta.estado not in ('abierta', 'por_cobrar') then
      raise exception 'Solo se cancela una cuenta abierta o por cobrar; si ya se cobró, primero se anula el cobro';
    end if;
    v_desc := 'Solicitó cancelar ' || v_desc;
  elsif p_tipo = 'anular_cobro' then
    if v_cuenta.estado <> 'cobrada' then
      raise exception 'La cuenta no tiene un cobro registrado';
    end if;
    v_desc := 'Solicitó anular el cobro de ' || v_desc;
  else
    if v_cuenta.estado <> 'cobrada' then
      raise exception 'La cuenta aún no se cobra: el producto se quita sin autorización, con motivo';
    end if;
    if num_nonnulls(p_linea_id, p_cobro_extra_id) <> 1 then
      raise exception 'Indica el producto o el cobro extra que se quita';
    end if;
    if p_linea_id is not null and not exists (
         select 1 from public.lineas_cuenta l
         where l.id = p_linea_id and l.cuenta_id = p_cuenta_id and l.estado = 'activa') then
      raise exception 'El producto no pertenece a la cuenta o ya está cancelado';
    end if;
    if p_cobro_extra_id is not null and not exists (
         select 1 from public.cobros_extra x
         where x.id = p_cobro_extra_id and x.cuenta_id = p_cuenta_id and x.estado = 'activa') then
      raise exception 'El cobro extra no pertenece a la cuenta o ya está cancelado';
    end if;
    v_desc := 'Solicitó quitar ' ||
              coalesce((select l.cantidad || ' × ' || l.nombre_producto from public.lineas_cuenta l where l.id = p_linea_id),
                       (select 'el cobro extra "' || x.concepto || '"' from public.cobros_extra x where x.id = p_cobro_extra_id)) ||
              ' de ' || v_desc;
  end if;

  if exists (select 1 from public.autorizaciones a
             where a.estado = 'pendiente' and a.tipo = p_tipo
               and coalesce(a.linea_id, a.cobro_extra_id, a.cuenta_id) = coalesce(p_linea_id, p_cobro_extra_id, p_cuenta_id)) then
    raise exception 'Ya hay una solicitud pendiente para esto';
  end if;

  perform privado.fijar_accion(v_desc, p_motivo);
  insert into public.autorizaciones (sucursal_id, tipo, cuenta_id, linea_id, cobro_extra_id, motivo, solicitada_por)
  values (v_cuenta.sucursal_id, p_tipo, p_cuenta_id, p_linea_id, p_cobro_extra_id, trim(p_motivo), v_actor)
  returning * into v_fila;
  return v_fila;
end
$$;

-- El otro propietario aprueba o rechaza desde su sesión.
create function public.resolver_autorizacion(
  p_id uuid, p_aprobar boolean, p_comentario text default null
) returns public.autorizaciones
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.exigir_perfil('propietario');
  v_aut public.autorizaciones;
  v_cuenta public.cuentas;
begin
  select * into v_aut from public.autorizaciones where id = p_id for update;
  if not found then
    raise exception 'La solicitud no existe';
  end if;
  if v_aut.estado <> 'pendiente' then
    raise exception 'La solicitud ya fue resuelta';
  end if;
  if v_aut.solicitada_por = v_actor then
    raise exception 'Nadie puede aprobar ni rechazar su propia solicitud' using errcode = '42501';
  end if;

  select * into v_cuenta from public.cuentas where id = v_aut.cuenta_id for update;

  if not p_aprobar then
    perform privado.fijar_accion('Rechazó la solicitud: ' || v_aut.tipo, p_comentario);
    update public.autorizaciones
       set estado = 'rechazada', resuelta_por = v_actor, resuelta_en = now(), comentario = nullif(trim(p_comentario), '')
     where id = p_id
    returning * into v_aut;
    return v_aut;
  end if;

  perform privado.fijar_accion('Aprobó la solicitud: ' || v_aut.tipo, p_comentario);
  update public.autorizaciones
     set estado = 'aprobada', resuelta_por = v_actor, resuelta_en = now(), comentario = nullif(trim(p_comentario), '')
   where id = p_id
  returning * into v_aut;

  if v_aut.tipo = 'cancelar_cuenta' then
    if v_cuenta.estado not in ('abierta', 'por_cobrar') then
      raise exception 'La cuenta ya no está abierta; la solicitud ya no aplica, recházala para cerrarla';
    end if;
    perform privado.fijar_accion('Cuenta cancelada con autorización', v_aut.motivo);
    update public.cuentas
       set estado = 'cancelada', cancelada_en = now(), cancelada_por = v_aut.solicitada_por,
           cancelacion_motivo = v_aut.motivo, autorizacion_id = v_aut.id
     where id = v_cuenta.id;
    -- La mesa (y las unidas a ella) queda libre; la cuenta conserva todo su detalle.
    if v_cuenta.mesa_id is not null and v_cuenta.cobro_anulado_en is null then
      update public.mesas set estado = 'disponible', unida_a = null
       where id = v_cuenta.mesa_id or unida_a = v_cuenta.mesa_id;
    end if;

  elsif v_aut.tipo = 'anular_cobro' then
    if v_cuenta.estado <> 'cobrada' then
      raise exception 'La cuenta ya no está cobrada; la solicitud ya no aplica, recházala para cerrarla';
    end if;
    perform privado.fijar_accion('Cobro anulado con autorización', v_aut.motivo);
    update public.pagos
       set estado = 'anulado', anulado_en = now(), anulado_por = v_aut.solicitada_por,
           anulacion_motivo = v_aut.motivo, autorizacion_id = v_aut.id
     where cuenta_id = v_cuenta.id and estado = 'vigente';
    update public.propinas
       set estado = 'anulado', anulado_en = now(), anulado_por = v_aut.solicitada_por,
           anulacion_motivo = v_aut.motivo, autorizacion_id = v_aut.id
     where cuenta_id = v_cuenta.id and estado = 'vigente';
    -- La cuenta vuelve a "por cobrar" en caja con su mismo detalle.
    update public.cuentas
       set estado = 'por_cobrar', cobrada_en = null, subtotal = null, impuestos = null, total = null,
           cobro_anulado_en = now()
     where id = v_cuenta.id;

  else
    if v_cuenta.estado <> 'cobrada' then
      raise exception 'La cuenta ya no está cobrada; la solicitud ya no aplica, recházala para cerrarla';
    end if;
    perform privado.fijar_accion('Concepto quitado de una cuenta cobrada, con autorización', v_aut.motivo);
    if v_aut.linea_id is not null then
      update public.lineas_cuenta
         set estado = 'cancelada', cancelada_en = now(), cancelada_por = v_aut.solicitada_por,
             cancelacion_motivo = v_aut.motivo, autorizacion_id = v_aut.id
       where id = v_aut.linea_id and estado = 'activa';
    else
      update public.cobros_extra
         set estado = 'cancelada', cancelada_en = now(), cancelada_por = v_aut.solicitada_por,
             cancelacion_motivo = v_aut.motivo, autorizacion_id = v_aut.id
       where id = v_aut.cobro_extra_id and estado = 'activa';
    end if;
    if not found then
      raise exception 'El concepto ya estaba cancelado; la solicitud ya no aplica, recházala para cerrarla';
    end if;
  end if;

  return v_aut;
end
$$;
