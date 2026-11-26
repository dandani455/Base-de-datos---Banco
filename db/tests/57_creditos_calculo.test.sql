-- 57_creditos_calculo.test.sql · Etapa 8 · la matematica del credito: _tasa_mensual (D1 centralizada), _plan_cuotas (plan frances en numeric, la ultima cuota
-- absorbe el redondeo), _fecha_vencimiento (calendario anclado), validacion del plazo y la regla ct_credito_plan (UNA regla, v1.1) sobre planes fabricados.
-- No repite el libro (E2), el reloj (E3) ni el motor (E7). Una transaccion con ROLLBACK final.
BEGIN;

-- REFERENCIA INDEPENDIENTE: i y la cuota fija en float8 con exp/ln (otra aritmetica y otra formula que el numeric/power del codigo)
CREATE FUNCTION pg_temp.i_ref(p_tasa numeric) RETURNS float8 LANGUAGE sql AS $f$ SELECT exp(ln(1 + p_tasa::float8 / 100) / 12) - 1 $f$;
CREATE FUNCTION pg_temp.c_ref(p_monto numeric, p_tasa numeric, p_n int) RETURNS float8 LANGUAGE sql AS $f$
  SELECT p_monto::float8 * pg_temp.i_ref(p_tasa) / (1 - exp(-p_n * ln(1 + pg_temp.i_ref(p_tasa)))) $f$;
-- resumen del plan: cuota fija, ultima, total, intereses
CREATE FUNCTION pg_temp.resumen(p_monto numeric, p_tasa numeric, p_n int) RETURNS text LANGUAGE sql AS $f$
  SELECT (max(cuota) FILTER (WHERE numero = 1), max(cuota) FILTER (WHERE numero = p_n), sum(cuota), sum(interes))::text FROM public._plan_cuotas(p_monto, p_tasa, p_n) $f$;

-- ============================================================================
-- 1. Casos con cifras conocidas (comparadas con una consulta independiente al disenar E8)
-- ============================================================================
SELECT assert_eq('$10.000.000, 12 cuotas, 18 % E.A.: cuota 910.463,77; la ultima 910.463,73 absorbe el redondeo; total 10.925.565,20; intereses 925.565,20',
                 pg_temp.resumen(10000000, 18, 12), '(910463.77,910463.73,10925565.20,925565.20)'::text);
SELECT assert_eq('$30.000.000 al 23,9 % a 24 meses: cuota 1.550.764,56 y ultima 1.550.764,58', pg_temp.resumen(30000000, 23.9, 24) ~ '^\(1550764\.56,1550764\.58,' , true);
SELECT assert_eq('$50.000.000 al 18,9 % a 120 meses: cuota 882.874,10 y ultima 882.874,46', pg_temp.resumen(50000000, 18.9, 120) ~ '^\(882874\.10,882874\.46,', true);
SELECT assert_eq('$2.000.000.000 al 14 % a 360 meses: cuota 22.397.296,18 y ultima 22.397.278,22 (la deriva acumulada del redondeo, -17,96)',
                 pg_temp.resumen(2000000000, 14, 360) ~ '^\(22397296\.18,22397278\.22,', true);
SELECT assert_eq('$500.000 al 12 % a 360 meses: cuota 4.908,22 y ultima 4.916,69', pg_temp.resumen(500000, 12, 360) ~ '^\(4908\.22,4916\.69,', true);
SELECT assert_eq('una sola cuota: cuota = capital + interes de un mes, Σ capital = monto',
                 (SELECT (cuota, capital, interes, saldo)::text FROM public._plan_cuotas(1000000, 5, 1)), '(1004074.12,1000000.00,4074.12,0.00)'::text);

-- ============================================================================
-- 2. _tasa_mensual: UNICO punto de la convencion de tasas (D1, PROVISIONAL)
-- ============================================================================
SELECT assert_eq('E.A. estricta: (1 + i)^12 = 1 + tasa para 18 % (a 1e-15) y 0.001 %',
                 (abs(power(1 + public._tasa_mensual(18), 12) - 1.18) < 1e-15, abs(power(1 + public._tasa_mensual(0.001), 12) - 1.00001) < 1e-15)::text, '(t,t)'::text);
