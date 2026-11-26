-- 64_pagos_huecos.test.sql · Etapa 9 · huecos de las pruebas 60-63 que las MUTACIONES de E9 dejaron al descubierto (M224, M228, M238, M245, M250, M251, M253, M255, M257, M259, M260, M279):
--   H1  abono en el PRIMER periodo (cuota 1 impaga): el primer periodo corto, el recalculo y el ancla contra una referencia float8 independiente   (M228)
--   H2  la mora tras un abono se calcula sobre el valor VIGENTE de la cuota, no sobre el original                                                    (M224)
--   H3  un credito PAGADO no se opera: pagar, abonar y activar el descuento = Recurso no encontrado y el cursor no se toca                            (M238)
--   H4  el ancla fecha_interes NO retrocede al pagar una cuota (propiedad defensiva de la regla R)                                                    (M245)
--   H5  un segundo abono con el reloj POR DETRAS del ancla (se volvio a modo real) no la mueve hacia atras                                            (M279)
--   H6  la ronda de cobro: la cuota mas antigua gana aunque su credito tenga el id MAYOR (a) y, en un empate de vencimiento, el desembolso mas antiguo (b)   (M250, M251)
--   H7  el saldo exacto alcanza para cuota + mora (todo o nada): la mora llega hasta la fecha del intento (a) y el faltante de 0,01 NO cobra ni falla (b)   (M259, M253)
--   H8  la ventana de un credito es (cursor, hoy]: con otro credito generando el evento del dia 20, el credito con cursor 20 no cobra con fecha 20     (M255)
--   H9  las fechas-evento de un credito usan SU cursor: los vencimientos de otro credito (anteriores a su cursor) no crean rondas extra                (M257)
--   H10 con el reloj por detras del cursor el motor se pausa AUNQUE haya una cuota vencida y saldo (no solo cuando la cuota aun no vence)             (M260)
-- Una transaccion con ROLLBACK final; solo corre en banco_test/banco_mut (mueve el reloj). H6b va al final (adelanta el reloj mientras busca un par de creditos con ids opuestos).
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 20) n;
SELECT count(tests.cliente(n)) FROM generate_series(41, 60) n;
SELECT tests.cliente(99);                                                   -- sumidero: recibe lo que se "gasta" y fuente de ingresos de OTRA cuenta
UPDATE public.parametro SET tasa_mora_anual = 30;                           -- fixture de prueba (D7 provisional)
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES
  (tests.p(901), 'Libre', '', 18, 1, 1000000000, 1, 360), (tests.p(902), 'Vehiculo', '', 18, 1, 1000000000, 1, 360);
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES (tests.p(915), 'CDT 15', 15, 10, 1), (tests.p(920), 'CDT 20', 20, 10, 1);
CREATE TEMP TABLE t_b AS SELECT public.hoy_banco() AS d;
CREATE FUNCTION pg_temp.dia(p_n int) RETURNS date LANGUAGE sql STABLE AS $f$ SELECT (SELECT d FROM t_b) + p_n $f$;
CREATE FUNCTION pg_temp.ir(p_n int) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(false, pg_temp.dia(p_n)::text); END $f$;
CREATE FUNCTION pg_temp.real() RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(true, ''); END $f$;
CREATE FUNCTION pg_temp.cs(p_u int) RETURNS numeric LANGUAGE sql VOLATILE AS $f$ SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(p_u) $f$;
CREATE FUNCTION pg_temp.cre(p_u int, p_prod int, p_monto numeric, p_plazo int) RETURNS uuid LANGUAGE sql AS $f$
  SELECT (public.solicitar_credito(tests.u(p_u), tests.p(p_prod)::text, p_monto, p_plazo) ->> 'id')::uuid $f$;
