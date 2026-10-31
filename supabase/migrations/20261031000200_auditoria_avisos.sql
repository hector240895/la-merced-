-- =============================================================================
-- Sistema La Merced · Etapa 2 · 2/5
-- Auditoría (solo se agregan filas), avisos entre propietarios y disparadores
-- genéricos: prohibir borrado, columnas que no cambian y registro de cambios.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Auditoría
-- -----------------------------------------------------------------------------
create table public.auditoria (
  id           bigint generated always as identity primary key,
  sucursal_id  uuid references public.sucursales (id),
  creado_en    timestamptz not null default now(),
  usuario_id   uuid references public.usuarios (id),   -- null = sistema / instalación
  perfil       public.perfil_usuario,
  accion       text not null,
  tabla        text,
  registro_id  text,
  motivo       text,
  antes        jsonb,
  despues      jsonb
);

create index auditoria_creado_idx  on public.auditoria (creado_en desc);
create index auditoria_usuario_idx on public.auditoria (usuario_id, creado_en desc);
create index auditoria_registro_idx on public.auditoria (tabla, registro_id);

-- -----------------------------------------------------------------------------
-- Avisos: cada movimiento de un propietario se avisa al otro.
-- El texto sale de la fila de auditoría correspondiente.
-- -----------------------------------------------------------------------------
create table public.avisos (
  id               bigint generated always as identity primary key,
  sucursal_id      uuid references public.sucursales (id),
  para_usuario_id  uuid not null references public.usuarios (id),
  auditoria_id     bigint not null references public.auditoria (id),
  creado_en        timestamptz not null default now(),
  leido_en         timestamptz
);

create index avisos_para_idx on public.avisos (para_usuario_id, creado_en desc);

-- -----------------------------------------------------------------------------
-- Disparadores genéricos
-- -----------------------------------------------------------------------------

-- Nada se borra físicamente, ni siquiera con la llave de servicio.
create function privado.prohibir_borrado() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'No se permite borrar registros de %. Se marcan como cancelados, anulados o dados de baja.',
    tg_table_name using errcode = '42501';
end
$$;

-- La auditoría no se edita.
create function privado.prohibir_cambio() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Los registros de % no se pueden modificar; las correcciones se registran como movimientos nuevos.',
    tg_table_name using errcode = '42501';
end
$$;

-- Columnas que nunca cambian después de crearse (lista en los argumentos).
create function privado.proteger_columnas() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_old jsonb := to_jsonb(old);
  v_new jsonb := to_jsonb(new);
  v_col text;
begin
  foreach v_col in array tg_argv loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'El campo % de % no se puede modificar', v_col, tg_table_name
        using errcode = '42501';
    end if;
  end loop;
  return new;
end
$$;

-- Columnas "sello": pasan de vacías a un valor una sola vez y ya no cambian.
-- Se usa para cancelaciones y anulaciones: lo cancelado no se des-cancela.
create function privado.sellar_columnas() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_old jsonb := to_jsonb(old);
  v_new jsonb := to_jsonb(new);
  v_col text;
begin
  foreach v_col in array tg_argv loop
    if v_old ->> v_col is not null and v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'El campo % de % ya quedó registrado y no se puede cambiar', v_col, tg_table_name
        using errcode = '42501';
    end if;
  end loop;
  return new;
end
$$;

-- Agrega una fila de auditoría. Única vía de escritura en la tabla.
create function privado.registrar_auditoria(
  p_accion text,
  p_tabla text default null,
  p_registro_id text default null,
  p_motivo text default null,
  p_antes jsonb default null,
  p_despues jsonb default null,
  p_sucursal_id uuid default null
) returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.actor();
  v_perfil public.perfil_usuario;
  v_sucursal uuid;
  v_id bigint;
