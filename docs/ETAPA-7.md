# Etapa 7 · Catálogo

## Qué quedó hecho

Pestaña nueva **Catálogo** en el panel de los propietarios. Ya no necesitas pedirme cambios al menú.

**Categorías**
- Agregar, renombrar y ordenar (↑ ↓).
- **Ocultar**: por ejemplo, una categoría de temporada.
- **Eliminar**: solo si ya no tiene productos. Desaparece del menú pero se conserva en el historial.

**Productos**
- **Agregar** y **editar**: nombre, precio, categoría, descripción y **opciones para elegir**.
  - Las opciones son, por ejemplo, "Sabor" con Horchata y Jamaica, o "Guisado" con los 6 guisados.
  - Se escribe una opción por renglón.
  - **Repetir** sirve cuando se eligen varias iguales, como los 3 guisados de la orden de sopes.
- **Ordenar** dentro de la categoría (↑ ↓).
- **Duplicar**: crea "(copia)" con todo igual, para hacer rápido algo parecido.
- **Ocultar**: deja de aparecer a meseros y caja, pero se conserva.
- **Eliminar**: deja de aparecer y se conserva con sus ventas pasadas.
- **Foto**: subir, cambiar o quitar. Se reduce sola a un tamaño ligero y **solo se ve en el catálogo**. Al cambiarla, la anterior queda guardada.

**Agotado / disponible**
- Lo pueden marcar **meseros, caja y propietarios**.
- En la pantalla de pedido, cada producto tiene el enlace **"Se acabó"**. Pide confirmación para evitar toques por error.
- Un producto agotado se ve con la etiqueta **Agotado**, no se puede pedir y tiene el botón **Marcar disponible**.
- El cambio aparece al instante en todos los celulares y en caja.

**Precios**
- Cada cambio queda en el **historial de precios**: al editar un producto ves el precio anterior, el nuevo, quién lo cambió y cuándo.
- **Las cuentas ya abiertas conservan el precio con que se pidieron.**

**Control:** todo queda en la auditoría, incluido quién marcó algo agotado. El otro propietario recibe aviso de cada cambio que haga un propietario.

**Cocina:** todos los productos se siguen imprimiendo en la comanda.

## Base de datos

| Archivo | Contenido |
| --- | --- |
| `20261116000100_catalogo.sql` | Funciones del catálogo, agotado/disponible, espacio privado para fotos y menú en tiempo real |

## Cómo subirlo

En la carpeta `la-merced-` de tu computadora:

```
git pull
npx supabase db push
```

Vercel publica la app sola. En Supabase → SQL Editor corre `supabase/verificar/etapa7.sql`: deben salir las filas 1 a 4 con ✅. La computadora de caja no cambia.

## Cómo comprobar que funciona

1. **Categoría.** Como `hector` → **Catálogo** → agrega la categoría "Especiales".
2. **Producto nuevo.**
   - **Agregar producto**: "Birria", $120, descripción "Con consomé".
   - **Agregar opción para elegir**: "Tortilla", con "Maíz" y "Harina" en renglones distintos.
   - En el celular del mesero aparece en la pestaña **Especiales**, con los botones "+ Maíz" y "+ Harina".
3. **Cambio de precio.** **Editar** → precio $135 → **Guardar cambios**.
   - El celular muestra $135 sin recargar.
   - Al volver a **Editar** se ve "$120 → $135 · Hector Navarro".
4. **Agotado.**
   - En el celular, toca **Se acabó** en la Birria y confirma. Queda "Agotado" y no se puede pedir.
   - En el catálogo aparece *Agotado*.
   - Toca **Marcar disponible** para regresarla.
5. **Foto.** En **Editar**, elige una foto. Se ve en el catálogo, pero no en el celular del mesero.
6. **Duplicar, ocultar y eliminar.**
   - **Duplicar** la Birria crea "Birria (copia)".
   - **Ocultarla** la quita del celular.
   - **Eliminarla** la quita del catálogo.
7. **Aviso.** Como `wendy` → **Autorizaciones y avisos**: aparece "Cambió Birria: precio de $120.00 a $135.00".
8. **Cuenta abierta.** Si una mesa ya tenía Birria pedida antes del cambio de precio, su cuenta sigue con $120.

## Pruebas automáticas

- **Base de datos:** 29 pruebas nuevas en `supabase/tests/database/09_catalogo.test.sql` (255 en total). Cubren:
  - Validaciones: nombres repetidos, precios negativos y opciones incompletas.
  - Duplicar y ordenar.
  - Historial de precios.
  - Que las cuentas abiertas conserven su precio.
  - Agotado por mesero y caja, y que no se pueda pedir.
  - Permisos.
  - Ocultar, eliminar y fotos.
  - Avisos y auditoría.
- **Navegador:** 11 comprobaciones en `app/pruebas/catalogo.e2e.cjs`, con el propietario, el mesero y el otro propietario. Las 24 del salón siguen pasando.
