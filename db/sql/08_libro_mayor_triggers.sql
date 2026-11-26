-- ============================================================================
-- 08_libro_mayor_triggers.sql  ·  Etapa 2 (libro mayor y guardias) · parte 3/4
-- Propósito  : crea los triggers del libro mayor y los event triggers de DDL. Usan las funciones de 07.
--
--   El NOMBRE fija el orden de disparo (PostgreSQL ordena alfabéticamente los triggers del mismo evento):
--     transaccion  BEFORE INSERT : trg_transaccion_a_validar  ->  trg_transaccion_b_aplicar
--                  AFTER  INSERT : ct_transaccion_cuadre, ct_transaccion_cdt   (DIFERIDOS al COMMIT)
--                  BEFORE UPDATE/DELETE : trg_transaccion_inmutable      BEFORE TRUNCATE : trg_transaccion_truncate
--     cdt          AFTER INSERT/UPDATE : ct_cdt_inversion                (DIFERIDO)
--     cuenta, bolsillo, cdt, credito : BEFORE INSERT OR UPDATE : trg_zz_proteger_<tabla>  (corren ÚLTIMO)
--     cuenta       BEFORE DELETE : trg_cuenta_auditar_borrado
--     base         EVENT TRIGGER : evt_ddl_protegido (ALTER TABLE), evt_drop_protegido (DROP TRIGGER)
--
-- Dependencias : 01 a 07.
-- Ejecución    : como superusuario (los event triggers lo exigen). IDEMPOTENTE (CREATE OR REPLACE TRIGGER).
-- Verificar    : SELECT tgrelid::regclass AS tabla, tgname, tgenabled, tgdeferrable, tginitdeferred
--                  FROM pg_trigger WHERE NOT tgisinternal ORDER BY 1, 2;
-- ============================================================================

BEGIN;

-- (Los CONSTRAINT TRIGGER no admiten CREATE OR REPLACE: se hace DROP TRIGGER IF EXISTS + CREATE, dentro de la transaccion.)
-- Libro mayor: escritura ---------------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_transaccion_a_validar
  BEFORE INSERT ON public.transaccion
  FOR EACH ROW EXECUTE FUNCTION public.trg_transaccion_a_validar();

CREATE OR REPLACE TRIGGER trg_transaccion_b_aplicar
  BEFORE INSERT ON public.transaccion
  FOR EACH ROW EXECUTE FUNCTION public.trg_transaccion_b_aplicar();

DROP TRIGGER IF EXISTS ct_transaccion_cuadre ON public.transaccion;
CREATE CONSTRAINT TRIGGER ct_transaccion_cuadre
  AFTER INSERT ON public.transaccion
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.ct_transaccion_cuadre();

DROP TRIGGER IF EXISTS ct_transaccion_cdt ON public.transaccion;
CREATE CONSTRAINT TRIGGER ct_transaccion_cdt
  AFTER INSERT ON public.transaccion
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW WHEN (NEW.cdt_id IS NOT NULL)
  EXECUTE FUNCTION public.ct_cdt_inversion();

DROP TRIGGER IF EXISTS ct_cdt_inversion ON public.cdt;
CREATE CONSTRAINT TRIGGER ct_cdt_inversion
  AFTER INSERT OR UPDATE OF estado, generado_acumulado ON public.cdt
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.ct_cdt_inversion();

-- Libro mayor: inmutabilidad ------------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_transaccion_inmutable
  BEFORE UPDATE OR DELETE ON public.transaccion
  FOR EACH ROW EXECUTE FUNCTION public.trg_transaccion_inmutable();

CREATE OR REPLACE TRIGGER trg_transaccion_truncate
  BEFORE TRUNCATE ON public.transaccion
  FOR EACH STATEMENT EXECUTE FUNCTION public.trg_transaccion_truncate();

-- Guardias de acumuladores (corren último: el prefijo trg_zz_ los ordena al final) ----------------------------
CREATE OR REPLACE TRIGGER trg_zz_proteger_cuenta
  BEFORE INSERT OR UPDATE ON public.cuenta
  FOR EACH ROW EXECUTE FUNCTION public.trg_zz_proteger_cuenta();

CREATE OR REPLACE TRIGGER trg_zz_proteger_bolsillo
  BEFORE INSERT OR UPDATE ON public.bolsillo
  FOR EACH ROW EXECUTE FUNCTION public.trg_zz_proteger_bolsillo();

CREATE OR REPLACE TRIGGER trg_zz_proteger_cdt
  BEFORE INSERT OR UPDATE ON public.cdt
  FOR EACH ROW EXECUTE FUNCTION public.trg_zz_proteger_cdt();

