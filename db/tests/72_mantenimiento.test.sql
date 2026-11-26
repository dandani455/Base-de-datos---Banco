-- 72_mantenimiento.test.sql · Etapa 13 · sp_verificar_integridad (el informe de integridad) y el catalogo de los 2 procedimientos.
-- Riesgos NUEVOS: el informe coincide con v_integridad_global y CADA control detecta su sabotaje (con la fila defectuosa en `detalle`), el tope de filas de muestra, que es de SOLO LECTURA, y que los
-- procedimientos son SECURITY INVOKER sin SET (unica forma de hacer COMMIT), sin permisos para nadie, con el search_path fijado en CADA transaccion (3 veces, tras cada COMMIT) y que clasifican el 55P03
-- como timeout de bloqueo. Lo que EXIGE COMMIT real (sp_avanzar_todos corriendo) se prueba con conexiones reales en reales/56. Una transaccion con ROLLBACK final; solo en banco_test/banco_mut.
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 2) n;
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES (tests.p(930), 'CDT 30', 30, 10, 1);
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES (tests.p(901), 'Libre', '', 18, 1, 1000000000, 1, 360);
SELECT tests.fondear(tests.c(1), 10000000);
CREATE TEMP TABLE t_bol AS SELECT public.crear_bolsillo(tests.u(1), 'Viajes') ->> 'id' AS b;
SELECT public.mover_a_bolsillo(tests.u(1), (SELECT b FROM t_bol), 500000);
SELECT public.crear_cdt(tests.u(1), tests.p(930)::text, 1000000);
CREATE TEMP TABLE t_k AS SELECT (public.solicitar_credito(tests.u(1), tests.p(901)::text, 2000000, 12) ->> 'id')::uuid AS k;
SELECT public.hacer_transferencia(tests.u(1), (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(2)), 100000, 'x', NULL);
CREATE FUNCTION pg_temp.informe() RETURNS jsonb LANGUAGE plpgsql AS $f$ DECLARE r jsonb; BEGIN CALL public.sp_verificar_integridad(r); RETURN r; END $f$;
CREATE FUNCTION pg_temp.suelta(p_grupo uuid, p_tipo text, p_cont text, p_sent text, p_monto numeric, p_cuenta uuid) RETURNS void LANGUAGE sql AS $f$
  INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, saldo_previo, saldo_posterior, cuenta_id)
  VALUES (p_grupo, now(), p_tipo::public.tipo_transaccion, p_cont::public.contenedor_contable, p_sent::public.sentido_asiento, p_monto,
          CASE WHEN p_cont IN ('CUENTA','BOLSILLO','CREDITO') THEN 1000 END, CASE WHEN p_cont IN ('CUENTA','BOLSILLO','CREDITO') THEN 1000 + CASE p_sent WHEN 'E' THEN p_monto ELSE -p_monto END END, p_cuenta) $f$;

-- ============================================================================
-- A. Banco sano
-- ============================================================================
CREATE TEMP TABLE t_sp AS SELECT current_setting('search_path') AS sp;
CREATE TEMP TABLE t_h0 AS SELECT tests.huella_saldos() AS h, (SELECT count(*) FROM audit.evento) AS ev;
CREATE TEMP TABLE t_i0 AS SELECT pg_temp.informe() AS j;
SELECT assert_eq('A1 banco sano: ok = true, todos los desvios en 0 y las 6 secciones de detalle VACIAS ([])',
                 (SELECT (j ->> 'ok', j ->> 'contenedores_con_desvio', j ->> 'grupos_con_error', j ->> 'cuentas_con_desvio_i5u', j ->> 'defensas_fallidas', j ->> 'controles_auth_fallidos', j ->> 'creditos_con_plan_incoherente',
                          (SELECT string_agg(k || '=' || jsonb_array_length(j -> 'detalle' -> k), ',' ORDER BY k) FROM jsonb_object_keys(j -> 'detalle') k))::text FROM t_i0),
                 '(true,0,0,0,0,0,0,"auth=0,creditos=0,defensas=0,grupos=0,saldos=0,usuario=0")'::text);
