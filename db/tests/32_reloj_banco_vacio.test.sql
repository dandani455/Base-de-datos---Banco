-- 32_reloj_banco_vacio.test.sql · Etapa 3 · clausula de banco vacio (D5 / D-E3-2): mientras NO exista ninguna fila en transaccion el reloj
-- puede moverse hacia atras (el seed arranca ~120 dias en el pasado con funciones reales y luego avanza). En cuanto existe UNA pata, rige la
-- regla completa de la opcion A. Una sola transaccion con ROLLBACK final.
BEGIN;

CREATE TEMP TABLE t_r AS SELECT (now() AT TIME ZONE 'America/Bogota')::date AS r;
CREATE FUNCTION pg_temp.t(p_n int) RETURNS text LANGUAGE sql STABLE AS $$ SELECT to_char(r + p_n, 'YYYY-MM-DD') FROM t_r $$;

SELECT assert_eq('banco vacio: ninguna fila en transaccion', (SELECT count(*) FROM public.transaccion), 0::bigint);
SELECT assert_eq('v_reloj_estado: banco_vacio = true', (SELECT banco_vacio FROM public.v_reloj_estado), true);

-- ============================================================================
-- 1. Con el banco vacio el reloj se mueve libremente
-- ============================================================================
SELECT assert_ok('vacio: real -> manual(R-120) (arrancar el seed 120 dias atras)', $$SELECT public._reloj_actualizar(false, pg_temp.t(-120))$$);
SELECT assert_eq('   el hoy del banco es R-120', public.hoy_banco(), (SELECT r - 120 FROM t_r));
SELECT assert_ok('vacio: manual(R-120) -> manual(R-200) (hacia atras)', $$SELECT public._reloj_actualizar(false, pg_temp.t(-200))$$);
SELECT assert_ok('vacio: manual -> manual(R+10) (hacia adelante)', $$SELECT public._reloj_actualizar(false, pg_temp.t(10))$$);
SELECT assert_ok('vacio: manual(R+10) -> manual(R-5)', $$SELECT public._reloj_actualizar(false, pg_temp.t(-5))$$);
SELECT assert_ok('vacio: manual -> real', $$SELECT public._reloj_actualizar(true, '')$$);
SELECT assert_ok('vacio: real -> manual(R-30) (anterior al hoy real)', $$SELECT public._reloj_actualizar(false, pg_temp.t(-30))$$);
SELECT assert_violates('vacio: el rango 2000-2100 sigue rigiendo en UPDATE directo (anterior a 2000)', $$UPDATE public.reloj SET fecha_sistema = DATE '1999-12-31'$$, 'ck_reloj_fecha_rango');
SELECT assert_raises('vacio: y la funcion rechaza fechas fuera de rango con Fecha inválida', $$SELECT public._reloj_actualizar(false, '1999-12-31')$$, 'Fecha inválida', 'P0001');

-- ============================================================================
-- 2. El seed: arrancar en el pasado, operar con funciones reales y avanzar sin retroceder
-- ============================================================================
SELECT assert_ok('(el reloj queda en R-120)', $$SELECT public._reloj_actualizar(false, pg_temp.t(-120))$$);
SELECT tests.cliente(1);
SELECT assert_ok('un ingreso fechado con ahora_banco() (R-120) es VALIDO: la fecha de la pata no es posterior al hoy del banco',
                 $$SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c(1), 500))$$);
SELECT assert_eq('la pata quedo fechada en R-120 (fecha de negocio) y registrada hoy (registrado_en real)',
                 (SELECT ((fecha AT TIME ZONE 'America/Bogota')::date = r - 120, (registrado_en AT TIME ZONE 'America/Bogota')::date = r)::text FROM public.transaccion, t_r WHERE contenedor = 'CUENTA'), '(t,t)'::text);
SELECT assert_eq('banco NO vacio desde la primera pata', (SELECT banco_vacio FROM public.v_reloj_estado), false);

