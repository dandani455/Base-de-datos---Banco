-- 62_cobro_automatico.test.sql · Etapa 9 · el cobro automatico CRONOLOGICO dentro de _avanzar_hasta (diseno v1.2 §7): fechas-evento (vencimientos con el cursor individual de cada
-- credito + cierres de CDT desde el MENOR cursor + hoy), cierre de CDT ANTES del cobro, ronda de las cuotas vencidas mas antiguas en CADA fecha, mora hasta la fecha real del
-- intento, saldo disponible a la fecha, escenarios R1 (a-h), R2 (a-f) del cursor cobro_hasta, idempotencia y el limite de 5 s con 360 cuotas.
-- No repite el motor de E7 ni el libro de E2. Una transaccion con ROLLBACK final; solo corre en banco_test/banco_mut (mueve el reloj).
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 30) n;
SELECT tests.cliente(99);                                                   -- sumidero: recibe lo que se "gasta" para dejar a los clientes sin saldo
UPDATE public.parametro SET tasa_mora_anual = 30;                           -- fixture de prueba (D7 provisional; el valor real lo decide el equipo)
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES
  (tests.p(901), 'Libre', '', 18, 1, 1000000000, 1, 360), (tests.p(902), 'Vehiculo', '', 18, 1, 1000000000, 1, 360),
  (tests.p(903), 'Educacion', '', 18, 1, 1000000000, 1, 360), (tests.p(904), 'Largo', '', 14, 1, 1000000000, 1, 360);
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES
  (tests.p(910), 'CDT 10', 10, 10, 1), (tests.p(915), 'CDT 15', 15, 10, 1), (tests.p(916), 'CDT 16', 16, 10, 1), (tests.p(920), 'CDT 20', 20, 10, 1);
CREATE TEMP TABLE t_b AS SELECT public.hoy_banco() AS d;
CREATE FUNCTION pg_temp.dia(p_n int) RETURNS date LANGUAGE sql STABLE AS $f$ SELECT (SELECT d FROM t_b) + p_n $f$;
CREATE FUNCTION pg_temp.ts(p_n int) RETURNS timestamptz LANGUAGE sql STABLE AS $f$ SELECT (pg_temp.dia(p_n)::timestamp AT TIME ZONE 'America/Bogota') $f$;
CREATE FUNCTION pg_temp.ir(p_n int) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(false, pg_temp.dia(p_n)::text); END $f$;
CREATE FUNCTION pg_temp.real() RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(true, ''); END $f$;
CREATE FUNCTION pg_temp.cs(p_u int) RETURNS numeric LANGUAGE sql VOLATILE AS $f$ SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(p_u) $f$;
CREATE FUNCTION pg_temp.cre(p_u int, p_prod int, p_monto numeric, p_plazo int) RETURNS uuid LANGUAGE sql AS $f$
  SELECT (public.solicitar_credito(tests.u(p_u), tests.p(p_prod)::text, p_monto, p_plazo) ->> 'id')::uuid $f$;
CREATE FUNCTION pg_temp.venc(p_k uuid, p_num int, p_dia int) RETURNS void LANGUAGE sql AS $f$ UPDATE public.cuota SET fecha_vencimiento = pg_temp.dia(p_dia) WHERE credito_id = p_k AND numero = p_num $f$;
CREATE FUNCTION pg_temp.vaciar(p_u int, p_deja numeric DEFAULT 100) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN PERFORM public.hacer_transferencia(tests.u(p_u), '4000000099', pg_temp.cs(p_u) - p_deja, 'gasto', NULL); END $f$;
CREATE FUNCTION pg_temp.cdt(p_u int, p_def int, p_monto numeric) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public.crear_cdt(tests.u(p_u), tests.p(p_def)::text, p_monto); END $f$;
CREATE FUNCTION pg_temp.auto(p_u int, p_k uuid, p_on boolean) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public.activar_descuento_automatico(tests.u(p_u), p_k::text, p_on); END $f$;
CREATE FUNCTION pg_temp.lee(p_u int) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public.vista_creditos(tests.u(p_u)); END $f$;
CREATE FUNCTION pg_temp.cur(p_k uuid) RETURNS text LANGUAGE sql VOLATILE AS $f$ SELECT coalesce((cobro_hasta - (SELECT d FROM t_b))::text, 'NULL') FROM public.credito WHERE id = p_k $f$;
-- cuotas pagadas: 'numero:dia-de-pago' (dias desde la base), en orden
CREATE FUNCTION pg_temp.pag(p_k uuid) RETURNS text LANGUAGE sql VOLATILE AS $f$
  SELECT coalesce(string_agg(numero || ':' || (fecha_pago - (SELECT d FROM t_b)), ',' ORDER BY numero) FILTER (WHERE pagada), '-') FROM public.cuota WHERE credito_id = p_k $f$;
