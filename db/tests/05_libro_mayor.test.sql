-- 05_libro_mayor.test.sql · Etapa 1 · integridad de cada FILA del libro mayor (tabla transaccion).
-- La matriz contable (D2) se prueba COMPLETA: las 37 combinaciones (tipo, contenedor, sentido) permitidas
-- entran y las otras 133 de las 170 posibles se rechazan.
-- LIMITE DE LOS CHECK (se prueba expresamente): validan UNA fila. Que cada GRUPO de asientos cuadre
-- (Σ Debitos = Σ Creditos) lo valida el trigger diferido de la Etapa 2 (ver 12_libro_asentar y 13_libro_cuadre).
-- E2: aqui se APAGAN solo los triggers de usuario (libro mayor y guardias) para aislar los CHECK de FILA y las FK
-- de E1; las FK siguen activas (a diferencia de session_replication_role = replica, que tambien las apaga).
-- Una sola transaccion con ROLLBACK final. Corre como superusuario.
BEGIN;
SELECT tests.sin_triggers_de_usuario();

-- Datos base: un cliente con cuenta, bolsillo, CDT y credito a los que apuntar -------------------------------
INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento)
  VALUES ('10000000-0000-4000-8000-000000000001','jperez483','h','Juan','Perez','1020304050','juan@correo.co','3001234567','1990-05-01');
INSERT INTO public.cuenta (id, usuario_id, numero_cuenta) VALUES ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','4001002003');
INSERT INTO public.bolsillo (id, cuenta_id, nombre, ultimo_cobro) VALUES ('30000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','Viajes','2026-11-21');
INSERT INTO public.cdt (id, cuenta_id, nombre, monto, tasa_anual, plazo_dias, fecha_inicio, fecha_fin, ultimo_cobro)
  VALUES ('50000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','CDT',1000000,10,90,DATE '2026-11-01',DATE '2026-11-01'+90,'2026-11-01');
INSERT INTO public.credito_producto (id, nombre, tasa_anual, monto_min, monto_max, plazo_max_meses) VALUES ('60000000-0000-4000-8000-000000000001','Libre',20,1,100000000,24);
INSERT INTO public.credito (id, cuenta_id, producto_id, monto, tasa_anual, plazo_meses, fecha_desembolso, capital_pendiente, fecha_interes)
  VALUES ('70000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000001',1000000,20,12,'2026-11-21',1000000,'2026-11-21');

-- Funcion de ayuda: inserta una pata y devuelve su lado --------------------------------------------------------
CREATE FUNCTION pg_temp.nx(p_tipo text, p_cont text, p_sent text, p_monto numeric, p_previo numeric, p_post numeric,
                           p_bol uuid DEFAULT NULL, p_cdt uuid DEFAULT NULL, p_cre uuid DEFAULT NULL,
                           p_cuenta uuid DEFAULT '20000000-0000-4000-8000-000000000001') RETURNS text LANGUAGE sql AS $$
  INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, saldo_previo, saldo_posterior,
                                  cuenta_id, bolsillo_id, cdt_id, credito_id)
  VALUES (gen_random_uuid(), now(), p_tipo::public.tipo_transaccion, p_cont::public.contenedor_contable, p_sent::public.sentido_asiento,
          p_monto, p_previo, p_post, p_cuenta, p_bol, p_cdt, p_cre) RETURNING lado::text $$;

