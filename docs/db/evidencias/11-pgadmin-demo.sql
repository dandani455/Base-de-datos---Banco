-- Demostracion de E11 (administracion) para pgAdmin: conexion "administracion (postgres)", base banco. NO deja datos NI cambia el reloj NI las tasas NI la tasa de mora: todo va dentro de
-- BEGIN ... ROLLBACK (los saltos de fecha tambien se deshacen) y cada intento rechazado se captura con un sub-bloque, asi que el script NO se aborta y los resultados aparecen como NOTICE
-- en la pestaña "Messages". Ejecutar COMPLETO con F5.
-- (Se usa registrar_usuario de E4 para crear a los clientes. La creacion del PRIMER administrador es del seed (E14, D5): solo para esta demo, como superusuario, se insertan dos directamente.
--  Un deposito fijo por el libro deja cifras redondas; el catalogo real de productos y la mora son decisiones del EQUIPO (D11, D7): aqui se insertan datos de DEMOSTRACION.)
BEGIN;
DO $demo$
DECLARE
  h constant text := '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';       -- hash con FORMA de bcrypt (la BD nunca ve la clave en claro)
  ua uuid; ca uuid; ub uuid; cb uuid; uc uuid; adm uuid; adb uuid; v_def text; v_prod text; d jsonb; r jsonb; v_hoy date; v_n bigint; v_un_b text; v_nc_b text; v_rec record; v_h0 text;
