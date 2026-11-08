// Prueba de la Etapa 5 en el navegador, contra Supabase LOCAL: abrir caja,
// pedido para llevar desde el celular, cobro combinado con cambio y propina,
// cobrar una mesa, retiro, corte, aprobación y devolución autorizada.
//
//   node app/pruebas/caja.e2e.cjs <carpeta-capturas>
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

const tarjeta = (page, nombre) => page.locator('.tcard').filter({ has: page.locator('b', { hasText: new RegExp(`^${nombre}$`) }) });
const cuenta = (page, texto) => page.locator('.acc', { hasText: texto });

(async () => {
  CLAVES.laura = CLAVES.carlos + 'L';
  await crearCuenta('carlos', 'Carlos Pérez', 'mesero', CLAVES.carlos);
  await crearCuenta('laura', 'Laura', 'cajero', CLAVES.laura);
  const navegador = await chromium.launch();

  // ---------------------------------------------------------------- Abrir caja
  const laura = await sesion(navegador, 'laura', CLAVES.laura);
  await comprobar('La cajera entra y la caja está cerrada', async () => {
    await laura.getByText('Laura · Cajero').waitFor();
    await laura.getByText('Caja cerrada').waitFor();
  });
  await comprobar('La cajera abre caja con $500', async () => {
    await laura.getByRole('button', { name: 'Caja y corte' }).click();
    await laura.getByLabel('Fondo inicial').fill('500');
    await laura.getByRole('button', { name: 'Abrir caja', exact: true }).click();
    await laura.getByText('Caja abierta', { exact: true }).waitFor();
    await laura.getByRole('button', { name: 'Cobrar', exact: true }).click();
  });

  // ---------------------------------------------------------------- Para llevar desde el celular
  const carlos = await sesion(navegador, 'carlos', CLAVES.carlos, true);
  await comprobar('El mesero captura un pedido para llevar y lo envía a cocina', async () => {
    await carlos.getByRole('button', { name: 'Nuevo para llevar' }).click();
    await carlos.getByRole('button', { name: 'Bebidas', exact: true }).click();
    await carlos.getByRole('button', { name: 'Agregar Café de olla', exact: true }).click();
    await carlos.getByRole('button', { name: 'Agregar Café de olla', exact: true }).click();
    await carlos.getByRole('button', { name: /Revisar pedido · 2 productos/ }).click();
    await carlos.getByRole('button', { name: 'Enviar a cocina' }).click();
    await carlos.getByText('Pedido enviado. La comanda va a la impresora de cocina.').waitFor();
    await carlos.getByRole('button', { name: 'Para llevar #1' }).waitFor();
    await captura(carlos, '20-mesero-para-llevar');
  });

  // ---------------------------------------------------------------- Cobro combinado
  await comprobar('Caja ve el pedido para llevar al instante', async () => {
    await cuenta(laura, 'Para llevar #1').waitFor({ timeout: 8000 });
    await cuenta(laura, 'Para llevar #1').click();
    await laura.getByText('2 × Café de olla').waitFor();
  });
  await comprobar('Cobro extra con comentario: el total sube a $100', async () => {
    await laura.getByLabel('Concepto del cobro extra').fill('Salsa extra para llevar');
    await laura.getByLabel('Monto del cobro extra').fill('40');
    await laura.getByRole('button', { name: 'Agregar cobro extra' }).click();
    await laura.locator('.grande', { hasText: '$100' }).waitFor();
  });
  await comprobar('Pago combinado: $60 efectivo (paga con $100, deja $10 de propina) y $40 con tarjeta; cambio $30', async () => {
    await laura.getByRole('button', { name: 'Efectivo', exact: true }).click();
    await laura.getByLabel('Monto del pago').fill('60');
    await laura.getByLabel('Efectivo recibido').fill('100');
    await laura.getByRole('button', { name: 'Agregar pago' }).click();
    await laura.getByText('Falta $40').waitFor();
    await laura.getByRole('button', { name: 'Tarjeta', exact: true }).click();
    await laura.getByRole('button', { name: 'Agregar pago' }).click();
    await laura.getByText('Cuenta cubierta').waitFor();
    await laura.getByLabel('Propina', { exact: true }).fill('10');
    await laura.getByLabel('Método de la propina').selectOption('efectivo');
    await laura.locator('.rem', { hasText: 'Cambio: $30' }).waitFor();
    await captura(laura, '21-caja-cobro');
    await laura.getByRole('button', { name: 'Cobrar e imprimir ticket' }).click();
  });
  await comprobar('Sale el ticket con el negocio, la dirección, el total y el cambio', async () => {
    const papel = laura.locator('.papel');
    await laura.locator('.cambio-grande', { hasText: 'Cambio: $30' }).waitFor();
    await papel.getByText('Cenaduría La Merced').waitFor();
    await papel.getByText('Av. Fundición 2103, San Cayetano, 20010 Aguascalientes, Ags.').waitFor();
    await papel.getByText('Tel. 449 940 44 90 / 449 181 31 21').waitFor();
    await papel.locator('.t-total', { hasText: '$100' }).waitFor();
    await papel.getByText('Extra: Salsa extra para llevar').waitFor();
    await captura(laura, '22-ticket');
    await laura.getByRole('button', { name: 'Cerrar' }).click();
    await cuenta(laura, 'Para llevar #1').getByText('Cobrada').waitFor();
  });

  // ---------------------------------------------------------------- Cobrar una mesa
  await comprobar('Una mesa se cobra cuando el mesero pide la cuenta, y queda libre', async () => {
    await tarjeta(carlos, 'Mesa 1').locator('.tbl').click();
    await carlos.getByRole('button', { name: 'Agregar Pozole rojo chico', exact: true }).click();
    await carlos.getByRole('button', { name: /Revisar pedido/ }).click();
    await carlos.getByRole('button', { name: 'Enviar a cocina' }).click();
    await carlos.getByText('Pedido enviado').first().waitFor();
    await cuenta(laura, 'Mesa 1').waitFor({ timeout: 8000 });
    await cuenta(laura, 'Mesa 1').click();
    await laura.getByText('El cobro se habilita cuando el mesero pide la cuenta.').waitFor();
    await tarjeta(carlos, 'Mesa 1').locator('.tbl').click();
    await carlos.getByRole('button', { name: /Revisar pedido/ }).click();
    await carlos.getByRole('button', { name: 'Pedir la cuenta' }).click();
    await cuenta(laura, 'Mesa 1').getByText('Por cobrar').waitFor({ timeout: 8000 });
    await laura.getByRole('button', { name: 'Transferencia', exact: true }).click();
    await laura.getByRole('button', { name: 'Agregar pago' }).click();
    await laura.getByRole('button', { name: 'Cobrar e imprimir ticket' }).click();
    await laura.getByText('Cobrado. Mesa 1 queda libre.').waitFor();
    await laura.getByRole('button', { name: 'Cerrar' }).click();
    await tarjeta(carlos, 'Mesa 1').getByText('Disponible').waitFor({ timeout: 8000 });
  });

  // ---------------------------------------------------------------- Retiro y corte
  await comprobar('Retiro con motivo y corte: esperado $530 = $500 + $60 − $30 (sin propinas)', async () => {
    await laura.getByRole('button', { name: 'Caja y corte' }).click();
    await laura.getByLabel('Monto del movimiento').fill('30');
    await laura.getByLabel('Motivo del movimiento').fill('Compra de hielo');
    await laura.getByRole('button', { name: 'Registrar' }).click();
    await laura.getByText('Retiro · Compra de hielo').waitFor();
    await laura.locator('.r.s', { hasText: '$530' }).waitFor();
    await laura.getByLabel('Efectivo contado').fill('530');
    await laura.getByText('Caja cuadrada: sin diferencia.').waitFor();
    await captura(laura, '23-corte');
    await laura.getByRole('button', { name: 'Realizar corte y enviar al propietario' }).click();
    await laura.getByText('Corte guardado y enviado al propietario para su aprobación.').waitFor();
    await laura.getByText('Caja cerrada').waitFor();
  });

  // ---------------------------------------------------------------- Propietarios
  const hector = await sesion(navegador, 'hector', CLAVES.hector);
  await comprobar('El propietario aprueba el corte', async () => {
    await hector.getByRole('button', { name: 'Cortes y ventas' }).click();
    await hector.getByText('Por aprobar').waitFor();
    await hector.getByRole('button', { name: 'Aprobar corte' }).click();
    await hector.getByText('Corte aprobado').waitFor();
    await hector.locator('.row', { hasText: 'Cajero: Laura' }).getByText('Aprobado').waitFor();
  });
  await comprobar('Quitar un producto cobrado pide autorización y cómo devolver el dinero', async () => {
    await hector.locator('.row', { hasText: 'Mesa 1 · Folio 2' }).getByRole('button', { name: 'Quitar producto' }).click();
    await hector.getByLabel('Producto a quitar').selectOption({ label: '1 × Pozole rojo chico · $75' });
    await hector.getByLabel('Cómo se devuelve el dinero').selectOption('transferencia');
    await hector.getByLabel('Motivo de la solicitud').fill('El pozole no se sirvió');
    await hector.getByRole('button', { name: 'Enviar solicitud' }).click();
    await hector.getByText('Solicitud enviada al otro propietario').waitFor();
    await captura(hector, '24-cortes-ventas');
  });
  const wendy = await sesion(navegador, 'wendy', CLAVES.wendy);
  await comprobar('El otro propietario aprueba y la devolución queda registrada', async () => {
    await wendy.getByRole('button', { name: /Autorizaciones y avisos/ }).click();
    await wendy.getByText('Devolución al cliente: Transferencia').waitFor();
    await wendy.getByRole('button', { name: 'Aprobar' }).click();
    await wendy.locator('.row', { hasText: 'Quitar producto de cuenta cobrada' }).getByText('Aprobada').waitFor();
    await wendy.getByText(/Devolución al cliente por concepto quitado/).first().waitFor();
  });

  await navegador.close();
  console.log(`\n${n - fallas} de ${n} comprobaciones correctas`);
  process.exit(fallas ? 1 : 0);
})();
