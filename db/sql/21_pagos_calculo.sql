-- ============================================================================
-- 21_pagos_calculo.sql  ·  Etapa 9 (pagos, abonos, mora y descuento automático) · parte 1/2: columnas, guardia y cálculo
-- Propósito  : las dos columnas nuevas de credito (cursor del cobro automático y memoria de la mora ya cobrada), la guardia del cursor y la matemática de la
--              mora y del recálculo de las cuotas restantes tras un abono. Nada de esto mueve dinero: lo hace 22 por _asentar_grupo.
--
--   Columnas (credito):
--     cobro_hasta date NULL   cursor del cobro automático: NULL = descuento desactivado (CHECK descuento_automatico = (cobro_hasta IS NOT NULL)); con descuento
--                             activo, «los eventos hasta esta fecha ya se procesaron en su día» (D-E9-6). La guardia solo rechaza «fecha -> fecha anterior».
--     mora_hasta  date NULL   hasta qué fecha ya se COBRÓ la mora de las cuotas vencidas en un abono (D-E9-3/4): evita cobrarla dos veces (ver DESVIACION en 09-pagos.md).
--   Internas (EXECUTE para nadie salvo el dueño):
--     _reglas_pago()                      valores centralizados de pago/mora (base de días del año)
--     _mora_cuota(valor, dias)            LA fórmula de la mora (D7, PROVISIONAL, del EQUIPO): simple sobre el valor de la cuota; tasa NULL => 0
--     _dias_mora(mora_hasta, venc, fecha) días de mora a una fecha: max(0, fecha - max(venc, mora_hasta))
--     _mora_de_cuota(credito, numero, fecha)  mora de UNA cuota a una fecha
--     _mora_pendiente(credito, fecha)     mora de todas las cuotas impagas vencidas a una fecha (lo que muestra vista_creditos)
--     _inicio_periodo(credito, numero)    s_j: vencimiento de la cuota anterior o fecha de desembolso
--     _proxima_cuota(credito)             la próxima cuota impaga (ayudante para E10)
--     _plan_restante(capital, tasa, m, j0) recálculo de las m cuotas restantes con el primer período corto (D-E9-5)
--     trg_cobro_hasta_monotono()          guardia del cursor
--
-- D7 (mora, abono y cobro), D1 (tasas) y D10 (firmas) son decisiones del EQUIPO: aquí solo hay valores PROVISIONALES centralizados.
-- Dependencias : 00 a 20.   Ejecución: como superusuario, IDEMPOTENTE, transaccional.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- Columnas nuevas de credito (sin editar 03_schema.sql; solo se altera la tabla si falta, para no repetir el ALTER en cada reaplicación)
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.credito'::regclass AND attname = 'cobro_hasta' AND NOT attisdropped) THEN
    ALTER TABLE public.credito ADD COLUMN cobro_hasta date;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.credito'::regclass AND attname = 'mora_hasta' AND NOT attisdropped) THEN
    ALTER TABLE public.credito ADD COLUMN mora_hasta date;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.credito'::regclass AND conname = 'ck_credito_cobro_hasta') THEN
    ALTER TABLE public.credito ADD CONSTRAINT ck_credito_cobro_hasta CHECK (descuento_automatico = (cobro_hasta IS NOT NULL));
  END IF;
END
$$;
COMMENT ON COLUMN public.credito.cobro_hasta IS
  'E9. Cursor del cobro automático. NULL = descuento desactivado (CHECK con descuento_automatico). Con descuento activo, los eventos hasta esta fecha ya se procesaron en su día; solo puede avanzar (trg_cobro_hasta_monotono); desactivar y reactivar lo reinicia.';
COMMENT ON COLUMN public.credito.mora_hasta IS
  'E9. Fecha hasta la que ya se COBRÓ la mora de las cuotas vencidas en un abono. La mora de una cuota se cuenta desde max(vencimiento, mora_hasta): el abono recalcula valor_cuota y sin esta memoria la mora se cobraría dos veces. NULL = nunca se cobró mora en un abono.';

-- ----------------------------------------------------------------------------
-- _reglas_pago
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reglas_pago()
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('base_dias_mora', 365)       -- D-E9-3 (PROVISIONAL, D7): la tasa de mora es anual y se aplica por día sobre 365
$$;
COMMENT ON FUNCTION public._reglas_pago() IS
  'E9. PURA. Valores de pago/mora en UN solo lugar: base_dias_mora = 365 (D-E9-3, PROVISIONAL, D7 del equipo). Los mensajes son los existentes del contrato §6 (no hay mensajes nuevos, D-E9-10).';

