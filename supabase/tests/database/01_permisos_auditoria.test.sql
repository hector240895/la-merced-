-- Pruebas de la Etapa 2: permisos por perfil, nada se borra, auditoría que
-- solo agrega filas y autorización cruzada entre propietarios.
-- Se ejecutan con:  npx supabase test db
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(49);

-- ---------------------------------------------------------------- Ayudantes
-- Entra "como" un usuario: rol authenticated con su token simulado.
create function pg_temp.como(p_id uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_id, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.sin_sesion() returns void language sql as $$
  select set_config('request.jwt.claims', '{"role":"anon"}', true),
         set_config('role', 'anon', true);
$$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- ---------------------------------------------------------------- Datos
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'hector@lamerced.local'),
  ('22222222-2222-2222-2222-222222222222', 'wendy@lamerced.local'),
  ('33333333-3333-3333-3333-333333333333', 'carlos@lamerced.local'),
  ('44444444-4444-4444-4444-444444444444', 'laura@lamerced.local'),
  ('55555555-5555-5555-5555-555555555555', 'intruso@lamerced.local');

select public.instalar_propietario('11111111-1111-1111-1111-111111111111', 'hector', 'Hector Navarro');
select public.instalar_propietario('22222222-2222-2222-2222-222222222222', 'wendy', 'Wendy Rivas');

select throws_ok(
  $$ select public.instalar_propietario('55555555-5555-5555-5555-555555555555', 'intruso', 'Tercero') $$,
  'Ya existen las dos cuentas de propietario',
  'No se puede crear un tercer propietario');

-- Hector crea al mesero y al cajero.
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select public.registrar_usuario('33333333-3333-3333-3333-333333333333', 'carlos', 'Carlos', 'mesero');
select public.registrar_usuario('44444444-4444-4444-4444-444444444444', 'laura', 'Laura', 'cajero');
reset role;

-- Datos de operación (como administrador de la base, solo para la prueba).
insert into public.categorias (id, nombre) values ('c0000000-0000-0000-0000-000000000001', 'Cenas');
insert into public.productos (id, categoria_id, nombre, precio, estado) values
  ('d0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'Pozole rojo', 95, 'activo'),
  ('d0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', 'Buñuelos', 45, 'inactivo');
insert into public.gastos (categoria, concepto, monto) values ('gas', 'Tanque de gas', 350);
insert into public.turnos_caja (id, cajero_id, fondo_inicial) values
  ('e0000000-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444', 500);

-- Cuenta A: Mesa 1 abierta (para cancelar).
insert into public.cuentas (id, tipo, mesa_id, mesero_id)
select 'a0000000-0000-0000-0000-000000000001', 'mesa', id, '33333333-3333-3333-3333-333333333333'
from public.mesas where nombre = 'Mesa 1';
update public.mesas set estado = 'pedido_enviado' where nombre = 'Mesa 1';
insert into public.lineas_cuenta (id, cuenta_id, producto_id, nombre_producto, precio_unitario, tasa_iva, cantidad, creado_por)
values ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001',
        'd0000000-0000-0000-0000-000000000001', 'Pozole rojo', 95, 0.16, 2, '33333333-3333-3333-3333-333333333333');

-- Cuenta B: Mesa 2 ya cobrada (para anular cobro y quitar producto).
insert into public.cuentas (id, tipo, mesa_id, mesero_id)
select 'a0000000-0000-0000-0000-000000000002', 'mesa', id, '33333333-3333-3333-3333-333333333333'
from public.mesas where nombre = 'Mesa 2';
insert into public.lineas_cuenta (id, cuenta_id, producto_id, nombre_producto, precio_unitario, tasa_iva, cantidad)
values ('b0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002',
        'd0000000-0000-0000-0000-000000000001', 'Pozole rojo', 95, 0.16, 1),
       ('b0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002',
        'd0000000-0000-0000-0000-000000000001', 'Pozole rojo', 95, 0.16, 1);
