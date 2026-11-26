-- 52_bolsillos.test.sql · Etapa 6 · crear_bolsillo, mover_a_bolsillo, retirar_de_bolsillo, mover_entre_bolsillos, vista_balance y balance_total:
-- mensajes exactos y orden, patas del libro (plantilla, contraparte snapshot, fecha/grupo), saldo exacto, nombres, vista (forma, consistencia, aislamiento),
-- atomicidad (fallos en cada pata), una sola instantanea del reloj, ningun camino alternativo al libro y permisos por rol real.
-- No repite las pruebas exhaustivas del libro (E2) ni de transferencias (E5). Una transaccion con ROLLBACK final.
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba sustituye _ahora_real() y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

-- clientes: 1 (principal, 1000), 2 (ajeno, tiene bolsillos), 3 (bloqueado), 5 (sin bolsillos)
SELECT tests.cliente(1); SELECT tests.cliente(2); SELECT tests.cliente(3); SELECT tests.cliente(5);
SELECT tests.fondear(tests.c(1), 1000);
INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol)
VALUES ('adminz', tests.hash(), 'Adm', 'In', '9300001', 'adminz@mail.co', '3170000001', DATE '1980-01-01', 'ADMIN');

CREATE FUNCTION pg_temp.mv(p_op text, p_u int, p_a text, p_b text, p_m text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  IF p_op = 'in' THEN PERFORM public.mover_a_bolsillo(tests.u(p_u), p_a, p_m::numeric);
  ELSIF p_op = 'out' THEN PERFORM public.retirar_de_bolsillo(tests.u(p_u), p_a, p_m::numeric);
  ELSE PERFORM public.mover_entre_bolsillos(tests.u(p_u), p_a, p_b, p_m::numeric); END IF;
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM;
END $f$;
CREATE FUNCTION pg_temp.sc(p int) RETURNS numeric LANGUAGE sql VOLATILE AS $f$ SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(p) $f$;
CREATE FUNCTION pg_temp.sbn(p_nombre text) RETURNS numeric LANGUAGE sql VOLATILE AS $f$ SELECT balance::numeric FROM public.bolsillo WHERE nombre = p_nombre AND cuenta_id = tests.c(1) $f$;
CREATE FUNCTION pg_temp.h() RETURNS text LANGUAGE sql VOLATILE AS $f$ SELECT tests.huella_saldos() || '|' || (SELECT count(*) FROM public.bolsillo) $f$;

-- ============================================================================
-- 1. Helpers y crear_bolsillo
-- ============================================================================
SELECT assert_eq('_reglas_bolsillo: nombre 1..40 y los 2 mensajes nuevos, PROVISIONALES, en UN solo lugar (D-E6-8 / D-E6-9)', public._reglas_bolsillo(),
                 '{"nombre_min":1,"nombre_max":40,"msg_nombre":"Nombre de bolsillo inválido","msg_distintos":"Los bolsillos de origen y destino deben ser distintos"}'::jsonb);

CREATE TEMP TABLE t_a AS SELECT public.crear_bolsillo(tests.u(1), '  Ahorro   para   viaje ') AS r;
SELECT assert_json_shape('crear_bolsillo devuelve {id, nombre}', (SELECT r FROM t_a), '{"id":"string","nombre":"string"}'::jsonb);
SELECT assert_eq('nombre normalizado (recorte y colapso de espacios); el bolsillo nace con balance 0, en MI cuenta, ultimo_cobro = hoy del banco',
                 (SELECT (r ->> 'nombre', b.nombre, b.balance, b.cuenta_id = tests.c(1), b.ultimo_cobro = public.hoy_banco(), b.creado_en <= clock_timestamp())::text
                    FROM t_a, public.bolsillo b WHERE b.id = (r ->> 'id')::uuid),
                 '("Ahorro para viaje","Ahorro para viaje",0.00,t,t,t)'::text);
CREATE TEMP TABLE t_ids AS SELECT (SELECT (r ->> 'id') FROM t_a) AS a, (public.crear_bolsillo(tests.u(1), 'B') ->> 'id') AS b, (public.crear_bolsillo(tests.u(1), 'C') ->> 'id') AS c,
                                  (public.crear_bolsillo(tests.u(2), 'Ajeno') ->> 'id') AS x;
UPDATE public.bolsillo SET nombre = 'A' WHERE id = (SELECT a::uuid FROM t_ids);

DO $do$
DECLARE r record; mal text := ''; v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES (repeat('a', 40), true), ('  ' || repeat('b', 40) || '  ', true), (repeat('c', 41), false), ('', false), ('    ', false), (chr(9) || chr(10) || ' ', false),
                                 (NULL, false), ('a' || chr(7) || 'b', false), ('x' || chr(0 + 27), false), ('2026', true), ('日本の貯金', true), ('Ahorro' || chr(10) || 'casa', true)) q(n, ok)
  LOOP
    BEGIN PERFORM public.crear_bolsillo(tests.u(5), r.n);
      IF NOT r.ok THEN mal := mal || coalesce(left(r.n, 6), 'NULL') || ' aceptado; '; END IF;
    EXCEPTION WHEN OTHERS THEN IF r.ok OR SQLERRM <> 'Nombre de bolsillo inválido' THEN mal := mal || coalesce(left(r.n, 6), 'NULL') || ' [' || SQLERRM || ']; '; END IF; END;
  END LOOP;
  PERFORM tests.assert_eq('nombres: 40 si / 41 no, recorte antes de medir, vacio/blanco/NULL/caracteres de control rechazados, digitos y otros alfabetos aceptados', mal, ''::text);
  SELECT string_agg(nombre, '|' ORDER BY nombre) INTO v FROM public.bolsillo WHERE cuenta_id = tests.c(5) AND nombre IN ('Ahorro casa', '2026');
  PERFORM tests.assert_eq('el salto de linea interior se colapsa a un espacio', v, '2026|Ahorro casa'::text);
