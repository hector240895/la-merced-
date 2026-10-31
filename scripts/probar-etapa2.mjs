// Prueba de punta a punta de la Etapa 2 contra el Supabase LOCAL
// (supabase start). Usa la API real: inicio de sesión por usuario, la función
// admin-usuarios y los permisos de la base.
//
//   npm run probar:api
//
// Se niega a correr contra un proyecto en la nube: crea y da de baja cuentas.
import { execSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import { clienteServicio, correoDe, instalarPropietario } from './lib/supabase.mjs';

const estado = Object.fromEntries(
  execSync('npx supabase status -o env', { encoding: 'utf8' })
    .split('\n').filter((l) => l.includes('=')).map((l) => {
      const i = l.indexOf('=');
      return [l.slice(0, i), l.slice(i + 1).replace(/^"|"$/g, '')];
    }),
);
const URL = estado.API_URL;
if (!/^http:\/\/(127\.0\.0\.1|localhost)/.test(URL ?? '')) {
  console.error('Esta prueba solo corre contra Supabase local.');
  process.exit(1);
}
const PUBLICA = estado.ANON_KEY;
const admin = clienteServicio(URL, estado.SERVICE_ROLE_KEY);

let fallas = 0;
let n = 0;
function comprobar(condicion, descripcion, detalle) {
  n += 1;
  if (condicion) console.log(`ok ${n} - ${descripcion}`);
  else { fallas += 1; console.log(`not ok ${n} - ${descripcion}${detalle ? ` (${detalle})` : ''}`); }
}

const contrasena = () => randomBytes(9).toString('base64url');
const nuevoCliente = () => createClient(URL, PUBLICA, { auth: { persistSession: false, autoRefreshToken: false } });

async function entrar(usuario, clave) {
  const c = nuevoCliente();
  const { error } = await c.auth.signInWithPassword({ email: correoDe(usuario), password: clave });
  return { c, error };
}

async function adminUsuarios(cliente, cuerpo) {
  const { data: { session } } = await cliente.auth.getSession();
  const r = await fetch(`${process.env.FUNCIONES_URL ?? `${URL}/functions/v1`}/admin-usuarios`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${session.access_token}`, apikey: PUBLICA, 'Content-Type': 'application/json' },
    body: JSON.stringify(cuerpo),
  });
  return { status: r.status, cuerpo: await r.json().catch(() => ({})) };
}

// Base limpia para la prueba.
execSync('npx supabase db reset', { stdio: 'ignore' });

// --- Instalación: los dos propietarios
const claves = { hector: contrasena(), wendy: contrasena(), carlos: contrasena(), laura: contrasena() };
await instalarPropietario(admin, { usuario: 'hector', nombre: 'Hector Navarro', contrasena: claves.hector });
await instalarPropietario(admin, { usuario: 'wendy', nombre: 'Wendy Rivas', contrasena: claves.wendy });
let tercero;
try { await instalarPropietario(admin, { usuario: 'tercero', nombre: 'Tercero', contrasena: contrasena() }); }
catch (e) { tercero = e; }
comprobar(tercero, 'La instalación no admite un tercer propietario');
const { data: sinRastro } = await admin.auth.admin.listUsers();
comprobar(!sinRastro.users.some((u) => u.email === correoDe('tercero')), 'El acceso rechazado no queda creado');

// --- Nadie se registra solo
const { error: errRegistro } = await nuevoCliente().auth.signUp({ email: correoDe('colado'), password: contrasena() });
comprobar(errRegistro, 'El registro público está desactivado');

// --- Inicio de sesión por usuario
const { c: hector, error: errH } = await entrar('hector', claves.hector);
comprobar(!errH, 'Hector inicia sesión con su usuario y contraseña', errH?.message);
const { data: yoH } = await hector.rpc('yo').single();
comprobar(yoH?.perfil === 'propietario' && yoH?.nombre === 'Hector Navarro', 'Hector es propietario');
const { error: errMala } = await entrar('hector', 'contraseña-equivocada');
comprobar(errMala, 'Con contraseña equivocada no entra');

// --- Hector crea al mesero y a la cajera
let r = await adminUsuarios(hector, { accion: 'crear', usuario: 'carlos', nombre: 'Carlos', perfil: 'mesero', contrasena: claves.carlos });
comprobar(r.status === 201, 'El propietario crea la cuenta del mesero', JSON.stringify(r.cuerpo));
const idCarlos = r.cuerpo.usuario?.id;
r = await adminUsuarios(hector, { accion: 'crear', usuario: 'laura', nombre: 'Laura', perfil: 'cajero', contrasena: claves.laura });
comprobar(r.status === 201, 'El propietario crea la cuenta de la cajera', JSON.stringify(r.cuerpo));
const idLaura = r.cuerpo.usuario?.id;
r = await adminUsuarios(hector, { accion: 'crear', usuario: 'carlos', nombre: 'Otro', perfil: 'mesero', contrasena: contrasena() });
comprobar(r.status === 409, 'No se repite un nombre de usuario');
r = await adminUsuarios(hector, { accion: 'crear', usuario: 'jefe', nombre: 'Jefe', perfil: 'propietario', contrasena: contrasena() });
comprobar(r.status === 403, 'Desde el panel no se crean propietarios');

// --- El mesero
const { c: carlos, error: errC } = await entrar('carlos', claves.carlos);
comprobar(!errC, 'El mesero inicia sesión', errC?.message);
const { data: gastosMesero } = await carlos.from('gastos').select('*');
comprobar(Array.isArray(gastosMesero) && gastosMesero.length === 0, 'El mesero no recibe gastos');
const { data: mesasMesero } = await carlos.from('mesas').select('nombre');
comprobar(mesasMesero?.length === 7, 'El mesero ve las siete mesas');
const { error: errInsert } = await carlos.from('mesas').insert({ nombre: 'Mesa pirata' });
comprobar(errInsert, 'El mesero no puede escribir directo en las tablas');
r = await adminUsuarios(carlos, { accion: 'crear', usuario: 'amigo', nombre: 'Amigo', perfil: 'mesero', contrasena: contrasena() });
comprobar(r.status === 403, 'El mesero no puede crear cuentas');

// --- La cajera
const { c: laura } = await entrar('laura', claves.laura);
r = await adminUsuarios(laura, { accion: 'dar_de_baja', id: idCarlos, motivo: 'x' });
comprobar(r.status === 403, 'La cajera no puede dar de baja cuentas');
const { data: audLaura } = await laura.from('auditoria').select('*');
comprobar(audLaura?.length === 0, 'La cajera no ve la auditoría');

// --- Contraseñas
const nuevaLaura = contrasena();
r = await adminUsuarios(hector, { accion: 'cambiar_contrasena', id: idLaura, contrasena: nuevaLaura });
comprobar(r.status === 200, 'El propietario cambia la contraseña de la cajera', JSON.stringify(r.cuerpo));
comprobar(!(await entrar('laura', nuevaLaura)).error, 'La cajera entra con la contraseña nueva');
const { data: wendyFila } = await hector.from('usuarios').select('id').eq('usuario', 'wendy').single();
r = await adminUsuarios(hector, { accion: 'cambiar_contrasena', id: wendyFila.id, contrasena: contrasena() });
comprobar(r.status === 403, 'Un propietario no cambia la contraseña del otro');
comprobar(!(await entrar('wendy', claves.wendy)).error, 'La contraseña de Wendy sigue igual');

// --- Baja: corta el acceso de inmediato y conserva la cuenta
r = await adminUsuarios(hector, { accion: 'dar_de_baja', id: idCarlos, motivo: 'Dejó el trabajo' });
comprobar(r.status === 200 && !r.cuerpo.aviso, 'El propietario da de baja al mesero', JSON.stringify(r.cuerpo));
const { data: mesasTrasBaja } = await carlos.from('mesas').select('nombre');
comprobar(mesasTrasBaja?.length === 0, 'Con su sesión aún abierta, el mesero dado de baja ya no ve nada');
const { error: errLoginBaja } = await entrar('carlos', claves.carlos);
comprobar(errLoginBaja, 'El mesero dado de baja ya no puede iniciar sesión');
const { data: carlosFila } = await hector.from('usuarios').select('activo, baja_motivo').eq('id', idCarlos).single();
comprobar(carlosFila?.activo === false && carlosFila?.baja_motivo === 'Dejó el trabajo', 'La cuenta se conserva, marcada de baja con motivo');
r = await adminUsuarios(hector, { accion: 'dar_de_baja', id: wendyFila.id, motivo: 'x' });
comprobar(r.status === 403, 'Un propietario no da de baja al otro');

r = await adminUsuarios(hector, { accion: 'reactivar', id: idCarlos });
comprobar(r.status === 200, 'El propietario reactiva al mesero');
comprobar(!(await entrar('carlos', claves.carlos)).error, 'El mesero reactivado vuelve a entrar');

// --- Renombrar (directo con la función de la base)
const { error: errRen } = await hector.rpc('renombrar_usuario', { p_id: idCarlos, p_nombre: 'Carlos Pérez' });
comprobar(!errRen, 'El propietario renombra una cuenta', errRen?.message);
const { error: errRenM } = await laura.rpc('renombrar_usuario', { p_id: idCarlos, p_nombre: 'Hackeado' });
comprobar(errRenM, 'La cajera no puede renombrar cuentas');

// --- Avisos y auditoría
const { c: wendy } = await entrar('wendy', claves.wendy);
const { data: avisos } = await wendy.from('avisos').select('id, auditoria(accion, motivo, creado_en)').order('id');
const acciones = (avisos ?? []).map((a) => a.auditoria?.accion);
comprobar(acciones.some((a) => a?.startsWith('Dio de baja la cuenta de Carlos')), 'Wendy recibe el aviso de la baja que hizo Hector', acciones.join(' | '));
comprobar(acciones.some((a) => a?.startsWith('Cambió la contraseña de Laura')), 'Wendy recibe el aviso del cambio de contraseña');
const { data: leidos } = await wendy.rpc('marcar_avisos_leidos');
comprobar(leidos === avisos.length, 'Wendy marca sus avisos como leídos');
const { data: avisosH } = await hector.from('avisos').select('id');
comprobar(avisosH?.length === 0, 'Hector no recibe avisos de sus propias acciones');
const { error: errBorrarAud } = await hector.from('auditoria').delete().gt('id', 0);
const { count: totalAud } = await hector.from('auditoria').select('*', { count: 'exact', head: true });
comprobar(errBorrarAud && totalAud > 0, 'Ni un propietario puede borrar la auditoría');

console.log(`\n${n - fallas} de ${n} comprobaciones correctas`);
process.exit(fallas ? 1 : 0);
