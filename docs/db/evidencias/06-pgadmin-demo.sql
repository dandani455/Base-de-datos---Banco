-- Demostracion de E6 (bolsillos y vista_balance) para pgAdmin: conexion "administracion (postgres)", base banco. NO deja datos: todo va dentro de BEGIN ... ROLLBACK y cada
-- intento rechazado se captura con un sub-bloque, asi que el script NO se aborta y los resultados aparecen como NOTICE en la pestaña "Messages". Ejecutar COMPLETO con F5.
-- (Se usa registrar_usuario de E4 para crear al cliente y, solo para esta demo como superusuario, un ingreso fijo de $200.000 por el libro para que las cifras sean redondas.)
BEGIN;
DO $demo$
DECLARE
  h constant text := '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';       -- hash con FORMA de bcrypt (la BD nunca ve la clave en claro)
  ua uuid; ub uuid; ca uuid; cb uuid; b1 text; b2 text; ajeno text; r jsonb; v jsonb; v_rec record; s0 numeric; tot0 numeric;
BEGIN
  ua := (public.registrar_usuario('Ana', 'Bolsillos', '9200001', 'ana.e6@mail.co', '3109200001', '1990-05-17', h, true, NULL, true) ->> 'usuario_id')::uuid;
  ub := (public.registrar_usuario('Beto', 'Vecino', '9200002', 'beto.e6@mail.co', '3109200002', '1991-06-18', h, true, NULL, true) ->> 'usuario_id')::uuid;
  SELECT id INTO ca FROM public.cuenta WHERE usuario_id = ua;
  SELECT id INTO cb FROM public.cuenta WHERE usuario_id = ub;
  PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', 200000, 'cuenta_id', ca),
    jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', 200000, 'cuenta_id', ca, 'contraparte_nombre', 'Banco Digital')));
  s0 := (SELECT balance FROM public.cuenta WHERE id = ca);
  tot0 := (SELECT sum(balance) FROM public.cuenta) + (SELECT coalesce(sum(balance), 0) FROM public.bolsillo);
  RAISE NOTICE 'Ana tiene en su cuenta principal %', s0;

  -- 1) El front entra a Balance: GET /bolsillos = vista_balance (sin bolsillos todavia)
  RAISE NOTICE '1) vista_balance sin bolsillos: %', public.vista_balance(ua);

  -- 2) POST /bolsillos: crear (el nombre se recorta y colapsa; nombres repetidos permitidos, provisional D-E6-8)
  r := public.crear_bolsillo(ua, '   Vacaciones    2027  ');  b1 := r ->> 'id';
  RAISE NOTICE '2) crear_bolsillo devuelve: %', r;
  r := public.crear_bolsillo(ua, 'Carro');                       b2 := r ->> 'id';
  ajeno := (public.crear_bolsillo(ub, 'Del vecino') ->> 'id');

  -- 3) ingresar (cuenta -> bolsillo), retirar (bolsillo -> cuenta) y mover entre bolsillos; el monto va como texto
  r := public.mover_a_bolsillo(ua, b1, 50000.50);
  RAISE NOTICE '3a) mover_a_bolsillo devuelve: %', r;
  FOR v_rec IN SELECT t.tipo, t.contenedor, t.sentido, t.monto, t.contraparte_nombre FROM public.transaccion t WHERE t.grupo_id = (r ->> 'id')::uuid ORDER BY t.orden LOOP
    RAISE NOTICE '     pata: % % % $% contraparte=%', v_rec.tipo, v_rec.contenedor, v_rec.sentido, v_rec.monto, v_rec.contraparte_nombre;
  END LOOP;
  r := public.retirar_de_bolsillo(ua, b1, 0.50);
  RAISE NOTICE '3b) retirar_de_bolsillo devuelve: %', r;
  r := public.mover_entre_bolsillos(ua, b1, b2, 20000);
  RAISE NOTICE '3c) mover_entre_bolsillos devuelve: %', r;
  FOR v_rec IN SELECT t.tipo, t.contenedor, t.sentido, t.monto, t.contraparte_nombre FROM public.transaccion t WHERE t.grupo_id = (r ->> 'id')::uuid ORDER BY t.orden LOOP
    RAISE NOTICE '     pata: % % % $% contraparte=% (solo patas de bolsillo: la cuenta principal no se toca)', v_rec.tipo, v_rec.contenedor, v_rec.sentido, v_rec.monto, v_rec.contraparte_nombre;
  END LOOP;

  -- 4) La vista tras operar: total = principal + saldos (D-E6-12, provisional: CDT y deudas se sumaran cuando el equipo decida D6)
  v := public.vista_balance(ua);
  RAISE NOTICE '4) vista_balance: %', v;
  RAISE NOTICE '   total=% principal=% (= % - 50000.50 + 0.50)  y NO aparece el bolsillo del vecino: %', v ->> 'total', v ->> 'principal', s0,
               NOT (v::text LIKE '%' || ajeno || '%');

  -- 5) Cada rechazo con su mensaje exacto (y sin dejar rastro)
  BEGIN PERFORM public.mover_a_bolsillo(ua, b1, 0);                       RAISE NOTICE '5a) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '5a) monto 0: %', SQLERRM; END;
  BEGIN PERFORM public.retirar_de_bolsillo(ua, b1, 1.234);                RAISE NOTICE '5b) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '5b) 3 decimales: %', SQLERRM; END;
  BEGIN PERFORM public.mover_a_bolsillo(ua, 'no-es-uuid', 10);            RAISE NOTICE '5c) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '5c) bolsillo mal formado (negocio, no error de driver): %', SQLERRM; END;
  BEGIN PERFORM public.mover_a_bolsillo(ua, ajeno, 10);                   RAISE NOTICE '5d) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '5d) bolsillo AJENO (indistinguible de uno inexistente): %', SQLERRM; END;
  BEGIN PERFORM public.mover_entre_bolsillos(ua, b1, b1, 10);             RAISE NOTICE '5e) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '5e) mismo bolsillo (PROVISIONAL D-E6-9): %', SQLERRM; END;
  BEGIN PERFORM public.retirar_de_bolsillo(ua, b2, 20000.01);             RAISE NOTICE '5f) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '5f) un centavo mas que el bolsillo: %', SQLERRM; END;
  BEGIN PERFORM public.mover_a_bolsillo(ua, b1, 99999999);                RAISE NOTICE '5g) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '5g) mas que la cuenta: %', SQLERRM; END;
  BEGIN PERFORM public.crear_bolsillo(ua, repeat('x', 41));               RAISE NOTICE '5h) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '5h) nombre de 41 caracteres (PROVISIONAL D-E6-8): %', SQLERRM; END;
  BEGIN PERFORM public.vista_balance(gen_random_uuid());                  RAISE NOTICE '5i) !!! FALLO'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE '5i) sin sesion viva: %', SQLERRM; END;

  -- 6) Conservacion: los movimientos no crean ni destruyen dinero
  RAISE NOTICE '6) suma de cuentas + bolsillos: antes % = despues % ; integridad global ok = %', tot0,
               (SELECT sum(balance) FROM public.cuenta) + (SELECT coalesce(sum(balance), 0) FROM public.bolsillo), (SELECT ok FROM public.v_integridad_global);
END
$demo$;
ROLLBACK;
