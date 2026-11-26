-- 66_vistas_aleatorio.test.sql · Etapa 10 · ~140 operaciones ALEATORIAS (envios, bolsillos, CDT, creditos, pagos, abonos, descuento, lecturas y saltos de reloj) sobre 5 clientes; al final, para CADA
-- cliente, el historial y el dashboard se comparan con un ORACULO independiente (DISTINCT ON por grupo con prioridad CUENTA > BOLSILLO > CDT, en vez del NOT EXISTS de la vista).
-- Una transaccion con ROLLBACK final; semilla fija (reproducible); solo en banco_test/banco_mut (mueve el reloj).
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 5) n;
SELECT count(tests.fondear(tests.c(n), 4000000 * n)) FROM generate_series(1, 5) n;
UPDATE public.parametro SET tasa_mora_anual = 30;
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES
  (tests.p(901), 'Libre', '', 23.9, 1000000, 30000000, 6, 24), (tests.p(902), 'Vehiculo', '', 18.9, 5000000, 200000000, 12, 120);
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES (tests.p(950), 'CDT 30', 30, 9, 100000), (tests.p(951), 'CDT 90', 90, 10, 100000);
SELECT setseed(0.20261127);
CREATE TEMP TABLE t_res (n int, op text, r text);
CREATE TEMP TABLE t_cred (k uuid, usr int);
DO $do$
DECLARE
  i int; u int; u2 int; op int; r text; p int; k uuid; bol text; ks uuid[];
BEGIN
  FOR i IN 1..140 LOOP
    u := 1 + floor(random() * 5)::int;
    op := floor(random() * 100)::int;
    BEGIN
      IF op < 12 THEN
        p := 901 + floor(random() * 2)::int;
        r := public.solicitar_credito(tests.u(u), tests.p(p)::text, round((5000000 + random() * 9000000)::numeric, 0), 12 + floor(random() * 12)::int) ->> 'id';
        INSERT INTO t_cred VALUES (r::uuid, u); INSERT INTO t_res VALUES (i, 'solicitar', 'OK');
      ELSIF op < 26 THEN
        SELECT array_agg(c.k) INTO ks FROM t_cred c WHERE c.usr = u;
        k := coalesce(ks[1 + floor(random() * greatest(coalesce(array_length(ks, 1), 1), 1))::int], gen_random_uuid());
        PERFORM public.pagar_cuota(tests.u(u), k::text, NULL); INSERT INTO t_res VALUES (i, 'pagar', 'OK');
      ELSIF op < 34 THEN
        SELECT array_agg(c.k) INTO ks FROM t_cred c WHERE c.usr = u;
        k := coalesce(ks[1 + floor(random() * greatest(coalesce(array_length(ks, 1), 1), 1))::int], gen_random_uuid());
        PERFORM public.abonar_credito(tests.u(u), k::text, round((1000 + random() * 3000000)::numeric, 0)); INSERT INTO t_res VALUES (i, 'abonar', 'OK');
      ELSIF op < 40 THEN
        SELECT array_agg(c.k) INTO ks FROM t_cred c WHERE c.usr = u;
        k := coalesce(ks[1 + floor(random() * greatest(coalesce(array_length(ks, 1), 1), 1))::int], gen_random_uuid());
        PERFORM public.activar_descuento_automatico(tests.u(u), k::text, random() < 0.7); INSERT INTO t_res VALUES (i, 'descuento', 'OK');
      ELSIF op < 48 THEN
        PERFORM public.crear_cdt(tests.u(u), tests.p(950 + floor(random() * 2)::int)::text, round((100000 + random() * 1500000)::numeric, 0)); INSERT INTO t_res VALUES (i, 'cdt', 'OK');
      ELSIF op < 58 THEN
        bol := (public.crear_bolsillo(tests.u(u), 'B' || i) ->> 'id');
        PERFORM public.mover_a_bolsillo(tests.u(u), bol, round((10000 + random() * 800000)::numeric, 0)); INSERT INTO t_res VALUES (i, 'bolsillo', 'OK');
      ELSIF op < 66 THEN
        SELECT b.id::text INTO bol FROM public.bolsillo b WHERE b.cuenta_id = tests.c(u) ORDER BY random() LIMIT 1;
        IF bol IS NULL THEN bol := gen_random_uuid()::text; END IF;
        IF random() < 0.5 THEN PERFORM public.retirar_de_bolsillo(tests.u(u), bol, round((1000 + random() * 300000)::numeric, 0));
        ELSE PERFORM public.mover_a_bolsillo(tests.u(u), bol, round((1000 + random() * 300000)::numeric, 0)); END IF;
        INSERT INTO t_res VALUES (i, 'bolsillo2', 'OK');
      ELSIF op < 78 THEN
        u2 := 1 + floor(random() * 5)::int; IF u2 = u THEN u2 := 1 + (u % 5); END IF;
        SELECT b.id::text INTO bol FROM public.bolsillo b WHERE b.cuenta_id = tests.c(u) ORDER BY random() LIMIT 1;
        PERFORM public.hacer_transferencia(tests.u(u), (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(u2)), round((1000 + random() * 2000000)::numeric, 0), 'aleatorio', CASE WHEN random() < 0.3 THEN bol END);
        INSERT INTO t_res VALUES (i, 'envio', 'OK');
      ELSIF op < 90 THEN
        PERFORM public.vista_dashboard(tests.u(u)); PERFORM public.vista_historial(tests.u(u), 1 + floor(random() * 60)::int); INSERT INTO t_res VALUES (i, 'lectura', 'OK');
      ELSIF op < 98 THEN
        PERFORM public._reloj_actualizar(false, (public.hoy_banco() + floor(random() * 40)::int)::text); INSERT INTO t_res VALUES (i, 'reloj', 'OK');
      ELSE
        PERFORM public._reloj_actualizar(true, ''); INSERT INTO t_res VALUES (i, 'real', 'OK');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO t_res VALUES (i, CASE WHEN op < 12 THEN 'solicitar' WHEN op < 26 THEN 'pagar' WHEN op < 34 THEN 'abonar' WHEN op < 40 THEN 'descuento' WHEN op < 48 THEN 'cdt' WHEN op < 66 THEN 'bolsillo' ELSE 'otro' END, SQLERRM);
    END;
  END LOOP;