-- fechas (dias desde la base) y montos de los asientos de un tipo (patas de CUENTA), en orden de insercion
CREATE FUNCTION pg_temp.fch(p_k uuid, p_tipo text) RETURNS text LANGUAGE sql VOLATILE AS $f$
  SELECT coalesce(string_agg((((fecha AT TIME ZONE 'America/Bogota')::date) - (SELECT d FROM t_b))::text, ',' ORDER BY orden), '-') FROM public.transaccion WHERE credito_id = p_k AND tipo::text = p_tipo AND contenedor = 'CUENTA' $f$;
CREATE FUNCTION pg_temp.mto(p_k uuid, p_tipo text) RETURNS text LANGUAGE sql VOLATILE AS $f$
  SELECT coalesce(string_agg(monto::text, ',' ORDER BY orden), '-') FROM public.transaccion WHERE credito_id = p_k AND tipo::text = p_tipo AND contenedor = 'CUENTA' $f$;
CREATE FUNCTION pg_temp.mora(p_valor numeric, p_dias int) RETURNS numeric LANGUAGE sql IMMUTABLE AS $f$ SELECT round(p_valor * 0.30 / 365 * p_dias, 2) $f$;   -- referencia independiente de la formula provisional
CREATE FUNCTION pg_temp.npatas(p_u int) RETURNS bigint LANGUAGE sql VOLATILE AS $f$ SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(p_u) $f$;
CREATE FUNCTION pg_temp.ord(p_u int, p_tipo text) RETURNS bigint LANGUAGE sql VOLATILE AS $f$ SELECT min(orden) FROM public.transaccion WHERE cuenta_id = tests.c(p_u) AND tipo::text = p_tipo $f$;
-- (la cuota estandar de 10M a 12 meses al 18 % E.A. es 910.463,77: E8)

-- ============================================================================
-- R1(a). La cuota vence el dia 15 sin saldo; un CDT vence el dia 20; hoy = dia 30 -> se cobra CON FECHA 20, DESPUES del cierre, con mora de 5 dias
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_a AS SELECT pg_temp.cre(1, 901, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_a), 1, 15);
SELECT pg_temp.cdt(1, 920, 5000000);
SELECT pg_temp.vaciar(1);
SELECT pg_temp.auto(1, (SELECT k FROM t_a), true);
SELECT assert_eq('estado previo: descuento activo con el cursor en hoy (dia 0)', concat_ws('|', pg_temp.cur((SELECT k FROM t_a)), (SELECT descuento_automatico FROM public.credito WHERE id = (SELECT k FROM t_a))), '0|t'::text);
SELECT pg_temp.ir(30);
SELECT pg_temp.lee(1);
SELECT assert_eq('R1(a) la cuota del dia 15 se paga con fecha del dia 20 (cuando el CDT acredito), NO el 30 ni el 15',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_a)), pg_temp.fch((SELECT k FROM t_a), 'CREDITO_CUOTA')), '1:20|20'::text);
SELECT assert_eq('R1(a) mora de 5 dias (hasta la fecha del intento), no de 15', pg_temp.mto((SELECT k FROM t_a), 'CREDITO_MORA'), pg_temp.mora(910463.77, 5)::text);
SELECT assert_eq('R1(a) el CDT_VENCIMIENTO (fecha 20) va ANTES que la CREDITO_CUOTA por orden: primero se cierran los CDT y despues se cobra; la mora despues de la cuota',
                 concat_ws('|', pg_temp.ord(1, 'CDT_VENCIMIENTO') < pg_temp.ord(1, 'CREDITO_CUOTA'), pg_temp.ord(1, 'CREDITO_CUOTA') < pg_temp.ord(1, 'CREDITO_MORA')), 't|t'::text);
SELECT assert_eq('R1(a) el cursor avanza a hoy (dia 30) y las otras 11 cuotas siguen impagas',
                 concat_ws('|', pg_temp.cur((SELECT k FROM t_a)), (SELECT count(*) FROM public.cuota WHERE credito_id = (SELECT k FROM t_a) AND NOT pagada)), '30|11'::text);
CREATE TEMP TABLE t_n1 AS SELECT pg_temp.npatas(1) AS n;
SELECT pg_temp.lee(1); SELECT pg_temp.lee(1);
SELECT assert_eq('R1(g) una segunda y tercera consulta NO escriben nada (idempotente: 0 patas nuevas, mismo cursor)', concat_ws('|', pg_temp.npatas(1) - (SELECT n FROM t_n1), pg_temp.cur((SELECT k FROM t_a))), '0|30'::text);
SELECT assert_eq('R1(a) v_integridad_global (con planes) en orden', (SELECT ok FROM public.v_integridad_global), true);

