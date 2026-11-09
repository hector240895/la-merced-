import { useCallback, useEffect, useMemo, useState } from 'react';
import { llamar, mensajeDe, supabase } from '../lib/supabase';
import { useEnVivo } from '../lib/vivo';
import { useAviso } from '../componentes/Aviso';
import Pedido, { leerBorradores, type Borrador, type Borradores, CLAVE_BORRADORES } from '../componentes/Pedido';
import { CifrasCorte, VistaTicket } from '../componentes/Ticket';
import { EstadoImp } from '../componentes/Comanda';
import {
  CAMPOS_TRABAJO, METODO, dinero, fechaHora, type Categoria, type CobroExtra, type ContenidoTicket, type Cuenta, type Linea,
  type Mesa, type MetodoPago, type Producto, type Resumen, type Trabajo, type Yo,
} from '../lib/tipos';

interface CuentaCaja extends Cuenta { total: number | null; cobrada_en: string | null; turno_id: string | null; cuenta_pedida_en: string | null }
interface PagoCaptura { metodo: MetodoPago; importe: number; recibido?: number }
interface Movimiento { id: string; tipo: 'entrada' | 'retiro'; importe: number; motivo: string; creado_en: string }

const redondo = (n: number) => Math.round(n * 100) / 100;

// Pantalla de caja: cobrar (mesas y para llevar) y la caja del día (movimientos y corte).
export default function Caja({ yo }: { yo: Yo }) {
  const aviso = useAviso();
  const [vista, setVista] = useState<'cobrar' | 'caja'>('cobrar');
  const [resumen, setResumen] = useState<Resumen | null | undefined>(undefined);
  const [cuentas, setCuentas] = useState<CuentaCaja[]>([]);
  const [lineas, setLineas] = useState<Linea[]>([]);
  const [extras, setExtras] = useState<CobroExtra[]>([]);
  const [mesas, setMesas] = useState<Mesa[]>([]);
  const [tickets, setTickets] = useState<Trabajo[]>([]);
  const [precuentas, setPrecuentas] = useState<Trabajo[]>([]);
  const [comandas, setComandas] = useState<Trabajo[]>([]);
  const [movs, setMovs] = useState<Movimiento[]>([]);
  const [categorias, setCategorias] = useState<Categoria[]>([]);
  const [productos, setProductos] = useState<Producto[]>([]);
  const [ocupado, setOcupado] = useState(false);
  const [sel, setSel] = useState<string | null>(null);
  const [llevar, setLlevar] = useState<string | null>(null);   // 'nuevo' o la cuenta para agregar productos
  const [borradores, setBorradores] = useState<Borradores>(leerBorradores);
  const [ticket, setTicket] = useState<{ t: ContenidoTicket; cambio?: number } | null>(null);

  useEffect(() => {
    try { localStorage.setItem(CLAVE_BORRADORES, JSON.stringify(borradores)); } catch { /* sin almacenamiento */ }
  }, [borradores]);

  const cargar = useCallback(async () => {
    const r = await supabase.rpc('resumen_caja');
    if (r.error) { aviso(mensajeDe(r.error)); return; }
    const res = r.data as Resumen | null;
    setResumen(res);
    const campos = 'id, folio, tipo, mesa_id, estado, mesero_id, cobro_anulado_en, total, cobrada_en, turno_id, cuenta_pedida_en';
    const [abiertas, cobradas, m, k, p] = await Promise.all([
      supabase.from('cuentas').select(campos).in('estado', ['abierta', 'por_cobrar']).order('folio'),
      res?.turno_id
        ? supabase.from('cuentas').select(campos).eq('estado', 'cobrada').eq('turno_id', res.turno_id).order('cobrada_en', { ascending: false })
        : Promise.resolve({ data: [], error: null }),
      supabase.from('mesas').select('id, nombre, orden, activa, estado, unida_a, eliminada_en'),
      supabase.from('categorias').select('id, nombre, orden').order('orden'),
      supabase.from('productos').select('id, categoria_id, nombre, descripcion, precio, estado, orden, selecciones').order('orden'),
    ]);
    const todas = [...(abiertas.data ?? []), ...(cobradas.data ?? [])] as CuentaCaja[];
    const ids = todas.map((c) => c.id);
    const [l, x, t, mv] = await Promise.all([
      ids.length ? supabase.from('lineas_cuenta')
        .select('id, cuenta_id, producto_id, nombre_producto, precio_unitario, cantidad, observacion, opcion, estado, cancelacion_motivo, enviada_en, reemplaza_linea_id, creado_en')
        .in('cuenta_id', ids).order('creado_en') : Promise.resolve({ data: [], error: null }),
      ids.length ? supabase.from('cobros_extra').select('id, cuenta_id, concepto, importe, estado, cancelacion_motivo')
        .in('cuenta_id', ids).order('creado_en') : Promise.resolve({ data: [], error: null }),
      ids.length ? supabase.from('trabajos_impresion').select(CAMPOS_TRABAJO).in('cuenta_id', ids)
        .order('creado_en', { ascending: false }) : Promise.resolve({ data: [], error: null }),
      res?.turno_id ? supabase.from('movimientos_efectivo').select('id, tipo, importe, motivo, creado_en')
        .eq('turno_id', res.turno_id).order('creado_en') : Promise.resolve({ data: [], error: null }),
    ]);
    setCuentas(todas);
    setLineas((l.data ?? []) as Linea[]);
    setExtras((x.data ?? []) as CobroExtra[]);
    const trabajos = (t.data ?? []) as unknown as Trabajo[];
    setTickets(trabajos.filter((j) => (j.contenido as unknown as { documento: string }).documento === 'ticket'));
    setPrecuentas(trabajos.filter((j) => (j.contenido as unknown as { documento: string }).documento === 'precuenta'));
    setComandas(trabajos.filter((j) => j.contenido.documento === 'comanda'));
    setMovs((mv.data ?? []) as Movimiento[]);
    setMesas((m.data ?? []) as Mesa[]);
    setCategorias((k.data ?? []) as Categoria[]);
    setProductos((p.data ?? []) as Producto[]);
  }, [aviso]);
  useEffect(() => { cargar(); }, [cargar]);
  useEnVivo(['cuentas', 'lineas_cuenta', 'cobros_extra', 'mesas', 'turnos_caja', 'pagos', 'movimientos_efectivo', 'trabajos_impresion'], cargar);

  async function accion(fn: () => Promise<unknown>, exito?: string) {
    setOcupado(true);
    try { await fn(); if (exito) aviso(exito); await cargar(); return true; }
    catch (e) { aviso(mensajeDe(e)); await cargar(); return false; }
    finally { setOcupado(false); }
  }

  const nombreMesa = (c: Cuenta) => {
    if (c.tipo === 'llevar') return `Para llevar #${c.folio}`;
    const principal = mesas.find((m) => m.id === c.mesa_id);
    const unidas = mesas.filter((m) => m.unida_a === c.mesa_id).map((m) => m.nombre);
    return [principal?.nombre ?? 'Mesa', ...unidas].join(' + ');
  };
  const totalDe = (id: string) => redondo(
    lineas.filter((l) => l.cuenta_id === id && l.estado === 'activa').reduce((s, l) => s + l.precio_unitario * l.cantidad, 0)
    + extras.filter((x) => x.cuenta_id === id && x.estado === 'activa').reduce((s, x) => s + Number(x.importe), 0));
  const precio = useMemo(() => Object.fromEntries(productos.map((p) => [p.id, p])), [productos]);

  // ---------------------------------------------------------------- Capturar para llevar
  const cuentaLlevar = cuentas.find((c) => c.id === llevar);
  if (llevar === 'nuevo' || cuentaLlevar) {
    const clave = `llevar:${cuentaLlevar?.id ?? 'nuevo'}`;
    return (
      <Pedido
        destino={{
          titulo: cuentaLlevar ? `Para llevar #${cuentaLlevar.folio}` : 'Nuevo pedido para llevar',
          chip: { texto: 'Para llevar', clase: 's-pedido_enviado' },
          lineas: cuentaLlevar ? lineas.filter((l) => l.cuenta_id === cuentaLlevar.id) : [],
          trabajos: cuentaLlevar ? comandas.filter((t) => t.cuenta_id === cuentaLlevar.id) : [],
          bloqueada: false,
          enviar: async (productos, solicitud) => {
            const r = await llamar<{ cuenta_id: string }>('enviar_pedido_llevar',
              { p_cuenta_id: cuentaLlevar?.id ?? null, p_productos: productos, p_solicitud_id: solicitud });
            setSel(r.cuenta_id);
            return r;
          },
        }}
        categorias={categorias} productos={productos} precio={precio}
        borrador={borradores[clave] ?? { items: [] }}
        guardarBorrador={(b: Borrador) => setBorradores((x) => {
          const y = { ...x };
          if (b.items.length || b.solicitud) y[clave] = b; else delete y[clave];
          return y;
        })}
        ocupado={ocupado} accion={accion} volver={() => setLlevar(null)} dentroDePanel
      />
    );
  }

  const abierta = resumen !== null && resumen !== undefined;

  return (
    <main className="ancho" style={{ maxWidth: 1100 }}>
      <div className="nav2">
        <button className={vista === 'cobrar' ? 'on' : ''} onClick={() => setVista('cobrar')}>Cobrar</button>
        <button className={vista === 'caja' ? 'on' : ''} onClick={() => setVista('caja')}>Caja y corte</button>
        <span className={`chip ${abierta ? 'g' : 'r'}`} style={{ alignSelf: 'center' }}>{abierta ? 'Caja abierta' : 'Caja cerrada'}</span>
      </div>
      {resumen === undefined && <p className="cargando">Cargando…</p>}
      {resumen !== undefined && vista === 'cobrar' && (
        <Cobrar
          yo={yo} abierta={abierta} cuentas={cuentas} lineas={lineas} extras={extras} tickets={tickets}
          sel={sel} setSel={setSel} nombre={nombreMesa} totalDe={totalDe} ocupado={ocupado} accion={accion}
          nuevoLlevar={() => setLlevar('nuevo')} agregarLlevar={(id) => setLlevar(id)}
          pendienteNuevo={(borradores['llevar:nuevo']?.items.length ?? 0) > 0}
          irACaja={() => setVista('caja')} verTicket={(t, cambio) => setTicket({ t, cambio })} precuentas={precuentas}
        />
      )}
      {resumen !== undefined && vista === 'caja' && (
        <CajaDelDia resumen={resumen} movs={movs} ocupado={ocupado} accion={accion} />
      )}
      {ticket && <VistaTicket t={ticket.t} cambio={ticket.cambio} cerrar={() => setTicket(null)} />}
    </main>
  );
}

