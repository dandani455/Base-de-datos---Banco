-- 17_libro_aleatorio.test.sql · Etapa 2 · prueba ALEATORIA (semilla fija: reproducible).
-- Genera miles de operaciones validas de TODAS las plantillas y de credito (cuota, abono, mora) entre 6 clientes y las asienta con
-- _asentar_grupo. Tras cada operacion valida, con probabilidad ~40 %, intenta una version MUTADA e invalida del mismo grupo
-- (quitar una pata, +0,01 en una pata, invertir el sentido, duplicar una pata, mover una pata a otra cuenta, cambiar su tipo):
-- TODAS deben rechazarse y NINGUNA puede dejar rastro. Al final, las vistas de integridad y la conservacion del dinero.
-- Tamano por defecto: 3000 iteraciones. Para una corrida pesada:  psql -v n_iter=20000 -f 17_libro_aleatorio.test.sql
\if :{?n_iter}
\else
  \set n_iter 3000
\endif
SELECT set_config('tests.n_iter', :'n_iter', false);

BEGIN;

-- 6 clientes con 100.000 cada uno, 2 bolsillos y un credito de 50.000 ya desembolsado
DO $$
DECLARE i int;
BEGIN
  FOR i IN 1..6 LOOP
    PERFORM tests.cliente(i);
    PERFORM tests.fondear(tests.c(i), 100000);
    PERFORM tests.bolsillo(i * 10 + 1, tests.c(i));
    PERFORM tests.bolsillo(i * 10 + 2, tests.c(i));
    PERFORM tests.credito(i, tests.c(i), 50000);
    PERFORM tests.asentar(tests.pata('CREDITO_DESEMBOLSO','CUENTA','E',50000,tests.c(i),NULL,NULL,tests.k(i)),
                          tests.pata('CREDITO_DESEMBOLSO','CREDITO','E',50000,tests.c(i),NULL,NULL,tests.k(i)));
  END LOOP;
END $$;

CREATE TEMP TABLE t_res (clave text PRIMARY KEY, valor bigint NOT NULL);

DO $$
DECLARE
  n int := current_setting('tests.n_iter')::int;
  it int; k int; c int; d int; j int; m int; src int;
  amt numeric; bal numeric; bbal numeric; cap numeric; i1 numeric;
  legs jsonb; legs2 jsonb; mutable boolean; tipo text; nuevo text; cdt_id uuid; cdt_c uuid; cdt_monto numeric; cdt_gen numeric;
  cdt_n int := 100;
  h0 text;
  v_ok int := 0; v_skip int := 0; v_mut int := 0; v_rech int := 0; v_acept int := 0; v_cambio int := 0;
  tipos_ing text[] := ARRAY['INGRESO_SIMULADO','BONO_REFERIDO','DEPOSITO_BANCO','AJUSTE_ADMIN'];
  tipos_mut text[] := ARRAY['INGRESO_SIMULADO','BONO_REFERIDO','DEPOSITO_BANCO','AJUSTE_ADMIN','ENVIO','RECIBO','BOLSO_INGRESO','CDT_CREACION'];
  usos int[] := array_fill(0, ARRAY[15]);