CREATE FUNCTION pg_temp.venc(p_k uuid, p_num int, p_dia int) RETURNS void LANGUAGE sql AS $f$ UPDATE public.cuota SET fecha_vencimiento = pg_temp.dia(p_dia) WHERE credito_id = p_k AND numero = p_num $f$;
CREATE FUNCTION pg_temp.fijar(p_k uuid) RETURNS void LANGUAGE sql AS $f$ UPDATE public.cuota SET fecha_vencimiento = pg_temp.dia(30 * numero) WHERE credito_id = p_k $f$;
CREATE FUNCTION pg_temp.vaciar(p_u int, p_deja numeric DEFAULT 100) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN PERFORM public.hacer_transferencia(tests.u(p_u), '4000000099', pg_temp.cs(p_u) - p_deja, 'gasto', NULL); END $f$;
CREATE FUNCTION pg_temp.cdt(p_u int, p_def int, p_monto numeric) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public.crear_cdt(tests.u(p_u), tests.p(p_def)::text, p_monto); END $f$;
CREATE FUNCTION pg_temp.auto(p_u int, p_k uuid, p_on boolean) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public.activar_descuento_automatico(tests.u(p_u), p_k::text, p_on); END $f$;
CREATE FUNCTION pg_temp.lee(p_u int) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public.vista_creditos(tests.u(p_u)); END $f$;
CREATE FUNCTION pg_temp.lee_ok(p_u int) RETURNS text LANGUAGE plpgsql AS $f$ BEGIN PERFORM public.vista_creditos(tests.u(p_u)); RETURN 'ok'; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $f$;
CREATE FUNCTION pg_temp.cur(p_k uuid) RETURNS text LANGUAGE sql VOLATILE AS $f$ SELECT coalesce((cobro_hasta - (SELECT d FROM t_b))::text, 'NULL') FROM public.credito WHERE id = p_k $f$;
CREATE FUNCTION pg_temp.pag(p_k uuid) RETURNS text LANGUAGE sql VOLATILE AS $f$
  SELECT coalesce(string_agg(numero || ':' || (fecha_pago - (SELECT d FROM t_b)), ',' ORDER BY numero) FILTER (WHERE pagada), '-') FROM public.cuota WHERE credito_id = p_k $f$;
CREATE FUNCTION pg_temp.mto(p_k uuid, p_tipo text) RETURNS text LANGUAGE sql VOLATILE AS $f$
  SELECT coalesce(string_agg(monto::text, ',' ORDER BY orden), '-') FROM public.transaccion WHERE credito_id = p_k AND tipo::text = p_tipo AND contenedor = 'CUENTA' $f$;
CREATE FUNCTION pg_temp.mora(p_valor numeric, p_dias int) RETURNS numeric LANGUAGE sql IMMUTABLE AS $f$ SELECT round(p_valor * 0.30 / 365 * p_dias, 2) $f$;   -- referencia independiente de la formula provisional
CREATE FUNCTION pg_temp.npatas(p_u int) RETURNS bigint LANGUAGE sql VOLATILE AS $f$ SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(p_u) $f$;
CREATE FUNCTION pg_temp.pc(p_u int, p_k uuid) RETURNS text LANGUAGE plpgsql AS $f$ BEGIN RETURN 'OK:' || (public.pagar_cuota(tests.u(p_u), p_k::text) ->> 'numero'); EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $f$;
CREATE FUNCTION pg_temp.ab(p_u int, p_k uuid, p_m numeric) RETURNS text LANGUAGE plpgsql AS $f$ BEGIN RETURN 'OK:' || (public.abonar_credito(tests.u(p_u), p_k::text, p_m) ->> 'capital'); EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $f$;
CREATE FUNCTION pg_temp.au(p_u int, p_k uuid) RETURNS text LANGUAGE plpgsql AS $f$ BEGIN RETURN 'OK:' || (public.activar_descuento_automatico(tests.u(p_u), p_k::text, true) ->> 'descuento_automatico'); EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $f$;
-- referencia independiente en float8 (exp/ln/power, nunca la funcion bajo prueba): i = 1,18^(1/12) - 1 ; C' = (K' + j0)·i·(1+i)^(m-1) / ((1+i)^m - 1)
CREATE FUNCTION pg_temp.imens() RETURNS float8 LANGUAGE sql IMMUTABLE AS $f$ SELECT power(1.18::float8, 1 / 12.0::float8) - 1 $f$;
CREATE FUNCTION pg_temp.ref_j0(p_k numeric, p_rem numeric) RETURNS numeric LANGUAGE sql IMMUTABLE AS $f$ SELECT round((p_k::float8 * pg_temp.imens() * p_rem::float8)::numeric, 2) $f$;
CREATE FUNCTION pg_temp.ref_cuota(p_k numeric, p_j0 numeric, p_m int) RETURNS numeric LANGUAGE sql IMMUTABLE AS $f$
  SELECT round((((p_k + p_j0)::float8) * pg_temp.imens() * power(1 + pg_temp.imens(), p_m - 1) / (power(1 + pg_temp.imens(), p_m) - 1))::numeric, 2) $f$;

