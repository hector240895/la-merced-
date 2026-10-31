// Deja la base LOCAL limpia con Hector y Wendy, para la prueba en navegador
// (app/pruebas/salon.e2e.cjs). Imprime contraseñas aleatorias de prueba en JSON.
import { execSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { clienteServicio, instalarPropietario } from './lib/supabase.mjs';

const estado = Object.fromEntries(
  execSync('npx supabase status -o env', { encoding: 'utf8' }).split('\n').filter((l) => l.includes('='))
    .map((l) => { const i = l.indexOf('='); return [l.slice(0, i), l.slice(i + 1).replace(/^"|"$/g, '')]; }),
);
if (!/^http:\/\/(127\.0\.0\.1|localhost)/.test(estado.API_URL ?? '')) {
  console.error('Solo contra Supabase local.');
  process.exit(1);
}
execSync('npx supabase db reset', { stdio: 'ignore' });
const admin = clienteServicio(estado.API_URL, estado.SERVICE_ROLE_KEY);
const claves = Object.fromEntries(['hector', 'wendy', 'carlos'].map((u) => [u, randomBytes(9).toString('base64url')]));
await instalarPropietario(admin, { usuario: 'hector', nombre: 'Hector Navarro', contrasena: claves.hector });
await instalarPropietario(admin, { usuario: 'wendy', nombre: 'Wendy Rivas', contrasena: claves.wendy });
console.log(JSON.stringify(claves));