-- ============================================================================
-- R1(b) y (c). El CDT vence ANTES del vencimiento (dia 10 < 15) y el MISMO dia (15)
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_b2 AS SELECT pg_temp.cre(2, 901, 10000000, 12) AS k;
CREATE TEMP TABLE t_c2 AS SELECT pg_temp.cre(3, 901, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_b2), 1, 15); SELECT pg_temp.venc((SELECT k FROM t_c2), 1, 15);
SELECT pg_temp.cdt(2, 910, 5000000); SELECT pg_temp.cdt(3, 915, 5000000);
SELECT pg_temp.vaciar(2); SELECT pg_temp.vaciar(3);
SELECT pg_temp.auto(2, (SELECT k FROM t_b2), true); SELECT pg_temp.auto(3, (SELECT k FROM t_c2), true);
SELECT pg_temp.ir(30);
SELECT pg_temp.lee(2); SELECT pg_temp.lee(3);
SELECT assert_eq('R1(b) CDT del dia 10 (antes del vencimiento): la cuota se paga el dia 15 con mora 0 (sin grupo de mora)', concat_ws('|', pg_temp.pag((SELECT k FROM t_b2)), pg_temp.mto((SELECT k FROM t_b2), 'CREDITO_MORA')), '1:15|-'::text);
SELECT assert_eq('R1(c) CDT que vence el MISMO dia 15: cierre primero (orden menor), cobro despues, ambos fechados el 15 y sin mora',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_c2)), pg_temp.ord(3, 'CDT_VENCIMIENTO') < pg_temp.ord(3, 'CREDITO_CUOTA'), pg_temp.mto((SELECT k FROM t_c2), 'CREDITO_MORA'),
                    (SELECT ((fecha AT TIME ZONE 'America/Bogota')::date - (SELECT d FROM t_b)) FROM public.transaccion WHERE cuenta_id = tests.c(3) AND tipo = 'CDT_VENCIMIENTO' AND contenedor = 'CUENTA')),
                 '1:15|t|-|15'::text);

-- ============================================================================
-- R1(d). Dos cuotas vencidas del mismo credito: con fondos para UNA paga la mas antigua; con fondos para ambas, las dos en orden
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_d1 AS SELECT pg_temp.cre(4, 901, 10000000, 12) AS k;
CREATE TEMP TABLE t_d2 AS SELECT pg_temp.cre(5, 901, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_d1), 1, 12); SELECT pg_temp.venc((SELECT k FROM t_d1), 2, 14);
SELECT pg_temp.venc((SELECT k FROM t_d2), 1, 12); SELECT pg_temp.venc((SELECT k FROM t_d2), 2, 14);
SELECT pg_temp.cdt(4, 916, 1000000); SELECT pg_temp.cdt(5, 916, 2000000);
SELECT pg_temp.vaciar(4); SELECT pg_temp.vaciar(5);
SELECT pg_temp.auto(4, (SELECT k FROM t_d1), true); SELECT pg_temp.auto(5, (SELECT k FROM t_d2), true);
SELECT pg_temp.ir(30);
SELECT pg_temp.lee(4); SELECT pg_temp.lee(5);
SELECT assert_eq('R1(d) fondos para UNA cuota (CDT de 1.000.000 el dia 16): paga la MAS ANTIGUA (1) con mora de 4 dias; la 2 sigue impaga',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_d1)), pg_temp.mto((SELECT k FROM t_d1), 'CREDITO_MORA')), ('1:16|' || pg_temp.mora(910463.77, 4))::text);
SELECT assert_eq('R1(d) fondos para AMBAS (CDT de 2.000.000): las dos el dia 16, en orden, con mora de 4 y 2 dias',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_d2)), pg_temp.mto((SELECT k FROM t_d2), 'CREDITO_MORA')), ('1:16,2:16|' || pg_temp.mora(910463.77, 4) || ',' || pg_temp.mora(910463.77, 2))::text);

-- ============================================================================
-- R1(e). Dos creditos: el inalcanzable (el mas antiguo) NO bloquea al otro, que si alcanza
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_e1 AS SELECT pg_temp.cre(6, 901, 10000000, 12) AS k;          -- cuota ~910.463 (inalcanzable)
CREATE TEMP TABLE t_e2 AS SELECT pg_temp.cre(6, 902, 1000000, 12) AS k;           -- cuota ~91.046 (alcanzable)
SELECT pg_temp.venc((SELECT k FROM t_e1), 1, 12); SELECT pg_temp.venc((SELECT k FROM t_e2), 1, 14);
SELECT pg_temp.vaciar(6, 200000);
SELECT pg_temp.auto(6, (SELECT k FROM t_e1), true); SELECT pg_temp.auto(6, (SELECT k FROM t_e2), true);
SELECT pg_temp.ir(30);
SELECT pg_temp.lee(6);
SELECT assert_eq('R1(e) el credito de la cuota mas antigua (inalcanzable con 200.000) NO bloquea al otro: el pequeno se paga el dia 14 y el grande sigue impago',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_e1)), pg_temp.pag((SELECT k FROM t_e2))), '-|1:14'::text);

