import { ESTADO_IMPRESION, type ContenidoComanda, type EstadoImpresion } from '../lib/tipos';

export function EstadoImp({ estado, error }: { estado: EstadoImpresion; error?: string | null }) {
  return (
    <span className={`imp imp-${estado}`} title={error ?? undefined}>
      {estado === 'impreso' ? '✓ Comanda impresa' : ESTADO_IMPRESION[estado]}
    </span>
  );
}

const TITULO: Record<ContenidoComanda['tipo'], string> = {
  nueva: 'COMANDA', adicional: 'COMANDA ADICIONAL', cancelacion: 'AVISO DE CANCELACIÓN', modificacion: 'MODIFICACIÓN',
};

// Vista previa de la comanda tal como sale en la impresora de cocina (80 mm).
// Mismo contenido que se imprime: nunca precios.
export function VistaComanda({ c, cerrar }: { c: ContenidoComanda; cerrar: () => void }) {
  return (
    <div className="sheet centro" onClick={(e) => { if (e.target === e.currentTarget) cerrar(); }}>
      <div role="dialog" aria-label="Vista previa de la comanda">
        <div className="papel">
          {c.reimpresion && <p className="p-marca">REIMPRESIÓN {c.hora_reimpresion}{c.reimprimio ? ` · ${c.reimprimio}` : ''}</p>}
          <p className="p-titulo">{TITULO[c.tipo]}</p>
          <p className="p-destino">{c.destino}</p>
          {c.para_llevar && <p className="p-destino">Pedido #{c.folio}</p>}
          <p className="p-meta">
            Comanda {c.numero} · {c.fecha} {c.hora}<br />
            {c.tipo === 'cancelacion' ? 'Canceló' : 'Mesero'}: {c.usuario}
          </p>
          <hr />
          {c.lineas.map((l, i) => (
            <div key={i} className="p-linea">
              <b>{l.leyenda ? `${l.leyenda}: ` : ''}{l.cantidad} × {l.producto}</b>
              {l.opcion && <div className="p-opcion">{l.opcion}</div>}
              {l.observacion && <div className="p-obs">** {l.observacion} **</div>}
            </div>
          ))}
          <hr />
          <p className="p-meta">Folio {c.folio}</p>
        </div>
        <button className="sec" style={{ background: 'var(--card)' }} onClick={cerrar}>Cerrar</button>
      </div>
    </div>
  );
}
