-- 68_admin_usuarios.test.sql · Etapa 11 · admin_listar_usuarios, admin_detalle_usuario, admin_bloquear / admin_desbloquear, admin_borrar_usuario y admin_ajustar_balance.
-- Riesgos NUEVOS: la lista solo muestra CLIENTES y busca por 4 campos sin tildes ni comodines; el detalle corre el motor sobre el consultado; bloquear rige ya; el borrado deja
-- 0 filas, conserva la contraparte de los terceros, audita con el admin como actor y es atomico; el ajuste (con signo) pasa SOLO por el libro, devenga antes y es atomico.
-- No repite el libro (E2), el motor (E7), los pagos (E9) ni las vistas (E10). Una transaccion con ROLLBACK final; solo corre en banco_test/banco_mut (mueve el reloj).
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 8) n;
INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol) VALUES
  (tests.u(900), 'admin900', 'h', 'Ada', 'Admin', '9000000900', 'a900@t.co', '3000000900', DATE '1980-01-01', 'ADMIN'),
  (tests.u(901), 'admin901', 'h', 'Beto', 'Admin', '9000000901', 'a901@t.co', '3000000901', DATE '1980-01-01', 'ADMIN');
UPDATE public.usuario SET nombres = 'Álvaro', apellidos = 'Muñoz'    WHERE id = tests.u(1);
UPDATE public.usuario SET nombres = 'Zoé',    apellidos = 'Garcia'   WHERE id = tests.u(2);
UPDATE public.usuario SET nombres = 'Carla',  apellidos = 'Ga_cia'   WHERE id = tests.u(3);
UPDATE public.usuario SET nombres = 'Dario',  apellidos = '100%Real' WHERE id = tests.u(4);
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES (tests.p(901), 'Libre', '', 18, 1, 1000000000, 1, 360);
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES (tests.p(930), 'CDT 30', 30, 10, 1);
CREATE TEMP TABLE t_b AS SELECT public.hoy_banco() AS d;
CREATE FUNCTION pg_temp.dia(p_n int) RETURNS date LANGUAGE sql STABLE AS $f$ SELECT (SELECT d FROM t_b) + p_n $f$;
CREATE FUNCTION pg_temp.ir(p_n int) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(false, pg_temp.dia(p_n)::text); END $f$;
CREATE FUNCTION pg_temp.real() RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(true, ''); END $f$;
-- ejecuta una sentencia y devuelve OK o el mensaje (un error que NO sea de negocio P0001 se marca)
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN EXECUTE p_sql; RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN CASE WHEN SQLSTATE = 'P0001' THEN SQLERRM ELSE 'NO-P0001 ' || SQLSTATE || ': ' || SQLERRM END; END $f$;
CREATE FUNCTION pg_temp.lista(p_q text) RETURNS text LANGUAGE sql STABLE AS $f$
  SELECT coalesce(string_agg(e ->> 'username', ',' ORDER BY o), '') FROM jsonb_array_elements(public.admin_listar_usuarios(tests.u(900), p_q)) WITH ORDINALITY x(e, o) $f$;
CREATE FUNCTION pg_temp.num(p_u int) RETURNS text LANGUAGE sql STABLE AS $f$ SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(p_u) $f$;
CREATE FUNCTION pg_temp.ev(p_accion text, p_entidad_id text) RETURNS bigint LANGUAGE sql STABLE AS $f$ SELECT count(*) FROM audit.evento WHERE accion = p_accion AND entidad_id = p_entidad_id $f$;
SELECT pg_temp.real();

-- ============================================================================
-- A. admin_listar_usuarios
-- ============================================================================
CREATE TEMP TABLE t_l0 AS SELECT public.admin_listar_usuarios(tests.u(900), NULL) AS j, tests.huella_saldos() AS h, (SELECT count(*) FROM audit.evento) AS ev;
SELECT assert_eq('A1 forma del contrato: exactamente {id, username, nombre, cedula, correo, numero_cuenta, estado} (sin password_hash ni nada mas)',
                 (SELECT array_agg(DISTINCT k ORDER BY k) FROM t_l0, jsonb_array_elements(j) e, jsonb_object_keys(e) k),
                 ARRAY['cedula', 'correo', 'estado', 'id', 'nombre', 'numero_cuenta', 'username']::text[]);
SELECT assert_eq('A2 solo CLIENTES: 8 filas (los 2 ADMIN no aparecen: no tienen cuenta)', (SELECT jsonb_array_length(j) FROM t_l0), 8);
SELECT assert_eq('A3 tipos: strings (id, nombre = nombres + apellidos, numero_cuenta de 10 digitos)',
                 (SELECT (jsonb_typeof(j -> 0 -> 'id'), j -> 0 ->> 'nombre', (j -> 0 ->> 'numero_cuenta') ~ '^[0-9]{10}$')::text FROM (SELECT public.admin_listar_usuarios(tests.u(900), 'Alvaro') AS j) x),
                 '(string,"Álvaro Muñoz",t)'::text);
SELECT assert_eq('A4 busqueda NULL, vacia o solo espacios = todos', concat_ws('|', jsonb_array_length(public.admin_listar_usuarios(tests.u(900), '')), jsonb_array_length(public.admin_listar_usuarios(tests.u(900), '   ')),
                 jsonb_array_length(public.admin_listar_usuarios(tests.u(900)))), '8|8|8'::text);
