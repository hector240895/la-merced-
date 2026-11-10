// Prueba de la Etapa 9 (gastos y reportes) en el navegador, contra Supabase LOCAL.
//   node app/pruebas/finanzas.e2e.cjs <carpeta-capturas>
const { chromium } = require('playwright');
const { createClient } = require('@supabase/supabase-js');

const APP = process.env.APP_URL ?? 'http://localhost:5173';
const FUNCIONES = process.env.FUNCIONES_URL;
const CLAVES = JSON.parse(process.env.CLAVES_PRUEBA);
const CAPTURAS = process.argv[2];

let n = 0;
let fallas = 0;
async function comprobar(descripcion, fn) {
  n += 1;
  try { await fn(); console.log(`ok ${n} - ${descripcion}`); }
  catch (e) { fallas += 1; console.log(`not ok ${n} - ${descripcion}\n   ${String(e.message).split('\n')[0]}`); }
}
const captura = (page, nombre) => CAPTURAS && page.screenshot({ path: `${CAPTURAS}/${nombre}.png`, fullPage: true });

async function crearCuenta(usuario, nombre, perfil, contrasena) {
  const c = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  await c.auth.signInWithPassword({ email: 'hector@lamerced.local', password: CLAVES.hector });
  const { data: { session } } = await c.auth.getSession();
  const r = await fetch(FUNCIONES, {
    method: 'POST', headers: { Authorization: `Bearer ${session.access_token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ accion: 'crear', usuario, nombre, perfil, contrasena }),
  });
  if (r.status !== 201) throw new Error(`No se creó ${usuario}: ${await r.text()}`);
}

async function sesion(navegador, usuario, contrasena, movil) {
  const ctx = await navegador.newContext(movil
    ? { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }
    : { viewport: { width: 1280, height: 900 } });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => console.log(`   [error en la página de ${usuario}] ${e.message}`));
  page.on('dialog', (d) => d.accept());
  await page.goto(APP);
  await page.getByLabel('Usuario').fill(usuario);
  await page.getByLabel('Contraseña').fill(contrasena);
  await page.getByRole('button', { name: 'Entrar' }).click();
  return page;
}
const producto = (page, nombre) => page.locator('.prod').filter({ has: page.locator('h3', { hasText: nombre }) });
const fila = (page, texto) => page.locator('.row').filter({ has: page.locator('b', { hasText: texto }) });

(async () => {
  CLAVES.laura = CLAVES.carlos + 'L';
  await crearCuenta('laura', 'Laura', 'cajero', CLAVES.laura);
  const navegador = await chromium.launch();
  const hector = await sesion(navegador, 'hector', CLAVES.hector);
  await hector.getByRole('button', { name: 'Gastos', exact: true }).click();

  await comprobar('El propietario agrega una categoría de gasto', async () => {
    await hector.getByRole('button', { name: 'Categorías' }).click();
    await hector.getByLabel('Nombre de la categoría nueva').fill('Garrafones');
    await hector.getByRole('button', { name: 'Agregar categoría' }).click();
    await hector.getByText('Categoría Garrafones agregada').waitFor();
    await fila(hector, /^Garrafones$/).waitFor();
  });

  await comprobar('Agrega empleados con su puesto y sueldo fijo', async () => {
    await hector.getByRole('button', { name: 'Sueldos', exact: true }).click();
    for (const [nombre, puesto, sueldo] of [['Rosa', 'Cocinera', '2000'], ['Pedro', 'Lavaloza', '1500']]) {
      await hector.getByRole('button', { name: 'Agregar empleado' }).first().click();
      await hector.getByLabel('Nombre', { exact: true }).fill(nombre);
      await hector.getByLabel('Puesto').fill(puesto);
      await hector.getByLabel('Sueldo $').fill(sueldo);
      await hector.locator('.pane').getByRole('button', { name: 'Agregar empleado' }).click();
      await hector.getByText('Empleado agregado').first().waitFor();
      await fila(hector, nombre).waitFor();
    }
    await fila(hector, 'Rosa').getByText('$2,000 por semana').waitFor();
  });

  await comprobar('Paga sueldos: se llenan solos y ajusta a quien faltó', async () => {
    await hector.getByRole('button', { name: 'Pagar sueldos' }).click();
    await hector.getByLabel('¿Qué periodo pagas?').fill('Semana 1');
    if (await hector.getByLabel(/^Rosa/).inputValue() !== '2000') throw new Error('No se llenó el sueldo de Rosa');
    await hector.getByLabel(/^Pedro/).fill('750');
    await hector.getByText('$2,750').waitFor();
    await captura(hector, '60-pagar-sueldos');
    await hector.getByRole('button', { name: 'Registrar sueldos' }).click();
    await hector.getByText('Sueldos registrados por $2,750').waitFor();
  });

  await comprobar('La renta se registra sola como gasto fijo', async () => {
    await hector.getByRole('button', { name: 'Renta y gastos fijos' }).click();
    await hector.getByRole('button', { name: 'Agregar gasto fijo' }).first().click();
    await hector.getByLabel('Monto al mes $').fill('8000');
    await hector.locator('.pane').getByRole('button', { name: 'Agregar gasto fijo' }).click();
    await hector.getByText('Gasto fijo agregado').waitFor();
    await fila(hector, 'Renta del local').getByText('$8,000 al mes').waitFor();
    await hector.locator('.nav2').getByRole('button', { name: 'Gastos', exact: true }).click();
    await fila(hector, 'Renta del local').getByText(/automático/).waitFor();
    await fila(hector, 'Sueldo de Pedro · Semana 1').getByText('$750').waitFor();
  });

  await comprobar('Un dueño anota un gasto que pagó el otro', async () => {
    await hector.getByRole('button', { name: 'Registrar gasto' }).click();
    await hector.getByLabel('Categoría', { exact: true }).selectOption({ label: 'Gas' });
    await hector.getByLabel('¿En qué se gastó?').fill('Tanque de gas');
    await hector.getByLabel('Monto $').fill('300');
    await hector.getByLabel('¿Quién lo pagó?').selectOption({ label: 'Wendy Rivas' });
    await hector.getByRole('button', { name: 'Guardar gasto' }).click();
    await hector.getByText('Gasto de $300 registrado').waitFor();
    await fila(hector, 'Tanque de gas').getByText(/pagó Wendy Rivas/).waitFor();
  });

  const laura = await sesion(navegador, 'laura', CLAVES.laura);
  await laura.getByRole('button', { name: 'Caja y corte' }).click();
  await laura.getByLabel('Fondo inicial').fill('1000');
  await laura.getByRole('button', { name: 'Abrir caja', exact: true }).click();
  await laura.locator('.chip', { hasText: 'Caja abierta' }).waitFor();
  await laura.getByRole('button', { name: 'Gastos', exact: true }).click();

  await comprobar('Caja registra un gasto pagado con su efectivo (sin renta ni sueldos)', async () => {
    await laura.getByRole('button', { name: 'Registrar gasto' }).click();
    const opciones = await laura.getByLabel('Categoría').locator('option').allTextContents();
    if (opciones.includes('Renta') || opciones.includes('Sueldos')) throw new Error('Caja puede elegir renta o sueldos');
    await laura.getByLabel('Categoría').selectOption({ label: 'Garrafones' });
    await laura.getByLabel('¿En qué se gastó?').fill('4 garrafones');
    await laura.getByLabel('Monto $').fill('120');
    await captura(laura, '61-cajero-gasto');
    await laura.getByRole('button', { name: 'Guardar gasto' }).click();
    await laura.getByText('Gasto de $120 registrado').waitFor();
    await fila(laura, '4 garrafones').getByText(/Efectivo de la caja/).waitFor();
  });

  await comprobar('El gasto baja el efectivo esperado de la caja', async () => {
    await laura.getByRole('button', { name: 'Caja', exact: true }).click();
    await laura.getByRole('button', { name: 'Caja y corte' }).click();
    await laura.getByText('Gasto: 4 garrafones').first().waitFor();
  });

  await comprobar('El propietario lo ve al instante y puede anularlo con motivo', async () => {
    await fila(hector, '4 garrafones').getByText(/Laura/).waitFor({ timeout: 8000 });
    await fila(hector, '4 garrafones').getByRole('button', { name: 'Anular 4 garrafones' }).click();
    await hector.getByLabel('Motivo').fill('Se capturó por error');
    await hector.locator('.pane').getByRole('button', { name: 'Anular gasto' }).click();
    await hector.getByText('Gasto anulado').waitFor();
    await fila(hector, '4 garrafones').getByText(/ANULADO: Se capturó por error/).waitFor();
  });

  await comprobar('El reporte muestra ventas, gastos y la utilidad real', async () => {
    await hector.getByRole('button', { name: 'Reportes', exact: true }).click();
    await hector.locator('.kpi', { hasText: 'Gastos' }).getByText('$11,050').waitFor();
    await hector.locator('.kpi', { hasText: 'Utilidad real' }).getByText('-$11,050').waitFor();
    await hector.locator('.fila-barra', { hasText: 'Renta' }).getByText('$8,000').waitFor();
    await hector.locator('.fila-barra', { hasText: 'Sueldos' }).getByText('$2,750').waitFor();
    await captura(hector, '62-reportes');
  });

  await comprobar('El reporte separa los gastos de cada dueño', async () => {
    await hector.locator('.dueno', { hasText: 'Wendy Rivas' }).getByText('$300').first().waitFor();
    await hector.locator('.dueno', { hasText: 'Hector Navarro' }).getByText('$10,750').first().waitFor();
    await hector.locator('.dueno', { hasText: 'Hector Navarro' }).locator('.r', { hasText: 'Renta' }).getByText('$8,000').waitFor();
    await hector.locator('.box', { hasText: 'Gastos por dueño' }).screenshot({ path: `${CAPTURAS}/63-gastos-por-dueno.png` });
  });

  await comprobar('Exportar a Excel descarga el archivo', async () => {
    const [descarga] = await Promise.all([hector.waitForEvent('download'), hector.getByRole('button', { name: 'Exportar a Excel' }).click()]);
    if (!/^la-merced-.*\.csv$/.test(descarga.suggestedFilename())) throw new Error(descarga.suggestedFilename());
  });

  const wendy = await sesion(navegador, 'wendy', CLAVES.wendy);
  await comprobar('Los propietarios reciben aviso del gasto de caja', async () => {
    await wendy.getByRole('button', { name: /Autorizaciones y avisos/ }).click();
    await wendy.getByText(/Registró un gasto de \$120(\.00)? pagado con la caja: 4 garrafones/).first().waitFor();
  });

  await navegador.close();
  console.log(`\n${n - fallas} de ${n} comprobaciones correctas`);
  process.exit(fallas ? 1 : 0);
})();
