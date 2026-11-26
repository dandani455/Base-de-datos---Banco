-- 18_libro_aislamiento.test.sql · Etapa 2 · nivel de aislamiento exigido por _asentar_grupo, rendimiento del libro y uso de indices.
-- Cada bloque con un nivel de aislamiento especial es su propia transaccion (SET TRANSACTION debe ser la primera sentencia).

-- ============================================================================
-- 1. _asentar_grupo exige READ COMMITTED (FOR NO KEY UPDATE daria 40001 en otros niveles)
-- ============================================================================
BEGIN ISOLATION LEVEL REPEATABLE READ;
DO $$
BEGIN
  BEGIN
    PERFORM public._asentar_grupo(now(), '[]'::jsonb);
    RAISE EXCEPTION 'FAIL: REPEATABLE READ: _asentar_grupo debia rechazar el nivel de aislamiento';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%READ COMMITTED%repeatable read%' THEN RAISE NOTICE 'PASS: REPEATABLE READ se rechaza con un mensaje claro (P0001, no un 40001 que el backend veria como 503)';
    ELSE RAISE EXCEPTION 'FAIL: mensaje inesperado: %', SQLERRM; END IF;
  END;
END $$;
ROLLBACK;

BEGIN ISOLATION LEVEL SERIALIZABLE;
DO $$
BEGIN
  BEGIN
    PERFORM public._asentar_grupo(now(), '[]'::jsonb);
    RAISE EXCEPTION 'FAIL: SERIALIZABLE: _asentar_grupo debia rechazar el nivel de aislamiento';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM LIKE '%READ COMMITTED%serializable%' THEN RAISE NOTICE 'PASS: SERIALIZABLE se rechaza con un mensaje claro (P0001)';
    ELSE RAISE EXCEPTION 'FAIL: mensaje inesperado: %', SQLERRM; END IF;
  END;
END $$;
ROLLBACK;

BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT assert_raises('READ COMMITTED pasa la validacion de aislamiento (falla despues, por el JSON vacio)',
                     $$SELECT public._asentar_grupo(now(), '[]'::jsonb)$$, '%al menos dos patas%', 'P0001');
ROLLBACK;

-- ============================================================================
-- 2. Rendimiento y uso de indices (~6.000 patas). Cada grupo va en SU PROPIA transaccion (autocommit, via \gexec), como
--    ocurre con el backend: asentar miles de grupos dentro de UNA transaccion acumularia miles de subtransacciones y no
--    seria representativo. Los datos se crean con clientes 801 y 802 y se eliminan al final (cascada, con auditoria).
-- ============================================================================
SELECT tests.cliente(801);
SELECT tests.cliente(802);
SELECT tests.fondear(tests.c(801), 1000000);
SELECT tests.cliente(803);
SELECT tests.fondear(tests.c(803), 10);      -- cuenta con pocas patas, para el plan del historial

CREATE TEMP TABLE t_tiempo AS SELECT clock_timestamp() AS t0;
\o /dev/null
SELECT format('SELECT public._asentar_grupo(now(), tests.g_envio(%L, %L, 1))',
              CASE WHEN g % 2 = 1 THEN tests.c(801) ELSE tests.c(802) END, CASE WHEN g % 2 = 1 THEN tests.c(802) ELSE tests.c(801) END)
  FROM generate_series(1, 3000) g
\gexec
\o

SELECT assert_eq('se asentaron 3000 grupos (6000 patas) mas el ingreso inicial (2 patas)',
                 (SELECT count(*) FROM public.transaccion WHERE cuenta_id IN (tests.c(801), tests.c(802))), 6002::bigint);
SELECT assert_true('3000 grupos de 2 patas, cada uno en su transaccion, se asientan en menos de 60 s (todos los triggers, bloqueos y el cuadre inmediato)',
                   (SELECT clock_timestamp() - t0 < interval '60 seconds' FROM t_tiempo));
SELECT assert_eq('saldos exactos tras 3000 transferencias cruzadas: 1.000.000 en la cuenta 801 y 0 en la 802',
                 ((SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(801)), (SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(802)))::text, '(1000000.00,0.00)'::text);
SELECT assert_true('v_integridad_global ok tras 6.000 patas', (SELECT ok FROM public.v_integridad_global));
DO $$ BEGIN RAISE NOTICE 'RENDIMIENTO: 3000 grupos (6000 patas) en % ms (% ms por grupo)',
  round(extract(epoch FROM (clock_timestamp() - (SELECT t0 FROM t_tiempo))) * 1000), round(extract(epoch FROM (clock_timestamp() - (SELECT t0 FROM t_tiempo))) * 1000 / 3000, 2); END $$;

BEGIN;
ANALYZE public.transaccion;
SET LOCAL enable_seqscan = off;
SELECT assert_true('el cuadre de un grupo (WHERE grupo_id = ?) usa ix_transaccion_grupo, no un barrido de la tabla',
                   (SELECT bool_or(l LIKE '%ix_transaccion_grupo%') FROM tests.plan($$SELECT count(*) FROM public.transaccion WHERE grupo_id = 'aaaaaaaa-0000-4000-8000-000000000001'$$) l));
SELECT assert_true('el historial de una cuenta con pocas patas (WHERE cuenta_id = ? ORDER BY orden DESC) usa ix_transaccion_cuenta_orden',
                   (SELECT bool_or(l LIKE '%ix_transaccion_cuenta_orden%') FROM tests.plan($$SELECT * FROM public.transaccion WHERE cuenta_id = '20000000-0000-4000-8000-000000000803' ORDER BY orden DESC LIMIT 50$$) l));
SELECT assert_true('el historial de una cuenta con miles de patas (las 50 ultimas) se resuelve con un indice, sin barrer la tabla (Seq Scan)',
                   (SELECT bool_or(l LIKE '%Index%') AND NOT bool_or(l LIKE '%Seq Scan%') FROM tests.plan($$SELECT * FROM public.transaccion WHERE cuenta_id = '20000000-0000-4000-8000-000000000801' ORDER BY orden DESC LIMIT 50$$) l));
SELECT assert_true('la inversion de un CDT (WHERE cdt_id = ?) usa el indice parcial ix_transaccion_cdt',
                   (SELECT bool_or(l LIKE '%ix_transaccion_cdt%') FROM tests.plan($$SELECT count(*) FROM public.transaccion WHERE cdt_id = '50000000-0000-4000-8000-000000000001'$$) l));
ROLLBACK;

-- limpieza: se eliminan los clientes de la prueba (cascada de cuenta con el libro activo)
DELETE FROM public.usuario WHERE id IN (tests.u(801), tests.u(802), tests.u(803));
SELECT assert_eq('limpieza: ya no queda ninguna pata de la prueba de rendimiento', (SELECT count(*) FROM public.transaccion WHERE cuenta_id IN (tests.c(801), tests.c(802), tests.c(803))), 0::bigint);