-- ============================================================================
-- 1. La matriz completa: 37 permitidas entran, 133 prohibidas se rechazan
-- ============================================================================
CREATE TEMP TABLE permitidas (tipo text, cont text, sent text);
INSERT INTO permitidas VALUES
  ('ENVIO','CUENTA','S'),('ENVIO','BOLSILLO','S'),
  ('RECIBO','CUENTA','E'),
  ('BOLSO_INGRESO','CUENTA','S'),('BOLSO_INGRESO','BOLSILLO','E'),
  ('BOLSO_RETIRO','BOLSILLO','S'),('BOLSO_RETIRO','CUENTA','E'),
  ('BOLSO_MOVIMIENTO','BOLSILLO','S'),('BOLSO_MOVIMIENTO','BOLSILLO','E'),
  ('INTERES_BOLSO','BOLSILLO','E'),('INTERES_BOLSO','RESULTADO','E'),
  ('CDT_CREACION','CUENTA','S'),('CDT_CREACION','CDT','E'),
  ('INTERES_CDT','CDT','E'),('INTERES_CDT','RESULTADO','E'),
  ('CDT_VENCIMIENTO','CDT','S'),('CDT_VENCIMIENTO','CUENTA','E'),
  ('CREDITO_DESEMBOLSO','CUENTA','E'),('CREDITO_DESEMBOLSO','CREDITO','E'),
  ('CREDITO_CUOTA','CUENTA','S'),('CREDITO_CUOTA','CREDITO','S'),('CREDITO_CUOTA','RESULTADO','S'),
  ('CREDITO_ABONO','CUENTA','S'),('CREDITO_ABONO','CREDITO','S'),('CREDITO_ABONO','RESULTADO','S'),
  ('CREDITO_MORA','CUENTA','S'),('CREDITO_MORA','RESULTADO','S'),
  ('INGRESO_SIMULADO','CUENTA','E'),('INGRESO_SIMULADO','RESULTADO','E'),
  ('BONO_REFERIDO','CUENTA','E'),('BONO_REFERIDO','RESULTADO','E'),
  ('DEPOSITO_BANCO','CUENTA','E'),('DEPOSITO_BANCO','RESULTADO','E'),
  ('AJUSTE_ADMIN','CUENTA','E'),('AJUSTE_ADMIN','CUENTA','S'),('AJUSTE_ADMIN','RESULTADO','E'),('AJUSTE_ADMIN','RESULTADO','S');

SELECT assert_eq('la lista independiente de permitidas tiene 37 combinaciones', (SELECT count(*) FROM permitidas), 37::bigint);

DO $$
DECLARE
  r record;
  v_bol uuid; v_cdt uuid; v_cre uuid;
  v_previo numeric; v_post numeric;
  v_lado text; v_esperado text;
  v_permitida boolean;
  v_ok int := 0; v_rechazadas int := 0; v_lado_mal int := 0; v_inesperado int := 0;
  v_state text;
