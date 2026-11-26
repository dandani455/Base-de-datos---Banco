-- 53_bolsillos_aleatorio.test.sql · Etapa 6 · prueba ALEATORIA (semilla fija: reproducible) de mover_a_bolsillo / retirar_de_bolsillo / mover_entre_bolsillos
-- y vista_balance contra un MODELO independiente. 4 clientes, cada uno con la cuenta en 50000 y 3 bolsillos (creados con crear_bolsillo). Mezcla de movimientos
-- validos (incluido el saldo exacto) e invalidos (monto 0/negativo/3 decimales/NaN, bolsillo ajeno o mal formado, mismo bolsillo, saldo +0,01). El modelo
-- predice el mensaje exacto (orden: monto, bolsillo(s), mismo bolsillo, saldo) y los saldos; cada rechazo deja la huella intacta; tras CADA operacion la vista
-- coincide con el modelo (principal, saldos, total). Al final: conservacion por cliente, nada negativo, 2 patas por exito, integridad global.
-- Por defecto 600 operaciones:  psql -v n_iter=3000 -f ...
\if :{?n_iter}
\else
  \set n_iter 600
\endif
SELECT set_config('tests.n_iter', :'n_iter', false);

DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN RAISE EXCEPTION 'FAIL: solo en banco_test/banco_mut (BD actual: %)', current_database(); END IF;
END $$;
BEGIN;

CREATE TEMP TABLE t_bol (cli int, pos int, id text, PRIMARY KEY (cli, pos));
DO $$
DECLARE i int; j int;
BEGIN
  FOR i IN 1..4 LOOP
    PERFORM tests.cliente(i);
    PERFORM tests.fondear(tests.c(i), 50000);
    FOR j IN 1..3 LOOP
      INSERT INTO t_bol VALUES (i, j, public.crear_bolsillo(tests.u(i), 'Bolsillo ' || j) ->> 'id');
    END LOOP;
  END LOOP;
END $$;

CREATE TEMP TABLE t_res (clave text PRIMARY KEY, valor bigint NOT NULL);

DO $$
DECLARE
  n int := current_setting('tests.n_iter')::int;
  it int; c int; j int; k int; o int; r numeric;
  mc numeric[] := array_fill(50000::numeric, ARRAY[4]);         -- modelo: saldo de cada cuenta
  mb numeric[] := array_fill(0::numeric, ARRAY[43]);            -- modelo: saldo de bolsillo (indice = cliente*10 + j)
  op text; disp numeric; monto text; m_val numeric; m_nan boolean; m_bad boolean;
  id_a text; id_b text; esp text; got text; h0 text; v jsonb; fecha_prev timestamptz := '-infinity'; res jsonb;
  v_ok int := 0; v_in int := 0; v_out int := 0; v_mv int := 0; v_exacto int := 0;
  rech jsonb := '{}'::jsonb; kk text; tot0 numeric; i int; mal_a boolean; mal_b boolean; mismo boolean;