-- ----------------------------------------------------------------------------
-- _mora_cuota: LA fórmula de la mora (PROVISIONAL, D7)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mora_cuota(p_valor numeric, p_dias integer)
RETURNS numeric LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  -- D-E9-3 (PROVISIONAL, decide el equipo): mora SIMPLE sobre el valor de la cuota, «se acumula diariamente sobre el valor de la cuota» (spec §7.6):
  --   round(valor * tasa_mora_anual/100 / 365 * dias, 2). parametro.tasa_mora_anual NULL (sin valor hasta que el equipo decida D7) => 0: no se inventa una tasa.
  -- Comparación con 910.463,77, 30 % y 30 días: simple 22.449,79 / E.A. diaria lineal 19.640,47 / E.A. compuesta 19.846,63. Cambiar la convención = cambiar SOLO este cuerpo.
  SELECT CASE WHEN p_dias IS NULL OR p_dias <= 0 OR pa.tasa_mora_anual IS NULL OR pa.tasa_mora_anual <= 0 THEN 0.00::numeric
              ELSE round(p_valor * pa.tasa_mora_anual / 100 / (public._reglas_pago() ->> 'base_dias_mora')::numeric * p_dias, 2) END
    FROM public.parametro pa WHERE pa.id = 1
$$;
COMMENT ON FUNCTION public._mora_cuota(numeric, integer) IS
  'E9. LA fórmula de la mora (D7, PROVISIONAL, del EQUIPO): simple sobre el valor de la cuota, round(valor * tasa_mora_anual/100/365 * dias, 2); tasa NULL, 0 o días <= 0 => 0. Cambiar la convención = cambiar solo este cuerpo.';

CREATE OR REPLACE FUNCTION public._dias_mora(p_mora_hasta date, p_venc date, p_fecha date)
RETURNS integer LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT greatest(0, p_fecha - greatest(p_venc, coalesce(p_mora_hasta, p_venc)))
$$;
COMMENT ON FUNCTION public._dias_mora(date, date, date) IS
  'E9. PURA. Días de mora de una cuota a una fecha: max(0, fecha - max(vencimiento, mora_hasta)). mora_hasta es la fecha hasta la que un abono ya cobró la mora; NULL = ninguna.';

CREATE OR REPLACE FUNCTION public._mora_de_cuota(p_credito_id uuid, p_numero integer, p_fecha date)
RETURNS numeric LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT public._mora_cuota(q.valor_cuota, public._dias_mora(k.mora_hasta, q.fecha_vencimiento, p_fecha))
                     FROM public.cuota q JOIN public.credito k ON k.id = q.credito_id
                    WHERE q.credito_id = p_credito_id AND q.numero = p_numero AND NOT q.pagada), 0.00::numeric)
$$;
COMMENT ON FUNCTION public._mora_de_cuota(uuid, integer, date) IS
  'E9. Mora de UNA cuota impaga a una fecha (0 si está pagada, no existe o aún no vence): _mora_cuota(valor_cuota vigente, _dias_mora(mora_hasta del crédito, vencimiento, fecha)).';

CREATE OR REPLACE FUNCTION public._mora_pendiente(p_credito_id uuid, p_fecha date)
RETURNS numeric LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT coalesce(sum(public._mora_cuota(q.valor_cuota, public._dias_mora(k.mora_hasta, q.fecha_vencimiento, p_fecha))), 0.00::numeric)
    FROM public.cuota q JOIN public.credito k ON k.id = q.credito_id
   WHERE q.credito_id = p_credito_id AND NOT q.pagada AND q.fecha_vencimiento < p_fecha
$$;
COMMENT ON FUNCTION public._mora_pendiente(uuid, date) IS
  'E9. Mora de todas las cuotas impagas ya vencidas de un crédito a una fecha (lo que costaría ponerse al día; es lo que muestra vista_creditos.mora_acumulada y lo que cobra un abono). Derivada: no escribe nada.';

-- ----------------------------------------------------------------------------
-- períodos y próxima cuota
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._inicio_periodo(p_credito_id uuid, p_numero integer)
RETURNS date LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p_numero <= 1 THEN (SELECT k.fecha_desembolso FROM public.credito k WHERE k.id = p_credito_id)
              ELSE (SELECT q.fecha_vencimiento FROM public.cuota q WHERE q.credito_id = p_credito_id AND q.numero = p_numero - 1) END
$$;
COMMENT ON FUNCTION public._inicio_periodo(uuid, integer) IS
  'E9. s_j: inicio del período de la cuota j = vencimiento de la cuota j-1 (o la fecha de desembolso para la 1). Regla R: fecha_interes siempre cae en [s_j, v_j] de la próxima cuota impaga.';

CREATE OR REPLACE FUNCTION public._proxima_cuota(p_credito_id uuid)
RETURNS public.cuota LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT q FROM public.cuota q WHERE q.credito_id = p_credito_id AND NOT q.pagada ORDER BY q.numero LIMIT 1
$$;
COMMENT ON FUNCTION public._proxima_cuota(uuid) IS
  'E9. La próxima cuota impaga de un crédito (la de menor número), o una fila nula si no hay. Ayudante para E10 (cuota_por_pagar) y para pagar/abonar.';

