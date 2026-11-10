-- Pruebas de la Etapa 7: catálogo.
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

-- ---------------------------------------------------------------- Categorías
select pg_temp.como('11111111-1111-1111-1111-111111111111');
insert into v select 'cat', (public.crear_categoria('Especiales del día')).id;
select is((select orden from categorias where id = (select id from v where clave = 'cat')), 11, 'La categoría nueva va al final');
select throws_ok($$ select public.crear_categoria('pozole') $$, 'Ya existe la categoría pozole', 'No se repiten categorías');
select lives_ok($$ select public.renombrar_categoria((select id from v where clave = 'cat'), 'Especiales') $$, 'Se renombra una categoría');

-- ---------------------------------------------------------------- Productos
insert into v select 'birria', (public.crear_producto((select id from v where clave = 'cat'), '  Birria  ', 120, 'Con consomé',
  '[{"etiqueta": " Tortilla ", "opciones": ["Maíz", "Harina", "maíz", " "]}]')).id;
select is((select nombre from productos where id = (select id from v where clave = 'birria')), 'Birria', 'Se limpian los espacios del nombre');
select is((select selecciones from productos where id = (select id from v where clave = 'birria')),
  '[{"etiqueta": "Tortilla", "opciones": ["Maíz", "Harina"]}]'::jsonb, 'Las opciones se limpian y no se repiten');
select throws_ok($$ select public.crear_producto((select id from v where clave = 'cat'), 'birria', 100) $$,
  'Ya existe "birria" en esa categoría', 'No se repite un producto en la categoría');
select throws_ok($$ select public.crear_producto((select id from v where clave = 'cat'), 'Barato', -5) $$,
  'Escribe un precio válido', 'No se aceptan precios negativos');
select throws_ok($$ select public.crear_producto((select id from v where clave = 'cat'), 'Sopa', 50, null,
  '[{"etiqueta": "Tamaño", "opciones": ["Chica"]}]') $$, 'La opción "Tamaño" necesita al menos 2 elementos para elegir',
  'Una opción necesita al menos 2 elementos');
select throws_ok($$ select public.crear_producto((select id from v where clave = 'cat'), 'Sopa', 50, null,
  '[{"etiqueta": "", "opciones": ["A", "B"]}]') $$, 'Cada opción necesita un nombre (por ejemplo "Guisado" o "Sabor")',
  'Cada opción necesita nombre');

insert into v select 'copia', (public.duplicar_producto((select id from v where clave = 'birria'))).id;
select is((select nombre || ' ' || precio from productos where id = (select id from v where clave = 'copia')), 'Birria (copia) 120.00',
  'Duplicar crea una copia con el mismo precio');
select public.ordenar_productos((select id from v where clave = 'cat'),
  array[(select id from v where clave = 'copia'), (select id from v where clave = 'birria')]);
select is((select orden from productos where id = (select id from v where clave = 'copia')), 1, 'Se cambia el orden de los productos');
reset role;

-- ---------------------------------------------------------------- Precio y cuentas abiertas
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select public.enviar_pedido((select id from mesas where nombre = 'Mesa 1'), jsonb_build_array(
  jsonb_build_object('producto_id', (select id from v where clave = 'birria'), 'cantidad', 1, 'opcion', 'Maíz')), gen_random_uuid());
reset role;
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select public.editar_producto((select id from v where clave = 'birria'), (select id from v where clave = 'cat'), 'Birria', 135,
  'Con consomé', '[{"etiqueta": "Tortilla", "opciones": ["Maíz", "Harina"]}]');
reset role;
select is((select precio_nuevo from historial_precios where producto_id = (select id from v where clave = 'birria')), 135.00,
  'El cambio de precio queda en el historial');
select is((select precio_unitario from lineas_cuenta where producto_id = (select id from v where clave = 'birria')), 120.00,
  'La cuenta abierta conserva el precio con que se pidió');
select ok((select count(*) > 0 from avisos a join auditoria x on x.id = a.auditoria_id
           where a.para_usuario_id = '22222222-2222-2222-2222-222222222222' and x.accion like 'Cambió Birria: precio de $120.00 a $135.00%'),
  'Wendy recibe aviso del cambio de precio');

-- ---------------------------------------------------------------- Agotado (todos) y permisos
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select lives_ok($$ select public.marcar_agotado((select id from v where clave = 'birria'), true) $$, 'El mesero marca agotado');
select is((select estado::text from productos where id = (select id from v where clave = 'birria')), 'agotado', 'El producto queda agotado');
select throws_ok($$ select public.enviar_pedido((select id from mesas where nombre = 'Mesa 2'), jsonb_build_array(
  jsonb_build_object('producto_id', (select id from v where clave = 'birria'), 'cantidad', 1, 'opcion', 'Maíz')), gen_random_uuid()) $$,
  'Birria está agotado', 'Un producto agotado no se puede pedir');
select throws_ok($$ select public.crear_producto((select id from v where clave = 'cat'), 'Otro', 10) $$, '42501', null,
  'El mesero no crea productos');
select throws_ok($$ select public.editar_producto((select id from v where clave = 'birria'), (select id from v where clave = 'cat'),
  'Birria', 1, null, '[]') $$, '42501', null, 'El mesero no cambia precios');
select throws_ok($$ select public.ocultar_producto((select id from v where clave = 'birria'), true) $$, '42501', null,
  'El mesero no oculta productos');
reset role;
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select lives_ok($$ select public.marcar_agotado((select id from v where clave = 'birria'), false) $$, 'La caja marca disponible');
select throws_ok($$ select public.eliminar_producto((select id from v where clave = 'birria')) $$, '42501', null,
  'La caja no elimina productos');
reset role;

-- ---------------------------------------------------------------- Ocultar, eliminar, fotos
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select public.ocultar_producto((select id from v where clave = 'copia'), true);
reset role;
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select is((select count(*)::int from productos where id = (select id from v where clave = 'copia')), 0, 'El mesero no ve productos ocultos');
reset role;
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select throws_ok($$ select public.eliminar_categoria((select id from v where clave = 'cat')) $$, null,
  'No se elimina una categoría con productos');
select public.eliminar_producto((select id from v where clave = 'copia'));
select is((select eliminado_en is not null from productos where id = (select id from v where clave = 'copia')), true,
  'Eliminar conserva el producto marcado');
select lives_ok($$ select public.cambiar_foto_producto((select id from v where clave = 'birria'),
  (select id from v where clave = 'birria')::text || '/foto-1.jpg') $$, 'El propietario pone la foto');
select throws_ok($$ select public.cambiar_foto_producto((select id from v where clave = 'birria'), 'otro/archivo.jpg') $$,
  'Foto no válida', 'La foto debe ser de ese producto');
select public.ocultar_producto((select id from v where clave = 'birria'), true);
select throws_ok($$ select public.marcar_agotado((select id from v where clave = 'birria'), true) $$,
  'El producto no está en el menú', 'Un producto oculto no se marca agotado');
reset role;
select ok((select count(*) > 0 from auditoria where accion = 'Marcó agotado: Birria'
           and usuario_id = '33333333-3333-3333-3333-333333333333'), 'Queda registrado quién marcó agotado');

select * from finish();
rollback;
