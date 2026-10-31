import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const llave = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined;
const dominio = (import.meta.env.VITE_DOMINIO_USUARIOS as string | undefined) ?? 'lamerced.local';

export const configurado = Boolean(url && llave);

export const supabase = createClient(url ?? 'http://localhost', llave ?? 'sin-llave', {
  auth: { persistSession: true, autoRefreshToken: true, storageKey: 'la-merced-sesion' },
});

// Cada persona entra con su usuario; por dentro Supabase usa un correo interno.
export const correoDe = (usuario: string) => `${usuario.trim().toLowerCase()}@${dominio}`;

// Mensaje entendible a partir de un error de la base o de la red.
export function mensajeDe(error: unknown): string {
  const m = (error as { message?: string })?.message ?? String(error);
  if (/Failed to fetch|NetworkError|network/i.test(m)) return 'Sin conexión. Revisa el internet e intenta de nuevo.';
  if (/Invalid login credentials/i.test(m)) return 'Usuario o contraseña incorrectos.';
  if (/banned/i.test(m)) return 'Esta cuenta está dada de baja.';
  if (/JWT|token/i.test(m)) return 'Tu sesión expiró. Vuelve a iniciar sesión.';
  return m;
}

// Llama una función del servidor y lanza su mensaje si falla.
export async function llamar<T = unknown>(funcion: string, parametros: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(funcion, parametros);
  if (error) throw new Error(mensajeDe(error));
  return data as T;
}

// Función admin-usuarios (crear cuenta, contraseña, baja, reactivar).
export async function adminUsuarios(cuerpo: Record<string, unknown>) {
  const { data, error } = await supabase.functions.invoke('admin-usuarios', { body: cuerpo });
  if (error) {
    const respuesta = (error as { context?: Response }).context;
    const detalle = respuesta ? await respuesta.json().catch(() => null) : null;
    throw new Error(detalle?.error ?? mensajeDe(error));
  }
  return data as { usuario?: unknown; aviso?: string };
}
