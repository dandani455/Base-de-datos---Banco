-- ============================================================================
-- 12_reloj_triggers.sql  ·  Etapa 3 (reloj bancario) · parte 3/3
-- Propósito  : triggers del reloj y la vista informativa v_reloj_estado. Usan las funciones de 11.
--
--   reloj  BEFORE UPDATE : trg_reloj_a_validar   en modo manual solo adelantar ("El reloj no puede retroceder");
--                                                pasar a modo real SIEMPRE permitido (fecha_sistema := NULL)
--          AFTER  UPDATE : trg_reloj_auditar     RELOJ_CAMBIO en audit.evento
--          BEFORE DELETE : trg_reloj_borrar      el registro único no se borra
--          BEFORE TRUNCATE: trg_reloj_truncate   la tabla no se vacía
--   (No hay trigger BEFORE INSERT: la PK y ck_reloj_fila_unica ya impiden una 2.ª fila y, como no se puede borrar la
--    fila, el INSERT ... ON CONFLICT DO NOTHING de 03_schema.sql sigue siendo un no-op idempotente.)
--
--   v_reloj_estado  vista informativa: hoy/ahora del banco, fecha real de Colombia y cuántas patas quedaron fechadas
--                   "en el futuro" del reloj actual (consecuencia esperada de volver a fecha real tras una simulación).
-- Dependencias : 01 a 11.   Ejecución: como superusuario, IDEMPOTENTE, transaccional.
-- Verificar    : SELECT tgname, tgenabled FROM pg_trigger WHERE tgrelid = 'public.reloj'::regclass AND NOT tgisinternal;
--                SELECT * FROM public.v_reloj_estado;
-- ============================================================================

BEGIN;

CREATE OR REPLACE TRIGGER trg_reloj_a_validar
  BEFORE UPDATE ON public.reloj
  FOR EACH ROW EXECUTE FUNCTION public.trg_reloj_a_validar();

CREATE OR REPLACE TRIGGER trg_reloj_auditar
  AFTER UPDATE ON public.reloj
  FOR EACH ROW EXECUTE FUNCTION public.trg_reloj_auditar();

CREATE OR REPLACE TRIGGER trg_reloj_borrar
  BEFORE DELETE ON public.reloj
  FOR EACH ROW EXECUTE FUNCTION public.trg_reloj_borrar();

CREATE OR REPLACE TRIGGER trg_reloj_truncate
  BEFORE TRUNCATE ON public.reloj
  FOR EACH STATEMENT EXECUTE FUNCTION public.trg_reloj_truncate();

COMMENT ON TRIGGER trg_reloj_a_validar ON public.reloj IS 'E3. BEFORE UPDATE: en modo manual solo adelantar (El reloj no puede retroceder; con el banco vacío se permite); modo real siempre permitido y deja fecha_sistema en NULL.';
COMMENT ON TRIGGER trg_reloj_auditar ON public.reloj IS 'E3. AFTER UPDATE: registra RELOJ_CAMBIO en audit.evento (estado y hoy del banco antes y después).';
COMMENT ON TRIGGER trg_reloj_borrar ON public.reloj IS 'E3. BEFORE DELETE: el registro único del reloj no se borra.';
COMMENT ON TRIGGER trg_reloj_truncate ON public.reloj IS 'E3. BEFORE TRUNCATE: la tabla del reloj no se vacía.';

-- ----------------------------------------------------------------------------
-- Vista informativa (dueño banco_owner; lectura para banco_lector y banco_dev). Usa hoy_banco()/ahora_banco(), que son
-- ejecutables por banco_lector (una vista ejecuta las funciones con los privilegios de QUIEN LA CONSULTA).
-- ----------------------------------------------------------------------------
SET LOCAL ROLE banco_owner;

CREATE OR REPLACE VIEW public.v_reloj_estado AS
SELECT r.usar_fecha_real,
       r.fecha_sistema,
       public.hoy_banco()                                       AS hoy_banco,
       public.ahora_banco()                                     AS ahora_banco,
       (now() AT TIME ZONE 'America/Bogota')::date              AS fecha_real_colombia,
       (SELECT count(*) = 0 FROM public.transaccion)            AS banco_vacio,
       (SELECT count(*) FROM public.transaccion t
         WHERE (t.fecha AT TIME ZONE 'America/Bogota')::date > public.hoy_banco()) AS patas_fechadas_en_el_futuro
  FROM public.reloj r WHERE r.id = 1;
COMMENT ON VIEW public.v_reloj_estado IS
  'E3. Estado del reloj: modo, fecha manual, hoy/ahora del banco, fecha real de Colombia, si el banco está vacío (permite mover el reloj hacia atrás) y cuántas patas están fechadas DESPUÉS del hoy actual (consecuencia esperada de volver a fecha real tras una simulación: el historial permanece; NO es un error).';

RESET ROLE;

GRANT SELECT ON public.v_reloj_estado TO banco_lector;

COMMIT;
