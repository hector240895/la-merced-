-- =============================================================================
-- ARRANQUE · Paso 2 de 2 · BORRAR LOS DATOS DE PRUEBA (una sola vez)
--
-- Deja el sistema en cero para empezar a trabajar de verdad: los folios vuelven
-- a empezar en 1 y los reportes, la caja, los gastos y el inventario quedan
-- vacíos. Se conservan los propietarios, el menú, las mesas, las categorías de
-- gasto, los datos del negocio y la configuración de las impresoras.
--
-- Después de hoy la regla sigue igual: nada se borra. Este archivo es solo para
-- el arranque.
--
-- Cómo usarlo:
--   1. Corre antes 1-revisar-datos-de-prueba.sql y revisa la lista.
--   2. Aquí abajo cambia  confirmar := 'NO'  por  confirmar := 'SI'.
--   3. Ajusta las otras dos opciones si hace falta.
--   4. Supabase → SQL Editor → pega todo → Run.
-- Si algo falla no se borra nada (todo o nada) y aparece el motivo.
-- =============================================================================
do $$
declare
  -- 1) Para confirmar, cambia 'NO' por 'SI'.
  confirmar constant text := 'NO';

  -- 2) true: también borra insumos, proveedores, empleados y gastos fijos
  --    (renta) de prueba, para que captures los reales.
  --    false: los conserva y solo pone las existencias de inventario en 0.
  borrar_catalogos_de_prueba constant boolean := true;

  -- 3) true: borra las cuentas de meseros y cajeros (por ejemplo, las de prueba)
  --    para poder volver a usar esos nombres de usuario. Los propietarios nunca
  --    se tocan. false: se quedan; puedes darlas de baja en la pestaña Usuarios.
  borrar_cuentas_meseros_cajeros constant boolean := false;

  operacion constant text[] := array['auditoria', 'avisos', 'autorizaciones', 'devoluciones', 'propinas', 'pagos',
    'cobros_extra', 'comanda_lineas', 'comandas', 'trabajos_impresion', 'lineas_cuenta', 'uniones_mesas', 'cuentas',
    'movimientos_efectivo', 'turnos_caja', 'gasto_productos', 'movimientos_inventario', 'gastos'];
  catalogos constant text[] := array['insumos', 'proveedores', 'empleados', 'gastos_fijos'];
  ajustar constant text[] := array['mesas', 'productos', 'insumos', 'usuarios'];
  borrar text[];
  t text;
  v_cuentas bigint := (select count(*) from public.cuentas);
  v_gastos bigint := (select count(*) from public.gastos);
  v_usuarios bigint := 0;
begin
  if confirmar is distinct from 'SI' then
    raise exception 'No se borró nada. Para confirmar, cambia confirmar := ''NO'' por confirmar := ''SI'' y vuelve a correrlo.';
  end if;

  borrar := operacion || case when borrar_catalogos_de_prueba then catalogos else '{}'::text[] end;

  -- Las reglas de "no borrar" se apagan solo durante esta limpieza.
  foreach t in array (borrar || ajustar) loop
    execute format('alter table public.%I disable trigger user', t);
  end loop;

  execute 'truncate table ' || (select string_agg(format('public.%I', x), ', ') from unnest(borrar) x) || ' restart identity';

  update public.mesas set estado = 'disponible', unida_a = null where estado <> 'disponible' or unida_a is not null;
  update public.productos set estado = 'activo' where estado = 'agotado';
  if not borrar_catalogos_de_prueba then
    update public.insumos set existencia = 0 where existencia <> 0;
  end if;

  if borrar_cuentas_meseros_cajeros then
    create temp table quitar_usuarios on commit drop as
      select id from public.usuarios where perfil <> 'propietario';
    v_usuarios := (select count(*) from quitar_usuarios);
    delete from public.usuarios where id in (select id from quitar_usuarios);
    delete from auth.users where id in (select id from quitar_usuarios);
  end if;

  foreach t in array (borrar || ajustar) loop
    execute format('alter table public.%I enable trigger user', t);
  end loop;

  perform privado.registrar_auditoria(
    'Limpieza de datos de prueba antes del arranque',
    null, null,
    format('Se borraron %s cuentas y %s gastos de prueba%s%s. Desde aquí empieza la operación real.',
           v_cuentas, v_gastos,
           case when borrar_catalogos_de_prueba then ', con insumos, proveedores, empleados y gastos fijos' else '' end,
           case when v_usuarios > 0 then format(', y %s cuentas de meseros/cajeros', v_usuarios) else '' end));

  raise notice 'Listo: datos de prueba borrados. Los folios empiezan otra vez en 1.';
end
$$;

-- Comprobación: todo debe salir en 0 (menos la fila de auditoría de la limpieza).
select (select count(*) from public.cuentas) as cuentas, (select count(*) from public.gastos) as gastos,
       (select count(*) from public.turnos_caja) as cortes, (select count(*) from public.movimientos_inventario) as inventario,
       (select count(*) from public.auditoria) as "auditoría (1 = la limpieza)";