-- ============================================================================
-- H1 (M228). Abono a mitad del PRIMER periodo (cuota 1 impaga, dia 15 de 30): I = 69.442,15; r = 930.557,85; K' = 9.069.442,15; rem = 0,5
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_h1 AS SELECT pg_temp.cre(1, 901, 10000000, 12) AS k;
SELECT pg_temp.fijar((SELECT k FROM t_h1));
SELECT pg_temp.ir(15);
CREATE TEMP TABLE t_h1r AS SELECT public.abonar_credito(tests.u(1), (SELECT k FROM t_h1)::text, 1000000) AS r;
SELECT assert_eq('H1 abono de 1.000.000 en el dia 15 del PRIMER periodo: mora 0, interes corriendo 69.442,15 (la mitad de 138.884,30), capital 930.557,85, saldo 9.069.442,15',
                 concat_ws('|', (SELECT r ->> 'mora' FROM t_h1r), (SELECT r ->> 'interes' FROM t_h1r), (SELECT r ->> 'capital' FROM t_h1r), (SELECT r ->> 'saldo' FROM t_h1r)), '0.00|69442.15|930557.85|9069442.15'::text);
SELECT assert_eq('H1 la cuota 1 queda con el interes del RESTO del periodo j0 = K''·i·0,5 (referencia float8, +-0,02) y NO con 0 (periodo inicial mal calculado)',
                 (SELECT abs(interes_programado - pg_temp.ref_j0(9069442.15, 0.5)) <= 0.02 AND interes_programado > 0 FROM public.cuota WHERE credito_id = (SELECT k FROM t_h1) AND numero = 1), true);
SELECT assert_eq('H1 la cuota nueva = (K'' + j0)·i·(1+i)^11 / ((1+i)^12 - 1) (referencia float8, +-0,02) y valor = capital + interes exactos',
                 (SELECT concat_ws('|', abs(valor_cuota - pg_temp.ref_cuota(9069442.15, pg_temp.ref_j0(9069442.15, 0.5), 12)) <= 0.02, valor_cuota = capital_programado + interes_programado)
                    FROM public.cuota WHERE credito_id = (SELECT k FROM t_h1) AND numero = 1), 't|t'::text);
SELECT assert_eq('H1 el ancla pasa al dia 15; las 12 cuotas siguen impagas con sus vencimientos (dia 30k) y la suma de su capital = capital_pendiente = 9.069.442,15',
                 (SELECT concat_ws('|', (c.fecha_interes - pg_temp.dia(0)), (SELECT count(*) FROM public.cuota q WHERE q.credito_id = c.id AND NOT q.pagada),
                                   (SELECT bool_and(q.fecha_vencimiento = pg_temp.dia(30 * q.numero)) FROM public.cuota q WHERE q.credito_id = c.id),
                                   (SELECT sum(q.capital_programado - q.capital_pagado) FROM public.cuota q WHERE q.credito_id = c.id AND NOT q.pagada), c.capital_pendiente)
                    FROM public.credito c WHERE c.id = (SELECT k FROM t_h1)), '15|12|t|9069442.15|9069442.15'::text);

