import { useCallback, useEffect, useState } from 'react';
import { llamar, mensajeDe, supabase } from '../lib/supabase';
import { useEnVivo } from '../lib/vivo';
import { useAviso } from '../componentes/Aviso';
import { dinero } from '../lib/tipos';
import {
  FORMA_PAGO, PERIODOS, fechaCorta, hoy, rango,
  type CategoriaGasto, type Empleado, type FormaPago, type Gasto, type GastoFijo, type Periodo,
} from '../lib/finanzas';

// Gastos. Propietarios: todo (gastos, sueldos, gastos fijos y categorías).
// Caja: gastos pagados con el efectivo de la caja, del día.

type Seccion = 'gastos' | 'sueldos' | 'fijos' | 'categorias';
const PUESTOS = ['Lavaloza', 'Cocinera', 'Mesero', 'Cajero'];
const PERIODICIDAD = { semanal: 'semana', quincenal: 'quincena', mensual: 'mes' } as const;
const FORMAS_PROPIETARIO: FormaPago[] = ['efectivo', 'transferencia', 'tarjeta', 'caja'];

type FormGasto = { categoria_id: string; concepto: string; monto: string; forma: FormaPago; fecha: string; nota: string; pagado_por: string };
type FormEmpleado = { id: string | null; nombre: string; puesto: string; sueldo: string; periodicidad: Empleado['periodicidad'] };
type FormFijo = { id: string | null; categoria_id: string; concepto: string; monto: string; dia: string; forma: FormaPago; pagado_por: string };

