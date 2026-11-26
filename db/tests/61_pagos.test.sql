-- 61_pagos.test.sql · Etapa 9 · pagar_cuota, abonar_credito, activar_descuento_automatico y vista_creditos ampliada: pago completo (capital_pagado/intereses_pagados, ancla, PAGADO),
-- mora en grupo aparte y sin cobrarse dos veces, abono (mora -> interes -> capital, rangos, recalculo SIN cambiar el plazo, liquidacion), R3 (pago anticipado + abono con ancla futura,
-- dos abonos en el mismo periodo), las 5 plantillas del libro, atomicidad con falla inyectada en cada pata, una sola instantanea y permisos.
-- No repite el calculo (60), el cobro automatico (62) ni el plan/capital de E8 (57/58). Una transaccion con ROLLBACK final; solo corre en banco_test/banco_mut (mueve el reloj).
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 20) n;
SELECT tests.cliente(99);
INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol)
VALUES ('adminz', tests.hash(), 'Adm', 'In', '9300001', 'adminz@mail.co', '3170000001', DATE '1980-01-01', 'ADMIN');
UPDATE public.parametro SET tasa_mora_anual = 30;                           -- fixture de prueba (D7 provisional)
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES
  (tests.p(901), 'Libre', '', 18, 1, 1000000000, 1, 360), (tests.p(902), 'Vehiculo', '', 18, 1, 1000000000, 1, 360);
CREATE TEMP TABLE t_b AS SELECT public.hoy_banco() AS d;
CREATE FUNCTION pg_temp.dia(p_n int) RETURNS date LANGUAGE sql STABLE AS $f$ SELECT (SELECT d FROM t_b) + p_n $f$;
CREATE FUNCTION pg_temp.ir(p_n int) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(false, pg_temp.dia(p_n)::text); END $f$;
CREATE FUNCTION pg_temp.real() RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(true, ''); END $f$;
CREATE FUNCTION pg_temp.cs(p_u int) RETURNS numeric LANGUAGE sql VOLATILE AS $f$ SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(p_u) $f$;
CREATE FUNCTION pg_temp.cre(p_u int, p_prod int, p_monto numeric, p_plazo int) RETURNS uuid LANGUAGE sql AS $f$
  SELECT (public.solicitar_credito(tests.u(p_u), tests.p(p_prod)::text, p_monto, p_plazo) ->> 'id')::uuid $f$;
