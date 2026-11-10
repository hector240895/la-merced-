import { test } from 'node:test';
import assert from 'node:assert/strict';
import { codificar, partir, Documento } from '../src/escpos.mjs';
import { comanda, ticket, corte, precuenta } from '../src/formatos.mjs';

// Convierte los bytes impresos de vuelta a texto legible (sin comandos).
function leer(bytes, tabla = 'cp850') {
  const inverso = new Map();
  for (const c of 'áéíóúÁÉÍÓÚñÑ¿¡ü·×’') { const b = codificar(c, tabla); if (b.length === 1) inverso.set(b[0], c); }
  let s = '';
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    if (b === 0x1c) { i += 1; continue; }   // FS . (sin caracteres chinos)
    if (b === 0x1b || b === 0x1d) { i += (bytes[i + 1] === 0x40 ? 1 : bytes[i + 1] === 0x56 ? 3 : 2); continue; }
    s += b === 0x0a ? '\n' : b < 0x80 ? String.fromCharCode(b) : (inverso.get(b) ?? '?');
  }
  return s;
}

test('acentos y ñ en las dos tablas', () => {
  assert.deepEqual(codificar('áéíóúñÑ¿¡', 'cp850'), [0xa0, 0x82, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa8, 0xad]);
  assert.deepEqual(codificar('áéíóúñÑ¿¡', 'cp1252'), [0xe1, 0xe9, 0xed, 0xf3, 0xfa, 0xf1, 0xd1, 0xbf, 0xa1]);
  assert.deepEqual(codificar('Aguascalientes’n', 'cp850').slice(-2), [0x27, 0x6e], 'el apóstrofo curvo se vuelve recto');
});

test('el texto se parte al ancho del papel', () => {
  assert.deepEqual(partir('Orden de sopes con guisado (3 pz)', 16), ['Orden de sopes', 'con guisado (3', 'pz)']);
});

const COMANDA = {
  documento: 'comanda', tipo: 'nueva', numero: 1, folio: 7, para_llevar: false, destino: 'Mesa 1 + Mesa 2',
  usuario: 'Carlos Pérez', fecha: '08/11/2026', hora: '21:35',
  lineas: [
    { cantidad: 2, producto: 'Pozole rojo chico', opcion: null, observacion: 'Sin lechuga', leyenda: null },
    { cantidad: 1, producto: 'Orden de sopes con guisado (3 pz)', opcion: 'Deshebrada, Pollo, Pollo', observacion: null, leyenda: null },
    { cantidad: 1, producto: 'Refresco de vidrio (355 ml)', opcion: 'Jarrito piña', observacion: null, leyenda: 'CANCELADO' },
  ],
};

test('comanda de cocina: mesa, mesero, guisados, observación destacada, sin precios y con corte', () => {
  const bytes = comanda(COMANDA, { ancho: 48 });
  const t = leer(bytes);
  assert.match(t, /COMANDA/);
  assert.match(t, /Mesa 1 \+ Mesa 2/);
  assert.match(t, /Mesero: Carlos Pérez/);
  assert.match(t, /2 x Pozole rojo chico/);
  assert.match(t, /\*\* SIN LECHUGA \*\*/);
  assert.match(t, /Deshebrada, Pollo, Pollo/);
  assert.match(t, /CANCELADO: 1 x Refresco de vidrio/);
  assert.match(t, /Jarrito piña/);
  assert.doesNotMatch(t, /\$/, 'la comanda no lleva precios');
  assert.deepEqual([...bytes.slice(-4)], [0x1d, 0x56, 0x42, 0x00], 'termina con corte de papel');
  for (const r of t.split('\n')) assert.ok(r.length <= 48, `renglón demasiado largo: "${r}"`);
});

