-- Pruebas de la Etapa 3: mesas y pedidos.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(40);

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
select public.registrar_usuario('33333333-3333-3333-3333-333333333333', 'carlos', 'Carlos', 'mesero');
select public.registrar_usuario('44444444-4444-4444-4444-444444444444', 'laura', 'Laura', 'cajero');
reset role;

create temp table ids as
select (select id from mesas where nombre = 'Mesa 1') m1, (select id from mesas where nombre = 'Mesa 2') m2,
       (select id from mesas where nombre = 'Mesa 3') m3, (select id from mesas where nombre = 'Mesa 4') m4,
       (select id from productos where nombre = 'Pozole rojo chico') pozole,
       (select id from productos where nombre = 'Refresco de vidrio (355 ml)') refresco,
       (select id from productos where nombre = 'Flautas de pollo') flautas,
       gen_random_uuid() s1, gen_random_uuid() s2;
grant select on ids to authenticated;
update productos set estado = 'agotado' where nombre = 'Flautas de pollo';

-- ---------------------------------------------------------------- Mesero
select pg_temp.como('33333333-3333-3333-3333-333333333333');

select lives_ok($$ select public.ocupar_mesa((select m1 from ids)) $$, 'El mesero abre una mesa');
select is((select estado::text from mesas where id = (select m1 from ids)), 'ocupada', 'La mesa queda ocupada');
select lives_ok($$ select public.liberar_mesa((select m1 from ids)) $$, 'Se libera si se fueron sin pedir');
select is((select estado::text from mesas where id = (select m1 from ids)), 'disponible', 'La mesa vuelve a disponible');

select public.enviar_pedido((select m1 from ids),
  jsonb_build_array(jsonb_build_object('producto_id', (select pozole from ids), 'cantidad', 2, 'observacion', 'Sin lechuga'),
                    jsonb_build_object('producto_id', (select refresco from ids), 'cantidad', 2)),
  (select s1 from ids));
select is((select estado::text from mesas where id = (select m1 from ids)), 'pedido_enviado', 'Enviar deja la mesa en pedido enviado');
select is((select count(*)::int from cuentas where mesa_id = (select m1 from ids)), 1, 'El primer pedido abre la cuenta');
select is((select mesero_id from cuentas where mesa_id = (select m1 from ids)),
  '33333333-3333-3333-3333-333333333333'::uuid, 'La cuenta guarda al mesero');
select is((select precio_unitario from lineas_cuenta where producto_id = (select pozole from ids)), 75.00,
  'La línea guarda el precio del momento');
select is((select observacion from lineas_cuenta where producto_id = (select pozole from ids)), 'Sin lechuga',
  'La observación se guarda');
select is((select c.tipo::text from comandas c join cuentas k on k.id = c.cuenta_id where k.mesa_id = (select m1 from ids)),
  'nueva', 'Es la comanda nueva');

-- Reintento del mismo envío (señal intermitente): no se duplica.
select is((public.enviar_pedido((select m1 from ids),
  jsonb_build_array(jsonb_build_object('producto_id', (select pozole from ids), 'cantidad', 2)), (select s1 from ids)) ->> 'repetido'),
  'true', 'Repetir el mismo envío no duplica');
select is((select count(*)::int from lineas_cuenta l join cuentas k on k.id = l.cuenta_id where k.mesa_id = (select m1 from ids)),
  2, 'Siguen siendo dos productos');

-- Pedido adicional: solo lo nuevo.
select public.enviar_pedido((select m1 from ids),
  jsonb_build_array(jsonb_build_object('producto_id', (select refresco from ids), 'cantidad', 1)), (select s2 from ids));
select is((select tipo::text from comandas where solicitud_id = (select s2 from ids)), 'adicional', 'El segundo envío es comanda adicional');
select is((select count(*)::int from comanda_lineas cl join comandas c on c.id = cl.comanda_id where c.solicitud_id = (select s2 from ids)),
  1, 'La comanda adicional lleva solo lo nuevo');

select throws_ok($$ select public.enviar_pedido((select m2 from ids),
  jsonb_build_array(jsonb_build_object('producto_id', (select flautas from ids), 'cantidad', 1)), gen_random_uuid()) $$,
  'Flautas de pollo está agotado', 'No se piden productos agotados');
select is((select estado::text from mesas where id = (select m2 from ids)), 'disponible', 'Un envío rechazado no deja nada a medias');
select throws_ok($$ select public.enviar_pedido((select m2 from ids), '[]'::jsonb, gen_random_uuid()) $$,
  'El pedido no tiene productos', 'No se envía un pedido vacío');

-- Quitar parte de un producto ya enviado.
select throws_ok($$ select public.quitar_producto((select id from lineas_cuenta where producto_id = (select pozole from ids)), '') $$,
  'Escribe el motivo para quitar el producto', 'Quitar exige motivo');
