-- Demostracion de E7 (motor de devengo y CDT) para pgAdmin: conexion "administracion (postgres)", base banco. NO deja datos NI cambia el reloj: todo va dentro de
-- BEGIN ... ROLLBACK (el salto de fecha tambien se deshace) y cada intento rechazado se captura con un sub-bloque, asi que el script NO se aborta y los resultados aparecen
-- como NOTICE en la pestaña "Messages". Ejecutar COMPLETO con F5.
-- (Se usa registrar_usuario de E4 para crear al cliente y, solo para esta demo como superusuario, un deposito fijo de $2.000.000 por el libro para que las cifras sean redondas;
--  el catalogo real de CDT es la decision D11 del equipo: aqui se inserta UNA definicion de demostracion dentro de la transaccion.)
BEGIN;
DO $demo$
DECLARE
  h constant text := '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';       -- hash con FORMA de bcrypt (la BD nunca ve la clave en claro)
  ua uuid; ca uuid; ub uuid; cb uuid; nb text; b1 text; def text; r jsonb; v jsonb; v_rec record; v_hoy date; v_n int; v_msg text; v_cdt uuid; s0 numeric; g numeric;
BEGIN
  ua := (public.registrar_usuario('Ana', 'Devengo', '9300001', 'ana.e7@mail.co', '3109300001', '1990-05-17', h, true, NULL, true) ->> 'usuario_id')::uuid;
  ub := (public.registrar_usuario('Beto', 'Destino', '9300002', 'beto.e7@mail.co', '3109300002', '1991-06-18', h, true, NULL, true) ->> 'usuario_id')::uuid;
  SELECT id INTO ca FROM public.cuenta WHERE usuario_id = ua;
  SELECT id, numero_cuenta INTO cb, nb FROM public.cuenta WHERE usuario_id = ub;
  PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', 2000000, 'cuenta_id', ca),
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', 2000000, 'cuenta_id', ca, 'contraparte_nombre', 'Banco Digital')));
  s0 := (SELECT balance FROM public.cuenta WHERE id = ca);
  v_hoy := public.hoy_banco();
  RAISE NOTICE 'Hoy del banco: %. Ana tiene en su cuenta principal % (ingresos simulados + deposito de la demo)', v_hoy, s0;

  -- 1) un bolsillo con $1.000.000 y un CDT de $500.000 a 90 dias (definicion de DEMOSTRACION: el catalogo real es D11, del equipo)
  b1 := (public.crear_bolsillo(ua, 'Ahorro') ->> 'id');
  PERFORM public.mover_a_bolsillo(ua, b1, 1000000);
  INSERT INTO public.cdt_definicion (nombre, plazo_dias, tasa_anual, monto_min) VALUES ('Demo CDT 90 dias', 90, 10, 100000) RETURNING id::text INTO def;
  RAISE NOTICE '1) listar_cdt_definiciones: %', public.listar_cdt_definiciones(ua);
  RAISE NOTICE '   simular_cdt($500.000, 90 dias, 10 %% E.A.): %  (PROVISIONAL D1: tasa efectiva anual estricta)', public.simular_cdt(ua, def, 500000);
  r := public.crear_cdt(ua, def, 500000);
  v_cdt := (r ->> 'id')::uuid;
  RAISE NOTICE '   crear_cdt devuelve: %', r;
  RAISE NOTICE '   vista_balance: % (el total NO baja al crear el CDT: incluye los CDT activos, D-E7-5 provisional)', public.vista_balance(ua);

  -- 2) el reloj avanza 30 dias (simulacion del admin): la PRIMERA consulta devenga (devengo perezoso) y la segunda no repite nada
  PERFORM public._reloj_actualizar(false, (v_hoy + 30)::text);
  RAISE NOTICE '2) reloj +30 dias: hoy = %', public.hoy_banco();
  v := public.vista_balance(ua);
  RAISE NOTICE '   vista_balance (devenga antes de leer): %', v;
  FOR v_rec IN SELECT t.tipo, t.contenedor, t.sentido, t.monto, t.nota, t.contraparte_nombre FROM public.transaccion t
                WHERE t.cuenta_id = ca AND t.tipo IN ('INTERES_BOLSO', 'INTERES_CDT') ORDER BY t.orden LOOP
    RAISE NOTICE '     pata: % % % $% nota "%" contraparte=%', v_rec.tipo, v_rec.contenedor, v_rec.sentido, v_rec.monto, v_rec.nota, v_rec.contraparte_nombre;
  END LOOP;
  RAISE NOTICE '   comprobacion: 1.000.000 * (1,12^(30/365) - 1) = %  (formula independiente exp/ln)', round(1000000 * (exp(ln(1.12) * 30 / 365.0) - 1), 2);
  v_n := (SELECT count(*) FROM public.transaccion WHERE cuenta_id = ca);
  PERFORM public.vista_balance(ua); PERFORM public.vista_cdts(ua);
  RAISE NOTICE '   consultar de nuevo NO escribe nada mas (idempotente): patas antes=%, despues=%', v_n, (SELECT count(*) FROM public.transaccion WHERE cuenta_id = ca);
  RAISE NOTICE '   vista_cdts a los 30 dias: %', public.vista_cdts(ua);

  -- 3) devengar ANTES de operar: se puede retirar el saldo del bolsillo CON sus intereses
  g := (SELECT balance FROM public.bolsillo WHERE id = b1::uuid);
  RAISE NOTICE '3) saldo del bolsillo con intereses: %  -> retirar_de_bolsillo por ese monto exacto: %', g, public.retirar_de_bolsillo(ua, b1, g);

  -- 4) el CDT vence (+95 dias en total): el motor lo cierra y acredita monto + generado en la fecha de vencimiento
  PERFORM public._reloj_actualizar(false, (v_hoy + 95)::text);
  s0 := (SELECT balance FROM public.cuenta WHERE id = ca);
  RAISE NOTICE '4) reloj +95 dias: hoy = %. Cuenta antes de consultar: %', public.hoy_banco(), s0;
  v := public.vista_cdts(ua);
  RAISE NOTICE '   vista_cdts (cierra y acredita): %', v;
  FOR v_rec IN SELECT t.tipo, t.contenedor, t.sentido, t.monto, t.fecha FROM public.transaccion t WHERE t.cdt_id = v_cdt AND t.tipo IN ('INTERES_CDT', 'CDT_VENCIMIENTO') ORDER BY t.orden LOOP
    RAISE NOTICE '     pata: % % % $% fecha %', v_rec.tipo, v_rec.contenedor, v_rec.sentido, v_rec.monto, v_rec.fecha;
  END LOOP;
  RAISE NOTICE '   la cuenta paso de % a % (+ monto 500000 + generado); el CDT esta %', s0, (SELECT balance FROM public.cuenta WHERE id = ca), (SELECT estado FROM public.cdt WHERE id = v_cdt);
  RAISE NOTICE '   generado final = % = simular_cdt (generado_vencimiento): % ', (SELECT generado_acumulado FROM public.cdt WHERE id = v_cdt), public.simular_cdt(ua, def, 500000) ->> 'generado_vencimiento';
  PERFORM public._reloj_actualizar(false, (v_hoy + 500)::text); PERFORM public.vista_cdts(ua);
  RAISE NOTICE '   a +500 dias (hoy = %) NO se devenga nada mas (el interes se topa en fecha_fin): CDT sigue con generado %', public.hoy_banco(), (SELECT generado_acumulado FROM public.cdt WHERE id = v_cdt);

  -- 5) hacer_transferencia tambien devenga al emisor antes de mover dinero (UNA instantanea, ambas cuentas bloqueadas en orden de id)
  r := public.hacer_transferencia(ua, nb, 100, 'demo', NULL);
  RAISE NOTICE '5) hacer_transferencia: %', r;

  -- 6) volver al reloj real: hoy < ultimo_cobro => el motor no escribe ni recobra nada; la guardia impide retroceder ultimo_cobro
  PERFORM public._reloj_actualizar(true, '');
  v_n := (SELECT count(*) FROM public.transaccion WHERE cuenta_id = ca);
  PERFORM public.vista_balance(ua); PERFORM public.vista_cdts(ua);
  RAISE NOTICE '6) de vuelta al reloj real (hoy = %): vista_balance y vista_cdts no escriben nada (patas antes=%, despues=%)', public.hoy_banco(), v_n, (SELECT count(*) FROM public.transaccion WHERE cuenta_id = ca);
  BEGIN
    UPDATE public.bolsillo SET ultimo_cobro = ultimo_cobro - 1 WHERE id = b1::uuid;
    RAISE NOTICE '   *** la guardia NO rechazo el retroceso ***';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '   guardia monotonica: UPDATE ultimo_cobro hacia atras rechazado: %', v_msg;
  END;

  -- 7) los rechazos con su mensaje exacto (y sin rastro)
  FOR v_rec IN SELECT * FROM (VALUES ('monto bajo el minimo', 'crear', 99999.99), ('saldo insuficiente', 'crear', 999999999), ('monto invalido', 'crear', 0)) q(que, op, m) LOOP
    BEGIN PERFORM public.crear_cdt(ua, def, v_rec.m); RAISE NOTICE '7) %: *** NO fallo ***', v_rec.que;
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '7) %: %', v_rec.que, v_msg; END;
  END LOOP;
  BEGIN PERFORM public.crear_cdt(ua, 'no-es-uuid', 100000); RAISE NOTICE '7) definicion mal formada: *** NO fallo ***';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '7) definicion mal formada (negocio, no error de driver): %', v_msg; END;

  -- 8) integridad global tras todo (partida doble, inversion del CDT, generado = suma de patas, conservacion)
  RAISE NOTICE '8) v_integridad_global.ok = % (defensas fallidas=%, grupos con error=%, contenedores con desvio=%)', (SELECT ok FROM public.v_integridad_global),
               (SELECT defensas_fallidas FROM public.v_integridad_global), (SELECT grupos_con_error FROM public.v_integridad_global), (SELECT contenedores_con_desvio FROM public.v_integridad_global);
END
$demo$;
ROLLBACK;
SELECT 'Demo terminada: ROLLBACK ejecutado (el reloj y los datos quedaron como estaban)' AS resultado;
