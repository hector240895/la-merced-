import { useCallback, useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { configurado, supabase } from './lib/supabase';
import type { Yo } from './lib/tipos';
import Login from './vistas/Login';
import Salon from './vistas/Salon';
import Propietario from './vistas/Propietario';
import Cajero from './vistas/Cajero';

export default function App() {
  const [sesion, setSesion] = useState<Session | null | undefined>(undefined);
  const [yo, setYo] = useState<Yo | null | undefined>(undefined);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSesion(data.session));
    const { data } = supabase.auth.onAuthStateChange((_evento, s) => setSesion(s));
    return () => data.subscription.unsubscribe();
  }, []);

  const cargarPerfil = useCallback(async () => {
    if (!sesion) { setYo(null); return; }
    const { data, error } = await supabase.rpc('yo').maybeSingle<Yo>();
    if (error || !data) {
      // Sin perfil (cuenta dada de baja): se cierra la sesión.
      setYo(null);
      await supabase.auth.signOut();
      return;
    }
    setYo(data);
  }, [sesion]);

  useEffect(() => { cargarPerfil(); }, [cargarPerfil]);

  if (!configurado) {
    return <div className="login"><p className="lock er">Falta configurar la conexión con Supabase (variables VITE_SUPABASE_URL y VITE_SUPABASE_PUBLISHABLE_KEY).</p></div>;
  }
  if (sesion === undefined || (sesion && yo === undefined)) return <p className="cargando">Cargando…</p>;
  if (!sesion || !yo) return <Login />;

  const salir = () => supabase.auth.signOut();
  if (yo.perfil === 'propietario') return <Propietario yo={yo} salir={salir} />;
  if (yo.perfil === 'cajero') return <Cajero yo={yo} salir={salir} />;
  return <Salon yo={yo} salir={salir} />;
}
