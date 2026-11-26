-- Demostracion de E8 (creditos) para pgAdmin: conexion "administracion (postgres)", base banco. NO deja datos NI cambia el reloj: todo va dentro de BEGIN ... ROLLBACK
-- (el salto de fecha tambien se deshace) y cada intento rechazado se captura con un sub-bloque, asi que el script NO se aborta y los resultados aparecen como NOTICE
-- en la pestaña "Messages". Ejecutar COMPLETO con F5.
-- (Se usa registrar_usuario de E4 para crear al cliente y, solo para esta demo como superusuario, un deposito fijo por el libro para que las cifras sean redondas;
--  el catalogo real de productos de credito es la decision D11 del equipo: aqui se insertan 4 productos de DEMOSTRACION dentro de la transaccion.)
BEGIN;
DO $demo$
DECLARE
  h constant text := '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';       -- hash con FORMA de bcrypt (la BD nunca ve la clave en claro)
  ua uuid; ca uuid; ub uuid; cb uuid; r jsonb; v_rec record; v_hoy date; v_msg text; v_k uuid; v_bol text;
  p_libre text; p_inm text; p_veh text; v_int1 numeric; v_antes numeric;
BEGIN
  ua := (public.registrar_usuario('Ana', 'Credito', '9400001', 'ana.e8@mail.co', '3109400001', '1990-05-17', h, true, NULL, true) ->> 'usuario_id')::uuid;
  ub := (public.registrar_usuario('Beto', 'Mayor', '9400002', 'beto.e8@mail.co', '3109400002', '1983-02-10', h, true, NULL, true) ->> 'usuario_id')::uuid;   -- ~43 años: regla de edad
  SELECT id INTO ca FROM public.cuenta WHERE usuario_id = ua;
  SELECT id INTO cb FROM public.cuenta WHERE usuario_id = ub;
  PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', 5000000, 'cuenta_id', ca),
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', 5000000, 'cuenta_id', ca, 'contraparte_nombre', 'Banco Digital')));
  PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', 5000000, 'cuenta_id', cb),
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', 5000000, 'cuenta_id', cb, 'contraparte_nombre', 'Banco Digital')));
  v_hoy := public.hoy_banco();
  RAISE NOTICE 'Hoy del banco: %. Ana tiene % en la cuenta (ingresos simulados + deposito de la demo)', v_hoy, (SELECT balance FROM public.cuenta WHERE id = ca);

  -- 1) catalogo de DEMOSTRACION (el real es D11, del equipo). Libre inversion con tope fijo 30M dentro de un rango de hasta 50M; Inmuebles = 100 x patrimonio, tope 2.000M, regla de edad
  INSERT INTO public.credito_producto (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses, tope_absoluto, multiplicador_balance, aplica_regla_edad) VALUES
    ('Demo Libre inversion', 'Dinero para lo que necesites', 18, 1000000, 50000000, 6, 24, 30000000, NULL, false),
    ('Demo Vehiculo',        'Estrena carro',                18.9, 5000000, 200000000, 12, 120, NULL, NULL, false),
    ('Demo Educacion',       'Invierte en tu formacion',     15.4, 1000000, 100000000, 6, 240, NULL, NULL, false),
    ('Demo Inmuebles',       'Tu casa',                      14.1, 1, 2000000000, 12, 360, 2000000000, 100, true);
  SELECT id::text INTO p_libre FROM public.credito_producto WHERE nombre = 'Demo Libre inversion';
  SELECT id::text INTO p_inm   FROM public.credito_producto WHERE nombre = 'Demo Inmuebles';
  SELECT id::text INTO p_veh   FROM public.credito_producto WHERE nombre = 'Demo Vehiculo';
  RAISE NOTICE '1) productos_publicos (sin sesion, topes BASE): %', public.productos_publicos();
  RAISE NOTICE '   productos_disponibles de Ana (topes EFECTIVOS: Libre 30M por el tope fijo; Inmuebles = 100 x patrimonio): %', public.productos_disponibles(ua);

  -- 2) simular: $10.000.000 a 12 meses al 18 % E.A. (PROVISIONAL D1: tasa efectiva anual estricta; con la tasa nominal 18/12 la cuota seria 916.799,93)
  RAISE NOTICE '2) simular_credito($10.000.000, 12 meses, 18 %% E.A.): %', public.simular_credito(ua, p_libre, 10000000, 12);
  RAISE NOTICE '   (cuota fija 910.463,77 = P·i·q/(q-1) con i = 1,388843 %% mensual; la ultima cuota absorbe el redondeo; total = suma de cuotas)';

  -- 3) solicitar: desembolso instantaneo, plan completo y asiento
  v_antes := (SELECT balance FROM public.cuenta WHERE id = ca);
  r := public.solicitar_credito(ua, p_libre, 10000000, 12);
  v_k := (r ->> 'id')::uuid;
  RAISE NOTICE '3) solicitar_credito devuelve: %', r;
  RAISE NOTICE '   cuenta: % -> % (+10.000.000); capital_pendiente = %; estado %', v_antes, (SELECT balance FROM public.cuenta WHERE id = ca),
               (SELECT capital_pendiente FROM public.credito WHERE id = v_k), (SELECT estado FROM public.credito WHERE id = v_k);
  RAISE NOTICE '   plan: % cuotas; suma de capital = %; suma de cuotas = %; suma de intereses = %', (SELECT count(*) FROM public.cuota WHERE credito_id = v_k),
               (SELECT sum(capital_programado) FROM public.cuota WHERE credito_id = v_k), (SELECT sum(valor_cuota) FROM public.cuota WHERE credito_id = v_k), (SELECT sum(interes_programado) FROM public.cuota WHERE credito_id = v_k);
  FOR v_rec IN SELECT numero, fecha_vencimiento, valor_cuota, capital_programado, interes_programado FROM public.cuota WHERE credito_id = v_k AND numero IN (1, 2, 12) ORDER BY numero LOOP
    RAISE NOTICE '     cuota %: vence %  valor %  capital %  interes %', v_rec.numero, v_rec.fecha_vencimiento, v_rec.valor_cuota, v_rec.capital_programado, v_rec.interes_programado;
  END LOOP;
  FOR v_rec IN SELECT t.tipo, t.contenedor, t.sentido, t.monto, t.saldo_previo, t.saldo_posterior, t.contraparte_nombre FROM public.transaccion t WHERE t.credito_id = v_k ORDER BY t.orden LOOP
    RAISE NOTICE '     pata: % % % $% (saldo % -> %) contraparte=%', v_rec.tipo, v_rec.contenedor, v_rec.sentido, v_rec.monto, v_rec.saldo_previo, v_rec.saldo_posterior, v_rec.contraparte_nombre;
  END LOOP;
  RAISE NOTICE '   vista_creditos: %', public.vista_creditos(ua);
  RAISE NOTICE '   el tope de Inmuebles NO se infla con la deuda (patrimonio neto = balance_total - deuda): %', (SELECT e FROM jsonb_array_elements(public.productos_disponibles(ua)) e WHERE e ->> 'nombre' = 'Demo Inmuebles');
  RAISE NOTICE '   (D6 PROVISIONAL: balance_total NO resta la deuda: %; el patrimonio neto para el tope: %)', public.balance_total(ca), public._patrimonio_neto(ca);

  -- 4) rechazos con su mensaje exacto (y sin rastro)
  FOR v_rec IN SELECT * FROM (VALUES ('segundo credito del mismo producto (Ana)', ua, p_libre, 2000000::numeric, 12::numeric), ('Libre inversion 31.000.000, sobre el tope fijo de 30M (Beto)', ub, p_libre, 31000000::numeric, 12::numeric),
                                     ('Vehiculo 4.000.000, bajo el minimo de 5M de la demo (Beto)', ub, p_veh, 4000000::numeric, 24::numeric), ('plazo fraccionario (Beto)', ub, p_libre, 2000000::numeric, 12.5::numeric),
                                     ('plazo de 5 meses, bajo el minimo de 6 (Beto)', ub, p_libre, 2000000::numeric, 5::numeric), ('monto invalido (Beto)', ub, p_libre, 0::numeric, 12::numeric)) q(que, usr, prod, m, pl) LOOP
    BEGIN PERFORM public.solicitar_credito(v_rec.usr, v_rec.prod, v_rec.m, v_rec.pl); RAISE NOTICE '4) %: *** NO fallo ***', v_rec.que;
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '4) %: %', v_rec.que, v_msg; END;
  END LOOP;
  BEGIN PERFORM public.solicitar_credito(ua, 'no-es-uuid', 1000000, 12); RAISE NOTICE '4) producto mal formado: *** NO fallo ***';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '4) producto mal formado (negocio, no error de driver): %', v_msg; END;

  -- 5) regla de edad (Beto, ~43 años): plazo maximo de Inmuebles = (70 - 43) * 12 = 324 meses
  RAISE NOTICE '5) productos de Beto (edad %): Inmuebles %', date_part('year', age(v_hoy, (SELECT fecha_nacimiento FROM public.usuario WHERE id = ub))),
               (SELECT e FROM jsonb_array_elements(public.productos_disponibles(ub)) e WHERE e ->> 'nombre' = 'Demo Inmuebles');
  BEGIN PERFORM public.solicitar_credito(ub, p_inm, 1000000, 340); RAISE NOTICE '5) plazo 340: *** NO fallo ***';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '5) Inmuebles a 340 meses (> 324): %', v_msg; END;
  BEGIN PERFORM public.solicitar_credito(ub, p_inm, 1000000, 400); RAISE NOTICE '5) plazo 400: *** NO fallo ***';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '5) Inmuebles a 400 meses (> 360, maximo del producto): %', v_msg; END;
  RAISE NOTICE '5) Inmuebles $500.000.000 a 324 meses (dentro del tope 100 x patrimonio): %', public.solicitar_credito(ub, p_inm, 500000000, 324);

  -- 6) el reloj avanza: el interes corriendo (derivado, PROVISIONAL D-E8-4) crece por prorrata hasta el interes completo de la cuota 1 y no escribe nada
  v_int1 := (SELECT interes_programado FROM public.cuota WHERE credito_id = v_k AND numero = 1);
  RAISE NOTICE '6) interes de la cuota 1: % (periodo de % dias)', v_int1, (SELECT fecha_vencimiento - v_hoy FROM public.cuota WHERE credito_id = v_k AND numero = 1);
  PERFORM public._reloj_actualizar(false, (v_hoy + 15)::text);
  RAISE NOTICE '   reloj +15 dias (hoy = %): interes_mes = %', public.hoy_banco(), (SELECT e ->> 'interes_mes' FROM jsonb_array_elements(public.vista_creditos(ua)) e);
  PERFORM public._reloj_actualizar(false, (v_hoy + 45)::text);
  RAISE NOTICE '   reloj +45 dias (hoy = %): interes_mes = % (tope: el interes completo de la cuota 1; no crece mas ni hay mora en E8)', public.hoy_banco(), (SELECT e ->> 'interes_mes' FROM jsonb_array_elements(public.vista_creditos(ua)) e);
  RAISE NOTICE '   patas de credito de Ana siguen siendo %: leer no escribe en el libro', (SELECT count(*) FROM public.transaccion WHERE credito_id = v_k);

  -- 7) devengo previo (E7): un bolsillo de Ana gana interes ANTES de que se calcule el tope
  v_bol := public.crear_bolsillo(ua, 'Ahorro') ->> 'id';
  PERFORM public.mover_a_bolsillo(ua, v_bol, 1000000);
  PERFORM public._reloj_actualizar(false, (v_hoy + 75)::text);
  RAISE NOTICE '7) +30 dias con $1.000.000 en un bolsillo: interes escrito antes de leer = %', (SELECT balance - 1000000 FROM public.bolsillo WHERE id = v_bol::uuid);
  PERFORM public.productos_disponibles(ua);
  RAISE NOTICE '   tras productos_disponibles (devenga PRIMERO y luego calcula el tope): interes del bolsillo = %, grupos INTERES_BOLSO = %, monto_max de Inmuebles = %',
               (SELECT balance - 1000000 FROM public.bolsillo WHERE id = v_bol::uuid), (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE bolsillo_id = v_bol::uuid AND tipo = 'INTERES_BOLSO'),
               (SELECT e ->> 'monto_max' FROM jsonb_array_elements(public.productos_disponibles(ua)) e WHERE e ->> 'nombre' = 'Demo Inmuebles');
  RAISE NOTICE '   (la segunda consulta no repite nada: sigue 1 solo grupo de interes)';

  -- 8) la regla ct_credito_plan: capital_pendiente = Σ (capital_programado - capital_pagado) de las cuotas impagas. Un plan que no cuadra se rechaza al verificar.
  BEGIN
    UPDATE public.cuota SET capital_programado = capital_programado + 1, valor_cuota = valor_cuota + 1 WHERE credito_id = v_k AND numero = 1;
    SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota IMMEDIATE;
    RAISE NOTICE '8) *** ct_credito_plan NO objeto un plan descuadrado ***';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; RAISE NOTICE '8) plan descuadrado (capital de la cuota 1 + 1): %', v_msg; END;

  -- 9) integridad global (partida doble, I5u, planes de credito)
  RAISE NOTICE '9) v_integridad_global.ok = % (defensas fallidas=%, grupos con error=%, cuentas con desvio=%, creditos con plan incoherente=%)', (SELECT ok FROM public.v_integridad_global),
               (SELECT defensas_fallidas FROM public.v_integridad_global), (SELECT grupos_con_error FROM public.v_integridad_global), (SELECT cuentas_con_desvio_i5u FROM public.v_integridad_global),
               (SELECT creditos_con_plan_incoherente FROM public.v_integridad_global);
END
$demo$;
ROLLBACK;
SELECT 'Demo terminada: ROLLBACK ejecutado (el reloj y los datos quedaron como estaban)' AS resultado;
