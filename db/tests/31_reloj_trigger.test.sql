-- 31_reloj_trigger.test.sql · Etapa 3 · D4 = opcion A (aprobada por el equipo): en modo MANUAL el reloj solo puede adelantarse
-- ("El reloj no puede retroceder"); pasar a modo REAL siempre esta permitido, aunque la fecha real sea anterior a la simulada;
-- sin desfase. Matriz completa de transiciones, ciclos repetidos, entradas invalidas, ataques directos y auditoria.
-- Una sola transaccion con ROLLBACK final. El banco NO esta vacio (hay patas), asi que rige la regla completa.
BEGIN;

SELECT tests.cliente(1);
SELECT tests.fondear(tests.c(1), 1000);                 -- ya hay patas: ya no vale la clausula de banco vacio

CREATE TEMP TABLE t_r AS SELECT (now() AT TIME ZONE 'America/Bogota')::date AS r;        -- fecha real de Colombia (constante)
CREATE FUNCTION pg_temp.d(p_n int) RETURNS date LANGUAGE sql STABLE AS $$ SELECT r + p_n FROM t_r $$;
CREATE FUNCTION pg_temp.t(p_n int) RETURNS text LANGUAGE sql STABLE AS $$ SELECT to_char(r + p_n, 'YYYY-MM-DD') FROM t_r $$;
CREATE FUNCTION pg_temp.estado() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT (usar_fecha_real, fecha_sistema, public.hoy_banco())::text FROM public.reloj $$;
CREATE FUNCTION pg_temp.eventos() RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT count(*) FROM audit.evento WHERE accion = 'RELOJ_CAMBIO' $$;

SELECT assert_eq('punto de partida: modo real, fecha_sistema NULL, hoy = fecha real', (SELECT (usar_fecha_real, fecha_sistema IS NULL, public.hoy_banco() = r)::text FROM public.reloj, t_r), '(t,t,t)'::text);
SELECT assert_eq('el banco NO esta vacio (hay patas): rige la regla completa', (SELECT count(*) > 0 FROM public.transaccion), true);

-- ============================================================================
-- 1. Las transiciones pedidas (D4 = A)
-- ============================================================================
-- (1) Fecha real -> manual con fecha futura
SELECT assert_eq('1) real -> manual(+30): permitido y el hoy pasa a ser R+30', public._reloj_actualizar(false, pg_temp.t(30)) ->> 'fecha_actual', pg_temp.t(30));
SELECT assert_eq('   estado: manual, fecha_sistema = R+30', (SELECT (usar_fecha_real, fecha_sistema = pg_temp.d(30))::text FROM public.reloj), '(f,t)'::text);
-- (2) Manual -> otra fecha manual mas adelantada
SELECT assert_eq('2) manual(+30) -> manual(+60): permitido', public._reloj_actualizar(false, pg_temp.t(60)) ->> 'fecha_actual', pg_temp.t(60));
SELECT assert_ok('   manual(+60) -> manual(+60): repetir la misma fecha es un no-op permitido', $$SELECT public._reloj_actualizar(false, pg_temp.t(60))$$);
SELECT assert_raises('   manual(+60) -> manual(+59): RETROCESO rechazado con el mensaje exacto del contrato', $$SELECT public._reloj_actualizar(false, pg_temp.t(59))$$, 'El reloj no puede retroceder', 'P0001');
SELECT assert_raises('   manual(+60) -> manual(R): RETROCESO a la fecha real, tambien rechazado (sigue en modo manual)', $$SELECT public._reloj_actualizar(false, pg_temp.t(0))$$, 'El reloj no puede retroceder', 'P0001');
SELECT assert_raises('   manual(+60) -> manual(ayer): rechazado', $$SELECT public._reloj_actualizar(false, pg_temp.t(-1))$$, 'El reloj no puede retroceder', 'P0001');
SELECT assert_eq('   el rechazo no cambio nada: sigue manual en R+60', (SELECT (usar_fecha_real, fecha_sistema = pg_temp.d(60), public.hoy_banco() = pg_temp.d(60))::text FROM public.reloj), '(f,t,t)'::text);
-- (3) Manual -> fecha real anterior a la simulada
SELECT assert_eq('3) manual(+60) -> REAL: SIEMPRE permitido aunque la fecha real (R) sea anterior a la simulada (R+60)',
                 public._reloj_actualizar(true, '') ->> 'fecha_actual', pg_temp.t(0));