export default function Gastos({ esPropietario, yoId = '' }: { esPropietario: boolean; yoId?: string }) {
  const aviso = useAviso();
  const [seccion, setSeccion] = useState<Seccion>('gastos');
  const [categorias, setCategorias] = useState<CategoriaGasto[]>([]);
  const [gastos, setGastos] = useState<Gasto[]>([]);
  const [empleados, setEmpleados] = useState<Empleado[]>([]);
  const [fijos, setFijos] = useState<GastoFijo[]>([]);
  const [duenos, setDuenos] = useState<{ id: string; nombre: string }[]>([]);
  const [filtroDueno, setFiltroDueno] = useState('');
  const [periodo, setPeriodo] = useState<Periodo>(esPropietario ? 'mes' : 'hoy');
  const [fechas, setFechas] = useState<[string, string]>([hoy(), hoy()]);
  const [filtro, setFiltro] = useState('');
  const [ocupado, setOcupado] = useState(false);
  const vacio = (): FormGasto => ({ categoria_id: '', concepto: '', monto: '', forma: esPropietario ? 'efectivo' : 'caja', fecha: hoy(), nota: '', pagado_por: yoId });
  const [fGasto, setFGasto] = useState<FormGasto | null>(null);
  const [anulando, setAnulando] = useState<Gasto | null>(null);
  const [motivo, setMotivo] = useState('');
  const [fEmpleado, setFEmpleado] = useState<FormEmpleado | null>(null);
  const [nomina, setNomina] = useState<{ periodo: string; forma: FormaPago; fecha: string; pagado_por: string; montos: Record<string, string> } | null>(null);
  const [fFijo, setFFijo] = useState<FormFijo | null>(null);
  const [nuevaCat, setNuevaCat] = useState('');
  const [renombres, setRenombres] = useState<Record<string, string>>({});

  const [desde, hasta] = rango(periodo, fechas[0], fechas[1]);

  const cargar = useCallback(async () => {
    if (esPropietario) await supabase.rpc('generar_gastos_fijos');
    const [c, g] = await Promise.all([
      supabase.from('categorias_gasto').select('id, clave, nombre, orden').is('eliminado_en', null).order('orden').order('nombre'),
      supabase.from('gastos')
        .select('id, categoria_id, concepto, monto, fecha, forma_pago, estado, nota, anulacion_motivo, gasto_fijo_id, creado_en, pagado_por, usuarios!gastos_creado_por_fkey(nombre)')
        .gte('fecha', desde).lte('fecha', hasta).order('fecha', { ascending: false }).order('creado_en', { ascending: false }),
    ]);
    if (c.data) setCategorias(c.data as CategoriaGasto[]);
    if (g.data) setGastos(g.data as unknown as Gasto[]);
    if (esPropietario) {
      const [e, f, d] = await Promise.all([
        supabase.from('empleados').select('id, nombre, puesto, sueldo, periodicidad').is('eliminado_en', null).order('nombre'),
        supabase.from('gastos_fijos').select('id, categoria_id, concepto, monto, dia, forma_pago, desde, pagado_por').is('eliminado_en', null).order('dia'),
        supabase.from('usuarios').select('id, nombre').eq('perfil', 'propietario').eq('activo', true).order('nombre'),
      ]);
      if (d.data) setDuenos(d.data);
      if (e.data) setEmpleados(e.data as Empleado[]);
      if (f.data) setFijos(f.data as GastoFijo[]);
    }
  }, [esPropietario, desde, hasta]);
  useEffect(() => { cargar(); }, [cargar]);
  useEnVivo(['gastos', 'categorias_gasto', 'empleados', 'gastos_fijos'], cargar);

  async function hacer(fn: () => Promise<unknown>, exito: string) {
    setOcupado(true);
    try { await fn(); aviso(exito); return true; } catch (e) { aviso(mensajeDe(e)); return false; }
    finally { setOcupado(false); await cargar(); }
  }

  const nombreCat = (id: string) => categorias.find((c) => c.id === id)?.nombre ?? '—';
  // Caja no registra renta ni sueldos.
  const catsParaGasto = categorias.filter((c) => esPropietario || !['renta', 'nomina'].includes(c.clave ?? ''));
  const vigentes = gastos.filter((g) => g.estado === 'vigente');
  const nombreDueno = (id: string | null) => duenos.find((d) => d.id === id)?.nombre;
  // Filtro por dueño: un id, "caja" o vacío (todos).
  const deDueno = (g: Gasto) => !filtroDueno || (filtroDueno === 'caja' ? g.forma_pago === 'caja' : g.pagado_por === filtroDueno);
  const pasa = (g: Gasto) => (!filtro || g.categoria_id === filtro) && deDueno(g);
  const visibles = gastos.filter(pasa);
  const total = vigentes.filter(pasa).reduce((s, g) => s + Number(g.monto), 0);
  const totalNomina = nomina ? Object.values(nomina.montos).reduce((s, m) => s + (Number(m) || 0), 0) : 0;

  async function guardarGasto() {
    if (!fGasto) return;
    const ok = await hacer(() => llamar('registrar_gasto', {
      p_categoria_id: fGasto.categoria_id || null, p_concepto: fGasto.concepto, p_monto: fGasto.monto === '' ? null : Number(fGasto.monto),
      p_forma_pago: fGasto.forma, p_fecha: fGasto.fecha, p_nota: fGasto.nota || null,
      ...(esPropietario && fGasto.forma !== 'caja' ? { p_pagado_por: fGasto.pagado_por || null } : {}),
    }), `Gasto de ${dinero(Number(fGasto.monto))} registrado`);
    if (ok) setFGasto(null);
  }

  function abrirNomina() {
    setNomina({
      periodo: '', forma: 'efectivo', fecha: hoy(), pagado_por: yoId,
      montos: Object.fromEntries(empleados.map((e) => [e.id, String(Number(e.sueldo))])),
    });
  }

  const cerrar = (fn: () => void) => (e: React.MouseEvent) => { if (e.target === e.currentTarget) fn(); };

  return (
    <>
      {esPropietario && (
        <nav className="nav2" aria-label="Secciones de gastos">
          {([['gastos', 'Gastos'], ['sueldos', 'Sueldos'], ['fijos', 'Renta y gastos fijos'], ['categorias', 'Categorías']] as [Seccion, string][]).map(([k, t]) => (
            <button key={k} className={seccion === k ? 'on' : ''} onClick={() => setSeccion(k)}>{t}</button>
          ))}
        </nav>
      )}

      {seccion === 'gastos' && (
        <>
          <div className="box">
            <h2>{esPropietario ? 'Gastos' : 'Gastos pagados con la caja'}</h2>
            <p className="hint">
              {esPropietario
                ? 'Todo lo que se gasta: así el reporte muestra la utilidad real. Lo pagado con el efectivo de la caja se descuenta del corte.'
                : 'Gas, garrafones, desechables… pagados con el efectivo de la caja. Se descuentan del efectivo esperado en el corte.'}
            </p>
            <div className="f">
              <button className="btn" disabled={ocupado} onClick={() => setFGasto(vacio())}>Registrar gasto</button>
              {esPropietario && (
                <>
                  <select aria-label="Periodo" value={periodo} onChange={(e) => setPeriodo(e.target.value as Periodo)}>
                    {PERIODOS.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
                  </select>
                  {periodo === 'otro' && (
                    <>
                      <input type="date" aria-label="Desde" value={fechas[0]} max={hoy()} onChange={(e) => setFechas([e.target.value, fechas[1]])} />
                      <input type="date" aria-label="Hasta" value={fechas[1]} max={hoy()} onChange={(e) => setFechas([fechas[0], e.target.value])} />
                    </>
                  )}
                  <select aria-label="Categoría a mostrar" value={filtro} onChange={(e) => setFiltro(e.target.value)}>
                    <option value="">Todas las categorías</option>
                    {categorias.map((c) => <option key={c.id} value={c.id}>{c.nombre}</option>)}
                  </select>
                  <select aria-label="Quién pagó" value={filtroDueno} onChange={(e) => setFiltroDueno(e.target.value)}>
                    <option value="">Pagado por todos</option>
                    {duenos.map((d) => <option key={d.id} value={d.id}>Pagó {d.nombre}</option>)}
                    <option value="caja">Pagado con la caja</option>
                  </select>
                </>
              )}
            </div>
            <p className="tot"><span>Total{esPropietario ? ' del periodo' : ' de hoy'}</span><span>{dinero(total)}</span></p>
          </div>
          <div className="box">
            {visibles.length === 0 && <p className="vacio">Sin gastos {esPropietario ? 'en este periodo' : 'hoy'}.</p>}
            {visibles.map((g) => (
              <div className="row" key={g.id}>
                <span className="n">
                  <b style={g.estado === 'anulado' ? { textDecoration: 'line-through' } : undefined}>{g.concepto}</b>
                  <small>
                    {fechaCorta(g.fecha)} · {nombreCat(g.categoria_id)} · {FORMA_PAGO[g.forma_pago]}
                    {esPropietario && nombreDueno(g.pagado_por) ? ` · pagó ${nombreDueno(g.pagado_por)}` : ''}
                    {g.gasto_fijo_id ? ' · automático' : ` · ${g.usuarios?.nombre ?? '—'}`}{g.nota ? ` · ${g.nota}` : ''}
                    {g.estado === 'anulado' ? ` · ANULADO: ${g.anulacion_motivo}` : ''}
                  </small>
                </span>
                <span className={`chip ${g.estado === 'anulado' ? '' : 'r'}`}>{dinero(g.monto)}</span>
                {esPropietario && g.estado === 'vigente' && (
                  <button className="btn s d" disabled={ocupado} aria-label={`Anular ${g.concepto}`}
                          onClick={() => { setAnulando(g); setMotivo(''); }}>Anular</button>
                )}
              </div>
            ))}
          </div>
        </>
      )}

      {esPropietario && seccion === 'sueldos' && (
        <div className="box">
          <h2>Empleados y sueldos</h2>
          <p className="hint">Guarda a cada empleado con su sueldo fijo. Al pagar, los montos se llenan solos y solo ajustas a quien faltó.</p>
          <div className="f">
            <button className="btn" disabled={ocupado || empleados.length === 0} onClick={abrirNomina}>Pagar sueldos</button>
            <button className="btn s" disabled={ocupado}
                    onClick={() => setFEmpleado({ id: null, nombre: '', puesto: '', sueldo: '', periodicidad: 'semanal' })}>Agregar empleado</button>
          </div>
          {empleados.length === 0 && <p className="vacio">Aún no hay empleados.</p>}
          {empleados.map((e) => (
            <div className="row" key={e.id}>
              <span className="n"><b>{e.nombre}</b><small>{e.puesto ?? 'Sin puesto'}</small></span>
              <span className="chip">{dinero(e.sueldo)} por {PERIODICIDAD[e.periodicidad]}</span>
              <button className="btn s" disabled={ocupado} aria-label={`Editar a ${e.nombre}`}
                      onClick={() => setFEmpleado({ id: e.id, nombre: e.nombre, puesto: e.puesto ?? '', sueldo: String(Number(e.sueldo)), periodicidad: e.periodicidad })}>Editar</button>
              <button className="btn s d" disabled={ocupado} aria-label={`Quitar a ${e.nombre}`}
                      onClick={() => { if (confirm(`¿Quitar a ${e.nombre} de la lista? Sus pagos se conservan.`)) hacer(() => llamar('eliminar_empleado', { p_id: e.id }), `${e.nombre} quitado de la lista`); }}>Quitar</button>
            </div>
          ))}
        </div>
      )}

      {esPropietario && seccion === 'fijos' && (
        <div className="box">
          <h2>Renta y gastos fijos</h2>
          <p className="hint">Se registran solos cada mes en el día que elijas. Si cambias el monto, cuenta desde el siguiente mes.</p>
          <div className="f">
            <button className="btn" disabled={ocupado}
                    onClick={() => setFFijo({ id: null, categoria_id: categorias.find((c) => c.clave === 'renta')?.id ?? '', concepto: 'Renta del local', monto: '', dia: '1', forma: 'transferencia', pagado_por: yoId })}>Agregar gasto fijo</button>
          </div>
          {fijos.length === 0 && <p className="vacio">Sin gastos fijos. Agrega la renta para que se registre sola.</p>}
          {fijos.map((f) => (
            <div className="row" key={f.id}>
              <span className="n"><b>{f.concepto}</b><small>{nombreCat(f.categoria_id)} · día {f.dia} de cada mes · {FORMA_PAGO[f.forma_pago]}{nombreDueno(f.pagado_por) ? ` · paga ${nombreDueno(f.pagado_por)}` : ''}</small></span>
              <span className="chip">{dinero(f.monto)} al mes</span>
              <button className="btn s" disabled={ocupado} aria-label={`Editar ${f.concepto}`}
                      onClick={() => setFFijo({ id: f.id, categoria_id: f.categoria_id, concepto: f.concepto, monto: String(Number(f.monto)), dia: String(f.dia), forma: f.forma_pago, pagado_por: f.pagado_por ?? yoId })}>Editar</button>
              <button className="btn s d" disabled={ocupado} aria-label={`Quitar ${f.concepto}`}
                      onClick={() => { if (confirm(`¿Dejar de registrar "${f.concepto}" cada mes? Lo ya registrado se conserva.`)) hacer(() => llamar('eliminar_gasto_fijo', { p_id: f.id }), 'Gasto fijo quitado'); }}>Quitar</button>
            </div>
          ))}
        </div>
      )}

      {esPropietario && seccion === 'categorias' && (
        <div className="box">
          <h2>Categorías de gasto</h2>
          <form className="f" onSubmit={async (e) => {
            e.preventDefault();
            if (await hacer(() => llamar('guardar_categoria_gasto', { p_id: null, p_nombre: nuevaCat }), `Categoría ${nuevaCat.trim()} agregada`)) setNuevaCat('');
          }}>
            <input placeholder="Nombre de la categoría nueva" aria-label="Nombre de la categoría nueva" value={nuevaCat} onChange={(e) => setNuevaCat(e.target.value)} />
            <button className="btn" disabled={ocupado || !nuevaCat.trim()}>Agregar categoría</button>
          </form>
          {categorias.map((c) => (
            <div className="row" key={c.id}>
              <span className="n"><b>{c.nombre}</b></span>
              <input placeholder="Nuevo nombre" aria-label={`Nuevo nombre para ${c.nombre}`} value={renombres[c.id] ?? ''} style={{ width: 160 }}
                     onChange={(e) => setRenombres({ ...renombres, [c.id]: e.target.value })} />
              <button className="btn s" disabled={ocupado || !(renombres[c.id] ?? '').trim()}
                      onClick={async () => { if (await hacer(() => llamar('guardar_categoria_gasto', { p_id: c.id, p_nombre: renombres[c.id] }), 'Categoría renombrada')) setRenombres({ ...renombres, [c.id]: '' }); }}>Renombrar</button>
              {!['nomina', 'compras_mercancia', 'otros'].includes(c.clave ?? '') && (
                <button className="btn s d" disabled={ocupado} aria-label={`Quitar categoría ${c.nombre}`}
                        onClick={() => { if (confirm(`¿Quitar la categoría ${c.nombre}? Los gastos ya registrados la conservan.`)) hacer(() => llamar('eliminar_categoria_gasto', { p_id: c.id }), `Categoría ${c.nombre} quitada`); }}>Quitar</button>
              )}
            </div>
          ))}
        </div>
      )}

      {fGasto && (
        <div className="sheet centro" onClick={cerrar(() => setFGasto(null))}>
          <div className="pane formulario" role="dialog" aria-label="Registrar gasto">
            <h2>Registrar gasto</h2>
            <label htmlFor="g-cat">Categoría</label>
            <select id="g-cat" value={fGasto.categoria_id} onChange={(e) => setFGasto({ ...fGasto, categoria_id: e.target.value })}>
              <option value="">Elige una categoría</option>
              {catsParaGasto.map((c) => <option key={c.id} value={c.id}>{c.nombre}</option>)}
            </select>
            <label htmlFor="g-concepto">¿En qué se gastó?</label>
            <input id="g-concepto" placeholder="Tanque de gas, 4 garrafones…" value={fGasto.concepto} onChange={(e) => setFGasto({ ...fGasto, concepto: e.target.value })} />
            <label htmlFor="g-monto">Monto $</label>
            <input id="g-monto" type="number" inputMode="decimal" min="0" step="any" value={fGasto.monto} onChange={(e) => setFGasto({ ...fGasto, monto: e.target.value })} />
            {esPropietario ? (
              <div className="par">
                <span>
                  <label htmlFor="g-forma">¿Cómo se pagó?</label>
                  <select id="g-forma" value={fGasto.forma} onChange={(e) => setFGasto({ ...fGasto, forma: e.target.value as FormaPago })}>
                    {FORMAS_PROPIETARIO.map((f) => <option key={f} value={f}>{FORMA_PAGO[f]}</option>)}
                  </select>
                </span>
                <span>
                  <label htmlFor="g-fecha">Fecha</label>
                  <input id="g-fecha" type="date" max={hoy()} value={fGasto.fecha} onChange={(e) => setFGasto({ ...fGasto, fecha: e.target.value })} />
                </span>
              </div>
            ) : (
              <p className="hint">Se paga con el efectivo de la caja y se descuenta del corte.</p>
            )}
            {esPropietario && fGasto.forma !== 'caja' && (
              <>
                <label htmlFor="g-quien">¿Quién lo pagó?</label>
                <select id="g-quien" value={fGasto.pagado_por} onChange={(e) => setFGasto({ ...fGasto, pagado_por: e.target.value })}>
                  {duenos.map((d) => <option key={d.id} value={d.id}>{d.nombre}</option>)}
                </select>
              </>
            )}
            {esPropietario && fGasto.forma === 'caja' && <p className="hint">Sale de la caja abierta y baja el efectivo esperado del corte.</p>}
            <label htmlFor="g-nota">Nota (opcional)</label>
            <input id="g-nota" value={fGasto.nota} onChange={(e) => setFGasto({ ...fGasto, nota: e.target.value })} />
            <div className="f" style={{ marginTop: 12 }}>
              <button className="btn s" type="button" onClick={() => setFGasto(null)}>Cancelar</button>
              <button className="btn" disabled={ocupado} onClick={guardarGasto}>Guardar gasto</button>
            </div>
          </div>
        </div>
      )}

      {anulando && (
        <div className="sheet centro" onClick={cerrar(() => setAnulando(null))}>
          <div className="pane formulario" role="dialog" aria-label="Anular gasto">
            <h2>Anular gasto</h2>
            <p className="hint">{anulando.concepto} · {dinero(anulando.monto)}. No se borra: queda marcado como anulado.
              {anulando.forma_pago === 'caja' ? ' Si la caja sigue abierta, el efectivo regresa a la caja.' : ''}
              {nombreCat(anulando.categoria_id) === 'Insumos y mercancía' ? ' Si fue una compra, se descuenta del inventario.' : ''}</p>
            <label htmlFor="a-motivo">Motivo</label>
            <input id="a-motivo" value={motivo} onChange={(e) => setMotivo(e.target.value)} placeholder="Se capturó dos veces, monto equivocado…" />
            <div className="f" style={{ marginTop: 12 }}>
              <button className="btn s" type="button" onClick={() => setAnulando(null)}>Cancelar</button>
              <button className="btn" disabled={ocupado || !motivo.trim()}
                      onClick={async () => { if (await hacer(() => llamar('anular_gasto', { p_gasto_id: anulando.id, p_motivo: motivo }), 'Gasto anulado')) setAnulando(null); }}>Anular gasto</button>
            </div>
          </div>
        </div>
      )}

      {fEmpleado && (
        <div className="sheet centro" onClick={cerrar(() => setFEmpleado(null))}>
          <div className="pane formulario" role="dialog" aria-label={fEmpleado.id ? 'Editar empleado' : 'Agregar empleado'}>
            <h2>{fEmpleado.id ? 'Editar empleado' : 'Agregar empleado'}</h2>
            <label htmlFor="e-nombre">Nombre</label>
            <input id="e-nombre" value={fEmpleado.nombre} onChange={(e) => setFEmpleado({ ...fEmpleado, nombre: e.target.value })} />
            <label htmlFor="e-puesto">Puesto</label>
            <input id="e-puesto" list="puestos" placeholder="Cocinera, lavaloza…" value={fEmpleado.puesto} onChange={(e) => setFEmpleado({ ...fEmpleado, puesto: e.target.value })} />
            <datalist id="puestos">{PUESTOS.map((p) => <option key={p} value={p} />)}</datalist>
            <div className="par">
              <span>
                <label htmlFor="e-sueldo">Sueldo $</label>
                <input id="e-sueldo" type="number" inputMode="decimal" min="0" step="any" value={fEmpleado.sueldo} onChange={(e) => setFEmpleado({ ...fEmpleado, sueldo: e.target.value })} />
              </span>
              <span>
                <label htmlFor="e-cada">Cada</label>
                <select id="e-cada" value={fEmpleado.periodicidad} onChange={(e) => setFEmpleado({ ...fEmpleado, periodicidad: e.target.value as Empleado['periodicidad'] })}>
                  <option value="semanal">Semana</option><option value="quincenal">Quincena</option><option value="mensual">Mes</option>
                </select>
              </span>
            </div>
            <div className="f" style={{ marginTop: 12 }}>
              <button className="btn s" type="button" onClick={() => setFEmpleado(null)}>Cancelar</button>
              <button className="btn" disabled={ocupado} onClick={async () => {
                const ok = await hacer(() => llamar('guardar_empleado', {
                  p_id: fEmpleado.id, p_nombre: fEmpleado.nombre, p_puesto: fEmpleado.puesto || null,
                  p_sueldo: fEmpleado.sueldo === '' ? null : Number(fEmpleado.sueldo), p_periodicidad: fEmpleado.periodicidad,
                }), fEmpleado.id ? 'Empleado actualizado' : 'Empleado agregado');
                if (ok) setFEmpleado(null);
              }}>{fEmpleado.id ? 'Guardar cambios' : 'Agregar empleado'}</button>
            </div>
          </div>
        </div>
      )}

      {nomina && (
        <div className="sheet centro" onClick={cerrar(() => setNomina(null))}>
          <div className="pane formulario" role="dialog" aria-label="Pagar sueldos">
            <h2>Pagar sueldos</h2>
            <p className="hint">Ajusta a quien faltó. Pon 0 si no se le paga esta vez.</p>
            <label htmlFor="n-periodo">¿Qué periodo pagas?</label>
            <input id="n-periodo" placeholder="Semana del 3 al 9 de noviembre" value={nomina.periodo} onChange={(e) => setNomina({ ...nomina, periodo: e.target.value })} />
            {empleados.map((e) => (
              <div key={e.id}>
                <label htmlFor={`n-${e.id}`}>{e.nombre}{e.puesto ? ` · ${e.puesto}` : ''} (fijo {dinero(e.sueldo)})</label>
                <input id={`n-${e.id}`} type="number" inputMode="decimal" min="0" step="any" value={nomina.montos[e.id] ?? ''}
                       onChange={(ev) => setNomina({ ...nomina, montos: { ...nomina.montos, [e.id]: ev.target.value } })} />
              </div>
            ))}
            <div className="par">
              <span>
                <label htmlFor="n-forma">¿Cómo se pagó?</label>
                <select id="n-forma" value={nomina.forma} onChange={(e) => setNomina({ ...nomina, forma: e.target.value as FormaPago })}>
                  {FORMAS_PROPIETARIO.map((f) => <option key={f} value={f}>{FORMA_PAGO[f]}</option>)}
                </select>
              </span>
              <span>
                <label htmlFor="n-fecha">Fecha</label>
                <input id="n-fecha" type="date" max={hoy()} value={nomina.fecha} onChange={(e) => setNomina({ ...nomina, fecha: e.target.value })} />
              </span>
            </div>
            {nomina.forma !== 'caja' && (
              <>
                <label htmlFor="n-quien">¿Quién pagó?</label>
                <select id="n-quien" value={nomina.pagado_por} onChange={(e) => setNomina({ ...nomina, pagado_por: e.target.value })}>
                  {duenos.map((d) => <option key={d.id} value={d.id}>{d.nombre}</option>)}
                </select>
              </>
            )}
            <p className="tot"><span>Total</span><span>{dinero(totalNomina)}</span></p>
            <div className="f" style={{ marginTop: 12 }}>
              <button className="btn s" type="button" onClick={() => setNomina(null)}>Cancelar</button>
              <button className="btn" disabled={ocupado} onClick={async () => {
                const ok = await hacer(() => llamar('pagar_sueldos', {
                  p_pagos: Object.entries(nomina.montos).map(([empleado_id, m]) => ({ empleado_id, monto: Number(m) || 0 })),
                  p_periodo: nomina.periodo, p_forma_pago: nomina.forma, p_fecha: nomina.fecha,
                  ...(nomina.forma !== 'caja' ? { p_pagado_por: nomina.pagado_por || null } : {}),
                }), `Sueldos registrados por ${dinero(totalNomina)}`);
                if (ok) setNomina(null);
              }}>Registrar sueldos</button>
            </div>
          </div>
        </div>
      )}

      {fFijo && (
        <div className="sheet centro" onClick={cerrar(() => setFFijo(null))}>
          <div className="pane formulario" role="dialog" aria-label={fFijo.id ? 'Editar gasto fijo' : 'Agregar gasto fijo'}>
            <h2>{fFijo.id ? 'Editar gasto fijo' : 'Agregar gasto fijo'}</h2>
            <label htmlFor="x-concepto">Concepto</label>
            <input id="x-concepto" value={fFijo.concepto} onChange={(e) => setFFijo({ ...fFijo, concepto: e.target.value })} />
            <label htmlFor="x-cat">Categoría</label>
            <select id="x-cat" value={fFijo.categoria_id} onChange={(e) => setFFijo({ ...fFijo, categoria_id: e.target.value })}>
              <option value="">Elige una categoría</option>
              {categorias.map((c) => <option key={c.id} value={c.id}>{c.nombre}</option>)}
            </select>
            <div className="par">
              <span>
                <label htmlFor="x-monto">Monto al mes $</label>
                <input id="x-monto" type="number" inputMode="decimal" min="0" step="any" value={fFijo.monto} onChange={(e) => setFFijo({ ...fFijo, monto: e.target.value })} />
              </span>
              <span>
                <label htmlFor="x-dia">Día del mes</label>
                <input id="x-dia" type="number" inputMode="numeric" min="1" max="31" value={fFijo.dia} onChange={(e) => setFFijo({ ...fFijo, dia: e.target.value })} />
              </span>
            </div>
            <label htmlFor="x-forma">¿Cómo se paga?</label>
            <select id="x-forma" value={fFijo.forma} onChange={(e) => setFFijo({ ...fFijo, forma: e.target.value as FormaPago })}>
              {FORMAS_PROPIETARIO.filter((f) => f !== 'caja').map((f) => <option key={f} value={f}>{FORMA_PAGO[f]}</option>)}
            </select>
            <label htmlFor="x-quien">¿Quién lo paga?</label>
            <select id="x-quien" value={fFijo.pagado_por} onChange={(e) => setFFijo({ ...fFijo, pagado_por: e.target.value })}>
              {duenos.map((d) => <option key={d.id} value={d.id}>{d.nombre}</option>)}
            </select>
            {!fFijo.id && <p className="hint">Cuenta desde este mes: si el día ya pasó, el de este mes se registra al guardar.</p>}
            <div className="f" style={{ marginTop: 12 }}>
              <button className="btn s" type="button" onClick={() => setFFijo(null)}>Cancelar</button>
              <button className="btn" disabled={ocupado} onClick={async () => {
                const ok = await hacer(() => llamar('guardar_gasto_fijo', {
                  p_id: fFijo.id, p_categoria_id: fFijo.categoria_id || null, p_concepto: fFijo.concepto,
                  p_monto: fFijo.monto === '' ? null : Number(fFijo.monto), p_dia: fFijo.dia === '' ? null : Number(fFijo.dia), p_forma_pago: fFijo.forma, p_pagado_por: fFijo.pagado_por || null,
                }), fFijo.id ? 'Gasto fijo actualizado' : 'Gasto fijo agregado');
                if (ok) setFFijo(null);
              }}>{fFijo.id ? 'Guardar cambios' : 'Agregar gasto fijo'}</button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
