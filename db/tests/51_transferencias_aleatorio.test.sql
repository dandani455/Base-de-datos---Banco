-- 51_transferencias_aleatorio.test.sql · Etapa 5 · prueba ALEATORIA (semilla fija: reproducible) de hacer_transferencia contra un MODELO independiente.
-- 6 clientes, cada uno con cuenta y 2 bolsillos con saldo. Mezcla de transferencias validas (desde la cuenta o un bolsillo, por el saldo exacto) e
-- invalidas (monto 0/negativo/3 decimales/NaN, destino inexistente, autoenvio, bolsillo ajeno, nota larga, saldo +0,01). El modelo predice el mensaje
-- exacto (orden: monto, destino, autoenvio, bolsillo, nota, saldo) y los saldos. Cada rechazo deja la huella de saldos intacta. Al final:
-- conservacion del dinero, nada negativo, 2 patas por cada exito, integridad global.   Por defecto 600 operaciones:  psql -v n_iter=3000 -f ...
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

DO $$
DECLARE i int;
BEGIN
  FOR i IN 1..6 LOOP
    PERFORM tests.cliente(i);
    PERFORM tests.fondear(tests.c(i), 100000);
    PERFORM tests.bolsillo(i * 10 + 1, tests.c(i));
    PERFORM tests.bolsillo(i * 10 + 2, tests.c(i));
    PERFORM tests.app_bolso_ingreso(tests.c(i), tests.b(i * 10 + 1), 20000);
    PERFORM tests.app_bolso_ingreso(tests.c(i), tests.b(i * 10 + 2), 20000);
  END LOOP;
END $$;

CREATE TEMP TABLE t_res (clave text PRIMARY KEY, valor bigint NOT NULL);

DO $$
DECLARE
  n int := current_setting('tests.n_iter')::int;
  it int; c int; d int; j int; r numeric; x numeric;
  mc numeric[] := array_fill(60000::numeric, ARRAY[6]);          -- modelo: saldo de cada cuenta
  mb numeric[] := array_fill(20000::numeric, ARRAY[62]);         -- modelo: saldo de bolsillo (indice = cliente*10 + 1|2)
  disp numeric; monto text; m_val numeric; m_nan boolean; m_bad boolean;
  dest text; es_self boolean; es_inex boolean; bol text; ajeno boolean; nota text; nota_larga boolean; usa_bol boolean;
  esp text; got text; h0 text; fecha_prev timestamptz := '-infinity';
  v_ok int := 0; v_ok_bol int := 0; v_ok_exacto int := 0;
  rech jsonb := '{}'::jsonb; k text; tot0 numeric; res jsonb;
BEGIN
  PERFORM setseed(0.77);
  SELECT sum(balance::numeric) INTO tot0 FROM public.cuenta;
  tot0 := tot0 + (SELECT sum(balance::numeric) FROM public.bolsillo);
  FOR it IN 1..n LOOP
    c := 1 + floor(random() * 6)::int;
    j := 1 + floor(random() * 2)::int;
    r := random();
    -- destino
    d := 1 + (c + floor(random() * 5)::int) % 6;                 -- distinto de c
    es_self := false; es_inex := false;
    IF r < 0.08 THEN es_self := true; d := c; END IF;
    dest := '400000000' || d;
    IF r >= 0.08 AND r < 0.15 THEN es_inex := true; dest := '4999999999'; END IF;
    IF random() < 0.3 THEN dest := ' ' || substr(dest, 1, 4) || '.' || substr(dest, 5) || ' '; END IF;
    -- origen
    usa_bol := random() < 0.4; ajeno := false; bol := NULL;
    IF usa_bol THEN bol := tests.b(c * 10 + j)::text; END IF;
    IF random() < 0.06 THEN ajeno := true; usa_bol := false; bol := tests.b(d * 10 + j)::text; IF d = c THEN bol := gen_random_uuid()::text; END IF; END IF;
    IF usa_bol THEN disp := mb[c * 10 + j]; ELSE disp := mc[c]; END IF;
    -- monto
    m_bad := false; m_nan := false; r := random();
    IF r < 0.07 THEN
      m_bad := true; monto := (ARRAY['0', '-3', '1.234', 'NaN', '0.001', '-0.01'])[1 + floor(random() * 6)::int]; m_nan := monto = 'NaN';
    ELSIF r < 0.17 THEN monto := disp::text;                                          -- todo el saldo
    ELSIF r < 0.25 THEN monto := (disp + 0.01)::text;                                 -- un centavo de mas
    ELSE monto := round((0.01 + random() * greatest(least(disp, 4000) - 0.01, 0))::numeric, 2)::text;
    END IF;
    IF NOT m_bad AND monto::numeric <= 0 THEN monto := '0.01'; END IF;                -- saldo 0: pide 0,01 (sera insuficiente)
    m_val := CASE WHEN m_nan THEN NULL ELSE monto::numeric END;
    -- nota
    nota := NULL; nota_larga := false; r := random();
    IF r < 0.08 THEN nota := repeat('n', 141); nota_larga := true; ELSIF r < 0.45 THEN nota := '  pago ' || it || '  '; END IF;
    -- modelo del resultado
    IF m_bad THEN esp := 'Monto inválido';
    ELSIF es_inex THEN esp := 'Cuenta no encontrada';
    ELSIF es_self THEN esp := 'No puedes enviarte dinero a ti mismo';
    ELSIF ajeno THEN esp := 'Recurso no encontrado';
    ELSIF nota_larga THEN esp := 'Nota inválida';
    ELSIF m_val > disp THEN esp := 'Saldo insuficiente';
    ELSE esp := 'OK'; END IF;

    h0 := tests.huella_saldos();
    BEGIN
      res := public.hacer_transferencia(tests.u(c), dest, monto::numeric, nota, bol);
      got := 'OK';
      IF (res ->> 'fecha')::timestamptz < fecha_prev THEN got := 'FECHA RETROCEDE'; END IF;
      fecha_prev := (res ->> 'fecha')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
      got := SQLERRM;
      IF SQLSTATE <> 'P0001' THEN got := SQLSTATE || ' ' || SQLERRM; END IF;
    END;
    IF got <> esp THEN
      RAISE EXCEPTION 'FAIL: it=% c=% d=% monto=% bol=% usa_bol=% nota_larga=% esperaba [%] y obtuve [%]', it, c, d, monto, bol, usa_bol, nota_larga, esp, got;
    END IF;
    IF esp = 'OK' THEN
      v_ok := v_ok + 1;
      IF usa_bol THEN mb[c * 10 + j] := mb[c * 10 + j] - m_val; v_ok_bol := v_ok_bol + 1; ELSE mc[c] := mc[c] - m_val; END IF;
      mc[d] := mc[d] + m_val;
      IF m_val = disp THEN v_ok_exacto := v_ok_exacto + 1; END IF;
    ELSE
      IF tests.huella_saldos() <> h0 THEN RAISE EXCEPTION 'FAIL: el rechazo [%] (it=%) dejo rastro', esp, it; END IF;
      rech := jsonb_set(rech, ARRAY[esp], to_jsonb(coalesce((rech ->> esp)::int, 0) + 1));
    END IF;
    -- el modelo coincide con la BD (emisor y destino) tras cada operacion
    IF (SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(c)) <> mc[c] OR (SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(d)) <> mc[d]
       OR (SELECT balance::numeric FROM public.bolsillo WHERE id = tests.b(c * 10 + j)) <> mb[c * 10 + j] THEN
      RAISE EXCEPTION 'FAIL: el modelo y la BD divergen en it=%', it;
    END IF;
  END LOOP;
  INSERT INTO t_res VALUES ('ok', v_ok), ('ok_bolsillo', v_ok_bol), ('ok_exacto', v_ok_exacto), ('n', n);
  FOR k IN SELECT jsonb_object_keys(rech) LOOP INSERT INTO t_res VALUES ('rech:' || k, (rech ->> k)::bigint); END LOOP;
  INSERT INTO t_res VALUES ('tot0', tot0::bigint);