CREATE OR REPLACE TRIGGER trg_zz_proteger_credito
  BEFORE INSERT OR UPDATE ON public.credito
  FOR EACH ROW EXECUTE FUNCTION public.trg_zz_proteger_credito();

-- Auditoría del borrado de cuentas ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_cuenta_auditar_borrado
  BEFORE DELETE ON public.cuenta
  FOR EACH ROW EXECUTE FUNCTION public.trg_cuenta_auditar_borrado();

-- Event triggers de DDL (no los afecta session_replication_role) -------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'evt_ddl_protegido') THEN
    CREATE EVENT TRIGGER evt_ddl_protegido ON ddl_command_end WHEN TAG IN ('ALTER TABLE')
      EXECUTE FUNCTION public.trg_evento_ddl();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'evt_drop_protegido') THEN
    CREATE EVENT TRIGGER evt_drop_protegido ON sql_drop WHEN TAG IN ('DROP TRIGGER')
      EXECUTE FUNCTION public.trg_evento_drop();
  END IF;
END
$$;
ALTER EVENT TRIGGER evt_ddl_protegido ENABLE;
ALTER EVENT TRIGGER evt_drop_protegido ENABLE;
COMMENT ON EVENT TRIGGER evt_ddl_protegido IS 'E2. Registra en audit.evento cada ALTER TABLE (incluye DISABLE TRIGGER) sobre cuenta, bolsillo, cdt, credito y transaccion.';
COMMENT ON EVENT TRIGGER evt_drop_protegido IS 'E2. Registra en audit.evento cada DROP TRIGGER sobre las tablas del libro y sus acumuladores.';

-- Documentación de cada trigger (visible en pgAdmin: Triggers > Comments) ---------------------------------
COMMENT ON TRIGGER trg_transaccion_a_validar ON public.transaccion IS 'E2. BEFORE INSERT (1/2): fuerza registrado_en/tx_id, descarta saldos del llamador, sella el grupo, comprueba propiedad de los productos.';
COMMENT ON TRIGGER trg_transaccion_b_aplicar ON public.transaccion IS 'E2. BEFORE INSERT (2/2): función de banco_ledger; único camino que mueve los acumuladores; fija saldo previo/posterior.';
COMMENT ON TRIGGER ct_transaccion_cuadre ON public.transaccion IS 'E2. DIFERIDO (COMMIT): partida doble ΣD=ΣC, plantilla, sellado, misma fecha, dinero entre cuentas solo en par ENVIO/RECIBO.';
COMMENT ON TRIGGER ct_transaccion_cdt ON public.transaccion IS 'E2. DIFERIDO: invariantes del CDT cuando una pata lo referencia.';
COMMENT ON TRIGGER ct_cdt_inversion ON public.cdt IS 'E2. DIFERIDO: inversión del CDT en el libro = monto+generado (ACTIVO) o 0 (CERRADO); generado = suma de INTERES_CDT.';
COMMENT ON TRIGGER trg_transaccion_inmutable ON public.transaccion IS 'E2. UPDATE siempre rechazado; DELETE solo por cascada de cuenta (la cuenta ya no existe).';
COMMENT ON TRIGGER trg_transaccion_truncate ON public.transaccion IS 'E2. TRUNCATE siempre rechazado.';
COMMENT ON TRIGGER trg_zz_proteger_cuenta ON public.cuenta IS 'E2. Guardia (último BEFORE): balance 0 al crear; solo el libro lo modifica; columnas inmutables.';
COMMENT ON TRIGGER trg_zz_proteger_bolsillo ON public.bolsillo IS 'E2. Guardia (último BEFORE): balance 0 al crear; solo el libro lo modifica; columnas inmutables.';
COMMENT ON TRIGGER trg_zz_proteger_cdt ON public.cdt IS 'E2. Guardia (último BEFORE): generado_acumulado 0 al crear; solo el libro lo modifica; campos contractuales inmutables; ACTIVO->CERRADO.';
COMMENT ON TRIGGER trg_zz_proteger_credito ON public.credito IS 'E2. Guardia (último BEFORE): capital_pendiente 0 al crear; solo el libro lo modifica; campos contractuales inmutables; ACTIVO->PAGADO.';
COMMENT ON TRIGGER trg_cuenta_auditar_borrado ON public.cuenta IS 'E2. Antes de borrar una cuenta registra CUENTA_BORRADA en audit.evento con lo que se destruye.';

COMMIT;