SELECT assert_eq('   vuelve inmediatamente a la fecha real de Colombia y NO queda ningun desfase ni fecha guardada',
                 (SELECT (usar_fecha_real, fecha_sistema IS NULL, public.hoy_banco() = r)::text FROM public.reloj, t_r), '(t,t,t)'::text);
SELECT assert_eq('   el contrato devuelve fecha_sistema null en modo real', public._reloj_vista() -> 'fecha_sistema', 'null'::jsonb);
-- (4) Fecha real -> manual con una fecha posterior a la real pero ANTERIOR a una fecha simulada usada antes
SELECT assert_eq('4) real -> manual(+10): permitido aunque +10 sea anterior a la simulada anterior (+60)', public._reloj_actualizar(false, pg_temp.t(10)) ->> 'fecha_actual', pg_temp.t(10));
SELECT assert_raises('   ...y desde ahi, retroceder a +9 se rechaza (el retroceso se compara con el hoy ACTUAL, no con el historial de simulaciones)', $$SELECT public._reloj_actualizar(false, pg_temp.t(9))$$, 'El reloj no puede retroceder', 'P0001');
SELECT assert_ok('   adelantar a +11 si se puede', $$SELECT public._reloj_actualizar(false, pg_temp.t(11))$$);
-- real -> manual con fecha anterior al hoy real: tambien es "una fecha anterior a hoy_banco()"
SELECT assert_ok('   (volver a real para el siguiente caso)', $$SELECT public._reloj_actualizar(true, '')$$);
SELECT assert_raises('   real -> manual(ayer): una fecha anterior a hoy_banco() se rechaza', $$SELECT public._reloj_actualizar(false, pg_temp.t(-1))$$, 'El reloj no puede retroceder', 'P0001');
SELECT assert_ok('   real -> manual(hoy): igual al hoy real es valido (no retrocede)', $$SELECT public._reloj_actualizar(false, pg_temp.t(0))$$);
SELECT assert_ok('   manual(hoy) -> real: no-op de fecha, permitido', $$SELECT public._reloj_actualizar(true, '')$$);
SELECT assert_ok('   real -> real: idempotente (el front manda fecha_sistema aunque sea real: se ignora)', $$SELECT public._reloj_actualizar(true, '2031-05-05')$$);
SELECT assert_eq('   ...y esa fecha basura NO se guardo', (SELECT fecha_sistema IS NULL FROM public.reloj), true);

-- ============================================================================
-- 2. (5) Ciclos repetidos de adelanto y retorno a fecha real
-- ============================================================================
DO $$
DECLARE
  i int; j int; v_ok int := 0; v_rech int := 0; v_mal int := 0; v_retro_salida int := 0;
  v_off int; v_hoy_ant date; v_r date;
