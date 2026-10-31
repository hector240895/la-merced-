import { useCallback, useEffect, useState } from 'react';
import { llamar, mensajeDe, supabase } from '../../lib/supabase';
import { useEnVivo } from '../../lib/vivo';
import { useAviso } from '../../componentes/Aviso';
import { ESTADO_MESA, type Cuenta, type Mesa } from '../../lib/tipos';

// Administración de mesas: agregar, renombrar, ordenar, activar o desactivar,
// eliminar (se conserva con su historial) y pedir la cancelación de una cuenta.
export default function MesasAdmin() {
  const aviso = useAviso();
  const [mesas, setMesas] = useState<Mesa[]>([]);
  const [cuentas, setCuentas] = useState<Cuenta[]>([]);
  const [nueva, setNueva] = useState('');
  const [nombres, setNombres] = useState<Record<string, string>>({});
  const [cancelando, setCancelando] = useState<string | null>(null);
  const [motivo, setMotivo] = useState('');
  const [ocupado, setOcupado] = useState(false);

  const cargar = useCallback(async () => {
    const [m, c] = await Promise.all([
      supabase.from('mesas').select('id, nombre, orden, activa, estado, unida_a, eliminada_en')
        .is('eliminada_en', null).order('orden').order('nombre'),
      supabase.from('cuentas').select('id, folio, tipo, mesa_id, estado, mesero_id, cobro_anulado_en')
        .eq('tipo', 'mesa').in('estado', ['abierta', 'por_cobrar']).is('cobro_anulado_en', null),
    ]);
    if (m.data) setMesas(m.data as Mesa[]);
    if (c.data) setCuentas(c.data as Cuenta[]);
  }, []);
  useEffect(() => { cargar(); }, [cargar]);
  useEnVivo(['mesas', 'cuentas'], cargar);

  async function hacer(fn: () => Promise<unknown>, exito: string) {
    setOcupado(true);
    try { await fn(); aviso(exito); return true; } catch (e) { aviso(mensajeDe(e)); return false; }
    finally { setOcupado(false); await cargar(); }
  }

  const nombreDe = (id: string | null) => mesas.find((m) => m.id === id)?.nombre ?? '';

  async function mover(i: number, d: number) {
    const ids = mesas.map((m) => m.id);
    const j = i + d;
    if (j < 0 || j >= ids.length) return;
    [ids[i], ids[j]] = [ids[j], ids[i]];
    await hacer(() => llamar('ordenar_mesas', { p_ids: ids }), 'Orden actualizado');
  }

  return (
    <>
      <div className="box">
        <h2>Agregar mesa</h2>
        <form className="f" onSubmit={async (e) => {
          e.preventDefault();
          if (await hacer(() => llamar('crear_mesa', { p_nombre: nueva }), `Mesa ${nueva.trim()} agregada`)) setNueva('');
        }}>
          <input placeholder="Nombre de la mesa nueva" value={nueva} onChange={(e) => setNueva(e.target.value)} aria-label="Nombre de la mesa nueva" />
          <button className="btn" disabled={ocupado || !nueva.trim()}>Agregar mesa</button>
        </form>
      </div>

      <div className="box">
        <h2>Mesas del salón · {mesas.filter((m) => m.activa).length} activas</h2>
        {mesas.map((m, i) => {
          const cuenta = cuentas.find((c) => c.mesa_id === m.id);
          return (
            <div key={m.id}>
              <div className="row">
                <span className="n">
                  <b>{m.nombre}</b>
                  <small>
                    {ESTADO_MESA[m.estado]}
                    {m.unida_a ? ` · unida a ${nombreDe(m.unida_a)}` : ''}
                    {cuenta ? ` · cuenta folio ${cuenta.folio}` : ''}
                  </small>
                </span>
                <span className={`chip ${m.activa ? 'g' : ''}`}>{m.activa ? 'Activa' : 'Desactivada'}</span>
                <button className="btn s" aria-label={`Subir ${m.nombre}`} disabled={ocupado || i === 0} onClick={() => mover(i, -1)}>↑</button>
                <button className="btn s" aria-label={`Bajar ${m.nombre}`} disabled={ocupado || i === mesas.length - 1} onClick={() => mover(i, 1)}>↓</button>
                <input placeholder="Nuevo nombre" value={nombres[m.id] ?? ''} aria-label={`Nuevo nombre para ${m.nombre}`}
                       onChange={(e) => setNombres({ ...nombres, [m.id]: e.target.value })} style={{ width: 150 }} />
                <button className="btn s" disabled={ocupado || !(nombres[m.id] ?? '').trim()}
                        onClick={async () => {
                          if (await hacer(() => llamar('renombrar_mesa', { p_id: m.id, p_nombre: nombres[m.id] }), 'Mesa renombrada')) {
                            setNombres({ ...nombres, [m.id]: '' });
                          }
                        }}>Renombrar</button>
                <button className="btn s" disabled={ocupado}
                        onClick={() => hacer(() => llamar('activar_mesa', { p_id: m.id, p_activa: !m.activa }),
                          m.activa ? `${m.nombre} desactivada` : `${m.nombre} activada`)}>
                  {m.activa ? 'Desactivar' : 'Activar'}
                </button>
                <button className="btn d" disabled={ocupado}
                        onClick={() => {
                          if (confirm(`¿Eliminar ${m.nombre}? Deja de aparecer en el salón; su historial se conserva.`)) {
                            hacer(() => llamar('eliminar_mesa', { p_id: m.id }), `${m.nombre} eliminada`);
                          }
                        }}>Eliminar</button>
                {cuenta && (
                  <button className="btn s" disabled={ocupado} onClick={() => { setCancelando(cuenta.id); setMotivo(''); }}>
                    Solicitar cancelar cuenta
                  </button>
                )}
              </div>
              {cuenta && cancelando === cuenta.id && (
                <div className="f" style={{ padding: '0 0 10px' }}>
                  <input autoFocus placeholder="Motivo de la cancelación (obligatorio)" value={motivo} onChange={(e) => setMotivo(e.target.value)}
                         aria-label="Motivo de la cancelación" />
                  <button className="btn" disabled={ocupado || !motivo.trim()}
                          onClick={async () => {
                            if (await hacer(() => llamar('solicitar_autorizacion', { p_tipo: 'cancelar_cuenta', p_cuenta_id: cuenta.id, p_motivo: motivo }),
                              'Solicitud enviada al otro propietario. La cuenta no cambia hasta que la apruebe.')) setCancelando(null);
                          }}>Enviar solicitud</button>
                  <button className="btn s" onClick={() => setCancelando(null)}>Cancelar</button>
                </div>
              )}
            </div>
          );
        })}
        <p className="note">
          Una mesa con cuenta abierta no se puede desactivar ni eliminar. Las mesas eliminadas conservan su historial.
          Cancelar una cuenta requiere la autorización del otro propietario.
        </p>
      </div>
    </>
  );
}
