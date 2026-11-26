-- ============================================================================
-- 06_libro_mayor_estructura.sql  ·  Etapa 2 (libro mayor y guardias) · parte 1/4
-- Propósito  : (a) dos columnas de trazabilidad en transaccion y (b) los permisos de E2 sobre los
--              acumuladores y el libro. NO crea funciones ni triggers (eso es 07 y 08).
--
--   transaccion.registrado_en  hora REAL de registro (clock_timestamp), distinta de "fecha" (hora de
--                              negocio, que el reloj manual puede adelantar). El trigger la fuerza.
--   transaccion.tx_id          xid8 de la transacción de BD que escribió la pata. Todas las patas de un
--                              grupo deben compartirlo (el grupo se "sella" al confirmarse).
--
--   Permisos (el script CONVERGE: reaplicarlo corrige desvíos):
--     banco_owner pierde UPDATE de tabla sobre cuenta, bolsillo, cdt, credito (acumuladores) y
--       UPDATE de tabla + TRUNCATE sobre transaccion. Conserva INSERT/SELECT/DELETE (DELETE lo exige la
--       cascada de borrado de cuenta). Recibe UPDATE solo de columnas que NO son acumuladores:
--         cuenta(creado_en)*  bolsillo(nombre, ultimo_cobro)  cdt(ultimo_cobro, estado, definicion_id**)
--         credito(descuento_automatico, mora_acumulada, fecha_interes, estado)
--         transaccion(registrado_en)***
--       *  columna inocua: PostgreSQL comprueba las FK con SELECT ... FOR KEY SHARE, que exige algún
--          privilegio UPDATE sobre la tabla padre y corre con los privilegios de su dueño. Sin esta
--          concesión, insertar en una tabla hija falla con "permission denied". El guardia (08) impide
--          modificarla igualmente.
--       ** la FK ON DELETE SET NULL de cdt.definicion_id actualiza la columna como dueño de cdt.
--       *** igual que *, pero en el lado hijo: al borrar un bolsillo/CDT/credito la FK NO ACTION de
--          transaccion se comprueba con SELECT ... FOR KEY SHARE sobre transaccion como su dueño. Esa
--          columna es inocua: el trigger trg_transaccion_inmutable rechaza TODO UPDATE del libro.
--     mora_acumulada sigue editable por el dueño hasta que el equipo decida D7 (no se adelanta nada).
-- Dependencias : 01 a 05.
-- Ejecución    : como superusuario (pgAdmin o "ctl apply"). IDEMPOTENTE y transaccional.
-- Verificar    : SELECT column_name, data_type FROM information_schema.columns
--                 WHERE table_name = 'transaccion' AND column_name IN ('registrado_en','tx_id');
--                SELECT * FROM public.v_integridad_defensas WHERE NOT ok;   -- (después de 09)
-- ============================================================================

BEGIN;

-- 1) Columnas de trazabilidad (ALTER como dueño; IF NOT EXISTS lo hace idempotente) --------------------
SET LOCAL ROLE banco_owner;

ALTER TABLE public.transaccion ADD COLUMN IF NOT EXISTS registrado_en timestamptz NOT NULL DEFAULT clock_timestamp();
ALTER TABLE public.transaccion ADD COLUMN IF NOT EXISTS tx_id         xid8        NOT NULL DEFAULT pg_current_xact_id();

COMMENT ON COLUMN public.transaccion.registrado_en IS
  'Hora REAL en que se registró la pata (clock_timestamp). Distinta de fecha (hora de negocio, ajustable por el reloj del banco). La fuerza el trigger: el llamador no puede falsearla.';
COMMENT ON COLUMN public.transaccion.tx_id IS
  'Identificador (xid8) de la transacción de base de datos que escribió la pata. Todas las patas de un grupo lo comparten: así un grupo no puede ampliarse después de confirmado. La fuerza el trigger.';

RESET ROLE;

-- 2) Permisos de E2 (como superusuario: equivale a REVOKE/GRANT del dueño) ----------------------------
-- Se parte de cero para estos privilegios del dueño y se concede solo lo debido.
REVOKE UPDATE ON public.cuenta, public.bolsillo, public.cdt, public.credito FROM banco_owner;
REVOKE UPDATE, TRUNCATE ON public.transaccion FROM banco_owner;

GRANT UPDATE (creado_en)                                                         ON public.cuenta   TO banco_owner;
GRANT UPDATE (nombre, ultimo_cobro)                                              ON public.bolsillo TO banco_owner;
GRANT UPDATE (ultimo_cobro, estado, definicion_id)                               ON public.cdt      TO banco_owner;
GRANT UPDATE (descuento_automatico, mora_acumulada, fecha_interes, estado)       ON public.credito  TO banco_owner;
GRANT UPDATE (registrado_en)                                                     ON public.transaccion TO banco_owner;   -- solo para las FK (ver ***)

COMMIT;