-- ============================================================================
-- R1(f). El dinero llega por una operacion de OTRA cuenta (no del motor) el dia 20: el cobro se fecha HOY (30) y la mora llega hasta hoy
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_f AS SELECT pg_temp.cre(7, 901, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_f), 1, 15);
SELECT pg_temp.vaciar(7);
SELECT pg_temp.auto(7, (SELECT k FROM t_f), true);
SELECT tests.fondear(tests.c(99), 3000000);
SELECT pg_temp.ir(20);
SELECT public.hacer_transferencia(tests.u(99), (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(7)), 2000000, 'llega', NULL);   -- ingreso de OTRO usuario el dia 20
SELECT pg_temp.ir(30);
SELECT pg_temp.lee(7);
SELECT assert_eq('R1(f) un ingreso por operacion de otra cuenta (dia 20) NO paga una cuota del dia 15 con fecha 15: se cobra HOY (dia 30) con mora de 15 dias',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_f)), pg_temp.mto((SELECT k FROM t_f), 'CREDITO_MORA')), ('1:30|' || pg_temp.mora(910463.77, 15))::text);

-- ============================================================================
-- R1(i). El MISMO dia del cierre del CDT (dia 20) llega, despues de las 00:00, una transferencia externa de 1.000.000: la ronda HISTORICA del dia 20 NO la ve
--        (solo cuenta el CDT, cuyo cierre lleva el instante del evento: dia 20 00:00); la cuota del dia 15 (910.463,77) sigue impaga ese dia y se cobra en la ronda de HOY (dia 30)
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_i AS SELECT pg_temp.cre(25, 901, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_i), 1, 15);
SELECT pg_temp.cdt(25, 920, 500000);                                                              -- CDT de 500.000 que vence el dia 20 (no alcanza para la cuota)
SELECT pg_temp.vaciar(25);
SELECT pg_temp.auto(25, (SELECT k FROM t_i), true);
SELECT tests.fondear(tests.c(99), 3000000);
SELECT pg_temp.ir(20);
SELECT public.hacer_transferencia(tests.u(99), (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(25)), 1000000, 'llega el dia 20', NULL);   -- ingreso EXTERNO del dia 20, con la hora real (> 00:00)
SELECT assert_eq('R1(i) estado previo: la transferencia externa lleva fecha del dia 20 POSTERIOR a las 00:00 (despues del instante del cierre del CDT)',
                 (SELECT (t.fecha > pg_temp.ts(20) AND (t.fecha AT TIME ZONE 'America/Bogota')::date = pg_temp.dia(20))::text FROM public.transaccion t WHERE t.cuenta_id = tests.c(25) AND t.tipo = 'RECIBO' AND t.contenedor = 'CUENTA'), 'true'::text);
SELECT pg_temp.ir(30);
SELECT pg_temp.lee(25);
SELECT assert_eq('R1(i) la cuota del dia 15 NO se paga en la ronda historica del dia 20 (CDT de 500.000 no alcanza y la transferencia del mismo dia aun no existia): se cobra HOY (dia 30) con mora de 15 dias',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_i)), pg_temp.fch((SELECT k FROM t_i), 'CREDITO_CUOTA'), pg_temp.mto((SELECT k FROM t_i), 'CREDITO_MORA')), ('1:30|30|' || pg_temp.mora(910463.77, 15))::text);
SELECT assert_eq('R1(i) el CDT cerro el dia 20 con su propio instante (cuenta el cierre) y ninguna pata de cuota ni de mora lleva fecha <= dia 20',
                 concat_ws('|', (SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(25) AND tipo = 'CDT_VENCIMIENTO' AND contenedor = 'CUENTA'),
                           (SELECT count(*) FROM public.transaccion WHERE credito_id = (SELECT k FROM t_i) AND tipo IN ('CREDITO_CUOTA', 'CREDITO_MORA') AND fecha <= pg_temp.ts(21))), '1|0'::text);

