-- Pruebas de guisados para elegir (uno o varios por platillo).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(12);

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

select is((select opciones from productos where nombre = 'Sope con guisado (1 pz)'),
  array['Deshebrada', 'Papas con chorizo', 'Chicharrón prensado', 'Requesón con rajas', 'Champiñones', 'Pollo'],
  'Los 6 guisados están en la lista');
select is((select count(*)::int from productos where nombre_opcion = 'guisado'), 8, 'Ocho platillos eligen guisado');
select is((select string_agg(nombre || '=' || cuantas_opciones, ', ' order by nombre) from productos where cuantas_opciones > 1),
  'Orden de quesadillitas (3 pz)=3, Orden de sopes con guisado (3 pz)=3, Quesadilla (2 guisados)=2',
  'Las órdenes de sopes y quesadillitas llevan 3 guisados; la quesadilla de 2, dos');
select is((select opciones from productos where nombre = 'Agua de sabor (500 ml)'), array['Horchata', 'Jamaica'],
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

select * from finish();
rollback;