BEGIN
  PERFORM setseed(0.55);
  tot0 := (SELECT sum(balance::numeric) FROM public.cuenta) + (SELECT sum(balance::numeric) FROM public.bolsillo);
  FOR it IN 1..n LOOP
    c := 1 + floor(random() * 4)::int;
    j := 1 + floor(random() * 3)::int;
    k := 1 + (j + floor(random() * 2)::int) % 3;                   -- otro bolsillo, distinto de j
    r := random();
    op := CASE WHEN r < 0.34 THEN 'in' WHEN r < 0.67 THEN 'out' ELSE 'mv' END;
    id_a := (SELECT id FROM t_bol WHERE t_bol.cli = c AND t_bol.pos = j);
    id_b := (SELECT id FROM t_bol WHERE t_bol.cli = c AND t_bol.pos = k);
    mal_a := false; mal_b := false; mismo := false;
    r := random();
    IF r < 0.05 THEN mal_a := true; id_a := (SELECT id FROM t_bol WHERE t_bol.cli = 1 + c % 4 AND t_bol.pos = j);        -- bolsillo AJENO
    ELSIF r < 0.08 THEN mal_a := true; id_a := 'no-es-uuid';
    ELSIF r < 0.11 THEN mal_a := true; id_a := gen_random_uuid()::text;
    END IF;
    IF op = 'mv' THEN
      r := random();
      IF r < 0.05 THEN mal_b := true; id_b := (SELECT id FROM t_bol WHERE t_bol.cli = 1 + c % 4 AND t_bol.pos = k);
      ELSIF r < 0.08 THEN mal_b := true; id_b := '';
      ELSIF r < 0.14 AND NOT mal_a THEN mismo := true; id_b := ' ' || upper(id_a) || ' ';
      END IF;
    END IF;
    -- saldo disponible del origen
    IF op = 'in' THEN disp := mc[c]; ELSE disp := mb[c * 10 + j]; END IF;
    -- monto
    m_bad := false; m_nan := false; r := random();
    IF r < 0.07 THEN
      m_bad := true; monto := (ARRAY['0', '-3', '1.234', 'NaN', '0.001', '-0.01'])[1 + floor(random() * 6)::int]; m_nan := monto = 'NaN';
    ELSIF r < 0.17 THEN monto := disp::text;                                          -- todo el saldo
    ELSIF r < 0.25 THEN monto := (disp + 0.01)::text;                                 -- un centavo de mas
    ELSE monto := round((0.01 + random() * greatest(least(disp, 3000) - 0.01, 0))::numeric, 2)::text;
    END IF;
    IF NOT m_bad AND monto::numeric <= 0 THEN monto := '0.01'; END IF;                -- saldo 0: pide 0,01 (sera insuficiente)
    m_val := CASE WHEN m_nan THEN NULL ELSE monto::numeric END;
    -- modelo del resultado
    IF m_bad THEN esp := 'Monto inválido';
    ELSIF mal_a OR mal_b THEN esp := 'Recurso no encontrado';
    ELSIF mismo THEN esp := 'Los bolsillos de origen y destino deben ser distintos';
    ELSIF m_val > disp THEN esp := 'Saldo insuficiente';
    ELSE esp := 'OK'; END IF;

    h0 := tests.huella_saldos();
    BEGIN
      IF op = 'in' THEN res := public.mover_a_bolsillo(tests.u(c), id_a, monto::numeric);
      ELSIF op = 'out' THEN res := public.retirar_de_bolsillo(tests.u(c), id_a, monto::numeric);
      ELSE res := public.mover_entre_bolsillos(tests.u(c), id_a, id_b, monto::numeric); END IF;
      got := 'OK';
      IF (res ->> 'fecha')::timestamptz < fecha_prev THEN got := 'FECHA RETROCEDE'; END IF;
      fecha_prev := (res ->> 'fecha')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
      got := SQLERRM;
      IF SQLSTATE <> 'P0001' THEN got := SQLSTATE || ' ' || SQLERRM; END IF;
    END;
    IF got <> esp THEN
      RAISE EXCEPTION 'FAIL: it=% op=% c=% j=% k=% monto=% esperaba [%] y obtuve [%]', it, op, c, j, k, monto, esp, got;
    END IF;
    IF esp = 'OK' THEN
      v_ok := v_ok + 1;
      IF op = 'in' THEN mc[c] := mc[c] - m_val; mb[c * 10 + j] := mb[c * 10 + j] + m_val; v_in := v_in + 1;
      ELSIF op = 'out' THEN mb[c * 10 + j] := mb[c * 10 + j] - m_val; mc[c] := mc[c] + m_val; v_out := v_out + 1;
      ELSE mb[c * 10 + j] := mb[c * 10 + j] - m_val; mb[c * 10 + k] := mb[c * 10 + k] + m_val; v_mv := v_mv + 1; END IF;
      IF m_val = disp THEN v_exacto := v_exacto + 1; END IF;
    ELSE
      IF tests.huella_saldos() <> h0 THEN RAISE EXCEPTION 'FAIL: el rechazo [%] (it=%) dejo rastro', esp, it; END IF;
      rech := jsonb_set(rech, ARRAY[esp], to_jsonb(coalesce((rech ->> esp)::int, 0) + 1));
    END IF;
    -- la VISTA del cliente coincide con el modelo tras cada operacion: principal, 3 saldos en orden, total
    v := public.vista_balance(tests.u(c));
    IF (v ->> 'principal')::numeric <> mc[c] OR jsonb_array_length(v -> 'bolsillos') <> 3
       OR (v -> 'bolsillos' -> 0 ->> 'saldo')::numeric <> mb[c * 10 + 1] OR (v -> 'bolsillos' -> 1 ->> 'saldo')::numeric <> mb[c * 10 + 2] OR (v -> 'bolsillos' -> 2 ->> 'saldo')::numeric <> mb[c * 10 + 3]
       OR (v ->> 'total')::numeric <> mc[c] + mb[c * 10 + 1] + mb[c * 10 + 2] + mb[c * 10 + 3] OR (v ->> 'total')::numeric <> 50000 THEN
      RAISE EXCEPTION 'FAIL: la vista y el modelo divergen en it=% (vista=%)', it, v;
    END IF;
  END LOOP;
  INSERT INTO t_res VALUES ('ok', v_ok), ('in', v_in), ('out', v_out), ('mv', v_mv), ('exacto', v_exacto), ('n', n), ('tot0', tot0::bigint);
  FOR kk IN SELECT jsonb_object_keys(rech) LOOP INSERT INTO t_res VALUES ('rech:' || kk, (rech ->> kk)::bigint); END LOOP;
