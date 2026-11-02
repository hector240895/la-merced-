import { useCallback, useEffect, useMemo, useState } from 'react';
import { llamar, mensajeDe, supabase } from '../lib/supabase';
import { useEnVivo } from '../lib/vivo';
import { useAviso } from '../componentes/Aviso';
import {
  ESTADO_MESA, dinero, type Categoria, type Cuenta, type Linea, type Mesa, type Producto, type Yo,
} from '../lib/tipos';

// Pedido que el mesero va armando antes de enviarlo. Se guarda en el teléfono
// para no perderlo si se cierra la app; "solicitud" evita duplicar un envío
// que se reintenta después de un corte de señal.
interface Item { producto_id: string; opcion?: string; cantidad: number; observacion: string }
interface Borrador { items: Item[]; solicitud?: string }
const mismo = (x: Item, producto_id: string, opcion?: string) => x.producto_id === producto_id && (x.opcion ?? '') === (opcion ?? '');
const nombreLinea = (nombre: string, opcion?: string | null) => (opcion ? `${nombre} · ${opcion}` : nombre);
type Borradores = Record<string, Borrador>;
const CLAVE_BORRADORES = 'la-merced-borradores';

function leerBorradores(): Borradores {
  try { return JSON.parse(localStorage.getItem(CLAVE_BORRADORES) ?? '{}'); } catch { return {}; }
}

interface Grupo { principal: Mesa; miembros: Mesa[]; nombre: string; cuenta?: Cuenta; lineas: Linea[] }

