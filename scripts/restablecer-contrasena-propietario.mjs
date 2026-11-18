// Para cuando un propietario olvidó su contraseña (en la app cada propietario
// solo puede cambiar la suya estando dentro).
//
//   npm run contrasena-propietario -- --usuario hector
//
// Lee SUPABASE_URL y SUPABASE_SECRET_KEY de .env.local (en tu computadora). La
// contraseña nueva se escribe en la terminal sin mostrarse y no se guarda.
import { parseArgs } from 'node:util';
import readline from 'node:readline';
import { clienteServicio, variable, correoDe } from './lib/supabase.mjs';

const { values } = parseArgs({ options: { usuario: { type: 'string' } } });
if (!values.usuario) {
  console.error('Uso: npm run contrasena-propietario -- --usuario hector');
  process.exit(1);
}

// Una sola lectura de la terminal para las dos preguntas; lo que se escribe no se muestra.
const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: process.stdin.isTTY });
let pregunta = '';
rl._writeToOutput = (s) => { if (s.includes(pregunta)) rl.output.write(s); };
const lineas = rl[Symbol.asyncIterator]();
async function preguntarOculto(texto) {
  pregunta = texto;
  process.stdout.write(texto);
  const { value } = await lineas.next();
  process.stdout.write('\n');
  return value ?? '';
}

const admin = clienteServicio(variable('SUPABASE_URL'), variable('SUPABASE_SECRET_KEY'));
const usuario = values.usuario.trim().toLowerCase();
const { data: perfil, error } = await admin.from('usuarios').select('id, nombre, perfil, activo').eq('usuario', usuario).maybeSingle();
if (error || !perfil) {
  console.error(`No existe el usuario "${usuario}".`);
  process.exit(1);
}
if (perfil.perfil !== 'propietario') {
  console.error('Este script es solo para propietarios. A meseros y cajeros les cambia la contraseña un propietario en la pestaña Usuarios.');
  process.exit(1);
}

const contrasena = await preguntarOculto(`Contraseña nueva para ${perfil.nombre}: `);
if (contrasena.length < 8) {
  console.error('La contraseña debe tener al menos 8 caracteres.');
  process.exit(1);
}
if ((await preguntarOculto('Repítela: ')) !== contrasena) {
  console.error('Las contraseñas no coinciden.');
  process.exit(1);
}

rl.close();
const { error: err } = await admin.auth.admin.updateUserById(perfil.id, { password: contrasena });
if (err) {
  console.error(`No se pudo cambiar: ${err.message}`);
  process.exit(1);
}
console.log(`Listo: ${perfil.nombre} ya entra con el usuario "${usuario}" (${correoDe(usuario)}) y su contraseña nueva.`);
