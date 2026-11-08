-- Sistema La Merced · Nuevo documento de impresión: precuenta (cuenta informativa,
-- antes de cobrar). Va en su propia migración porque un valor nuevo de un tipo
-- enumerado no puede usarse en la misma operación en que se crea.
alter type public.tipo_documento add value if not exists 'precuenta';
