-- 16_integridad_vistas.test.sql · Etapa 2 · las vistas v_integridad_* DETECTAN lo que escape a los triggers y las defensas caidas.
-- Cada "sabotaje" (que solo un superusuario puede hacer: desactivar un trigger, tocar un saldo, conceder un privilegio...) se aplica
-- dentro de tests.detecta(), que comprueba que la vista lo senala y SIEMPRE lo deshace. Una transaccion con ROLLBACK final.
BEGIN;

-- Escenario sano: dos clientes con bolsillo, CDT, credito y una transferencia
SELECT tests.cliente(1); SELECT tests.cliente(2);
SELECT tests.fondear(tests.c(1), 10000);
SELECT tests.bolsillo(1, tests.c(1));
SELECT tests.asentar(tests.pata('BOLSO_INGRESO','CUENTA','S',500,tests.c(1),tests.b(1)), tests.pata('BOLSO_INGRESO','BOLSILLO','E',500,tests.c(1),tests.b(1)));
SELECT tests.cdt(1, tests.c(1), 1000);
SELECT tests.asentar(tests.pata('CDT_CREACION','CUENTA','S',1000,tests.c(1),NULL,tests.d(1)), tests.pata('CDT_CREACION','CDT','E',1000,tests.c(1),NULL,tests.d(1)));
SELECT tests.credito(1, tests.c(1), 3000);
SELECT tests.asentar(tests.pata('CREDITO_DESEMBOLSO','CUENTA','E',3000,tests.c(1),NULL,NULL,tests.k(1)), tests.pata('CREDITO_DESEMBOLSO','CREDITO','E',3000,tests.c(1),NULL,NULL,tests.k(1)));
-- E8: plan de una cuota con el capital del desembolso y diferido evaluado ahora (un ALTER TABLE sobre credito exige que no queden eventos diferidos pendientes)
INSERT INTO public.cuota (credito_id, numero, fecha_vencimiento, valor_cuota_original, valor_cuota, capital_programado, interes_programado) VALUES (tests.k(1), 1, '2026-12-21', 3000, 3000, 3000, 0);
SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota IMMEDIATE;
SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota DEFERRED;
SELECT public._asentar_grupo(now(), tests.g_envio(tests.c(1), tests.c(2), 700));

-- Inserta UNA pata suelta (solo con los triggers de usuario apagados): los saldos se escriben a mano para pasar la CHECK de fila
CREATE FUNCTION pg_temp.suelta(p_grupo uuid, p_tipo text, p_cont text, p_sent text, p_monto numeric, p_cuenta uuid,
                               p_cre uuid DEFAULT NULL, p_fecha timestamptz DEFAULT now(), p_cp text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, saldo_previo, saldo_posterior, cuenta_id, credito_id, contraparte_nombre, contraparte_cuenta)
  VALUES (p_grupo, p_fecha, p_tipo::public.tipo_transaccion, p_cont::public.contenedor_contable, p_sent::public.sentido_asiento, p_monto,
          CASE WHEN p_cont IN ('CUENTA','BOLSILLO','CREDITO') THEN 1000 END,
          CASE WHEN p_cont IN ('CUENTA','BOLSILLO','CREDITO') THEN 1000 + CASE p_sent WHEN 'E' THEN p_monto ELSE -p_monto END END,
          p_cuenta, p_cre, CASE WHEN p_cp IS NOT NULL THEN 'X' END, p_cp) $$;

-- ============================================================================
-- 1. Estado sano
-- ============================================================================
SELECT assert_eq('sano: v_integridad_global ok, sin desvios ni defensas caidas',
                 (SELECT (tests.ok_sin_plan(), contenedores_con_desvio, grupos_con_error, cuentas_con_desvio_i5u, defensas_fallidas, desvio_transferencias)::text FROM public.v_integridad_global), '(t,0,0,0,0,0.00)'::text);
SELECT assert_true('sano: ninguna fila de v_integridad_saldos, grupos ni usuario falla',
                   (SELECT (SELECT bool_and(ok) FROM public.v_integridad_saldos) AND (SELECT bool_and(ok) FROM public.v_integridad_grupos) AND (SELECT bool_and(ok) FROM public.v_integridad_usuario)));
SELECT assert_eq('sano: v_integridad_saldos cubre cuenta x2, bolsillo, CDT (generado e inversion) y credito = 6 filas', (SELECT count(*) FROM public.v_integridad_saldos), 6::bigint);
SELECT assert_eq('sano: I5u por cuenta con diferencia 0', (SELECT count(*) FROM public.v_integridad_usuario WHERE diferencia = 0), 2::bigint);

