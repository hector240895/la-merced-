-- Pruebas de guisados para elegir (uno o varios por platillo).
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
select (select id from mesas where nombre = 'Mesa 1') m1,
       (select id from productos where nombre = 'Orden de sopes con guisado (3 pz)') sopes,
       (select id from productos where nombre = 'Quesadilla (2 guisados)') q2,
       (select id from productos where nombre = 'Tostada con guisado') tostada,
       (select id from productos where nombre = 'Enchiladas rojas con pollo') enchiladas;
grant select on t to authenticated;
create temp table t_plato (id uuid);
grant select on t_plato to authenticated;

select is((select selecciones -> 0 -> 'opciones' from productos where nombre = 'Sope con guisado (1 pz)'),
  '["Deshebrada", "Papas con chorizo", "Chicharrón prensado", "Requesón con rajas", "Champiñones", "Pollo"]'::jsonb,
  'Los 6 guisados están en la lista');
select is((select count(*)::int from productos where selecciones @> '[{"etiqueta": "Guisado"}]'), 9,
  'Nueve platillos eligen guisado (incluido el taco de guisado)');
select is((select string_agg(nombre || '=' || jsonb_array_length(selecciones), ', ' order by nombre) from productos
           where jsonb_array_length(selecciones) > 1),
  'Orden de quesadillitas (3 pz)=3, Orden de sopes con guisado (3 pz)=3, Plato Aguascalientes’n=3, Quesadilla (2 guisados)=2',
  'Sopes, quesadillitas y el plato Aguascalientes’n llevan 3 selecciones; la quesadilla de 2, dos');
select is((select selecciones -> 0 -> 'opciones' from productos where nombre = 'Agua de sabor (500 ml)'), '["Horchata", "Jamaica"]'::jsonb,
  'Los sabores de bebidas no cambian');

select pg_temp.como('33333333-3333-3333-3333-333333333333');
select throws_ok($$ select public.enviar_pedido((select m1 from t), jsonb_build_array(
  jsonb_build_object('producto_id', (select sopes from t), 'cantidad', 1, 'opciones', array['Pollo', 'Pollo'])), gen_random_uuid()) $$,
  'Elige los 3 guisados de Orden de sopes con guisado (3 pz)', 'La orden de sopes exige 3 guisados');
select throws_ok($$ select public.enviar_pedido((select m1 from t), jsonb_build_array(
  jsonb_build_object('producto_id', (select tostada from t), 'cantidad', 1)), gen_random_uuid()) $$,
  'Elige el guisado de Tostada con guisado', 'La tostada exige su guisado');
select throws_ok($$ select public.enviar_pedido((select m1 from t), jsonb_build_array(
  jsonb_build_object('producto_id', (select q2 from t), 'cantidad', 1, 'opciones', array['Pollo', 'Mole'])), gen_random_uuid()) $$,
  'Elige los 2 guisados de Quesadilla (2 guisados)', 'Un guisado que no está en la lista no se acepta');

-- Cada pieza por separado, con su propia observación.
select public.enviar_pedido((select m1 from t), jsonb_build_array(
  jsonb_build_object('producto_id', (select sopes from t), 'cantidad', 1, 'opciones', array['Deshebrada', 'Pollo', 'Pollo']),
  jsonb_build_object('producto_id', (select tostada from t), 'cantidad', 1, 'opcion', 'Champiñones'),
  jsonb_build_object('producto_id', (select enchiladas from t), 'cantidad', 1, 'observacion', 'Sin crema'),
  jsonb_build_object('producto_id', (select enchiladas from t), 'cantidad', 1, 'observacion', 'Sin cebolla'),
  jsonb_build_object('producto_id', (select enchiladas from t), 'cantidad', 1)), gen_random_uuid());
reset role;
select is((select opcion from lineas_cuenta where producto_id = (select sopes from t)), 'Deshebrada, Pollo, Pollo',
  'Los 3 guisados de la orden quedan guardados, se pueden repetir');
select is((select opcion from lineas_cuenta where producto_id = (select tostada from t)), 'Champiñones',
  'Un solo guisado también se acepta como opción');
select is((select string_agg(coalesce(observacion, '(sin observación)'), ', ' order by observacion nulls last)
           from lineas_cuenta where producto_id = (select enchiladas from t)), 'Sin cebolla, Sin crema, (sin observación)',
  'Cada orden de enchiladas lleva su propia observación');

set constraints comandas_imprimir immediate;
set constraints comandas_imprimir deferred;
select ok((select contenido -> 'lineas' @> '[{"producto": "Orden de sopes con guisado (3 pz)", "opcion": "Deshebrada, Pollo, Pollo"}]'
           from trabajos_impresion), 'La comanda dice los guisados');
select is((select jsonb_array_length(contenido -> 'lineas') from trabajos_impresion), 5,
  'La comanda lleva cada pieza con su observación');

-- Plato Aguascalientes’n: tres listas distintas.
insert into t_plato select id from productos where nombre = 'Plato Aguascalientes’n';
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select throws_ok($$ select public.enviar_pedido((select m1 from t), jsonb_build_array(
  jsonb_build_object('producto_id', (select id from t_plato), 'cantidad', 1, 'opciones', array['Pollo', 'Pollo'])), gen_random_uuid()) $$,
  'Completa las opciones de Plato Aguascalientes’n', 'El plato exige sus tres selecciones');
select throws_ok($$ select public.enviar_pedido((select m1 from t), jsonb_build_array(
  jsonb_build_object('producto_id', (select id from t_plato), 'cantidad', 1, 'opciones', array['Pollo', 'Pollo', 'Pollo'])), gen_random_uuid()) $$,
  'Completa las opciones de Plato Aguascalientes’n', 'Cada selección acepta solo las opciones de su propia lista');
select public.enviar_pedido((select m1 from t), jsonb_build_array(
  jsonb_build_object('producto_id', (select id from t_plato), 'cantidad', 1, 'opciones', array['Deshebrada', 'Pollo', 'Pata curtida'])),
  gen_random_uuid());
reset role;
select is((select opcion from lineas_cuenta where producto_id = (select id from t_plato)),
  'Guisado del sope: Deshebrada, Guisado de la quesadillita: Pollo, Pata o cueritos: Pata curtida',
  'La comanda dice qué guisado va en cada pieza y si es pata o cueritos');
select is((select precio from productos where nombre = 'Taco de guisado'), 12.00, 'Taco de guisado a $12');
select is((select k.nombre || ' · ' || p.precio || ' · ' || p.orden from productos p join categorias k on k.id = p.categoria_id
           where p.nombre = 'Quesadillitas sencillas'), 'Quesadillas · 70.00 · 2', 'Quesadillitas sencillas a $70 en Quesadillas');

select * from finish();
rollback;
