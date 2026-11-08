// Prueba de la app en el navegador (Etapa 3), contra Supabase LOCAL.
// Requiere: supabase start, la app en http://localhost:5173 (npm run dev) y
// las cuentas hector / wendy creadas por scripts/probar-etapa3-preparar.mjs.
// FUNCIONES_URL permite apuntar admin-usuarios a otro servidor local.
//
//   node app/pruebas/salon.e2e.cjs <carpeta-capturas>
const { chromium } = require('playwright');
const { createClient } = require('@supabase/supabase-js');

const APP = process.env.APP_URL ?? 'http://localhost:5173';
const FUNCIONES = process.env.FUNCIONES_URL;
const CLAVES = JSON.parse(process.env.CLAVES_PRUEBA);
const CAPTURAS = process.argv[2];

// Hace las veces del servicio de impresión de caja (Etapa 6): informa
// "impresa" o "error" de la última comanda de una mesa.
async function informarImpresion(destino, tipo, impreso, error) {
  const c = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  await c.auth.signInWithPassword({ email: 'hector@lamerced.local', password: CLAVES.hector });
  const { data } = await c.from('trabajos_impresion').select('id, contenido').eq('estado', 'pendiente').order('creado_en', { ascending: false });
  const t = data.find((x) => x.contenido.destino === destino && x.contenido.tipo === tipo);
  if (!t) throw new Error(`No hay comanda ${tipo} pendiente de ${destino}`);
  const r = await c.rpc('reportar_impresion', { p_trabajo_id: t.id, p_impreso: impreso, p_error: error ?? null });
  if (r.error) throw new Error(r.error.message);
}

let n = 0;
let fallas = 0;
async function comprobar(descripcion, fn) {
  n += 1;
  try { await fn(); console.log(`ok ${n} - ${descripcion}`); }
  catch (e) { fallas += 1; console.log(`not ok ${n} - ${descripcion}\n   ${String(e.message).split('\n')[0]}`); }
}
const captura = (page, nombre) => CAPTURAS && page.screenshot({ path: `${CAPTURAS}/${nombre}.png`, fullPage: true });

async function nuevaSesion(navegador, usuario, contrasena, movil) {
  const ctx = await navegador.newContext(movil
    ? { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }
    : { viewport: { width: 1280, height: 860 } });
  if (FUNCIONES) {
    await ctx.route('**/functions/v1/admin-usuarios', async (ruta) => {
      const respuesta = await ruta.fetch({ url: FUNCIONES });
      await ruta.fulfill({ response: respuesta });
    });
  }
  const page = await ctx.newPage();
  page.on('pageerror', (e) => console.log(`   [error en la página de ${usuario}] ${e.message}`));
  await page.goto(APP);
  await page.getByLabel('Usuario').fill(usuario);
  await page.getByLabel('Contraseña').fill(contrasena);
  await page.getByRole('button', { name: 'Entrar' }).click();
  return page;
}

const tarjeta = (page, nombre) => page.locator('.tcard').filter({ has: page.locator('b', { hasText: new RegExp(`^${nombre}$`) }) });
const producto = (page, nombre) => page.locator('.prod').filter({ has: page.locator('h3', { hasText: nombre }) });

