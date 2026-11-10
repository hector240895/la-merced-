import { useCallback, useEffect, useState } from 'react';
import { llamar, mensajeDe } from '../../lib/supabase';
import { useEnVivo } from '../../lib/vivo';
import { dinero, fechaHora } from '../../lib/tipos';
import { FORMA_PAGO, PERIODOS, descargarCsv, fechaCorta, fechaLarga, hoy, rango, type FormaPago, type Periodo } from '../../lib/finanzas';

// Reporte de utilidad real (ventas − todos los gastos) y de ventas.

interface Reporte {
  desde: string; hasta: string;
  ventas: { efectivo: number; tarjeta: number; transferencia: number; cobrado: number; devoluciones: number; netas: number; cuentas: number; ticket_promedio: number };
  propinas: { efectivo: number; tarjeta: number; total: number };
  gastos: { total: number; por_categoria: { categoria_id: string; nombre: string; total: number; n: number }[] };
  utilidad: number; margen: number | null;
  anterior: { desde: string; hasta: string; ventas: number; gastos: number; utilidad: number };
  por_dia: { fecha: string; ventas: number; gastos: number; cuentas: number }[];
  por_hora: { hora: number; ventas: number; cuentas: number }[];
  productos: { producto: string; cantidad: number; importe: number }[];
  meseros: { mesero: string; cuentas: number; ventas: number; propinas: number }[];
  formas_pago_gastos: Partial<Record<FormaPago, number>>;
  gastos_lista: { id: string; fecha: string; categoria: string; concepto: string; monto: number; forma_pago: FormaPago; quien: string | null }[];
  cancelaciones: {
    productos_quitados: number; cuentas_canceladas: number; cobros_anulados: number; devoluciones: number;
    detalle: { cuando: string; que: string; importe: number; motivo: string | null; quien: string | null }[];
  };
}

// Con signo al frente: -$1,500.
const conSigno = (n: number) => (Number(n) < 0 ? `-${dinero(-Number(n))}` : dinero(n));

function cambio(actual: number, antes: number) {
  if (!antes) return null;
  return Math.round(((actual - antes) / Math.abs(antes)) * 100);
}

function Barra({ valor, max, tono }: { valor: number; max: number; tono?: 'r' }) {
  const ancho = max > 0 && Number(valor) > 0 ? Math.max(2, Math.round((Number(valor) / max) * 100)) : 0;
  return <span className="barra"><span className={tono === 'r' ? 'r' : ''} style={{ width: `${ancho}%` }} /></span>;
}

