-- Pruebas de la Etapa 4: comandas e impresión.
-- La comanda se encola al terminar la operación (al confirmar). En la prueba
-- se fuerza ese momento con SET CONSTRAINTS ... IMMEDIATE.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(25);

create function pg_temp.como(p_id uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_id, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
grant execute on all functions in schema pg_temp to authenticated;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'hector@lamerced.local'),
  ('33333333-3333-3333-3333-333333333333', 'carlos@lamerced.local'),
  ('44444444-4444-4444-4444-444444444444', 'laura@lamerced.local');
select public.instalar_propietario('11111111-1111-1111-1111-111111111111', 'hector', 'Hector Navarro');
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select public.registrar_usuario('33333333-3333-3333-3333-333333333333', 'carlos', 'Carlos Pérez', 'mesero');
select public.registrar_usuario('44444444-4444-4444-4444-444444444444', 'laura', 'Laura', 'cajero');
reset role;

create temp table t as
select (select id from mesas where nombre = 'Mesa 1') m1,
       (select id from productos where nombre = 'Pozole rojo chico') pozole,
       (select id from productos where nombre = 'Agua de sabor (500 ml)') agua,
       (select id from productos where nombre = 'Jericallas') postre;
grant select on t to authenticated;

-- ---------------------------------------------------------------- Pedido nuevo
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select public.enviar_pedido((select m1 from t), jsonb_build_array(
  jsonb_build_object('producto_id', (select pozole from t), 'cantidad', 2, 'observacion', 'Sin lechuga'),
  jsonb_build_object('producto_id', (select agua from t), 'cantidad', 1, 'opcion', 'Jamaica')), gen_random_uuid());
reset role;
select is((select count(*)::int from trabajos_impresion), 0, 'Mientras la operación no termina, no se encola nada');
set constraints comandas_imprimir immediate;
set constraints comandas_imprimir deferred;

select is((select count(*)::int from trabajos_impresion), 1, 'Enviar un pedido encola una comanda');
select is((select documento || '/' || impresora || '/' || estado from trabajos_impresion), 'comanda/cocina/pendiente',
  'Va a la impresora de cocina y queda pendiente');
select is((select contenido ->> 'destino' from trabajos_impresion), 'Mesa 1', 'La comanda dice la mesa');
select is((select contenido ->> 'usuario' from trabajos_impresion), 'Carlos Pérez', 'La comanda dice el mesero');
select ok((select contenido ->> 'hora' ~ '^\d\d:\d\d$' from trabajos_impresion), 'La comanda dice la hora');
select is((select contenido ->> 'tipo' from trabajos_impresion), 'nueva', 'Es la comanda nueva');
select is((select jsonb_array_length(contenido -> 'lineas') from trabajos_impresion), 2, 'Lleva los dos productos');
select ok((select contenido -> 'lineas' @> '[{"cantidad": 2, "producto": "Pozole rojo chico", "observacion": "Sin lechuga"}]'
           from trabajos_impresion), 'Lleva la observación');
select ok((select contenido -> 'lineas' @> '[{"producto": "Agua de sabor (500 ml)", "opcion": "Jamaica"}]'
           from trabajos_impresion), 'Lleva el sabor');
select ok((select contenido::text !~* 'precio|importe|total|"95|"75' from trabajos_impresion), 'No lleva precios');

-- ---------------------------------------------------------------- Adicional y cancelación
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select public.enviar_pedido((select m1 from t), jsonb_build_array(
  jsonb_build_object('producto_id', (select postre from t), 'cantidad', 1)), gen_random_uuid());
reset role;
set constraints comandas_imprimir immediate;
set constraints comandas_imprimir deferred;
select is((select contenido ->> 'tipo' from trabajos_impresion order by creado_en desc, contenido ->> 'numero' desc limit 1), 'adicional',
  'El segundo envío encola una comanda adicional');
