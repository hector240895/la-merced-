-- Pruebas de opciones para elegir (sabores de aguas y refrescos).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(9);

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

create temp table ids as
select (select id from mesas where nombre = 'Mesa 1') m1,
       (select id from productos where nombre = 'Agua de sabor (500 ml)') agua,
       (select id from productos where nombre = 'Café de olla') cafe;
grant select on ids to authenticated;

select is((select opciones from productos where nombre = 'Agua de sabor (900 ml)'), array['Horchata', 'Jamaica'],
  'El agua de 900 ml tiene horchata y jamaica');
select is((select cardinality(opciones) from productos where nombre = 'Refresco de vidrio (355 ml)'), 11,
  'El refresco de vidrio tiene 11 sabores');

select pg_temp.como('33333333-3333-3333-3333-333333333333');
select throws_ok($$ select public.enviar_pedido((select m1 from ids),
  jsonb_build_array(jsonb_build_object('producto_id', (select agua from ids), 'cantidad', 1)), gen_random_uuid()) $$,
  'Elige el sabor de Agua de sabor (500 ml)', 'Sin sabor no se envía');
select throws_ok($$ select public.enviar_pedido((select m1 from ids),
  jsonb_build_array(jsonb_build_object('producto_id', (select agua from ids), 'cantidad', 1, 'opcion', 'Limón')), gen_random_uuid()) $$,
  'Elige el sabor de Agua de sabor (500 ml)', 'Un sabor que no está en la lista no se acepta');
select throws_ok($$ select public.enviar_pedido((select m1 from ids),
  jsonb_build_array(jsonb_build_object('producto_id', (select cafe from ids), 'cantidad', 1, 'opcion', 'Horchata')), gen_random_uuid()) $$,
  'Café de olla no tiene opciones para elegir', 'Un producto sin opciones no acepta una');

select public.enviar_pedido((select m1 from ids),
  jsonb_build_array(jsonb_build_object('producto_id', (select agua from ids), 'cantidad', 3, 'opcion', 'Horchata'),
                    jsonb_build_object('producto_id', (select agua from ids), 'cantidad', 1, 'opcion', 'Jamaica')),
  gen_random_uuid());
select is((select string_agg(cantidad || ' ' || opcion, ', ' order by opcion) from lineas_cuenta), '3 Horchata, 1 Jamaica',
  'Cada sabor queda en su propia línea');

select public.quitar_producto((select id from lineas_cuenta where opcion = 'Horchata'), 'Se equivocó de sabor', 1);
select is((select opcion from lineas_cuenta where estado = 'activa' and reemplaza_linea_id is not null), 'Horchata',
  'Lo que queda conserva el sabor');
reset role;
select ok((select count(*) > 0 from auditoria where accion like 'Quitó 1 × Agua de sabor (500 ml) · Horchata%'),
  'La auditoría dice qué sabor se quitó');
select throws_ok($$ update lineas_cuenta set opcion = 'Jamaica' where opcion = 'Horchata' $$, '42501', null,
  'El sabor guardado no se cambia');

select * from finish();
rollback;
