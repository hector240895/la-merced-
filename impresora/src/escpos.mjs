// Comandos ESC/POS para impresoras térmicas (Nextep NE-511 y NE-510X) y
// codificación de texto en español (acentos, ñ, ¡, ¿).

const ESC = 0x1b;
const GS = 0x1d;
const FS = 0x1c;

// Tablas de caracteres. Cada impresora elige una con "ESC t n"; el asistente
// de configuración imprime una prueba con ambas para escoger la que se ve bien.
export const TABLAS = {
  cp850: { n: 2, nombre: 'PC850' },
  cp1252: { n: 16, nombre: 'Windows-1252' },
};

const CP850 = {
  'Ç': 0x80, 'ü': 0x81, 'é': 0x82, 'â': 0x83, 'ä': 0x84, 'à': 0x85, 'ç': 0x87, 'ê': 0x88, 'ë': 0x89, 'è': 0x8a,
  'ï': 0x8b, 'î': 0x8c, 'ì': 0x8d, 'Ä': 0x8e, 'É': 0x90, 'ô': 0x93, 'ö': 0x94, 'ò': 0x95, 'û': 0x96, 'ù': 0x97,
  'Ö': 0x99, 'Ü': 0x9a, '×': 0x9e, 'á': 0xa0, 'í': 0xa1, 'ó': 0xa2, 'ú': 0xa3, 'ñ': 0xa4, 'Ñ': 0xa5, 'ª': 0xa6,
  'º': 0xa7, '¿': 0xa8, '¡': 0xad, 'Á': 0xb5, 'Â': 0xb6, 'À': 0xb7, 'Ê': 0xd2, 'Ë': 0xd3, 'È': 0xd4, 'Í': 0xd6,
  'Î': 0xd7, 'Ï': 0xd8, 'Ì': 0xde, 'Ó': 0xe0, 'Ô': 0xe2, 'Ò': 0xe3, 'Ú': 0xe9, 'Û': 0xea, 'Ù': 0xeb, '·': 0xfa,
  '°': 0xf8,
};
const CP1252_EXTRA = { '’': 0x92, '‘': 0x91, '“': 0x93, '”': 0x94, '–': 0x96, '—': 0x97, '…': 0x85 };
// Lo que una tabla no tiene se cambia por algo parecido.
const PARECIDOS = { '’': "'", '‘': "'", '“': '"', '”': '"', '–': '-', '—': '-', '…': '...', '•': '*', '−': '-' };

export function codificar(texto, tabla = 'cp850') {
  const salida = [];
  for (const c of String(texto).normalize('NFC')) {
    const cp = c.codePointAt(0);
    if (cp < 0x80) { salida.push(cp); continue; }
    if (tabla === 'cp850') {
      if (CP850[c] !== undefined) { salida.push(CP850[c]); continue; }
    } else {
      if (CP1252_EXTRA[c] !== undefined) { salida.push(CP1252_EXTRA[c]); continue; }
      if (cp >= 0xa0 && cp <= 0xff) { salida.push(cp); continue; }
    }
    const parecido = PARECIDOS[c] ?? c.normalize('NFD').replace(/[̀-ͯ]/g, '');
    for (const p of parecido) salida.push(p.codePointAt(0) < 0x80 ? p.codePointAt(0) : 0x3f);
  }
  return salida;
}

// Constructor de un documento: acumula bytes con formato.
export class Documento {
  constructor({ ancho = 48, tabla = 'cp850', cortar = true } = {}) {
    this.ancho = ancho;
    this.tabla = tabla;
    this.cortar = cortar;
    // Inicializar y elegir la tabla de caracteres. Con CP1252 (la NE-510X de caja)
    // primero se apaga el modo de caracteres chinos (FS .), que si no revuelve los
    // acentos. La tabla CP850 (cocina) queda como estaba.
    this.bytes = [
      ESC, 0x40,
      ...(tabla === 'cp1252' ? [FS, 0x2e] : []),
      ESC, 0x74, TABLAS[tabla].n,
    ];
  }
  crudo(...b) { this.bytes.push(...b); return this; }
  alinear(a) { return this.crudo(ESC, 0x61, { izquierda: 0, centro: 1, derecha: 2 }[a]); }
  negrita(si) { return this.crudo(ESC, 0x45, si ? 1 : 0); }
  // Tamaño 1 (normal) o 2 (doble alto y doble ancho).
  tamano(t) { return this.crudo(GS, 0x21, t === 2 ? 0x11 : t === 'alto' ? 0x01 : 0x00); }
  texto(t) { this.bytes.push(...codificar(t, this.tabla)); return this; }
  linea(t = '') { return this.texto(t).crudo(0x0a); }
  separador(c = '-') { return this.linea(c.repeat(this.ancho)); }
  // Texto largo partido en renglones del ancho del papel.
  parrafo(t, ancho = this.ancho, sangria = '') {
    for (const r of partir(t, ancho - sangria.length)) this.linea(sangria + r);
    return this;
  }
  // "Concepto ........ $60": el importe a la derecha; el concepto se parte si no cabe.
  dosColumnas(izq, der, ancho = this.ancho) {
    const espacio = ancho - der.length - 1;
    const renglones = partir(izq, espacio);
    renglones.forEach((r, i) => {
      if (i === renglones.length - 1) this.linea(r + ' '.repeat(Math.max(1, ancho - r.length - der.length)) + der);
      else this.linea(r);
    });
    return this;
  }
  avanzar(n = 1) { return this.crudo(ESC, 0x64, n); }
  terminar() {
    this.avanzar(4);
    if (this.cortar) this.crudo(GS, 0x56, 0x42, 0x00);   // corte parcial
    return Uint8Array.from(this.bytes);
  }
}

export function partir(texto, ancho) {
  const palabras = String(texto ?? '').split(/\s+/).filter(Boolean);
  const renglones = [];
  let actual = '';
  for (const p of palabras) {
    if (p.length > ancho) {
      if (actual) { renglones.push(actual); actual = ''; }
      for (let i = 0; i < p.length; i += ancho) renglones.push(p.slice(i, i + ancho));
      continue;
    }
    if (!actual) actual = p;
    else if (actual.length + 1 + p.length <= ancho) actual += ' ' + p;
    else { renglones.push(actual); actual = p; }
  }
  if (actual || !renglones.length) renglones.push(actual);
  return renglones;
}
