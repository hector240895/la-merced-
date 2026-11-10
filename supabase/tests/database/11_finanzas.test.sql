-- Pruebas de la Etapa 9: gastos, gastos fijos, sueldos y reporte de utilidad.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(36);

create function pg_temp.como(p_id uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_id, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
grant execute on all functions in schema pg_temp to authenticated;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'hector@lamerced.local'),
  ('22222222-2222-2222-2222-222222222222', 'wendy@lamerced.local'),
  ('33333333-3333-3333-3333-333333333333', 'carlos@lamerced.local'),
  ('44444444-4444-4444-4444-444444444444', 'laura@lamerced.local');
select public.instalar_propietario('11111111-1111-1111-1111-111111111111', 'hector', 'Hector Navarro');
select public.instalar_propietario('22222222-2222-2222-2222-222222222222', 'wendy', 'Wendy Rivas');
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select public.registrar_usuario('33333333-3333-3333-3333-333333333333', 'carlos', 'Carlos Pérez', 'mesero');
select public.registrar_usuario('44444444-4444-4444-4444-444444444444', 'laura', 'Laura', 'cajero');
reset role;
create temp table v (clave text primary key, id uuid);
insert into v values ('gas', (select id from categorias_gasto where clave = 'gas')),
  ('renta', (select id from categorias_gasto where clave = 'renta')),
  ('nomina', (select id from categorias_gasto where clave = 'nomina')),
  ('cafe', (select id from productos where nombre = 'Café de olla'));
create temp table f as select privado.hoy() hoy, date_trunc('month', privado.hoy())::date mes;
grant all on v, f to authenticated;

-- ---------------------------------------------------------------- Una venta de $60
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select public.abrir_caja(1000);
select pg_temp.como('33333333-3333-3333-3333-333333333333');
insert into v select 'cuenta', (public.enviar_pedido_llevar(null,
  jsonb_build_array(jsonb_build_object('producto_id', (select id from v where clave = 'cafe'), 'cantidad', 2)), gen_random_uuid()) ->> 'cuenta_id')::uuid;
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select public.cobrar_cuenta((select id from v where clave = 'cuenta'), '[{"metodo": "efectivo", "importe": 60, "recibido": 100}]', gen_random_uuid());

-- ---------------------------------------------------------------- Categorías
select pg_temp.como('11111111-1111-1111-1111-111111111111');
insert into v select 'garrafones', (public.guardar_categoria_gasto(null, ' Garrafones ')).id;
select throws_ok($$ select public.guardar_categoria_gasto(null, 'garrafones') $$, 'Ya existe la categoría garrafones', 'No se repiten categorías');
select throws_ok($$ select public.eliminar_categoria_gasto((select id from v where clave = 'nomina')) $$,
  'La categoría Sueldos la usa el sistema y no se puede quitar', 'Sueldos no se puede quitar');
reset role;
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select throws_ok($$ select public.guardar_categoria_gasto(null, 'Otra') $$, '42501', null, 'Caja no agrega categorías');
select is((select count(*)::int from categorias_gasto), 15, 'Caja ve las categorías para registrar gastos');

-- ---------------------------------------------------------------- Gasto con el efectivo de la caja
select throws_ok($$ select public.registrar_gasto((select id from v where clave = 'gas'), 'Gas', 50, 'efectivo') $$,
  'Desde caja solo se registran gastos pagados con el efectivo de la caja', 'Caja solo paga con la caja');
select throws_ok($$ select public.registrar_gasto((select id from v where clave = 'renta'), 'Renta', 50, 'caja') $$,
  'La renta y los sueldos los registran los propietarios', 'Caja no registra renta');
select throws_ok($$ select public.registrar_gasto((select id from v where clave = 'gas'), 'Gas', 5000, 'caja') $$,
  'En la caja solo debe haber $1060.00', 'No sale más efectivo del que hay en la caja');
insert into v select 'g_gas', (public.registrar_gasto((select id from v where clave = 'gas'), 'Tanque de gas', 350, 'caja')).id;
select is((public.resumen_caja() ->> 'efectivo_esperado')::numeric, 710.00, 'El gasto baja el efectivo esperado: 1000 + 60 − 350');
select is((select count(*)::int from gastos), 1, 'Caja ve el gasto que registró hoy');
select is((select motivo from movimientos_efectivo where tipo = 'retiro'), 'Gasto: Tanque de gas', 'El gasto aparece como retiro de la caja');
reset role;
select is((select count(*)::int from avisos a join auditoria x on x.id = a.auditoria_id
           where x.accion = 'Registró un gasto de $350.00 pagado con la caja: Tanque de gas'), 2, 'Los dos propietarios reciben aviso');

-- ---------------------------------------------------------------- Propietarios
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select lives_ok($$ select public.registrar_gasto((select id from v where clave = 'garrafones'), 'Garrafones', 120, 'transferencia') $$,
  'El propietario registra un gasto en una categoría nueva');
select throws_ok($$ select public.registrar_gasto((select id from v where clave = 'gas'), 'Gas', 10, 'efectivo', (select hoy + 1 from f)) $$,
  'La fecha del gasto no puede ser futura', 'No hay gastos con fecha futura');
select throws_ok($$ select public.anular_gasto((select id from v where clave = 'g_gas'), ' ') $$, 'Escribe por qué se anula el gasto', 'Anular pide motivo');
select lives_ok($$ select public.anular_gasto((select id from v where clave = 'g_gas'), 'Se capturó dos veces') $$, 'Se anula un gasto');
select is((public.resumen_caja() ->> 'efectivo_esperado')::numeric, 1060.00, 'Al anularlo, el efectivo regresa a la caja');
select throws_ok($$ select public.anular_gasto((select id from v where clave = 'g_gas'), 'Otra vez') $$, 'El gasto ya estaba anulado', 'No se anula dos veces');