END $do$;

SELECT assert_eq('140 operaciones: TODAS terminan en OK o en un mensaje de negocio permitido (nunca CHECK, FK, unique, driver ni un error interno)',
                 (SELECT coalesce(string_agg(DISTINCT r, ' || '), '') FROM t_res
                   WHERE r <> 'OK' AND r NOT IN ('Monto fuera de rango', 'Plazo fuera de rango', 'Plazo excede el límite de edad', 'Ya tienes un crédito vigente de este producto', 'Recurso no encontrado', 'Saldo insuficiente',
                                                 'Monto por debajo del mínimo del CDT', 'Monto inválido', 'Nombre de bolsillo inválido', 'Los bolsillos de origen y destino deben ser distintos')), ''::text);
SELECT assert_true('la corrida es significativa: >= 8 creditos, >= 5 cuotas, >= 4 CDT y varios tipos de fila en el libro',
                   (SELECT count(*) >= 8 FROM public.credito) AND (SELECT count(*) >= 5 FROM public.transaccion WHERE tipo = 'CREDITO_CUOTA' AND contenedor = 'CUENTA')
                   AND (SELECT count(*) >= 4 FROM public.cdt) AND (SELECT count(DISTINCT tipo) >= 10 FROM public.transaccion));
-- oraculo INDEPENDIENTE: por grupo, la pata de liquidez de mayor prioridad (DISTINCT ON), los 50 mas recientes por orden
CREATE TEMP TABLE t_or AS
  SELECT u, array_agg(id ORDER BY orden DESC) AS ids FROM (
    SELECT u, id, orden, row_number() OVER (PARTITION BY u ORDER BY orden DESC) AS rn FROM (
      SELECT DISTINCT ON (g.n, t.grupo_id) g.n AS u, t.id, t.orden
        FROM generate_series(1, 5) g(n) JOIN public.transaccion t ON t.cuenta_id = tests.c(g.n) AND t.contenedor IN ('CUENTA', 'BOLSILLO', 'CDT')
       ORDER BY g.n, t.grupo_id, CASE t.contenedor WHEN 'CUENTA' THEN 1 WHEN 'BOLSILLO' THEN 2 ELSE 3 END, CASE WHEN t.sentido = 'S' THEN 0 ELSE 1 END) z) y
   WHERE rn <= 50 GROUP BY u;
SELECT assert_eq('para los 5 clientes el historial trae EXACTAMENTE las mismas filas (ids, en el mismo orden) que el oraculo independiente',
                 (SELECT count(*) FROM t_or o WHERE o.ids <> ARRAY(SELECT (e ->> 'id')::uuid FROM jsonb_array_elements(public.vista_historial(tests.u(o.u), 50)) WITH ORDINALITY x(e, n) ORDER BY n)), 0::bigint);
SELECT assert_eq('en el dashboard: balance_total = vista_balance.total, transacciones = las 8 primeras del historial y cdts/creditos coinciden con sus fuentes, para los 5 clientes',
                 (SELECT count(*) FROM generate_series(1, 5) n
                   WHERE NOT (((public.vista_dashboard(tests.u(n)) ->> 'balance_total')::numeric = (public.vista_balance(tests.u(n)) ->> 'total')::numeric)
                          AND public.vista_dashboard(tests.u(n)) -> 'transacciones' = public.vista_historial(tests.u(n), 8)
                          AND (public.vista_dashboard(tests.u(n)) -> 'cdts' ->> 'activos')::int = (SELECT count(*) FROM public.cdt WHERE cuenta_id = tests.c(n) AND estado = 'ACTIVO')
                          AND (public.vista_dashboard(tests.u(n)) -> 'creditos' ->> 'interes_corriendo')::numeric = coalesce((SELECT sum((e ->> 'interes_mes')::numeric) FROM jsonb_array_elements(public.vista_creditos(tests.u(n))) e), 0))), 0::bigint);
SELECT assert_eq('ninguna fila de ningun historial es de CREDITO ni RESULTADO, todas son envio/recibo con monto > 0 y contraparte no nula',
                 (SELECT count(*) FROM generate_series(1, 5) n, jsonb_array_elements(public.vista_historial(tests.u(n), 50)) e
                   WHERE e ->> 'tipo' NOT IN ('envio', 'recibo') OR (e ->> 'monto')::numeric <= 0 OR e ->> 'contraparte' IS NULL
                      OR NOT EXISTS (SELECT 1 FROM public.transaccion t WHERE t.id = (e ->> 'id')::uuid AND t.contenedor IN ('CUENTA', 'BOLSILLO', 'CDT'))), 0::bigint);
SELECT assert_eq('estado global: partida doble, I5u por cuenta, conservacion entre clientes, defensas (incluida la vista del historial) y planes en orden',
                 (SELECT (ok, contenedores_con_desvio, grupos_con_error, cuentas_con_desvio_i5u, defensas_fallidas, desvio_transferencias, creditos_con_plan_incoherente, grupos_credito_sin_plantilla)::text FROM public.v_integridad_global),
                 '(t,0,0,0,0,0.00,0,0)'::text);
ROLLBACK;
