# Etapa 9 · Finanzas y reportes

## Qué quedó hecho

Dos pestañas nuevas para los propietarios: **Gastos** y **Reportes**. Caja tiene una pestaña **Gastos** propia.

### Gastos (propietarios)

La pestaña tiene cuatro secciones:

**Gastos**
- **Registrar gasto**: categoría, en qué se gastó, monto, cómo se pagó, fecha y nota.
- Formas de pago:
  - **Efectivo de la caja**: sale de la caja abierta y baja el efectivo esperado del corte.
  - **Efectivo (fuera de la caja)**, **transferencia** o **tarjeta**: no tocan la caja.
- La lista se filtra por periodo y por categoría, con el total.
- **Anular**: un gasto no se borra; queda marcado con motivo, quién y cuándo.
  - Si se pagó con la caja y esta sigue abierta, el efectivo regresa a la caja.
  - Si era una compra de inventario, se descuenta del inventario.
- Las compras de la pestaña Inventario aparecen aquí solas.
- **¿Quién lo pagó?**: Hector o Wendy. Por defecto, el dueño que lo registra; se puede elegir al otro. Lo pagado con el efectivo de la caja es "Caja".
  - También al pagar sueldos y en cada gasto fijo, por ejemplo "la renta la paga Hector".
  - La lista se puede filtrar por quién pagó.

**Sueldos**
- Agrega a cada empleado con puesto y sueldo fijo por semana, quincena o mes.
- Los puestos son libres. Se sugieren lavaloza, cocinera, mesero y cajero, pero puedes escribir cualquiera.
- **Pagar sueldos**: los montos se llenan con el sueldo fijo. Ajusta a quien faltó, o pon 0 si no se le paga.
- Cada pago queda como un gasto de "Sueldos" con el nombre del empleado y el periodo.

**Renta y gastos fijos**
- Agrega la renta con su monto y el día del mes. **Se registra sola cada mes.**
- Si nadie abre el sistema en unos días, se pone al corriente y nunca registra un mes dos veces.
- Si cambias el monto, cuenta desde el siguiente mes; lo ya registrado no cambia.
- Sirve para cualquier pago fijo mensual, por ejemplo internet.

**Categorías**
- Ya vienen las de fábrica:
  - Renta, Sueldos, Insumos y mercancía, Refrescos y bebidas.
  - Gas, Luz, Agua, Internet y teléfono.
  - Desechables, Limpieza, Comisiones de la terminal, Mantenimiento, Publicidad y Otros.
- **Puedes agregar, renombrar o quitar categorías.** Las que ya usaste conservan sus gastos.
- Sueldos, Insumos y mercancía y Otros no se pueden quitar, porque el sistema las usa.

### Gastos desde caja
- El cajero registra gastos **pagados con el efectivo de la caja**, como gas o garrafones. Solo del día, y no renta ni sueldos.
- No puede sacar más efectivo del que debe haber en la caja.
- El gasto aparece en **Caja y corte** como "Gasto: …" y baja el efectivo esperado.
- Las compras de inventario que registra caja también salen del efectivo de la caja.
- Cada gasto de caja **avisa a los dos propietarios**.
- El cajero solo ve los gastos que él registró hoy.

### Reportes (propietarios)
- **Periodo**: hoy, ayer, esta semana, este mes, mes pasado u otras fechas.
- **Utilidad real = ventas − todos los gastos**, en pesos y como porcentaje de las ventas. Se compara con el periodo anterior.
- **Ventas**: por forma de pago, con las devoluciones restadas; también cuentas cobradas y ticket promedio.
  - Las propinas se muestran aparte porque son de los meseros.
- **Gastos** por categoría.
- **Gastos por dueño**: cuánto pagó Hector, cuánto Wendy y cuánto salió de la caja, cada uno con su detalle por categoría.
- **Por día**: ventas y gastos de cada día.
- **Horas con más venta.**
- **Meseros**: cuentas, ventas y propinas de cada uno.
- **Productos vendidos**: los 10 más vendidos, y la lista completa para ver los que menos se venden.
- **Cancelaciones y anulaciones**: productos quitados, cuentas canceladas y cobros anulados, con quién, cuándo y motivo.
- **Exportar a Excel**: descarga un archivo con todo el reporte y el detalle de gastos, para tu contador.

Los precios del menú incluyen IVA, así que las ventas del reporte también.

## Base de datos

| Archivo | Contenido |
| --- | --- |
| `20261118000100_categorias_gasto.sql` | Categorías nuevas y formas de pago de gastos |
| `20261118000200_finanzas.sql` | Categorías editables, gastos con forma de pago, gastos fijos, empleados y sueldos, anulación y reporte de utilidad |
| `20261118000300_gasto_fijo_mes.sql` | Un gasto fijo nuevo cuenta desde el mes en curso |
| `20261119000100_gastos_por_dueno.sql` | Quién pagó cada gasto y gastos por dueño |

## Cómo subirlo

En la carpeta `la-merced-` de tu computadora:

```
git pull
npx supabase db push
```

Vercel publica la app sola. En Supabase → SQL Editor corre `supabase/verificar/etapa9.sql`: deben salir las filas 1 a 6 con ✅.

## Cómo comprobar que funciona

1. **Categoría.** Como `hector` → **Gastos** → **Categorías** → agrega "Garrafones".
2. **Empleados.** **Sueldos** → **Agregar empleado**: por ejemplo, Rosa, cocinera, $2,000 por semana, y Pedro, lavaloza, $1,500.
3. **Pagar sueldos.** Escribe el periodo y verás los sueldos ya llenos. Cambia el de Pedro a $750, como si hubiera faltado, y toca **Registrar sueldos**.
4. **Renta.** **Renta y gastos fijos** → **Agregar gasto fijo** con el monto y el día. En **Gastos** aparece la renta de este mes como "automático".
5. **Gasto desde caja.** Como cajero, con la caja abierta → **Gastos** → **Registrar gasto**:
   - Elige Garrafones, "4 garrafones", $120.
   - En **Caja y corte** aparece "Gasto: 4 garrafones" y el efectivo esperado baja $120.
6. **Aviso.** Como `wendy` → **Autorizaciones y avisos**: aparece el gasto de caja.
7. **Anular.** Como `hector`, **Anular** el gasto de garrafones con un motivo. El efectivo regresa a la caja.
8. **Gasto de otro dueño.** Como `hector`, registra "Tanque de gas" $300 y en **¿Quién lo pagó?** elige Wendy Rivas.
9. **Reporte.** **Reportes** → **Este mes**: ventas, gastos por categoría y utilidad real. En **Gastos por dueño** ves lo de Hector y lo de Wendy por separado. Toca **Exportar a Excel**.

Como estos son datos de prueba, al terminar puedes anular los gastos, quitar la renta y los empleados de prueba y luego capturar los reales.

## Pruebas automáticas

- **Base de datos:** 36 pruebas nuevas en `supabase/tests/database/11_finanzas.test.sql` (320 en total). Cubren:
  - Categorías editables y las del sistema que no se quitan.
  - Gastos de caja que bajan el efectivo esperado y no rebasan lo que hay.
  - Permisos de caja.
  - Anulación con regreso del efectivo.
  - Renta automática sin duplicados.
  - Sueldos, el reporte de utilidad y los gastos por dueño.
- **Navegador:** `app/pruebas/finanzas.e2e.cjs`, 12 comprobaciones con propietarios y caja al mismo tiempo.