-- ============================================================================
-- 2. Saldos alterados a mano (el guardia se apaga como superusuario): las vistas los DETECTAN
-- ============================================================================
SELECT tests.detecta('un balance de cuenta alterado (+1) se detecta en I1 y en I5u',
   $s$ALTER TABLE public.cuenta DISABLE TRIGGER trg_zz_proteger_cuenta; UPDATE public.cuenta SET balance = balance + 1 WHERE id = tests.c(1)$s$,
   $d$SELECT (SELECT count(*) FROM public.v_integridad_saldos WHERE NOT ok AND contenedor = 'CUENTA') = 1
          AND (SELECT count(*) FROM public.v_integridad_usuario WHERE NOT ok) = 1
          AND (SELECT diferencia FROM public.v_integridad_saldos WHERE NOT ok) = 1
          AND NOT tests.ok_sin_plan()$d$);
SELECT tests.detecta('dinero creado de la nada en la cuenta (+1.000.000) se detecta',
   $s$ALTER TABLE public.cuenta DISABLE TRIGGER trg_zz_proteger_cuenta; UPDATE public.cuenta SET balance = balance + 1000000 WHERE id = tests.c(2)$s$,
   $d$SELECT (SELECT contenedores_con_desvio FROM public.v_integridad_global) = 1 AND (SELECT cuentas_con_desvio_i5u FROM public.v_integridad_global) = 1$d$);
SELECT tests.detecta('un balance de bolsillo alterado se detecta',
   $s$ALTER TABLE public.bolsillo DISABLE TRIGGER trg_zz_proteger_bolsillo; UPDATE public.bolsillo SET balance = balance - 1$s$,
   $d$SELECT (SELECT count(*) FROM public.v_integridad_saldos WHERE NOT ok AND contenedor = 'BOLSILLO') = 1 AND NOT tests.ok_sin_plan()$d$);
SELECT tests.detecta('un generado_acumulado de CDT alterado se detecta (generado e inversion)',
   $s$ALTER TABLE public.cdt DISABLE TRIGGER trg_zz_proteger_cdt; UPDATE public.cdt SET generado_acumulado = 5$s$,
   $d$SELECT (SELECT count(*) FROM public.v_integridad_saldos WHERE NOT ok AND contenedor IN ('CDT_GENERADO','CDT_INVERSION')) = 2$d$);
SELECT tests.detecta('un capital_pendiente de credito alterado se detecta (I1 y I5u)',
   $s$ALTER TABLE public.credito DISABLE TRIGGER trg_zz_proteger_credito; UPDATE public.credito SET capital_pendiente = 1$s$,
   $d$SELECT (SELECT count(*) FROM public.v_integridad_saldos WHERE NOT ok AND contenedor = 'CREDITO') = 1 AND (SELECT cuentas_con_desvio_i5u FROM public.v_integridad_global) = 1$d$);
SELECT tests.detecta('un CDT cerrado sin devolver el dinero se detecta (inversion esperada 0, libro 1000)',
   $s$ALTER TABLE public.cdt DISABLE TRIGGER trg_zz_proteger_cdt; UPDATE public.cdt SET estado = 'CERRADO'$s$,
   $d$SELECT (SELECT count(*) FROM public.v_integridad_saldos WHERE NOT ok AND contenedor = 'CDT_INVERSION') = 1$d$);

-- ============================================================================
-- 3. Grupos inventados con los triggers del libro apagados: v_integridad_grupos los detecta
-- ============================================================================
SELECT tests.detecta('una pata suelta (grupo de una sola pata) se detecta como ERROR',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER USER; SELECT pg_temp.suelta(gen_random_uuid(), 'DEPOSITO_BANCO', 'CUENTA', 'E', 100, tests.c(1))$s$,
   $d$SELECT (SELECT count(*) FROM public.v_integridad_grupos WHERE estado = 'ERROR') = 1 AND (SELECT grupos_con_error FROM public.v_integridad_global) = 1$d$);
SELECT tests.detecta('un grupo descuadrado (100 contra 99) se detecta',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER USER; SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000001', 'DEPOSITO_BANCO', 'CUENTA', 'E', 100, tests.c(1));
      SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000001', 'DEPOSITO_BANCO', 'RESULTADO', 'E', 99, tests.c(1))$s$,
   $d$SELECT (SELECT estado FROM public.v_integridad_grupos WHERE grupo_id = 'cccccccc-0000-4000-8000-000000000001') = 'ERROR'$d$);
