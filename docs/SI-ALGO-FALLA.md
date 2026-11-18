# Si algo falla

| Qué pasa | Qué hacer |
| --- | --- |
| **Se fue el internet** | La app necesita internet para guardar. Lo que se intente enviar muestra "Sin conexión": espera a que regrese y vuelve a tocar **Enviar a cocina** o **Cobrar** (no se duplica). Mientras, anota en papel. |
| **No imprime la comanda o el ticket** | Pestaña **Comandas**: muestra qué impresora falla y el motivo (sin papel, apagada, desconectada). Arregla la impresora y toca **Reintentar**. Lo pendiente sale solo, en orden. |
| **Dice "impresoras desconectadas"** | La computadora de caja está apagada o el servicio no corre. Enciéndela; el servicio arranca solo. Si no, en la carpeta `impresora` corre `reiniciar.bat`. |
| **Los acentos salen raros** | En la computadora de caja corre otra vez `instalar.bat` e imprime la página de prueba para elegir la tabla de letras correcta. |
| **Un mesero o cajero olvidó su contraseña** | Un propietario: **Usuarios → Cambiar contraseña**. |
| **Un propietario olvidó su contraseña** | En tu computadora, en la carpeta `la-merced-`: `npm run contrasena-propietario -- --usuario hector` (o `wendy`). Pide la nueva sin mostrarla. Usa las llaves de `.env.local`, que solo están en tu computadora. |
| **Se perdió o robaron un celular** | **Usuarios → Dar de baja** a esa persona: la sesión de ese celular deja de servir de inmediato. Luego **Reactivar** con una **contraseña nueva** para que entre desde otro celular. Si es de un propietario: cambia su contraseña (ver arriba) y avísame. |
| **La app no muestra lo último** | Ciérrala y vuelve a abrirla: se actualiza sola. En computadora: **Ctrl + Shift + R**. |
| **Algo no cuadra en el corte** | En **Cortes y ventas**, **Reabrir corte** con el motivo, corrige (entrada o retiro de efectivo) y vuelve a cerrar. |

## Respaldos
- Toda la información vive en **Supabase** (en internet), no en los celulares ni en la computadora de caja. Si se descompone un equipo no se pierde nada.
- En Supabase → **Database → Backups** ves si tu plan guarda copias diarias. Los planes de pago las guardan automáticamente; el gratuito no.
- **Respaldo propio** (recomendado cada semana o cada mes), en tu computadora, en la carpeta `la-merced-`:
  ```
  npm run respaldo
  ```
  Crea `respaldos/respaldo-AAAA-MM-DD.json` con todos los datos. Usa las llaves de tu `.env.local` y no necesita Docker. Copia el archivo a una USB o a tu nube; la carpeta `respaldos` no se sube a GitHub. Guárdalo en un lugar seguro, porque trae toda la información del negocio.
- Además, el **Exportar a Excel** de cada mes en **Reportes** sirve como respaldo legible.
