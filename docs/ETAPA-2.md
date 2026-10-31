# Etapa 2 · Base de datos, usuarios, roles, permisos y auditoría

## Qué quedó hecho

**Base de datos (Supabase, `supabase/migrations/`)**

| Archivo | Contenido |
| --- | --- |
| `…000100_base_usuarios.sql` | Sucursal, usuarios con perfil (propietario, cajero, mesero), funciones de permisos |
| `…000200_auditoria_avisos.sql` | Auditoría que solo admite agregar filas, avisos entre propietarios, reglas de "nada se borra" |
| `…000300_tablas_operacion.sql` | Catálogo, mesas (las 7 iniciales), cuentas, líneas, cobros extra, comandas, pagos, propinas, turnos y cortes, movimientos de efectivo, cola de impresión, gastos |
| `…000400_autorizaciones_funciones.sql` | Autorización cruzada entre propietarios y funciones del servidor para usuarios y avisos |
| `…000500_permisos_rls.sql` | Qué puede leer cada perfil (Row Level Security) y qué funciones puede llamar |

**Reglas que la base hace cumplir, sin importar la pantalla:**

- La app solo **lee**, y cada perfil lee solo lo suyo. Toda escritura pasa por funciones del servidor que revisan el perfil.
- **Nada se borra**: ningún perfil, ni siquiera el administrador de la base, puede borrar o vaciar tablas. Lo cancelado o anulado lleva motivo, usuario, fecha y hora, y no se puede des-cancelar.
- **La auditoría no se edita ni se borra.** Cada alta y cada cambio queda con el antes y el después.
- El precio de cada venta es una copia: cambiar el precio del catálogo no altera ventas pasadas, y el cambio queda en el historial de precios.
- **Autorización del otro propietario** solo para: cancelar una cuenta, anular un cobro y quitar un producto o cobro extra de una cuenta ya cobrada. Nadie aprueba su propia solicitud. Sin autorización, la base rechaza esos cambios.
- **Avisos**: todo lo que hace un propietario le llega como aviso al otro.
- Máximo **dos propietarios**; no se dan de baja ni se crean desde el panel.
- Solo los propietarios crean, renombran, cambian contraseña y dan de baja cuentas de meseros y cajeros. Un propietario no puede cambiar la contraseña del otro.
- **Dar de baja** corta el acceso a los datos al instante (aunque el teléfono siga con la sesión abierta) y bloquea el inicio de sesión. La cuenta y su historial se conservan.
- Una mesa con cuenta abierta no se desactiva ni se elimina.
- El inventario no existe todavía (Etapa 8) y nunca se descontará por venta.

**Qué ve cada perfil**

| Datos | Propietario | Cajero | Mesero |
| --- | --- | --- | --- |
| Catálogo | Todo | Activos y agotados | Activos y agotados |
| Mesas | Todas | Las vigentes | Las vigentes |
| Cuentas | Todas | Abiertas, por cobrar y las cobradas en su turno abierto | Cuentas de mesa abiertas o por cobrar |
| Pagos y propinas | Todos | Los de su turno abierto | Nada |
| Turnos y cortes | Todos | Los suyos | Nada |
| Gastos, auditoría, autorizaciones, avisos, historial de precios | Sí | Nada | Nada |
| Usuarios | Todos | Solo su cuenta | Solo su cuenta |

**Función `admin-usuarios`** (`supabase/functions/admin-usuarios/`): crea el acceso de meseros y cajeros, cambia contraseñas y bloquea o desbloquea el inicio de sesión al dar de baja o reactivar. Valida que quien la llama sea propietario.

**Inicio de sesión:** cada persona entra con su **usuario** (por ejemplo `hector`) y contraseña. Por dentro, Supabase usa el correo `hector@lamerced.local`; nadie necesita un correo real.

## Funciones del servidor disponibles (para las pantallas de las siguientes etapas)

