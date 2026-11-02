-- =============================================================================
-- Sistema La Merced · Menú de la cenaduría (carta MENU_1.pdf)
-- Precios finales al cliente. El propietario podrá cambiar productos y
-- precios desde el catálogo (Etapa 7); como todo, nada se borra.
--
-- Criterios de captura:
--   * Los guisados se eligen como observación del pedido (la lista aparece en
--     la descripción de cada platillo que lleva guisado).
--   * Cuando la carta junta opciones que cocina prepara distinto ("de pollo /
--     queso", tamales rojo, verde y prensado) van como productos separados.
--   * El sabor de refrescos y aguas se anota como observación.
--   * "Solo viernes, sábado y domingo" queda en la descripción; esos días el
--     propietario puede marcar el producto como agotado.
-- =============================================================================
do $$
declare
  guisado constant text :=
    'Guisado a elegir: deshebrada, papas con chorizo, chicharrón prensado verde, requesón con rajas, champiñones o pollo';
  sabor constant text := 'Anota el sabor en la observación';
  c uuid;
begin
  perform privado.fijar_accion('Instalación: menú de La Merced');

  insert into public.categorias (nombre, orden) values ('Pozole', 1) returning id into c;
  insert into public.productos (categoria_id, nombre, descripcion, precio, orden) values
    (c, 'Pozole rojo chico',     null, 75, 1),
    (c, 'Pozole rojo grande',    null, 85, 2),
    (c, 'Pozole verde chico',    'Solo viernes, sábado y domingo', 80, 3),
    (c, 'Pozole verde grande',   'Solo viernes, sábado y domingo', 90, 4),
    (c, 'Litro de pozole rojo',  null, 100, 5),
    (c, 'Litro de pozole verde', null, 110, 6),
    (c, 'Pozole de pollo (extra)', 'Se agrega al pozole para que sea de pollo', 5, 7);

  insert into public.categorias (nombre, orden) values ('Enchiladas', 2) returning id into c;
  insert into public.productos (categoria_id, nombre, descripcion, precio, orden) values
    (c, 'Enchiladas rojas con queso y cebolla', 'Orden de 4 piezas', 80, 1),
    (c, 'Enchiladas rojas con pollo',           'Orden de 4 piezas', 95, 2),
    (c, 'Enchiladas verdes con pollo',          'Orden de 4 piezas', 105, 3),
    (c, 'Enchiladas verdes con queso',          'Orden de 4 piezas', 95, 4);

  insert into public.categorias (nombre, orden) values ('Flautas', 3) returning id into c;
  insert into public.productos (categoria_id, nombre, descripcion, precio, orden) values
    (c, 'Flautas de deshebrada',         'Orden de 4 piezas', 60, 1),
    (c, 'Flautas de pollo',              'Orden de 4 piezas', 65, 2),
    (c, 'Flautas de requesón con rajas', 'Orden de 4 piezas', 65, 3);

  insert into public.categorias (nombre, orden) values ('Quesadillas', 4) returning id into c;
  insert into public.productos (categoria_id, nombre, descripcion, precio, orden) values
    (c, 'Orden de quesadillitas (3 pz)',        null, 95, 1),
    (c, 'Quesadilla (1 guisado)',               guisado, 65, 2),
    (c, 'Quesadilla (2 guisados)',              guisado, 70, 3),
    (c, 'Quesadilla sencilla (solo queso)',     null, 45, 4),
    (c, 'Quesadillita individual con guisado',  guisado, 35, 5);

  insert into public.categorias (nombre, orden) values ('Sopes', 5) returning id into c;
  insert into public.productos (categoria_id, nombre, descripcion, precio, orden) values
    (c, 'Orden de sopes con guisado (3 pz)', 'Llevan pico de gallo. ' || guisado, 85, 1),
    (c, 'Orden de sopes sencillos (3 pz)',   'Solo frijoles', 55, 2),
    (c, 'Sope con guisado (1 pz)',           guisado, 30, 3),
    (c, 'Sope sencillo (1 pz)',              null, 20, 4);

  insert into public.categorias (nombre, orden) values ('Antojitos', 6) returning id into c;
  insert into public.productos (categoria_id, nombre, descripcion, precio, orden) values
    (c, 'Plato Aguascalientes’n',
        '1 sope con guisado, 1 flauta, 1 enchilada roja, 1 taco dorado, 1 quesadillita con guisado y media orden de pata o cueritos',
        155, 1),
    (c, 'Tacos dorados',             null, 65, 2),
    (c, 'Tostada con guisado',       guisado, 45, 3),
    (c, 'Tostada con cueritos',      null, 40, 4),
    (c, 'Orden de cueritos',         null, 60, 5),
    (c, 'Media orden de cueritos',   null, 30, 6),
    (c, 'Orden de pata',             null, 75, 7),
    (c, 'Media orden de pata',       null, 40, 8),
    (c, 'Tamal rojo',                'Solo viernes y sábado', 20, 9),
    (c, 'Tamal verde',               'Solo viernes y sábado', 20, 10),
    (c, 'Tamal de prensado con queso', 'Solo viernes y sábado', 20, 11);

  insert into public.categorias (nombre, orden) values ('Medias órdenes', 7) returning id into c;
  insert into public.productos (categoria_id, nombre, descripcion, precio, orden) values
    (c, 'Media enchiladas verdes de pollo (2 pz)',            null, 50, 1),
    (c, 'Media enchiladas verdes de queso (2 pz)',            null, 50, 2),
    (c, 'Media enchiladas rojas con queso y cebolla (2 pz)',  null, 45, 3),
    (c, 'Media enchiladas rojas con pollo (2 pz)',            null, 50, 4),
    (c, 'Media flautas de deshebrada (2 pz)',                 null, 35, 5),
    (c, 'Media flautas de requesón (2 pz)',                   null, 35, 6),
    (c, 'Media flautas de pollo (2 pz)',                      null, 45, 7),
    (c, 'Media tacos dorados (3 pz)',                         null, 40, 8);

  insert into public.categorias (nombre, orden) values ('Extras', 8) returning id into c;
  insert into public.productos (categoria_id, nombre, descripcion, precio, orden) values
    (c, 'Orden de papas',  null, 20, 1),
    (c, 'Extra cueritos',  null, 15, 2),
    (c, 'Crema',           null, 5, 3),
    (c, 'Aguacate',        null, 10, 4),
    (c, 'Guisado extra',   'Anota cuál guisado en la observación', 5, 5);

  insert into public.categorias (nombre, orden) values ('Bebidas', 9) returning id into c;
  insert into public.productos (categoria_id, nombre, descripcion, precio, orden) values
    (c, 'Refresco de vidrio (355 ml)',    sabor, 25, 1),
    (c, 'Refresco desechable (600 ml)',   sabor, 30, 2),
    (c, 'Agua de sabor (500 ml)',         sabor, 25, 3),
    (c, 'Agua de sabor (900 ml)',         sabor, 35, 4),
    (c, 'Café de olla',                   null, 30, 5),
    (c, 'Botellín de agua natural',       null, 10, 6),
    (c, 'Arizona',                        sabor, 25, 7);

  insert into public.categorias (nombre, orden) values ('Postres', 10) returning id into c;
  insert into public.productos (categoria_id, nombre, descripcion, precio, orden) values
    (c, 'Rebanada de chocoflan', null, 45, 1),
    (c, 'Carlotta',              null, 35, 2),
    (c, 'Jericallas',            null, 45, 3);

  perform privado.fijar_accion(null);
end
$$;
