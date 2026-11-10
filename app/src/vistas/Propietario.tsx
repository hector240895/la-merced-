import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useEnVivo } from '../lib/vivo';
import type { Yo } from '../lib/tipos';
import Salon from './Salon';
import MesasAdmin from './propietario/MesasAdmin';
import Usuarios from './propietario/Usuarios';
import Autorizaciones from './propietario/Autorizaciones';
import Comandas from './Comandas';
import Caja from './Caja';
import CortesVentas from './propietario/CortesVentas';
import Catalogo from './propietario/Catalogo';
import Inventario, { usePorSurtir } from './Inventario';
import Gastos from './Gastos';
import Reportes from './propietario/Reportes';

type Pestana = 'salon' | 'caja' | 'cortes' | 'reportes' | 'gastos' | 'comandas' | 'catalogo' | 'inventario' | 'mesas' | 'usuarios' | 'autorizaciones';
const CLAVE_PESTANA = 'la-merced-pestana';

export default function Propietario({ yo, salir }: { yo: Yo; salir: () => void }) {
  const [pestana, setPestana] = useState<Pestana>(() => {
    try { return (localStorage.getItem(CLAVE_PESTANA) as Pestana) || 'salon'; } catch { return 'salon'; }
  });
  const [pendientes, setPendientes] = useState(0);
  const [fallidas, setFallidas] = useState(0);
  const porSurtir = usePorSurtir(true);

  useEffect(() => { try { localStorage.setItem(CLAVE_PESTANA, pestana); } catch { /* sin almacenamiento */ } }, [pestana]);

  // Solicitudes del otro propietario por resolver + avisos sin leer.
  const contar = useCallback(async () => {
    const [a, v] = await Promise.all([
      supabase.from('autorizaciones').select('id', { count: 'exact', head: true }).eq('estado', 'pendiente').neq('solicitada_por', yo.id),
      supabase.from('avisos').select('id', { count: 'exact', head: true }).is('leido_en', null),
    ]);
    setPendientes((a.count ?? 0) + (v.count ?? 0));
  }, [yo.id]);

  // Comandas que no se imprimieron: aviso en la pestaña Comandas.
  const contarFallidas = useCallback(async () => {
    const { count } = await supabase.from('trabajos_impresion').select('id', { count: 'exact', head: true }).eq('estado', 'error');
    setFallidas(count ?? 0);
  }, []);
  useEffect(() => { contarFallidas(); }, [contarFallidas]);
  useEnVivo(['trabajos_impresion'], contarFallidas);
  useEffect(() => { contar(); }, [contar]);
  useEnVivo(['autorizaciones', 'avisos'], contar);

  const pestanas: [Pestana, string][] = [
    ['salon', 'Salón'], ['caja', 'Caja'], ['cortes', 'Cortes y ventas'], ['reportes', 'Reportes'], ['gastos', 'Gastos'], ['comandas', 'Comandas'], ['catalogo', 'Catálogo'], ['inventario', 'Inventario'], ['mesas', 'Mesas'], ['usuarios', 'Usuarios'], ['autorizaciones', 'Autorizaciones y avisos'],
  ];

  return (
    <>
      <header className="top">
        <h1>La Merced</h1>
        <nav className="nav">
          {pestanas.map(([k, t]) => (
            <button key={k} className={pestana === k ? 'on' : ''} onClick={() => setPestana(k)}>
              {t}{k === 'autorizaciones' && pendientes > 0 && <span className="num">{pendientes}</span>}
              {k === 'comandas' && fallidas > 0 && <span className="num">{fallidas}</span>}
              {k === 'inventario' && porSurtir > 0 && <span className="num">{porSurtir}</span>}
            </button>
          ))}
        </nav>
        <span className="quien"><small>{yo.nombre} · Propietario</small><button className="salir" onClick={salir}>Salir</button></span>
      </header>
      {pestana === 'salon' && <Salon yo={yo} dentroDePanel />}
      {pestana === 'caja' && <Caja yo={yo} />}
      {pestana === 'cortes' && <main className="ancho"><CortesVentas /></main>}
      {pestana === 'reportes' && <main className="ancho"><Reportes /></main>}
      {pestana === 'gastos' && <main className="ancho"><Gastos esPropietario yoId={yo.id} /></main>}
      {pestana === 'comandas' && <main className="ancho"><Comandas /></main>}
      {pestana === 'catalogo' && <main className="ancho"><Catalogo /></main>}
      {pestana === 'inventario' && <main className="ancho"><Inventario esPropietario /></main>}
      {pestana === 'mesas' && <main className="ancho"><MesasAdmin /></main>}
      {pestana === 'usuarios' && <main className="ancho"><Usuarios yo={yo} /></main>}
      {pestana === 'autorizaciones' && <main className="ancho"><Autorizaciones yo={yo} alCambiar={contar} /></main>}
    </>
  );
}
