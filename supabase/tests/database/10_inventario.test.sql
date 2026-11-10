-- Pruebas de la Etapa 8: inventario manual.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(29);

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
grant all on v to authenticated;

-- ---------------------------------------------------------------- Catálogos (propietarios)
select pg_temp.como('11111111-1111-1111-1111-111111111111');
insert into v select 'prov', (public.guardar_proveedor(null, ' Carnicería López ', '33 1234 5678', 'Entrega martes')).id;
select throws_ok($$ select public.guardar_proveedor(null, 'carnicería lópez') $$, 'Ya existe el proveedor carnicería lópez', 'No se repiten proveedores');
insert into v select 'carne', (public.guardar_insumo(null, 'Carne de res', ' KG ', 5, (select id from v where clave = 'prov'))).id;
insert into v select 'tortilla', (public.guardar_insumo(null, 'Tortilla', 'kg', 10, null, 8)).id;
select is((select unidad from insumos where id = (select id from v where clave = 'carne')), 'kg', 'La unidad se guarda limpia');
select is((select existencia from insumos where id = (select id from v where clave = 'tortilla')), 8.000::numeric, 'Se registra la existencia inicial');
select is((select tipo::text || ' ' || motivo from movimientos_inventario where insumo_id = (select id from v where clave = 'tortilla')),
  'ajuste Existencia inicial', 'La existencia inicial queda como movimiento');
select throws_ok($$ select public.guardar_insumo(null, 'Sal', '', 0) $$, 'Escribe la unidad (kg, pieza, litro…)', 'La unidad es obligatoria');
reset role;

select pg_temp.como('44444444-4444-4444-4444-444444444444');
select throws_ok($$ select public.guardar_insumo(null, 'Sal', 'kg', 0) $$, '42501', null, 'El cajero no da de alta insumos');
select throws_ok($$ select public.guardar_proveedor(null, 'Otro') $$, '42501', null, 'El cajero no da de alta proveedores');
select is((select count(*)::int from insumos), 2, 'El cajero ve los insumos');
reset role;

select pg_temp.como('33333333-3333-3333-3333-333333333333');
select is((select count(*)::int from insumos), 0, 'El mesero no ve el inventario');
select throws_ok($$ select public.registrar_entrada((select id from v where clave = 'carne'), 1, 'x') $$, '42501', null, 'El mesero no registra entradas');
reset role;

-- ---------------------------------------------------------------- Compra (cajero) = gasto automático
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select public.abrir_caja(3000);
insert into v select 'gasto', (public.registrar_compra((select id from v where clave = 'prov'),
  jsonb_build_array(jsonb_build_object('insumo_id', (select id from v where clave = 'carne'), 'cantidad', 10, 'costo', 1800),
                    jsonb_build_object('insumo_id', (select id from v where clave = 'tortilla'), 'cantidad', 5, 'costo', 125.5)),
  'Factura 77')).id;
select is((select count(*)::int from movimientos_inventario), 0, 'El cajero no consulta el historial con costos');
select is((select count(*)::int from gastos where creado_por <> '44444444-4444-4444-4444-444444444444'), 0, 'El cajero no consulta otros gastos');
select throws_ok($$ select public.registrar_compra(null, '[]') $$, 'Agrega al menos un insumo a la compra', 'Una compra necesita insumos');
select throws_ok($$ select public.registrar_compra(null, jsonb_build_array(jsonb_build_object('insumo_id', (select id from v where clave = 'carne'), 'cantidad', 2))) $$,
  'Cada insumo de la compra necesita cantidad y costo', 'Cada insumo necesita costo');
select throws_ok($$ select public.registrar_merma((select id from v where clave = 'carne'), 1, 'Se echó a perder') $$, '42501', null, 'El cajero no registra mermas');
select throws_ok($$ select public.ajustar_existencia((select id from v where clave = 'carne'), 3) $$, '42501', null, 'El cajero no ajusta existencias');
select lives_ok($$ select public.registrar_entrada((select id from v where clave = 'carne'), 0.5, 'Sobró de un evento') $$, 'El cajero registra una entrada');
select is((select count(*)::int from public.mis_movimientos_inventario()), 3, 'El cajero ve lo que él registró');
reset role;

select is((select categoria::text || ' ' || monto || ' ' || concepto from gastos where id = (select id from v where clave = 'gasto')),
  'compras_mercancia 1925.50 Compra a Carnicería López', 'La compra queda como gasto de Compras y mercancía');
select is((select count(*)::int from gasto_productos where gasto_id = (select id from v where clave = 'gasto')), 2, 'El gasto lleva el detalle de la compra');
select is((select existencia from insumos where id = (select id from v where clave = 'carne')), 10.500::numeric, 'La compra y la entrada suman a la existencia');
select is((select count(*)::int from avisos a join auditoria x on x.id = a.auditoria_id
           where x.accion like 'Registró una compra de $1925.50%' and x.tabla = 'gastos'), 2, 'Ambos propietarios reciben aviso de la compra del cajero');

-- ---------------------------------------------------------------- Merma y ajuste (propietarios)
select pg_temp.como('22222222-2222-2222-2222-222222222222');
select throws_ok($$ select public.registrar_merma((select id from v where clave = 'carne'), 1, ' ') $$, 'Escribe el motivo de la merma', 'La merma necesita motivo');
select throws_ok($$ select public.registrar_merma((select id from v where clave = 'carne'), 20, 'Se cayó') $$, 'Solo hay 10.500 kg de Carne de res', 'No se saca más de lo que hay');
select lives_ok($$ select public.registrar_merma((select id from v where clave = 'carne'), 1.5, 'Se echó a perder') $$, 'Se registra una merma');
select is((public.ajustar_existencia((select id from v where clave = 'carne'), 7.25)).cantidad, -1.750::numeric, 'El ajuste registra la diferencia con el conteo');
select throws_ok($$ select public.ajustar_existencia((select id from v where clave = 'carne'), 7.25) $$,
  'El conteo coincide con lo anotado: no hay nada que ajustar', 'Un conteo igual no genera movimiento');
reset role;

-- ---------------------------------------------------------------- Inmutables
select throws_ok($$ update movimientos_inventario set cantidad = 100 $$, null, null, 'Los movimientos no se editan');
select throws_ok($$ delete from insumos $$, null, null, 'Los insumos no se borran');

select * from finish();
rollback;
