-- =============================================================================
-- Sistema La Merced · Etapa 2 · 1/5
-- Base: esquema privado, sucursales, usuarios y funciones de apoyo de permisos.
--
-- Reglas de todo el esquema:
--   * Nada se borra físicamente (ver prohibir_borrado en 2/5).
--   * Los clientes (anon / authenticated) no escriben directo en las tablas:
--     toda escritura pasa por funciones del servidor que validan el perfil.
--   * La lectura se controla con Row Level Security por perfil.
-- =============================================================================

-- Funciones internas: no se exponen por la API (PostgREST solo expone public).
create schema if not exists privado;
revoke all on schema privado from public, anon;
grant usage on schema privado to authenticated, service_role;

-- Nada nuevo en public queda abierto por omisión: se otorga explícitamente.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema privado revoke execute on functions from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Sucursales (hoy una sola; preparado para más)
-- -----------------------------------------------------------------------------
create table public.sucursales (
  id            uuid primary key default gen_random_uuid(),
  nombre        text not null check (length(trim(nombre)) > 0),
  zona_horaria  text not null default 'America/Mexico_City',
  moneda        text not null default 'MXN',
  creado_en     timestamptz not null default now(),
  creado_por    uuid
);

insert into public.sucursales (id, nombre)
values ('00000000-0000-0000-0000-000000000001', 'La Merced');

-- -----------------------------------------------------------------------------
-- Usuarios
-- La contraseña cifrada vive en auth.users (Supabase Auth); aquí el perfil.
-- Se inicia sesión con "usuario" + contraseña; por dentro el correo es
-- <usuario>@lamerced.local.
-- -----------------------------------------------------------------------------
create type public.perfil_usuario as enum ('propietario', 'cajero', 'mesero');

create table public.usuarios (
  id           uuid primary key references auth.users (id) on delete restrict,
  sucursal_id  uuid not null default '00000000-0000-0000-0000-000000000001'
               references public.sucursales (id),
  usuario      text not null unique check (usuario ~ '^[a-z0-9][a-z0-9._-]{2,29}$'),
  nombre       text not null check (length(trim(nombre)) between 1 and 80),
  perfil       public.perfil_usuario not null,
  activo       boolean not null default true,
  baja_en      timestamptz,
  baja_por     uuid references public.usuarios (id),
  baja_motivo  text,
  creado_en    timestamptz not null default now(),
  creado_por   uuid references public.usuarios (id),
  -- Una cuenta dada de baja siempre dice cuándo, quién y por qué.
  constraint usuarios_baja_completa check (
    activo or (baja_en is not null and baja_por is not null and length(trim(baja_motivo)) > 0)
  ),
  -- Las cuentas de propietario no se dan de baja.
  constraint usuarios_propietario_activo check (perfil <> 'propietario' or activo)
);

create index usuarios_perfil_idx on public.usuarios (perfil) where activo;

-- -----------------------------------------------------------------------------
-- Funciones de apoyo para permisos
-- Todas revisan "activo": dar de baja corta el acceso a los datos de inmediato,
-- aunque la sesión del usuario siga abierta en su teléfono.
-- -----------------------------------------------------------------------------

-- Usuario que hace la operación. En funciones llamadas con la llave de
-- servicio (sin sesión) se puede indicar con app.actor; nunca reemplaza a una
-- sesión real.
create function privado.actor() returns uuid
language sql stable
set search_path = ''
as $$
  select coalesce(auth.uid(), nullif(current_setting('app.actor', true), '')::uuid)
$$;

create function privado.perfil_actual() returns public.perfil_usuario
language sql stable security definer
set search_path = ''
as $$
  select u.perfil from public.usuarios u where u.id = auth.uid() and u.activo
$$;

create function privado.es_propietario() returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce(privado.perfil_actual() = 'propietario', false)
$$;

create function privado.tiene_perfil(variadic perfiles public.perfil_usuario[]) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce(privado.perfil_actual() = any (perfiles), false)
$$;

-- Lanza error si el usuario actual no tiene alguno de los perfiles indicados.
create function privado.exigir_perfil(variadic perfiles public.perfil_usuario[]) returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_actor uuid := privado.actor();
  v_perfil public.perfil_usuario;
begin
  select u.perfil into v_perfil from public.usuarios u where u.id = v_actor and u.activo;
  if v_perfil is null or not (v_perfil = any (perfiles)) then
    raise exception 'Permiso denegado: esta acción requiere perfil %', array_to_string(perfiles, ' o ')
      using errcode = '42501';
  end if;
  return v_actor;
end
$$;

grant execute on function privado.actor(), privado.perfil_actual(), privado.es_propietario(),
  privado.tiene_perfil(public.perfil_usuario[]) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Reglas de usuarios que no dependen de quién llama
-- -----------------------------------------------------------------------------
create function privado.validar_usuario() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.id <> old.id or new.usuario <> old.usuario or new.creado_en <> old.creado_en
       or new.creado_por is distinct from old.creado_por then
      raise exception 'El identificador, el usuario de acceso y los datos de creación no se modifican';
    end if;
    -- Nadie se convierte en propietario ni deja de serlo.
    if (old.perfil = 'propietario') <> (new.perfil = 'propietario') then
      raise exception 'El perfil de propietario no se asigna ni se quita';
    end if;
  end if;

  if new.perfil = 'propietario'
     and (tg_op = 'INSERT' or old.perfil <> 'propietario')
     and (select count(*) from public.usuarios u where u.perfil = 'propietario') >= 2 then
    raise exception 'Ya existen las dos cuentas de propietario';
  end if;
  return new;
end
$$;

create trigger usuarios_validar
before insert or update on public.usuarios
for each row execute function privado.validar_usuario();