-- vencimientos deterministas: la cuota k vence el dia 30*k (el desembolso es el dia 0)
CREATE FUNCTION pg_temp.fijar(p_k uuid) RETURNS void LANGUAGE sql AS $f$ UPDATE public.cuota SET fecha_vencimiento = pg_temp.dia(30 * numero) WHERE credito_id = p_k $f$;
CREATE FUNCTION pg_temp.vaciar(p_u int, p_deja numeric DEFAULT 100) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN PERFORM public.hacer_transferencia(tests.u(p_u), '4000000099', pg_temp.cs(p_u) - p_deja, 'gasto', NULL); END $f$;
CREATE FUNCTION pg_temp.pc(p_u int, p_k uuid, p_num int DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN RETURN 'OK:' || (public.pagar_cuota(tests.u(p_u), p_k::text, p_num) ->> 'numero');
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $f$;
CREATE FUNCTION pg_temp.ab(p_u int, p_k uuid, p_monto numeric) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN RETURN 'OK:' || (public.abonar_credito(tests.u(p_u), p_k::text, p_monto) ->> 'capital');
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $f$;
CREATE FUNCTION pg_temp.pag(p_k uuid) RETURNS text LANGUAGE sql VOLATILE AS $f$
  SELECT coalesce(string_agg(numero || ':' || (fecha_pago - (SELECT d FROM t_b)), ',' ORDER BY numero) FILTER (WHERE pagada), '-') FROM public.cuota WHERE credito_id = p_k $f$;
CREATE FUNCTION pg_temp.k(p_k uuid) RETURNS public.credito LANGUAGE sql VOLATILE AS $f$ SELECT c FROM public.credito c WHERE c.id = p_k $f$;
CREATE FUNCTION pg_temp.legs(p_k uuid, p_tipo text) RETURNS text LANGUAGE sql VOLATILE AS $f$
  SELECT coalesce(string_agg(contenedor::text || sentido::text || ':' || monto, ',' ORDER BY contenedor::text, orden), '-') FROM public.transaccion WHERE credito_id = p_k AND tipo::text = p_tipo $f$;
CREATE FUNCTION pg_temp.tipos(p_k uuid) RETURNS text LANGUAGE sql VOLATILE AS $f$
  SELECT coalesce(string_agg(t, ',' ORDER BY o), '-') FROM (SELECT tipo::text || ':' || count(*) AS t, min(orden) AS o FROM public.transaccion WHERE credito_id = p_k AND tipo::text IN ('CREDITO_CUOTA', 'CREDITO_ABONO', 'CREDITO_MORA') GROUP BY tipo) q $f$;
CREATE FUNCTION pg_temp.mora(p_valor numeric, p_dias int) RETURNS numeric LANGUAGE sql IMMUTABLE AS $f$ SELECT round(p_valor * 0.30 / 365 * p_dias, 2) $f$;
CREATE FUNCTION pg_temp.vc(p_u int) RETURNS jsonb LANGUAGE sql VOLATILE AS $f$ SELECT public.vista_creditos(tests.u(p_u)) $f$;

-- ============================================================================
-- A. Pago completo (por ADELANTADO el dia 0, la cuota vence el dia 30): patas, capital_pagado/intereses_pagados, ancla futura, orden y numero idempotente
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_a AS SELECT pg_temp.cre(1, 901, 10000000, 12) AS k;
SELECT pg_temp.fijar((SELECT k FROM t_a));
CREATE TEMP TABLE t_ar AS SELECT public.pagar_cuota(tests.u(1), (SELECT k FROM t_a)::text) AS r;
SELECT assert_json_shape('pagar_cuota devuelve {numero, pagado, mora, fecha}', (SELECT r FROM t_ar), '{"numero":"number","pagado":"number","mora":"number","fecha":"string"}'::jsonb);
SELECT assert_eq('paga la cuota 1 completa: pagado = 910.463,77, mora 0', concat_ws('|', (SELECT r ->> 'numero' FROM t_ar), (SELECT r ->> 'pagado' FROM t_ar), (SELECT r ->> 'mora' FROM t_ar)), '1|910463.77|0.00'::text);
SELECT assert_eq('la cuota queda pagada con fecha_pago = hoy, capital_pagado = capital_programado e intereses_pagados = interes_programado',
                 (SELECT concat_ws('|', pagada, fecha_pago - (SELECT d FROM t_b), capital_pagado = capital_programado, intereses_pagados = interes_programado, valor_cuota = valor_cuota_original) FROM public.cuota WHERE credito_id = (SELECT k FROM t_a) AND numero = 1), 't|0|t|t|t'::text);
SELECT assert_eq('el grupo CREDITO_CUOTA: CUENTA S 910.463,77, CREDITO S 771.579,47 (capital), RESULTADO S 138.884,30 (interes); UNA fecha y un solo grupo',
                 concat_ws('|', pg_temp.legs((SELECT k FROM t_a), 'CREDITO_CUOTA'), (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE credito_id = (SELECT k FROM t_a) AND tipo = 'CREDITO_CUOTA')),
                 'CREDITOS:771579.47,CUENTAS:910463.77,RESULTADOS:138884.30|1'::text);
SELECT assert_eq('capital_pendiente baja el capital de la cuota (9.228.420,53), la cuenta baja la cuota, el credito sigue ACTIVO',
                 concat_ws('|', (pg_temp.k((SELECT k FROM t_a))).capital_pendiente, pg_temp.cs(1), (pg_temp.k((SELECT k FROM t_a))).estado), '9228420.53|9089536.23|ACTIVO'::text);
SELECT assert_eq('R3(a) pagada por adelantado, fecha_interes = vencimiento de la cuota 1 (dia 30, FUTURA) y el interes corriendo mostrado es 0',
                 concat_ws('|', (pg_temp.k((SELECT k FROM t_a))).fecha_interes - (SELECT d FROM t_b), (pg_temp.vc(1) -> 0 ->> 'interes_mes')), '30|0.00'::text);
SELECT assert_eq('vista_creditos: 1 pagada, 11 faltantes, saldo = capital pendiente, y los 2 campos nuevos (descuento_automatico false, mora_acumulada 0)',
                 (SELECT concat_ws('|', e ->> 'cuotas_pagadas', e ->> 'cuotas_faltantes', e ->> 'saldo', e ->> 'descuento_automatico', e ->> 'mora_acumulada') FROM jsonb_array_elements(pg_temp.vc(1)) e), '1|11|9228420.53|false|0.00'::text);
SELECT assert_json_shape('vista_creditos conserva los 6 campos del contrato y agrega descuento_automatico y mora_acumulada', pg_temp.vc(1) -> 0,
                         '{"id":"string","producto":"string","cuotas_pagadas":"number","cuotas_faltantes":"number","interes_mes":"number","saldo":"number","descuento_automatico":"boolean","mora_acumulada":"number"}'::jsonb);
SELECT assert_eq('D-E9-8: con `numero` la cuota ya pagada (1) o una que NO es la proxima (3) responde Recurso no encontrado y NO paga otra',
                 concat_ws('|', pg_temp.pc(1, (SELECT k FROM t_a), 1), pg_temp.pc(1, (SELECT k FROM t_a), 3), pg_temp.pc(1, (SELECT k FROM t_a), 0), pg_temp.pag((SELECT k FROM t_a))), 'Recurso no encontrado|Recurso no encontrado|Recurso no encontrado|1:0'::text);
SELECT assert_eq('con `numero` = la proxima (2) la paga; sin `numero` paga la siguiente (3): orden estricto, una cuota por llamada',
                 concat_ws('|', pg_temp.pc(1, (SELECT k FROM t_a), 2), pg_temp.pc(1, (SELECT k FROM t_a)), pg_temp.pag((SELECT k FROM t_a))), 'OK:2|OK:3|1:0,2:0,3:0'::text);
-- mensajes y sesion
SELECT tests.fondear(tests.c(2), 20000000);
CREATE TEMP TABLE t_a2 AS SELECT pg_temp.cre(2, 901, 10000000, 12) AS k;
SELECT assert_eq('credito ajeno, mal formado, NULL y numero invalido: Recurso no encontrado (sin distinguir) y sin rastro',
                 concat_ws('|', pg_temp.pc(1, (SELECT k FROM t_a2)), tests.captura($$SELECT public.pagar_cuota(tests.u(1), 'no-es-uuid')$$), tests.captura($$SELECT public.pagar_cuota(tests.u(1), NULL)$$),
                           tests.captura('SELECT public.abonar_credito(tests.u(1), ' || quote_literal((SELECT k FROM t_a2)) || ', 1000)'), tests.captura('SELECT public.activar_descuento_automatico(tests.u(1), ' || quote_literal((SELECT k FROM t_a2)) || ', true)')),
                 'Recurso no encontrado|Recurso no encontrado|Recurso no encontrado|Recurso no encontrado|Recurso no encontrado'::text);
DO $do$
DECLARE f text; u text; i int; r text; esp text[] := ARRAY['Sesión inválida', 'Acceso denegado']; mal text := '';
BEGIN
  FOREACH f IN ARRAY ARRAY['pagar_cuota(%L, ''x'')', 'abonar_credito(%L, ''x'', 1)', 'activar_descuento_automatico(%L, ''x'', true)'] LOOP
    i := 0;
    FOREACH u IN ARRAY ARRAY[gen_random_uuid()::text, (SELECT id::text FROM public.usuario WHERE username = 'adminz')] LOOP
      i := i + 1; r := tests.captura('SELECT public.' || format(f, u));
      IF r IS DISTINCT FROM esp[i] THEN mal := mal || f || '#' || i || ' [' || coalesce(r, 'NULL') || ']; '; END IF;
    END LOOP;
  END LOOP;
  PERFORM tests.assert_eq('las 3 funciones exigen sesion viva ANTES de todo (inexistente = Sesión inválida, ADMIN = Acceso denegado)', mal, ''::text);
END $do$;
-- Saldo insuficiente: sin rastro
SELECT pg_temp.vaciar(2);
CREATE TEMP TABLE t_h1 AS SELECT tests.huella_saldos() AS h;
SELECT assert_eq('pagar_cuota sin saldo: Saldo insuficiente y NADA cambia (huella intacta, cuota impaga)', concat_ws('|', pg_temp.pc(2, (SELECT k FROM t_a2)), tests.huella_saldos() = (SELECT h FROM t_h1), pg_temp.pag((SELECT k FROM t_a2))), 'Saldo insuficiente|t|-'::text);
-- la ultima cuota cierra el credito y libera el producto
SELECT tests.fondear(tests.c(3), 5000000);
CREATE TEMP TABLE t_a3 AS SELECT pg_temp.cre(3, 901, 3000000, 3) AS k;
SELECT pg_temp.pc(3, (SELECT k FROM t_a3)); SELECT pg_temp.pc(3, (SELECT k FROM t_a3)); SELECT pg_temp.pc(3, (SELECT k FROM t_a3));
SELECT assert_eq('al pagar la ULTIMA cuota (3 de 3): estado PAGADO, capital 0, 3 pagadas; ya no aparece en vista_creditos; pagar_cuota/abonar sobre el = Recurso no encontrado; el producto queda libre',
                 concat_ws('|', (pg_temp.k((SELECT k FROM t_a3))).estado, (pg_temp.k((SELECT k FROM t_a3))).capital_pendiente, pg_temp.pag((SELECT k FROM t_a3)) LIKE '1:0,2:0,3:0', pg_temp.vc(3)::text, pg_temp.pc(3, (SELECT k FROM t_a3)),
                           pg_temp.ab(3, (SELECT k FROM t_a3), 100), left(pg_temp.cre(3, 901, 1000000, 6)::text, 0) || 'nuevo'), 'PAGADO|0.00|t|[]|Recurso no encontrado|Recurso no encontrado|nuevo'::text);

-- ============================================================================
-- B. Mora: se cobra al pagar (grupo CREDITO_MORA aparte), se muestra derivada y se detiene al pagar
-- ============================================================================
SELECT pg_temp.real();
SELECT tests.fondear(tests.c(4), 3000000);
CREATE TEMP TABLE t_m AS SELECT pg_temp.cre(4, 901, 10000000, 12) AS k;
SELECT pg_temp.fijar((SELECT k FROM t_m));
SELECT pg_temp.ir(40);
SELECT assert_eq('antes de pagar: mora_acumulada mostrada = mora de 10 dias de la cuota 1 (vencio el dia 30); descuento_automatico false',
                 (SELECT concat_ws('|', e ->> 'mora_acumulada', e ->> 'descuento_automatico') FROM jsonb_array_elements(pg_temp.vc(4)) e), (pg_temp.mora(910463.77, 10) || '|false')::text);
CREATE TEMP TABLE t_mr AS SELECT public.pagar_cuota(tests.u(4), (SELECT k FROM t_m)::text) AS r;
SELECT assert_eq('pagado = cuota + mora, mora de 10 dias en el resultado',
                 concat_ws('|', (SELECT r ->> 'pagado' FROM t_mr), (SELECT r ->> 'mora' FROM t_mr)), ((910463.77 + pg_temp.mora(910463.77, 10)) || '|' || pg_temp.mora(910463.77, 10))::text);
SELECT assert_eq('la mora va en un grupo APARTE: CREDITO_CUOTA de 3 patas y CREDITO_MORA de 2 (CUENTA S + RESULTADO S), con la fecha de pago del dia 40',
                 concat_ws('|', pg_temp.tipos((SELECT k FROM t_m)), pg_temp.legs((SELECT k FROM t_m), 'CREDITO_MORA'), pg_temp.pag((SELECT k FROM t_m))),
                 ('CREDITO_CUOTA:3,CREDITO_MORA:2|CUENTAS:' || pg_temp.mora(910463.77, 10) || ',RESULTADOS:' || pg_temp.mora(910463.77, 10) || '|1:40')::text);
SELECT assert_eq('la mora se DETIENE al pagar: la mora mostrada despues es 0 (la cuota 2 vence el dia 60)', (SELECT e ->> 'mora_acumulada' FROM jsonb_array_elements(pg_temp.vc(4)) e), '0.00'::text);

-- ============================================================================
-- C. R3. Pago anticipado + abonos con ANCLA FUTURA, mitad de periodo y recalculo sin cambiar el plazo
-- ============================================================================
SELECT pg_temp.real();
SELECT tests.fondear(tests.c(5), 5000000);
CREATE TEMP TABLE t_r3 AS SELECT pg_temp.cre(5, 901, 10000000, 12) AS k;
SELECT pg_temp.fijar((SELECT k FROM t_r3));
CREATE TEMP TABLE t_fechas AS SELECT md5(string_agg(fecha_vencimiento::text, ',' ORDER BY numero)) AS h FROM public.cuota WHERE credito_id = (SELECT k FROM t_r3);
SELECT pg_temp.ir(5);
SELECT pg_temp.pc(5, (SELECT k FROM t_r3));                                        -- cuota 1 pagada el dia 5 (vence el 30)
SELECT pg_temp.ir(10);
SELECT assert_eq('R3(a) tras el pago anticipado el interes corriendo sigue en 0 el dia 10 (el periodo de la cuota 2 empieza el dia 30)', (pg_temp.vc(5) -> 0 ->> 'interes_mes'), '0.00'::text);
CREATE TEMP TABLE t_r3a AS SELECT public.abonar_credito(tests.u(5), (SELECT k FROM t_r3)::text, 1000000) AS r;
SELECT assert_json_shape('abonar_credito devuelve {fecha, mora, interes, capital, saldo, cuota_nueva}', (SELECT r FROM t_r3a), '{"fecha":"string","mora":"number","interes":"number","capital":"number","saldo":"number","cuota_nueva":"number"}'::jsonb);
SELECT assert_eq('R3(b) abono anticipado: mora 0, interes 0 (el periodo no empezo), TODO el abono baja capital: saldo 9.228.420,53 - 1.000.000 = 8.228.420,53',
                 concat_ws('|', (SELECT r ->> 'mora' FROM t_r3a), (SELECT r ->> 'interes' FROM t_r3a), (SELECT r ->> 'capital' FROM t_r3a), (SELECT r ->> 'saldo' FROM t_r3a)), '0.00|0.00|1000000.00|8228420.53'::text);
SELECT assert_eq('R3(b) el ancla NO se mueve (sigue en el dia 30) y la cuota nueva = cuota francesa estandar de K'' a 11 cuotas (referencia independiente, ±1 centavo)',
                 concat_ws('|', (pg_temp.k((SELECT k FROM t_r3))).fecha_interes - (SELECT d FROM t_b),
                           abs((SELECT r ->> 'cuota_nueva' FROM t_r3a)::numeric - (SELECT cuota FROM public._plan_cuotas(8228420.53, 18, 11) WHERE numero = 1)) <= 0.01), '30|t'::text);
SELECT assert_eq('R3(b) plazo y vencimientos intactos (11 impagas, mismas fechas), valor_cuota_original intacto, Σ capital_programado = capital_pendiente = 8.228.420,53, j0 = interes de un periodo COMPLETO',
                 (SELECT concat_ws('|', count(*) FILTER (WHERE NOT pagada), (SELECT md5(string_agg(fecha_vencimiento::text, ',' ORDER BY numero)) = (SELECT h FROM t_fechas) FROM public.cuota WHERE credito_id = (SELECT k FROM t_r3)),
                                   max(valor_cuota_original), sum(capital_programado) FILTER (WHERE NOT pagada), (SELECT capital_pendiente FROM public.credito WHERE id = (SELECT k FROM t_r3)),
                                   (SELECT interes_programado = round(8228420.53 * public._tasa_mensual(18), 2) FROM public.cuota WHERE credito_id = (SELECT k FROM t_r3) AND numero = 2))
                    FROM public.cuota WHERE credito_id = (SELECT k FROM t_r3)), '11|t|910463.77|8228420.53|8228420.53|t'::text);
SELECT assert_eq('R3(b) el libro: CREDITO_ABONO SIN pata de interes (CUENTA S 1.000.000 + CREDITO S 1.000.000) y la integridad del plan en orden',
                 concat_ws('|', pg_temp.legs((SELECT k FROM t_r3), 'CREDITO_ABONO'), (SELECT ok FROM public.v_integridad_global)), 'CREDITOS:1000000.00,CUENTAS:1000000.00|t'::text);
SELECT pg_temp.ir(15);
CREATE TEMP TABLE t_r3b AS SELECT public.abonar_credito(tests.u(5), (SELECT k FROM t_r3)::text, 500000) AS r;
SELECT assert_eq('R3(c) segundo abono en la ventana anticipada: interes 0, el ancla sigue en el dia 30 y la cuota nueva = cuota estandar de K'''' = 7.728.420,53 a 11 cuotas',
                 concat_ws('|', (SELECT r ->> 'interes' FROM t_r3b), (SELECT r ->> 'saldo' FROM t_r3b), (pg_temp.k((SELECT k FROM t_r3))).fecha_interes - (SELECT d FROM t_b),
                           abs((SELECT r ->> 'cuota_nueva' FROM t_r3b)::numeric - (SELECT cuota FROM public._plan_cuotas(7728420.53, 18, 11) WHERE numero = 1)) <= 0.01), '0.00|7728420.53|30|t'::text);
-- abono con el ancla ya alcanzada: dia 45 de un periodo [30, 60]: I = interes del periodo * 15/30; el ancla pasa a 45
SELECT pg_temp.ir(45);
CREATE TEMP TABLE t_i45 AS SELECT interes_programado AS i2 FROM public.cuota WHERE credito_id = (SELECT k FROM t_r3) AND numero = 2;
SELECT assert_eq('R3(d) el dia 45 (mitad del periodo 2) el interes corriendo = interes de la cuota 2 * 15/30', (pg_temp.vc(5) -> 0 ->> 'interes_mes')::numeric, (SELECT round(i2 * 15 / 30, 2) FROM t_i45));
CREATE TEMP TABLE t_r3c AS SELECT public.abonar_credito(tests.u(5), (SELECT k FROM t_r3)::text, 600000) AS r;
SELECT assert_eq('R3(d) abono de 600.000 a mitad de periodo: cobra primero el interes corriendo y el resto baja capital; el ancla pasa al dia 45',
                 concat_ws('|', (SELECT r ->> 'interes' FROM t_r3c) = (SELECT round(i2 * 15 / 30, 2)::text FROM t_i45), (SELECT (r ->> 'capital')::numeric + (r ->> 'interes')::numeric FROM t_r3c), (pg_temp.k((SELECT k FROM t_r3))).fecha_interes - (SELECT d FROM t_b)), 't|600000.00|45'::text);
SELECT assert_eq('R3(d) la cuota 2 queda solo con el resto del periodo: interes = round(K''''''·i·15/30, 2); Σ capital impago = capital pendiente; 11 impagas; intereses_pagados de la cuota 2 = el interes cobrado',
                 (SELECT concat_ws('|', interes_programado = round((SELECT capital_pendiente FROM public.credito WHERE id = (SELECT k FROM t_r3)) * public._tasa_mensual(18) * 15 / 30, 2), intereses_pagados = (SELECT round(i2 * 15 / 30, 2) FROM t_i45),
                                   (SELECT sum(capital_programado) = (SELECT capital_pendiente FROM public.credito WHERE id = (SELECT k FROM t_r3)) FROM public.cuota WHERE credito_id = (SELECT k FROM t_r3) AND NOT pagada),
                                   (SELECT count(*) FROM public.cuota WHERE credito_id = (SELECT k FROM t_r3) AND NOT pagada))
                    FROM public.cuota WHERE credito_id = (SELECT k FROM t_r3) AND numero = 2), 't|t|t|11'::text);
-- dos abonos en el mismo periodo = suma de TRAMOS (el escenario del diseño: cuota 1 pagada a tiempo el dia 30; abonos dia 40 y dia 50; cuota 2 pagada el dia 60)
SELECT pg_temp.real();
SELECT tests.fondear(tests.c(6), 5000000);
CREATE TEMP TABLE t_r4 AS SELECT pg_temp.cre(6, 901, 10000000, 12) AS k;
SELECT pg_temp.fijar((SELECT k FROM t_r4));
SELECT pg_temp.ir(30); SELECT pg_temp.pc(6, (SELECT k FROM t_r4));
SELECT pg_temp.ir(40); SELECT pg_temp.ab(6, (SELECT k FROM t_r4), 1000000);
SELECT pg_temp.ir(50); SELECT pg_temp.ab(6, (SELECT k FROM t_r4), 500000);
SELECT pg_temp.ir(60); SELECT pg_temp.pc(6, (SELECT k FROM t_r4));
SELECT assert_eq('dos abonos en el mismo periodo: el interes total cobrado en el periodo 2 (abono 1 + abono 2 + resto en la cuota 2) = 117.167,43 = la suma de los tramos de 10 dias sobre cada saldo (y NO 18.076,79 mas)',
                 (SELECT (sum(monto) FILTER (WHERE tipo = 'CREDITO_ABONO' AND contenedor = 'RESULTADO'))::text || '+' ||
                         (SELECT monto::text FROM public.transaccion WHERE credito_id = (SELECT k FROM t_r4) AND tipo = 'CREDITO_CUOTA' AND contenedor = 'RESULTADO' ORDER BY orden DESC LIMIT 1) || '=' ||
                         ((sum(monto) FILTER (WHERE tipo = 'CREDITO_ABONO' AND contenedor = 'RESULTADO')) + (SELECT monto FROM public.transaccion WHERE credito_id = (SELECT k FROM t_r4) AND tipo = 'CREDITO_CUOTA' AND contenedor = 'RESULTADO' ORDER BY orden DESC LIMIT 1))::text
                    FROM public.transaccion WHERE credito_id = (SELECT k FROM t_r4)), '81013.83+36153.60=117167.43'::text);
SELECT assert_eq('...las cuotas 1 y 2 quedan pagadas a tiempo (dias 30 y 60) y el credito sigue en orden (capital = Σ capital impago)', concat_ws('|', pg_temp.pag((SELECT k FROM t_r4)), (SELECT ok FROM public.v_integridad_creditos WHERE credito_id = (SELECT k FROM t_r4))), '1:30,2:60|t'::text);

-- ============================================================================
-- D. Abono con cuota VENCIDA: mora primero, interes completo del periodo, j0 = 0, ancla en el vencimiento, la mora no se cobra dos veces
-- ============================================================================
SELECT pg_temp.real();
SELECT tests.fondear(tests.c(7), 5000000);
CREATE TEMP TABLE t_d AS SELECT pg_temp.cre(7, 901, 10000000, 12) AS k;
SELECT pg_temp.fijar((SELECT k FROM t_d));
SELECT pg_temp.ir(40);                                                             -- la cuota 1 vencio el dia 30: 10 dias de mora
CREATE TEMP TABLE t_dr AS SELECT public.abonar_credito(tests.u(7), (SELECT k FROM t_d)::text, 1000000) AS r;
SELECT assert_eq('abono con la cuota 1 vencida: mora de 10 dias + interes COMPLETO del periodo (138.884,30) + resto a capital',
                 concat_ws('|', (SELECT r ->> 'mora' FROM t_dr), (SELECT r ->> 'interes' FROM t_dr), (SELECT r ->> 'capital' FROM t_dr)), (pg_temp.mora(910463.77, 10) || '|138884.30|' || (1000000 - pg_temp.mora(910463.77, 10) - 138884.30))::text);
SELECT assert_eq('libro: CREDITO_MORA (2 patas) y CREDITO_ABONO (3 patas) en ese orden',
                 pg_temp.tipos((SELECT k FROM t_d)), 'CREDITO_MORA:2,CREDITO_ABONO:3'::text);
SELECT assert_eq('la cuota 1 queda con interes_programado 0 (rem = 0) y valor = capital; el ancla en su vencimiento (dia 30, NO en hoy); intereses_pagados = 138.884,30; mora_hasta = hoy (dia 40)',
                 (SELECT concat_ws('|', q.interes_programado, q.valor_cuota = q.capital_programado, k.fecha_interes - (SELECT d FROM t_b), q.intereses_pagados, k.mora_hasta - (SELECT d FROM t_b))
                    FROM public.cuota q JOIN public.credito k ON k.id = q.credito_id WHERE q.credito_id = (SELECT k FROM t_d) AND q.numero = 1), '0.00|t|30|138884.30|40'::text);
SELECT assert_eq('la mora YA cobrada no se cobra de nuevo: justo despues del abono la mora mostrada es 0', (SELECT e ->> 'mora_acumulada' FROM jsonb_array_elements(pg_temp.vc(7)) e), '0.00'::text);
SELECT pg_temp.pc(7, (SELECT k FROM t_d));
SELECT assert_eq('...pagar la cuota 1 hoy (mismo dia): NO genera un segundo grupo de mora (la mora total cobrada es la del abono) y la cuota sale SIN pata de interes (CUENTA S + CREDITO S)',
                 concat_ws('|', pg_temp.tipos((SELECT k FROM t_d)), (SELECT sum(monto) FROM public.transaccion WHERE credito_id = (SELECT k FROM t_d) AND tipo = 'CREDITO_MORA' AND contenedor = 'CUENTA') = pg_temp.mora(910463.77, 10)), 'CREDITO_MORA:2,CREDITO_ABONO:3,CREDITO_CUOTA:2|t'::text);
-- rangos del abono
SELECT pg_temp.real();
SELECT tests.fondear(tests.c(8), 20000000);
CREATE TEMP TABLE t_g AS SELECT pg_temp.cre(8, 901, 10000000, 12) AS k;
SELECT pg_temp.fijar((SELECT k FROM t_g));
SELECT pg_temp.ir(45);                                                             -- cuota 1 vencida (dia 30): M = mora de 15 dias, I = 138.884,30
CREATE TEMP TABLE t_g1 AS SELECT pg_temp.mora(910463.77, 15) + 138884.30 AS mi;
SELECT assert_eq('abono <= mora + interes (no reduce capital) = Monto fuera de rango; mora + interes + 0,01 si se acepta; sobre la liquidacion (+0,01) = Monto fuera de rango; 0 y 3 decimales = Monto inválido',
                 concat_ws('|', pg_temp.ab(8, (SELECT k FROM t_g), (SELECT mi FROM t_g1)), pg_temp.ab(8, (SELECT k FROM t_g), 100), pg_temp.ab(8, (SELECT k FROM t_g), (SELECT mi + 10000000.01 FROM t_g1)),
                           pg_temp.ab(8, (SELECT k FROM t_g), 0), pg_temp.ab(8, (SELECT k FROM t_g), 1000.001), pg_temp.pag((SELECT k FROM t_g)), (pg_temp.k((SELECT k FROM t_g))).capital_pendiente),
                 'Monto fuera de rango|Monto fuera de rango|Monto fuera de rango|Monto inválido|Monto inválido|-|10000000.00'::text);
SELECT assert_eq('mora + interes + 0,01 SI se acepta (capital abonado 0,01) y la deuda baja exactamente 0,01', concat_ws('|', pg_temp.ab(8, (SELECT k FROM t_g), (SELECT mi + 0.01 FROM t_g1)), (pg_temp.k((SELECT k FROM t_g))).capital_pendiente), 'OK:0.01|9999999.99'::text);

-- ============================================================================
-- E. LIQUIDACION: abono = capital + interes corriendo (a mitad de periodo) y la liquidacion en ventana anticipada (solo capital)
-- ============================================================================
SELECT pg_temp.real();
SELECT tests.fondear(tests.c(9), 15000000); SELECT tests.fondear(tests.c(10), 15000000);
CREATE TEMP TABLE t_l1 AS SELECT pg_temp.cre(9, 901, 10000000, 12) AS k;
CREATE TEMP TABLE t_l2 AS SELECT pg_temp.cre(10, 901, 10000000, 12) AS k;
SELECT pg_temp.fijar((SELECT k FROM t_l1)); SELECT pg_temp.fijar((SELECT k FROM t_l2));
SELECT pg_temp.ir(15);
CREATE TEMP TABLE t_l1r AS SELECT public.abonar_credito(tests.u(9), (SELECT k FROM t_l1)::text, 10000000 + round(138884.30 * 15 / 30, 2)) AS r;
SELECT assert_eq('liquidacion el dia 15 (mitad del periodo 1): capital 10.000.000 + interes 69.442,15; saldo 0 y cuota_nueva 0',
                 concat_ws('|', (SELECT r ->> 'capital' FROM t_l1r), (SELECT r ->> 'interes' FROM t_l1r), (SELECT r ->> 'saldo' FROM t_l1r), (SELECT r ->> 'cuota_nueva' FROM t_l1r)), '10000000.00|69442.15|0.00|0'::text);
SELECT assert_eq('el credito queda PAGADO; las 12 cuotas siguen existiendo y quedan pagadas el dia 15 (extinguidas por abono: capital_pagado 0); intereses_pagados de la cuota 1 = 69.442,15; fuera de vista_creditos; el producto queda libre',
                 concat_ws('|', (pg_temp.k((SELECT k FROM t_l1))).estado, (SELECT count(*) FROM public.cuota WHERE credito_id = (SELECT k FROM t_l1) AND pagada AND fecha_pago = pg_temp.dia(15) AND capital_pagado = 0), (SELECT intereses_pagados FROM public.cuota WHERE credito_id = (SELECT k FROM t_l1) AND numero = 1),
                           pg_temp.vc(9)::text, (SELECT ok FROM public.v_integridad_creditos WHERE credito_id = (SELECT k FROM t_l1))), 'PAGADO|12|69442.15|[]|t'::text);
SELECT assert_eq('el libro de la liquidacion: CREDITO_ABONO con las 3 patas (CUENTA S 10.069.442,15, CREDITO S 10.000.000, RESULTADO S 69.442,15)', pg_temp.legs((SELECT k FROM t_l1), 'CREDITO_ABONO'), 'CREDITOS:10000000.00,CUENTAS:10069442.15,RESULTADOS:69442.15'::text);
SELECT pg_temp.real(); SELECT pg_temp.ir(5); SELECT pg_temp.pc(10, (SELECT k FROM t_l2));                  -- pago anticipado de la cuota 1 el dia 5 (vence el 30)
SELECT pg_temp.ir(10);
CREATE TEMP TABLE t_l2r AS SELECT public.abonar_credito(tests.u(10), (SELECT k FROM t_l2)::text, 9228420.53) AS r;
SELECT assert_eq('R3(f) liquidacion en ventana anticipada: SOLO capital (9.228.420,53), interes 0, credito PAGADO y el asiento sin pata de interes',
                 concat_ws('|', (SELECT r ->> 'interes' FROM t_l2r), (SELECT r ->> 'saldo' FROM t_l2r), (pg_temp.k((SELECT k FROM t_l2))).estado, pg_temp.legs((SELECT k FROM t_l2), 'CREDITO_ABONO')), '0.00|0.00|PAGADO|CREDITOS:9228420.53,CUENTAS:9228420.53'::text);

-- ============================================================================
-- F. activar_descuento_automatico: forma, sin escribir el libro, idempotencia (el ciclo del cursor se prueba en 62)
-- ============================================================================
SELECT pg_temp.real();
SELECT tests.fondear(tests.c(11), 5000000);
CREATE TEMP TABLE t_f AS SELECT pg_temp.cre(11, 901, 10000000, 12) AS k;
CREATE TEMP TABLE t_fh AS SELECT tests.huella_saldos() AS h;
CREATE TEMP TABLE t_fr AS SELECT public.activar_descuento_automatico(tests.u(11), (SELECT k FROM t_f)::text, true) AS r;
SELECT assert_json_shape('activar_descuento_automatico devuelve {id, descuento_automatico}', (SELECT r FROM t_fr), '{"id":"string","descuento_automatico":"boolean"}'::jsonb);
SELECT assert_eq('activar: descuento_automatico true, cursor = hoy; el libro NO se toca (huella intacta); vista_creditos lo muestra',
                 concat_ws('|', (pg_temp.k((SELECT k FROM t_f))).descuento_automatico, (pg_temp.k((SELECT k FROM t_f))).cobro_hasta - (SELECT d FROM t_b), tests.huella_saldos() = (SELECT h FROM t_fh), (pg_temp.vc(11) -> 0 ->> 'descuento_automatico')), 't|0|t|true'::text);
SELECT assert_eq('boolean NULL = Recurso no encontrado; activar un credito ajeno = Recurso no encontrado',
                 concat_ws('|', tests.captura('SELECT public.activar_descuento_automatico(tests.u(11), ' || quote_literal((SELECT k FROM t_f)) || ', NULL)'), tests.captura('SELECT public.activar_descuento_automatico(tests.u(1), ' || quote_literal((SELECT k FROM t_f)) || ', true)')),
                 'Recurso no encontrado|Recurso no encontrado'::text);

-- ============================================================================
-- G. Las 5 plantillas del libro (D-E9-7): formas validas aceptadas, invalidas rechazadas; la integridad las reconoce
-- ============================================================================
SELECT assert_eq('_plantillas_validas tiene 20 formas, las 5 nuevas de credito incluidas',
                 (SELECT concat_ws('|', count(*), count(*) FILTER (WHERE plantilla IN ('CREDITO_CUOTA', 'CREDITO_CUOTA_SIN_INTERES', 'CREDITO_ABONO', 'CREDITO_ABONO_SIN_INTERES', 'CREDITO_MORA'))) FROM public._plantillas_validas()), '20|5'::text);
SAVEPOINT sg;                                                                      -- (estos grupos mueven capital_pendiente sin tocar el plan: se deshacen antes de seguir)
SELECT tests.fondear(tests.c(12), 5000000);
CREATE TEMP TABLE t_p AS SELECT pg_temp.cre(12, 901, 1000000, 12) AS k;
CREATE FUNCTION pg_temp.g(p_tipo text, VARIADIC p_l text[]) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v_patas jsonb := '[]'::jsonb; x text; v_k uuid := (SELECT k FROM t_p);
BEGIN
  FOREACH x IN ARRAY p_l LOOP
    v_patas := v_patas || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('tipo', p_tipo, 'contenedor', split_part(x, ':', 1), 'sentido', 'S', 'monto', split_part(x, ':', 2)::numeric,
                                            'cuenta_id', tests.c(12), 'credito_id', v_k, 'contraparte_nombre', CASE WHEN split_part(x, ':', 1) = 'RESULTADO' THEN 'Banco Digital' END)));
  END LOOP;
  PERFORM public._asentar_grupo(now(), v_patas);
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $f$;
SELECT assert_eq('formas VALIDAS aceptadas: CUOTA (3 patas), CUOTA sin interes, ABONO (3), ABONO sin interes y MORA',
                 concat_ws('|', pg_temp.g('CREDITO_CUOTA', 'CUENTA:110', 'CREDITO:100', 'RESULTADO:10'), pg_temp.g('CREDITO_CUOTA', 'CUENTA:100', 'CREDITO:100'), pg_temp.g('CREDITO_ABONO', 'CUENTA:55', 'CREDITO:50', 'RESULTADO:5'),
                           pg_temp.g('CREDITO_ABONO', 'CUENTA:40', 'CREDITO:40'), pg_temp.g('CREDITO_MORA', 'CUENTA:7', 'RESULTADO:7')), 'OK|OK|OK|OK|OK'::text);
SELECT assert_eq('formas INVALIDAS rechazadas por el libro: CUOTA sin pata de CREDITO, ABONO sin pata de CREDITO, CUOTA con el RESULTADO repetido (4 patas), MORA con 3 patas',
                 concat_ws('|', pg_temp.g('CREDITO_CUOTA', 'CUENTA:10', 'RESULTADO:10') LIKE '%no corresponde a ninguna forma contable válida%', pg_temp.g('CREDITO_ABONO', 'CUENTA:10', 'RESULTADO:10') LIKE '%no corresponde a ninguna forma contable válida%',
                           pg_temp.g('CREDITO_CUOTA', 'CUENTA:110', 'CREDITO:100', 'RESULTADO:5', 'RESULTADO:5') LIKE '%no corresponde a ninguna forma contable válida%', pg_temp.g('CREDITO_MORA', 'CUENTA:10', 'RESULTADO:5', 'RESULTADO:5') LIKE '%no corresponde a ninguna forma contable válida%'),
                 't|t|t|t'::text);
SELECT assert_eq('v_integridad_grupos: los 5 grupos de credito aceptados se clasifican OK (ninguno SIN_PLANTILLA_CREDITO) y el contador global grupos_credito_sin_plantilla es 0',
                 concat_ws('|', (SELECT count(DISTINCT g.grupo_id) FROM public.v_integridad_grupos g JOIN public.transaccion t ON t.grupo_id = g.grupo_id WHERE t.credito_id = (SELECT k FROM t_p) AND g.estado = 'OK' AND g.plantilla LIKE 'CREDITO\_%' AND g.plantilla <> 'CREDITO_DESEMBOLSO'), (SELECT grupos_credito_sin_plantilla FROM public.v_integridad_global)), '5|0'::text);
SELECT assert_eq('las reglas generales de E2 siguen mandando: un grupo de credito con dos creditos distintos o dos cuentas se rechaza con SU mensaje de E2',
                 concat_ws('|', (tests.captura($$SELECT public._asentar_grupo(now(), jsonb_build_array(
                     jsonb_build_object('tipo','CREDITO_MORA','contenedor','CUENTA','sentido','S','monto',5,'cuenta_id',tests.c(12),'credito_id',(SELECT k FROM t_p)),
                     jsonb_build_object('tipo','CREDITO_MORA','contenedor','RESULTADO','sentido','S','monto',5,'cuenta_id',tests.c(11),'credito_id',(SELECT k FROM t_f),'contraparte_nombre','Banco Digital')))$$) LIKE '%más de una cuenta%')), 't'::text);

ROLLBACK TO sg;
-- ============================================================================
-- H. ATOMICIDAD: falla inyectada en cada pata (mora 2 + cuota 3 = 5; mora 2 + abono 3 = 5) y en la actualizacion de cuota y credito
-- ============================================================================
SELECT pg_temp.real();
SELECT tests.fondear(tests.c(13), 5000000); SELECT tests.fondear(tests.c(14), 5000000);
CREATE TEMP TABLE t_h13 AS SELECT pg_temp.cre(13, 901, 10000000, 12) AS k;
CREATE TEMP TABLE t_h14 AS SELECT pg_temp.cre(14, 901, 10000000, 12) AS k;
SELECT pg_temp.fijar((SELECT k FROM t_h13)); SELECT pg_temp.fijar((SELECT k FROM t_h14));
SELECT pg_temp.ir(40);                                                             -- las cuotas 1 vencieron el dia 30: hay mora
CREATE FUNCTION tests.trg_falla_e9() RETURNS trigger LANGUAGE plpgsql AS $f$
DECLARE v text := coalesce(current_setting('tests.falla_e9', true), '');
BEGIN
  IF v = TG_TABLE_NAME THEN RAISE EXCEPTION 'FALLA INYECTADA al actualizar %', TG_TABLE_NAME USING ERRCODE = 'P0001'; END IF;
  RETURN NEW;
END $f$;
CREATE TRIGGER trg_zz_falla_e9 BEFORE UPDATE ON public.cuota   FOR EACH ROW EXECUTE FUNCTION tests.trg_falla_e9();
CREATE TRIGGER trg_zz_falla_e9 BEFORE UPDATE OF fecha_interes, mora_hasta, estado, cobro_hasta ON public.credito FOR EACH ROW EXECUTE FUNCTION tests.trg_falla_e9();
SELECT tests.instalar_fallas();
DO $do$
DECLARE p int; mal text := ''; h0 text; r text; v text; k13 uuid := (SELECT k FROM t_h13); k14 uuid := (SELECT k FROM t_h14);
BEGIN
  h0 := tests.huella_saldos();
  FOR p IN 1..5 LOOP                                                              -- pagar_cuota con mora: 3 patas de cuota + 2 de mora
    PERFORM tests.falla('tx:' || p);
    r := pg_temp.pc(13, k13);
    IF r NOT LIKE 'FALLA INYECTADA%' OR tests.huella_saldos() <> h0 OR pg_temp.pag(k13) <> '-' THEN mal := mal || 'pc' || p || ':' || coalesce(r, 'NULL') || '; '; END IF;
    PERFORM tests.falla('tx:' || p);
    r := pg_temp.ab(14, k14, 2000000);                                            -- abonar con mora e interes: 2 patas de mora + 3 de abono
    IF r NOT LIKE 'FALLA INYECTADA%' OR tests.huella_saldos() <> h0 OR (pg_temp.k(k14)).mora_hasta IS NOT NULL THEN mal := mal || 'ab' || p || ':' || coalesce(r, 'NULL') || '; '; END IF;
  END LOOP;
  PERFORM tests.falla('');
  FOREACH v IN ARRAY ARRAY['cuota', 'credito'] LOOP                               -- falla DESPUES del libro, al actualizar el plan o el credito
    PERFORM set_config('tests.falla_e9', v, true);
    r := pg_temp.pc(13, k13);
    IF r NOT LIKE 'FALLA INYECTADA%' OR tests.huella_saldos() <> h0 OR pg_temp.pag(k13) <> '-' THEN mal := mal || 'pc-' || v || ':' || coalesce(r, 'NULL') || '; '; END IF;
    r := pg_temp.ab(14, k14, 2000000);
    IF r NOT LIKE 'FALLA INYECTADA%' OR tests.huella_saldos() <> h0 THEN mal := mal || 'ab-' || v || ':' || coalesce(r, 'NULL') || '; '; END IF;
  END LOOP;
  PERFORM set_config('tests.falla_e9', '', true);
  PERFORM tests.assert_eq('falla inyectada en CADA una de las 5 patas de pagar_cuota y de abonar_credito y despues del libro (cuota y credito): nada queda a medias (huella, cuotas pagadas y mora_hasta intactos)', mal, ''::text);
END $do$;
DROP TRIGGER trg_zz_falla_e9 ON public.cuota; DROP TRIGGER trg_zz_falla_e9 ON public.credito;
SELECT tests.falla(''); SELECT tests.quitar_fallas();
SELECT assert_eq('sin fallas: la misma cuota se paga (con mora de 10 dias) y el abono se acepta', concat_ws('|', pg_temp.pc(13, (SELECT k FROM t_h13)), left(pg_temp.ab(14, (SELECT k FROM t_h14), 2000000), 3)), 'OK:1|OK:'::text);

-- ============================================================================
-- I. Catalogo, una sola instantanea y permisos
-- ============================================================================
SELECT assert_eq('las 3 funciones nuevas: _avanzar_hasta( EXACTAMENTE 1 vez y _reloj_instantanea() EXACTAMENTE 1 vez con la instantanea ANTES; _bloquear_cuentas( 1 vez DESPUES del devengo; ct_credito_plan verificado antes de volver (pagar y abonar)',
                 (SELECT array_agg(p.proname::text ORDER BY p.proname::text) FILTER (WHERE (length(p.prosrc) - length(replace(p.prosrc, '_avanzar_hasta(', ''))) / length('_avanzar_hasta(') <> 1
                                                                                           OR (length(p.prosrc) - length(replace(p.prosrc, '_reloj_instantanea()', ''))) / length('_reloj_instantanea()') <> 1
                                                                                           OR strpos(p.prosrc, '_reloj_instantanea()') > strpos(p.prosrc, '_avanzar_hasta(')
                                                                                           OR (length(p.prosrc) - length(replace(p.prosrc, '_bloquear_cuentas(', ''))) / length('_bloquear_cuentas(') <> 1
                                                                                           OR strpos(p.prosrc, '_avanzar_hasta(') > strpos(p.prosrc, '_bloquear_cuentas(')
                                                                                           OR (p.proname IN ('pagar_cuota', 'abonar_credito') AND p.prosrc NOT LIKE '%ct_credito_plan, public.ct_credito_plan_cuota IMMEDIATE%'))
                    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('pagar_cuota', 'abonar_credito', 'activar_descuento_automatico')), NULL::text[]);
SELECT assert_eq('ni las 3 publicas ni los helpers de E9 leen el reloj por su cuenta (now, current_date, clock_timestamp, hoy_banco, ahora_banco, _ahora_real); el dinero solo por _asentar_grupo (ningun INSERT INTO transaccion)',
                 (SELECT array_agg(p.proname::text ORDER BY p.proname::text) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                     AND p.proname IN ('pagar_cuota', 'abonar_credito', 'activar_descuento_automatico', '_pagar_cuota_interna', '_cobrar_creditos', '_credito_propio', '_mora_cuota', '_mora_de_cuota', '_mora_pendiente', '_plan_restante', '_inicio_periodo', '_dias_mora', '_proxima_cuota')
                     AND (p.prosrc ~* '(now\(\)|current_date|current_timestamp|clock_timestamp|hoy_banco|ahora_banco|_ahora_real)' OR p.prosrc ~* 'insert\s+into\s+public\.transaccion')), NULL::text[]);
SELECT assert_eq('banco_app ejecuta las 3 publicas y NINGUNA interna de E9; banco_lector y PUBLIC ninguna',
                 (SELECT concat_ws('|', count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE') AND p.proname IN ('pagar_cuota', 'abonar_credito', 'activar_descuento_automatico')),
                          count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE') AND p.proname NOT IN ('pagar_cuota', 'abonar_credito', 'activar_descuento_automatico')),
                          count(*) FILTER (WHERE has_function_privilege('banco_lector', p.oid, 'EXECUTE')),
                          count(*) FILTER (WHERE EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))
                    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('pagar_cuota', 'abonar_credito', 'activar_descuento_automatico', '_pagar_cuota_interna', '_cobrar_creditos', '_credito_propio', '_reglas_pago', '_mora_cuota', '_mora_de_cuota',
                                                                                                   '_mora_pendiente', '_plan_restante', '_inicio_periodo', '_dias_mora', '_proxima_cuota', 'trg_cobro_hasta_monotono')), '3|0|0|0'::text);
SELECT assert_eq('las 3 publicas son SECURITY DEFINER con search_path fijo y dueño banco_owner', (SELECT bool_and(p.prosecdef AND pg_get_userbyid(p.proowner) = 'banco_owner' AND p.proconfig::text LIKE '%search_path=public, pg_temp%')::text
                    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('pagar_cuota', 'abonar_credito', 'activar_descuento_automatico')), 'true'::text);
-- lecturas del reloj (conteo dinamico)
SELECT tests.fondear(tests.c(15), 5000000);
SELECT pg_temp.real();
CREATE TEMP TABLE t_c AS SELECT pg_temp.cre(15, 901, 3000000, 6) AS k;
SELECT pg_temp.fijar((SELECT k FROM t_c));
CREATE TEMP SEQUENCE sq_lect;
GRANT USAGE, SELECT, UPDATE ON SEQUENCE sq_lect TO banco_owner;
CREATE OR REPLACE FUNCTION public._ahora_real() RETURNS timestamptz LANGUAGE plpgsql VOLATILE SET search_path = public, pg_temp AS $f$
BEGIN RETURN '2026-11-21 10:00:00-05'::timestamptz + make_interval(secs => nextval('pg_temp.sq_lect')::int); END $f$;
CREATE FUNCTION pg_temp.lect() RETURNS int LANGUAGE sql VOLATILE AS $f$ SELECT CASE WHEN is_called THEN last_value::int ELSE 0 END FROM pg_temp.sq_lect $f$;
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.pagar_cuota(tests.u(15), (SELECT k FROM t_c)::text);
SELECT assert_eq('pagar_cuota sin nada vencido: 1 lectura (instantanea) + 3 patas del grupo CREDITO_CUOTA = 4', pg_temp.lect(), 4);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.abonar_credito(tests.u(15), (SELECT k FROM t_c)::text, 100000);
SELECT assert_eq('abonar_credito sin mora y con el periodo no iniciado: 1 + 2 patas (CUENTA S y CREDITO S) = 3', pg_temp.lect(), 3);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.activar_descuento_automatico(tests.u(15), (SELECT k FROM t_c)::text, true);
SELECT assert_eq('activar_descuento_automatico: 1 lectura (solo la instantanea)', pg_temp.lect(), 1);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT assert_eq('un rechazo de validacion (monto 0) no lee el reloj', concat_ws('|', tests.captura('SELECT public.abonar_credito(tests.u(15), ' || quote_literal((SELECT k FROM t_c)) || ', 0)'), pg_temp.lect()), 'Monto inválido|0'::text);
ROLLBACK;
SELECT assert_eq('tras el ROLLBACK _ahora_real() es otra vez el reloj de pared', (SELECT pg_get_functiondef(oid) LIKE '%SELECT clock_timestamp()%' FROM pg_proc WHERE oid = 'public._ahora_real()'::regprocedure), true);