-- ---------------------------------------------------------------- Renta automática
insert into v select 'fijo', (public.guardar_gasto_fijo(null, (select id from v where clave = 'renta'), 'Renta del local', 8000, 1,
  'transferencia', (select (mes - interval '2 months')::date from f))).id;
select is((select count(*)::int from gastos where gasto_fijo_id = (select id from v where clave = 'fijo')), 3,
  'La renta se registra sola: dos meses atrás y este mes');
select is(public.generar_gastos_fijos(), 0, 'Nunca se repite un mes');
select public.guardar_gasto_fijo((select id from v where clave = 'fijo'), (select id from v where clave = 'renta'), 'Renta del local', 9000, 1, 'transferencia');
select is((select sum(monto) from gastos where gasto_fijo_id = (select id from v where clave = 'fijo')), 24000.00, 'Cambiar el monto no altera los meses ya registrados');
select throws_ok($$ select public.eliminar_categoria_gasto((select id from v where clave = 'renta')) $$,
  'Un gasto fijo usa la categoría Renta: cámbialo primero', 'No se quita una categoría que usa un gasto fijo');

-- ---------------------------------------------------------------- Sueldos
insert into v select 'rosa', (public.guardar_empleado(null, 'Rosa', 'Cocinera', 2000, 'semanal')).id;
insert into v select 'pedro', (public.guardar_empleado(null, 'Pedro', 'Lavaloza', 1500, 'semanal')).id;
select throws_ok($$ select public.guardar_empleado(null, 'rosa', 'Cocinera', 1, 'semanal') $$, 'Ya existe el empleado rosa', 'No se repiten empleados');
select is(public.pagar_sueldos(jsonb_build_array(jsonb_build_object('empleado_id', (select id from v where clave = 'rosa'), 'monto', 2000),
                                                 jsonb_build_object('empleado_id', (select id from v where clave = 'pedro'), 'monto', 0)),
                               'Semana 1', 'efectivo'), 1, 'Solo se registra a quien se le pagó');
select is((select concepto || ' ' || monto from gastos where empleado_id = (select id from v where clave = 'rosa')),
  'Sueldo de Rosa · Semana 1 2000.00', 'El sueldo queda como gasto de Sueldos');
reset role;

-- ---------------------------------------------------------------- Reporte
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select throws_ok($$ select public.reporte_finanzas((select mes from f), (select hoy from f)) $$, '42501', null, 'Caja no ve el reporte de utilidad');
select pg_temp.como('22222222-2222-2222-2222-222222222222');
create temp table r as select public.reporte_finanzas((select mes from f), (select (mes + interval '1 month' - interval '1 day')::date from f)) j;
select is((select (j -> 'ventas' ->> 'netas')::numeric from r), 60.00, 'Ventas del mes');
select is((select (j -> 'gastos' ->> 'total')::numeric from r), 10120.00, 'Gastos del mes: renta + garrafones + sueldo (sin el anulado)');
select is((select (j ->> 'utilidad')::numeric from r), -10060.00, 'Utilidad real = ventas − gastos');
select is((select j -> 'productos' -> 0 ->> 'producto' || ' ' || (j -> 'productos' -> 0 ->> 'cantidad') from r), 'Café de olla 2', 'Productos vendidos');
select is((select (j -> 'anterior' ->> 'gastos')::numeric from r), 8000.00, 'Compara con el mes anterior');
reset role;

-- ---------------------------------------------------------------- Quién pagó
select pg_temp.como('11111111-1111-1111-1111-111111111111');
insert into v select 'g_wendy', (public.registrar_gasto((select id from v where clave = 'gas'), 'Gas que pagó Wendy', 500, 'efectivo',
  null, null, '22222222-2222-2222-2222-222222222222')).id;
reset role;
select is((select pagado_por from gastos where id = (select id from v where clave = 'g_wendy')),
  '22222222-2222-2222-2222-222222222222'::uuid, 'Se puede anotar que lo pagó el otro dueño');
select is((select pagado_por from gastos where concepto = 'Garrafones'), '11111111-1111-1111-1111-111111111111'::uuid,
  'Si no se elige, lo pagó quien lo registra');
select is((select count(*)::int from gastos where forma_pago = 'caja' and pagado_por is not null), 0, 'Lo pagado con la caja no es de ningún dueño');
select is((select count(*)::int from gastos where gasto_fijo_id is not null and pagado_por = '11111111-1111-1111-1111-111111111111'), 3,
  'La renta automática la paga el dueño del gasto fijo');
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select throws_ok($$ select public.registrar_gasto((select id from v where clave = 'gas'), 'Gas', 10, 'caja', null, null,
  '11111111-1111-1111-1111-111111111111') $$, 'Desde caja los gastos se pagan con el efectivo de la caja', 'Caja no asigna gastos a un dueño');
select pg_temp.como('22222222-2222-2222-2222-222222222222');
select is((select jsonb_object_agg(x ->> 'quien', (x ->> 'total')::numeric) from jsonb_array_elements(
  public.gastos_por_dueno((select mes from f), (select hoy from f))) x),
  '{"Hector Navarro": 10120, "Wendy Rivas": 500}'::jsonb, 'Gastos por dueño en el mes');
reset role;

select * from finish();
rollback;
