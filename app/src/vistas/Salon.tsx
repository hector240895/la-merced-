import { useCallback, useEffect, useMemo, useState } from 'react';
import { llamar, mensajeDe, supabase } from '../lib/supabase';
import { useEnVivo } from '../lib/vivo';
import { useAviso } from '../componentes/Aviso';
import { EstadoImp } from '../componentes/Comanda';
import Pedido, { CLAVE_BORRADORES, leerBorradores, type Borrador, type Borradores } from '../componentes/Pedido';
import {
  CAMPOS_TRABAJO, ESTADO_MESA, dinero, estadoDeComandas, type Categoria, type Cuenta, type Linea, type Mesa, type Producto,
  type Trabajo, type Yo,
} from '../lib/tipos';

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
  const [llevar, setLlevar] = useState<string | null>(null);    // pedido para llevar en pantalla ('nuevo' o su cuenta)
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
        .in('estado', ['abierta', 'por_cobrar']).is('cobro_anulado_en', null).order('folio'),
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
    const cuenta = cuentas.find((c) => c.tipo === 'mesa' && c.mesa_id === principal.id);
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

  const guardarEn = (clave: string) => (b: Borrador) => setBorradores((x) => {
    const y = { ...x };
    if (b.items.length || b.solicitud) y[clave] = b; else delete y[clave];
    return y;
  });

  if (grupo) {
    const id = grupo.principal.id;
    return (
      <Pedido
        destino={{
          titulo: grupo.nombre,
          chip: { texto: ESTADO_MESA[grupo.principal.estado], clase: `s-${grupo.principal.estado}` },
          lineas: grupo.lineas, trabajos: grupo.trabajos, bloqueada: grupo.principal.estado === 'por_cobrar',
          enviar: (productos, solicitud) => llamar('enviar_pedido', { p_mesa_id: id, p_productos: productos, p_solicitud_id: solicitud }),
          pedirCuenta: () => llamar('pedir_cuenta', { p_mesa_id: id }),
          imprimirCuenta: grupo.cuenta ? () => llamar('imprimir_precuenta', { p_cuenta_id: grupo.cuenta!.id }) : undefined,
        }}
        categorias={categorias} productos={productos} precio={precio}
        borrador={borradores[id] ?? { items: [] }} guardarBorrador={guardarEn(id)}
        ocupado={ocupado} accion={accion} dentroDePanel={dentroDePanel}
        volver={async () => {
          const sinNada = !grupo.cuenta && !(borradores[id]?.items.length);
          setAbierta(null);
          if (sinNada && grupo.principal.estado === 'ocupada') {
            await accion(() => llamar('liberar_mesa', { p_mesa_id: id }));
          }
        }}
      />
    );
  }

  // Pedido para llevar: nuevo (aún sin folio) o uno abierto.
  const cuentaLlevar = cuentas.find((c) => c.id === llevar && c.tipo === 'llevar');
  if (llevar === 'nuevo' || cuentaLlevar) {
    const clave = `llevar:${cuentaLlevar?.id ?? 'nuevo'}`;
    return (
      <Pedido
        destino={{
          titulo: cuentaLlevar ? `Para llevar #${cuentaLlevar.folio}` : 'Nuevo pedido para llevar',
          chip: { texto: 'Para llevar', clase: 's-pedido_enviado' },
          lineas: cuentaLlevar ? lineas.filter((l) => l.cuenta_id === cuentaLlevar.id) : [],
          trabajos: cuentaLlevar ? trabajos.filter((t) => t.cuenta_id === cuentaLlevar.id) : [],
          bloqueada: false,
          enviar: (productos, solicitud) => llamar('enviar_pedido_llevar',
            { p_cuenta_id: cuentaLlevar?.id ?? null, p_productos: productos, p_solicitud_id: solicitud }),
        }}
        categorias={categorias} productos={productos} precio={precio}
        borrador={borradores[clave] ?? { items: [] }} guardarBorrador={guardarEn(clave)}
        ocupado={ocupado} accion={accion} dentroDePanel={dentroDePanel}
        volver={() => setLlevar(null)}
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

        {!uniendo && cargado && (
          <>
            <div className="bar" style={{ marginTop: 24 }}>
              <h2>Para llevar</h2>
              <button className="ghost" onClick={() => setLlevar('nuevo')}>Nuevo para llevar</button>
            </div>
            {(borradores['llevar:nuevo']?.items.length ?? 0) > 0 && (
              <button className="tbl" style={{ marginBottom: 12 }} onClick={() => setLlevar('nuevo')}>
                <b>Nuevo pedido para llevar</b>
                <small>{borradores['llevar:nuevo'].items.length} sin enviar</small>
              </button>
            )}
            <div className="grid">
              {cuentas.filter((c) => c.tipo === 'llevar' && c.estado === 'abierta').map((c) => {
                const ls = lineas.filter((l) => l.cuenta_id === c.id && l.estado === 'activa');
                const ts = trabajos.filter((t) => t.cuenta_id === c.id);
                return (
                  <div key={c.id} className="tcard">
                    <button className="tbl" onClick={() => setLlevar(c.id)} aria-label={`Para llevar #${c.folio}`}>
                      <b>#{c.folio}</b>
                      <span className="st s-pedido_enviado">Para llevar</span>
                      <small>
                        {ls.reduce((n, l) => n + l.cantidad, 0)} productos · {dinero(ls.reduce((n, l) => n + l.precio_unitario * l.cantidad, 0))}
                      </small>
                      {estadoDeComandas(ts) && <EstadoImp estado={estadoDeComandas(ts)!} />}
                    </button>
                  </div>
                );
              })}
            </div>
            {!cuentas.some((c) => c.tipo === 'llevar' && c.estado === 'abierta') && (
              <p className="hint">No hay pedidos para llevar abiertos. Caja los cobra.</p>
            )}
          </>
        )}
      </main>
    </div>
  );
}