BEGIN
  PERFORM setseed(0.42);
  FOR it IN 1..n LOOP
    k := 1 + floor(random() * 14)::int;
    c := 1 + floor(random() * 6)::int;
    d := 1 + (c + floor(random() * 5)::int) % 6;           -- otra cuenta distinta de c
    j := 1 + floor(random() * 2)::int;
    SELECT balance::numeric INTO bal FROM public.cuenta WHERE id = tests.c(c);
    SELECT balance::numeric INTO bbal FROM public.bolsillo WHERE id = tests.b(c * 10 + j);
    legs := NULL; mutable := true;

    IF k = 1 THEN                                                  -- ingreso / bono / deposito / ajuste +
      legs := tests.g_ingreso(tests.c(c), (1 + floor(random() * 5000))::numeric, tipos_ing[1 + floor(random() * 4)::int]);
    ELSIF k = 2 AND bal >= 1 THEN                                  -- ajuste negativo
      amt := 1 + floor(random() * least(bal, 3000));
      legs := jsonb_build_array(tests.pata('AJUSTE_ADMIN','CUENTA','S',amt,tests.c(c)), tests.pata('AJUSTE_ADMIN','RESULTADO','S',amt,tests.c(c)));
    ELSIF k = 3 AND bal >= 1 THEN                                  -- cuenta -> bolsillo
      amt := 1 + floor(random() * least(bal, 3000));
      legs := jsonb_build_array(tests.pata('BOLSO_INGRESO','CUENTA','S',amt,tests.c(c),tests.b(c * 10 + j)), tests.pata('BOLSO_INGRESO','BOLSILLO','E',amt,tests.c(c),tests.b(c * 10 + j)));
    ELSIF k = 4 AND bbal >= 1 THEN                                 -- bolsillo -> cuenta
      amt := 1 + floor(random() * least(bbal, 3000));
      legs := jsonb_build_array(tests.pata('BOLSO_RETIRO','BOLSILLO','S',amt,tests.c(c),tests.b(c * 10 + j)), tests.pata('BOLSO_RETIRO','CUENTA','E',amt,tests.c(c),tests.b(c * 10 + j)));
    ELSIF k = 5 AND bbal >= 1 THEN                                 -- bolsillo -> otro bolsillo
      amt := 1 + floor(random() * least(bbal, 2000));
      legs := jsonb_build_array(tests.pata('BOLSO_MOVIMIENTO','BOLSILLO','S',amt,tests.c(c),tests.b(c * 10 + j)), tests.pata('BOLSO_MOVIMIENTO','BOLSILLO','E',amt,tests.c(c),tests.b(c * 10 + 3 - j)));
    ELSIF k = 6 THEN                                               -- interes de bolsillo
      amt := 1 + floor(random() * 50);
      legs := jsonb_build_array(tests.pata('INTERES_BOLSO','BOLSILLO','E',amt,tests.c(c),tests.b(c * 10 + j)), tests.pata('INTERES_BOLSO','RESULTADO','E',amt,tests.c(c),tests.b(c * 10 + j)));
    ELSIF k = 7 AND bal >= 1 THEN                                  -- envio cuenta -> cuenta
      legs := tests.g_envio(tests.c(c), tests.c(d), (1 + floor(random() * least(bal, 4000)))::numeric);
    ELSIF k = 8 AND bbal >= 1 THEN                                 -- envio desde bolsillo
      legs := tests.g_envio(tests.c(c), tests.c(d), (1 + floor(random() * least(bbal, 2000)))::numeric, tests.b(c * 10 + j));
    ELSIF k = 9 AND bal >= 200 THEN                                -- CDT: el CDT nace JUSTO antes de su grupo de apertura
      amt := 100 + floor(random() * (least(bal, 5000) - 99));
      cdt_n := cdt_n + 1;
      PERFORM tests.cdt(cdt_n, tests.c(c), amt);
      legs := jsonb_build_array(tests.pata('CDT_CREACION','CUENTA','S',amt,tests.c(c),NULL,tests.d(cdt_n)), tests.pata('CDT_CREACION','CDT','E',amt,tests.c(c),NULL,tests.d(cdt_n)));
      mutable := false;
    ELSIF k = 10 THEN                                              -- interes de un CDT abierto
      SELECT x.id, x.cuenta_id INTO cdt_id, cdt_c FROM public.cdt x WHERE x.estado = 'ACTIVO' ORDER BY random() LIMIT 1;
      IF cdt_id IS NOT NULL THEN
        amt := 1 + floor(random() * 40);
        legs := jsonb_build_array(tests.pata('INTERES_CDT','CDT','E',amt,cdt_c,NULL,cdt_id), tests.pata('INTERES_CDT','RESULTADO','E',amt,cdt_c,NULL,cdt_id));
      END IF;
    ELSIF k = 11 THEN                                              -- vencimiento de un CDT abierto (cierra y devuelve monto + generado)
      SELECT x.id, x.cuenta_id, x.monto::numeric, x.generado_acumulado::numeric INTO cdt_id, cdt_c, cdt_monto, cdt_gen FROM public.cdt x WHERE x.estado = 'ACTIVO' ORDER BY random() LIMIT 1;
      IF cdt_id IS NOT NULL THEN
        UPDATE public.cdt SET estado = 'CERRADO' WHERE id = cdt_id;
        legs := jsonb_build_array(tests.pata('CDT_VENCIMIENTO','CDT','S',cdt_monto + cdt_gen,cdt_c,NULL,cdt_id), tests.pata('CDT_VENCIMIENTO','CUENTA','E',cdt_monto + cdt_gen,cdt_c,NULL,cdt_id));
        mutable := false;
      END IF;
    ELSIF k IN (12, 13) THEN                                       -- cuota / abono del credito
      SELECT capital_pendiente::numeric INTO cap FROM public.credito WHERE id = tests.k(c);
      IF cap >= 1 AND bal >= 2 THEN
        amt := 1 + floor(random() * least(cap, 2000, bal - 1));
        i1 := 1 + floor(random() * least(100, bal - amt));
        tipo := CASE k WHEN 12 THEN 'CREDITO_CUOTA' ELSE 'CREDITO_ABONO' END;
        legs := jsonb_build_array(tests.pata(tipo,'CUENTA','S',amt + i1,tests.c(c),NULL,NULL,tests.k(c)), tests.pata(tipo,'CREDITO','S',amt,tests.c(c),NULL,NULL,tests.k(c)),
                                  tests.pata(tipo,'RESULTADO','S',i1,tests.c(c),NULL,NULL,tests.k(c)));
      END IF;
    ELSIF k = 14 AND bal >= 1 THEN                                 -- mora
      amt := 1 + floor(random() * least(bal, 200));
      legs := jsonb_build_array(tests.pata('CREDITO_MORA','CUENTA','S',amt,tests.c(c),NULL,NULL,tests.k(c)), tests.pata('CREDITO_MORA','RESULTADO','S',amt,tests.c(c),NULL,NULL,tests.k(c)));
    END IF;

    IF legs IS NULL THEN
      v_skip := v_skip + 1;
      CONTINUE;
    END IF;
    PERFORM public._asentar_grupo(now(), legs);
    v_ok := v_ok + 1;
    usos[k] := usos[k] + 1;

    -- version MUTADA e invalida del mismo grupo: debe rechazarse sin dejar rastro
    IF mutable AND random() < 0.4 THEN
      m := 1 + floor(random() * 6)::int;
      SELECT g INTO src FROM generate_series(1, 6) g WHERE tests.c(g)::text = legs -> 0 ->> 'cuenta_id';   -- indice del cliente de la pata 0
      legs2 := CASE m
        WHEN 1 THEN legs - 0
        WHEN 2 THEN jsonb_set(legs, '{0,monto}', to_jsonb((legs -> 0 ->> 'monto')::numeric + 0.01))
        WHEN 3 THEN jsonb_set(legs, '{0,sentido}', to_jsonb(CASE legs -> 0 ->> 'sentido' WHEN 'E' THEN 'S' ELSE 'E' END))
        WHEN 4 THEN legs || jsonb_build_array(legs -> 0)
        WHEN 5 THEN jsonb_set(legs, '{0,cuenta_id}', to_jsonb(tests.c(1 + (src % 6))))
        ELSE legs END;
      IF m = 6 THEN
        nuevo := tipos_mut[1 + floor(random() * array_length(tipos_mut, 1))::int];
        WHILE nuevo = legs -> 0 ->> 'tipo' LOOP nuevo := tipos_mut[1 + floor(random() * array_length(tipos_mut, 1))::int]; END LOOP;
        legs2 := jsonb_set(legs, '{0,tipo}', to_jsonb(nuevo));
      END IF;
      h0 := tests.huella_saldos();
      v_mut := v_mut + 1;
      BEGIN
        PERFORM public._asentar_grupo(now(), legs2);
        v_acept := v_acept + 1;                                    -- NO debia aceptarse
      EXCEPTION WHEN OTHERS THEN
        v_rech := v_rech + 1;
        IF tests.huella_saldos() IS DISTINCT FROM h0 THEN v_cambio := v_cambio + 1; END IF;
      END;
    END IF;
  END LOOP;
  INSERT INTO t_res VALUES ('iteraciones', n), ('validas', v_ok), ('omitidas', v_skip), ('mutadas', v_mut), ('rechazadas', v_rech), ('aceptadas_indebidas', v_acept), ('con_rastro', v_cambio);
  FOR k IN 1..14 LOOP INSERT INTO t_res VALUES ('uso_' || lpad(k::text, 2, '0'), usos[k]); END LOOP;
