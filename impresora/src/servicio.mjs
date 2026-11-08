// Arranque del servicio de impresión (lo inicia Windows al entrar a la sesión).
import { leerConfig, contrasena, registrar } from './config.mjs';
import { controladorArchivo, controladorWindows } from './impresoras.mjs';
import { iniciarServicio } from './cola.mjs';

process.on('unhandledRejection', (e) => registrar(`Error inesperado: ${e?.message ?? e}`));

async function arrancar() {
  const config = await leerConfig();
  const controlador = config.controlador === 'archivo' ? controladorArchivo(config.carpetaArchivo) : controladorWindows();
  for (;;) {
    try {
      const servicio = await iniciarServicio({ config, contrasena: await contrasena(config), controlador, registrar });
      process.on('SIGINT', async () => { await servicio.detener(); process.exit(0); });
      return;
    } catch (e) {
      // Sin internet al encender la computadora: reintenta cada 30 s.
      await registrar(`${e.message}. Reintento en 30 segundos.`);
      await new Promise((r) => setTimeout(r, 30_000));
    }
  }
}

arrancar().catch(async (e) => {
  await registrar(`No se pudo arrancar: ${e.message}`);
  process.exit(1);
});
