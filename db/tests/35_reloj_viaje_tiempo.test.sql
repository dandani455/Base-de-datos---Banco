-- 35_reloj_viaje_tiempo.test.sql · Etapa 3 · "viaje en el tiempo": prueba basada en un MODELO (oraculo) con tiempo real INYECTADO.
-- D-E3-9: _ahora_real() se sustituye EXCLUSIVAMENTE en banco_test, dentro de esta transaccion (el DDL es transaccional: el ROLLBACK final
-- restaura la funcion original). Se simulan miles de pasos (pasa el tiempo, el admin pone fecha real o manual, operaciones del libro) y en
-- cada uno se compara hoy_banco()/ahora_banco() y la aceptacion/rechazo de cada PUT con un modelo independiente:
--   * modo manual: solo adelantar (retroceso rechazado con el mensaje exacto);   * modo real: SIEMPRE permitido, aunque retroceda;
--   * hoy real = fecha de America/Bogota del instante; ahora = hoy + hora real de Bogota;   * el libro rechaza patas fechadas despues del hoy.
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN       -- banco_mut: base desechable de las pruebas de mutacion
    RAISE EXCEPTION 'FAIL: esta prueba sustituye _ahora_real() y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;

BEGIN;

-- Sustitucion de _ahora_real() (solo en esta transaccion y solo en banco_test)
CREATE OR REPLACE FUNCTION public._ahora_real()
RETURNS timestamptz LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$ SELECT current_setting('tests.ahora')::timestamptz $$;
SELECT set_config('tests.ahora', '2026-11-21 10:00:00-05', true);

SELECT tests.cliente(1);
SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c(1), 1000));        -- ya hay patas: rige la regla completa

SELECT assert_eq('la sustitucion funciona: hoy_banco() sigue el tiempo inyectado (2026-11-21 10:00 en Bogota)', public.hoy_banco(), DATE '2026-11-21');
SELECT set_config('tests.ahora', '2026-11-22 00:00:01-05', true);
SELECT assert_eq('...y cambia a la medianoche de Bogota (00:00:01 del 22)', public.hoy_banco(), DATE '2026-11-22');
SELECT set_config('tests.ahora', '2026-11-22 04:59:59+00', true);
SELECT assert_eq('...04:59:59 UTC del 22 todavia es el 21 en Bogota', public.hoy_banco(), DATE '2026-11-21');
SELECT set_config('tests.ahora', '2026-11-21 10:00:00-05', true);

DO $$
DECLARE
  n int := 4000;
  i int; k float; t timestamptz := '2026-11-21 10:00:00-05'; o_usar boolean := true; o_fecha date := NULL;
  v_hoy_ant date; v_exp_hoy date; v_f date; v_ok boolean; v_msg text;
  v_mal int := 0; v_acept int := 0; v_rech int := 0; v_salidas int := 0; v_salidas_atras int := 0; v_ops int := 0; v_ops_fut int := 0; v_tiempo int := 0; v_manual_estable int := 0;
  g uuid;
