-- 45_auth_permisos.test.sql · Etapa 4 · permisos por ROL REAL (SET LOCAL ROLE, no superusuario): banco_app ejecuta SOLO las 5 funciones publicas y nada
-- de tablas; banco_lector no ejecuta ninguna; banco_dev las hereda; las internas no las ejecuta nadie; nada para PUBLIC.
BEGIN;

CREATE TEMP TABLE t_c AS SELECT tests.reg(1) AS r;
SELECT set_config('tests.cli', (SELECT r ->> 'usuario_id' FROM t_c), true);
SELECT set_config('tests.usr', (SELECT r ->> 'username' FROM t_c), true);

-- ============================================================================
-- 1. banco_app (el backend) con la conexion de ROL REAL: las 5 funciones funcionan de punta a punta
-- ============================================================================
SELECT assert_ok('banco_app: registrar_usuario',
   $$SET LOCAL ROLE banco_app; SELECT public.registrar_usuario('Pedro', 'Pardo', '8100000001', 'pp1@mail.co', '3111111111', '1991-02-03', tests.hash(), true, NULL, true)$$);
SELECT assert_ok('banco_app: obtener_credenciales (login paso 1)', $$SET LOCAL ROLE banco_app; SELECT * FROM public.obtener_credenciales(current_setting('tests.usr'))$$);
SELECT assert_ok('banco_app: validar_sesion (cada peticion)', $$SET LOCAL ROLE banco_app; SELECT public.validar_sesion(current_setting('tests.cli')::uuid)$$);
SELECT assert_ok('banco_app: vista_perfil', $$SET LOCAL ROLE banco_app; SELECT public.vista_perfil(current_setting('tests.cli')::uuid)$$);
SELECT assert_ok('banco_app: verificar_correo', $$SET LOCAL ROLE banco_app; SELECT public.verificar_correo(current_setting('tests.cli')::uuid)$$);
SELECT assert_eq('el registro hecho por banco_app creo al usuario y su cuenta con los 5 ingresos (efecto real, no solo "sin error")',
                 (SELECT (count(DISTINCT t.grupo_id))::text FROM public.usuario u JOIN public.cuenta c ON c.usuario_id = u.id JOIN public.transaccion t ON t.cuenta_id = c.id WHERE u.cedula = '8100000001'), '5'::text);
SELECT assert_eq('verificar_correo ejecutado por banco_app marco el correo', (SELECT correoverificado FROM public.usuario WHERE id = current_setting('tests.cli')::uuid), true);

-- ============================================================================
-- 2. banco_dev: hereda EXECUTE de banco_app (explorar desde pgAdmin sin ser superusuario)
-- ============================================================================
SELECT assert_ok('banco_dev (hereda de banco_app): obtener_credenciales, validar_sesion y vista_perfil',
   $$SET LOCAL ROLE banco_dev; SELECT * FROM public.obtener_credenciales(current_setting('tests.usr')); SELECT public.validar_sesion(current_setting('tests.cli')::uuid); SELECT public.vista_perfil(current_setting('tests.cli')::uuid)$$);

-- ============================================================================
-- 3. banco_lector: NINGUNA de las 5 (solo lectura de vistas)
-- ============================================================================
DO $do$
DECLARE f text; mal text := '';
BEGIN
  FOREACH f IN ARRAY ARRAY['registrar_usuario(''A'',''B'',''1234567'',''a@b.co'',''3000000000'',''1990-01-01'',''x'',true,NULL,true)',
                           'obtener_credenciales(''x'')', 'validar_sesion(gen_random_uuid())', 'verificar_correo(gen_random_uuid())', 'vista_perfil(gen_random_uuid())'] LOOP
    IF coalesce(tests.captura('SET LOCAL ROLE banco_lector; SELECT public.' || f), '') NOT LIKE 'permission denied for function%' THEN mal := mal || f || '; '; END IF;
    RESET ROLE;
  END LOOP;
  PERFORM tests.assert_eq('banco_lector NO ejecuta ninguna de las 5 funciones publicas (permission denied)', mal, ''::text);
END $do$;

-- ============================================================================
-- 4. Las INTERNAS no las ejecuta nadie (ni banco_app, ni lector, ni dev)
-- ============================================================================
DO $do$
DECLARE r text; f text; mal text := ''; v_msg text;
BEGIN
  FOREACH f IN ARRAY ARRAY['_reglas_registro()', '_msg_auth(''politica'')', '_nombre_valido(''Ana'')', '_norm_texto(''a'')', '_norm_digitos(''1'', true)',
                           '_norm_cedula(''1234567'')', '_norm_telefono(''3001234567'')', '_username_base(''a'',''b'')', '_edad_en(DATE ''2000-01-01'', DATE ''2020-01-01'')',
                           '_es_hash_bcrypt(''x'')', '_validar_cliente(gen_random_uuid())', '_validar_admin(gen_random_uuid())', '_pagar_bono_referido(gen_random_uuid(), now())'] LOOP
    FOREACH r IN ARRAY ARRAY['banco_app', 'banco_lector', 'banco_dev'] LOOP
      v_msg := coalesce(tests.captura('SET LOCAL ROLE ' || r || '; SELECT public.' || f), '');
      RESET ROLE;
      IF v_msg NOT LIKE 'permission denied for function%' THEN mal := mal || r || ':' || f || ' [' || v_msg || ']; '; END IF;
    END LOOP;
  END LOOP;
  PERFORM tests.assert_eq('las 13 funciones internas de E4 dan permission denied a banco_app, banco_lector y banco_dev (39 combinaciones)', mal, ''::text);