export default function Salon({ yo, salir, dentroDePanel = false }: { yo: Yo; salir?: () => void; dentroDePanel?: boolean }) {
  const aviso = useAviso();
  const [mesas, setMesas] = useState<Mesa[]>([]);
  const [cuentas, setCuentas] = useState<Cuenta[]>([]);
  const [lineas, setLineas] = useState<Linea[]>([]);
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
      supabase.from('productos').select('id, categoria_id, nombre, descripcion, precio, estado, orden, opciones').order('orden'),
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
    setError('');
    setMesas(m.data as Mesa[]);
    setCuentas(c.data as Cuenta[]);
    setCategorias(k.data as Categoria[]);
    setProductos(p.data as Producto[]);
    setLineas(l.data as Linea[]);
    setCargado(true);
  }, []);

  useEffect(() => { cargar(); }, [cargar]);
  useEnVivo(['mesas', 'cuentas', 'lineas_cuenta'], cargar);

  const grupos = useMemo<Grupo[]>(() => mesas.filter((m) => !m.unida_a).map((principal) => {
    const miembros = [principal, ...mesas.filter((m) => m.unida_a === principal.id)];
    const cuenta = cuentas.find((c) => c.mesa_id === principal.id);
    return {
      principal, miembros, cuenta,
      nombre: miembros.map((m) => m.nombre).join(' + '),
      lineas: cuenta ? lineas.filter((l) => l.cuenta_id === cuenta.id) : [],
    };
  }), [mesas, cuentas, lineas]);

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
          for (const it of y[id]?.items ?? []) {
            const igual = juntos.find((j) => mismo(j, it.producto_id, it.opcion));
            if (igual) igual.cantidad = Math.min(99, igual.cantidad + it.cantidad);
            else juntos.push({ ...it });
          }
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
  const totalBorrador = items.reduce((s, x) => s + (precio[x.producto_id]?.precio ?? 0) * x.cantidad, 0);
  const total = enviadas.reduce((s, l) => s + l.precio_unitario * l.cantidad, 0) + totalBorrador;
  const piezas = enviadas.reduce((s, l) => s + l.cantidad, 0) + items.reduce((s, x) => s + x.cantidad, 0);

  function cambiar(producto_id: string, delta: number, opcion?: string) {
    const lista = items.map((x) => ({ ...x }));
    let l = lista.find((x) => mismo(x, producto_id, opcion));
    if (!l) { l = { producto_id, opcion, cantidad: 0, observacion: '' }; lista.push(l); }
    l.cantidad = Math.min(99, l.cantidad + delta);
    // Cambiar el pedido invalida el identificador de un envío anterior fallido.
    guardarBorrador({ items: lista.filter((x) => x.cantidad > 0) });
  }

  function guardarNota(producto_id: string) {
    guardarBorrador({ items: items.map((x) => mismo(x, producto_id) ? { ...x, observacion: nota.trim() } : x) });
    setNotaDe(null);
  }

  async function enviar() {
    const solicitud = borrador.solicitud ?? crypto.randomUUID();
    guardarBorrador({ ...borrador, solicitud });
    const ok = await accion(() => llamar('enviar_pedido', {
      p_mesa_id: grupo.principal.id, p_productos: items, p_solicitud_id: solicitud,
    }), enviadas.length ? 'Pedido adicional enviado a cocina' : 'Pedido enviado a cocina');
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
        {bloqueada && <p className="lock">Cuenta solicitada. El cajero registrará el cobro y liberará la mesa.</p>}
        {!bloqueada && productos.filter((p) => p.categoria_id === cat).map((p) => {
          const l = items.find((x) => mismo(x, p.id));
          const agotado = p.estado === 'agotado';
          const conOpciones = p.opciones?.length > 0;
          const elegidas = items.filter((x) => x.producto_id === p.id).length;
          return (
            <div key={p.id} className={`prod ${l || elegidas ? 'has' : ''} ${agotado ? 'agotado' : ''}`}>
              <div className="rh">
                <div><h3>{p.nombre}</h3>{p.descripcion && <p>{p.descripcion}</p>}</div>
                <span className="pr">{dinero(p.precio)}</span>
              </div>
              {agotado ? <p className="note">Agotado</p> : conOpciones ? (
                // Sabores: cada uno con su propia cantidad.
                <div className="opciones" role="group" aria-label={`Sabor de ${p.nombre}`}>
                  {p.opciones.map((o) => {
                    const x = items.find((it) => mismo(it, p.id, o));
                    return x ? (
                      <div key={o} className="opc on">
                        <span>{o}</span>
                        <div className="qty">
                          <button onClick={() => cambiar(p.id, -1, o)} aria-label={`Quitar un ${p.nombre} ${o}`}>−</button>
                          <span>{x.cantidad}</span>
                          <button onClick={() => cambiar(p.id, 1, o)} aria-label={`Agregar un ${p.nombre} ${o}`}>+</button>
                        </div>
                      </div>
                    ) : (
                      <button key={o} className="opc" onClick={() => cambiar(p.id, 1, o)}>+ {o}</button>
                    );
                  })}
                </div>
              ) : l ? (
                <>
                  {l.observacion && notaDe !== p.id && <p className="nv">{l.observacion}</p>}
                  {notaDe === p.id && (
                    <div className="ni">
                      <input autoFocus value={nota} placeholder="Ej. sin crema, extra rábanos" aria-label={`Observación para ${p.nombre}`}
                             onChange={(e) => setNota(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && guardarNota(p.id)} />
                      <button className="add" onClick={() => guardarNota(p.id)}>Guardar</button>
                    </div>
                  )}
                  <div className="rc">
                    <div className="qty">
                      <button onClick={() => cambiar(p.id, -1)} aria-label={`Quitar un ${p.nombre}`}>−</button>
                      <span>{l.cantidad}</span>
                      <button onClick={() => cambiar(p.id, 1)} aria-label={`Agregar un ${p.nombre}`}>+</button>
                    </div>
                    <button className="obs" onClick={() => { setNotaDe(p.id); setNota(l.observacion); }}>
                      {l.observacion ? 'Editar observación' : 'Agregar observación'}
                    </button>
                  </div>
                </>
              ) : (
                <div className="rc"><button className="add" onClick={() => cambiar(p.id, 1)}>Agregar</button></div>
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
              <div key={`${x.producto_id}|${x.opcion ?? ''}`} className="li">
                <span>
                  {x.cantidad} × {nombreLinea(precio[x.producto_id]?.nombre ?? 'Producto', x.opcion)}
                  {x.observacion && <small>{x.observacion}</small>}
                  {' '}<button className="rm" onClick={() => cambiar(x.producto_id, -x.cantidad, x.opcion)}>Quitar</button>
                </span>
                <span>{dinero((precio[x.producto_id]?.precio ?? 0) * x.cantidad)}</span>
              </div>
            ))}

            <div className="tot"><span>Total acumulado</span><span>{dinero(total)}</span></div>
            {borrador.solicitud && items.length > 0 && (
              <p className="lock er" style={{ marginTop: 12 }}>El envío anterior no se confirmó. Vuelve a enviar: no se duplicará.</p>
            )}
            {items.length > 0 && <button className="cta" disabled={ocupado} onClick={enviar}>{ocupado ? 'Enviando…' : 'Enviar a cocina'}</button>}
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
