-- =============================================================================
-- Sistema La Merced · Etapa 2 · 5/5
-- Permisos por perfil en la base de datos.
--
--   * anon (sin sesión): nada.
--   * authenticated: solo SELECT, filtrado por Row Level Security según el
--     perfil. Ninguna tabla admite INSERT/UPDATE/DELETE directo desde la app:
--     las escrituras pasan por funciones del servidor que validan el perfil.
--   * Un usuario dado de baja no ve nada aunque conserve su sesión.
-- =============================================================================

do $$
declare
  t text;
begin
  foreach t in array array[
    'sucursales', 'usuarios', 'auditoria', 'avisos', 'autorizaciones',
    'categorias', 'productos', 'historial_precios', 'mesas', 'uniones_mesas',
    'turnos_caja', 'movimientos_efectivo', 'cuentas', 'lineas_cuenta', 'cobros_extra',
    'comandas', 'comanda_lineas', 'pagos', 'propinas', 'trabajos_impresion',
    'gastos', 'gasto_productos'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('revoke delete, truncate on public.%I from service_role', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end
$$;

-- La auditoría solo admite agregar filas, también para la llave de servicio.
revoke update on public.auditoria from service_role;

revoke all on all sequences in schema public from anon, authenticated;

-- Abreviaturas usadas en las reglas (se evalúan una vez por consulta).
--   (select privado.es_propietario())
--   (select privado.tiene_perfil('cajero'))  etc.

-- ----------------------------------------------------------------- Usuarios
create policy sucursales_leer on public.sucursales for select to authenticated
  using ((select privado.perfil_actual()) is not null);

create policy usuarios_leer on public.usuarios for select to authenticated
  using ((select privado.es_propietario())
         or (id = (select auth.uid()) and (select privado.perfil_actual()) is not null));

create policy auditoria_leer on public.auditoria for select to authenticated
  using ((select privado.es_propietario()));

create policy avisos_leer on public.avisos for select to authenticated
  using ((select privado.es_propietario()) and para_usuario_id = (select auth.uid()));

create policy autorizaciones_leer on public.autorizaciones for select to authenticated
  using ((select privado.es_propietario()));

-- ----------------------------------------------------------------- Catálogo
-- Mesero y cajero ven productos activos o agotados; nunca inactivos ni eliminados.
create policy categorias_leer on public.categorias for select to authenticated
  using ((select privado.es_propietario())
         or ((select privado.tiene_perfil('cajero', 'mesero')) and activa and eliminada_en is null));

create policy productos_leer on public.productos for select to authenticated
  using ((select privado.es_propietario())
         or ((select privado.tiene_perfil('cajero', 'mesero')) and estado <> 'inactivo' and eliminado_en is null));

create policy historial_precios_leer on public.historial_precios for select to authenticated
  using ((select privado.es_propietario()));

-- ----------------------------------------------------------------- Salón
create policy mesas_leer on public.mesas for select to authenticated
  using ((select privado.es_propietario())
         or ((select privado.tiene_perfil('cajero', 'mesero')) and eliminada_en is null));

create policy uniones_mesas_leer on public.uniones_mesas for select to authenticated
  using ((select privado.tiene_perfil('propietario', 'mesero')));

-- ----------------------------------------------------------------- Caja
-- El cajero ve sus propios turnos; el propietario, todos.
create policy turnos_leer on public.turnos_caja for select to authenticated
  using ((select privado.es_propietario())
         or ((select privado.tiene_perfil('cajero')) and cajero_id = (select auth.uid())));

create policy movimientos_leer on public.movimientos_efectivo for select to authenticated
  using ((select privado.es_propietario())
         or ((select privado.tiene_perfil('cajero'))
             and exists (select 1 from public.turnos_caja t
                         where t.id = turno_id and t.cajero_id = (select auth.uid()))));

-- ----------------------------------------------------------------- Ventas
-- Mesero: cuentas de mesa abiertas o por cobrar (lo que necesita para servir).
-- Cajero: cuentas abiertas o por cobrar, y las que cobró en su turno abierto.
-- Propietario: todas.
create policy cuentas_leer on public.cuentas for select to authenticated
  using ((select privado.es_propietario())
         or ((select privado.tiene_perfil('mesero')) and tipo = 'mesa' and estado in ('abierta', 'por_cobrar'))
         or ((select privado.tiene_perfil('cajero'))
             and (estado in ('abierta', 'por_cobrar')
                  or exists (select 1 from public.turnos_caja t
                             where t.id = turno_id and t.cajero_id = (select auth.uid()) and t.estado = 'abierto'))));

-- El detalle se ve si se ve la cuenta (la regla de cuentas se aplica dentro).
create policy lineas_leer on public.lineas_cuenta for select to authenticated
  using (exists (select 1 from public.cuentas c where c.id = cuenta_id));

create policy cobros_extra_leer on public.cobros_extra for select to authenticated
  using (exists (select 1 from public.cuentas c where c.id = cuenta_id));

create policy comandas_leer on public.comandas for select to authenticated
  using (exists (select 1 from public.cuentas c where c.id = cuenta_id));

create policy comanda_lineas_leer on public.comanda_lineas for select to authenticated
  using (exists (select 1 from public.comandas c where c.id = comanda_id));

-- Pagos y propinas: propietario, o el cajero dentro de su turno abierto.
create policy pagos_leer on public.pagos for select to authenticated
  using ((select privado.es_propietario())
         or ((select privado.tiene_perfil('cajero'))
             and exists (select 1 from public.turnos_caja t
                         where t.id = turno_id and t.cajero_id = (select auth.uid()) and t.estado = 'abierto')));

create policy propinas_leer on public.propinas for select to authenticated
  using ((select privado.es_propietario())
         or ((select privado.tiene_perfil('cajero'))
             and exists (select 1 from public.turnos_caja t
                         where t.id = turno_id and t.cajero_id = (select auth.uid()) and t.estado = 'abierto')));

-- Impresión: el mesero ve el estado de las comandas de cuentas que puede ver
-- (las comandas no llevan precios); los tickets solo caja y propietario.
create policy trabajos_leer on public.trabajos_impresion for select to authenticated
  using ((select privado.tiene_perfil('propietario', 'cajero'))
         or ((select privado.tiene_perfil('mesero')) and documento = 'comanda'
             and exists (select 1 from public.cuentas c where c.id = cuenta_id)));

-- ----------------------------------------------------------------- Gastos
create policy gastos_leer on public.gastos for select to authenticated
  using ((select privado.es_propietario()));

create policy gasto_productos_leer on public.gasto_productos for select to authenticated
  using ((select privado.es_propietario()));

-- =============================================================================
-- Funciones: nadie las ejecuta salvo lo que se otorga aquí.
-- =============================================================================
revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema privado from public, anon, authenticated;

grant execute on function
  privado.actor(), privado.perfil_actual(), privado.es_propietario(),
  privado.tiene_perfil(public.perfil_usuario[])
to authenticated, service_role;

grant execute on function
  public.yo(),
  public.registrar_usuario(uuid, text, text, public.perfil_usuario),
  public.renombrar_usuario(uuid, text),
  public.cambiar_perfil_usuario(uuid, public.perfil_usuario),
  public.dar_de_baja_usuario(uuid, text),
  public.reactivar_usuario(uuid),
  public.registrar_cambio_contrasena(uuid),
  public.marcar_avisos_leidos(bigint[]),
  public.solicitar_autorizacion(public.tipo_autorizacion, uuid, text, uuid, uuid),
  public.resolver_autorizacion(uuid, boolean, text)
to authenticated;

-- Instalación de propietarios: solo la llave de servicio.
revoke execute on function public.instalar_propietario(uuid, text, text) from authenticated;
grant execute on function public.instalar_propietario(uuid, text, text) to service_role;