END $$;

SELECT assert_true('hubo exitos suficientes (cuenta y bolsillo) y saldos exactos enviados', (SELECT valor FROM t_res WHERE clave = 'ok') > 100 AND (SELECT valor FROM t_res WHERE clave = 'ok_bolsillo') > 20 AND (SELECT valor FROM t_res WHERE clave = 'ok_exacto') > 5);
SELECT assert_eq('se ejercitaron los 6 rechazos del contrato (cada uno al menos una vez)', (SELECT array_agg(clave ORDER BY clave) FROM t_res WHERE clave LIKE 'rech:%'),
                 ARRAY['rech:Cuenta no encontrada','rech:Monto inválido','rech:No puedes enviarte dinero a ti mismo','rech:Nota inválida','rech:Recurso no encontrado','rech:Saldo insuficiente']::text[]);
SELECT assert_eq('conservacion: la suma de cuentas + bolsillos no cambia (las transferencias no crean ni destruyen dinero)',
                 (SELECT sum(x) FROM (SELECT balance::numeric AS x FROM public.cuenta UNION ALL SELECT balance::numeric FROM public.bolsillo) z), (SELECT valor::numeric FROM t_res WHERE clave = 'tot0'));
SELECT assert_eq('ningun saldo negativo', (SELECT count(*) FROM (SELECT balance FROM public.cuenta UNION ALL SELECT balance FROM public.bolsillo) z WHERE balance < 0), 0::bigint);
SELECT assert_eq('exactamente 2 patas por cada transferencia exitosa (ENVIO + RECIBO) y cada grupo cuadra con contrapartes cruzadas',
                 (SELECT (count(*) FILTER (WHERE tipo = 'ENVIO'), count(*) FILTER (WHERE tipo = 'RECIBO'), count(DISTINCT grupo_id))::text FROM public.transaccion WHERE tipo IN ('ENVIO', 'RECIBO')),
                 (SELECT (valor, valor, valor)::text FROM t_res WHERE clave = 'ok'));
SELECT assert_eq('toda pata de transferencia tiene contraparte (cuenta de 10 digitos y nombre) y sus dos patas comparten fecha',
                 ((SELECT count(*) FROM public.transaccion WHERE tipo IN ('ENVIO', 'RECIBO') AND (contraparte_cuenta !~ '^[0-9]{10}$' OR contraparte_nombre IS NULL)),
                  (SELECT count(*) FROM (SELECT grupo_id FROM public.transaccion WHERE tipo IN ('ENVIO', 'RECIBO') GROUP BY grupo_id HAVING min(fecha) <> max(fecha)) q))::text, '(0,0)'::text);
SELECT assert_true('integridad global (saldos, grupos, defensas) en orden tras las operaciones', (SELECT ok FROM public.v_integridad_global));
ROLLBACK;