insert into public.pagos (cuenta_id, turno_id, metodo, importe) values
  ('a0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 'efectivo', 100),
  ('a0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 'tarjeta', 90);
update public.cuentas set estado = 'cobrada', cobrada_en = now(), total = 190,
       cajero_id = '44444444-4444-4444-4444-444444444444', turno_id = 'e0000000-0000-0000-0000-000000000001'
 where id = 'a0000000-0000-0000-0000-000000000002';

-- ---------------------------------------------------------------- Sin sesión
select pg_temp.sin_sesion();
select throws_ok($$ select * from public.usuarios $$, '42501', null, 'Sin sesión no se lee nada');
select throws_ok($$ select public.yo() $$, '42501', null, 'Sin sesión no se llama ninguna función');
reset role;

-- ---------------------------------------------------------------- Mesero
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select is((select perfil::text from public.yo()), 'mesero', 'El mesero ve su propio perfil');
select is((select count(*)::int from public.usuarios), 1, 'El mesero solo ve su propia cuenta de usuario');
select is((select count(*)::int from public.gastos), 0, 'El mesero no ve gastos');
select is((select count(*)::int from public.pagos), 0, 'El mesero no ve pagos');
select is((select count(*)::int from public.auditoria), 0, 'El mesero no ve la auditoría');
select is((select count(*)::int from public.autorizaciones), 0, 'El mesero no ve autorizaciones');
select is((select count(*)::int from public.productos), 1, 'El mesero solo ve productos activos (no inactivos)');
select is((select count(*)::int from public.cuentas), 1, 'El mesero ve la cuenta abierta, no la cobrada');
select throws_ok($$ insert into public.productos (categoria_id, nombre, precio)
                   values ('c0000000-0000-0000-0000-000000000001', 'Pirata', 1) $$,
  '42501', null, 'El mesero no puede escribir directo en las tablas');
select throws_ok($$ update public.lineas_cuenta set cantidad = 1 $$,
  '42501', null, 'El mesero no puede modificar líneas directo');
select throws_ok($$ select public.registrar_usuario('55555555-5555-5555-5555-555555555555', 'intruso', 'X', 'mesero') $$,
  '42501', null, 'El mesero no puede crear usuarios');
reset role;

-- ---------------------------------------------------------------- Cajero
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select is((select count(*)::int from public.gastos), 0, 'El cajero no ve gastos');
select is((select count(*)::int from public.auditoria), 0, 'El cajero no ve la auditoría');
select is((select count(*)::int from public.pagos), 2, 'El cajero ve los pagos de su turno abierto');
select throws_ok($$ select public.dar_de_baja_usuario('33333333-3333-3333-3333-333333333333', 'x') $$,
  '42501', null, 'El cajero no puede dar de baja usuarios');
select throws_ok($$ select public.solicitar_autorizacion('cancelar_cuenta', 'a0000000-0000-0000-0000-000000000001', 'x') $$,
  '42501', null, 'El cajero no puede pedir cancelar cuentas');
reset role;

-- ---------------------------------------------------------------- Nada se borra
select throws_ok($$ delete from public.cuentas $$, '42501', null, 'Ni el administrador de la base borra cuentas');
select throws_ok($$ delete from public.usuarios where usuario = 'carlos' $$, '42501', null, 'Los usuarios no se borran');
select throws_ok($$ update public.auditoria set accion = 'x' $$, '42501', null, 'La auditoría no se edita');
select throws_ok($$ delete from public.auditoria $$, '42501', null, 'La auditoría no se borra');
select throws_ok($$ truncate public.auditoria cascade $$, '42501', null, 'La auditoría no se vacía');
select throws_ok($$ update public.lineas_cuenta set precio_unitario = 1 where id = 'b0000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'El precio guardado en una venta no cambia');
select throws_ok($$ update public.lineas_cuenta set estado = 'cancelada', cancelada_en = now(),
                      cancelada_por = '11111111-1111-1111-1111-111111111111', cancelacion_motivo = 'x'
                   where id = 'b0000000-0000-0000-0000-000000000002' $$,
  '42501', null, 'Quitar un producto de una cuenta cobrada exige autorización');
select throws_ok($$ update public.pagos set estado = 'anulado', anulado_en = now(),
                      anulado_por = '11111111-1111-1111-1111-111111111111', anulacion_motivo = 'x'
                   where cuenta_id = 'a0000000-0000-0000-0000-000000000002' $$,
  '23514', null, 'Anular un pago exige autorización');
select throws_ok($$ update public.mesas set activa = false where nombre = 'Mesa 1' $$,
  null, 'No se desactiva una mesa con cuenta abierta');

update public.productos set precio = 98 where id = 'd0000000-0000-0000-0000-000000000001';
select is((select precio_nuevo from public.historial_precios where producto_id = 'd0000000-0000-0000-0000-000000000001'),
  98.00, 'El cambio de precio queda en el historial');
select is((select precio_unitario from public.lineas_cuenta where id = 'b0000000-0000-0000-0000-000000000001'),
  95.00, 'Cambiar el precio no altera las ventas ya registradas');

-- ---------------------------------------------------------------- Autorización cruzada
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select public.solicitar_autorizacion('cancelar_cuenta', 'a0000000-0000-0000-0000-000000000001', 'El cliente se fue sin consumir');
select is((select estado::text from public.cuentas where id = 'a0000000-0000-0000-0000-000000000001'),
  'abierta', 'Solicitar no cambia la cuenta todavía');
select throws_ok($$ select public.resolver_autorizacion(
                      (select id from public.autorizaciones where cuenta_id = 'a0000000-0000-0000-0000-000000000001'), true) $$,
  '42501', null, 'Nadie aprueba su propia solicitud');
select throws_ok($$ select public.dar_de_baja_usuario('22222222-2222-2222-2222-222222222222', 'x') $$,
  '42501', null, 'Un propietario no da de baja al otro');
select throws_ok($$ select public.registrar_cambio_contrasena('22222222-2222-2222-2222-222222222222') $$,
  '42501', null, 'Un propietario no cambia la contraseña del otro');
reset role;

select pg_temp.como('22222222-2222-2222-2222-222222222222');
select ok((select count(*) from public.avisos) > 0, 'Wendy recibe aviso de lo que hizo Hector');
select public.resolver_autorizacion(
  (select id from public.autorizaciones where cuenta_id = 'a0000000-0000-0000-0000-000000000001'), true, 'De acuerdo');
reset role;

select is((select estado::text from public.cuentas where id = 'a0000000-0000-0000-0000-000000000001'),
  'cancelada', 'Aprobada: la cuenta queda cancelada');
select is((select count(*)::int from public.lineas_cuenta where cuenta_id = 'a0000000-0000-0000-0000-000000000001'),
  1, 'La cuenta cancelada conserva sus productos');
select is((select estado::text from public.mesas where nombre = 'Mesa 1'), 'disponible', 'La mesa queda libre');
select throws_ok($$ update public.cuentas set estado = 'abierta', cancelada_en = null
                   where id = 'a0000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'Una cuenta cancelada no se des-cancela');

-- Quitar un producto de la cuenta cobrada con autorización.
select pg_temp.como('22222222-2222-2222-2222-222222222222');
select public.solicitar_autorizacion('cancelar_linea_cobrada', 'a0000000-0000-0000-0000-000000000002',
  'Se cobró un pozole que no se sirvió', 'b0000000-0000-0000-0000-000000000003');
reset role;
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select ok((select count(*) from public.avisos) > 0, 'Hector recibe aviso de lo que hizo Wendy');
select public.resolver_autorizacion(
  (select id from public.autorizaciones where linea_id = 'b0000000-0000-0000-0000-000000000003'), true);
reset role;
select is((select estado::text from public.lineas_cuenta where id = 'b0000000-0000-0000-0000-000000000003'),
  'cancelada', 'El producto queda cancelado con autorización, sin borrarse');

-- Anular el cobro, rechazado primero y aprobado después.
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select public.solicitar_autorizacion('anular_cobro', 'a0000000-0000-0000-0000-000000000002', 'Cobro duplicado');
reset role;
select pg_temp.como('22222222-2222-2222-2222-222222222222');
select public.resolver_autorizacion(
  (select id from public.autorizaciones where tipo = 'anular_cobro' and estado = 'pendiente'), false, 'No es duplicado');
reset role;
select is((select count(*)::int from public.pagos where estado = 'vigente'), 2, 'Rechazada: los pagos no cambian');

select pg_temp.como('11111111-1111-1111-1111-111111111111');
select public.solicitar_autorizacion('anular_cobro', 'a0000000-0000-0000-0000-000000000002', 'Ahora sí, cobro duplicado');
reset role;
select pg_temp.como('22222222-2222-2222-2222-222222222222');
select public.resolver_autorizacion(
  (select id from public.autorizaciones where tipo = 'anular_cobro' and estado = 'pendiente'), true);
reset role;
select is((select count(*)::int from public.pagos where estado = 'anulado' and autorizacion_id is not null), 2,
  'Aprobada: los pagos quedan anulados con su autorización');
select is((select estado::text from public.cuentas where id = 'a0000000-0000-0000-0000-000000000002'),
  'por_cobrar', 'La cuenta vuelve a por cobrar');

-- ---------------------------------------------------------------- Baja de usuario
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select public.dar_de_baja_usuario('33333333-3333-3333-3333-333333333333', 'Dejó el trabajo');
reset role;
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select is((select count(*)::int from public.yo()), 0, 'Dado de baja: ya no tiene perfil aunque conserve la sesión');
select is((select count(*)::int from public.productos), 0, 'Dado de baja: ya no ve datos');
reset role;
select is((select count(*)::int from public.usuarios where usuario = 'carlos'), 1, 'La cuenta dada de baja no se borra');

-- ---------------------------------------------------------------- Auditoría
select ok((select count(*) from public.auditoria
           where usuario_id = '11111111-1111-1111-1111-111111111111' and accion like 'Dio de baja%'
             and motivo = 'Dejó el trabajo') = 1, 'La baja queda en la auditoría con usuario y motivo');
select ok((select count(*) from public.auditoria
           where usuario_id = '22222222-2222-2222-2222-222222222222' and accion like 'Aprobó%') > 0,
          'La aprobación queda en la auditoría con quién aprobó');

select * from finish();
rollback;