BEGIN
  SELECT r INTO v_r FROM t_r;
  PERFORM setseed(0.31);
  FOR i IN 1..60 LOOP
    -- adelantar: +1.. +400 dias, y luego varios intentos dentro del modo manual (algunos retroceden, otros no)
    v_off := 1 + floor(random() * 400)::int;
    PERFORM public._reloj_actualizar(false, to_char(v_r + v_off, 'YYYY-MM-DD'));
    v_ok := v_ok + 1;
    IF public.hoy_banco() <> v_r + v_off THEN v_mal := v_mal + 1; END IF;
    FOR j IN 1..4 LOOP
      v_hoy_ant := public.hoy_banco();
      v_off := floor(random() * 500)::int - 50;          -- puede ser menor, igual o mayor que el hoy actual
      BEGIN
        PERFORM public._reloj_actualizar(false, to_char(v_r + v_off, 'YYYY-MM-DD'));
        IF v_r + v_off < v_hoy_ant THEN v_mal := v_mal + 1; END IF;                 -- se acepto un retroceso: MAL
        IF public.hoy_banco() < v_hoy_ant THEN v_mal := v_mal + 1; END IF;
        v_ok := v_ok + 1;
      EXCEPTION WHEN SQLSTATE 'P0001' THEN
        IF SQLERRM <> 'El reloj no puede retroceder' THEN v_mal := v_mal + 1; END IF;
        IF v_r + v_off >= v_hoy_ant THEN v_mal := v_mal + 1; END IF;                -- se rechazo algo que NO retrocedia: MAL
        IF public.hoy_banco() <> v_hoy_ant THEN v_mal := v_mal + 1; END IF;         -- el rechazo cambio el estado: MAL
        v_rech := v_rech + 1;
      END;
    END LOOP;
    -- retorno a fecha real: SIEMPRE permitido, aunque retroceda respecto a la simulacion
    v_hoy_ant := public.hoy_banco();
    PERFORM public._reloj_actualizar(true, to_char(v_r + 999, 'YYYY-MM-DD'));
    IF public.hoy_banco() <> v_r THEN v_mal := v_mal + 1; END IF;
    IF v_hoy_ant > v_r THEN v_retro_salida := v_retro_salida + 1; END IF;
    IF (SELECT fecha_sistema FROM public.reloj) IS NOT NULL THEN v_mal := v_mal + 1; END IF;
    v_ok := v_ok + 1;
  END LOOP;
  PERFORM tests.assert_eq('60 ciclos adelanto/retorno: ninguna discrepancia con el modelo (retroceso rechazado solo dentro del modo manual; todo lo demas aceptado)', v_mal, 0);
  PERFORM tests.assert_true('...hubo rechazos de retroceso (' || v_rech || ') y aceptaciones (' || v_ok || ')', v_rech > 20 AND v_ok > 120);
  PERFORM tests.assert_eq('...y las 60 salidas de la simulacion volvieron a la fecha real aunque retrocedieran (todas permitidas)', v_retro_salida, 60);
END $$;
SELECT assert_eq('tras los ciclos: modo real, sin fecha guardada, hoy = fecha real', (SELECT (usar_fecha_real, fecha_sistema IS NULL, public.hoy_banco() = r)::text FROM public.reloj, t_r), '(t,t,t)'::text);

-- ============================================================================
-- 3. Entradas invalidas: "Fecha inválida" (P0001, provisional hasta D13); nada cambia
-- ============================================================================
SELECT assert_raises('fecha vacia en modo manual', $$SELECT public._reloj_actualizar(false, '')$$, 'Fecha inválida', 'P0001');
SELECT assert_raises('fecha NULL en modo manual', $$SELECT public._reloj_actualizar(false, NULL)$$, 'Fecha inválida', 'P0001');
SELECT assert_raises('texto que no es fecha', $$SELECT public._reloj_actualizar(false, 'abc')$$, 'Fecha inválida', 'P0001');
SELECT assert_raises('formato incorrecto (dd-mm-aaaa)', $$SELECT public._reloj_actualizar(false, '21-11-2026')$$, 'Fecha inválida', 'P0001');
SELECT assert_raises('fecha inexistente (30 de febrero)', $$SELECT public._reloj_actualizar(false, '2027-02-30')$$, 'Fecha inválida', 'P0001');
SELECT assert_raises('mes 13', $$SELECT public._reloj_actualizar(false, '2027-13-01')$$, 'Fecha inválida', 'P0001');
SELECT assert_raises('con hora (no es solo fecha)', $$SELECT public._reloj_actualizar(false, '2027-01-01 10:00')$$, 'Fecha inválida', 'P0001');
SELECT assert_raises('anterior a 2000-01-01', $$SELECT public._reloj_actualizar(false, '1999-12-31')$$, 'Fecha inválida', 'P0001');
SELECT assert_raises('posterior a 2100-12-31', $$SELECT public._reloj_actualizar(false, '2101-01-01')$$, 'Fecha inválida', 'P0001');
SELECT assert_ok('el limite superior 2100-12-31 es valido', $$SELECT public._reloj_actualizar(false, '2100-12-31')$$);
SELECT assert_raises('...y desde ahi cualquier fecha menor retrocede', $$SELECT public._reloj_actualizar(false, '2100-12-30')$$, 'El reloj no puede retroceder', 'P0001');
SELECT assert_ok('(volver a real)', $$SELECT public._reloj_actualizar(true, NULL)$$);
SELECT assert_raises('usar_fecha_real NULL', $$SELECT public._reloj_actualizar(NULL, '2027-01-01')$$, 'Reloj: usar_fecha_real es obligatorio', 'P0001');
SELECT assert_ok('modo real con fecha invalida: se ignora la fecha y es valido', $$SELECT public._reloj_actualizar(true, 'esto no es una fecha')$$);
SELECT assert_eq('espacios alrededor de una fecha valida se toleran', public._reloj_actualizar(false, '  ' || pg_temp.t(2) || ' ') ->> 'fecha_actual', pg_temp.t(2));
SELECT assert_ok('(volver a real)', $$SELECT public._reloj_actualizar(true, '')$$);

