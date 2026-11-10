-- Etapa 9 · Un gasto fijo nuevo cuenta desde el mes en curso: si su día ya
-- pasó, el de este mes se registra al guardarlo.
create or replace function public.guardar_gasto_fijo(
  p_id uuid, p_categoria_id uuid, p_concepto text, p_monto numeric, p_dia integer,
  p_forma_pago public.forma_pago_gasto, p_desde date default null
) returns public.gastos_fijos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fila public.gastos_fijos;
begin
  perform privado.exigir_perfil('propietario');
  if not exists (select 1 from public.categorias_gasto where id = p_categoria_id and eliminado_en is null) then
    raise exception 'Elige la categoría del gasto';
  end if;
  if coalesce(length(trim(p_concepto)), 0) = 0 then
    raise exception 'Escribe el concepto (por ejemplo, "Renta del local")';
  end if;
  if p_monto is null or p_monto <= 0 then
    raise exception 'Escribe el monto';
  end if;
  if p_dia is null or p_dia not between 1 and 31 then
    raise exception 'Escribe el día del mes (1 a 31)';
  end if;
  if p_forma_pago is null or p_forma_pago = 'caja' then
    raise exception 'Un gasto fijo no se paga con el efectivo de la caja';
  end if;
  if p_id is null then
    perform privado.fijar_accion(format('Agregó el gasto fijo "%s": $%s cada mes, día %s', trim(p_concepto), round(p_monto, 2), p_dia));
    insert into public.gastos_fijos (sucursal_id, categoria_id, concepto, monto, dia, forma_pago, desde)
    values (privado.sucursal_del_actor(), p_categoria_id, trim(p_concepto), round(p_monto, 2), p_dia, p_forma_pago,
            coalesce(p_desde, date_trunc('month', privado.hoy())::date))
    returning * into v_fila;
  else
    -- Los meses ya registrados no cambian; el cambio cuenta para los siguientes.
    perform privado.fijar_accion(format('Cambió el gasto fijo "%s": $%s cada mes, día %s', trim(p_concepto), round(p_monto, 2), p_dia));
    update public.gastos_fijos set categoria_id = p_categoria_id, concepto = trim(p_concepto), monto = round(p_monto, 2), dia = p_dia,
                                   forma_pago = p_forma_pago
     where id = p_id and eliminado_en is null returning * into v_fila;
    if not found then
      raise exception 'El gasto fijo no existe';
    end if;
  end if;
  perform privado.generar_gastos_fijos();
  return v_fila;
end
$$;
