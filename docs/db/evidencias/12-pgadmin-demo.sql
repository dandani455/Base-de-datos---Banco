-- Demostracion de E12 (Control: admin_esquema y admin_tabla) para pgAdmin: conexion "administracion (postgres)", base banco. NO deja datos NI cambia el reloj: todo va dentro de BEGIN ... ROLLBACK
-- y cada intento rechazado se captura con un sub-bloque, asi que el script NO se aborta y los resultados aparecen como NOTICE en la pestaña "Messages". Ejecutar COMPLETO con F5.
-- (Se usa registrar_usuario de E4 para crear a dos clientes y, solo para esta demo como superusuario, se insertan un administrador con un hash RECONOCIBLE y 70 usuarios de relleno para ver la paginacion.
--  La creacion del primer administrador es del seed (E14, D5).)
BEGIN;
DO $demo$
DECLARE
  h constant text := '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';       -- hash con FORMA de bcrypt
  ua uuid; ub uuid; adm uuid; adb uuid; e jsonb; t jsonb; v_hoy date; v_n0 bigint; v_uc date;
BEGIN
  ua := (public.registrar_usuario('Ana',  'Control', '9900001', 'ana.e12@mail.co',  '3109900001', '1990-05-17', h, true, NULL, true) ->> 'usuario_id')::uuid;
  ub := (public.registrar_usuario('Beto', 'Control', '9900002', 'beto.e12@mail.co', '3109900002', '1991-02-10', h, true, NULL, true) ->> 'usuario_id')::uuid;
  INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol, estado)
  VALUES ('admdemo12', 'HASH-REAL-SECRETO-DEL-ADMIN', 'Admin', 'Demo', '9900900', 'admdemo.e12@mail.co', '3109900900', DATE '1980-01-01', 'ADMIN', 'ACTIVO'),
         ('admblq12', 'HASH-REAL-DEL-BLOQUEADO', 'Admin', 'Bloqueado', '9900901', 'admblq.e12@mail.co', '3109900901', DATE '1980-01-01', 'ADMIN', 'BLOQUEADO');
  SELECT id INTO adm FROM public.usuario WHERE username = 'admdemo12'; SELECT id INTO adb FROM public.usuario WHERE username = 'admblq12';
  INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento)
  SELECT 'relleno' || g, 'HASH-REAL-' || g, 'Relleno' || g, 'Demo', '98' || lpad(g::text, 6, '0'), 'relleno' || g || '@mail.co', '31098' || lpad(g::text, 5, '0'), DATE '1990-01-01' FROM generate_series(1, 70) g;
  v_hoy := public.hoy_banco();
  RAISE NOTICE 'Hoy del banco: %. Hay % usuarios (2 clientes reales, 70 de relleno y 2 administradores).', v_hoy, (SELECT count(*) FROM public.usuario);

  -- 1) el esquema: las 11 tablas, sus columnas con badges y las FK
  e := public.admin_esquema(adm);
  RAISE NOTICE '1) admin_esquema: % tablas, en este orden: %', jsonb_array_length(e -> 'tablas'), (SELECT string_agg(x ->> 'nombre', ', ' ORDER BY o) FROM jsonb_array_elements(e -> 'tablas') WITH ORDINALITY y(x, o));
  RAISE NOTICE '   columnas de usuario con sus banderas (llave / unico / no_nulo / tipo):';
  RAISE NOTICE '     %', (SELECT string_agg((c ->> 'nombre') || CASE WHEN (c ->> 'llave')::boolean THEN ' PK' ELSE '' END || CASE WHEN (c ->> 'unico')::boolean THEN ' UQ' ELSE '' END || CASE WHEN (c ->> 'no_nulo')::boolean THEN ' NN' ELSE '' END || ' [' || (c ->> 'tipo') || ']', ' ; ' ORDER BY o)
                              FROM jsonb_array_elements(e #> '{tablas,0,columnas}') WITH ORDINALITY y(c, o));
  RAISE NOTICE '   total de FK en el esquema: % ; la propia de usuario: % ; la compuesta de cuenta sale UNA vez: %', (SELECT count(*) FROM jsonb_array_elements(e -> 'tablas') tb, jsonb_array_elements(tb -> 'fks') f),
               e #> '{tablas,0,fks}', e #> '{tablas,1,fks}';
  RAISE NOTICE '   audit.evento NO esta (D-E12-D2): %', (e::text LIKE '%evento%');

  -- 2) una tabla: filas paginadas de a 50 y el hash enmascarado
  t := public.admin_tabla(adm, 'usuario');
  RAISE NOTICE '2) admin_tabla(usuario): pagina % de %, % filas en esta pagina (50 por pagina); la mas reciente primero', t ->> 'pagina', t ->> 'total_paginas', jsonb_array_length(t -> 'filas');
  RAISE NOTICE '   la primera fila: %', t #> '{filas,0}';
  RAISE NOTICE '   password_hash distinto de "••••" en esta pagina: % ; aparece algun "HASH-REAL" en la respuesta: %', (SELECT count(*) FROM jsonb_array_elements(t -> 'filas') f WHERE f ->> 'password_hash' <> repeat(chr(8226), 4)), (t::text LIKE '%HASH-REAL%');
  RAISE NOTICE '   (en la BD el hash real SI existe: % usuarios con hash real)', (SELECT count(*) FROM public.usuario WHERE password_hash LIKE 'HASH-REAL%');
  RAISE NOTICE '   pagina 2 -> % filas; pagina 99 (se recorta a la ultima) -> pagina % con % filas; "abc" -> pagina %; NULL -> pagina %', jsonb_array_length(public.admin_tabla(adm, 'usuario', '2') -> 'filas'),
               public.admin_tabla(adm, 'usuario', '99') ->> 'pagina', jsonb_array_length(public.admin_tabla(adm, 'usuario', '99') -> 'filas'), public.admin_tabla(adm, 'usuario', 'abc') ->> 'pagina', public.admin_tabla(adm, 'usuario', NULL) ->> 'pagina';
  RAISE NOTICE '   una tabla vacia (cdt_definicion): %', public.admin_tabla(adm, 'cdt_definicion');
  RAISE NOTICE '   una tabla del libro (transaccion): % filas en total, la pagina 1 trae % y la mas reciente primero (orden %)', (SELECT count(*) FROM public.transaccion), jsonb_array_length(public.admin_tabla(adm, 'transaccion') -> 'filas'), public.admin_tabla(adm, 'transaccion') #>> '{filas,0,orden}';
  RAISE NOTICE '   cuenta (sin enmascarar nada): %', public.admin_tabla(adm, 'cuenta') #> '{filas,0}';

  -- 3) la lista blanca
  RAISE NOTICE '3) fuera de la lista blanca:';
  BEGIN PERFORM public.admin_tabla(adm, 'audit.evento'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '     audit.evento -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_tabla(adm, 'Usuario'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '     Usuario (mayuscula) -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_tabla(adm, 'pg_catalog.pg_user'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '     pg_catalog.pg_user -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_tabla(adm, 'usuario; DROP TABLE cuenta; --'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '     inyeccion "usuario; DROP TABLE cuenta; --" -> "%" (la tabla cuenta sigue: %)', SQLERRM, to_regclass('public.cuenta') IS NOT NULL; END;
  BEGIN PERFORM public.admin_tabla(adm, NULL); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '     NULL -> "%"', SQLERRM; END;

  -- 4) solo lectura: no devenga, no cobra, no audita (muestra lo GUARDADO)
  PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', 1000000, 'cuenta_id', (SELECT id FROM public.cuenta WHERE usuario_id = ua)),
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', 1000000, 'cuenta_id', (SELECT id FROM public.cuenta WHERE usuario_id = ua), 'contraparte_nombre', 'Banco Digital')));
  PERFORM public.crear_bolsillo(ua, 'Viajes');
  PERFORM public.mover_a_bolsillo(ua, (SELECT id::text FROM public.bolsillo WHERE cuenta_id = (SELECT id FROM public.cuenta WHERE usuario_id = ua)), 500000);
  v_n0 := (SELECT count(*) FROM public.transaccion); v_uc := (SELECT ultimo_cobro FROM public.bolsillo LIMIT 1);
  PERFORM public._reloj_actualizar(false, (v_hoy + 40)::text);
  PERFORM public.admin_esquema(adm), public.admin_tabla(adm, 'bolsillo'), public.admin_tabla(adm, 'cuenta');
  RAISE NOTICE '4) con el reloj +40 dias (el bolsillo tendria intereses pendientes) el visor NO escribe nada: patas en el libro = % (antes: %) y el bolsillo sigue con ultimo_cobro = % (antes: %; con el motor seria %)',
               (SELECT count(*) FROM public.transaccion), v_n0, (SELECT ultimo_cobro FROM public.bolsillo LIMIT 1), v_uc, v_hoy + 40;
  RAISE NOTICE '   volatilidad en el catalogo (s = STABLE: PostgreSQL impide que escriban): %', (SELECT string_agg(proname || '=' || provolatile::text, ', ') FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('admin_esquema', 'admin_tabla'));

  -- 5) control de acceso (el administrador se valida ANTES que la tabla)
  RAISE NOTICE '5) un CLIENTE llamando a admin_esquema y a admin_tabla(audit.evento):';
  BEGIN PERFORM public.admin_esquema(ua); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '     -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_tabla(ua, 'audit.evento'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '     -> "%" (no puede ni sondear que tablas existen)', SQLERRM; END;
  BEGIN PERFORM public.admin_tabla(adb, 'usuario'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   un ADMIN BLOQUEADO -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_esquema(gen_random_uuid()); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   un usuario inexistente -> "%"', SQLERRM; END;

  -- 6) permisos
  RAISE NOTICE '6) banco_app ejecuta admin_esquema y admin_tabla (%): % ; _reglas_control: % ; banco_lector ejecuta admin_tabla: % ; funciones publicas de banco_app en total: %',
               'las dos de E12', (has_function_privilege('banco_app', 'public.admin_esquema(uuid)', 'EXECUTE') AND has_function_privilege('banco_app', 'public.admin_tabla(uuid,text,text)', 'EXECUTE')),
               has_function_privilege('banco_app', 'public._reglas_control()', 'EXECUTE'), has_function_privilege('banco_lector', 'public.admin_tabla(uuid,text,text)', 'EXECUTE'),
               (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e') AND has_function_privilege('banco_app', p.oid, 'EXECUTE'));
  RAISE NOTICE '   libro y defensas (desvios de saldos, grupos con error, desvios I5u, defensas caidas, desvio de transferencias) = %  (el control de autenticacion de v_integridad_global.ok no aplica aqui: los 70 usuarios de relleno se insertaron sin cuenta ni ingresos)', (SELECT (contenedores_con_desvio, grupos_con_error, cuentas_con_desvio_i5u, defensas_fallidas, desvio_transferencias) FROM public.v_integridad_global);
  RAISE NOTICE '   _reglas_control (todo lo provisional en un solo lugar): %', public._reglas_control() - 'orden';
END
$demo$;
ROLLBACK;
