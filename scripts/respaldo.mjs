// Respaldo propio de todos los datos (no necesita Docker).
//
//   npm run respaldo
//
// Lee SUPABASE_URL y SUPABASE_SECRET_KEY de .env.local y guarda un archivo
// respaldos/respaldo-AAAA-MM-DD.json con todas las tablas. La carpeta
// respaldos/ no se sube a GitHub: guarda el archivo en una USB o en tu nube.
import { mkdirSync, writeFileSync } from 'node:fs';
import { clienteServicio, variable } from './lib/supabase.mjs';

const TABLAS = [
  'sucursales', 'usuarios', 'categorias', 'productos', 'historial_precios', 'mesas', 'uniones_mesas',
  'turnos_caja', 'movimientos_efectivo', 'cuentas', 'lineas_cuenta', 'cobros_extra', 'comandas', 'comanda_lineas',
  'pagos', 'propinas', 'devoluciones', 'autorizaciones', 'trabajos_impresion', 'servicio_impresion',
  'categorias_gasto', 'empleados', 'gastos_fijos', 'gastos', 'gasto_productos',
  'proveedores', 'insumos', 'movimientos_inventario', 'auditoria', 'avisos',
];

const admin = clienteServicio(variable('SUPABASE_URL'), variable('SUPABASE_SECRET_KEY'));
const datos = {};
let total = 0;
for (const tabla of TABLAS) {
  const filas = [];
  for (let desde = 0; ; desde += 1000) {
    const { data, error } = await admin.from(tabla).select('*').range(desde, desde + 999);
    if (error) {
      console.error(`No se pudo leer ${tabla}: ${error.message}`);
      process.exit(1);
    }
    filas.push(...data);
    if (data.length < 1000) break;
  }
  datos[tabla] = filas;
  total += filas.length;
}

const hoy = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Mexico_City' });
mkdirSync('respaldos', { recursive: true });
const archivo = `respaldos/respaldo-${hoy}.json`;
writeFileSync(archivo, JSON.stringify({ creado: new Date().toISOString(), tablas: datos }, null, 1));
console.log(`Listo: ${total} registros de ${TABLAS.length} tablas en ${archivo}. Cópialo a una USB o a tu nube.`);
