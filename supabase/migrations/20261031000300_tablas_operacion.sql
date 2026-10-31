-- =============================================================================
-- Sistema La Merced · Etapa 2 · 3/5
-- Tablas de operación: catálogo, salón, ventas, caja, impresión y gastos.
-- Las funciones que las usan (abrir mesa, enviar comanda, cobrar…) se agregan
-- en sus etapas; aquí quedan la estructura y las reglas que nunca se rompen.
--
-- Importes en pesos con 2 decimales. Los precios del catálogo son precio final
-- al cliente (IVA incluido); tasa_iva permite el desglose para facturar después.
-- =============================================================================

create type public.estado_producto     as enum ('activo', 'agotado', 'inactivo');
create type public.estado_mesa         as enum ('disponible', 'ocupada', 'pedido_enviado', 'por_cobrar');
create type public.tipo_cuenta         as enum ('mesa', 'llevar');
create type public.estado_cuenta       as enum ('abierta', 'por_cobrar', 'cobrada', 'cancelada');
create type public.estado_linea        as enum ('activa', 'cancelada');
create type public.estado_facturacion  as enum ('no_facturada', 'facturada', 'cancelada');
create type public.metodo_pago         as enum ('efectivo', 'tarjeta', 'transferencia');
create type public.estado_pago         as enum ('vigente', 'anulado');
create type public.tipo_comanda        as enum ('nueva', 'adicional', 'cancelacion', 'modificacion');
create type public.estado_turno        as enum ('abierto', 'cerrado', 'aprobado');
create type public.tipo_movimiento     as enum ('entrada', 'retiro');
create type public.tipo_documento      as enum ('comanda', 'ticket', 'corte');
create type public.impresora           as enum ('cocina', 'caja');
create type public.estado_impresion    as enum ('pendiente', 'enviado', 'impreso', 'error');
create type public.categoria_gasto     as enum ('renta', 'nomina', 'gas', 'electricidad', 'agua',
                                                'compras_mercancia', 'mantenimiento', 'publicidad', 'otros');

-- -----------------------------------------------------------------------------
-- Catálogo
-- -----------------------------------------------------------------------------
create table public.categorias (
  id            uuid primary key default gen_random_uuid(),
  sucursal_id   uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  nombre        text not null check (length(trim(nombre)) > 0),
  orden         integer not null default 0,
  activa        boolean not null default true,
  eliminada_en  timestamptz,
  eliminada_por uuid references public.usuarios (id),
  creado_en     timestamptz not null default now(),
  creado_por    uuid references public.usuarios (id) default privado.actor(),
  constraint categorias_eliminada check ((eliminada_en is null) = (eliminada_por is null))
);

create table public.productos (
  id            uuid primary key default gen_random_uuid(),
  sucursal_id   uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  categoria_id  uuid not null references public.categorias (id),
  nombre        text not null check (length(trim(nombre)) > 0),
  descripcion   text,
  precio        numeric(10, 2) not null check (precio >= 0),
  tasa_iva      numeric(5, 4) not null default 0.16 check (tasa_iva between 0 and 1),
  estado        public.estado_producto not null default 'activo',
  orden         integer not null default 0,
  foto_url      text,
  eliminado_en  timestamptz,
  eliminado_por uuid references public.usuarios (id),
  creado_en     timestamptz not null default now(),
  creado_por    uuid references public.usuarios (id) default privado.actor(),
  constraint productos_eliminado check ((eliminado_en is null) = (eliminado_por is null))
);
create index productos_categoria_idx on public.productos (categoria_id);

create table public.historial_precios (
  id               uuid primary key default gen_random_uuid(),
  sucursal_id      uuid not null references public.sucursales (id),
  producto_id      uuid not null references public.productos (id),
  precio_anterior  numeric(10, 2) not null,
  precio_nuevo     numeric(10, 2) not null,
  creado_en        timestamptz not null default now(),
  creado_por       uuid references public.usuarios (id) default privado.actor()
);
create index historial_precios_producto_idx on public.historial_precios (producto_id, creado_en desc);

