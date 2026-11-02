-- Sistema La Merced · Sabores del Arizona para elegir con botón.
do $$
begin
  perform privado.fijar_accion('Instalación: sabores del Arizona');
  update public.productos set descripcion = null, opciones = array['Té verde', 'Mango', 'Kiwi', 'Sandía']
   where nombre = 'Arizona' and eliminado_en is null;
  perform privado.fijar_accion(null);
end
$$;