| Función | Quién | Para qué |
| --- | --- | --- |
| `yo()` | Todos | Perfil del usuario con sesión (vacío si está dado de baja) |
| `renombrar_usuario`, `cambiar_perfil_usuario` | Propietario | Cambiar nombre; cambiar entre mesero y cajero |
| `admin-usuarios` (función) | Propietario | Crear cuenta, cambiar contraseña, dar de baja, reactivar |
| `solicitar_autorizacion`, `resolver_autorizacion` | Propietario | Pedir y aprobar o rechazar lo grave |
| `marcar_avisos_leidos` | Propietario | Marcar avisos como leídos |

## Cómo subirlo a tu proyecto de Supabase

Hazlo desde tu computadora, en la carpeta del repositorio. Necesitas Node.js 20 o más reciente.

1. Instala dependencias: `npm install`
2. Inicia sesión en Supabase (abre el navegador): `npx supabase login`
3. Vincula el proyecto; te pedirá la contraseña de la base de datos, escríbela ahí y no en el chat: `npx supabase link --project-ref yayksvcwxrkomqbeafla`
4. Sube la base de datos: `npx supabase db push`
5. Sube la función: `npx supabase functions deploy admin-usuarios --no-verify-jwt`
6. En el panel de Supabase → **Authentication → Sign In / Providers**:
   - Desactiva **Allow new users to sign up** (nadie se registra solo).
   - Deja **Email** activado (así entran con usuario y contraseña).
   - En **Email**, desactiva **Confirm email**.
   - Sube la longitud mínima de contraseña a **8**.
7. Crea las dos cuentas de propietario:
   - Copia `.env.example` como `.env.local`.
   - Llena `SUPABASE_SECRET_KEY` con la **Secret key** de *Project Settings → API Keys*.
   - Ejecuta, una vez por cada propietario. La contraseña se escribe en la terminal sin mostrarse y no queda guardada:

     ```
     npm run propietario -- --usuario hector --nombre "Hector Navarro"
     npm run propietario -- --usuario wendy --nombre "Wendy Rivas"
     ```

## Cómo comprobar que funciona

**A. Pruebas automáticas (en tu computadora, con Docker Desktop abierto)**

1. Levanta una copia local de Supabase: `npx supabase start`
2. Corre las 49 pruebas de la base de datos: `npx supabase test db`
3. Corre las 35 pruebas de punta a punta (inicio de sesión, función de usuarios, bajas y avisos): `npm run probar:api`
   - Esta prueba corre solo contra la copia local; se niega a tocar tu proyecto real.

Cada línea debe decir `ok`.

**B. En tu proyecto real (panel de Supabase)**

1. **Table Editor**:
   - Están las tablas `usuarios`, `auditoria`, `avisos`, `autorizaciones`, `cuentas`, etc.
   - `mesas` tiene las 7 mesas.
   - En `usuarios` aparecen Hector y Wendy como `propietario`.
2. **SQL Editor**, ejecuta `delete from auditoria;`. Debe responder *"No se permite borrar registros de auditoria"*.
3. **SQL Editor**, ejecuta `delete from mesas;`. Debe responder lo mismo para `mesas`.
4. **Authentication → Users**: solo existen los dos accesos `hector@lamerced.local` y `wendy@lamerced.local`.
5. **Advisors → Security Advisor**: no debe marcar tablas sin RLS.

Las pantallas (crear meseros desde el panel del propietario, etc.) se conectan en las siguientes etapas; en esta etapa la comprobación es con las pruebas y el panel de Supabase.

## Decisiones tomadas en esta etapa (avísame si alguna no te parece)

1. **Anular un cobro** anula todas sus líneas de pago y su propina. La cuenta vuelve a *por cobrar* en caja con su mismo detalle, sin volver a ocupar la mesa.
2. **Quitar un producto de una cuenta ya cobrada** (con autorización) lo marca cancelado. Cómo se registra la devolución del dinero se define en la Etapa 5 (Caja).
3. Los botones **"Eliminar"** de productos y mesas del prototipo serán una baja lógica: desaparecen de la operación pero se conservan.
4. **Aprobar o rechazar** no pide escribir de nuevo la contraseña: basta la sesión abierta del otro propietario.
5. Los precios del catálogo se consideran **IVA incluido**. La tasa de IVA (16 % por omisión) queda guardada para facturar en el futuro.
6. El mesero y el cajero ven productos **activos y agotados** (marcados como agotados); nunca los inactivos.