BEGIN
  FOR r IN
    SELECT t::text AS tipo, c::text AS cont, s::text AS sent
      FROM unnest(enum_range(NULL::public.tipo_transaccion)) t
           CROSS JOIN unnest(enum_range(NULL::public.contenedor_contable)) c
           CROSS JOIN unnest(enum_range(NULL::public.sentido_asiento)) s
  LOOP
    v_permitida := EXISTS (SELECT 1 FROM permitidas p WHERE p.tipo = r.tipo AND p.cont = r.cont AND p.sent = r.sent);
    -- ids coherentes con tipo/contenedor, para que SOLO la matriz decida
    v_bol := CASE WHEN r.tipo IN ('BOLSO_INGRESO','BOLSO_RETIRO','BOLSO_MOVIMIENTO','INTERES_BOLSO') OR r.cont = 'BOLSILLO'
                  THEN '30000000-0000-4000-8000-000000000001'::uuid END;
    v_cdt := CASE WHEN r.tipo IN ('CDT_CREACION','CDT_VENCIMIENTO','INTERES_CDT') OR r.cont = 'CDT'
                  THEN '50000000-0000-4000-8000-000000000001'::uuid END;
    v_cre := CASE WHEN r.tipo IN ('CREDITO_DESEMBOLSO','CREDITO_CUOTA','CREDITO_ABONO','CREDITO_MORA') OR r.cont = 'CREDITO'
                  THEN '70000000-0000-4000-8000-000000000001'::uuid END;
    IF r.cont IN ('CUENTA','BOLSILLO','CREDITO') THEN
      v_previo := 1000; v_post := CASE WHEN r.sent = 'E' THEN 1100 ELSE 900 END;
    ELSE
      v_previo := NULL; v_post := NULL;
    END IF;
    BEGIN
      v_lado := pg_temp.nx(r.tipo, r.cont, r.sent, 100, v_previo, v_post, v_bol, v_cdt, v_cre);
      IF v_permitida THEN
        v_ok := v_ok + 1;
        -- lado esperado segun la tabla contable: activos (CUENTA, BOLSILLO, CDT): E=Debito, S=Credito;
        -- pasivo (CREDITO) y patrimonio (RESULTADO): E=Credito, S=Debito.
        v_esperado := CASE WHEN r.cont IN ('CUENTA','BOLSILLO','CDT') THEN CASE r.sent WHEN 'E' THEN 'D' ELSE 'C' END
                           ELSE CASE r.sent WHEN 'E' THEN 'C' ELSE 'D' END END;
        IF v_lado IS DISTINCT FROM v_esperado THEN v_lado_mal := v_lado_mal + 1; END IF;
      ELSE
        v_inesperado := v_inesperado + 1;       -- una combinacion prohibida entro
      END IF;
    EXCEPTION WHEN check_violation THEN
      IF v_permitida THEN v_inesperado := v_inesperado + 1; ELSE v_rechazadas := v_rechazadas + 1; END IF;
    END;
  END LOOP;
  PERFORM tests.assert_eq('matriz: las 37 combinaciones permitidas entran', v_ok, 37);
  PERFORM tests.assert_eq('matriz: las 133 combinaciones prohibidas se rechazan (check_violation)', v_rechazadas, 133);
  PERFORM tests.assert_eq('matriz: ninguna combinacion se comporto al reves', v_inesperado, 0);
  PERFORM tests.assert_eq('matriz: el lado D/C generado coincide con la tabla contable en las 37 permitidas', v_lado_mal, 0);
END
$$;

SELECT assert_eq('las 37 filas de la matriz quedaron en el libro (orden creciente sin huecos de logica)',
                 (SELECT count(*) FROM public.transaccion), 37::bigint);

-- Dos casos que solo viola la MATRIZ (todo lo demas es valido): se verifica el nombre exacto -------------------------
SELECT assert_violates('RECIBO solo es una ENTRADA de la cuenta (RECIBO/CUENTA/S)',
                       $$SELECT pg_temp.nx('RECIBO','CUENTA','S', 100, 1000, 900)$$, 'ck_transaccion_tipo_contenedor_sentido', '23514');
SELECT assert_violates('DEPOSITO_BANCO solo aumenta el resultado (DEPOSITO_BANCO/RESULTADO/S)',
                       $$SELECT pg_temp.nx('DEPOSITO_BANCO','RESULTADO','S', 100, NULL, NULL)$$, 'ck_transaccion_tipo_contenedor_sentido', '23514');
SELECT assert_violates('un ENVIO no puede afectar al CDT', $$SELECT pg_temp.nx('ENVIO','CDT','S', 100, NULL, NULL)$$, 'ck_transaccion_tipo_contenedor_sentido');

-- ============================================================================
-- 2. lado y orden son columnas generadas (no se escriben a mano)
-- ============================================================================
SELECT assert_raises('lado no se puede insertar (GENERATED ALWAYS)',
                     $$INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, lado, monto, saldo_previo, saldo_posterior, cuenta_id)
                       VALUES (gen_random_uuid(), now(), 'RECIBO', 'CUENTA', 'E', 'D', 100, 0, 100, '20000000-0000-4000-8000-000000000001')$$, NULL, '428C9');
SELECT assert_raises('orden no se puede insertar (GENERATED ALWAYS identity)',
                     $$INSERT INTO public.transaccion (orden, grupo_id, fecha, tipo, contenedor, sentido, monto, saldo_previo, saldo_posterior, cuenta_id)
                       VALUES (999, gen_random_uuid(), now(), 'RECIBO', 'CUENTA', 'E', 100, 0, 100, '20000000-0000-4000-8000-000000000001')$$, NULL, '428C9');