END $$;

SELECT assert_true('hubo exitos suficientes de las 3 operaciones y movimientos de saldo exacto',
                   (SELECT valor FROM t_res WHERE clave = 'in') > 30 AND (SELECT valor FROM t_res WHERE clave = 'out') > 30 AND (SELECT valor FROM t_res WHERE clave = 'mv') > 30 AND (SELECT valor FROM t_res WHERE clave = 'exacto') > 5);
SELECT assert_eq('se ejercitaron los 4 rechazos de E6 (cada uno al menos una vez)', (SELECT array_agg(clave ORDER BY clave) FROM t_res WHERE clave LIKE 'rech:%'),
                 ARRAY['rech:Los bolsillos de origen y destino deben ser distintos', 'rech:Monto inválido', 'rech:Recurso no encontrado', 'rech:Saldo insuficiente']::text[]);
SELECT assert_eq('conservacion: cada cliente conserva 50000 entre cuenta y bolsillos, y el total del banco no cambia',
                 ((SELECT count(*) FROM public.cuenta c WHERE c.balance + (SELECT coalesce(sum(b.balance), 0) FROM public.bolsillo b WHERE b.cuenta_id = c.id) <> 50000),
                  (SELECT sum(x) FROM (SELECT balance::numeric AS x FROM public.cuenta UNION ALL SELECT balance::numeric FROM public.bolsillo) z) = (SELECT valor::numeric FROM t_res WHERE clave = 'tot0'))::text, '(0,t)'::text);
SELECT assert_eq('ningun saldo negativo', (SELECT count(*) FROM (SELECT balance FROM public.cuenta UNION ALL SELECT balance FROM public.bolsillo) z WHERE balance < 0), 0::bigint);
SELECT assert_eq('EXACTAMENTE 2 patas por cada movimiento exitoso, del tipo correcto (INGRESO/RETIRO/MOVIMIENTO) y un grupo cada uno',
                 (SELECT (count(*) FILTER (WHERE tipo = 'BOLSO_INGRESO'), count(*) FILTER (WHERE tipo = 'BOLSO_RETIRO'), count(*) FILTER (WHERE tipo = 'BOLSO_MOVIMIENTO'), count(DISTINCT grupo_id))::text
                    FROM public.transaccion WHERE tipo IN ('BOLSO_INGRESO', 'BOLSO_RETIRO', 'BOLSO_MOVIMIENTO')),
                 (SELECT (2 * (SELECT valor FROM t_res WHERE clave = 'in'), 2 * (SELECT valor FROM t_res WHERE clave = 'out'), 2 * (SELECT valor FROM t_res WHERE clave = 'mv'), (SELECT valor FROM t_res WHERE clave = 'ok'))::text));
SELECT assert_eq('toda pata de movimiento lleva el nombre del bolsillo como contraparte y sus dos patas comparten fecha',
                 ((SELECT count(*) FROM public.transaccion WHERE tipo IN ('BOLSO_INGRESO', 'BOLSO_RETIRO', 'BOLSO_MOVIMIENTO') AND (contraparte_nombre !~ '^Bolsillo [123]$' OR bolsillo_id IS NULL)),
                  (SELECT count(*) FROM (SELECT grupo_id FROM public.transaccion WHERE tipo IN ('BOLSO_INGRESO', 'BOLSO_RETIRO', 'BOLSO_MOVIMIENTO') GROUP BY grupo_id HAVING min(fecha) <> max(fecha)) q))::text, '(0,0)'::text);
SELECT assert_true('integridad global (saldos, grupos, defensas) en orden tras las operaciones', (SELECT ok FROM public.v_integridad_global));
ROLLBACK;
