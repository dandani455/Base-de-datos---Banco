-- ============================================================================
-- 17_motor_devengo.sql  ·  Etapa 7 (motor de devengo lazy) · parte 1/2
-- Propósito  : el motor que devenga intereses de bolsillos y CDT y cierra los CDT vencidos, SIEMPRE antes de que una operación lea o mueva
--              saldos. Todo el dinero se mueve SOLO por _asentar_grupo (plantillas INTERES_BOLSO, INTERES_CDT y CDT_VENCIMIENTO de E2).
--
--   Internas (sin EXECUTE para nadie salvo el dueño; no son API del backend):
--     _factor_interes(tasa_pct, dias)     ÚNICA fórmula de interés (D1: E.A. estricta, PROVISIONAL). La usan el motor y simular_cdt.
--     _avanzar_hasta(cuenta, hoy, ahora)  motor: salida rápida sin bloqueo -> bloqueo de la cuenta -> relee bajo el bloqueo -> devenga. NO lee el reloj.
--     _devengar_bolsillos / _devengar_cdts   los dos pasos del motor (forma cerrada: coste O(productos), nunca O(días))
--     _bloquear_cuentas(ids)              bloquea varias cuentas en ORDEN DE id (protocolo anti-deadlock de hacer_transferencia)
--     trg_ultimo_cobro_monotono()         guardia: ultimo_cobro de bolsillo/cdt NUNCA retrocede (BEFORE UPDATE OF ultimo_cobro)
--
-- Garantías (probadas en 54-56 y reales/45-46):
--   * UNA instantánea del reloj por operación: la toma la función de negocio y pasa (hoy, ahora); el motor no usa now()/hoy_banco()/_ahora_real().
--   * El bloqueo de la cuenta (FOR NO KEY UPDATE, el MISMO del libro) lo toma el devengo y lo conserva la operación posterior (misma transacción).
--   * Sin doble devengo: ultimo_cobro se avanza en la MISMA transacción que el asiento y bajo el bloqueo; el CDT se devenga por OBJETIVO ACUMULADO
--     (asiento = objetivo - generado_acumulado), por lo que repetir la llamada produce 0 asientos; hoy <= ultimo_cobro no hace nada.
--   * Atomicidad: un fallo en cualquier punto revierte el devengo junto con la operación que lo disparó (la siguiente lo repite UNA vez).
--
-- D1 / D11 siguen siendo decisiones del EQUIPO: aquí solo hay valores PROVISIONALES centralizados (_factor_interes; tasa_bolsillo_anual de parametro).
-- Dependencias : 00 a 16.   Ejecución: como superusuario, IDEMPOTENTE, transaccional.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- _factor_interes: la ÚNICA fórmula de interés del motor (PROVISIONAL, D1)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._factor_interes(p_tasa_pct numeric, p_dias integer)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  -- D1 (PROVISIONAL, decide el equipo): tasa EFECTIVA ANUAL estricta, capitalización diaria equivalente: (1 + t/100)^(dias/365) - 1.
  -- Es compuesta A PROPÓSITO: el interés de un bolsillo se acredita dentro de su saldo y el esquema solo guarda saldo y ultimo_cobro, así que
  -- solo un factor compuesto con base diaria fija no depende de CUÁNTAS VECES consulte el usuario (salvo el redondeo a centavos, D-E7-9).
  -- Si el equipo elige otra convención, SOLO cambia este cuerpo (motor y simular_cdt la comparten).
  SELECT CASE WHEN p_dias IS NULL OR p_dias <= 0 OR p_tasa_pct IS NULL OR p_tasa_pct <= 0 THEN 0::numeric
              ELSE power(1 + p_tasa_pct / 100, p_dias::numeric / 365) - 1 END
