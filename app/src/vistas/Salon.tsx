import { useCallback, useEffect, useMemo, useState } from 'react';
import { llamar, mensajeDe, supabase } from '../lib/supabase';
import { useEnVivo } from '../lib/vivo';
import { useAviso } from '../componentes/Aviso';
import { EstadoImp } from '../componentes/Comanda';
import ListaComandas from '../componentes/ListaComandas';
import {
  CAMPOS_TRABAJO, ESTADO_MESA, dinero, estadoDeComandas, type Categoria, type Cuenta, type Linea, type Mesa, type Producto,
  type Trabajo, type Yo,
} from '../lib/tipos';

// Pedido que el mesero va armando antes de enviarlo. Se guarda en el teléfono
// para no perderlo si se cierra la app; "solicitud" evita duplicar un envío
// que se reintenta después de un corte de señal.
// Cada pieza se anota por separado, con su propia observación y sus propios
// sabores o guisados. Al enviar, las piezas idénticas viajan juntas.
interface Pieza { id: string; producto_id: string; opciones: string[]; observacion: string }
interface Borrador { items: Pieza[]; solicitud?: string }
const nombreLinea = (nombre: string, opcion?: string | null) => (opcion ? `${nombre} · ${opcion}` : nombre);
// Mismo texto que guarda el servidor: "Deshebrada, Pollo" o, si las selecciones
// tienen nombres distintos, "Guisado del sope: Deshebrada, Pata o cueritos: Pata curtida".
function textoPieza(x: Pieza, p?: Producto) {
  const sel = p?.selecciones ?? [];
  const conNombre = new Set(sel.map((s) => s.etiqueta)).size > 1;
  return x.opciones.map((o, i) => (o && conNombre ? `${sel[i]?.etiqueta}: ${o}` : o)).filter(Boolean).join(', ');
}
const completa = (x: Pieza, p?: Producto) =>
  !p || !p.selecciones?.length || (x.opciones.length === p.selecciones.length && x.opciones.every(Boolean));
// Nombre de la primera selección que falta elegir ("guisado", "pata o cueritos").
const faltante = (x: Pieza, p?: Producto) =>
  (p?.selecciones.find((_, i) => !x.opciones[i])?.etiqueta ?? 'opción').toLowerCase();
type Borradores = Record<string, Borrador>;
const CLAVE_BORRADORES = 'la-merced-borradores';

function leerBorradores(): Borradores {
  try {
    const datos = JSON.parse(localStorage.getItem(CLAVE_BORRADORES) ?? '{}') as Record<string, { items: Record<string, unknown>[]; solicitud?: string }>;
    // Borradores de la versión anterior (cantidad por producto): se pasan a piezas.
    for (const b of Object.values(datos)) {
      b.items = b.items.flatMap((x) => x.id ? [x] : Array.from({ length: Number(x.cantidad) || 1 }, () => ({
        id: crypto.randomUUID(), producto_id: x.producto_id, opciones: x.opcion ? [x.opcion] : [], observacion: x.observacion ?? '',
      })));
    }
    return datos as unknown as Borradores;
  } catch { return {}; }
}

// Piezas idénticas (mismo producto, opciones y observación) se envían juntas.
function agrupar(items: Pieza[]) {
  const grupos = new Map<string, { producto_id: string; cantidad: number; observacion: string; opciones?: string[] }>();
  for (const x of items) {
    const clave = `${x.producto_id}|${x.opciones.join('|')}|${x.observacion.trim()}`;
    const g = grupos.get(clave);
    if (g) g.cantidad += 1;
    else grupos.set(clave, { producto_id: x.producto_id, cantidad: 1, observacion: x.observacion.trim(),
                             ...(x.opciones.length ? { opciones: x.opciones } : {}) });
  }
  return [...grupos.values()];
}

interface Grupo { principal: Mesa; miembros: Mesa[]; nombre: string; cuenta?: Cuenta; lineas: Linea[]; trabajos: Trabajo[] }

