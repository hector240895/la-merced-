import { useCallback, useEffect, useMemo, useState } from 'react';
import { llamar, mensajeDe, supabase } from '../../lib/supabase';
import { useEnVivo } from '../../lib/vivo';
import { useAviso } from '../../componentes/Aviso';
import { dinero, fechaHora } from '../../lib/tipos';

interface Categoria { id: string; nombre: string; orden: number; activa: boolean }
interface Seleccion { etiqueta: string; opciones: string[] }
interface Prod {
  id: string; categoria_id: string; nombre: string; descripcion: string | null; precio: number;
  estado: 'activo' | 'agotado' | 'inactivo'; orden: number; selecciones: Seleccion[]; foto_url: string | null;
}
interface Formulario { id?: string; categoria_id: string; nombre: string; precio: string; descripcion: string; selecciones: { etiqueta: string; texto: string }[] }
interface Precio { precio_anterior: number; precio_nuevo: number; creado_en: string; creado_por: string | null }

const BUCKET = 'fotos-productos';

// Reduce la foto (máximo 1200 px) antes de subirla.
async function reducir(archivo: File): Promise<Blob> {
  const img = await createImageBitmap(archivo);
  const escala = Math.min(1, 1200 / Math.max(img.width, img.height));
  const lienzo = document.createElement('canvas');
  lienzo.width = Math.round(img.width * escala);
  lienzo.height = Math.round(img.height * escala);
  lienzo.getContext('2d')!.drawImage(img, 0, 0, lienzo.width, lienzo.height);
  return new Promise((r) => lienzo.toBlob((b) => r(b!), 'image/jpeg', 0.85));
}