$$;
COMMENT ON FUNCTION public._factor_interes(numeric, integer) IS
  'E7. PURA. ÚNICA fórmula de interés (D1, PROVISIONAL: la decide el equipo): E.A. estricta (1 + tasa/100)^(dias/365) - 1; 0 si dias <= 0 o tasa <= 0. La usan _devengar_bolsillos, _devengar_cdts y simular_cdt, por lo que la simulación coincide con lo que de verdad se genera. Cambiar de convención = cambiar SOLO este cuerpo. Ejemplos: $1.000.000 al 12 % por 30 días = $9.358,20; $10.000.000 al 10 % por 360 días = $985.647,56.';

-- ----------------------------------------------------------------------------
-- _bloquear_cuentas: bloqueo ordenado de varias cuentas (el mismo FOR NO KEY UPDATE del libro)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._bloquear_cuentas(p_ids uuid[])
RETURNS integer LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_n integer;
BEGIN
  -- Orden ascendente de id: el MISMO protocolo que _asentar_grupo (A->B y B->A toman A y B en el mismo orden: sin deadlock).
  PERFORM 1 FROM public.cuenta c WHERE c.id = ANY (p_ids) ORDER BY c.id FOR NO KEY UPDATE;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$$;
COMMENT ON FUNCTION public._bloquear_cuentas(uuid[]) IS
  'E7. Interna. Bloquea (FOR NO KEY UPDATE, el mismo bloqueo del libro y del borrado en cascada) las cuentas dadas en ORDEN ASCENDENTE de id y devuelve cuántas existían (el llamador traduce las ausentes con sus reglas de carrera). Imprescindible en hacer_transferencia: devengar primero la cuenta del emisor bloquearía solo esa y A->B || B->A haría deadlock. Reentrante: _asentar_grupo vuelve a pedir los mismos bloqueos.';

-- ----------------------------------------------------------------------------
-- _devengar_bolsillos: un grupo INTERES_BOLSO por bolsillo con interés > 0; SIEMPRE avanza ultimo_cobro
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._devengar_bolsillos(p_cuenta_id uuid, p_hoy date, p_ahora timestamptz)
RETURNS integer LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_tasa  numeric;
  v_max   numeric;
  r       record;
  v_n     integer := 0;
  v_dias  integer;
  v_int   numeric;
  v_nota  text;
BEGIN
  SELECT p.tasa_bolsillo_anual, p.monto_maximo INTO v_tasa, v_max FROM public.parametro p WHERE p.id = 1;
  -- Orden de id (bolsillos); la cuenta ya está bloqueada por _avanzar_hasta, así que nadie más mueve sus bolsillos.
  FOR r IN SELECT b.id, b.balance, b.ultimo_cobro
             FROM public.bolsillo b
            WHERE b.cuenta_id = p_cuenta_id AND b.ultimo_cobro < p_hoy
            ORDER BY b.id FOR NO KEY UPDATE
  LOOP
    v_dias := p_hoy - r.ultimo_cobro;
    -- forma cerrada (sin bucle por día); el recorte a monto_maximo evita desbordar el dominio (caso de laboratorio): nunca un error no-P0001
    v_int  := least(round(r.balance * public._factor_interes(v_tasa, v_dias), 2), greatest(v_max - r.balance, 0));
    IF v_int > 0 THEN
      v_nota := v_dias || CASE WHEN v_dias = 1 THEN ' día' ELSE ' días' END;
      PERFORM public._asentar_grupo(p_ahora, jsonb_build_array(
        jsonb_build_object('tipo', 'INTERES_BOLSO', 'contenedor', 'BOLSILLO',  'sentido', 'E', 'monto', v_int, 'cuenta_id', p_cuenta_id,
                           'bolsillo_id', r.id, 'nota', v_nota, 'contraparte_nombre', 'Banco Digital'),
        jsonb_build_object('tipo', 'INTERES_BOLSO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', v_int, 'cuenta_id', p_cuenta_id,
                           'bolsillo_id', r.id, 'nota', v_nota, 'contraparte_nombre', 'Banco Digital')));
      v_n := v_n + 1;
    END IF;
    -- SIEMPRE (incluso con saldo 0 o interés redondeado a 0): si no, un depósito posterior cobraría días retroactivos (mutación dedicada)
    UPDATE public.bolsillo SET ultimo_cobro = p_hoy WHERE id = r.id;
  END LOOP;
  RETURN v_n;
