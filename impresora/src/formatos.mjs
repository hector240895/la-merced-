// Cómo se ve en papel cada documento: comanda (cocina, 80 mm), ticket y
// corte (caja, 58 mm). Reciben el "contenido" que arma la base de datos.
import { Documento } from './escpos.mjs';

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

export function ticket(t, opciones) {
  const d = new Documento({ cortar: false, ...opciones });
  d.alinear('centro');
  if (t.reimpresion) d.linea('*** REIMPRESIÓN ***');
  d.negrita(true).parrafo(t.negocio).negrita(false);
  d.separador();
  d.linea(`${t.fecha} ${t.hora}  Folio ${t.folio}`);
  if (t.para_llevar) d.linea('Para llevar');
  d.separador().alinear('izquierda');
  for (const l of t.lineas ?? []) {
    d.dosColumnas(`${l.cantidad} ${l.producto}`, dinero(l.importe));
    if (l.opcion) d.parrafo(l.opcion, d.ancho, '  ');
  }
  for (const x of t.extras ?? []) d.dosColumnas(`Extra: ${x.concepto}`, dinero(x.importe));
  d.separador();
  d.negrita(true).tamano('alto').dosColumnas('TOTAL', dinero(t.total)).tamano(1).negrita(false);
  if (t.recibido != null) d.dosColumnas('Recibido', dinero(t.recibido));
  if (t.cambio != null) d.dosColumnas('Cambio', dinero(t.cambio));
  if (t.leyenda) d.linea().alinear('centro').parrafo(t.leyenda);
  return d.terminar();
}

// Precuenta: la cuenta antes de cobrar, para llevarla a la mesa.
// (Sin leyendas "cuenta informativa" ni "no pagada", a petición del propietario.)
export function precuenta(t, opciones) {
  const d = new Documento({ cortar: false, ...opciones });
  d.alinear('centro').negrita(true).parrafo(t.negocio).negrita(false);
  d.tamano(2).negrita(true).parrafo(t.destino, Math.floor(d.ancho / 2)).negrita(false).tamano(1);
  d.linea(`Folio ${t.folio}  ${t.fecha} ${t.hora}`);
  d.separador().alinear('izquierda');
  for (const l of t.lineas ?? []) {
    d.dosColumnas(`${l.cantidad} ${l.producto}`, dinero(l.importe));
    if (l.opcion) d.parrafo(l.opcion, d.ancho, '  ');
  }
  for (const x of t.extras ?? []) d.dosColumnas(`Extra: ${x.concepto}`, dinero(x.importe));
  d.separador();
  d.negrita(true).tamano('alto').dosColumnas('TOTAL', dinero(t.total)).tamano(1).negrita(false);
  return d.terminar();
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
