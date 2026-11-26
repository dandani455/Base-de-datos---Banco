-- 44_auth_sesion.test.sql · Etapa 4 · obtener_credenciales (login paso 1), validar_sesion (cada peticion), vista_perfil y los helpers
-- _validar_cliente/_validar_admin: usuario inexistente, bloqueado con "sesion abierta", ADMIN, el hash solo sale por obtener_credenciales.
BEGIN;

-- usuarios: un cliente (via registrar_usuario), un cliente que se bloqueara, un admin activo y un admin bloqueado
CREATE TEMP TABLE t_c AS SELECT tests.reg(1, 'Camila', 'Rodríguez') AS r;
CREATE TEMP TABLE t_x AS SELECT tests.reg(2, 'Beto', 'Blanco') AS r;
INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol)
VALUES ('admin1', tests.hash(), 'Admin', 'Uno', '9200001', 'admin1@mail.co', '3180000001', DATE '1980-01-01', 'ADMIN'),
       ('admin2', tests.hash(), 'Admin', 'Dos', '9200002', 'admin2@mail.co', '3180000002', DATE '1980-01-01', 'ADMIN');
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE username = 'admin2';
CREATE TEMP TABLE t_ids AS SELECT tests.uid((SELECT r FROM t_c)) AS cli, tests.uid((SELECT r FROM t_x)) AS bloq,
                                  (SELECT id FROM public.usuario WHERE username = 'admin1') AS adm, (SELECT id FROM public.usuario WHERE username = 'admin2') AS admb;

-- ============================================================================
-- 1. obtener_credenciales
-- ============================================================================
SELECT assert_eq('obtener_credenciales: usuario inexistente = 0 filas (nunca lanza)', (SELECT count(*) FROM public.obtener_credenciales('noexiste999')), 0::bigint);
SELECT assert_eq('obtener_credenciales: NULL y vacio = 0 filas', (SELECT count(*) FROM public.obtener_credenciales(NULL)) + (SELECT count(*) FROM public.obtener_credenciales('')) + (SELECT count(*) FROM public.obtener_credenciales('   ')), 0::bigint);
SELECT assert_eq('obtener_credenciales: el usuario existente devuelve 1 fila con id, hash, rol y estado',
                 (SELECT (usuario_id = (SELECT cli FROM t_ids), password_hash = tests.hash(), rol, estado)::text FROM public.obtener_credenciales((SELECT r ->> 'username' FROM t_c))), '(t,t,CLIENTE,ACTIVO)'::text);
SELECT assert_eq('obtener_credenciales: la firma es TABLE(usuario_id uuid, password_hash text, rol text, estado text)',
                 pg_get_function_result('public.obtener_credenciales(text)'::regprocedure), 'TABLE(usuario_id uuid, password_hash text, rol text, estado text)'::text);
SELECT assert_eq('obtener_credenciales ignora mayusculas y espacios del username', (SELECT count(*) FROM public.obtener_credenciales('  ' || upper((SELECT r ->> 'username' FROM t_c)) || '  ')), 1::bigint);
SELECT assert_eq('obtener_credenciales devuelve tambien al BLOQUEADO (el backend compara bcrypt ANTES de validar_sesion) y al ADMIN',
                 (SELECT (count(*) FILTER (WHERE estado = 'ACTIVO'), count(*) FILTER (WHERE estado = 'BLOQUEADO'), count(*) FILTER (WHERE rol = 'ADMIN'))::text
                    FROM (SELECT * FROM public.obtener_credenciales('admin1') UNION ALL SELECT * FROM public.obtener_credenciales('admin2')) z), '(1,1,2)'::text);
SELECT assert_eq('obtener_credenciales: una cadena de inyeccion no devuelve nada ni rompe', (SELECT count(*) FROM public.obtener_credenciales('x'' OR ''1''=''1')), 0::bigint);

-- ============================================================================
-- 2. validar_sesion
-- ============================================================================
SELECT assert_json_shape('validar_sesion de un cliente: {username, rol, estado}', public.validar_sesion((SELECT cli FROM t_ids)), '{"username":"string","rol":"string","estado":"string"}'::jsonb);
SELECT assert_eq('validar_sesion(cliente) = {username, rol CLIENTE, estado ACTIVO}', public.validar_sesion((SELECT cli FROM t_ids)),
                 jsonb_build_object('username', (SELECT r ->> 'username' FROM t_c), 'rol', 'CLIENTE', 'estado', 'ACTIVO'));
