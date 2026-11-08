# Etapa 5 · Caja y pagos

## Qué quedó hecho

**Pedidos para llevar**
- Los capturan el **mesero** (en su celular, sección *Para llevar* debajo de las mesas), la **caja** y los propietarios.
- Usan el mismo menú, con guisados, sabores y una observación por pieza.
- "Enviar a cocina" manda la comanda con la leyenda **PARA LLEVAR** y el número de pedido, sin esperar al cobro. Lo que se agrega después sale como comanda adicional.
- **Solo caja cobra.**

**Caja** (cajero y propietarios; pestaña *Caja*)
- **Abrir caja** con el fondo inicial. Una sola caja abierta a la vez; sin caja abierta no se cobra.
- **Cobrar:**
  - Las mesas se cobran cuando el mesero pidió la cuenta; los pedidos para llevar, en cualquier momento.
  - **Pago en efectivo, tarjeta, transferencia o combinado.** La suma debe dar exacto el total.
  - En efectivo se captura **con cuánto paga** el cliente y se muestra el **cambio**.
  - **Propina** aparte, con tarjeta o en efectivo. No es venta y se entrega a los meseros.
  - **Cobro extra** con comentario obligatorio. Cuenta como venta y sale en el ticket.
  - **Quitar productos** antes del cobro, con motivo.
  - **Sin cobros duplicados**, aunque se toque "Cobrar" dos veces.
  - Al cobrar, la mesa queda **libre** (y separada si estaba unida).
- **Ticket** para la impresora de caja (58 mm), con vista previa en pantalla y reimpresión registrada. Desde el 8 de noviembre es **simple**:
  - Lleva: Cenaduría La Merced, fecha, hora, folio, "Para llevar" cuando aplica, productos con precio, cobros extra, total, pagos, lo recibido, el cambio, la propina y "¡Gracias por su visita!".
  - Ya no lleva mesa, mesero, quién atendió en caja, dirección ni teléfonos (`20261111000100_ticket_simple.sql`).
- **Entradas y retiros de efectivo** con motivo obligatorio.
- **Corte de caja** (uno al día):
  - Muestra el fondo, los cobros por método, las entradas, los retiros y las devoluciones en efectivo.
  - Calcula el **efectivo esperado**, que **no incluye las propinas** porque se entregan a los meseros.
  - Calcula lo que debe marcar la **terminal**: tarjeta más propinas con tarjeta.
  - El cajero captura el efectivo contado y ve el **faltante o sobrante** antes de mandarlo.
  - El corte también sale impreso en caja (Etapa 6).

**Propietarios** (pestaña *Cortes y ventas*)
- **Aprobar** cortes y **reabrir** un corte, con motivo y registrado en la auditoría.
- Ver las **cuentas cobradas** y sus tickets.
- Con autorización del otro propietario:
  - **Anular un cobro:** la cuenta vuelve a caja para cobrarse de nuevo.
  - **Quitar un producto ya cobrado:** se elige cómo se **devuelve el dinero al cliente** (efectivo, tarjeta o transferencia). La devolución queda registrada; si es en efectivo, sale de la caja abierta y aparece en el corte.

## Base de datos

| Archivo | Contenido |
| --- | --- |
| `20261110000100_caja.sql` | Pedidos para llevar, caja, cobro, ticket, devoluciones, corte, permisos y tiempo real |
| `20261111000100_ticket_simple.sql` | Ticket más simple |

## Cómo subirlo

En la carpeta `la-merced-` de tu computadora:

```
git pull
npx supabase db push
```

Vercel publica la app sola. En Supabase → SQL Editor corre `supabase/verificar/etapa5.sql`: deben salir 6 filas con ✅.

## Cómo comprobar que funciona

Necesitas una cuenta de **cajero**. Créala en *Usuarios*, con el perfil Cajero.

1. **Abrir caja.** Entra como el cajero → *Caja* → **Caja y corte** → abre la caja con $500.
2. **Pedido para llevar.** En el celular, el mesero toca **Nuevo para llevar**, agrega 2 cafés de olla y envía.
   - En caja aparece "Para llevar #N" sin recargar.
   - En **Comandas** está su comanda con "PARA LLEVAR".
3. **Cobro combinado.** En caja, abre el pedido para llevar:
   - Agrega un **cobro extra** "Salsa extra" de $40. El total sube a $100.
   - Pago **Efectivo** $60 con "Con cuánto paga" $100, y luego **Tarjeta** (se llena solo con $40).
   - Propina $10 en efectivo: debe decir **"Cambio: $30"**.
   - Toca **Cobrar e imprimir ticket**. Revisa que el ticket traiga los productos, el total y el cambio, sin mesa, mesero, dirección ni teléfonos.
4. **Cobrar una mesa.** El mesero toma un pedido en la Mesa 1. En caja dice "El cobro se habilita cuando el mesero pide la cuenta". Cuando la pida, cóbrala: la Mesa 1 queda **Disponible** en el celular.
5. **Corte.** En **Caja y corte**:
   - Registra un retiro de $30 "Compra de hielo".
   - Revisa el efectivo esperado: $500 + $60 − $30 = **$530**. La propina no cuenta.
   - Captura $530 contado: debe decir "Caja cuadrada". Toca **Realizar corte**.
6. **Aprobar.** Como `hector` → **Cortes y ventas**: el corte aparece "Por aprobar". Apruébalo.
7. **Devolución.** En **Cuentas cobradas** → **Quitar producto** en la Mesa 1:
   - Elige el pozole, "Devolver por transferencia" y un motivo, y envía.
   - Como `wendy` → **Autorizaciones y avisos** → debe decir "Devolución al cliente: Transferencia" → **Aprobar**.

## Pruebas automáticas

- **Base de datos:** 49 pruebas nuevas en `supabase/tests/database/07_caja.test.sql` (207 en total).
- **Navegador:** 12 comprobaciones nuevas en `app/pruebas/caja.e2e.cjs`, con el mesero, la cajera y los dos propietarios. Las 24 del salón siguen pasando.

## Decisiones tomadas en esta etapa

1. **Una línea de pago por método.** Si el cliente paga dos veces con tarjeta, se suma en la misma línea.
2. **El cambio se calcula así:** lo que entrega el cliente − lo que paga en efectivo − la propina en efectivo, si la dejó incluida.
3. **Propinas con tarjeta:** si se las pagas a los meseros en efectivo desde la caja, regístralo como **retiro**, para que el corte cuadre.
4. **Devolución en efectivo** de un producto ya cobrado: necesita la caja abierta, porque el dinero sale de ahí.
5. **Las cuentas sin cobrar no impiden hacer el corte,** pero el sistema avisa cuántas hay.