END $do$;
SELECT public.crear_bolsillo(tests.u(2), 'Repetido'), public.crear_bolsillo(tests.u(2), 'Repetido');
SELECT count(public.crear_bolsillo(tests.u(2), 'Mas ' || g)) FROM generate_series(1, 30) g;
SELECT assert_eq('nombres repetidos permitidos (D-E6-8 provisional: sin UNIQUE) y sin tope de bolsillos (la cuenta 2 tiene 33)',
                 ((SELECT count(*) FROM public.bolsillo WHERE cuenta_id = tests.c(2) AND nombre = 'Repetido'), (SELECT count(*) FROM public.bolsillo WHERE cuenta_id = tests.c(2)))::text, '(2,33)'::text);
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = tests.u(3);
SELECT assert_eq('crear_bolsillo: sesion inexistente/NULL = Sesion invalida; ADMIN = Acceso denegado; BLOQUEADO = mensaje de bloqueo (y sin rastro)',
                 (tests.captura($$SELECT public.crear_bolsillo(gen_random_uuid(), 'x')$$), tests.captura($$SELECT public.crear_bolsillo(NULL, 'x')$$),
                  tests.captura('SELECT public.crear_bolsillo((SELECT id FROM public.usuario WHERE username = ''adminz''), ''x'')'),
                  tests.captura('SELECT public.crear_bolsillo(' || quote_literal(tests.u(3)) || '::uuid, ''x'')'), (SELECT count(*) FROM public.bolsillo WHERE cuenta_id = tests.c(3)))::text,
                 '("Sesión inválida","Sesión inválida","Acceso denegado","Tu cuenta ha sido restringida, contacte con el banco para desbloquearla",0)'::text);
SELECT assert_eq('la sesion se valida ANTES que el nombre (nombre invalido con sesion invalida = Sesion invalida)', tests.captura($$SELECT public.crear_bolsillo(gen_random_uuid(), '')$$), 'Sesión inválida'::text);

-- ============================================================================
-- 2. Movimientos: mensajes exactos, orden de validacion y saldo exacto (cuenta 1000; A, B, C vacios)
-- ============================================================================
SELECT assert_eq('ingresar 300 a A (cuenta 1000 -> 700, A 300)', (pg_temp.mv('in', 1, (SELECT a FROM t_ids), NULL, '300'), pg_temp.sc(1), pg_temp.sbn('A'))::text, '(OK,700.00,300.00)'::text);
CREATE TEMP TABLE t_h0 AS SELECT pg_temp.h() AS h;
SELECT assert_eq('monto invalido ANTES que el bolsillo, en las 3 funciones (0, 3 decimales, NaN, negativo, NULL, sobre el maximo)',
                 (SELECT array_agg(DISTINCT pg_temp.mv(o, 1, 'no-es-uuid', 'no-es-uuid', m)) FROM unnest(ARRAY['in', 'out', 'mv']) o, unnest(ARRAY['0', '1.234', 'NaN', '-5', NULL, '99999999999999999']) m),
                 ARRAY['Monto inválido']::text[]);
SELECT assert_eq('bolsillo mal formado, inexistente o AJENO = Recurso no encontrado (nunca un error de driver), en ingresar/retirar',
                 (SELECT array_agg(DISTINCT pg_temp.mv(o, 1, b, NULL, '10')) FROM unnest(ARRAY['in', 'out']) o,
                         unnest(ARRAY['no-es-uuid', '', gen_random_uuid()::text, (SELECT x FROM t_ids), NULL, 'zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz']) b),
                 ARRAY['Recurso no encontrado']::text[]);
SELECT assert_eq('mover: origen o destino mal formado/ajeno/inexistente = Recurso no encontrado; con AMBOS iguales e invalidos tambien (antes que "distintos")',
                 (SELECT array_agg(DISTINCT m) FROM (VALUES
                    (pg_temp.mv('mv', 1, 'no-es-uuid', (SELECT b FROM t_ids), '10')), (pg_temp.mv('mv', 1, (SELECT a FROM t_ids), 'no-es-uuid', '10')),
                    (pg_temp.mv('mv', 1, (SELECT a FROM t_ids), (SELECT x FROM t_ids), '10')), (pg_temp.mv('mv', 1, (SELECT x FROM t_ids), (SELECT a FROM t_ids), '10')),
                    (pg_temp.mv('mv', 1, (SELECT x FROM t_ids), (SELECT x FROM t_ids), '10')), (pg_temp.mv('mv', 1, gen_random_uuid()::text, gen_random_uuid()::text, '10'))) q(m)),
                 ARRAY['Recurso no encontrado']::text[]);
SELECT assert_eq('D-E6-9 (PROVISIONAL): mover un bolsillo a si mismo (aunque el uuid cambie de mayusculas/espacios) = mensaje nuevo',
                 (pg_temp.mv('mv', 1, (SELECT a FROM t_ids), (SELECT a FROM t_ids), '10'), pg_temp.mv('mv', 1, (SELECT a FROM t_ids), ' ' || upper((SELECT a FROM t_ids)) || ' ', '10'))::text,
                 '("Los bolsillos de origen y destino deben ser distintos","Los bolsillos de origen y destino deben ser distintos")'::text);