-- ============================================================================
-- H2 (M224). Tras el abono la cuota 1 vale menos: su mora (vencida 10 dias el dia 40) se calcula sobre el valor VIGENTE, no sobre los 910.463,77 originales
-- ============================================================================
SELECT pg_temp.ir(40);
SELECT assert_eq('H2 mora_acumulada de vista_creditos = mora de 10 dias sobre el valor_cuota VIGENTE de la cuota 1 (y no la del valor original 910.463,77)',
                 concat_ws('|', (SELECT e ->> 'mora_acumulada' FROM jsonb_array_elements(public.vista_creditos(tests.u(1))) e),
                           ((SELECT valor_cuota FROM public.cuota WHERE credito_id = (SELECT k FROM t_h1) AND numero = 1) < 910463.77), ((SELECT e ->> 'mora_acumulada' FROM jsonb_array_elements(public.vista_creditos(tests.u(1))) e)::numeric <> pg_temp.mora(910463.77, 10))),
                 concat_ws('|', pg_temp.mora((SELECT valor_cuota FROM public.cuota WHERE credito_id = (SELECT k FROM t_h1) AND numero = 1), 10)::text, 't', 't'));
SELECT assert_eq('H2 pagar_cuota cobra valor vigente + su mora de 10 dias (pagado y mora coinciden con la referencia)',
                 (SELECT concat_ws('|', (r ->> 'pagado')::numeric = (SELECT valor_cuota FROM public.cuota WHERE credito_id = (SELECT k FROM t_h1) AND numero = 1) + (r ->> 'mora')::numeric,
                                   (r ->> 'mora')::numeric = pg_temp.mora((SELECT valor_cuota FROM public.cuota WHERE credito_id = (SELECT k FROM t_h1) AND numero = 1), 10))
                    FROM (SELECT public.pagar_cuota(tests.u(1), (SELECT k FROM t_h1)::text) AS r) x), 't|t'::text);

-- ============================================================================
-- H3 (M238). Un credito PAGADO no se opera: Recurso no encontrado y el cursor / descuento no se tocan
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_h3 AS SELECT pg_temp.cre(2, 901, 1000000, 6) AS k;
CREATE TEMP TABLE t_h3r AS SELECT pg_temp.ab(2, (SELECT k FROM t_h3), 1000000) AS r;
SELECT assert_eq('H3 liquidacion: abono = capital pendiente el dia del desembolso (interes corriendo 0) deja el credito PAGADO',
                 concat_ws('|', (SELECT r FROM t_h3r), (SELECT estado::text FROM public.credito WHERE id = (SELECT k FROM t_h3))), 'OK:1000000.00|PAGADO'::text);
SELECT assert_eq('H3 sobre el credito PAGADO: pagar_cuota, abonar_credito y activar_descuento_automatico responden Recurso no encontrado',
                 concat_ws('|', pg_temp.pc(2, (SELECT k FROM t_h3)), pg_temp.ab(2, (SELECT k FROM t_h3), 1000), pg_temp.au(2, (SELECT k FROM t_h3))), 'Recurso no encontrado|Recurso no encontrado|Recurso no encontrado'::text);
SELECT assert_eq('H3 ...y el credito PAGADO sigue sin descuento ni cursor', (SELECT concat_ws('|', descuento_automatico, cobro_hasta IS NULL) FROM public.credito WHERE id = (SELECT k FROM t_h3)), 'f|t'::text);

-- ============================================================================
-- H4 (M245). Propiedad defensiva de la regla R: pagar una cuota NO hace retroceder una fecha_interes que ya esta mas adelante
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_h4 AS SELECT pg_temp.cre(3, 901, 10000000, 12) AS k;
SELECT pg_temp.fijar((SELECT k FROM t_h4));
UPDATE public.credito SET fecha_interes = pg_temp.dia(100) WHERE id = (SELECT k FROM t_h4);
CREATE TEMP TABLE t_h4r AS SELECT pg_temp.pc(3, (SELECT k FROM t_h4)) AS r;
SELECT assert_eq('H4 pagar la cuota 1 (vence el dia 30) con el ancla ya en el dia 100: el ancla NO retrocede',
                 concat_ws('|', (SELECT r FROM t_h4r), (SELECT fecha_interes - pg_temp.dia(0) FROM public.credito WHERE id = (SELECT k FROM t_h4))), 'OK:1|100'::text);

