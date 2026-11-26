-- 60_pagos_calculo.test.sql · Etapa 9 · la matematica de la mora (_mora_cuota, _dias_mora, _mora_de_cuota, _mora_pendiente) y del recalculo de las cuotas restantes (_plan_restante)
-- contra referencias INDEPENDIENTES (float8 con exp/ln, sumas por tramos), incluida la ancla futura de un pago anticipado (R3) y el caso de dos abonos en un mismo periodo.
-- No repite el plan frances de E8 (57). Una transaccion con ROLLBACK final; la tasa de mora es un valor de prueba (la real la decide el equipo, D7).
BEGIN;

-- ============================================================================
-- 1. _mora_cuota (D7 PROVISIONAL, centralizada): simple sobre el valor de la cuota; tasa NULL = 0
-- ============================================================================
SELECT assert_eq('sin tasa de mora (parametro.tasa_mora_anual NULL, el estado real hasta que el equipo decida D7) la mora es 0 siempre',
                 (SELECT tasa_mora_anual IS NULL FROM public.parametro WHERE id = 1)::text || '|' || public._mora_cuota(910463.77, 30)::text, 'true|0.00'::text);
UPDATE public.parametro SET tasa_mora_anual = 30;
SELECT assert_eq('910.463,77 con 30 % y 30 dias = 22.449,79 (simple nominal); 1 dia = 748,33; 0 y negativos = 0',
                 concat_ws('|', public._mora_cuota(910463.77, 30), public._mora_cuota(910463.77, 1), public._mora_cuota(910463.77, 0), public._mora_cuota(910463.77, -3)), '22449.79|748.33|0.00|0.00'::text);
SELECT assert_eq('la mora coincide con una referencia independiente (float8) en 500 casos aleatorios (±1 centavo) y es lineal en los dias',
                 (SELECT count(*) FROM (SELECT v, d FROM (SELECT (1 + random() * 99999999)::numeric(18,2) AS v, (1 + random() * 2000)::int AS d FROM generate_series(1, 500)) x
                    WHERE abs(public._mora_cuota(v, d)::float8 - v::float8 * 0.30 / 365 * d) > 0.0100001 OR public._mora_cuota(v, d) < public._mora_cuota(v, d - 1)) y), 0::bigint);
-- (el dominio porcentaje no admite tasa 0: la mora sin tasa se expresa con NULL, ya probado arriba)
SELECT assert_eq('_dias_mora: max(0, fecha - max(vencimiento, mora_hasta)); mora_hasta NULL = desde el vencimiento',
                 concat_ws('|', public._dias_mora(NULL, DATE '2026-01-10', DATE '2026-01-15'), public._dias_mora(DATE '2026-01-12', DATE '2026-01-10', DATE '2026-01-15'),
                           public._dias_mora(DATE '2026-01-20', DATE '2026-01-10', DATE '2026-01-15'), public._dias_mora(NULL, DATE '2026-01-10', DATE '2026-01-10'), public._dias_mora(NULL, DATE '2026-01-10', DATE '2026-01-05')),
                 '5|3|0|0|0'::text);

-- ============================================================================
-- 2. _mora_de_cuota y _mora_pendiente sobre un credito real (E8): solo cuotas IMPAGAS y VENCIDAS; mora_hasta fija el reloj
-- ============================================================================
SELECT tests.cliente(1); SELECT tests.fondear(tests.c(1), 1000000);
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES (tests.p(901), 'Libre', '', 18, 1, 1000000000, 1, 360);
CREATE TEMP TABLE t_k AS SELECT (public.solicitar_credito(tests.u(1), tests.p(901)::text, 10000000, 12) ->> 'id')::uuid AS k, public.hoy_banco() AS h;
UPDATE public.cuota SET fecha_vencimiento = (SELECT h FROM t_k) + 10 WHERE credito_id = (SELECT k FROM t_k) AND numero = 1;
UPDATE public.cuota SET fecha_vencimiento = (SELECT h FROM t_k) + 20 WHERE credito_id = (SELECT k FROM t_k) AND numero = 2;
SELECT assert_eq('mora de la cuota 1 a los 15 dias del vencimiento (dia 25) = round(910.463,77 * 30 % / 365 * 15, 2); la cuota 2 (vence el 20) a 5 dias; una cuota que aun no vence = 0',
                 concat_ws('|', public._mora_de_cuota((SELECT k FROM t_k), 1, (SELECT h FROM t_k) + 25), public._mora_de_cuota((SELECT k FROM t_k), 2, (SELECT h FROM t_k) + 25), public._mora_de_cuota((SELECT k FROM t_k), 3, (SELECT h FROM t_k) + 25)),
                 (round(910463.77 * 0.30 / 365 * 15, 2) || '|' || round(910463.77 * 0.30 / 365 * 5, 2) || '|0.00')::text);
