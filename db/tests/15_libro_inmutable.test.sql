-- 15_libro_inmutable.test.sql · Etapa 2 · el historial es inmutable (sin UPDATE, sin TRUNCATE, DELETE solo por cascada de cuenta),
-- trazabilidad del borrado (audit.evento CUENTA_BORRADA) y borrado completo de un usuario con el libro ACTIVO.
-- Las FK y sus politicas corren con su comportamiento NORMAL (aqui NO se apaga ningun trigger). Una transaccion con ROLLBACK final.
BEGIN;

-- Escenario: A (c1) con bolsillo, CDT, credito, cuota y transferencias con B (c2) y C (c3)
SELECT tests.cliente(1); SELECT tests.cliente(2); SELECT tests.cliente(3);
SELECT tests.fondear(tests.c(1), 5000);
SELECT tests.fondear(tests.c(3), 200);
SELECT tests.bolsillo(1, tests.c(1));
SELECT tests.asentar(tests.pata('BOLSO_INGRESO','CUENTA','S',500,tests.c(1),tests.b(1)), tests.pata('BOLSO_INGRESO','BOLSILLO','E',500,tests.c(1),tests.b(1)));
SELECT tests.cdt(1, tests.c(1), 1000);
SELECT tests.asentar(tests.pata('CDT_CREACION','CUENTA','S',1000,tests.c(1),NULL,tests.d(1)), tests.pata('CDT_CREACION','CDT','E',1000,tests.c(1),NULL,tests.d(1)));
SELECT tests.asentar(tests.pata('INTERES_CDT','CDT','E',30,tests.c(1),NULL,tests.d(1)), tests.pata('INTERES_CDT','RESULTADO','E',30,tests.c(1),NULL,tests.d(1)));
SELECT tests.credito(1, tests.c(1), 3000);
SELECT tests.asentar(tests.pata('CREDITO_DESEMBOLSO','CUENTA','E',3000,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_DESEMBOLSO','CREDITO','E',3000,tests.c(1),NULL,NULL,tests.k(1)));
SELECT tests.asentar(tests.pata('CREDITO_CUOTA','CUENTA','S',330,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_CUOTA','CREDITO','S',300,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_CUOTA','RESULTADO','S',30,tests.c(1),NULL,NULL,tests.k(1)));
SELECT public._asentar_grupo(now(), tests.g_envio(tests.c(1), tests.c(2), 300));
SELECT public._asentar_grupo(now(), tests.g_envio(tests.c(3), tests.c(1), 100));
INSERT INTO public.cuota (credito_id, numero, fecha_vencimiento, valor_cuota_original, valor_cuota, capital_programado, interes_programado)
  VALUES (tests.k(1), 1, '2026-12-21', 2730, 2730, 2700, 30);
-- E8: el plan (capital 2700) cuadra con el libro (3000 - 300) y se evalua el diferido ahora: un evento diferido PENDIENTE de ct_credito_plan impediria el TRUNCATE de la prueba 3
SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota IMMEDIATE;
SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota DEFERRED;

SELECT assert_eq('escenario: 9 grupos, 19 patas y el estado global en orden', (SELECT (grupos, patas, tests.ok_sin_plan())::text FROM public.v_integridad_global), '(9,19,t)'::text);

-- ============================================================================
-- 1. UPDATE: siempre rechazado
-- ============================================================================
SELECT assert_raises('superusuario: UPDATE de nota', $$UPDATE public.transaccion SET nota = 'x'$$, '%inmutables%', 'P0001');
SELECT assert_raises('superusuario: UPDATE de monto', $$UPDATE public.transaccion SET monto = 1$$, '%inmutables%', 'P0001');
SELECT assert_raises('superusuario: UPDATE de saldo_posterior', $$UPDATE public.transaccion SET saldo_posterior = 0$$, '%inmutables%', 'P0001');
SELECT assert_raises('superusuario: UPDATE de cuenta_id (reasignar una pata)', $$UPDATE public.transaccion SET cuenta_id = tests.c(2)$$, '%inmutables%', 'P0001');
SELECT assert_raises('superusuario: UPDATE de grupo_id (mover una pata a otro grupo)', $$UPDATE public.transaccion SET grupo_id = gen_random_uuid()$$, '%inmutables%', 'P0001');
SELECT assert_raises('banco_owner: UPDATE de monto (sin privilegio)', $$SET LOCAL ROLE banco_owner; UPDATE public.transaccion SET monto = 1$$, 'permission denied for table transaccion', '42501');
SELECT assert_raises('banco_owner: UPDATE de nota (sin privilegio)', $$SET LOCAL ROLE banco_owner; UPDATE public.transaccion SET nota = 'x'$$, 'permission denied for table transaccion', '42501');
SELECT assert_raises('banco_owner: la unica columna que puede tocar (registrado_en, solo por las FK) la rechaza el trigger',
                     $$SET LOCAL ROLE banco_owner; UPDATE public.transaccion SET registrado_en = now()$$, '%inmutables%', 'P0001');
SELECT assert_raises('banco_ledger: UPDATE de una pata (sin privilegio)', $$SET LOCAL ROLE banco_ledger; UPDATE public.transaccion SET monto = 1$$, 'permission denied for table transaccion', '42501');
SELECT assert_raises('banco_app: UPDATE de una pata', $$SET LOCAL ROLE banco_app; UPDATE public.transaccion SET monto = 1$$, 'permission denied for table transaccion', '42501');

-- ============================================================================
-- 2. DELETE directo: rechazado (la cuenta de la pata existe)
-- ============================================================================
SELECT assert_raises('superusuario: DELETE de todo el libro', $$DELETE FROM public.transaccion$$, '%no se pueden borrar%', 'P0001');
SELECT assert_raises('superusuario: DELETE de una pata', $$DELETE FROM public.transaccion WHERE tipo = 'ENVIO'$$, '%no se pueden borrar%', 'P0001');
SELECT assert_raises('banco_owner TIENE el privilegio DELETE (lo exige la cascada) pero el trigger lo rechaza',
                     $$SET LOCAL ROLE banco_owner; DELETE FROM public.transaccion WHERE tipo = 'RECIBO'$$, '%no se pueden borrar%', 'P0001');
SELECT assert_raises('banco_ledger: DELETE de una pata (sin privilegio)', $$SET LOCAL ROLE banco_ledger; DELETE FROM public.transaccion$$, 'permission denied for table transaccion', '42501');
SELECT assert_raises('banco_app: DELETE de una pata', $$SET LOCAL ROLE banco_app; DELETE FROM public.transaccion$$, 'permission denied for table transaccion', '42501');
SELECT assert_eq('el libro sigue con 19 patas', (SELECT count(*) FROM public.transaccion), 19::bigint);

-- ============================================================================
-- 3. TRUNCATE: rechazado, tambien en cascada
-- ============================================================================
SELECT assert_raises('superusuario: TRUNCATE transaccion', $$TRUNCATE public.transaccion$$, '%no se puede vaciar%', 'P0001');
SELECT assert_raises('superusuario: TRUNCATE cuenta CASCADE arrastraria al libro', $$TRUNCATE public.cuenta CASCADE$$, '%no se puede vaciar%', 'P0001');
SELECT assert_raises('superusuario: TRUNCATE usuario CASCADE arrastraria al libro', $$TRUNCATE public.usuario CASCADE$$, '%no se puede vaciar%', 'P0001');
SELECT assert_raises('banco_owner: TRUNCATE transaccion (sin privilegio)', $$SET LOCAL ROLE banco_owner; TRUNCATE public.transaccion$$, 'permission denied for table transaccion', '42501');
SELECT assert_raises('banco_app: TRUNCATE transaccion', $$SET LOCAL ROLE banco_app; TRUNCATE public.transaccion$$, 'permission denied for table transaccion', '42501');

-- ============================================================================
-- 4. Proteccion de movimientos historicos frente a borrados individuales (FK NO ACTION, comportamiento normal)
-- ============================================================================
SELECT assert_violates('NO se puede borrar un BOLSILLO con movimientos (FK), tambien como banco_owner',
                       $$SET LOCAL ROLE banco_owner; DELETE FROM public.bolsillo WHERE id = tests.b(1)$$, 'fk_transaccion_bolsillo', '23503');
SELECT assert_violates('NO se puede borrar un CDT con movimientos (FK)', $$SET LOCAL ROLE banco_owner; DELETE FROM public.cdt WHERE id = tests.d(1)$$, 'fk_transaccion_cdt', '23503');
SELECT assert_violates('NO se puede borrar un CREDITO con movimientos (FK)', $$SET LOCAL ROLE banco_owner; DELETE FROM public.credito WHERE id = tests.k(1)$$, 'fk_transaccion_credito', '23503');

-- ============================================================================
-- 5. BORRADO COMPLETO del usuario A con TODOS los triggers de E2 activos
-- ============================================================================
CREATE TEMP TABLE antes AS
  SELECT u.cuenta, u.bolsillos, u.cdt_vigente, u.pasivos, u.resultado, u.transf_neto,
         (SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(1)) AS patas
    FROM public.v_integridad_usuario u WHERE u.cuenta_id = tests.c(1);
SELECT assert_eq('antes: A tiene 5970 en cuenta, 500 en bolsillos, CDT vigente 1030, pasivo 2700, resultado 5000 (el ingreso), transferencias netas -200 y 15 patas',
                 (SELECT (cuenta, bolsillos, cdt_vigente, pasivos, resultado, transf_neto, patas)::text FROM antes), '(5970.00,500.00,1030.00,2700.00,5000.00,-200.00,15)'::text);

SELECT set_config('banco.actor', 'admin1', true);
SELECT assert_ok('DELETE del usuario A (cuenta, bolsillo, CDT, credito, cuota y 15 patas) como banco_owner, con el libro activo',
                 $$SET LOCAL ROLE banco_owner; DELETE FROM public.usuario WHERE id = tests.u(1)$$);
SELECT assert_eq('despues: de A no queda NADA (cuenta, bolsillo, cdt, credito, cuota, patas)',
                 (SELECT ((SELECT count(*) FROM public.cuenta WHERE id = tests.c(1)), (SELECT count(*) FROM public.bolsillo), (SELECT count(*) FROM public.cdt),
                          (SELECT count(*) FROM public.credito), (SELECT count(*) FROM public.cuota),
                          (SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(1)))::text), '(0,0,0,0,0,0)'::text);
SELECT assert_eq('lo de B y C queda intacto: 1 pata de B (RECIBO) y 2 de C (ingreso: CUENTA y RESULTADO) + 1 de C (ENVIO) = 4 patas',
                 (SELECT count(*) FROM public.transaccion), 4::bigint);
SELECT assert_eq('la contraparte de A en la pata de B queda guardada como TEXTO (nombre y numero), sin FK',
                 (SELECT (contraparte_nombre, contraparte_cuenta)::text FROM public.transaccion WHERE cuenta_id = tests.c(2)), '(Origen,4000000001)'::text);
SELECT assert_eq('auditoria: UN evento CUENTA_BORRADA con la entidad y el actor (atribucion)',
                 (SELECT (count(*), min(entidad_id), min(actor_username))::text FROM audit.evento WHERE accion = 'CUENTA_BORRADA'),
                 (SELECT '(1,' || tests.c(1)::text || ',admin1)'));
SELECT assert_eq('auditoria: el evento guarda EXACTAMENTE lo que se destruyo (balance, bolsillos, CDT, pasivos, resultado, transferencias, patas)',
                 (SELECT ((e.antes ->> 'balance')::numeric, (e.antes ->> 'bolsillos')::numeric, (e.antes ->> 'cdt_vigente')::numeric, (e.antes ->> 'pasivos')::numeric,
                          (e.antes ->> 'resultado')::numeric, (e.antes ->> 'transf_neto')::numeric, (e.antes ->> 'patas')::int)::text
                    FROM audit.evento e WHERE e.accion = 'CUENTA_BORRADA'),
                 (SELECT (cuenta, bolsillos, cdt_vigente, pasivos, resultado, transf_neto, patas)::text FROM antes));
SELECT assert_eq('las 2 transferencias de A quedan con UNA sola pata y se clasifican HUERFANO_POR_BORRADO (esperado, no un error)',
                 (SELECT count(*) FROM public.v_integridad_grupos WHERE estado = 'HUERFANO_POR_BORRADO'), 2::bigint);
SELECT assert_eq('estado global en orden, 1 cuenta borrada auditada y la conservacion de transferencias (vivas + borradas) = 0',
                 (SELECT (tests.ok_sin_plan(), cuentas_borradas, grupos_huerfanos_por_borrado, desvio_transferencias)::text FROM public.v_integridad_global), '(t,1,2,0.00)'::text);

-- ============================================================================
-- 6. Borrar una cuenta directamente tambien cascadea, audita y no deja patas huerfanas
-- ============================================================================
SELECT assert_ok('DELETE de la cuenta de B directamente (como superusuario)', $$DELETE FROM public.cuenta WHERE id = tests.c(2)$$);
SELECT assert_eq('...2 eventos CUENTA_BORRADA y ya no quedan patas de B', (SELECT ((SELECT count(*) FROM audit.evento WHERE accion = 'CUENTA_BORRADA'), (SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(2)))::text), '(2,0)'::text);
SELECT assert_eq('...y la conservacion sigue en 0 (cuentas vivas: solo C; borradas: A y B)', (SELECT desvio_transferencias FROM public.v_integridad_global), 0::numeric);

ROLLBACK;