export default function Reportes() {
  const [periodo, setPeriodo] = useState<Periodo>('mes');
  const [fechas, setFechas] = useState<[string, string]>([hoy(), hoy()]);
  const [r, setR] = useState<Reporte | null>(null);
  const [error, setError] = useState('');
  const [todosProductos, setTodosProductos] = useState(false);
  const [desde, hasta] = rango(periodo, fechas[0], fechas[1]);

  const cargar = useCallback(async () => {
    try { setR(await llamar<Reporte>('reporte_finanzas', { p_desde: desde, p_hasta: hasta })); setError(''); }
    catch (e) { setError(mensajeDe(e)); }
  }, [desde, hasta]);
  useEffect(() => { cargar(); }, [cargar]);
  useEnVivo(['pagos', 'gastos', 'devoluciones'], cargar);

  function exportar() {
    if (!r) return;
    const f: (string | number | null)[][] = [
      ['Reporte La Merced', `${r.desde} a ${r.hasta}`], [],
      ['Resumen'], ['Ventas', r.ventas.netas], ['Gastos', r.gastos.total], ['Utilidad', r.utilidad], ['Margen %', r.margen],
      ['Cuentas cobradas', r.ventas.cuentas], ['Ticket promedio', r.ventas.ticket_promedio], [],
      ['Ventas por forma de pago'], ['Efectivo', r.ventas.efectivo], ['Tarjeta', r.ventas.tarjeta], ['Transferencia', r.ventas.transferencia],
      ['Devoluciones', -r.ventas.devoluciones], ['Propinas (de los meseros, no cuentan como venta)', r.propinas.total], [],
      ['Gastos por categoría', 'Total', 'Número'], ...r.gastos.por_categoria.map((c) => [c.nombre, c.total, c.n]), [],
      ['Detalle de gastos'], ['Fecha', 'Categoría', 'Concepto', 'Monto', 'Forma de pago', 'Registró'],
      ...r.gastos_lista.map((g) => [g.fecha, g.categoria, g.concepto, g.monto, FORMA_PAGO[g.forma_pago], g.quien ?? 'Automático']), [],
      ['Por día', 'Ventas', 'Gastos', 'Cuentas'], ...r.por_dia.map((d) => [d.fecha, d.ventas, d.gastos, d.cuentas]), [],
      ['Productos', 'Cantidad', 'Importe'], ...r.productos.map((p) => [p.producto, p.cantidad, p.importe]), [],
      ['Mesero', 'Cuentas', 'Ventas', 'Propinas'], ...r.meseros.map((m) => [m.mesero, m.cuentas, m.ventas, m.propinas]), [],
      ['Cancelaciones', 'Importe', 'Motivo', 'Quién', 'Cuándo'],
      ...r.cancelaciones.detalle.map((c) => [c.que, c.importe, c.motivo, c.quien, fechaHora(c.cuando)]),
    ];
    descargarCsv(`la-merced-${r.desde}-a-${r.hasta}.csv`, f);
  }

  const maxCat = Math.max(0, ...(r?.gastos.por_categoria.map((c) => Number(c.total)) ?? []));
  const maxDia = Math.max(0, ...(r?.por_dia.flatMap((d) => [Number(d.ventas), Number(d.gastos)]) ?? []));
  const maxHora = Math.max(0, ...(r?.por_hora.map((h) => Number(h.ventas)) ?? []));
  const maxProd = Math.max(0, ...(r?.productos.map((p) => Number(p.cantidad)) ?? []));
  const variacion = (a: number, b: number) => {
    const c = cambio(a, b);
    return c == null ? 'sin datos del periodo anterior' : `${c > 0 ? '+' : ''}${c}% vs. periodo anterior`;
  };

  return (
    <>
      <div className="box">
        <h2>Reportes</h2>
        <div className="f">
          <select aria-label="Periodo del reporte" value={periodo} onChange={(e) => setPeriodo(e.target.value as Periodo)}>
            {PERIODOS.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
          </select>
          {periodo === 'otro' && (
            <>
              <input type="date" aria-label="Desde" value={fechas[0]} max={hoy()} onChange={(e) => setFechas([e.target.value, fechas[1]])} />
              <input type="date" aria-label="Hasta" value={fechas[1]} max={hoy()} onChange={(e) => setFechas([fechas[0], e.target.value])} />
            </>
          )}
          <button className="btn s" disabled={!r} onClick={exportar}>Exportar a Excel</button>
        </div>
        <p className="hint">{desde === hasta ? fechaLarga(desde) : `Del ${fechaLarga(desde)} al ${fechaLarga(hasta)}`}</p>
        {error && <p className="falta">{error}</p>}
      </div>

      {r && (
        <>
          <div className="kpis">
            <div className="kpi"><small>Ventas</small><b>{dinero(r.ventas.netas)}</b><small>{variacion(r.ventas.netas, r.anterior.ventas)}</small></div>
            <div className="kpi"><small>Gastos</small><b>{dinero(r.gastos.total)}</b><small>{variacion(r.gastos.total, r.anterior.gastos)}</small></div>
            <div className={`kpi ${r.utilidad < 0 ? 'neg' : 'pos'}`}>
              <small>Utilidad real</small><b>{conSigno(r.utilidad)}</b>
              <small>{r.margen != null ? `${r.margen}% de las ventas · ` : ''}antes: {conSigno(r.anterior.utilidad)}</small>
            </div>
            <div className="kpi"><small>Cuentas cobradas</small><b>{r.ventas.cuentas}</b><small>Ticket promedio {dinero(r.ventas.ticket_promedio)}</small></div>
          </div>

          <div className="dos">
            <div className="box">
              <h2>Ventas por forma de pago</h2>
              <p className="r"><span>Efectivo</span><b>{dinero(r.ventas.efectivo)}</b></p>
              <p className="r"><span>Tarjeta</span><b>{dinero(r.ventas.tarjeta)}</b></p>
              <p className="r"><span>Transferencia</span><b>{dinero(r.ventas.transferencia)}</b></p>
              {r.ventas.devoluciones > 0 && <p className="r"><span>Devoluciones</span><b>−{dinero(r.ventas.devoluciones)}</b></p>}
              <p className="tot"><span>Ventas</span><span>{dinero(r.ventas.netas)}</span></p>
              <p className="hint" style={{ marginTop: 10 }}>Propinas: {dinero(r.propinas.total)} (son de los meseros; no cuentan como venta).</p>
            </div>
            <div className="box">
              <h2>Gastos por categoría</h2>
              {r.gastos.por_categoria.length === 0 && <p className="vacio">Sin gastos en el periodo.</p>}
              {r.gastos.por_categoria.map((c) => (
                <div className="fila-barra" key={c.categoria_id}>
                  <span>{c.nombre}</span><Barra valor={c.total} max={maxCat} tono="r" /><b>{dinero(c.total)}</b>
                </div>
              ))}
              {r.gastos.por_categoria.length > 0 && <p className="tot"><span>Gastos</span><span>{dinero(r.gastos.total)}</span></p>}
            </div>
          </div>

          {r.por_dia.length > 1 && (
            <div className="box">
              <h2>Por día</h2>
              <p className="hint"><span className="clave v" /> Ventas <span className="clave g" /> Gastos</p>
              {r.por_dia.map((d) => (
                <div className="fila-barra doble" key={d.fecha}>
                  <span>{fechaCorta(d.fecha)}</span>
                  <span className="barras"><Barra valor={d.ventas} max={maxDia} /><Barra valor={d.gastos} max={maxDia} tono="r" /></span>
                  <b>{dinero(d.ventas)}{Number(d.gastos) > 0 && <small>−{dinero(d.gastos)}</small>}</b>
                </div>
              ))}
            </div>
          )}

          <div className="dos">
            <div className="box">
              <h2>Horas con más venta</h2>
              {r.por_hora.length === 0 && <p className="vacio">Sin ventas en el periodo.</p>}
              {r.por_hora.map((h) => (
                <div className="fila-barra" key={h.hora}>
                  <span>{h.hora}:00 – {h.hora + 1}:00</span><Barra valor={h.ventas} max={maxHora} /><b>{dinero(h.ventas)}</b>
                </div>
              ))}
            </div>
            <div className="box">
              <h2>Meseros</h2>
              {r.meseros.length === 0 && <p className="vacio">Sin cuentas cobradas.</p>}
              {r.meseros.map((m) => (
                <div className="row" key={m.mesero}>
                  <span className="n"><b>{m.mesero}</b><small>{m.cuentas} cuentas · propinas {dinero(m.propinas)}</small></span>
                  <span className="chip g">{dinero(m.ventas)}</span>
                </div>
              ))}
            </div>
          </div>

          <div className="box">
            <h2>Productos vendidos</h2>
            {r.productos.length === 0 && <p className="vacio">Sin ventas en el periodo.</p>}
            {(todosProductos ? r.productos : r.productos.slice(0, 10)).map((p) => (
              <div className="fila-barra" key={p.producto}>
                <span>{p.producto}</span><Barra valor={p.cantidad} max={maxProd} /><b>{p.cantidad}<small>{dinero(p.importe)}</small></b>
              </div>
            ))}
            {r.productos.length > 10 && (
              <button className="btn s" onClick={() => setTodosProductos(!todosProductos)}>
                {todosProductos ? 'Ver solo los 10 más vendidos' : `Ver los ${r.productos.length} (incluye los que menos se venden)`}
              </button>
            )}
          </div>

          <div className="box">
            <h2>Cancelaciones y anulaciones</h2>
            <p className="hint">
              {r.cancelaciones.productos_quitados} productos quitados · {r.cancelaciones.cuentas_canceladas} cuentas canceladas ·{' '}
              {r.cancelaciones.cobros_anulados} cobros anulados · {r.cancelaciones.devoluciones} devoluciones
            </p>
            {r.cancelaciones.detalle.map((c, k) => (
              <div className="row" key={k}>
                <span className="n"><b>{c.que}</b><small>{fechaHora(c.cuando)} · {c.quien ?? '—'}{c.motivo ? ` · ${c.motivo}` : ''}</small></span>
                <span className="chip">{dinero(c.importe)}</span>
              </div>
            ))}
          </div>
        </>
      )}
    </>
  );
}
