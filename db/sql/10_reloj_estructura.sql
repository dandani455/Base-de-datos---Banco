-- ============================================================================
-- 10_reloj_estructura.sql  ·  Etapa 3 (reloj bancario) · parte 1/3
-- Propósito  : estructura y permisos del reloj del banco. NO crea funciones ni triggers (eso es 11 y 12).
--
--   Reloj (decisión D4 = opción A, aprobada por el equipo):
--     * usar_fecha_real = true  -> el "hoy" del banco es la fecha actual de America/Bogota. Sin desfase: no se
--                                  guarda ninguna fecha (fecha_sistema queda NULL: el contrato así lo devuelve).
--     * usar_fecha_real = false -> el "hoy" es fecha_sistema, que SOLO puede adelantarse.
--     * Pasar a modo real siempre se permite, aunque la fecha real sea anterior a la simulada: es una salida
--       explícita de la simulación. La simulación NO es reversible en términos contables: las operaciones
--       hechas quedan en el historial (aunque algunas queden fechadas "en el futuro" del reloj actual).
--
--   Cambios sobre la tabla reloj (E1):
--     * CHECK ck_reloj_fecha_rango: fecha_sistema entre 2000-01-01 y 2100-12-31 (D-E3-8). Evita fechas absurdas
--       que romperían la aritmética de fechas; cubre de sobra "+30 años".
--     * banco_owner pierde UPDATE de tabla y recibe UPDATE solo de (usar_fecha_real, fecha_sistema), mismo patrón
--       que E2. (La tabla no tiene otra columna editable; id es inmutable.)
-- Dependencias : 01 a 09.   Ejecución: como superusuario (pgAdmin o "ctl apply"). IDEMPOTENTE y transaccional.
-- Verificar    : SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.reloj'::regclass;
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.reloj'::regclass AND conname = 'ck_reloj_fecha_rango') THEN
    ALTER TABLE public.reloj ADD CONSTRAINT ck_reloj_fecha_rango
      CHECK (fecha_sistema IS NULL OR fecha_sistema BETWEEN DATE '2000-01-01' AND DATE '2100-12-31');
  END IF;
END
$$;

-- (Los COMMENT de la tabla y de sus columnas viven en 03_schema.sql, junto al resto del diccionario de datos.)

RESET ROLE;

-- Permisos (como superusuario equivale a REVOKE/GRANT del dueño): el dueño solo edita las dos columnas del reloj.
REVOKE UPDATE ON public.reloj FROM banco_owner;
GRANT UPDATE (usar_fecha_real, fecha_sistema) ON public.reloj TO banco_owner;

COMMIT;