END
$$;
COMMENT ON FUNCTION public._devengar_bolsillos(uuid, date, timestamptz) IS
  'E7. Interna (la llama _avanzar_hasta con la cuenta YA bloqueada). Por cada bolsillo con ultimo_cobro < hoy: n = hoy - ultimo_cobro; interés = round(saldo * _factor_interes(tasa_bolsillo_anual, n), 2) recortado a monto_maximo; si es > 0 asienta UN grupo INTERES_BOLSO (BOLSILLO E + RESULTADO E, contraparte "Banco Digital", nota "N días", fecha = ahora recibido) por _asentar_grupo; SIEMPRE avanza ultimo_cobro a hoy (también con saldo 0 o interés 0). No lee el reloj. Devuelve los grupos escritos.';

-- ----------------------------------------------------------------------------
-- _devengar_cdts: objetivo acumulado, tope en fecha_fin, cierre en la misma transacción
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._devengar_cdts(p_cuenta_id uuid, p_hoy date, p_ahora timestamptz)
RETURNS integer LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_max     numeric;
  r         record;
  v_n       integer := 0;
  v_d       date;
  v_cierra  boolean;
  v_fecha   timestamptz;
  v_obj     numeric;
  v_gen     numeric;
  v_dias    integer;
  v_nota    text;
BEGIN
  SELECT p.monto_maximo INTO v_max FROM public.parametro p WHERE p.id = 1;
  FOR r IN SELECT d.id, d.nombre, d.monto, d.tasa_anual, d.fecha_inicio, d.fecha_fin, d.generado_acumulado, d.ultimo_cobro
             FROM public.cdt d
            WHERE d.cuenta_id = p_cuenta_id AND d.estado = 'ACTIVO' AND (d.fecha_fin <= p_hoy OR d.ultimo_cobro < p_hoy)
            ORDER BY d.fecha_fin, d.id FOR NO KEY UPDATE
  LOOP
    v_d      := least(p_hoy, r.fecha_fin);                    -- el interés NUNCA pasa de fecha_fin aunque el reloj salte años (M2)
    v_cierra := r.fecha_fin <= p_hoy;
    -- D-E7-6: el cierre (y su último interés) se fecha en fecha_fin 00:00 de Bogotá; los intereses hasta hoy, en el ahora de la operación
    v_fecha  := CASE WHEN v_cierra THEN (r.fecha_fin::timestamp AT TIME ZONE 'America/Bogota') ELSE p_ahora END;
    v_gen    := r.generado_acumulado;
    IF v_d > r.ultimo_cobro THEN                              -- monotonía: nunca se retrocede ni se recobra un período
      v_dias := v_d - r.fecha_inicio;
      -- OBJETIVO ACUMULADO: depende solo de los días transcurridos; el asiento es la DIFERENCIA con lo ya generado => idempotente por construcción
      v_obj  := least(round(r.monto * public._factor_interes(r.tasa_anual, v_dias), 2), greatest(v_max - r.monto, 0));
      IF v_obj > r.generado_acumulado THEN
        v_nota := (v_d - r.ultimo_cobro) || CASE WHEN v_d - r.ultimo_cobro = 1 THEN ' día' ELSE ' días' END;
        PERFORM public._asentar_grupo(v_fecha, jsonb_build_array(
          jsonb_build_object('tipo', 'INTERES_CDT', 'contenedor', 'CDT',       'sentido', 'E', 'monto', v_obj - r.generado_acumulado, 'cuenta_id', p_cuenta_id,
                             'cdt_id', r.id, 'nota', v_nota, 'contraparte_nombre', 'Banco Digital'),
          jsonb_build_object('tipo', 'INTERES_CDT', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', v_obj - r.generado_acumulado, 'cuenta_id', p_cuenta_id,
                             'cdt_id', r.id, 'nota', v_nota, 'contraparte_nombre', 'Banco Digital')));
        v_gen := v_obj;
        v_n := v_n + 1;
      END IF;
      UPDATE public.cdt SET ultimo_cobro = v_d WHERE id = r.id;
    END IF;
    IF v_cierra THEN
      -- el estado CERRADO va en la MISMA transacción y ANTES del asiento: ct_cdt_inversion (inmediato dentro de _asentar_grupo) exige inversión 0 al cerrar
      UPDATE public.cdt SET estado = 'CERRADO' WHERE id = r.id;
      PERFORM public._asentar_grupo(v_fecha, jsonb_build_array(
        jsonb_build_object('tipo', 'CDT_VENCIMIENTO', 'contenedor', 'CDT',    'sentido', 'S', 'monto', r.monto + v_gen, 'cuenta_id', p_cuenta_id,
                           'cdt_id', r.id, 'contraparte_nombre', r.nombre),
        jsonb_build_object('tipo', 'CDT_VENCIMIENTO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', r.monto + v_gen, 'cuenta_id', p_cuenta_id,
                           'cdt_id', r.id, 'contraparte_nombre', r.nombre)));
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END
$$;
COMMENT ON FUNCTION public._devengar_cdts(uuid, date, timestamptz) IS
  'E7. Interna (la llama _avanzar_hasta con la cuenta YA bloqueada). Por cada CDT ACTIVO con algo pendiente (orden fecha_fin, id): d = min(hoy, fecha_fin); objetivo acumulado = round(monto * _factor_interes(tasa copiada, d - fecha_inicio), 2); asienta UN grupo INTERES_CDT por la DIFERENCIA con generado_acumulado (si > 0) y avanza ultimo_cobro a d (repetir la llamada = 0 asientos). Si fecha_fin <= hoy: estado CERRADO y UN grupo CDT_VENCIMIENTO (CDT S + CUENTA E por monto + generado) en la misma transacción, fechado en fecha_fin 00:00 Bogotá (D-E7-6). No lee el reloj. Devuelve los grupos escritos.';

