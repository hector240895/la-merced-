// Crea una de las dos cuentas de propietario (solo durante la instalación).
//
//   npm run propietario -- --usuario hector --nombre "Hector Navarro"
//
// Lee SUPABASE_URL y SUPABASE_SECRET_KEY de .env.local. La contraseña se
// escribe en la terminal sin mostrarse; no se guarda en ningún archivo.
import { parseArgs } from 'node:util';
import readline from 'node:readline';
import { clienteServicio, instalarPropietario, variable, correoDe } from './lib/supabase.mjs';

const { values } = parseArgs({ options: { usuario: { type: 'string' }, nombre: { type: 'string' } } });
if (!values.usuario || !values.nombre) {
  console.error('Uso: npm run propietario -- --usuario hector --nombre "Hector Navarro"');
  process.exit(1);
}

function preguntarOculto(texto) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    rl._writeToOutput = (s) => { if (s.includes(texto)) rl.output.write(s); };
    rl.question(texto, (r) => { rl.close(); process.stdout.write('\n'); resolve(r); });
  });
}

const contrasena = await preguntarOculto(`Contraseña para ${values.nombre}: `);
if (contrasena.length < 8) {
  console.error('La contraseña debe tener al menos 8 caracteres.');
  process.exit(1);
}
if ((await preguntarOculto('Repítela: ')) !== contrasena) {
  console.error('Las contraseñas no coinciden.');
  process.exit(1);
}

const admin = clienteServicio(variable('SUPABASE_URL'), variable('SUPABASE_SECRET_KEY'));
try {
  await instalarPropietario(admin, { usuario: values.usuario, nombre: values.nombre, contrasena });
  console.log(`Listo: ${values.nombre} entra con el usuario "${values.usuario.toLowerCase()}" (${correoDe(values.usuario)}).`);
} catch (e) {
  console.error(e.message);
  process.exit(1);
}
