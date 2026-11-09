# Etapa 6 · Impresoras

## Qué quedó hecho

Un programa para la **computadora de caja (Windows 11)**, en la carpeta `impresora/` del repositorio:

- **Arranque:** se inicia solo al entrar a Windows y se conecta al sistema. Si se cierra por algún error, se vuelve a abrir en 5 segundos.
- **Comandas** (pedidos nuevos, adicionales y avisos de cancelación): salen en la **NE-511** de cocina (80 mm) y el papel se corta solo.
  - Llevan la mesa en letra grande, el mesero, la hora, cada producto con sus guisados o sabor y las observaciones en mayúsculas.
  - Nunca llevan precios.
- **Tickets y cortes de caja:** salen en la **NE-510X** de caja (58 mm). Esa impresora corta a mano.
- **Confirmación:** después de cada impresión avisa al sistema "impresa" o "error", y el mesero lo ve en su celular.
- **Detección de fallas:** si la impresora está apagada, sin papel o desconectada, Windows no logra imprimir. El programa **cancela ese intento** (para que no salga después repetido) y avisa "Error de impresión". Desde el celular o la caja se toca **Reintentar**.
- **Sin internet o con la computadora apagada:** los trabajos esperan. Al volver se imprimen **en orden de llegada**.
- **Sin duplicados:** el programa recuerda lo que ya imprimió. Si se va el internet justo después de imprimir, al volver solo confirma, sin repetir el papel.
- **Acentos y ñ:** durante la instalación se imprimen dos páginas de prueba y se escoge la que se ve bien.
- **Estado en la app:** en la pestaña **Comandas**, caja y propietarios ven si las impresoras están "Listas" y si la computadora de caja está conectada. Si se desconecta, aparece una alerta en rojo.

La contraseña de la cuenta del programa queda **cifrada con la protección de Windows**: solo ese usuario de Windows, en esa computadora, puede leerla.

## Precuenta (cuenta informativa antes de cobrar)

Agregada el 8 de noviembre de 2026 (`20261113000100_precuenta_tipo.sql`, `20261113000200_precuenta.sql`; programa de impresión versión 1.1.0).

- **Cuándo se imprime:** sola, cuando el mesero toca **Pedir la cuenta**, en la impresora de **caja** (NE-510X).
- **Volver a imprimirla:** desde el celular del mesero (**Volver a imprimir la cuenta**) o desde caja (**Imprimir cuenta**). También la pueden imprimir los propietarios.
- **Qué lleva:** Cenaduría La Merced, la **mesa** (o "Para llevar #folio") en letra grande, folio, fecha y hora, los productos con su importe, los cobros extra, el **TOTAL** y "¡Gracias por su visita!". Sin las leyendas "cuenta informativa" ni "cuenta no pagada" (programa de impresión 1.1.2, `20261114000100_precuenta_gracias.sql`).
- **Qué no hace:** no cambia la mesa, no registra pagos y no entra al corte. Sí queda registrado quién la imprimió.
- La impresora de **cocina** no cambia.

- **Sin guisados:** la precuenta y el ticket pagado no muestran los guisados ni otras opciones del platillo; sí muestran el sabor de las bebidas. La comanda de cocina sigue mostrando todo (`20261115000100_tickets_sin_guisados.sql`).

### Cómo actualizar (en este orden)

1. **Primero la computadora de caja:**
   - Descarga otra vez el ZIP de GitHub y reemplaza la carpeta `C:\LaMerced\la-merced--main`.
   - En la carpeta `impresora`, haz doble clic en `reiniciar.bat`. No necesitas volver a configurar.
   - En la app, en **Comandas**, la computadora debe aparecer conectada.
2. **Después la base de datos**, en tu computadora: `git pull` y `npx supabase db push`.

Hazlo en ese orden: el programa anterior no conoce la precuenta y la marcaría "Error de impresión".

## Instalación (la haces tú, una sola vez)

### A. En tu computadora, con el repositorio

```
git pull
npx supabase db push
```

Esto agrega el aviso de "impresoras conectadas" (`20261112000100_servicio_impresion.sql`). Vercel actualiza la app sola.

### B. En el sistema (desde cualquier navegador)

Entra como `hector` → **Usuarios** → agrega la cuenta del programa:
- **Nombre:** Impresora de caja
- **Usuario:** `impresora`
- **Perfil:** Cajero
- **Contraseña:** una que solo tú sepas (mínimo 8 caracteres). La vas a escribir en la computadora de caja, no en el chat.

### C. En la computadora de caja

1. **Instala Node.js.**
   - Entra a https://nodejs.org y descarga la versión **LTS**.
   - Ábrela e instálala con las opciones que trae (Siguiente, Siguiente…, Instalar).