-- ============================================================================
-- H5 (M279). Un segundo abono con el reloj POR DETRAS del ancla (se simulo el dia 15 y se volvio a modo real, dia 0): el ancla se queda en el 15
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_h5 AS SELECT pg_temp.cre(4, 901, 10000000, 12) AS k;
SELECT pg_temp.fijar((SELECT k FROM t_h5));
SELECT pg_temp.ir(15);
SELECT public.abonar_credito(tests.u(4), (SELECT k FROM t_h5)::text, 1000000);
SELECT pg_temp.real();
CREATE TEMP TABLE t_h5r AS SELECT public.abonar_credito(tests.u(4), (SELECT k FROM t_h5)::text, 500000) AS r;
SELECT assert_eq('H5 con hoy (dia 0) < ancla (dia 15): el segundo abono no cobra interes (el interes corriendo es 0) y TODO baja capital',
                 concat_ws('|', (SELECT r ->> 'interes' FROM t_h5r), (SELECT r ->> 'capital' FROM t_h5r)), '0.00|500000.00'::text);
SELECT assert_eq('H5 ...y el ancla NO retrocede (sigue en el dia 15) y el primer periodo corto usa lo que falta desde el ancla (rem = 0,5), no el periodo completo',
                 (SELECT concat_ws('|', (c.fecha_interes - pg_temp.dia(0)), abs(q.interes_programado - pg_temp.ref_j0(c.capital_pendiente, 0.5)) <= 0.02)
                    FROM public.credito c JOIN public.cuota q ON q.credito_id = c.id AND q.numero = 1 WHERE c.id = (SELECT k FROM t_h5)), '15|t'::text);

-- ============================================================================
-- H6a (M250). Dos creditos con cuotas vencidas (dia 10 y 12), fondos para UNA: gana la cuota MAS ANTIGUA aunque su credito tenga el id MAYOR
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_h6 AS SELECT pg_temp.cre(5, 901, 10000000, 12) AS a, pg_temp.cre(5, 902, 10000000, 12) AS b;
CREATE TEMP TABLE t_h6x AS SELECT greatest(a, b) AS x, least(a, b) AS y FROM t_h6;                 -- x = id mayor (cuota del dia 10), y = id menor (cuota del dia 12)
SELECT pg_temp.venc((SELECT x FROM t_h6x), 1, 10); SELECT pg_temp.venc((SELECT y FROM t_h6x), 1, 12);
SELECT pg_temp.cdt(5, 920, 1000000);                                                              -- el unico dinero llega el dia 20 (cierre del CDT): alcanza para UNA cuota
SELECT pg_temp.vaciar(5);
SELECT pg_temp.auto(5, (SELECT x FROM t_h6x), true); SELECT pg_temp.auto(5, (SELECT y FROM t_h6x), true);
SELECT pg_temp.ir(30);
SELECT pg_temp.lee(5);
SELECT assert_eq('H6a el dia 20 cierra el CDT y alcanza para UNA cuota: se paga la del dia 10 (credito de id MAYOR) y la del dia 12 sigue impaga',
                 concat_ws('|', pg_temp.pag((SELECT x FROM t_h6x)), pg_temp.pag((SELECT y FROM t_h6x))), '1:20|-'::text);

-- ============================================================================
-- H7a (M259). Saldo EXACTO = cuota (910.463,77): la cuota vence el dia 15 y se paga ese dia con mora 0; la mora hasta HOY (dia 30) no se usa para decidir si alcanza
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_h7a AS SELECT pg_temp.cre(6, 901, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_h7a), 1, 15);
SELECT pg_temp.vaciar(6, 910463.77);
SELECT assert_eq('H7a estado previo: la cuenta tiene exactamente el valor de la cuota', pg_temp.cs(6), 910463.77::numeric);
SELECT pg_temp.auto(6, (SELECT k FROM t_h7a), true);
SELECT pg_temp.ir(30);
SELECT pg_temp.lee(6);
SELECT assert_eq('H7a la cuota del dia 15 se paga EL DIA 15 con el saldo justo (mora 0 a esa fecha), sin grupo de mora, y la cuenta queda en 0',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_h7a)), pg_temp.mto((SELECT k FROM t_h7a), 'CREDITO_MORA'), pg_temp.cs(6)), '1:15|-|0.00'::text);

