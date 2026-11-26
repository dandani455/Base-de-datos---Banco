-- 12_libro_asentar.test.sql · Etapa 2 · _asentar_grupo y el trigger de aplicacion de saldos.
-- Se recorren las 15 plantillas de punta a punta (saldos exactos, saldo previo/posterior), los grupos de credito sin
-- plantilla (CUOTA/ABONO/MORA), y todos los rechazos del escritor autorizado. Una sola transaccion con ROLLBACK final.
BEGIN;

SELECT tests.cliente(1);
SELECT tests.cliente(2);
SELECT tests.bolsillo(1, tests.c(1));
SELECT tests.bolsillo(2, tests.c(1));
SELECT tests.bolsillo(3, tests.c(2));            -- bolsillo AJENO (de la cuenta 2)
SELECT tests.credito(1, tests.c(1), 5000);

CREATE TEMP TABLE t_h (h text);
CREATE FUNCTION pg_temp.cu(p int) RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(p) $$;
CREATE FUNCTION pg_temp.bo(p int) RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT balance::numeric FROM public.bolsillo WHERE id = tests.b(p) $$;

-- ============================================================================
-- 1. Las 4 plantillas "de banco": ingreso simulado, bono, deposito y ajuste (+ y -)
-- ============================================================================
SELECT assert_ok('INGRESO_SIMULADO 10000', $$SELECT tests.asentar(tests.pata('INGRESO_SIMULADO','CUENTA','E',10000,tests.c(1)),
                                                              tests.pata('INGRESO_SIMULADO','RESULTADO','E',10000,tests.c(1),NULL,NULL,NULL,'Banco Digital'))$$);
SELECT assert_eq('cuenta 10000.00', pg_temp.cu(1), 10000::numeric);
SELECT assert_eq('pata CUENTA: saldo previo 0 y posterior 10000 (los fija el libro)',
                 (SELECT (saldo_previo, saldo_posterior)::text FROM public.transaccion WHERE cuenta_id = tests.c(1) AND contenedor = 'CUENTA' AND tipo = 'INGRESO_SIMULADO'),
                 '(0.00,10000.00)'::text);
SELECT assert_eq('pata RESULTADO (contenedor derivado): sin saldos',
                 (SELECT (saldo_previo IS NULL AND saldo_posterior IS NULL) FROM public.transaccion WHERE contenedor = 'RESULTADO' AND tipo = 'INGRESO_SIMULADO'), true);
SELECT assert_ok('BONO_REFERIDO 50', $$SELECT tests.asentar(VARIADIC ARRAY(SELECT jsonb_array_elements(tests.g_ingreso(tests.c(1), 50, 'BONO_REFERIDO'))))$$);
SELECT assert_ok('DEPOSITO_BANCO 100', $$SELECT tests.asentar(VARIADIC ARRAY(SELECT jsonb_array_elements(tests.g_ingreso(tests.c(1), 100, 'DEPOSITO_BANCO'))))$$);
SELECT assert_ok('AJUSTE_ADMIN positivo 500', $$SELECT tests.asentar(VARIADIC ARRAY(SELECT jsonb_array_elements(tests.g_ingreso(tests.c(1), 500, 'AJUSTE_ADMIN'))))$$);
SELECT assert_ok('AJUSTE_ADMIN negativo 200', $$SELECT tests.asentar(tests.pata('AJUSTE_ADMIN','CUENTA','S',200,tests.c(1)), tests.pata('AJUSTE_ADMIN','RESULTADO','S',200,tests.c(1)))$$);
SELECT assert_eq('cuenta 10450.00 = 10000 + 50 + 100 + 500 - 200', pg_temp.cu(1), 10450::numeric);