-- ============================================================================
-- 4. El trigger rige a CUALQUIERA que haga UPDATE directo
-- ============================================================================
SELECT assert_ok('superusuario: UPDATE directo a manual(+20)', $$UPDATE public.reloj SET usar_fecha_real = false, fecha_sistema = (SELECT r + 20 FROM t_r)$$);
SELECT assert_raises('superusuario: UPDATE directo que retrocede a +10', $$UPDATE public.reloj SET fecha_sistema = (SELECT r + 10 FROM t_r)$$, 'El reloj no puede retroceder', 'P0001');
SELECT assert_raises('banco_owner: UPDATE directo que retrocede (aunque tenga el privilegio de columna)', $$SET LOCAL ROLE banco_owner; UPDATE public.reloj SET fecha_sistema = (now() AT TIME ZONE 'America/Bogota')::date + 10$$, 'El reloj no puede retroceder', 'P0001');
SELECT assert_ok('banco_owner: UPDATE directo que adelanta', $$SET LOCAL ROLE banco_owner; UPDATE public.reloj SET fecha_sistema = (now() AT TIME ZONE 'America/Bogota')::date + 25$$);
SELECT assert_ok('superusuario: UPDATE directo a modo real con una fecha: la fecha se fuerza a NULL (sin desfase)', $$UPDATE public.reloj SET usar_fecha_real = true, fecha_sistema = DATE '2040-01-01'$$);
SELECT assert_eq('...y quedo NULL', (SELECT fecha_sistema IS NULL FROM public.reloj), true);
SELECT assert_raises('UPDATE a manual sin fecha', $$UPDATE public.reloj SET usar_fecha_real = false$$, 'Fecha inválida', 'P0001');
SELECT assert_violates('fecha fuera de rango por UPDATE directo (CHECK de rango)', $$UPDATE public.reloj SET usar_fecha_real = false, fecha_sistema = DATE '2101-01-01'$$, 'ck_reloj_fecha_rango');
SELECT assert_raises('fecha anterior a 2000 por UPDATE directo: con el banco no vacio es antes que nada un retroceso (con el banco vacio la ataja el CHECK: ver 32)', $$UPDATE public.reloj SET usar_fecha_real = false, fecha_sistema = DATE '1999-12-31'$$, 'El reloj no puede retroceder', 'P0001');
SELECT assert_raises('el id es inmutable', $$UPDATE public.reloj SET id = 2$$, NULL);
SELECT assert_raises('banco_owner NO puede cambiar el id (sin privilegio de columna)', $$SET LOCAL ROLE banco_owner; UPDATE public.reloj SET id = 2$$, 'permission denied for table reloj', '42501');
SELECT assert_raises('banco_app: UPDATE del reloj', $$SET LOCAL ROLE banco_app; UPDATE public.reloj SET usar_fecha_real = true$$, 'permission denied for table reloj', '42501');
SELECT assert_raises('banco_app: ni siquiera lee el reloj', $$SET LOCAL ROLE banco_app; SELECT * FROM public.reloj$$, 'permission denied for table reloj', '42501');
SELECT assert_raises('banco_lector: UPDATE del reloj', $$SET LOCAL ROLE banco_lector; UPDATE public.reloj SET usar_fecha_real = true$$, 'permission denied for table reloj', '42501');
SELECT assert_raises('banco_dev: UPDATE del reloj', $$SET LOCAL ROLE banco_dev; UPDATE public.reloj SET usar_fecha_real = true$$, 'permission denied for table reloj', '42501');
SELECT assert_ok('banco_lector lee el reloj', $$SET LOCAL ROLE banco_lector; SELECT * FROM public.reloj; SELECT * FROM public.v_reloj_estado$$);
SELECT assert_raises('banco_ledger no toca el reloj', $$SET LOCAL ROLE banco_ledger; UPDATE public.reloj SET usar_fecha_real = true$$, 'permission denied for table reloj', '42501');

