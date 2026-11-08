# Sistema La Merced

Sistema web (PWA) para la operación y administración de Cenaduría La Merced:
mesas, comandas impresas, caja, catálogo, inventario manual, gastos y reportes.

- Base de datos y autenticación: Supabase (`supabase/`)
- Aplicación web (PWA): React + Vite (`app/`), publicada en Vercel
- Servicio de impresión para la computadora de caja (Windows 11): `impresora/`
- Especificación: documento maestro v1.4

## Etapas

| # | Etapa | Estado |
| --- | --- | --- |
| 2 | Base de datos, usuarios, roles, permisos y auditoría | Terminada → [docs/ETAPA-2.md](docs/ETAPA-2.md) |
| 3 | Mesas y pedidos | Terminada → [docs/ETAPA-3.md](docs/ETAPA-3.md) |
| 4 | Comandas | Terminada → [docs/ETAPA-4.md](docs/ETAPA-4.md) |
| 5 | Caja y pagos | Terminada → [docs/ETAPA-5.md](docs/ETAPA-5.md) |
| 6 | Impresoras | Lista para instalar y probar → [docs/ETAPA-6.md](docs/ETAPA-6.md) |
| 7 | Catálogo | Pendiente |
| 8 | Inventario | Pendiente |
| 9 | Finanzas y reportes | Pendiente |
| 10 | Pruebas y puesta en marcha | Pendiente |

## Llaves y contraseñas

Nunca se guardan en el repositorio. Copia `.env.example` como `.env.local`
en tu computadora y llénalo ahí (`.env.local` está en `.gitignore`).