-- ============================================================================
-- 3. Con UNA sola pata rige la regla completa
-- ============================================================================
SELECT assert_raises('con patas: manual(R-120) -> manual(R-121) es un retroceso', $$SELECT public._reloj_actualizar(false, pg_temp.t(-121))$$, 'El reloj no puede retroceder', 'P0001');
SELECT assert_ok('con patas: adelantar si se puede (R-100)', $$SELECT public._reloj_actualizar(false, pg_temp.t(-100))$$);
SELECT assert_raises('con patas: ya no se puede retroceder a R-110', $$SELECT public._reloj_actualizar(false, pg_temp.t(-110))$$, 'El reloj no puede retroceder', 'P0001');
SELECT assert_ok('con patas: volver a real sigue permitido (el hoy pasa de R-100 a R: adelanta)', $$SELECT public._reloj_actualizar(true, '')$$);
SELECT assert_raises('con patas: real -> manual(R-1) es una fecha anterior a hoy_banco()', $$SELECT public._reloj_actualizar(false, pg_temp.t(-1))$$, 'El reloj no puede retroceder', 'P0001');
SELECT assert_ok('con patas: real -> manual(R+50)', $$SELECT public._reloj_actualizar(false, pg_temp.t(50))$$);
SELECT assert_ok('con patas: manual(R+50) -> real (retrocede de R+50 a R, siempre permitido)', $$SELECT public._reloj_actualizar(true, '')$$);

-- ============================================================================
-- 4. Si el banco vuelve a quedar vacio (cascada de cuenta), la clausula vuelve a aplicar
-- ============================================================================
DELETE FROM public.usuario WHERE id = tests.u(1);
SELECT assert_eq('tras borrar al unico cliente el banco vuelve a estar vacio', (SELECT (count(*), (SELECT banco_vacio FROM public.v_reloj_estado))::text FROM public.transaccion), '(0,t)'::text);
SELECT assert_ok('...y el reloj puede otra vez moverse hacia atras (real -> manual(R-90))', $$SELECT public._reloj_actualizar(false, pg_temp.t(-90))$$);
SELECT assert_ok('...y manual(R-90) -> manual(R-95)', $$SELECT public._reloj_actualizar(false, pg_temp.t(-95))$$);

-- ============================================================================
-- 5. Seed completo simulado: avanzar por etapas con clientes reales sin ningun retroceso
-- ============================================================================
SELECT assert_ok('(reloj a R-120 con el banco vacio)', $$SELECT public._reloj_actualizar(false, pg_temp.t(-120))$$);
SELECT tests.cliente(2);
SELECT tests.cliente(3);
SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c(2), 1000));
DO $$
DECLARE d int; v_mal int := 0;
BEGIN
  FOR d IN SELECT g FROM generate_series(-110, 0, 10) g LOOP
    PERFORM public._reloj_actualizar(false, to_char((SELECT r FROM t_r) + d, 'YYYY-MM-DD'));
    PERFORM public._asentar_grupo(public.ahora_banco(), tests.g_envio(tests.c(2), tests.c(3), 1));       -- operaciones fechadas en el dia simulado
    IF public.hoy_banco() <> (SELECT r FROM t_r) + d THEN v_mal := v_mal + 1; END IF;
  END LOOP;
  PERFORM tests.assert_eq('seed: de R-120 a R en 11 etapas con operaciones reales fechadas en cada dia simulado, sin retrocesos ni errores', v_mal, 0);
END $$;
SELECT assert_eq('...las patas quedaron fechadas desde R-120 hasta R, todas con fecha <= hoy', (SELECT (min((fecha AT TIME ZONE 'America/Bogota')::date) = (SELECT r - 120 FROM t_r), max((fecha AT TIME ZONE 'America/Bogota')::date) = (SELECT r FROM t_r))::text FROM public.transaccion), '(t,t)'::text);
SELECT assert_ok('...y al terminar se puede volver a la fecha real (R): no cambia nada del historial', $$SELECT public._reloj_actualizar(true, '')$$);
SELECT assert_eq('...sin patas fechadas en el futuro (el seed termino en R)', (SELECT patas_fechadas_en_el_futuro FROM public.v_reloj_estado), 0::bigint);
SELECT assert_true('...y la integridad esta en orden', (SELECT ok FROM public.v_integridad_global));

ROLLBACK;
