-- 13_libro_cuadre.test.sql · Etapa 2 · partida doble, plantillas, sellado y coherencia de cada grupo (trigger DIFERIDO).
-- Las patas se insertan de forma DIRECTA (sin _asentar_grupo) y la evaluacion del trigger diferido se fuerza con
-- SET CONSTRAINTS ... IMMEDIATE, que es exactamente lo que ocurriria al COMMIT. Cada rechazo ocurre en una subtransaccion
-- (assert_raises), asi que el estado queda intacto. Una sola transaccion con ROLLBACK final.
BEGIN;

SELECT tests.cliente(1);
SELECT tests.cliente(2);
SELECT tests.bolsillo(1, tests.c(1));
SELECT tests.bolsillo(2, tests.c(1));
SELECT tests.credito(1, tests.c(1), 5000);
SELECT tests.credito(2, tests.c(1), 3000);
SELECT tests.credito(3, tests.c(2), 3000);
SELECT tests.credito(4, tests.c(1), 10000);       -- sin desembolso (capital 0): admite una pata CREDITO E
SELECT tests.fondear(tests.c(1), 10000);
SELECT tests.fondear(tests.c(2), 1000);
SELECT tests.asentar(tests.pata('BOLSO_INGRESO','CUENTA','S',500,tests.c(1),tests.b(1)), tests.pata('BOLSO_INGRESO','BOLSILLO','E',500,tests.c(1),tests.b(1)));
SELECT tests.asentar(tests.pata('BOLSO_INGRESO','CUENTA','S',500,tests.c(1),tests.b(2)), tests.pata('BOLSO_INGRESO','BOLSILLO','E',500,tests.c(1),tests.b(2)));
SELECT tests.asentar(tests.pata('CREDITO_DESEMBOLSO','CUENTA','E',5000,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_DESEMBOLSO','CREDITO','E',5000,tests.c(1),NULL,NULL,tests.k(1)));
SELECT tests.asentar(tests.pata('CREDITO_DESEMBOLSO','CUENTA','E',3000,tests.c(1),NULL,NULL,tests.k(2)), tests.pata('CREDITO_DESEMBOLSO','CREDITO','E',3000,tests.c(1),NULL,NULL,tests.k(2)));
SELECT tests.asentar(tests.pata('CREDITO_DESEMBOLSO','CUENTA','E',3000,tests.c(2),NULL,NULL,tests.k(3)), tests.pata('CREDITO_DESEMBOLSO','CREDITO','E',3000,tests.c(2),NULL,NULL,tests.k(3)));

-- Inserta las patas de un grupo DIRECTAMENTE, en el orden dado, y fuerza el cuadre (como el COMMIT).
-- p_fecha2: si se da, la 2a pata usa esa fecha (para probar "fechas distintas").
CREATE FUNCTION pg_temp.directo(p_grupo uuid, p_patas jsonb, p_fecha2 timestamptz DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r jsonb; i int := 0;
BEGIN
  FOR r IN SELECT * FROM jsonb_array_elements(p_patas) LOOP
    i := i + 1;
    INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, cuenta_id, bolsillo_id, cdt_id, credito_id, contraparte_nombre, contraparte_cuenta)
    VALUES (p_grupo, CASE WHEN i = 2 AND p_fecha2 IS NOT NULL THEN p_fecha2 ELSE now() END,
            (r ->> 'tipo')::public.tipo_transaccion, (r ->> 'contenedor')::public.contenedor_contable, (r ->> 'sentido')::public.sentido_asiento,
            (r ->> 'monto')::numeric, (r ->> 'cuenta_id')::uuid, (r ->> 'bolsillo_id')::uuid, (r ->> 'cdt_id')::uuid, (r ->> 'credito_id')::uuid,
            r ->> 'contraparte_nombre', r ->> 'contraparte_cuenta');
  END LOOP;
  SET CONSTRAINTS public.ct_transaccion_cuadre, public.ct_transaccion_cdt, public.ct_cdt_inversion IMMEDIATE;
  SET CONSTRAINTS public.ct_transaccion_cuadre, public.ct_transaccion_cdt, public.ct_cdt_inversion DEFERRED;
END $$;

-- ============================================================================
-- 1. Grupos VALIDOS aceptados por el cuadre diferido
-- ============================================================================
SELECT assert_ok('valido: transferencia (par ENVIO/RECIBO de dos cuentas)', $$SELECT pg_temp.directo(gen_random_uuid(), tests.g_envio(tests.c(1), tests.c(2), 100))$$);
SELECT assert_ok('valido: ingreso simulado', $$SELECT pg_temp.directo(gen_random_uuid(), tests.g_ingreso(tests.c(1), 100))$$);
SELECT assert_ok('valido (credito sin plantilla): CUOTA con cuadre, un credito y una cuenta',
                 $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('CREDITO_CUOTA','CUENTA','S',110,tests.c(1),NULL,NULL,tests.k(1)),
                        tests.pata('CREDITO_CUOTA','CREDITO','S',100,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_CUOTA','RESULTADO','S',10,tests.c(1),NULL,NULL,tests.k(1))))$$);
SELECT assert_ok('valido (credito sin plantilla): ABONO con cuadre',
                 $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('CREDITO_ABONO','CUENTA','S',210,tests.c(1),NULL,NULL,tests.k(1)),
                        tests.pata('CREDITO_ABONO','CREDITO','S',200,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_ABONO','RESULTADO','S',10,tests.c(1),NULL,NULL,tests.k(1))))$$);
SELECT assert_ok('valido (credito sin plantilla): MORA con cuadre',
                 $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('CREDITO_MORA','CUENTA','S',20,tests.c(1),NULL,NULL,tests.k(1)),
                        tests.pata('CREDITO_MORA','RESULTADO','S',20,tests.c(1),NULL,NULL,tests.k(1))))$$);

-- ============================================================================
-- 2. G1 y G2: al menos dos patas y partida doble
-- ============================================================================
SELECT assert_raises('una pata sola', $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('INGRESO_SIMULADO','CUENTA','E',100,tests.c(1))))$$, '%una sola pata%', 'P0001');
SELECT assert_raises('descuadrado: debitos 100 contra creditos 99',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('INGRESO_SIMULADO','CUENTA','E',100,tests.c(1)), tests.pata('INGRESO_SIMULADO','RESULTADO','E',99,tests.c(1))))$$,
                     '%descuadrado%d%bitos=100.00%cr%ditos=99.00%', 'P0001');
