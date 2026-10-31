import { useCallback, useEffect, useState } from 'react';
import { llamar, mensajeDe, supabase } from '../../lib/supabase';
import { useEnVivo } from '../../lib/vivo';
import { useAviso } from '../../componentes/Aviso';
import { fechaHora, type Yo } from '../../lib/tipos';

interface Solicitud {
  id: string; tipo: 'cancelar_cuenta' | 'anular_cobro' | 'cancelar_linea_cobrada'; cuenta_id: string;
  linea_id: string | null; cobro_extra_id: string | null; motivo: string; estado: 'pendiente' | 'aprobada' | 'rechazada';
  solicitada_por: string; solicitada_en: string; resuelta_por: string | null; resuelta_en: string | null; comentario: string | null;
}
interface Registro { id: number; accion: string; motivo: string | null; usuario_id: string | null; creado_en: string }
interface Aviso { id: number; leido_en: string | null; auditoria: Registro }

const TIPO = {
  cancelar_cuenta: 'Cancelar cuenta',
  anular_cobro: 'Anular cobro',
  cancelar_linea_cobrada: 'Quitar producto de cuenta cobrada',
};

export default function Autorizaciones({ yo, alCambiar }: { yo: Yo; alCambiar: () => void }) {
  const aviso = useAviso();
  const [solicitudes, setSolicitudes] = useState<Solicitud[]>([]);
  const [avisos, setAvisos] = useState<Aviso[]>([]);
  const [actividad, setActividad] = useState<Registro[]>([]);
  const [nombres, setNombres] = useState<Record<string, string>>({});
  const [cuentas, setCuentas] = useState<Record<string, string>>({});
  const [comentario, setComentario] = useState<Record<string, string>>({});
  const [ocupado, setOcupado] = useState(false);

  const cargar = useCallback(async () => {
    const [s, a, h, u, m] = await Promise.all([
      supabase.from('autorizaciones').select('*').order('solicitada_en', { ascending: false }).limit(50),
      supabase.from('avisos').select('id, leido_en, auditoria(id, accion, motivo, usuario_id, creado_en)')
        .order('id', { ascending: false }).limit(50),
      supabase.from('auditoria').select('id, accion, motivo, usuario_id, creado_en').order('id', { ascending: false }).limit(80),
      supabase.from('usuarios').select('id, nombre'),
      supabase.from('mesas').select('id, nombre'),
    ]);
    const sol = (s.data ?? []) as Solicitud[];
    setSolicitudes(sol);
    setAvisos((a.data ?? []) as unknown as Aviso[]);
    // Una misma acción deja varias filas (cuenta, productos, mesa): se muestra una.
    const vistos = new Set<string>();
    setActividad(((h.data ?? []) as Registro[]).filter((r) => {
      const k = `${r.creado_en}|${r.usuario_id}|${r.accion}`;
      if (vistos.has(k)) return false;
      vistos.add(k);
      return true;
    }));
    setNombres(Object.fromEntries((u.data ?? []).map((x) => [x.id, x.nombre])));
    const ids = [...new Set(sol.map((x) => x.cuenta_id))];
    if (ids.length) {
      const mesas = Object.fromEntries((m.data ?? []).map((x) => [x.id, x.nombre]));
      const { data } = await supabase.from('cuentas').select('id, folio, tipo, mesa_id').in('id', ids);
      setCuentas(Object.fromEntries((data ?? []).map((c) => [c.id,
        `${c.tipo === 'mesa' ? mesas[c.mesa_id] ?? 'Mesa' : 'Para llevar'} · folio ${c.folio}`])));
    }
  }, []);
  useEffect(() => { cargar(); }, [cargar]);
  useEnVivo(['autorizaciones', 'avisos'], cargar);

  async function resolver(s: Solicitud, aprobar: boolean) {
    setOcupado(true);
    try {
      await llamar('resolver_autorizacion', { p_id: s.id, p_aprobar: aprobar, p_comentario: comentario[s.id] ?? null });
      aviso(aprobar ? 'Aprobada. Queda marcada como cancelada, sin borrarse.' : 'Solicitud rechazada. Nada cambió.');
    } catch (e) { aviso(mensajeDe(e)); }
    finally { setOcupado(false); await cargar(); alCambiar(); }
  }

  async function marcarLeidos() {
    try { await llamar('marcar_avisos_leidos'); } catch (e) { aviso(mensajeDe(e)); }
    await cargar(); alCambiar();
  }

  const sinLeer = avisos.filter((a) => !a.leido_en).length;
  const quien = (id: string | null) => (id ? nombres[id] ?? 'Usuario' : 'Sistema');

  return (
    <>
      <div className="box">
        <h2>Autorizaciones</h2>
        {solicitudes.length === 0 && <p className="note">Sin solicitudes.</p>}
        {solicitudes.map((s) => (
          <div key={s.id} className="row">
            <span className="n">
              <b>{TIPO[s.tipo]} · {cuentas[s.cuenta_id] ?? ''}</b>
              <small>Solicitó {quien(s.solicitada_por)} el {fechaHora(s.solicitada_en)} · Motivo: {s.motivo}</small>
              {s.resuelta_por && <small>{s.estado === 'aprobada' ? 'Aprobó' : 'Rechazó'} {quien(s.resuelta_por)} el {fechaHora(s.resuelta_en!)}{s.comentario ? ` · ${s.comentario}` : ''}</small>}
            </span>
            <span className={`chip ${s.estado === 'aprobada' ? 'g' : s.estado === 'rechazada' ? 'r' : ''}`}>
              {s.estado === 'pendiente' ? 'Pendiente' : s.estado === 'aprobada' ? 'Aprobada' : 'Rechazada'}
            </span>
            {s.estado === 'pendiente' && (s.solicitada_por === yo.id
              ? <span className="note">Esperando al otro propietario</span>
              : <>
                  <input placeholder="Comentario (opcional)" value={comentario[s.id] ?? ''} aria-label="Comentario"
                         onChange={(e) => setComentario({ ...comentario, [s.id]: e.target.value })} />
                  <button className="btn" disabled={ocupado} onClick={() => resolver(s, true)}>Aprobar</button>
                  <button className="btn s" disabled={ocupado} onClick={() => resolver(s, false)}>Rechazar</button>
                </>)}
          </div>
        ))}
        <p className="note">
          Se pide autorización solo para cancelar una cuenta, anular un cobro y quitar un producto de una cuenta ya cobrada.
          Nadie aprueba su propia solicitud y lo aprobado se marca como cancelado, sin borrarse.
        </p>
      </div>

      <div className="box">
        <div className="bar" style={{ marginBottom: 6 }}>
          <h2 style={{ margin: 0 }}>Avisos del otro propietario{sinLeer ? ` · ${sinLeer} sin leer` : ''}</h2>
          {sinLeer > 0 && <button className="btn s" onClick={marcarLeidos}>Marcar como leídos</button>}
        </div>
        {avisos.length === 0 && <p className="note">Aquí aparece cada cambio que haga el otro propietario.</p>}
        {avisos.map((a) => (
          <div key={a.id} className={`log ${a.leido_en ? '' : 'nuevo'}`}>
            {fechaHora(a.auditoria.creado_en)} · <b>{quien(a.auditoria.usuario_id)}</b> · {a.auditoria.accion}
            {a.auditoria.motivo ? ` · Motivo: ${a.auditoria.motivo}` : ''}
          </div>
        ))}
      </div>

      <div className="box">
        <h2>Actividad reciente</h2>
        {actividad.map((r) => (
          <div key={r.id} className="log">
            {fechaHora(r.creado_en)} · <b>{quien(r.usuario_id)}</b> · {r.accion}{r.motivo ? ` · Motivo: ${r.motivo}` : ''}
          </div>
        ))}
      </div>
    </>
  );
}