SELECT assert_eq('A2 las claves del informe son EXACTAMENTE las 12 de v_integridad_global + detalle, y cada valor coincide con la vista (una sola fuente de verdad)',
                 ((SELECT array_agg(k ORDER BY k COLLATE "C") FROM t_i0, jsonb_object_keys(j) k),
                  (SELECT count(*) FROM t_i0, jsonb_each_text(j - 'detalle') e, public.v_integridad_global g WHERE e.value IS DISTINCT FROM (to_jsonb(g) ->> e.key)))::text,
                 '("{contenedores_con_desvio,controles_auth_fallidos,creditos_con_plan_incoherente,cuentas,cuentas_borradas,cuentas_con_desvio_i5u,defensas_fallidas,desvio_transferencias,detalle,grupos,grupos_con_error,ok,patas}",0)'::text);
-- el procedimiento puede llamarse dentro de una transaccion: NO debe dejar al llamador con otro search_path (la prueba del propio runner lo detecto: los helpers dejaron de verse)
SELECT assert_eq('A3b el informe RESTAURA el search_path del llamador (set_config local dura hasta el fin de la transaccion): no cambia',
                 (SELECT current_setting('search_path') = (SELECT sp FROM t_sp))::text, 'true'::text);
SELECT assert_eq('A3 el informe es SOLO LECTURA: ni saldos ni libro ni auditoria cambian al llamarlo (y es repetible: dos llamadas = el mismo informe)',
                 (tests.huella_saldos() = (SELECT h FROM t_h0), (SELECT count(*) FROM audit.evento) = (SELECT ev FROM t_h0), pg_temp.informe() = (SELECT j FROM t_i0))::text, '(t,t,t)'::text);