-- registro unico permanente
SELECT assert_raises('DELETE del reloj (superusuario)', $$DELETE FROM public.reloj$$, '%no se puede borrar%', 'P0001');
SELECT assert_raises('DELETE del reloj (banco_owner tiene el privilegio, el trigger lo rechaza)', $$SET LOCAL ROLE banco_owner; DELETE FROM public.reloj$$, '%no se puede borrar%', 'P0001');
SELECT assert_raises('TRUNCATE del reloj', $$TRUNCATE public.reloj$$, '%no se puede vaciar%', 'P0001');
SELECT assert_raises('TRUNCATE ... CASCADE desde otra tabla no vacia el reloj', $$TRUNCATE public.reloj CASCADE$$, '%no se puede vaciar%', 'P0001');
SELECT assert_violates('una segunda fila (id 2)', $$INSERT INTO public.reloj (id) VALUES (2)$$, 'ck_reloj_fila_unica');
SELECT assert_violates('repetir el id 1', $$INSERT INTO public.reloj (id) VALUES (1)$$, 'pk_reloj', '23505');
SELECT assert_ok('INSERT ... ON CONFLICT DO NOTHING (la siembra idempotente de 03_schema.sql) sigue siendo un no-op', $$INSERT INTO public.reloj (id, usar_fecha_real) VALUES (1, true) ON CONFLICT (id) DO NOTHING$$);
SELECT assert_eq('sigue habiendo UNA sola fila', (SELECT count(*) FROM public.reloj), 1::bigint);

-- ============================================================================
-- 5. Auditoria de cada cambio (RELOJ_CAMBIO)
-- ============================================================================
CREATE TEMP TABLE t_ev AS SELECT pg_temp.eventos() AS n;
SELECT public._reloj_actualizar(true, '');                          -- ya estaba en real: no hay cambio
SELECT assert_eq('real -> real (sin cambio) NO audita', pg_temp.eventos() - (SELECT n FROM t_ev), 0::bigint);
SELECT set_config('banco.actor', 'admin1', true);
SELECT public._reloj_actualizar(false, pg_temp.t(40));
SELECT assert_eq('un cambio real -> manual audita UN evento', pg_temp.eventos() - (SELECT n FROM t_ev), 1::bigint);
SELECT assert_eq('...con el actor (atribucion), el estado y el hoy del banco antes y despues',
                 (SELECT (actor_username, antes ->> 'usar_fecha_real', despues ->> 'usar_fecha_real', antes ->> 'hoy_banco' = to_char(r, 'YYYY-MM-DD'), despues ->> 'hoy_banco' = to_char(r + 40, 'YYYY-MM-DD'),
                          despues ->> 'fecha_sistema' = to_char(r + 40, 'YYYY-MM-DD'), antes ->> 'fecha_sistema' IS NULL)::text
                    FROM audit.evento, t_r WHERE accion = 'RELOJ_CAMBIO' ORDER BY orden DESC LIMIT 1),
                 '(admin1,true,false,t,t,t,t)'::text);
SELECT assert_raises('un retroceso rechazado', $$SELECT public._reloj_actualizar(false, pg_temp.t(39))$$, 'El reloj no puede retroceder', 'P0001');
SELECT assert_eq('...NO deja evento (el rechazo es atomico con la auditoria)', pg_temp.eventos() - (SELECT n FROM t_ev), 1::bigint);
SELECT public._reloj_actualizar(true, '');                          -- manual -> real
SELECT assert_eq('manual -> real audita otro evento: el hoy baja de R+40 a R y queda registrado',
                 (SELECT (pg_temp.eventos() - (SELECT n FROM t_ev), (SELECT despues ->> 'hoy_banco' = to_char(r, 'YYYY-MM-DD') AND antes ->> 'hoy_banco' = to_char(r + 40, 'YYYY-MM-DD')
                                                          FROM audit.evento, t_r WHERE accion = 'RELOJ_CAMBIO' ORDER BY orden DESC LIMIT 1))::text), '(2,t)'::text);
SELECT assert_eq('el estado final es real', (SELECT usar_fecha_real FROM public.reloj), true);

ROLLBACK;
