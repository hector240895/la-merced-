// Cómo se ve en papel cada documento: comanda (cocina, 80 mm), ticket y
// corte (caja, 58 mm). Reciben el "contenido" que arma la base de datos.
import { Documento, partir } from './escpos.mjs';

const dinero = (n) => '$' + Number(n ?? 0).toLocaleString('es-MX', { minimumFractionDigits: 0, maximumFractionDigits: 2 });

const TITULO_COMANDA = { nueva: 'COMANDA', adicional: 'COMANDA ADICIONAL', cancelacion: 'AVISO DE CANCELACIÓN', modificacion: 'MODIFICACION' };

export function comanda(c, opciones) {
  const d = new Documento(opciones);
  d.alinear('centro');
  if (c.reimpresion) d.negrita(true).linea(`*** REIMPRESIÓN ${c.hora_reimpresion ?? ''} ***`).negrita(false);
  d.negrita(true).linea(TITULO_COMANDA[c.tipo] ?? 'COMANDA').negrita(false);
  d.tamano(2).negrita(true).parrafo(c.destino, Math.floor(d.ancho / 2)).negrita(false).tamano(1);
  if (c.para_llevar) d.tamano(2).linea(`Pedido #${c.folio}`).tamano(1);
  d.linea(`Comanda ${c.numero} - ${c.fecha} ${c.hora}`);
  d.linea(`${c.tipo === 'cancelacion' ? 'Canceló' : 'Mesero'}: ${c.usuario}`);
  d.alinear('izquierda').separador('=');
  for (const l of c.lineas ?? []) {
    d.tamano('alto').negrita(true);
    d.parrafo(`${l.leyenda ? l.leyenda + ': ' : ''}${l.cantidad} x ${l.producto}`);
    d.negrita(false).tamano(1);
    if (l.opcion) d.parrafo(l.opcion, d.ancho, '    ');
    if (l.observacion) d.negrita(true).parrafo(`** ${String(l.observacion).toUpperCase()} **`, d.ancho, '    ').negrita(false);
    d.linea();
  }
  d.separador('=').alinear('centro').linea(`Folio ${c.folio}`);
  return d.terminar();
}

