// Espera a que el servicio de tiempo real local entregue eventos (tras un db reset).
import { createClient } from '@supabase/supabase-js';
const c = createClient('http://127.0.0.1:54321', process.env.SERVICE_ROLE_KEY, { auth: { persistSession: false } });
for (let i = 0; i < 30; i++) {
  const ok = await new Promise((resolve) => {
    const ch = c.channel('espera-' + i);
    ch.on('system', {}, (m) => { if (m.extension === 'postgres_changes' && m.status === 'ok') resolve(true); });
    ch.on('postgres_changes', { event: '*', schema: 'public', table: 'mesas' }, () => {});
    ch.subscribe();
    setTimeout(() => resolve(false), 3000);
  });
  if (ok) { console.log('tiempo real listo'); process.exit(0); }
}
console.log('tiempo real no respondió'); process.exit(1);
