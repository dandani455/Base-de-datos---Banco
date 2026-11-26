-- 56_motor_aleatorio.test.sql · Etapa 7 · operaciones ALEATORIAS con SALTOS DE RELOJ contra un MODELO independiente: 4 clientes con 2 bolsillos y CDT de 20 y 90 dias;
-- ingresos, retiros, movimientos entre bolsillos, transferencias (desde la cuenta y desde un bolsillo), CDT y lecturas, mezclados con saltos de 1 a 25 dias.
-- El modelo (tablas temporales m_*) reimplementa el devengo perezoso con OTRA expresion (exp/ln en vez de power) y los mismos puntos de contacto
-- (una operacion toca la cuenta que la ejecuta; una transferencia solo toca al EMISOR). Cada 20 operaciones compara cuentas, bolsillos y CDT con la BD.
-- Al final: conservacion del dinero (capital + intereses devengados) e integridad global. Una transaccion con ROLLBACK final; semilla fija (reproducible).
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 4) n;
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES
  (tests.p(901), 'CDT 90', 90, 10, 100000), (tests.p(903), 'CDT 20', 20, 8, 50000);
SELECT count(tests.fondear(tests.c(n), 3000000)) FROM generate_series(1, 4) n;
SELECT count(*) FROM (SELECT public.crear_bolsillo(tests.u(n), 'M' || k) FROM generate_series(1, 4) n, generate_series(1, 2) k) q;

CREATE TEMP TABLE m_cta (cl int PRIMARY KEY, saldo numeric NOT NULL);
CREATE TEMP TABLE m_bol (id uuid PRIMARY KEY, cl int NOT NULL, ord int NOT NULL, saldo numeric NOT NULL, ult date NOT NULL);
CREATE TEMP TABLE m_cdt (id uuid PRIMARY KEY, cl int NOT NULL, monto numeric NOT NULL, tasa numeric NOT NULL, gen numeric NOT NULL, ini date NOT NULL, fin date NOT NULL, ult date NOT NULL, activo boolean NOT NULL);
INSERT INTO m_cta SELECT n, 3000000 FROM generate_series(1, 4) n;
INSERT INTO m_bol SELECT b.id, n, row_number() OVER (PARTITION BY n ORDER BY b.nombre), 0, public.hoy_banco()
  FROM generate_series(1, 4) n JOIN public.cuenta c ON c.id = tests.c(n) JOIN public.bolsillo b ON b.cuenta_id = c.id;

CREATE FUNCTION pg_temp.sig(p_n int) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(false, (public.hoy_banco() + p_n)::text); END $f$;
-- el MODELO: devengo perezoso de una cuenta hasta p_hoy (formula distinta de la del motor: exp/ln)
CREATE FUNCTION pg_temp.m_dev(p_cl int, p_hoy date) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE r record; v_i numeric; v_d date; v_obj numeric; v_gen numeric;
BEGIN
  FOR r IN SELECT id, saldo, ult FROM m_bol WHERE cl = p_cl AND ult < p_hoy LOOP
    v_i := round(r.saldo * (exp(ln(1 + 12 / 100.0) * (p_hoy - r.ult) / 365.0) - 1), 2);
    UPDATE m_bol SET saldo = saldo + v_i, ult = p_hoy WHERE id = r.id;
  END LOOP;
  FOR r IN SELECT * FROM m_cdt WHERE cl = p_cl AND activo AND (fin <= p_hoy OR ult < p_hoy) ORDER BY fin, id LOOP
    v_d := least(p_hoy, r.fin);
    v_gen := r.gen;
    IF v_d > r.ult THEN
      v_obj := round(r.monto * (exp(ln(1 + r.tasa / 100.0) * (v_d - r.ini) / 365.0) - 1), 2);
      IF v_obj > v_gen THEN v_gen := v_obj; END IF;
      UPDATE m_cdt SET gen = v_gen, ult = v_d WHERE id = r.id;
    END IF;
    IF r.fin <= p_hoy THEN
      UPDATE m_cdt SET activo = false WHERE id = r.id;
      UPDATE m_cta SET saldo = saldo + r.monto + v_gen WHERE cl = p_cl;
    END IF;
  END LOOP;
END $f$;
-- compara el modelo con la BD (tolerancia 5 centavos: solo el redondeo de dos formulas equivalentes); devuelve la lista de discrepancias
CREATE FUNCTION pg_temp.m_cmp() RETURNS text LANGUAGE sql VOLATILE AS $f$
  SELECT coalesce(string_agg(x, '; '), '') FROM (
    SELECT 'cuenta ' || m.cl || ' modelo=' || m.saldo || ' bd=' || c.balance AS x FROM m_cta m JOIN public.cuenta c ON c.id = tests.c(m.cl) WHERE abs(m.saldo - c.balance) > 0.05
    UNION ALL SELECT 'bolsillo ' || m.cl || '.' || m.ord || ' modelo=' || m.saldo || ' bd=' || b.balance FROM m_bol m JOIN public.bolsillo b ON b.id = m.id WHERE abs(m.saldo - b.balance) > 0.05
    UNION ALL SELECT 'cdt ' || m.cl || ' modelo=' || m.gen || '/' || m.activo || ' bd=' || d.generado_acumulado || '/' || (d.estado = 'ACTIVO') FROM m_cdt m JOIN public.cdt d ON d.id = m.id
               WHERE abs(m.gen - d.generado_acumulado) > 0.05 OR m.activo <> (d.estado = 'ACTIVO')) q $f$;