-- -----------------------------------------------------------------------------
-- Salón
-- -----------------------------------------------------------------------------
create table public.mesas (
  id            uuid primary key default gen_random_uuid(),
  sucursal_id   uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  nombre        text not null check (length(trim(nombre)) > 0),
  orden         integer not null default 0,
  activa        boolean not null default true,
  estado        public.estado_mesa not null default 'disponible',
  unida_a       uuid references public.mesas (id),       -- mesa principal cuando están unidas
  eliminada_en  timestamptz,
  eliminada_por uuid references public.usuarios (id),
  creado_en     timestamptz not null default now(),
  creado_por    uuid references public.usuarios (id) default privado.actor(),
  constraint mesas_eliminada check ((eliminada_en is null) = (eliminada_por is null)),
  constraint mesas_no_unida_a_si_misma check (unida_a is null or unida_a <> id)
);
create unique index mesas_nombre_unico on public.mesas (sucursal_id, lower(nombre)) where eliminada_en is null;

-- Las siete mesas iniciales (editables por el propietario).
insert into public.mesas (nombre, orden)
select 'Mesa ' || n, n from generate_series(1, 7) as n;

create table public.uniones_mesas (
  id           uuid primary key default gen_random_uuid(),
  sucursal_id  uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  operacion    text not null check (operacion in ('union', 'separacion')),
  mesa_ids     uuid[] not null check (cardinality(mesa_ids) >= 2),
  cuenta_id    uuid,   -- referencia agregada abajo
  creado_en    timestamptz not null default now(),
  creado_por   uuid references public.usuarios (id) default privado.actor()
);

-- -----------------------------------------------------------------------------
-- Caja (va antes de cuentas porque los cobros apuntan al turno)
-- -----------------------------------------------------------------------------
create table public.turnos_caja (
  id                 uuid primary key default gen_random_uuid(),
  sucursal_id        uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  cajero_id          uuid not null references public.usuarios (id),
  estado             public.estado_turno not null default 'abierto',
  fondo_inicial      numeric(12, 2) not null check (fondo_inicial >= 0),
  abierto_en         timestamptz not null default now(),
  cerrado_en         timestamptz,
  efectivo_esperado  numeric(12, 2),
  efectivo_contado   numeric(12, 2) check (efectivo_contado >= 0),
  diferencia         numeric(12, 2),
  resumen            jsonb,          -- foto del corte: totales por método, propinas, movimientos
  aprobado_en        timestamptz,
  aprobado_por       uuid references public.usuarios (id),
  creado_en          timestamptz not null default now(),
  creado_por         uuid references public.usuarios (id) default privado.actor(),
  constraint turnos_cerrado check (
    estado = 'abierto' or (cerrado_en is not null and efectivo_esperado is not null
                           and efectivo_contado is not null and diferencia is not null)),
  constraint turnos_aprobado check ((estado = 'aprobado') = (aprobado_en is not null and aprobado_por is not null))
);
-- Una sola caja física: un turno abierto a la vez por sucursal.
create unique index turnos_un_abierto on public.turnos_caja (sucursal_id) where estado = 'abierto';

create table public.movimientos_efectivo (
  id           uuid primary key default gen_random_uuid(),
  sucursal_id  uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  turno_id     uuid not null references public.turnos_caja (id),
  tipo         public.tipo_movimiento not null,
  importe      numeric(12, 2) not null check (importe > 0),
  motivo       text not null check (length(trim(motivo)) > 0),
  creado_en    timestamptz not null default now(),
  creado_por   uuid references public.usuarios (id) default privado.actor()
);
create index movimientos_turno_idx on public.movimientos_efectivo (turno_id);

