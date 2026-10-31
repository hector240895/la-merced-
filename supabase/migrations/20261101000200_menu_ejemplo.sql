-- =============================================================================
-- Sistema La Merced · Etapa 3 · Menú de ejemplo
-- Productos y precios del prototipo, para poder tomar pedidos mientras se
-- construye el catálogo (Etapa 7). El propietario los cambia o da de baja
-- desde el catálogo; como todo, no se borran: quedan en el historial.
-- =============================================================================
do $$
declare
  v_cenas uuid;
  v_bebidas uuid;
  v_postres uuid;
begin
  perform privado.fijar_accion('Instalación: menú de ejemplo');

  insert into public.categorias (nombre, orden) values ('Cenas', 1) returning id into v_cenas;
  insert into public.categorias (nombre, orden) values ('Bebidas', 2) returning id into v_bebidas;
  insert into public.categorias (nombre, orden) values ('Postres', 3) returning id into v_postres;

  insert into public.productos (categoria_id, nombre, descripcion, precio, orden) values
    (v_cenas,   'Pozole rojo',      'Cerdo, lechuga, rábano y tostadas', 95, 1),
    (v_cenas,   'Tostadas de pata', 'Orden de tres',                     70, 2),
    (v_cenas,   'Enchiladas',       'Con queso, pollo y ensalada',       90, 3),
    (v_cenas,   'Flautas',          'Orden de cuatro, con crema',        85, 4),
    (v_cenas,   'Gorditas',         'Pieza, a elegir guisado',           32, 5),
    (v_bebidas, 'Agua de horchata', 'Vaso grande',                       35, 1),
    (v_bebidas, 'Refresco',         'Botella de 355 ml',                 28, 2),
    (v_bebidas, 'Café de olla',     'Taza',                              30, 3),
    (v_bebidas, 'Atole',            'Vaso de 12 oz',                     32, 4),
    (v_postres, 'Buñuelos',         'Con piloncillo, orden de dos',      45, 1),
    (v_postres, 'Arroz con leche',  'Porción',                           40, 2);

  perform privado.fijar_accion(null);
end
$$;
