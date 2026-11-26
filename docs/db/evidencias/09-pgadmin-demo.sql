-- Demostracion de E9 (pagos, abonos, mora y descuento automatico) para pgAdmin: conexion "administracion (postgres)", base banco. NO deja datos NI cambia el reloj NI la tasa de mora:
-- todo va dentro de BEGIN ... ROLLBACK (los saltos de fecha tambien se deshacen) y cada intento rechazado se captura con un sub-bloque, asi que el script NO se aborta y los resultados
-- aparecen como NOTICE en la pestaña "Messages". Ejecutar COMPLETO con F5.
-- (Se usa registrar_usuario de E4 para crear a los clientes y, solo para esta demo como superusuario, un deposito fijo por el libro para que las cifras sean redondas; el catalogo real de
--  productos de credito es la decision D11 del equipo: aqui se inserta 1 producto de DEMOSTRACION. La tasa de mora de 30 % es SOLO de esta demo: D7 la decide el equipo.)
BEGIN;
DO $demo$
DECLARE
  h constant text := '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';       -- hash con FORMA de bcrypt (la BD nunca ve la clave en claro)
  ua uuid; ca uuid; ub uuid; cb uuid; uc uuid; cc uuid;
  r jsonb; v_rec record; v_hoy date; v_msg text; v_k uuid; v_kb uuid; v_kc uuid; p_lib text; v_def text; v_bol text; v_antes numeric; v_n1 integer; v_n2 integer; v_x numeric;
