-- Demostracion de E5 (transferencias) para pgAdmin: conexion "administracion (postgres)", base banco. NO deja datos: todo va dentro de BEGIN ... ROLLBACK y cada
-- intento rechazado se captura con un sub-bloque, asi que el script NO se aborta y los resultados aparecen como NOTICE en la pestaña "Messages". Ejecutar COMPLETO con F5.
-- (Se usan registrar_usuario de E4 para crear clientes y, solo para esta demo como superusuario, un bolsillo con saldo: las funciones de bolsillos llegan en E6.)
BEGIN;
DO $demo$
DECLARE
  h constant text := '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';       -- hash con FORMA de bcrypt (la BD nunca ve la clave en claro)
  ua uuid; ub uuid; ca uuid; cb uuid; na text; nb text; bol uuid; r jsonb; v_msg text; tot0 numeric; s numeric; v_rec record;
BEGIN
  ua := (public.registrar_usuario('Ana', 'Emisora', '9100001', 'ana.e5@mail.co', '3109100001', '1990-05-17', h, true, NULL, true) ->> 'usuario_id')::uuid;
  ub := (public.registrar_usuario('Beto', 'Receptor', '9100002', 'beto.e5@mail.co', '3109100002', '1991-06-18', h, true, NULL, true) ->> 'usuario_id')::uuid;
  SELECT id, numero_cuenta INTO ca, na FROM public.cuenta WHERE usuario_id = ua;
  SELECT id, numero_cuenta INTO cb, nb FROM public.cuenta WHERE usuario_id = ub;
  INSERT INTO public.bolsillo (cuenta_id, nombre, ultimo_cobro) VALUES (ca, 'Ahorro demo', public.hoy_banco()) RETURNING id INTO bol;
  PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
    jsonb_build_object('tipo', 'BOLSO_INGRESO', 'contenedor', 'CUENTA', 'sentido', 'S', 'monto', 20000, 'cuenta_id', ca, 'bolsillo_id', bol),
    jsonb_build_object('tipo', 'BOLSO_INGRESO', 'contenedor', 'BOLSILLO', 'sentido', 'E', 'monto', 20000, 'cuenta_id', ca, 'bolsillo_id', bol)));
  SELECT (SELECT sum(balance) FROM public.cuenta) + (SELECT sum(balance) FROM public.bolsillo) INTO tot0;
  RAISE NOTICE 'Emisora % (cuenta %) saldo % y bolsillo %;  Receptor % (cuenta %) saldo %', 'Ana', na, (SELECT balance FROM public.cuenta WHERE id = ca), (SELECT balance FROM public.bolsillo WHERE id = bol), 'Beto', nb, (SELECT balance FROM public.cuenta WHERE id = cb);

  -- 1) ¿Envias a <nombre>?  (exige sesion viva)
  RAISE NOTICE '1) nombre_destinatario(%): %', nb, public.nombre_destinatario(ua, ' ' || substr(nb, 1, 4) || '.' || substr(nb, 5) || ' ');
  BEGIN PERFORM public.nombre_destinatario(gen_random_uuid(), nb); RAISE NOTICE '1b) !!! FALLO: sin sesion se pudo consultar';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '1b) sin sesion viva RECHAZADO: %', SQLERRM; END;

  -- 2) Transferencia cuenta -> cuenta: el libro registra 2 patas con contrapartes cruzadas, misma fecha y grupo
  r := public.hacer_transferencia(ua, nb, 150000.50, '  Pago   del   arriendo ', NULL);
  RAISE NOTICE '2) hacer_transferencia devuelve: %', r;
  FOR v_rec IN SELECT t.tipo, t.contenedor, t.sentido, t.monto, t.nota, t.contraparte_nombre, t.contraparte_cuenta FROM public.transaccion t WHERE t.grupo_id = (r ->> 'id')::uuid ORDER BY t.orden LOOP
    RAISE NOTICE '     pata: % % % $% nota=[%] contraparte=% (%)', v_rec.tipo, v_rec.contenedor, v_rec.sentido, v_rec.monto, v_rec.nota, v_rec.contraparte_nombre, v_rec.contraparte_cuenta;
  END LOOP;
  RAISE NOTICE '     saldos: emisora % | receptor %', (SELECT balance FROM public.cuenta WHERE id = ca), (SELECT balance FROM public.cuenta WHERE id = cb);

  -- 3) Desde un bolsillo (la cuenta principal no se toca)
  s := (SELECT balance FROM public.cuenta WHERE id = ca);
  r := public.hacer_transferencia(ua, nb, 5000, 'del ahorro', bol::text);
  RAISE NOTICE '3) desde el bolsillo: bolsillo % (antes 20000), cuenta principal sin cambio=%, pata de salida del contenedor %', (SELECT balance FROM public.bolsillo WHERE id = bol),
               (SELECT balance FROM public.cuenta WHERE id = ca) = s, (SELECT contenedor FROM public.transaccion WHERE grupo_id = (r ->> 'id')::uuid AND tipo = 'ENVIO');

  -- 4) Cada rechazo con su mensaje exacto (y sin dejar rastro)
  BEGIN PERFORM public.hacer_transferencia(ua, nb, 0, NULL, NULL);               RAISE NOTICE '4a) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '4a) monto 0: %', SQLERRM; END;
  BEGIN PERFORM public.hacer_transferencia(ua, nb, 1.234, NULL, NULL);           RAISE NOTICE '4b) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '4b) 3 decimales: %', SQLERRM; END;
  BEGIN PERFORM public.hacer_transferencia(ua, '4999999999', 10, NULL, NULL);    RAISE NOTICE '4c) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '4c) destino inexistente: %', SQLERRM; END;
  BEGIN PERFORM public.hacer_transferencia(ua, na, 10, NULL, NULL);              RAISE NOTICE '4d) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '4d) autoenvio: %', SQLERRM; END;
  BEGIN PERFORM public.hacer_transferencia(ua, nb, 10, NULL, gen_random_uuid()::text); RAISE NOTICE '4e) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '4e) bolsillo inexistente/ajeno: %', SQLERRM; END;
  BEGIN PERFORM public.hacer_transferencia(ua, nb, 10, NULL, 'no-es-un-uuid');   RAISE NOTICE '4f) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '4f) bolsillo mal formado (negocio, no error de driver): %', SQLERRM; END;
  BEGIN PERFORM public.hacer_transferencia(ua, nb, 10, repeat('x', 141), NULL);  RAISE NOTICE '4g) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '4g) nota de 141 caracteres (PROVISIONAL D-E5-8): %', SQLERRM; END;
  BEGIN PERFORM public.hacer_transferencia(ua, nb, 99999999, NULL, NULL);        RAISE NOTICE '4h) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '4h) saldo insuficiente: %', SQLERRM; END;
  BEGIN PERFORM public.hacer_transferencia(ua, nb, 15000.01, NULL, bol::text);   RAISE NOTICE '4i) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '4i) mas que el saldo del bolsillo: %', SQLERRM; END;

  -- 5) Conservacion: las transferencias no crean ni destruyen dinero
  RAISE NOTICE '5) suma de cuentas + bolsillos: antes % = despues % ; integridad global ok = %', tot0,
               (SELECT sum(balance) FROM public.cuenta) + (SELECT sum(balance) FROM public.bolsillo), (SELECT ok FROM public.v_integridad_global);
END
$demo$;
ROLLBACK;