test('comanda para llevar dice el número de pedido', () => {
  const t = leer(comanda({ ...COMANDA, destino: 'PARA LLEVAR', para_llevar: true, folio: 12 }, { ancho: 48 }));
  assert.match(t, /PARA LLEVAR/);
  assert.match(t, /Pedido #12/);
});

test('ticket de 58 mm: solo total, recibido y cambio; sin cortar', () => {
  const bytes = ticket({
    documento: 'ticket', negocio: 'Cenaduría La Merced', leyenda: '¡Gracias por su visita!', folio: 3, para_llevar: false,
    fecha: '08/11/2026', hora: '22:10', total: 100, recibido: 200, cambio: 100,
    lineas: [{ cantidad: 2, producto: 'Café de olla', opcion: null, precio_unitario: 30, importe: 60 }],
    extras: [{ concepto: 'Salsa extra para llevar', importe: 40 }],
  }, { ancho: 32 });
  const t = leer(bytes);
  assert.match(t, /Cenaduría La Merced/);
  assert.match(t, /2 Café de olla\s+\$60/);
  assert.match(t, /TOTAL\s+\$100/);
  assert.match(t, /Recibido\s+\$200/);
  assert.match(t, /Cambio\s+\$100/);
  assert.match(t, /¡Gracias por su visita!/);
  assert.doesNotMatch(t, /Propina|Tarjeta|Efectivo|Mesero/);
  for (const r of t.split('\n')) assert.ok(r.length <= 32, `renglón demasiado largo: "${r}"`);
  assert.notDeepEqual([...bytes.slice(-4)], [0x1d, 0x56, 0x42, 0x00], 'la impresora de caja corta a mano');
});

test('corte de caja: esperado, contado y diferencia', () => {
  const t = leer(corte({ fondo_inicial: 500, ventas_efectivo: 60, ventas_tarjeta: 40, ventas_transferencia: 75, entradas: 0,
    retiros: 30, devoluciones_efectivo: 0, efectivo_esperado: 530, efectivo_contado: 525, diferencia: -5, ventas_total: 175,
    cuentas_cobradas: 2, terminal_esperada: 40, propinas_efectivo: 10, propinas_tarjeta: 0, cajero: 'Laura',
    abierto_en: '08/11/2026 18:00', cerrado_en: '09/11/2026 00:10' }, { ancho: 32 }));
  assert.match(t, /CORTE DE CAJA/);
  assert.match(t, /Efectivo esperado\s+\$530/);
  assert.match(t, /Faltante\s+\$5/);
});

test('precuenta: mesa, productos, total y agradecimiento, en 58 mm', () => {
  const t = leer(precuenta({
    documento: 'precuenta', negocio: 'Cenaduría La Merced', destino: 'Mesa 1', folio: 25, fecha: '08/11/2026', hora: '22:40',
    lineas: [{ cantidad: 2, producto: 'Pozole rojo grande', opcion: null, precio_unitario: 85, importe: 170 },
             { cantidad: 1, producto: 'Refresco de vidrio (355 ml)', opcion: 'Pepsi', precio_unitario: 25, importe: 25 }],
    extras: [], total: 195, leyenda: '¡Gracias por su visita!',
  }, { ancho: 32 }));
  assert.match(t, /Mesa 1/);
  assert.match(t, /Folio 25/);
  assert.match(t, /2 Pozole rojo grande\s+\$170/);
  assert.match(t, /Pepsi/);
  assert.match(t, /TOTAL\s+\$195/);
  assert.match(t, /¡Gracias por su visita!/);
  assert.doesNotMatch(t, /CUENTA INFORMATIVA|NO PAGADA/);
  for (const r of t.split('\n')) assert.ok(r.length <= 32, `renglón demasiado largo: "${r}"`);
});

test('CP1252 apaga el modo de caracteres chinos antes de elegir la tabla; CP850 no cambia', () => {
  const caja = [...new Documento({ tabla: 'cp1252' }).terminar().slice(0, 7)];
  assert.deepEqual(caja, [0x1b, 0x40, 0x1c, 0x2e, 0x1b, 0x74, 16]);
  const cocina = [...new Documento({ tabla: 'cp850' }).terminar().slice(0, 5)];
  assert.deepEqual(cocina, [0x1b, 0x40, 0x1b, 0x74, 2]);
});

test('ticket en CP1252 conserva los acentos', () => {
  const t = leer(ticket({ negocio: 'Cenaduría La Merced', leyenda: '¡Gracias por su visita!', folio: 1, fecha: '10/11/2026', hora: '20:00',
    total: 45, recibido: null, cambio: null, lineas: [{ cantidad: 1, producto: 'Champiñones', importe: 45 }], extras: [] },
    { ancho: 32, tabla: 'cp1252' }), 'cp1252');
  assert.match(t, /Cenaduría La Merced/);
  assert.match(t, /1 Champiñones\s+\$45/);
  assert.match(t, /¡Gracias por su visita!/);
});
