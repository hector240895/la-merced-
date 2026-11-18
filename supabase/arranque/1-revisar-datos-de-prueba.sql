-- =============================================================================
-- ARRANQUE · Paso 1 de 2 · REVISAR (solo lee, no cambia nada)
--
-- Pégalo completo en Supabase → SQL Editor → Run. Muestra lo que se borraría
-- con el paso 2 y lo que se conserva. Revísalo antes de seguir.
-- =============================================================================
with conteos(orden, grupo, que, cuantos) as (
  values
  (1,  'SE BORRA', 'Cuentas (pedidos de mesa y para llevar)', (select count(*) from public.cuentas)),
  (2,  'SE BORRA', 'Productos pedidos en las cuentas', (select count(*) from public.lineas_cuenta)),
  (3,  'SE BORRA', 'Comandas', (select count(*) from public.comandas)),
  (4,  'SE BORRA', 'Cobros, propinas y devoluciones', (select (select count(*) from public.pagos) + (select count(*) from public.propinas) + (select count(*) from public.devoluciones))),
  (5,  'SE BORRA', 'Cajas abiertas y cortes', (select count(*) from public.turnos_caja)),
  (6,  'SE BORRA', 'Entradas y retiros de efectivo', (select count(*) from public.movimientos_efectivo)),
  (7,  'SE BORRA', 'Impresiones (comandas, tickets, precuentas, cortes)', (select count(*) from public.trabajos_impresion)),
  (8,  'SE BORRA', 'Autorizaciones', (select count(*) from public.autorizaciones)),
  (9,  'SE BORRA', 'Gastos (incluye sueldos, renta y compras)', (select count(*) from public.gastos)),
  (10, 'SE BORRA', 'Movimientos de inventario', (select count(*) from public.movimientos_inventario)),
  (11, 'SE BORRA', 'Historial de auditoría y avisos de prueba', (select count(*) from public.auditoria)),
  (20, 'SE BORRA si dejas borrar_catalogos_de_prueba = true', 'Insumos: ' || coalesce((select string_agg(nombre, ', ' order by nombre) from public.insumos where eliminado_en is null), '—'), (select count(*) from public.insumos)),
  (21, 'SE BORRA si dejas borrar_catalogos_de_prueba = true', 'Proveedores: ' || coalesce((select string_agg(nombre, ', ' order by nombre) from public.proveedores where eliminado_en is null), '—'), (select count(*) from public.proveedores)),
  (22, 'SE BORRA si dejas borrar_catalogos_de_prueba = true', 'Empleados: ' || coalesce((select string_agg(nombre, ', ' order by nombre) from public.empleados where eliminado_en is null), '—'), (select count(*) from public.empleados)),
  (23, 'SE BORRA si dejas borrar_catalogos_de_prueba = true', 'Gastos fijos: ' || coalesce((select string_agg(concepto, ', ' order by concepto) from public.gastos_fijos where eliminado_en is null), '—'), (select count(*) from public.gastos_fijos)),
  (30, 'SE BORRA solo si cambias borrar_cuentas_meseros_cajeros = true', 'Cuentas de meseros y cajeros: ' || coalesce((select string_agg(usuario || ' (' || perfil || ')', ', ' order by usuario) from public.usuarios where perfil <> 'propietario'), '—'), (select count(*) from public.usuarios where perfil <> 'propietario')),
  (40, 'SE CONSERVA', 'Propietarios', (select count(*) from public.usuarios where perfil = 'propietario')),
  (41, 'SE CONSERVA', 'Categorías y productos del menú (con fotos e historial de precios)', (select count(*) from public.productos where eliminado_en is null)),
  (42, 'SE CONSERVA', 'Mesas (quedan disponibles)', (select count(*) from public.mesas where eliminada_en is null)),
  (43, 'SE CONSERVA', 'Categorías de gasto', (select count(*) from public.categorias_gasto where eliminado_en is null)),
  (44, 'SE CONSERVA', 'Datos del negocio y estado de las impresoras', (select count(*) from public.sucursales))
)
select grupo as "Qué pasa", que as "Datos", cuantos as "Cuántos" from conteos order by orden;

-- Aviso: si hay una caja abierta ahora mismo, haz el corte antes de limpiar
-- (de todas formas se borra, pero así nadie está cobrando en ese momento).