-- ============================================================================
-- H7b (M253). Saldo = cuota + mora(15 dias) - 0,01: NO cobra y NO falla (todo o nada); con 0,01 mas, cobra cuota y mora
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_h7b AS SELECT pg_temp.cre(7, 901, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_h7b), 1, 15);
SELECT pg_temp.vaciar(7, 910463.77 + pg_temp.mora(910463.77, 15) - 0.01);
SELECT pg_temp.ir(20);
SELECT pg_temp.auto(7, (SELECT k FROM t_h7b), true);                                              -- la cuota (dia 15) ya estaba vencida al activar: no es un evento; la unica ronda es la de hoy
SELECT pg_temp.ir(30);
SELECT assert_eq('H7b con 0,01 menos que cuota + mora de 15 dias la lectura NO falla y NO cobra nada (todo o nada)',
                 concat_ws('|', pg_temp.lee_ok(7), pg_temp.pag((SELECT k FROM t_h7b)), pg_temp.mto((SELECT k FROM t_h7b), 'CREDITO_MORA'), pg_temp.cs(7)), ('ok|-|-|' || (910463.77 + pg_temp.mora(910463.77, 15) - 0.01))::text);
SELECT tests.fondear(tests.c(7), 0.01);
SELECT pg_temp.lee(7);
SELECT assert_eq('H7b con el saldo justo (cuota + mora de 15 dias) cobra la cuota y la mora, con fecha de hoy',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_h7b)), pg_temp.mto((SELECT k FROM t_h7b), 'CREDITO_MORA'), pg_temp.cs(7)), ('1:30|' || pg_temp.mora(910463.77, 15) || '|0.00')::text);

-- ============================================================================
-- H8 (M255). A (cursor 10) genera el evento del dia 20 con su cuota; B (cursor 20) tiene una cuota vencida el dia 18: NO cobra con fecha 20 (su ventana es (20, hoy]), cobra HOY
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_h8a AS SELECT pg_temp.cre(8, 901, 10000000, 12) AS k;
CREATE TEMP TABLE t_h8b AS SELECT pg_temp.cre(8, 902, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_h8a), 1, 20); SELECT pg_temp.venc((SELECT k FROM t_h8b), 1, 18);
SELECT pg_temp.ir(20);
SELECT pg_temp.auto(8, (SELECT k FROM t_h8b), true);                                              -- B: cursor = dia 20
SELECT pg_temp.real();
SELECT pg_temp.ir(10);
SELECT pg_temp.auto(8, (SELECT k FROM t_h8a), true);                                              -- A: cursor = dia 10
SELECT assert_eq('H8 estado previo: cursores A = 10 y B = 20, nada pagado', concat_ws('|', pg_temp.cur((SELECT k FROM t_h8a)), pg_temp.cur((SELECT k FROM t_h8b)), pg_temp.pag((SELECT k FROM t_h8a)), pg_temp.pag((SELECT k FROM t_h8b))), '10|20|-|-'::text);
SELECT pg_temp.ir(30);
SELECT pg_temp.lee(8);
SELECT assert_eq('H8 A cobra su cuota el dia 20 (evento propio, mora 0); B NO cobra con fecha 20 (d = su cursor no es ventana) sino HOY (dia 30) con mora de 12 dias (18 -> 30)',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_h8a)), pg_temp.pag((SELECT k FROM t_h8b)), pg_temp.mto((SELECT k FROM t_h8b), 'CREDITO_MORA')), ('1:20|1:30|' || pg_temp.mora(910463.77, 12))::text);