END $do$;

-- ============================================================================
-- 5. banco_app sin tablas: solo funciones
-- ============================================================================
SELECT assert_raises('banco_app NO lee usuario', $$SET LOCAL ROLE banco_app; SELECT * FROM public.usuario$$, 'permission denied for table usuario', '42501');
SELECT assert_raises('banco_app NO lee password_hash', $$SET LOCAL ROLE banco_app; SELECT password_hash FROM public.usuario$$, NULL, '42501');
SELECT assert_raises('banco_app NO lee cuenta', $$SET LOCAL ROLE banco_app; SELECT * FROM public.cuenta$$, 'permission denied for table cuenta', '42501');
SELECT assert_raises('banco_app NO lee el libro', $$SET LOCAL ROLE banco_app; SELECT * FROM public.transaccion$$, 'permission denied for table transaccion', '42501');
SELECT assert_raises('banco_app NO lee la auditoria', $$SET LOCAL ROLE banco_app; SELECT * FROM audit.evento$$, NULL, '42501');
SELECT assert_raises('banco_app NO inserta usuarios a mano', $$SET LOCAL ROLE banco_app; INSERT INTO public.usuario (username) VALUES ('x')$$, NULL, '42501');
SELECT assert_raises('banco_app NO actualiza usuarios (estado, rol, hash, bandera de bono)', $$SET LOCAL ROLE banco_app; UPDATE public.usuario SET estado = 'ACTIVO'$$, NULL, '42501');
SELECT assert_raises('banco_app NO borra usuarios', $$SET LOCAL ROLE banco_app; DELETE FROM public.usuario$$, NULL, '42501');
SELECT assert_raises('banco_app NO toca saldos', $$SET LOCAL ROLE banco_app; UPDATE public.cuenta SET balance = balance + 1$$, NULL, '42501');
SELECT assert_raises('banco_app NO ejecuta _asentar_grupo', $$SET LOCAL ROLE banco_app; SELECT public._asentar_grupo(now(), '[]'::jsonb)$$, 'permission denied for function _asentar_grupo', '42501');
-- (SET ROLE desde una sesion de superusuario no sirve para probar esto; aqui se mira la membresia y la conexion REAL esta en reales/39)
SELECT assert_eq('banco_app, banco_lector y banco_dev NO pueden asumir banco_owner ni banco_ledger (pg_has_role MEMBER/USAGE/SET)',
                 (SELECT count(*) FROM (VALUES ('banco_app'), ('banco_lector'), ('banco_dev')) r(x), (VALUES ('banco_owner'), ('banco_ledger')) g(y), (VALUES ('MEMBER'), ('USAGE'), ('SET')) m(z)
                   WHERE pg_has_role(r.x, g.y, m.z)), 0::bigint);
SELECT assert_raises('banco_app NO lee las vistas de integridad (solo lector y dev)', $$SET LOCAL ROLE banco_app; SELECT * FROM public.v_integridad_auth$$, 'permission denied for view v_integridad_auth', '42501');
SELECT assert_ok('banco_lector SI lee v_integridad_auth (verificacion independiente)', $$SET LOCAL ROLE banco_lector; SELECT * FROM public.v_integridad_auth$$);
SELECT assert_raises('...y banco_lector sigue sin poder leer password_hash', $$SET LOCAL ROLE banco_lector; SELECT password_hash FROM public.usuario$$, NULL, '42501');

-- ============================================================================
-- 6. Catalogo: dueño, SECURITY DEFINER, search_path, COMMENT y ACL
-- ============================================================================
SELECT assert_eq('las 5 publicas: dueño banco_owner, SECURITY DEFINER, search_path fijo, COMMENT',
                 (SELECT (count(*), bool_and(pg_get_userbyid(proowner) = 'banco_owner'), bool_and(prosecdef), bool_and('search_path=public, pg_temp' = ANY (proconfig)),
                          bool_and(obj_description(oid, 'pg_proc') IS NOT NULL))::text FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                    AND proname IN ('registrar_usuario', 'obtener_credenciales', 'validar_sesion', 'verificar_correo', 'vista_perfil')), '(5,t,t,t,t)'::text);