SELECT assert_eq('A5 por NOMBRE sin tildes ni mayusculas: "alvaro" y "MUNOZ" encuentran a Álvaro Muñoz; "oe garc" a Zoé Garcia (nombres + apellidos)',
                 concat_ws('|', pg_temp.lista('alvaro'), pg_temp.lista('MUNOZ'), pg_temp.lista('oe garc')), 'cli1|cli1|cli2'::text);
SELECT assert_eq('A6 por CEDULA, por CORREO y por NUMERO DE CUENTA (parciales)', concat_ws('|', pg_temp.lista('0000003'), pg_temp.lista('c6@t'), pg_temp.lista('40000000' || '05')), 'cli3|cli6|cli5'::text);
SELECT assert_eq('A7 NO busca por username (los 4 criterios son nombre, cedula, correo y cuenta): "cli7" no encuentra nada', pg_temp.lista('cli7'), ''::text);
SELECT assert_eq('A8 los comodines del usuario son LITERALES: "%" solo encuentra a 100%Real, "Ga_cia" no encuentra a Garcia, "_" solo a Ga_cia',
                 concat_ws('|', pg_temp.lista('%'), pg_temp.lista('Ga_cia'), pg_temp.lista('_')), 'cli4|cli3|cli3'::text);
SELECT assert_eq('A9 una barra invertida en la busqueda no rompe el LIKE (sin error, sin filas)', pg_temp.err($$SELECT public.admin_listar_usuarios(tests.u(900), chr(92))$$) || '|' || pg_temp.lista(chr(92)), 'OK|'::text);
SELECT assert_eq('A10 sin coincidencias = [] (arreglo vacio, nunca null)', public.admin_listar_usuarios(tests.u(900), 'zzzz-nada')::text, '[]'::text);
SELECT assert_eq('A11 orden por nombres, apellidos, id (oraculo independiente)', pg_temp.lista(NULL),
                 (SELECT string_agg(username, ',' ORDER BY nombres, apellidos, id) FROM public.usuario WHERE rol = 'CLIENTE'));
SELECT assert_eq('A12 la lista NO corre el motor ni escribe nada: huella de saldos y eventos de auditoria intactos', (tests.huella_saldos() = (SELECT h FROM t_l0), (SELECT count(*) FROM audit.evento) = (SELECT ev FROM t_l0))::text, '(t,t)'::text);
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = tests.u(8);
SELECT assert_eq('A13 el estado se refleja (un bloqueado sigue en la lista, con estado BLOQUEADO)', (SELECT e ->> 'estado' FROM jsonb_array_elements(public.admin_listar_usuarios(tests.u(900), 'c8@')) e), 'BLOQUEADO'::text);
UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = tests.u(8);
SAVEPOINT s_lim;
SELECT count(tests.cliente(n)) FROM generate_series(1000, 1204) n;
SELECT assert_eq('A14 con 213 clientes la lista devuelve EXACTAMENTE 200 (el tope de _reglas_admin)', jsonb_array_length(public.admin_listar_usuarios(tests.u(900), NULL)), 200);
ROLLBACK TO SAVEPOINT s_lim;
SELECT assert_eq('A15 el tope sale de _reglas_admin(): lista_max = 200', (public._reglas_admin() ->> 'lista_max')::int, 200);

-- ============================================================================
-- B. admin_detalle_usuario
-- ============================================================================
SELECT tests.fondear(tests.c(1), 5000000);
CREATE TEMP TABLE t_bol AS SELECT public.crear_bolsillo(tests.u(1), 'Viajes') ->> 'id' AS b1;
SELECT public.mover_a_bolsillo(tests.u(1), (SELECT b1 FROM t_bol), 100000);
SELECT public.crear_cdt(tests.u(1), tests.p(930)::text, 1000000);
CREATE TEMP TABLE t_k AS SELECT (public.solicitar_credito(tests.u(1), tests.p(901)::text, 2000000, 12) ->> 'id')::uuid AS k;
SELECT tests.fondear(tests.c(2), 1000000);
SELECT public.hacer_transferencia(tests.u(2), pg_temp.num(1), 25000, 'hola', NULL);
CREATE TEMP TABLE t_d1 AS SELECT public.admin_detalle_usuario(tests.u(900), tests.u(1)::text) AS d;
SELECT assert_json_shape('B1 forma del contrato (AdminUsuarioDetalle de types.ts)', (SELECT d FROM t_d1),
                         '{"id":"string","username":"string","nombre":"string","cedula":"string","correo":"string","numero_cuenta":"string","estado":"string","balance":"object","historial":"array"}'::jsonb);
SELECT assert_json_shape('B2 balance {total, principal, bolsillos, cdts, creditos}', (SELECT d -> 'balance' FROM t_d1),
                         '{"total":"number","principal":"number","bolsillos":"array","cdts":"array","creditos":"array"}'::jsonb);
