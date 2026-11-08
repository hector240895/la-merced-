export type Perfil = 'propietario' | 'cajero' | 'mesero';
export type EstadoMesa = 'disponible' | 'ocupada' | 'pedido_enviado' | 'por_cobrar';

export interface Yo { id: string; usuario: string; nombre: string; perfil: Perfil; sucursal_id: string }

export interface Mesa {
  id: string; nombre: string; orden: number; activa: boolean; estado: EstadoMesa;
  unida_a: string | null; eliminada_en: string | null;
}
export interface Categoria { id: string; nombre: string; orden: number }
export interface Producto {
  id: string; categoria_id: string; nombre: string; descripcion: string | null;
  precio: number; estado: 'activo' | 'agotado' | 'inactivo'; orden: number; // Cada selección (sabor, guisado, "pata o cueritos"…) con su propia lista.
  selecciones: { etiqueta: string; opciones: string[] }[];
}
export interface Cuenta {
  id: string; folio: number; tipo: 'mesa' | 'llevar'; mesa_id: string | null;
  estado: 'abierta' | 'por_cobrar' | 'cobrada' | 'cancelada'; mesero_id: string | null;
  cobro_anulado_en: string | null;
}
export interface Linea {
  id: string; cuenta_id: string; producto_id: string; nombre_producto: string; precio_unitario: number;
  cantidad: number; observacion: string | null; opcion: string | null; estado: 'activa' | 'cancelada';
  cancelacion_motivo: string | null; enviada_en: string | null; reemplaza_linea_id: string | null; creado_en: string;
}
export interface Usuario {
  id: string; usuario: string; nombre: string; perfil: Perfil; activo: boolean;
  baja_en: string | null; baja_motivo: string | null; creado_en: string;
}

export const ESTADO_MESA: Record<EstadoMesa, string> = {
  disponible: 'Disponible', ocupada: 'Ocupada', pedido_enviado: 'Pedido enviado', por_cobrar: 'Por cobrar',
};
export const PERFIL: Record<Perfil, string> = { propietario: 'Propietario', cajero: 'Cajero', mesero: 'Mesero' };

export const dinero = (n: number) =>
  '$' + Number(n).toLocaleString('es-MX', { minimumFractionDigits: 0, maximumFractionDigits: 2 });

export const fechaHora = (iso: string) =>
  new Date(iso).toLocaleString('es-MX', { timeZone: 'America/Mexico_City', dateStyle: 'medium', timeStyle: 'short' });

// Comandas e impresión (Etapa 4)
export interface LineaComanda {
  cantidad: number; producto: string; opcion: string | null; observacion: string | null; leyenda: string | null;
}
export interface ContenidoComanda {
  documento: 'comanda'; tipo: 'nueva' | 'adicional' | 'cancelacion' | 'modificacion'; numero: number; folio: number;
  para_llevar: boolean; destino: string; usuario: string; fecha: string; hora: string; lineas: LineaComanda[];
  reimpresion?: boolean; hora_reimpresion?: string; reimprimio?: string;
}
export type EstadoImpresion = 'pendiente' | 'enviado' | 'impreso' | 'error';
export interface Trabajo {
  id: string; comanda_id: string | null; cuenta_id: string | null; estado: EstadoImpresion; intentos: number;
  ultimo_error: string | null; reimpresion_de: string | null; creado_en: string; impreso_en: string | null;
  contenido: ContenidoComanda;
}
export const CAMPOS_TRABAJO = 'id, comanda_id, cuenta_id, estado, intentos, ultimo_error, reimpresion_de, creado_en, impreso_en, contenido';
export const ESTADO_IMPRESION: Record<EstadoImpresion, string> = {
  pendiente: 'Pendiente de imprimir', enviado: 'Imprimiendo…', impreso: '✓ Impresa', error: 'Error de impresión',
};
export const TIPO_COMANDA: Record<ContenidoComanda['tipo'], string> = {
  nueva: 'Comanda', adicional: 'Adicional', cancelacion: 'Cancelación', modificacion: 'Modificación',
};

// Estado de impresión que resume varias comandas: lo más urgente primero.
export function estadoDeComandas(trabajos: Trabajo[]): EstadoImpresion | null {
  const originales = trabajos.filter((t) => !t.reimpresion_de);
  if (!originales.length) return null;
  if (trabajos.some((t) => t.estado === 'error')) return 'error';
  if (trabajos.some((t) => t.estado === 'pendiente' || t.estado === 'enviado')) return 'pendiente';
  return 'impreso';
}

// Caja (Etapa 5)
export type MetodoPago = 'efectivo' | 'tarjeta' | 'transferencia';
export const METODO: Record<MetodoPago, string> = { efectivo: 'Efectivo', tarjeta: 'Tarjeta', transferencia: 'Transferencia' };
export interface CobroExtra { id: string; cuenta_id: string; concepto: string; importe: number; estado: 'activa' | 'cancelada'; cancelacion_motivo: string | null }
export interface ContenidoTicket {
  documento: 'ticket'; negocio: string; leyenda: string | null;
  folio: number; para_llevar: boolean; fecha: string; hora: string;
  lineas: { cantidad: number; producto: string; opcion: string | null; precio_unitario: number; importe: number }[];
  extras: { concepto: string; importe: number }[];
  total: number; recibido: number | null; cambio: number | null;
  reimpresion?: boolean; reimprimio?: string;
}
export interface Resumen {
  fondo_inicial: number; ventas_efectivo: number; ventas_tarjeta: number; ventas_transferencia: number; ventas_total: number;
  propinas_efectivo: number; propinas_tarjeta: number; devoluciones_efectivo: number; devoluciones_tarjeta: number;
  devoluciones_transferencia: number; entradas: number; retiros: number; efectivo_esperado: number; terminal_esperada: number;
  cuentas_cobradas: number; cobros_extra: number; cuentas_abiertas: number; turno_id?: string; abierto_en?: string;
}
export interface Turno {
  id: string; cajero_id: string; estado: 'abierto' | 'cerrado' | 'aprobado'; fondo_inicial: number; abierto_en: string;
  cerrado_en: string | null; efectivo_esperado: number | null; efectivo_contado: number | null; diferencia: number | null;
  resumen: Resumen | null; aprobado_en: string | null; aprobado_por: string | null;
}