-- -----------------------------------------------------------------------------
-- Ventas
-- -----------------------------------------------------------------------------
create table public.cuentas (
  id                   uuid primary key default gen_random_uuid(),
  sucursal_id          uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  folio                bigint generated always as identity unique,   -- número de pedido
  tipo                 public.tipo_cuenta not null,
  mesa_id              uuid references public.mesas (id),
  estado               public.estado_cuenta not null default 'abierta',
  mesero_id            uuid references public.usuarios (id),
  cajero_id            uuid references public.usuarios (id),
  turno_id             uuid references public.turnos_caja (id),
  abierta_en           timestamptz not null default now(),
  cuenta_pedida_en     timestamptz,
  cobrada_en           timestamptz,
  -- Importes fijados al cobrar (copia; los precios posteriores no los alteran).
  subtotal             numeric(12, 2),
  impuestos            numeric(12, 2),
  total                numeric(12, 2),
  cancelada_en         timestamptz,
  cancelada_por        uuid references public.usuarios (id),
  cancelacion_motivo   text,
  autorizacion_id      uuid,           -- referencia agregada en 4/5
  cobro_anulado_en     timestamptz,    -- última vez que se anuló su cobro (vuelve a por cobrar)
  -- Preparación para facturar (sin uso por ahora).
  datos_fiscales       jsonb,
  estado_facturacion   public.estado_facturacion not null default 'no_facturada',
  creado_en            timestamptz not null default now(),
  creado_por           uuid references public.usuarios (id) default privado.actor(),
  constraint cuentas_mesa check ((tipo = 'mesa') = (mesa_id is not null)),
  -- Cancelar una cuenta exige motivo, usuario y la autorización del otro propietario.
  constraint cuentas_cancelada check (
    (estado = 'cancelada') = (cancelada_en is not null)
    and (cancelada_en is null or (cancelada_por is not null and autorizacion_id is not null
                                  and length(trim(cancelacion_motivo)) > 0))),
  constraint cuentas_cobrada check (
    estado <> 'cobrada' or (cobrada_en is not null and cajero_id is not null and total is not null))
);
-- Una mesa no tiene dos cuentas abiertas a la vez. Una cuenta cuyo cobro se
-- anuló vuelve a "por cobrar" en caja, pero ya no ocupa la mesa.
create unique index cuentas_una_abierta_por_mesa on public.cuentas (mesa_id)
  where estado in ('abierta', 'por_cobrar') and cobro_anulado_en is null;
create index cuentas_estado_idx on public.cuentas (sucursal_id, estado);
create index cuentas_turno_idx on public.cuentas (turno_id);

alter table public.uniones_mesas
  add constraint uniones_mesas_cuenta_fk foreign key (cuenta_id) references public.cuentas (id);

-- Detalle por producto: qué se vendió, a qué precio y quién lo tomó (creado_por).
create table public.lineas_cuenta (
  id                  uuid primary key default gen_random_uuid(),
  sucursal_id         uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  cuenta_id           uuid not null references public.cuentas (id),
  producto_id         uuid not null references public.productos (id),
  nombre_producto     text not null,                       -- copia al momento de pedir
  precio_unitario     numeric(10, 2) not null check (precio_unitario >= 0),   -- copia
  tasa_iva            numeric(5, 4) not null check (tasa_iva between 0 and 1), -- copia
  cantidad            integer not null check (cantidad > 0),
  observacion         text,
  estado              public.estado_linea not null default 'activa',
  cancelada_en        timestamptz,
  cancelada_por       uuid references public.usuarios (id),
  cancelacion_motivo  text,
  autorizacion_id     uuid,           -- obligatoria si la cuenta ya estaba cobrada (4/5)
  creado_en           timestamptz not null default now(),
  creado_por          uuid references public.usuarios (id) default privado.actor(),
  constraint lineas_cancelada check (
    (estado = 'cancelada') = (cancelada_en is not null)
    and (cancelada_en is null or (cancelada_por is not null and length(trim(cancelacion_motivo)) > 0)))
);
create index lineas_cuenta_idx on public.lineas_cuenta (cuenta_id);
create index lineas_producto_idx on public.lineas_cuenta (producto_id, creado_en);

