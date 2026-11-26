-- ============================================================================
-- 19_creditos_calculo.sql  ·  Etapa 8 (créditos) · parte 1/2: cálculo e integridad del plan
-- Propósito  : la matemática del crédito (tasa mensual, plan francés, vencimientos, interés corriendo, patrimonio para topes) y la guardia de integridad
--              ct_credito_plan (capital_pendiente = Σ (capital_programado - capital_pagado) de las cuotas impagas). SIN tablas nuevas (credito, cuota y
--              credito_producto existen desde E1). Nada de esto mueve dinero: el desembolso lo hace solicitar_credito (20) por _asentar_grupo.
--
--   Internas (EXECUTE para nadie salvo el dueño; las usan 20, E9 y E10):
--     _reglas_credito()                 valores centralizados: plazo técnico máximo de cálculo (360) y los mensajes del contrato §6 (D-E8-3, D-E8-7)
--     _tasa_mensual(tasa_pct)           i mensual. ÚNICO punto de la convención de tasas (D1, PROVISIONAL, del EQUIPO): E.A. estricta (1+t)^(1/12)-1
--     _fecha_vencimiento(desembolso,k)  desembolso + k meses calendario ANCLADO a la fecha original (D-E8-3, PROVISIONAL)
--     _plan_cuotas(monto, tasa, n)      plan francés: (numero, cuota, capital, interes, saldo); la última cuota absorbe el redondeo. Lo usan simular Y solicitar
--     _patrimonio_neto(cuenta)          base del tope de Inmuebles = balance_total - Σ capital_pendiente (spec §7.6; D-E8-5, PROVISIONAL, D6 del equipo)
--     _interes_corriendo(credito, hoy)  prorrata lineal del interés de la próxima cuota impaga (D-E8-4, PROVISIONAL; contrato §7.4)
--     ct_credito_plan()                 trigger de restricción DIFERIDO (D-E8-9 v1.1): UNA regla, sobre credito y cuota
--
-- NO hay pagos, abonos, mora ni descuento automático (E9, D7). D1, D6 y D7 son decisiones del EQUIPO: aquí solo hay valores PROVISIONALES centralizados.
-- Dependencias : 00 a 18.   Ejecución: como superusuario, IDEMPOTENTE, transaccional.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- _reglas_credito: valores y mensajes en UN solo lugar
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reglas_credito()
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'plazo_tecnico_max', 360,                                                       -- D-E8-3: tope TÉCNICO de cálculo (la cifra del contrato §8), no una regla de negocio
    'msg_monto',   'Monto fuera de rango',                                          -- contrato §6 (exactos)
    'msg_plazo',   'Plazo fuera de rango',
    'msg_edad',    'Plazo excede el límite de edad',
    'msg_vigente', 'Ya tienes un crédito vigente de este producto')
$$;
COMMENT ON FUNCTION public._reglas_credito() IS
  'E8. PURA. plazo_tecnico_max = 360 meses (D-E8-3: protege el cálculo de un producto mal cargado; la cifra es la del contrato §8) y los 4 mensajes de crédito del contrato §6 (el mensaje combinado "Plazo excede el límite de edad / Plazo fuera de rango" son DOS mensajes; D13 del equipo). Mensajes que ya existen en E4/E5 (Monto inválido, Recurso no encontrado, Sesión inválida) se piden a _msg_negocio/_msg_auth.';

