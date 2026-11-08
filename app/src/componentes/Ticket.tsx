import { METODO, dinero, type ContenidoTicket, type Resumen } from '../lib/tipos';

// Vista previa del ticket tal como sale en la impresora de caja (58 mm).
export function VistaTicket({ t, cambio, cerrar }: { t: ContenidoTicket; cambio?: number; cerrar: () => void }) {
  return (
    <div className="sheet centro" onClick={(e) => { if (e.target === e.currentTarget) cerrar(); }}>
      <div role="dialog" aria-label="Ticket">
        {cambio !== undefined && cambio > 0 && <p className="cambio-grande">Cambio: {dinero(cambio)}</p>}
        <div className="papel angosto">
          {t.reimpresion && <p className="p-marca">REIMPRESIÓN{t.reimprimio ? ` · ${t.reimprimio}` : ''}</p>}
          <p className="p-titulo">{t.negocio}</p>
          <hr />
          <p className="p-meta">{t.fecha} {t.hora} · Folio {t.folio}</p>
          {t.para_llevar && <p className="p-meta">Para llevar</p>}
          <hr />
          {t.lineas.map((l, i) => (
            <div key={i} className="t-linea">
              <span>{l.cantidad} {l.producto}{l.opcion && <small>{l.opcion}</small>}</span>
              <span>{dinero(l.importe)}</span>
            </div>
          ))}
          {t.extras.map((x, i) => (
            <div key={`x${i}`} className="t-linea"><span>Extra: {x.concepto}</span><span>{dinero(x.importe)}</span></div>
          ))}
          <hr />
          <div className="t-linea t-total"><span>TOTAL</span><span>{dinero(t.total)}</span></div>
          {t.pagos.map((p, i) => (
            <div key={`p${i}`}>
              <div className="t-linea"><span>{METODO[p.metodo]}</span><span>{dinero(p.importe)}</span></div>
              {p.recibido != null && <div className="t-linea"><span>Recibido</span><span>{dinero(p.recibido)}</span></div>}
              {p.cambio != null && <div className="t-linea"><span>Cambio</span><span>{dinero(p.cambio)}</span></div>}
            </div>
          ))}
          {t.propina && <div className="t-linea"><span>Propina ({METODO[t.propina.metodo].toLowerCase()})</span><span>{dinero(t.propina.importe)}</span></div>}
          {t.leyenda && <p className="p-titulo" style={{ marginTop: 8 }}>{t.leyenda}</p>}
        </div>
        <button className="sec" style={{ background: 'var(--card)' }} onClick={cerrar}>Cerrar</button>
      </div>
    </div>
  );
}

// Las cifras del corte, en pantalla.
export function CifrasCorte({ r, contado }: { r: Resumen; contado?: number | null }) {
  const fila = (t: string, v: number, signo = '') => <div className="r"><span>{t}</span><span>{signo}{dinero(v)}</span></div>;
  const dif = contado != null ? contado - r.efectivo_esperado : null;
  return (
    <>
      {fila('Fondo inicial', r.fondo_inicial)}
      {fila('Cobros en efectivo', r.ventas_efectivo)}
      {fila('Cobros con tarjeta', r.ventas_tarjeta)}
      {fila('Cobros por transferencia', r.ventas_transferencia)}
      {fila('Entradas de efectivo', r.entradas)}
      {fila('Retiros de efectivo', r.retiros, '−')}
      {r.devoluciones_efectivo > 0 && fila('Devoluciones en efectivo', r.devoluciones_efectivo, '−')}
      <div className="r s"><span>Efectivo esperado en caja</span><span>{dinero(r.efectivo_esperado)}</span></div>
      {contado != null && (
        <>
          {fila('Efectivo contado', contado)}
          <p className={`rem ${dif === 0 ? 'ok' : 'no'}`}>
            {dif === 0 ? 'Caja cuadrada: sin diferencia.' : dif! < 0 ? `Faltante de ${dinero(-dif!)}` : `Sobrante de ${dinero(dif!)}`}
          </p>
        </>
      )}
      <p className="note">
        Ventas del turno: {dinero(r.ventas_total)} en {r.cuentas_cobradas} cuentas (cobros extra: {dinero(r.cobros_extra)}).
        La terminal debe marcar {dinero(r.terminal_esperada)} (tarjeta más propinas con tarjeta).
      </p>
      <p className="note">
        Propinas para los meseros, fuera de la venta y del efectivo de la caja: {dinero(r.propinas_efectivo)} en efectivo
        y {dinero(r.propinas_tarjeta)} con tarjeta.
      </p>
    </>
  );
}