SELECT tests.detecta('un grupo con fechas distintas se detecta',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER USER; SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000002', 'DEPOSITO_BANCO', 'CUENTA', 'E', 100, tests.c(1));
      SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000002', 'DEPOSITO_BANCO', 'RESULTADO', 'E', 100, tests.c(1), NULL, now() + interval '1 day')$s$,
   $d$SELECT (SELECT estado FROM public.v_integridad_grupos WHERE grupo_id = 'cccccccc-0000-4000-8000-000000000002') = 'ERROR'$d$);
SELECT tests.detecta('un grupo cuadrado pero SIN plantilla (tipos mezclados) se detecta',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER USER; SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000003', 'DEPOSITO_BANCO', 'CUENTA', 'E', 100, tests.c(1));
      SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000003', 'BONO_REFERIDO', 'RESULTADO', 'E', 100, tests.c(1))$s$,
   $d$SELECT (SELECT (estado, plantilla IS NULL)::text FROM public.v_integridad_grupos WHERE grupo_id = 'cccccccc-0000-4000-8000-000000000003') = '(ERROR,t)'$d$);
SELECT tests.detecta('dinero entre dos cuentas FUERA de un par ENVIO/RECIBO se detecta',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER USER; SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000004', 'DEPOSITO_BANCO', 'CUENTA', 'E', 100, tests.c(1));
      SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000004', 'DEPOSITO_BANCO', 'RESULTADO', 'E', 100, tests.c(2))$s$,
   $d$SELECT (SELECT estado FROM public.v_integridad_grupos WHERE grupo_id = 'cccccccc-0000-4000-8000-000000000004') = 'ERROR'$d$);
SELECT tests.detecta('un ENVIO que perdio a su RECIBO estando la cuenta contraria VIVA es un ERROR real',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER USER; SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000005', 'ENVIO', 'CUENTA', 'S', 50, tests.c(1), NULL, now(), '4000000002')$s$,
   $d$SELECT (SELECT estado FROM public.v_integridad_grupos WHERE grupo_id = 'cccccccc-0000-4000-8000-000000000005') = 'ERROR'$d$);
SELECT tests.detecta('...mientras que el mismo ENVIO suelto cuya contraparte NO existe es HUERFANO_POR_BORRADO (esperado, ok)',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER USER; SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000006', 'ENVIO', 'CUENTA', 'S', 50, tests.c(1), NULL, now(), '4999999999')$s$,
   $d$SELECT (SELECT (estado, ok)::text FROM public.v_integridad_grupos WHERE grupo_id = 'cccccccc-0000-4000-8000-000000000006') = '(HUERFANO_POR_BORRADO,t)'$d$);
SELECT tests.detecta('un grupo de credito con dos creditos distintos se detecta; uno coherente (CREDITO_MORA, plantilla de E9) es OK',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER USER;
      SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000007', 'CREDITO_MORA', 'CUENTA', 'S', 10, tests.c(1), tests.k(1));
      SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000007', 'CREDITO_MORA', 'RESULTADO', 'S', 10, tests.c(1), tests.k(1));
      SELECT tests.credito(2, tests.c(1), 100);
      SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000008', 'CREDITO_CUOTA', 'CUENTA', 'S', 10, tests.c(1), tests.k(1));
      SELECT pg_temp.suelta('cccccccc-0000-4000-8000-000000000008', 'CREDITO_CUOTA', 'CREDITO', 'S', 10, tests.c(1), tests.k(2))$s$,
   $d$SELECT (SELECT estado FROM public.v_integridad_grupos WHERE grupo_id = 'cccccccc-0000-4000-8000-000000000007') = 'OK'
          AND (SELECT estado FROM public.v_integridad_grupos WHERE grupo_id = 'cccccccc-0000-4000-8000-000000000008') = 'ERROR'$d$);
SELECT tests.detecta('session_replication_role = replica (que apaga los triggers) tampoco evita que los DATOS malos se detecten',
   $s$SET LOCAL session_replication_role = replica; SELECT pg_temp.suelta(gen_random_uuid(), 'DEPOSITO_BANCO', 'CUENTA', 'E', 100, tests.c(1))$s$,
   $d$SELECT (SELECT grupos_con_error FROM public.v_integridad_global) = 1$d$);