-- ----------------------------------------------------------------------------
-- _avanzar_hasta: el motor
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._avanzar_hasta(p_cuenta_id uuid, p_hoy date, p_ahora timestamptz)
RETURNS integer LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_n integer := 0;
BEGIN
  IF p_cuenta_id IS NULL OR p_hoy IS NULL OR p_ahora IS NULL THEN
    RAISE EXCEPTION 'Motor de devengo: cuenta, hoy y ahora son obligatorios' USING ERRCODE = 'P0001';
  END IF;
  -- a) salida rápida SIN bloqueo. Segura: el reloj no cambia mientras haya operaciones en vuelo (FOR SHARE de E3), así que si con MI hoy no hay nada
  --    vencido, ninguna otra sesión del mismo cliente puede dejarme algo vencido; si hay algo, se relee bajo el bloqueo (b).
  IF NOT EXISTS (SELECT 1 FROM public.bolsillo b WHERE b.cuenta_id = p_cuenta_id AND b.ultimo_cobro < p_hoy)
     AND NOT EXISTS (SELECT 1 FROM public.cdt d WHERE d.cuenta_id = p_cuenta_id AND d.estado = 'ACTIVO' AND (d.fecha_fin <= p_hoy OR d.ultimo_cobro < p_hoy))
     -- E9: nada que cobrar automaticamente (credito ACTIVO con descuento, cobro_hasta <= hoy y algo por procesar: el cursor atrasado o una cuota impaga ya vencida)
     AND NOT EXISTS (SELECT 1 FROM public.credito k WHERE k.cuenta_id = p_cuenta_id AND k.estado = 'ACTIVO' AND k.cobro_hasta IS NOT NULL AND k.cobro_hasta <= p_hoy
                        AND (k.cobro_hasta < p_hoy OR EXISTS (SELECT 1 FROM public.cuota q WHERE q.credito_id = k.id AND NOT q.pagada AND q.fecha_vencimiento <= p_hoy))) THEN
    RETURN 0;
  END IF;
  -- b) el MISMO bloqueo que el libro (FOR NO KEY UPDATE): lo conserva la operación posterior hasta el COMMIT
  PERFORM 1 FROM public.cuenta c WHERE c.id = p_cuenta_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RETURN 0;                       -- la cuenta ya no existe: el llamador sigue su ruta de carreras (Sesión inválida)
  END IF;
  -- c) bajo el bloqueo, cada paso relee lo vencido en una SENTENCIA NUEVA (en READ COMMITTED ve lo que otra sesión acaba de devengar)
  v_n := public._devengar_bolsillos(p_cuenta_id, p_hoy, p_ahora);
  v_n := v_n + public._cobrar_creditos(p_cuenta_id, p_hoy, p_ahora);       -- E9: cobro automatico CRONOLOGICO (cierra los CDT por fecha y cobra cuotas en orden)
  v_n := v_n + public._devengar_cdts(p_cuenta_id, p_hoy, p_ahora);          -- el resto (no-op si _cobrar_creditos ya cerro hasta hoy)
  -- d) créditos (E9): _cobrar_creditos fusiona en ORDEN CRONOLÓGICO los vencimientos de cuotas con descuento automático y los cierres de CDT (M10; 09-pagos-diseno.md §7).
  RETURN v_n;
