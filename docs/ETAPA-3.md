# Etapa 3 · Mesas y pedidos

## Qué quedó hecho

**La aplicación (`app/`)**: web instalable (PWA) con el diseño de los prototipos. Funciona en celular, tablet y computadora.

- **Inicio de sesión** con usuario y contraseña. Cada perfil entra directo a su pantalla. Una cuenta dada de baja no entra.
- **Mesero** (desde el celular), como en el prototipo:
  - Ve todas las mesas con su estado: disponible, ocupada, pedido enviado, por cobrar.
  - Toca una mesa, elige productos por categoría, ajusta cantidades y agrega observaciones.
  - Revisa el pedido y lo envía a cocina. Si la mesa ya tenía pedido, se manda solo lo nuevo (pedido adicional).
  - Quita un producto ya enviado, o parte de su cantidad, con motivo obligatorio. Se guarda el aviso CANCELADO para cocina.
  - Une y separa mesas, y pide la cuenta. Después de pedir la cuenta ya no se agregan productos.
  - Si abre una mesa y sale sin pedir nada, la mesa vuelve a disponible.
  - Lo que va anotando sin enviar se guarda en el teléfono. Si se va la señal al enviar, vuelve a intentarlo y **no se duplica**.
- **Propietario**, con cuatro pestañas:
  - **Salón:** la misma pantalla del mesero; el propietario también puede tomar pedidos.
  - **Mesas:** agregar, renombrar, ordenar (↑ ↓), activar o desactivar, eliminar y *Solicitar cancelar cuenta*.
  - **Usuarios:** agregar meseros y cajeros, renombrar, cambiar entre mesero y cajero, cambiar contraseña, dar de baja y reactivar.
  - **Autorizaciones y avisos:**
    - Aprobar o rechazar lo que pide el otro propietario.
    - Ver sus avisos (un número rojo indica cuántos hay pendientes).
    - Consultar la actividad reciente.
- **En vivo:** lo que hace un mesero aparece al instante en los demás teléfonos y en el panel, sin recargar.
- **Cajero:** por ahora ve un aviso. Su pantalla llega en la Etapa 5.

**Base de datos**: dos migraciones nuevas.

| Archivo | Contenido |
| --- | --- |
| `20261101000100_mesas_pedidos.sql` | Funciones de mesas y pedidos, administración de mesas, tiempo real y un solo aviso por acción entre propietarios |
| `20261101000200_menu.sql` | Menú de La Merced: 57 productos en 10 categorías, tomados de la carta (MENU_1.pdf) |
| `20261102000100_opciones_sabores.sql` | Opciones para elegir en un producto (sabores de aguas y refrescos) |
| `20261102000200_sabores_arizona.sql` | Sabores del Arizona |

## Reglas nuevas que cuida el servidor

- Al unir mesas, la cuenta es la de la mesa principal. **Solo se unen mesas si, a lo más, una tiene pedido**: los productos de una cuenta no se pasan a otra.
- Al separar, la mesa principal se queda con la cuenta y las demás quedan libres.
- No se piden productos agotados. Una mesa con cuenta no se libera a mano: queda libre cuando caja cobre (Etapa 5) o cuando se cancela la cuenta con autorización.
- Una mesa en servicio o unida no se desactiva ni se elimina.
- Cada acción queda en la auditoría con usuario, fecha, hora y motivo cuando aplica. El otro propietario recibe **un** aviso por acción.

## Qué todavía no hace (siguientes etapas)

- **No imprime todavía.** "Enviar a cocina" registra la comanda, pero el papel sale cuando conectemos la impresora (Etapas 4 y 6).
- **Cobro, pedidos para llevar y corte de caja:** Etapa 5.
- **Catálogo editable** (productos, precios, fotos, marcar agotado): Etapa 7. Mientras tanto, cualquier cambio al menú me lo pides.

## Cómo publicarlo

### 1. Subir los cambios de la base de datos (desde tu computadora)

En la carpeta `la-merced-`, ejecuta uno por uno:

```
git pull
npm install
npx supabase db push
```

`db push` aplica solo las dos migraciones nuevas y no toca lo que ya existe.

### 2. Publicar la app en Vercel

1. Entra a https://vercel.com con tu cuenta de GitHub → **Add New… → Project** → importa `hector240895/la-merced-`.
2. En **Root Directory** elige `app`. Vercel detecta Vite solo.
3. En **Environment Variables** agrega:

   | Nombre | Valor |
   | --- | --- |
   | `VITE_SUPABASE_URL` | `https://yayksvcwxrkomqbeafla.supabase.co` |
   | `VITE_SUPABASE_PUBLISHABLE_KEY` | tu **Publishable key** (`sb_publishable_…`) |

   Las dos son públicas por diseño. **Nunca pongas la Secret key en Vercel.**
4. **Deploy.** Te da una dirección como `la-merced.vercel.app`.

Cada vez que yo suba cambios a GitHub, Vercel publica la nueva versión sola.

