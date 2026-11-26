-- 70_admin_aleatorio.test.sql · Etapa 11 · ~130 operaciones ALEATORIAS que mezclan al ADMIN (ajustes con signo, bloqueos, desbloqueos, BORRADOS, detalles, listas, reloj y tasas) con los CLIENTES (envios,
-- bolsillos, CDT, creditos y pagos) sobre 6 clientes. Al final: todo termina en OK o en un mensaje de negocio, cada accion admin con efecto dejo SU evento, el libro sigue cuadrado (partida doble, I5u,
-- conservacion con los usuarios borrados) y las defensas en orden. Una transaccion con ROLLBACK final; semilla fija (reproducible); solo en banco_test/banco_mut (mueve el reloj).
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 6) n;
SELECT count(tests.fondear(tests.c(n), 3000000 * n)) FROM generate_series(1, 6) n;
INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol) VALUES
  (tests.u(900), 'admin900', 'h', 'Ada', 'Admin', '9000000900', 'a900@t.co', '3000000900', DATE '1980-01-01', 'ADMIN');
UPDATE public.parametro SET tasa_mora_anual = 30;
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES
  (tests.p(901), 'Libre', '', 23.9, 1000000, 30000000, 6, 24), (tests.p(902), 'Vehiculo', '', 18.9, 5000000, 200000000, 12, 120);
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES (tests.p(950), 'CDT 30', 30, 9, 100000), (tests.p(951), 'CDT 90', 90, 10, 100000);
CREATE TEMP TABLE t_ev0 AS SELECT coalesce(max(orden), 0) AS o FROM audit.evento;       -- solo cuentan los eventos de ESTA prueba (la suite puede dejar otros)
SELECT setseed(0.20261125);
CREATE TEMP TABLE t_res (n int, op text, r text);
CREATE TEMP TABLE t_cred (k uuid, usr int);
DO $do$
DECLARE
  i int; u int; u2 int; op int; r text; k uuid; bol text; ks uuid[]; v_tipo text; m numeric;
  adm uuid := tests.u(900);
