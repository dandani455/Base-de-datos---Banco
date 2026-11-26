-- ============================================================================
-- 02_tipos_dominios.sql  ·  Etapa 1 (esquema y permisos)
-- Propósito  : dominios y tipos enumerados compartidos por las tablas de 03_schema.sql.
--
--   dinero               NUMERIC(18,2) acotado a |x| < 10^13: garantiza el transporte sin pérdida
--                        de centavos hasta Node.js (los importes caben en un double con 2 decimales).
--   porcentaje           NUMERIC(6,3) con 0 < x <= 100: tasas como porcentaje (12 = 12 %).
--   rol_usuario          CLIENTE | ADMIN                (discriminador de la especialización)
--   estado_usuario       ACTIVO | BLOQUEADO
--   estado_cdt           ACTIVO | CERRADO
--   estado_credito       ACTIVO | PAGADO
--   tipo_transaccion     los 17 tipos del contrato      (discriminador de la generalización)
--   contenedor_contable  CUENTA | BOLSILLO | CDT | CREDITO | RESULTADO   (qué acumulador afecta una pata)
--   sentido_asiento      E (aumenta) | S (disminuye)
--
-- Dependencias : 01_roles.sql (rol banco_owner).
-- Ejecución    : como superusuario (pgAdmin o "ctl apply"); los objetos quedan a nombre de
--                banco_owner. IDEMPOTENTE; transaccional (el rol se restablece solo al terminar).
-- Verificar    : SELECT typname, typtype, pg_get_userbyid(typowner) FROM pg_type
--                WHERE typnamespace = 'public'::regnamespace AND typtype IN ('d','e') ORDER BY 1;
-- ============================================================================

BEGIN;
SET LOCAL ROLE banco_owner;

DO $$
BEGIN
  -- Dominios ---------------------------------------------------------------
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typname = 'dinero') THEN
    CREATE DOMAIN public.dinero AS numeric(18,2)
      CONSTRAINT ck_dinero_rango CHECK (VALUE > -10000000000000 AND VALUE < 10000000000000);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typname = 'porcentaje') THEN
    CREATE DOMAIN public.porcentaje AS numeric(6,3)
      CONSTRAINT ck_porcentaje_rango CHECK (VALUE > 0 AND VALUE <= 100);
  END IF;

  -- Enumerados ---------------------------------------------------------------
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typname = 'rol_usuario') THEN
    CREATE TYPE public.rol_usuario AS ENUM ('CLIENTE', 'ADMIN');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typname = 'estado_usuario') THEN
    CREATE TYPE public.estado_usuario AS ENUM ('ACTIVO', 'BLOQUEADO');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typname = 'estado_cdt') THEN
    CREATE TYPE public.estado_cdt AS ENUM ('ACTIVO', 'CERRADO');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typname = 'estado_credito') THEN
    CREATE TYPE public.estado_credito AS ENUM ('ACTIVO', 'PAGADO');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typname = 'tipo_transaccion') THEN
    CREATE TYPE public.tipo_transaccion AS ENUM (
      'DEPOSITO_BANCO', 'ENVIO', 'RECIBO',
      'BOLSO_INGRESO', 'BOLSO_RETIRO', 'BOLSO_MOVIMIENTO',
      'CDT_CREACION', 'CDT_VENCIMIENTO', 'INTERES_CDT', 'INTERES_BOLSO',
      'CREDITO_DESEMBOLSO', 'CREDITO_CUOTA', 'CREDITO_ABONO', 'CREDITO_MORA',
      'BONO_REFERIDO', 'INGRESO_SIMULADO', 'AJUSTE_ADMIN');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typname = 'contenedor_contable') THEN
    CREATE TYPE public.contenedor_contable AS ENUM ('CUENTA', 'BOLSILLO', 'CDT', 'CREDITO', 'RESULTADO');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typname = 'sentido_asiento') THEN
    CREATE TYPE public.sentido_asiento AS ENUM ('E', 'S');
  END IF;
END
$$;

-- Documentación (COMMENT ON es idempotente) ---------------------------------------
COMMENT ON DOMAIN public.dinero IS
  'Importe en COP: NUMERIC(18,2) con |valor| < 10^13. El tope garantiza que los 2 decimales (centavos) sobreviven al transporte JSON hasta Node.js. El signo no va en el valor: lo dan sentido/lado del asiento.';
COMMENT ON DOMAIN public.porcentaje IS
  'Tasa como porcentaje (12 = 12 %): NUMERIC(6,3) con 0 < valor <= 100, formato del contrato front-BD.';
COMMENT ON TYPE public.rol_usuario IS 'Discriminador de la especialización USUARIO: CLIENTE (posee cuenta y productos) o ADMIN (opera el banco, sin cuenta).';
COMMENT ON TYPE public.estado_usuario IS 'Estado de acceso: ACTIVO o BLOQUEADO (un bloqueado no puede operar).';
COMMENT ON TYPE public.estado_cdt IS 'Ciclo de vida del CDT: ACTIVO hasta su vencimiento y luego CERRADO (historial).';
COMMENT ON TYPE public.estado_credito IS 'Ciclo de vida del crédito: ACTIVO mientras tenga deuda y luego PAGADO.';
COMMENT ON TYPE public.tipo_transaccion IS 'Discriminador de la generalización TRANSACCION: los 17 tipos del contrato (familias Transferencia, Bolsillo, CDT, Crédito y Banco).';
COMMENT ON TYPE public.contenedor_contable IS 'Acumulador que afecta una pata del libro mayor: CUENTA, BOLSILLO, CDT (derivado), CREDITO (pasivo) o RESULTADO (ingresos/gastos del cliente; derivado, no es una cuenta contable del banco).';
COMMENT ON TYPE public.sentido_asiento IS 'Dirección de una pata sobre el acumulador de su contenedor: E = aumenta, S = disminuye.';

COMMIT;
