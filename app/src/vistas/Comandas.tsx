import { useCallback, useEffect, useState } from 'react';
import { mensajeDe, supabase } from '../lib/supabase';
import { useEnVivo } from '../lib/vivo';
import { useAviso } from '../componentes/Aviso';
import ListaComandas from '../componentes/ListaComandas';
import { CAMPOS_TRABAJO, fechaHora, type EstadoImpresion, type Trabajo } from '../lib/tipos';
import { EstadoImp } from '../componentes/Comanda';
import { llamar } from '../lib/supabase';

interface TrabajoCaja {
  id: string; documento: 'ticket' | 'precuenta' | 'corte'; estado: EstadoImpresion; ultimo_error: string | null; creado_en: string;
  contenido: { destino?: string; folio?: number } | null;
}
interface Servicio {
  ultimo_latido: string; equipo: string | null; pendientes: number;
  impresoras: Record<string, { nombre: string; estado: string }>;
}

// Estado de las impresoras y cola de comandas de cocina: lo pendiente, lo que
// falló y lo reciente. Caja y propietarios la ven.
export default function Comandas() {
  const aviso = useAviso();
  const [trabajos, setTrabajos] = useState<Trabajo[]>([]);
  const [ocupado, setOcupado] = useState(false);
  const [servicio, setServicio] = useState<Servicio | null | undefined>(undefined);
  const [caja, setCaja] = useState<TrabajoCaja[]>([]);
  const [ahora, setAhora] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setAhora(Date.now()), 10_000); return () => clearInterval(t); }, []);

  const cargar = useCallback(async () => {
    const { data, error } = await supabase.from('trabajos_impresion').select(CAMPOS_TRABAJO)
      .eq('documento', 'comanda').order('creado_en', { ascending: false }).limit(60);
    if (error) aviso(mensajeDe(error));
    else setTrabajos(data as unknown as Trabajo[]);
    // Impresiones de caja (cuentas, tickets, cortes) que fallaron o siguen esperando.
    const c = await supabase.from('trabajos_impresion').select('id, documento, estado, ultimo_error, creado_en, contenido')
      .eq('impresora', 'caja').in('estado', ['pendiente', 'error']).order('creado_en', { ascending: false }).limit(20);
    setCaja((c.data ?? []) as TrabajoCaja[]);
    const s = await supabase.from('servicio_impresion').select('ultimo_latido, equipo, impresoras, pendientes').maybeSingle();
    setServicio((s.data as Servicio | null) ?? null);
  }, [aviso]);
  useEffect(() => { cargar(); }, [cargar]);
  useEnVivo(['trabajos_impresion', 'servicio_impresion'], cargar);

  async function accion(fn: () => Promise<unknown>, exito?: string) {
    setOcupado(true);
    try { await fn(); if (exito) aviso(exito); return true; }
    catch (e) { aviso(mensajeDe(e)); return false; }
    finally { setOcupado(false); await cargar(); }
  }

  const errores = trabajos.filter((t) => t.estado === 'error');
  const pendientes = trabajos.filter((t) => t.estado === 'pendiente' || t.estado === 'enviado');

  const conectado = servicio && ahora - new Date(servicio.ultimo_latido).getTime() < 60_000;
  const conProblema = servicio && Object.values(servicio.impresoras ?? {}).some((i) => i.estado !== 'lista' && i.estado !== 'imprimiendo');

  return (
    <>
      <div className="box" style={{ borderColor: conectado && !conProblema ? undefined : 'var(--er)' }}>
        <h2>Impresoras</h2>
        {servicio === undefined ? <p className="note">Revisando…</p>
          : !servicio ? <p className="lock">El servicio de impresión todavía no se instala en la computadora de caja.</p>
          : !conectado ? (
            <p className="lock er">
              Sin conexión con la computadora de caja desde {fechaHora(servicio.ultimo_latido)}. Las comandas esperan en la
              cola y saldrán al volver. Revisa que la computadora esté encendida y con internet.
            </p>
          ) : (
            <>
              {Object.entries(servicio.impresoras ?? {}).sort(([a], [b]) => (a === 'cocina' ? -1 : b === 'cocina' ? 1 : 0)).map(([k, i]) => (
                <div key={k} className="row">
                  <span className="n"><b>{k === 'cocina' ? 'Cocina' : 'Caja'}</b><small>{i.nombre}</small></span>
                  <span className={`chip ${i.estado === 'lista' || i.estado === 'imprimiendo' ? 'g' : 'r'}`}>
                    {i.estado === 'lista' ? 'Lista' : i.estado.charAt(0).toUpperCase() + i.estado.slice(1)}
                  </span>
                </div>
              ))}
              <p className="note">Computadora de caja conectada ({servicio.equipo}).</p>
            </>
          )}
      </div>
      {caja.length > 0 && (
        <div className="box" style={{ borderColor: caja.some((t) => t.estado === 'error') ? 'var(--er)' : undefined }}>
          <h2>Impresora de caja · sin imprimir</h2>
          {caja.map((t) => (
            <div key={t.id} className="cmd">
              <span className="n">
                <b>{t.documento === 'precuenta' ? `Cuenta de ${t.contenido?.destino ?? ''}` : t.documento === 'ticket' ? `Ticket folio ${t.contenido?.folio ?? ''}` : 'Corte de caja'}</b>
                <small>{fechaHora(t.creado_en)}{t.ultimo_error ? ` · ${t.ultimo_error}` : ''}</small>
              </span>
              <EstadoImp estado={t.estado} error={t.ultimo_error} impresoTexto="✓ Impresa" />
              {t.estado === 'error' && (
                <button className="btn" disabled={ocupado}
                        onClick={() => accion(() => llamar('reintentar_impresion', { p_trabajo_id: t.id }), 'Se manda otra vez a la impresora de caja')}>
                  Reintentar
                </button>
              )}
            </div>
          ))}
        </div>
      )}
      {errores.length > 0 && (
        <div className="box" style={{ borderColor: 'var(--er)' }}>
          <h2>No se imprimieron · {errores.length}</h2>
          <p className="lock er">Revisa la impresora de cocina (papel, cable, encendida) y toca Reintentar.</p>
          <ListaComandas trabajos={errores} accion={accion} ocupado={ocupado} conDestino />
        </div>
      )}
      <div className="box">
        <h2>Pendientes de imprimir · {pendientes.length}</h2>
        {pendientes.length === 0 && <p className="note">No hay comandas en espera.</p>}
        <ListaComandas trabajos={pendientes} accion={accion} ocupado={ocupado} conDestino />
        <p className="note">Si la impresora falla, toca Ver para leer la comanda en pantalla.</p>
      </div>
      <div className="box">
        <h2>Impresas recientemente</h2>
        {trabajos.filter((t) => t.estado === 'impreso').length === 0 && <p className="note">Todavía no hay comandas impresas.</p>}
        <ListaComandas trabajos={trabajos.filter((t) => t.estado === 'impreso')} accion={accion} ocupado={ocupado} conDestino />
      </div>
    </>
  );
}