BEGIN
  FOR i IN 1..130 LOOP
    u := 1 + floor(random() * 6)::int;
    op := floor(random() * 100)::int;
    IF i IN (108, 114, 120, 126) THEN op := 36; END IF;                 -- borrados forzados al final (con productos vivos)
    v_tipo := 'otro';
    BEGIN
      IF op < 16 THEN
        v_tipo := 'ajuste';
        m := round(((random() - 0.35) * 3000000)::numeric, 2);
        PERFORM public.admin_ajustar_balance(adm, CASE floor(random() * 3)::int WHEN 0 THEN tests.u(u)::text WHEN 1 THEN 'cli' || u ELSE (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(u)) END, m, CASE WHEN random() < 0.5 THEN 'aleatorio' END);
      ELSIF op < 24 THEN
        v_tipo := 'bloquear'; u := 5 + floor(random() * 2)::int; PERFORM public.admin_bloquear(adm, tests.u(u)::text);        -- solo 5 y 6 se bloquean/borran: el resto del trafico sigue vivo
      ELSIF op < 34 THEN
        v_tipo := 'desbloquear'; u := 5 + floor(random() * 2)::int; PERFORM public.admin_desbloquear(adm, tests.u(u)::text);
      ELSIF op < 38 AND i > 95 THEN
        v_tipo := 'borrar'; u := 4 + floor(random() * 3)::int; PERFORM public.admin_borrar_usuario(adm, tests.u(u)::text);       -- los borrados al final (se prueban borrando con productos vivos)
      ELSIF op < 54 THEN
        v_tipo := 'envio';
        u2 := 1 + floor(random() * 6)::int; IF u2 = u THEN u2 := 1 + (u % 6); END IF;
        PERFORM public.hacer_transferencia(tests.u(u), (SELECT coalesce((SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(u2)), '4099999999')), round((1000 + random() * 1500000)::numeric, 0), 'aleatorio', NULL);
      ELSIF op < 61 THEN
        v_tipo := 'bolsillo';
        bol := (public.crear_bolsillo(tests.u(u), 'B' || i) ->> 'id');
        PERFORM public.mover_a_bolsillo(tests.u(u), bol, round((10000 + random() * 600000)::numeric, 0));
      ELSIF op < 67 THEN
        v_tipo := 'cdt'; PERFORM public.crear_cdt(tests.u(u), tests.p(950 + floor(random() * 2)::int)::text, round((100000 + random() * 1200000)::numeric, 0));
      ELSIF op < 72 THEN
        v_tipo := 'credito';
        r := public.solicitar_credito(tests.u(u), tests.p(901 + floor(random() * 2)::int)::text, round((5000000 + random() * 8000000)::numeric, 0), 12 + floor(random() * 12)::int) ->> 'id';
        INSERT INTO t_cred VALUES (r::uuid, u);
      ELSIF op < 78 THEN
        v_tipo := 'pagar';
        SELECT array_agg(c.k) INTO ks FROM t_cred c WHERE c.usr = u;
        k := coalesce(ks[1 + floor(random() * greatest(coalesce(array_length(ks, 1), 1), 1))::int], gen_random_uuid());
        PERFORM public.pagar_cuota(tests.u(u), k::text, NULL);
      ELSIF op < 84 THEN
        v_tipo := 'detalle'; PERFORM public.admin_detalle_usuario(adm, tests.u(u)::text);
      ELSIF op < 86 THEN
        v_tipo := 'lista'; PERFORM public.admin_listar_usuarios(adm, CASE WHEN random() < 0.5 THEN NULL ELSE 'nombre' || u END);
      ELSIF op < 90 THEN
        v_tipo := 'reloj'; PERFORM public.admin_set_reloj(adm, false, (public.hoy_banco() + floor(random() * 25)::int)::text);
      ELSIF op < 92 THEN
        v_tipo := 'real'; PERFORM public.admin_set_reloj(adm, true, 'x');
      ELSIF op < 97 THEN
        v_tipo := 'tasas';
        PERFORM public.admin_set_tasa_cdt(adm, tests.p(950 + floor(random() * 2)::int)::text, round((5 + random() * 20)::numeric, 2)::text);
        PERFORM public.admin_set_tasa_credito(adm, tests.p(901 + floor(random() * 2)::int)::text, round((10 + random() * 30)::numeric, 3)::text);
        PERFORM public.admin_set_tasa_mora(adm, CASE WHEN random() < 0.2 THEN '0' ELSE round((20 + random() * 20)::numeric, 1)::text END);
      ELSIF op < 99 THEN
        v_tipo := 'tasa_mala'; PERFORM public.admin_set_tasa_cdt(adm, tests.p(950)::text, CASE floor(random() * 3)::int WHEN 0 THEN '-5' WHEN 1 THEN 'x' ELSE '100.5' END);
      ELSE
        v_tipo := 'get'; PERFORM public.admin_get_tasas(adm); PERFORM public.admin_get_reloj(adm);
      END IF;
      INSERT INTO t_res VALUES (i, v_tipo, 'OK');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO t_res VALUES (i, v_tipo, SQLERRM);
    END;
  END LOOP;
END $do$;

SELECT assert_eq('130 operaciones: TODAS terminan en OK o en un mensaje de negocio permitido (nunca CHECK, FK, unique, driver ni un error interno)',
                 (SELECT coalesce(string_agg(DISTINCT r, ' || '), '') FROM t_res
                   WHERE r <> 'OK' AND r NOT IN ('Monto fuera de rango', 'Plazo fuera de rango', 'Plazo excede el límite de edad', 'Ya tienes un crédito vigente de este producto', 'Recurso no encontrado', 'Saldo insuficiente',
                                                 'Monto por debajo del mínimo del CDT', 'Monto inválido', 'Cuenta no encontrada', 'Sesión inválida', 'Tasa inválida', 'El reloj no puede retroceder',
                                                 'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla')), ''::text);
SELECT assert_true('la corrida es significativa: >= 8 ajustes OK, >= 3 bloqueos, >= 1 borrado, >= 3 cambios de reloj, >= 3 de tasas, >= 10 envios y >= 2 creditos',
                   (SELECT count(*) FILTER (WHERE op = 'ajuste' AND r = 'OK') >= 8 AND count(*) FILTER (WHERE op = 'bloquear' AND r = 'OK') >= 3 AND count(*) FILTER (WHERE op = 'borrar' AND r = 'OK') >= 1
                           AND count(*) FILTER (WHERE op IN ('reloj', 'real') AND r = 'OK') >= 3 AND count(*) FILTER (WHERE op = 'tasas' AND r = 'OK') >= 3 AND count(*) FILTER (WHERE op = 'envio' AND r = 'OK') >= 10
                           AND (SELECT count(*) FROM public.credito) >= 2 FROM t_res));