-- ----------------------------------------------------------------------------
-- _tasa_mensual: la ÚNICA convención de tasa del crédito (PROVISIONAL, D1)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._tasa_mensual(p_tasa_pct numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  -- D1 (PROVISIONAL, decide el equipo): la tasa del producto es EFECTIVA ANUAL (contrato §2) y la mensual equivalente es (1 + t/100)^(1/12) - 1.
  -- El contrato §3.5 dice literalmente "i = tasa/12" (nominal), que contradice "% E.A.": con 10.000.000, 12 cuotas y 18 % la cuota es 910.463,77 (E.A.)
  -- frente a 916.799,93 (nominal). Si el equipo elige otra convención SOLO cambia este cuerpo (simular y solicitar comparten _plan_cuotas).
  SELECT CASE WHEN p_tasa_pct IS NULL OR p_tasa_pct <= 0 THEN 0::numeric
              ELSE power(1 + p_tasa_pct / 100, 1::numeric / 12) - 1 END
$$;
COMMENT ON FUNCTION public._tasa_mensual(numeric) IS
  'E8. PURA. ÚNICO punto de la convención de tasas del crédito (D1, PROVISIONAL, del EQUIPO): E.A. estricta (1 + t/100)^(1/12) - 1, en numeric. El contrato dice también "i = tasa/12": contradicción abierta (ver 08-creditos-diseno.md §4.1). Cambiar la convención = cambiar solo este cuerpo.';

-- ----------------------------------------------------------------------------
-- _fecha_vencimiento: calendario del plan (PROVISIONAL, D-E8-3)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._fecha_vencimiento(p_desembolso date, p_k integer)
RETURNS date LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  -- D-E8-3 (PROVISIONAL): vencimiento de la cuota k = desembolso + k MESES CALENDARIO, anclado a la fecha original (no iterativo): 31-ene -> 28-feb,
  -- 31-mar, 30-abr... (PostgreSQL recorta al fin de mes). El spec no define el calendario.
  SELECT (p_desembolso + make_interval(months => p_k))::date
$$;
COMMENT ON FUNCTION public._fecha_vencimiento(date, integer) IS
  'E8. PURA. Vencimiento de la cuota k = fecha de desembolso + k meses calendario, anclado a la fecha original (31-ene -> 28-feb, 31-mar...). D-E8-3 PROVISIONAL (el spec no define el calendario).';

-- ----------------------------------------------------------------------------
-- _plan_cuotas: amortización francesa en numeric
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._plan_cuotas(p_monto numeric, p_tasa_pct numeric, p_n integer)
RETURNS TABLE (numero integer, cuota numeric, capital numeric, interes numeric, saldo numeric)
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  i  numeric;
  q  numeric;
  c  numeric;
  s  numeric := round(p_monto, 2);
  k  integer;
  it numeric;
  cp numeric;
BEGIN
  IF p_monto IS NULL OR p_monto <= 0 OR p_n IS NULL OR p_n < 1 OR p_n > (public._reglas_credito() ->> 'plazo_tecnico_max')::int THEN
    RAISE EXCEPTION 'Créditos: _plan_cuotas recibió monto o plazo inválidos (monto=%, n=%)', p_monto, p_n USING ERRCODE = 'P0001';
  END IF;
  i := public._tasa_mensual(p_tasa_pct);
  IF i = 0 THEN
    c := round(p_monto / p_n, 2);                                         -- tasa 0 (no la admite el dominio de producto; defensa)
  ELSE
    q := power(1 + i, p_n);
    c := round(p_monto * i * q / (q - 1), 2);                             -- cuota fija: P·i·(1+i)^n / ((1+i)^n - 1), redondeada a centavos
  END IF;
  FOR k IN 1..p_n LOOP
    it := round(s * i, 2);                                                -- interés del período = saldo previo * i, a centavos
    IF k = p_n THEN
      cp := s;                                                            -- la ÚLTIMA cuota absorbe la diferencia: el capital restante exacto (contrato §3.5)
    ELSE
      cp := c - it;
    END IF;
    IF cp < 0 THEN
      RAISE EXCEPTION '%', (public._reglas_credito() ->> 'msg_monto') USING ERRCODE = 'P0001';   -- monto diminuto: el interés redondeado supera la cuota
    END IF;
    numero := k; interes := it; capital := cp; cuota := cp + it; s := s - cp; saldo := s;
    RETURN NEXT;
  END LOOP;
END
$$;
COMMENT ON FUNCTION public._plan_cuotas(numeric, numeric, integer) IS
  'E8. Plan francés en numeric (nunca float): i = _tasa_mensual(tasa) (D1 PROVISIONAL); cuota fija C = round(P·i·q/(q-1), 2) con q = (1+i)^n; por período interés = round(saldo·i, 2) y capital = C - interés; la ÚLTIMA cuota toma el capital restante exacto (cuota = capital + interés), así Σ capital = P siempre. Devuelve (numero, cuota, capital, interes, saldo). La usan simular_credito y solicitar_credito: lo simulado es lo que se cobra. n entre 1 y plazo_tecnico_max.';

-- ----------------------------------------------------------------------------
-- _patrimonio_neto: base del tope de Inmuebles (PROVISIONAL, D6 del equipo)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._patrimonio_neto(p_cuenta_id uuid)
RETURNS numeric LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  -- D-E8-5 (PROVISIONAL, D6): spec §7.6 «balance total para los topes = (principal + bolsillos + CDT activos) - Σ capital_pendiente». balance_total (E6/E7)
  -- NO resta la deuda y no se toca aquí: lo que muestra el front como «total» es decisión D6 del equipo. Si D6 adopta el neto, esta función pasa a ser un alias.
  SELECT public.balance_total(p_cuenta_id)
         - coalesce((SELECT sum(k.capital_pendiente) FROM public.credito k WHERE k.cuenta_id = p_cuenta_id), 0)
$$;
COMMENT ON FUNCTION public._patrimonio_neto(uuid) IS
  'E8. Base del tope de Inmuebles (spec §7.6): balance_total(cuenta) - Σ capital_pendiente de sus créditos. D-E8-5 PROVISIONAL (D6 del equipo): balance_total NO cambia. Puede ser negativo (el tope usa greatest(0, ·)). STABLE: el llamador devenga ANTES (sentencia anterior).';

-- ----------------------------------------------------------------------------
-- _interes_corriendo: interés devengado del período en curso, aún no pagado (PROVISIONAL, D-E8-4)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._interes_corriendo(p_credito_id uuid, p_hoy date)
RETURNS numeric LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  -- D-E8-4 (PROVISIONAL; contrato §7.4; el abono es D7): prorrata LINEAL por días dentro del período de la PRÓXIMA cuota impaga j:
  --   round(interes_programado_j * clamp((hoy - fecha_interes) / (vencimiento_j - fecha_interes), 0, 1), 2); 0 si no hay cuota impaga.
  -- DERIVADO: no escribe nada (los intereses de crédito solo entran al libro cuando se PAGAN, E9). Vencida e impaga = el interés completo de la cuota.
  SELECT coalesce((
    SELECT round(q.interes_programado * greatest(0::numeric, least(1::numeric,
             coalesce((p_hoy - k.fecha_interes)::numeric / nullif(q.fecha_vencimiento - k.fecha_interes, 0), 1::numeric))), 2)
      FROM public.credito k
      JOIN public.cuota q ON q.credito_id = k.id AND NOT q.pagada
     WHERE k.id = p_credito_id
     ORDER BY q.numero LIMIT 1), 0::numeric)
$$;
COMMENT ON FUNCTION public._interes_corriendo(uuid, date) IS
  'E8. Interés corriendo = interes_programado de la próxima cuota impaga * clamp((hoy - fecha_interes)/(vencimiento - fecha_interes), 0, 1), a centavos (D-E8-4 PROVISIONAL, contrato §7.4). Derivado: no escribe. 0 sin cuota impaga. Si E9 mueve fecha_interes a la fecha de un abono, interes_programado debe ser el del tramo restante.';

-- ----------------------------------------------------------------------------
-- ct_credito_plan: UNA regla, diferida (D-E8-9 v1.1)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ct_credito_plan()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_id   uuid;
  v_cap  numeric;
  v_plan numeric;
BEGIN
  -- (IF y no CASE: plpgsql resuelve los campos de NEW/OLD al planificar y 'credito' no tiene credito_id)
  IF TG_TABLE_NAME = 'credito' THEN
    v_id := NEW.id;
  ELSIF TG_OP = 'DELETE' THEN
    v_id := OLD.credito_id;
  ELSE
    v_id := NEW.credito_id;
  END IF;
  SELECT k.capital_pendiente INTO v_cap FROM public.credito k WHERE k.id = v_id;
  IF NOT FOUND THEN
    RETURN NULL;                          -- el crédito ya no existe (cascada del borrado de la cuenta, en la misma transacción)
  END IF;
  SELECT coalesce(sum(q.capital_programado - q.capital_pagado), 0) INTO v_plan
    FROM public.cuota q WHERE q.credito_id = v_id AND NOT q.pagada;
  IF v_plan <> v_cap THEN
    RAISE EXCEPTION 'Créditos: el plan del crédito % no cuadra con su capital pendiente (capital_pendiente=%, capital de las cuotas impagas=%)', v_id, v_cap, v_plan
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NULL;
END
$$;
COMMENT ON FUNCTION public.ct_credito_plan() IS
  'E8 (D-E8-9 v1.1). Trigger de restricción DIFERIDO sobre credito y cuota. UNA regla, para ACTIVO y PAGADO: capital_pendiente (acumulador del libro) = Σ (capital_programado - capital_pagado) de las cuotas NO pagadas. Detecta un abono/pago que mueva la deuda sin dejar el plan coherente. NO impone cuántas cuotas hay ni cómo se cierran al liquidar (decisiones de E9/D7). Corre con los privilegios del dueño (el trigger diferido corre con el usuario de la sesión).';

DROP TRIGGER IF EXISTS ct_credito_plan ON public.credito;
CREATE CONSTRAINT TRIGGER ct_credito_plan
  AFTER INSERT OR UPDATE OF capital_pendiente, estado ON public.credito
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.ct_credito_plan();

DROP TRIGGER IF EXISTS ct_credito_plan_cuota ON public.cuota;
CREATE CONSTRAINT TRIGGER ct_credito_plan_cuota
  AFTER INSERT OR DELETE OR UPDATE OF credito_id, capital_programado, capital_pagado, pagada ON public.cuota
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.ct_credito_plan();

COMMENT ON TRIGGER ct_credito_plan ON public.credito IS 'E8. DIFERIDO: capital_pendiente = Σ (capital_programado - capital_pagado) de las cuotas impagas. Lo dispara también el UPDATE de capital_pendiente que hace el libro.';
COMMENT ON TRIGGER ct_credito_plan_cuota ON public.cuota IS 'E8. DIFERIDO: la misma regla vista desde la cuota (alta, baja o cambio de desglose/estado).';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- Permisos: ninguna función de este script es ejecutable por banco_app / lector / dev
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('_reglas_credito', '_tasa_mensual', '_fecha_vencimiento', '_plan_cuotas', '_patrimonio_neto', '_interes_corriendo', 'ct_credito_plan')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
  END LOOP;
END
$$;

COMMIT;
