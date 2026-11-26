-- Demostracion de E2 para pgAdmin (conexion "administracion (postgres)", base banco). NO deja datos: todo va dentro de
-- BEGIN ... ROLLBACK y cada intento prohibido se captura con un sub-bloque, asi que el script NO se aborta y los resultados
-- aparecen como NOTICE en la pestaña "Messages". Ejecutar COMPLETO con F5.
BEGIN;
DO $$
DECLARE
  a uuid := '11111111-1111-4111-8111-111111111111';
  b uuid := '22222222-2222-4222-8222-222222222222';
  g uuid;
BEGIN
  INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento) VALUES
    (a, 'demoana1',  'x', 'Ana',  'Demo', '9000001', 'ana.demo@x.co',  '3000001', DATE '1990-01-01'),
    (b, 'demobeto1', 'x', 'Beto', 'Demo', '9000002', 'beto.demo@x.co', '3000002', DATE '1990-01-01');
  INSERT INTO public.cuenta (id, usuario_id, numero_cuenta) VALUES (a, a, '4090000001'), (b, b, '4090000002');
  RAISE NOTICE '1) Las cuentas nacen con balance 0: Ana=%, Beto=%', (SELECT balance FROM public.cuenta WHERE id = a), (SELECT balance FROM public.cuenta WHERE id = b);

  g := public._asentar_grupo(now(), jsonb_build_array(
         jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','CUENTA',    'sentido','E','monto',1000,'cuenta_id',a),
         jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','RESULTADO', 'sentido','E','monto',1000,'cuenta_id',a)));
  RAISE NOTICE '2) Ingreso de 1000 a Ana por el unico escritor autorizado (_asentar_grupo). Ana=%', (SELECT balance FROM public.cuenta WHERE id = a);

  PERFORM public._asentar_grupo(now(), jsonb_build_array(
         jsonb_build_object('tipo','ENVIO', 'contenedor','CUENTA','sentido','S','monto',300,'cuenta_id',a,'contraparte_nombre','Beto Demo','contraparte_cuenta','4090000002'),
         jsonb_build_object('tipo','RECIBO','contenedor','CUENTA','sentido','E','monto',300,'cuenta_id',b,'contraparte_nombre','Ana Demo','contraparte_cuenta','4090000001')));
  RAISE NOTICE '3) Transferencia de 300 de Ana a Beto. Ana=% Beto=%', (SELECT balance FROM public.cuenta WHERE id = a), (SELECT balance FROM public.cuenta WHERE id = b);
  RAISE NOTICE '   saldo previo/posterior de la pata ENVIO (los fija el libro): %',
               (SELECT saldo_previo || ' -> ' || saldo_posterior FROM public.transaccion WHERE tipo = 'ENVIO' AND cuenta_id = a);
  RAISE NOTICE '4) Vistas de integridad: ok=% (patas=%, grupos=%)', (SELECT ok FROM public.v_integridad_global), (SELECT patas FROM public.v_integridad_global), (SELECT grupos FROM public.v_integridad_global);

  BEGIN
    UPDATE public.cuenta SET balance = 999999 WHERE id = a;
    RAISE NOTICE '5) !!! FALLO: el UPDATE directo de balance fue ACEPTADO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '5) UPDATE directo de balance RECHAZADO: %', SQLERRM;
  END;
  BEGIN
    PERFORM public._asentar_grupo(now(), jsonb_build_array(
         jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','CUENTA',   'sentido','E','monto',1000,'cuenta_id',a),
         jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','RESULTADO','sentido','E','monto',999, 'cuenta_id',a)));
    RAISE NOTICE '6) !!! FALLO: un grupo descuadrado fue ACEPTADO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '6) Grupo descuadrado (1000 contra 999) RECHAZADO: %', SQLERRM;
  END;
  BEGIN
    PERFORM public._asentar_grupo(now(), jsonb_build_array(
         jsonb_build_object('tipo','AJUSTE_ADMIN','contenedor','CUENTA',   'sentido','S','monto',5000000,'cuenta_id',a),
         jsonb_build_object('tipo','AJUSTE_ADMIN','contenedor','RESULTADO','sentido','S','monto',5000000,'cuenta_id',a)));
    RAISE NOTICE '7) !!! FALLO: un retiro sin saldo fue ACEPTADO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '7) Retiro sin saldo RECHAZADO: %', SQLERRM;
  END;
  BEGIN
    PERFORM public._asentar_grupo(now(), jsonb_build_array(
         jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','CUENTA',   'sentido','E','monto',10,'cuenta_id',a),
         jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','RESULTADO','sentido','E','monto',10,'cuenta_id',b)));
    RAISE NOTICE '8) !!! FALLO: dinero entre cuentas fuera de un par ENVIO/RECIBO fue ACEPTADO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '8) Dinero entre dos cuentas fuera de un par ENVIO/RECIBO RECHAZADO: %', SQLERRM;
  END;
  BEGIN UPDATE public.transaccion SET monto = 1;     RAISE NOTICE '9) !!! FALLO: UPDATE de una pata ACEPTADO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '9) UPDATE de una pata del libro RECHAZADO: %', SQLERRM; END;
  BEGIN DELETE FROM public.transaccion;               RAISE NOTICE '10) !!! FALLO: DELETE de patas ACEPTADO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '10) DELETE directo de patas RECHAZADO: %', SQLERRM; END;
  BEGIN TRUNCATE public.transaccion;                  RAISE NOTICE '11) !!! FALLO: TRUNCATE ACEPTADO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '11) TRUNCATE del libro RECHAZADO: %', SQLERRM; END;

  DELETE FROM public.usuario WHERE id = b;
  RAISE NOTICE '12) Borrado de Beto (cascada): auditoria = %', (SELECT antes::text FROM audit.evento WHERE accion = 'CUENTA_BORRADA' AND entidad_id = b::text);
  RAISE NOTICE '    grupos huerfanos por borrado (esperado: 1, la transferencia): %   estado global ok=%',
               (SELECT count(*) FROM public.v_integridad_grupos WHERE estado = 'HUERFANO_POR_BORRADO'), (SELECT ok FROM public.v_integridad_global);
END
$$;
ROLLBACK;
SELECT count(*) AS cuentas_tras_la_demo, (SELECT count(*) FROM public.transaccion) AS patas_tras_la_demo FROM public.cuenta;