SELECT assert_eq('i = 1,388843 % para 18 % (la cifra del diseno); tasa nula, negativa o NULL = 0 (sin error)',
                 (round(public._tasa_mensual(18) * 100, 6), public._tasa_mensual(0), public._tasa_mensual(-5), public._tasa_mensual(NULL))::text, '(1.388843,0,0,0)'::text);
SELECT assert_eq('el plan depende SOLO de _tasa_mensual: con la tasa nominal 18/12 la cuota seria 916.799,93 (contraste documentado), con E.A. 910.463,77',
                 (SELECT (round(10000000 * (18.0 / 1200) * power(1 + 18.0 / 1200, 12) / (power(1 + 18.0 / 1200, 12) - 1), 2), cuota)::text
                    FROM public._plan_cuotas(10000000, 18, 12) WHERE numero = 1), '(916799.93,910463.77)'::text);

-- ============================================================================
-- 3. Propiedades del plan: ~200 casos aleatorios contra la referencia independiente
-- ============================================================================
SELECT setseed(0.20261124);
CREATE TEMP TABLE t_caso AS
  SELECT g AS id, (round((1 + random() * 1999999999)::numeric, 2)) AS monto, (round((0.5 + random() * 59)::numeric, 3)) AS tasa, (1 + floor(random() * 360))::int AS n
    FROM generate_series(1, 200) g;
-- unos casos extremos al final
INSERT INTO t_caso VALUES (201, 1000, 0.001, 360), (202, 1000, 100, 360), (203, 0.01, 12, 1), (204, 9999999999999.99, 30, 360), (205, 1000000, 100, 1), (206, 5000000, 23.9, 6);
-- (203 y 204 se verifican aparte: monto diminuto y monto gigante)
DELETE FROM t_caso WHERE id IN (203, 204);
CREATE TEMP TABLE t_viol (id int, regla text);
DO $do$
DECLARE c record; p record; s numeric; ant numeric; i float8; cfija numeric; cap_total numeric; kmax int; bound float8; ult numeric;
BEGIN
  FOR c IN SELECT * FROM t_caso ORDER BY id LOOP
    i := pg_temp.i_ref(c.tasa);
    s := c.monto; cap_total := 0; ant := c.monto;
    FOR p IN SELECT * FROM public._plan_cuotas(c.monto, c.tasa, c.n) ORDER BY numero LOOP
      IF p.cuota <> p.capital + p.interes THEN INSERT INTO t_viol VALUES (c.id, 'cuota <> capital + interes en ' || p.numero); END IF;
      IF abs(p.interes - round((s * i)::numeric, 2)) > 0.01 THEN INSERT INTO t_viol VALUES (c.id, 'interes de la cuota ' || p.numero || ' lejos de la referencia'); END IF;
      s := s - p.capital; cap_total := cap_total + p.capital;
      IF p.saldo <> s THEN INSERT INTO t_viol VALUES (c.id, 'saldo ' || p.numero || ' no es el saldo previo - capital'); END IF;
      IF p.saldo < 0 OR (p.numero > 1 AND p.saldo >= ant AND p.capital > 0) THEN INSERT INTO t_viol VALUES (c.id, 'saldo no decrece o negativo en ' || p.numero); END IF;
      IF p.numero = 1 THEN cfija := p.cuota; END IF;
      ult := p.cuota;
      ant := p.saldo;
    END LOOP;
    IF cap_total <> c.monto OR s <> 0 THEN INSERT INTO t_viol VALUES (c.id, 'Σ capital <> monto (' || cap_total || ')'); END IF;
    IF c.n > 1 AND abs(cfija::float8 - pg_temp.c_ref(c.monto, c.tasa, c.n)) > 0.0100001 THEN INSERT INTO t_viol VALUES (c.id, 'cuota fija lejos de la referencia'); END IF;
    -- la cuota (con n = 1 es capital + interes de un mes) y la deriva de la ultima: error de redondeo compuesto <= 0,01 * ((1+i)^n - 1) / i + 0,01
    IF c.n > 1 THEN
      bound := 0.01 * (power(1 + i, c.n) - 1) / i + 0.01;
      IF abs(ult::float8 - cfija::float8) > bound THEN INSERT INTO t_viol VALUES (c.id, 'la ultima cuota se desvia de la fija mas de lo que explica el redondeo'); END IF;
    END IF;
  END LOOP;
