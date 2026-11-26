-- 33_reloj_libro.test.sql · Etapa 3 · regla del libro (D-E3-3): la FECHA de negocio de una pata (en America/Bogota) no puede ser posterior a
-- hoy_banco(). Se compara DATE contra DATE: no depende de la zona de la sesion. Las fechas pasadas se aceptan. Una transaccion con ROLLBACK final.
BEGIN;

SELECT tests.cliente(1);
SELECT tests.cliente(2);
SELECT tests.fondear(tests.c(1), 10000);

CREATE TEMP TABLE t_r AS SELECT (now() AT TIME ZONE 'America/Bogota')::date AS r;
-- instante de una fecha de Bogota y una hora local
CREATE FUNCTION pg_temp.ts(p_dias int, p_hora time) RETURNS timestamptz LANGUAGE sql STABLE AS $$ SELECT ((r + p_dias) + p_hora) AT TIME ZONE 'America/Bogota' FROM t_r $$;
CREATE FUNCTION pg_temp.ing(p_fecha timestamptz) RETURNS uuid LANGUAGE sql AS $$ SELECT public._asentar_grupo(p_fecha, tests.g_ingreso(tests.c(1), 1)) $$;

-- ============================================================================
-- 1. Reloj real: pasado y hoy si; manana no
-- ============================================================================
SELECT assert_ok('una pata fechada ahora', $$SELECT pg_temp.ing(now())$$);
SELECT assert_ok('fechada ayer a mediodia (pasado)', $$SELECT pg_temp.ing(pg_temp.ts(-1, '12:00'))$$);
SELECT assert_ok('fechada hace 400 dias (el cobro lazy y el seed fechan en el pasado)', $$SELECT pg_temp.ing(pg_temp.ts(-400, '00:00'))$$);
SELECT assert_ok('fechada hoy a las 00:00:00 de Bogota', $$SELECT pg_temp.ing(pg_temp.ts(0, '00:00:00'))$$);
SELECT assert_ok('fechada HOY a las 23:59:59.999999 de Bogota: es la misma FECHA que hoy_banco() (se compara fecha, no hora)', $$SELECT pg_temp.ing(pg_temp.ts(0, '23:59:59.999999'))$$);
SELECT assert_raises('fechada manana a las 00:00:00 de Bogota: posterior al reloj', $$SELECT pg_temp.ing(pg_temp.ts(1, '00:00:00'))$$, '%fecha de la pata%posterior al reloj del banco%', 'P0001');
SELECT assert_raises('fechada manana a mediodia', $$SELECT pg_temp.ing(pg_temp.ts(1, '12:00'))$$, '%posterior al reloj del banco%', 'P0001');
SELECT assert_raises('fechada dentro de un año', $$SELECT pg_temp.ing(pg_temp.ts(365, '12:00'))$$, '%posterior al reloj del banco%', 'P0001');
SELECT assert_eq('el mensaje trae ambas fechas (la de la pata y el hoy del banco)',
                 (SELECT m FROM (SELECT tests.captura($$SELECT pg_temp.ing(pg_temp.ts(3, '10:00'))$$) AS m) x) ~ ('la fecha de la pata \(' || to_char((SELECT r + 3 FROM t_r), 'YYYY-MM-DD') || '\) es posterior al reloj del banco \(' || to_char((SELECT r FROM t_r), 'YYYY-MM-DD') || '\)'), true);

-- La comparacion es independiente de la zona de la SESION
DO $$
DECLARE z text; v_mal int := 0;
BEGIN
  FOREACH z IN ARRAY ARRAY['UTC', 'Asia/Tokyo', 'America/Los_Angeles', 'Pacific/Kiritimati', 'Pacific/Pago_Pago'] LOOP
    PERFORM set_config('TimeZone', z, true);
    BEGIN PERFORM pg_temp.ing(pg_temp.ts(0, '23:59:59')); EXCEPTION WHEN OTHERS THEN v_mal := v_mal + 1; END;        -- hoy en Bogota: debe pasar
    BEGIN PERFORM pg_temp.ing(pg_temp.ts(-1, '12:00')); EXCEPTION WHEN OTHERS THEN v_mal := v_mal + 1; END;          -- ayer: debe pasar
    BEGIN PERFORM pg_temp.ing(pg_temp.ts(1, '00:00:01')); v_mal := v_mal + 1; EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL; END;   -- manana en Bogota: debe fallar
  END LOOP;
  PERFORM tests.assert_eq('la regla da el mismo resultado con la TimeZone de la sesion en UTC, Tokio, Los Angeles, Kiritimati y Pago Pago', v_mal, 0);