SELECT assert_raises('descuadrado por 1 centavo', $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('INGRESO_SIMULADO','CUENTA','E',100.01,tests.c(1)), tests.pata('INGRESO_SIMULADO','RESULTADO','E',100,tests.c(1))))$$, '%descuadrado%', 'P0001');
SELECT assert_raises('dos patas del mismo lado: ΣC = 0',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('INGRESO_SIMULADO','CUENTA','E',100,tests.c(1)), tests.pata('DEPOSITO_BANCO','CUENTA','E',100,tests.c(1))))$$, '%descuadrado%', 'P0001');
SELECT assert_raises('credito: cuota descuadrada (cuenta -100, capital -90)',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('CREDITO_CUOTA','CUENTA','S',100,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_CUOTA','CREDITO','S',90,tests.c(1),NULL,NULL,tests.k(1))))$$, '%descuadrado%', 'P0001');
SELECT assert_raises('credito: una sola pata', $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('CREDITO_MORA','CUENTA','S',10,tests.c(1),NULL,NULL,tests.k(1))))$$, '%una sola pata%', 'P0001');

-- ============================================================================
-- 3. G4: una sola fecha de negocio por grupo
-- ============================================================================
SELECT assert_raises('fechas distintas entre las patas de un grupo',
                     $$SELECT pg_temp.directo(gen_random_uuid(), tests.g_ingreso(tests.c(1), 100), now() - interval '1 day')$$, '%fechas distintas%', 'P0001');