SELECT assert_eq('saldo insuficiente: un centavo mas del origen (cuenta 700; A 300; A 300; B vacio)',
                 (pg_temp.mv('in', 1, (SELECT a FROM t_ids), NULL, '700.01'), pg_temp.mv('out', 1, (SELECT a FROM t_ids), NULL, '300.01'),
                  pg_temp.mv('mv', 1, (SELECT a FROM t_ids), (SELECT b FROM t_ids), '300.01'), pg_temp.mv('out', 1, (SELECT b FROM t_ids), NULL, '0.01'))::text,
                 '("Saldo insuficiente","Saldo insuficiente","Saldo insuficiente","Saldo insuficiente")'::text);
SELECT assert_eq('ningun rechazo deja rastro (saldos, patas ni bolsillos)', pg_temp.h(), (SELECT h FROM t_h0));
SELECT assert_eq('sesion en las 3 funciones: inexistente = Sesion invalida; ADMIN = Acceso denegado; BLOQUEADO = mensaje de bloqueo',
                 (SELECT array_agg(DISTINCT m ORDER BY m) FROM (VALUES
                    (tests.captura($$SELECT public.mover_a_bolsillo(gen_random_uuid(), 'x', 1)$$)), (tests.captura($$SELECT public.retirar_de_bolsillo(NULL, 'x', 1)$$)),
                    (tests.captura($$SELECT public.mover_entre_bolsillos(gen_random_uuid(), 'x', 'y', 1)$$))) q(m)), ARRAY['Sesión inválida']::text[]);
SELECT assert_eq('...ADMIN y BLOQUEADO',
                 (tests.captura('SELECT public.mover_a_bolsillo((SELECT id FROM public.usuario WHERE username = ''adminz''), ''x'', 1)'),
                  tests.captura('SELECT public.retirar_de_bolsillo(' || quote_literal(tests.u(3)) || '::uuid, ''x'', 1)'),
                  tests.captura('SELECT public.mover_entre_bolsillos(' || quote_literal(tests.u(3)) || '::uuid, ''x'', ''y'', 1)'))::text,
                 '("Acceso denegado","Tu cuenta ha sido restringida, contacte con el banco para desbloquearla","Tu cuenta ha sido restringida, contacte con el banco para desbloquearla")'::text);
UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = tests.u(3);

-- ============================================================================
-- 3. Patas del libro y saldos (plantilla, contraparte snapshot, misma fecha/grupo/tx)
-- ============================================================================
CREATE TEMP TABLE t_in AS SELECT public.mover_a_bolsillo(tests.u(1), ' ' || upper((SELECT a FROM t_ids)) || ' ', 50.25) AS r;     -- uuid en mayusculas y con espacios
CREATE TEMP TABLE t_mv AS SELECT public.mover_entre_bolsillos(tests.u(1), (SELECT a FROM t_ids), (SELECT b FROM t_ids), 100) AS r;
CREATE TEMP TABLE t_out AS SELECT public.retirar_de_bolsillo(tests.u(1), (SELECT b FROM t_ids), 40) AS r;
SELECT assert_json_shape('las 3 operaciones devuelven {id, fecha}', (SELECT r FROM t_in), '{"id":"string","fecha":"string"}'::jsonb);
SELECT assert_eq('saldos: cuenta 700-50.25+40 = 689.75; A 300+50.25-100 = 250.25; B 100-40 = 60',
                 (pg_temp.sc(1), pg_temp.sbn('A'), pg_temp.sbn('B'))::text, '(689.75,250.25,60.00)'::text);
SELECT assert_eq('INGRESAR: 2 patas BOLSO_INGRESO en UN grupo (el id devuelto): CUENTA S y BOLSILLO E, ambas con bolsillo_id = A, contraparte = nombre del bolsillo',
                 (SELECT (count(*), count(DISTINCT grupo_id), min(grupo_id::text) = (SELECT r ->> 'id' FROM t_in), bool_and(tipo = 'BOLSO_INGRESO' AND monto = 50.25 AND bolsillo_id = (SELECT a::uuid FROM t_ids) AND cuenta_id = tests.c(1) AND contraparte_nombre = 'A'),
                          string_agg(contenedor::text || sentido::text, ',' ORDER BY contenedor::text), count(DISTINCT fecha), count(DISTINCT tx_id), min(fecha) = (SELECT (r ->> 'fecha')::timestamptz FROM t_in), bool_and(nota IS NULL))::text
                    FROM public.transaccion WHERE grupo_id = (SELECT (r ->> 'id')::uuid FROM t_in)),
                 '(2,1,t,t,"BOLSILLOE,CUENTAS",1,1,t,t)'::text);
SELECT assert_eq('RETIRAR: BOLSO_RETIRO, BOLSILLO S (B) y CUENTA E con bolsillo_id = B; contraparte = nombre de B',
                 (SELECT (count(*), string_agg(contenedor::text || sentido::text, ',' ORDER BY contenedor::text), bool_and(tipo = 'BOLSO_RETIRO' AND bolsillo_id = (SELECT b::uuid FROM t_ids) AND contraparte_nombre = 'B' AND monto = 40), count(DISTINCT fecha))::text
                    FROM public.transaccion WHERE grupo_id = (SELECT (r ->> 'id')::uuid FROM t_out)), '(2,"BOLSILLOS,CUENTAE",t,1)'::text);