-- ============================================================================
-- R1(h). DOS creditos con cursores 10 y 20 y un CDT que vence el dia 15 (camino real por la API); lectura unica el dia 30
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_ha AS SELECT pg_temp.cre(8, 901, 10000000, 12) AS k;           -- A
CREATE TEMP TABLE t_hb AS SELECT pg_temp.cre(8, 902, 10000000, 12) AS k;           -- B
SELECT pg_temp.venc((SELECT k FROM t_ha), 1, 12);                                  -- A: cuota vencida el dia 12
SELECT pg_temp.venc((SELECT k FROM t_hb), 1, 18); SELECT pg_temp.venc((SELECT k FROM t_hb), 2, 25);   -- B: cuotas vencidas los dias 18 y 25
SELECT pg_temp.ir(20);
SELECT pg_temp.auto(8, (SELECT k FROM t_hb), true);                                -- B: cursor = dia 20 (a esa fecha aun no hay CDT)
SELECT pg_temp.real();                                                             -- se vuelve a modo real (dia 0)
SELECT pg_temp.cdt(8, 915, 5000000);                                               -- CDT que vence el dia 15
SELECT pg_temp.vaciar(8);                                                          -- la cuenta queda sin saldo hasta que el CDT cierre
SELECT pg_temp.ir(10);
SELECT pg_temp.auto(8, (SELECT k FROM t_ha), true);                                -- A: cursor = dia 10 (B, con cursor 20 > 10, esta en pausa)
SELECT assert_eq('R1(h) estado previo: cursores A = dia 10 y B = dia 20; el CDT sigue ACTIVO; nada pagado',
                 concat_ws('|', pg_temp.cur((SELECT k FROM t_ha)), pg_temp.cur((SELECT k FROM t_hb)), (SELECT estado::text FROM public.cdt WHERE cuenta_id = tests.c(8)),
                           pg_temp.pag((SELECT k FROM t_ha)), pg_temp.pag((SELECT k FROM t_hb))), '10|20|ACTIVO|-|-'::text);
SELECT pg_temp.ir(30);
SELECT pg_temp.lee(8);
SELECT assert_eq('R1(h) A: su cuota del dia 12 se paga con fecha 15 (cuando cierra el CDT, ventana del MENOR cursor) y mora de 3 dias',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_ha)), pg_temp.fch((SELECT k FROM t_ha), 'CREDITO_CUOTA'), pg_temp.mto((SELECT k FROM t_ha), 'CREDITO_MORA')), ('1:15|15|' || pg_temp.mora(910463.77, 3))::text);
SELECT assert_eq('R1(h) B: sus cuotas del 18 y del 25 se pagan con fecha 25 (nada con fecha <= 20: no es retroactivo), la mas antigua primero, mora de 7 y 0 dias',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_hb)), pg_temp.fch((SELECT k FROM t_hb), 'CREDITO_CUOTA'), pg_temp.mto((SELECT k FROM t_hb), 'CREDITO_MORA')), ('1:25,2:25|25,25|' || pg_temp.mora(910463.77, 7))::text);
SELECT assert_eq('R1(h) orden por insercion: cierre del CDT -> cuota de A -> cuotas de B',
                 (SELECT array_agg(x ORDER BY o) FROM (SELECT min(orden) AS o, CASE WHEN tipo = 'CDT_VENCIMIENTO' THEN 'cdt' WHEN credito_id = (SELECT k FROM t_ha) THEN 'A' ELSE 'B' END AS x
                    FROM public.transaccion WHERE cuenta_id = tests.c(8) AND tipo IN ('CDT_VENCIMIENTO', 'CREDITO_CUOTA') AND contenedor = 'CUENTA' GROUP BY 2) q),
                 ARRAY['cdt', 'A', 'B']);
SELECT assert_eq('R1(h) ambos cursores quedan en el dia 30', concat_ws('|', pg_temp.cur((SELECT k FROM t_ha)), pg_temp.cur((SELECT k FROM t_hb))), '30|30'::text);
CREATE TEMP TABLE t_n8 AS SELECT pg_temp.npatas(8) AS n;
SELECT pg_temp.lee(8);
SELECT assert_eq('R1(h) la segunda lectura no escribe nada', pg_temp.npatas(8) - (SELECT n FROM t_n8), 0::bigint);