create table public.cobros_extra (
  id                  uuid primary key default gen_random_uuid(),
  sucursal_id         uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  cuenta_id           uuid not null references public.cuentas (id),
  concepto            text not null check (length(trim(concepto)) > 0),   -- comentario obligatorio
  importe             numeric(10, 2) not null check (importe > 0),
  tasa_iva            numeric(5, 4) not null default 0.16 check (tasa_iva between 0 and 1),
  estado              public.estado_linea not null default 'activa',
  cancelada_en        timestamptz,
  cancelada_por       uuid references public.usuarios (id),
  cancelacion_motivo  text,
  autorizacion_id     uuid,
  creado_en           timestamptz not null default now(),
  creado_por          uuid references public.usuarios (id) default privado.actor(),
  constraint cobros_extra_cancelado check (
    (estado = 'cancelada') = (cancelada_en is not null)
    and (cancelada_en is null or (cancelada_por is not null and length(trim(cancelacion_motivo)) > 0)))
);
create index cobros_extra_cuenta_idx on public.cobros_extra (cuenta_id);

create table public.comandas (
  id           uuid primary key default gen_random_uuid(),
  sucursal_id  uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  cuenta_id    uuid not null references public.cuentas (id),
  numero       integer not null check (numero > 0),   -- 1 = primera, 2+ = adicionales/avisos
  tipo         public.tipo_comanda not null,
  creado_en    timestamptz not null default now(),
  creado_por   uuid references public.usuarios (id) default privado.actor(),
  unique (cuenta_id, numero)
);

create table public.comanda_lineas (
  id           uuid primary key default gen_random_uuid(),
  sucursal_id  uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  comanda_id   uuid not null references public.comandas (id),
  linea_id     uuid not null references public.lineas_cuenta (id),
  cantidad     integer not null check (cantidad > 0),
  leyenda      text check (leyenda in ('CANCELADO', 'MODIFICADO')),
  creado_en    timestamptz not null default now(),
  creado_por   uuid references public.usuarios (id) default privado.actor()
);
create index comanda_lineas_comanda_idx on public.comanda_lineas (comanda_id);

-- Pagos: varias líneas por cuenta (pago combinado). La propina va aparte.
create table public.pagos (
  id                uuid primary key default gen_random_uuid(),
  sucursal_id       uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  cuenta_id         uuid not null references public.cuentas (id),
  turno_id          uuid not null references public.turnos_caja (id),
  metodo            public.metodo_pago not null,
  importe           numeric(12, 2) not null check (importe > 0),
  estado            public.estado_pago not null default 'vigente',
  anulado_en        timestamptz,
  anulado_por       uuid references public.usuarios (id),
  anulacion_motivo  text,
  autorizacion_id   uuid,
  creado_en         timestamptz not null default now(),
  creado_por        uuid references public.usuarios (id) default privado.actor(),
  -- Anular un cobro siempre lleva la autorización del otro propietario.
  constraint pagos_anulado check (
    (estado = 'anulado') = (anulado_en is not null)
    and (anulado_en is null or (anulado_por is not null and autorizacion_id is not null
                                and length(trim(anulacion_motivo)) > 0)))
);
create index pagos_cuenta_idx on public.pagos (cuenta_id);
create index pagos_turno_idx on public.pagos (turno_id);

