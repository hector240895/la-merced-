-- Pruebas de la Etapa 5: pedidos para llevar, cobro, caja, devoluciones y corte.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(49);

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

create temp table t as
select (select id from mesas where nombre = 'Mesa 1') m1, (select id from mesas where nombre = 'Mesa 2') m2,
       (select id from productos where nombre = 'Café de olla') cafe,
       (select id from productos where nombre = 'Pozole rojo chico') pozole,
       (select id from productos where nombre = 'Refresco de vidrio (355 ml)') refresco,
       gen_random_uuid() s_llevar, gen_random_uuid() s_cobro;
grant select on t to authenticated;
create temp table v (clave text primary key, valor text);
grant all on v to authenticated;

-- ---------------------------------------------------------------- Caja
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select throws_ok($$ select public.abrir_caja(500) $$, '42501', null, 'El mesero no abre caja');
reset role;

select pg_temp.como('44444444-4444-4444-4444-444444444444');
select throws_ok($$ select public.registrar_movimiento('entrada', 50, 'Cambio') $$, 'Abre la caja primero',
  'Sin caja abierta no hay movimientos');
select lives_ok($$ select public.abrir_caja(500) $$, 'La cajera abre caja con $500 de fondo');
select throws_ok($$ select public.abrir_caja(100) $$, 'La caja ya está abierta', 'Solo una caja abierta a la vez');
select throws_ok($$ select public.registrar_movimiento('retiro', 30, '') $$, 'Escribe el motivo del movimiento',
  'Los movimientos exigen motivo');
select public.registrar_movimiento('entrada', 50, 'Cambio en monedas');
select public.registrar_movimiento('retiro', 30, 'Compra de hielo');
reset role;

-- ---------------------------------------------------------------- Para llevar (lo captura el mesero)
select pg_temp.como('33333333-3333-3333-3333-333333333333');
insert into v select 'llevar', public.enviar_pedido_llevar(null,
  jsonb_build_array(jsonb_build_object('producto_id', (select cafe from t), 'cantidad', 2)), (select s_llevar from t)) ->> 'cuenta_id';
select is((select tipo::text || '/' || estado from cuentas where id = (select valor::uuid from v where clave = 'llevar')),
  'llevar/abierta', 'El mesero crea un pedido para llevar');
select is((public.enviar_pedido_llevar(null,
  jsonb_build_array(jsonb_build_object('producto_id', (select cafe from t), 'cantidad', 2)), (select s_llevar from t)) ->> 'repetido'),
  'true', 'Reintentar el mismo envío no crea otro pedido');
select is((select count(*)::int from cuentas where tipo = 'llevar'), 1, 'Sigue siendo un solo pedido para llevar');
select is((select count(*)::int from cuentas where tipo = 'llevar'), 1, 'El mesero ve el pedido para llevar abierto');
reset role;
set constraints comandas_imprimir immediate;
set constraints comandas_imprimir deferred;
select ok((select (contenido ->> 'para_llevar')::boolean and contenido ->> 'destino' = 'PARA LLEVAR'
           from trabajos_impresion where cuenta_id = (select valor::uuid from v where clave = 'llevar')),
  'La comanda dice PARA LLEVAR');

-- Mesa 1: pozole y refresco.
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select public.enviar_pedido((select m1 from t), jsonb_build_array(
  jsonb_build_object('producto_id', (select pozole from t), 'cantidad', 1),
  jsonb_build_object('producto_id', (select refresco from t), 'cantidad', 1, 'opcion', 'Pepsi')), gen_random_uuid());
select throws_ok($$ select public.cobrar_cuenta((select id from cuentas where mesa_id = (select m1 from t)),
  '[{"metodo": "efectivo", "importe": 100}]', gen_random_uuid()) $$, '42501', null, 'El mesero no cobra');
reset role;

-- ---------------------------------------------------------------- Cobro extra
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select throws_ok($$ select public.agregar_cobro_extra((select valor::uuid from v where clave = 'llevar'), ' ', 40) $$,
  'Escribe qué se cobra', 'El cobro extra exige comentario');
select public.agregar_cobro_extra((select valor::uuid from v where clave = 'llevar'), 'Salsa extra para llevar', 40);
reset role;
select is(privado.total_cuenta((select valor::uuid from v where clave = 'llevar')), 100.00,
  'El cobro extra se suma al total (2 cafés $60 + $40)');
select pg_temp.como('44444444-4444-4444-4444-444444444444');

-- ---------------------------------------------------------------- Cobrar el pedido para llevar
select throws_ok($$ select public.cobrar_cuenta((select valor::uuid from v where clave = 'llevar'),
  '[{"metodo": "efectivo", "importe": 60}]', gen_random_uuid()) $$,
  'Los pagos suman $60.00 y la cuenta es de $100.00', 'Los pagos deben igualar el total');
