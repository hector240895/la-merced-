/// <reference types="vite-plugin-pwa/client" />
import { registerSW } from 'virtual:pwa-register';

// Cuando se publica una versión nueva, la app se actualiza sola: se revisa al
// abrirla y cada vez que se regresa a ella, y la página se recarga con lo nuevo.
registerSW({
  immediate: true,
  onRegisteredSW(_url, registro) {
    if (!registro) return;
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible' && navigator.onLine) registro.update().catch(() => {});
    });
  },
});