-- ============================================================================
-- H9 (M257). A (cursor 10, cuota del dia 12 sin saldo); B (cursor 20) tiene una cuota del dia 18, ANTERIOR a su cursor: NO es un evento. Un ingreso de otra cuenta llega el dia 14:
--   A cobra HOY (dia 30, mora de 18 dias), no el dia 18 (esa fecha existiria solo si los vencimientos de B contaran con el cursor menor)
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_h9a AS SELECT pg_temp.cre(9, 901, 10000000, 12) AS k;
CREATE TEMP TABLE t_h9b AS SELECT pg_temp.cre(9, 902, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_h9a), 1, 12); SELECT pg_temp.venc((SELECT k FROM t_h9b), 1, 18);
SELECT pg_temp.vaciar(9);
SELECT tests.fondear(tests.c(99), 3000000);
SELECT pg_temp.ir(20);
SELECT pg_temp.auto(9, (SELECT k FROM t_h9b), true);                                              -- B: cursor = dia 20
SELECT pg_temp.real();
SELECT pg_temp.ir(10);
SELECT pg_temp.auto(9, (SELECT k FROM t_h9a), true);                                              -- A: cursor = dia 10
SELECT pg_temp.ir(14);
SELECT public.hacer_transferencia(tests.u(99), (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(9)), 2000000, 'llega el dia 14', NULL);
SELECT pg_temp.ir(30);
SELECT pg_temp.lee(9);
SELECT assert_eq('H9 el ingreso del dia 14 llega por una operacion de otra cuenta: A cobra HOY (dia 30) con mora de 18 dias y B tambien hoy con mora de 12 (nada con fecha 18)',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_h9a)), pg_temp.mto((SELECT k FROM t_h9a), 'CREDITO_MORA'), pg_temp.pag((SELECT k FROM t_h9b)), pg_temp.mto((SELECT k FROM t_h9b), 'CREDITO_MORA')),
                 ('1:30|' || pg_temp.mora(910463.77, 18) || '|1:30|' || pg_temp.mora(910463.77, 12))::text);

-- ============================================================================
-- H10 (M260). Pausa con el reloj por detras del cursor AUNQUE haya una cuota ya vencida (dia -5) y saldo: no cobra, no escribe, no toca el cursor
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_h10 AS SELECT pg_temp.cre(10, 901, 10000000, 12) AS k;
SELECT pg_temp.venc((SELECT k FROM t_h10), 1, -5);
SELECT pg_temp.vaciar(10);
SELECT pg_temp.auto(10, (SELECT k FROM t_h10), true);
SELECT pg_temp.ir(10);
SELECT pg_temp.lee(10);                                                                           -- sin saldo: nada se cobra y el cursor llega al dia 10
SELECT pg_temp.real();                                                                            -- hoy (dia 0) < cursor (dia 10) y la cuota del dia -5 YA vencio
SELECT tests.fondear(tests.c(10), 3000000);
CREATE TEMP TABLE t_n10 AS SELECT pg_temp.npatas(10) AS n;
SELECT pg_temp.lee(10); SELECT pg_temp.lee(10);
SELECT assert_eq('H10 con hoy < cursor y una cuota ya vencida con saldo disponible: el motor NO cobra, NO escribe y NO toca el cursor',
                 concat_ws('|', pg_temp.npatas(10) - (SELECT n FROM t_n10), pg_temp.pag((SELECT k FROM t_h10)), pg_temp.cur((SELECT k FROM t_h10))), '0|-|10'::text);

