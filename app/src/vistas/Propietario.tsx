import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useEnVivo } from '../lib/vivo';
import type { Yo } from '../lib/tipos';
import Salon from './Salon';
import MesasAdmin from './propietario/MesasAdmin';
import Usuarios from './propietario/Usuarios';
import Autorizaciones from './propietario/Autorizaciones';

type Pestana = 'salon' | 'mesas' | 'usuarios' | 'autorizaciones';
const CLAVE_PESTANA = 'la-merced-pestana';

export default function Propietario({ yo, salir }: { yo: Yo; salir: () => void }) {
  const [pestana, setPestana] = useState<Pestana>(() => {
    try { return (localStorage.getItem(CLAVE_PESTANA) as Pestana) || 'salon'; } catch { return 'salon'; }
  });
  const [pendientes, setPendientes] = useState(0);

  useEffect(() => { try { localStorage.setItem(CLAVE_PESTANA, pestana); } catch { /* sin almacenamiento */ } }, [pestana]);

  // Solicitudes del otro propietario por resolver + avisos sin leer.
  const contar = useCallback(async () => {
    const [a, v] = await Promise.all([
      supabase.from('autorizaciones').select('id', { count: 'exact', head: true }).eq('estado', 'pendiente').neq('solicitada_por', yo.id),
      supabase.from('avisos').select('id', { count: 'exact', head: true }).is('leido_en', null),
    ]);
    setPendientes((a.count ?? 0) + (v.count ?? 0));
  }, [yo.id]);
  useEffect(() => { contar(); }, [contar]);
  useEnVivo(['autorizaciones', 'avisos'], contar);

  const pestanas: [Pestana, string][] = [
    ['salon', 'Salón'], ['mesas', 'Mesas'], ['usuarios', 'Usuarios'], ['autorizaciones', 'Autorizaciones y avisos'],
  ];

  return (
    <>
      <header className="top">
        <h1>La Merced</h1>
        <nav className="nav">
          {pestanas.map(([k, t]) => (
            <button key={k} className={pestana === k ? 'on' : ''} onClick={() => setPestana(k)}>
              {t}{k === 'autorizaciones' && pendientes > 0 && <span className="num">{pendientes}</span>}
            </button>
          ))}
        </nav>
        <span className="quien"><small>{yo.nombre} · Propietario</small><button className="salir" onClick={salir}>Salir</button></span>
      </header>
      {pestana === 'salon' && <Salon yo={yo} dentroDePanel />}
      {pestana === 'mesas' && <main className="ancho"><MesasAdmin /></main>}
      {pestana === 'usuarios' && <main className="ancho"><Usuarios yo={yo} /></main>}
      {pestana === 'autorizaciones' && <main className="ancho"><Autorizaciones yo={yo} alCambiar={contar} /></main>}
    </>
  );
}