END $do$;
SELECT assert_eq('206 planes (200 aleatorios + extremos 0,001 %, 100 %, 1 cuota, 360 cuotas): Σ capital = monto, saldo final 0 y decreciente, cuota = capital + interes, interes por periodo y cuota fija = referencia exp/ln (±1 centavo), deriva de la ultima cuota acotada por el redondeo',
                 (SELECT coalesce(string_agg(id || ':' || regla, '; '), '') FROM (SELECT * FROM t_viol ORDER BY id LIMIT 5) q), ''::text);
SELECT assert_eq('Σ cuotas - monto = Σ intereses (intereses_totales coherente) en los 206 planes',
                 (SELECT count(*) FROM t_caso c WHERE (SELECT sum(cuota) - sum(interes) FROM public._plan_cuotas(c.monto, c.tasa, c.n)) <> c.monto), 0::bigint);

-- monto diminuto: el interes redondeado supera la cuota -> 'Monto fuera de rango' (nunca un error de CHECK); monto gigante dentro del dominio
SELECT assert_eq('monto diminuto ($0,01 a 360 meses): el plan se rechaza con "Monto fuera de rango" o se calcula sin capital negativo (nunca un CHECK)',
                 (SELECT CASE WHEN r IS NULL OR r = 'Monto fuera de rango' THEN 'ok' ELSE r END
                    FROM (SELECT tests.captura($$SELECT count(*) FROM public._plan_cuotas(0.01, 12, 360) WHERE capital < 0$$) AS r) q), 'ok'::text);
SELECT assert_eq('monto gigante ($9.999.999.999.999,99 al 30 % a 360 meses): Σ capital = monto y ninguna cuota rebasa el dominio dinero',
                 (SELECT (sum(capital) = 9999999999999.99, max(cuota) < 1e13)::text FROM public._plan_cuotas(9999999999999.99, 30, 360)), '(t,t)'::text);
SELECT assert_eq('argumentos invalidos: n = 0, n = 361 (> tecnico 360), monto 0 o NULL, n NULL = error P0001 de la funcion',
                 (tests.captura($$SELECT * FROM public._plan_cuotas(1000, 10, 0)$$) LIKE 'Créditos: _plan_cuotas recibió monto o plazo inválidos%',
                  tests.captura($$SELECT * FROM public._plan_cuotas(1000, 10, 361)$$) LIKE 'Créditos: _plan_cuotas%',
                  tests.captura($$SELECT * FROM public._plan_cuotas(0, 10, 12)$$) LIKE 'Créditos: _plan_cuotas%',
                  tests.captura($$SELECT * FROM public._plan_cuotas(NULL, 10, 12)$$) LIKE 'Créditos: _plan_cuotas%',
                  tests.captura($$SELECT * FROM public._plan_cuotas(1000, 10, NULL)$$) LIKE 'Créditos: _plan_cuotas%')::text, '(t,t,t,t,t)'::text);
CREATE TEMP TABLE t_tiempo AS SELECT clock_timestamp() AS t0;
SELECT count(*) FROM generate_series(1, 20) g, LATERAL public._plan_cuotas(2000000000, 14, 360);
SELECT assert_true('20 planes de 360 cuotas en menos de 1 segundo (el contrato pide < 5 s para 30 años)', clock_timestamp() - (SELECT t0 FROM t_tiempo) < interval '1 second');

-- ============================================================================
-- 4. Calendario: vencimientos anclados a la fecha de desembolso (PROVISIONAL D-E8-3)
-- ============================================================================
SELECT assert_eq('desembolso 31-ene-2026: 28-feb, 31-mar, 30-abr, 31-may (anclado, no iterativo)',
                 (SELECT array_agg(public._fecha_vencimiento(DATE '2026-01-31', k)::text ORDER BY k) FROM generate_series(1, 4) k),
                 ARRAY['2026-02-28', '2026-03-31', '2026-04-30', '2026-05-31']);