SELECT assert_eq('cada ajuste, cada borrado y cada accion con efecto dejo SU evento: AJUSTE_ADMIN = ajustes OK, USUARIO_BORRADO = CUENTA_BORRADA = borrados OK',
                 (SELECT ((SELECT count(*) FROM audit.evento WHERE orden > (SELECT o FROM t_ev0) AND accion = 'AJUSTE_ADMIN') - count(*) FILTER (WHERE op = 'ajuste' AND r = 'OK'),
                          (SELECT count(*) FROM audit.evento WHERE orden > (SELECT o FROM t_ev0) AND accion = 'USUARIO_BORRADO') - count(*) FILTER (WHERE op = 'borrar' AND r = 'OK'),
                          (SELECT count(*) FROM audit.evento WHERE orden > (SELECT o FROM t_ev0) AND accion = 'CUENTA_BORRADA') - count(*) FILTER (WHERE op = 'borrar' AND r = 'OK'))::text FROM t_res), '(0,0,0)'::text);
SELECT assert_eq('el bloqueo y el desbloqueo auditan SOLO los cambios reales: los eventos son los cambios de estado observables (<= llamadas OK) y todos llevan al admin como actor',
                 (SELECT ((SELECT count(*) FROM audit.evento WHERE orden > (SELECT o FROM t_ev0) AND accion IN ('USUARIO_BLOQUEADO', 'USUARIO_DESBLOQUEADO')) <= count(*) FILTER (WHERE op IN ('bloquear', 'desbloquear') AND r = 'OK'),
                          (SELECT count(*) FROM audit.evento WHERE orden > (SELECT o FROM t_ev0) AND accion IN ('USUARIO_BLOQUEADO', 'USUARIO_DESBLOQUEADO') AND actor_username <> 'admin900'),
                          (SELECT count(*) FROM audit.evento WHERE orden > (SELECT o FROM t_ev0) AND accion IN ('USUARIO_BORRADO', 'CUENTA_BORRADA', 'AJUSTE_ADMIN', 'TASA_CAMBIO', 'RELOJ_CAMBIO') AND actor_username IS DISTINCT FROM 'admin900'))::text FROM t_res LIMIT 1),
                 '(t,0,0)'::text);
SELECT assert_eq('los borrados no dejaron NADA colgando: ninguna fila de bolsillo, cdt, credito, cuota ni transaccion apunta a una cuenta o credito inexistente (y no quedan usuarios sin su cuenta)',
                 (SELECT (SELECT count(*) FROM public.bolsillo b WHERE NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = b.cuenta_id)) + (SELECT count(*) FROM public.cdt d WHERE NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = d.cuenta_id))
                        + (SELECT count(*) FROM public.credito k WHERE NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = k.cuenta_id)) + (SELECT count(*) FROM public.cuota q WHERE NOT EXISTS (SELECT 1 FROM public.credito k WHERE k.id = q.credito_id))
                        + (SELECT count(*) FROM public.transaccion t WHERE NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = t.cuenta_id))
                        + (SELECT count(*) FROM public.usuario u WHERE u.rol = 'CLIENTE' AND NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.usuario_id = u.id))),
                 0::bigint);
SELECT assert_eq('las tasas quedaron en el dominio: 0 < t <= 100 en todas las definiciones, productos y la mora (si no es NULL)',
                 (SELECT count(*) FROM (SELECT tasa_anual FROM public.cdt_definicion UNION ALL SELECT tasa_anual FROM public.credito_producto UNION ALL SELECT tasa_mora_anual FROM public.parametro) x WHERE tasa_anual IS NOT NULL AND (tasa_anual <= 0 OR tasa_anual > 100)), 0::bigint);
SELECT assert_eq('el estado de ningun administrador cambio (los admin_* solo actuan sobre CLIENTES)', (SELECT (count(*), min(estado::text), max(estado::text))::text FROM public.usuario WHERE rol = 'ADMIN'), '(1,ACTIVO,ACTIVO)'::text);
SELECT assert_eq('estado global: partida doble, I5u por cuenta, conservacion entre clientes INCLUIDOS los borrados, defensas y planes en orden',
                 (SELECT (ok, contenedores_con_desvio, grupos_con_error, cuentas_con_desvio_i5u, defensas_fallidas, desvio_transferencias, creditos_con_plan_incoherente, grupos_credito_sin_plantilla)::text FROM public.v_integridad_global),
                 '(t,0,0,0,0,0.00,0,0)'::text);
ROLLBACK;