CREATE TEMP TABLE t_cont (op text PRIMARY KEY, n int NOT NULL DEFAULT 0);
INSERT INTO t_cont VALUES ('reloj', 0), ('vista_balance', 0), ('vista_cdts', 0), ('ingresar', 0), ('retirar', 0), ('mover', 0), ('transf_cuenta', 0), ('transf_bolsillo', 0), ('crear_cdt', 0), ('rechazo_saldo', 0);

DO $do$
DECLARE
  i int; v_op int; v_c int; v_c2 int; v_k int; v_k2 int; v_hoy date; s numeric; amt numeric; v_b uuid; v_b2 uuid; v_def int; v_min numeric; v_pl int; v_tasa numeric; r jsonb; v_id uuid; mal text;
BEGIN
  PERFORM setseed(0.7);
  FOR i IN 1..220 LOOP
    v_op := floor(random() * 12)::int;
    v_c := 1 + floor(random() * 4)::int;
    v_c2 := 1 + (v_c + floor(random() * 3)::int) % 4;          -- otro cliente (distinto de v_c)
    v_k := 1 + floor(random() * 2)::int; v_k2 := 3 - v_k;
    BEGIN
      IF v_op <= 1 THEN
        PERFORM pg_temp.sig(1 + floor(random() * 25)::int);
        UPDATE t_cont SET n = n + 1 WHERE op = 'reloj';
      ELSE
        v_hoy := public.hoy_banco();
        PERFORM pg_temp.m_dev(v_c, v_hoy);
        SELECT m.saldo INTO s FROM m_cta m WHERE m.cl = v_c;
        SELECT m.id INTO v_b FROM m_bol m WHERE m.cl = v_c AND m.ord = v_k;
        SELECT m.id INTO v_b2 FROM m_bol m WHERE m.cl = v_c AND m.ord = v_k2;
        IF v_op = 2 THEN
          PERFORM public.vista_balance(tests.u(v_c)); UPDATE t_cont SET n = n + 1 WHERE op = 'vista_balance';
        ELSIF v_op = 3 THEN
          PERFORM public.vista_cdts(tests.u(v_c)); UPDATE t_cont SET n = n + 1 WHERE op = 'vista_cdts';
        ELSIF v_op IN (4, 5) THEN
          IF s >= 3 THEN
            amt := 1 + floor(random() * (s - 2));
            PERFORM public.mover_a_bolsillo(tests.u(v_c), v_b::text, amt);
            UPDATE m_cta SET saldo = saldo - amt WHERE cl = v_c; UPDATE m_bol SET saldo = saldo + amt WHERE id = v_b;
            UPDATE t_cont SET n = n + 1 WHERE op = 'ingresar';
          END IF;
        ELSIF v_op = 6 THEN
          SELECT m.saldo INTO s FROM m_bol m WHERE m.id = v_b;
          IF s >= 3 THEN
            amt := 1 + floor(random() * (s - 2));
            PERFORM public.retirar_de_bolsillo(tests.u(v_c), v_b::text, amt);
            UPDATE m_cta SET saldo = saldo + amt WHERE cl = v_c; UPDATE m_bol SET saldo = saldo - amt WHERE id = v_b;
            UPDATE t_cont SET n = n + 1 WHERE op = 'retirar';
          END IF;
        ELSIF v_op = 7 THEN
          SELECT m.saldo INTO s FROM m_bol m WHERE m.id = v_b;
          IF s >= 3 THEN
            amt := 1 + floor(random() * (s - 2));
            PERFORM public.mover_entre_bolsillos(tests.u(v_c), v_b::text, v_b2::text, amt);
            UPDATE m_bol SET saldo = saldo - amt WHERE id = v_b; UPDATE m_bol SET saldo = saldo + amt WHERE id = v_b2;
            UPDATE t_cont SET n = n + 1 WHERE op = 'mover';
          END IF;
        ELSIF v_op = 8 THEN
          IF s >= 3 THEN
            amt := 1 + floor(random() * (s - 2));
            PERFORM public.hacer_transferencia(tests.u(v_c), (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(v_c2)), amt, NULL, NULL);
            UPDATE m_cta SET saldo = saldo - amt WHERE cl = v_c; UPDATE m_cta SET saldo = saldo + amt WHERE cl = v_c2;    -- el destino NO devenga (solo se toca al emisor)
            UPDATE t_cont SET n = n + 1 WHERE op = 'transf_cuenta';
          END IF;
        ELSIF v_op = 9 THEN
          SELECT m.saldo INTO s FROM m_bol m WHERE m.id = v_b;
          IF s >= 3 THEN
            amt := 1 + floor(random() * (s - 2));
            PERFORM public.hacer_transferencia(tests.u(v_c), (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(v_c2)), amt, NULL, v_b::text);
            UPDATE m_bol SET saldo = saldo - amt WHERE id = v_b; UPDATE m_cta SET saldo = saldo + amt WHERE cl = v_c2;
            UPDATE t_cont SET n = n + 1 WHERE op = 'transf_bolsillo';
          END IF;
        ELSE
          IF random() < 0.5 THEN v_def := 903; v_min := 50000; v_pl := 20; v_tasa := 8; ELSE v_def := 901; v_min := 100000; v_pl := 90; v_tasa := 10; END IF;
          IF s >= v_min + 1 THEN
            amt := v_min + floor(random() * (least(s - 1, v_min * 4) - v_min + 1));
            r := public.crear_cdt(tests.u(v_c), tests.p(v_def)::text, amt);
            v_id := (r ->> 'id')::uuid;
            INSERT INTO m_cdt VALUES (v_id, v_c, amt, v_tasa, 0, v_hoy, v_hoy + v_pl, v_hoy, true);
            UPDATE m_cta SET saldo = saldo - amt WHERE cl = v_c;
            UPDATE t_cont SET n = n + 1 WHERE op = 'crear_cdt';
          END IF;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      PERFORM tests.assert_eq('ninguna operacion aleatoria falla (it=' || i || ', op=' || v_op || ')', SQLERRM, ''::text);
    END;
    IF i % 20 = 0 THEN
      mal := pg_temp.m_cmp();
      PERFORM tests.assert_eq('modelo = BD en el punto de control ' || i || ' (cuentas, bolsillos y CDT, +-5 centavos)', mal, ''::text);
    END IF;
  END LOOP;
