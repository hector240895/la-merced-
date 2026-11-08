import { useState } from 'react';
import { llamar } from '../lib/supabase';
import { TIPO_COMANDA, fechaHora, type ContenidoComanda, type Trabajo } from '../lib/tipos';
import { EstadoImp, VistaComanda } from './Comanda';

interface Props {
  trabajos: Trabajo[];
  accion: (fn: () => Promise<unknown>, exito?: string) => Promise<boolean>;
  ocupado: boolean;
  conDestino?: boolean;
}

// Comandas con su estado de impresión: ver la comanda, reintentar si falló
// o reimprimir si ya salió (queda registrado con quién la pidió).
export default function ListaComandas({ trabajos, accion, ocupado, conDestino = false }: Props) {
  const [viendo, setViendo] = useState<ContenidoComanda | null>(null);
  return (
    <>
      {trabajos.map((t) => (
        <div key={t.id} className="cmd">
          <span className="n">
            <b>{conDestino ? `${t.contenido.destino} · ` : ''}{TIPO_COMANDA[t.contenido.tipo]} {t.contenido.numero}</b>
            {t.reimpresion_de ? ` (reimpresión${t.contenido.reimprimio ? ` de ${t.contenido.reimprimio}` : ''})` : ''}
            <small>
              {conDestino ? fechaHora(t.creado_en) : t.contenido.hora} · {t.contenido.usuario}
              {t.estado === 'error' && t.ultimo_error ? ` · ${t.ultimo_error}` : ''}
            </small>
          </span>
          <EstadoImp estado={t.estado} error={t.ultimo_error} />
          <button className="btn s" onClick={() => setViendo(t.contenido)}>Ver</button>
          {t.estado === 'error' && (
            <button className="btn" disabled={ocupado}
                    onClick={() => accion(() => llamar('reintentar_impresion', { p_trabajo_id: t.id }), 'Comanda enviada de nuevo a la impresora')}>
              Reintentar
            </button>
          )}
          {t.estado === 'impreso' && !t.reimpresion_de && t.comanda_id && (
            <button className="btn s" disabled={ocupado}
                    onClick={() => accion(() => llamar('reimprimir_comanda', { p_comanda_id: t.comanda_id }), 'Reimpresión enviada a cocina')}>
              Reimprimir
            </button>
          )}
        </div>
      ))}
      {viendo && <VistaComanda c={viendo} cerrar={() => setViendo(null)} />}
    </>
  );
}
