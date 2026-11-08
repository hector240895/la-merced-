-- =============================================================================
-- Sistema La Merced · Etapa 6 · Estado del servicio de impresión
-- El programa de la computadora de caja avisa cada pocos segundos que sigue
-- conectado y en qué estado ve las impresoras. La app lo muestra en la pestaña
-- Comandas y alerta si se desconecta.
-- =============================================================================
create table public.servicio_impresion (
  sucursal_id    uuid primary key references public.sucursales (id),
  ultimo_latido  timestamptz not null default now(),
  equipo         text,            -- nombre de la computadora
  version        text,
  impresoras     jsonb not null default '{}'::jsonb,   -- {"cocina": {"nombre": "...", "estado": "lista"}, "caja": {...}}
  pendientes     integer not null default 0
);

-- Estado operativo que se sobrescribe cada pocos segundos: no es historial,
-- así que no pasa por la auditoría. No se borra.
create trigger servicio_impresion_sin_borrado before delete on public.servicio_impresion
  for each row execute function privado.prohibir_borrado();

alter table public.servicio_impresion enable row level security;
alter table public.servicio_impresion force row level security;
revoke all on public.servicio_impresion from public, anon, authenticated;
grant select on public.servicio_impresion to authenticated;
create policy servicio_impresion_leer on public.servicio_impresion for select to authenticated
  using ((select privado.tiene_perfil('propietario', 'cajero', 'mesero')));

create function public.latido_impresion(p_equipo text, p_version text, p_impresoras jsonb, p_pendientes integer)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  perform privado.exigir_perfil('propietario', 'cajero');
  insert into public.servicio_impresion (sucursal_id, ultimo_latido, equipo, version, impresoras, pendientes)
  values (privado.sucursal_del_actor(), now(), left(p_equipo, 80), left(p_version, 20), coalesce(p_impresoras, '{}'), coalesce(p_pendientes, 0))
  on conflict (sucursal_id) do update
     set ultimo_latido = now(), equipo = excluded.equipo, version = excluded.version,
         impresoras = excluded.impresoras, pendientes = excluded.pendientes;
end
$$;
revoke execute on function public.latido_impresion(text, text, jsonb, integer) from public, anon;
grant execute on function public.latido_impresion(text, text, jsonb, integer) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'servicio_impresion') then
    alter publication supabase_realtime add table public.servicio_impresion;
  end if;
end
$$;
