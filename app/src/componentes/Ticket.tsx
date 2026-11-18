import { dinero, type ContenidoTicket, type Resumen } from '../lib/tipos';

const pesos = (n: number) => '$' + Number(n).toLocaleString('es-MX', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const mayus = (t: string | null | undefined) => String(t ?? '').toLocaleUpperCase('es-MX');

// Vista previa del ticket tal como sale en la impresora de caja (58 mm).
export function VistaTicket({ t, cambio, cerrar }: { t: ContenidoTicket; cambio?: number; cerrar: () => void }) {
  return (
    <div className="sheet centro" onClick={(e) => { if (e.target === e.currentTarget) cerrar(); }}>
      <div role="dialog" aria-label="Ticket">
        {cambio !== undefined && cambio > 0 && <p className="cambio-grande">Cambio: {dinero(cambio)}</p>}
        <div className="papel angosto">
          {t.reimpresion && <p className="p-marca">REIMPRESIÓN{t.reimprimio ? ` · ${t.reimprimio}` : ''}</p>}
          <div className="tienda">
            <p className="p-titulo">{mayus(t.negocio)}</p>
            {t.direccion && <p>{mayus(t.direccion)}</p>}
            {t.telefonos && <p>TEL. {t.telefonos}</p>}
            <hr />
            <p className="p-titulo">FOLIO NO. {t.folio}</p>
            <p>{t.fecha} {t.hora}</p>
            {(t.destino ?? (t.para_llevar ? 'Para llevar' : null)) && <p className="p-titulo">{mayus(t.destino ?? 'Para llevar')}</p>}
            <hr />
            <div className="t-fila t-cab"><span>CANT</span><span>DESCRIPCION</span><span>IMPORTE</span></div>
            {t.lineas.map((l, i) => (
              <div key={i} className="t-fila"><span>{l.cantidad}</span><span>{mayus(l.producto)}</span><span>{pesos(l.importe)}</span></div>
            ))}
            {t.extras.map((x, i) => (
              <div key={`x${i}`} className="t-fila"><span>1</span><span>EXTRA: {mayus(x.concepto)}</span><span>{pesos(x.importe)}</span></div>
            ))}
            <p className="t-der t-total" style={{ marginTop: 10 }}>TOTAL: {pesos(t.total)}</p>
            {t.recibido != null && <p className="t-der">RECIBIDO: {pesos(t.recibido)}</p>}
            {t.cambio != null && <p className="t-der">CAMBIO: {pesos(t.cambio)}</p>}
            {t.total_letra && <p style={{ marginTop: 8 }}>SON: {t.total_letra}</p>}
            {t.leyenda && <p className="p-titulo" style={{ marginTop: 8 }}>{mayus(t.leyenda)}</p>}
            <p>ESTE NO ES UN COMPROBANTE FISCAL</p>
          </div>
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
