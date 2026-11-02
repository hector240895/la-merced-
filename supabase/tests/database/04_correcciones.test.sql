-- Pruebas de las correcciones de la auditoría técnica (20261103000100).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(17);

create function pg_temp.como(p_id uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_id, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
grant execute on all functions in schema pg_temp to authenticated;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'hector@lamerced.local'),
  ('33333333-3333-3333-3333-333333333333', 'carlos@lamerced.local');
select public.instalar_propietario('11111111-1111-1111-1111-111111111111', 'hector', 'Hector Navarro');
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select public.registrar_usuario('33333333-3333-3333-3333-333333333333', 'carlos', 'Carlos', 'mesero');
reset role;

create temp table t as
select (select id from mesas where nombre = 'Mesa 1') m1, (select id from mesas where nombre = 'Mesa 2') m2,
       (select id from mesas where nombre = 'Mesa 3') m3, (select id from mesas where nombre = 'Mesa 4') m4,
       (select id from mesas where nombre = 'Mesa 5') m5, (select id from mesas where nombre = 'Mesa 6') m6,
       (select id from mesas where nombre = 'Mesa 7') m7,
       (select id from productos where nombre = 'Café de olla') cafe, gen_random_uuid() s;
grant select on t to authenticated;

-- ---------------------------------------------------------------- Críticos
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select throws_ok($$ select public.enviar_pedido((select m3 from t), null, gen_random_uuid()) $$,
  'El pedido no tiene productos', 'Un pedido NULL se rechaza');
select is((select count(*)::int from cuentas where mesa_id = (select m3 from t)), 0,
  'Un pedido NULL no crea cuenta');
select is((select estado::text from mesas where id = (select m3 from t)), 'disponible',
  'Un pedido NULL no cambia la mesa');

select public.enviar_pedido((select m1 from t),
  jsonb_build_array(jsonb_build_object('producto_id', (select cafe from t), 'cantidad', 1)), (select s from t));
select throws_ok($$ select public.enviar_pedido((select m2 from t),
  jsonb_build_array(jsonb_build_object('producto_id', (select cafe from t), 'cantidad', 5)), (select s from t)) $$,
  'Este envío ya se usó en otro pedido. Vuelve a enviar el pedido.',
  'Un identificador de envío de otra mesa se rechaza (el pedido no se pierde en silencio)');
select is((public.enviar_pedido((select m1 from t),
  jsonb_build_array(jsonb_build_object('producto_id', (select cafe from t), 'cantidad', 1)), (select s from t)) ->> 'repetido'),
  'true', 'El reintento en la misma mesa sigue respondiendo "repetido"');

select throws_ok($$ select public.enviar_pedido((select m2 from t),
  jsonb_build_array(jsonb_build_object('producto_id', (select cafe from t), 'cantidad', 1, 'observacion', repeat('x', 201))),
  gen_random_uuid()) $$, 'La observación es muy larga (máximo 200 letras)', 'La observación tiene límite');
reset role;

-- ---------------------------------------------------------------- Mesas
-- Una cuenta con cobro anulado ya no ocupa la mesa: se puede desactivar.
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select public.enviar_pedido((select m4 from t),
  jsonb_build_array(jsonb_build_object('producto_id', (select cafe from t), 'cantidad', 1)), gen_random_uuid());
reset role;
update cuentas set estado = 'por_cobrar', cobro_anulado_en = now() where mesa_id = (select m4 from t);
update mesas set estado = 'disponible' where id = (select m4 from t);
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select lives_ok($$ select public.activar_mesa((select m4 from t), false) $$,
  'Una mesa cuya cuenta solo espera cobro en caja se puede desactivar');
select throws_ok($$ select public.activar_mesa((select m1 from t), false) $$, null,
  'Una mesa con cuenta abierta sigue sin poder desactivarse');

select throws_ok($$ select public.ordenar_mesas(array[(select m1 from t), (select m1 from t)]) $$,
  'Una mesa aparece dos veces en el orden', 'Ordenar rechaza mesas repetidas');
select throws_ok($$ select public.ordenar_mesas(array[(select m1 from t), gen_random_uuid()]) $$,
  'Una de las mesas no existe', 'Ordenar rechaza mesas inexistentes');
select lives_ok($$ select public.ordenar_mesas(array[(select m2 from t), (select m1 from t)]) $$,
  'Ordenar con una lista válida funciona');
reset role;

-- Uniones: la regla se revisa al final; aquí se fuerza al momento para probarla.
set constraints all immediate;
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select lives_ok($$ select public.unir_mesas(array[(select m5 from t), (select m6 from t)]) $$,
  'Unir mesas sigue funcionando con la regla nueva');
select lives_ok($$ select public.unir_mesas(array[(select m6 from t), (select m7 from t)]) $$,
  'Unir una mesa de un grupo con otra suma al grupo existente');
reset role;
select is((select count(*)::int from mesas where unida_a = (select m5 from t)), 2,
  'Las tres mesas quedan en un solo grupo, sin cadenas');
select throws_ok($$ update mesas set unida_a = (select m6 from t) where id = (select m2 from t) $$,
  'Unión de mesas inválida: una mesa solo se une a una mesa principal',
  'La base no permite unir una mesa a otra que ya está unida');

-- ---------------------------------------------------------------- Catálogo
select throws_ok($$ insert into categorias (nombre) values ('pozole') $$, '23505', null,
  'No se repite el nombre de una categoría vigente');
select throws_ok($$ insert into productos (categoria_id, nombre, precio)
                   select categoria_id, 'CAFÉ DE OLLA', 1 from productos where nombre = 'Café de olla' $$, '23505', null,
  'No se repite el nombre de un producto vigente en su categoría');

select * from finish();
rollback;