-- ----------------------------------------------------------------------------
-- _plan_restante: las m cuotas restantes tras un abono, con el primer período corto
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._plan_restante(p_capital numeric, p_tasa_pct numeric, p_m integer, p_j0 numeric)
RETURNS TABLE (numero integer, cuota numeric, capital numeric, interes numeric, saldo numeric)
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  i  numeric;
  q  numeric;
  c  numeric;
  s  numeric := round(p_capital, 2);
  k  integer;
  it numeric;
  cp numeric;
BEGIN
  IF p_capital IS NULL OR p_capital <= 0 OR p_m IS NULL OR p_m < 1 OR p_j0 IS NULL OR p_j0 < 0 THEN
    RAISE EXCEPTION 'Créditos: _plan_restante recibió capital, cuotas o interés inválidos (capital=%, m=%, j0=%)', p_capital, p_m, p_j0 USING ERRCODE = 'P0001';
  END IF;
  i := public._tasa_mensual(p_tasa_pct);                                  -- D1 (PROVISIONAL): la MISMA convención que E8
  IF i = 0 THEN
    c := round(p_capital / p_m, 2);
  ELSE
    q := power(1 + i, p_m);
    -- D-E9-5: cuota fija con el primer período corto j0 (si j0 = capital*i coincide con la cuota francesa estándar):
    --   C' = (K' + j0) · i · (1+i)^(m-1) / ((1+i)^m - 1)
    c := round((p_capital + p_j0) * i * power(1 + i, p_m - 1) / (q - 1), 2);
  END IF;
  FOR k IN 1..p_m LOOP
    it := CASE WHEN k = 1 THEN round(p_j0, 2) ELSE round(s * i, 2) END;
    cp := CASE WHEN k = p_m THEN s ELSE c - it END;                      -- la ÚLTIMA cuota absorbe el redondeo: Σ capital = K' exacto
    IF cp < 0 THEN
      RAISE EXCEPTION '%', (public._reglas_credito() ->> 'msg_monto') USING ERRCODE = 'P0001';
    END IF;
    numero := k; interes := it; capital := cp; cuota := cp + it; s := s - cp; saldo := s;
    RETURN NEXT;
  END LOOP;
END
$$;
COMMENT ON FUNCTION public._plan_restante(numeric, numeric, integer, numeric) IS
  'E9. Recálculo de las m cuotas restantes tras un abono (D-E9-5, PROVISIONAL D7): capital K'', tasa del crédito (_tasa_mensual, D1), mismo número de cuotas y primer período corto j0 = round(K''·i·rem, 2). Cuota fija C'' = (K''+j0)·i·(1+i)^(m-1)/((1+i)^m-1); la última absorbe el redondeo (Σ capital = K''). Devuelve (numero 1..m, cuota, capital, interes, saldo). Con j0 = K''·i es la cuota francesa estándar de K'' a m cuotas.';

-- ----------------------------------------------------------------------------
-- Guardia del cursor: solo rechaza «fecha -> fecha anterior» (NULL <-> fecha siempre se permite: activar y desactivar el descuento)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_cobro_hasta_monotono()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF OLD.cobro_hasta IS NOT NULL AND NEW.cobro_hasta IS NOT NULL AND NEW.cobro_hasta < OLD.cobro_hasta THEN
    RAISE EXCEPTION 'Libro mayor: cobro_hasta solo puede avanzar (desactivar y reactivar el descuento lo reinicia)' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;
COMMENT ON FUNCTION public.trg_cobro_hasta_monotono() IS
  'E9. Guardia (BEFORE UPDATE OF cobro_hasta ON credito): rechaza SOLO fecha -> fecha anterior. NULL -> fecha (activar el descuento) y fecha -> NULL (desactivarlo) siempre se permiten: son el único camino para reiniciar el cursor y no son un retroceso del tiempo (mientras es NULL el crédito no se procesa). El motor nunca intenta bajarlo: con hoy < cobro_hasta no escribe.';

CREATE OR REPLACE TRIGGER trg_cobro_hasta_monotono
  BEFORE UPDATE OF cobro_hasta ON public.credito
  FOR EACH ROW EXECUTE FUNCTION public.trg_cobro_hasta_monotono();
COMMENT ON TRIGGER trg_cobro_hasta_monotono ON public.credito IS 'E9. cobro_hasta solo avanza (NULL <-> fecha libre); el cobro automático no recobra ni cobra con fecha retroactiva.';

RESET ROLE;

-- el dueño actualiza solo columnas no-acumulador de credito (E2): se agregan las dos nuevas
GRANT UPDATE (cobro_hasta, mora_hasta) ON public.credito TO banco_owner;

-- ----------------------------------------------------------------------------
-- Permisos: ninguna función de este script es ejecutable por banco_app / lector / dev
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('_reglas_pago', '_mora_cuota', '_dias_mora', '_mora_de_cuota', '_mora_pendiente', '_inicio_periodo', '_proxima_cuota', '_plan_restante', 'trg_cobro_hasta_monotono')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
  END LOOP;
END
$$;

COMMIT;
