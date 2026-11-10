import { useCallback, useEffect, useState } from 'react';
import { llamar, mensajeDe, supabase } from '../lib/supabase';
import { useEnVivo } from '../lib/vivo';
import { useAviso } from '../componentes/Aviso';
import { dinero, fechaHora } from '../lib/tipos';

// Inventario manual: las existencias solo cambian con lo que se registra aquí.
// Propietarios: todo. Caja: compras (se vuelven gasto) y entradas.

interface Insumo { id: string; nombre: string; unidad: string; minimo: number; existencia: number; proveedor_id: string | null }
interface Proveedor { id: string; nombre: string; telefono: string | null; notas: string | null }
type Tipo = 'compra' | 'entrada' | 'merma' | 'ajuste';
interface Movimiento {
  id: string; tipo: Tipo; cantidad: number; existencia_nueva: number; costo: number | null; motivo: string | null; creado_en: string;
  insumos: { nombre: string; unidad: string } | null; proveedores: { nombre: string } | null; usuarios: { nombre: string } | null;
}
interface MiMovimiento { creado_en: string; tipo: Tipo; insumo: string; unidad: string; cantidad: number; motivo: string | null }

const TIPO: Record<Tipo, string> = { compra: 'Compra', entrada: 'Entrada', merma: 'Merma', ajuste: 'Ajuste' };
const num = (n: number) => Number(n).toLocaleString('es-MX', { maximumFractionDigits: 3 });
const bajo = (i: Pick<Insumo, 'existencia' | 'minimo'>) => Number(i.minimo) > 0 && Number(i.existencia) <= Number(i.minimo);

type FormInsumo = { id: string | null; nombre: string; unidad: string; minimo: string; proveedor_id: string; inicial: string };
type FormProveedor = { id: string | null; nombre: string; telefono: string; notas: string };
type Renglon = { insumo_id: string; cantidad: string; costo: string };
type FormMov = { tipo: 'entrada' | 'merma' | 'ajuste'; insumo: Insumo; cantidad: string; motivo: string };

