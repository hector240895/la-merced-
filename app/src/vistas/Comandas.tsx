import { useCallback, useEffect, useState } from 'react';
import { mensajeDe, supabase } from '../lib/supabase';
import { useEnVivo } from '../lib/vivo';
import { useAviso } from '../componentes/Aviso';
import ListaComandas from '../componentes/ListaComandas';
import { CAMPOS_TRABAJO, type Trabajo } from '../lib/tipos';

// Cola de impresión de cocina: lo pendiente, lo que falló y lo reciente.
// Caja y propietarios la ven; el servicio de impresión llega en la Etapa 6.
export default function Comandas() {
  const aviso = useAviso();
  const [trabajos, setTrabajos] = useState<Trabajo[]>([]);
  const [ocupado, setOcupado] = useState(false);

  const cargar = useCallback(async () => {
    const { data, error } = await supabase.from('trabajos_impresion').select(CAMPOS_TRABAJO)
      .eq('documento', 'comanda').order('creado_en', { ascending: false }).limit(60);
    if (error) aviso(mensajeDe(error));
    else setTrabajos(data as unknown as Trabajo[]);
  }, [aviso]);
  useEffect(() => { cargar(); }, [cargar]);
  useEnVivo(['trabajos_impresion'], cargar);

  async function accion(fn: () => Promise<unknown>, exito?: string) {
    setOcupado(true);
    try { await fn(); if (exito) aviso(exito); return true; }
    catch (e) { aviso(mensajeDe(e)); return false; }
    finally { setOcupado(false); await cargar(); }
  }

  const errores = trabajos.filter((t) => t.estado === 'error');
  const pendientes = trabajos.filter((t) => t.estado === 'pendiente' || t.estado === 'enviado');

  return (
    <>
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
        <p className="note">
          La impresión automática en la impresora de cocina se activa en la Etapa 6. Mientras tanto, toca Ver para
          leer la comanda en pantalla.
        </p>
      </div>
      <div className="box">
        <h2>Impresas recientemente</h2>
        {trabajos.filter((t) => t.estado === 'impreso').length === 0 && <p className="note">Todavía no hay comandas impresas.</p>}
        <ListaComandas trabajos={trabajos.filter((t) => t.estado === 'impreso')} accion={accion} ocupado={ocupado} conDestino />
      </div>
    </>
  );
}