END $$;

-- ============================================================================
-- 2. Reloj manual adelantado: la fecha de las operaciones es ahora_banco()
-- ============================================================================
SELECT public._reloj_actualizar(false, to_char((SELECT r + 30 FROM t_r), 'YYYY-MM-DD'));
SELECT assert_ok('manual(R+30): una pata fechada con ahora_banco() pasa', $$SELECT pg_temp.ing(public.ahora_banco())$$);
SELECT assert_ok('manual(R+30): una pata fechada R+30 a las 23:59 pasa (misma fecha que el hoy del banco)', $$SELECT pg_temp.ing(pg_temp.ts(30, '23:59:59'))$$);
SELECT assert_ok('manual(R+30): una pata con la fecha REAL de hoy es pasada para el banco: pasa', $$SELECT pg_temp.ing(now())$$);
SELECT assert_raises('manual(R+30): R+31 es posterior al reloj', $$SELECT pg_temp.ing(pg_temp.ts(31, '00:00:00'))$$, '%posterior al reloj del banco%', 'P0001');
SELECT assert_ok('manual(R+30): una operacion de varias patas (transferencia) fechada con ahora_banco()',
                 $$SELECT public._asentar_grupo(public.ahora_banco(), tests.g_envio(tests.c(1), tests.c(2), 5))$$);
SELECT assert_eq('manual: la pata quedo fechada R+30 (fecha de negocio) y registrada hoy (hora real)',
                 (SELECT ((fecha AT TIME ZONE 'America/Bogota')::date = r + 30, (registrado_en AT TIME ZONE 'America/Bogota')::date = r)::text FROM public.transaccion, t_r WHERE tipo = 'ENVIO'), '(t,t)'::text);

-- ============================================================================
-- 3. Volver a fecha real: el historial permanece, la regla vuelve a regir con el hoy real
-- ============================================================================
SELECT assert_eq('antes de volver: 6 patas fechadas en R+30 (2 ingresos y 1 transferencia, de 2 patas cada uno)', (SELECT count(*) FROM public.transaccion WHERE (fecha AT TIME ZONE 'America/Bogota')::date = (SELECT r + 30 FROM t_r)), 6::bigint);
SELECT public._reloj_actualizar(true, '');
SELECT assert_eq('de vuelta a real: hoy_banco() = fecha de Colombia', public.hoy_banco(), (SELECT r FROM t_r));
SELECT assert_eq('las 6 patas fechadas en R+30 PERMANECEN (no se borran, revierten ni recalculan)', (SELECT count(*) FROM public.transaccion WHERE (fecha AT TIME ZONE 'America/Bogota')::date = (SELECT r + 30 FROM t_r)), 6::bigint);
SELECT assert_eq('v_reloj_estado cuenta las patas fechadas en el futuro del reloj actual (informativo)', (SELECT patas_fechadas_en_el_futuro FROM public.v_reloj_estado), 6::bigint);
SELECT assert_true('...y eso NO es un error: v_integridad_global.ok sigue en true', (SELECT ok FROM public.v_integridad_global));
SELECT assert_eq('...ni los grupos fechados en el futuro estan en error', (SELECT count(*) FROM public.v_integridad_grupos WHERE NOT ok), 0::bigint);
SELECT assert_raises('una pata NUEVA fechada R+30 ya no se acepta (es futuro para el reloj real)', $$SELECT pg_temp.ing(pg_temp.ts(30, '12:00'))$$, '%posterior al reloj del banco%', 'P0001');
SELECT assert_ok('...pero una fechada hoy si', $$SELECT pg_temp.ing(now())$$);
SELECT assert_eq('saldos intactos y exactos: 10000 + 19 ingresos de 1 peso aceptados - 5 de la transferencia',
                 (SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(1)), 10014::numeric);

-- ============================================================================
-- 4. Sin triggers (sabotaje): las patas futuras se SENALAN con v_reloj_estado
-- ============================================================================
SELECT tests.detecta('una pata insertada con los triggers apagados y fechada en el futuro se cuenta en v_reloj_estado',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER USER; INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, saldo_previo, saldo_posterior, cuenta_id)
        VALUES (gen_random_uuid(), now() + interval '5 days', 'DEPOSITO_BANCO', 'CUENTA', 'E', 1, 0, 1, tests.c(2))$s$,
   $d$SELECT (SELECT patas_fechadas_en_el_futuro FROM public.v_reloj_estado) = 7$d$);

ROLLBACK;
