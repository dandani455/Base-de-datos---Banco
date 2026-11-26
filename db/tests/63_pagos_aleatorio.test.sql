-- 63_pagos_aleatorio.test.sql · Etapa 9 · ~200 operaciones ALEATORIAS (solicitar, pagar cuota, abonar, activar/desactivar el descuento, CDT, bolsillos, envios, lecturas y saltos de reloj)
-- sobre 6 clientes. Cada operacion termina en OK o en un mensaje de negocio permitido (nunca CHECK, FK, unique ni un error interno). Al final: partida doble y conservacion
-- (v_integridad_global con planes), cada credito con su plazo intacto, ningun pago doble (un grupo CREDITO_CUOTA por cuota pagada), capital = Σ impago, y los cursores coherentes.
-- Una transaccion con ROLLBACK final; semilla fija (reproducible); solo en banco_test/banco_mut (mueve el reloj).
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 6) n;
SELECT count(tests.fondear(tests.c(n), 3000000 * n)) FROM generate_series(1, 6) n;
UPDATE public.parametro SET tasa_mora_anual = 30;
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES
  (tests.p(901), 'Libre', '', 23.9, 1000000, 30000000, 6, 24), (tests.p(902), 'Vehiculo', '', 18.9, 5000000, 200000000, 12, 120), (tests.p(903), 'Educacion', '', 15.4, 1000000, 100000000, 6, 60);
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES (tests.p(950), 'CDT 30', 30, 9, 100000), (tests.p(951), 'CDT 90', 90, 10, 100000);

SELECT setseed(0.20261126);
CREATE TEMP TABLE t_res (n int, op text, r text);
CREATE TEMP TABLE t_cred (k uuid, usr int);
DO $do$
DECLARE
  i int; u int; u2 int; op int; r text; p int; k uuid; monto numeric; bol text; ks uuid[];
BEGIN
  FOR i IN 1..200 LOOP
    u := 1 + floor(random() * 6)::int;
    op := floor(random() * 100)::int;
    BEGIN
      IF op < 14 THEN
        p := 901 + floor(random() * 3)::int;
        r := public.solicitar_credito(tests.u(u), tests.p(p)::text, round((1000000 + random() * 12000000)::numeric, 0), 6 + floor(random() * 18)::int) ->> 'id';
        INSERT INTO t_cred VALUES (r::uuid, u); INSERT INTO t_res VALUES (i, 'solicitar', 'OK');
      ELSIF op < 40 THEN                                            -- pagar la proxima cuota de un credito del usuario (a veces con numero, a veces con uno erroneo)
        SELECT array_agg(c.k) INTO ks FROM t_cred c WHERE c.usr = u;
        k := coalesce(ks[1 + floor(random() * greatest(coalesce(array_length(ks, 1), 1), 1))::int], gen_random_uuid());
        PERFORM public.pagar_cuota(tests.u(u), k::text, CASE WHEN random() < 0.3 THEN 1 + floor(random() * 3)::int END);
        INSERT INTO t_res VALUES (i, 'pagar', 'OK');
      ELSIF op < 58 THEN                                            -- abonar
        SELECT array_agg(c.k) INTO ks FROM t_cred c WHERE c.usr = u;
        k := coalesce(ks[1 + floor(random() * greatest(coalesce(array_length(ks, 1), 1), 1))::int], gen_random_uuid());
        PERFORM public.abonar_credito(tests.u(u), k::text, round((1000 + random() * 4000000)::numeric, 0));
        INSERT INTO t_res VALUES (i, 'abonar', 'OK');
      ELSIF op < 66 THEN                                            -- activar o desactivar el descuento
        SELECT array_agg(c.k) INTO ks FROM t_cred c WHERE c.usr = u;
        k := coalesce(ks[1 + floor(random() * greatest(coalesce(array_length(ks, 1), 1), 1))::int], gen_random_uuid());
        PERFORM public.activar_descuento_automatico(tests.u(u), k::text, random() < 0.7);
        INSERT INTO t_res VALUES (i, 'descuento', 'OK');
      ELSIF op < 72 THEN
        PERFORM public.crear_cdt(tests.u(u), tests.p(950 + floor(random() * 2)::int)::text, round((100000 + random() * 2000000)::numeric, 0));
        INSERT INTO t_res VALUES (i, 'cdt', 'OK');
      ELSIF op < 78 THEN
        bol := (public.crear_bolsillo(tests.u(u), 'B' || i) ->> 'id');
        PERFORM public.mover_a_bolsillo(tests.u(u), bol, round((10000 + random() * 800000)::numeric, 0));
        INSERT INTO t_res VALUES (i, 'bolsillo', 'OK');
      ELSIF op < 85 THEN
        u2 := 1 + floor(random() * 6)::int;
        IF u2 = u THEN u2 := 1 + (u % 6); END IF;
        PERFORM public.hacer_transferencia(tests.u(u), (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(u2)), round((1000 + random() * 3000000)::numeric, 0), 'aleatorio', NULL);
        INSERT INTO t_res VALUES (i, 'envio', 'OK');
      ELSIF op < 92 THEN
        PERFORM public.vista_creditos(tests.u(u)); PERFORM public.productos_disponibles(tests.u(u));
        INSERT INTO t_res VALUES (i, 'lectura', 'OK');
      ELSIF op < 97 THEN                                             -- salto de reloj de 0 a 45 dias
        PERFORM public._reloj_actualizar(false, (public.hoy_banco() + floor(random() * 46)::int)::text);
        INSERT INTO t_res VALUES (i, 'reloj', 'OK');
      ELSE                                                           -- de vuelta a real (el motor se pausa si hoy queda por detras de un cursor)
        PERFORM public._reloj_actualizar(true, '');
        INSERT INTO t_res VALUES (i, 'real', 'OK');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO t_res VALUES (i, CASE WHEN op < 14 THEN 'solicitar' WHEN op < 40 THEN 'pagar' WHEN op < 58 THEN 'abonar' WHEN op < 66 THEN 'descuento' WHEN op < 72 THEN 'cdt' WHEN op < 78 THEN 'bolsillo' WHEN op < 85 THEN 'envio' ELSE 'otro' END, SQLERRM);
    END;
  END LOOP;