SELECT assert_eq('_mora_pendiente = suma de las cuotas impagas vencidas a la fecha; el dia del vencimiento aun no hay mora',
                 concat_ws('|', public._mora_pendiente((SELECT k FROM t_k), (SELECT h FROM t_k) + 25), public._mora_pendiente((SELECT k FROM t_k), (SELECT h FROM t_k) + 10), public._mora_pendiente((SELECT k FROM t_k), (SELECT h FROM t_k) + 11)),
                 ((round(910463.77 * 0.30 / 365 * 15, 2) + round(910463.77 * 0.30 / 365 * 5, 2)) || '|0.00|' || round(910463.77 * 0.30 / 365, 2))::text);
UPDATE public.credito SET mora_hasta = (SELECT h FROM t_k) + 20 WHERE id = (SELECT k FROM t_k);
SELECT assert_eq('con mora_hasta = dia 20 (un abono ya cobro la mora hasta esa fecha) la mora del dia 25 es de 5 dias para la cuota 1 y 5 para la 2 (nunca antes de mora_hasta)',
                 concat_ws('|', public._mora_de_cuota((SELECT k FROM t_k), 1, (SELECT h FROM t_k) + 25), public._mora_de_cuota((SELECT k FROM t_k), 2, (SELECT h FROM t_k) + 25)),
                 (round(910463.77 * 0.30 / 365 * 5, 2) || '|' || round(910463.77 * 0.30 / 365 * 5, 2))::text);
UPDATE public.credito SET mora_hasta = NULL WHERE id = (SELECT k FROM t_k);
UPDATE public.cuota SET pagada = true, fecha_pago = (SELECT h FROM t_k) WHERE credito_id = (SELECT k FROM t_k) AND numero = 1;
SELECT assert_eq('una cuota pagada ya no genera mora', public._mora_de_cuota((SELECT k FROM t_k), 1, (SELECT h FROM t_k) + 25), 0.00::numeric);

-- ============================================================================
-- 3. _plan_restante: contra una referencia independiente (float8 con exp/ln) y propiedades
-- ============================================================================
-- referencia: saldo final de la recurrencia con la cuota teorica C = (K+j0)·i·(1+i)^(m-1)/((1+i)^m-1) en float8 = 0 (cierra la deuda)
CREATE FUNCTION pg_temp.i_ref(p_tasa numeric) RETURNS float8 LANGUAGE sql AS $f$ SELECT exp(ln(1 + p_tasa::float8 / 100) / 12) - 1 $f$;
CREATE FUNCTION pg_temp.c_ref(k numeric, tasa numeric, m int, j0 numeric) RETURNS float8 LANGUAGE sql AS $f$
  SELECT (k::float8 + j0::float8) * pg_temp.i_ref(tasa) * power(1 + pg_temp.i_ref(tasa), m - 1) / (power(1 + pg_temp.i_ref(tasa), m) - 1) $f$;
SELECT assert_eq('ejemplo del diseno (10M, 12 m, 18 %; cuota 1 pagada; dia 15 de 30; abono de 1.000.000): K'' = 8.292.504,67, j0 = 57.584,94; las 11 cuotas pasan de 910.463,77 a 812.524,11 y la ultima es 812.524,17',
                 (SELECT concat_ws('|', max(cuota) FILTER (WHERE numero = 1), max(cuota) FILTER (WHERE numero = 11), sum(capital), max(interes) FILTER (WHERE numero = 1))
                    FROM public._plan_restante(8292504.67, 18, 11, round(8292504.67 * public._tasa_mensual(18) * 15 / 30, 2))), '812524.11|812524.17|8292504.67|57584.94'::text);
SELECT assert_eq('R3(b) pago anticipado + abono antes del vencimiento (rem = 1, j0 = K''·i): la cuota nueva es la cuota francesa ESTANDAR de K'' a 11 cuotas (811.805,09), la ultima 811.805,08',
                 (SELECT concat_ws('|', max(cuota) FILTER (WHERE numero = 1), max(cuota) FILTER (WHERE numero = 11), (SELECT cuota FROM public._plan_cuotas(8228420.53, 18, 11) WHERE numero = 1))
                    FROM public._plan_restante(8228420.53, 18, 11, round(8228420.53 * public._tasa_mensual(18), 2))), '811805.09|811805.08|811805.09'::text);
