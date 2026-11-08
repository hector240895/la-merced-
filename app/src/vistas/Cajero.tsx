import type { Yo } from '../lib/tipos';
import Comandas from './Comandas';

// La pantalla de caja (cobros, pedidos para llevar, corte) llega en la Etapa 5.
// Por ahora: la cola de comandas de cocina.
export default function Cajero({ yo, salir }: { yo: Yo; salir: () => void }) {
  return (
    <>
      <header className="top">
        <h1>La Merced</h1>
        <span className="quien"><small>{yo.nombre} · Cajero</small><button className="salir" onClick={salir}>Salir</button></span>
      </header>
      <main className="ancho">
        <div className="box">
          <h2>Caja</h2>
          <p className="note">La pantalla de cobros, pedidos para llevar y corte de caja se habilita en la Etapa 5.</p>
        </div>
        <Comandas />
      </main>
    </>
  );
}
