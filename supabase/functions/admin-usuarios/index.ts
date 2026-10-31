// Sistema La Merced · Función admin-usuarios
//
// Lo que necesita la llave de servicio de Supabase Auth y por eso no puede
// hacerse desde la app: crear el acceso de un mesero o cajero, cambiar una
// contraseña y bloquear o desbloquear el acceso al dar de baja o reactivar.
//
// Quién llama se identifica con su propia sesión. Cada operación pasa además
// por una función de la base de datos que vuelve a revisar que sea
// propietario y que deja el registro en la auditoría.
//
// POST { accion: "crear", usuario, nombre, perfil: "mesero" | "cajero", contrasena }
// POST { accion: "cambiar_contrasena", id, contrasena }
// POST { accion: "dar_de_baja", id, motivo }
// POST { accion: "reactivar", id }

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.75.0";

const DOMINIO = Deno.env.get("DOMINIO_USUARIOS") ?? "lamerced.local";
const MIN_CONTRASENA = 8;
const BLOQUEO_INDEFINIDO = "876000h"; // ~100 años

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function responder(status: number, cuerpo: Record<string, unknown>) {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

// Errores de permiso de la base (42501) se devuelven como 403.
function errorBase(error: { code?: string; message: string }) {
  return responder(error.code === "42501" ? 403 : 400, { error: error.message });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return responder(405, { error: "Método no permitido" });

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return responder(401, { error: "Inicia sesión" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // Cliente con la sesión de quien llama: la base aplica sus permisos.
  const sesion: SupabaseClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: yo, error: errYo } = await sesion.rpc("yo").maybeSingle<{ id: string; perfil: string }>();
  if (errYo || !yo) return responder(401, { error: "Sesión no válida o cuenta dada de baja" });
  if (yo.perfil !== "propietario") {
    return responder(403, { error: "Solo los propietarios administran usuarios" });
  }

  let datos: Record<string, string>;
  try {
    datos = await req.json();
  } catch {
    return responder(400, { error: "Solicitud inválida" });
  }

  switch (datos.accion) {
    case "crear": {
      const usuario = (datos.usuario ?? "").trim().toLowerCase();
      const nombre = (datos.nombre ?? "").trim();
      if (!/^[a-z0-9][a-z0-9._-]{2,29}$/.test(usuario)) {
        return responder(400, { error: "El usuario debe tener de 3 a 30 letras minúsculas, números, punto, guion o guion bajo" });
      }
      if (!nombre) return responder(400, { error: "Escribe el nombre" });
      if (datos.perfil !== "mesero" && datos.perfil !== "cajero") {
        return responder(403, { error: "Solo se agregan cuentas de mesero o cajero" });
      }
      if ((datos.contrasena ?? "").length < MIN_CONTRASENA) {
        return responder(400, { error: `La contraseña debe tener al menos ${MIN_CONTRASENA} caracteres` });
      }

      const { data: creado, error: errCrear } = await admin.auth.admin.createUser({
        email: `${usuario}@${DOMINIO}`,
        password: datos.contrasena,
        email_confirm: true,
        user_metadata: { nombre },
      });
      if (errCrear || !creado.user) {
        const existe = /already|registered|exists/i.test(errCrear?.message ?? "");
        return responder(existe ? 409 : 400, {
          error: existe ? `El usuario ${usuario} ya existe` : (errCrear?.message ?? "No se pudo crear el acceso"),
        });
      }

      const { data: fila, error: errRegistro } = await sesion.rpc("registrar_usuario", {
        p_id: creado.user.id, p_usuario: usuario, p_nombre: nombre, p_perfil: datos.perfil,
      });
      if (errRegistro) {
        // El acceso recién creado no llegó a tener perfil ni historial: se retira.
        await admin.auth.admin.deleteUser(creado.user.id);
        return errorBase(errRegistro);
      }
      return responder(201, { usuario: fila });
    }

    case "cambiar_contrasena": {
      if ((datos.contrasena ?? "").length < MIN_CONTRASENA) {
        return responder(400, { error: `La contraseña debe tener al menos ${MIN_CONTRASENA} caracteres` });
      }
      const { data: destino } = await sesion.from("usuarios").select("id, perfil").eq("id", datos.id).maybeSingle();
      if (!destino) return responder(404, { error: "El usuario no existe" });
      if (destino.perfil === "propietario" && destino.id !== yo.id) {
        return responder(403, { error: "Cada propietario cambia solo su propia contraseña" });
      }
      const { error: errCambio } = await admin.auth.admin.updateUserById(datos.id, { password: datos.contrasena });
      if (errCambio) return responder(400, { error: errCambio.message });
      const { error: errAud } = await sesion.rpc("registrar_cambio_contrasena", { p_id: datos.id });
      if (errAud) return errorBase(errAud);
      return responder(200, { ok: true });
    }

    case "dar_de_baja": {
      // Primero la base: desde este momento la cuenta ya no ve ni escribe nada.
      const { data: fila, error } = await sesion.rpc("dar_de_baja_usuario", { p_id: datos.id, p_motivo: datos.motivo ?? "" });
      if (error) return errorBase(error);
      // Después se bloquea el inicio de sesión y la renovación de su sesión.
      const { error: errBloqueo } = await admin.auth.admin.updateUserById(datos.id, { ban_duration: BLOQUEO_INDEFINIDO });
      if (errBloqueo) {
        return responder(200, {
          usuario: fila,
          aviso: "La cuenta quedó dada de baja y sin acceso a datos, pero no se pudo bloquear el inicio de sesión. Intenta de nuevo.",
        });
      }
      return responder(200, { usuario: fila });
    }

    case "reactivar": {
      const { data: fila, error } = await sesion.rpc("reactivar_usuario", { p_id: datos.id });
      if (error) return errorBase(error);
      const { error: errDesbloqueo } = await admin.auth.admin.updateUserById(datos.id, { ban_duration: "none" });
      if (errDesbloqueo) return responder(400, { error: errDesbloqueo.message });
      return responder(200, { usuario: fila });
    }

    default:
      return responder(400, { error: "Acción desconocida" });
  }
});