END
$$;

SELECT assert_true('se asentaron al menos el 60 % de las iteraciones como operaciones validas',
                   (SELECT valor FROM t_res WHERE clave = 'validas') >= (SELECT valor * 6 / 10 FROM t_res WHERE clave = 'iteraciones'));
SELECT assert_true('se probaron mas de 500 grupos mutados invalidos', (SELECT valor FROM t_res WHERE clave = 'mutadas') > 500);
SELECT assert_eq('NINGUN grupo mutado invalido fue aceptado', (SELECT valor FROM t_res WHERE clave = 'aceptadas_indebidas'), 0::bigint);
SELECT assert_eq('TODOS los grupos mutados fueron rechazados', (SELECT valor FROM t_res WHERE clave = 'rechazadas'), (SELECT valor FROM t_res WHERE clave = 'mutadas'));
SELECT assert_eq('NINGUN rechazo dejo rastro (saldos, contenedores y numero de patas intactos)', (SELECT valor FROM t_res WHERE clave = 'con_rastro'), 0::bigint);
SELECT assert_true('las 14 clases de operacion se ejercitaron al menos una vez', (SELECT count(*) = 14 AND min(valor) > 0 FROM t_res WHERE clave LIKE 'uso\_%'));
SELECT assert_true('v_integridad_global.ok tras todas las operaciones', (SELECT ok FROM public.v_integridad_global));
SELECT assert_eq('0 contenedores con desvio, 0 grupos con error, 0 cuentas con desvio I5u',
                 (SELECT (contenedores_con_desvio, grupos_con_error, cuentas_con_desvio_i5u)::text FROM public.v_integridad_global), '(0,0,0)'::text);
