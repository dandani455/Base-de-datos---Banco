-- 34_reloj_retorno_simulacion.test.sql · Etapa 3 · CONSECUENCIAS de volver a fecha real despues de una simulacion (D4 = A).
-- La simulacion NO es reversible en terminos contables: solo cambia la fecha del banco. Se comprueba, con un cobro NEUTRO de prueba
-- (tests.cobro_simulado: 1 peso por dia; NO es ninguna formula de interes) apoyado en las reglas puras de E3 (_dias_por_cobrar, _cuota_vencida):
--   1. las transacciones hechas durante la simulacion permanecen (no se eliminan, revierten ni recalculan);
--   2. saldos, acumuladores, ultimo_cobro y la mora registrada se conservan; ultimo_cobro NO retrocede;
--   3. con hoy <= ultimo_cobro no se genera ningun movimiento (sin rangos negativos ni recobros);
--   4. al adelantar otra vez solo se cobra lo NO cobrado (sin duplicados);
--   5. las cuotas vencidas se calculan al consultar (fecha < hoy y no pagada), sin bandera guardada.
-- Una sola transaccion con ROLLBACK final.
BEGIN;

CREATE TEMP TABLE t_r AS SELECT (now() AT TIME ZONE 'America/Bogota')::date AS r;
CREATE FUNCTION pg_temp.d(p_n int) RETURNS date LANGUAGE sql STABLE AS $$ SELECT r + p_n FROM t_r $$;
CREATE FUNCTION pg_temp.t(p_n int) RETURNS text LANGUAGE sql STABLE AS $$ SELECT to_char(r + p_n, 'YYYY-MM-DD') FROM t_r $$;
-- huellas
CREATE FUNCTION pg_temp.h_libro() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT md5(coalesce(string_agg(to_jsonb(t)::text, '|' ORDER BY t.orden), '')) FROM public.transaccion t $$;
CREATE FUNCTION pg_temp.h_libro_hasta(p_orden bigint) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT md5(coalesce(string_agg(to_jsonb(t)::text, '|' ORDER BY t.orden), '')) FROM public.transaccion t WHERE t.orden <= p_orden $$;
CREATE FUNCTION pg_temp.h_prod() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT md5((SELECT coalesce(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id), '') FROM public.cuenta x)   || '#' ||
             (SELECT coalesce(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id), '') FROM public.bolsillo x) || '#' ||
             (SELECT coalesce(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id), '') FROM public.cdt x)      || '#' ||
             (SELECT coalesce(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id), '') FROM public.credito x)  || '#' ||
             (SELECT coalesce(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id), '') FROM public.cuota x)) $$;
CREATE FUNCTION pg_temp.vencidas() RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT count(*) FROM public.cuota c WHERE public._cuota_vencida(c.fecha_vencimiento, c.pagada, public.hoy_banco()) $$;
CREATE FUNCTION pg_temp.dias_cobrados() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT (count(*), count(DISTINCT (fecha AT TIME ZONE 'America/Bogota')::date))::text FROM public.transaccion WHERE tipo = 'INTERES_BOLSO' AND contenedor = 'BOLSILLO' $$;