SELECT assert_raises('credito: fechas distintas',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('CREDITO_MORA','CUENTA','S',10,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_MORA','RESULTADO','S',10,tests.c(1),NULL,NULL,tests.k(1))), now() - interval '1 day')$$,
                     '%fechas distintas%', 'P0001');

-- ============================================================================
-- 4. G6: plantilla (forma contable valida)
-- ============================================================================
SELECT assert_raises('tipos mezclados que cuadran pero no forman una plantilla (INGRESO_SIMULADO + DEPOSITO_BANCO)',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('INGRESO_SIMULADO','CUENTA','E',100,tests.c(1)), tests.pata('DEPOSITO_BANCO','RESULTADO','E',100,tests.c(1))))$$,
                     '%ninguna forma contable v%lida%', 'P0001');
SELECT assert_raises('tres patas en una plantilla de dos (cuadra: 100 = 60 + 40)',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('INGRESO_SIMULADO','CUENTA','E',100,tests.c(1)), tests.pata('INGRESO_SIMULADO','RESULTADO','E',60,tests.c(1)), tests.pata('INGRESO_SIMULADO','RESULTADO','E',40,tests.c(1))))$$,
                     '%ninguna forma contable v%lida%', 'P0001');
SELECT assert_raises('un solo contenedor repetido (dos RESULTADO), cuadre imposible de otra forma: sin plantilla',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('BONO_REFERIDO','CUENTA','E',100,tests.c(1)), tests.pata('BONO_REFERIDO','CUENTA','E',100,tests.c(1)), tests.pata('BONO_REFERIDO','RESULTADO','E',200,tests.c(1))))$$,
                     '%ninguna forma contable v%lida%', 'P0001');

-- ============================================================================
-- 5. G5: el dinero solo cruza cuentas en un par ENVIO/RECIBO
-- ============================================================================
SELECT assert_raises('ingreso con la pata de CUENTA en una cuenta y la de RESULTADO en otra',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('INGRESO_SIMULADO','CUENTA','E',100,tests.c(1)), tests.pata('INGRESO_SIMULADO','RESULTADO','E',100,tests.c(2))))$$,
                     '%solo puede involucrar una cuenta%', 'P0001');
SELECT assert_raises('ENVIO y RECIBO en la MISMA cuenta (un auto-envio no es una transferencia)',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(
                         tests.pata('ENVIO','CUENTA','S',100,tests.c(1),NULL,NULL,NULL,'Yo','4000000001'), tests.pata('RECIBO','CUENTA','E',100,tests.c(1),NULL,NULL,NULL,'Yo','4000000001')))$$,
                     '%exactamente dos cuentas distintas%', 'P0001');
SELECT assert_raises('ENVIO con contraparte_cuenta que no es la cuenta del receptor',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(
                         tests.pata('ENVIO','CUENTA','S',100,tests.c(1),NULL,NULL,NULL,'Beto','9999999999'), tests.pata('RECIBO','CUENTA','E',100,tests.c(2),NULL,NULL,NULL,'Ana','4000000001')))$$,
                     '%contraparte_cuenta%', 'P0001');
SELECT assert_raises('RECIBO con contraparte_cuenta que no es la cuenta del emisor',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(
                         tests.pata('ENVIO','CUENTA','S',100,tests.c(1),NULL,NULL,NULL,'Beto','4000000002'), tests.pata('RECIBO','CUENTA','E',100,tests.c(2),NULL,NULL,NULL,'Ana','9999999999')))$$,
                     '%contraparte_cuenta%', 'P0001');
SELECT assert_raises('ENVIO sin contraparte_nombre',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(
                         tests.pata('ENVIO','CUENTA','S',100,tests.c(1),NULL,NULL,NULL,NULL,'4000000002'), tests.pata('RECIBO','CUENTA','E',100,tests.c(2),NULL,NULL,NULL,'Ana','4000000001')))$$,
                     '%falta contraparte_nombre%', 'P0001');
SELECT assert_raises('credito (sin plantilla): una pata en cada cuenta',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('CREDITO_CUOTA','CUENTA','S',100,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_CUOTA','RESULTADO','S',100,tests.c(2),NULL,NULL,tests.k(3))))$$,
                     '%m%s de una cuenta%', 'P0001');

-- ============================================================================
-- 6. Coherencia de producto dentro de la plantilla
-- ============================================================================
SELECT assert_raises('BOLSO_INGRESO con las dos patas en bolsillos distintos',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('BOLSO_INGRESO','CUENTA','S',10,tests.c(1),tests.b(1)), tests.pata('BOLSO_INGRESO','BOLSILLO','E',10,tests.c(1),tests.b(2))))$$,
                     '%mismo bolsillo%', 'P0001');