-- ============================================================================
-- 2. Bolsillos: ingreso, retiro, movimiento e interes
-- ============================================================================
SELECT assert_ok('BOLSO_INGRESO 1000 (cuenta -> bolsillo 1)', $$SELECT tests.asentar(tests.pata('BOLSO_INGRESO','CUENTA','S',1000,tests.c(1),tests.b(1)), tests.pata('BOLSO_INGRESO','BOLSILLO','E',1000,tests.c(1),tests.b(1)))$$);
SELECT assert_eq('cuenta 9450.00 y bolsillo 1: 1000.00', (pg_temp.cu(1), pg_temp.bo(1))::text, '(9450.00,1000.00)'::text);
SELECT assert_eq('pata BOLSILLO: saldo previo 0 y posterior 1000',
                 (SELECT (saldo_previo, saldo_posterior)::text FROM public.transaccion WHERE contenedor = 'BOLSILLO' AND tipo = 'BOLSO_INGRESO'), '(0.00,1000.00)'::text);
SELECT assert_ok('BOLSO_RETIRO 400 (bolsillo 1 -> cuenta)', $$SELECT tests.asentar(tests.pata('BOLSO_RETIRO','BOLSILLO','S',400,tests.c(1),tests.b(1)), tests.pata('BOLSO_RETIRO','CUENTA','E',400,tests.c(1),tests.b(1)))$$);
SELECT assert_eq('cuenta 9850.00 y bolsillo 1: 600.00', (pg_temp.cu(1), pg_temp.bo(1))::text, '(9850.00,600.00)'::text);
SELECT assert_ok('BOLSO_MOVIMIENTO 100 (bolsillo 1 -> bolsillo 2)', $$SELECT tests.asentar(tests.pata('BOLSO_MOVIMIENTO','BOLSILLO','S',100,tests.c(1),tests.b(1)), tests.pata('BOLSO_MOVIMIENTO','BOLSILLO','E',100,tests.c(1),tests.b(2)))$$);
SELECT assert_eq('bolsillo 1: 500.00 y bolsillo 2: 100.00 (la cuenta no cambia)', (pg_temp.bo(1), pg_temp.bo(2), pg_temp.cu(1))::text, '(500.00,100.00,9850.00)'::text);
SELECT assert_ok('INTERES_BOLSO 5 (bolsillo 2 y resultado)', $$SELECT tests.asentar(tests.pata('INTERES_BOLSO','BOLSILLO','E',5,tests.c(1),tests.b(2)), tests.pata('INTERES_BOLSO','RESULTADO','E',5,tests.c(1),tests.b(2),NULL,NULL,'Banco Digital'))$$);
SELECT assert_eq('bolsillo 2: 105.00', pg_temp.bo(2), 105::numeric);

-- ============================================================================
-- 3. CDT: apertura, interes, vencimiento (el estado se cierra antes de devolver el dinero)
-- ============================================================================
-- un CDT sin su pata de apertura es incoherente: se crea justo antes de su grupo (asi lo hara la funcion de negocio)
SELECT tests.cdt(1, tests.c(1), 2000);
SELECT assert_ok('CDT_CREACION 2000', $$SELECT tests.asentar(tests.pata('CDT_CREACION','CUENTA','S',2000,tests.c(1),NULL,tests.d(1)), tests.pata('CDT_CREACION','CDT','E',2000,tests.c(1),NULL,tests.d(1)))$$);
SELECT assert_eq('cuenta 7850.00 y la inversion vigente del CDT en el libro es 2000.00',
                 (pg_temp.cu(1), (SELECT calculado FROM public.v_integridad_saldos WHERE contenedor = 'CDT_INVERSION'))::text, '(7850.00,2000.00)'::text);
SELECT assert_ok('INTERES_CDT 50 (generado_acumulado)', $$SELECT tests.asentar(tests.pata('INTERES_CDT','CDT','E',50,tests.c(1),NULL,tests.d(1)), tests.pata('INTERES_CDT','RESULTADO','E',50,tests.c(1),NULL,tests.d(1),NULL,'Banco Digital'))$$);
SELECT assert_eq('cdt.generado_acumulado = 50.00 (lo movio el libro) y la inversion vale 2050.00',
                 (SELECT (generado_acumulado, monto + generado_acumulado)::text FROM public.cdt WHERE id = tests.d(1)), '(50.00,2050.00)'::text);
