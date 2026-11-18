# Ticket estilo tienda, ticket opcional y sin aviso de cancelación

## Qué cambió

**Ticket de cobro** (impresora de caja, 58 mm), parecido a un ticket de tienda:

```
      CENADURÍA LA MERCED
   AV. FUNDICIÓN 2103, SAN
CAYETANO, 20010 AGUASCALIENTES,
             AGS.
    TEL. 449 940 44 90
        449 181 31 21
================================
         FOLIO NO. 18
    06/11/2026 03:01:21 PM
            MESA 4
================================
CANT DESCRIPCION         IMPORTE
4  FLAUTAS KING SIZE     $276.00

               TOTAL: $1,276.00
            RECIBIDO: $1,300.00
                  CAMBIO: $24.00

 SON: MIL DOSCIENTOS SETENTA Y
   SEIS PESOS 00/100 M.N.

   ¡GRACIAS POR SU VISITA!
ESTE NO ES UN COMPROBANTE FISCAL
```

- Los datos del negocio son los del menú. No lleva la parte de "sucursal".
- Lleva la mesa o "PARA LLEVAR", y la hora con segundos.
- Recibido y cambio salen solo cuando se paga en efectivo.
- La vista previa en la pantalla de caja se ve igual.

**La cuenta** (la que sale con **Pedir la cuenta** o **Imprimir cuenta**) usa el mismo formato, sin recibido ni cambio.

**Al cobrar ya no se imprime el ticket automáticamente.**
- Caja marca **Imprimir ticket** antes de cobrar si el cliente lo quiere.
- O lo imprime después desde la cuenta cobrada con **Imprimir ticket**.
- En pantalla siempre se puede ver con **Ver ticket**.

**Quitar un producto ya enviado a cocina** ya no imprime el aviso "CANCELADO" en cocina. Sigue quedando registrado en la cuenta y en la auditoría, con motivo, quién y cuándo.

## Cómo subirlo

1. En tu computadora, en la carpeta `la-merced-`:
   ```
   git pull
   npx supabase db push
   ```
   Incluye `20261120000100_ticket_formato.sql`, `20261121000100_ticket_opcional.sql` y `20261121000200_precuenta_formato.sql`.
2. **En la computadora de caja**, actualiza el servicio de impresión a la versión **1.2.0**:
   - Descarga otra vez el ZIP.
   - Reemplaza la carpeta `impresora`.
   - Corre `instalar.bat`, igual que en la Etapa 6.
   - La pestaña **Comandas** muestra la versión del servicio.

Sin el paso 2, los tickets se siguen imprimiendo con el formato anterior.

## Pruebas automáticas

- **Base de datos:** 325 pruebas, incluidos el importe con letra y el ticket opcional.
- **Servicio de impresión:** 9 de formato y 10 de integración.
- **Navegador:** caja 12/12 y salón 24/24.