END
$$;
COMMENT ON FUNCTION public._avanzar_hasta(uuid, date, timestamptz) IS
  'E7. MOTOR de devengo lazy. Interna: toda función de cliente que lee o mueve saldos la llama UNA vez, con el (hoy, ahora) de SU única _reloj_instantanea() (no lee el reloj). Si nada está vencido sale sin bloquear; si no, bloquea la cuenta (FOR NO KEY UPDATE, el mismo del libro; la operación posterior lo conserva), relee bajo el bloqueo y devenga bolsillos (_devengar_bolsillos) y CDT (_devengar_cdts). Devuelve cuántos grupos escribió (0 si la cuenta ya no existe: el llamador traduce la carrera). Idempotente. Hueco para créditos (E8/E9).';

-- ----------------------------------------------------------------------------
-- Guardia: ultimo_cobro nunca retrocede (recomendada en E3; D-E7-8). Un valor igual se acepta (UPDATE idempotente).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_ultimo_cobro_monotono()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.ultimo_cobro < OLD.ultimo_cobro THEN
    RAISE EXCEPTION 'Motor de devengo: ultimo_cobro no puede retroceder (% -> %)', OLD.ultimo_cobro, NEW.ultimo_cobro USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;
COMMENT ON FUNCTION public.trg_ultimo_cobro_monotono() IS
  'E7. BEFORE UPDATE OF ultimo_cobro en bolsillo y cdt: rechaza (P0001) cualquier valor menor que el actual (un período ya cobrado no se recobra, ni siquiera tras volver al reloj real). Igual o mayor se acepta. No protege de un superusuario (limitación documentada de E2).';

CREATE OR REPLACE TRIGGER trg_ultimo_cobro_monotono
  BEFORE UPDATE OF ultimo_cobro ON public.bolsillo
  FOR EACH ROW EXECUTE FUNCTION public.trg_ultimo_cobro_monotono();
CREATE OR REPLACE TRIGGER trg_ultimo_cobro_monotono
  BEFORE UPDATE OF ultimo_cobro ON public.cdt
  FOR EACH ROW EXECUTE FUNCTION public.trg_ultimo_cobro_monotono();
COMMENT ON TRIGGER trg_ultimo_cobro_monotono ON public.bolsillo IS 'E7. ultimo_cobro del bolsillo nunca retrocede (no se recobra un período).';
COMMENT ON TRIGGER trg_ultimo_cobro_monotono ON public.cdt IS 'E7. ultimo_cobro del CDT nunca retrocede (no se recobra un período).';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- Permisos: ninguna es ejecutable por nadie salvo el dueño
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('_factor_interes', '_bloquear_cuentas', '_devengar_bolsillos', '_devengar_cdts', '_avanzar_hasta', 'trg_ultimo_cobro_monotono')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
  END LOOP;
END
$$;

COMMIT;