-- Propinas: no son venta ni ingreso; se muestran aparte en el corte.
create table public.propinas (
  id                uuid primary key default gen_random_uuid(),
  sucursal_id       uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  cuenta_id         uuid not null references public.cuentas (id),
  turno_id          uuid not null references public.turnos_caja (id),
  metodo            public.metodo_pago not null check (metodo in ('efectivo', 'tarjeta')),
  importe           numeric(12, 2) not null check (importe > 0),
  estado            public.estado_pago not null default 'vigente',
  anulado_en        timestamptz,
  anulado_por       uuid references public.usuarios (id),
  anulacion_motivo  text,
  autorizacion_id   uuid,
  creado_en         timestamptz not null default now(),
  creado_por        uuid references public.usuarios (id) default privado.actor(),
  constraint propinas_anulada check (
    (estado = 'anulado') = (anulado_en is not null)
    and (anulado_en is null or (anulado_por is not null and autorizacion_id is not null
                                and length(trim(anulacion_motivo)) > 0)))
);
create index propinas_turno_idx on public.propinas (turno_id);

-- -----------------------------------------------------------------------------
-- Cola de impresión. El id es el identificador único que evita duplicados.
-- -----------------------------------------------------------------------------
create table public.trabajos_impresion (
  id              uuid primary key default gen_random_uuid(),
  sucursal_id     uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  documento       public.tipo_documento not null,
  impresora       public.impresora not null,
  comanda_id      uuid references public.comandas (id),
  cuenta_id       uuid references public.cuentas (id),
  turno_id        uuid references public.turnos_caja (id),
  contenido       jsonb not null,
  estado          public.estado_impresion not null default 'pendiente',
  intentos        integer not null default 0 check (intentos >= 0),
  ultimo_error    text,
  reimpresion_de  uuid references public.trabajos_impresion (id),   -- reimpresión manual
  actualizado_en  timestamptz not null default now(),
  impreso_en      timestamptz,
  creado_en       timestamptz not null default now(),
  creado_por      uuid references public.usuarios (id) default privado.actor(),
  -- Las comandas solo van a cocina; tickets y cortes, a caja.
  constraint trabajos_impresora check ((documento = 'comanda') = (impresora = 'cocina')),
  constraint trabajos_comanda check (documento <> 'comanda' or comanda_id is not null)
);
create index trabajos_pendientes_idx on public.trabajos_impresion (sucursal_id, creado_en)
  where estado in ('pendiente', 'error');
create index trabajos_cuenta_idx on public.trabajos_impresion (cuenta_id);

-- -----------------------------------------------------------------------------
-- Gastos (exclusivo del propietario)
-- -----------------------------------------------------------------------------
create table public.gastos (
  id                uuid primary key default gen_random_uuid(),
  sucursal_id       uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  categoria         public.categoria_gasto not null,
  concepto          text not null check (length(trim(concepto)) > 0),
  monto             numeric(12, 2) not null check (monto > 0),
  fecha             date not null default current_date,
  estado            public.estado_pago not null default 'vigente',
  anulado_en        timestamptz,
  anulado_por       uuid references public.usuarios (id),
  anulacion_motivo  text,
  creado_en         timestamptz not null default now(),
  creado_por        uuid references public.usuarios (id) default privado.actor(),
  constraint gastos_anulado check (
    (estado = 'anulado') = (anulado_en is not null)
    and (anulado_en is null or (anulado_por is not null and length(trim(anulacion_motivo)) > 0)))
);
create index gastos_fecha_idx on public.gastos (sucursal_id, fecha);

create table public.gasto_productos (
  id           uuid primary key default gen_random_uuid(),
  sucursal_id  uuid not null default '00000000-0000-0000-0000-000000000001' references public.sucursales (id),
  gasto_id     uuid not null references public.gastos (id),
  producto     text not null check (length(trim(producto)) > 0),
  cantidad     numeric(12, 3) not null check (cantidad > 0),
  costo        numeric(12, 2) not null check (costo >= 0),
  creado_en    timestamptz not null default now(),
  creado_por   uuid references public.usuarios (id) default privado.actor()
);
create index gasto_productos_gasto_idx on public.gasto_productos (gasto_id);
create index gasto_productos_producto_idx on public.gasto_productos (lower(producto));