// Catálogo: categorías, productos, precios, opciones para elegir y fotos.
export default function Catalogo() {
  const aviso = useAviso();
  const [categorias, setCategorias] = useState<Categoria[]>([]);
  const [productos, setProductos] = useState<Prod[]>([]);
  const [fotos, setFotos] = useState<Record<string, string>>({});
  const [nombres, setNombres] = useState<Record<string, string>>({});
  const [cat, setCat] = useState<string>('');
  const [nuevaCat, setNuevaCat] = useState('');
  const [renombrando, setRenombrando] = useState<{ id: string; nombre: string } | null>(null);
  const [form, setForm] = useState<Formulario | null>(null);
  const [historial, setHistorial] = useState<Precio[]>([]);
  const [ocupado, setOcupado] = useState(false);

  const cargar = useCallback(async () => {
    const [k, p, u] = await Promise.all([
      supabase.from('categorias').select('id, nombre, orden, activa').is('eliminada_en', null).order('orden').order('nombre'),
      supabase.from('productos').select('id, categoria_id, nombre, descripcion, precio, estado, orden, selecciones, foto_url')
        .is('eliminado_en', null).order('orden').order('nombre'),
      supabase.from('usuarios').select('id, nombre'),
    ]);
    const ks = (k.data ?? []) as Categoria[];
    const ps = (p.data ?? []) as Prod[];
    setCategorias(ks);
    setProductos(ps);
    setNombres(Object.fromEntries((u.data ?? []).map((x) => [x.id, x.nombre])));
    setCat((c) => (c && ks.some((x) => x.id === c) ? c : ks[0]?.id ?? ''));
    const rutas = ps.filter((x) => x.foto_url).map((x) => x.foto_url!);
    if (rutas.length) {
      const { data } = await supabase.storage.from(BUCKET).createSignedUrls(rutas, 3600);
      setFotos(Object.fromEntries((data ?? []).filter((x) => x.signedUrl).map((x) => [x.path!, x.signedUrl])));
    }
  }, []);
  useEffect(() => { cargar(); }, [cargar]);
  useEnVivo(['productos', 'categorias'], cargar);

  async function hacer(fn: () => Promise<unknown>, exito: string) {
    setOcupado(true);
    try { await fn(); aviso(exito); return true; } catch (e) { aviso(mensajeDe(e)); return false; }
    finally { setOcupado(false); await cargar(); }
  }

  const deCat = useMemo(() => productos.filter((p) => p.categoria_id === cat), [productos, cat]);

  async function moverCat(i: number, d: number) {
    const ids = categorias.map((c) => c.id);
    const j = i + d;
    if (j < 0 || j >= ids.length) return;
    [ids[i], ids[j]] = [ids[j], ids[i]];
    await hacer(() => llamar('ordenar_categorias', { p_ids: ids }), 'Orden actualizado');
  }
  async function moverProd(i: number, d: number) {
    const ids = deCat.map((p) => p.id);
    const j = i + d;
    if (j < 0 || j >= ids.length) return;
    [ids[i], ids[j]] = [ids[j], ids[i]];
    await hacer(() => llamar('ordenar_productos', { p_categoria_id: cat, p_ids: ids }), 'Orden actualizado');
  }

  async function abrir(p?: Prod) {
    setForm(p
      ? { id: p.id, categoria_id: p.categoria_id, nombre: p.nombre, precio: String(p.precio), descripcion: p.descripcion ?? '',
          selecciones: p.selecciones.map((s) => ({ etiqueta: s.etiqueta, texto: s.opciones.join('\n') })) }
      : { categoria_id: cat, nombre: '', precio: '', descripcion: '', selecciones: [] });
    setHistorial([]);
    if (p) {
      const { data } = await supabase.from('historial_precios').select('precio_anterior, precio_nuevo, creado_en, creado_por')
        .eq('producto_id', p.id).order('creado_en', { ascending: false }).limit(10);
      setHistorial((data ?? []) as Precio[]);
    }
  }

  async function guardar() {
    if (!form) return;
    const selecciones = form.selecciones.map((s) => ({ etiqueta: s.etiqueta, opciones: s.texto.split('\n') }));
    const ok = await hacer(() => (form.id
      ? llamar('editar_producto', { p_id: form.id, p_categoria_id: form.categoria_id, p_nombre: form.nombre,
          p_precio: Number(form.precio), p_descripcion: form.descripcion, p_selecciones: selecciones })
      : llamar('crear_producto', { p_categoria_id: form.categoria_id, p_nombre: form.nombre, p_precio: Number(form.precio),
          p_descripcion: form.descripcion, p_selecciones: selecciones })),
    form.id ? 'Producto actualizado' : 'Producto agregado');
    if (ok) setForm(null);
  }

  async function subirFoto(p: Prod, archivo: File) {
    await hacer(async () => {
      const ruta = `${p.id}/${Date.now()}.jpg`;
      const { error } = await supabase.storage.from(BUCKET).upload(ruta, await reducir(archivo), { contentType: 'image/jpeg' });
      if (error) throw new Error(error.message);
      await llamar('cambiar_foto_producto', { p_id: p.id, p_ruta: ruta });
    }, 'Foto guardada');
  }

  const editable = form && productos.find((p) => p.id === form.id);

  return (
    <>
      <div className="box">
        <h2>Categorías</h2>
        {categorias.map((c, i) => (
          <div key={c.id} className="row">
            <span className="n">
              {renombrando?.id === c.id ? (
                <span className="f" style={{ margin: 0 }}>
                  <input autoFocus value={renombrando.nombre} aria-label="Nuevo nombre de la categoría"
                         onChange={(e) => setRenombrando({ ...renombrando, nombre: e.target.value })} />
                  <button className="btn" disabled={ocupado} onClick={async () => {
                    if (await hacer(() => llamar('renombrar_categoria', { p_id: c.id, p_nombre: renombrando.nombre }), 'Categoría renombrada')) setRenombrando(null);
                  }}>Guardar</button>
                  <button className="btn s" onClick={() => setRenombrando(null)}>Cancelar</button>
                </span>
              ) : <><b>{c.nombre}</b><small>{productos.filter((p) => p.categoria_id === c.id).length} productos</small></>}
            </span>
            {!c.activa && <span className="chip r">Oculta</span>}
            <button className="btn s" aria-label={`Subir ${c.nombre}`} disabled={ocupado || i === 0} onClick={() => moverCat(i, -1)}>↑</button>
            <button className="btn s" aria-label={`Bajar ${c.nombre}`} disabled={ocupado || i === categorias.length - 1} onClick={() => moverCat(i, 1)}>↓</button>
            <button className="btn s" onClick={() => setRenombrando({ id: c.id, nombre: c.nombre })}>Renombrar</button>
            <button className="btn s" disabled={ocupado}
                    onClick={() => hacer(() => llamar('activar_categoria', { p_id: c.id, p_activa: !c.activa }), c.activa ? 'Categoría oculta' : 'Categoría visible')}>
              {c.activa ? 'Ocultar' : 'Mostrar'}
            </button>
            <button className="btn d" disabled={ocupado}
                    onClick={() => confirm(`¿Eliminar la categoría ${c.nombre}?`) && hacer(() => llamar('eliminar_categoria', { p_id: c.id }), 'Categoría eliminada')}>
              Eliminar
            </button>
          </div>
        ))}
        <form className="f" style={{ marginTop: 10 }} onSubmit={async (e) => {
          e.preventDefault();
          if (await hacer(() => llamar('crear_categoria', { p_nombre: nuevaCat }), 'Categoría agregada')) setNuevaCat('');
        }}>
          <input placeholder="Nombre de la categoría nueva" value={nuevaCat} onChange={(e) => setNuevaCat(e.target.value)} aria-label="Nombre de la categoría nueva" />
          <button className="btn" disabled={ocupado || !nuevaCat.trim()}>Agregar categoría</button>
        </form>
      </div>

      <div className="box">
        <div className="bar">
          <h2 style={{ margin: 0 }}>Productos</h2>
          <button className="btn" onClick={() => abrir()} disabled={!cat}>Agregar producto</button>
        </div>
        <div className="ms">
          {categorias.map((c) => (
            <button key={c.id} className={`m ${c.id === cat ? 'on' : ''}`} onClick={() => setCat(c.id)}>{c.nombre}</button>
          ))}
        </div>
        {deCat.length === 0 && <p className="note">Esta categoría no tiene productos.</p>}
        {deCat.map((p, i) => (
          <div key={p.id} className="row">
            {p.foto_url && fotos[p.foto_url] ? <img className="foto" src={fotos[p.foto_url]} alt="" /> : <span className="foto" aria-hidden="true" />}
            <span className="n">
              <b>{p.nombre}</b>
              <small>
                {dinero(p.precio)}
                {p.selecciones.length > 0 && ` · elige: ${p.selecciones.map((s) => s.etiqueta.toLowerCase()).join(', ')}`}
                {p.descripcion ? ` · ${p.descripcion}` : ''}
              </small>
            </span>
            <span className={`chip ${p.estado === 'activo' ? 'g' : 'r'}`}>
              {p.estado === 'activo' ? 'Disponible' : p.estado === 'agotado' ? 'Agotado' : 'Oculto'}
            </span>
            <button className="btn s" aria-label={`Subir ${p.nombre}`} disabled={ocupado || i === 0} onClick={() => moverProd(i, -1)}>↑</button>
            <button className="btn s" aria-label={`Bajar ${p.nombre}`} disabled={ocupado || i === deCat.length - 1} onClick={() => moverProd(i, 1)}>↓</button>
            <button className="btn s" onClick={() => abrir(p)}>Editar</button>
            {p.estado !== 'inactivo' && (
              <button className="btn s" disabled={ocupado}
                      onClick={() => hacer(() => llamar('marcar_agotado', { p_id: p.id, p_agotado: p.estado !== 'agotado' }),
                        p.estado === 'agotado' ? `${p.nombre} disponible` : `${p.nombre} agotado`)}>
                {p.estado === 'agotado' ? 'Marcar disponible' : 'Marcar agotado'}
              </button>
            )}
            <button className="btn s" disabled={ocupado} onClick={() => hacer(() => llamar('duplicar_producto', { p_id: p.id }), `${p.nombre} duplicado`)}>Duplicar</button>
            <button className="btn s" disabled={ocupado}
                    onClick={() => hacer(() => llamar('ocultar_producto', { p_id: p.id, p_oculto: p.estado !== 'inactivo' }),
                      p.estado === 'inactivo' ? `${p.nombre} visible` : `${p.nombre} oculto`)}>
              {p.estado === 'inactivo' ? 'Mostrar' : 'Ocultar'}
            </button>
            <button className="btn d" disabled={ocupado}
                    onClick={() => confirm(`¿Eliminar ${p.nombre}? Deja de aparecer en el menú; las ventas pasadas se conservan.`)
                      && hacer(() => llamar('eliminar_producto', { p_id: p.id }), `${p.nombre} eliminado`)}>
              Eliminar
            </button>
          </div>
        ))}
        <p className="note">
          Oculto: no aparece a meseros ni caja (por ejemplo, de temporada). Agotado: aparece pero no se puede pedir.
          Cambiar un precio no afecta las cuentas ya abiertas. Las fotos solo se ven aquí.
        </p>
      </div>

      {form && (
        <div className="sheet centro" onClick={(e) => { if (e.target === e.currentTarget) setForm(null); }}>
          <div className="pane formulario" role="dialog" aria-label={form.id ? 'Editar producto' : 'Agregar producto'}
               style={{ maxWidth: 560, borderRadius: 20 }}>
            <h2>{form.id ? 'Editar producto' : 'Agregar producto'}</h2>
            <label htmlFor="f-nombre">Nombre</label>
            <input id="f-nombre" value={form.nombre} onChange={(e) => setForm({ ...form, nombre: e.target.value })} />
            <label htmlFor="f-precio">Precio (con IVA)</label>
            <input id="f-precio" type="number" min="0" step="0.5" value={form.precio} onChange={(e) => setForm({ ...form, precio: e.target.value })} />
            <label htmlFor="f-cat">Categoría</label>
            <select id="f-cat" value={form.categoria_id} onChange={(e) => setForm({ ...form, categoria_id: e.target.value })}>
              {categorias.map((c) => <option key={c.id} value={c.id}>{c.nombre}</option>)}
            </select>
            <label htmlFor="f-desc">Descripción (opcional)</label>
            <input id="f-desc" value={form.descripcion} onChange={(e) => setForm({ ...form, descripcion: e.target.value })} />

            <label>Opciones para elegir (sabores, guisados…)</label>
            {form.selecciones.map((s, k) => (
              <div key={k} className="selec">
                <div className="f" style={{ margin: 0 }}>
                  <input placeholder="Nombre (ej. Guisado, Sabor)" value={s.etiqueta} aria-label={`Nombre de la opción ${k + 1}`}
                         onChange={(e) => setForm({ ...form, selecciones: form.selecciones.map((x, z) => (z === k ? { ...x, etiqueta: e.target.value } : x)) })} />
                  <button type="button" className="rm" onClick={() => setForm({ ...form, selecciones: [...form.selecciones.slice(0, k + 1), { ...s }, ...form.selecciones.slice(k + 1)] })}>
                    Repetir
                  </button>
                  <button type="button" className="rm" onClick={() => setForm({ ...form, selecciones: form.selecciones.filter((_, z) => z !== k) })}>Quitar</button>
                </div>
                <textarea placeholder="Una opción por renglón" value={s.texto} aria-label={`Lista de la opción ${k + 1}`}
                          onChange={(e) => setForm({ ...form, selecciones: form.selecciones.map((x, z) => (z === k ? { ...x, texto: e.target.value } : x)) })} />
              </div>
            ))}
            <button type="button" className="btn s" onClick={() => setForm({ ...form, selecciones: [...form.selecciones, { etiqueta: '', texto: '' }] })}>
              Agregar opción para elegir
            </button>
            <p className="note">Escribe una opción por renglón. "Repetir" sirve cuando se eligen varias iguales (por ejemplo, 3 guisados).</p>

            {editable && (
              <>
                <label>Foto</label>
                <div className="f">
                  {editable.foto_url && fotos[editable.foto_url] && <img className="foto grande" src={fotos[editable.foto_url]} alt="" />}
                  <input type="file" accept="image/jpeg,image/png,image/webp" aria-label="Foto del producto"
                         onChange={(e) => { const a = e.target.files?.[0]; if (a) subirFoto(editable, a); e.target.value = ''; }} />
                  {editable.foto_url && (
                    <button type="button" className="btn d" disabled={ocupado}
                            onClick={() => hacer(() => llamar('cambiar_foto_producto', { p_id: editable.id, p_ruta: null }), 'Foto quitada')}>
                      Quitar foto
                    </button>
                  )}
                </div>
              </>
            )}

            {historial.length > 0 && (
              <>
                <label>Cambios de precio</label>
                {historial.map((h, i) => (
                  <div key={i} className="log">
                    {fechaHora(h.creado_en)} · {dinero(h.precio_anterior)} → {dinero(h.precio_nuevo)} · {h.creado_por ? nombres[h.creado_por] ?? '' : 'Sistema'}
                  </div>
                ))}
              </>
            )}

            <button className="cta" disabled={ocupado || !form.nombre.trim() || form.precio === ''} onClick={guardar}>
              {form.id ? 'Guardar cambios' : 'Agregar producto'}
            </button>
            <button className="sec" onClick={() => setForm(null)}>Cancelar</button>
          </div>
        </div>
      )}
    </>
  );
}
