// Finanzas (Etapa 9): tipos, nombres y fechas en hora de la Ciudad de México.

export type FormaPago = 'caja' | 'efectivo' | 'tarjeta' | 'transferencia';
export const FORMA_PAGO: Record<FormaPago, string> = {
  caja: 'Efectivo de la caja', efectivo: 'Efectivo (fuera de la caja)', tarjeta: 'Tarjeta', transferencia: 'Transferencia',
};

export interface CategoriaGasto { id: string; clave: string | null; nombre: string; orden: number }
export interface Gasto {
  id: string; categoria_id: string; concepto: string; monto: number; fecha: string; forma_pago: FormaPago;
  estado: 'vigente' | 'anulado'; nota: string | null; anulacion_motivo: string | null; gasto_fijo_id: string | null;
  creado_en: string; usuarios: { nombre: string } | null;
}
export interface Empleado { id: string; nombre: string; puesto: string | null; sueldo: number; periodicidad: 'semanal' | 'quincenal' | 'mensual' }
export interface GastoFijo { id: string; categoria_id: string; concepto: string; monto: number; dia: number; forma_pago: FormaPago; desde: string }

const ZONA = 'America/Mexico_City';
// Fecha de hoy (AAAA-MM-DD) en la Ciudad de México.
export const hoy = () => new Date().toLocaleDateString('en-CA', { timeZone: ZONA });

function sumarDias(fecha: string, dias: number) {
  const d = new Date(`${fecha}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + dias);
  return d.toISOString().slice(0, 10);
}
export const inicioMes = (fecha: string) => `${fecha.slice(0, 8)}01`;
export function finMes(fecha: string) {
  const d = new Date(`${inicioMes(fecha)}T12:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() + 1);
  d.setUTCDate(0);
  return d.toISOString().slice(0, 10);
}

export type Periodo = 'hoy' | 'ayer' | 'semana' | 'mes' | 'mes_pasado' | 'otro';
export const PERIODOS: [Periodo, string][] = [
  ['hoy', 'Hoy'], ['ayer', 'Ayer'], ['semana', 'Esta semana'], ['mes', 'Este mes'], ['mes_pasado', 'Mes pasado'], ['otro', 'Otras fechas'],
];
export function rango(p: Periodo, desde = hoy(), hasta = hoy()): [string, string] {
  const h = hoy();
  switch (p) {
    case 'hoy': return [h, h];
    case 'ayer': return [sumarDias(h, -1), sumarDias(h, -1)];
    case 'semana': { // de lunes a hoy
      const dia = new Date(`${h}T12:00:00Z`).getUTCDay();
      return [sumarDias(h, -((dia + 6) % 7)), h];
    }
    case 'mes': return [inicioMes(h), h];
    case 'mes_pasado': { const fin = sumarDias(inicioMes(h), -1); return [inicioMes(fin), fin]; }
    default: return [desde, hasta];
  }
}

export const fechaCorta = (f: string) =>
  new Date(`${f}T12:00:00Z`).toLocaleDateString('es-MX', { timeZone: 'UTC', weekday: 'short', day: 'numeric', month: 'short' });
export const fechaLarga = (f: string) =>
  new Date(`${f}T12:00:00Z`).toLocaleDateString('es-MX', { timeZone: 'UTC', day: 'numeric', month: 'long', year: 'numeric' });

// Archivo CSV que abre Excel (con acentos): filas de celdas.
export function descargarCsv(nombre: string, filas: (string | number | null | undefined)[][]) {
  const celda = (v: string | number | null | undefined) => {
    const t = v == null ? '' : String(v);
    return /[",\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
  };
  const texto = '﻿' + filas.map((f) => f.map(celda).join(',')).join('\r\n');
  const url = URL.createObjectURL(new Blob([texto], { type: 'text/csv;charset=utf-8' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = nombre;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