-- -----------------------------------------------------------------------------
-- Reglas propias de algunas tablas
-- -----------------------------------------------------------------------------

-- Cada cambio de precio queda en el historial.
create function privado.registrar_cambio_precio() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.precio is distinct from old.precio then
    insert into public.historial_precios (sucursal_id, producto_id, precio_anterior, precio_nuevo)
    values (new.sucursal_id, new.id, old.precio, new.precio);
  end if;
  return null;
end
$$;
create trigger productos_historial_precio after update of precio on public.productos
for each row execute function privado.registrar_cambio_precio();

-- Una mesa con cuenta abierta no se desactiva ni se elimina.
create function privado.validar_mesa() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if ((old.activa and not new.activa) or (old.eliminada_en is null and new.eliminada_en is not null))
     and exists (select 1 from public.cuentas c
                 where c.mesa_id = new.id and c.estado in ('abierta', 'por_cobrar')) then
    raise exception '% tiene una cuenta abierta. No se puede desactivar ni eliminar.', old.nombre;
  end if;
  return new;
end
$$;
create trigger mesas_validar before update on public.mesas
for each row execute function privado.validar_mesa();

-- Un producto de una cuenta ya cobrada solo se cancela con autorización.
create function privado.validar_cancelacion_linea() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.estado = 'cancelada' and old.estado <> 'cancelada' and new.autorizacion_id is null
     and exists (select 1 from public.cuentas c where c.id = new.cuenta_id and c.estado = 'cobrada') then
    raise exception 'La cuenta ya está cobrada: quitar este concepto requiere la autorización del otro propietario'
      using errcode = '42501';
  end if;
  return new;
end
$$;
create trigger lineas_validar_cancelacion before update on public.lineas_cuenta
for each row execute function privado.validar_cancelacion_linea();
create trigger cobros_extra_validar_cancelacion before update on public.cobros_extra
for each row execute function privado.validar_cancelacion_linea();

-- -----------------------------------------------------------------------------
-- Columnas que no cambian y sellos de cancelación / anulación
-- -----------------------------------------------------------------------------
create trigger categorias_inmutables before update on public.categorias for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'creado_en', 'creado_por');
create trigger categorias_sello before update on public.categorias for each row
  execute function privado.sellar_columnas('eliminada_en', 'eliminada_por');

create trigger productos_inmutables before update on public.productos for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'creado_en', 'creado_por');
create trigger productos_sello before update on public.productos for each row
  execute function privado.sellar_columnas('eliminado_en', 'eliminado_por');

create trigger mesas_inmutables before update on public.mesas for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'creado_en', 'creado_por');
create trigger mesas_sello before update on public.mesas for each row
  execute function privado.sellar_columnas('eliminada_en', 'eliminada_por');

create trigger cuentas_inmutables before update on public.cuentas for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'folio', 'tipo', 'abierta_en',
                                             'creado_en', 'creado_por');
create trigger cuentas_sello before update on public.cuentas for each row
  execute function privado.sellar_columnas('cancelada_en', 'cancelada_por', 'cancelacion_motivo', 'autorizacion_id');

create trigger lineas_inmutables before update on public.lineas_cuenta for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'cuenta_id', 'producto_id', 'nombre_producto',
                                             'precio_unitario', 'tasa_iva', 'cantidad', 'observacion',
                                             'creado_en', 'creado_por');
create trigger lineas_sello before update on public.lineas_cuenta for each row
  execute function privado.sellar_columnas('cancelada_en', 'cancelada_por', 'cancelacion_motivo', 'autorizacion_id');

create trigger cobros_extra_inmutables before update on public.cobros_extra for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'cuenta_id', 'concepto', 'importe',
                                             'tasa_iva', 'creado_en', 'creado_por');
create trigger cobros_extra_sello before update on public.cobros_extra for each row
  execute function privado.sellar_columnas('cancelada_en', 'cancelada_por', 'cancelacion_motivo', 'autorizacion_id');