-- ============================================================================
-- 4. Defensas caidas: v_integridad_defensas lo senala (y los event triggers lo registran)
-- ============================================================================
SELECT tests.detecta('trigger de aplicar de saldos DESACTIVADO',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER trg_transaccion_b_aplicar$s$,
   $d$SELECT (SELECT (NOT ok, detalle)::text FROM public.v_integridad_defensas WHERE control = 'trigger activo: transaccion.trg_transaccion_b_aplicar') LIKE '(t,"DESACTIVADO%'$d$);
SELECT tests.detecta('trigger de cuadre ELIMINADO', $s$DROP TRIGGER ct_transaccion_cuadre ON public.transaccion$s$,
   $d$SELECT (SELECT detalle FROM public.v_integridad_defensas WHERE control = 'trigger activo: transaccion.ct_transaccion_cuadre') = 'NO EXISTE'$d$);
SELECT tests.detecta('trigger de cuadre recreado NO diferido (se evaluaria fila a fila, no al COMMIT)',
   $s$DROP TRIGGER ct_transaccion_cuadre ON public.transaccion; CREATE TRIGGER ct_transaccion_cuadre AFTER INSERT ON public.transaccion FOR EACH ROW EXECUTE FUNCTION public.ct_transaccion_cuadre()$s$,
   $d$SELECT (SELECT detalle FROM public.v_integridad_defensas WHERE control = 'trigger activo: transaccion.ct_transaccion_cuadre') = 'NO es diferido'$d$);
SELECT tests.detecta('guardia de cuenta DESACTIVADO', $s$ALTER TABLE public.cuenta DISABLE TRIGGER trg_zz_proteger_cuenta$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control = 'trigger activo: cuenta.trg_zz_proteger_cuenta')$d$);
SELECT tests.detecta('TODOS los triggers de usuario del libro desactivados de una vez',
   $s$ALTER TABLE public.transaccion DISABLE TRIGGER USER$s$,
   $d$SELECT (SELECT count(*) FROM public.v_integridad_defensas WHERE NOT ok AND control LIKE 'trigger activo: transaccion.%') = 6$d$);
SELECT tests.detecta('trigger de auditoria del borrado de cuentas desactivado', $s$ALTER TABLE public.cuenta DISABLE TRIGGER trg_cuenta_auditar_borrado$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control = 'trigger activo: cuenta.trg_cuenta_auditar_borrado')$d$);
SELECT tests.detecta('event trigger de DDL desactivado', $s$ALTER EVENT TRIGGER evt_ddl_protegido DISABLE$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control = 'event trigger activo: evt_ddl_protegido')$d$);
SELECT tests.detecta('event trigger de DROP TRIGGER eliminado', $s$DROP EVENT TRIGGER evt_drop_protegido$s$,
   $d$SELECT (SELECT detalle FROM public.v_integridad_defensas WHERE control = 'event trigger activo: evt_drop_protegido') = 'NO EXISTE'$d$);
SELECT tests.detecta('el dueño recupera UPDATE sobre un acumulador', $s$GRANT UPDATE (balance) ON public.cuenta TO banco_owner$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control = 'banco_owner sin UPDATE de acumuladores')$d$);
SELECT tests.detecta('el dueño recupera UPDATE de tabla sobre transaccion', $s$GRANT UPDATE ON public.transaccion TO banco_owner$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'banco_owner sin UPDATE de tabla ni TRUNCATE sobre transaccion%')$d$);
SELECT tests.detecta('el dueño recupera TRUNCATE sobre transaccion', $s$GRANT TRUNCATE ON public.transaccion TO banco_owner$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'banco_owner sin UPDATE de tabla ni TRUNCATE sobre transaccion%')$d$);
SELECT tests.detecta('banco_app recibe UPDATE de un acumulador', $s$GRANT UPDATE (balance) ON public.cuenta TO banco_app$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'roles de acceso%')$d$);
SELECT tests.detecta('banco_ledger recibe SELECT de TABLA completa', $s$GRANT SELECT ON public.cuenta TO banco_ledger$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'banco_ledger: SELECT solo%')$d$);
SELECT tests.detecta('banco_ledger recibe INSERT sobre el libro', $s$GRANT INSERT ON public.transaccion TO banco_ledger$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'banco_ledger: SELECT solo%')$d$);
SELECT tests.detecta('banco_ledger recibe UPDATE de otra columna', $s$GRANT UPDATE (numero_cuenta) ON public.cuenta TO banco_ledger$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control = 'banco_ledger: UPDATE solo en los 4 acumuladores')$d$);
SELECT tests.detecta('banco_app pasa a poder asumir banco_ledger', $s$GRANT banco_ledger TO banco_app$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'nadie (salvo superusuarios)%')$d$);
SELECT tests.detecta('banco_dev pasa a poder asumir banco_owner', $s$GRANT banco_owner TO banco_dev$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'nadie (salvo superusuarios)%')$d$);
SELECT tests.detecta('banco_owner pasa a poder iniciar sesion (LOGIN)', $s$ALTER ROLE banco_owner LOGIN$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'banco_owner y banco_ledger: NOLOGIN%')$d$);
SELECT tests.detecta('banco_ledger pasa a poder iniciar sesion (LOGIN)', $s$ALTER ROLE banco_ledger LOGIN$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'banco_owner y banco_ledger: NOLOGIN%')$d$);
SELECT tests.detecta('un guardia pasa a SECURITY DEFINER (veria al dueño y no a quien actualiza)',
   $s$ALTER FUNCTION public.trg_zz_proteger_cuenta() SECURITY DEFINER$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'guardias: SECURITY INVOKER%')$d$);
