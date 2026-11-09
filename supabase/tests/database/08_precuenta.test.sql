-- Pruebas de la precuenta (cuenta informativa antes de cobrar).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(18);

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
select (select id from mesas where nombre = 'Mesa 1') m1, (select id from mesas where nombre = 'Mesa 2') m2,
       (select id from productos where nombre = 'Pozole rojo chico') pozole,
       (select id from productos where nombre = 'Refresco de vidrio (355 ml)') refresco;
grant select on t to authenticated;

select pg_temp.como('33333333-3333-3333-3333-333333333333');
select public.enviar_pedido((select m1 from t), jsonb_build_array(
  jsonb_build_object('producto_id', (select pozole from t), 'cantidad', 2),
  jsonb_build_object('producto_id', (select refresco from t), 'cantidad', 1, 'opcion', 'Pepsi')), gen_random_uuid());
select public.unir_mesas(array[(select m1 from t), (select m2 from t)]);
select is((select count(*)::int from trabajos_impresion where documento = 'precuenta'), 0, 'Antes de pedir la cuenta no hay precuenta');
select public.pedir_cuenta((select m1 from t));
select is((select count(*)::int from trabajos_impresion where documento = 'precuenta'), 1,
  'Al pedir la cuenta se imprime la precuenta');
select is((select impresora::text || '/' || estado from trabajos_impresion where documento = 'precuenta'), 'caja/pendiente',
  'Va a la impresora de caja');
select is((select contenido ->> 'destino' from trabajos_impresion where documento = 'precuenta'), 'Mesa 1 + Mesa 2',
  'Lleva la mesa para saber de dónde es');
select is((select (contenido ->> 'total')::numeric from trabajos_impresion where documento = 'precuenta'), 175.00,
  'Lleva el total (2 pozoles $150 + refresco $25)');
select is((select contenido ->> 'leyenda' from trabajos_impresion where documento = 'precuenta'), '¡Gracias por su visita!',
  'Termina con la leyenda de agradecimiento');
select ok((select contenido -> 'lineas' @> '[{"cantidad": 2, "producto": "Pozole rojo chico", "importe": 150.00},
                                            {"producto": "Refresco de vidrio (355 ml)", "opcion": null}]'
           from trabajos_impresion where documento = 'precuenta'), 'Lleva los productos con su importe, sin sabores');
select is((select count(*)::int from trabajos_impresion where documento = 'precuenta'), 1,
  'El mesero ve el estado de impresión de la precuenta');

-- Volver a imprimirla: mesero y caja.
select lives_ok($$ select public.imprimir_precuenta((select id from cuentas where mesa_id = (select m1 from t))) $$,
  'El mesero vuelve a imprimir la cuenta');
reset role;
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select lives_ok($$ select public.imprimir_precuenta((select id from cuentas where mesa_id = (select m1 from t))) $$,
  'La caja vuelve a imprimir la cuenta');
reset role;

select is((select estado::text from cuentas where mesa_id = (select m1 from t)), 'por_cobrar', 'La cuenta sigue por cobrar');
select is((select count(*)::int from pagos), 0, 'No se registra ningún pago');
select ok((select count(*) >= 2 from auditoria where accion like 'Imprimió la cuenta de Mesa 1 + Mesa 2%'),
  'Queda registrado quién imprimió la cuenta');

-- Guisados y sabores: no aparecen en la precuenta ni en el ticket, sí en la comanda de cocina.
create temp table g as select (select id from mesas where nombre = 'Mesa 3') m3,
  (select id from productos where nombre = 'Tostada con guisado') tostada,
  (select id from productos where nombre = 'Agua de sabor (500 ml)') agua;
grant select on g to authenticated;
select pg_temp.como('33333333-3333-3333-3333-333333333333');
select public.enviar_pedido((select m3 from g), jsonb_build_array(
  jsonb_build_object('producto_id', (select tostada from g), 'cantidad', 1, 'opcion', 'Champiñones'),
  jsonb_build_object('producto_id', (select agua from g), 'cantidad', 1, 'opcion', 'Jamaica')), gen_random_uuid());
select public.pedir_cuenta((select m3 from g));
reset role;
set constraints comandas_imprimir immediate;
set constraints comandas_imprimir deferred;
select ok((select contenido -> 'lineas' @> '[{"producto": "Tostada con guisado", "opcion": "Champiñones"}]'
           from trabajos_impresion where documento = 'comanda' and contenido ->> 'destino' = 'Mesa 3'),
  'La comanda de cocina sí lleva el guisado');
select ok((select contenido -> 'lineas' @> '[{"producto": "Tostada con guisado", "opcion": null}]'
           from trabajos_impresion where documento = 'precuenta' and contenido ->> 'destino' = 'Mesa 3'),
  'La precuenta no lleva el guisado');
select ok((select contenido -> 'lineas' @> '[{"producto": "Agua de sabor (500 ml)", "opcion": null}]'
           from trabajos_impresion where documento = 'precuenta' and contenido ->> 'destino' = 'Mesa 3'),
  'La precuenta tampoco lleva el sabor de la bebida');

-- Una cuenta cobrada ya no imprime precuenta.
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select public.abrir_caja(0);
select public.cobrar_cuenta((select id from cuentas where mesa_id = (select m1 from t)),
  '[{"metodo": "tarjeta", "importe": 175}]', gen_random_uuid());
select throws_ok($$ select public.imprimir_precuenta((select id from cuentas where mesa_id = (select m1 from t))) $$,
  'La cuenta no está abierta', 'Una cuenta cobrada no imprime precuenta (para eso está el ticket)');
select public.cobrar_cuenta((select id from cuentas where mesa_id = (select m3 from g)),
  '[{"metodo": "tarjeta", "importe": 70}]', gen_random_uuid());
reset role;
select ok((select contenido -> 'lineas' @> '[{"producto": "Tostada con guisado", "opcion": null}, {"producto": "Agua de sabor (500 ml)", "opcion": null}]'
           from trabajos_impresion where documento = 'ticket' and cuenta_id = (select id from cuentas where mesa_id = (select m3 from g))),
  'El ticket pagado no lleva guisados ni sabores');

select * from finish();
rollback;