SELECT assert_eq('caso largo (1.900M, 14 %, 300 cuotas, j0 = 40 % del periodo): cuotas 1 y 2 = 21.537.818,39; la ultima difiere solo −5,99 (deriva del redondeo, no del primer periodo corto)',
                 (SELECT concat_ws('|', max(cuota) FILTER (WHERE numero = 1), max(cuota) FILTER (WHERE numero = 2), max(cuota) FILTER (WHERE numero = 300))
                    FROM public._plan_restante(1900000000, 14, 300, round(1900000000 * public._tasa_mensual(14) * 0.4, 2))), '21537818.39|21537818.39|21537812.40'::text);
SELECT assert_eq('con el primer periodo ya vencido (rem = 0, j0 = 0) la primera cuota es solo capital y la cuota fija la cubre', (SELECT concat_ws('|', interes, cuota = capital) FROM public._plan_restante(5000000, 18, 6, 0) WHERE numero = 1), '0.00|t'::text);
-- 150 casos aleatorios
SELECT setseed(0.20261125);
CREATE TEMP TABLE t_pr AS SELECT g AS id, round((10000 + random() * 1999990000)::numeric, 2) AS k, round((0.5 + random() * 59)::numeric, 3) AS tasa, (1 + floor(random() * 359))::int AS m, random() AS rem FROM generate_series(1, 150) g;
UPDATE t_pr SET m = 1 + (id % 3) WHERE id <= 6;                                   -- unos casos de 1 a 3 cuotas
CREATE TEMP TABLE t_viol (id int, regla text);
DO $do$
DECLARE c record; p record; i float8; s numeric; cfija numeric; ult numeric; j0 numeric; bound float8; sumcap numeric; n int;
BEGIN
  FOR c IN SELECT * FROM t_pr ORDER BY id LOOP
    i := pg_temp.i_ref(c.tasa);
    j0 := round((c.k * public._tasa_mensual(c.tasa) * c.rem)::numeric, 2);
    s := c.k; sumcap := 0; n := 0;
    FOR p IN SELECT * FROM public._plan_restante(c.k, c.tasa, c.m, j0) ORDER BY numero LOOP
      n := n + 1;
      IF p.cuota <> p.capital + p.interes THEN INSERT INTO t_viol VALUES (c.id, 'cuota <> capital + interes'); END IF;
      s := s - p.capital; sumcap := sumcap + p.capital;
      IF p.saldo <> s OR p.saldo < 0 THEN INSERT INTO t_viol VALUES (c.id, 'saldo incoherente en ' || p.numero); END IF;
      IF p.numero = 1 THEN cfija := p.cuota; IF p.interes <> j0 THEN INSERT INTO t_viol VALUES (c.id, 'el interes del primer periodo no es j0'); END IF; END IF;
      IF p.numero > 1 AND abs(p.interes - round((p.saldo + p.capital) * i::numeric, 2)) > 0.01 THEN INSERT INTO t_viol VALUES (c.id, 'interes de la cuota ' || p.numero || ' lejos de la referencia'); END IF;
      ult := p.cuota;
    END LOOP;
    IF n <> c.m OR sumcap <> c.k OR s <> 0 THEN INSERT INTO t_viol VALUES (c.id, 'plazo o capital: n=' || n || ' sum=' || sumcap); END IF;
    IF c.m > 1 AND abs(cfija::float8 - pg_temp.c_ref(c.k, c.tasa, c.m, j0)) > 0.0100001 THEN INSERT INTO t_viol VALUES (c.id, 'cuota fija lejos de la referencia'); END IF;
    IF c.m > 1 THEN
      bound := 0.01 * (power(1 + i, c.m) - 1) / i + 0.02;
      IF abs(ult::float8 - cfija::float8) > bound THEN INSERT INTO t_viol VALUES (c.id, 'la ultima cuota se desvia mas de lo que explica el redondeo'); END IF;
    END IF;
  END LOOP;
