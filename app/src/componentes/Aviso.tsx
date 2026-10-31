import { createContext, useCallback, useContext, useState, type ReactNode } from 'react';

const Ctx = createContext<(m: string) => void>(() => {});

// Mensaje breve en la parte de abajo, como en los prototipos.
export function ProveedorAvisos({ children }: { children: ReactNode }) {
  const [mensaje, setMensaje] = useState<string | null>(null);
  const mostrar = useCallback((m: string) => {
    setMensaje(m);
    window.clearTimeout((mostrar as unknown as { t?: number }).t);
    (mostrar as unknown as { t?: number }).t = window.setTimeout(() => setMensaje(null), 3500);
  }, []);
  return (
    <Ctx.Provider value={mostrar}>
      {children}
      {mensaje && <div className="toast" role="status">{mensaje}</div>}
    </Ctx.Provider>
  );
}

export const useAviso = () => useContext(Ctx);