-- H10b (M260). La pausa tambien debe vivir DENTRO de _cobrar_creditos: otro credito A (activo, cursor = hoy, cuota vencida e inalcanzable) obliga al motor a entrar
--   (la salida rapida no basta); el credito B, con cursor 10 > hoy, esta en pausa y su cuota vencida (alcanzable) NO se cobra
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_h10a AS SELECT pg_temp.cre(11, 901, 50000000, 12) AS k;                       -- A: cuota ~4,5M (inalcanzable)
CREATE TEMP TABLE t_h10b AS SELECT pg_temp.cre(11, 902, 1000000, 12) AS k;                        -- B: cuota ~91k (alcanzable)
SELECT pg_temp.venc((SELECT k FROM t_h10a), 1, -5); SELECT pg_temp.venc((SELECT k FROM t_h10b), 1, -5);
SELECT pg_temp.vaciar(11);
SELECT pg_temp.ir(10);
SELECT pg_temp.auto(11, (SELECT k FROM t_h10b), true);                                            -- B: cursor = dia 10
SELECT pg_temp.real();                                                                            -- hoy (dia 0) < cursor de B (10)
SELECT pg_temp.auto(11, (SELECT k FROM t_h10a), true);                                            -- A: cursor = hoy real (dia 0): A mantiene al motor despierto
SELECT tests.fondear(tests.c(11), 1000000);
SELECT assert_eq('H10b estado previo: cursor A = 0 y B = 10; nada pagado', concat_ws('|', pg_temp.cur((SELECT k FROM t_h10a)), pg_temp.cur((SELECT k FROM t_h10b)), pg_temp.pag((SELECT k FROM t_h10a)), pg_temp.pag((SELECT k FROM t_h10b))), '0|10|-|-'::text);
SELECT pg_temp.lee(11); SELECT pg_temp.lee(11);
SELECT assert_eq('H10b el motor entra por A (sin saldo para su cuota) pero B, en pausa (cursor 10 > hoy 0), NO cobra su cuota vencida aunque hay saldo; los cursores no se tocan',
                 concat_ws('|', pg_temp.pag((SELECT k FROM t_h10a)), pg_temp.pag((SELECT k FROM t_h10b)), pg_temp.cur((SELECT k FROM t_h10a)), pg_temp.cur((SELECT k FROM t_h10b))), '-|-|0|10'::text);

-- ============================================================================
-- H6b (M251). Empate de vencimiento: gana el credito de DESEMBOLSO mas antiguo aunque su id sea MAYOR (se busca un par con ids opuestos creando pares de creditos en dias consecutivos)
-- ============================================================================
SELECT pg_temp.real();
CREATE TEMP TABLE t_h6b (n int, viejo uuid, nuevo uuid);
DO $do$
DECLARE n int; a uuid; b uuid;
BEGIN
  FOR n IN 41..60 LOOP
    a := pg_temp.cre(n, 901, 10000000, 12);                                                     -- desembolso: hoy
    PERFORM public._reloj_actualizar(false, (public.hoy_banco() + 1)::text);
    b := pg_temp.cre(n, 902, 10000000, 12);                                                     -- desembolso: manana
    IF a > b THEN INSERT INTO t_h6b VALUES (n, a, b); EXIT; END IF;                              -- el de desembolso mas antiguo (a) tiene el id MAYOR
  END LOOP;
END $do$;
SELECT assert_eq('H6b se encontro un par de creditos con el desembolso mas antiguo y el id MAYOR (probabilidad de fallar 2^-20)', (SELECT count(*) FROM t_h6b), 1::bigint);
CREATE TEMP TABLE t_h6bt AS SELECT public.hoy_banco() AS t0;
UPDATE public.cuota SET fecha_vencimiento = (SELECT t0 FROM t_h6bt) + 10 WHERE numero = 1 AND credito_id IN (SELECT viejo FROM t_h6b UNION SELECT nuevo FROM t_h6b);   -- AMBAS vencen el mismo dia
SELECT pg_temp.cdt((SELECT n FROM t_h6b), 915, 1000000);
SELECT pg_temp.vaciar((SELECT n FROM t_h6b));
SELECT pg_temp.auto((SELECT n FROM t_h6b), (SELECT viejo FROM t_h6b), true); SELECT pg_temp.auto((SELECT n FROM t_h6b), (SELECT nuevo FROM t_h6b), true);
SELECT public._reloj_actualizar(false, ((SELECT t0 FROM t_h6bt) + 20)::text);
SELECT pg_temp.lee((SELECT n FROM t_h6b));
SELECT assert_eq('H6b el CDT cierra el dia 15 con fondos para UNA cuota: se paga la del credito de desembolso MAS ANTIGUO (id mayor) y la del mas nuevo sigue impaga',
                 (SELECT concat_ws('|', (SELECT bool_or(pagada) FROM public.cuota WHERE credito_id = viejo), (SELECT bool_or(pagada) FROM public.cuota WHERE credito_id = nuevo)) FROM t_h6b), 't|f'::text);

SELECT assert_eq('estado global en orden (partida doble, I5u, planes y defensas) tras todos los escenarios', (SELECT ok FROM public.v_integridad_global), true);
ROLLBACK;
