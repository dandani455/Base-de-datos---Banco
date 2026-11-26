-- 59_creditos_aleatorio.test.sql · Etapa 8 · ~160 operaciones ALEATORIAS (solicitar credito de los 4 productos, simular, CDT, bolsillos, envios, lecturas y saltos de reloj)
-- sobre 6 clientes de distinta edad. Cada operacion termina en OK o en uno de los mensajes de negocio permitidos (nunca un error de CHECK, FK, unique o driver).
-- Al final: partida doble y conservacion (v_integridad_global), cada credito con su plan completo = capital pendiente = monto, el diferido ct_credito_plan evaluado
-- sobre TODO lo creado, y el dinero desembolsado = Σ montos. Una transaccion con ROLLBACK final; semilla fija (reproducible).
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 6) n;
SELECT count(tests.fondear(tests.c(n), 2000000 * n)) FROM generate_series(1, 6) n;
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses, tope_absoluto, multiplicador_balance, aplica_regla_edad) VALUES
  (tests.p(901), 'Libre inversión', '', 23.9, 1000000, 30000000, 6, 24, 30000000, NULL, false),
  (tests.p(902), 'Vehículo',        '', 18.9, 5000000, 200000000, 12, 120, NULL, NULL, false),
  (tests.p(903), 'Educación',       '', 15.4, 1000000, 100000000, 6, 240, NULL, NULL, false),
  (tests.p(904), 'Inmuebles',       '', 14.1, 1, 2000000000, 12, 360, 2000000000, 100, true);
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES (tests.p(950), 'CDT 30', 30, 9, 100000), (tests.p(951), 'CDT 90', 90, 10, 100000);
DO $f$ DECLARE n int; BEGIN FOR n IN 1..6 LOOP UPDATE public.usuario SET fecha_nacimiento = public.hoy_banco() - (interval '1 year' * (24 + n * 8)) - interval '37 days' WHERE id = tests.u(n); END LOOP; END $f$;

SELECT setseed(0.1124);
CREATE TEMP TABLE t_res (n int, op text, r text);
DO $do$
DECLARE
  i int; u int; u2 int; op int; r text; v_ok int := 0;
  prods int[] := ARRAY[901, 902, 903, 904];
  p int; monto numeric; plazo numeric; id1 uuid; bol text;
BEGIN
  FOR i IN 1..160 LOOP
    u := 1 + floor(random() * 6)::int;
    op := floor(random() * 100)::int;
    BEGIN
      IF op < 40 THEN                                              -- solicitar credito (montos y plazos que a veces no caben)
        p := prods[1 + floor(random() * 4)::int];
        monto := round((500000 + random() * 60000000)::numeric, 0);
        plazo := 1 + floor(random() * 400)::int;
        IF random() < 0.1 THEN plazo := plazo + 0.5; END IF;
        r := 'OK:' || (public.solicitar_credito(tests.u(u), tests.p(p)::text, monto, plazo) ->> 'id');
        INSERT INTO t_res VALUES (i, 'solicitar', 'OK');
      ELSIF op < 50 THEN                                           -- simular
        p := prods[1 + floor(random() * 4)::int];
        PERFORM public.simular_credito(tests.u(u), tests.p(p)::text, round((1000000 + random() * 50000000)::numeric, 0), 6 + floor(random() * 40)::int);
        INSERT INTO t_res VALUES (i, 'simular', 'OK');
      ELSIF op < 58 THEN                                           -- crear CDT
        PERFORM public.crear_cdt(tests.u(u), tests.p(950 + floor(random() * 2)::int)::text, round((100000 + random() * 3000000)::numeric, 0));
        INSERT INTO t_res VALUES (i, 'cdt', 'OK');
      ELSIF op < 66 THEN                                           -- bolsillo: crear y mover
        bol := (public.crear_bolsillo(tests.u(u), 'B' || i) ->> 'id');
        PERFORM public.mover_a_bolsillo(tests.u(u), bol, round((10000 + random() * 800000)::numeric, 0));
        INSERT INTO t_res VALUES (i, 'bolsillo', 'OK');
      ELSIF op < 76 THEN                                           -- envio entre clientes
        u2 := 1 + floor(random() * 6)::int;
        IF u2 = u THEN u2 := 1 + (u % 6); END IF;
        PERFORM public.hacer_transferencia(tests.u(u), (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(u2)), round((1000 + random() * 3000000)::numeric, 0), 'aleatorio', NULL);
        INSERT INTO t_res VALUES (i, 'envio', 'OK');
      ELSIF op < 88 THEN                                           -- lecturas
        PERFORM public.vista_creditos(tests.u(u)); PERFORM public.productos_disponibles(tests.u(u));
        INSERT INTO t_res VALUES (i, 'lectura', 'OK');
      ELSE                                                         -- salto de reloj de 0 a 40 dias
        PERFORM public._reloj_actualizar(false, (public.hoy_banco() + floor(random() * 41)::int)::text);
        INSERT INTO t_res VALUES (i, 'reloj', 'OK');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO t_res VALUES (i, CASE WHEN op < 40 THEN 'solicitar' WHEN op < 50 THEN 'simular' WHEN op < 58 THEN 'cdt' WHEN op < 66 THEN 'bolsillo' WHEN op < 76 THEN 'envio' ELSE 'otro' END, SQLERRM);
    END;
  END LOOP;