select throws_ok($$ select public.cobrar_cuenta((select valor::uuid from v where clave = 'llevar'),
  '[{"metodo": "efectivo", "importe": 60, "recibido": 50}, {"metodo": "tarjeta", "importe": 40}]', gen_random_uuid()) $$,
  null, 'El efectivo recibido debe alcanzar');
select throws_ok($$ select public.cobrar_cuenta((select valor::uuid from v where clave = 'llevar'),
  '[{"metodo": "efectivo", "importe": 60}, {"metodo": "efectivo", "importe": 40}]', gen_random_uuid()) $$,
  'Junta en una sola línea los pagos del mismo método', 'Un método por línea');

-- Pago combinado: $60 en efectivo (paga con $100 e incluye $10 de propina) y $40 con tarjeta.
insert into v select 'cobro', public.cobrar_cuenta((select valor::uuid from v where clave = 'llevar'),
  '[{"metodo": "efectivo", "importe": 60, "recibido": 100}, {"metodo": "tarjeta", "importe": 40}]',
  (select s_cobro from t), 10, 'efectivo')::text;
select is((select (valor::jsonb ->> 'cambio')::numeric from v where clave = 'cobro'), 30.00,
  'Cambio: $100 recibidos − $60 de la cuenta − $10 de propina = $30');
select is((select estado::text || ' ' || total from cuentas where id = (select valor::uuid from v where clave = 'llevar')),
  'cobrada 100.00', 'El pedido para llevar queda cobrado por $100');
select is((select subtotal + impuestos from cuentas where id = (select valor::uuid from v where clave = 'llevar')), 100.00,
  'Subtotal más IVA dan el total');
select is((select count(*)::int from pagos where cuenta_id = (select valor::uuid from v where clave = 'llevar')), 2,
  'Quedan dos líneas de pago (pago combinado)');
select is((select importe from propinas where cuenta_id = (select valor::uuid from v where clave = 'llevar')), 10.00,
  'La propina queda aparte');
select is((public.cobrar_cuenta((select valor::uuid from v where clave = 'llevar'),
  '[{"metodo": "efectivo", "importe": 100}]', (select s_cobro from t)) ->> 'repetido'), 'true',
  'Tocar Cobrar dos veces no cobra dos veces');
select throws_ok($$ select public.cobrar_cuenta((select valor::uuid from v where clave = 'llevar'),
  '[{"metodo": "efectivo", "importe": 100}]', gen_random_uuid()) $$, 'La cuenta ya está cobrada',
  'Una cuenta cobrada no se vuelve a cobrar');
select is((select count(*)::int from pagos where cuenta_id = (select valor::uuid from v where clave = 'llevar')), 2,
  'Siguen siendo dos pagos');

-- Ticket
select is((select documento || '/' || impresora from trabajos_impresion
           where cuenta_id = (select valor::uuid from v where clave = 'llevar') and documento = 'ticket'), 'ticket/caja',
  'El cobro manda el ticket a la impresora de caja');
select ok((select contenido ->> 'negocio' = 'Cenaduría La Merced'
              and contenido ->> 'direccion' = 'Av. Fundición 2103, San Cayetano, 20010 Aguascalientes, Ags.'
              and contenido ->> 'telefonos' = '449 940 44 90 / 449 181 31 21'
              and contenido ->> 'fecha' ~ '^\d\d/\d\d/\d{4}$' and contenido ->> 'hora' ~ '^\d\d:\d\d$'
           from trabajos_impresion where documento = 'ticket'), 'El ticket lleva negocio, dirección, teléfonos, fecha y hora');
select ok((select contenido -> 'lineas' @> '[{"cantidad": 2, "producto": "Café de olla", "precio_unitario": 30.00, "importe": 60.00}]'
              and contenido -> 'extras' @> '[{"concepto": "Salsa extra para llevar", "importe": 40.00}]'
              and (contenido ->> 'total')::numeric = 100
           from trabajos_impresion where documento = 'ticket'), 'El ticket lleva productos con precio, cobro extra y total');
select ok((select contenido -> 'pagos' @> '[{"metodo": "efectivo", "importe": 60.00, "recibido": 100.00, "cambio": 30.00}]'
           from trabajos_impresion where documento = 'ticket'), 'El ticket lleva el pago, lo recibido y el cambio');
select lives_ok($$ select public.reimprimir_ticket((select valor::uuid from v where clave = 'llevar')) $$,
  'La caja reimprime el ticket');
reset role;