SELECT assert_true('orden crece con cada insercion',
                   (SELECT bool_and(orden > anterior) FROM (SELECT orden, lag(orden) OVER (ORDER BY orden) AS anterior FROM public.transaccion) x WHERE anterior IS NOT NULL));

-- ============================================================================
-- 3. Restricciones por fila
-- ============================================================================
SELECT assert_ok('fila valida: RECIBO a la cuenta', $$SELECT pg_temp.nx('RECIBO','CUENTA','E', 250.75, 1000, 1250.75)$$);
SELECT assert_violates('monto 0', $$SELECT pg_temp.nx('RECIBO','CUENTA','E', 0, 1000, 1000)$$, 'ck_transaccion_monto_positivo');
SELECT assert_violates('monto negativo (el signo lo dan sentido/lado, nunca el monto)', $$SELECT pg_temp.nx('RECIBO','CUENTA','E', -5, 1000, 995)$$, 'ck_transaccion_monto_positivo');
SELECT assert_violates('monto fuera del dominio dinero', $$SELECT pg_temp.nx('RECIBO','CUENTA','E', 10000000000000, 0, 10000000000000)$$, 'ck_dinero_rango');

-- ids por familia
SELECT assert_violates('BOLSO_INGRESO exige bolsillo_id', $$SELECT pg_temp.nx('BOLSO_INGRESO','BOLSILLO','E', 100, 0, 100)$$, 'ck_transaccion_bolsillo_id_familia');
SELECT assert_violates('INTERES_BOLSO exige bolsillo_id', $$SELECT pg_temp.nx('INTERES_BOLSO','RESULTADO','E', 100, NULL, NULL)$$, 'ck_transaccion_bolsillo_id_familia');
SELECT assert_violates('ENVIO desde la cuenta no lleva bolsillo_id',
                       $$SELECT pg_temp.nx('ENVIO','CUENTA','S', 100, 1000, 900, '30000000-0000-4000-8000-000000000001')$$, 'ck_transaccion_bolsillo_id_familia');
SELECT assert_violates('ENVIO desde un bolsillo exige bolsillo_id', $$SELECT pg_temp.nx('ENVIO','BOLSILLO','S', 100, 1000, 900)$$, 'ck_transaccion_bolsillo_id_familia');
SELECT assert_violates('RECIBO no lleva bolsillo_id',
                       $$SELECT pg_temp.nx('RECIBO','CUENTA','E', 100, 0, 100, '30000000-0000-4000-8000-000000000001')$$, 'ck_transaccion_bolsillo_id_familia');
SELECT assert_violates('CDT_CREACION exige cdt_id', $$SELECT pg_temp.nx('CDT_CREACION','CUENTA','S', 100, 1000, 900)$$, 'ck_transaccion_cdt_id_familia');
SELECT assert_violates('RECIBO no lleva cdt_id',
                       $$SELECT pg_temp.nx('RECIBO','CUENTA','E', 100, 0, 100, NULL, '50000000-0000-4000-8000-000000000001')$$, 'ck_transaccion_cdt_id_familia');
SELECT assert_violates('CREDITO_CUOTA exige credito_id', $$SELECT pg_temp.nx('CREDITO_CUOTA','CUENTA','S', 100, 1000, 900)$$, 'ck_transaccion_credito_id_familia');
SELECT assert_violates('RECIBO no lleva credito_id',
                       $$SELECT pg_temp.nx('RECIBO','CUENTA','E', 100, 0, 100, NULL, NULL, '70000000-0000-4000-8000-000000000001')$$, 'ck_transaccion_credito_id_familia');