END $do$;

SELECT assert_eq('160 operaciones: TODAS terminan en OK o en un mensaje de negocio permitido (nunca CHECK, FK, unique, driver ni un error interno)',
                 (SELECT coalesce(string_agg(DISTINCT r, ' || '), '') FROM t_res
                   WHERE r <> 'OK' AND r NOT IN ('Monto fuera de rango', 'Plazo fuera de rango', 'Plazo excede el límite de edad', 'Ya tienes un crédito vigente de este producto',
                                                 'Saldo insuficiente', 'Monto por debajo del mínimo del CDT', 'Monto inválido', 'Nombre de bolsillo inválido')), ''::text);
SELECT assert_true('la corrida es significativa: al menos 8 creditos desembolsados, al menos 3 rechazos distintos de solicitar y al menos 3 productos distintos',
                   (SELECT count(*) >= 8 FROM public.credito) AND (SELECT count(DISTINCT r) >= 3 FROM t_res WHERE op = 'solicitar' AND r <> 'OK') AND (SELECT count(DISTINCT producto_id) >= 3 FROM public.credito));
SELECT assert_eq('cada credito tiene su plan completo (plazo_meses cuotas) con Σ capital_programado = monto = capital_pendiente, todo impago',
                 (SELECT count(*) FROM public.credito k WHERE (SELECT count(*) FROM public.cuota q WHERE q.credito_id = k.id) <> k.plazo_meses
                         OR (SELECT sum(capital_programado) FROM public.cuota q WHERE q.credito_id = k.id) <> k.monto OR k.capital_pendiente <> k.monto
                         OR EXISTS (SELECT 1 FROM public.cuota q WHERE q.credito_id = k.id AND q.pagada)), 0::bigint);
SELECT assert_eq('Σ de los desembolsos del libro = Σ monto de los creditos = Σ capital_pendiente (dinero que entra = deuda que nace)',
                 (SELECT (sum(t.monto) FILTER (WHERE t.contenedor = 'CUENTA'), sum(t.monto) FILTER (WHERE t.contenedor = 'CREDITO'))::text FROM public.transaccion t WHERE t.tipo = 'CREDITO_DESEMBOLSO'),
                 (SELECT (sum(monto), sum(capital_pendiente))::text FROM public.credito));
SELECT assert_eq('a lo sumo UN credito ACTIVO por producto y cuenta (el indice y la funcion coinciden)',
                 (SELECT count(*) FROM (SELECT cuenta_id, producto_id FROM public.credito WHERE estado = 'ACTIVO' GROUP BY 1, 2 HAVING count(*) > 1) q), 0::bigint);
SELECT assert_eq('ningun credito supera su tope: monto <= monto_max del producto y plazo <= plazo_max; Inmuebles con edad + plazo (anios) <= 70 al momento de pedirlo',
                 (SELECT count(*) FROM public.credito k JOIN public.credito_producto p ON p.id = k.producto_id
                   WHERE k.monto > p.monto_max OR k.monto < p.monto_min OR k.plazo_meses > p.plazo_max_meses OR k.plazo_meses < p.plazo_min_meses
                      OR (p.aplica_regla_edad AND date_part('year', age(k.fecha_desembolso, (SELECT fecha_nacimiento FROM public.usuario WHERE id = (SELECT usuario_id FROM public.cuenta WHERE id = k.cuenta_id)))) * 12 + k.plazo_meses > 70 * 12)), 0::bigint);
SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota IMMEDIATE;
SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota DEFERRED;
SELECT assert_eq('el diferido ct_credito_plan evaluado sobre TODO lo creado no objeta nada (si llegamos aqui, paso)', 'ok'::text, 'ok'::text);
SELECT assert_eq('estado global: partida doble, I5u por cuenta, conservacion entre clientes, defensas y planes en orden',
                 (SELECT (ok, contenedores_con_desvio, grupos_con_error, cuentas_con_desvio_i5u, defensas_fallidas, desvio_transferencias, creditos_con_plan_incoherente)::text FROM public.v_integridad_global),
                 '(t,0,0,0,0,0.00,0)'::text);
ROLLBACK;
