// El corazón del servicio: toma los trabajos pendientes en orden de llegada,
// los imprime en la impresora que corresponde e informa el resultado.
//
//   * Al arrancar y al reconectarse imprime todo lo pendiente.
//   * Escucha en tiempo real los trabajos nuevos y, por si acaso, revisa cada 10 s.
//   * Recuerda lo ya impreso: si se cae la conexión justo después de imprimir,
//     al volver solo informa "impreso", sin repetir el papel.
//   * Avisa cada 15 s que sigue conectado y cómo están las impresoras.
import { hostname } from 'node:os';
import { createClient } from '@supabase/supabase-js';
import { formatear } from './formatos.mjs';
import { guardarImpresos, leerImpresos } from './config.mjs';

export const VERSION = '1.1.3';

export async function iniciarServicio({ config, contrasena, controlador, registrar = console.log, intervalo = 10_000, intervaloLatido = 15_000 }) {
  const supabase = createClient(config.supabaseUrl, config.llavePublica, {
    auth: { persistSession: false, autoRefreshToken: true },
  });
  const { error: errLogin } = await supabase.auth.signInWithPassword({
    email: `${config.usuario}@${config.dominio}`, password: contrasena,
  });
  if (errLogin) throw new Error(`No se pudo iniciar sesión como "${config.usuario}": ${errLogin.message}`);
  const { data: yo } = await supabase.rpc('yo').maybeSingle();
  if (!yo || !['cajero', 'propietario'].includes(yo.perfil)) {
    throw new Error(`La cuenta "${config.usuario}" debe tener perfil de cajero y estar activa`);
  }
  registrar(`Conectado como ${yo.nombre} (${yo.perfil}). Cocina: "${config.impresoras.cocina.nombre}". Caja: "${config.impresoras.caja.nombre}".`);

  const impresos = await leerImpresos();
  const porInformar = new Map();   // trabajos impresos cuyo aviso no llegó (sin conexión)
  let trabajando = false;
  let otraVez = false;
  let pendientes = 0;
  let detenido = false;

  async function informar(id, impreso, error) {
    const { error: e } = await supabase.rpc('reportar_impresion', { p_trabajo_id: id, p_impreso: impreso, p_error: error ?? null });
    if (e) throw new Error(e.message);
  }

  async function procesar() {
    if (detenido) return;
    if (trabajando) { otraVez = true; return; }
    trabajando = true;
    try {
      do {
        otraVez = false;
        // Avisos pendientes de una desconexión anterior.
        for (const [id, r] of porInformar) {
          try { await informar(id, r.impreso, r.error); porInformar.delete(id); } catch { break; }
        }
        const { data, error } = await supabase.from('trabajos_impresion')
          .select('id, documento, impresora, contenido, creado_en, reimpresion_de')
          .eq('estado', 'pendiente').order('creado_en').limit(50);
        if (error) throw new Error(error.message);
        pendientes = data.length;
        for (const t of data) {
          if (detenido) return;
          if (porInformar.has(t.id)) continue;
          const imp = config.impresoras[t.impresora];
          let resultado;
          if (impresos.has(t.id)) {
            resultado = { impreso: true };   // ya salió en papel: solo falta avisar
            registrar(`${t.documento} ${t.id.slice(0, 8)} ya estaba impreso; solo se confirma.`);
          } else {
            try {
              if (!imp?.nombre) throw new Error(`No está configurada la impresora de ${t.impresora}`);
              await controlador.imprimir(imp.nombre, formatear(t, config), `${t.documento}-${t.id.slice(0, 8)}`);
              impresos.add(t.id);
              await guardarImpresos(impresos);
              resultado = { impreso: true };
              registrar(`Impreso: ${t.documento} ${describir(t)} en "${imp.nombre}".`);
            } catch (e) {
              resultado = { impreso: false, error: String(e.message).slice(0, 300) };
              registrar(`ERROR al imprimir ${t.documento} ${describir(t)}: ${resultado.error}`);
            }
          }
          try { await informar(t.id, resultado.impreso, resultado.error); }
          catch (e) { porInformar.set(t.id, resultado); registrar(`Sin conexión para confirmar ${t.id.slice(0, 8)}; se confirmará al volver. (${e.message})`); }
          pendientes -= 1;
        }
        if (data.length === 50) otraVez = true;
      } while (otraVez && !detenido);
    } catch (e) {
      registrar(`No se pudo revisar la cola: ${e.message}`);
    } finally {
      trabajando = false;
    }
  }

  async function latido() {
    if (detenido) return;
    const estado = {};
    for (const [k, imp] of Object.entries(config.impresoras)) {
      estado[k] = { nombre: imp.nombre, estado: imp.nombre ? await controlador.estado(imp.nombre).catch(() => 'desconocido') : 'sin configurar' };
    }
    const { error } = await supabase.rpc('latido_impresion', {
      p_equipo: hostname(), p_version: VERSION, p_impresoras: estado, p_pendientes: pendientes + porInformar.size,
    });
    if (error) registrar(`No se pudo avisar el estado: ${error.message}`);
  }

  const canal = supabase.channel('servicio-impresion')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'trabajos_impresion' }, () => procesar())
    .subscribe((estado) => { if (estado === 'SUBSCRIBED') procesar(); });
  const relojCola = setInterval(procesar, intervalo);
  const relojLatido = setInterval(latido, intervaloLatido);
  await latido();
  await procesar();

  return {
    procesar,
    async detener() {
      detenido = true;
      clearInterval(relojCola);
      clearInterval(relojLatido);
      await supabase.removeChannel(canal);
      await supabase.auth.signOut().catch(() => {});
      while (trabajando) await new Promise((r) => setTimeout(r, 50));
    },
  };
}

function describir(t) {
  const c = t.contenido ?? {};
  if (t.documento === 'comanda') return `${c.destino ?? ''} #${c.numero ?? ''}`;
  if (t.documento === 'ticket') return `folio ${c.folio ?? ''}`;
  if (t.documento === 'precuenta') return `${c.destino ?? ''} folio ${c.folio ?? ''}`;
  return '';
}
