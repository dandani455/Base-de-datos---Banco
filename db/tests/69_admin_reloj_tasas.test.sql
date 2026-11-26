-- 69_admin_reloj_tasas.test.sql · Etapa 11 · admin_get_reloj / admin_set_reloj, admin_get_tasas / admin_set_tasa_cdt / _credito / _mora y el CONTROL DE ACCESO de las 12 funciones admin_*.
-- Riesgos NUEVOS: la forma del contrato del reloj y la atribucion del cambio al admin; las tasas llegan como TEXTO y se validan en un solo lugar (_parse_tasa); lo ya creado NO cambia;
-- la secuencia EXACTA del backend (BEGIN, 3 llamadas, ROLLBACK/COMMIT) deja todo o nada; un cliente, un desconocido o un admin bloqueado no pueden usar NINGUNA de las 12;
-- permisos, catalogo (_validar_admin primero, una sola via de auditoria, sin reloj suelto). No repite E3 (trigger del reloj) ni E1/E2.
-- Una transaccion con ROLLBACK final; solo corre en banco_test/banco_mut (mueve el reloj).
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 3) n;
SELECT count(tests.cliente(n)) FROM generate_series(31, 33) n;
INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol) VALUES
  (tests.u(900), 'admin900', 'h', 'Ada', 'Admin', '9000000900', 'a900@t.co', '3000000900', DATE '1980-01-01', 'ADMIN'),
  (tests.u(901), 'admin901', 'h', 'Beto', 'Admin', '9000000901', 'a901@t.co', '3000000901', DATE '1980-01-01', 'ADMIN'),
  (tests.u(902), 'admin902', 'h', 'Cleo', 'Admin', '9000000902', 'a902@t.co', '3000000902', DATE '1980-01-01', 'ADMIN');
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES (tests.p(930), 'CDT 30', 30, 10, 1), (tests.p(931), 'CDT 90', 90, 11, 1);
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES
  (tests.p(901), 'Libre', '', 18, 1, 1000000000, 1, 360), (tests.p(902), 'Vehiculo', '', 20, 1, 1000000000, 1, 360);
CREATE TEMP TABLE t_b AS SELECT public.hoy_banco() AS d;
CREATE FUNCTION pg_temp.dia(p_n int) RETURNS date LANGUAGE sql STABLE AS $f$ SELECT (SELECT d FROM t_b) + p_n $f$;
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN EXECUTE p_sql; RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN CASE WHEN SQLSTATE = 'P0001' THEN SQLERRM ELSE 'NO-P0001 ' || SQLSTATE || ': ' || SQLERRM END; END $f$;
CREATE FUNCTION pg_temp.ptasa(p_t text, p_cero boolean) RETURNS text LANGUAGE sql AS $f$ SELECT pg_temp.err(format('SELECT public._parse_tasa(%L, %L)', p_t, p_cero)) $f$;
CREATE FUNCTION pg_temp.ev(p_accion text) RETURNS bigint LANGUAGE sql STABLE AS $f$ SELECT count(*) FROM audit.evento WHERE accion = p_accion $f$;
SELECT public._reloj_actualizar(true, '');
SELECT tests.fondear(tests.c(1), 5000000);                                   -- el banco deja de estar vacio: el reloj ya no puede retroceder

-- ============================================================================
-- A. Reloj
-- ============================================================================
SELECT assert_eq('A1 admin_get_reloj en modo real: {usar_fecha_real: true, fecha_sistema: null, fecha_actual: hoy} (el contrato) y es exactamente la vista de E3',
                 (SELECT (public.admin_get_reloj(tests.u(900)) = public._reloj_vista(), public.admin_get_reloj(tests.u(900)) -> 'usar_fecha_real', jsonb_typeof(public.admin_get_reloj(tests.u(900)) -> 'fecha_sistema'),
                          public.admin_get_reloj(tests.u(900)) ->> 'fecha_actual' = (SELECT d::text FROM t_b))::text), '(t,true,null,t)'::text);
CREATE TEMP TABLE t_r1 AS SELECT public.admin_set_reloj(tests.u(900), false, pg_temp.dia(5)::text) AS r;
SELECT assert_eq('A2 set a una fecha futura: devuelve la vista nueva (usar false, fecha_sistema y fecha_actual = hoy+5) y get la confirma',
                 (SELECT (r ->> 'usar_fecha_real', r ->> 'fecha_sistema', r ->> 'fecha_actual', r = public.admin_get_reloj(tests.u(900)))::text FROM t_r1), ('(false,' || pg_temp.dia(5) || ',' || pg_temp.dia(5) || ',t)')::text);