SELECT assert_eq('MOVER A->B: BOLSO_MOVIMIENTO, BOLSILLO S de A (contraparte = nombre de B) y BOLSILLO E de B (contraparte = nombre de A); misma fecha y tx; NINGUNA pata de la cuenta',
                 (SELECT (count(*), count(DISTINCT fecha), count(DISTINCT tx_id), bool_and(tipo = 'BOLSO_MOVIMIENTO' AND contenedor = 'BOLSILLO' AND monto = 100),
                          (SELECT (s.bolsillo_id = (SELECT a::uuid FROM t_ids), s.contraparte_nombre)::text FROM public.transaccion s WHERE s.grupo_id = (SELECT (r ->> 'id')::uuid FROM t_mv) AND s.sentido = 'S'),
                          (SELECT (e.bolsillo_id = (SELECT b::uuid FROM t_ids), e.contraparte_nombre)::text FROM public.transaccion e WHERE e.grupo_id = (SELECT (r ->> 'id')::uuid FROM t_mv) AND e.sentido = 'E'))::text
                    FROM public.transaccion WHERE grupo_id = (SELECT (r ->> 'id')::uuid FROM t_mv)),
                 '(2,1,1,t,"(t,B)","(t,A)")'::text);
SELECT assert_true('integridad global en orden tras los movimientos (conservacion, cuadre, saldos = patas)', (SELECT ok FROM public.v_integridad_global));
-- saldo EXACTO: se puede mover todo lo que hay (y un centavo mas no) desde cada origen
SELECT assert_eq('saldo exacto: ingresar TODO el saldo de la cuenta a C; retirar TODO C; mover TODO A a B',
                 (pg_temp.mv('in', 1, (SELECT c FROM t_ids), NULL, (SELECT (pg_temp.sc(1) + 0.01)::text)), pg_temp.mv('in', 1, (SELECT c FROM t_ids), NULL, (SELECT pg_temp.sc(1)::text)), pg_temp.sc(1),
                  pg_temp.mv('out', 1, (SELECT c FROM t_ids), NULL, '689.75'), pg_temp.sc(1), pg_temp.sbn('C'),
                  pg_temp.mv('mv', 1, (SELECT a FROM t_ids), (SELECT b FROM t_ids), '250.25'), pg_temp.sbn('A'), pg_temp.sbn('B'))::text,
                 '("Saldo insuficiente",OK,0.00,OK,689.75,0.00,OK,0.00,310.25)'::text);
SELECT assert_eq('suma por cliente conservada: cuenta + bolsillos = 1000 (lo fondeado)', (SELECT (SELECT balance FROM public.cuenta WHERE id = tests.c(1)) + (SELECT coalesce(sum(balance), 0) FROM public.bolsillo WHERE cuenta_id = tests.c(1))), 1000.00::numeric);

-- ============================================================================
-- 4. vista_balance y balance_total
-- ============================================================================
SELECT assert_json_shape('vista_balance devuelve {total, principal, bolsillos}', public.vista_balance(tests.u(1)), '{"total":"number","principal":"number","bolsillos":"array"}'::jsonb);
SELECT assert_eq('SOLO esas 3 claves; cada bolsillo SOLO {id (texto), nombre, saldo (numero)}',
                 (SELECT (array_agg(k ORDER BY k), (SELECT array_agg(DISTINCT jsonb_typeof(e -> 'id') || '/' || jsonb_typeof(e -> 'saldo')) FROM jsonb_array_elements(public.vista_balance(tests.u(1)) -> 'bolsillos') e),
                          (SELECT array_agg(DISTINCT kk ORDER BY kk) FROM jsonb_array_elements(public.vista_balance(tests.u(1)) -> 'bolsillos') e, jsonb_object_keys(e) kk))::text
                    FROM jsonb_object_keys(public.vista_balance(tests.u(1))) k),
                 '("{bolsillos,principal,total}",{string/number},"{id,nombre,saldo}")'::text);
CREATE TEMP TABLE t_v AS SELECT public.vista_balance(tests.u(1)) AS v;
SELECT assert_eq('valores: principal = cuenta.balance (689.75); total = principal + suma de saldos (1000); bolsillos A, B, C con sus saldos, en orden de creacion; solo los de MI cuenta',
                 (SELECT ((v ->> 'principal')::numeric, (v ->> 'total')::numeric, jsonb_array_length(v -> 'bolsillos'),
                          (SELECT string_agg((e ->> 'nombre') || '=' || (e ->> 'saldo')::numeric, ',' ORDER BY ord) FROM jsonb_array_elements(v -> 'bolsillos') WITH ORDINALITY q(e, ord)))::text FROM t_v),
                 '(689.75,1000.00,3,"A=0.00,B=310.25,C=0.00")'::text);
SELECT assert_eq('los ids de la vista son los de los bolsillos y SIRVEN tal cual (texto) para operar',
                 ((SELECT array_agg(e ->> 'id' ORDER BY ord) FROM t_v, jsonb_array_elements(v -> 'bolsillos') WITH ORDINALITY q(e, ord)) = ARRAY[(SELECT a FROM t_ids), (SELECT b FROM t_ids), (SELECT c FROM t_ids)],
                  pg_temp.mv('in', 1, (SELECT (v -> 'bolsillos' -> 0 ->> 'id') FROM t_v), NULL, '1'), pg_temp.mv('out', 1, (SELECT (v -> 'bolsillos' -> 0 ->> 'id') FROM t_v), NULL, '1'))::text, '(t,OK,OK)'::text);