SELECT assert_eq('las 13 internas: dueño banco_owner, NO son SECURITY DEFINER (solo las llaman funciones definer), search_path fijo, COMMENT',
                 (SELECT (count(*), bool_and(pg_get_userbyid(proowner) = 'banco_owner'), bool_and(NOT prosecdef), bool_and('search_path=public, pg_temp' = ANY (proconfig)),
                          bool_and(obj_description(oid, 'pg_proc') IS NOT NULL))::text FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                    AND proname IN ('_reglas_registro', '_msg_auth', '_nombre_valido', '_norm_texto', '_norm_digitos', '_norm_cedula', '_norm_telefono', '_username_base',
                                    '_edad_en', '_es_hash_bcrypt', '_validar_cliente', '_validar_admin', '_pagar_bono_referido')), '(13,t,t,t,t)'::text);
SELECT assert_eq('ACL de las 5 publicas: solo banco_owner y banco_app (ni PUBLIC, ni lector, ni dev explicito)',
                 (SELECT array_agg(DISTINCT CASE a.grantee WHEN 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END ORDER BY CASE a.grantee WHEN 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END)
                    FROM pg_proc p, aclexplode(p.proacl) a WHERE p.pronamespace = 'public'::regnamespace AND a.privilege_type = 'EXECUTE'
                     AND p.proname IN ('registrar_usuario', 'obtener_credenciales', 'validar_sesion', 'verificar_correo', 'vista_perfil')),
                 ARRAY['banco_app', 'banco_owner']::text[]);
SELECT assert_eq('ACL de las 13 internas: solo su dueño banco_owner',
                 (SELECT array_agg(DISTINCT pg_get_userbyid(a.grantee)::text) FROM pg_proc p, aclexplode(p.proacl) a
                   WHERE p.pronamespace = 'public'::regnamespace AND a.privilege_type = 'EXECUTE'
                     AND p.proname IN ('_reglas_registro', '_msg_auth', '_nombre_valido', '_norm_texto', '_norm_digitos', '_norm_cedula', '_norm_telefono', '_username_base',
                                       '_edad_en', '_es_hash_bcrypt', '_validar_cliente', '_validar_admin', '_pagar_bono_referido')),
                 ARRAY['banco_owner']::text[]);
SELECT assert_eq('la funcion de reenvio de verificacion NO existe (D-E4-9 pendiente de Juan): ni la funcion ni un permiso para ella', to_regproc('public.datos_reenvio_verificacion'), NULL::regproc);

-- ============================================================================
-- 7. Las defensas de integridad detectan una concesion indebida
-- ============================================================================
SELECT assert_true('estado sano: la lista blanca de banco_app esta en orden', (SELECT ok FROM public.v_integridad_defensas WHERE control LIKE 'banco_app ejecuta EXACTAMENTE%'));
SELECT tests.detecta('GRANT EXECUTE de una interna a banco_app lo detecta v_integridad_defensas',
   $s$GRANT EXECUTE ON FUNCTION public._pagar_bono_referido(uuid, timestamptz) TO banco_app$s$,
   $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_defensas WHERE NOT ok)$d$);
SELECT tests.detecta('GRANT EXECUTE de una funcion publica a PUBLIC lo detecta la lista blanca',
   $s$GRANT EXECUTE ON FUNCTION public.obtener_credenciales(text) TO PUBLIC$s$,
   $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_defensas WHERE NOT ok AND control LIKE 'banco_app ejecuta EXACTAMENTE%')$d$);
SELECT tests.detecta('GRANT EXECUTE de una funcion publica a banco_lector lo detecta la lista blanca',
   $s$GRANT EXECUTE ON FUNCTION public.validar_sesion(uuid) TO banco_lector$s$,
   $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_defensas WHERE NOT ok AND control LIKE 'banco_app ejecuta EXACTAMENTE%')$d$);
SELECT tests.detecta('REVOKE de una de las 5 a banco_app (el backend dejaria de funcionar) lo detecta la lista blanca',
   $s$REVOKE EXECUTE ON FUNCTION public.vista_perfil(uuid) FROM banco_app$s$,
   $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_defensas WHERE NOT ok AND control LIKE 'banco_app ejecuta EXACTAMENTE%')$d$);
SELECT tests.detecta('GRANT EXECUTE de OTRA funcion de public (_asentar_grupo) a banco_app lo detecta la lista blanca',
   $s$GRANT EXECUTE ON FUNCTION public._asentar_grupo(timestamptz, jsonb) TO banco_app$s$,
   $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_defensas WHERE NOT ok AND control LIKE 'banco_app ejecuta EXACTAMENTE%')$d$);
SELECT assert_true('tras deshacer los sabotajes las defensas vuelven a estar en orden', (SELECT bool_and(ok) FROM public.v_integridad_defensas));

ROLLBACK;