2. **Descarga el sistema.**
   - En https://github.com/hector240895/la-merced- toca el botón verde **Code → Download ZIP** (inicia sesión con tu cuenta de GitHub).
   - Descomprime el ZIP en `C:\LaMerced`, para que quede `C:\LaMerced\la-merced--main\`.
3. **Abre la carpeta** `C:\LaMerced\la-merced--main\impresora` y haz doble clic en **`instalar.bat`**.
   - Si Windows muestra "Windows protegió su PC", toca **Más información → Ejecutar de todas formas**.
4. **Sigue el asistente:**
   1. **Usuario:** presiona Enter para usar `impresora`. Luego escribe la **contraseña** de esa cuenta; no se ve mientras escribes.
   2. **Impresoras:** aparece la lista de impresoras de Windows. Escribe el **número** de la de **cocina** y luego el de la de **caja**.
   3. **Acentos:** cada impresora imprime **dos páginas de prueba**, la **A** y la **B**. Escribe la letra de la página donde "á é í ó ú ñ ¡ ¿" se ven bien.
   4. **Listo:** el asistente deja el programa arrancando con Windows y lo inicia en ese momento.
5. **Revisa en la app** (pestaña **Comandas**) que diga **Cocina: Lista**, **Caja: Lista** y "Computadora de caja conectada".

> El programa arranca cuando **alguien entra a la sesión de Windows** de esa computadora. Configúrala para que entre sola al encender, o que el cajero entre a su sesión al llegar.

Para revisar desde Supabase: en el SQL Editor corre `supabase/verificar/etapa6.sql`. Las filas 1 a 4 deben salir con ✅.

## Pruebas físicas

Haz cada una y anota si salió bien:

| # | Prueba | Qué debe pasar |
|---|---|---|
| 1 | El mesero envía un pedido con una observación y un guisado | Sale la comanda en **cocina**, con la mesa grande, la observación en mayúsculas, **sin precios**, y se corta sola. En el celular dice **✓ Comanda impresa** |
| 2 | Pedido adicional a la misma mesa | Sale "COMANDA ADICIONAL" solo con lo nuevo |
| 3 | Quitar un producto ya enviado | Sale "AVISO DE CANCELACIÓN" con "CANCELADO: …" |
| 4 | Pedido para llevar | La comanda dice "PARA LLEVAR" y "Pedido #…" |
| 5 | Cobrar en efectivo | Sale el ticket en **caja** (58 mm): total, recibido y cambio, legible y sin que se corte el texto |
| 6 | Quitar el papel de cocina (o apagarla) y enviar un pedido | En el celular sale **Error de impresión**; en Comandas la impresora no aparece "Lista". Pon el papel, toca **Reintentar**: sale **una sola vez** |
| 7 | Desconectar el internet de la computadora de caja y enviar 2 pedidos desde un celular con datos | La app muestra "Sin conexión con la computadora de caja". Al reconectar salen los 2, **en orden** y **sin repetirse** |
| 8 | Apagar la computadora de caja, enviar un pedido y volver a prenderla | Al entrar a Windows sale la comanda pendiente |
| 9 | Reimprimir una comanda desde Comandas | Sale marcada "REIMPRESIÓN" |
| 10 | Hacer el corte de caja | Sale el corte en la impresora de caja |
| 12 | El mesero toca **Pedir la cuenta** | Sale en **caja** la cuenta con la mesa en grande, los productos, el TOTAL y "¡Gracias por su visita!"; la mesa sigue "Por cobrar" y el corte no cambia |
| 13 | **Volver a imprimir la cuenta** (celular) e **Imprimir cuenta** (caja) | Sale otra vez la cuenta |
| 11 | Acentos y ñ | "Requesón", "Champiñones", "Jarrito piña" se ven bien |

Si algo no sale bien, mándame el número de la prueba y lo que viste, y la parte final del **registro**:
`C:\Users\<tu usuario>\AppData\Roaming\LaMercedImpresion\registro.log`
(escribe `%APPDATA%\LaMercedImpresion` en la barra del explorador de archivos).

## Mantenimiento

| Necesito… | Haz esto en `C:\LaMerced\la-merced--main\impresora` |
|---|---|
| Cambiar de impresora, de cuenta o la tabla de acentos | Doble clic en `instalar.bat` y vuelve a seguir el asistente |
| Reiniciar el programa | Doble clic en `reiniciar.bat` |
| Quitar el programa | Doble clic en `desinstalar.bat` |
| Actualizar a una versión nueva | Descarga otra vez el ZIP, reemplaza la carpeta y corre `instalar.bat` |

## Pruebas automáticas

Las hice sin Windows ni impresoras reales: Windows y las impresoras físicas se prueban con la lista de arriba.

- **`impresora/pruebas/formatos.test.mjs` (7 pruebas):**
  - Acentos y ñ en las dos tablas.
  - Renglones que caben en 80 mm y 58 mm.
  - Comanda sin precios y con corte de papel.
  - Ticket solo con total, recibido y cambio.
  - Corte con faltante o sobrante.
  - Precuenta con la mesa, el total y el agradecimiento.
- **`impresora/pruebas/servicio.integracion.mjs` (10 comprobaciones):** el servicio real contra la base local, con impresoras simuladas.
  - Comanda en cocina y ticket en caja.
  - Error y reintento.
  - Pendientes al reconectar, en orden.
  - Sin duplicados.
  - Reimpresión, precuenta y corte.
  - Estado de las impresoras.

- **Base de datos:** `supabase/tests/database/08_precuenta.test.sql` (14 pruebas): la precuenta sale al pedir la cuenta, en caja, con la mesa, sin registrar pagos ni cambiar la cuenta.