-- ---------------------------------------------------------------- Cobrar una mesa
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select public.unir_mesas(array[(select m1 from t), (select m2 from t)]);
reset role;
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select throws_ok($$ select public.cobrar_cuenta((select id from cuentas where mesa_id = (select m1 from t)),
  '[{"metodo": "transferencia", "importe": 100}]', gen_random_uuid()) $$,
  'El mesero aún no pide la cuenta de Mesa 1 + Mesa 2', 'Una mesa se cobra cuando el mesero pide la cuenta');
reset role;
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select public.pedir_cuenta((select m1 from t));
reset role;
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select lives_ok($$ select public.cobrar_cuenta((select id from cuentas where mesa_id = (select m1 from t)),
  '[{"metodo": "transferencia", "importe": 100}]', gen_random_uuid()) $$, 'La cajera cobra la mesa por transferencia');
reset role;
select ok((select bool_and(estado = 'disponible' and unida_a is null) from mesas where id in ((select m1 from t), (select m2 from t))),
  'Al cobrar, las mesas quedan libres y separadas');

-- ---------------------------------------------------------------- Devolución autorizada
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select throws_ok($$ select public.solicitar_autorizacion('cancelar_linea_cobrada', (select id from cuentas where mesa_id = (select m1 from t)),
  'El refresco no se sirvió', (select id from lineas_cuenta where producto_id = (select refresco from t))) $$,
  'Indica cómo se le devuelve el dinero al cliente', 'Quitar un producto cobrado exige decir cómo se devuelve el dinero');
select public.solicitar_autorizacion('cancelar_linea_cobrada', (select id from cuentas where mesa_id = (select m1 from t)),
  'El refresco no se sirvió', (select id from lineas_cuenta where producto_id = (select refresco from t)), null, 'efectivo');
reset role;
select pg_temp.como('22222222-2222-2222-2222-222222222222');
select public.resolver_autorizacion((select id from autorizaciones where tipo = 'cancelar_linea_cobrada'), true);
reset role;
select is((select metodo || ' ' || importe from devoluciones), 'efectivo 25.00',
  'Al aprobar, se registra la devolución de $25 en efectivo');
select ok((select turno_id is not null from devoluciones), 'La devolución en efectivo queda en el turno de caja');

-- ---------------------------------------------------------------- Corte
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select is((select count(*)::int from pagos), 3, 'La cajera ve los pagos de su caja abierta');
insert into v select 'resumen', public.resumen_caja()::text;
select is((select (valor::jsonb ->> 'efectivo_esperado')::numeric from v where clave = 'resumen'), 555.00,
  'Efectivo esperado: $500 fondo + $60 ventas + $50 entrada − $30 retiro − $25 devolución (las propinas no cuentan)');
select is((select (valor::jsonb ->> 'terminal_esperada')::numeric from v where clave = 'resumen'), 40.00,
  'La terminal debe marcar $40');
select is((select (valor::jsonb ->> 'ventas_transferencia')::numeric from v where clave = 'resumen'), 100.00,
  'Ventas por transferencia: $100');
select is((select (valor::jsonb ->> 'propinas_efectivo')::numeric from v where clave = 'resumen'), 10.00,
  'Propinas en efectivo aparte: $10');
select public.cerrar_caja(550);
select is((select diferencia from turnos_caja), -5.00, 'Contado $550: faltante de $5');
select is((select estado::text from turnos_caja), 'cerrado', 'El corte queda cerrado, pendiente de aprobar');
select is((select count(*)::int from pagos), 0, 'Con la caja cerrada, la cajera ya no ve los pagos');
select throws_ok($$ select public.aprobar_corte((select id from turnos_caja)) $$, '42501', null, 'La cajera no aprueba cortes');
reset role;
select is((select documento || '/' || impresora from trabajos_impresion where documento = 'corte'), 'corte/caja',
  'El corte se manda a la impresora de caja');

select pg_temp.como('11111111-1111-1111-1111-111111111111');
select public.aprobar_corte((select id from turnos_caja));
select is((select estado::text from turnos_caja), 'aprobado', 'El propietario aprueba el corte');
select throws_ok($$ select public.reabrir_corte((select id from turnos_caja), '') $$,
  'Escribe el motivo para reabrir el corte', 'Reabrir exige motivo');
select public.reabrir_corte((select id from turnos_caja), 'Faltó registrar un retiro');
select is((select estado::text || ' ' || coalesce(diferencia::text, 'sin diferencia') from turnos_caja), 'abierto sin diferencia',
  'Solo el propietario reabre el corte');
reset role;
select ok((select count(*) > 0 from auditoria where accion like 'Reabrió el corte de caja%' and motivo = 'Faltó registrar un retiro'),
  'La reapertura queda en la auditoría con su motivo');

select * from finish();
rollback;