SELECT assert_eq('conservacion del dinero entre clientes: transferencias netas = 0', (SELECT sum(transf_neto) FROM public.v_integridad_usuario), 0::numeric);
SELECT assert_true('ningun saldo negativo en ningun contenedor',
                   (SELECT NOT EXISTS (SELECT 1 FROM public.cuenta WHERE balance < 0) AND NOT EXISTS (SELECT 1 FROM public.bolsillo WHERE balance < 0)
                       AND NOT EXISTS (SELECT 1 FROM public.credito WHERE capital_pendiente < 0)));
SELECT assert_eq('cada saldo de cuenta coincide con la suma de sus patas (recomputado por fuera de la vista)',
                 (SELECT count(*) FROM public.cuenta c WHERE c.balance <> (SELECT coalesce(sum(CASE t.sentido WHEN 'E' THEN t.monto ELSE -t.monto END), 0)
                                                                              FROM public.transaccion t WHERE t.cuenta_id = c.id AND t.contenedor = 'CUENTA')), 0::bigint);
SELECT assert_true('el resumen queda en NOTICE para la evidencia', true);
DO $$ DECLARE r record; BEGIN FOR r IN SELECT clave, valor FROM t_res ORDER BY clave LOOP RAISE NOTICE 'ALEATORIO %: %', r.clave, r.valor; END LOOP; END $$;

ROLLBACK;
