-- Demostracion de E13 (mantenimiento) para pgAdmin: conexion "administracion (postgres)", base banco.
-- PARTE 1 (BEGIN ... ROLLBACK, se puede ejecutar COMPLETA con F5): sp_verificar_integridad y los limites de sp_avanzar_todos.
-- PARTE 2 (CIERRE REAL): sp_avanzar_todos HACE COMMIT por cuenta, asi que NO puede correr dentro de una transaccion: en pgAdmin ejecuta CADA sentencia por separado (selecciona la sentencia y F5;
--          el Query Tool debe estar en autocommit, que es su modo por defecto). Esta parte deja datos y mueve el reloj: usala sobre una copia o respaldo (politica de demostraciones de E3) y ejecuta
--          al final el bloque de LIMPIEZA. En la evidencia se corrio completa con `psql -f` (que si usa autocommit) sobre una base desechable.
-- (Los clientes se crean con registrar_usuario de E4; el catalogo de productos es la decision D11 del equipo: aqui se insertan 1 producto y 1 CDT de DEMOSTRACION.)

-- ============================================================================
-- PARTE 1: el informe de integridad (solo lectura) y el limite transaccional
-- ============================================================================
BEGIN;
DO $demo$
DECLARE
  h constant text := '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';
  ua uuid; ub uuid; r jsonb;
