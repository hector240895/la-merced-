// Asistente de configuración del servicio de impresión (se corre una vez en la
// computadora de caja, desde instalar.bat). Pregunta la cuenta, deja elegir las
// impresoras de Windows, imprime páginas de prueba para escoger la tabla de
// acentos, guarda todo y deja el servicio arrancando solo con Windows.
import readline from 'node:readline';
import { execFileSync, spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import { CARPETA, PREDETERMINADO, guardarConfig, proteger } from './config.mjs';
import { controladorWindows } from './impresoras.mjs';
import { paginaPrueba } from './formatos.mjs';

const AQUI = dirname(fileURLToPath(import.meta.url));
const TAREA = 'La Merced Impresion';

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const preguntar = (texto, porOmision = '') => new Promise((r) =>
  rl.question(porOmision ? `${texto} [${porOmision}]: ` : `${texto}: `, (x) => r(x.trim() || porOmision)));
function preguntarOculto(texto) {
  return new Promise((r) => {
    const salida = rl._writeToOutput;
    rl._writeToOutput = (s) => { if (s.includes(texto)) rl.output.write(s); };
    rl.question(`${texto}: `, (x) => { rl._writeToOutput = salida; process.stdout.write('\n'); r(x); });
  });
}
const titulo = (t) => console.log(`\n=== ${t} ===\n`);

async function elegir(lista, texto) {
  lista.forEach((x, i) => console.log(`  ${i + 1}. ${x.nombre}${x.puerto ? `  (puerto ${x.puerto})` : ''}`));
  for (;;) {
    const n = Number(await preguntar(texto));
    if (n >= 1 && n <= lista.length) return lista[n - 1].nombre;
    console.log('  Escribe el número de la lista.');
  }
}

async function main() {
  console.log('\nSistema La Merced · Configuración del servicio de impresión\n');
  const config = structuredClone(PREDETERMINADO);
  const windows = controladorWindows();

  titulo('1. Cuenta del servicio');
  console.log('Usa la cuenta de cajero que creaste en el sistema para la impresora (por ejemplo "impresora").');
  config.usuario = (await preguntar('Usuario', config.usuario)).toLowerCase();
  let clave;
  for (;;) {
    clave = await preguntarOculto('Contraseña (no se muestra al escribir)');
    const sb = createClient(config.supabaseUrl, config.llavePublica, { auth: { persistSession: false } });
    const { error } = await sb.auth.signInWithPassword({ email: `${config.usuario}@${config.dominio}`, password: clave });
    if (error) { console.log(`  No se pudo entrar: ${error.message}. Intenta de nuevo.`); continue; }
    const { data: yo } = await sb.rpc('yo').maybeSingle();
    await sb.auth.signOut();
    if (!yo || !['cajero', 'propietario'].includes(yo.perfil)) {
      console.log('  Esa cuenta no es de cajero o está dada de baja. Usa otra.'); continue;
    }
    console.log(`  Listo: ${yo.nombre} (${yo.perfil}).`);
    break;
  }
  config.contrasenaProtegida = await proteger(clave);

  titulo('2. Impresoras');
  const lista = await windows.listar();
  if (!lista.length) throw new Error('Windows no tiene impresoras instaladas. Instala las dos impresoras y vuelve a correr esto.');
  config.impresoras.cocina.nombre = await elegir(lista, 'Número de la impresora de COCINA (NE-511, 80 mm)');
  config.impresoras.caja.nombre = await elegir(lista, 'Número de la impresora de CAJA (NE-510X, 58 mm)');

  titulo('3. Acentos y ñ');
  for (const [clave2, etiqueta] of [['cocina', 'COCINA'], ['caja', 'CAJA']]) {
    const imp = config.impresoras[clave2];
    console.log(`Imprimiendo dos páginas de prueba en ${etiqueta} ("${imp.nombre}")…`);
    try {
      await windows.imprimir(imp.nombre, paginaPrueba(etiqueta, 'cp850', { ancho: imp.ancho }), 'prueba-a');
      await windows.imprimir(imp.nombre, paginaPrueba(etiqueta, 'cp1252', { ancho: imp.ancho }), 'prueba-b');
    } catch (e) {
      console.log(`  No se pudo imprimir: ${e.message}`);
      console.log('  Revisa que esté encendida, con papel y conectada, y vuelve a correr la configuración.');
      throw new Error('Prueba de impresión fallida');
    }
    for (;;) {
      const r = (await preguntar(`¿En qué página de ${etiqueta} se ven bien "á é í ó ú ñ ¡ ¿"? Escribe A o B`)).toUpperCase();
      if (r === 'A' || r === 'B') { imp.tabla = r === 'A' ? 'cp850' : 'cp1252'; break; }
    }
  }

  titulo('4. Guardar y arrancar con Windows');
  const ruta = await guardarConfig(config);
  console.log(`Configuración guardada en ${ruta}`);
  // Lanzador oculto: arranca el servicio sin ventana y lo reinicia si se cierra.
  const node = process.execPath;
  const servicio = resolve(AQUI, 'servicio.mjs');
  const vbs = join(CARPETA, 'iniciar-oculto.vbs');
  writeFileSync(vbs, [
    "' Sistema La Merced: arranca el servicio de impresión sin ventana y lo reinicia si se detiene.",
    'Set sh = CreateObject("WScript.Shell")',
    'Do',
    `  sh.Run """${node}"" ""${servicio}""", 0, True`,
    '  WScript.Sleep 5000',
    'Loop',
  ].join('\r\n'), 'latin1');
  try { execFileSync('schtasks', ['/Delete', '/F', '/TN', TAREA], { stdio: 'ignore' }); } catch { /* no existía */ }
  execFileSync('schtasks', ['/Create', '/F', '/SC', 'ONLOGON', '/TN', TAREA, '/TR', `wscript.exe "${vbs}"`, '/RL', 'LIMITED']);
  console.log(`Tarea de Windows "${TAREA}" creada: el servicio arranca solo al iniciar sesión.`);

  spawn('wscript.exe', [vbs], { detached: true, stdio: 'ignore' }).unref();
  console.log('\nEl servicio de impresión ya está corriendo.');
  console.log('En la app (pestaña Comandas) debe decir "Impresoras conectadas".');
  console.log(`Si algo falla, revisa el registro: ${join(CARPETA, 'registro.log')}\n`);
}

main().catch((e) => { console.error(`\nNo se completó la configuración: ${e.message}\n`); process.exitCode = 1; })
  .finally(() => rl.close());