create trigger pagos_inmutables before update on public.pagos for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'cuenta_id', 'turno_id', 'metodo', 'importe',
                                             'creado_en', 'creado_por');
create trigger pagos_sello before update on public.pagos for each row
  execute function privado.sellar_columnas('anulado_en', 'anulado_por', 'anulacion_motivo', 'autorizacion_id');

create trigger propinas_inmutables before update on public.propinas for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'cuenta_id', 'turno_id', 'metodo', 'importe',
                                             'creado_en', 'creado_por');
create trigger propinas_sello before update on public.propinas for each row
  execute function privado.sellar_columnas('anulado_en', 'anulado_por', 'anulacion_motivo', 'autorizacion_id');

create trigger gastos_inmutables before update on public.gastos for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'categoria', 'concepto', 'monto', 'fecha',
                                             'creado_en', 'creado_por');
create trigger gastos_sello before update on public.gastos for each row
  execute function privado.sellar_columnas('anulado_en', 'anulado_por', 'anulacion_motivo');

create trigger turnos_inmutables before update on public.turnos_caja for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'cajero_id', 'fondo_inicial', 'abierto_en',
                                             'creado_en', 'creado_por');

create trigger trabajos_inmutables before update on public.trabajos_impresion for each row
  execute function privado.proteger_columnas('id', 'sucursal_id', 'documento', 'impresora', 'comanda_id',
                                             'cuenta_id', 'turno_id', 'contenido', 'reimpresion_de',
                                             'creado_en', 'creado_por');

-- Registros que nunca se modifican una vez creados.
create trigger historial_precios_sin_cambios before update on public.historial_precios
  for each row execute function privado.prohibir_cambio();
create trigger uniones_mesas_sin_cambios before update on public.uniones_mesas
  for each row execute function privado.prohibir_cambio();
create trigger movimientos_sin_cambios before update on public.movimientos_efectivo
  for each row execute function privado.prohibir_cambio();
create trigger comandas_sin_cambios before update on public.comandas
  for each row execute function privado.prohibir_cambio();
create trigger comanda_lineas_sin_cambios before update on public.comanda_lineas
  for each row execute function privado.prohibir_cambio();
create trigger gasto_productos_sin_cambios before update on public.gasto_productos
  for each row execute function privado.prohibir_cambio();

-- -----------------------------------------------------------------------------
-- Sin borrado en ninguna tabla y auditoría de altas y cambios
-- -----------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'categorias', 'productos', 'historial_precios', 'mesas', 'uniones_mesas', 'turnos_caja',
    'movimientos_efectivo', 'cuentas', 'lineas_cuenta', 'cobros_extra', 'comandas', 'comanda_lineas',
    'pagos', 'propinas', 'trabajos_impresion', 'gastos', 'gasto_productos'
  ] loop
    execute format('create trigger %I before delete on public.%I for each row execute function privado.prohibir_borrado()',
                   t || '_sin_borrado', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function privado.prohibir_borrado()',
                   t || '_sin_vaciar', t);
  end loop;

  -- La cola de impresión cambia de estado muchas veces (pendiente → impreso);
  -- se audita su alta (incluidas las reimpresiones manuales), no cada cambio.
  foreach t in array array[
    'categorias', 'productos', 'mesas', 'uniones_mesas', 'turnos_caja', 'movimientos_efectivo',
    'cuentas', 'lineas_cuenta', 'cobros_extra', 'comandas', 'pagos', 'propinas', 'gastos', 'gasto_productos'
  ] loop
    execute format('create trigger %I after insert or update on public.%I for each row execute function privado.auditar_cambios()',
                   t || '_auditar', t);
  end loop;
end
$$;

create trigger trabajos_impresion_auditar after insert on public.trabajos_impresion
  for each row execute function privado.auditar_cambios();