-- ============================================================================
-- B. Cada control DETECTA su sabotaje y la fila defectuosa sale en `detalle`
-- ============================================================================
SELECT tests.detecta('B1 un balance de cuenta alterado (+1): saldos (1 fila CUENTA, diferencia 1) y usuario (I5u), ok = false',
   $s$ALTER TABLE public.cuenta DISABLE TRIGGER trg_zz_proteger_cuenta; UPDATE public.cuenta SET balance = balance + 1 WHERE id = tests.c(2)$s$,
   $d$SELECT (j ->> 'ok') = 'false' AND (j ->> 'contenedores_con_desvio') = '1' AND (j ->> 'cuentas_con_desvio_i5u') = '1' AND jsonb_array_length(j #> '{detalle,saldos}') = 1
          AND (j #>> '{detalle,saldos,0,contenedor}') = 'CUENTA' AND (j #>> '{detalle,saldos,0,diferencia}')::numeric = 1 AND jsonb_array_length(j #> '{detalle,usuario}') = 1 FROM (SELECT pg_temp.informe() AS j) x$d$);
SELECT tests.detecta('B2 un balance de bolsillo alterado: 1 fila BOLSILLO en saldos',
   $s$ALTER TABLE public.bolsillo DISABLE TRIGGER trg_zz_proteger_bolsillo; UPDATE public.bolsillo SET balance = balance - 1$s$,
   $d$SELECT (j ->> 'ok') = 'false' AND (j #>> '{detalle,saldos,0,contenedor}') = 'BOLSILLO' AND jsonb_array_length(j #> '{detalle,saldos}') = 1 FROM (SELECT pg_temp.informe() AS j) x$d$);
SELECT tests.detecta('B3 un generado_acumulado de CDT alterado: 2 filas (CDT_GENERADO y CDT_INVERSION)',
   $s$ALTER TABLE public.cdt DISABLE TRIGGER trg_zz_proteger_cdt; UPDATE public.cdt SET generado_acumulado = 5$s$,
   $d$SELECT jsonb_array_length(j #> '{detalle,saldos}') = 2 AND (SELECT array_agg(e ->> 'contenedor' ORDER BY e ->> 'contenedor') FROM jsonb_array_elements(j #> '{detalle,saldos}') e) = ARRAY['CDT_GENERADO', 'CDT_INVERSION'] FROM (SELECT pg_temp.informe() AS j) x$d$);
SELECT tests.detecta('B4 un capital_pendiente de credito alterado: 1 fila CREDITO en saldos y 1 de I5u',
   $s$ALTER TABLE public.credito DISABLE TRIGGER trg_zz_proteger_credito; UPDATE public.credito SET capital_pendiente = capital_pendiente - 1$s$,
   $d$SELECT (j #>> '{detalle,saldos,0,contenedor}') = 'CREDITO' AND (j ->> 'cuentas_con_desvio_i5u') = '1' FROM (SELECT pg_temp.informe() AS j) x$d$);
SELECT tests.detecta('B5 una pata suelta (grupo de una sola pata): grupos_con_error = 1 y la fila en detalle.grupos con estado ERROR',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER USER; SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000001', 'DEPOSITO_BANCO', 'CUENTA', 'E', 100, tests.c(1))$s$,
   $d$SELECT (j ->> 'grupos_con_error') = '1' AND (j #>> '{detalle,grupos,0,grupo_id}') = 'cccccccc-0000-4000-8000-000000000001' AND (j #>> '{detalle,grupos,0,estado}') = 'ERROR' FROM (SELECT pg_temp.informe() AS j) x$d$);
SELECT tests.detecta('B6 un grupo descuadrado (100 contra 99): detalle.grupos lo trae',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER USER; SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000002', 'DEPOSITO_BANCO', 'CUENTA', 'E', 100, tests.c(1)); SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000002', 'DEPOSITO_BANCO', 'RESULTADO', 'E', 99, tests.c(1))$s$,
   $d$SELECT (SELECT bool_or(e ->> 'grupo_id' = 'cccccccc-0000-4000-8000-000000000002') FROM jsonb_array_elements(j #> '{detalle,grupos}') e) FROM (SELECT pg_temp.informe() AS j) x$d$);
SELECT tests.detecta('B7 una DEFENSA caida (guardia de cuenta desactivado): defensas_fallidas >= 1 y el control con su nombre en detalle.defensas',
   $s$ALTER TABLE public.cuenta DISABLE TRIGGER trg_zz_proteger_cuenta$s$,
   $d$SELECT (j ->> 'defensas_fallidas')::int >= 1 AND (SELECT bool_or(e ->> 'control' = 'trigger activo: cuenta.trg_zz_proteger_cuenta') FROM jsonb_array_elements(j #> '{detalle,defensas}') e) AND (j ->> 'ok') = 'false' FROM (SELECT pg_temp.informe() AS j) x$d$);
SELECT tests.detecta('B8 un permiso de mas (banco_app recibe UPDATE de un acumulador): la defensa de roles cae y sale en detalle.defensas',
   $s$GRANT UPDATE (balance) ON public.cuenta TO banco_app$s$,
   $d$SELECT (SELECT bool_or(e ->> 'control' LIKE 'roles de acceso%') FROM jsonb_array_elements(j #> '{detalle,defensas}') e) FROM (SELECT pg_temp.informe() AS j) x$d$);
SELECT tests.detecta('B9 la lista blanca de banco_app rota (se concede EXECUTE de una interna): la defensa de las 40 funciones cae',
   $s$GRANT EXECUTE ON FUNCTION public._reglas_control() TO banco_app$s$,
   $d$SELECT (SELECT bool_or(e ->> 'control' LIKE 'banco_app ejecuta EXACTAMENTE las 40%') FROM jsonb_array_elements(j #> '{detalle,defensas}') e) FROM (SELECT pg_temp.informe() AS j) x$d$);
SELECT tests.detecta('B10 un CLIENTE sin cuenta (autenticacion): controles_auth_fallidos >= 1 y la fila en detalle.auth',
   $s$INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento) VALUES (tests.u(77), 'sincuenta', 'h', 'S', 'C', '9777', 's77@t.co', '3777', DATE '1990-01-01')$s$,
   $d$SELECT (j ->> 'controles_auth_fallidos')::int >= 1 AND jsonb_array_length(j #> '{detalle,auth}') >= 1 AND (j ->> 'ok') = 'false' FROM (SELECT pg_temp.informe() AS j) x$d$);
SELECT tests.detecta('B11 un capital_pendiente que ya no cuadra con el plan de cuotas: creditos_con_plan_incoherente = 1 y la fila en detalle.creditos',
   $s$ALTER TABLE public.credito DISABLE TRIGGER trg_zz_proteger_credito; UPDATE public.credito SET capital_pendiente = capital_pendiente - 1$s$,
   $d$SELECT (j ->> 'creditos_con_plan_incoherente') = '1' AND jsonb_array_length(j #> '{detalle,creditos}') = 1 AND (j ->> 'ok') = 'false' FROM (SELECT pg_temp.informe() AS j) x$d$);
SELECT tests.detecta('B12 un ENVIO que perdio a su RECIBO con la cuenta contraria VIVA es un error real (detalle.grupos), no un huerfano esperado',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER USER; INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, saldo_previo, saldo_posterior, cuenta_id, contraparte_nombre, contraparte_cuenta)
        VALUES ('cccccccc-0000-4000-8000-000000000003', now(), 'ENVIO', 'CUENTA', 'S', 50, 1000, 950, tests.c(1), 'X', (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(2)))$s$,
   $d$SELECT (j ->> 'grupos_con_error') = '1' FROM (SELECT pg_temp.informe() AS j) x$d$);
-- tope de filas de muestra: 30 defectos reales = conteo 30 y 20 filas en la muestra
SELECT count(tests.cliente(n)) FROM generate_series(100, 129) n;
SELECT tests.detecta('B13 30 saldos alterados: el CONTEO es el real (30) y el detalle trae a lo sumo 20 filas (muestra_max)',
   $s$ALTER TABLE public.cuenta DISABLE TRIGGER trg_zz_proteger_cuenta; UPDATE public.cuenta SET balance = balance + 1 WHERE id IN (SELECT tests.c(n) FROM generate_series(100, 129) n)$s$,
   $d$SELECT (j ->> 'contenedores_con_desvio') = '30' AND jsonb_array_length(j #> '{detalle,saldos}') = 20 AND (j ->> 'cuentas_con_desvio_i5u') = '30' AND jsonb_array_length(j #> '{detalle,usuario}') = 20 FROM (SELECT pg_temp.informe() AS j) x$d$);
SELECT assert_eq('B14 despues de todos los sabotajes (deshechos) el banco vuelve a estar sano: ok = true y detalle vacio', (SELECT (pg_temp.informe() ->> 'ok', jsonb_array_length(pg_temp.informe() #> '{detalle,saldos}'))::text), '(true,0)'::text);

-- ============================================================================
-- C. Catalogo, permisos y el search_path en CADA transaccion
-- ============================================================================
SELECT assert_eq('C1 los 2 procedimientos: prokind = p, SECURITY INVOKER y SIN clausula SET (la unica forma de poder hacer COMMIT), con COMMENT, dueño banco_owner',
                 (SELECT (count(*), bool_and(prokind = 'p'), bool_or(prosecdef), bool_or(proconfig IS NOT NULL), bool_and(obj_description(oid, 'pg_proc') IS NOT NULL), bool_and(pg_get_userbyid(proowner) = 'banco_owner'))::text
                    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('sp_avanzar_todos', 'sp_verificar_integridad')), '(2,t,f,f,t,t)'::text);
SELECT assert_eq('C2 NADIE salvo dueño/superusuario los ejecuta: ni PUBLIC, ni banco_app, ni banco_lector, ni banco_dev (los 2 procedimientos y _reglas_mantenimiento)',
                 (SELECT (count(*), count(*) FILTER (WHERE has_function_privilege('banco_app', oid, 'EXECUTE') OR has_function_privilege('banco_lector', oid, 'EXECUTE') OR has_function_privilege('banco_dev', oid, 'EXECUTE')),
                          count(*) FILTER (WHERE EXISTS (SELECT 1 FROM aclexplode(coalesce(proacl, acldefault('f', proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))::text
                    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('sp_avanzar_todos', 'sp_verificar_integridad', '_reglas_mantenimiento')), '(3,0,0)'::text);
SELECT assert_raises('C3 banco_lector NO puede ejecutar sp_verificar_integridad (permiso denegado)', $$SET LOCAL ROLE banco_lector; CALL public.sp_verificar_integridad()$$, NULL, '42501');
SELECT assert_raises('C4 banco_app NO puede ejecutar sp_avanzar_todos (permiso denegado)', $$SET LOCAL ROLE banco_app; CALL public.sp_avanzar_todos()$$, NULL, '42501');
CREATE FUNCTION pg_temp.secuencia(p_src text) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT string_agg(m.l, '' ORDER BY m.pos) FROM (
    SELECT g AS pos, 'S' AS l FROM generate_series(1, length(p_src)) g WHERE substr(p_src, g, length('set_config(''search_path''')) = 'set_config(''search_path'''
    UNION ALL SELECT g, 'C' FROM generate_series(1, length(p_src)) g WHERE substr(p_src, g, 7) = 'COMMIT;'
    UNION ALL SELECT g, 'F' FROM generate_series(1, length(p_src)) g WHERE substr(p_src, g, 7) = 'FOREACH'
    UNION ALL SELECT g, 'E' FROM generate_series(1, length(p_src)) g WHERE substr(p_src, g, 8) = 'END LOOP'
    UNION ALL SELECT g, 'R' FROM generate_series(1, length(p_src)) g WHERE substr(p_src, g, 20) = '_reloj_instantanea()'
    UNION ALL SELECT g, 'A' FROM generate_series(1, length(p_src)) g WHERE substr(p_src, g, 15) = '_avanzar_hasta(') m $f$;
SELECT assert_eq('C5 AJUSTE 1: en sp_avanzar_todos el orden de las instrucciones es S C F S R A C E S C: set_config del search_path en la transaccion de CAPTURA (S), su COMMIT (C), el bucle (F), set_config al INICIO DE CADA CUENTA (S), la instantanea del reloj DENTRO del bucle (R), el motor (A), el COMMIT de la cuenta (C), fin del bucle (E) y set_config en la transaccion FINAL de auditoria (S) con su COMMIT (C): despues de CADA COMMIT se vuelve a fijar (cada COMMIT descarta lo local)',
                 (SELECT pg_temp.secuencia(prosrc) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'sp_avanzar_todos'), 'SCFSRACESC'::text);
SELECT assert_eq('C6 sp_verificar_integridad fija el search_path y lo RESTAURA al terminar (2 set_config; no hace COMMIT, no escribe: sin INSERT/UPDATE/DELETE/COMMIT en su codigo)',
                 (SELECT ((length(prosrc) - length(replace(prosrc, 'set_config(''search_path''', ''))) / length('set_config(''search_path'''), prosrc ~* '\m(insert|update|delete|truncate|commit|rollback)\M')::text
                    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'sp_verificar_integridad'), '(2,f)'::text);
SELECT assert_eq('C7 AJUSTE 2: el 55P03 (lock_not_available) se cuenta como TIMEOUT DE BLOQUEO (clave omitidas_por_timeout_de_bloqueo, sin asumir que la cuenta estaba ocupada); no existe la clave antigua "omitidas_por_bloqueo" ni "ocupada"',
                 (SELECT (prosrc LIKE '%WHEN lock_not_available%', prosrc LIKE '%omitidas_por_timeout_de_bloqueo%', prosrc ~* '(omitidas_por_bloqueo|ocupada)')::text FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'sp_avanzar_todos'), '(t,t,f)'::text);
SELECT assert_eq('C8 cada cuenta usa SU instantanea del reloj y el motor de E7-E9: UNA _reloj_instantanea() y UNA _avanzar_hasta en el bucle; ningun INSERT en transaccion ni lectura suelta del reloj',
                 (SELECT ((length(prosrc) - length(replace(prosrc, '_reloj_instantanea()', ''))) / length('_reloj_instantanea()'), (length(prosrc) - length(replace(prosrc, '_avanzar_hasta(', ''))) / length('_avanzar_hasta('),
                          prosrc ~* '(insert\s+into\s+public\.transaccion|_asentar_grupo|now\s*\(|current_date|hoy_banco|ahora_banco|_ahora_real)')::text FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'sp_avanzar_todos'), '(1,1,f)'::text);
SELECT assert_eq('C9 valores provisionales fijados en _reglas_mantenimiento(): lock_timeout 2s, errores_max 20, muestra_max 20', public._reglas_mantenimiento(), jsonb_build_object('lock_timeout', '2s', 'errores_max', 20, 'muestra_max', 20));
CREATE TEMP TABLE t_h1 AS SELECT tests.huella_saldos() AS h;
SELECT assert_raises('C10 sp_avanzar_todos DENTRO de una transaccion falla con "invalid transaction termination" (SQLSTATE 2D000): hay que llamarlo SOLO (autocommit)', $$CALL public.sp_avanzar_todos()$$, 'invalid transaction termination', '2D000');
SELECT assert_eq('C11 ...y ese intento fallido no dejo NADA: ni evento de auditoria ni cambios', ((SELECT count(*) FROM audit.evento WHERE accion = 'MANTENIMIENTO_AVANZAR'), tests.huella_saldos() = (SELECT h FROM t_h1))::text, '(0,t)'::text);

ROLLBACK;
