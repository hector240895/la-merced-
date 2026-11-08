// Controladores de impresora:
//   windows  → impresoras instaladas en Windows (envío RAW por PowerShell)
//   archivo  → guarda cada impresión en una carpeta (simulación y pruebas)
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm, mkdir, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const AQUI = dirname(fileURLToPath(import.meta.url));

export function powershell(argumentos, entrada) {
  return new Promise((resolve) => {
    const p = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', ...argumentos], { windowsHide: true });
    let salida = '';
    let error = '';
    p.stdout.on('data', (d) => { salida += d; });
    p.stderr.on('data', (d) => { error += d; });
    p.on('error', (e) => resolve({ codigo: -1, salida, error: e.message }));
    p.on('close', (codigo) => resolve({ codigo, salida: salida.trim(), error: error.trim() }));
    if (entrada !== undefined) p.stdin.end(entrada); else p.stdin.end();
  });
}

const ESTADOS = { 0: 'lista', 1: 'en pausa', 2: 'con error', 3: 'eliminándose', 4: 'sin papel', 5: 'sin papel',
  6: 'sin conexión', 7: 'ocupada', 8: 'imprimiendo' };

export function controladorWindows() {
  return {
    async listar() {
      const r = await powershell(['-Command', 'Get-Printer | Select-Object Name, PrinterStatus, PortName | ConvertTo-Json -Compress']);
      if (r.codigo !== 0) throw new Error(r.error || 'No se pudo leer la lista de impresoras de Windows');
      const datos = r.salida ? JSON.parse(r.salida) : [];
      return (Array.isArray(datos) ? datos : [datos]).map((x) => ({ nombre: x.Name, puerto: x.PortName, estado: x.PrinterStatus }));
    },
    async estado(nombre) {
      const r = await powershell(['-Command', `$p = Get-Printer -Name '${nombre.replace(/'/g, "''")}' -ErrorAction SilentlyContinue; if ($p) { [int]$p.PrinterStatus } else { -1 }`]);
      const n = Number(r.salida);
      return n === -1 ? 'no encontrada' : ESTADOS[n] ?? `estado ${r.salida}`;
    },
    async imprimir(nombre, bytes, etiqueta) {
      const carpeta = await mkdtemp(join(tmpdir(), 'la-merced-'));
      const archivo = join(carpeta, `${etiqueta}.bin`);
      try {
        await writeFile(archivo, bytes);
        const r = await powershell(['-File', join(AQUI, 'imprimir-raw.ps1'), '-Impresora', nombre, '-Archivo', archivo]);
        if (r.codigo !== 0) throw new Error(r.error || `Error de impresión (código ${r.codigo})`);
      } finally {
        await rm(carpeta, { recursive: true, force: true });
      }
    },
  };
}

// Simulación: cada impresión es un archivo. Si existe el archivo FALLAR en la
// carpeta de una impresora, esa impresora "falla" (para probar errores).
export function controladorArchivo(carpeta) {
  let n = 0;
  return {
    async listar() { return [{ nombre: 'Simulada cocina', estado: 0 }, { nombre: 'Simulada caja', estado: 0 }]; },
    async estado(nombre) {
      try { await access(join(carpeta, nombre, 'FALLAR')); return 'sin papel'; } catch { return 'lista'; }
    },
    async imprimir(nombre, bytes, etiqueta) {
      const dir = join(carpeta, nombre);
      await mkdir(dir, { recursive: true });
      try { await access(join(dir, 'FALLAR')); throw new Error('La impresora no respondió (simulación: sin papel)'); }
      catch (e) { if (!String(e.message).includes('ENOENT') && e.code !== 'ENOENT') throw e; }
      n += 1;
      await writeFile(join(dir, `${String(Date.now())}-${String(n).padStart(4, '0')}-${etiqueta}.bin`), bytes);
    },
  };
}