-- ============================================================================
-- R2. El cursor cobro_hasta: activar, desactivar, reactivar, guardia y reloj de vuelta a real
-- ============================================================================
-- (a) activar con una cuota YA vencida: sin cobro retroactivo
SELECT pg_temp.real();
CREATE TEMP TABLE t_r2a AS SELECT pg_temp.cre(9, 901, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_r2a), 1, 5);
SELECT pg_temp.ir(10);
SELECT pg_temp.auto(9, (SELECT k FROM t_r2a), true);                               -- hay saldo (el desembolso) y la cuota 1 vencio el dia 5
SELECT assert_eq('R2(a) activar NO cobra nada por si mismo y deja el cursor en el dia 10', concat_ws('|', pg_temp.pag((SELECT k FROM t_r2a)), pg_temp.cur((SELECT k FROM t_r2a))), '-|10'::text);
SELECT pg_temp.lee(9);
SELECT assert_eq('R2(a) la primera ronda con fecha >= activacion la cobra el dia 10 (no el 5) con mora de 5 dias; ningun asiento anterior al dia 10',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_r2a)), pg_temp.mto((SELECT k FROM t_r2a), 'CREDITO_MORA'),
                           (SELECT count(*) FROM public.transaccion WHERE credito_id = (SELECT k FROM t_r2a) AND tipo IN ('CREDITO_CUOTA', 'CREDITO_MORA') AND fecha < pg_temp.ts(10))),
                 ('1:10|' || pg_temp.mora(910463.77, 5) || '|0')::text);
-- (b) desactivar y reactivar: lo que paso apagado no se cobra con fecha pasada
SELECT pg_temp.real();
CREATE TEMP TABLE t_r2b AS SELECT pg_temp.cre(10, 901, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_r2b), 1, 8); SELECT pg_temp.venc((SELECT k FROM t_r2b), 2, 20);
SELECT pg_temp.vaciar(10);
SELECT pg_temp.auto(10, (SELECT k FROM t_r2b), true);
SELECT pg_temp.ir(10); SELECT pg_temp.lee(10);
SELECT assert_eq('R2(b) con el descuento activo y sin saldo, la cuota 1 (dia 8) queda impaga y el cursor llega al 10', concat_ws('|', pg_temp.pag((SELECT k FROM t_r2b)), pg_temp.cur((SELECT k FROM t_r2b))), '-|10'::text);
SELECT pg_temp.auto(10, (SELECT k FROM t_r2b), false);
SELECT assert_eq('R2(b) desactivar: cursor NULL y descuento apagado (fecha -> NULL permitido)', concat_ws('|', pg_temp.cur((SELECT k FROM t_r2b)), (SELECT descuento_automatico FROM public.credito WHERE id = (SELECT k FROM t_r2b))), 'NULL|f'::text);
SELECT pg_temp.ir(12);
SELECT public.hacer_transferencia(tests.u(99), (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(10)), 3000000, 'llega', NULL);
SELECT pg_temp.ir(25); SELECT pg_temp.lee(10);
SELECT assert_eq('R2(b) apagado y con saldo, el dia 25 NO se cobra nada (ni la cuota 1 ni la 2 que vencio el 20)', pg_temp.pag((SELECT k FROM t_r2b)), '-'::text);
SELECT pg_temp.auto(10, (SELECT k FROM t_r2b), true);
SELECT assert_eq('R2(b) reactivar: cursor = hoy (dia 25), NULL -> fecha permitido', pg_temp.cur((SELECT k FROM t_r2b)), '25'::text);
SELECT pg_temp.lee(10);
SELECT assert_eq('R2(b) las dos cuotas vencidas mientras estuvo apagado se cobran el dia 25 (no con fecha 8 ni 20): mora de 17 y 5 dias',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_r2b)), pg_temp.mto((SELECT k FROM t_r2b), 'CREDITO_MORA')), ('1:25,2:25|' || pg_temp.mora(910463.77, 17) || ',' || pg_temp.mora(910463.77, 5))::text);
-- (c) la guardia
SELECT pg_temp.real();
CREATE TEMP TABLE t_r2c AS SELECT pg_temp.cre(11, 901, 10000000, 12) AS k;
SELECT pg_temp.auto(11, (SELECT k FROM t_r2c), true);
SELECT pg_temp.ir(10); SELECT pg_temp.lee(11);
SELECT assert_eq('R2(c) la guardia rechaza un UPDATE directo hacia atras (fecha -> fecha anterior)',
                 tests.captura('UPDATE public.credito SET cobro_hasta = cobro_hasta - 1 WHERE id = ' || quote_literal((SELECT k FROM t_r2c))), 'Libro mayor: cobro_hasta solo puede avanzar (desactivar y reactivar el descuento lo reinicia)'::text);
SELECT assert_eq('R2(c) un UPDATE al mismo valor o hacia adelante se permite',
                 concat_ws('|', tests.captura('UPDATE public.credito SET cobro_hasta = cobro_hasta WHERE id = ' || quote_literal((SELECT k FROM t_r2c))),
                                tests.captura('UPDATE public.credito SET cobro_hasta = cobro_hasta + 5 WHERE id = ' || quote_literal((SELECT k FROM t_r2c))), 'ok'), 'ok'::text);