SELECT assert_eq('aislamiento: la vista del cliente 2 no mezcla los bolsillos del 1 (33 bolsillos, todos de su cuenta, ninguno de A/B/C)',
                 (SELECT (jsonb_array_length(v -> 'bolsillos'), bool_and((e ->> 'id')::uuid IN (SELECT id FROM public.bolsillo WHERE cuenta_id = tests.c(2))),
                          bool_or((e ->> 'id') IN ((SELECT a FROM t_ids), (SELECT b FROM t_ids), (SELECT c FROM t_ids))), (v ->> 'total')::numeric, (v ->> 'principal')::numeric)::text
                    FROM (SELECT public.vista_balance(tests.u(2)) AS v) z, jsonb_array_elements(z.v -> 'bolsillos') e GROUP BY v),
                 '(33,t,f,0.00,0.00)'::text);
SELECT assert_eq('cliente sin bolsillos: bolsillos = [] (nunca null) y total = principal', (SELECT (v -> 'bolsillos', v ->> 'total', v ->> 'principal')::text FROM (SELECT public.vista_balance(tests.u(3)) AS v) z), '([],0.00,0.00)'::text);
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = tests.u(3);
SELECT assert_eq('vista_balance: sesion inexistente/NULL = Sesion invalida; ADMIN = Acceso denegado; BLOQUEADO = mensaje de bloqueo',
                 (tests.captura($$SELECT public.vista_balance(gen_random_uuid())$$), tests.captura($$SELECT public.vista_balance(NULL)$$),
                  tests.captura('SELECT public.vista_balance((SELECT id FROM public.usuario WHERE username = ''adminz''))'),
                  tests.captura('SELECT public.vista_balance(' || quote_literal(tests.u(3)) || '::uuid)'))::text,
                 '("Sesión inválida","Sesión inválida","Acceso denegado","Tu cuenta ha sido restringida, contacte con el banco para desbloquearla")'::text);
UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = tests.u(3);
SELECT assert_eq('balance_total: STABLE (usa la foto de la sentencia que la llama), vale 1000 para la cuenta 1 y NULL para una cuenta que no existe; la vista usa ESE valor',
                 ((SELECT provolatile::text FROM pg_proc WHERE oid = 'public.balance_total(uuid)'::regprocedure), public.balance_total(tests.c(1)), public.balance_total(gen_random_uuid()),
                  (SELECT (v ->> 'total')::numeric = public.balance_total(tests.c(1)) FROM t_v))::text, '(s,1000.00,,t)'::text);
SELECT assert_true('en TODA respuesta de la vista total = principal + suma de saldos (4 clientes distintos)',
                   (SELECT bool_and((v ->> 'total')::numeric = (v ->> 'principal')::numeric + coalesce((SELECT sum((e ->> 'saldo')::numeric) FROM jsonb_array_elements(v -> 'bolsillos') e), 0))
                      FROM (SELECT public.vista_balance(tests.u(n)) AS v FROM unnest(ARRAY[1, 2, 3, 5]) n) z));