select is((select contenido -> 'lineas' from trabajos_impresion where contenido ->> 'tipo' = 'adicional'),
  '[{"opcion": null, "leyenda": null, "cantidad": 1, "producto": "Jericallas", "observacion": null}]'::jsonb,
  'La adicional lleva solo lo nuevo');

select pg_temp.como('33333333-3333-3333-3333-333333333333');
select public.quitar_producto((select id from lineas_cuenta where producto_id = (select pozole from t)), 'No lo pidieron', 1);
reset role;
set constraints comandas_imprimir immediate;
set constraints comandas_imprimir deferred;
select is((select contenido -> 'lineas' -> 0 ->> 'leyenda' || ' ' || (contenido -> 'lineas' -> 0 ->> 'cantidad')
           from trabajos_impresion where contenido ->> 'tipo' = 'cancelacion'), 'CANCELADO 1',
  'Quitar un producto encola el aviso CANCELADO con la cantidad');

-- ---------------------------------------------------------------- Sin precios, garantizado
select throws_ok($$ insert into trabajos_impresion (documento, impresora, comanda_id, contenido)
                   select 'comanda', 'cocina', comanda_id, contenido || '{"precio_unitario": 95}'
                   from trabajos_impresion limit 1 $$, '23514', null,
  'La base rechaza una comanda que lleve precios');

-- ---------------------------------------------------------------- Estado de impresión
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select throws_ok($$ select public.reportar_impresion((select id from trabajos_impresion where contenido ->> 'tipo' = 'nueva'), true) $$,
  '42501', null, 'El mesero no puede marcar comandas como impresas');
select is((select count(*)::int from trabajos_impresion), 3, 'El mesero ve el estado de las comandas de sus mesas');
reset role;

select pg_temp.como('44444444-4444-4444-4444-444444444444');
select public.reportar_impresion((select id from trabajos_impresion where contenido ->> 'tipo' = 'adicional'), false, 'Sin papel');
select public.reportar_impresion((select id from trabajos_impresion where contenido ->> 'tipo' = 'nueva'), true);
select is((select estado::text from trabajos_impresion where contenido ->> 'tipo' = 'nueva'), 'impreso', 'Caja informa: impresa');
select public.reportar_impresion((select id from trabajos_impresion where contenido ->> 'tipo' = 'nueva'), false, 'tarde');
select is((select estado::text from trabajos_impresion where contenido ->> 'tipo' = 'nueva'), 'impreso',
  'Un aviso tardío no cambia una comanda ya impresa (sin duplicados)');
reset role;

select pg_temp.como('33333333-3333-3333-3333-333333333333');
select is((select ultimo_error from trabajos_impresion where contenido ->> 'tipo' = 'adicional'), 'Sin papel',
  'El mesero ve el error de impresión');
select public.reintentar_impresion((select id from trabajos_impresion where contenido ->> 'tipo' = 'adicional'));
select is((select estado::text from trabajos_impresion where contenido ->> 'tipo' = 'adicional'), 'pendiente',
  'Reintentar devuelve la comanda a la cola');
select throws_ok($$ select public.reimprimir_comanda((select comanda_id from trabajos_impresion where contenido ->> 'tipo' = 'adicional')) $$,
  'La comanda aún no se imprime; si falló, usa Reintentar', 'No se reimprime lo que aún no sale');
select public.reimprimir_comanda((select comanda_id from trabajos_impresion where contenido ->> 'tipo' = 'nueva'));
select ok((select reimpresion_de is not null and (contenido ->> 'reimpresion')::boolean and estado = 'pendiente'
           from trabajos_impresion where reimpresion_de is not null), 'Reimprimir crea una copia marcada como reimpresión');
reset role;
select ok((select count(*) > 0 from auditoria where accion like 'Reimprimió la comanda 1 de Mesa 1'
           and usuario_id = '33333333-3333-3333-3333-333333333333'), 'La reimpresión queda registrada con quién la pidió');
select is((select contenido ->> 'reimprimio' from trabajos_impresion where reimpresion_de is not null), 'Carlos Pérez',
  'La comanda reimpresa dice quién la pidió');

select * from finish();
rollback;
