// Configuración del servicio (en la computadora de caja) y registro local de
// lo ya impreso, que evita imprimir dos veces después de un corte.
import { readFile, writeFile, mkdir, appendFile, stat, rename } from 'node:fs/promises';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { powershell } from './impresoras.mjs';

export const CARPETA = process.env.LA_MERCED_CARPETA
  ?? join(process.env.APPDATA ?? join(homedir(), '.config'), 'LaMercedImpresion');
const ARCHIVO_CONFIG = join(CARPETA, 'config.json');
const ARCHIVO_IMPRESOS = join(CARPETA, 'impresos.json');
const ARCHIVO_REGISTRO = join(CARPETA, 'registro.log');

export const PREDETERMINADO = {
  supabaseUrl: 'https://yayksvcwxrkomqbeafla.supabase.co',
  // Llave pública (la misma que usa la app web); no es secreta.
  llavePublica: 'sb_publishable_u1ZGhCs4b23jn9jdabbk1w_R4Lr7u78',
  dominio: 'lamerced.local',
  usuario: 'impresora',
  controlador: 'windows',
  impresoras: {
    cocina: { nombre: '', ancho: 48, tabla: 'cp850' },
    caja: { nombre: '', ancho: 32, tabla: 'cp850' },
  },
};

export async function leerConfig() {
  const datos = JSON.parse(await readFile(ARCHIVO_CONFIG, 'utf8'));
  return { ...PREDETERMINADO, ...datos, impresoras: { ...PREDETERMINADO.impresoras, ...datos.impresoras } };
}

export async function guardarConfig(config) {
  await mkdir(CARPETA, { recursive: true });
  await writeFile(ARCHIVO_CONFIG, JSON.stringify(config, null, 2));
  return ARCHIVO_CONFIG;
}

// La contraseña se guarda cifrada con la protección de Windows (DPAPI): solo
// el mismo usuario de Windows, en esta computadora, puede descifrarla.
export async function proteger(texto) {
  const r = await powershell(['-Command',
    'Add-Type -AssemblyName System.Security; $t = [Console]::In.ReadToEnd(); ' +
    "[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($t), $null, 'CurrentUser'))"], texto);
  if (r.codigo !== 0) throw new Error('No se pudo proteger la contraseña: ' + r.error);
  return r.salida;
}

export async function desproteger(cifrado) {
  const r = await powershell(['-Command',
    'Add-Type -AssemblyName System.Security; $t = [Console]::In.ReadToEnd().Trim(); ' +
    "[Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($t), $null, 'CurrentUser'))"], cifrado);
  if (r.codigo !== 0) throw new Error('No se pudo leer la contraseña guardada. Vuelve a correr la configuración.');
  return r.salida;
}

export async function contrasena(config) {
  if (process.env.LA_MERCED_CONTRASENA) return process.env.LA_MERCED_CONTRASENA;   // solo para pruebas
  return desproteger(config.contrasenaProtegida);
}

// Identificadores ya impresos (los últimos 5,000).
export async function leerImpresos() {
  try { return new Set(JSON.parse(await readFile(ARCHIVO_IMPRESOS, 'utf8'))); } catch { return new Set(); }
}
export async function guardarImpresos(impresos) {
  await mkdir(CARPETA, { recursive: true });
  const lista = [...impresos].slice(-5000);
  await writeFile(ARCHIVO_IMPRESOS + '.tmp', JSON.stringify(lista));
  await rename(ARCHIVO_IMPRESOS + '.tmp', ARCHIVO_IMPRESOS);
}

export async function registrar(mensaje) {
  const linea = `${new Date().toLocaleString('es-MX', { timeZone: 'America/Mexico_City' })}  ${mensaje}\n`;
  process.stdout.write(linea);
  try {
    await mkdir(CARPETA, { recursive: true });
    const s = await stat(ARCHIVO_REGISTRO).catch(() => null);
    if (s && s.size > 2_000_000) await rename(ARCHIVO_REGISTRO, ARCHIVO_REGISTRO + '.anterior');
    await appendFile(ARCHIVO_REGISTRO, linea);
  } catch { /* sin registro en disco */ }
}