select public.quitar_producto((select id from lineas_cuenta where producto_id = (select pozole from ids)),
  'Uno no se llevó al cliente', 1);
select is((select count(*)::int from lineas_cuenta where producto_id = (select pozole from ids) and estado = 'cancelada'), 1,
  'La línea original queda cancelada, sin borrarse');
select is((select cantidad from lineas_cuenta where producto_id = (select pozole from ids) and estado = 'activa'), 1,
  'Queda un pozole en la cuenta');
select is((select observacion from lineas_cuenta where producto_id = (select pozole from ids) and estado = 'activa'), 'Sin lechuga',
  'Lo que queda conserva la observación');
select is((select cl.leyenda || ' ' || cl.cantidad from comanda_lineas cl join comandas c on c.id = cl.comanda_id
           where c.tipo = 'cancelacion'), 'CANCELADO 1', 'Cocina recibe CANCELADO por la cantidad quitada');
select is((select cancelacion_motivo from lineas_cuenta where producto_id = (select pozole from ids) and estado = 'cancelada'),
  'Uno no se llevó al cliente', 'El motivo queda registrado');

-- Unir y separar.
select throws_ok($$ select public.unir_mesas(array[(select m1 from ids)]) $$, 'Elige al menos dos mesas distintas',
  'Se necesitan dos mesas para unir');
select public.unir_mesas(array[(select m3 from ids), (select m1 from ids)]);
select is((select unida_a from mesas where id = (select m3 from ids)), (select m1 from ids),
  'La mesa sin cuenta se une a la que tiene pedido');
select is((select estado::text from mesas where id = (select m3 from ids)), 'pedido_enviado', 'La mesa unida toma el estado del grupo');
select public.enviar_pedido((select m3 from ids),
  jsonb_build_array(jsonb_build_object('producto_id', (select refresco from ids), 'cantidad', 1)), gen_random_uuid());
select is((select count(*)::int from cuentas where estado = 'abierta'), 1, 'Pedir desde la mesa unida usa la misma cuenta');
select public.enviar_pedido((select m2 from ids),
  jsonb_build_array(jsonb_build_object('producto_id', (select refresco from ids), 'cantidad', 1)), gen_random_uuid());
select throws_ok($$ select public.unir_mesas(array[(select m1 from ids), (select m2 from ids)]) $$,
  'Solo se puede unir si a lo más una de las mesas tiene pedido', 'No se unen dos mesas con pedido');
select public.separar_mesas((select m3 from ids));
select ok((select unida_a is null and estado = 'disponible' from mesas where id = (select m3 from ids)),
  'Al separar, la otra mesa queda libre');
select is((select count(*)::int from uniones_mesas), 2, 'Unión y separación quedan registradas');

-- Pedir la cuenta.
select public.pedir_cuenta((select m1 from ids));
select is((select estado::text from mesas where id = (select m1 from ids)), 'por_cobrar', 'Pedir la cuenta deja la mesa por cobrar');
select throws_ok($$ select public.enviar_pedido((select m1 from ids),
  jsonb_build_array(jsonb_build_object('producto_id', (select refresco from ids), 'cantidad', 1)), gen_random_uuid()) $$,
  null, 'Con la cuenta pedida ya no se agregan productos');
select throws_ok($$ select public.liberar_mesa((select m1 from ids)) $$, null, 'Una mesa con cuenta no se libera a mano');
select throws_ok($$ select public.crear_mesa('Terraza') $$, '42501', null, 'El mesero no administra mesas');
reset role;

-- ---------------------------------------------------------------- Cajero
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select throws_ok($$ select public.ocupar_mesa((select m4 from ids)) $$, '42501', null, 'El cajero no abre mesas');
select lives_ok($$ select public.quitar_producto((select id from lineas_cuenta where producto_id = (select refresco from ids)
                    and estado = 'activa' order by creado_en limit 1), 'No lo recibió') $$,
  'El cajero quita un producto antes del cobro');
reset role;

-- ---------------------------------------------------------------- Propietario
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select public.crear_mesa('Terraza');
select throws_ok($$ select public.crear_mesa('terraza') $$, 'Ya existe una mesa llamada terraza', 'No se repiten nombres de mesa');
select throws_ok($$ select public.eliminar_mesa((select m1 from ids)) $$, null, 'Una mesa con cuenta no se elimina');
select public.eliminar_mesa((select id from mesas where nombre = 'Terraza'));
select ok((select eliminada_en is not null from mesas where nombre = 'Terraza'), 'Eliminar conserva la mesa marcada');
reset role;
select ok((select count(*) > 0 from avisos a join auditoria x on x.id = a.auditoria_id
           where a.para_usuario_id = '22222222-2222-2222-2222-222222222222' and x.accion = 'Eliminó Terraza'),
  'Wendy recibe aviso de la mesa eliminada');

select * from finish();
rollback;