SELECT assert_eq('el contenedor CDT no tiene saldos previo/posterior', (SELECT bool_and(saldo_previo IS NULL AND saldo_posterior IS NULL) FROM public.transaccion WHERE contenedor = 'CDT'), true);
UPDATE public.cdt SET estado = 'CERRADO' WHERE id = tests.d(1);
SELECT assert_ok('CDT_VENCIMIENTO 2050 (devuelve monto + generado)', $$SELECT tests.asentar(tests.pata('CDT_VENCIMIENTO','CDT','S',2050,tests.c(1),NULL,tests.d(1)), tests.pata('CDT_VENCIMIENTO','CUENTA','E',2050,tests.c(1),NULL,tests.d(1)))$$);
SELECT assert_eq('cuenta 9900.00 y inversion del CDT 0.00', (pg_temp.cu(1), (SELECT calculado FROM public.v_integridad_saldos WHERE contenedor = 'CDT_INVERSION'))::text, '(9900.00,0.00)'::text);

-- ============================================================================
-- 4. Credito: desembolso (con plantilla) y cuota/abono/mora (sin plantilla hasta D7)
-- ============================================================================
SELECT assert_ok('CREDITO_DESEMBOLSO 5000: sube el capital pendiente (el credito nacio en 0)',
                 $$SELECT tests.asentar(tests.pata('CREDITO_DESEMBOLSO','CUENTA','E',5000,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_DESEMBOLSO','CREDITO','E',5000,tests.c(1),NULL,NULL,tests.k(1)))$$);
SELECT assert_eq('cuenta 14900.00 y capital pendiente 5000.00', (pg_temp.cu(1), (SELECT capital_pendiente::numeric FROM public.credito WHERE id = tests.k(1)))::text, '(14900.00,5000.00)'::text);
SELECT assert_eq('pata CREDITO: saldo previo 0 y posterior 5000',
                 (SELECT (saldo_previo, saldo_posterior)::text FROM public.transaccion WHERE contenedor = 'CREDITO' AND tipo = 'CREDITO_DESEMBOLSO'), '(0.00,5000.00)'::text);
SELECT assert_ok('CREDITO_CUOTA: cuenta -1100, capital -1000, resultado (gasto) -100',
                 $$SELECT tests.asentar(tests.pata('CREDITO_CUOTA','CUENTA','S',1100,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_CUOTA','CREDITO','S',1000,tests.c(1),NULL,NULL,tests.k(1)),
                                        tests.pata('CREDITO_CUOTA','RESULTADO','S',100,tests.c(1),NULL,NULL,tests.k(1),'Banco Digital'))$$);
SELECT assert_eq('cuenta 13800.00 y capital 4000.00', (pg_temp.cu(1), (SELECT capital_pendiente::numeric FROM public.credito WHERE id = tests.k(1)))::text, '(13800.00,4000.00)'::text);
SELECT assert_ok('CREDITO_ABONO: cuenta -520, capital -500, resultado -20',
                 $$SELECT tests.asentar(tests.pata('CREDITO_ABONO','CUENTA','S',520,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_ABONO','CREDITO','S',500,tests.c(1),NULL,NULL,tests.k(1)),
                                        tests.pata('CREDITO_ABONO','RESULTADO','S',20,tests.c(1),NULL,NULL,tests.k(1)))$$);
SELECT assert_ok('CREDITO_MORA: cuenta -30, resultado -30', $$SELECT tests.asentar(tests.pata('CREDITO_MORA','CUENTA','S',30,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_MORA','RESULTADO','S',30,tests.c(1),NULL,NULL,tests.k(1)))$$);
SELECT assert_eq('cuenta 13250.00 y capital 3500.00', (pg_temp.cu(1), (SELECT capital_pendiente::numeric FROM public.credito WHERE id = tests.k(1)))::text, '(13250.00,3500.00)'::text);

-- ============================================================================
-- 5. Transferencias: desde la cuenta y desde un bolsillo (par ENVIO/RECIBO)
-- ============================================================================
SELECT assert_ok('ENVIO 250 de la cuenta 1 a la cuenta 2', $$SELECT public._asentar_grupo(now(), tests.g_envio(tests.c(1), tests.c(2), 250))$$);
SELECT assert_eq('cuenta 1: 13000.00 y cuenta 2: 250.00', (pg_temp.cu(1), pg_temp.cu(2))::text, '(13000.00,250.00)'::text);
SELECT assert_ok('ENVIO 100 desde el bolsillo 1 a la cuenta 2', $$SELECT public._asentar_grupo(now(), tests.g_envio(tests.c(1), tests.c(2), 100, tests.b(1)))$$);
SELECT assert_eq('bolsillo 1: 400.00, cuenta 1 igual y cuenta 2: 350.00', (pg_temp.bo(1), pg_temp.cu(1), pg_temp.cu(2))::text, '(400.00,13000.00,350.00)'::text);
SELECT assert_eq('la pata RECIBO guarda la contraparte como TEXTO (nombre y numero de cuenta del emisor)',
                 (SELECT (contraparte_nombre, contraparte_cuenta)::text FROM public.transaccion WHERE tipo = 'RECIBO' AND monto = 250), '(Origen,4000000001)'::text);

-- ============================================================================
-- 6. Resultado global del recorrido
-- ============================================================================
SELECT assert_eq('18 grupos y 38 patas en el libro', (SELECT (grupos, patas)::text FROM public.v_integridad_global), '(18,38)'::text);
SELECT assert_eq('las 18 plantillas recorridas (15 de E2 + CUOTA/ABONO/MORA de E9) aparecen en v_integridad_grupos',
                 (SELECT count(DISTINCT plantilla) FROM public.v_integridad_grupos WHERE plantilla IS NOT NULL), 18::bigint);
SELECT assert_eq('...y desde E9 los 3 grupos de CUOTA/ABONO/MORA tienen plantilla: ninguno se clasifica SIN_PLANTILLA_CREDITO (estado OK)',
                 (SELECT (count(*) FILTER (WHERE estado = 'SIN_PLANTILLA_CREDITO'), count(*) FILTER (WHERE tipos && ARRAY['CREDITO_CUOTA','CREDITO_ABONO','CREDITO_MORA']::text[] AND estado = 'OK'))::text FROM (SELECT g.estado, (SELECT array_agg(DISTINCT t.tipo::text) FROM public.transaccion t WHERE t.grupo_id = g.grupo_id) AS tipos FROM public.v_integridad_grupos g) x), '(0,3)'::text);
SELECT assert_true('las vistas de integridad estan en orden tras el recorrido completo', tests.ok_sin_plan());
SELECT assert_eq('cada pata lleva el tx_id de ESTA transaccion', (SELECT bool_and(tx_id = pg_current_xact_id()) FROM public.transaccion), true);
SELECT assert_eq('registrado_en (hora real) es posterior a fecha (now() del inicio de la transaccion) en todas las patas',
                 (SELECT bool_and(registrado_en > fecha) FROM public.transaccion), true);
SELECT assert_eq('las patas de un grupo comparten fecha, y cada grupo tiene un solo tx_id',
                 (SELECT bool_and(f = 1 AND t = 1) FROM (SELECT count(DISTINCT fecha) f, count(DISTINCT tx_id) t FROM public.transaccion GROUP BY grupo_id) x), true);

-- Orden determinista de insercion: por id de cuenta ascendente (1->2: ENVIO antes que RECIBO; 2->1: RECIBO antes que ENVIO)
SELECT assert_ok('ENVIO 10 de la cuenta 2 a la cuenta 1', $$SELECT public._asentar_grupo(now(), tests.g_envio(tests.c(2), tests.c(1), 10))$$);
SELECT assert_eq('orden ascendente por id de cuenta: en 1->2 el ENVIO (cuenta 1) va primero; en 2->1 el RECIBO (cuenta 1) va primero',
                 (SELECT (
                    (SELECT e.orden < r.orden FROM public.transaccion e JOIN public.transaccion r ON r.grupo_id = e.grupo_id AND r.tipo = 'RECIBO' WHERE e.tipo = 'ENVIO' AND e.monto = 250),
                    (SELECT e.orden > r.orden FROM public.transaccion e JOIN public.transaccion r ON r.grupo_id = e.grupo_id AND r.tipo = 'RECIBO' WHERE e.tipo = 'ENVIO' AND e.monto = 10)
                  )::text), '(t,t)'::text);

-- ============================================================================
-- 7. Rechazos del escritor autorizado (cada uno deja el estado intacto)
-- ============================================================================
INSERT INTO t_h SELECT tests.huella_saldos();
SELECT assert_raises('saldo insuficiente en la cuenta (BOLSO_INGRESO de 99.999.999)',
                     $$SELECT tests.asentar(tests.pata('BOLSO_INGRESO','CUENTA','S',99999999,tests.c(1),tests.b(1)), tests.pata('BOLSO_INGRESO','BOLSILLO','E',99999999,tests.c(1),tests.b(1)))$$, 'Saldo insuficiente', 'P0001');
SELECT assert_raises('saldo insuficiente en el bolsillo (BOLSO_RETIRO de 99.999)',
                     $$SELECT tests.asentar(tests.pata('BOLSO_RETIRO','BOLSILLO','S',99999,tests.c(1),tests.b(1)), tests.pata('BOLSO_RETIRO','CUENTA','E',99999,tests.c(1),tests.b(1)))$$, 'Saldo insuficiente', 'P0001');
SELECT assert_raises('ENVIO por mas de lo que hay', $$SELECT public._asentar_grupo(now(), tests.g_envio(tests.c(2), tests.c(1), 999999))$$, 'Saldo insuficiente', 'P0001');
SELECT assert_raises('un abono mayor al capital pendiente deja el capital negativo: rechazado',
                     $$SELECT tests.asentar(tests.pata('CREDITO_ABONO','CUENTA','S',5000,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_ABONO','CREDITO','S',4950,tests.c(1),NULL,NULL,tests.k(1)),
                                            tests.pata('CREDITO_ABONO','RESULTADO','S',50,tests.c(1),NULL,NULL,tests.k(1)))$$, '%capital pendiente%', 'P0001');
SELECT assert_raises('bolsillo de OTRA cuenta en una pata', $$SELECT tests.asentar(tests.pata('BOLSO_INGRESO','CUENTA','S',10,tests.c(1),tests.b(3)), tests.pata('BOLSO_INGRESO','BOLSILLO','E',10,tests.c(1),tests.b(3)))$$, '%no pertenece a la cuenta%', 'P0001');
SELECT assert_raises('CDT de OTRA cuenta en una pata', $$SELECT tests.asentar(tests.pata('INTERES_CDT','CDT','E',5,tests.c(2),NULL,tests.d(1)), tests.pata('INTERES_CDT','RESULTADO','E',5,tests.c(2),NULL,tests.d(1)))$$, '%no pertenece a la cuenta%', 'P0001');
SELECT assert_raises('credito de OTRA cuenta en una pata', $$SELECT tests.asentar(tests.pata('CREDITO_MORA','CUENTA','S',5,tests.c(2),NULL,NULL,tests.k(1)), tests.pata('CREDITO_MORA','RESULTADO','S',5,tests.c(2),NULL,NULL,tests.k(1)))$$, '%no pertenece a la cuenta%', 'P0001');
SELECT assert_raises('cuenta inexistente', $$SELECT tests.asentar(tests.pata('INGRESO_SIMULADO','CUENTA','E',5,gen_random_uuid()), tests.pata('INGRESO_SIMULADO','RESULTADO','E',5,gen_random_uuid()))$$, '%no existe%', 'P0001');
SELECT assert_raises('tipo desconocido', $$SELECT tests.asentar(tests.pata('ROBO','CUENTA','E',5,tests.c(1)), tests.pata('ROBO','RESULTADO','E',5,tests.c(1)))$$, '%pata inv%', 'P0001');
SELECT assert_raises('contenedor desconocido', $$SELECT tests.asentar(tests.pata('INGRESO_SIMULADO','CAJA','E',5,tests.c(1)), tests.pata('INGRESO_SIMULADO','RESULTADO','E',5,tests.c(1)))$$, '%pata inv%', 'P0001');
SELECT assert_raises('sentido desconocido', $$SELECT tests.asentar(tests.pata('INGRESO_SIMULADO','CUENTA','X',5,tests.c(1)), tests.pata('INGRESO_SIMULADO','RESULTADO','E',5,tests.c(1)))$$, '%pata inv%', 'P0001');
SELECT assert_raises('combinacion fuera de la matriz contable (RECIBO solo es una ENTRADA de la cuenta)',
                     $$SELECT tests.asentar(tests.pata('RECIBO','CUENTA','S',5,tests.c(1)), tests.pata('RECIBO','RESULTADO','S',5,tests.c(1)))$$, '%[ck_transaccion_tipo_contenedor_sentido]%', 'P0001');
SELECT assert_raises('un CDT sin cdt_id en la pata: lo detecta el libro antes que la CHECK',
                     $$SELECT tests.asentar(tests.pata('ENVIO','CDT','S',5,tests.c(1)), tests.pata('ENVIO','RESULTADO','S',5,tests.c(1)))$$, '%no pertenece a la cuenta%', 'P0001');
SELECT assert_raises('BOLSO_INGRESO: la pata de CUENTA sin bolsillo_id viola la CHECK de familia', $$SELECT tests.asentar(tests.pata('BOLSO_INGRESO','CUENTA','S',5,tests.c(1)), tests.pata('BOLSO_INGRESO','BOLSILLO','E',5,tests.c(1),tests.b(1)))$$, '%[ck_transaccion_bolsillo_id_familia]%', 'P0001');
SELECT assert_raises('BOLSO_INGRESO: la pata de BOLSILLO sin bolsillo_id la rechaza el libro (contenedor sin producto)', $$SELECT tests.asentar(tests.pata('BOLSO_INGRESO','CUENTA','S',5,tests.c(1),tests.b(1)), tests.pata('BOLSO_INGRESO','BOLSILLO','E',5,tests.c(1)))$$, '%no pertenece a la cuenta%', 'P0001');
SELECT assert_raises('monto 0', $$SELECT tests.asentar(tests.pata('INGRESO_SIMULADO','CUENTA','E',0,tests.c(1)), tests.pata('INGRESO_SIMULADO','RESULTADO','E',0,tests.c(1)))$$, 'Monto inválido', 'P0001');
SELECT assert_raises('monto negativo', $$SELECT tests.asentar(tests.pata('INGRESO_SIMULADO','CUENTA','E',-5,tests.c(1)), tests.pata('INGRESO_SIMULADO','RESULTADO','E',-5,tests.c(1)))$$, 'Monto inválido', 'P0001');
SELECT assert_raises('monto con 3 decimales', $$SELECT tests.asentar(tests.pata('INGRESO_SIMULADO','CUENTA','E',1.005,tests.c(1)), tests.pata('INGRESO_SIMULADO','RESULTADO','E',1.005,tests.c(1)))$$, 'Monto inválido', 'P0001');
SELECT assert_raises('monto ausente', $$SELECT public._asentar_grupo(now(), jsonb_build_array(jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','CUENTA','sentido','E','cuenta_id',tests.c(1)), jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','RESULTADO','sentido','E','cuenta_id',tests.c(1))))$$, 'Monto inválido', 'P0001');
SELECT assert_raises('pata sin cuenta_id', $$SELECT public._asentar_grupo(now(), jsonb_build_array(jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','CUENTA','sentido','E','monto',5), jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','RESULTADO','sentido','E','monto',5,'cuenta_id',tests.c(1))))$$, '%necesita cuenta_id%', 'P0001');
SELECT assert_raises('cuenta_id que no es un uuid', $$SELECT public._asentar_grupo(now(), jsonb_build_array(jsonb_build_object('cuenta_id','no-es-uuid'), jsonb_build_object('cuenta_id', tests.c(1))))$$, '%pata inv%', 'P0001');
SELECT assert_raises('una sola pata', $$SELECT tests.asentar(tests.pata('INGRESO_SIMULADO','CUENTA','E',5,tests.c(1)))$$, '%al menos dos patas%', 'P0001');
SELECT assert_raises('arreglo vacio', $$SELECT public._asentar_grupo(now(), '[]'::jsonb)$$, '%al menos dos patas%', 'P0001');
SELECT assert_raises('las patas no son un arreglo', $$SELECT public._asentar_grupo(now(), '{"tipo":"X"}'::jsonb)$$, '%arreglo JSON%', 'P0001');
SELECT assert_raises('patas NULL', $$SELECT public._asentar_grupo(now(), NULL)$$, '%arreglo JSON%', 'P0001');
SELECT assert_raises('fecha NULL', $$SELECT public._asentar_grupo(NULL, tests.g_ingreso(tests.c(1), 5))$$, '%fecha%obligatoria%', 'P0001');
SELECT assert_raises('grupo descuadrado (1000 contra 999)', $$SELECT tests.asentar(tests.pata('INGRESO_SIMULADO','CUENTA','E',1000,tests.c(1)), tests.pata('INGRESO_SIMULADO','RESULTADO','E',999,tests.c(1)))$$, '%descuadrado%', 'P0001');
-- fallo a mitad de grupo: la 1a pata (CUENTA E) ya se habia aplicado cuando la 2a falla por la CHECK de familia de credito
SELECT assert_raises('fallo a MITAD de grupo (2a pata con credito_id en un ingreso): se revierte todo',
                     $$SELECT tests.asentar(tests.pata('INGRESO_SIMULADO','CUENTA','E',10,tests.c(1)), tests.pata('INGRESO_SIMULADO','RESULTADO','E',10,tests.c(1),NULL,NULL,tests.k(1)))$$, '%[ck_transaccion_credito_id_familia]%', 'P0001');
SELECT assert_eq('ningun rechazo dejo rastro: mismos saldos, mismos contenedores y mismo numero de patas', tests.huella_saldos(), (SELECT h FROM t_h));

-- ============================================================================
-- 8. Insercion DIRECTA (camino no sancionado): el trigger tambien aplica y fija los saldos; los que traiga el llamador se descartan
-- ============================================================================
SELECT assert_ok('insercion directa de un grupo valido con saldos FALSOS del llamador y luego cuadre inmediato',
                 $$INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, cuenta_id, saldo_previo, saldo_posterior, registrado_en, tx_id)
                   VALUES ('aaaaaaaa-0000-4000-8000-0000000000aa', now(), 'DEPOSITO_BANCO', 'CUENTA', 'E', 40, tests.c(2), 777, 817, '2000-01-01', '1'::xid8),
                          ('aaaaaaaa-0000-4000-8000-0000000000aa', now(), 'DEPOSITO_BANCO', 'RESULTADO', 'E', 40, tests.c(2), NULL, NULL, '2000-01-01', '1'::xid8);
                   SET CONSTRAINTS public.ct_transaccion_cuadre, public.ct_transaccion_cdt, public.ct_cdt_inversion IMMEDIATE$$);
SELECT assert_eq('...el libro ignoro los saldos del llamador y fijo los reales (previo 340, posterior 380)',
                 (SELECT (saldo_previo, saldo_posterior)::text FROM public.transaccion WHERE grupo_id = 'aaaaaaaa-0000-4000-8000-0000000000aa' AND contenedor = 'CUENTA'), '(340.00,380.00)'::text);
SELECT assert_eq('...y fijo registrado_en y tx_id (no los del llamador)',
                 (SELECT bool_and(registrado_en > now() - interval '1 hour' AND tx_id = pg_current_xact_id()) FROM public.transaccion WHERE grupo_id = 'aaaaaaaa-0000-4000-8000-0000000000aa'), true);
SELECT assert_eq('...y el saldo de la cuenta 2 es 380.00', pg_temp.cu(2), 380::numeric);

ROLLBACK;