-- ============================================================================
-- Escenario: un cliente con bolsillo, CDT, credito con 3 cuotas y una mora registrada
-- ============================================================================
SELECT tests.cliente(1);
SELECT tests.fondear(tests.c(1), 10000);
SELECT tests.bolsillo(1, tests.c(1));
SELECT tests.asentar(tests.pata('BOLSO_INGRESO','CUENTA','S',1000,tests.c(1),tests.b(1)), tests.pata('BOLSO_INGRESO','BOLSILLO','E',1000,tests.c(1),tests.b(1)));
SELECT tests.cdt(1, tests.c(1), 2000);
SELECT tests.asentar(tests.pata('CDT_CREACION','CUENTA','S',2000,tests.c(1),NULL,tests.d(1)), tests.pata('CDT_CREACION','CDT','E',2000,tests.c(1),NULL,tests.d(1)));
SELECT tests.credito(1, tests.c(1), 5000);
SELECT tests.asentar(tests.pata('CREDITO_DESEMBOLSO','CUENTA','E',5000,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_DESEMBOLSO','CREDITO','E',5000,tests.c(1),NULL,NULL,tests.k(1)));
UPDATE public.bolsillo SET ultimo_cobro = (SELECT r FROM t_r) WHERE id = tests.b(1);
UPDATE public.cdt SET ultimo_cobro = (SELECT r FROM t_r) WHERE id = tests.d(1);
UPDATE public.credito SET fecha_interes = (SELECT r FROM t_r) WHERE id = tests.k(1);
INSERT INTO public.cuota (credito_id, numero, fecha_vencimiento, valor_cuota_original, valor_cuota, capital_programado, interes_programado, pagada, fecha_pago) VALUES
  (tests.k(1), 1, pg_temp.d(15), 500, 500, 450, 50, false, NULL),
  (tests.k(1), 2, pg_temp.d(45), 500, 500, 450, 50, true,  pg_temp.d(0)),         -- pagada: nunca vencida
  (tests.k(1), 3, pg_temp.d(75), 500, 500, 450, 50, false, NULL);

SELECT assert_eq('punto de partida: modo real, hoy = fecha real, bolsillo 1000, ultimo_cobro = hoy',
                 (SELECT (usar_fecha_real, public.hoy_banco() = r, (SELECT balance::numeric FROM public.bolsillo), (SELECT ultimo_cobro = r FROM public.bolsillo))::text FROM public.reloj, t_r), '(t,t,1000.00,t)'::text);
SELECT assert_eq('hoy ninguna cuota esta vencida (la primera vence en R+15)', pg_temp.vencidas(), 0::bigint);
SELECT assert_eq('cobro de prueba en modo real con ultimo_cobro = hoy: no hay nada que cobrar', tests.cobro_simulado(tests.b(1)), 0);

-- ============================================================================
-- A. Simulacion: adelantar +60 y cobrar
-- ============================================================================
SELECT assert_eq('adelantar el reloj a R+60', public._reloj_actualizar(false, pg_temp.t(60)) ->> 'fecha_actual', pg_temp.t(60));
SELECT assert_eq('el cobro de prueba procesa exactamente los 60 dias (R+1 .. R+60)', tests.cobro_simulado(tests.b(1)), 60);
SELECT assert_eq('60 dias cobrados, todos distintos (R+1..R+60)', (SELECT (pg_temp.dias_cobrados(), (SELECT min((fecha AT TIME ZONE 'America/Bogota')::date) FROM public.transaccion WHERE tipo = 'INTERES_BOLSO') = pg_temp.d(1),
                                                                        (SELECT max((fecha AT TIME ZONE 'America/Bogota')::date) FROM public.transaccion WHERE tipo = 'INTERES_BOLSO') = pg_temp.d(60))::text), '("(60,60)",t,t)'::text);
SELECT assert_eq('ultimo_cobro del bolsillo avanzo a R+60 y el saldo a 1060', (SELECT (ultimo_cobro = pg_temp.d(60), balance::numeric)::text FROM public.bolsillo), '(t,1060.00)'::text);
SELECT assert_eq('con el reloj en R+60 la cuota 1 (R+15) esta vencida; la 2 (pagada) y la 3 (R+75) no', pg_temp.vencidas(), 1::bigint);
UPDATE public.credito SET mora_acumulada = 5 WHERE id = tests.k(1);         -- la mora que el banco ya acumulo y registro durante la simulacion

CREATE TEMP TABLE t_s AS SELECT pg_temp.h_libro() AS libro, pg_temp.h_prod() AS prod, (SELECT max(orden) FROM public.transaccion) AS max_orden,
                                (SELECT ultimo_cobro FROM public.bolsillo) AS ult_b, (SELECT ultimo_cobro FROM public.cdt) AS ult_c, (SELECT fecha_interes FROM public.credito) AS ult_k,
                                (SELECT balance::numeric FROM public.cuenta) AS cuenta, (SELECT balance::numeric FROM public.bolsillo) AS bolsillo,
                                (SELECT capital_pendiente::numeric FROM public.credito) AS capital, (SELECT generado_acumulado::numeric FROM public.cdt) AS generado,
                                (SELECT mora_acumulada::numeric FROM public.credito) AS mora, (SELECT count(*) FROM public.transaccion) AS patas;

-- ============================================================================
-- B. Volver a fecha real: nada del historial ni de los productos cambia
-- ============================================================================
SELECT assert_eq('volver a fecha real (permitido aunque retroceda de R+60 a R)', public._reloj_actualizar(true, '') ->> 'fecha_actual', pg_temp.t(0));
SELECT assert_eq('hoy_banco() = fecha real de Colombia y no queda ningun desfase ni fecha guardada', (SELECT (public.hoy_banco() = r, usar_fecha_real, fecha_sistema IS NULL)::text FROM public.reloj, t_r), '(t,t,t)'::text);
SELECT assert_eq('1) TODAS las transacciones de la simulacion permanecen y NO se modificaron (huella del libro completo identica)', pg_temp.h_libro() = (SELECT libro FROM t_s), true);
SELECT assert_eq('   no se elimino ni se agrego ninguna pata', (SELECT count(*) FROM public.transaccion) = (SELECT patas FROM t_s), true);
SELECT assert_eq('2) cuentas, bolsillos, CDT, creditos y cuotas intactos (huella de todas las filas identica)', pg_temp.h_prod() = (SELECT prod FROM t_s), true);
SELECT assert_eq('   saldos y acumuladores conservados (cuenta, bolsillo, capital pendiente, CDT generado)',
                 (SELECT ((SELECT balance::numeric FROM public.cuenta) = cuenta, (SELECT balance::numeric FROM public.bolsillo) = bolsillo,
                          (SELECT capital_pendiente::numeric FROM public.credito) = capital, (SELECT generado_acumulado::numeric FROM public.cdt) = generado)::text FROM t_s), '(t,t,t,t)'::text);
SELECT assert_eq('   ultimo_cobro NO retrocede: bolsillo, CDT y credito conservan su fecha (el del bolsillo sigue en R+60 > hoy)',
                 (SELECT ((SELECT ultimo_cobro FROM public.bolsillo) = ult_b, (SELECT ultimo_cobro FROM public.cdt) = ult_c, (SELECT fecha_interes FROM public.credito) = ult_k,
                          (SELECT ultimo_cobro FROM public.bolsillo) > public.hoy_banco())::text FROM t_s), '(t,t,t,t)'::text);
SELECT assert_eq('5) la mora ya acumulada y registrada se CONSERVA (5.00) aunque la cuota deje de verse vencida', (SELECT mora_acumulada::numeric FROM public.credito), 5::numeric);
SELECT assert_eq('4) las cuotas vencidas se calculan al consultar: con el hoy real ya no hay ninguna (no quedo bandera obsoleta)', pg_temp.vencidas(), 0::bigint);
SELECT assert_eq('   ...porque no se guarda ninguna bandera de vencimiento en el esquema', (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name IN ('cuota', 'credito') AND column_name ~ 'vencid'), 0::bigint);
SELECT assert_eq('   la cuota 1 sigue sin pagar y con su fecha original (solo cambia como se interpreta contra hoy)', (SELECT (pagada, fecha_vencimiento = pg_temp.d(15))::text FROM public.cuota WHERE numero = 1), '(f,t)'::text);
SELECT assert_eq('las operaciones historicas quedan "en el futuro" del reloj actual y v_reloj_estado lo informa (60 dias x 2 patas = 120)', (SELECT patas_fechadas_en_el_futuro FROM public.v_reloj_estado), 120::bigint);
SELECT assert_true('...pero eso NO es un error: v_integridad_global.ok = true', tests.ok_sin_plan());
SELECT assert_eq('   I1: cada saldo coincide con la suma de sus patas', (SELECT count(*) FROM public.v_integridad_saldos WHERE NOT ok), 0::bigint);
SELECT assert_eq('3) sin movimientos con rangos negativos: con hoy < ultimo_cobro el rango por cobrar esta VACIO', (SELECT count(*) FROM public._dias_por_cobrar((SELECT ultimo_cobro FROM public.bolsillo), public.hoy_banco())), 0::bigint);
SELECT assert_eq('   el cobro de prueba con el hoy real (R < ultimo_cobro R+60) no hace NADA', tests.cobro_simulado(tests.b(1)), 0);
SELECT assert_eq('   ...y deja el libro y los productos exactamente igual', (pg_temp.h_libro() = (SELECT libro FROM t_s), pg_temp.h_prod() = (SELECT prod FROM t_s))::text, '(t,t)'::text);

-- ============================================================================
-- C. Adelantar de nuevo: nada se cobra dos veces
-- ============================================================================
SELECT assert_ok('adelantar a R+30 (anterior al ultimo_cobro R+60)', $$SELECT public._reloj_actualizar(false, pg_temp.t(30))$$);
SELECT assert_eq('6) con la nueva fecha <= ultimo_cobro NO se genera ningun cobro', tests.cobro_simulado(tests.b(1)), 0);
SELECT assert_eq('   libro y productos identicos', (pg_temp.h_libro() = (SELECT libro FROM t_s), pg_temp.h_prod() = (SELECT prod FROM t_s))::text, '(t,t)'::text);
SELECT assert_eq('   la cuota 1 (R+15 < R+30) vuelve a calcularse vencida (dinamico) y la mora registrada sigue en 5', (pg_temp.vencidas(), (SELECT mora_acumulada::numeric FROM public.credito))::text, '(1,5.00)'::text);
SELECT assert_ok('adelantar a R+60 exacto (= ultimo_cobro)', $$SELECT public._reloj_actualizar(false, pg_temp.t(60))$$);
SELECT assert_eq('   hoy = ultimo_cobro: tampoco se cobra nada', tests.cobro_simulado(tests.b(1)), 0);
SELECT assert_ok('adelantar a R+70', $$SELECT public._reloj_actualizar(false, pg_temp.t(70))$$);
SELECT assert_eq('   solo se cobran los 10 dias NUEVOS (R+61 .. R+70)', tests.cobro_simulado(tests.b(1)), 10);
SELECT assert_eq('   70 dias cobrados en total, todos distintos: NINGUN dia duplicado', pg_temp.dias_cobrados(), '(70,70)'::text);
SELECT assert_eq('   lo anterior no se toco: las patas de la primera simulacion siguen identicas (huella del prefijo del libro)', pg_temp.h_libro_hasta((SELECT max_orden FROM t_s)) = (SELECT libro FROM t_s), true);
SELECT assert_eq('   ultimo_cobro = R+70 y el saldo del bolsillo 1070', (SELECT (ultimo_cobro = pg_temp.d(70), balance::numeric)::text FROM public.bolsillo), '(t,1070.00)'::text);

-- ============================================================================
-- D. Ciclos repetidos: adelantar, cobrar, volver a real, cobrar (0)
-- ============================================================================
DO $$
DECLARE
  i int; v_off int := 70; v_ult date; v_ult_ant date; v_n int; v_mal int := 0; v_prefijo text; v_max bigint; v_h text;
  v_r date := (SELECT r FROM t_r);
BEGIN
  PERFORM setseed(0.34);
  FOR i IN 1..8 LOOP
    SELECT max(orden) INTO v_max FROM public.transaccion;
    SELECT md5(coalesce(string_agg(to_jsonb(t)::text, '|' ORDER BY t.orden), '')) INTO v_prefijo FROM public.transaccion t;
    SELECT ultimo_cobro INTO v_ult_ant FROM public.bolsillo;
    -- adelantar entre 1 y 90 dias mas
    v_off := v_off + 1 + floor(random() * 90)::int;
    PERFORM public._reloj_actualizar(false, to_char(v_r + v_off, 'YYYY-MM-DD'));
    v_n := tests.cobro_simulado(tests.b(1));
    IF v_n <> (v_off - (v_ult_ant - v_r)) THEN v_mal := v_mal + 1; END IF;               -- solo los dias nuevos
    -- volver a fecha real: nada cambia y el cobro no hace nada
    PERFORM public._reloj_actualizar(true, '');
    IF tests.cobro_simulado(tests.b(1)) <> 0 THEN v_mal := v_mal + 1; END IF;
    SELECT ultimo_cobro INTO v_ult FROM public.bolsillo;
    IF v_ult < v_ult_ant OR v_ult <> v_r + v_off THEN v_mal := v_mal + 1; END IF;         -- ultimo_cobro avanzo y NO retrocede
    -- el prefijo del libro anterior sigue identico
    SELECT md5(coalesce(string_agg(to_jsonb(t)::text, '|' ORDER BY t.orden), '')) INTO v_h FROM public.transaccion t WHERE t.orden <= v_max;
    IF v_h <> v_prefijo THEN v_mal := v_mal + 1; END IF;
    -- nunca un dia cobrado dos veces
    IF (SELECT count(*) <> count(DISTINCT (fecha AT TIME ZONE 'America/Bogota')::date) FROM public.transaccion WHERE tipo = 'INTERES_BOLSO' AND contenedor = 'BOLSILLO') THEN v_mal := v_mal + 1; END IF;
  END LOOP;
  PERFORM tests.assert_eq('8 ciclos (adelantar + cobrar + volver a real + cobrar): solo dias nuevos, ultimo_cobro nunca retrocede, historial intacto, ningun cobro duplicado', v_mal, 0);
  PERFORM tests.assert_eq('...y el bolsillo suma 1 peso por cada dia cobrado (1000 + dias)', (SELECT balance::numeric FROM public.bolsillo), 1000 + (SELECT count(*) FROM public.transaccion WHERE tipo = 'INTERES_BOLSO' AND contenedor = 'BOLSILLO')::numeric);
END $$;
SELECT assert_eq('al final: modo real y cobrado hasta mucho mas alla del hoy real', (SELECT (usar_fecha_real, ultimo_cobro > public.hoy_banco() + 100)::text FROM public.reloj, public.bolsillo), '(t,t)'::text);
SELECT assert_true('v_integridad_global.ok tras todos los ciclos', tests.ok_sin_plan());
SELECT assert_eq('...con I1, I3 e I5u en orden (0 desvios, 0 grupos con error)', (SELECT (contenedores_con_desvio, grupos_con_error, cuentas_con_desvio_i5u)::text FROM public.v_integridad_global), '(0,0,0)'::text);
SELECT assert_true('cada salida de la simulacion quedo auditada (RELOJ_CAMBIO) con el estado antes y despues', (SELECT count(*) FILTER (WHERE (antes ->> 'usar_fecha_real')::boolean = false AND (despues ->> 'usar_fecha_real')::boolean) >= 9 FROM audit.evento WHERE accion = 'RELOJ_CAMBIO'));

ROLLBACK;
