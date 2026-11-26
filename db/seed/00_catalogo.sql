-- ============================================================================
-- 00_catalogo.sql - Etapa 14 - Catalogo de CDT y de productos de credito (PROVISIONAL, D11 / D-E14-D1 del EQUIPO)
--
-- Es CONFIGURACION (no datos de demostracion): se puede cargar en cualquier banco, y es IDEMPOTENTE (upsert por nombre;
-- recargarlo restaura estos valores). El equipo cambia el catalogo editando SOLO este archivo (o con admin_set_tasa_*).
--
-- Fuentes y decisiones (D-E14-D1, aprobada como provisional):
--   * Creditos: reglas del SPEC §7.6 (nombres, rangos, plazos, tope de Libre inversion, tope y regla de edad de Inmuebles);
--     TASAS del mock (% E.A.): Libre inversion 23,9 / Vehiculo 18,9 / Educacion 15,4 / Inmuebles 14,1.
--   * CDT: 90, 180 y 360 dias con las tasas del mock (9,25 / 10 / 10,75 % E.A.) y minimo $100.000 (el sugerido por el contrato §4;
--     el mock dice 500.000 / 1M / 2M). El contrato admite cualquiera de los dos juegos de plazos.
--   * plazo_min_meses y monto_min de Libre inversion/Inmuebles: del mock (el spec dice «a voluntad»).
-- Ejecucion: como superusuario (ctl seed catalogo). Dependencias: db/sql/*.sql aplicados.
-- ============================================================================
BEGIN;

INSERT INTO public.cdt_definicion (nombre, plazo_dias, tasa_anual, monto_min) VALUES
  ('CDT 90 días',   90, 9.25,  100000),
  ('CDT 180 días', 180, 10.00, 100000),
  ('CDT 360 días', 360, 10.75, 100000)
ON CONFLICT (nombre) DO UPDATE
  SET plazo_dias = EXCLUDED.plazo_dias, tasa_anual = EXCLUDED.tasa_anual, monto_min = EXCLUDED.monto_min;

INSERT INTO public.credito_producto
  (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses, tope_absoluto, multiplicador_balance, aplica_regla_edad) VALUES
  ('Libre inversión', 'Dinero para lo que necesites, con cuotas fijas.',                  23.9,   1000000,    30000000,  6,  24,  30000000, NULL, false),
  ('Vehículo',        'Estrena carro o moto con tasas competitivas.',                     18.9,  50000000,   200000000, 12, 120, NULL,       NULL, false),
  ('Educación',       'Invierte en tu formación y la de tu familia.',                     15.4,   1000000,   100000000,  6, 240, NULL,       NULL, false),
  ('Inmuebles',       'Financia tu casa o apartamento a largo plazo.',                    14.1,  20000000,  2000000000, 60, 360, 2000000000, 100,  true)
ON CONFLICT (nombre) DO UPDATE
  SET descripcion = EXCLUDED.descripcion, tasa_anual = EXCLUDED.tasa_anual, monto_min = EXCLUDED.monto_min, monto_max = EXCLUDED.monto_max,
      plazo_min_meses = EXCLUDED.plazo_min_meses, plazo_max_meses = EXCLUDED.plazo_max_meses, tope_absoluto = EXCLUDED.tope_absoluto,
      multiplicador_balance = EXCLUDED.multiplicador_balance, aplica_regla_edad = EXCLUDED.aplica_regla_edad;

COMMIT;
