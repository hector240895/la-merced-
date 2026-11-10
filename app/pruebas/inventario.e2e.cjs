// Prueba de la Etapa 8 (inventario) en el navegador, contra Supabase LOCAL.
//   node app/pruebas/inventario.e2e.cjs <carpeta-capturas>
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

const fila = (page, nombre) => page.locator('.box', { hasText: 'Existencias' }).locator('.row').filter({ has: page.locator('b', { hasText: new RegExp(`^${nombre}$`) }) });

(async () => {
  CLAVES.laura = CLAVES.carlos + 'L';
  await crearCuenta('laura', 'Laura', 'cajero', CLAVES.laura);
  const navegador = await chromium.launch();
  const hector = await sesion(navegador, 'hector', CLAVES.hector);
  await hector.getByRole('button', { name: 'Inventario' }).click();

  await comprobar('El propietario agrega un proveedor', async () => {
    await hector.getByRole('button', { name: 'Agregar proveedor' }).click();
    await hector.getByLabel('Nombre del proveedor').fill('Carnicería López');
    await hector.getByLabel('Teléfono (opcional)').fill('33 1234 5678');
    await hector.locator('.pane').getByRole('button', { name: 'Agregar proveedor' }).click();
    await hector.getByText('Proveedor agregado').waitFor();
  });

  await comprobar('Agrega insumos con unidad, mínimo y existencia actual', async () => {
    for (const [nombre, unidad, minimo, inicial] of [['Carne de res', 'kg', '5', '6'], ['Tortilla', 'kg', '10', '4']]) {
      await hector.locator('.box').getByRole('button', { name: 'Agregar insumo' }).click();
      await hector.getByLabel('Nombre del insumo').fill(nombre);
      await hector.getByLabel('Unidad').fill(unidad);
      await hector.getByLabel('Avisar cuando queden').fill(minimo);
      if (nombre === 'Carne de res') await hector.getByLabel('Proveedor habitual').selectOption({ label: 'Carnicería López' });
      await hector.getByLabel('Existencia actual (opcional)').fill(inicial);
      await hector.locator('.pane').getByRole('button', { name: 'Agregar insumo' }).click();
      await hector.getByText('Insumo agregado').first().waitFor();
      await fila(hector, nombre).waitFor();
    }
  });

  await comprobar('El insumo bajo del mínimo se marca y la pestaña muestra el aviso', async () => {
    await fila(hector, 'Tortilla').getByText('4 kg · bajo').waitFor();
    await hector.getByText(/Por surtir: Tortilla/).waitFor();
    await hector.getByRole('button', { name: /^Inventario\s*1$/ }).waitFor();
  });

  const laura = await sesion(navegador, 'laura', CLAVES.laura);
  await laura.getByRole('button', { name: /^Inventario/ }).click();
  await comprobar('El cajero ve existencias pero no puede dar de alta, mermar ni contar', async () => {
    await fila(laura, 'Tortilla').waitFor();
    for (const b of ['Agregar insumo', 'Agregar proveedor', 'Merma de Tortilla', 'Contar Tortilla']) {
      if (await laura.getByRole('button', { name: b }).count()) throw new Error(`El cajero ve "${b}"`);
    }
  });

  await comprobar('El cajero registra una compra de dos insumos', async () => {
    await fila(laura, 'Tortilla').getByRole('button', { name: 'Compra de Tortilla' }).click();
    await laura.getByLabel('Cantidad (kg)').fill('10');
    await laura.getByLabel('Costo total $').fill('250');
    await laura.getByRole('button', { name: 'Agregar otro insumo' }).click();
    await laura.getByLabel('Insumo 2').selectOption({ label: 'Carne de res (kg)' });
    await laura.locator('#c-cant-1').fill('2.5');
    await laura.locator('#c-costo-1').fill('450');
    await laura.getByLabel('Proveedor').selectOption({ label: 'Carnicería López' });
    await laura.getByLabel(/Nota/).fill('Factura 77');
    await laura.getByText('Total: $700').waitFor();
    await captura(laura, '50-cajero-compra');
    await laura.getByRole('button', { name: 'Guardar compra' }).click();
    await laura.getByText('Compra registrada por $700 (también quedó como gasto)').waitFor();
    await fila(laura, 'Tortilla').getByText('14 kg').waitFor();
    await laura.locator('.box', { hasText: 'Lo que registré' }).getByText('Compra · Carne de res').waitFor();
  });

  await comprobar('El aviso de "por surtir" desaparece en vivo para el propietario', async () => {
    await fila(hector, 'Tortilla').getByText('14 kg').waitFor({ timeout: 8000 });
    await hector.getByText(/Por surtir/).waitFor({ state: 'detached' });
  });

  await comprobar('El cajero registra una entrada con su origen', async () => {
    await fila(laura, 'Carne de res').getByRole('button', { name: 'Entrada de Carne de res' }).click();
    await laura.getByLabel('Cantidad (kg)').fill('1');
    await laura.getByLabel('¿De dónde viene?').fill('Sobró del evento');
    await laura.getByRole('button', { name: 'Guardar', exact: true }).click();
    await laura.getByText('Entrada de Carne de res registrada').waitFor();
    await fila(laura, 'Carne de res').getByText('9.5 kg').waitFor();
  });

  await comprobar('El propietario registra una merma con motivo', async () => {
    await fila(hector, 'Carne de res').getByRole('button', { name: 'Merma de Carne de res' }).click();
    await hector.getByLabel('Cantidad (kg)').fill('0.5');
    await hector.getByLabel('Motivo de la merma').fill('Se echó a perder');
    await hector.getByRole('button', { name: 'Guardar', exact: true }).click();
    await hector.getByText('Merma de Carne de res registrada').waitFor();
    await fila(hector, 'Carne de res').getByText('9 kg').waitFor();
  });

  await comprobar('El conteo físico ajusta la diferencia', async () => {
    await fila(hector, 'Carne de res').getByRole('button', { name: 'Contar Carne de res' }).click();
    await hector.getByLabel(/Cuánto contaste/).fill('8.25');
    await hector.getByText('Diferencia: -0.75 kg').waitFor();
    await hector.getByRole('button', { name: 'Guardar', exact: true }).click();
    await hector.getByText('Carne de res ajustado al conteo').waitFor();
    await fila(hector, 'Carne de res').getByText('8.25 kg').waitFor();
  });

  await comprobar('El historial muestra quién, cuánto y el costo de la compra', async () => {
    const mov = hector.locator('.box', { hasText: 'Movimientos' });
    await mov.locator('.row', { hasText: 'Compra · Tortilla' }).getByText('$250').waitFor();
    await mov.locator('.row', { hasText: 'Compra · Tortilla' }).getByText(/Laura · Carnicería López · Factura 77/).waitFor();
    await mov.locator('.row', { hasText: 'Ajuste · Carne de res' }).getByText('-0.75 kg').waitFor();
    await captura(hector, '51-inventario');
  });

  const wendy = await sesion(navegador, 'wendy', CLAVES.wendy);
  await comprobar('Los propietarios reciben aviso de la compra del cajero', async () => {
    await wendy.getByRole('button', { name: /Autorizaciones y avisos/ }).click();
    await wendy.getByText(/Registró una compra de \$700(\.00)? a Carnicería López/).first().waitFor();
  });

  await navegador.close();
  console.log(`\n${n - fallas} de ${n} comprobaciones correctas`);
  process.exit(fallas ? 1 : 0);
})();