BEGIN
  ua := (public.registrar_usuario('Ana',  'Admin', '9800001', 'ana.e11@mail.co',  '3109800001', '1990-05-17', h, true, NULL, true) ->> 'usuario_id')::uuid;
  ub := (public.registrar_usuario('Beto', 'Admin', '9800002', 'beto.e11@mail.co', '3109800002', '1991-02-10', h, true, NULL, true) ->> 'usuario_id')::uuid;
  uc := (public.registrar_usuario('Zoé',  'Muñoz', '9800003', 'zoe.e11@mail.co',  '3109800003', '1992-07-21', h, true, NULL, true) ->> 'usuario_id')::uuid;
  SELECT id INTO ca FROM public.cuenta WHERE usuario_id = ua; SELECT id INTO cb FROM public.cuenta WHERE usuario_id = ub;
  SELECT username INTO v_un_b FROM public.usuario WHERE id = ub; SELECT numero_cuenta INTO v_nc_b FROM public.cuenta WHERE id = cb;
  INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol)
  VALUES ('admdemo11', h, 'Admin', 'Demo', '9800900', 'admdemo.e11@mail.co', '3109800900', DATE '1980-01-01', 'ADMIN'),
         ('admblq11',  h, 'Admin', 'Bloqueado', '9800901', 'admblq.e11@mail.co', '3109800901', DATE '1980-01-01', 'ADMIN');
  SELECT id INTO adm FROM public.usuario WHERE username = 'admdemo11'; SELECT id INTO adb FROM public.usuario WHERE username = 'admblq11';
  UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = adb;
  PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', 5000000, 'cuenta_id', ca),
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', 5000000, 'cuenta_id', ca, 'contraparte_nombre', 'Banco Digital')));
  INSERT INTO public.credito_producto (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES ('Demo Libre', '', 18, 1000000, 50000000, 6, 24);
  INSERT INTO public.cdt_definicion (nombre, plazo_dias, tasa_anual, monto_min) VALUES ('Demo CDT 30', 30, 9, 100000);
  SELECT id::text INTO v_prod FROM public.credito_producto WHERE nombre = 'Demo Libre'; SELECT id::text INTO v_def FROM public.cdt_definicion WHERE nombre = 'Demo CDT 30';
  v_hoy := public.hoy_banco();
  RAISE NOTICE 'Hoy del banco: %. Clientes: Ana (5 ingresos simulados + 5.000.000 de la demo), Beto (%) y Zoé; administradores: admdemo11 y admblq11 (bloqueado).', v_hoy, v_un_b;

  -- 1) la lista: solo CLIENTES, con la forma del contrato
  d := public.admin_listar_usuarios(adm, NULL);
  RAISE NOTICE '1) admin_listar_usuarios: % filas (los 2 ADMIN no aparecen). Claves de cada fila: %', jsonb_array_length(d), (SELECT string_agg(k, ', ' ORDER BY k) FROM jsonb_object_keys(d -> 0) k);
  RAISE NOTICE '   busqueda "zoe" (sin tildes ni mayusculas) -> %; "MUNOZ" -> %; por numero de cuenta de Beto -> %; "%%" (el comodin es literal) -> % filas',
               (SELECT e ->> 'nombre' FROM jsonb_array_elements(public.admin_listar_usuarios(adm, 'zoe')) e),
               (SELECT e ->> 'nombre' FROM jsonb_array_elements(public.admin_listar_usuarios(adm, 'MUNOZ')) e),
               (SELECT e ->> 'username' FROM jsonb_array_elements(public.admin_listar_usuarios(adm, v_nc_b)) e),
               jsonb_array_length(public.admin_listar_usuarios(adm, '%'));

  -- 2) el detalle de Ana (corre el motor sobre ella antes de leer)
  PERFORM public.hacer_transferencia(ua, v_nc_b, 120000, 'arriendo', NULL);
  PERFORM public.crear_bolsillo(ua, 'Viajes');
  PERFORM public.crear_cdt(ua, v_def, 1000000);
  PERFORM public.solicitar_credito(ua, v_prod, 2000000, 12);
  d := public.admin_detalle_usuario(adm, ua::text);
  RAISE NOTICE '2) admin_detalle_usuario(Ana): principal=%, total=%, bolsillos=%, cdts=%, creditos=%', d #>> '{balance,principal}', d #>> '{balance,total}', jsonb_array_length(d #> '{balance,bolsillos}'), d #> '{balance,cdts}', d #> '{balance,creditos}';
  RAISE NOTICE '   historial (ultimas 50, la mas reciente primero): % filas; la primera: %', jsonb_array_length(d -> 'historial'), d #> '{historial,0}';
  RAISE NOTICE '   el historial del detalle es EXACTAMENTE el de vista_historial(Ana): %', d -> 'historial' = public.vista_historial(ua, 50);

  -- 3) ajuste de balance con signo: por uuid, username o numero de cuenta; todo por el libro
  r := public.admin_ajustar_balance(adm, ub::text, 250000.50, 'bono manual');
  RAISE NOTICE '3) +250000.50 a Beto por UUID -> %; saldo = %', r, (SELECT balance FROM public.cuenta WHERE id = cb);
  r := public.admin_ajustar_balance(adm, v_un_b, -1000, NULL);
  RAISE NOTICE '   -1000 por USERNAME -> %; saldo = %', r, (SELECT balance FROM public.cuenta WHERE id = cb);
  r := public.admin_ajustar_balance(adm, v_nc_b, 10, 'por numero de cuenta');
  RAISE NOTICE '   +10 por NUMERO DE CUENTA -> %; saldo = %', r, (SELECT balance FROM public.cuenta WHERE id = cb);
  BEGIN PERFORM public.admin_ajustar_balance(adm, ub::text, -99999999, NULL); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   un ajuste negativo que dejaria la cuenta bajo cero -> "%" (no cambia nada)', SQLERRM; END;
  BEGIN PERFORM public.admin_ajustar_balance(adm, ub::text, 0, NULL); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   monto 0 -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_ajustar_balance(adm, ub::text, 1.005, NULL); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   monto con 3 decimales -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_ajustar_balance(adm, 'admdemo11', 10, NULL); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   ajustar a un ADMIN -> "%"', SQLERRM; END;
  RAISE NOTICE '   el historial de Beto muestra los ajustes: %', (SELECT string_agg((e ->> 'tipo') || ' ' || (e ->> 'monto') || ' ' || coalesce(e ->> 'nota', '-'), ' ; ' ORDER BY o) FROM jsonb_array_elements(public.vista_historial(ub, 4)) WITH ORDINALITY x(e, o) WHERE e ->> 'tipo_detalle' = 'AJUSTE_ADMIN');
  RAISE NOTICE '   eventos AJUSTE_ADMIN de la auditoria: % (actor: %)', (SELECT count(*) FROM audit.evento WHERE accion = 'AJUSTE_ADMIN'), (SELECT string_agg(DISTINCT actor_username, ', ') FROM audit.evento WHERE accion = 'AJUSTE_ADMIN');

  -- 4) bloquear / desbloquear: rige en la SIGUIENTE peticion del usuario
  r := public.admin_bloquear(adm, uc::text);
  RAISE NOTICE '4) admin_bloquear(Zoe) -> %', r;
  BEGIN PERFORM public.vista_balance(uc); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   la SIGUIENTE peticion de Zoe -> "%"', SQLERRM; END;
  PERFORM public.admin_bloquear(adm, uc::text);
  RAISE NOTICE '   bloquear dos veces es idempotente: eventos USUARIO_BLOQUEADO = %', (SELECT count(*) FROM audit.evento WHERE accion = 'USUARIO_BLOQUEADO');
  RAISE NOTICE '   admin_desbloquear(Zoe) -> %; vista_balance de Zoe responde de nuevo: %', public.admin_desbloquear(adm, uc::text), (public.vista_balance(uc) ->> 'principal') IS NOT NULL;
  BEGIN PERFORM public.admin_bloquear(adm, adm::text); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   un admin no puede bloquearse a si mismo ni a otro admin -> "%"', SQLERRM; END;

  -- 5) el reloj (envuelve las funciones de E3)
  RAISE NOTICE '5) admin_get_reloj -> %', public.admin_get_reloj(adm);
  RAISE NOTICE '   admin_set_reloj(+5 dias) -> %', public.admin_set_reloj(adm, false, (v_hoy + 5)::text);
  BEGIN PERFORM public.admin_set_reloj(adm, false, v_hoy::text); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   retroceder a hoy -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_set_reloj(adm, false, 'ayer'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   fecha invalida -> "%"', SQLERRM; END;
  RAISE NOTICE '   volver a la fecha real (el front manda una fecha que se IGNORA) -> %', public.admin_set_reloj(adm, true, '2030-01-01');
  RAISE NOTICE '   auditoria del reloj atribuida al admin: %', (SELECT string_agg(accion || ' por ' || coalesce(actor_username, '?'), ' ; ' ORDER BY orden) FROM audit.evento WHERE accion = 'RELOJ_CAMBIO');

  -- 6) las tasas (3 funciones; PUT /admin/tasas las ejecuta en UNA transaccion)
  RAISE NOTICE '6) admin_get_tasas (la mora sin valor se LEE como 0, D-E11-D7a provisional) -> %', public.admin_get_tasas(adm);
  RAISE NOTICE '   set_tasa_cdt 12.5 -> %; set_tasa_credito 19 -> %; set_tasa_mora 30 -> %',
               public.admin_set_tasa_cdt(adm, v_def, '12.5'), public.admin_set_tasa_credito(adm, v_prod, '19'), public.admin_set_tasa_mora(adm, '30');
  BEGIN PERFORM public.admin_set_tasa_cdt(adm, v_def, '100.5'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   tasa 100.5 -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_set_tasa_cdt(adm, v_def, 'doce'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   tasa "doce" -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_set_tasa_cdt(adm, '00000000-0000-4000-8000-000000000001', '10'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   definicion inexistente -> "%"', SQLERRM; END;
  -- la secuencia del backend: BEGIN; cdt OK; credito INVALIDO; ROLLBACK => nada cambia (un sub-bloque revierte lo que hizo antes de fallar)
  v_h0 := (public.admin_get_tasas(adm))::text;
  BEGIN
    PERFORM public.admin_set_tasa_cdt(adm, v_def, '40');
    PERFORM public.admin_set_tasa_credito(adm, v_prod, 'abc');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '   formulario con una tasa invalida en la 2a llamada -> "%"; tasas intactas tras el ROLLBACK: %', SQLERRM, (public.admin_get_tasas(adm))::text = v_h0;
  END;
  RAISE NOTICE '   mora "0" = sin mora: set_tasa_mora(0) -> %; en la BD queda NULL: %; get_tasas la lee como %', public.admin_set_tasa_mora(adm, '0'), (SELECT tasa_mora_anual IS NULL FROM public.parametro), public.admin_get_tasas(adm) -> 'mora';
  RAISE NOTICE '   eventos TASA_CAMBIO: % (solo los cambios reales)', (SELECT count(*) FROM audit.evento WHERE accion = 'TASA_CAMBIO');
  RAISE NOTICE '   D-E11-D7b (NO decidido por el equipo): cambiar la tasa de mora cambia la mora de las cuotas YA vencidas, porque E9 la deriva; E11 no agrega logica sobre eso.';

  -- 7) borrar a un usuario: cascada, auditoria, y la contraparte del tercero queda como texto
  v_n := (SELECT count(*) FROM public.transaccion WHERE cuenta_id = cb);
  RAISE NOTICE '7) antes de borrar a Beto: % patas suyas en el libro, saldo %; Ana ve en su historial a "%"', v_n, (SELECT balance FROM public.cuenta WHERE id = cb),
               (SELECT e ->> 'contraparte' FROM jsonb_array_elements(public.vista_historial(ua, 50)) e WHERE e ->> 'tipo_detalle' = 'ENVIO');
  RAISE NOTICE '   admin_borrar_usuario(Beto) -> %', public.admin_borrar_usuario(adm, ub::text);
  RAISE NOTICE '   quedan: usuario=%, cuenta=%, patas=%; Ana sigue viendo a "%"', (SELECT count(*) FROM public.usuario WHERE id = ub), (SELECT count(*) FROM public.cuenta WHERE id = cb), (SELECT count(*) FROM public.transaccion WHERE cuenta_id = cb),
               (SELECT e ->> 'contraparte' FROM jsonb_array_elements(public.vista_historial(ua, 50)) e WHERE e ->> 'tipo_detalle' = 'ENVIO');
  RAISE NOTICE '   auditoria: %', (SELECT string_agg(accion || ' (' || coalesce(actor_username, '?') || ')', ' ; ' ORDER BY orden) FROM audit.evento WHERE accion IN ('USUARIO_BORRADO', 'CUENTA_BORRADA'));
  RAISE NOTICE '   CUENTA_BORRADA conserva lo que se destruyo: %', (SELECT antes FROM audit.evento WHERE accion = 'CUENTA_BORRADA' ORDER BY orden DESC LIMIT 1);
  BEGIN PERFORM public.admin_borrar_usuario(adm, ub::text); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   borrarlo otra vez -> "%"; la sesion de Beto -> "%"', SQLERRM, (SELECT public._msg_auth('sesion')); END;
  BEGIN PERFORM public.validar_sesion(ub); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   validar_sesion(Beto borrado) -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_borrar_usuario(adm, adm::text); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   un admin no puede borrarse a si mismo -> "%"', SQLERRM; END;

  -- 8) control de acceso: SOLO un administrador activo puede usar las 12 funciones
  RAISE NOTICE '8) un CLIENTE (Ana) llamando a admin_get_reloj, admin_listar_usuarios y admin_set_tasa_mora:';
  BEGIN PERFORM public.admin_get_reloj(ua); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '     -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_listar_usuarios(ua, NULL); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '     -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_set_tasa_mora(ua, '99'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '     -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_get_tasas(adb); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   un ADMIN BLOQUEADO -> "%"', SQLERRM; END;
  BEGIN PERFORM public.admin_get_reloj(gen_random_uuid()); EXCEPTION WHEN OTHERS THEN RAISE NOTICE '   un usuario inexistente -> "%"', SQLERRM; END;

  -- 9) permisos e integridad
  RAISE NOTICE '9) banco_app ejecuta las 12 admin_* y ninguno de los 4 helpers: % | % ; funciones publicas de banco_app en total: %',
               (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'admin\_%' AND has_function_privilege('banco_app', p.oid, 'EXECUTE')),
               (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('_reglas_admin', '_parse_tasa', '_cliente_objetivo', '_auditar_admin') AND has_function_privilege('banco_app', p.oid, 'EXECUTE')),
               (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e') AND has_function_privilege('banco_app', p.oid, 'EXECUTE'));
  RAISE NOTICE '   banco_lector NO ejecuta admin_get_reloj: %', NOT has_function_privilege('banco_lector', 'public.admin_get_reloj(uuid)', 'EXECUTE');
  RAISE NOTICE '   v_integridad_global.ok = % (partida doble, I5u, conservacion con los borrados incluidos, defensas)', (SELECT ok FROM public.v_integridad_global);
END
$demo$;
ROLLBACK;