(async () => {
  const navegador = await chromium.launch();

  // ---------------------------------------------------------------- Propietario
  const hector = await nuevaSesion(navegador, 'hector', CLAVES.hector);
  await comprobar('Hector entra y ve el panel de propietario', async () => {
    await hector.getByRole('button', { name: 'Usuarios' }).waitFor();
    await hector.getByText('Hector Navarro · Propietario').waitFor();
  });
  await comprobar('Contraseña equivocada muestra el error', async () => {
    const ctx = await navegador.newContext();
    const p = await ctx.newPage();
    await p.goto(APP);
    await p.getByLabel('Usuario').fill('hector');
    await p.getByLabel('Contraseña').fill('equivocada123');
    await p.getByRole('button', { name: 'Entrar' }).click();
    await p.getByText('Usuario o contraseña incorrectos.').waitFor();
    await captura(p, '01-inicio-sesion-error');
    await ctx.close();
  });

  await hector.getByRole('button', { name: 'Usuarios' }).click();
  await comprobar('Hector agrega al mesero Carlos desde Usuarios', async () => {
    await hector.getByLabel('Nombre', { exact: true }).fill('Carlos Pérez');
    await hector.getByLabel('Usuario', { exact: true }).fill('carlos');
    await hector.getByLabel('Contraseña inicial').fill(CLAVES.carlos);
    await hector.getByRole('button', { name: 'Agregar', exact: true }).click();
    await hector.locator('.row', { hasText: 'Carlos Pérez' }).waitFor();
    await captura(hector, '02-propietario-usuarios');
  });
  await hector.getByRole('button', { name: 'Salón' }).click();
  await hector.getByText('Mesa 7').waitFor();

  // ---------------------------------------------------------------- Mesero
  const carlos = await nuevaSesion(navegador, 'carlos', CLAVES.carlos, true);
  await comprobar('Carlos entra desde el celular y ve las 7 mesas', async () => {
    await carlos.getByText('Carlos Pérez · Mesero').waitFor();
    if ((await carlos.locator('.tcard').count()) !== 7) throw new Error('No hay 7 mesas');
    await captura(carlos, '03-mesero-mesas');
  });

  await comprobar('Carlos toma el pedido de la Mesa 1: cada pieza con su observación', async () => {
    await tarjeta(carlos, 'Mesa 1').locator('.tbl').click();
    const agregar = (nombre) => carlos.getByRole('button', { name: `Agregar ${nombre}`, exact: true }).click();
    await agregar('Pozole rojo chico');
    await agregar('Pozole rojo chico');
    for (const [n, nota] of [[1, 'Sin lechuga'], [2, 'Sin cebolla']]) {
      await carlos.getByRole('button', { name: `Agregar observación de Pozole rojo chico ${n}` }).click();
      await carlos.getByLabel(`Observación para Pozole rojo chico ${n}`).fill(nota);
      await carlos.getByRole('button', { name: 'Guardar' }).click();
    }
    await carlos.getByRole('button', { name: 'Bebidas', exact: true }).click();
    await producto(carlos, 'Refresco de vidrio (355 ml)').getByRole('button', { name: '+ Jarrito tamarindo' }).click();
    await producto(carlos, 'Agua de sabor (500 ml)').getByRole('button', { name: '+ Jamaica' }).click();
    await producto(carlos, 'Agua de sabor (500 ml)').getByRole('button', { name: '+ Jamaica' }).click();
    await captura(carlos, '04b-mesero-sabores');
    await carlos.getByRole('button', { name: 'Pozole', exact: true }).click();
    await captura(carlos, '04-mesero-pedido');
    await carlos.getByRole('button', { name: /Revisar pedido · 5 productos/ }).click();
    await carlos.locator('.pane').getByText('Sin lechuga').waitFor();
    await carlos.locator('.pane').getByText('Sin cebolla').waitFor();
    await carlos.locator('.pane').getByText('1 × Refresco de vidrio (355 ml) · Jarrito tamarindo').waitFor();
    if ((await carlos.locator('.pane .li', { hasText: '1 × Agua de sabor (500 ml) · Jamaica' }).count()) !== 2) {
      throw new Error('Cada agua debería aparecer por separado');
    }
    await captura(carlos, '05-mesero-revisar');
    await carlos.getByRole('button', { name: 'Enviar a cocina' }).click();
    await carlos.getByText('Pedido enviado. La comanda va a la impresora de cocina.').waitFor();
    await tarjeta(carlos, 'Mesa 1').getByText('Pedido enviado').waitFor();
    await tarjeta(carlos, 'Mesa 1').getByText('5 productos · $225').waitFor();
    await captura(carlos, '06-mesero-enviado');
  });

  await comprobar('Hector ve la Mesa 1 con pedido enviado al instante, sin recargar', async () => {
    await tarjeta(hector, 'Mesa 1').getByText('Pedido enviado').waitFor({ timeout: 8000 });
  });

  await comprobar('La comanda queda pendiente de imprimir y se ve sin precios', async () => {
    await tarjeta(carlos, 'Mesa 1').getByText('Pendiente de imprimir').waitFor();
    await tarjeta(carlos, 'Mesa 1').locator('.tbl').click();
    await carlos.getByRole('button', { name: /Revisar pedido/ }).click();
    await carlos.getByText('Comandas a cocina').waitFor();
    await carlos.locator('.cmd').getByRole('button', { name: 'Ver' }).click();
    const papel = carlos.locator('.papel');
    await papel.getByText('Mesa 1', { exact: true }).waitFor();
    await papel.getByText('Mesero: Carlos Pérez').waitFor();
    await papel.locator('.p-obs', { hasText: /sin lechuga/i }).waitFor();
    await papel.locator('.p-opcion', { hasText: 'Jarrito tamarindo' }).waitFor();
    if ((await papel.innerText()).includes('$')) throw new Error('La comanda muestra precios');
    await captura(carlos, '05b-comanda-vista-previa');
    await carlos.getByRole('button', { name: 'Cerrar' }).click();
    await carlos.getByRole('button', { name: 'Seguir pidiendo' }).click();
    await carlos.getByRole('button', { name: '‹ Mesas' }).click();
  });

  await comprobar('Cuando caja informa que se imprimió, el mesero lo ve al instante', async () => {
    await informarImpresion('Mesa 1', 'nueva', true);
    await tarjeta(carlos, 'Mesa 1').getByText('✓ Comanda impresa').waitFor({ timeout: 8000 });
  });

  await comprobar('Pedido adicional con guisados elegidos: no se envía hasta elegirlos todos', async () => {
    await tarjeta(carlos, 'Mesa 1').locator('.tbl').click();
    await carlos.getByRole('button', { name: 'Postres', exact: true }).click();
    await carlos.getByRole('button', { name: 'Agregar Jericallas', exact: true }).click();
    await carlos.getByRole('button', { name: 'Sopes', exact: true }).click();
    await carlos.getByRole('button', { name: 'Agregar Orden de sopes con guisado (3 pz)', exact: true }).click();
    await carlos.getByRole('button', { name: /Revisar pedido · 7 productos/ }).click();
    await carlos.locator('.pane').getByText('Falta elegir guisado en Orden de sopes con guisado (3 pz).').waitFor();
    if (!(await carlos.getByRole('button', { name: 'Enviar a cocina' }).isDisabled())) throw new Error('Se puede enviar sin guisados');
    await carlos.getByRole('button', { name: 'Seguir pidiendo' }).click();
    for (const [k, g] of [[1, 'Deshebrada'], [2, 'Pollo'], [3, 'Pollo']]) {
      await carlos.getByLabel(`guisado ${k} de Orden de sopes con guisado (3 pz) 1`).selectOption(g);
    }
    await captura(carlos, '04c-mesero-guisados');
    await carlos.getByRole('button', { name: /Revisar pedido · 7 productos/ }).click();
    await carlos.locator('.pane').getByText('1 × Orden de sopes con guisado (3 pz) · Deshebrada, Pollo, Pollo').waitFor();
    await carlos.getByText('Nueva comanda').waitFor();
    await carlos.getByText('Ya enviado a cocina').waitFor();
    await carlos.getByRole('button', { name: 'Enviar a cocina' }).click();
    await carlos.getByText('Pedido adicional enviado. La comanda va a la impresora de cocina.').waitFor();
    await tarjeta(carlos, 'Mesa 1').getByText('7 productos · $355').waitFor();
  });

  await comprobar('Si la comanda falla, el mesero ve el error y la reintenta', async () => {
    await informarImpresion('Mesa 1', 'adicional', false, 'Sin papel');
    await tarjeta(carlos, 'Mesa 1').getByText('Error de impresión').waitFor({ timeout: 8000 });
    await tarjeta(carlos, 'Mesa 1').locator('.tbl').click();
    await carlos.getByText('Una comanda no se imprimió').waitFor();
    await captura(carlos, '06b-error-impresion');
    await carlos.getByRole('button', { name: 'Reintentar impresión' }).click();
    await carlos.getByText('Comanda enviada de nuevo a la impresora').waitFor();
    await carlos.getByRole('button', { name: '‹ Mesas' }).click();
    await tarjeta(carlos, 'Mesa 1').getByText('Pendiente de imprimir').waitFor();
    await informarImpresion('Mesa 1', 'adicional', true);
  });

  await comprobar('Caja y propietarios ven la cola de comandas; se puede reimprimir', async () => {
    await hector.getByRole('button', { name: 'Comandas', exact: true }).click();
    await hector.getByText('Impresas recientemente').waitFor();
    await hector.locator('.cmd', { hasText: 'Mesa 1 · Comanda 1' }).getByRole('button', { name: 'Reimprimir' }).click();
    await hector.getByText('Reimpresión enviada a cocina').waitFor();
    await hector.locator('.cmd', { hasText: '(reimpresión de Hector Navarro)' }).first().waitFor();
    await captura(hector, '06c-propietario-comandas');
    await hector.getByRole('button', { name: 'Salón' }).click();
  });

  await comprobar('Carlos une la Mesa 1 con la Mesa 2', async () => {
    await carlos.getByRole('button', { name: 'Unir mesas' }).click();
    await tarjeta(carlos, 'Mesa 2').locator('.tbl').click();
    await tarjeta(carlos, 'Mesa 1').locator('.tbl').click();
    await carlos.getByRole('button', { name: 'Unir 2 mesas' }).click();
    await carlos.getByText('Mesa 1 + Mesa 2').waitFor();
    await captura(carlos, '07-mesero-unidas');
  });

  await comprobar('Carlos quita una de dos aguas iguales con motivo; queda tachada y el total baja', async () => {
    await carlos.locator('.tbl', { hasText: 'Mesa 1 + Mesa 2' }).click();
    await carlos.getByRole('button', { name: /Revisar pedido/ }).click();
    await carlos.locator('.li', { hasText: '2 × Agua de sabor (500 ml) · Jamaica' }).getByRole('button', { name: 'Quitar' }).click();
    await carlos.getByLabel('Motivo').fill('Una no se llevó al cliente');
    await carlos.getByLabel('Cantidad a quitar').selectOption('1');
    await carlos.getByRole('button', { name: 'Confirmar' }).click();
    await carlos.getByText('Quitados').waitFor();
    await carlos.locator('.li.tachado', { hasText: '1 × Agua de sabor (500 ml) · Jamaica' }).waitFor();
    await carlos.locator('.li.old', { hasText: '1 × Agua de sabor (500 ml) · Jamaica' }).waitFor();
    await carlos.locator('.tot', { hasText: '$330' }).waitFor();
    await captura(carlos, '08-mesero-quitar');
  });

  await comprobar('Carlos pide la cuenta y la mesa queda por cobrar y bloqueada', async () => {
    await carlos.getByRole('button', { name: 'Pedir la cuenta' }).click();
    await carlos.getByText('Cuenta solicitada. Avisa al cajero.').waitFor();
    await carlos.locator('.tcard', { hasText: 'Mesa 1 + Mesa 2' }).getByText('Por cobrar').waitFor();
    await carlos.locator('.tbl', { hasText: 'Mesa 1 + Mesa 2' }).click();
    await carlos.getByText('El cajero registrará el cobro').waitFor();
    await carlos.getByRole('button', { name: '‹ Mesas' }).click();
  });

  await comprobar('Abrir una mesa y salir sin pedir la deja disponible otra vez', async () => {
    await tarjeta(carlos, 'Mesa 3').locator('.tbl').click();
    await carlos.getByRole('button', { name: '‹ Mesas' }).click();
    await tarjeta(carlos, 'Mesa 3').getByText('Disponible').waitFor();
  });

  // ---------------------------------------------------------------- Administración de mesas
  await comprobar('Plato Aguascalientes’n: guisado del sope, de la quesadillita y pata o cueritos; taco de guisado', async () => {
    await tarjeta(carlos, 'Mesa 4').locator('.tbl').click();
    await carlos.getByRole('button', { name: 'Antojitos', exact: true }).click();
    await carlos.getByRole('button', { name: 'Agregar Plato Aguascalientes’n', exact: true }).click();
    await carlos.getByLabel('guisado del sope de Plato Aguascalientes’n 1').selectOption('Champiñones');
    await carlos.getByLabel('guisado de la quesadillita de Plato Aguascalientes’n 1').selectOption('Requesón con rajas');
    await carlos.getByLabel('pata o cueritos de Plato Aguascalientes’n 1').selectOption('Cueritos');
    await captura(carlos, '04d-plato-aguascalientes');
    await carlos.getByRole('button', { name: 'Extras', exact: true }).click();
    await producto(carlos, 'Taco de guisado').getByRole('button', { name: '+ Papas con chorizo' }).click();
    await carlos.getByRole('button', { name: /Revisar pedido · 2 productos/ }).click();
    await carlos.locator('.pane').getByText(
      '1 × Plato Aguascalientes’n · Guisado del sope: Champiñones, Guisado de la quesadillita: Requesón con rajas, Pata o cueritos: Cueritos').waitFor();
    await carlos.locator('.pane').getByText('1 × Taco de guisado · Papas con chorizo').waitFor();
    await carlos.getByRole('button', { name: 'Enviar a cocina' }).click();
    await carlos.getByText('Pedido enviado. La comanda va a la impresora de cocina.').waitFor();
    await tarjeta(carlos, 'Mesa 4').getByText('2 productos · $167').waitFor();
  });

  await hector.getByRole('button', { name: 'Mesas', exact: true }).click();
  await comprobar('Hector agrega la mesa Terraza', async () => {
    await hector.getByLabel('Nombre de la mesa nueva').fill('Terraza');
    await hector.getByRole('button', { name: 'Agregar mesa' }).click();
    await hector.locator('.row', { hasText: 'Terraza' }).waitFor();
  });
  await comprobar('Carlos ve la mesa nueva en su celular sin recargar', async () => {
    await tarjeta(carlos, 'Terraza').waitFor({ timeout: 8000 });
  });
  await comprobar('No se puede desactivar una mesa con cuenta abierta', async () => {
    await hector.locator('.row', { hasText: 'cuenta folio' }).first().getByRole('button', { name: 'Desactivar' }).click();
    await hector.getByText(/está en servicio|cuenta abierta/).waitFor();
  });
  await comprobar('Hector solicita cancelar la cuenta de la Mesa 1', async () => {
    await hector.locator('.row', { hasText: 'cuenta folio' }).first().getByRole('button', { name: 'Solicitar cancelar cuenta' }).click();
    await hector.getByLabel('Motivo de la cancelación').fill('Prueba: el cliente se fue');
    await hector.getByRole('button', { name: 'Enviar solicitud' }).click();
    await hector.getByText('Solicitud enviada al otro propietario').waitFor();
    await captura(hector, '09-propietario-mesas');
  });
  await comprobar('Hector no puede aprobar su propia solicitud', async () => {
    await hector.getByRole('button', { name: /Autorizaciones y avisos/ }).click();
    await hector.getByText('Esperando al otro propietario').waitFor();
    if (await hector.getByRole('button', { name: 'Aprobar' }).count()) throw new Error('Aparece el botón Aprobar');
  });

  // ---------------------------------------------------------------- Otro propietario
  const wendy = await nuevaSesion(navegador, 'wendy', CLAVES.wendy);
  await comprobar('Wendy ve el contador de pendientes y los avisos de Hector', async () => {
    await wendy.locator('.nav .num').waitFor();
    await wendy.getByRole('button', { name: /Autorizaciones y avisos/ }).click();
    await wendy.getByText(/Agregó la mesa Terraza/).first().waitFor();
    await wendy.getByText(/Creó la cuenta de Carlos Pérez/).first().waitFor();
    await captura(wendy, '10-propietario-autorizaciones');
  });
  await comprobar('Wendy aprueba y la mesa queda libre en el celular del mesero', async () => {
    await wendy.getByRole('button', { name: 'Aprobar' }).click();
    await wendy.locator('.row', { hasText: 'Cancelar cuenta' }).getByText('Aprobada').waitFor();
    await tarjeta(carlos, 'Mesa 1').getByText('Disponible').waitFor({ timeout: 8000 });
    await tarjeta(carlos, 'Mesa 2').getByText('Disponible').waitFor();
    await captura(carlos, '11-mesero-tras-cancelacion');
  });

  // ---------------------------------------------------------------- Baja
  await comprobar('Hector da de baja a Carlos y su celular pierde el acceso', async () => {
    await hector.getByRole('button', { name: 'Usuarios' }).click();
    await hector.locator('.row', { hasText: 'Carlos Pérez' }).getByRole('button', { name: 'Dar de baja' }).click();
    await hector.getByLabel('Motivo de la baja (obligatorio)').fill('Prueba de baja');
    await hector.getByRole('button', { name: 'Confirmar baja' }).click();
    await hector.locator('.row', { hasText: 'Carlos Pérez' }).getByText('De baja').waitFor();
    await carlos.reload();
    await carlos.getByRole('button', { name: 'Entrar' }).waitFor({ timeout: 8000 });
  });

  await navegador.close();
  console.log(`\n${n - fallas} de ${n} comprobaciones correctas`);
  process.exit(fallas ? 1 : 0);
})();