SELECT assert_eq('A3 el cambio queda atribuido al ADMIN: RELOJ_CAMBIO (E3) con actor_username admin900', (SELECT (count(*), min(actor_username))::text FROM audit.evento WHERE accion = 'RELOJ_CAMBIO'), '(1,admin900)'::text);
SELECT assert_eq('A4 retroceder = "El reloj no puede retroceder" y el reloj no se mueve', (pg_temp.err(format('SELECT public.admin_set_reloj(tests.u(900), false, %L)', pg_temp.dia(2)::text)), public.admin_get_reloj(tests.u(900)) ->> 'fecha_sistema')::text,
                 ('("El reloj no puede retroceder",' || pg_temp.dia(5) || ')')::text);
SELECT assert_eq('A5 fecha invalida, vacia, NULL, texto o inexistente en modo manual = "Fecha inválida"',
                 (SELECT array_agg(DISTINCT pg_temp.err(format('SELECT public.admin_set_reloj(tests.u(900), false, %s)', v))) FROM unnest(ARRAY[quote_literal('2026-13-45'), quote_literal(''), 'NULL', quote_literal('abc'), quote_literal('1999-12-31'), quote_literal('2026-02-30')]) v),
                 ARRAY['Fecha inválida']::text[]);
SELECT assert_eq('A6 usar_fecha_real NULL = el mensaje de E3 (obligatorio)', pg_temp.err($$SELECT public.admin_set_reloj(tests.u(900), NULL, '2027-01-01')$$), 'Reloj: usar_fecha_real es obligatorio'::text);
SELECT assert_eq('A7 igualar o adelantar sigue permitido: el mismo dia y +10',
                 (pg_temp.err(format('SELECT public.admin_set_reloj(tests.u(900), false, %L)', pg_temp.dia(5)::text)), pg_temp.err(format('SELECT public.admin_set_reloj(tests.u(900), false, %L)', pg_temp.dia(10)::text)))::text, '(OK,OK)'::text);
CREATE TEMP TABLE t_r2 AS SELECT public.admin_set_reloj(tests.u(900), true, 'cualquier-cosa-que-mande-el-front') AS r;
SELECT assert_eq('A8 volver a real SIEMPRE se permite y la fecha que mande el front (basura incluida) se IGNORA: fecha_sistema null',
                 (SELECT (r ->> 'usar_fecha_real', jsonb_typeof(r -> 'fecha_sistema'), r = public.admin_get_reloj(tests.u(900)), (SELECT fecha_sistema FROM public.reloj) IS NULL)::text FROM t_r2), '(true,null,t,t)'::text);
SELECT assert_eq('A9 en modo real tambien se acepta fecha vacia o NULL', (pg_temp.err($$SELECT public.admin_set_reloj(tests.u(900), true, '')$$), pg_temp.err($$SELECT public.admin_set_reloj(tests.u(900), true, NULL)$$))::text, '(OK,OK)'::text);
SELECT assert_eq('A10 los cambios con efecto se auditan atribuidos (adelanto a +5, +10 y vuelta a real = 3); real -> real no agrega nada',
                 (SELECT (count(*), count(*) FILTER (WHERE actor_username = 'admin900'))::text FROM audit.evento WHERE accion = 'RELOJ_CAMBIO'), '(3,3)'::text);

