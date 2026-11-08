import { useCallback, useEffect, useState } from 'react';
import { llamar, mensajeDe, supabase } from '../../lib/supabase';
import { useEnVivo } from '../../lib/vivo';
import { useAviso } from '../../componentes/Aviso';
import { CifrasCorte, VistaTicket } from '../../componentes/Ticket';
import { METODO, dinero, fechaHora, type ContenidoTicket, type MetodoPago, type Turno } from '../../lib/tipos';

interface Cobrada { id: string; folio: number; tipo: 'mesa' | 'llevar'; mesa_id: string | null; total: number; cobrada_en: string }
interface Concepto { id: string; cuenta_id: string; texto: string; importe: number; tipo: 'linea' | 'extra' }
type Accion = { cuenta: string; tipo: 'anular' | 'quitar' } | null;

// Cortes de caja (aprobar, reabrir) y cuentas cobradas (ticket, anular cobro,
// quitar un producto con devolución): lo grave pide autorización del otro propietario.
export default function CortesVentas() {
  const aviso = useAviso();
  const [turnos, setTurnos] = useState<Turno[]>([]);
  const [nombres, setNombres] = useState<Record<string, string>>({});
  const [mesas, setMesas] = useState<Record<string, string>>({});
  const [cobradas, setCobradas] = useState<Cobrada[]>([]);
  const [conceptos, setConceptos] = useState<Concepto[]>([]);
  const [metodos, setMetodos] = useState<Record<string, string>>({});
  const [pendientes, setPendientes] = useState<Set<string>>(new Set());
  const [detalle, setDetalle] = useState<string | null>(null);
  const [reabriendo, setReabriendo] = useState<string | null>(null);
  const [accionSel, setAccionSel] = useState<Accion>(null);
  const [form, setForm] = useState({ motivo: '', concepto: '', metodo: 'efectivo' as MetodoPago });
  const [ticket, setTicket] = useState<ContenidoTicket | null>(null);
  const [ocupado, setOcupado] = useState(false);

  const cargar = useCallback(async () => {
    const [t, u, m, c] = await Promise.all([
      supabase.from('turnos_caja').select('*').order('abierto_en', { ascending: false }).limit(30),
      supabase.from('usuarios').select('id, nombre'),
      supabase.from('mesas').select('id, nombre'),
      supabase.from('cuentas').select('id, folio, tipo, mesa_id, total, cobrada_en').eq('estado', 'cobrada')
        .order('cobrada_en', { ascending: false }).limit(40),
    ]);
    setTurnos((t.data ?? []) as Turno[]);
    setNombres(Object.fromEntries((u.data ?? []).map((x) => [x.id, x.nombre])));
    setMesas(Object.fromEntries((m.data ?? []).map((x) => [x.id, x.nombre])));
    const cs = (c.data ?? []) as Cobrada[];
    setCobradas(cs);
    const ids = cs.map((x) => x.id);
    if (!ids.length) return;
    const [l, x, p, a] = await Promise.all([
      supabase.from('lineas_cuenta').select('id, cuenta_id, nombre_producto, opcion, cantidad, precio_unitario').in('cuenta_id', ids).eq('estado', 'activa'),
      supabase.from('cobros_extra').select('id, cuenta_id, concepto, importe').in('cuenta_id', ids).eq('estado', 'activa'),
      supabase.from('pagos').select('cuenta_id, metodo, importe').in('cuenta_id', ids).eq('estado', 'vigente'),
      supabase.from('autorizaciones').select('cuenta_id').in('cuenta_id', ids).eq('estado', 'pendiente'),
    ]);
    setConceptos([
      ...(l.data ?? []).map((y) => ({ id: y.id, cuenta_id: y.cuenta_id, tipo: 'linea' as const, importe: y.precio_unitario * y.cantidad,
        texto: `${y.cantidad} × ${y.nombre_producto}${y.opcion ? ` · ${y.opcion}` : ''}` })),
      ...(x.data ?? []).map((y) => ({ id: y.id, cuenta_id: y.cuenta_id, tipo: 'extra' as const, importe: Number(y.importe), texto: `Extra: ${y.concepto}` })),
    ]);
    const mt: Record<string, string[]> = {};
    for (const y of p.data ?? []) (mt[y.cuenta_id] ??= []).push(`${METODO[y.metodo as MetodoPago]} ${dinero(Number(y.importe))}`);
    setMetodos(Object.fromEntries(Object.entries(mt).map(([k, v]) => [k, v.join(' + ')])));
    setPendientes(new Set((a.data ?? []).map((y) => y.cuenta_id)));
  }, []);
  useEffect(() => { cargar(); }, [cargar]);
  useEnVivo(['turnos_caja', 'cuentas', 'autorizaciones', 'pagos'], cargar);

  async function hacer(fn: () => Promise<unknown>, exito: string) {
    setOcupado(true);
    try { await fn(); aviso(exito); return true; } catch (e) { aviso(mensajeDe(e)); return false; }
    finally { setOcupado(false); await cargar(); }
  }

  async function verTicket(cuenta: string) {
    const { data } = await supabase.from('trabajos_impresion').select('contenido').eq('cuenta_id', cuenta).eq('documento', 'ticket')
      .is('reimpresion_de', null).order('creado_en', { ascending: false }).limit(1).maybeSingle();
    if (data) setTicket(data.contenido as unknown as ContenidoTicket);
    else aviso('Esta cuenta no tiene ticket');
  }

  const destino = (c: Cobrada) => (c.tipo === 'llevar' ? 'Para llevar' : mesas[c.mesa_id ?? ''] ?? 'Mesa');

  return (
    <>
      <div className="box">
        <h2>Cortes de caja</h2>
        {turnos.length === 0 && <p className="note">Todavía no hay cortes.</p>}
        {turnos.map((t) => {
          const d = t.diferencia == null ? null : Number(t.diferencia);
          return (
            <div key={t.id}>
              <div className="row">
                <span className="n">
                  <b>{fechaHora(t.abierto_en)}</b>
                  <small>
                    Cajero: {nombres[t.cajero_id] ?? '—'}
                    {t.efectivo_esperado != null && ` · Esperado ${dinero(Number(t.efectivo_esperado))} · Contado ${dinero(Number(t.efectivo_contado))}`}
                    {t.aprobado_por && ` · Aprobó ${nombres[t.aprobado_por]}`}
                  </small>
                </span>
                {d != null && (d === 0 ? <span className="chip g">Sin diferencia</span>
                  : <span className="rem no">{d < 0 ? 'Faltante' : 'Sobrante'} {dinero(Math.abs(d))}</span>)}
                <span className={`chip ${t.estado === 'aprobado' ? 'g' : t.estado === 'abierto' ? '' : 'r'}`}>
                  {t.estado === 'abierto' ? 'Caja abierta' : t.estado === 'cerrado' ? 'Por aprobar' : 'Aprobado'}
                </span>
                {t.resumen && <button className="btn s" onClick={() => setDetalle(detalle === t.id ? null : t.id)}>Detalle</button>}
                {t.estado === 'cerrado' && (
                  <button className="btn" disabled={ocupado} onClick={() => hacer(() => llamar('aprobar_corte', { p_turno_id: t.id }), 'Corte aprobado')}>
                    Aprobar corte
                  </button>
                )}
                {t.estado !== 'abierto' && (
                  <button className="btn s" disabled={ocupado} onClick={() => { setReabriendo(t.id); setForm({ ...form, motivo: '' }); }}>Reabrir</button>
                )}
              </div>
              {reabriendo === t.id && (
                <div className="f" style={{ paddingBottom: 10 }}>
                  <input autoFocus placeholder="Motivo para reabrir (obligatorio)" value={form.motivo} aria-label="Motivo para reabrir"
                         onChange={(e) => setForm({ ...form, motivo: e.target.value })} />
                  <button className="btn" disabled={ocupado || !form.motivo.trim()}
                          onClick={async () => {
                            if (await hacer(() => llamar('reabrir_corte', { p_turno_id: t.id, p_motivo: form.motivo }),
                              'Corte reabierto. Queda registrado en la auditoría.')) setReabriendo(null);
                          }}>Reabrir corte</button>
                  <button className="btn s" onClick={() => setReabriendo(null)}>Cancelar</button>
                </div>
              )}
              {detalle === t.id && t.resumen && <div style={{ padding: '4px 0 12px' }}><CifrasCorte r={t.resumen} contado={Number(t.efectivo_contado)} /></div>}
            </div>
          );
        })}
        <p className="note">Solo un propietario puede reabrir un corte, y siempre queda registrado.</p>
      </div>

      <div className="box">
        <h2>Cuentas cobradas</h2>
        {cobradas.length === 0 && <p className="note">Todavía no hay cuentas cobradas.</p>}
        {cobradas.map((c) => (
          <div key={c.id}>
            <div className="row">
              <span className="n">
                <b>{destino(c)} · Folio {c.folio}</b>
                <small>{fechaHora(c.cobrada_en)} · {metodos[c.id] ?? ''}</small>
              </span>
              <b>{dinero(Number(c.total))}</b>
              {pendientes.has(c.id) && <span className="chip">Solicitud pendiente</span>}
              <button className="btn s" onClick={() => verTicket(c.id)}>Ver ticket</button>
              <button className="btn s" disabled={ocupado} onClick={() => { setAccionSel({ cuenta: c.id, tipo: 'quitar' }); setForm({ motivo: '', concepto: '', metodo: 'efectivo' }); }}>
                Quitar producto
              </button>
              <button className="btn d" disabled={ocupado} onClick={() => { setAccionSel({ cuenta: c.id, tipo: 'anular' }); setForm({ motivo: '', concepto: '', metodo: 'efectivo' }); }}>
                Anular cobro
              </button>
            </div>
            {accionSel?.cuenta === c.id && (
              <div className="f" style={{ paddingBottom: 10 }}>
                {accionSel.tipo === 'quitar' && (
                  <>
                    <select value={form.concepto} onChange={(e) => setForm({ ...form, concepto: e.target.value })} aria-label="Producto a quitar">
                      <option value="">Elige el producto…</option>
                      {conceptos.filter((x) => x.cuenta_id === c.id).map((x) => (
                        <option key={x.id} value={`${x.tipo}:${x.id}`}>{x.texto} · {dinero(x.importe)}</option>
                      ))}
                    </select>
                    <select value={form.metodo} onChange={(e) => setForm({ ...form, metodo: e.target.value as MetodoPago })} aria-label="Cómo se devuelve el dinero">
                      <option value="efectivo">Devolver en efectivo</option>
                      <option value="tarjeta">Devolver a la tarjeta</option>
                      <option value="transferencia">Devolver por transferencia</option>
                    </select>
                  </>
                )}
                <input placeholder="Motivo (obligatorio)" value={form.motivo} aria-label="Motivo de la solicitud"
                       onChange={(e) => setForm({ ...form, motivo: e.target.value })} />
                <button className="btn" disabled={ocupado || !form.motivo.trim() || (accionSel.tipo === 'quitar' && !form.concepto)}
                        onClick={async () => {
                          const [tipo, id] = form.concepto.split(':');
                          const ok = await hacer(() => llamar('solicitar_autorizacion', accionSel.tipo === 'anular'
                            ? { p_tipo: 'anular_cobro', p_cuenta_id: c.id, p_motivo: form.motivo }
                            : { p_tipo: 'cancelar_linea_cobrada', p_cuenta_id: c.id, p_motivo: form.motivo,
                                p_linea_id: tipo === 'linea' ? id : null, p_cobro_extra_id: tipo === 'extra' ? id : null,
                                p_metodo_devolucion: form.metodo }),
                            'Solicitud enviada al otro propietario. Nada cambia hasta que la apruebe.');
                          if (ok) setAccionSel(null);
                        }}>Enviar solicitud</button>
                <button className="btn s" onClick={() => setAccionSel(null)}>Cancelar</button>
              </div>
            )}
          </div>
        ))}
        <p className="note">
          Anular un cobro y quitar un producto ya cobrado requieren la autorización del otro propietario. Al aprobar, el
          producto queda cancelado (sin borrarse) y la devolución al cliente queda registrada en el corte.
        </p>
      </div>
      {ticket && <VistaTicket t={ticket} cerrar={() => setTicket(null)} />}
    </>
  );
}
