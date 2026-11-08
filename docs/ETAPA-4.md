# Etapa 4 · Comandas

## Qué quedó hecho

- **Comanda en cada envío.** Al enviar un pedido se forma la comanda para la impresora de cocina (NE-511). Lleva:
  - Mesa (o "Mesa 1 + Mesa 2" si están unidas), fecha, hora y mesero.
  - Cada producto con su cantidad, **sabor** y **observaciones** en letra destacada.
  - **Todas las categorías, bebidas incluidas.**
  - **Nunca precios ni totales:** la base de datos rechaza cualquier comanda que los traiga.
- **Comanda adicional.** Cuando una mesa ya tenía pedido, lleva el título "COMANDA ADICIONAL" y solo lo nuevo.
- **Aviso de cancelación.** Al quitar un producto se forma "AVISO DE CANCELACIÓN" con "CANCELADO: 1 × Pozole rojo chico", la mesa, la hora y quién lo quitó.
- **Estado de impresión** en vivo para el mesero, caja y propietarios:
  - *Pendiente de imprimir*, *✓ Comanda impresa* o *Error de impresión*.
  - En la tarjeta de la mesa, en "Revisar pedido" y en la pestaña **Comandas**.
- **Si una comanda falla:**
  - El mesero ve "Una comanda no se imprimió" y el botón **Reintentar impresión**.
  - En el panel, la pestaña **Comandas** muestra un número rojo.
- **Reimpresión manual** de una comanda ya impresa:
  - Sale marcada como **REIMPRESIÓN**, con la hora y quién la pidió.
  - Queda en la auditoría.
- **Vista previa (botón Ver):** la comanda en pantalla, con el ancho real del papel de 80 mm. Sirve para revisar el formato y como plan de emergencia si la impresora falla.
- **Sin duplicados:**
  - Cada comanda se encola una sola vez.
  - Si llega dos veces el aviso de "impresa", la segunda no cambia nada; así una reconexión no confunde el estado.

**Pestaña Comandas:** está en el panel del propietario y en la pantalla de caja. Tiene tres secciones: *No se imprimieron*, *Pendientes de imprimir* e *Impresas recientemente*.

## Importante: todavía no sale papel

La impresión física la hace un programa en la computadora de caja que se construye en la **Etapa 6**. Hasta entonces, las comandas se quedan en **"Pendiente de imprimir"**: es lo esperado. Para leerlas, toca **Ver**.

## Base de datos

| Archivo | Contenido |
| --- | --- |
| `20261108000100_comandas.sql` | Formación y encolado de comandas, regla "sin precios", funciones para informar, reintentar y reimprimir, y estado en tiempo real |

**Funciones nuevas:**

| Función | Quién | Para qué |
| --- | --- | --- |
| `reportar_impresion` | Caja y propietario | La usará el servicio de impresión (Etapa 6) para avisar "impresa" o "error" |
| `reintentar_impresion` | Todos | Volver a mandar una comanda que falló |
| `reimprimir_comanda` | Todos | Copia de una comanda ya impresa, registrada con quién la pidió |

## Cómo subirlo

En la carpeta `la-merced-` de tu computadora:

```
git pull
npx supabase db push
```

Vercel publica la nueva versión de la app solo.

Para revisar la base: en Supabase → SQL Editor, corre `supabase/verificar/etapa4.sql`. Deben salir 6 filas con ✅.

## Cómo comprobar que funciona

1. **Enviar un pedido.** En el celular, entra como mesero y envía a la **Mesa 1**:
   - 2 pozoles rojos chicos con la observación "Sin lechuga".
   - Un agua de jamaica.

   La tarjeta de la Mesa 1 debe decir *Pendiente de imprimir*.
2. **Ver la comanda.** Toca la Mesa 1 → **Revisar pedido** → en "Comandas a cocina" toca **Ver**. Debe salir:
   - "COMANDA", "Mesa 1", la hora y tu nombre.
   - "2 × Pozole rojo chico" con "** SIN LECHUGA **".
   - "1 × Agua de sabor (500 ml)" con "Jamaica".
   - **Ningún precio.**
3. **Pedido adicional.** Agrega un postre y envía. La nueva comanda dice "COMANDA ADICIONAL" y trae **solo** el postre.
4. **Aviso de cancelación.** Quita uno de los pozoles con un motivo. Aparece una comanda "Cancelación" que dice "CANCELADO: 1 × Pozole rojo chico".
5. **Cola en el panel.** En la computadora, entra como `hector` → pestaña **Comandas**. Ahí ves las 3 comandas en *Pendientes de imprimir*, cada una con su vista previa.

Las partes de "impresa", "error", "reintentar" y "reimprimir" necesitan el servicio de la Etapa 6. Ya están probadas con pruebas automáticas (abajo).

## Pruebas automáticas

- **Base de datos:** 25 pruebas nuevas en `supabase/tests/database/05_comandas.test.sql`:
  - Comanda nueva, adicional y aviso CANCELADO.
  - Mesero, hora, sabor y observación.
  - Sin precios, garantizado por la base.
  - Impresa, error, reintentar y reimprimir, sin duplicados, con permisos y auditoría.
- **Navegador:** 4 comprobaciones nuevas (23 en total). Una de ellas simula al servicio de impresión avisando "impresa" y "error", y verifica que el mesero lo ve en su celular al instante y puede reintentar.
