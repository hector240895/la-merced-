// Prueba del servicio de impresión contra Supabase LOCAL, con impresoras
// simuladas (cada impresión es un archivo). Cubre: comanda y ticket en la
// impresora correcta, error y reintento, trabajos pendientes al reconectar en
// orden, sin duplicados, corte y estado de las impresoras.
//
//   node impresora/pruebas/servicio.integracion.mjs   (desde la raíz del repositorio)
import { execSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';

const carpeta = mkdtempSync(join(tmpdir(), 'la-merced-impresora-'));
process.env.LA_MERCED_CARPETA = join(carpeta, 'datos');
const { createClient } = await import('@supabase/supabase-js');
const { iniciarServicio } = await import('../src/cola.mjs');
const { controladorArchivo } = await import('../src/impresoras.mjs');
const { leerImpresos, guardarImpresos } = await import('../src/config.mjs');

const estado = Object.fromEntries(execSync('npx supabase status -o env', { encoding: 'utf8' }).split('\n')
  .filter((l) => l.includes('=')).map((l) => { const i = l.indexOf('='); return [l.slice(0, i), l.slice(i + 1).replace(/^"|"$/g, '')]; }));
const URL = estado.API_URL;
if (!/127\.0\.0\.1|localhost/.test(URL)) throw new Error('Solo contra Supabase local');

let n = 0;
let fallas = 0;
async function comprobar(descripcion, fn) {
  n += 1;
  try { await fn(); console.log(`ok ${n} - ${descripcion}`); }
  catch (e) { fallas += 1; console.log(`not ok ${n} - ${descripcion}\n   ${e.message}`); }
}
const esperar = async (fn, ms = 10_000) => {
  const fin = Date.now() + ms;
  for (;;) {
    const r = await fn().catch(() => null);
    if (r) return r;
    if (Date.now() > fin) throw new Error('No ocurrió a tiempo');
    await new Promise((x) => setTimeout(x, 250));
  }
};
const latin = (b) => [...b].map((x) => (x === 0x0a ? '\n' : x >= 0x20 && x < 0x80 ? String.fromCharCode(x) : '')).join('');
const archivos = (imp) => { try { return readdirSync(join(carpeta, 'papel', imp)).filter((f) => f.endsWith('.bin')).sort(); } catch { return []; } };
const leerArchivo = (imp, f) => latin(readFileSync(join(carpeta, 'papel', imp, f)));

// ---------------------------------------------------------------- Preparación
const claves = JSON.parse(execSync('node scripts/probar-etapa3-preparar.mjs', { encoding: 'utf8' }).trim().split('\n').pop());
execSync(`node scripts/esperar-realtime.mjs`, { env: { ...process.env, SERVICE_ROLE_KEY: estado.SERVICE_ROLE_KEY }, stdio: 'ignore' });
const admin = createClient(URL, estado.SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const sesion = async (usuario, clave) => {
  const c = createClient(URL, estado.ANON_KEY, { auth: { persistSession: false } });
  const { error } = await c.auth.signInWithPassword({ email: `${usuario}@lamerced.local`, password: clave });
  if (error) throw new Error(`${usuario}: ${error.message}`);
  return c;
};
const hector = await sesion('hector', claves.hector);
const clave = 'Clave-' + randomBytes(6).toString('hex');
for (const [usuario, nombre, perfil] of [['carlos', 'Carlos Pérez', 'mesero'], ['laura', 'Laura', 'cajero'], ['impresora', 'Impresora de caja', 'cajero']]) {
  const { data } = await admin.auth.admin.createUser({ email: `${usuario}@lamerced.local`, password: clave, email_confirm: true });
  const r = await hector.rpc('registrar_usuario', { p_id: data.user.id, p_usuario: usuario, p_nombre: nombre, p_perfil: perfil });
  if (r.error) throw new Error(r.error.message);
}
const carlos = await sesion('carlos', clave);
const laura = await sesion('laura', clave);
const mesa = async (nombre) => (await carlos.from('mesas').select('id').eq('nombre', nombre).single()).data.id;
const producto = async (nombre) => (await carlos.from('productos').select('id').eq('nombre', nombre).single()).data.id;
const pedir = async (mesaNombre, prod = 'Pozole rojo chico', obs = 'Sin lechuga') => {
  const r = await carlos.rpc('enviar_pedido', {
    p_mesa_id: await mesa(mesaNombre), p_solicitud_id: crypto.randomUUID(),
    p_productos: [{ producto_id: await producto(prod), cantidad: 1, observacion: obs }],
  });
  if (r.error) throw new Error(r.error.message);
  return r.data;
};
const trabajoDe = async (comandaId) => (await hector.from('trabajos_impresion').select('*').eq('comanda_id', comandaId).is('reimpresion_de', null).single()).data;

const config = {
  supabaseUrl: URL, llavePublica: estado.ANON_KEY, dominio: 'lamerced.local', usuario: 'impresora',
  impresoras: { cocina: { nombre: 'cocina', ancho: 48, tabla: 'cp850' }, caja: { nombre: 'caja', ancho: 32, tabla: 'cp850' } },
};
const controlador = controladorArchivo(join(carpeta, 'papel'));
const arrancar = () => iniciarServicio({ config, contrasena: clave, controlador, registrar: () => {}, intervalo: 1500, intervaloLatido: 1000 });
let servicio = await arrancar();

// ---------------------------------------------------------------- Pruebas
await comprobar('El servicio avisa que está conectado y cómo están las impresoras', async () => {
  const s = await esperar(async () => (await hector.from('servicio_impresion').select('*').maybeSingle()).data);
  if (s.impresoras.cocina.estado !== 'lista' || s.impresoras.caja.estado !== 'lista') throw new Error(JSON.stringify(s.impresoras));
});

let pedido1;
await comprobar('Una comanda sale en la impresora de cocina y queda "impresa"', async () => {
  pedido1 = await pedir('Mesa 1');
  await esperar(async () => (await trabajoDe(pedido1.comanda_id))?.estado === 'impreso');
  const [f] = archivos('cocina');
  const t = leerArchivo('cocina', f);
  if (!t.includes('COMANDA') || !t.includes('Mesa 1') || !t.includes('SIN LECHUGA')) throw new Error(t);
  if (t.includes('$')) throw new Error('La comanda lleva precios');
});

await comprobar('El ticket sale en la impresora de caja', async () => {
  await carlos.rpc('pedir_cuenta', { p_mesa_id: await mesa('Mesa 1') });
  await laura.rpc('abrir_caja', { p_fondo: 500 });
  const r = await laura.rpc('cobrar_cuenta', { p_cuenta_id: pedido1.cuenta_id, p_solicitud_id: crypto.randomUUID(),
    p_pagos: [{ metodo: 'efectivo', importe: 75, recibido: 100 }] });
  if (r.error) throw new Error(r.error.message);
  await esperar(async () => archivos('caja').length === 1);
  const t = leerArchivo('caja', archivos('caja')[0]);
  if (!/TOTAL\s+\$75/.test(t) || !/Cambio\s+\$25/.test(t)) throw new Error(t);
  if (archivos('cocina').length !== 1) throw new Error('El ticket salió en cocina');
});

await comprobar('Si la impresora falla, queda "error" con el motivo y el estado lo muestra', async () => {
  writeFileSync(join(carpeta, 'papel', 'cocina', 'FALLAR'), '');
  const p = await pedir('Mesa 2');
  const t = await esperar(async () => { const x = await trabajoDe(p.comanda_id); return x?.estado === 'error' ? x : null; });
  if (!t.ultimo_error.includes('sin papel')) throw new Error(t.ultimo_error);
  await esperar(async () => (await hector.from('servicio_impresion').select('impresoras').single()).data.impresoras.cocina.estado === 'sin papel');
  pedido1 = p;
});

await comprobar('Al reintentar con la impresora lista, sale y queda "impresa"', async () => {
  rmSync(join(carpeta, 'papel', 'cocina', 'FALLAR'));
  const t = await trabajoDe(pedido1.comanda_id);
  const r = await carlos.rpc('reintentar_impresion', { p_trabajo_id: t.id });
  if (r.error) throw new Error(r.error.message);
  await esperar(async () => (await trabajoDe(pedido1.comanda_id))?.estado === 'impreso');
  if (archivos('cocina').length !== 2) throw new Error(`${archivos('cocina').length} comandas en papel`);
});

await comprobar('Con la computadora apagada, lo pendiente sale al volver, en orden de llegada', async () => {
  await servicio.detener();
  const a = await pedir('Mesa 3');
  const b = await pedir('Mesa 4');
  if ((await trabajoDe(a.comanda_id)).estado !== 'pendiente') throw new Error('Debía quedar pendiente');
  servicio = await arrancar();
  await esperar(async () => (await trabajoDe(b.comanda_id))?.estado === 'impreso');
  const ultimos = archivos('cocina').slice(-2).map((f) => leerArchivo('cocina', f));
  if (!ultimos[0].includes('Mesa 3') || !ultimos[1].includes('Mesa 4')) throw new Error('Salieron en otro orden');
});

await comprobar('Sin duplicados: lo que ya salió en papel solo se confirma al reconectar', async () => {
  await servicio.detener();
  const p = await pedir('Mesa 5');
  const t = await trabajoDe(p.comanda_id);
  const impresos = await leerImpresos();
  impresos.add(t.id);   // como si se hubiera impreso justo antes de perder la conexión
  await guardarImpresos(impresos);
  const antes = archivos('cocina').length;
  servicio = await arrancar();
  await esperar(async () => (await trabajoDe(p.comanda_id))?.estado === 'impreso');
  if (archivos('cocina').length !== antes) throw new Error('Se volvió a imprimir');
});

await comprobar('La reimpresión manual sale marcada como REIMPRESIÓN', async () => {
  const p = await pedir('Mesa 7');
  await esperar(async () => (await trabajoDe(p.comanda_id))?.estado === 'impreso');
  const x = await carlos.rpc('reimprimir_comanda', { p_comanda_id: p.comanda_id });
  if (x.error) throw new Error(x.error.message);
  await esperar(async () => leerArchivo('cocina', archivos('cocina').slice(-1)[0]).includes('REIMPRESI'));
});

await comprobar('El corte de caja sale en la impresora de caja', async () => {
  const r = await laura.rpc('cerrar_caja', { p_efectivo_contado: 575 });
  if (r.error) throw new Error(r.error.message);
  await esperar(async () => archivos('caja').some((f) => leerArchivo('caja', f).includes('CORTE DE CAJA')));
});

await servicio.detener();
rmSync(carpeta, { recursive: true, force: true });
console.log(`\n${n - fallas} de ${n} comprobaciones correctas`);
process.exit(fallas ? 1 : 0);