export default function Inventario({ esPropietario }: { esPropietario: boolean }) {
  const aviso = useAviso();
  const [insumos, setInsumos] = useState<Insumo[]>([]);
  const [proveedores, setProveedores] = useState<Proveedor[]>([]);
  const [historial, setHistorial] = useState<Movimiento[]>([]);
  const [mios, setMios] = useState<MiMovimiento[]>([]);
  const [buscar, setBuscar] = useState('');
  const [ocupado, setOcupado] = useState(false);
  const [fInsumo, setFInsumo] = useState<FormInsumo | null>(null);
  const [fProveedor, setFProveedor] = useState<FormProveedor | null>(null);
  const [fMov, setFMov] = useState<FormMov | null>(null);
  const [compra, setCompra] = useState<{ proveedor_id: string; nota: string; renglones: Renglon[] } | null>(null);

  const cargar = useCallback(async () => {
    const [i, p] = await Promise.all([
      supabase.from('insumos').select('id, nombre, unidad, minimo, existencia, proveedor_id').is('eliminado_en', null).order('nombre'),
      supabase.from('proveedores').select('id, nombre, telefono, notas').is('eliminado_en', null).order('nombre'),
    ]);
    if (i.data) setInsumos(i.data as Insumo[]);
    if (p.data) setProveedores(p.data as Proveedor[]);
    if (esPropietario) {
      const h = await supabase.from('movimientos_inventario')
        .select('id, tipo, cantidad, existencia_nueva, costo, motivo, creado_en, insumos(nombre, unidad), proveedores(nombre), usuarios(nombre)')
        .order('creado_en', { ascending: false }).limit(60);
      if (h.data) setHistorial(h.data as unknown as Movimiento[]);
    } else {
      const m = await supabase.rpc('mis_movimientos_inventario');
      if (m.data) setMios(m.data as MiMovimiento[]);
    }
  }, [esPropietario]);
  useEffect(() => { cargar(); }, [cargar]);
  useEnVivo(['insumos', 'proveedores', 'movimientos_inventario'], cargar);

  async function hacer(fn: () => Promise<unknown>, exito: string) {
    setOcupado(true);
    try { await fn(); aviso(exito); return true; } catch (e) { aviso(mensajeDe(e)); return false; }
    finally { setOcupado(false); await cargar(); }
  }

  const proveedorDe = (id: string | null) => proveedores.find((p) => p.id === id)?.nombre;
  const visibles = insumos.filter((i) => i.nombre.toLowerCase().includes(buscar.trim().toLowerCase()));
  const bajos = insumos.filter(bajo);
  const totalCompra = compra?.renglones.reduce((s, r) => s + (Number(r.costo) || 0), 0) ?? 0;

  function nuevaCompra(insumo?: Insumo) {
    setCompra({
      proveedor_id: insumo?.proveedor_id ?? '', nota: '',
      renglones: [{ insumo_id: insumo?.id ?? '', cantidad: '', costo: '' }],
    });
  }

  async function guardarCompra() {
    if (!compra) return;
    const ok = await hacer(() => llamar('registrar_compra', {
      p_proveedor_id: compra.proveedor_id || null,
      p_productos: compra.renglones.filter((r) => r.insumo_id).map((r) => ({
        insumo_id: r.insumo_id, cantidad: r.cantidad === '' ? null : Number(r.cantidad), costo: r.costo === '' ? null : Number(r.costo),
      })),
      p_nota: compra.nota || null,
    }), `Compra registrada por ${dinero(totalCompra)} (también quedó como gasto)`);
    if (ok) setCompra(null);
  }

  async function guardarMovimiento() {
    if (!fMov) return;
    const { tipo, insumo, cantidad, motivo } = fMov;
    const n = cantidad === '' ? null : Number(cantidad);
    const ok = tipo === 'entrada'
      ? await hacer(() => llamar('registrar_entrada', { p_insumo_id: insumo.id, p_cantidad: n, p_motivo: motivo }), `Entrada de ${insumo.nombre} registrada`)
      : tipo === 'merma'
        ? await hacer(() => llamar('registrar_merma', { p_insumo_id: insumo.id, p_cantidad: n, p_motivo: motivo }), `Merma de ${insumo.nombre} registrada`)
        : await hacer(() => llamar('ajustar_existencia', { p_insumo_id: insumo.id, p_contado: n, p_motivo: motivo || 'Conteo físico' }), `${insumo.nombre} ajustado al conteo`);
    if (ok) setFMov(null);
  }

  async function guardarInsumo() {
    if (!fInsumo) return;
    const ok = await hacer(() => llamar('guardar_insumo', {
      p_id: fInsumo.id, p_nombre: fInsumo.nombre, p_unidad: fInsumo.unidad,
      p_minimo: fInsumo.minimo === '' ? 0 : Number(fInsumo.minimo), p_proveedor_id: fInsumo.proveedor_id || null,
      p_existencia_inicial: fInsumo.inicial === '' ? 0 : Number(fInsumo.inicial),
    }), fInsumo.id ? 'Insumo actualizado' : 'Insumo agregado');
    if (ok) setFInsumo(null);
  }

  async function guardarProveedor() {
    if (!fProveedor) return;
    const ok = await hacer(() => llamar('guardar_proveedor', {
      p_id: fProveedor.id, p_nombre: fProveedor.nombre, p_telefono: fProveedor.telefono || null, p_notas: fProveedor.notas || null,
    }), fProveedor.id ? 'Proveedor actualizado' : 'Proveedor agregado');
    if (ok) setFProveedor(null);
  }

  const cerrar = (fn: () => void) => (e: React.MouseEvent) => { if (e.target === e.currentTarget) fn(); };

  return (
    <>
      <div className="box">
        <h2>Existencias</h2>
        <p className="hint">El inventario no se descuenta con las ventas: cambia solo con compras, entradas{esPropietario ? ', mermas y conteos' : ''} que se registran aquí.</p>
        {bajos.length > 0 && (
          <p className="falta" role="alert">Por surtir: {bajos.map((i) => `${i.nombre} (${num(i.existencia)} ${i.unidad})`).join(', ')}</p>
        )}
        <div className="f">
          <input placeholder="Buscar insumo" aria-label="Buscar insumo" value={buscar} onChange={(e) => setBuscar(e.target.value)} />
          <button className="btn" disabled={ocupado || insumos.length === 0} onClick={() => nuevaCompra()}>Registrar compra</button>
          {esPropietario && (
            <button className="btn s" disabled={ocupado}
                    onClick={() => setFInsumo({ id: null, nombre: '', unidad: '', minimo: '', proveedor_id: '', inicial: '' })}>Agregar insumo</button>
          )}
        </div>
        {insumos.length === 0 && (
          <p className="vacio">{esPropietario ? 'Aún no hay insumos. Agrega el primero con "Agregar insumo".' : 'Aún no hay insumos. Los propietarios los dan de alta.'}</p>
        )}
        {visibles.map((i) => (
          <div className="row" key={i.id}>
            <span className="n">
              <b>{i.nombre}</b>
              <small>
                Mínimo {num(i.minimo)} {i.unidad}{proveedorDe(i.proveedor_id) ? ` · ${proveedorDe(i.proveedor_id)}` : ''}
              </small>
            </span>
            <span className={`chip ${bajo(i) ? 'r' : 'g'}`}>{num(i.existencia)} {i.unidad}{bajo(i) ? ' · bajo' : ''}</span>
            <button className="btn s" disabled={ocupado} aria-label={`Compra de ${i.nombre}`} onClick={() => nuevaCompra(i)}>Compra</button>
            <button className="btn s" disabled={ocupado} aria-label={`Entrada de ${i.nombre}`}
                    onClick={() => setFMov({ tipo: 'entrada', insumo: i, cantidad: '', motivo: '' })}>Entrada</button>
            {esPropietario && (
              <>
                <button className="btn s" disabled={ocupado} aria-label={`Merma de ${i.nombre}`}
                        onClick={() => setFMov({ tipo: 'merma', insumo: i, cantidad: '', motivo: '' })}>Merma</button>
                <button className="btn s" disabled={ocupado} aria-label={`Contar ${i.nombre}`}
                        onClick={() => setFMov({ tipo: 'ajuste', insumo: i, cantidad: '', motivo: '' })}>Contar</button>
                <button className="btn s" disabled={ocupado} aria-label={`Editar ${i.nombre}`}
                        onClick={() => setFInsumo({ id: i.id, nombre: i.nombre, unidad: i.unidad, minimo: String(Number(i.minimo)), proveedor_id: i.proveedor_id ?? '', inicial: '' })}>Editar</button>
                <button className="btn s d" disabled={ocupado} aria-label={`Eliminar ${i.nombre}`}
                        onClick={() => { if (confirm(`¿Eliminar ${i.nombre}? Su historial se conserva.`)) hacer(() => llamar('eliminar_insumo', { p_id: i.id }), `${i.nombre} eliminado`); }}>Eliminar</button>
              </>
            )}
          </div>
        ))}
      </div>

      {esPropietario && (
        <div className="box">
          <h2>Proveedores</h2>
          <div className="f">
            <button className="btn s" disabled={ocupado} onClick={() => setFProveedor({ id: null, nombre: '', telefono: '', notas: '' })}>Agregar proveedor</button>
          </div>
          {proveedores.length === 0 && <p className="vacio">Sin proveedores todavía.</p>}
          {proveedores.map((p) => (
            <div className="row" key={p.id}>
              <span className="n"><b>{p.nombre}</b><small>{[p.telefono, p.notas].filter(Boolean).join(' · ') || 'Sin datos'}</small></span>
              <button className="btn s" disabled={ocupado} aria-label={`Editar proveedor ${p.nombre}`}
                      onClick={() => setFProveedor({ id: p.id, nombre: p.nombre, telefono: p.telefono ?? '', notas: p.notas ?? '' })}>Editar</button>
              <button className="btn s d" disabled={ocupado} aria-label={`Eliminar proveedor ${p.nombre}`}
                      onClick={() => { if (confirm(`¿Eliminar al proveedor ${p.nombre}?`)) hacer(() => llamar('eliminar_proveedor', { p_id: p.id }), `${p.nombre} eliminado`); }}>Eliminar</button>
            </div>
          ))}
        </div>
      )}

      <div className="box">
        <h2>{esPropietario ? 'Movimientos' : 'Lo que registré'}</h2>
        {esPropietario ? (
          historial.length === 0 ? <p className="vacio">Sin movimientos todavía.</p> : historial.map((m) => (
            <div className="row" key={m.id}>
              <span className="n">
                <b>{TIPO[m.tipo]} · {m.insumos?.nombre}</b>
                <small>
                  {fechaHora(m.creado_en)} · {m.usuarios?.nombre ?? '—'}
                  {m.proveedores ? ` · ${m.proveedores.nombre}` : ''}{m.motivo ? ` · ${m.motivo}` : ''}
                  {` · quedó en ${num(m.existencia_nueva)}`}
                </small>
              </span>
              {m.costo != null && <span className="chip">{dinero(m.costo)}</span>}
              <span className={`chip ${m.cantidad > 0 ? 'g' : 'r'}`}>{m.cantidad > 0 ? '+' : ''}{num(m.cantidad)} {m.insumos?.unidad}</span>
            </div>
          ))
        ) : (
          mios.length === 0 ? <p className="vacio">Aún no registras compras ni entradas.</p> : mios.map((m, k) => (
            <div className="row" key={k}>
              <span className="n"><b>{TIPO[m.tipo]} · {m.insumo}</b><small>{fechaHora(m.creado_en)}{m.motivo ? ` · ${m.motivo}` : ''}</small></span>
              <span className="chip g">+{num(m.cantidad)} {m.unidad}</span>
            </div>
          ))
        )}
      </div>

      {compra && (
        <div className="sheet centro" onClick={cerrar(() => setCompra(null))}>
          <div className="pane formulario" role="dialog" aria-label="Registrar compra">
            <h2>Registrar compra</h2>
            <p className="hint">Suma al inventario y queda como gasto de “Compras y mercancía”.</p>
            <label htmlFor="c-prov">Proveedor</label>
            <select id="c-prov" value={compra.proveedor_id} onChange={(e) => setCompra({ ...compra, proveedor_id: e.target.value })}>
              <option value="">Sin proveedor</option>
              {proveedores.map((p) => <option key={p.id} value={p.id}>{p.nombre}</option>)}
            </select>
            {compra.renglones.map((r, k) => {
              const ins = insumos.find((i) => i.id === r.insumo_id);
              const cambiar = (c: Partial<Renglon>) => setCompra({ ...compra, renglones: compra.renglones.map((x, j) => (j === k ? { ...x, ...c } : x)) });
              return (
                <div key={k}>
                  <label htmlFor={`c-ins-${k}`}>Insumo {k + 1}</label>
                  <select id={`c-ins-${k}`} value={r.insumo_id} onChange={(e) => cambiar({ insumo_id: e.target.value })}>
                    <option value="">Elige un insumo</option>
                    {insumos.map((i) => <option key={i.id} value={i.id}>{i.nombre} ({i.unidad})</option>)}
                  </select>
                  <div className="par">
                    <span>
                      <label htmlFor={`c-cant-${k}`}>Cantidad{ins ? ` (${ins.unidad})` : ''}</label>
                      <input id={`c-cant-${k}`} type="number" inputMode="decimal" min="0" step="any" value={r.cantidad} onChange={(e) => cambiar({ cantidad: e.target.value })} />
                    </span>
                    <span>
                      <label htmlFor={`c-costo-${k}`}>Costo total $</label>
                      <input id={`c-costo-${k}`} type="number" inputMode="decimal" min="0" step="any" value={r.costo} onChange={(e) => cambiar({ costo: e.target.value })} />
                    </span>
                  </div>
                  {compra.renglones.length > 1 && (
                    <button className="btn s" type="button" onClick={() => setCompra({ ...compra, renglones: compra.renglones.filter((_, j) => j !== k) })}>Quitar insumo {k + 1}</button>
                  )}
                </div>
              );
            })}
            <p><button className="btn s" type="button"
                       onClick={() => setCompra({ ...compra, renglones: [...compra.renglones, { insumo_id: '', cantidad: '', costo: '' }] })}>Agregar otro insumo</button></p>
            <label htmlFor="c-nota">Nota (opcional, p. ej. número de factura)</label>
            <input id="c-nota" value={compra.nota} onChange={(e) => setCompra({ ...compra, nota: e.target.value })} />
            <p className="tot"><b>Total: {dinero(totalCompra)}</b></p>
            <div className="f">
              <button className="btn s" type="button" onClick={() => setCompra(null)}>Cancelar</button>
              <button className="btn" disabled={ocupado} onClick={guardarCompra}>Guardar compra</button>
            </div>
          </div>
        </div>
      )}

      {fMov && (
        <div className="sheet centro" onClick={cerrar(() => setFMov(null))}>
          <div className="pane formulario" role="dialog" aria-label={`${fMov.tipo === 'ajuste' ? 'Conteo' : TIPO[fMov.tipo]} de ${fMov.insumo.nombre}`}>
            <h2>{fMov.tipo === 'ajuste' ? 'Conteo físico' : TIPO[fMov.tipo]} · {fMov.insumo.nombre}</h2>
            <p className="hint">Anotado: {num(fMov.insumo.existencia)} {fMov.insumo.unidad}</p>
            <label htmlFor="m-cant">{fMov.tipo === 'ajuste' ? `¿Cuánto contaste? (${fMov.insumo.unidad})` : `Cantidad (${fMov.insumo.unidad})`}</label>
            <input id="m-cant" type="number" inputMode="decimal" min="0" step="any" value={fMov.cantidad} onChange={(e) => setFMov({ ...fMov, cantidad: e.target.value })} />
            <label htmlFor="m-motivo">{fMov.tipo === 'entrada' ? '¿De dónde viene?' : fMov.tipo === 'merma' ? 'Motivo de la merma' : 'Nota (opcional)'}</label>
            <input id="m-motivo" value={fMov.motivo} onChange={(e) => setFMov({ ...fMov, motivo: e.target.value })}
                   placeholder={fMov.tipo === 'entrada' ? 'Regalo, devolución, traspaso…' : fMov.tipo === 'merma' ? 'Se echó a perder, caducó…' : 'Conteo físico'} />
            {fMov.tipo === 'ajuste' && fMov.cantidad !== '' && (
              <p className="hint">Diferencia: {Number(fMov.cantidad) - Number(fMov.insumo.existencia) > 0 ? '+' : ''}{num(Number(fMov.cantidad) - Number(fMov.insumo.existencia))} {fMov.insumo.unidad}</p>
            )}
            <div className="f">
              <button className="btn s" type="button" onClick={() => setFMov(null)}>Cancelar</button>
              <button className="btn" disabled={ocupado} onClick={guardarMovimiento}>Guardar</button>
            </div>
          </div>
        </div>
      )}

      {fInsumo && (
        <div className="sheet centro" onClick={cerrar(() => setFInsumo(null))}>
          <div className="pane formulario" role="dialog" aria-label={fInsumo.id ? 'Editar insumo' : 'Agregar insumo'}>
            <h2>{fInsumo.id ? 'Editar insumo' : 'Agregar insumo'}</h2>
            <label htmlFor="i-nombre">Nombre del insumo</label>
            <input id="i-nombre" value={fInsumo.nombre} onChange={(e) => setFInsumo({ ...fInsumo, nombre: e.target.value })} />
            <div className="par">
              <span>
                <label htmlFor="i-unidad">Unidad</label>
                <input id="i-unidad" list="unidades" placeholder="kg, pieza, litro…" value={fInsumo.unidad} onChange={(e) => setFInsumo({ ...fInsumo, unidad: e.target.value })} />
                <datalist id="unidades">{['kg', 'g', 'litro', 'pieza', 'paquete', 'caja', 'bolsa', 'manojo'].map((u) => <option key={u} value={u} />)}</datalist>
              </span>
              <span>
                <label htmlFor="i-minimo">Avisar cuando queden</label>
                <input id="i-minimo" type="number" inputMode="decimal" min="0" step="any" placeholder="0 = sin aviso" value={fInsumo.minimo} onChange={(e) => setFInsumo({ ...fInsumo, minimo: e.target.value })} />
              </span>
            </div>
            <label htmlFor="i-prov">Proveedor habitual</label>
            <select id="i-prov" value={fInsumo.proveedor_id} onChange={(e) => setFInsumo({ ...fInsumo, proveedor_id: e.target.value })}>
              <option value="">Sin proveedor</option>
              {proveedores.map((p) => <option key={p.id} value={p.id}>{p.nombre}</option>)}
            </select>
            {!fInsumo.id && (
              <>
                <label htmlFor="i-inicial">Existencia actual (opcional)</label>
                <input id="i-inicial" type="number" inputMode="decimal" min="0" step="any" value={fInsumo.inicial} onChange={(e) => setFInsumo({ ...fInsumo, inicial: e.target.value })} />
              </>
            )}
            <div className="f" style={{ marginTop: 12 }}>
              <button className="btn s" type="button" onClick={() => setFInsumo(null)}>Cancelar</button>
              <button className="btn" disabled={ocupado} onClick={guardarInsumo}>{fInsumo.id ? 'Guardar cambios' : 'Agregar insumo'}</button>
            </div>
          </div>
        </div>
      )}

      {fProveedor && (
        <div className="sheet centro" onClick={cerrar(() => setFProveedor(null))}>
          <div className="pane formulario" role="dialog" aria-label={fProveedor.id ? 'Editar proveedor' : 'Agregar proveedor'}>
            <h2>{fProveedor.id ? 'Editar proveedor' : 'Agregar proveedor'}</h2>
            <label htmlFor="p-nombre">Nombre del proveedor</label>
            <input id="p-nombre" value={fProveedor.nombre} onChange={(e) => setFProveedor({ ...fProveedor, nombre: e.target.value })} />
            <label htmlFor="p-tel">Teléfono (opcional)</label>
            <input id="p-tel" type="tel" value={fProveedor.telefono} onChange={(e) => setFProveedor({ ...fProveedor, telefono: e.target.value })} />
            <label htmlFor="p-notas">Notas (opcional)</label>
            <input id="p-notas" placeholder="Días de entrega, contacto…" value={fProveedor.notas} onChange={(e) => setFProveedor({ ...fProveedor, notas: e.target.value })} />
            <div className="f" style={{ marginTop: 12 }}>
              <button className="btn s" type="button" onClick={() => setFProveedor(null)}>Cancelar</button>
              <button className="btn" disabled={ocupado} onClick={guardarProveedor}>{fProveedor.id ? 'Guardar cambios' : 'Agregar proveedor'}</button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}

// Cantidad de insumos por surtir, para el número rojo de la pestaña.
export function usePorSurtir(activo: boolean) {
  const [n, setN] = useState(0);
  const contar = useCallback(async () => {
    if (!activo) return;
    const { data } = await supabase.from('insumos').select('existencia, minimo').is('eliminado_en', null).gt('minimo', 0);
    setN((data ?? []).filter(bajo).length);
  }, [activo]);
  useEffect(() => { contar(); }, [contar]);
  useEnVivo(['insumos'], contar);
  return n;
}
