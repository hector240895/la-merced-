import { useEffect, useState } from 'react';
import { llamar } from '../lib/supabase';
import ListaComandas from './ListaComandas';
import { dinero, type Categoria, type Linea, type Producto, type Trabajo } from '../lib/tipos';

// Pedido que el mesero va armando antes de enviarlo. Se guarda en el teléfono
// para no perderlo si se cierra la app; "solicitud" evita duplicar un envío
// que se reintenta después de un corte de señal.
// Cada pieza se anota por separado, con su propia observación y sus propios
// sabores o guisados. Al enviar, las piezas idénticas viajan juntas.
export interface Pieza { id: string; producto_id: string; opciones: string[]; observacion: string }
export interface Borrador { items: Pieza[]; solicitud?: string }
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
export type Borradores = Record<string, Borrador>;
export const CLAVE_BORRADORES = 'la-merced-borradores';

export function leerBorradores(): Borradores {
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
export function agrupar(items: Pieza[]) {
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



// ---------------------------------------------------------------------------
// Pantalla de pedido: de una mesa o para llevar
// ---------------------------------------------------------------------------
export interface Destino {
  titulo: string;
  chip?: { texto: string; clase: string };
  lineas: Linea[];
  trabajos: Trabajo[];
  bloqueada: boolean;                 // la cuenta ya se pidió: no se agregan productos
  enviar: (productos: ReturnType<typeof agrupar>, solicitud: string) => Promise<unknown>;
  pedirCuenta?: () => Promise<unknown>;
  imprimirCuenta?: () => Promise<unknown>;   // precuenta en la impresora de caja
}

interface PropsPedido {
  destino: Destino; categorias: Categoria[]; productos: Producto[]; precio: Record<string, Producto>;
  borrador: Borrador; guardarBorrador: (b: Borrador) => void;
  ocupado: boolean; accion: (fn: () => Promise<unknown>, exito?: string) => Promise<boolean>;
  volver: () => void; dentroDePanel?: boolean;
}

export default function Pedido({ destino, categorias, productos, precio, borrador, guardarBorrador, ocupado, accion, volver,
  dentroDePanel = false }: PropsPedido) {
  const [cat, setCat] = useState(categorias[0]?.id ?? '');
  const [notaDe, setNotaDe] = useState<string | null>(null);
  const [nota, setNota] = useState('');
  const [hoja, setHoja] = useState(false);
  const [quitando, setQuitando] = useState<string | null>(null);
  const [motivo, setMotivo] = useState('');
  const [cuantos, setCuantos] = useState(1);

  useEffect(() => { if (!cat && categorias[0]) setCat(categorias[0].id); }, [cat, categorias]);

  const bloqueada = destino.bloqueada;
  const enviadas = destino.lineas.filter((l) => l.estado === 'activa');
  const canceladas = destino.lineas.filter((l) => l.estado === 'cancelada');
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
    const ok = await accion(() => destino.enviar(agrupar(items), solicitud), enviadas.length ? 'Pedido adicional enviado. La comanda va a la impresora de cocina.' : 'Pedido enviado. La comanda va a la impresora de cocina.');
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
    if (!destino.pedirCuenta) return;
    const ok = await accion(destino.pedirCuenta, 'Cuenta solicitada. La cuenta se imprime en caja.');
    if (ok) { setHoja(false); volver(); }
  }

  return (
    <div className="movil">
      <header className="top" style={dentroDePanel ? { position: 'static' } : undefined}>
        <div>
          <button className="back" onClick={volver}>‹ Mesas</button>
          <h1>{destino.titulo}</h1>
        </div>
        {destino.chip && <span className={`st ${destino.chip.clase}`} style={{ marginLeft: 'auto' }}>{destino.chip.texto}</span>}
      </header>

      {!bloqueada && (
        <nav className="tabs" aria-label="Categorías" style={dentroDePanel ? { position: 'static' } : undefined}>
          {categorias.map((c) => (
            <button key={c.id} className={`tab ${c.id === cat ? 'on' : ''}`} onClick={() => { setCat(c.id); setNotaDe(null); }}>{c.nombre}</button>
          ))}
        </nav>
      )}

      <main>
        {destino.trabajos.some((t) => t.estado === 'error') && (
          <>
            <p className="lock er">Una comanda no se imprimió. Revisa la impresora de cocina y vuelve a intentar.</p>
            <button className="cta" style={{ margin: '0 0 16px' }} disabled={ocupado}
                    onClick={() => accion(async () => {
                      for (const t of destino.trabajos.filter((x) => x.estado === 'error')) {
                        await llamar('reintentar_impresion', { p_trabajo_id: t.id });
                      }
                    }, 'Comanda enviada de nuevo a la impresora')}>
              Reintentar impresión
            </button>
          </>
        )}
        {bloqueada && <p className="lock">Cuenta solicitada. El cajero registrará el cobro y liberará la mesa.</p>}
        {bloqueada && destino.imprimirCuenta && (
          <button className="sec" disabled={ocupado}
                  onClick={() => accion(destino.imprimirCuenta!, 'La cuenta se imprime otra vez en caja.')}>
            Volver a imprimir la cuenta
          </button>
        )}
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
            <h2>{destino.titulo}</h2>

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
              const queda = destino.lineas.find((x) => x.reemplaza_linea_id === l.id)?.cantidad ?? 0;
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
            {destino.trabajos.length > 0 && (
              <>
                <h3>Comandas a cocina</h3>
                <ListaComandas trabajos={destino.trabajos} accion={accion} ocupado={ocupado} />
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
            {!items.length && enviadas.length > 0 && !bloqueada && destino.pedirCuenta && (
              <button className="cta" disabled={ocupado} onClick={pedirCuenta}>Pedir la cuenta</button>
            )}
            <button className="sec" onClick={() => { setHoja(false); setQuitando(null); }}>Seguir pidiendo</button>
          </div>
        </div>
      )}
    </div>
  );
}