BEGIN
  ua := (public.registrar_usuario('Ana',  'Pagos', '9500001', 'ana.e9@mail.co',  '3109500001', '1990-05-17', h, true, NULL, true) ->> 'usuario_id')::uuid;
  ub := (public.registrar_usuario('Beto', 'Pagos', '9500002', 'beto.e9@mail.co', '3109500002', '1991-02-10', h, true, NULL, true) ->> 'usuario_id')::uuid;
  uc := (public.registrar_usuario('Carla', 'Pagos', '9500003', 'carla.e9@mail.co', '3109500003', '1992-07-21', h, true, NULL, true) ->> 'usuario_id')::uuid;
  SELECT id INTO ca FROM public.cuenta WHERE usuario_id = ua;
  SELECT id INTO cb FROM public.cuenta WHERE usuario_id = ub;
  SELECT id INTO cc FROM public.cuenta WHERE usuario_id = uc;
  PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', 5000000, 'cuenta_id', ca),
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', 5000000, 'cuenta_id', ca, 'contraparte_nombre', 'Banco Digital')));
  v_hoy := public.hoy_banco();
  UPDATE public.parametro SET tasa_mora_anual = 30;                      -- SOLO esta demo (se deshace con el ROLLBACK): D7 la decide el equipo; sin tasa la mora es 0
  INSERT INTO public.credito_producto (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES ('Demo Libre inversion', 'Dinero para lo que necesites', 18, 1000000, 50000000, 6, 24);
  SELECT id::text INTO p_lib FROM public.credito_producto WHERE nombre = 'Demo Libre inversion';
  RAISE NOTICE 'Hoy del banco: %. Ana tiene % en la cuenta. Tasa de mora de la demo: 30 %% anual (provisional)', v_hoy, (SELECT balance FROM public.cuenta WHERE id = ca);

  -- 1) credito de 10.000.000 a 12 cuotas al 18 % E.A. (E8): el plan que E9 va a pagar y recalcular
  v_k := (public.solicitar_credito(ua, p_lib, 10000000, 12) ->> 'id')::uuid;
  RAISE NOTICE '1) credito %: cuotas % de %; capital_pendiente %; cuenta %', v_k, (SELECT count(*) FROM public.cuota WHERE credito_id = v_k), (SELECT valor_cuota FROM public.cuota WHERE credito_id = v_k AND numero = 1),
               (SELECT capital_pendiente FROM public.credito WHERE id = v_k), (SELECT balance FROM public.cuenta WHERE id = ca);

  -- 2) pagar la cuota 1 POR ADELANTADO (el dia del desembolso): paga cuota + interes completo, ancla fecha_interes = vencimiento, interes_mes = 0
  r := public.pagar_cuota(ua, v_k::text, 1);
  RAISE NOTICE '2) pagar_cuota(credito, numero 1) devuelve: %', r;
  RAISE NOTICE '   cuota 1: pagada=%, capital_pagado=%, intereses_pagados=%; capital_pendiente %; fecha_interes = % (el vencimiento de la cuota 1: futura)', (SELECT pagada FROM public.cuota WHERE credito_id = v_k AND numero = 1),
               (SELECT capital_pagado FROM public.cuota WHERE credito_id = v_k AND numero = 1), (SELECT intereses_pagados FROM public.cuota WHERE credito_id = v_k AND numero = 1),
               (SELECT capital_pendiente FROM public.credito WHERE id = v_k), (SELECT fecha_interes FROM public.credito WHERE id = v_k);
  FOR v_rec IN SELECT t.tipo, t.contenedor, t.sentido, t.monto FROM public.transaccion t WHERE t.credito_id = v_k AND t.tipo = 'CREDITO_CUOTA' ORDER BY t.orden LOOP
    RAISE NOTICE '     pata: % % % $%', v_rec.tipo, v_rec.contenedor, v_rec.sentido, v_rec.monto;
  END LOOP;
  RAISE NOTICE '   vista_creditos: %', public.vista_creditos(ua);
  -- idempotencia: el mismo `numero` otra vez, o uno que no es el proximo, NO paga otra cuota
  BEGIN PERFORM public.pagar_cuota(ua, v_k::text, 1); RAISE NOTICE '   *** el doble clic con numero=1 NO fallo ***';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '   doble clic con numero=1: % (no paga la cuota 2)', v_msg; END;
  BEGIN PERFORM public.pagar_cuota(ua, v_k::text, 5); RAISE NOTICE '   *** pagar la cuota 5 NO fallo ***';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '   numero=5 (no es la proxima): % (no se salta ninguna)', v_msg; END;
  RAISE NOTICE '   cuotas pagadas tras los dos intentos: % (solo la 1)', (SELECT count(*) FROM public.cuota WHERE credito_id = v_k AND pagada);

  -- 3) ABONO a mitad del periodo 2 (el dia 15 del periodo): mora -> interes corriendo -> capital; recalcula las 11 cuotas restantes SIN cambiar plazo ni fechas
  PERFORM public._reloj_actualizar(false, ((SELECT fecha_vencimiento FROM public.cuota WHERE credito_id = v_k AND numero = 1) + 15)::text);
  RAISE NOTICE '3) reloj en % (15 dias dentro del periodo de la cuota 2). vista_creditos: %', public.hoy_banco(), public.vista_creditos(ua);
  v_antes := (SELECT capital_pendiente FROM public.credito WHERE id = v_k);
  r := public.abonar_credito(ua, v_k::text, 1000000);
  RAISE NOTICE '   abonar_credito($1.000.000): % ', r;
  RAISE NOTICE '   capital % -> %; cuotas impagas % (antes 11 de 910.463,77): cuota 2 = %, cuota 12 = %; vencimientos y plazo intactos (cuotas totales %)', v_antes, (SELECT capital_pendiente FROM public.credito WHERE id = v_k),
               (SELECT count(*) FROM public.cuota WHERE credito_id = v_k AND NOT pagada), (SELECT valor_cuota FROM public.cuota WHERE credito_id = v_k AND numero = 2),
               (SELECT valor_cuota FROM public.cuota WHERE credito_id = v_k AND numero = 12), (SELECT count(*) FROM public.cuota WHERE credito_id = v_k);
  RAISE NOTICE '   suma de capital de las impagas = % = capital_pendiente (ct_credito_plan); valor_cuota_original de la 2 NO cambia: %', (SELECT sum(capital_programado - capital_pagado) FROM public.cuota WHERE credito_id = v_k AND NOT pagada),
               (SELECT valor_cuota_original FROM public.cuota WHERE credito_id = v_k AND numero = 2);
  FOR v_rec IN SELECT t.tipo, t.contenedor, t.sentido, t.monto FROM public.transaccion t WHERE t.credito_id = v_k AND t.tipo = 'CREDITO_ABONO' ORDER BY t.orden LOOP
    RAISE NOTICE '     pata: % % % $%', v_rec.tipo, v_rec.contenedor, v_rec.sentido, v_rec.monto;
  END LOOP;
  BEGIN PERFORM public.abonar_credito(ua, v_k::text, 0); RAISE NOTICE '   *** abono de $0 NO fallo ***';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '   abono de $0: % (el interes de este periodo ya se cobro: un segundo abono de $1.000 SI bajaria capital)', v_msg; END;
  BEGIN PERFORM public.abonar_credito(ua, v_k::text, 99000000); RAISE NOTICE '   *** abono mayor que la liquidacion NO fallo ***';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '   abono de $99.000.000 (excede la liquidacion): %', v_msg; END;

  -- 4) MORA: la cuota 2 queda sin pagar 10 dias despues de su vencimiento (D7 PROVISIONAL: simple sobre el valor de la cuota, 30 %% anual sobre 365)
  PERFORM public._reloj_actualizar(false, ((SELECT fecha_vencimiento FROM public.cuota WHERE credito_id = v_k AND numero = 2) + 10)::text);
  v_x := (SELECT valor_cuota FROM public.cuota WHERE credito_id = v_k AND numero = 2);
  RAISE NOTICE '4) reloj en %: cuota 2 vencida hace 10 dias (valor %). mora derivada = round(% x 30 %% / 365 x 10, 2) = %; vista_creditos.mora_acumulada = %', public.hoy_banco(), v_x, v_x, round(v_x * 0.30 / 365 * 10, 2),
               (SELECT e ->> 'mora_acumulada' FROM jsonb_array_elements(public.vista_creditos(ua)) e);
  r := public.pagar_cuota(ua, v_k::text);
  RAISE NOTICE '   pagar_cuota (sin numero) cobra cuota + mora en DOS grupos: %', r;
  FOR v_rec IN SELECT t.tipo, t.contenedor, t.sentido, t.monto FROM public.transaccion t WHERE t.credito_id = v_k AND t.tipo IN ('CREDITO_CUOTA', 'CREDITO_MORA') AND t.fecha >= public.ahora_banco() - interval '1 minute' ORDER BY t.orden LOOP
    RAISE NOTICE '     pata: % % % $%', v_rec.tipo, v_rec.contenedor, v_rec.sentido, v_rec.monto;
  END LOOP;

  -- 5) Saldo insuficiente: Beto pide un credito, se queda sin dinero y no puede pagar; nada se escribe
  v_kb := (public.solicitar_credito(ub, p_lib, 3000000, 12) ->> 'id')::uuid;
  PERFORM public.hacer_transferencia(ub, (SELECT numero_cuenta FROM public.cuenta WHERE id = ca), (SELECT balance FROM public.cuenta WHERE id = cb) - 500, 'vacia la cuenta', NULL);
  BEGIN PERFORM public.pagar_cuota(ub, v_kb::text); RAISE NOTICE '5) *** pagar sin saldo NO fallo ***';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '5) Beto (saldo %) paga su cuota: % (nada escrito: cuotas pagadas %, grupos de cuota %)', (SELECT balance FROM public.cuenta WHERE id = cb), v_msg,
                                                                                                    (SELECT count(*) FROM public.cuota WHERE credito_id = v_kb AND pagada), (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE credito_id = v_kb AND tipo = 'CREDITO_CUOTA'); END;
  BEGIN PERFORM public.pagar_cuota(ub, v_k::text); RAISE NOTICE '   *** pagar el credito AJENO NO fallo ***';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '   Beto intenta pagar el credito de Ana: % (no se distingue ajeno de inexistente)', v_msg; END;

  -- 6) DESCUENTO AUTOMATICO en orden cronologico (el caso aprobado): la cuota vence el dia ~30, Carla NO tiene saldo, su CDT vence el dia 40 y hoy = dia 55.
  --    El motor cierra el CDT (fecha del dia 40) y, EN LA MISMA fecha, reintenta la cuota: se paga con fecha del dia 40 y mora de ~10 dias (no de 30 como si fuera hoy).
  RAISE NOTICE '6) (el reloj de la demo ya esta en %: todas las fechas de Carla son relativas a ese dia, T)', public.hoy_banco();
  PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', 12000000, 'cuenta_id', cc),
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', 12000000, 'cuenta_id', cc, 'contraparte_nombre', 'Banco Digital')));
  INSERT INTO public.cdt_definicion (nombre, plazo_dias, tasa_anual, monto_min) VALUES ('Demo CDT 40 dias', 40, 9, 100000);
  SELECT id::text INTO v_def FROM public.cdt_definicion WHERE nombre = 'Demo CDT 40 dias';
  v_kc := (public.solicitar_credito(uc, p_lib, 10000000, 12) ->> 'id')::uuid;
  PERFORM public.crear_cdt(uc, v_def, (SELECT balance FROM public.cuenta WHERE id = cc) - 1000);           -- todo el dinero queda dentro del CDT: la cuenta se queda con $1.000
  r := public.activar_descuento_automatico(uc, v_kc::text, true);
  RAISE NOTICE '   activar_descuento_automatico: %; cobro_hasta (cursor) = hoy = %; saldo de la cuenta = %', r, (SELECT cobro_hasta FROM public.credito WHERE id = v_kc), (SELECT balance FROM public.cuenta WHERE id = cc);
  PERFORM public._reloj_actualizar(false, (public.hoy_banco() + 55)::text);
  RAISE NOTICE '   reloj +55 dias (hoy = %); cuota 1 vence el %; el CDT vence el %', public.hoy_banco(), (SELECT fecha_vencimiento FROM public.cuota WHERE credito_id = v_kc AND numero = 1), (SELECT fecha_fin FROM public.cdt WHERE cuenta_id = cc);
  v_n1 := (SELECT count(*) FROM public.transaccion WHERE cuenta_id = cc);
  PERFORM public.vista_creditos(uc);                                                                               -- UNA lectura dispara todo el recorrido
  RAISE NOTICE '   tras UNA lectura: cuotas pagadas = %, cobro_hasta = % (= hoy)', (SELECT count(*) FROM public.cuota WHERE credito_id = v_kc AND pagada), (SELECT cobro_hasta FROM public.credito WHERE id = v_kc);
  FOR v_rec IN SELECT t.orden, t.tipo, t.contenedor, t.monto, t.fecha::date AS dia FROM public.transaccion t WHERE t.cuenta_id = cc AND t.tipo IN ('CDT_VENCIMIENTO', 'CREDITO_CUOTA', 'CREDITO_MORA') AND t.contenedor = 'CUENTA' ORDER BY t.orden LOOP
    RAISE NOTICE '     orden %: % % $% con fecha %', v_rec.orden, v_rec.tipo, v_rec.contenedor, v_rec.monto, v_rec.dia;
  END LOOP;
  RAISE NOTICE '   (el CDT se cierra PRIMERO con la fecha de su vencimiento y la cuota se cobra DESPUES, en esa misma fecha, con mora de % dias: del vencimiento de la cuota al cierre del CDT, no hasta hoy)', (SELECT (t.fecha AT TIME ZONE 'America/Bogota')::date - (SELECT fecha_vencimiento FROM public.cuota WHERE credito_id = v_kc AND numero = 1) FROM public.transaccion t WHERE t.cuenta_id = cc AND t.tipo = 'CREDITO_MORA' AND t.contenedor = 'CUENTA' LIMIT 1);
  v_n2 := (SELECT count(*) FROM public.transaccion WHERE cuenta_id = cc);
  PERFORM public.vista_creditos(uc);
  RAISE NOTICE '   segunda lectura: patas escritas = % (idempotente: no escribe nada)', (SELECT count(*) FROM public.transaccion WHERE cuenta_id = cc) - v_n2;
  r := public.activar_descuento_automatico(uc, v_kc::text, false);
  RAISE NOTICE '   desactivar: % ; cobro_hasta = % (NULL: el credito deja de procesarse)', r, (SELECT cobro_hasta FROM public.credito WHERE id = v_kc);

  -- 7) plantillas y permisos
  RAISE NOTICE '7) plantillas del libro: %; banco_app ejecuta % funciones publicas (las 3 de E9 incluidas: %)', (SELECT count(*) FROM public._plantillas_validas()),
               (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND has_function_privilege('banco_app', p.oid, 'EXECUTE') AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')),
               (SELECT string_agg(p.proname, ', ' ORDER BY p.proname) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('pagar_cuota', 'abonar_credito', 'activar_descuento_automatico') AND has_function_privilege('banco_app', p.oid, 'EXECUTE'));

  -- 8) integridad global (partida doble, I5u, planes, defensas)
  RAISE NOTICE '8) v_integridad_global.ok = % (defensas fallidas=%, grupos con error=%, cuentas con desvio=%, creditos con plan incoherente=%, grupos de credito sin plantilla=%)', (SELECT ok FROM public.v_integridad_global),
               (SELECT defensas_fallidas FROM public.v_integridad_global), (SELECT grupos_con_error FROM public.v_integridad_global), (SELECT cuentas_con_desvio_i5u FROM public.v_integridad_global),
               (SELECT creditos_con_plan_incoherente FROM public.v_integridad_global), (SELECT grupos_credito_sin_plantilla FROM public.v_integridad_global);
END
$demo$;
ROLLBACK;
SELECT 'Demo terminada: ROLLBACK ejecutado (el reloj, la tasa de mora y los datos quedaron como estaban)' AS resultado;
