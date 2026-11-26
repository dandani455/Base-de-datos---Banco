-- Demostracion de E4 (autenticacion y registro) para pgAdmin: conexion "administracion (postgres)", base banco. NO deja datos: todo va dentro de
-- BEGIN ... ROLLBACK y cada intento prohibido se captura con un sub-bloque, asi que el script NO se aborta y los resultados aparecen como NOTICE en la
-- pestaña "Messages". Ejecutar COMPLETO con F5.
BEGIN;
DO $demo$
DECLARE
  h   constant text := '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';       -- un hash con FORMA de bcrypt (la BD nunca ve la clave en claro)
  r1 jsonb; r2 jsonb; r3 jsonb; r4 jsonb; r5 jsonb;
  u1 uuid; u2 uuid; u3 uuid; u4 uuid;
  cod text; s0 numeric; v_msg text; v_rec record; n int;
BEGIN
  -- 1) Registro completo
  r1 := public.registrar_usuario('María del Pilar', 'Núñez Pérez', '1.234.567', 'Maria@Mail.com', '(300) 123-4567', '1990-05-17', h, true, NULL, true);
  u1 := (r1 ->> 'usuario_id')::uuid;
  RAISE NOTICE '1) registrar_usuario devuelve: %', r1;
  RAISE NOTICE '   guardado normalizado: %', (SELECT format('nombres=%s apellidos=%s cedula=%s correo=%s telefono=%s', nombres, apellidos, cedula, correo, telefono) FROM public.usuario WHERE id = u1);
  RAISE NOTICE '   cuenta: % con balance % = suma de 5 INGRESO_SIMULADO', (SELECT numero_cuenta FROM public.cuenta WHERE usuario_id = u1), (SELECT balance FROM public.cuenta WHERE usuario_id = u1);
  FOR v_rec IN SELECT to_char(t.fecha, 'YYYY-MM-DD HH24:MI') AS fecha, t.monto FROM public.transaccion t WHERE t.cuenta_id = (SELECT id FROM public.cuenta WHERE usuario_id = u1) AND t.contenedor = 'CUENTA' ORDER BY t.orden LOOP
    RAISE NOTICE '     ingreso simulado  % (fecha distinta y ascendente, dentro de los 90 dias previos)  $ %', v_rec.fecha, v_rec.monto;
  END LOOP;

  -- 2) Nombres internacionales: se guardan intactos; el username usa su regla propia
  r2 := public.registrar_usuario('李明', '王', '7654321', 'li@mail.com', '+57 301 765 4321', '1985-01-01', h, true, NULL, true);
  RAISE NOTICE '2) nombre chino: guardado = %  username = %  telefono (+57 canonico) = %', (SELECT nombres || ' ' || apellidos FROM public.usuario WHERE id = (r2 ->> 'usuario_id')::uuid), r2 ->> 'username',
               (SELECT telefono FROM public.usuario WHERE id = (r2 ->> 'usuario_id')::uuid);

  -- 3) Cada validacion con su mensaje exacto
  v_msg := coalesce((SELECT 'OK' WHERE false), 'x');
  BEGIN PERFORM public.registrar_usuario('Ana', 'Gil', '8000001', 'a1@m.co', '3000000001', '1990-01-01', h, false, NULL, true); RAISE NOTICE '3a) !!! FALLO: sin politica fue ACEPTADO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '3a) sin aceptar la politica RECHAZADO: %', SQLERRM; END;
  BEGIN PERFORM public.registrar_usuario('Ana', 'Gil', '8000001', 'a1@m.co', '3000000001', '1990-01-01', 'Banco2026', true, NULL, true); RAISE NOTICE '3b) !!! FALLO: una clave en claro fue ACEPTADA';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '3b) hash que no es bcrypt (clave en claro) RECHAZADO: %', SQLERRM; END;
  BEGIN PERFORM public.registrar_usuario('Ana', 'Gil', '8000001', 'a1@m.co', '3000000001', '1990-01-01', h, true, 'no-es-un-uuid', true); RAISE NOTICE '3c) !!! FALLO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '3c) codigo de referido malformado = error de NEGOCIO (no de driver): %', SQLERRM; END;
  BEGIN PERFORM public.registrar_usuario('Ana', 'Gil', '8000001', 'a1@m.co', '3000000001', '1990-02-30', h, true, NULL, true); RAISE NOTICE '3d) !!! FALLO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '3d) fecha de nacimiento imposible RECHAZADA: %', SQLERRM; END;
  BEGIN PERFORM public.registrar_usuario('Ana', 'Gil', '8000001', 'a1@m.co', '3000000001', to_char(current_date - interval '17 years', 'YYYY-MM-DD'), h, true, NULL, true); RAISE NOTICE '3e) !!! FALLO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '3e) menor de edad RECHAZADO (regla provisional D-E4-12): %', SQLERRM; END;
  BEGIN PERFORM public.registrar_usuario('Robert''); DROP TABLE usuario;--', 'Gil', '8000001', 'a1@m.co', '3000000001', '1990-01-01', h, true, NULL, true); RAISE NOTICE '3f) !!! FALLO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '3f) intento de inyeccion SQL en el nombre RECHAZADO como formato: %', SQLERRM; END;
  BEGIN PERFORM public.registrar_usuario('Ana', 'Gil', '1234567', 'otro@m.co', '3000000002', '1990-01-01', h, true, NULL, true); RAISE NOTICE '3g) !!! FALLO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '3g) cedula duplicada (con otro formato: 1234567 = 1.234.567) RECHAZADA: %', SQLERRM; END;
  BEGIN PERFORM public.registrar_usuario('Ana', 'Gil', '8000009', 'otro@m.co', '+57 300 123 4567', '1990-01-01', h, true, NULL, true); RAISE NOTICE '3h) !!! FALLO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '3h) telefono duplicado (+57 300 123 4567 = (300) 123-4567) RECHAZADO: %', SQLERRM; END;

  -- 4) Login y sesion (lo que hara el backend): credenciales -> bcrypt en el backend -> validar_sesion en cada peticion
  SELECT * INTO v_rec FROM public.obtener_credenciales('  ' || upper(r1 ->> 'username') || '  ');
  RAISE NOTICE '4) obtener_credenciales: usuario_id=% rol=% estado=% (el hash de % caracteres solo sale por esta funcion)', v_rec.usuario_id, v_rec.rol, v_rec.estado, length(v_rec.password_hash);
  RAISE NOTICE '   usuario inexistente = % filas (el backend responde Credenciales invalidas)', (SELECT count(*) FROM public.obtener_credenciales('nadie999'));
  RAISE NOTICE '   validar_sesion: %', public.validar_sesion(u1);
  UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = u1;
  BEGIN PERFORM public.validar_sesion(u1); RAISE NOTICE '4b) !!! FALLO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '4b) con la sesion abierta y el usuario BLOQUEADO, la siguiente peticion recibe: %', SQLERRM; END;
  UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = u1;
  RAISE NOTICE '   perfil: %', public.vista_perfil(u1);

  -- 5) Referidos y bono (una sola funcion, idempotente)
  cod := (SELECT codigo_referido::text FROM public.usuario WHERE id = u1);
  s0 := (SELECT balance FROM public.cuenta WHERE usuario_id = u1);
  r3 := public.registrar_usuario('Beto', 'Blanco', '8000003', 'beto@m.co', '3000000003', '1991-03-03', h, true, cod, false);         -- verificacion APAGADA: el bono se paga al registrar
  RAISE NOTICE '5a) verificacion apagada: el referidor paso de % a % (+50000)', s0, (SELECT balance FROM public.cuenta WHERE usuario_id = u1);
  s0 := (SELECT balance FROM public.cuenta WHERE usuario_id = u1);
  r4 := public.registrar_usuario('Carla', 'Ruiz', '8000004', 'carla@m.co', '3000000004', '1992-04-04', h, true, upper(cod), true);   -- verificacion ENCENDIDA
  u4 := (r4 ->> 'usuario_id')::uuid;
  RAISE NOTICE '5b) verificacion encendida: el referidor sigue en % (el bono queda pendiente)', (SELECT balance FROM public.cuenta WHERE usuario_id = u1);
  PERFORM public.verificar_correo(u4); PERFORM public.verificar_correo(u4); PERFORM public.verificar_correo(u4);
  RAISE NOTICE '5c) tras verificar el correo TRES veces: el referidor tiene % (+50000 una sola vez); grupos de bono de Carla = %', (SELECT balance FROM public.cuenta WHERE usuario_id = u1),
               (SELECT count(*) FROM public.transaccion WHERE tipo = 'BONO_REFERIDO' AND contraparte_cuenta = (SELECT numero_cuenta FROM public.cuenta WHERE usuario_id = u4));
  RAISE NOTICE '    nota del bono: %', (SELECT nota FROM public.transaccion WHERE tipo = 'BONO_REFERIDO' AND contenedor = 'CUENTA' ORDER BY orden LIMIT 1);

  -- 6) Integridad y permisos
  RAISE NOTICE '6) integridad global ok=%  integridad de autenticacion: %', (SELECT ok FROM public.v_integridad_global), (SELECT string_agg(left(control, 40) || '=' || ok, ' | ') FROM public.v_integridad_auth);
  BEGIN SET LOCAL ROLE banco_app; PERFORM count(*) FROM public.usuario; RESET ROLE; RAISE NOTICE '6a) !!! FALLO: banco_app leyo la tabla usuario';
  EXCEPTION WHEN OTHERS THEN RESET ROLE; RAISE NOTICE '6a) banco_app NO lee la tabla usuario: %', SQLERRM; END;
  BEGIN SET LOCAL ROLE banco_app; PERFORM public._pagar_bono_referido(u4, now()); RESET ROLE; RAISE NOTICE '6b) !!! FALLO';
  EXCEPTION WHEN OTHERS THEN RESET ROLE; RAISE NOTICE '6b) banco_app NO ejecuta las funciones internas: %', SQLERRM; END;
  BEGIN SET LOCAL ROLE banco_lector; PERFORM public.validar_sesion(u1); RESET ROLE; RAISE NOTICE '6c) !!! FALLO';
  EXCEPTION WHEN OTHERS THEN RESET ROLE; RAISE NOTICE '6c) banco_lector NO ejecuta las funciones de autenticacion: %', SQLERRM; END;
  BEGIN SET LOCAL ROLE banco_app; PERFORM public.validar_sesion(u1); RESET ROLE; RAISE NOTICE '6d) banco_app SI ejecuta validar_sesion (y registrar_usuario, obtener_credenciales, verificar_correo, vista_perfil)';
  EXCEPTION WHEN OTHERS THEN RESET ROLE; RAISE NOTICE '6d) !!! FALLO: %', SQLERRM; END;
  SELECT count(*) INTO n FROM public.v_integridad_defensas WHERE NOT ok;
  RAISE NOTICE '   defensas de integridad en error: % (la lista blanca de banco_app esta en orden)', n;
END
$demo$;
ROLLBACK;
-- Tras el ROLLBACK no queda ninguno de los usuarios de la demo
SELECT (SELECT count(*) FROM public.usuario WHERE cedula IN ('1234567', '7654321', '8000003', '8000004')) AS usuarios_de_la_demo,
       (SELECT count(*) FROM public.v_integridad_auth WHERE NOT ok) AS controles_auth_fallidos;
