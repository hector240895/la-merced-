-- Etapa 9 · Categorías de gasto nuevas. Agregar valores a un tipo debe ir en
-- su propia migración para poder usarlos en la siguiente.
alter type public.categoria_gasto add value if not exists 'desechables';
alter type public.categoria_gasto add value if not exists 'limpieza';
alter type public.categoria_gasto add value if not exists 'comisiones_terminal';
alter type public.categoria_gasto add value if not exists 'internet_telefono';
alter type public.categoria_gasto add value if not exists 'refrescos';

create type public.forma_pago_gasto as enum ('caja', 'efectivo', 'tarjeta', 'transferencia');
