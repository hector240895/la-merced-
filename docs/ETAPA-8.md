# Etapa 8 · Inventario (manual)

## Qué quedó hecho

Pestaña nueva **Inventario** para los propietarios y para caja.

**El inventario es manual.** Vender un platillo **no descuenta nada**. Las existencias cambian solo con lo que se registra en esta pestaña.

**Insumos** (solo propietarios)
- **Agregar insumo**: nombre, unidad (kg, pieza, litro…), "avisar cuando queden" (mínimo), proveedor habitual y existencia actual.
- **Editar** y **eliminar**. Al eliminar, su historial se conserva.
- No hay lista inicial: tú agregas los insumos.

**Proveedores** (solo propietarios)
- Nombre, teléfono y notas (por ejemplo, días de entrega). Se pueden editar y eliminar.

**Movimientos**

| Movimiento | Quién | Qué hace |
| --- | --- | --- |
| **Compra** | Caja y propietarios | Suma al inventario **y registra el gasto automáticamente** en "Compras y mercancía", con el detalle de cada insumo. Puede llevar varios insumos, proveedor y nota (por ejemplo, el número de factura). |
| **Entrada** | Caja y propietarios | Suma sin costo (regalo, devolución, sobrante). Hay que decir de dónde viene. |
| **Merma** | Solo propietarios | Resta lo que se echó a perder o caducó. El motivo es obligatorio. |
| **Contar** | Solo propietarios | Escribes lo que contaste. El sistema registra la diferencia con lo anotado. |

- Los movimientos **no se editan ni se borran**. Si algo se registró mal, se corrige con otro movimiento (por ejemplo, un conteo).
- No se puede sacar más de lo que hay.

**Alertas de "por surtir"**
- Si un insumo llega a su mínimo o queda por debajo, se marca en rojo con la palabra **bajo**.
- Arriba aparece la lista "Por surtir".
- La pestaña **Inventario** muestra un número rojo con cuántos insumos faltan.

**Lo que ve cada quien**
- **Propietarios:** todo, incluido el historial de **Movimientos** con quién, cuándo, cuánto, el costo y el proveedor.
- **Caja:** existencias, alertas, **Compra** y **Entrada**, y "Lo que registré" (sin costos). No ve el historial de costos ni los gastos.
- **Meseros:** no ven el inventario.

**Control**
- Todo queda en la auditoría.
- Cuando caja registra una compra, **los dos propietarios reciben aviso**, porque genera un gasto.
- Lo que hace un propietario avisa al otro, como siempre.

## Base de datos

| Archivo | Contenido |
| --- | --- |
| `20261117000100_inventario.sql` | Insumos, proveedores, movimientos, compra con gasto automático, permisos y tiempo real |

## Cómo subirlo

En la carpeta `la-merced-` de tu computadora:

```
git pull
npx supabase db push
```

Vercel publica la app sola. En Supabase → SQL Editor corre `supabase/verificar/etapa8.sql`: deben salir las filas 1 a 5 con ✅. La computadora de caja no cambia.

## Cómo comprobar que funciona

1. **Proveedor.** Como `hector` → **Inventario** → **Agregar proveedor** (por ejemplo, "Carnicería López").
2. **Insumos.** **Agregar insumo**:
   - "Carne de res", unidad kg, avisar cuando queden 5, proveedor Carnicería López, existencia actual 6.
   - "Tortilla", unidad kg, avisar cuando queden 10, existencia actual 4.
   - La tortilla aparece en rojo con **bajo**, arriba sale "Por surtir: Tortilla" y la pestaña muestra **1**.
3. **Compra desde caja.** Entra como cajero → **Inventario** → **Compra** en la Tortilla:
   - 10 kg, costo $250.
   - **Agregar otro insumo**: Carne de res, 2.5 kg, $450.
   - Proveedor y nota "Factura 77". El total dice $700 → **Guardar compra**.
   - La tortilla sube a 14 kg y la alerta desaparece, también en la pantalla de Hector sin recargar.
4. **Entrada.** Como cajero, **Entrada** en la carne: 1 kg, "Sobró del evento".
5. **Merma.** Como `hector`, **Merma** en la carne: 0.5 kg, "Se echó a perder".
6. **Conteo.** **Contar** en la carne. Escribe lo que hay de verdad: el sistema muestra la diferencia y la registra.
7. **Historial.** En **Movimientos** ves cada paso con quién lo hizo y el costo de la compra.
8. **Aviso.** Como `wendy` → **Autorizaciones y avisos**: aparece "Registró una compra de $700.00 a Carnicería López".
9. **Gasto.** La compra ya quedó guardada como gasto. Lo verás en la pantalla de gastos de la Etapa 9.

## Pruebas automáticas

- **Base de datos:** 29 pruebas nuevas en `supabase/tests/database/10_inventario.test.sql` (284 en total). Cubren:
  - Permisos de cada perfil: caja compra y da entradas; solo propietarios dan de alta, mermas y conteos; meseros sin acceso.
  - La compra crea el gasto con su detalle y avisa a los propietarios.
  - Existencia inicial, merma con motivo, no sacar más de lo que hay y ajuste por diferencia.
  - Movimientos que no se editan e insumos que no se borran.
- **Navegador:** `app/pruebas/inventario.e2e.cjs`, 11 comprobaciones con propietario y caja al mismo tiempo.