SELECT assert_raises('BOLSO_RETIRO con las dos patas en bolsillos distintos',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('BOLSO_RETIRO','BOLSILLO','S',10,tests.c(1),tests.b(1)), tests.pata('BOLSO_RETIRO','CUENTA','E',10,tests.c(1),tests.b(2))))$$,
                     '%mismo bolsillo%', 'P0001');
SELECT assert_raises('BOLSO_MOVIMIENTO del bolsillo a si mismo',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('BOLSO_MOVIMIENTO','BOLSILLO','S',10,tests.c(1),tests.b(1)), tests.pata('BOLSO_MOVIMIENTO','BOLSILLO','E',10,tests.c(1),tests.b(1))))$$,
                     '%dos bolsillos distintos%', 'P0001');
SELECT assert_raises('INTERES_BOLSO con el RESULTADO apuntando a otro bolsillo',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('INTERES_BOLSO','BOLSILLO','E',5,tests.c(1),tests.b(1)), tests.pata('INTERES_BOLSO','RESULTADO','E',5,tests.c(1),tests.b(2))))$$,
                     '%mismo bolsillo%', 'P0001');
SELECT assert_raises('CREDITO_DESEMBOLSO con la pata de CUENTA en un credito y la de CREDITO en otro',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('CREDITO_DESEMBOLSO','CUENTA','E',10,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_DESEMBOLSO','CREDITO','E',10,tests.c(1),NULL,NULL,tests.k(4))))$$,
                     '%mismo cr%dito%', 'P0001');

-- ============================================================================
-- 7. Grupos de CREDITO (CUOTA / ABONO / MORA): sin plantilla, pero coherencia total
-- ============================================================================
SELECT assert_raises('credito: patas de crédito mezcladas con otra familia (cuadra: C 100 = D 100)',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('CREDITO_CUOTA','CUENTA','S',100,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('INGRESO_SIMULADO','CUENTA','E',100,tests.c(1))))$$,
                     '%mezcla patas de cr%dito con patas de otra familia%', 'P0001');
SELECT assert_raises('credito: dos creditos distintos de la misma cuenta en un grupo (cuenta -100, capital del credito 2 -100)',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('CREDITO_CUOTA','CUENTA','S',100,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_CUOTA','CREDITO','S',100,tests.c(1),NULL,NULL,tests.k(2))))$$,
                     '%mezcla cr%ditos distintos%', 'P0001');
SELECT assert_raises('credito: el credito pertenece a OTRA cuenta distinta de la pata (lo detecta el libro)',
                     $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('CREDITO_MORA','CUENTA','S',10,tests.c(1),NULL,NULL,tests.k(3)), tests.pata('CREDITO_MORA','RESULTADO','S',10,tests.c(1),NULL,NULL,tests.k(3))))$$,
                     '%no pertenece a la cuenta%', 'P0001');
SELECT assert_violates('credito: transferencia entre cuentas disfrazada de MORA (CUENTA E con tipo CREDITO_MORA no esta en la matriz)',
                       $$SELECT pg_temp.directo(gen_random_uuid(), jsonb_build_array(tests.pata('CREDITO_MORA','CUENTA','S',10,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_MORA','CUENTA','E',10,tests.c(2),NULL,NULL,tests.k(3))))$$,
                       'ck_transaccion_tipo_contenedor_sentido', '23514');

-- ============================================================================
-- 8. v_integridad_grupos clasifica lo aceptado
-- ============================================================================
SELECT assert_eq('los grupos validos aceptados: ninguno sin plantilla (desde E9 los de credito tienen la suya) y ninguno en ERROR',
                 (SELECT (count(*) FILTER (WHERE estado = 'SIN_PLANTILLA_CREDITO'), count(*) FILTER (WHERE estado = 'ERROR'))::text FROM public.v_integridad_grupos), '(0,0)'::text);
SELECT assert_true('el estado global sigue en orden despues de tantos rechazos', tests.ok_sin_plan());

ROLLBACK;