const pesos = (n) => '$' + Number(n ?? 0).toLocaleString('es-MX', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const mayus = (t) => String(t ?? '').toLocaleUpperCase('es-MX');

// Ticket de cobro, al estilo de ticket de tienda: datos del negocio, folio,
// fecha y hora, mesa, tabla CANT / DESCRIPCION / IMPORTE, total, importe con
// letra y "Este no es un comprobante fiscal".
export function ticket(t, opciones) {
  const d = new Documento({ cortar: false, ...opciones });
  const anchoCant = 3;
  // Cantidad, descripción (se parte si no cabe) e importe pegado a la derecha.
  const fila = (cant, desc, imp) => {
    const anchoDesc = d.ancho - anchoCant - imp.length - 1;
    const renglones = partir(mayus(desc), anchoDesc);
    renglones.forEach((r, i) => d.linea(i === 0
      ? String(cant).padEnd(anchoCant) + r.padEnd(anchoDesc) + ' ' + imp
      : ' '.repeat(anchoCant) + r));
  };

  d.alinear('centro');
  if (t.reimpresion) d.linea('*** REIMPRESIÓN ***');
  d.negrita(true).parrafo(mayus(t.negocio)).negrita(false);
  if (t.direccion) d.parrafo(mayus(t.direccion));
  // Cada teléfono en su renglón para que no se corte a la mitad.
  String(t.telefonos ?? '').split('/').map((x) => x.trim()).filter(Boolean)
    .forEach((tel, i) => d.linea(`${i === 0 ? 'TEL. ' : ''}${tel}`));
  d.separador('=');
  d.negrita(true).linea(`FOLIO NO. ${t.folio}`).negrita(false);
  d.linea(`${t.fecha} ${t.hora}`);
  const destino = t.destino ?? (t.para_llevar ? 'Para llevar' : null);
  if (destino) d.negrita(true).parrafo(mayus(destino)).negrita(false);
  d.separador('=');

  d.alinear('izquierda');
  d.dosColumnas('CANT DESCRIPCION', 'IMPORTE');
  for (const l of t.lineas ?? []) fila(l.cantidad, l.producto, pesos(l.importe));
  for (const x of t.extras ?? []) fila(1, `Extra: ${x.concepto}`, pesos(x.importe));
  d.linea();

  d.alinear('derecha');
  d.negrita(true).tamano('alto').linea(`TOTAL: ${pesos(t.total)}`).tamano(1).negrita(false);
  if (t.recibido != null) d.linea(`RECIBIDO: ${pesos(t.recibido)}`);
  if (t.cambio != null) d.linea(`CAMBIO: ${pesos(t.cambio)}`);

  d.alinear('centro');
  if (t.total_letra) d.linea().parrafo(`SON: ${t.total_letra}`);
  d.linea();
  if (t.leyenda) d.negrita(true).parrafo(mayus(t.leyenda)).negrita(false);
  d.parrafo('ESTE NO ES UN COMPROBANTE FISCAL');
  return d.terminar();
}

// Precuenta: la cuenta antes de cobrar, para llevarla a la mesa. Mismo formato
// que el ticket (sin recibido ni cambio, que aún no existen).
export function precuenta(t, opciones) {
  // Las precuentas anteriores traían "CUENTA NO PAGADA" como leyenda: no se imprime.
  const leyenda = t.leyenda === 'CUENTA NO PAGADA' ? null : t.leyenda;
  return ticket({ ...t, leyenda, recibido: null, cambio: null }, opciones);
}

export function corte(r, opciones) {
  const d = new Documento({ cortar: false, ...opciones });
  const fila = (txt, v, signo = '') => d.dosColumnas(txt, signo + dinero(v));
  d.alinear('centro').negrita(true).linea('CORTE DE CAJA').negrita(false);
  d.linea(`Abrió: ${r.abierto_en ?? ''}`).linea(`Cerró: ${r.cerrado_en ?? ''}`);
  if (r.cajero) d.linea(`Cajero: ${r.cajero}`);
  d.separador().alinear('izquierda');
  fila('Fondo inicial', r.fondo_inicial);
  fila('Efectivo', r.ventas_efectivo);
  fila('Tarjeta', r.ventas_tarjeta);
  fila('Transferencia', r.ventas_transferencia);
  fila('Entradas', r.entradas);
  fila('Retiros', r.retiros, '-');
  if (Number(r.devoluciones_efectivo)) fila('Devol. efectivo', r.devoluciones_efectivo, '-');
  d.separador();
  d.negrita(true); fila('Efectivo esperado', r.efectivo_esperado); d.negrita(false);
  fila('Efectivo contado', r.efectivo_contado);
  const dif = Number(r.diferencia ?? 0);
  d.negrita(true).dosColumnas(dif === 0 ? 'Sin diferencia' : dif < 0 ? 'Faltante' : 'Sobrante', dinero(Math.abs(dif))).negrita(false);
  d.separador();
  fila('Ventas totales', r.ventas_total);
  d.linea(`Cuentas cobradas: ${r.cuentas_cobradas ?? 0}`);
  fila('Terminal esperada', r.terminal_esperada);
  fila('Propinas efectivo', r.propinas_efectivo);
  fila('Propinas tarjeta', r.propinas_tarjeta);
  d.linea().linea().alinear('centro').linea('______________________').linea('Firma del cajero');
  return d.terminar();
}

// Página de prueba: acentos con las dos tablas para escoger la correcta.
export function paginaPrueba(destino, tabla, opciones) {
  const d = new Documento({ ...opciones, tabla });
  d.alinear('centro').negrita(true).linea('LA MERCED - PRUEBA').negrita(false);
  d.linea(destino).linea(`Tabla: ${tabla === 'cp850' ? 'A (PC850)' : 'B (Windows-1252)'}`).separador();
  d.alinear('izquierda').linea('Acentos: á é í ó ú  Á É Í Ó Ú').linea('Eñe: ñ Ñ   Signos: ¡ ¿ ü').linea('Pozole, Jamaica, Requesón con rajas, Champiñones');
  d.separador().alinear('centro').linea('Si los acentos se ven bien,').linea(`elige la tabla ${tabla === 'cp850' ? 'A' : 'B'}.`);
  return d.terminar();
}

export function formatear(trabajo, config) {
  const imp = config.impresoras[trabajo.impresora];
  const opciones = { ancho: imp.ancho, tabla: imp.tabla };
  const c = trabajo.contenido ?? {};
  if (trabajo.documento === 'comanda') return comanda(c, opciones);
  if (trabajo.documento === 'ticket') return ticket(c, opciones);
  if (trabajo.documento === 'corte') return corte(c, opciones);
  if (trabajo.documento === 'precuenta') return precuenta(c, opciones);
  throw new Error(`Documento desconocido: ${trabajo.documento}`);
}