SELECT assert_eq('R2(c) fecha -> NULL y NULL -> fecha (con descuento coherente) se permiten, y el CHECK exige descuento_automatico = (cobro_hasta IS NOT NULL)',
                 concat_ws('|', tests.captura('UPDATE public.credito SET descuento_automatico = false, cobro_hasta = NULL WHERE id = ' || quote_literal((SELECT k FROM t_r2c))),
                                tests.captura('UPDATE public.credito SET descuento_automatico = true, cobro_hasta = ' || quote_literal(pg_temp.dia(0)) || ' WHERE id = ' || quote_literal((SELECT k FROM t_r2c))),
                                (tests.captura('UPDATE public.credito SET cobro_hasta = NULL WHERE id = ' || quote_literal((SELECT k FROM t_r2c))) LIKE '%ck_credito_cobro_hasta%')), 't'::text);
-- (d) reloj manual hacia adelante y vuelta a REAL: el motor se pausa sin fallar; las operaciones manuales siguen; al pasar el cursor se retoma sin duplicar
SELECT pg_temp.real();
CREATE TEMP TABLE t_r2d AS SELECT pg_temp.cre(12, 901, 10000000, 12) AS k;
CREATE TEMP TABLE t_r2d2 AS SELECT pg_temp.cre(13, 901, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_r2d), 1, 8); SELECT pg_temp.venc((SELECT k FROM t_r2d2), 1, 8); SELECT pg_temp.venc((SELECT k FROM t_r2d2), 2, 30);
SELECT pg_temp.vaciar(12); SELECT pg_temp.vaciar(13);
SELECT pg_temp.auto(12, (SELECT k FROM t_r2d), true); SELECT pg_temp.auto(13, (SELECT k FROM t_r2d2), true);
SELECT pg_temp.ir(10); SELECT pg_temp.lee(12); SELECT pg_temp.lee(13);
SELECT pg_temp.real();                                                                -- se simulo hasta el dia 10 y se vuelve a modo REAL: hoy (dia 0) < cursor (10)
SELECT tests.fondear(tests.c(12), 3000000); SELECT tests.fondear(tests.c(13), 3000000);
CREATE TEMP TABLE t_n12 AS SELECT pg_temp.npatas(12) AS n;
SELECT pg_temp.lee(12); SELECT pg_temp.lee(12);
SELECT assert_eq('R2(d) con hoy < cursor el motor NO falla, NO cobra (aunque ya hay saldo), NO escribe y NO toca el cursor',
                 concat_ws('|', pg_temp.npatas(12) - (SELECT n FROM t_n12), pg_temp.pag((SELECT k FROM t_r2d)), pg_temp.cur((SELECT k FROM t_r2d))), '0|-|10'::text);
CREATE TEMP TABLE t_pm AS SELECT public.pagar_cuota(tests.u(12), (SELECT k FROM t_r2d)::text, 1) AS r;
SELECT pg_temp.auto(12, (SELECT k FROM t_r2d), false);
SELECT assert_eq('R2(d) en la pausa, pagar_cuota manual SI funciona (fecha de hoy real, por adelantado) y desactivar el descuento tambien',
                 concat_ws('|', (SELECT r ->> 'numero' FROM t_pm), pg_temp.pag((SELECT k FROM t_r2d)), pg_temp.cur((SELECT k FROM t_r2d))), '1|1:0|NULL'::text);
SELECT assert_eq('R2(d) abonar_credito manual tambien funciona con el reloj por detras del cursor', ((public.abonar_credito(tests.u(13), (SELECT k FROM t_r2d2)::text, 500000) ->> 'capital')::numeric > 0)::text, 'true'::text);
SELECT pg_temp.ir(40);
SELECT pg_temp.lee(13);
SELECT assert_eq('R2(d) al avanzar el reloj mas alla del cursor se RETOMA: la cuota 1 (dia 8, impaga) y la 2 (dia 30) se cobran el dia 30, y el cursor llega al 40',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_r2d2)), pg_temp.cur((SELECT k FROM t_r2d2))), '1:30,2:30|40'::text);
CREATE TEMP TABLE t_n13 AS SELECT pg_temp.npatas(13) AS n;
SELECT pg_temp.lee(13); SELECT pg_temp.lee(13);
SELECT assert_eq('R2(d) ...y sin duplicar: otras lecturas no escriben y hay exactamente 1 grupo CREDITO_CUOTA por cuota pagada',
                 concat_ws('|', pg_temp.npatas(13) - (SELECT n FROM t_n13), (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE credito_id = (SELECT k FROM t_r2d2) AND tipo = 'CREDITO_CUOTA')), '0|2'::text);