begin
  select u.perfil, u.sucursal_id into v_perfil, v_sucursal from public.usuarios u where u.id = v_actor;
  insert into public.auditoria (sucursal_id, usuario_id, perfil, accion, tabla, registro_id, motivo, antes, despues)
  values (coalesce(p_sucursal_id, v_sucursal, '00000000-0000-0000-0000-000000000001'),
          case when v_perfil is null then null else v_actor end,
          v_perfil, p_accion, p_tabla, p_registro_id, nullif(trim(p_motivo), ''), p_antes, p_despues)
  returning id into v_id;
  return v_id;
end
$$;

-- Etiqueta legible de la operación en curso; las funciones del servidor la
-- fijan antes de escribir. Si no hay etiqueta, se describe la operación.
create function privado.fijar_accion(p_accion text, p_motivo text default null) returns void
language sql
set search_path = ''
as $$
  select set_config('app.accion', coalesce(p_accion, ''), true),
         set_config('app.motivo', coalesce(p_motivo, ''), true);
$$;

-- Registra en auditoría cada alta y cada cambio, con el antes y el después.
create function privado.auditar_cambios() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_antes jsonb;
  v_despues jsonb := to_jsonb(new);
  v_accion text := nullif(current_setting('app.accion', true), '');
begin
  if tg_op = 'UPDATE' then
    v_antes := to_jsonb(old);
    if v_antes = v_despues then
      return null;
    end if;
  end if;
  perform privado.registrar_auditoria(
    coalesce(v_accion, case tg_op when 'INSERT' then 'Alta en ' else 'Cambio en ' end || tg_table_name),
    tg_table_name,
    v_despues ->> 'id',
    nullif(current_setting('app.motivo', true), ''),
    v_antes,
    v_despues,
    (v_despues ->> 'sucursal_id')::uuid
  );
  return null;
end
$$;

-- Aviso inmediato al otro propietario por cada movimiento de un propietario.
create function privado.avisar_otro_propietario() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.perfil = 'propietario' then
    insert into public.avisos (sucursal_id, para_usuario_id, auditoria_id)
    select new.sucursal_id, u.id, new.id
    from public.usuarios u
    where u.perfil = 'propietario' and u.activo and u.id <> new.usuario_id;
  end if;
  return null;
end
$$;

-- Avisos: solo puede cambiar leido_en, y una sola vez.
create function privado.validar_aviso() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (to_jsonb(new) - 'leido_en') <> (to_jsonb(old) - 'leido_en')
     or (old.leido_en is not null and new.leido_en is distinct from old.leido_en) then
    raise exception 'De un aviso solo se registra cuándo se leyó' using errcode = '42501';
  end if;
  return new;
end
$$;

create trigger auditoria_sin_cambios before update on public.auditoria
for each row execute function privado.prohibir_cambio();
create trigger auditoria_sin_borrado before delete on public.auditoria
for each row execute function privado.prohibir_borrado();
create trigger auditoria_sin_vaciar before truncate on public.auditoria
for each statement execute function privado.prohibir_borrado();
create trigger auditoria_avisar after insert on public.auditoria
for each row execute function privado.avisar_otro_propietario();

create trigger avisos_validar before update on public.avisos
for each row execute function privado.validar_aviso();
create trigger avisos_sin_borrado before delete on public.avisos
for each row execute function privado.prohibir_borrado();
create trigger avisos_sin_vaciar before truncate on public.avisos
for each statement execute function privado.prohibir_borrado();

-- Usuarios: sin borrado y con registro de cambios.
create trigger usuarios_sin_borrado before delete on public.usuarios
for each row execute function privado.prohibir_borrado();
create trigger usuarios_sin_vaciar before truncate on public.usuarios
for each statement execute function privado.prohibir_borrado();
create trigger usuarios_auditar after insert or update on public.usuarios
for each row execute function privado.auditar_cambios();

create trigger sucursales_sin_borrado before delete on public.sucursales
for each row execute function privado.prohibir_borrado();
create trigger sucursales_sin_vaciar before truncate on public.sucursales
for each statement execute function privado.prohibir_borrado();
create trigger sucursales_auditar after insert or update on public.sucursales
for each row execute function privado.auditar_cambios();
