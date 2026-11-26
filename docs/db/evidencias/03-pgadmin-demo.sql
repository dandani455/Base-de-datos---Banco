-- Demostracion de E3 (reloj bancario, opcion A) para pgAdmin: conexion "administracion (postgres)", base banco. NO deja datos ni cambia el reloj:
-- todo va dentro de BEGIN ... ROLLBACK y cada intento prohibido se captura con un sub-bloque, asi que el script NO se aborta y los resultados
-- aparecen como NOTICE en la pestaña "Messages". Ejecutar COMPLETO con F5.
BEGIN;
DO $$
DECLARE
  a  uuid := '11111111-1111-4111-8111-111111111111';
  r  date := (now() AT TIME ZONE 'America/Bogota')::date;          -- fecha real de Colombia
  g  uuid;
BEGIN
  RAISE NOTICE '1) Estado inicial del reloj: %  (hoy_banco = %, fecha real de Colombia = %)', public._reloj_vista(), public.hoy_banco(), r;

  -- Un cliente con un ingreso: desde que existe UNA pata del libro, el reloj ya no puede retroceder
  INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento)
  VALUES (a, 'demoana1', 'x', 'Ana', 'Demo', '9000001', 'ana.demo@x.co', '3000001', DATE '1990-01-01');
  INSERT INTO public.cuenta (id, usuario_id, numero_cuenta) VALUES (a, a, '4090000001');
  PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
          jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','CUENTA',   'sentido','E','monto',1000,'cuenta_id',a),
          jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','RESULTADO','sentido','E','monto',1000,'cuenta_id',a)));
  RAISE NOTICE '2) Ingreso de 1000 a Ana fechado con ahora_banco() = %. banco_vacio = %', public.ahora_banco(), (SELECT banco_vacio FROM public.v_reloj_estado);

  -- Adelantar es lo unico que se puede hacer en modo manual
  RAISE NOTICE '3) Adelantar el reloj 30 dias: %', public._reloj_actualizar(false, to_char(r + 30, 'YYYY-MM-DD'));
  RAISE NOTICE '   hoy_banco = % (fecha real + 30)   ahora_banco = % (hora REAL de Bogota)', public.hoy_banco(), public.ahora_banco();

  BEGIN
    PERFORM public._reloj_actualizar(false, to_char(r + 10, 'YYYY-MM-DD'));
    RAISE NOTICE '4) !!! FALLO: el retroceso a fecha real + 10 fue ACEPTADO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '4) Retroceder de +30 a +10 RECHAZADO: %', SQLERRM;
  END;
  BEGIN
    PERFORM public._reloj_actualizar(false, 'manana');
    RAISE NOTICE '5) !!! FALLO: una fecha invalida fue ACEPTADA';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '5) Fecha invalida RECHAZADA (mensaje provisional hasta D13): %', SQLERRM;
  END;

  -- El libro: una operacion se fecha con el reloj del banco; nada puede estar fechado despues de el
  PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
          jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','CUENTA',   'sentido','E','monto',5,'cuenta_id',a),
          jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','RESULTADO','sentido','E','monto',5,'cuenta_id',a)));
  RAISE NOTICE '6) Con el reloj en +30, un ingreso fechado con ahora_banco() entra (fecha de la pata: %)',
               (SELECT (fecha AT TIME ZONE 'America/Bogota')::date FROM public.transaccion WHERE cuenta_id = a AND monto = 5 AND contenedor = 'CUENTA');
  BEGIN
    PERFORM public._asentar_grupo(public.ahora_banco() + interval '1 day', jsonb_build_array(
          jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','CUENTA',   'sentido','E','monto',7,'cuenta_id',a),
          jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','RESULTADO','sentido','E','monto',7,'cuenta_id',a)));
    RAISE NOTICE '7) !!! FALLO: una pata fechada despues del reloj fue ACEPTADA';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '7) Pata fechada un dia DESPUES del reloj RECHAZADA: %', SQLERRM;
  END;

  -- Volver a fecha real: siempre permitido, aunque la fecha real sea ANTERIOR a la simulada
  RAISE NOTICE '8) Volver a fecha real: %', public._reloj_actualizar(true, '');
  RAISE NOTICE '   hoy_banco = % (la fecha de Colombia)   fecha_sistema guardada = %  <- no queda desfase', public.hoy_banco(), (SELECT fecha_sistema FROM public.reloj);
  RAISE NOTICE '   La pata fechada en +30 PERMANECE (la simulacion no se revierte contablemente): % patas fechadas en el futuro (informativo, no es error); integridad ok=%',
               (SELECT patas_fechadas_en_el_futuro FROM public.v_reloj_estado), (SELECT ok FROM public.v_integridad_global);
  BEGIN
    PERFORM public._asentar_grupo(((r + 30)::timestamp + time '12:00') AT TIME ZONE 'America/Bogota', jsonb_build_array(
          jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','CUENTA',   'sentido','E','monto',9,'cuenta_id',a),
          jsonb_build_object('tipo','INGRESO_SIMULADO','contenedor','RESULTADO','sentido','E','monto',9,'cuenta_id',a)));
    RAISE NOTICE '9) !!! FALLO: una pata nueva fechada en +30 fue ACEPTADA con el reloj real';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '9) Con el reloj real, una pata NUEVA fechada en +30 ya no entra: %', SQLERRM;
  END;

  -- Ni siquiera el UPDATE directo (superusuario incluido) puede retroceder el reloj ni dejarlo en un estado incoherente
  PERFORM public._reloj_actualizar(false, to_char(r + 5, 'YYYY-MM-DD'));
  BEGIN
    UPDATE public.reloj SET fecha_sistema = r - 1;
    RAISE NOTICE '10) !!! FALLO: UPDATE directo hacia atras ACEPTADO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '10) UPDATE directo que retrocede el reloj RECHAZADO (rige tambien para el superusuario): %', SQLERRM;
  END;
  BEGIN DELETE FROM public.reloj;   RAISE NOTICE '11) !!! FALLO: DELETE del reloj ACEPTADO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '11) DELETE del reloj RECHAZADO: %', SQLERRM; END;
  BEGIN TRUNCATE public.reloj;      RAISE NOTICE '12) !!! FALLO: TRUNCATE del reloj ACEPTADO';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE '12) TRUNCATE del reloj RECHAZADO: %', SQLERRM; END;

  RAISE NOTICE '13) Auditoria de esta demo (cada cambio efectivo del reloj): %',
               (SELECT string_agg((despues ->> 'usar_fecha_real') || '/' || coalesce(despues ->> 'fecha_sistema', 'null'), '  ->  ' ORDER BY orden)
                  FROM audit.evento WHERE accion = 'RELOJ_CAMBIO' AND fecha = now());          -- now() = instante de esta transaccion
  PERFORM public._reloj_actualizar(true, '');
  RAISE NOTICE '14) Estado final dentro de la demo (se revierte con el ROLLBACK): %', public._reloj_vista();
END
$$;
ROLLBACK;
-- Tras el ROLLBACK el reloj esta como estaba antes y no quedo ningun dato de la demo
SELECT usar_fecha_real, fecha_sistema, public.hoy_banco() AS hoy_banco, (SELECT count(*) FROM public.cuenta WHERE numero_cuenta = '4090000001') AS cuentas_de_la_demo FROM public.reloj;
