-- Demostracion de E10 (dashboard e historial) para pgAdmin: conexion "administracion (postgres)", base banco. NO deja datos NI cambia el reloj NI la tasa de mora: todo va dentro de
-- BEGIN ... ROLLBACK (los saltos de fecha tambien se deshacen) y cada intento rechazado se captura con un sub-bloque, asi que el script NO se aborta y los resultados aparecen como NOTICE
-- en la pestaña "Messages". Ejecutar COMPLETO con F5.
-- (Se usa registrar_usuario de E4 para crear a los clientes y, solo para esta demo como superusuario, un deposito fijo por el libro para que las cifras sean redondas; el catalogo real de
--  productos es la decision D11 del equipo: aqui se insertan 1 producto de credito y 1 definicion de CDT de DEMOSTRACION. La tasa de mora de 30 % es SOLO de esta demo: D7 la decide el equipo.)
BEGIN;
DO $demo$
DECLARE
  h constant text := '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';       -- hash con FORMA de bcrypt (la BD nunca ve la clave en claro)
  ua uuid; ca uuid; ub uuid; cb uuid; uc uuid; cc uuid; v_k uuid; v_kc uuid; v_p text; v_def text; v_b1 text; v_b2 text; v_rec record; v_msg text; v_hoy date; d jsonb; v_n integer;