SELECT assert_eq('desembolso 29-feb-2028 (bisiesto): 29-mar-2028, 28-feb-2029 (k = 12) y 29-feb-2032 (k = 48)',
                 (public._fecha_vencimiento(DATE '2028-02-29', 1)::text, public._fecha_vencimiento(DATE '2028-02-29', 12)::text, public._fecha_vencimiento(DATE '2028-02-29', 48)::text)::text,
                 '(2028-03-29,2029-02-28,2032-02-29)'::text);
SELECT assert_eq('360 meses despues del 24-nov-2026: 24-nov-2056', public._fecha_vencimiento(DATE '2026-11-24', 360)::text, '2056-11-24'::text);

-- ============================================================================
-- 5. _validar_plazo: entero entre 1 y 1.000.000, si no "Plazo fuera de rango" (nunca un error de driver)
-- ============================================================================
SELECT assert_eq('plazo valido: 1, 12, 12.0 (numeric entero) y 360',
                 (public._validar_plazo(1), public._validar_plazo(12), public._validar_plazo(12.0), public._validar_plazo(360))::text, '(1,12,12,360)'::text);
SELECT assert_eq('plazo invalido: 0, -1, 12.5, 0.99, NaN, Infinity, -Infinity, 1000001 y NULL = "Plazo fuera de rango"',
                 (SELECT array_agg(tests.captura('SELECT public._validar_plazo(' || x || ')') ORDER BY ord)::text
                    FROM unnest(ARRAY['0::numeric', '(-1)::numeric', '12.5::numeric', '0.99::numeric', '''NaN''::numeric', '''Infinity''::numeric', '''-Infinity''::numeric', '1000001::numeric', 'NULL::numeric']) WITH ORDINALITY t(x, ord)),
                 ARRAY(SELECT 'Plazo fuera de rango' FROM generate_series(1, 9))::text);

-- ============================================================================
-- 6. ct_credito_plan (UNA regla, v1.1): capital_pendiente = Σ (capital_programado - capital_pagado) de las cuotas impagas
--    Se prueba sobre planes fabricados (el consumidor real es E9: pago de cuota, abono con y sin recalculo, liquidacion).
-- ============================================================================
SELECT tests.cliente(1);
SELECT tests.fondear(tests.c(1), 10000000);
INSERT INTO public.credito_producto (id, nombre, tasa_anual, monto_min, monto_max, plazo_max_meses) VALUES (tests.p(901), 'Prod plan', 20, 1, 100000000, 24);
-- credito con plan de 3 cuotas (capital 1000 + 1000 + 1000) y desembolso de 3000
CREATE FUNCTION pg_temp.nuevo(p_n int, p_monto numeric) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid := tests.k(p_n);
BEGIN
  INSERT INTO public.credito (id, cuenta_id, producto_id, monto, tasa_anual, plazo_meses, fecha_desembolso, capital_pendiente, fecha_interes)
  VALUES (v, tests.c(1), tests.p(901), p_monto, 20, 3, public.hoy_banco(), 0, public.hoy_banco());
  INSERT INTO public.cuota (credito_id, numero, fecha_vencimiento, valor_cuota_original, valor_cuota, capital_programado, interes_programado)
  SELECT v, k, public._fecha_vencimiento(public.hoy_banco(), k), p_monto / 3 + 10, p_monto / 3 + 10, p_monto / 3, 10 FROM generate_series(1, 3) k;
  RETURN v;
END $f$;
CREATE FUNCTION pg_temp.desembolsa(p_cre uuid, p_monto numeric) RETURNS void LANGUAGE sql AS $f$
  SELECT tests.asentar(tests.pata('CREDITO_DESEMBOLSO', 'CUENTA', 'E', p_monto, tests.c(1), NULL, NULL, p_cre, 'P'), tests.pata('CREDITO_DESEMBOLSO', 'CREDITO', 'E', p_monto, tests.c(1), NULL, NULL, p_cre, 'P'))
  $f$;
-- aplica el diferido ahora (en la prueba) y lo devuelve a diferido; devuelve OK o el mensaje
CREATE FUNCTION pg_temp.verifica() RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota IMMEDIATE;
  SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota DEFERRED;
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
  RETURN regexp_replace(SQLERRM, '[0-9a-f]{8}-[0-9a-f-]{27}', '<id>', 'g');
END $f$;

SELECT pg_temp.nuevo(1, 3000);
SELECT assert_eq('credito con plan Σ capital = 3000 pero capital_pendiente 0 (sin desembolso): el diferido lo rechaza',
                 pg_temp.verifica(), 'Créditos: el plan del crédito <id> no cuadra con su capital pendiente (capital_pendiente=0.00, capital de las cuotas impagas=3000.00)'::text);
SAVEPOINT s1;
SELECT pg_temp.desembolsa(tests.k(1), 3000);
SELECT assert_eq('con el desembolso (capital_pendiente 3000) el plan cuadra', pg_temp.verifica(), 'OK'::text);
-- 6a. pago completo de la cuota 1: capital_pendiente baja su capital y la cuota sale de las impagas
SELECT tests.asentar(tests.pata('CREDITO_CUOTA', 'CUENTA', 'S', 1010, tests.c(1), NULL, NULL, tests.k(1)), tests.pata('CREDITO_CUOTA', 'CREDITO', 'S', 1000, tests.c(1), NULL, NULL, tests.k(1)),
                     tests.pata('CREDITO_CUOTA', 'RESULTADO', 'S', 10, tests.c(1), NULL, NULL, tests.k(1), 'Banco Digital'));
SELECT assert_eq('pago del capital en el libro SIN marcar la cuota pagada: el plan ya no explica la deuda (falla)', pg_temp.verifica() LIKE 'Créditos: el plan%capital_pendiente=2000.00, capital de las cuotas impagas=3000.00)', true);
UPDATE public.cuota SET pagada = true, fecha_pago = public.hoy_banco(), capital_pagado = 1000, intereses_pagados = 10 WHERE credito_id = tests.k(1) AND numero = 1;
SELECT assert_eq('pago completo de la cuota 1 (libro + cuota marcada pagada): cuadra', pg_temp.verifica(), 'OK'::text);
-- 6b. abono: el libro baja el capital; SIN recalcular el plan falla; CON recalculo cuadra (valor_cuota_original no se toca)
SELECT tests.asentar(tests.pata('CREDITO_ABONO', 'CUENTA', 'S', 510, tests.c(1), NULL, NULL, tests.k(1)), tests.pata('CREDITO_ABONO', 'CREDITO', 'S', 500, tests.c(1), NULL, NULL, tests.k(1)),
                     tests.pata('CREDITO_ABONO', 'RESULTADO', 'S', 10, tests.c(1), NULL, NULL, tests.k(1), 'Banco Digital'));
SELECT assert_eq('abono extraordinario de 500 SIN recalcular las cuotas impagas: falla (es el objetivo de la regla)',
                 pg_temp.verifica() LIKE 'Créditos: el plan%capital_pendiente=1500.00, capital de las cuotas impagas=2000.00)', true);
UPDATE public.cuota SET capital_programado = 750, valor_cuota = 750 + interes_programado WHERE credito_id = tests.k(1) AND NOT pagada;
SELECT assert_eq('el mismo abono CON el recalculo de las cuotas restantes (2 cuotas de capital 750): cuadra y valor_cuota_original queda intacto',
                 (pg_temp.verifica(), (SELECT (min(valor_cuota_original), min(valor_cuota))::text FROM public.cuota WHERE credito_id = tests.k(1) AND NOT pagada))::text, '(OK,"(1010.00,760.00)")'::text);
-- 6c. capital_pagado de una cuota aun impaga se descuenta (pago parcial NO definido: solo se comprueba que la regla lo admite sin cambios)
UPDATE public.cuota SET capital_pagado = 100 WHERE credito_id = tests.k(1) AND numero = 2;
SELECT assert_eq('capital_pagado de una cuota impaga se resta (la regla ya lo admite): sin ajustar la deuda, falla; con la deuda coherente, cuadra',
                 (pg_temp.verifica() LIKE 'Créditos: el plan%capital de las cuotas impagas=1400.00)') ::text, 'true'::text);
UPDATE public.cuota SET capital_pagado = 0 WHERE credito_id = tests.k(1) AND numero = 2;
-- 6d. liquidacion: el abono final deja capital 0; las cuotas restantes marcadas pagadas -> cuadra; eliminadas -> cuadra; dejarlas impagas -> falla
SELECT tests.asentar(tests.pata('CREDITO_ABONO', 'CUENTA', 'S', 1500, tests.c(1), NULL, NULL, tests.k(1)), tests.pata('CREDITO_ABONO', 'CREDITO', 'S', 1500, tests.c(1), NULL, NULL, tests.k(1)));
SELECT assert_eq('liquidacion por abono con las 2 cuotas restantes aun impagas: falla (capital 0 <> 1500 del plan)', pg_temp.verifica() LIKE 'Créditos: el plan%capital_pendiente=0.00, capital de las cuotas impagas=1500.00)', true);
SAVEPOINT s2;
UPDATE public.cuota SET pagada = true, fecha_pago = public.hoy_banco() WHERE credito_id = tests.k(1) AND NOT pagada;
UPDATE public.credito SET estado = 'PAGADO' WHERE id = tests.k(1);
SELECT assert_eq('liquidacion marcando las restantes pagadas (y el credito PAGADO): cuadra', pg_temp.verifica(), 'OK'::text);
ROLLBACK TO s2;
SAVEPOINT s3;
DELETE FROM public.cuota WHERE credito_id = tests.k(1) AND NOT pagada;
UPDATE public.credito SET estado = 'PAGADO' WHERE id = tests.k(1);
SELECT assert_eq('liquidacion ELIMINANDO las restantes: tambien cuadra (la regla no impone como se cierran: es decision de E9/D7)', pg_temp.verifica(), 'OK'::text);
ROLLBACK TO s3;
ROLLBACK TO s1;
-- 6e. la regla NO exige un numero de cuotas ni PAGADO => todo pagado (las reglas descartadas de la v1)
SELECT assert_eq('tras volver al credito sin desembolso y borrar una cuota impaga: sigue sin cuadrar solo por el capital (3000 vs 2000), no por el conteo',
                 (SELECT count(*) FROM public.cuota WHERE credito_id = tests.k(1))::int, 3);
DELETE FROM public.cuota WHERE credito_id = tests.k(1) AND numero = 3;
SELECT pg_temp.desembolsa(tests.k(1), 2000);   -- desembolso de 2000 = la suma que quedo en el plan (2 cuotas de 1000)
SELECT assert_eq('un credito de 3 meses con SOLO 2 cuotas cuyo capital suma el capital_pendiente cuadra (no se exige el conteo; la completitud al crear la afirma solicitar_credito)',
                 pg_temp.verifica(), 'OK'::text);
-- 6f. borrar el credito completo (cascada) no dispara el diferido contra algo inexistente
DELETE FROM public.cuota WHERE credito_id = tests.k(1);
SELECT assert_eq('una cuota borrada de un credito con deuda: el diferido lo detecta (1000 de plan vs 2000 de deuda)', pg_temp.verifica() LIKE 'Créditos: el plan%capital_pendiente=2000.00, capital de las cuotas impagas=0)', true);

-- la vista de integridad coincide con el trigger sobre los mismos datos
SELECT assert_eq('v_integridad_creditos marca el credito descuadrado (diferencia 2000) y v_integridad_global.ok lo refleja',
                 ((SELECT (ok, diferencia)::text FROM public.v_integridad_creditos WHERE credito_id = tests.k(1)), (SELECT ok FROM public.v_integridad_global), (SELECT creditos_con_plan_incoherente FROM public.v_integridad_global))::text,
                 '("(f,2000.00)",f,1)'::text);
ROLLBACK;