export default function Salon({ yo, salir, dentroDePanel = false }: { yo: Yo; salir?: () => void; dentroDePanel?: boolean }) {
  const aviso = useAviso();
  const [mesas, setMesas] = useState<Mesa[]>([]);
  const [cuentas, setCuentas] = useState<Cuenta[]>([]);
  const [lineas, setLineas] = useState<Linea[]>([]);
  const [trabajos, setTrabajos] = useState<Trabajo[]>([]);
  const [categorias, setCategorias] = useState<Categoria[]>([]);
  const [productos, setProductos] = useState<Producto[]>([]);
  const [cargado, setCargado] = useState(false);
  const [error, setError] = useState('');

  const [abierta, setAbierta] = useState<string | null>(null); // mesa principal en pantalla
  const [uniendo, setUniendo] = useState(false);
  const [elegidas, setElegidas] = useState<string[]>([]);
  const [borradores, setBorradores] = useState<Borradores>(leerBorradores);
  const [ocupado, setOcupado] = useState(false);

  useEffect(() => {
    try { localStorage.setItem(CLAVE_BORRADORES, JSON.stringify(borradores)); } catch { /* sin almacenamiento */ }
  }, [borradores]);

  const cargar = useCallback(async () => {
    const [m, c, k, p] = await Promise.all([
      supabase.from('mesas').select('id, nombre, orden, activa, estado, unida_a, eliminada_en')
        .eq('activa', true).is('eliminada_en', null).order('orden').order('nombre'),
      supabase.from('cuentas').select('id, folio, tipo, mesa_id, estado, mesero_id, cobro_anulado_en')
        .eq('tipo', 'mesa').in('estado', ['abierta', 'por_cobrar']).is('cobro_anulado_en', null),
      supabase.from('categorias').select('id, nombre, orden').order('orden'),
      supabase.from('productos').select('id, categoria_id, nombre, descripcion, precio, estado, orden, selecciones').order('orden'),
    ]);
    const fallo = m.error ?? c.error ?? k.error ?? p.error;
    if (fallo) { setError(mensajeDe(fallo)); return; }
    const ids = (c.data ?? []).map((x) => x.id);
    const l = ids.length
      ? await supabase.from('lineas_cuenta')
          .select('id, cuenta_id, producto_id, nombre_producto, precio_unitario, cantidad, observacion, opcion, estado, cancelacion_motivo, enviada_en, reemplaza_linea_id, creado_en')
          .in('cuenta_id', ids).order('creado_en')
      : { data: [], error: null };
    if (l.error) { setError(mensajeDe(l.error)); return; }
    const t = ids.length
      ? await supabase.from('trabajos_impresion').select(CAMPOS_TRABAJO)
          .eq('documento', 'comanda').in('cuenta_id', ids).order('creado_en', { ascending: false })
      : { data: [], error: null };
    if (t.error) { setError(mensajeDe(t.error)); return; }
    setError('');
    setMesas(m.data as Mesa[]);
    setCuentas(c.data as Cuenta[]);
    setCategorias(k.data as Categoria[]);
    setProductos(p.data as Producto[]);
    setLineas(l.data as Linea[]);
    setTrabajos(t.data as unknown as Trabajo[]);
    setCargado(true);
  }, []);

  useEffect(() => { cargar(); }, [cargar]);
  useEnVivo(['mesas', 'cuentas', 'lineas_cuenta', 'trabajos_impresion'], cargar);

  const grupos = useMemo<Grupo[]>(() => mesas.filter((m) => !m.unida_a).map((principal) => {
    const miembros = [principal, ...mesas.filter((m) => m.unida_a === principal.id)];
    const cuenta = cuentas.find((c) => c.mesa_id === principal.id);
    return {
      principal, miembros, cuenta,
      nombre: miembros.map((m) => m.nombre).join(' + '),
      lineas: cuenta ? lineas.filter((l) => l.cuenta_id === cuenta.id) : [],
      trabajos: cuenta ? trabajos.filter((t) => t.cuenta_id === cuenta.id) : [],
    };
  }), [mesas, cuentas, lineas, trabajos]);

  const precio = useMemo(() => Object.fromEntries(productos.map((p) => [p.id, p])), [productos]);
  const totalActivo = (g: Grupo) => g.lineas.filter((l) => l.estado === 'activa')
    .reduce((s, l) => s + l.precio_unitario * l.cantidad, 0);
  const piezas = (g: Grupo) => g.lineas.filter((l) => l.estado === 'activa').reduce((s, l) => s + l.cantidad, 0);

  async function accion(fn: () => Promise<unknown>, exito?: string) {
    setOcupado(true);
    try {
      await fn();
      if (exito) aviso(exito);
      await cargar();
      return true;
    } catch (e) {
      aviso(mensajeDe(e));
      await cargar();
      return false;
    } finally {
      setOcupado(false);
    }
  }

  async function tocarMesa(g: Grupo) {
    if (uniendo) {
      setElegidas((xs) => xs.includes(g.principal.id) ? xs.filter((x) => x !== g.principal.id) : [...xs, g.principal.id]);
      return;
    }
    setAbierta(g.principal.id);
    if (g.principal.estado === 'disponible') {
      await accion(() => llamar('ocupar_mesa', { p_mesa_id: g.principal.id }));
    }
  }

  async function unir() {
    setOcupado(true);
    try {
      const principal = await llamar<string>('unir_mesas', { p_mesa_ids: elegidas });
      // Lo que se iba armando en cada mesa pasa a la mesa principal.
      setBorradores((x) => {
        const y = { ...x };
        const juntos: Borrador['items'] = [];
        for (const id of [principal, ...elegidas.filter((e) => e !== principal)]) {
          juntos.push(...(y[id]?.items ?? []));
          delete y[id];
        }
        if (juntos.length) y[principal] = { items: juntos };
        return y;
      });
      setUniendo(false);
      setElegidas([]);
      aviso('Mesas unidas');
    } catch (e) {
      aviso(mensajeDe(e));
    } finally {
      setOcupado(false);
      await cargar();
    }
  }

  const grupo = grupos.find((g) => g.principal.id === abierta);
  useEffect(() => {
    // Si la mesa abierta se unió a otra (desde otro teléfono), se sigue en la principal.
    if (abierta && cargado && !grupos.some((g) => g.principal.id === abierta)) {
      setAbierta(mesas.find((m) => m.id === abierta)?.unida_a ?? null);
    }
  }, [abierta, cargado, grupos, mesas]);

  const encabezado = (contenido: React.ReactNode) => dentroDePanel ? null : (
    <header className="top">{contenido}</header>
  );

  if (grupo) {
    return (
      <Pedido
        yo={yo} grupo={grupo} categorias={categorias} productos={productos} precio={precio}
        borrador={borradores[grupo.principal.id] ?? { items: [] }}
        guardarBorrador={(b) => setBorradores((x) => {
          const y = { ...x };
          if (b.items.length || b.solicitud) y[grupo.principal.id] = b; else delete y[grupo.principal.id];
          return y;
        })}
        ocupado={ocupado} accion={accion} dentroDePanel={dentroDePanel}
        volver={async () => {
          const sinNada = !grupo.cuenta && !(borradores[grupo.principal.id]?.items.length);
          setAbierta(null);
          if (sinNada && grupo.principal.estado === 'ocupada') {
            await accion(() => llamar('liberar_mesa', { p_mesa_id: grupo.principal.id }));
          }
        }}
      />
    );
  }

  return (
    <div className="movil">
      {encabezado(<>
        <h1>La Merced</h1>
        <span className="quien"><small>{yo.nombre} · Mesero</small>{salir && <button className="salir" onClick={salir}>Salir</button>}</span>
      </>)}
      <main>
        {error && <p className="lock er">{error}</p>}
        <div className="bar">
          <h2>Mesas</h2>
          {uniendo
            ? <button className="ghost" onClick={() => { setUniendo(false); setElegidas([]); }}>Cancelar</button>
            : <button className="ghost" onClick={() => setUniendo(true)}>Unir mesas</button>}
        </div>
        {uniendo && <p className="hint">Elige las mesas que quieres unir.</p>}
        {!cargado && <p className="cargando">Cargando mesas…</p>}
        {cargado && grupos.length === 0 && <p className="vacio">No hay mesas activas. El propietario puede agregarlas.</p>}
        <div className="grid">
          {grupos.map((g) => {
            const borrador = borradores[g.principal.id]?.items.length ?? 0;
            return (
              <div key={g.principal.id} className={`tcard ${g.miembros.length > 1 ? 'wide' : ''}`}>
                <button className={`tbl ${elegidas.includes(g.principal.id) ? 'pick' : ''}`} onClick={() => tocarMesa(g)}
                        aria-label={`${g.nombre}, ${ESTADO_MESA[g.principal.estado]}`}>
                  <b>{g.nombre}</b>
                  <span className={`st s-${g.principal.estado}`}>{ESTADO_MESA[g.principal.estado]}</span>
                  <small>
                    {g.cuenta ? `${piezas(g)} productos · ${dinero(totalActivo(g))}` : 'Sin pedido'}
                    {borrador ? ` · ${borrador} sin enviar` : ''}
                  </small>
                  {estadoDeComandas(g.trabajos) && <EstadoImp estado={estadoDeComandas(g.trabajos)!} />}
                </button>
                {g.miembros.length > 1 && !uniendo && (
                  <button className="sep" disabled={ocupado}
                          onClick={() => accion(() => llamar('separar_mesas', { p_mesa_id: g.principal.id }), 'Mesas separadas')}>
                    Separar mesas
                  </button>
                )}
              </div>
            );
          })}
        </div>
        {uniendo && elegidas.length >= 2 && (
          <button className="cta" disabled={ocupado} onClick={unir}>Unir {elegidas.length} mesas</button>
        )}
      </main>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Pantalla de pedido de una mesa
// ---------------------------------------------------------------------------
interface PropsPedido {
  yo: Yo; grupo: Grupo; categorias: Categoria[]; productos: Producto[]; precio: Record<string, Producto>;
  borrador: Borrador; guardarBorrador: (b: Borrador) => void;
  ocupado: boolean; accion: (fn: () => Promise<unknown>, exito?: string) => Promise<boolean>;
  volver: () => void; dentroDePanel: boolean;
}

function Pedido({ grupo, categorias, productos, precio, borrador, guardarBorrador, ocupado, accion, volver, dentroDePanel }: PropsPedido) {
  const [cat, setCat] = useState(categorias[0]?.id ?? '');
  const [notaDe, setNotaDe] = useState<string | null>(null);
  const [nota, setNota] = useState('');
  const [hoja, setHoja] = useState(false);
  const [quitando, setQuitando] = useState<string | null>(null);
  const [motivo, setMotivo] = useState('');
  const [cuantos, setCuantos] = useState(1);

  useEffect(() => { if (!cat && categorias[0]) setCat(categorias[0].id); }, [cat, categorias]);

  const bloqueada = grupo.principal.estado === 'por_cobrar';
  const enviadas = grupo.lineas.filter((l) => l.estado === 'activa');
  const canceladas = grupo.lineas.filter((l) => l.estado === 'cancelada');
  const items = borrador.items;
  const totalBorrador = items.reduce((s, x) => s + (precio[x.producto_id]?.precio ?? 0), 0);
  const total = enviadas.reduce((s, l) => s + l.precio_unitario * l.cantidad, 0) + totalBorrador;
  const piezas = enviadas.reduce((s, l) => s + l.cantidad, 0) + items.length;
  const incompletas = items.filter((x) => !completa(x, precio[x.producto_id]));

  // Cambiar el pedido invalida el identificador de un envío anterior fallido.
  function agregar(p: Producto, opcion?: string) {
    const opciones = p.selecciones.map((_, i) => (i === 0 && opcion) || '');
    guardarBorrador({ items: [...items, { id: crypto.randomUUID(), producto_id: p.id, opciones, observacion: '' }] });
  }
  function quitarPieza(id: string) {
    guardarBorrador({ items: items.filter((x) => x.id !== id) });
    if (notaDe === id) setNotaDe(null);
  }
  function cambiarPieza(id: string, cambio: Partial<Pieza>) {
    guardarBorrador({ items: items.map((x) => (x.id === id ? { ...x, ...cambio } : x)) });
  }
  function guardarNota(id: string) {
    cambiarPieza(id, { observacion: nota.trim() });
    setNotaDe(null);
  }

  async function enviar() {
    const solicitud = borrador.solicitud ?? crypto.randomUUID();
    guardarBorrador({ ...borrador, solicitud });
    const ok = await accion(() => llamar('enviar_pedido', {
      p_mesa_id: grupo.principal.id, p_productos: agrupar(items), p_solicitud_id: solicitud,
    }), enviadas.length ? 'Pedido adicional enviado. La comanda va a la impresora de cocina.' : 'Pedido enviado. La comanda va a la impresora de cocina.');
    if (ok) {
      guardarBorrador({ items: [] });
      setHoja(false);
      volver();
    }
  }

  async function quitar(l: Linea) {
    if (!motivo.trim()) return;
    const ok = await accion(() => llamar('quitar_producto', { p_linea_id: l.id, p_motivo: motivo.trim(), p_cantidad: cuantos }),
      'Producto quitado. Cocina recibe el aviso CANCELADO y queda registrado con tu usuario.');
    if (ok) { setQuitando(null); setMotivo(''); setCuantos(1); }
  }

  async function pedirCuenta() {
    const ok = await accion(() => llamar('pedir_cuenta', { p_mesa_id: grupo.principal.id }), 'Cuenta solicitada. Avisa al cajero.');
    if (ok) { setHoja(false); volver(); }
  }

  return (
    <div className="movil">
      <header className="top" style={dentroDePanel ? { position: 'static' } : undefined}>
        <div>
          <button className="back" onClick={volver}>‹ Mesas</button>
          <h1>{grupo.nombre}</h1>
        </div>
        <span className={`st s-${grupo.principal.estado}`} style={{ marginLeft: 'auto' }}>{ESTADO_MESA[grupo.principal.estado]}</span>
      </header>

      {!bloqueada && (
        <nav className="tabs" aria-label="Categorías" style={dentroDePanel ? { position: 'static' } : undefined}>
          {categorias.map((c) => (
            <button key={c.id} className={`tab ${c.id === cat ? 'on' : ''}`} onClick={() => { setCat(c.id); setNotaDe(null); }}>{c.nombre}</button>
          ))}
        </nav>
      )}

      <main>
        {grupo.trabajos.some((t) => t.estado === 'error') && (
          <>
            <p className="lock er">Una comanda no se imprimió. Revisa la impresora de cocina y vuelve a intentar.</p>
            <button className="cta" style={{ margin: '0 0 16px' }} disabled={ocupado}
                    onClick={() => accion(async () => {
                      for (const t of grupo.trabajos.filter((x) => x.estado === 'error')) {
                        await llamar('reintentar_impresion', { p_trabajo_id: t.id });
                      }
                    }, 'Comanda enviada de nuevo a la impresora')}>
              Reintentar impresión
            </button>
          </>
        )}
        {bloqueada && <p className="lock">Cuenta solicitada. El cajero registrará el cobro y liberará la mesa.</p>}
        {!bloqueada && productos.filter((p) => p.categoria_id === cat).map((p) => {
          const mias = items.filter((x) => x.producto_id === p.id);
          const agotado = p.estado === 'agotado';
          const unaOpcion = p.selecciones.length === 1;
          const varias = p.selecciones.length > 1;
          const repetidas = new Set(p.selecciones.map((x) => x.etiqueta)).size === 1;
          return (
            <div key={p.id} className={`prod ${mias.length ? 'has' : ''} ${agotado ? 'agotado' : ''}`}>
              <div className="rh">
                <div><h3>{p.nombre}</h3>{p.descripcion && <p>{p.descripcion}</p>}</div>
                <span className="pr">{dinero(p.precio)}</span>
              </div>
              {agotado ? <p className="note">Agotado</p> : (
                <>
                  {mias.map((x, n) => (
                    <div key={x.id} className="pieza">
                      <div className="pieza-top">
                        <span>
                          {unaOpcion ? <><b>{n + 1}.</b> {x.opciones[0]}</>
                            : varias ? <><b>{n + 1}.</b> {textoPieza(x, p) || 'Elige las opciones'}</>
                            : <b>Pieza {n + 1}</b>}
                        </span>
                        <button className="rm" onClick={() => quitarPieza(x.id)} aria-label={`Quitar ${p.nombre} ${n + 1}`}>Quitar</button>
                      </div>
                      {varias && (
                        <div className="slots">
                          {p.selecciones.map((sel, k) => {
                            const nombre = sel.etiqueta.toLowerCase() + (repetidas ? ` ${k + 1}` : '');
                            return (
                              <select key={k} value={x.opciones[k] ?? ''} aria-label={`${nombre} de ${p.nombre} ${n + 1}`}
                                      className={x.opciones[k] ? '' : 'vacio'}
                                      onChange={(e) => cambiarPieza(x.id, {
                                        opciones: p.selecciones.map((_, z) => (z === k ? e.target.value : x.opciones[z] ?? '')),
                                      })}>
                                <option value="">Elige {nombre}…</option>
                                {sel.opciones.map((op) => <option key={op} value={op}>{op}</option>)}
                              </select>
                            );
                          })}
                        </div>
                      )}
                      {x.observacion && notaDe !== x.id && <p className="nv">{x.observacion}</p>}
                      {notaDe === x.id ? (
                        <div className="ni">
                          <input autoFocus value={nota} placeholder="Ej. sin crema, extra rábanos" aria-label={`Observación para ${p.nombre} ${n + 1}`}
                                 onChange={(e) => setNota(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && guardarNota(x.id)} />
                          <button className="add" onClick={() => guardarNota(x.id)}>Guardar</button>
                        </div>
                      ) : (
                        <button className="obs" onClick={() => { setNotaDe(x.id); setNota(x.observacion); }}
                                aria-label={`${x.observacion ? 'Editar' : 'Agregar'} observación de ${p.nombre} ${n + 1}`}>
                          {x.observacion ? 'Editar observación' : 'Agregar observación'}
                        </button>
                      )}
                    </div>
                  ))}
                  {unaOpcion ? (
                    <div className="opciones" role="group" aria-label={`${p.selecciones[0].etiqueta} de ${p.nombre}`}>
                      {p.selecciones[0].opciones.map((o) => <button key={o} className="opc" onClick={() => agregar(p, o)}>+ {o}</button>)}
                    </div>
                  ) : (
                    <div className="rc">
                      <button className="add" onClick={() => agregar(p)} aria-label={`Agregar ${p.nombre}`}>{mias.length ? 'Agregar otro' : 'Agregar'}</button>
                    </div>
                  )}
                </>
              )}
            </div>
          );
        })}
      </main>

      <div className="fab">
        <button className="cta" onClick={() => setHoja(true)} disabled={!piezas && !canceladas.length}>
          <span>Revisar pedido · {piezas} productos</span><span>{dinero(total)}</span>
        </button>
      </div>

      {hoja && (
        <div className="sheet" onClick={(e) => { if (e.target === e.currentTarget) { setHoja(false); setQuitando(null); } }}>
          <div className="pane" role="dialog" aria-label="Revisar pedido">
            <h2>{grupo.nombre}</h2>

            {enviadas.length > 0 && <h3>Ya enviado a cocina</h3>}
            {enviadas.map((l) => (
              <div key={l.id} className="li old">
                <span>
                  {l.cantidad} × {nombreLinea(l.nombre_producto, l.opcion)}{l.observacion && <small>{l.observacion}</small>}
                  {quitando === l.id ? (
                    <span className="ni">
                      <input autoFocus placeholder="Motivo (obligatorio)" value={motivo} onChange={(e) => setMotivo(e.target.value)} aria-label="Motivo" />
                      {l.cantidad > 1 && (
                        <select value={cuantos} onChange={(e) => setCuantos(Number(e.target.value))} aria-label="Cantidad a quitar">
                          {Array.from({ length: l.cantidad }, (_, i) => i + 1).map((n) => <option key={n} value={n}>Quitar {n}</option>)}
                        </select>
                      )}
                      <button className="rm" disabled={!motivo.trim() || ocupado} onClick={() => quitar(l)}>Confirmar</button>
                      <button className="rm" onClick={() => { setQuitando(null); setMotivo(''); }}>Cancelar</button>
                    </span>
                  ) : (
                    <> <button className="rm" onClick={() => { setQuitando(l.id); setMotivo(''); setCuantos(1); }}>Quitar</button></>
                  )}
                </span>
                <span>{dinero(l.precio_unitario * l.cantidad)}</span>
              </div>
            ))}

            {canceladas.length > 0 && <h3>Quitados</h3>}
            {canceladas.map((l) => {
              // Si se quitó solo una parte, lo que queda es otra línea que reemplaza a esta.
              const queda = grupo.lineas.find((x) => x.reemplaza_linea_id === l.id)?.cantidad ?? 0;
              return (
                <div key={l.id} className="li tachado">
                  <span>{l.cantidad - queda} × {nombreLinea(l.nombre_producto, l.opcion)}<small>{l.cancelacion_motivo}</small></span><span>—</span>
                </div>
              );
            })}

            {items.length > 0 && <h3>{enviadas.length ? 'Nueva comanda' : 'Pedido nuevo'}</h3>}
            {items.map((x) => (
              <div key={x.id} className="li">
                <span>
                  1 × {nombreLinea(precio[x.producto_id]?.nombre ?? 'Producto', textoPieza(x, precio[x.producto_id]))}
                  {x.observacion && <small>{x.observacion}</small>}
                  {!completa(x, precio[x.producto_id]) && <span className="falta"> Falta elegir {faltante(x, precio[x.producto_id])}</span>}
                  {' '}<button className="rm" onClick={() => quitarPieza(x.id)}>Quitar</button>
                </span>
                <span>{dinero(precio[x.producto_id]?.precio ?? 0)}</span>
              </div>
            ))}

            <div className="tot"><span>Total acumulado</span><span>{dinero(total)}</span></div>
            {grupo.trabajos.length > 0 && (
              <>
                <h3>Comandas a cocina</h3>
                <ListaComandas trabajos={grupo.trabajos} accion={accion} ocupado={ocupado} />
              </>
            )}
            {borrador.solicitud && items.length > 0 && (
              <p className="lock er" style={{ marginTop: 12 }}>El envío anterior no se confirmó. Vuelve a enviar: no se duplicará.</p>
            )}
            {incompletas.length > 0 && (
              <p className="lock er" style={{ marginTop: 12 }}>
                Falta elegir {faltante(incompletas[0], precio[incompletas[0].producto_id])} en {precio[incompletas[0].producto_id]?.nombre}.
              </p>
            )}
            {items.length > 0 && (
              <button className="cta" disabled={ocupado || incompletas.length > 0} onClick={enviar}>{ocupado ? 'Enviando…' : 'Enviar a cocina'}</button>
            )}
            {!items.length && enviadas.length > 0 && !bloqueada && (
              <button className="cta" disabled={ocupado} onClick={pedirCuenta}>Pedir la cuenta</button>
            )}
            <button className="sec" onClick={() => { setHoja(false); setQuitando(null); }}>Seguir pidiendo</button>
          </div>
        </div>
      )}
    </div>
  );
}