BEGIN
  ua := (public.registrar_usuario('Ana',  'Mant', '9600001', 'ana.e13@mail.co',  '3109600001', '1990-05-17', h, true, NULL, true) ->> 'usuario_id')::uuid;
  ub := (public.registrar_usuario('Beto', 'Mant', '9600002', 'beto.e13@mail.co', '3109600002', '1991-02-10', h, true, NULL, true) ->> 'usuario_id')::uuid;
  PERFORM public.hacer_transferencia(ua, (SELECT numero_cuenta FROM public.cuenta WHERE usuario_id = ub), 100000, 'demo', NULL);
  CALL public.sp_verificar_integridad(r);
  RAISE NOTICE '1) banco sano: ok = %, desvios de saldos = %, grupos con error = %, I5u = %, defensas caidas = %, planes = %; filas defectuosas en el detalle: saldos %, grupos %, defensas %',
               r ->> 'ok', r ->> 'contenedores_con_desvio', r ->> 'grupos_con_error', r ->> 'cuentas_con_desvio_i5u', r ->> 'defensas_fallidas', r ->> 'creditos_con_plan_incoherente',
               jsonb_array_length(r #> '{detalle,saldos}'), jsonb_array_length(r #> '{detalle,grupos}'), jsonb_array_length(r #> '{detalle,defensas}');
  RAISE NOTICE '   el informe coincide con la vista: %', (SELECT bool_and(e.value IS NOT DISTINCT FROM (to_jsonb(g) ->> e.key)) FROM jsonb_each_text(r - 'detalle') e, public.v_integridad_global g);
  -- un SABOTAJE que solo un superusuario puede hacer (apagar el guardia y alterar un saldo): el informe lo senala con su fila
  ALTER TABLE public.cuenta DISABLE TRIGGER trg_zz_proteger_cuenta;
  UPDATE public.cuenta SET balance = balance + 12345 WHERE usuario_id = ub;
  CALL public.sp_verificar_integridad(r);
  RAISE NOTICE '2) saldo alterado a mano (+12345) y guardia apagado: ok = %, desvios de saldos = %, I5u = %, defensas caidas = %', r ->> 'ok', r ->> 'contenedores_con_desvio', r ->> 'cuentas_con_desvio_i5u', r ->> 'defensas_fallidas';
  RAISE NOTICE '   la fila de saldos: %', r #> '{detalle,saldos,0}';
  RAISE NOTICE '   la defensa caida: %', (SELECT e ->> 'control' || ' -> ' || coalesce(e ->> 'detalle', '') FROM jsonb_array_elements(r #> '{detalle,defensas}') e LIMIT 1);
  RAISE NOTICE '   (un solo CALL: el informe se arma en UNA sentencia, asi que conteos y filas nunca se contradicen)';
  -- sp_avanzar_todos hace COMMIT por cuenta: dentro de una transaccion no puede
  BEGIN
    CALL public.sp_avanzar_todos(r);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '3) sp_avanzar_todos DENTRO de una transaccion -> "%" (SQLSTATE %): hay que llamarlo SOLO, en autocommit', SQLERRM, SQLSTATE;
  END;
  RAISE NOTICE '   nadie salvo dueño/superusuario ejecuta los procedimientos: banco_app = %, banco_lector = %, banco_dev = %',
               has_function_privilege('banco_app', 'public.sp_avanzar_todos(jsonb)', 'EXECUTE'), has_function_privilege('banco_lector', 'public.sp_verificar_integridad(jsonb)', 'EXECUTE'),
               has_function_privilege('banco_dev', 'public.sp_avanzar_todos(jsonb)', 'EXECUTE');
  RAISE NOTICE '   son procedimientos SECURITY INVOKER sin clausula SET (unica forma de poder hacer COMMIT): %', (SELECT string_agg(proname || ' secdef=' || prosecdef || ' config=' || coalesce(proconfig::text, 'ninguna'), ' ; ') FROM pg_proc WHERE proname IN ('sp_avanzar_todos', 'sp_verificar_integridad'));
END
$demo$;
ROLLBACK;

-- ============================================================================
-- PARTE 2: el cierre REAL (cada sentencia por separado en pgAdmin)
-- ============================================================================
-- 2.0 preparacion: 3 clientes con bolsillo, CDT de 30 dias y credito con descuento automatico; despues el reloj avanza 45 dias
SELECT public.registrar_usuario('Cata', 'Cierre', '9600011', 'cata.e13@mail.co', '3109600011', '1990-05-17', '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy', true, NULL, true) ->> 'username' AS cliente_1;
SELECT public.registrar_usuario('Dario', 'Cierre', '9600012', 'dario.e13@mail.co', '3109600012', '1991-02-10', '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy', true, NULL, true) ->> 'username' AS cliente_2;
SELECT public.registrar_usuario('Eva', 'Cierre', '9600013', 'eva.e13@mail.co', '3109600013', '1992-07-21', '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy', true, NULL, true) ->> 'username' AS cliente_3;
INSERT INTO public.credito_producto (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES ('Demo13 Libre', '', 18, 1000000, 50000000, 6, 24);
INSERT INTO public.cdt_definicion (nombre, plazo_dias, tasa_anual, monto_min) VALUES ('Demo13 CDT 30', 30, 9, 100000);
DO $p$
DECLARE u record; v_b text; v_k text;
BEGIN
  FOR u IN SELECT us.id, c.id AS cuenta FROM public.usuario us JOIN public.cuenta c ON c.usuario_id = us.id WHERE us.cedula IN ('9600011', '9600012', '9600013') LOOP
    PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
      jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', 5000000, 'cuenta_id', u.cuenta),
      jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', 5000000, 'cuenta_id', u.cuenta, 'contraparte_nombre', 'Banco Digital')));
    v_b := public.crear_bolsillo(u.id, 'Ahorro') ->> 'id';
    PERFORM public.mover_a_bolsillo(u.id, v_b, 100000);
    PERFORM public.crear_cdt(u.id, (SELECT id::text FROM public.cdt_definicion WHERE nombre = 'Demo13 CDT 30'), 1000000);
    v_k := public.solicitar_credito(u.id, (SELECT id::text FROM public.credito_producto WHERE nombre = 'Demo13 Libre'), 2000000, 12) ->> 'id';
    PERFORM public.activar_descuento_automatico(u.id, v_k, true);
  END LOOP;
END
$p$;
SELECT public._reloj_actualizar(false, (public.hoy_banco() + 45)::text) ->> 'fecha_actual' AS hoy_del_banco;

-- 2.1 el estado GUARDADO esta atrasado (es lo que muestran Control y las tablas: no incluye el interes ni los cierres pendientes)
SELECT (SELECT count(*) FROM public.bolsillo b JOIN public.cuenta c ON c.id = b.cuenta_id JOIN public.usuario us ON us.id = c.usuario_id WHERE us.cedula LIKE '96000_' OR us.cedula IN ('9600011', '9600012', '9600013')) AS bolsillos,
       (SELECT count(*) FROM public.bolsillo b JOIN public.cuenta c ON c.id = b.cuenta_id JOIN public.usuario us ON us.id = c.usuario_id WHERE us.cedula IN ('9600011', '9600012', '9600013') AND b.ultimo_cobro < public.hoy_banco()) AS con_interes_pendiente,
       (SELECT count(*) FROM public.cdt d JOIN public.cuenta c ON c.id = d.cuenta_id JOIN public.usuario us ON us.id = c.usuario_id WHERE us.cedula IN ('9600011', '9600012', '9600013') AND d.estado = 'ACTIVO') AS cdt_activos_ya_vencidos;

-- 2.2 EL CIERRE (una transaccion y una instantanea del reloj por cuenta; el resultado sale como una fila y como NOTICE)
CALL public.sp_avanzar_todos();

-- 2.3 ahora lo guardado esta al dia
SELECT (SELECT count(*) FROM public.bolsillo b JOIN public.cuenta c ON c.id = b.cuenta_id JOIN public.usuario us ON us.id = c.usuario_id WHERE us.cedula IN ('9600011', '9600012', '9600013') AND b.ultimo_cobro < public.hoy_banco()) AS con_interes_pendiente,
       (SELECT count(*) FROM public.cdt d JOIN public.cuenta c ON c.id = d.cuenta_id JOIN public.usuario us ON us.id = c.usuario_id WHERE us.cedula IN ('9600011', '9600012', '9600013') AND d.estado = 'CERRADO') AS cdt_cerrados,
       (SELECT count(*) FROM public.cuota q JOIN public.credito k ON k.id = q.credito_id JOIN public.cuenta c ON c.id = k.cuenta_id JOIN public.usuario us ON us.id = c.usuario_id WHERE us.cedula IN ('9600011', '9600012', '9600013') AND q.numero = 1 AND q.pagada) AS cuotas_1_cobradas_automaticamente;

-- 2.4 IDEMPOTENTE: la segunda corrida no escribe nada
CALL public.sp_avanzar_todos();

-- 2.5 una entrada de auditoria por corrida, y el informe de integridad
SELECT accion, actor_username, despues ->> 'cuentas' AS cuentas, despues ->> 'con_cambios' AS con_cambios, despues ->> 'grupos' AS grupos FROM audit.evento WHERE accion = 'MANTENIMIENTO_AVANZAR' ORDER BY orden;
CALL public.sp_verificar_integridad();

-- 2.6 LIMPIEZA (obligatoria si se uso sobre banco): vuelve a la fecha real y borra los datos de la demo
SELECT public._reloj_actualizar(true, '') ->> 'usar_fecha_real' AS reloj_real;
DELETE FROM public.usuario WHERE cedula IN ('9600011', '9600012', '9600013');   -- la cascada borra cuentas, productos y asientos de los 3 clientes
DELETE FROM public.credito_producto WHERE nombre = 'Demo13 Libre';
DELETE FROM public.cdt_definicion WHERE nombre = 'Demo13 CDT 30';
-- (los 2 eventos MANTENIMIENTO_AVANZAR quedan en audit.evento: es auditoria y no se borra; por eso la parte 2 va sobre una copia)