END $do$;

-- toque final de TODOS los clientes (el modelo devenga igual) y comparacion
DO $do$
DECLARE n int; v_hoy date;
BEGIN
  v_hoy := public.hoy_banco();
  FOR n IN 1..4 LOOP
    PERFORM pg_temp.m_dev(n, v_hoy);
    PERFORM public.vista_balance(tests.u(n));
    PERFORM public.vista_cdts(tests.u(n));
  END LOOP;
END $do$;
SELECT assert_eq('modelo = BD tras tocar a todos los clientes (+-5 centavos)', pg_temp.m_cmp(), ''::text);
SELECT assert_true('cobertura: el recorrido ejecuto al menos 8 ingresos, 4 retiros, 4 movimientos, 5 transferencias de cada clase, 8 CDT y muchos saltos de reloj',
                   (SELECT bool_and(CASE op WHEN 'ingresar' THEN n >= 8 WHEN 'retirar' THEN n >= 4 WHEN 'mover' THEN n >= 4 WHEN 'transf_cuenta' THEN n >= 5 WHEN 'transf_bolsillo' THEN n >= 5
                                           WHEN 'crear_cdt' THEN n >= 8 WHEN 'reloj' THEN n >= 20 ELSE n >= 1 END) FROM t_cont WHERE op <> 'rechazo_saldo'));
SELECT assert_true('se devengaron intereses de bolsillo y de CDT, y se cerraron CDT (CDT_VENCIMIENTO > 0)',
                   (SELECT count(*) FILTER (WHERE tipo = 'INTERES_BOLSO') > 0 AND count(*) FILTER (WHERE tipo = 'INTERES_CDT') > 0 AND count(*) FILTER (WHERE tipo = 'CDT_VENCIMIENTO') > 0 FROM public.transaccion));
SELECT assert_eq('CONSERVACION: la suma de los 4 totales (cuenta + bolsillos + CDT activos) = 12.000.000 de capital + los intereses de bolsillo y de CDT devengados',
                 (SELECT sum(public.balance_total(tests.c(n))) FROM generate_series(1, 4) n),
                 12000000 + (SELECT coalesce(sum(monto), 0) FROM public.transaccion WHERE (tipo = 'INTERES_BOLSO' AND contenedor = 'BOLSILLO') OR (tipo = 'INTERES_CDT' AND contenedor = 'CDT')));
SELECT assert_eq('todos los CDT cerrados tienen inversion 0 y los activos monto + generado (ct_cdt_inversion); ultimo_cobro de cada producto <= hoy',
                 (SELECT count(*) FROM public.cdt WHERE ultimo_cobro > public.hoy_banco()) + (SELECT count(*) FROM public.bolsillo WHERE ultimo_cobro > public.hoy_banco()), 0::bigint);
SELECT assert_true('v_integridad_global OK (partida doble, I1, I5u, defensas) tras el recorrido', (SELECT ok FROM public.v_integridad_global));
SELECT assert_eq('no hay saldos negativos ni desviaciones de saldo (v_integridad_saldos y v_integridad_usuario sin filas fallidas)',
                 (SELECT count(*) FROM public.v_integridad_saldos WHERE NOT ok) + (SELECT count(*) FROM public.v_integridad_usuario WHERE NOT ok), 0::bigint);

ROLLBACK;

SELECT assert_eq('tras el ROLLBACK el reloj vuelve a modo real', (SELECT usar_fecha_real FROM public.reloj WHERE id = 1), true);