END $do$;

SELECT assert_eq('200 operaciones: TODAS terminan en OK o en un mensaje de negocio permitido (nunca CHECK, FK, unique, driver ni un error interno)',
                 (SELECT coalesce(string_agg(DISTINCT r, ' || '), '') FROM t_res
                   WHERE r <> 'OK' AND r NOT IN ('Monto fuera de rango', 'Plazo fuera de rango', 'Plazo excede el límite de edad', 'Ya tienes un crédito vigente de este producto', 'Recurso no encontrado',
                                                 'Saldo insuficiente', 'Monto por debajo del mínimo del CDT', 'Monto inválido', 'Nombre de bolsillo inválido')), ''::text);
SELECT assert_true('la corrida es significativa: al menos 10 creditos, 10 cuotas pagadas, 3 abonos y varios rechazos distintos',
                   (SELECT count(*) >= 10 FROM public.credito) AND (SELECT count(DISTINCT grupo_id) >= 10 FROM public.transaccion WHERE tipo = 'CREDITO_CUOTA')
                   AND (SELECT count(DISTINCT grupo_id) >= 3 FROM public.transaccion WHERE tipo = 'CREDITO_ABONO') AND (SELECT count(DISTINCT r) >= 3 FROM t_res WHERE r <> 'OK'));
SELECT assert_eq('cada credito conserva su PLAZO: tantas cuotas como plazo_meses y los mismos numeros 1..n (los abonos y los pagos no cambian el plazo)',
                 (SELECT count(*) FROM public.credito k WHERE (SELECT count(*) FROM public.cuota q WHERE q.credito_id = k.id) <> k.plazo_meses
                         OR (SELECT max(numero) FROM public.cuota q WHERE q.credito_id = k.id) <> k.plazo_meses), 0::bigint);
SELECT assert_eq('capital_pendiente = Σ (capital_programado - capital_pagado) de las cuotas impagas en CADA credito (ct_credito_plan), y PAGADO = capital 0 sin cuotas impagas',
                 (SELECT count(*) FROM public.credito k WHERE k.capital_pendiente <> coalesce((SELECT sum(q.capital_programado - q.capital_pagado) FROM public.cuota q WHERE q.credito_id = k.id AND NOT q.pagada), 0)
                         OR (k.estado = 'PAGADO' AND (k.capital_pendiente <> 0 OR EXISTS (SELECT 1 FROM public.cuota q WHERE q.credito_id = k.id AND NOT q.pagada)))), 0::bigint);
SELECT assert_eq('ningun PAGO DOBLE: por cada credito, un grupo CREDITO_CUOTA por cuota pagada con capital_pagado > 0 (las liquidadas por abono no tienen grupo)',
                 (SELECT count(*) FROM public.credito k WHERE (SELECT count(*) FROM public.cuota q WHERE q.credito_id = k.id AND q.pagada AND q.capital_pagado > 0)
                                                           <> (SELECT count(DISTINCT t.grupo_id) FROM public.transaccion t WHERE t.credito_id = k.id AND t.tipo = 'CREDITO_CUOTA')), 0::bigint);
SELECT assert_eq('los cursores son coherentes: descuento_automatico = (cobro_hasta IS NOT NULL) en todos los creditos y ninguna cuota pagada tiene fecha_pago NULL',
                 (SELECT count(*) FROM public.credito k WHERE k.descuento_automatico <> (k.cobro_hasta IS NOT NULL)) + (SELECT count(*) FROM public.cuota q WHERE q.pagada AND q.fecha_pago IS NULL), 0::bigint);
SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota IMMEDIATE;
SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota DEFERRED;
SELECT assert_eq('el diferido ct_credito_plan evaluado sobre TODO lo creado no objeta nada (si llegamos aqui, paso)', 'ok'::text, 'ok'::text);
SELECT assert_eq('estado global: partida doble, I5u por cuenta, conservacion entre clientes, defensas y planes en orden',
                 (SELECT (ok, contenedores_con_desvio, grupos_con_error, cuentas_con_desvio_i5u, defensas_fallidas, desvio_transferencias, creditos_con_plan_incoherente, grupos_credito_sin_plantilla)::text FROM public.v_integridad_global),
                 '(t,0,0,0,0,0.00,0,0)'::text);
ROLLBACK;