-- (e) reactivar tras volver a real: permitido (cursor = hoy real, menor que el anterior) y sin cobros con fecha futura
SELECT pg_temp.real();
CREATE TEMP TABLE t_r2e AS SELECT pg_temp.cre(14, 901, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_r2e), 1, 3);
SELECT pg_temp.auto(14, (SELECT k FROM t_r2e), true);
SELECT pg_temp.ir(10); SELECT pg_temp.lee(14);
SELECT assert_eq('R2(e) simulado hasta el dia 10 el cursor esta en 10 y la cuota del dia 3 ya se cobro', concat_ws('|', pg_temp.cur((SELECT k FROM t_r2e)), pg_temp.pag((SELECT k FROM t_r2e))), '10|1:3'::text);
SELECT pg_temp.real();
SELECT pg_temp.auto(14, (SELECT k FROM t_r2e), false); SELECT pg_temp.auto(14, (SELECT k FROM t_r2e), true);
SELECT assert_eq('R2(e) volver a real, desactivar y reactivar: el cursor queda en el dia 0 (MENOR que el anterior: NULL -> fecha lo permite)', pg_temp.cur((SELECT k FROM t_r2e)), '0'::text);
SELECT pg_temp.venc((SELECT k FROM t_r2e), 2, 4);
SELECT pg_temp.ir(5); SELECT pg_temp.lee(14);
SELECT assert_eq('R2(e) con el reloj en el dia 5 se cobra la cuota 2 (vencida el 4) SIN fechas futuras: ningun asiento de credito posterior al dia 5',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_r2e)), (SELECT count(*) FROM public.transaccion WHERE credito_id = (SELECT k FROM t_r2e) AND fecha >= pg_temp.ts(6))), '1:3,2:4|0'::text);
-- (f) activar con el descuento ya activo no mueve el cursor
SELECT pg_temp.real();
CREATE TEMP TABLE t_r2f AS SELECT pg_temp.cre(15, 901, 10000000, 12) AS k;
SELECT pg_temp.auto(15, (SELECT k FROM t_r2f), true);
SELECT pg_temp.ir(10); SELECT pg_temp.lee(15);
SELECT pg_temp.auto(15, (SELECT k FROM t_r2f), true);
SELECT assert_eq('R2(f) activar(true) con el descuento ya activo es un no-op: el cursor no se mueve (10)', pg_temp.cur((SELECT k FROM t_r2f)), '10'::text);
SELECT pg_temp.real();
SELECT pg_temp.auto(15, (SELECT k FROM t_r2f), true);
SELECT assert_eq('R2(f) ...tampoco con el reloj por detras del cursor (no lo baja ni lo sube)', pg_temp.cur((SELECT k FROM t_r2f)), '10'::text);

-- ============================================================================
-- 360 cuotas y 30 años: el cobro automatico completo cabe en 5 s (contrato §8) y cada cuota se paga en su fecha
-- ============================================================================
SELECT pg_temp.real();
SELECT tests.fondear(tests.c(16), 600000000);
CREATE TEMP TABLE t_l AS SELECT pg_temp.cre(16, 904, 100000000, 360) AS k;
SELECT pg_temp.auto(16, (SELECT k FROM t_l), true);
SELECT pg_temp.ir(11000);
CREATE TEMP TABLE t_t AS SELECT clock_timestamp() AS t0;
SELECT pg_temp.lee(16);
SELECT assert_eq('360 cuotas y un salto de 30 años: se cobran las 360, el credito queda PAGADO y tarda menos de 5 s',
                 concat_ws('|', (SELECT count(*) FROM public.cuota WHERE credito_id = (SELECT k FROM t_l) AND pagada), (SELECT estado::text FROM public.credito WHERE id = (SELECT k FROM t_l)),
                           clock_timestamp() - (SELECT t0 FROM t_t) < interval '5 seconds'), '360|PAGADO|t'::text);
SELECT assert_eq('...cada cuota se pago en su fecha de vencimiento (siempre hubo saldo) y sin mora',
                 concat_ws('|', (SELECT count(*) FROM public.cuota WHERE credito_id = (SELECT k FROM t_l) AND fecha_pago <> fecha_vencimiento),
                           (SELECT count(*) FROM public.transaccion WHERE credito_id = (SELECT k FROM t_l) AND tipo = 'CREDITO_MORA')), '0|0'::text);
SELECT assert_eq('...y el capital pendiente es 0 y la integridad (libro, planes y cursores) sigue en orden',
                 concat_ws('|', (SELECT capital_pendiente::numeric FROM public.credito WHERE id = (SELECT k FROM t_l)), (SELECT ok FROM public.v_integridad_global)), '0.00|t'::text);
ROLLBACK;