SELECT assert_eq('B3 los elementos: bolsillos {id,nombre,saldo}, cdts {id,monto}, creditos {id,producto,saldo}',
                 (SELECT concat_ws('|', (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(d #> '{balance,bolsillos,0}') k),
                                        (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(d #> '{balance,cdts,0}') k),
                                        (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(d #> '{balance,creditos,0}') k)) FROM t_d1),
                 '{id,nombre,saldo}|{id,monto}|{id,producto,saldo}'::text);
SELECT assert_eq('B4 el contenido: nombre, principal, 1 bolsillo de 100000, 1 CDT de 1000000, 1 credito "Libre" con saldo 2000000',
                 (SELECT concat_ws('|', d ->> 'nombre', d #>> '{balance,principal}', d #>> '{balance,bolsillos,0,saldo}', d #>> '{balance,cdts,0,monto}', d #>> '{balance,creditos,0,producto}', d #>> '{balance,creditos,0,saldo}') FROM t_d1),
                 'Álvaro Muñoz|5925000.00|100000.00|1000000.00|Libre|2000000.00'::text);
SELECT assert_eq('B5 el total es el MISMO de vista_balance (balance_total, D6 provisional) y los bolsillos coinciden',
                 (SELECT ((d #>> '{balance,total}')::numeric = (public.vista_balance(tests.u(1)) ->> 'total')::numeric, d #> '{balance,bolsillos}' = public.vista_balance(tests.u(1)) -> 'bolsillos')::text FROM t_d1), '(t,t)'::text);
SELECT assert_eq('B6 el historial es EXACTAMENTE el de vista_historial (mismo formateador, recientes primero)', (SELECT d -> 'historial' FROM t_d1), public.vista_historial(tests.u(1), 50));
SELECT assert_eq('B7 nunca expone el hash ni la contrasena', (SELECT d::text ~* 'password|hash' FROM t_d1), false);
SELECT set_config('TimeZone', 'UTC', true);
CREATE TEMP TABLE t_tz AS SELECT public.admin_detalle_usuario(tests.u(900), tests.u(1)::text) #>> '{historial,0,fecha}' AS f;
SELECT set_config('TimeZone', 'America/Bogota', true);
SELECT assert_eq('B8 con la zona de la sesion en UTC las fechas del historial salen igual con offset de Bogota (-05:00), por codigo', (SELECT f LIKE '%-05:00' FROM t_tz), true);
-- el detalle corre el motor sobre el CONSULTADO: el CDT (30 dias) y el devengo del bolsillo se materializan al mirarlo
SELECT pg_temp.ir(31);
CREATE TEMP TABLE t_pre AS SELECT (SELECT estado::text FROM public.cdt WHERE cuenta_id = tests.c(1)) AS cdt,
                                  (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE cuenta_id = tests.c(1) AND tipo = 'CDT_VENCIMIENTO') AS venc,
                                  (SELECT ultimo_cobro FROM public.bolsillo WHERE id = (SELECT b1::uuid FROM t_bol)) AS uc;
CREATE TEMP TABLE t_d2 AS SELECT public.admin_detalle_usuario(tests.u(900), tests.u(1)::text) AS d;
SELECT assert_eq('B9 ANTES de consultarlo: CDT ACTIVO, sin cierre; DESPUES: CERRADO con su CDT_VENCIMIENTO (lo escribio el motor al mirar al usuario)',
                 (SELECT ((SELECT cdt FROM t_pre), (SELECT venc FROM t_pre), (SELECT estado::text FROM public.cdt WHERE cuenta_id = tests.c(1)),
                          (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE cuenta_id = tests.c(1) AND tipo = 'CDT_VENCIMIENTO'))::text),
                 '(ACTIVO,0,CERRADO,1)'::text);
SELECT assert_eq('B10 el bolsillo tambien se devengo hasta hoy y el detalle solo lista CDT ACTIVOS: ya no hay ninguno',
                 (SELECT ((SELECT ultimo_cobro FROM public.bolsillo WHERE id = (SELECT b1::uuid FROM t_bol)) = pg_temp.dia(31), (SELECT uc FROM t_pre) < pg_temp.dia(31), jsonb_array_length(d #> '{balance,cdts}'),
                          (d #>> '{balance,principal}')::numeric > 6925000)::text FROM t_d2), '(t,t,0,t)'::text);
-- creditos: solo ACTIVOS (uno pagado por completo desaparece)
CREATE TEMP TABLE t_k2 AS SELECT (public.solicitar_credito(tests.u(2), tests.p(901)::text, 120000, 3) ->> 'id')::uuid AS k;
SELECT public.pagar_cuota(tests.u(2), (SELECT k FROM t_k2)::text) FROM generate_series(1, 3);
SELECT assert_eq('B11 un credito PAGADO no aparece en el detalle; el activo de otro usuario sigue en el suyo',
                 (SELECT ((SELECT estado::text FROM public.credito WHERE id = (SELECT k FROM t_k2)), jsonb_array_length(public.admin_detalle_usuario(tests.u(900), tests.u(2)::text) #> '{balance,creditos}'),
                          jsonb_array_length(public.admin_detalle_usuario(tests.u(900), tests.u(1)::text) #> '{balance,creditos}'))::text), '(PAGADO,0,1)'::text);
-- limite de 50 en el historial
SELECT tests.fondear(tests.c(6), 1000 + g) FROM generate_series(1, 55) g;
SELECT assert_eq('B12 el historial trae las ultimas 50 (de 55 movimientos), la mas reciente primero',
                 (SELECT (jsonb_array_length(d -> 'historial'), d #>> '{historial,0,monto}', d #>> '{historial,49,monto}')::text FROM (SELECT public.admin_detalle_usuario(tests.u(900), tests.u(6)::text) AS d) x), '(50,1055.00,1006.00)'::text);
-- sin nada pendiente, consultar no cambia nada
CREATE TEMP TABLE t_h AS SELECT tests.huella_saldos() AS h, (SELECT count(*) FROM audit.evento) AS ev;
SELECT public.admin_detalle_usuario(tests.u(900), tests.u(6)::text);
SELECT assert_eq('B13 un segundo detalle sin nada vencido no cambia saldos ni audita (solo lectura)', (tests.huella_saldos() = (SELECT h FROM t_h), (SELECT count(*) FROM audit.evento) = (SELECT ev FROM t_h))::text, '(t,t)'::text);
SELECT assert_eq('B14 el id es TEXTO y los invalidos son de negocio: desconocido, mal formado, vacio, NULL, un ADMIN y el propio admin = "Recurso no encontrado"',
                 (SELECT array_agg(pg_temp.err(format('SELECT public.admin_detalle_usuario(tests.u(900), %s)', v)) ORDER BY o)
                    FROM unnest(ARRAY[quote_literal('00000000-0000-4000-8000-000000000999'), quote_literal('no-es-uuid'), quote_literal(''), 'NULL', quote_literal(tests.u(901)::text), quote_literal(tests.u(900)::text)]) WITH ORDINALITY x(v, o)),
                 ARRAY_FILL('Recurso no encontrado'::text, ARRAY[6]));
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = tests.u(6);
SELECT assert_eq('B15 un cliente BLOQUEADO se puede consultar (y su estado sale)', public.admin_detalle_usuario(tests.u(900), tests.u(6)::text) ->> 'estado', 'BLOQUEADO'::text);
UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = tests.u(6);

-- ============================================================================
-- C. admin_bloquear / admin_desbloquear
-- ============================================================================
CREATE TEMP TABLE t_c1 AS SELECT public.admin_bloquear(tests.u(900), tests.u(7)::text) AS r;
SELECT assert_eq('C1 bloquear -> {id, estado: BLOQUEADO} y la fila cambia', (SELECT (r ->> 'id', r ->> 'estado', (SELECT estado::text FROM public.usuario WHERE id = tests.u(7)))::text FROM t_c1), ('(' || tests.u(7)::text || ',BLOQUEADO,BLOQUEADO)')::text);
SELECT assert_eq('C2 rige YA: validar_sesion y una funcion de cliente lanzan el mensaje de bloqueo',
                 concat_ws('|', pg_temp.err($$SELECT public.validar_sesion(tests.u(7))$$), pg_temp.err($$SELECT public.vista_balance(tests.u(7))$$)),
                 public._msg_auth('bloqueado') || '|' || public._msg_auth('bloqueado'));
SELECT assert_eq('C3 audita USUARIO_BLOQUEADO: actor = el admin (id y username), antes ACTIVO, despues BLOQUEADO',
                 (SELECT (count(*), min(actor_username), bool_and(actor_id = tests.u(900)), min(antes ->> 'estado'), min(despues ->> 'estado'))::text FROM audit.evento WHERE accion = 'USUARIO_BLOQUEADO' AND entidad_id = tests.u(7)::text),
                 '(1,admin900,t,ACTIVO,BLOQUEADO)'::text);
SELECT public.admin_bloquear(tests.u(900), tests.u(7)::text);
SELECT assert_eq('C4 idempotente: bloquear de nuevo no cambia nada ni agrega un segundo evento', (pg_temp.ev('USUARIO_BLOQUEADO', tests.u(7)::text), (SELECT estado::text FROM public.usuario WHERE id = tests.u(7)))::text, '(1,BLOQUEADO)'::text);
SELECT assert_eq('C5 un bloqueado puede RECIBIR dinero (D-E5-9, equipo): se le puede ajustar y transferir', pg_temp.err(format('SELECT public.admin_ajustar_balance(tests.u(900), %L, 100)', tests.u(7)::text)), 'OK'::text);
CREATE TEMP TABLE t_c2 AS SELECT public.admin_desbloquear(tests.u(900), tests.u(7)::text) AS r;
SELECT assert_eq('C6 desbloquear -> {id, estado: ACTIVO}; validar_sesion vuelve a funcionar; evento USUARIO_DESBLOQUEADO',
                 (SELECT (r ->> 'estado', public.validar_sesion(tests.u(7)) ->> 'estado', pg_temp.ev('USUARIO_DESBLOQUEADO', tests.u(7)::text))::text FROM t_c2), '(ACTIVO,ACTIVO,1)'::text);
SELECT public.admin_desbloquear(tests.u(900), tests.u(7)::text);
SELECT assert_eq('C7 idempotente tambien al desbloquear (sin segundo evento)', pg_temp.ev('USUARIO_DESBLOQUEADO', tests.u(7)::text), 1::bigint);
SELECT assert_eq('C8 solo CLIENTES: otro ADMIN, el propio admin, desconocido, mal formado, vacio y NULL = "Recurso no encontrado" (bloquear y desbloquear)',
                 (SELECT array_agg(DISTINCT pg_temp.err(format('SELECT public.%I(tests.u(900), %s)', f, v)))
                    FROM unnest(ARRAY['admin_bloquear', 'admin_desbloquear']) f,
                         unnest(ARRAY[quote_literal(tests.u(901)::text), quote_literal(tests.u(900)::text), quote_literal('00000000-0000-4000-8000-000000000999'), quote_literal('x'), quote_literal(''), 'NULL']) v),
                 ARRAY['Recurso no encontrado']::text[]);
SELECT assert_eq('C9 los administradores NO cambiaron de estado tras esos intentos', (SELECT array_agg(estado::text ORDER BY username) FROM public.usuario WHERE rol = 'ADMIN'), ARRAY['ACTIVO', 'ACTIVO']::text[]);
SELECT assert_eq('C10 admin_bloquear/desbloquear son SECURITY DEFINER con search_path fijo y devuelven jsonb',
                 (SELECT (count(*), bool_and(prosecdef), bool_and('search_path=public, pg_temp' = ANY (proconfig)), bool_and(prorettype = 'jsonb'::regtype))::text FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('admin_bloquear', 'admin_desbloquear')),
                 '(2,t,t,t)'::text);

-- ============================================================================
-- D. admin_ajustar_balance
-- ============================================================================
CREATE TEMP TABLE t_a1 AS SELECT public.admin_ajustar_balance(tests.u(900), tests.u(8)::text, 150000.50, '  bono   manual ') AS r;
SELECT assert_eq('D1 positivo: {id, monto, fecha}; saldo = 150000.50', (SELECT (r ->> 'monto', jsonb_typeof(r -> 'id'), jsonb_typeof(r -> 'fecha'), (SELECT balance FROM public.cuenta WHERE id = tests.c(8)))::text FROM t_a1), '(150000.50,string,string,150000.50)'::text);
SELECT assert_eq('D2 el libro: UN grupo AJUSTE_ADMIN con 2 patas (CUENTA E + RESULTADO E), contraparte Banco Digital, nota normalizada, misma fecha que devuelve la funcion',
                 (SELECT (count(*), array_agg(contenedor::text || sentido::text ORDER BY contenedor::text), bool_and(contraparte_nombre = 'Banco Digital'), bool_and(nota = 'bono manual'), count(DISTINCT fecha),
                          min(fecha) = ((SELECT r FROM t_a1) ->> 'fecha')::timestamptz)::text FROM public.transaccion WHERE grupo_id = ((SELECT r FROM t_a1) ->> 'id')::uuid),
                 '(2,"{CUENTAE,RESULTADOE}",t,t,1,t)'::text);
SELECT assert_eq('D3 aparece en el historial del cliente como recibo AJUSTE_ADMIN de Banco Digital con su nota',
                 (SELECT (e ->> 'tipo', e ->> 'tipo_detalle', e ->> 'contraparte', e ->> 'nota')::text FROM jsonb_array_elements(public.vista_historial(tests.u(8), 50)) e WHERE e ->> 'tipo_detalle' = 'AJUSTE_ADMIN'),
                 '(recibo,AJUSTE_ADMIN,"Banco Digital","bono manual")'::text);
CREATE TEMP TABLE t_a2 AS SELECT public.admin_ajustar_balance(tests.u(900), tests.u(8)::text, -50000.25) AS r;
SELECT assert_eq('D4 negativo: saldo 100000.25; patas CUENTA S + RESULTADO S; en el historial es un envio',
                 (SELECT ((SELECT balance FROM public.cuenta WHERE id = tests.c(8)), (SELECT array_agg(contenedor::text || sentido::text ORDER BY contenedor::text) FROM public.transaccion WHERE grupo_id = ((SELECT r FROM t_a2) ->> 'id')::uuid),
                          (SELECT e ->> 'tipo' FROM jsonb_array_elements(public.vista_historial(tests.u(8), 1)) e))::text), '(100000.25,"{CUENTAS,RESULTADOS}",envio)'::text);
SELECT public.admin_ajustar_balance(tests.u(900), 'cli8', 1);
SELECT public.admin_ajustar_balance(tests.u(900), 'CLI8', 1);
SELECT public.admin_ajustar_balance(tests.u(900), pg_temp.num(8), 1);
SELECT public.admin_ajustar_balance(tests.u(900), ' ' || tests.u(8)::text || ' ', 1);
SELECT assert_eq('D5 el destino se puede dar como uuid, username (en cualquier caso), numero de cuenta o uuid con espacios: 4 ajustes de +1', (SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(8)), 100004.25::numeric);
CREATE TEMP TABLE t_h2 AS SELECT tests.huella_saldos() AS h, (SELECT count(*) FROM audit.evento) AS ev;
SELECT assert_eq('D6 un ajuste negativo que dejaria la cuenta bajo cero = "Saldo insuficiente" y NO cambia nada (ni libro ni evento)',
                 pg_temp.err(format('SELECT public.admin_ajustar_balance(tests.u(900), %L, -200000)', tests.u(8)::text)), 'Saldo insuficiente'::text);
SELECT assert_eq('D7 ...ni saldos ni patas ni auditoria', (tests.huella_saldos() = (SELECT h FROM t_h2), (SELECT count(*) FROM audit.evento) = (SELECT ev FROM t_h2))::text, '(t,t)'::text);
SELECT assert_eq('D8 monto invalido: 0, NULL, NaN, Infinity, 3 decimales, -0.001, 1e13 y -1e13 = "Monto inválido"',
                 (SELECT array_agg(DISTINCT pg_temp.err(format('SELECT public.admin_ajustar_balance(tests.u(900), %L, %s::numeric)', tests.u(8)::text, v)))
                    FROM unnest(ARRAY['0', 'NULL', '''NaN''', '''Infinity''', '1.005', '-0.001', '10000000000000', '-10000000000000']) v),
                 ARRAY['Monto inválido']::text[]);
SELECT assert_eq('D9 el monto se valida ANTES que el destino (un monto malformado no sirve para sondear usuarios)',
                 pg_temp.err($$SELECT public.admin_ajustar_balance(tests.u(900), 'no-existe', 0)$$), 'Monto inválido'::text);
SELECT assert_eq('D10 destino invalido: otro ADMIN (por uuid y por username), el propio admin, uuid y username desconocidos, cuenta inexistente, texto raro, vacio y NULL = "Recurso no encontrado"',
                 (SELECT array_agg(DISTINCT pg_temp.err(format('SELECT public.admin_ajustar_balance(tests.u(900), %s, 10)', v)))
                    FROM unnest(ARRAY[quote_literal(tests.u(901)::text), quote_literal('admin901'), quote_literal(tests.u(900)::text), quote_literal('00000000-0000-4000-8000-000000000999'), quote_literal('nadie123'),
                                      quote_literal('4099999999'), quote_literal('%'), quote_literal(''), 'NULL']) v),
                 ARRAY['Recurso no encontrado']::text[]);
SELECT assert_eq('D11 nota: 140 caracteres ok; 141 = "Nota inválida"; vacia, espacios o NULL = sin nota',
                 concat_ws('|', pg_temp.err(format('SELECT public.admin_ajustar_balance(tests.u(900), %L, 1, %L)', tests.u(8)::text, repeat('x', 140))),
                                pg_temp.err(format('SELECT public.admin_ajustar_balance(tests.u(900), %L, 1, %L)', tests.u(8)::text, repeat('x', 141))),
                                pg_temp.err(format('SELECT public.admin_ajustar_balance(tests.u(900), %L, 1, %L)', tests.u(8)::text, '   ')),
                                pg_temp.err(format('SELECT public.admin_ajustar_balance(tests.u(900), %L, 1, NULL)', tests.u(8)::text))),
                 'OK|Nota inválida|OK|OK');
SELECT assert_eq('D12 las notas vacias o NULL quedan NULL en el libro', (SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(8) AND tipo = 'AJUSTE_ADMIN' AND nota IS NULL), 14::bigint);
-- audita
SELECT assert_eq('D13 cada ajuste exitoso escribe UN evento AJUSTE_ADMIN (actor admin) con saldos antes/despues, monto con signo y el grupo del libro',
                 (SELECT (count(*), count(DISTINCT despues ->> 'grupo_id'), bool_and(actor_username = 'admin900'),
                          (SELECT (antes ->> 'balance', despues ->> 'balance', despues ->> 'monto', despues ->> 'grupo_id' = (SELECT r ->> 'id' FROM t_a2))
                             FROM audit.evento WHERE accion = 'AJUSTE_ADMIN' AND despues ->> 'grupo_id' = (SELECT r ->> 'id' FROM t_a2)))::text
                    FROM audit.evento WHERE accion = 'AJUSTE_ADMIN' AND entidad_id = tests.c(8)::text AND despues ->> 'username' = 'cli8' AND (despues ->> 'monto')::numeric <> 100),
                 '(9,9,t,"(150000.50,100000.25,-50000.25,t)")'::text);
-- el ajuste corre el motor ANTES (el saldo ya incluye intereses y cierres)
SELECT pg_temp.ir(45);
CREATE TEMP TABLE t_pre2 AS SELECT (SELECT ultimo_cobro FROM public.bolsillo WHERE id = (SELECT b1::uuid FROM t_bol)) AS uc,
                                   (SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(1) AND tipo = 'INTERES_BOLSO') AS n;
SELECT public.admin_ajustar_balance(tests.u(900), tests.u(1)::text, 10, 'motor');
SELECT assert_eq('D14 el ajuste devenga ANTES de escribir: el bolsillo se pone al dia y aparece su INTERES_BOLSO',
                 ((SELECT ultimo_cobro FROM public.bolsillo WHERE id = (SELECT b1::uuid FROM t_bol)) = pg_temp.dia(45), (SELECT uc FROM t_pre2) = pg_temp.dia(31),
                  (SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(1) AND tipo = 'INTERES_BOLSO') > (SELECT n FROM t_pre2))::text, '(t,t,t)'::text);
-- atomicidad: falla en la 2a pata, en la auditoria
SELECT tests.instalar_fallas();
CREATE TEMP TABLE t_h3 AS SELECT tests.huella_saldos() AS h, (SELECT count(*) FROM audit.evento) AS ev;
SELECT tests.falla('tx:2');
SELECT assert_eq('D15 un fallo en la 2a pata revierte TODO: error, huella intacta, sin evento',
                 (pg_temp.err(format('SELECT public.admin_ajustar_balance(tests.u(900), %L, 5)', tests.u(8)::text)) LIKE 'FALLA INYECTADA%', tests.huella_saldos() = (SELECT h FROM t_h3), (SELECT count(*) FROM audit.evento) = (SELECT ev FROM t_h3))::text, '(t,t,t)'::text);
SELECT tests.falla('tx:1');
SELECT assert_eq('D16 un fallo en la 1a pata tambien', (pg_temp.err(format('SELECT public.admin_ajustar_balance(tests.u(900), %L, 5)', tests.u(8)::text)) LIKE 'FALLA INYECTADA%', tests.huella_saldos() = (SELECT h FROM t_h3))::text, '(t,t)'::text);
SELECT tests.falla('');
SELECT tests.quitar_fallas();
CREATE FUNCTION tests.trg_falla_audit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
BEGIN
  IF current_setting('tests.falla_audit', true) = '1' THEN RAISE EXCEPTION 'FALLA INYECTADA en la auditoria' USING ERRCODE = 'P0001'; END IF;
  RETURN NEW;
END $f$;
CREATE TRIGGER trg_zz_falla_audit BEFORE INSERT ON audit.evento FOR EACH ROW EXECUTE FUNCTION tests.trg_falla_audit();
SELECT set_config('tests.falla_audit', '1', true);
SELECT assert_eq('D17 si la AUDITORIA falla (ultimo paso) el ajuste ya hecho en el libro se revierte: el evento y el dinero entran juntos o no entran',
                 (pg_temp.err(format('SELECT public.admin_ajustar_balance(tests.u(900), %L, 5)', tests.u(8)::text)) LIKE 'FALLA INYECTADA%', tests.huella_saldos() = (SELECT h FROM t_h3))::text, '(t,t)'::text);
SELECT set_config('tests.falla_audit', '0', true);

-- ============================================================================
-- E. admin_borrar_usuario
-- ============================================================================
SELECT count(tests.cliente(n)) FROM generate_series(21, 25) n;
UPDATE public.usuario SET referido_por = tests.u(21) WHERE id = tests.u(22);
SELECT tests.fondear(tests.c(21), 3000000);
SELECT tests.fondear(tests.c(23), 500000);
CREATE TEMP TABLE t_bol21 AS SELECT public.crear_bolsillo(tests.u(21), 'Ahorro') ->> 'id' AS b;
SELECT public.mover_a_bolsillo(tests.u(21), (SELECT b FROM t_bol21), 200000);
SELECT public.crear_cdt(tests.u(21), tests.p(930)::text, 500000);
SELECT public.solicitar_credito(tests.u(21), tests.p(901)::text, 1000000, 6);
SELECT public.hacer_transferencia(tests.u(21), pg_temp.num(23), 100000, 'de 21 a 23', NULL);
SELECT public.hacer_transferencia(tests.u(23), pg_temp.num(21), 40000, 'de 23 a 21', NULL);
CREATE TEMP TABLE t_v AS SELECT (SELECT balance FROM public.cuenta WHERE id = tests.c(21)) AS bal, (SELECT sum(capital_pendiente) FROM public.credito WHERE cuenta_id = tests.c(21)) AS pas,
                                (SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(21)) AS patas, (SELECT id FROM public.credito WHERE cuenta_id = tests.c(21)) AS k,
                                jsonb_array_length(public.vista_historial(tests.u(23), 50)) AS h23;
SELECT assert_eq('E0 el escenario de la victima (21): saldo, bolsillo, CDT, credito vivo, un referido y transferencias cruzadas con el 23',
                 (SELECT ((SELECT count(*) FROM public.bolsillo WHERE cuenta_id = tests.c(21)), (SELECT count(*) FROM public.cdt WHERE cuenta_id = tests.c(21)), (SELECT pas FROM t_v), (SELECT count(*) FROM public.usuario WHERE referido_por = tests.u(21)))::text),
                 '(1,1,1000000.00,1)'::text);
CREATE TEMP TABLE t_e1 AS SELECT public.admin_borrar_usuario(tests.u(900), tests.u(21)::text) AS r;
SELECT assert_eq('E1 devuelve {id, borrado: true}', (SELECT (r ->> 'id', r ->> 'borrado')::text FROM t_e1), ('(' || tests.u(21)::text || ',true)')::text);
SELECT assert_eq('E2 la cascada deja 0 filas del usuario en las 8 tablas (usuario, cuenta, bolsillo, cdt, credito, cuota, transaccion) y del propio credito',
                 (SELECT (SELECT count(*) FROM public.usuario WHERE id = tests.u(21)) + (SELECT count(*) FROM public.cuenta WHERE id = tests.c(21)) + (SELECT count(*) FROM public.bolsillo WHERE cuenta_id = tests.c(21))
                       + (SELECT count(*) FROM public.cdt WHERE cuenta_id = tests.c(21)) + (SELECT count(*) FROM public.credito WHERE cuenta_id = tests.c(21))
                       + (SELECT count(*) FROM public.cuota WHERE credito_id = (SELECT k FROM t_v)) + (SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(21))),
                 0::bigint);
SELECT assert_eq('E3 el referido SOBREVIVE y queda con referido_por NULL (ON DELETE SET NULL de E1)', (SELECT (count(*), count(referido_por))::text FROM public.usuario WHERE id = tests.u(22)), '(1,0)'::text);
SELECT assert_eq('E4 el historial del TERCERO (23) conserva "Nombre · cuenta" del borrado en ambas direcciones: nada que reescribir (la contraparte es texto al insertar) y no pierde ninguna fila',
                 (SELECT (count(*), count(DISTINCT e ->> 'contraparte'), min(e ->> 'contraparte'), jsonb_array_length(public.vista_historial(tests.u(23), 50)) = (SELECT h23 FROM t_v))::text
                    FROM jsonb_array_elements(public.vista_historial(tests.u(23), 50)) e WHERE e ->> 'tipo_detalle' IN ('ENVIO', 'RECIBO')),
                 '(2,1,"Nombre21 Apellido · 4000000021",t)'::text);
SELECT assert_eq('E5 audita USUARIO_BORRADO (actor admin; username, estado y numero de cuenta) y el CUENTA_BORRADA de E2 con el admin como actor y los saldos y la deuda que se destruyen',
                 (SELECT (pg_temp.ev('USUARIO_BORRADO', tests.u(21)::text),
                          (SELECT (min(actor_username), bool_and(actor_id = tests.u(900)), min(antes ->> 'username'), min(antes ->> 'numero_cuenta'), min(antes ->> 'estado')) FROM audit.evento WHERE accion = 'USUARIO_BORRADO' AND entidad_id = tests.u(21)::text),
                          (SELECT (count(*), min(actor_username), min((antes ->> 'balance')::numeric) = (SELECT bal FROM t_v), min((antes ->> 'pasivos')::numeric) = (SELECT pas FROM t_v), min((antes ->> 'patas')::int) = (SELECT patas FROM t_v))
                             FROM audit.evento WHERE accion = 'CUENTA_BORRADA' AND entidad_id = tests.c(21)::text))::text),
                 '(1,"(admin900,t,cli21,4000000021,ACTIVO)","(1,admin900,t,t,t)")'::text);
SELECT assert_eq('E6 el dinero y la deuda destruidos quedan CONCILIADOS: v_integridad_global.ok sigue verdadero tras el borrado', (SELECT ok FROM public.v_integridad_global), true);
SELECT assert_eq('E7 no se puede borrar a un ADMIN, a uno mismo, ni a un id desconocido, mal formado, vacio o NULL: "Recurso no encontrado" y los administradores siguen ahi',
                 (SELECT (array_agg(DISTINCT pg_temp.err(format('SELECT public.admin_borrar_usuario(tests.u(900), %s)', v))), (SELECT count(*) FROM public.usuario WHERE rol = 'ADMIN'))::text
                    FROM unnest(ARRAY[quote_literal(tests.u(901)::text), quote_literal(tests.u(900)::text), quote_literal('00000000-0000-4000-8000-000000000999'), quote_literal('x'), quote_literal(''), 'NULL']) v),
                 '("{""Recurso no encontrado""}",2)'::text);
SELECT assert_eq('E8 borrar dos veces al mismo = "Recurso no encontrado"', pg_temp.err(format('SELECT public.admin_borrar_usuario(tests.u(900), %L)', tests.u(21)::text)), 'Recurso no encontrado'::text);
SELECT assert_eq('E9 la sesion del borrado queda invalida: validar_sesion y una funcion de cliente = "Sesión inválida"',
                 concat_ws('|', pg_temp.err($$SELECT public.validar_sesion(tests.u(21))$$), pg_temp.err($$SELECT public.vista_balance(tests.u(21))$$)), 'Sesión inválida|Sesión inválida'::text);
-- atomicidad: fallo en la cascada y fallo en la auditoria
CREATE FUNCTION tests.trg_falla_borrado() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
BEGIN
  IF current_setting('tests.falla_borrado', true) = '1' THEN RAISE EXCEPTION 'FALLA INYECTADA en el borrado de la cuenta' USING ERRCODE = 'P0001'; END IF;
  RETURN OLD;
END $f$;
CREATE TRIGGER trg_zz_falla_borrado BEFORE DELETE ON public.cuenta FOR EACH ROW EXECUTE FUNCTION tests.trg_falla_borrado();
CREATE TEMP TABLE t_h4 AS SELECT tests.huella_saldos() AS h, (SELECT count(*) FROM audit.evento) AS ev;
SELECT set_config('tests.falla_borrado', '1', true);
SELECT assert_eq('E10 un fallo DURANTE la cascada revierte todo, incluido el evento USUARIO_BORRADO que ya se habia escrito: el usuario 24 sigue intacto',
                 (pg_temp.err(format('SELECT public.admin_borrar_usuario(tests.u(900), %L)', tests.u(24)::text)) LIKE 'FALLA INYECTADA%', (SELECT count(*) FROM public.usuario WHERE id = tests.u(24)), (SELECT count(*) FROM public.cuenta WHERE id = tests.c(24)),
                  tests.huella_saldos() = (SELECT h FROM t_h4), (SELECT count(*) FROM audit.evento) = (SELECT ev FROM t_h4))::text, '(t,1,1,t,t)'::text);
SELECT set_config('tests.falla_borrado', '0', true);
SELECT set_config('tests.falla_audit', '1', true);
SELECT assert_eq('E11 si la AUDITORIA falla, no se borra nada', (pg_temp.err(format('SELECT public.admin_borrar_usuario(tests.u(900), %L)', tests.u(24)::text)) LIKE 'FALLA INYECTADA%', (SELECT count(*) FROM public.usuario WHERE id = tests.u(24)))::text, '(t,1)'::text);
SELECT set_config('tests.falla_audit', '0', true);
SELECT public.admin_borrar_usuario(tests.u(900), tests.u(24)::text);
SELECT assert_eq('E12 sin fallos el mismo borrado se completa: usuario y cuenta ya no existen y quedan sus 2 eventos',
                 ((SELECT count(*) FROM public.usuario WHERE id = tests.u(24)), pg_temp.ev('USUARIO_BORRADO', tests.u(24)::text), (SELECT count(*) FROM audit.evento WHERE accion = 'CUENTA_BORRADA' AND entidad_id = tests.c(24)::text))::text, '(0,1,1)'::text);
SELECT assert_eq('E13 todo el recorrido deja los invariantes del libro en orden (saldos, cuadre, conservacion y defensas)', (SELECT ok FROM public.v_integridad_global), true);

ROLLBACK;
