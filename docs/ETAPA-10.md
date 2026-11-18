# Etapa 10 · Pruebas y puesta en marcha

## Qué quedó hecho

**1. Revisión de seguridad**: todo en orden. Se comprueba con `supabase/verificar/etapa10-seguridad.sql`, 10 revisiones con ✅.
- Todas las tablas tienen permisos por perfil y **nadie escribe directo** en ellas: todo pasa por funciones del servidor que revisan quién eres.
- Sin iniciar sesión no se ve ni se ejecuta nada.
- Ninguna tabla permite borrar registros, y la auditoría solo admite agregar.
- Una cuenta dada de baja pierde el acceso de inmediato, aunque tenga la app abierta.
- No hay llaves ni contraseñas en el código. Las llaves secretas solo están en tu `.env.local` y en Supabase/Vercel.
- Las fotos del menú están en un espacio privado.
- El registro público está cerrado: solo ustedes crean cuentas.

**2. Limpieza de datos de prueba (opción A)** en `supabase/arranque/`. Es para **una sola vez**, antes de arrancar.
- `1-revisar-datos-de-prueba.sql`: solo lee y muestra qué se borra y qué se conserva.
- `2-borrar-datos-de-prueba.sql`: borra cuentas, cobros, cortes, gastos, inventario, impresiones y auditoría de prueba. Los folios vuelven a empezar en 1.
  - **Se conservan**: propietarios, menú (con fotos), mesas, categorías de gasto, datos del negocio e impresoras.
  - No borra nada hasta que cambies `confirmar := 'NO'` por `'SI'`. Si algo falla, no se borra nada.
  - Opciones:
    - `borrar_catalogos_de_prueba`: por defecto `true`. Borra también insumos, proveedores, empleados y renta de prueba.
    - `borrar_cuentas_meseros_cajeros`: por defecto `false`. Ponlo en `true` para borrar las cuentas de meseros y cajeros de prueba y volver a usar esos nombres.
  - Deja una línea en la auditoría: "Limpieza de datos de prueba antes del arranque".

**3. Guías de uso** en lenguaje sencillo, para imprimir o enviar:
- [Meseros](guias/MESEROS.md)
- [Caja](guias/CAJA.md)
- [Propietarios](guias/PROPIETARIOS.md)
- [Si algo falla](SI-ALGO-FALLA.md): sin internet, no imprime, contraseña olvidada, celular perdido y respaldos.

**4. Dos herramientas nuevas** para tu computadora. Usan las llaves de tu `.env.local`; nunca las pegues en el chat.
- `npm run contrasena-propietario -- --usuario hector`: si a un propietario se le olvida la contraseña.
- `npm run respaldo`: copia de todos los datos en `respaldos/respaldo-AAAA-MM-DD.json`. No se sube a GitHub y no necesita Docker.

## Cómo subirlo

En tu computadora, en la carpeta `la-merced-`:

```
git pull
```

Esta etapa no tiene migraciones nuevas: no hace falta `npx supabase db push`, salvo que no hayas subido el cambio del ticket. En Supabase → SQL Editor corre `supabase/verificar/etapa10-seguridad.sql`: deben salir las 10 filas con ✅.

Revisa también en Supabase → **Authentication → Sign In / Providers** que esté **apagado** "Allow new users to sign up".

## Día de arranque (en este orden)

**Antes de abrir**
1. Termina las pruebas que quieras hacer. Haz el corte si hay una caja abierta.
2. Opcional: saca un respaldo de los datos de prueba con `npm run respaldo`.
3. Supabase → SQL Editor → corre `supabase/arranque/1-revisar-datos-de-prueba.sql` y revisa la lista.
4. Abre `supabase/arranque/2-borrar-datos-de-prueba.sql`:
   - Cambia `'NO'` por `'SI'` y ajusta las dos opciones.
   - Pégalo en el SQL Editor → **Run**.
   - Al final deben salir **0** cuentas, gastos, cortes e inventario, y **1** en auditoría.
5. Corre `supabase/verificar/etapa10-seguridad.sql`: todo ✅.

**Captura de lo real** (como Hector o Wendy)
6. **Usuarios**: da de alta a cada mesero y cajero con su contraseña. Si conservaste cuentas de prueba, dales de baja.
7. **Gastos → Sueldos**: tus empleados (lavaloza, cocineras, mesero, cajero…) con su sueldo.
8. **Gastos → Renta y gastos fijos**: la renta con su día y quién la paga.
9. **Inventario**: proveedores e insumos con su existencia actual y su mínimo.
10. **Catálogo**: revisa precios y que no haya nada marcado como agotado.

**En el restaurante**
11. Computadora de caja encendida. En **Comandas** debe decir que las impresoras están conectadas y el servicio en versión **1.2.0**.
12. Instala la app en el celular de cada mesero (abrir la página → "Agregar a pantalla de inicio") y que cada uno entre con su usuario.
13. Caja abre con su **fondo inicial**.
14. Prueba real: un pedido de una mesa → comanda en cocina → **Pedir la cuenta** → precuenta → **cobrar** → ticket.
15. Entrega las guías a meseros y caja.

**Al cerrar el primer día**
16. Corte de caja e impresión. Aprueben el corte en **Cortes y ventas**.
17. Revisen **Reportes → Hoy** y **Autorizaciones y avisos**.
18. Anoten todo lo que haya que ajustar y me lo pasan: hacemos los cambios en la semana del piloto.

## Pruebas automáticas (todo el sistema)

| Qué | Resultado |
| --- | --- |
| Base de datos (pgTAP) | 325 de 325 |
| Servicio de impresión: formatos | 9 de 9 |
| Servicio de impresión: integración | 10 de 10 |
| Navegador: salón | 24 de 24 |
| Navegador: caja | 12 de 12 |
| Navegador: catálogo | 11 de 11 |
| Navegador: inventario | 11 de 11 |
| Navegador: gastos y reportes | 12 de 12 |
| Limpieza de arranque | Probada: sin confirmar no borra nada; confirmada deja todo en cero, conserva menú, mesas y propietarios, y el primer pedido sale con folio 1 |
| Seguridad | 10 de 10 ✅ |