// ---------------------------------------------------------------------------
// Cobrar
// ---------------------------------------------------------------------------
interface PropsCobrar {
  yo: Yo; abierta: boolean; cuentas: CuentaCaja[]; lineas: Linea[]; extras: CobroExtra[]; tickets: Trabajo[];
  sel: string | null; setSel: (id: string | null) => void; nombre: (c: Cuenta) => string; totalDe: (id: string) => number;
  ocupado: boolean; accion: (fn: () => Promise<unknown>, exito?: string) => Promise<boolean>;
  nuevoLlevar: () => void; agregarLlevar: (id: string) => void; pendienteNuevo: boolean;
  irACaja: () => void; verTicket: (t: ContenidoTicket, cambio?: number) => void; precuentas: Trabajo[];
}

function Cobrar(props: PropsCobrar) {
  const { abierta, cuentas, lineas, extras, tickets, sel, setSel, nombre, totalDe } = props;
  const porCobrar = cuentas.filter((c) => c.estado === 'por_cobrar' || (c.tipo === 'llevar' && c.estado === 'abierta'));
  const enServicio = cuentas.filter((c) => c.tipo === 'mesa' && c.estado === 'abierta');
  const cobradas = cuentas.filter((c) => c.estado === 'cobrada');
  const c = cuentas.find((x) => x.id === sel);

  const fila = (x: CuentaCaja, tenue = false) => (
    <button key={x.id} className={`acc ${x.id === sel ? 'on' : ''} ${tenue ? 'tenue' : ''}`} onClick={() => setSel(x.id)}>
      <span>
        <b>{nombre(x)}</b>
        <small>
          Folio {x.folio}
          {x.cobro_anulado_en ? ' · cobro anulado: volver a cobrar' : ''}
          {x.estado === 'cobrada' && x.cobrada_en ? ` · ${fechaHora(x.cobrada_en)}` : ''}
        </small>
      </span>
      <span style={{ textAlign: 'right' }}>
        <span className={`chip ${x.estado === 'por_cobrar' || x.tipo === 'llevar' ? 'g' : ''}`}>
          {x.estado === 'cobrada' ? 'Cobrada' : x.estado === 'por_cobrar' ? 'Por cobrar' : x.tipo === 'llevar' ? 'Para llevar' : 'En servicio'}
        </span><br />
        <b>{dinero(x.estado === 'cobrada' ? Number(x.total) : totalDe(x.id))}</b>
      </span>
    </button>
  );

  return (
    <div className="dos">
      <div className="box">
        <h2>Cuentas</h2>
        {!abierta && (
          <p className="lock">La caja está cerrada. <button className="obs" onClick={props.irACaja}>Abrir caja</button> para cobrar.</p>
        )}
        <button className="btn sec" style={{ width: '100%', marginBottom: 12 }} onClick={props.nuevoLlevar}>
          {props.pendienteNuevo ? 'Seguir capturando el pedido para llevar' : 'Nuevo pedido para llevar'}
        </button>
        <h3 className="sub">Por cobrar</h3>
        {porCobrar.map((x) => fila(x))}
        {!porCobrar.length && <p className="note">Nada por cobrar.</p>}
        {enServicio.length > 0 && <h3 className="sub">En servicio (aún no piden la cuenta)</h3>}
        {enServicio.map((x) => fila(x, true))}
        {cobradas.length > 0 && <h3 className="sub">Cobradas en esta caja</h3>}
        {cobradas.map((x) => fila(x, true))}
      </div>

      {c ? (
        <Detalle key={c.id} {...props} c={c}
                 lineasC={lineas.filter((l) => l.cuenta_id === c.id)} extrasC={extras.filter((x) => x.cuenta_id === c.id)}
                 ticketC={tickets.find((t) => t.cuenta_id === c.id && !t.reimpresion_de)} total={totalDe(c.id)} />
      ) : (
        <div className="box"><p className="note">Elige una cuenta o crea un pedido para llevar.</p></div>
      )}
    </div>
  );
}