SELECT assert_eq('validar_sesion(admin) devuelve rol ADMIN (el front redirige con el)', public.validar_sesion((SELECT adm FROM t_ids)) ->> 'rol', 'ADMIN'::text);
SELECT assert_eq('validar_sesion de un usuario BLOQUEADO lanza el mensaje EXACTO del contrato (P0001)',
                 tests.captura('SELECT public.validar_sesion(''' || (SELECT admb FROM t_ids) || '''::uuid)'), 'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla'::text);
SELECT assert_raises('...con SQLSTATE P0001', 'SELECT public.validar_sesion(''' || (SELECT admb FROM t_ids) || '''::uuid)', 'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla', 'P0001');
SELECT assert_eq('validar_sesion de un usuario inexistente o NULL: Sesión inválida', (tests.captura($$SELECT public.validar_sesion(gen_random_uuid())$$), tests.captura($$SELECT public.validar_sesion(NULL)$$))::text, '("Sesión inválida","Sesión inválida")'::text);
-- bloqueo con "sesion abierta": la siguiente peticion ya ve el estado nuevo, y al desbloquear vuelve a funcionar
SELECT assert_eq('(sesion abierta) antes de bloquear, validar_sesion pasa', public.validar_sesion((SELECT bloq FROM t_ids)) ->> 'estado', 'ACTIVO'::text);
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = (SELECT bloq FROM t_ids);
SELECT assert_eq('(sesion abierta) tras bloquear, la siguiente peticion recibe el mensaje de bloqueo',
                 tests.captura('SELECT public.validar_sesion(''' || (SELECT bloq FROM t_ids) || '''::uuid)'), 'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla'::text);
UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = (SELECT bloq FROM t_ids);
SELECT assert_eq('(sesion abierta) al desbloquear vuelve a funcionar sin reiniciar nada', public.validar_sesion((SELECT bloq FROM t_ids)) ->> 'estado', 'ACTIVO'::text);
SELECT assert_eq('validar_sesion lee el ROL vivo: si el rol cambia, la siguiente respuesta lo refleja',
                 (SELECT (public.validar_sesion((SELECT adm FROM t_ids)) ->> 'rol')), 'ADMIN'::text);

-- ============================================================================
-- 3. vista_perfil
-- ============================================================================
SELECT assert_json_shape('vista_perfil: {username, numero_cuenta, codigo_referido} (todos texto)', public.vista_perfil((SELECT cli FROM t_ids)),
                         '{"username":"string","numero_cuenta":"string","codigo_referido":"string"}'::jsonb);
SELECT assert_eq('vista_perfil trae los datos del usuario: username, numero de cuenta de 10 digitos y su codigo de referido (uuid)',
                 (SELECT (p ->> 'username' = (SELECT r ->> 'username' FROM t_c), p ->> 'numero_cuenta' ~ '^40[0-9]{8}$',
                          p ->> 'numero_cuenta' = (SELECT numero_cuenta FROM public.cuenta WHERE usuario_id = (SELECT cli FROM t_ids)),
                          p ->> 'codigo_referido' = (SELECT codigo_referido::text FROM public.usuario WHERE id = (SELECT cli FROM t_ids)))::text
                    FROM (SELECT public.vista_perfil((SELECT cli FROM t_ids)) AS p) q), '(t,t,t,t)'::text);
SELECT assert_eq('vista_perfil tiene SOLO 3 claves (no expone saldo, hash, correo ni cedula)', (SELECT count(*) FROM jsonb_object_keys(public.vista_perfil((SELECT cli FROM t_ids)))), 3::bigint);
SELECT assert_eq('vista_perfil de un bloqueado: mensaje de bloqueo; de un ADMIN: Acceso denegado; de un inexistente: Sesión inválida',
                 (tests.captura('SELECT public.vista_perfil(''' || (SELECT admb FROM t_ids) || '''::uuid)'),
                  tests.captura('SELECT public.vista_perfil(''' || (SELECT adm FROM t_ids) || '''::uuid)'),
                  tests.captura($$SELECT public.vista_perfil(gen_random_uuid())$$))::text,
                 '("Acceso denegado","Acceso denegado","Sesión inválida")'::text);
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = (SELECT bloq FROM t_ids);
SELECT assert_eq('vista_perfil de un CLIENTE bloqueado lanza el mensaje de bloqueo',
                 tests.captura('SELECT public.vista_perfil(''' || (SELECT bloq FROM t_ids) || '''::uuid)'), 'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla'::text);
UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = (SELECT bloq FROM t_ids);
-- desviacion consciente del contrato: sin avanzar_hasta
SELECT assert_true('DESVIACION CONSCIENTE: vista_perfil NO ejecuta avanzar_hasta ni toca nada financiero ni dependiente del tiempo (su codigo no menciona saldos, libro ni productos)',
                   (SELECT p.prosrc !~* 'avanzar_hasta|balance|transaccion|bolsillo|cdt|credito|_reloj_instantanea|now\(|clock_timestamp'
                      FROM pg_proc p WHERE p.oid = 'public.vista_perfil(uuid)'::regprocedure));
SELECT assert_true('la desviacion queda documentada en el COMMENT de la funcion',
                   (SELECT obj_description('public.vista_perfil(uuid)'::regprocedure, 'pg_proc') ~ 'DESVIACI.N CONSCIENTE.*avanzar_hasta'));

-- ============================================================================
-- 4. Helpers: matriz rol x estado
-- ============================================================================
CREATE FUNCTION pg_temp.v(p_fn text, p_id uuid) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  EXECUTE format('SELECT public.%I(%L::uuid)', p_fn, p_id);
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM;
END $f$;
SELECT assert_eq('_validar_cliente: cliente activo OK; cliente bloqueado = bloqueo; admin (activo o bloqueado) = Acceso denegado; inexistente = Sesion invalida',
                 (SELECT (pg_temp.v('_validar_cliente', (SELECT cli FROM t_ids)), pg_temp.v('_validar_cliente', (SELECT bloq FROM t_ids)),
                          pg_temp.v('_validar_cliente', (SELECT adm FROM t_ids)), pg_temp.v('_validar_cliente', (SELECT admb FROM t_ids)),
                          pg_temp.v('_validar_cliente', gen_random_uuid()))::text),
                 '(OK,OK,"Acceso denegado","Acceso denegado","Sesión inválida")'::text);
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = (SELECT bloq FROM t_ids);
SELECT assert_eq('_validar_cliente con el cliente ya bloqueado = mensaje de bloqueo', pg_temp.v('_validar_cliente', (SELECT bloq FROM t_ids)), 'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla'::text);
SELECT assert_eq('_validar_admin: admin activo OK; admin bloqueado = bloqueo; clientes (activo o bloqueado) e inexistente = Acceso denegado',
                 (SELECT (pg_temp.v('_validar_admin', (SELECT adm FROM t_ids)), pg_temp.v('_validar_admin', (SELECT admb FROM t_ids)),
                          pg_temp.v('_validar_admin', (SELECT cli FROM t_ids)), pg_temp.v('_validar_admin', (SELECT bloq FROM t_ids)),
                          pg_temp.v('_validar_admin', gen_random_uuid()))::text),
                 '(OK,"Tu cuenta ha sido restringida, contacte con el banco para desbloquearla","Acceso denegado","Acceso denegado","Acceso denegado")'::text);
UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = (SELECT bloq FROM t_ids);

-- ============================================================================
-- 5. El hash solo sale por obtener_credenciales
-- ============================================================================
DO $do$
DECLARE v_h text := tests.hash(); mal text := '';
BEGIN
  IF (SELECT r::text FROM t_c) LIKE '%' || v_h || '%' THEN mal := mal || 'registrar_usuario; '; END IF;
  IF public.validar_sesion((SELECT cli FROM t_ids))::text LIKE '%' || v_h || '%' THEN mal := mal || 'validar_sesion; '; END IF;
  IF public.vista_perfil((SELECT cli FROM t_ids))::text LIKE '%' || v_h || '%' THEN mal := mal || 'vista_perfil; '; END IF;
  IF coalesce(tests.captura($$SELECT public.validar_sesion(gen_random_uuid())$$), '') LIKE '%' || v_h || '%' THEN mal := mal || 'mensaje de error; '; END IF;
  PERFORM tests.assert_eq('ni registrar_usuario, validar_sesion, vista_perfil ni un mensaje de error contienen el hash', mal, ''::text);
END $do$;
SELECT assert_eq('de las 5 funciones publicas, SOLO obtener_credenciales devuelve una columna password_hash',
                 (SELECT array_agg(proname::text ORDER BY proname::text) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                    AND proname IN ('registrar_usuario', 'obtener_credenciales', 'validar_sesion', 'verificar_correo', 'vista_perfil')
                    AND (pg_get_function_result(oid) ~* 'password_hash' OR prosrc ~* 'select[^;]*password_hash[^;]*into')),
                 ARRAY['obtener_credenciales']::text[]);
SELECT assert_true('la integridad global y de autenticacion siguen en orden (con admins sin cuenta y clientes con cuenta)', (SELECT ok FROM public.v_integridad_global) AND (SELECT bool_and(ok) FROM public.v_integridad_auth));

ROLLBACK;