### 3. Instalarla en el celular

Abre la dirección en el celular:
- **iPhone (Safari):** Compartir → *Agregar a pantalla de inicio*.
- **Android (Chrome):** menú ⋮ → *Instalar app*.

## Cómo comprobar que funciona

1. **Entrar como propietario:** en la computadora, entra como `hector` → pestaña **Usuarios** → agrega un mesero de prueba (por ejemplo, usuario `prueba`).
2. **Tomar un pedido:** en el celular, entra como `prueba` → toca **Mesa 1** → agrega 2 pozoles rojos chicos con la observación "Sin lechuga" y un refresco de vidrio → **Revisar pedido** → **Enviar a cocina**.
3. **Ver el cambio en vivo:** en la computadora (pestaña **Salón**), la Mesa 1 cambia a *Pedido enviado* sin recargar.
4. **Pedido adicional:** en el celular, agrega un postre a la Mesa 1 y envía. En *Revisar pedido* se ve "Ya enviado a cocina" separado de lo nuevo.
5. **Quitar un producto:** en *Revisar pedido* → **Quitar** en el pozole → escribe el motivo y elige *Quitar 1* → **Confirmar**. Queda tachado en *Quitados* y el total baja $75.
6. **Unir y separar:**
   - Toca **Unir mesas**, elige la Mesa 2 y la Mesa 1, y confirma. Aparece una sola tarjeta "Mesa 1 + Mesa 2".
   - Toca *Separar mesas* para separarlas otra vez.
7. **Pedir la cuenta:** en la Mesa 1 → *Revisar pedido* → **Pedir la cuenta**. La mesa queda *Por cobrar* y ya no deja agregar productos.
8. **Cancelar con autorización:**
   - En la computadora, pestaña **Mesas** → *Solicitar cancelar cuenta* en la Mesa 1, con un motivo.
   - Entra como `wendy` → **Autorizaciones y avisos** → **Aprobar**. La Mesa 1 queda *Disponible* en el celular, y la cuenta queda cancelada (no borrada).
   - Comprueba también que Hector no tiene botón *Aprobar* en su propia solicitud.
9. **Administrar mesas:** en **Mesas**, agrega "Terraza". Aparece en el celular del mesero al instante.
10. **Dar de baja:** en **Usuarios**, da de baja al mesero de prueba. En su celular, al recargar, vuelve a la pantalla de inicio y ya no puede entrar.

## Pruebas automáticas (en esta etapa)

- 49 pruebas de la Etapa 2, 40 de la Etapa 3 y 10 de sabores sobre la base de datos (`supabase/tests/database/`).
- 19 comprobaciones de la app en un navegador real, con un celular y dos computadoras a la vez (`app/pruebas/salon.e2e.cjs`).
- Todas pasan contra la copia local de Supabase.

## Decisiones tomadas en esta etapa (avísame si alguna no te parece)

1. **La cuenta de una mesa nace con el primer pedido enviado.** Abrir la mesa solo la marca *Ocupada*.
2. **Unir mesas con pedido en ambas no se permite.** Si pasa en la operación, se pide la cuenta de una y se sigue en la otra.
3. **El mesero puede quitar productos de cualquier mesa**, porque nadie tiene mesas asignadas. Todo queda registrado con su nombre y motivo.
4. **El propietario también puede tomar pedidos** desde la pestaña Salón.

## Cómo quedó capturado el menú

- **Guisados:** el mesero los anota en la observación. Cada platillo con guisado muestra la lista: deshebrada, papas con chorizo, chicharrón prensado verde, requesón con rajas, champiñones o pollo.
- **Opciones separadas:** donde la carta junta opciones que cocina prepara distinto, van como productos separados con el mismo precio. Son las medias órdenes "de pollo / queso" y "deshebrada / requesón", y los tamales rojo, verde y de prensado con queso.
- **Sabores para elegir con botón** (obligatorio elegir uno; cada sabor queda en su propia línea y saldrá en la comanda):
  - Agua de sabor (500 ml y 900 ml): Horchata o Jamaica.
  - Refresco de vidrio (355 ml, $25): Pepsi, Pepsi Black, Agua mineral, Mirinda, Jumex, 7UP, Jarrito tamarindo, Jarrito tutti frutti, Jarrito piña, Manzanita, Sangría.
  - Refresco desechable (600 ml, $30): Coca-Cola o Coca-Cola Light.
  - Arizona ($25): Té verde, Mango, Kiwi o Sandía.
- **"De pollo (extra $5)" del pozole:** es el producto *Pozole de pollo (extra)*, que se agrega junto al pozole.
- **"Solo viernes, sábado y domingo" y "Solo viernes y sábado":** aparece en la descripción. Desde la Etapa 7 podrás marcarlos como agotados los demás días.
- **"Todos nuestros platillos son preparados con lechuga, crema y queso":** los cambios ("sin crema") van en la observación.