END $do$;
SELECT assert_eq('150 casos aleatorios: m cuotas exactas (el plazo no cambia), Σ capital = K'' exacto, saldo final 0, cuota = capital + interes, interes del primer periodo = j0, intereses y cuota fija contra la referencia exp/ln (±1 centavo), deriva de la ultima acotada por el redondeo',
                 (SELECT coalesce(string_agg(id || ':' || regla, '; '), '') FROM (SELECT * FROM t_viol ORDER BY id LIMIT 5) q), ''::text);
SELECT assert_eq('con j0 = K''·i (periodo completo) la cuota nueva coincide (±1 centavo: j0 se redondea) con la cuota francesa estandar de K'' a m cuotas (E8) en 100 casos',
                 (SELECT count(*) FROM t_pr c WHERE c.id > 6 AND c.id <= 106 AND
                    abs((SELECT cuota FROM public._plan_restante(c.k, c.tasa, c.m, round(c.k * public._tasa_mensual(c.tasa), 2)) WHERE numero = 1) - (SELECT cuota FROM public._plan_cuotas(c.k, c.tasa, c.m) WHERE numero = 1)) > 0.01), 0::bigint);
SELECT assert_eq('la cuota nueva es MENOR que la original tras un abono de capital (K'' < K, mismo plazo restante y tasa) en los 150 casos con periodo completo',
                 (SELECT count(*) FROM t_pr c WHERE c.m > 1 AND
                    (SELECT cuota FROM public._plan_restante(c.k * 0.9, c.tasa, c.m, round(c.k * 0.9 * public._tasa_mensual(c.tasa), 2)) WHERE numero = 1) >= (SELECT cuota FROM public._plan_cuotas(c.k, c.tasa, c.m) WHERE numero = 1)), 0::bigint);
SELECT assert_eq('argumentos invalidos: capital <= 0, m < 1, j0 negativo o NULL = error P0001 de la funcion',
                 concat_ws('|', (tests.captura($$SELECT * FROM public._plan_restante(0, 18, 5, 0)$$) LIKE 'Créditos: _plan_restante%'), (tests.captura($$SELECT * FROM public._plan_restante(1000, 18, 0, 0)$$) LIKE 'Créditos: _plan_restante%'),
                           (tests.captura($$SELECT * FROM public._plan_restante(1000, 18, 5, -1)$$) LIKE 'Créditos: _plan_restante%'), (tests.captura($$SELECT * FROM public._plan_restante(1000, 18, 5, NULL)$$) LIKE 'Créditos: _plan_restante%')), 't|t|t|t'::text);
SELECT assert_eq('la deuda de LIQUIDACION del ejemplo (dia 15) = capital + interes corriendo = 9.292.504,67 (9.228.420,53 + 64.084,14)', (9228420.53 + round(128168.28 * 15 / 30, 2))::text, '9292504.67'::text);

-- ============================================================================
-- 4. Interes de dos abonos en un mismo periodo = suma de TRAMOS (referencia por tramos de 10 dias), no la formula ingenua «1 - f»
-- ============================================================================
SELECT assert_eq('periodo de 30 dias: abono 1 (1.000.000, dia 10) + abono 2 (500.000, dia 20) + resto: interes total = suma de los 3 tramos de 10 dias sobre cada saldo (117.167,43); la formula ingenua daria 18.076,79 mas',
                 (WITH base AS (SELECT (SELECT saldo FROM public._plan_cuotas(10000000, 18, 12) WHERE numero = 1) AS k1, (SELECT interes FROM public._plan_cuotas(10000000, 18, 12) WHERE numero = 2) AS int2, public._tasa_mensual(18) AS i),
                       a1 AS (SELECT *, round(int2 * 10 / 30, 2) AS i1 FROM base),
                       b1 AS (SELECT *, k1 - (1000000 - i1) AS k1n, round((k1 - (1000000 - i1)) * i * 20 / 30, 2) AS j0_1 FROM a1),
                       a2 AS (SELECT *, round(j0_1 * 10 / 20, 2) AS i2 FROM b1),
                       b2 AS (SELECT *, k1n - (500000 - i2) AS k2n FROM a2)
                  SELECT concat_ws('|', i1 + i2 + round(k2n * i * 10 / 30, 2), round(k1 * i * 10 / 30, 2) + round(k1n * i * 10 / 30, 2) + round(k2n * i * 10 / 30, 2),
                                   round(k2n * i * 0.5, 2) - round(k2n * i * 10 / 30, 2)) FROM b2),
                 '117167.43|117167.43|18076.79'::text);
ROLLBACK;
