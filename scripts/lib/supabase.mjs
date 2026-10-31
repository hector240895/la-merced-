// Utilidades compartidas por los scripts de instalación y de prueba.
import { createClient } from '@supabase/supabase-js';

export const DOMINIO_USUARIOS = process.env.DOMINIO_USUARIOS ?? 'lamerced.local';

export const correoDe = (usuario) => `${usuario.trim().toLowerCase()}@${DOMINIO_USUARIOS}`;

export function variable(nombre) {
  const valor = process.env[nombre];
  if (!valor) {
    console.error(`Falta la variable ${nombre}. Agrégala en el archivo .env.local (ver .env.example).`);
    process.exit(1);
  }
  return valor;
}

export function clienteServicio(url, llaveSecreta) {
  return createClient(url, llaveSecreta, { auth: { persistSession: false, autoRefreshToken: false } });
}

// Crea el acceso y el perfil de un propietario. La base acepta como máximo dos.
export async function instalarPropietario(admin, { usuario, nombre, contrasena }) {
  const { data, error } = await admin.auth.admin.createUser({
    email: correoDe(usuario),
    password: contrasena,
    email_confirm: true,
    user_metadata: { nombre },
  });
  if (error) throw new Error(`No se pudo crear el acceso de ${usuario}: ${error.message}`);

  const { error: errPerfil } = await admin.rpc('instalar_propietario', {
    p_id: data.user.id, p_usuario: usuario, p_nombre: nombre,
  });
  if (errPerfil) {
    await admin.auth.admin.deleteUser(data.user.id);
    throw new Error(`No se pudo registrar a ${nombre} como propietario: ${errPerfil.message}`);
  }
  return data.user.id;
}