BEGIN
  ua := (public.registrar_usuario('Ana',  'Vistas', '9700001', 'ana.e10@mail.co',  '3109700001', '1990-05-17', h, true, NULL, true) ->> 'usuario_id')::uuid;
  ub := (public.registrar_usuario('Beto', 'Vistas', '9700002', 'beto.e10@mail.co', '3109700002', '1991-02-10', h, true, NULL, true) ->> 'usuario_id')::uuid;
  uc := (public.registrar_usuario('Carla', 'Vistas', '9700003', 'carla.e10@mail.co', '3109700003', '1992-07-21', h, true, NULL, true) ->> 'usuario_id')::uuid;
  SELECT id INTO ca FROM public.cuenta WHERE usuario_id = ua; SELECT id INTO cb FROM public.cuenta WHERE usuario_id = ub; SELECT id INTO cc FROM public.cuenta WHERE usuario_id = uc;
  PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', 20000000, 'cuenta_id', ca),
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', 20000000, 'cuenta_id', ca, 'contraparte_nombre', 'Banco Digital')));
  UPDATE public.parametro SET tasa_mora_anual = 30;
  INSERT INTO public.credito_producto (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES ('Demo Libre', '', 18, 1000000, 50000000, 6, 24);
  INSERT INTO public.cdt_definicion (nombre, plazo_dias, tasa_anual, monto_min) VALUES ('Demo CDT 30', 30, 9, 100000), ('Demo CDT 40', 40, 9, 100000);
  SELECT id::text INTO v_p FROM public.credito_producto WHERE nombre = 'Demo Libre'; SELECT id::text INTO v_def FROM public.cdt_definicion WHERE nombre = 'Demo CDT 30';
  v_hoy := public.hoy_banco();
  RAISE NOTICE 'Hoy del banco: %. Ana tiene % en la cuenta (5 ingresos simulados + un deposito de la demo)', v_hoy, (SELECT balance FROM public.cuenta WHERE id = ca);

  -- 1) una cliente recien registrada: solo sus 5 ingresos simulados; sin CDT ni creditos los resumenes del dashboard van en ceros (nunca null)
  RAISE NOTICE '1) Carla (recien registrada): filas de historial = % (sus 5 ingresos simulados); dashboard: cdts = %, creditos = %', jsonb_array_length(public.vista_historial(uc, 50)), public.vista_dashboard(uc) -> 'cdts', public.vista_dashboard(uc) -> 'creditos';

  -- 2) operaciones de todos los tipos
  PERFORM public.hacer_transferencia(ua, (SELECT numero_cuenta FROM public.cuenta WHERE id = cb), 500000, 'arriendo', NULL);
  PERFORM public.hacer_transferencia(ub, (SELECT numero_cuenta FROM public.cuenta WHERE id = ca), 120000, 'devuelta', NULL);
  v_b1 := public.crear_bolsillo(ua, 'Viajes') ->> 'id'; v_b2 := public.crear_bolsillo(ua, 'Emergencias') ->> 'id';
  PERFORM public.mover_a_bolsillo(ua, v_b1, 1000000);
  PERFORM public.mover_entre_bolsillos(ua, v_b1, v_b2, 200000);
  PERFORM public.retirar_de_bolsillo(ua, v_b2, 50000);
  PERFORM public.hacer_transferencia(ua, (SELECT numero_cuenta FROM public.cuenta WHERE id = cb), 30000, 'desde bolsillo', v_b1);
  PERFORM public.crear_cdt(ua, v_def, 2000000);
  v_k := (public.solicitar_credito(ua, v_p, 5000000, 12) ->> 'id')::uuid;
  PERFORM public.pagar_cuota(ua, v_k::text);
  RAISE NOTICE '2) vista_historial(Ana) tras 1 ingreso de depositos, 3 envios/recibos, 3 movimientos de bolsillo, 1 CDT y 1 credito con su cuota: UNA fila por operacion (la mas reciente primero):';
  FOR v_rec IN SELECT e ->> 'tipo_detalle' AS td, e ->> 'tipo' AS tp, e ->> 'monto' AS mt, e ->> 'contraparte' AS cp, coalesce(e ->> 'nota', '-') AS nt
                 FROM jsonb_array_elements(public.vista_historial(ua, 50)) WITH ORDINALITY x(e, o) ORDER BY o LOOP
    RAISE NOTICE '     % | % | % | % | %', rpad(v_rec.td, 20), rpad(v_rec.tp, 6), lpad(v_rec.mt, 12), rpad(v_rec.cp, 34), v_rec.nt;
  END LOOP;
  RAISE NOTICE '   (la pata CREDITO y la pata RESULTADO de cada operacion NO aparecen; BOLSO_MOVIMIENTO sale UNA vez; el envio entre cuentas lleva el nombre y la cuenta de la contraparte)';
  RAISE NOTICE '   grupos del libro de Ana con pata de liquidez = %, filas del historial = %', (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE cuenta_id = ca AND contenedor IN ('CUENTA', 'BOLSILLO', 'CDT')), jsonb_array_length(public.vista_historial(ua, 50));
  RAISE NOTICE '   p_limite: 3 -> % filas; 0 y -5 se acotan a 1 (% y %); 1000 -> % filas (el maximo es 50)', jsonb_array_length(public.vista_historial(ua, 3)), jsonb_array_length(public.vista_historial(ua, 0)),
               jsonb_array_length(public.vista_historial(ua, -5)), jsonb_array_length(public.vista_historial(ua, 1000));
  RAISE NOTICE '   el receptor ve el mismo envio como RECIBO: %', (SELECT e FROM jsonb_array_elements(public.vista_historial(ub, 50)) e WHERE e ->> 'nota' = 'arriendo');

  -- 3) el reloj avanza: el dashboard INCLUYE el avance (devenga, cierra el CDT y trae los intereses ya escritos)
  PERFORM public._reloj_actualizar(false, (v_hoy + 45)::text);
  d := public.vista_dashboard(ua);
  RAISE NOTICE '3) reloj +45 dias (hoy = %). vista_dashboard: nombre=%, balance_total=%, cdts=%, creditos=%', public.hoy_banco(), d ->> 'nombre', d ->> 'balance_total', d -> 'cdts', d -> 'creditos';
  RAISE NOTICE '   las 3 primeras transacciones del dashboard (el motor las acaba de escribir): %', (SELECT string_agg(e ->> 'tipo_detalle' || ' ' || (e ->> 'monto'), ' ; ' ORDER BY o) FROM jsonb_array_elements(d -> 'transacciones') WITH ORDINALITY x(e, o) WHERE o <= 3);
  RAISE NOTICE '   coherencia: balance_total = vista_balance.total -> % ; transacciones = las 8 primeras del historial -> %', (d ->> 'balance_total')::numeric = (public.vista_balance(ua) ->> 'total')::numeric,
               d -> 'transacciones' = public.vista_historial(ua, 8);
  RAISE NOTICE '   vista_cdts: fecha_cierre es un INSTANTE ISO con zona (D-E10-5): %', public.vista_cdts(ua);

  -- 4) un cobro automatico disparado por el dashboard (el caso aprobado: cuota vencida, CDT que cierra despues, mora hasta la fecha del cierre)
  SELECT id::text INTO v_def FROM public.cdt_definicion WHERE nombre = 'Demo CDT 40';
  v_kc := (public.solicitar_credito(uc, v_p, 3000000, 12) ->> 'id')::uuid;
  PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', 2000000, 'cuenta_id', cc),
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', 2000000, 'cuenta_id', cc, 'contraparte_nombre', 'Banco Digital')));
  PERFORM public.crear_cdt(uc, v_def, (SELECT balance FROM public.cuenta WHERE id = cc) - 1000);
  PERFORM public.activar_descuento_automatico(uc, v_kc::text, true);
  PERFORM public._reloj_actualizar(false, (public.hoy_banco() + 50)::text);
  d := public.vista_dashboard(uc);
  RAISE NOTICE '4) Carla (descuento activo, sin saldo; la cuota vence el dia ~31 y su CDT cierra el dia 40). UNA lectura del dashboard a +50 dias cobro la cuota: cuota_por_pagar = % (ya es la cuota 2); transacciones:', d -> 'creditos' ->> 'cuota_por_pagar';
  FOR v_rec IN SELECT e ->> 'tipo_detalle' AS td, e ->> 'tipo' AS tp, e ->> 'monto' AS mt, e ->> 'contraparte' AS cp, substr(e ->> 'fecha', 1, 10) AS f
                 FROM jsonb_array_elements(d -> 'transacciones') WITH ORDINALITY x(e, o) ORDER BY o LOOP
    RAISE NOTICE '     % | % | % | % | fecha %', rpad(v_rec.td, 20), rpad(v_rec.tp, 6), lpad(v_rec.mt, 12), rpad(v_rec.cp, 12), v_rec.f;
  END LOOP;
  RAISE NOTICE '   (el cobro lleva la fecha del cierre del CDT (dia 40, con mora de los dias entre el vencimiento y el cierre), ANTES que la de hoy (dia 50): por eso el historial se ordena por orden de escritura, no por fecha)';
  v_n := (SELECT count(*) FROM public.transaccion WHERE cuenta_id = cc);
  PERFORM public.vista_dashboard(uc);
  RAISE NOTICE '   segunda lectura: patas nuevas = % (idempotente)', (SELECT count(*) FROM public.transaccion WHERE cuenta_id = cc) - v_n;

  -- 5) D8 (provisional, del equipo): UN solo punto de cambio
  RAISE NOTICE '5) _reglas_historial() = % (D8 PROVISIONAL: todo visible, como propone el contrato; cambiarlo = cambiar solo esta funcion)', public._reglas_historial();

  -- 6) rechazos y permisos
  BEGIN PERFORM public.vista_dashboard(gen_random_uuid()); RAISE NOTICE '6) *** usuario inexistente NO fallo ***';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '6) usuario inexistente: %', v_msg; END;
  RAISE NOTICE '   banco_app ejecuta % funciones publicas (las 2 de E10: %); SELECT de banco_app sobre v_transaccion_usuario = % (miraria a todos los usuarios); banco_lector = %',
               (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND has_function_privilege('banco_app', p.oid, 'EXECUTE') AND NOT EXISTS (SELECT 1 FROM pg_depend x WHERE x.objid = p.oid AND x.deptype = 'e')),
               (SELECT string_agg(p.proname, ', ' ORDER BY p.proname) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('vista_dashboard', 'vista_historial') AND has_function_privilege('banco_app', p.oid, 'EXECUTE')),
               has_table_privilege('banco_app', 'public.v_transaccion_usuario', 'SELECT'), has_table_privilege('banco_lector', 'public.v_transaccion_usuario', 'SELECT');
  RAISE NOTICE '7) v_integridad_global.ok = % (defensas fallidas=%, grupos con error=%, cuentas con desvio=%, creditos con plan incoherente=%)', (SELECT ok FROM public.v_integridad_global),
               (SELECT defensas_fallidas FROM public.v_integridad_global), (SELECT grupos_con_error FROM public.v_integridad_global), (SELECT cuentas_con_desvio_i5u FROM public.v_integridad_global),
               (SELECT creditos_con_plan_incoherente FROM public.v_integridad_global);
END
$demo$;
ROLLBACK;
SELECT 'Demo terminada: ROLLBACK ejecutado (el reloj, la tasa de mora y los datos quedaron como estaban)' AS resultado;
