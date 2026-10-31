import { useEffect, useRef } from 'react';
import { supabase } from './supabase';

// Vuelve a cargar cuando cambian las tablas indicadas (en este u otro teléfono)
// y al regresar a la app. Agrupa cambios seguidos en una sola recarga.
export function useEnVivo(tablas: string[], recargar: () => void) {
  const ref = useRef(recargar);
  ref.current = recargar;
  const clave = tablas.join(',');

  useEffect(() => {
    let espera: ReturnType<typeof setTimeout> | undefined;
    const pedir = () => {
      clearTimeout(espera);
      espera = setTimeout(() => ref.current(), 150);
    };
    const canal = supabase.channel(`vivo-${clave}-${Math.random().toString(36).slice(2)}`);
    for (const tabla of clave.split(',')) {
      canal.on('postgres_changes', { event: '*', schema: 'public', table: tabla }, pedir);
    }
    canal.subscribe();
    const alVolver = () => { if (document.visibilityState === 'visible') pedir(); };
    document.addEventListener('visibilitychange', alVolver);
    window.addEventListener('online', pedir);
    return () => {
      clearTimeout(espera);
      document.removeEventListener('visibilitychange', alVolver);
      window.removeEventListener('online', pedir);
      supabase.removeChannel(canal);
    };
  }, [clave]);
}