-- saldos
SELECT assert_violates('contenedor almacenado (CUENTA) sin saldos', $$SELECT pg_temp.nx('RECIBO','CUENTA','E', 100, NULL, NULL)$$, 'ck_transaccion_saldos');
SELECT assert_violates('saldo posterior incoherente con previo + monto', $$SELECT pg_temp.nx('RECIBO','CUENTA','E', 100, 1000, 1500)$$, 'ck_transaccion_saldos');
SELECT assert_violates('saldo posterior incoherente con previo - monto', $$SELECT pg_temp.nx('ENVIO','CUENTA','S', 100, 1000, 1100)$$, 'ck_transaccion_saldos');
SELECT assert_violates('una salida no puede dejar saldo negativo', $$SELECT pg_temp.nx('ENVIO','CUENTA','S', 100, 50, -50)$$, 'ck_transaccion_saldos');
SELECT assert_violates('saldo previo negativo', $$SELECT pg_temp.nx('RECIBO','CUENTA','E', 100, -1, 99)$$, 'ck_transaccion_saldos');
SELECT assert_violates('contenedor derivado (RESULTADO) no lleva saldos', $$SELECT pg_temp.nx('BONO_REFERIDO','RESULTADO','E', 100, 0, 100)$$, 'ck_transaccion_saldos');
SELECT assert_violates('contenedor derivado (CDT) no lleva saldos',
                       $$SELECT pg_temp.nx('CDT_CREACION','CDT','E', 100, 0, 100, NULL, '50000000-0000-4000-8000-000000000001')$$, 'ck_transaccion_saldos');
SELECT assert_ok('el pasivo (CREDITO) lleva saldos como los activos: E suma deuda',
                 $$SELECT pg_temp.nx('CREDITO_DESEMBOLSO','CREDITO','E', 100, 1000, 1100, NULL, NULL, '70000000-0000-4000-8000-000000000001')$$);

-- FK
SELECT assert_violates('la cuenta propietaria debe existir', $$SELECT pg_temp.nx('RECIBO','CUENTA','E', 100, 0, 100, NULL, NULL, NULL, '99999999-9999-4999-8999-999999999999')$$, 'fk_transaccion_cuenta', '23503');
SELECT assert_violates('el bolsillo debe existir', $$SELECT pg_temp.nx('BOLSO_INGRESO','BOLSILLO','E', 100, 0, 100, '99999999-9999-4999-8999-999999999999')$$, 'fk_transaccion_bolsillo', '23503');
SELECT assert_violates('el cdt debe existir', $$SELECT pg_temp.nx('INTERES_CDT','CDT','E', 100, NULL, NULL, NULL, '99999999-9999-4999-8999-999999999999')$$, 'fk_transaccion_cdt', '23503');
SELECT assert_violates('el credito debe existir', $$SELECT pg_temp.nx('CREDITO_MORA','RESULTADO','S', 100, NULL, NULL, NULL, NULL, '99999999-9999-4999-8999-999999999999')$$, 'fk_transaccion_credito', '23503');

-- ============================================================================
-- 4. Frontera: los CHECK por si solos NO validan el cuadre del grupo (lo hace el trigger diferido de E2)
-- ============================================================================
SELECT assert_ok('con los triggers de E2 apagados, los CHECK aceptan una pata sola (un grupo descuadrado): el cuadre es del trigger diferido',
                 $$INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, saldo_previo, saldo_posterior, cuenta_id)
                   VALUES ('aaaaaaaa-0000-4000-8000-000000000001', now(), 'RECIBO', 'CUENTA', 'E', 100, 0, 100, '20000000-0000-4000-8000-000000000001')$$);
SELECT assert_eq('...y ese grupo queda descuadrado (ΣD - ΣC = 100): lo detecta v_integridad_grupos',
                 (SELECT sum(CASE lado WHEN 'D' THEN monto ELSE -monto END)::numeric FROM public.transaccion
                   WHERE grupo_id = 'aaaaaaaa-0000-4000-8000-000000000001'), 100::numeric);

ROLLBACK;