BEGIN
  PERFORM setseed(0.35);
  FOR i IN 1..n LOOP
    k := random();
    v_exp_hoy := CASE WHEN o_usar THEN (t AT TIME ZONE 'America/Bogota')::date ELSE o_fecha END;
    v_hoy_ant := v_exp_hoy;

    IF k < 0.40 THEN
      -- pasa el tiempo real: de 0 a 40 horas
      t := t + make_interval(secs => floor(random() * 144000));
      PERFORM set_config('tests.ahora', t::text, true);
      v_tiempo := v_tiempo + 1;
      v_exp_hoy := CASE WHEN o_usar THEN (t AT TIME ZONE 'America/Bogota')::date ELSE o_fecha END;
      IF NOT o_usar AND public.hoy_banco() = o_fecha THEN v_manual_estable := v_manual_estable + 1; END IF;       -- en manual el paso del tiempo NO mueve el hoy

    ELSIF k < 0.60 THEN
      -- el admin vuelve a fecha real (con una fecha basura que debe ignorarse): SIEMPRE permitido
      PERFORM public._reloj_actualizar(true, '2099-09-09');
      IF NOT o_usar THEN
        v_salidas := v_salidas + 1;
        IF (t AT TIME ZONE 'America/Bogota')::date < o_fecha THEN v_salidas_atras := v_salidas_atras + 1; END IF;
      END IF;
      o_usar := true; o_fecha := NULL; v_acept := v_acept + 1;
      v_exp_hoy := (t AT TIME ZONE 'America/Bogota')::date;

    ELSIF k < 0.92 THEN
      -- el admin fija una fecha manual entre hoy-6 y hoy+14
      v_f := v_hoy_ant + (floor(random() * 21)::int - 6);
      BEGIN
        PERFORM public._reloj_actualizar(false, to_char(v_f, 'YYYY-MM-DD'));
        v_ok := true;
      EXCEPTION WHEN SQLSTATE 'P0001' THEN
        v_ok := false; v_msg := SQLERRM;
      END;
      IF v_f >= v_hoy_ant THEN                                           -- el modelo: se acepta si NO retrocede
        IF NOT v_ok THEN v_mal := v_mal + 1; ELSE o_usar := false; o_fecha := v_f; v_exp_hoy := v_f; v_acept := v_acept + 1; END IF;
      ELSE
        IF v_ok OR v_msg <> 'El reloj no puede retroceder' THEN v_mal := v_mal + 1; END IF;
        v_rech := v_rech + 1;
      END IF;

    ELSE
      -- una operacion del libro fechada con el reloj del banco: debe pasar; una fechada dos dias despues: debe fallar
      PERFORM public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c(1), 1));
      v_ops := v_ops + 1;
      BEGIN
        PERFORM public._asentar_grupo(public.ahora_banco() + interval '2 days', tests.g_ingreso(tests.c(1), 1));
        v_mal := v_mal + 1;
      EXCEPTION WHEN SQLSTATE 'P0001' THEN v_ops_fut := v_ops_fut + 1;
      END;
    END IF;

    -- comparacion con el modelo
    IF public.hoy_banco() <> v_exp_hoy THEN v_mal := v_mal + 1; END IF;
    IF public.ahora_banco() <> ((v_exp_hoy + (t AT TIME ZONE 'America/Bogota')::time) AT TIME ZONE 'America/Bogota') THEN v_mal := v_mal + 1; END IF;
    IF (SELECT (i.hoy <> v_exp_hoy OR i.ahora <> ((v_exp_hoy + (t AT TIME ZONE 'America/Bogota')::time) AT TIME ZONE 'America/Bogota')) FROM public._reloj_instantanea() i) THEN v_mal := v_mal + 1; END IF;   -- la instantanea (con tiempo inyectado) coincide con el modelo
    IF (SELECT (usar_fecha_real, fecha_sistema) IS DISTINCT FROM (o_usar, o_fecha) FROM public.reloj) THEN v_mal := v_mal + 1; END IF;
    IF o_usar AND (SELECT fecha_sistema IS NOT NULL FROM public.reloj) THEN v_mal := v_mal + 1; END IF;                -- sin desfase ni fecha guardada en modo real
  END LOOP;
  PERFORM tests.assert_eq('4000 pasos aleatorios: ninguna discrepancia con el modelo (hoy, ahora, aceptacion y rechazo de cada cambio, regla del libro)', v_mal, 0);
  PERFORM tests.assert_true('...hubo de todo: ' || v_acept || ' cambios aceptados, ' || v_rech || ' retrocesos rechazados, ' || v_salidas || ' salidas de simulacion', v_acept > 500 AND v_rech > 100 AND v_salidas > 100);
  PERFORM tests.assert_true('...' || v_salidas_atras || ' de las salidas a fecha real RETROCEDIERON respecto a la simulacion y todas se permitieron', v_salidas_atras > 20);
  PERFORM tests.assert_true('...el paso del tiempo no movio el hoy en modo manual (' || v_manual_estable || ' veces) y paso de medianoche en modo real', v_manual_estable > 100 AND v_tiempo > 1000);
  PERFORM tests.assert_true('...' || v_ops || ' operaciones del libro con el reloj del banco aceptadas y ' || v_ops_fut || ' fechadas despues rechazadas', v_ops > 100 AND v_ops = v_ops_fut);
END $$;
SELECT assert_true('v_integridad_global.ok tras 4000 pasos con tiempo inyectado', (SELECT ok FROM public.v_integridad_global));
SELECT assert_true('cada cambio de reloj efectivo quedo auditado (mas de 500 eventos RELOJ_CAMBIO)', (SELECT count(*) > 500 FROM audit.evento WHERE accion = 'RELOJ_CAMBIO'));

-- Invariante global sobre la bitacora: dentro del modo manual el hoy NUNCA baja (salvo la salida a modo real, que es explicita)
SELECT assert_eq('en toda la bitacora RELOJ_CAMBIO, ningun cambio manual -> manual retrocedio',
                 (SELECT count(*) FROM audit.evento e
                   WHERE e.accion = 'RELOJ_CAMBIO' AND (e.antes ->> 'usar_fecha_real')::boolean = false AND (e.despues ->> 'usar_fecha_real')::boolean = false
                     AND (e.despues ->> 'fecha_sistema')::date < (e.antes ->> 'fecha_sistema')::date), 0::bigint);
SELECT assert_eq('...y ninguna salida a real dejo fecha_sistema guardada', (SELECT count(*) FROM audit.evento e WHERE e.accion = 'RELOJ_CAMBIO' AND (e.despues ->> 'usar_fecha_real')::boolean AND e.despues ->> 'fecha_sistema' IS NOT NULL), 0::bigint);

ROLLBACK;

-- El ROLLBACK restauro la funcion original: con el reloj real sin inyeccion, hoy_banco() vuelve a ser la fecha de Colombia
SELECT assert_eq('tras el ROLLBACK _ahora_real() es otra vez now() (la sustitucion no sobrevive)', (SELECT pg_get_functiondef('public._ahora_real()'::regprocedure) LIKE '%SELECT clock_timestamp()%'), true);
SELECT assert_eq('...y hoy_banco() = fecha actual de America/Bogota', public.hoy_banco(), (now() AT TIME ZONE 'America/Bogota')::date);
