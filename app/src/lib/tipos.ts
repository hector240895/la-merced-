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
  precio: number; estado: 'activo' | 'agotado' | 'inactivo'; orden: number; opciones: string[];
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