-- ============================================================================
-- 5. Atomicidad: fallo en la 1.a y en la 2.a pata, en las 3 operaciones (la 2.a ya aplico el primer saldo): nadie pierde ni gana nada
-- ============================================================================
SELECT tests.instalar_fallas();
CREATE FUNCTION pg_temp.con_falla(p_regla text, p_op text, p_a text, p_b text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v_msg text;
BEGIN
  PERFORM tests.falla(p_regla);
  v_msg := pg_temp.mv(p_op, 1, p_a, p_b, '10');
  PERFORM tests.falla('');
  RETURN v_msg;
END $f$;
CREATE TEMP TABLE t_a0 AS SELECT pg_temp.h() AS h;
DO $do$
DECLARE o text; p int; v text; mal text := ''; a text := (SELECT a FROM t_ids); b text := (SELECT b FROM t_ids);
BEGIN
  FOREACH o IN ARRAY ARRAY['in', 'out', 'mv'] LOOP
    FOREACH p IN ARRAY ARRAY[1, 2] LOOP
      v := pg_temp.con_falla('tx:' || p, o, CASE o WHEN 'in' THEN a WHEN 'out' THEN b ELSE b END, CASE o WHEN 'mv' THEN a END);
      IF v <> 'FALLA INYECTADA en la pata ' || p OR pg_temp.h() <> (SELECT h FROM t_a0) THEN mal := mal || o || ':' || p || ' [' || v || ']; '; END IF;
    END LOOP;
  END LOOP;
  PERFORM tests.assert_eq('falla en la 1.a y la 2.a pata de ingresar, retirar y mover: se revierte TODO (saldos, patas, bolsillos)', mal, ''::text);
END $do$;
SELECT assert_eq('tras los fallos el reintento mueve el dinero UNA vez', (pg_temp.mv('mv', 1, (SELECT b FROM t_ids), (SELECT a FROM t_ids), '10'), pg_temp.sbn('A'), pg_temp.sbn('B'))::text, '(OK,10.00,300.25)'::text);
SELECT tests.quitar_fallas();

-- ============================================================================
-- 6. Ningun camino alternativo al libro; reloj: una instantanea por operacion (analisis del codigo y conteo dinamico)
-- ============================================================================
SELECT assert_true('el codigo de _mover_bolsillo solo mueve dinero por _asentar_grupo (sin INSERT/UPDATE/DELETE) y sin reloj del sistema',
                   (SELECT p.prosrc !~* 'insert\s+into|update\s+public\.|update\s+(cuenta|bolsillo)|delete\s+from' AND p.prosrc ~ '_asentar_grupo'
                           AND p.prosrc !~* '(now\s*\(|current_(date|time)|clock_timestamp|statement_timestamp|transaction_timestamp|localtime|hoy_banco|ahora_banco|_ahora_real|pg_sleep)'
                      FROM pg_proc p WHERE p.oid = 'public._mover_bolsillo(uuid,text,text,text,numeric)'::regprocedure));
SELECT assert_true('crear_bolsillo: su UNICA escritura es el INSERT de public.bolsillo (nace con balance 0); sin UPDATE/DELETE, sin libro y sin reloj del sistema',
                   (SELECT p.prosrc ~* 'insert\s+into\s+public\.bolsillo \(cuenta_id, nombre, ultimo_cobro, creado_en\)' AND (length(p.prosrc) - length(regexp_replace(p.prosrc, 'insert\s+into', '', 'gi'))) = length('insert into')
                           AND p.prosrc !~* 'update\s|delete\s+from|_asentar_grupo'
                           AND p.prosrc !~* '(now\s*\(|current_(date|time)|clock_timestamp|statement_timestamp|transaction_timestamp|localtime|hoy_banco|ahora_banco|_ahora_real|pg_sleep)'
                      FROM pg_proc p WHERE p.oid = 'public.crear_bolsillo(uuid,text)'::regprocedure));
SELECT assert_true('balance_total, _bolsillo_propio, _reglas_bolsillo y las 3 delgadas: de SOLO LECTURA (sin INSERT/UPDATE/DELETE), sin reloj y sin libro',
                   (SELECT bool_and(p.prosrc !~* 'insert\s+into|update\s|delete\s+from|_asentar_grupo|_reloj_instantanea|now\s*\(|current_(date|time)|clock_timestamp|hoy_banco|ahora_banco|_ahora_real')
                      FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('balance_total', '_bolsillo_propio', '_reglas_bolsillo', 'mover_a_bolsillo', 'retirar_de_bolsillo', 'mover_entre_bolsillos')));
SELECT assert_true('E7: vista_balance no escribe por si misma (sin INSERT/UPDATE/DELETE ni libro: devenga el motor), usa SOLO la instantanea (nada de now()/hoy_banco()/_ahora_real())',
                   (SELECT p.prosrc !~* 'insert\s+into|update\s|delete\s+from|_asentar_grupo|now\s*\(|current_(date|time)|clock_timestamp|hoy_banco|ahora_banco|_ahora_real' AND p.prosrc ~ '_reloj_instantanea' AND p.prosrc ~ '_avanzar_hasta'
                      FROM pg_proc p WHERE p.oid = 'public.vista_balance(uuid)'::regprocedure));
SELECT assert_eq('_reloj_instantanea() aparece UNA vez en _mover_bolsillo, UNA en crear_bolsillo y (E7) UNA en vista_balance, y en NINGUNA otra funcion de E6',
                 (SELECT array_agg(f || '=' || n ORDER BY f) FROM (SELECT p.proname::text AS f, (length(p.prosrc) - length(replace(p.prosrc, '_reloj_instantanea', ''))) / length('_reloj_instantanea') AS n
                    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('crear_bolsillo', 'mover_a_bolsillo', 'retirar_de_bolsillo', 'mover_entre_bolsillos', 'vista_balance',
                                                                                                    '_reglas_bolsillo', '_bolsillo_propio', '_mover_bolsillo', 'balance_total')) z WHERE n > 0),
                 ARRAY['_mover_bolsillo=1', 'crear_bolsillo=1', 'vista_balance=1']::text[]);
SELECT assert_eq('"total" tiene UNA sola definicion: solo balance_total suma saldos de bolsillo; la vista la llama y no suma',
                 ((SELECT array_agg(proname::text ORDER BY proname) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND prosrc ~* 'sum\s*\(' AND proname IN ('crear_bolsillo', 'mover_a_bolsillo', 'retirar_de_bolsillo', 'mover_entre_bolsillos', 'vista_balance', '_reglas_bolsillo', '_bolsillo_propio', '_mover_bolsillo', 'balance_total')),
                  (SELECT prosrc ~ 'balance_total\(' FROM pg_proc WHERE oid = 'public.vista_balance(uuid)'::regprocedure))::text, '({balance_total},t)'::text);
SELECT assert_eq('D-E7-4: el motor _avanzar_hasta (E7) esta integrado en vista_balance, _mover_bolsillo y crear_bolsillo (1 llamada cada una) y en NINGUNA otra funcion de E6; sin intereses mientras el reloj no avance',
                 ((SELECT array_agg(proname::text ORDER BY proname) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('vista_balance', '_mover_bolsillo', 'crear_bolsillo', 'mover_a_bolsillo', 'retirar_de_bolsillo', 'mover_entre_bolsillos', 'balance_total', '_bolsillo_propio', '_reglas_bolsillo') AND prosrc ~ '_avanzar_hasta'),
                  (SELECT count(*) FROM public.transaccion WHERE tipo = 'INTERES_BOLSO'))::text, '("{_mover_bolsillo,crear_bolsillo,vista_balance}",0)'::text);

-- reloj manual (E3): crear_bolsillo y los movimientos usan el hoy/ahora DEL BANCO
SELECT public._reloj_actualizar(false, to_char(public.hoy_banco() + 12, 'YYYY-MM-DD'));
CREATE TEMP TABLE t_m1 AS SELECT public.crear_bolsillo(tests.u(1), 'Futuro') AS r;
CREATE TEMP TABLE t_m2 AS SELECT public.mover_a_bolsillo(tests.u(1), (SELECT c FROM t_ids), 1) AS r;
SELECT assert_eq('reloj manual +12 dias: el bolsillo nace con ultimo_cobro = hoy del banco y creado_en en ese dia (Bogota); el movimiento se fecha en ese dia',
                 (SELECT (b.ultimo_cobro = public.hoy_banco(), (b.creado_en AT TIME ZONE 'America/Bogota')::date = public.hoy_banco(), b.ultimo_cobro > CURRENT_DATE + 10,
                          (SELECT bool_and((t.fecha AT TIME ZONE 'America/Bogota')::date = public.hoy_banco()) FROM public.transaccion t WHERE t.grupo_id = (SELECT (r ->> 'id')::uuid FROM t_m2)))::text
                    FROM public.bolsillo b WHERE b.id = (SELECT (r ->> 'id')::uuid FROM t_m1)), '(t,t,t,t)'::text);
SELECT public._reloj_actualizar(true, '');

-- conteo dinamico de lecturas del reloj (sustitucion de _ahora_real solo en banco_test/banco_mut, dentro de esta transaccion)
CREATE TEMP SEQUENCE sq_lect;
GRANT USAGE, SELECT, UPDATE ON SEQUENCE sq_lect TO banco_owner;
CREATE OR REPLACE FUNCTION public._ahora_real() RETURNS timestamptz LANGUAGE plpgsql VOLATILE SET search_path = public, pg_temp AS $f$
BEGIN
  RETURN '2026-11-21 10:00:00-05'::timestamptz + make_interval(secs => nextval('pg_temp.sq_lect')::int);
END $f$;
CREATE FUNCTION pg_temp.lect() RETURNS int LANGUAGE sql VOLATILE AS $f$ SELECT CASE WHEN is_called THEN last_value::int ELSE 0 END FROM pg_temp.sq_lect $f$;
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT pg_temp.mv('in', 1, (SELECT a FROM t_ids), NULL, '1');
SELECT assert_eq('ingresar lee el reloj 1 vez (instantanea) + 1 por pata del libro (2) = 3 lecturas, y ambas patas llevan EXACTAMENTE ese ahora (T+1s)',
                 (pg_temp.lect(), (SELECT (count(*), count(DISTINCT fecha), min(fecha) = TIMESTAMPTZ '2026-11-21 10:00:01-05')::text FROM public.transaccion WHERE tipo = 'BOLSO_INGRESO' AND fecha = TIMESTAMPTZ '2026-11-21 10:00:01-05'))::text, '(3,"(2,1,t)")'::text);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT pg_temp.mv('out', 1, (SELECT a FROM t_ids), NULL, '1');
SELECT assert_eq('retirar: 3 lecturas', pg_temp.lect(), 3);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT pg_temp.mv('mv', 1, (SELECT b FROM t_ids), (SELECT a FROM t_ids), '1');
SELECT assert_eq('mover entre bolsillos: 3 lecturas', pg_temp.lect(), 3);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.crear_bolsillo(tests.u(1), 'Otro');
SELECT assert_eq('crear_bolsillo: 1 lectura (la instantanea; el INSERT no genera patas)', pg_temp.lect(), 1);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.vista_balance(tests.u(1));
SELECT assert_eq('vista_balance (E7): 1 lectura del reloj (la instantanea del devengo previo; sin nada vencido no hay patas)', pg_temp.lect(), 1);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT assert_eq('un rechazo de validacion (monto, bolsillo, sesion o nombre) no lee el reloj',
                 (pg_temp.mv('in', 1, (SELECT a FROM t_ids), NULL, '0'), pg_temp.mv('out', 1, 'zz', NULL, '5'), pg_temp.mv('mv', 1, (SELECT a FROM t_ids), (SELECT a FROM t_ids), '5'),
                  tests.captura($$SELECT public.crear_bolsillo(tests.u(1), '')$$), pg_temp.lect())::text,
                 '("Monto inválido","Recurso no encontrado","Los bolsillos de origen y destino deben ser distintos","Nombre de bolsillo inválido",0)'::text);

-- ============================================================================
-- 7. Permisos por ROL real
-- ============================================================================
SELECT set_config('tests.e', tests.u(1)::text, true);
SELECT set_config('tests.a', (SELECT a FROM t_ids), true);
SELECT set_config('tests.b', (SELECT b FROM t_ids), true);
SELECT assert_ok('banco_app ejecuta las 5 publicas de E6',
   $$SET LOCAL ROLE banco_app; SELECT public.crear_bolsillo(current_setting('tests.e')::uuid, 'App'); SELECT public.vista_balance(current_setting('tests.e')::uuid);
     SELECT public.mover_a_bolsillo(current_setting('tests.e')::uuid, current_setting('tests.a'), 0.01); SELECT public.retirar_de_bolsillo(current_setting('tests.e')::uuid, current_setting('tests.a'), 0.01);
     SELECT public.mover_entre_bolsillos(current_setting('tests.e')::uuid, current_setting('tests.b'), current_setting('tests.a'), 0.01)$$);
SELECT assert_ok('banco_dev (hereda de banco_app) tambien: vista_balance', $$SET LOCAL ROLE banco_dev; SELECT public.vista_balance(current_setting('tests.e')::uuid)$$);
DO $do$
DECLARE f text; r text; mal text := ''; v_msg text;
BEGIN
  FOREACH f IN ARRAY ARRAY['crear_bolsillo(current_setting(''tests.e'')::uuid, ''x'')', 'vista_balance(current_setting(''tests.e'')::uuid)', 'mover_a_bolsillo(current_setting(''tests.e'')::uuid, ''x'', 1)',
                           'retirar_de_bolsillo(current_setting(''tests.e'')::uuid, ''x'', 1)', 'mover_entre_bolsillos(current_setting(''tests.e'')::uuid, ''x'', ''y'', 1)'] LOOP
    v_msg := coalesce(tests.captura('SET LOCAL ROLE banco_lector; SELECT public.' || f), ''); RESET ROLE;
    IF v_msg NOT LIKE 'permission denied for function%' THEN mal := mal || 'lector:' || f || '; '; END IF;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['_reglas_bolsillo()', '_bolsillo_propio(gen_random_uuid(), ''x'')', '_mover_bolsillo(current_setting(''tests.e'')::uuid, ''BOLSO_INGRESO'', ''x'', NULL, 1)', 'balance_total(gen_random_uuid())'] LOOP
    FOREACH r IN ARRAY ARRAY['banco_app', 'banco_lector', 'banco_dev'] LOOP
      v_msg := coalesce(tests.captura('SET LOCAL ROLE ' || r || '; SELECT public.' || f), ''); RESET ROLE;
      IF v_msg NOT LIKE 'permission denied for function%' THEN mal := mal || r || ':' || f || '; '; END IF;
    END LOOP;
  END LOOP;
  PERFORM tests.assert_eq('banco_lector NO ejecuta las 5 publicas, y los 4 helpers dan permission denied a banco_app, banco_lector y banco_dev', mal, ''::text);
END $do$;
SELECT assert_raises('banco_app NO toca saldos ni inserta bolsillos a mano (permission denied)', $$SET LOCAL ROLE banco_app; INSERT INTO public.bolsillo (cuenta_id, nombre, ultimo_cobro) VALUES (gen_random_uuid(), 'x', CURRENT_DATE)$$, NULL, '42501');
SELECT assert_eq('ACL: las 5 publicas solo banco_owner y banco_app; los 4 helpers solo banco_owner',
                 (SELECT (array_agg(DISTINCT pg_get_userbyid(a.grantee)::text) FILTER (WHERE p.proname IN ('crear_bolsillo', 'mover_a_bolsillo', 'retirar_de_bolsillo', 'mover_entre_bolsillos', 'vista_balance')),
                          array_agg(DISTINCT pg_get_userbyid(a.grantee)::text) FILTER (WHERE p.proname IN ('_reglas_bolsillo', '_bolsillo_propio', '_mover_bolsillo', 'balance_total')))::text
                    FROM pg_proc p, aclexplode(p.proacl) a WHERE p.pronamespace = 'public'::regnamespace AND a.privilege_type = 'EXECUTE'),
                 '("{banco_app,banco_owner}",{banco_owner})'::text);
SELECT assert_eq('las 5 publicas son SECURITY DEFINER; los 4 helpers no; todas con search_path fijo y COMMENT',
                 (SELECT (count(*) FILTER (WHERE prosecdef), count(*) FILTER (WHERE NOT prosecdef), bool_and('search_path=public, pg_temp' = ANY (proconfig)), bool_and(obj_description(oid, 'pg_proc') IS NOT NULL))::text
                    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('crear_bolsillo', 'mover_a_bolsillo', 'retirar_de_bolsillo', 'mover_entre_bolsillos', 'vista_balance', '_reglas_bolsillo', '_bolsillo_propio', '_mover_bolsillo', 'balance_total')),
                 '(5,4,t,t)'::text);
SELECT tests.detecta('GRANT EXECUTE de balance_total (helper) a banco_app lo detecta la lista blanca de v_integridad_defensas',
   $s$GRANT EXECUTE ON FUNCTION public.balance_total(uuid) TO banco_app$s$, $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_defensas WHERE NOT ok)$d$);
