import { useState } from 'react';
import type { Yo } from '../lib/tipos';
import Caja from './Caja';
import Comandas from './Comandas';
import Inventario, { usePorSurtir } from './Inventario';

// Pantalla de caja: cobrar, caja del día (movimientos y corte), comandas e
// inventario (compras y entradas).
export default function Cajero({ yo, salir }: { yo: Yo; salir: () => void }) {
  const [pestana, setPestana] = useState<'caja' | 'comandas' | 'inventario'>('caja');
  const porSurtir = usePorSurtir(true);
  return (
    <>
      <header className="top">
        <h1>La Merced</h1>
        <nav className="nav">
          <button className={pestana === 'caja' ? 'on' : ''} onClick={() => setPestana('caja')}>Caja</button>
          <button className={pestana === 'comandas' ? 'on' : ''} onClick={() => setPestana('comandas')}>Comandas</button>
          <button className={pestana === 'inventario' ? 'on' : ''} onClick={() => setPestana('inventario')}>
            Inventario{porSurtir > 0 && <span className="num">{porSurtir}</span>}
          </button>
        </nav>
        <span className="quien"><small>{yo.nombre} · Cajero</small><button className="salir" onClick={salir}>Salir</button></span>
      </header>
      {pestana === 'caja' && <Caja yo={yo} />}
      {pestana === 'comandas' && <main className="ancho"><Comandas /></main>}
      {pestana === 'inventario' && <main className="ancho"><Inventario esPropietario={false} /></main>}
    </>
  );
}
