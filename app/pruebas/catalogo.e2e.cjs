// Prueba de la Etapa 7 (catálogo) en el navegador, contra Supabase LOCAL.
//   node app/pruebas/catalogo.e2e.cjs <carpeta-capturas>
const { chromium } = require('playwright');
const { createClient } = require('@supabase/supabase-js');
const path = require('node:path');

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
const fila = (page, nombre) => page.locator('.row').filter({ has: page.locator('b', { hasText: new RegExp(`^${nombre}$`) }) });

(async () => {
  await crearCuenta('carlos', 'Carlos Pérez', 'mesero', CLAVES.carlos);
  const navegador = await chromium.launch();
  const hector = await sesion(navegador, 'hector', CLAVES.hector);
  await hector.getByRole('button', { name: 'Catálogo' }).click();

  await comprobar('El propietario agrega una categoría', async () => {
    await hector.getByLabel('Nombre de la categoría nueva').fill('Especiales');
    await hector.getByRole('button', { name: 'Agregar categoría' }).click();
    await hector.getByText('Categoría agregada').waitFor();
    await hector.locator('.m', { hasText: 'Especiales' }).click();
  });

  await comprobar('Agrega un producto con precio y una opción para elegir', async () => {
    await hector.getByRole('button', { name: 'Agregar producto' }).click();
    await hector.getByLabel('Nombre', { exact: true }).fill('Birria');
    await hector.getByLabel('Precio (con IVA)').fill('120');
    await hector.getByLabel('Descripción (opcional)').fill('Con consomé');
    await hector.getByRole('button', { name: 'Agregar opción para elegir' }).click();
    await hector.getByLabel('Nombre de la opción 1').fill('Tortilla');
    await hector.getByLabel('Lista de la opción 1').fill('Maíz\nHarina');
    await captura(hector, '40-catalogo-formulario');
    await hector.locator('.pane').getByRole('button', { name: 'Agregar producto' }).click();
    await hector.getByText('Producto agregado').waitFor();
    await fila(hector, 'Birria').getByText('$120').waitFor();
  });

  const carlos = await sesion(navegador, 'carlos', CLAVES.carlos, true);
  await comprobar('El mesero ve el producto nuevo con sus opciones', async () => {
    await carlos.locator('.tbl', { hasText: 'Mesa 1' }).click();
    await carlos.getByRole('button', { name: 'Especiales', exact: true }).click();
    await producto(carlos, 'Birria').getByRole('button', { name: '+ Maíz' }).waitFor();
  });

  await comprobar('El propietario cambia el precio y el mesero lo ve al instante', async () => {
    await fila(hector, 'Birria').getByRole('button', { name: 'Editar' }).click();
    await hector.getByLabel('Precio (con IVA)').fill('135');
    await hector.getByRole('button', { name: 'Guardar cambios' }).click();
    await hector.getByText('Producto actualizado').waitFor();
    await producto(carlos, 'Birria').getByText('$135').waitFor({ timeout: 8000 });
  });

  await comprobar('El cambio de precio queda en el historial', async () => {
    await fila(hector, 'Birria').getByRole('button', { name: 'Editar' }).click();
    await hector.getByText(/\$120 → \$135 · Hector Navarro/).waitFor();
    await hector.getByRole('button', { name: 'Cancelar' }).click();
  });

  await comprobar('El mesero marca "se acabó" y el propietario lo ve agotado', async () => {
    await carlos.getByRole('button', { name: 'Marcar agotado Birria' }).click();
    await carlos.getByText('Birria quedó agotado').waitFor();
    await producto(carlos, 'Birria').getByText('Agotado').waitFor();
    await fila(hector, 'Birria').getByText('Agotado').waitFor({ timeout: 8000 });
    await captura(carlos, '41-mesero-agotado');
  });

  await comprobar('El mesero lo vuelve a marcar disponible', async () => {
    await producto(carlos, 'Birria').getByRole('button', { name: 'Marcar disponible' }).click();
    await producto(carlos, 'Birria').getByRole('button', { name: '+ Maíz' }).waitFor();
  });

  await comprobar('El propietario sube una foto (solo se ve en el catálogo)', async () => {
    await fila(hector, 'Birria').getByRole('button', { name: 'Editar' }).click();
    await hector.getByLabel('Foto del producto').setInputFiles(path.join(__dirname, '..', 'public', 'icono-512.png'));
    await hector.getByText('Foto guardada').waitFor();
    await hector.locator('.pane img.foto').waitFor();
    await hector.getByRole('button', { name: 'Cancelar' }).click();
    await fila(hector, 'Birria').locator('img.foto').waitFor();
    if (await producto(carlos, 'Birria').locator('img').count()) throw new Error('El mesero ve la foto');
    await captura(hector, '42-catalogo');
  });

  await comprobar('Duplicar crea una copia', async () => {
    await fila(hector, 'Birria').getByRole('button', { name: 'Duplicar' }).click();
    await fila(hector, 'Birria \\(copia\\)').waitFor();
  });

  await comprobar('Ocultar un producto lo quita del menú del mesero', async () => {
    await fila(hector, 'Birria \\(copia\\)').getByRole('button', { name: 'Ocultar' }).click();
    await hector.getByText('Birria (copia) oculto').waitFor();
    await carlos.locator('.prod h3', { hasText: 'Birria (copia)' }).waitFor({ state: 'detached', timeout: 8000 });
  });

  const wendy = await sesion(navegador, 'wendy', CLAVES.wendy);
  await comprobar('El otro propietario recibe los avisos del catálogo', async () => {
    await wendy.getByRole('button', { name: /Autorizaciones y avisos/ }).click();
    await wendy.getByText(/Cambió Birria: precio de \$120.00 a \$135.00/).first().waitFor();
    await wendy.getByText(/Agregó el producto Birria/).first().waitFor();
  });

  await navegador.close();
  console.log(`\n${n - fallas} de ${n} comprobaciones correctas`);
  process.exit(fallas ? 1 : 0);
})();