SELECT tests.detecta('REVOKE de vista_balance a banco_app (el front no podria listar bolsillos) lo detecta la lista blanca',
   $s$REVOKE EXECUTE ON FUNCTION public.vista_balance(uuid) FROM banco_app$s$, $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_defensas WHERE NOT ok AND control LIKE 'banco_app ejecuta EXACTAMENTE%')$d$);
SELECT tests.detecta('REVOKE de mover_entre_bolsillos a banco_app lo detecta la lista blanca',
   $s$REVOKE EXECUTE ON FUNCTION public.mover_entre_bolsillos(uuid, text, text, numeric) FROM banco_app$s$, $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_defensas WHERE NOT ok AND control LIKE 'banco_app ejecuta EXACTAMENTE%')$d$);
SELECT assert_true('la lista blanca de banco_app tiene EXACTAMENTE 40 funciones (E4-E12) y esta en orden', (SELECT ok FROM public.v_integridad_defensas WHERE control LIKE 'banco_app ejecuta EXACTAMENTE las 40%'));

ROLLBACK;

SELECT assert_eq('tras el ROLLBACK _ahora_real() es otra vez el reloj de pared (la sustitucion no sobrevive)', (SELECT pg_get_functiondef(oid) LIKE '%SELECT clock_timestamp()%' FROM pg_proc WHERE oid = 'public._ahora_real()'::regprocedure), true);