SELECT tests.detecta('la funcion de aplicar pasa a SECURITY INVOKER', $s$ALTER FUNCTION public.trg_transaccion_b_aplicar() SECURITY INVOKER$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'trg_transaccion_b_aplicar: SECURITY DEFINER%')$d$);
SELECT tests.detecta('la funcion de aplicar cambia de dueño a banco_owner', $s$ALTER FUNCTION public.trg_transaccion_b_aplicar() OWNER TO banco_owner$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'trg_transaccion_b_aplicar: SECURITY DEFINER%')$d$);
SELECT tests.detecta('_asentar_grupo pasa a ser ejecutable por banco_app', $s$GRANT EXECUTE ON FUNCTION public._asentar_grupo(timestamptz, jsonb) TO banco_app$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'funciones internas sin EXECUTE%')$d$);
SELECT tests.detecta('_asentar_grupo pasa a ser ejecutable por PUBLIC', $s$GRANT EXECUTE ON FUNCTION public._asentar_grupo(timestamptz, jsonb) TO PUBLIC$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'funciones internas sin EXECUTE%')$d$);
SELECT tests.detecta('el trigger de aplicar pasa a ser ejecutable por banco_lector', $s$GRANT EXECUTE ON FUNCTION public.trg_transaccion_b_aplicar() TO banco_lector$s$,
   $d$SELECT (SELECT bool_and(NOT ok) FROM public.v_integridad_defensas WHERE control LIKE 'funciones internas sin EXECUTE%')$d$);

-- Los event triggers dejan RASTRO de los cambios de DDL sobre objetos protegidos
SELECT tests.detecta('ALTER TABLE ... DISABLE TRIGGER queda registrado en audit.evento (accion DDL)',
   $s$ALTER TABLE public.cuenta DISABLE TRIGGER trg_zz_proteger_cuenta$s$,
   $d$SELECT EXISTS (SELECT 1 FROM audit.evento WHERE accion = 'DDL' AND entidad = 'tabla_protegida' AND entidad_id = 'public.cuenta' AND despues ->> 'comando' = 'ALTER TABLE')$d$);
SELECT tests.detecta('DROP TRIGGER sobre una tabla protegida queda registrado en audit.evento',
   $s$DROP TRIGGER trg_transaccion_truncate ON public.transaccion$s$,
   $d$SELECT EXISTS (SELECT 1 FROM audit.evento WHERE accion = 'DDL' AND entidad = 'trigger_protegido' AND entidad_id LIKE 'trg_transaccion_truncate on public.transaccion')$d$);
SELECT tests.detecta('DDL sobre una tabla NO protegida (parametro) no se registra',
   $s$ALTER TABLE public.parametro DISABLE TRIGGER USER$s$,
   $d$SELECT NOT EXISTS (SELECT 1 FROM audit.evento WHERE accion = 'DDL' AND entidad_id = 'public.parametro')$d$);

-- Tras todos los sabotajes (deshechos) el estado vuelve a estar sano
SELECT assert_eq('despues de deshacer todos los sabotajes el estado global esta sano otra vez',
                 (SELECT (tests.ok_sin_plan(), defensas_fallidas)::text FROM public.v_integridad_global), '(t,0)'::text);

ROLLBACK;