function Detalle({ c, lineasC, extrasC, ticketC, total, abierta, nombre, ocupado, accion, agregarLlevar, verTicket, setSel, precuentas }:
  PropsCobrar & { c: CuentaCaja; lineasC: Linea[]; extrasC: CobroExtra[]; ticketC?: Trabajo; total: number }) {
  const [quitando, setQuitando] = useState<string | null>(null);
  const [motivo, setMotivo] = useState('');
  const [cuantos, setCuantos] = useState(1);
  const [extra, setExtra] = useState({ concepto: '', importe: '' });
  const [metodo, setMetodo] = useState<MetodoPago>('efectivo');
  const [monto, setMonto] = useState('');
  const [recibido, setRecibido] = useState('');
  const [pagos, setPagos] = useState<PagoCaptura[]>([]);
  const [propina, setPropina] = useState('');
  const [propinaMetodo, setPropinaMetodo] = useState<MetodoPago>('tarjeta');
  const [solicitud] = useState(() => crypto.randomUUID());

  const cobrada = c.estado === 'cobrada';
  const editable = c.estado === 'abierta' || c.estado === 'por_cobrar';
  const cobrable = abierta && (c.estado === 'por_cobrar' || (c.tipo === 'llevar' && c.estado === 'abierta')) && total > 0;
  const pagado = redondo(pagos.reduce((s, p) => s + p.importe, 0));
  const falta = redondo(total - pagado);
  const prop = Number(propina) || 0;
  const efectivo = pagos.find((p) => p.metodo === 'efectivo');
  const cambio = efectivo?.recibido != null ? redondo(efectivo.recibido - efectivo.importe - (propinaMetodo === 'efectivo' ? prop : 0)) : 0;

  useEffect(() => { setMonto(falta > 0 ? String(falta) : ''); }, [falta]);

  function agregarPago() {
    const v = redondo(Number(monto));
    if (!(v > 0)) return;
    if (pagos.some((p) => p.metodo === metodo)) {
      setPagos(pagos.map((p) => (p.metodo === metodo ? { ...p, importe: redondo(p.importe + v) } : p)));
    } else {
      setPagos([...pagos, { metodo, importe: v, ...(metodo === 'efectivo' && recibido ? { recibido: redondo(Number(recibido)) } : {}) }]);
    }
    setRecibido('');
  }

  async function cobrar() {
    let r: { cambio: number; ticket_id?: string } | null = null;
    const ok = await accion(async () => {
      r = await llamar('cobrar_cuenta', {
        p_cuenta_id: c.id, p_pagos: pagos, p_solicitud_id: solicitud,
        p_propina: prop, p_propina_metodo: prop > 0 ? propinaMetodo : null,
      });
    }, c.tipo === 'mesa' ? `Cobrado. ${nombre(c)} queda libre.` : 'Pedido para llevar cobrado.');
    if (ok && r) {
      const { data } = await supabase.from('trabajos_impresion').select('contenido')
        .eq('cuenta_id', c.id).eq('documento', 'ticket').is('reimpresion_de', null).order('creado_en', { ascending: false }).limit(1).maybeSingle();
      if (data) verTicket(data.contenido as unknown as ContenidoTicket, (r as { cambio: number }).cambio);
      setSel(null);
    }
  }

  return (
    <div className="box">
      <h2>{nombre(c)} <small className="note">· Folio {c.folio}</small></h2>
      {c.cobro_anulado_en && <p className="lock">El cobro anterior de esta cuenta se anuló. Vuelve a cobrarla.</p>}

      {lineasC.filter((l) => l.estado === 'activa').map((l) => (
        <div key={l.id} className="li">
          <span>
            {l.cantidad} × {l.nombre_producto}{l.opcion ? ` · ${l.opcion}` : ''}{l.observacion && <small>{l.observacion}</small>}
            {editable && (quitando === l.id ? (
              <span className="ni">
                <input autoFocus placeholder="Motivo (obligatorio)" value={motivo} onChange={(e) => setMotivo(e.target.value)} aria-label="Motivo" />
                {l.cantidad > 1 && (
                  <select value={cuantos} onChange={(e) => setCuantos(Number(e.target.value))} aria-label="Cantidad a quitar">
                    {Array.from({ length: l.cantidad }, (_, i) => i + 1).map((n) => <option key={n} value={n}>Quitar {n}</option>)}
                  </select>
                )}
                <button className="rm" disabled={!motivo.trim() || ocupado}
                        onClick={async () => {
                          if (await accion(() => llamar('quitar_producto', { p_linea_id: l.id, p_motivo: motivo, p_cantidad: cuantos }),
                            'Producto quitado. Queda registrado con tu usuario.')) { setQuitando(null); setMotivo(''); setPagos([]); }
                        }}>Confirmar</button>
                <button className="rm" onClick={() => setQuitando(null)}>Cancelar</button>
              </span>
            ) : <> <button className="rm" onClick={() => { setQuitando(l.id); setMotivo(''); setCuantos(1); }}>Quitar</button></>)}
          </span>
          <span>{dinero(l.precio_unitario * l.cantidad)}</span>
        </div>
      ))}
      {extrasC.filter((x) => x.estado === 'activa').map((x) => (
        <div key={x.id} className="li">
          <span>
            Cobro extra<small>{x.concepto}</small>
            {editable && (quitando === x.id ? (
              <span className="ni">
                <input autoFocus placeholder="Motivo (obligatorio)" value={motivo} onChange={(e) => setMotivo(e.target.value)} aria-label="Motivo" />
                <button className="rm" disabled={!motivo.trim() || ocupado}
                        onClick={async () => {
                          if (await accion(() => llamar('quitar_cobro_extra', { p_cobro_extra_id: x.id, p_motivo: motivo }), 'Cobro extra quitado.')) {
                            setQuitando(null); setPagos([]);
                          }
                        }}>Confirmar</button>
                <button className="rm" onClick={() => setQuitando(null)}>Cancelar</button>
              </span>
            ) : <> <button className="rm" onClick={() => { setQuitando(x.id); setMotivo(''); }}>Quitar</button></>)}
          </span>
          <span>{dinero(Number(x.importe))}</span>
        </div>
      ))}
      {lineasC.filter((l) => l.estado === 'cancelada').map((l) => (
        <div key={l.id} className="li tachado"><span>{l.nombre_producto}<small>{l.cancelacion_motivo}</small></span><span>—</span></div>
      ))}

      {c.tipo === 'llevar' && c.estado === 'abierta' && (
        <button className="btn sec" style={{ marginTop: 10 }} onClick={() => agregarLlevar(c.id)}>Agregar productos (comanda adicional)</button>
      )}

      {editable && (
        <form className="f" style={{ marginTop: 12 }} onSubmit={async (e) => {
          e.preventDefault();
          if (await accion(() => llamar('agregar_cobro_extra', { p_cuenta_id: c.id, p_concepto: extra.concepto, p_importe: Number(extra.importe) }),
            'Cobro extra agregado. Quedó registrado con tu usuario.')) { setExtra({ concepto: '', importe: '' }); setPagos([]); }
        }}>
          <input placeholder="Cobro extra: ¿qué se cobra? (obligatorio)" value={extra.concepto} aria-label="Concepto del cobro extra"
                 onChange={(e) => setExtra({ ...extra, concepto: e.target.value })} />
          <input type="number" min="0" step="0.5" placeholder="Monto" style={{ width: 100 }} value={extra.importe} aria-label="Monto del cobro extra"
                 onChange={(e) => setExtra({ ...extra, importe: e.target.value })} />
          <button className="btn s" disabled={ocupado || !extra.concepto.trim() || !(Number(extra.importe) > 0)}>Agregar cobro extra</button>
        </form>
      )}

      <div className="grande"><span>Total</span><span>{dinero(cobrada ? Number(c.total) : total)}</span></div>

      {editable && total > 0 && (
        <button className="btn s" disabled={ocupado} style={{ marginBottom: 8 }}
                onClick={() => accion(() => llamar('imprimir_precuenta', { p_cuenta_id: c.id }), 'La cuenta se manda a la impresora de caja (no es cobro).')}>
          Imprimir cuenta
        </button>
      )}
      {(() => {
        // Estado de la última cuenta impresa: así se nota si la impresora no la sacó.
        const u = precuentas.find((t) => t.cuenta_id === c.id);
        if (!u || !editable) return null;
        return (
          <p className="note" style={{ marginTop: 0 }}>
            Cuenta impresa a las {new Date(u.creado_en).toLocaleTimeString('es-MX', { hour: '2-digit', minute: '2-digit' })}: <EstadoImp estado={u.estado} error={u.ultimo_error} impresoTexto="✓ Impresa" />
            {u.estado === 'error' && (
              <>
                {u.ultimo_error && <span className="falta"> {u.ultimo_error}</span>}{' '}
                <button className="rm" disabled={ocupado} onClick={() => accion(() => llamar('reintentar_impresion', { p_trabajo_id: u.id }), 'Se manda otra vez a la impresora de caja')}>Reintentar</button>
              </>
            )}
            {u.estado === 'pendiente' && <span> · si no sale en unos segundos, revisa en Comandas que la computadora de caja esté conectada.</span>}
          </p>
        );
      })()}

      {cobrada && (
        <>
          <p className="rem ok">Cuenta cobrada.</p>
          {ticketC && <button className="btn s" onClick={() => verTicket(ticketC.contenido as unknown as ContenidoTicket)}>Ver ticket</button>}{' '}
          <button className="btn s" disabled={ocupado} onClick={() => accion(() => llamar('reimprimir_ticket', { p_cuenta_id: c.id }), 'Ticket enviado a la impresora de caja')}>
            Reimprimir ticket
          </button>
        </>
      )}

      {!cobrada && !cobrable && (
        <p className="lock">
          {!abierta ? 'Abre la caja para cobrar.'
            : c.tipo === 'mesa' && c.estado === 'abierta' ? 'El cobro se habilita cuando el mesero pide la cuenta.'
            : 'Agrega productos para cobrar.'}
        </p>
      )}

      {cobrable && (
        <>
          <h3 className="sub">Pago</h3>
          <div className="ms">
            {(['efectivo', 'tarjeta', 'transferencia'] as MetodoPago[]).map((m) => (
              <button key={m} className={`m ${metodo === m ? 'on' : ''}`} onClick={() => setMetodo(m)}>{METODO[m]}</button>
            ))}
          </div>
          <div className="f">
            <input type="number" min="0" step="0.5" value={monto} onChange={(e) => setMonto(e.target.value)} aria-label="Monto del pago" style={{ width: 120 }} />
            {metodo === 'efectivo' && (
              <input type="number" min="0" step="0.5" placeholder="Con cuánto paga" value={recibido} aria-label="Efectivo recibido"
                     onChange={(e) => setRecibido(e.target.value)} style={{ width: 150 }} />
            )}
            <button className="btn" onClick={agregarPago} disabled={!(Number(monto) > 0)}>Agregar pago</button>
          </div>
          {pagos.map((p) => (
            <div key={p.metodo} className="li">
              <span>{METODO[p.metodo]}{p.recibido != null && <small>Paga con {dinero(p.recibido)}</small>}</span>
              <span>{dinero(p.importe)} <button className="rm" onClick={() => setPagos(pagos.filter((x) => x.metodo !== p.metodo))}>Quitar</button></span>
            </div>
          ))}
          <p className={`rem ${falta === 0 ? 'ok' : 'no'}`}>
            {falta > 0 ? `Falta ${dinero(falta)}` : falta < 0 ? `Excede por ${dinero(-falta)}` : 'Cuenta cubierta'}
          </p>
          <div className="f">
            <input type="number" min="0" step="0.5" placeholder="Propina (terminal)" value={propina} onChange={(e) => setPropina(e.target.value)}
                   aria-label="Propina" style={{ width: 170 }} />
            <select value={propinaMetodo} onChange={(e) => setPropinaMetodo(e.target.value as MetodoPago)} aria-label="Método de la propina">
              <option value="tarjeta">Tarjeta</option><option value="efectivo">Efectivo</option>
            </select>
          </div>
          <p className="note">La propina se registra aparte: no es venta y se entrega a los meseros.</p>
          {efectivo?.recibido != null && (
            <p className={`rem ${cambio >= 0 ? 'ok' : 'no'}`}>{cambio >= 0 ? `Cambio: ${dinero(cambio)}` : `El efectivo no alcanza: faltan ${dinero(-cambio)}`}</p>
          )}
          <button className="btn big" disabled={ocupado || falta !== 0 || !pagos.length || cambio < 0} onClick={cobrar}>
            {ocupado ? 'Cobrando…' : 'Cobrar e imprimir ticket'}
          </button>
        </>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Caja del día: abrir, movimientos y corte
// ---------------------------------------------------------------------------
function CajaDelDia({ resumen, movs, ocupado, accion }: {
  resumen: Resumen | null; movs: Movimiento[]; ocupado: boolean;
  accion: (fn: () => Promise<unknown>, exito?: string) => Promise<boolean>;
}) {
  const [fondo, setFondo] = useState('500');
  const [mov, setMov] = useState({ tipo: 'retiro', importe: '', motivo: '' });
  const [contado, setContado] = useState('');

  if (!resumen) {
    return (
      <div className="box" style={{ maxWidth: 440 }}>
        <h2>Abrir caja</h2>
        <p className="note">Registra el fondo inicial de efectivo para empezar el día.</p>
        <form className="f" style={{ marginTop: 8 }} onSubmit={(e) => {
          e.preventDefault();
          accion(() => llamar('abrir_caja', { p_fondo: Number(fondo) }), 'Caja abierta');
        }}>
          <input type="number" min="0" step="0.5" value={fondo} onChange={(e) => setFondo(e.target.value)} aria-label="Fondo inicial" style={{ width: 140 }} />
          <button className="btn" disabled={ocupado || fondo === ''}>Abrir caja</button>
        </form>
      </div>
    );
  }

  const cont = contado === '' ? null : Number(contado);
  return (
    <div className="dos">
      <div className="box">
        <h2>Entradas y retiros de efectivo</h2>
        <form className="f" onSubmit={async (e) => {
          e.preventDefault();
          if (await accion(() => llamar('registrar_movimiento', { p_tipo: mov.tipo, p_importe: Number(mov.importe), p_motivo: mov.motivo }),
            'Movimiento registrado')) setMov({ ...mov, importe: '', motivo: '' });
        }}>
          <select value={mov.tipo} onChange={(e) => setMov({ ...mov, tipo: e.target.value })} aria-label="Tipo de movimiento">
            <option value="retiro">Retiro</option><option value="entrada">Entrada</option>
          </select>
          <input type="number" min="0" step="0.5" placeholder="Monto" style={{ width: 100 }} value={mov.importe} aria-label="Monto del movimiento"
                 onChange={(e) => setMov({ ...mov, importe: e.target.value })} />
          <input placeholder="Motivo (obligatorio)" value={mov.motivo} aria-label="Motivo del movimiento" style={{ flex: '1 1 100%' }}
                 onChange={(e) => setMov({ ...mov, motivo: e.target.value })} />
          <button className="btn" disabled={ocupado || !(Number(mov.importe) > 0) || !mov.motivo.trim()}>Registrar</button>
        </form>
        {movs.map((m) => (
          <div key={m.id} className="li"><span>{m.tipo === 'entrada' ? 'Entrada' : 'Retiro'} · {m.motivo}</span>
            <span>{m.tipo === 'retiro' ? '−' : '+'}{dinero(Number(m.importe))}</span></div>
        ))}
        {!movs.length && <p className="note">Sin movimientos.</p>}
        <p className="note">Si entregas a los meseros las propinas con tarjeta en efectivo, regístralo aquí como retiro.</p>
      </div>
      <div className="box">
        <h2>Corte de caja</h2>
        <p className="note">Caja abierta desde {resumen.abierto_en ? fechaHora(resumen.abierto_en) : ''}</p>
        <CifrasCorte r={resumen} contado={cont} />
        <div className="f" style={{ marginTop: 10 }}>
          <label htmlFor="contado"><b>Efectivo contado</b></label>
          <input id="contado" type="number" min="0" step="0.5" value={contado} onChange={(e) => setContado(e.target.value)} style={{ width: 140 }} />
        </div>
        {resumen.cuentas_abiertas > 0 && (
          <p className="lock">Hay {resumen.cuentas_abiertas} cuenta(s) sin cobrar. Cóbralas antes del corte si ya se fueron los clientes.</p>
        )}
        <button className="btn big" disabled={ocupado || contado === ''}
                onClick={() => {
                  if (resumen.cuentas_abiertas > 0 && !confirm('Hay cuentas sin cobrar. ¿Hacer el corte de todos modos?')) return;
                  accion(() => llamar('cerrar_caja', { p_efectivo_contado: Number(contado) }),
                    'Corte guardado y enviado al propietario para su aprobación.');
                }}>
          Realizar corte y enviar al propietario
        </button>
      </div>
    </div>
  );
}