-- ============================================================================
-- B. Tasas: lectura
-- ============================================================================
CREATE TEMP TABLE t_t0 AS SELECT public.admin_get_tasas(tests.u(900)) AS j;
SELECT assert_json_shape('B1 forma del contrato (AdminTasas): {cdts, creditos, mora}', (SELECT j FROM t_t0), '{"cdts":"array","creditos":"array","mora":"number"}'::jsonb);
SELECT assert_eq('B2 cada elemento {id, nombre, tasa} con tasa NUMERO, ordenados por nombre',
                 (SELECT (jsonb_array_length(j -> 'cdts'), jsonb_array_length(j -> 'creditos'),
                          (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(j #> '{cdts,0}') k), jsonb_typeof(j #> '{cdts,0,tasa}'), jsonb_typeof(j #> '{creditos,1,tasa}'),
                          (SELECT string_agg(e ->> 'nombre', ',' ORDER BY o) FROM jsonb_array_elements(j -> 'cdts') WITH ORDINALITY x(e, o)),
                          (SELECT string_agg(e ->> 'nombre', ',' ORDER BY o) FROM jsonb_array_elements(j -> 'creditos') WITH ORDINALITY x(e, o)))::text FROM t_t0),
                 '(2,2,"{id,nombre,tasa}",number,number,"CDT 30,CDT 90","Libre,Vehiculo")'::text);
SELECT assert_eq('B3 los valores salen como numeros exactos (10, 11, 18, 20)', (SELECT concat_ws('|', (j #>> '{cdts,0,tasa}')::numeric, (j #>> '{cdts,1,tasa}')::numeric, (j #>> '{creditos,0,tasa}')::numeric, (j #>> '{creditos,1,tasa}')::numeric) FROM t_t0), '10.000|11.000|18.000|20.000'::text);
SELECT assert_eq('B4 D-E11-D7a (PROVISIONAL): la mora sin valor (NULL, sin mora) se LEE como 0 (numero), y la BD sigue en NULL',
                 (SELECT ((j ->> 'mora')::numeric, jsonb_typeof(j -> 'mora'), (SELECT tasa_mora_anual FROM public.parametro) IS NULL)::text FROM t_t0), '(0,number,t)'::text);
UPDATE public.parametro SET tasa_mora_anual = 30;
SELECT assert_eq('B5 con una mora cargada se lee tal cual (30)', (public.admin_get_tasas(tests.u(900)) ->> 'mora')::numeric, 30::numeric);
UPDATE public.parametro SET tasa_mora_anual = NULL;
SELECT assert_eq('B6 las 3 lecturas de admin son jsonb y no escriben nada (huella y auditoria intactas)',
                 (SELECT ((SELECT count(*) FROM audit.evento WHERE accion = 'TASA_CAMBIO'), jsonb_typeof(public.admin_get_tasas(tests.u(900))), jsonb_typeof(public.admin_get_reloj(tests.u(900))), jsonb_typeof(public.admin_listar_usuarios(tests.u(900))))::text), '(0,object,object,array)'::text);

-- ============================================================================
-- C. _parse_tasa: la UNICA validacion (texto -> numero)
-- ============================================================================
SELECT assert_eq('C1 validas: 0.001, 1, 12.5, 100, 100.000, 12.5000 (ceros a la derecha), 012 y con espacios',
                 (SELECT array_agg(pg_temp.ptasa(v, false) ORDER BY o) FROM unnest(ARRAY['0.001', '1', '12.5', '100', '100.000', '12.5000', '012', ' 12.5 ']) WITH ORDINALITY x(v, o)), ARRAY_FILL('OK'::text, ARRAY[8]));
SELECT assert_eq('C2 los valores se normalizan: 12.5000 -> 12.5, 012 -> 12, 100.000 -> 100',
                 (public._parse_tasa('12.5000', false), public._parse_tasa('012', false), public._parse_tasa('100.000', false))::text, '(12.5,12,100)'::text);
SELECT assert_eq('C3 invalidas = "Tasa inválida" (nunca un error de driver): vacia, NULL, texto, signos, exponente, coma, 0, 0.000, 100.001, 4 decimales, 1000, doble punto, sin entero, sin decimales, digitos no ASCII',
                 (SELECT array_agg(DISTINCT pg_temp.ptasa(v, false)) FROM unnest(ARRAY['', ' ', 'abc', '-1', '+5', '1e2', '12,5', '0', '0.000', '100.001', '100.0001', '12.3456', '1000', '12.5.3', '.5', '5.', '1 2', '１２']) v),
                 ARRAY['Tasa inválida']::text[]);
SELECT assert_eq('C4 NULL tambien es "Tasa inválida"', pg_temp.err($$SELECT public._parse_tasa(NULL, false)$$), 'Tasa inválida'::text);
SELECT assert_eq('C5 solo con p_permite_cero (la mora, D-E11-D7a) se acepta 0 y 0.000; los negativos y lo demas siguen invalidos',
                 (pg_temp.ptasa('0', true), pg_temp.ptasa('0.000', true), pg_temp.ptasa('-0', true), pg_temp.ptasa('100.001', true), pg_temp.ptasa('0', false))::text, '(OK,OK,"Tasa inválida","Tasa inválida","Tasa inválida")'::text);
SELECT assert_eq('C6 el mensaje y los limites viven en _reglas_admin(): "Tasa inválida", 100 y 3 decimales',
                 (public._reglas_admin() ->> 'msg_tasa', public._reglas_admin() ->> 'tasa_max', public._reglas_admin() ->> 'tasa_decimales')::text, '("Tasa inválida",100,3)'::text);

-- ============================================================================
-- D. Tasas: escritura
-- ============================================================================
CREATE TEMP TABLE t_s1 AS SELECT public.admin_set_tasa_cdt(tests.u(900), tests.p(930)::text, '12.5') AS a, public.admin_set_tasa_credito(tests.u(900), tests.p(901)::text, '19.25') AS b, public.admin_set_tasa_mora(tests.u(900), '30') AS c;
SELECT assert_eq('D1 las 3 devuelven {id, tasa} / {mora} con numeros y la tabla cambia',
                 (SELECT ((a ->> 'tasa')::numeric, a ->> 'id' = tests.p(930)::text, (b ->> 'tasa')::numeric, (c ->> 'mora')::numeric, jsonb_typeof(a -> 'tasa'), jsonb_typeof(c -> 'mora'),
                          (SELECT tasa_anual::numeric FROM public.cdt_definicion WHERE id = tests.p(930)), (SELECT tasa_anual::numeric FROM public.credito_producto WHERE id = tests.p(901)), (SELECT tasa_mora_anual::numeric FROM public.parametro))::text FROM t_s1),
                 '(12.5,t,19.25,30,number,number,12.500,19.250,30.000)'::text);
SELECT assert_eq('D2 la lectura refleja lo escrito (admin_get_tasas)', (SELECT concat_ws('|', (j #>> '{cdts,0,tasa}')::numeric, (j #>> '{creditos,0,tasa}')::numeric, (j ->> 'mora')::numeric) FROM (SELECT public.admin_get_tasas(tests.u(900)) AS j) x), '12.500|19.250|30.000'::text);
SELECT assert_eq('D3 cada cambio escribe UN evento TASA_CAMBIO (actor admin, entidad, antes y despues)',
                 (SELECT (count(*), count(*) FILTER (WHERE actor_username = 'admin900' AND actor_id = tests.u(900)),
                          (SELECT (antes ->> 'tasa', despues ->> 'tasa') FROM audit.evento WHERE accion = 'TASA_CAMBIO' AND entidad = 'cdt_definicion'),
                          (SELECT (antes ->> 'tasa', despues ->> 'tasa') FROM audit.evento WHERE accion = 'TASA_CAMBIO' AND entidad = 'credito_producto'),
                          (SELECT (entidad_id, antes ->> 'mora', despues ->> 'mora') FROM audit.evento WHERE accion = 'TASA_CAMBIO' AND entidad = 'parametro'))::text FROM audit.evento WHERE accion = 'TASA_CAMBIO'),
                 '(3,3,"(10.000,12.5)","(18.000,19.25)","(1,0,30)")'::text);
SELECT public.admin_set_tasa_cdt(tests.u(900), tests.p(930)::text, '12.50');
SELECT assert_eq('D4 guardar el MISMO valor (el front reenvia todo el formulario) no cambia nada ni agrega evento', pg_temp.ev('TASA_CAMBIO'), 3::bigint);
CREATE TEMP TABLE t_d5 AS SELECT public.admin_set_tasa_mora(tests.u(900), '0') AS r;
SELECT assert_eq('D5 D-E11-D7a (PROVISIONAL): mora "0" = sin mora (se guarda NULL, el significado de E9) y se lee 0; "0" en un CDT o crédito es invalido',
                 ((SELECT r ->> 'mora' FROM t_d5), (SELECT tasa_mora_anual IS NULL FROM public.parametro), (public.admin_get_tasas(tests.u(900)) ->> 'mora')::numeric,
                  pg_temp.err(format('SELECT public.admin_set_tasa_cdt(tests.u(900), %L, ''0'')', tests.p(930)::text)), pg_temp.err(format('SELECT public.admin_set_tasa_credito(tests.u(900), %L, ''0'')', tests.p(901)::text)))::text,
                 '(0,t,0,"Tasa inválida","Tasa inválida")'::text);
SELECT assert_eq('D6a ...y ese paso 30 -> 0 tambien se audita (4 eventos)', pg_temp.ev('TASA_CAMBIO'), 4::bigint);
SELECT public.admin_set_tasa_mora(tests.u(900), '0.000');
SELECT assert_eq('D6b repetir "0" no agrega otro evento', pg_temp.ev('TASA_CAMBIO'), 4::bigint);
SELECT assert_eq('D7 tasa invalida en cada una (100.5, texto, 4 decimales, NULL): "Tasa inválida" y nada cambia',
                 (SELECT array_agg(DISTINCT pg_temp.err(format(f, v))) FROM unnest(ARRAY['SELECT public.admin_set_tasa_cdt(tests.u(900), ''' || tests.p(930)::text || ''', %s)', 'SELECT public.admin_set_tasa_credito(tests.u(900), ''' || tests.p(901)::text || ''', %s)', 'SELECT public.admin_set_tasa_mora(tests.u(900), %s)']) f,
                                                                                    unnest(ARRAY[quote_literal('100.5'), quote_literal('doce'), quote_literal('1.2345'), 'NULL']) v),
                 ARRAY['Tasa inválida']::text[]);
SELECT assert_eq('D8 id invalido: desconocido, mal formado, vacio y NULL = "Recurso no encontrado" (cdt y credito; no se ignora en silencio); el id de un credito NO sirve para un CDT',
                 (SELECT array_agg(DISTINCT pg_temp.err(format(f, v))) FROM unnest(ARRAY['SELECT public.admin_set_tasa_cdt(tests.u(900), %s, ''10'')', 'SELECT public.admin_set_tasa_credito(tests.u(900), %s, ''10'')']) f,
                                                                                    unnest(ARRAY[quote_literal('00000000-0000-4000-8000-000000000999'), quote_literal('x'), quote_literal(''), 'NULL', quote_literal(tests.p(901)::text)]) v WHERE NOT (f LIKE '%credito%' AND v = quote_literal(tests.p(901)::text))),
                 ARRAY['Recurso no encontrado']::text[]);
SELECT assert_eq('D9 el orden: primero la tasa, despues el id (tasa y id invalidos = "Tasa inválida")', pg_temp.err($$SELECT public.admin_set_tasa_cdt(tests.u(900), 'x', 'abc')$$), 'Tasa inválida'::text);
SELECT assert_eq('D10 el advisory lock de tasas queda tomado hasta el fin de la transaccion (un formulario completo a la vez)',
                 (SELECT count(*) >= 1 FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted), true);

-- ============================================================================
-- E. Lo YA CREADO no cambia: la tasa se copia al crear (CDT y credito)
-- ============================================================================
SELECT tests.fondear(tests.c(31), 6000000);
SELECT tests.fondear(tests.c(32), 6000000);
UPDATE public.cdt_definicion SET tasa_anual = 10 WHERE id = tests.p(930);
UPDATE public.credito_producto SET tasa_anual = 18 WHERE id = tests.p(901);
CREATE TEMP TABLE t_x1 AS SELECT public.crear_cdt(tests.u(31), tests.p(930)::text, 1000000) ->> 'id' AS cdt,
                                 (public.solicitar_credito(tests.u(31), tests.p(901)::text, 1200000, 12) ->> 'id')::uuid AS cre;
CREATE TEMP TABLE t_x2 AS SELECT (SELECT tasa_anual::numeric FROM public.cdt WHERE id = (SELECT cdt FROM t_x1)::uuid) AS tasa_cdt, (SELECT tasa_anual::numeric FROM public.credito WHERE id = (SELECT cre FROM t_x1)) AS tasa_cre,
                                 (SELECT string_agg(valor_cuota_original::text, ',' ORDER BY numero) FROM public.cuota WHERE credito_id = (SELECT cre FROM t_x1)) AS cuotas,
                                 (SELECT generado_acumulado FROM public.cdt WHERE id = (SELECT cdt FROM t_x1)::uuid) AS gen;
SELECT public.admin_set_tasa_cdt(tests.u(900), tests.p(930)::text, '40');
SELECT public.admin_set_tasa_credito(tests.u(900), tests.p(901)::text, '35');
SELECT assert_eq('E1 el CDT y el credito YA creados conservan su tasa y su plan de cuotas tras cambiar las tasas',
                 ((SELECT tasa_anual::numeric FROM public.cdt WHERE id = (SELECT cdt FROM t_x1)::uuid), (SELECT tasa_cdt FROM t_x2), (SELECT tasa_anual::numeric FROM public.credito WHERE id = (SELECT cre FROM t_x1)), (SELECT tasa_cre FROM t_x2),
                  (SELECT string_agg(valor_cuota_original::text, ',' ORDER BY numero) FROM public.cuota WHERE credito_id = (SELECT cre FROM t_x1)) = (SELECT cuotas FROM t_x2))::text, '(10.000,10.000,18.000,18.000,t)'::text);
CREATE TEMP TABLE t_x3 AS SELECT public.crear_cdt(tests.u(32), tests.p(930)::text, 1000000) ->> 'id' AS cdt, (public.solicitar_credito(tests.u(32), tests.p(901)::text, 1200000, 12) ->> 'id')::uuid AS cre;
SELECT assert_eq('E2 los NUEVOS usan la tasa nueva (40 y 35) y su cuota es mayor que la del anterior',
                 ((SELECT tasa_anual::numeric FROM public.cdt WHERE id = (SELECT cdt FROM t_x3)::uuid), (SELECT tasa_anual::numeric FROM public.credito WHERE id = (SELECT cre FROM t_x3)),
                  (SELECT max(valor_cuota_original) FROM public.cuota WHERE credito_id = (SELECT cre FROM t_x3)) > (SELECT max(valor_cuota_original) FROM public.cuota WHERE credito_id = (SELECT cre FROM t_x1)))::text, '(40.000,35.000,t)'::text);

-- ============================================================================
-- F. La secuencia del BACKEND (PUT /admin/tasas = db.tx: BEGIN, las 3 llamadas, COMMIT o ROLLBACK)
-- ============================================================================
UPDATE public.cdt_definicion SET tasa_anual = 10 WHERE id = tests.p(930);
UPDATE public.credito_producto SET tasa_anual = 18 WHERE id = tests.p(901);
UPDATE public.parametro SET tasa_mora_anual = NULL;
CREATE TEMP TABLE t_f0 AS SELECT (SELECT count(*) FROM audit.evento) AS ev, public.admin_get_tasas(tests.u(900)) AS j;
SAVEPOINT s_bk;
SELECT public.admin_set_tasa_cdt(tests.u(900), tests.p(930)::text, '21');
SELECT pg_temp.err(format('SELECT public.admin_set_tasa_credito(tests.u(900), %L, ''2o'')', tests.p(901)::text));      -- la 2a llamada falla: el backend reacciona con ROLLBACK
ROLLBACK TO SAVEPOINT s_bk;
SELECT assert_eq('F1 BEGIN; cdt OK; credito INVALIDO; ROLLBACK => NINGUNA tasa cambio y no queda ningun evento (todo o nada del formulario)',
                 (public.admin_get_tasas(tests.u(900)) = (SELECT j FROM t_f0), (SELECT count(*) FROM audit.evento) = (SELECT ev FROM t_f0))::text, '(t,t)'::text);
SAVEPOINT s_bk2;
SELECT public.admin_set_tasa_cdt(tests.u(900), tests.p(930)::text, '21');
SELECT public.admin_set_tasa_credito(tests.u(900), tests.p(901)::text, '22');
SELECT public.admin_set_tasa_mora(tests.u(900), '23');
RELEASE SAVEPOINT s_bk2;
SELECT assert_eq('F2 la misma secuencia valida (COMMIT) aplica las 3 tasas y deja sus 3 eventos',
                 ((SELECT concat_ws('|', (j #>> '{cdts,0,tasa}')::numeric, (j #>> '{creditos,0,tasa}')::numeric, (j ->> 'mora')::numeric) FROM (SELECT public.admin_get_tasas(tests.u(900)) AS j) x), (SELECT count(*) FROM audit.evento) - (SELECT ev FROM t_f0))::text, '(21.000|22.000|23.000,3)'::text);

-- ============================================================================
-- G. CONTROL DE ACCESO de las 12 funciones
-- ============================================================================
CREATE TEMP TABLE t_fn (f text, extra text);
INSERT INTO t_fn VALUES ('admin_listar_usuarios', ', NULL'), ('admin_detalle_usuario', ', ''x'''), ('admin_bloquear', ', ''x'''), ('admin_desbloquear', ', ''x'''), ('admin_borrar_usuario', ', ''x'''),
  ('admin_ajustar_balance', ', ''x'', 1'), ('admin_get_reloj', ''), ('admin_set_reloj', ', true, NULL'), ('admin_get_tasas', ''), ('admin_set_tasa_cdt', ', ''x'', ''10'''), ('admin_set_tasa_credito', ', ''x'', ''10'''), ('admin_set_tasa_mora', ', ''10'''),
  ('admin_esquema', ''), ('admin_tabla', ', ''usuario''');
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = tests.u(902);
CREATE TEMP TABLE t_g0 AS SELECT tests.huella_saldos() AS h, (SELECT count(*) FROM audit.evento) AS ev, public.admin_get_tasas(tests.u(900)) AS j, public.admin_get_reloj(tests.u(900)) AS r;
SELECT assert_eq('G1 hay EXACTAMENTE 14 funciones admin_* (12 de E11 + 2 del visor de E12) y son las del contrato', (SELECT array_agg(proname::text ORDER BY proname COLLATE "C") FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname LIKE 'admin\_%'), (SELECT array_agg(f ORDER BY f COLLATE "C") FROM t_fn));
SELECT assert_eq('G2 un CLIENTE (con sesion valida) llamando a CADA una de las 12 = "Acceso denegado"',
                 (SELECT array_agg(DISTINCT pg_temp.err(format('SELECT public.%I(%L%s)', f, tests.u(1)::text, extra))) FROM t_fn), ARRAY['Acceso denegado']::text[]);
SELECT assert_eq('G3 un uuid desconocido y un admin_id NULL = "Acceso denegado" en las 12',
                 (SELECT (array_agg(DISTINCT pg_temp.err(format('SELECT public.%I(%L%s)', f, '00000000-0000-4000-8000-000000000999', extra))), array_agg(DISTINCT pg_temp.err(format('SELECT public.%I(NULL::uuid%s)', f, extra))))::text FROM t_fn),
                 '("{""Acceso denegado""}","{""Acceso denegado""}")'::text);
SELECT assert_eq('G4 un ADMIN BLOQUEADO tampoco puede usar ninguna de las 12 (el mensaje de bloqueo)',
                 (SELECT array_agg(DISTINCT pg_temp.err(format('SELECT public.%I(%L%s)', f, tests.u(902)::text, extra))) FROM t_fn), ARRAY[public._msg_auth('bloqueado')]::text[]);
SELECT assert_eq('G5 todos esos rechazos no tocaron NADA: saldos, auditoria, tasas y reloj intactos',
                 (tests.huella_saldos() = (SELECT h FROM t_g0), (SELECT count(*) FROM audit.evento) = (SELECT ev FROM t_g0), public.admin_get_tasas(tests.u(900)) = (SELECT j FROM t_g0), public.admin_get_reloj(tests.u(900)) = (SELECT r FROM t_g0))::text, '(t,t,t,t)'::text);
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = tests.u(3);
SELECT assert_eq('G6 un CLIENTE bloqueado sigue siendo cliente: Acceso denegado (no el mensaje de bloqueo)', pg_temp.err(format('SELECT public.admin_get_reloj(%L)', tests.u(3)::text)), 'Acceso denegado'::text);
SELECT assert_eq('G7 las 12 son SECURITY DEFINER con search_path fijo, devuelven jsonb y ninguna de E11 usa SQL dinamico (EXECUTE; el unico dinamico es admin_tabla de E12, con lista blanca y %I)',
                 (SELECT (count(*), bool_and(prosecdef), bool_and('search_path=public, pg_temp' = ANY (proconfig)), bool_and(prorettype = 'jsonb'::regtype), bool_or(prosrc ~* '\mEXECUTE\M') FILTER (WHERE proname <> 'admin_tabla'))::text FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname LIKE 'admin\_%'),
                 '(14,t,t,t,f)'::text);
SELECT assert_eq('G8 permisos: banco_app y banco_dev ejecutan las 12; PUBLIC y banco_lector ninguna',
                 (SELECT (count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE')), count(*) FILTER (WHERE has_function_privilege('banco_dev', p.oid, 'EXECUTE')),
                          count(*) FILTER (WHERE has_function_privilege('banco_lector', p.oid, 'EXECUTE')),
                          count(*) FILTER (WHERE EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))::text
                    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'admin\_%'), '(14,14,0,0)'::text);
SELECT assert_eq('G9 los 4 helpers (_reglas_admin, _parse_tasa, _cliente_objetivo, _auditar_admin): nadie salvo el dueño (ni banco_app, ni lector, ni dev, ni PUBLIC)',
                 (SELECT (count(*), count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE') OR has_function_privilege('banco_lector', p.oid, 'EXECUTE') OR has_function_privilege('banco_dev', p.oid, 'EXECUTE')
                                                       OR EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))::text
                    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('_reglas_admin', '_parse_tasa', '_cliente_objetivo', '_auditar_admin')), '(4,0)'::text);
SELECT assert_ok('G10 banco_app ejecuta una funcion admin con un admin valido', $$SET LOCAL ROLE banco_app; SELECT public.admin_get_reloj(tests.u(900))$$);
SELECT assert_raises('G11 banco_lector NO puede ejecutarlas (permiso denegado)', $$SET LOCAL ROLE banco_lector; SELECT public.admin_get_reloj(tests.u(900))$$, NULL, '42501');
SELECT assert_raises('G12 banco_app no lee audit.evento', $$SET LOCAL ROLE banco_app; SELECT count(*) FROM audit.evento$$, NULL, '42501');
SELECT assert_raises('G13 banco_app no puede tocar parametro ni las definiciones de tasas', $$SET LOCAL ROLE banco_app; UPDATE public.parametro SET tasa_mora_anual = 99$$, NULL, '42501');
SELECT assert_raises('G14 banco_app no puede borrar usuarios ni bloquearlos directamente', $$SET LOCAL ROLE banco_app; UPDATE public.usuario SET estado = 'BLOQUEADO'$$, NULL, '42501');
SELECT assert_raises('G15 ni siquiera banco_dev puede llamar a los helpers', $$SET LOCAL ROLE banco_dev; SELECT public._parse_tasa('10', false)$$, NULL, '42501');

-- ============================================================================
-- H. Catalogo: el orden y las vias unicas
-- ============================================================================
SELECT assert_eq('H1 _validar_admin es lo PRIMERO que hace cada una de las 12 (antes de leer, validar parametros, bloquear, auditar o escribir)',
                 (SELECT array_agg(DISTINCT p.proname::text) FROM pg_proc p, unnest(ARRAY['_cliente_objetivo(', '_validar_monto(', '_parse_tasa(', 'FROM public.', '_reloj_instantanea', 'UPDATE public', 'DELETE FROM', '_reloj_vista(', '_reloj_actualizar(', 'pg_advisory',
                                                                                    '_auditar_admin(', 'set_config(', 'balance_total(', '_bloquear_cuentas(', 'jsonb_build_object']) m
                   WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'admin\_%'
                     AND (strpos(p.prosrc, '_validar_admin(') = 0 OR (strpos(p.prosrc, m) > 0 AND strpos(p.prosrc, m) < strpos(p.prosrc, '_validar_admin(')))),
                 NULL::text[]);
SELECT assert_eq('H2 las 12 (y los 4 helpers) no leen el reloj suelto: sin now(), current_date, hoy_banco, ahora_banco ni _ahora_real; solo detalle y ajuste toman la instantanea (UNA vez)',
                 (SELECT (count(*) FILTER (WHERE prosrc ~* '(now\s*\(|current_(date|time)|clock_timestamp|statement_timestamp|transaction_timestamp|localtime|hoy_banco|ahora_banco|_ahora_real|pg_sleep)'),
                          array_agg(proname::text ORDER BY proname) FILTER (WHERE prosrc LIKE '%_reloj_instantanea()%'),
                          bool_and((length(prosrc) - length(replace(prosrc, '_reloj_instantanea()', ''))) / length('_reloj_instantanea()') = 1) FILTER (WHERE prosrc LIKE '%_reloj_instantanea()%'))::text
                    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND (proname LIKE 'admin\_%' OR proname IN ('_reglas_admin', '_parse_tasa', '_cliente_objetivo', '_auditar_admin'))),
                 '(0,"{admin_ajustar_balance,admin_detalle_usuario}",t)'::text);
SELECT assert_eq('H3 el dinero se mueve SOLO por _asentar_grupo: ninguna escribe transaccion ni saldos directamente y solo admin_ajustar_balance llama al libro',
                 (SELECT (count(*) FILTER (WHERE prosrc ~* '(insert\s+into\s+public\.transaccion|update\s+public\.(cuenta|bolsillo|cdt|credito)\s|balance\s*=|capital_pendiente\s*=|generado_acumulado\s*=)'),
                          array_agg(proname::text) FILTER (WHERE prosrc LIKE '%_asentar_grupo(%'))::text
                    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND (proname LIKE 'admin\_%' OR proname IN ('_reglas_admin', '_parse_tasa', '_cliente_objetivo', '_auditar_admin'))),
                 '(0,{admin_ajustar_balance})'::text);
SELECT assert_eq('H4 UNA sola via de auditoria: audit.evento solo aparece en _auditar_admin (ninguna publica inserta eventos por su cuenta)',
                 (SELECT array_agg(proname::text) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND (proname LIKE 'admin\_%' OR proname IN ('_reglas_admin', '_parse_tasa', '_cliente_objetivo', '_auditar_admin')) AND prosrc LIKE '%audit.evento%'),
                 ARRAY['_auditar_admin']::text[]);
SELECT assert_eq('H5 las acciones que cambian algo llaman _auditar_admin (bloquear, desbloquear, borrar, ajustar y las 3 tasas); el reloj lo audita el disparador de E3',
                 (SELECT array_agg(proname::text ORDER BY proname) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname LIKE 'admin\_%' AND prosrc LIKE '%_auditar_admin(%'),
                 ARRAY['admin_ajustar_balance', 'admin_bloquear', 'admin_borrar_usuario', 'admin_desbloquear', 'admin_set_tasa_cdt', 'admin_set_tasa_credito', 'admin_set_tasa_mora']::text[]);
SELECT assert_eq('H6 el borrado bloquea la cuenta ANTES de escribir el evento y de borrar; el ajuste: instantanea -> bloqueo -> motor -> libro -> auditoria',
                 ((SELECT strpos(prosrc, '_bloquear_cuentas(') > 0 AND strpos(prosrc, '_bloquear_cuentas(') < strpos(prosrc, '_auditar_admin(') AND strpos(prosrc, '_auditar_admin(') < strpos(prosrc, 'DELETE FROM') FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'admin_borrar_usuario'),
                  (SELECT strpos(prosrc, '_reloj_instantanea()') < strpos(prosrc, '_bloquear_cuentas(') AND strpos(prosrc, '_bloquear_cuentas(') < strpos(prosrc, '_avanzar_hasta(')
                          AND strpos(prosrc, '_avanzar_hasta(') < strpos(prosrc, '_asentar_grupo(') AND strpos(prosrc, '_asentar_grupo(') < strpos(prosrc, '_auditar_admin(') FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'admin_ajustar_balance'))::text,
                 '(t,t)'::text);
SELECT assert_eq('H7 las 3 de tasas toman el MISMO advisory lock (una sola clave) antes de leer/escribir', (SELECT (count(*), bool_and(prosrc LIKE '%hashtextextended(''banco.admin.tasas'', 0)%'), bool_and(strpos(prosrc, 'pg_advisory_xact_lock') < strpos(prosrc, 'UPDATE public.'))
                    )::text FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('admin_set_tasa_cdt', 'admin_set_tasa_credito', 'admin_set_tasa_mora')), '(3,t,t)'::text);
SELECT assert_eq('I1 TODA la secuencia deja los invariantes del libro en orden', (SELECT ok FROM public.v_integridad_global), true);

ROLLBACK;
