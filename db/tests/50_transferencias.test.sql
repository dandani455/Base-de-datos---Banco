-- 50_transferencias.test.sql · Etapa 5 · hacer_transferencia / nombre_destinatario: validaciones y mensajes exactos, orden, patas del libro (nota, contrapartes,
-- fecha, grupo), origen en bolsillo, saldo exacto, destino bloqueado (D-E5-9 provisional), atomicidad ante fallos en ambas patas, reloj (una instantanea,
-- misma fecha), permisos por rol real. No repite las pruebas exhaustivas del libro (E2). Una transaccion con ROLLBACK final.
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba sustituye _ahora_real() y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

-- clientes deterministas: 1 (emisor, 1000), 2 (destino), 3 (destino que se bloqueara), 4 (ajeno, para el bolsillo ajeno)
SELECT tests.cliente(1); SELECT tests.cliente(2); SELECT tests.cliente(3); SELECT tests.cliente(4);
SELECT tests.fondear(tests.c(1), 1000);
SELECT tests.bolsillo(1, tests.c(1)); SELECT tests.bolsillo(4, tests.c(4));
SELECT tests.app_bolso_ingreso(tests.c(1), tests.b(1), 300);                 -- cuenta 700, bolsillo 300
SELECT tests.fondear(tests.c(4), 50); SELECT tests.app_bolso_ingreso(tests.c(4), tests.b(4), 50);

CREATE FUNCTION pg_temp.tr(p_monto text, p_destino text DEFAULT '4000000002', p_nota text DEFAULT NULL, p_bol text DEFAULT NULL, p_u int DEFAULT 1) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM public.hacer_transferencia(tests.u(p_u), p_destino, p_monto::numeric, p_nota, p_bol);
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM;
END $f$;
CREATE FUNCTION pg_temp.sal(p int) RETURNS numeric LANGUAGE sql VOLATILE AS $f$ SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(p) $f$;

-- ============================================================================
-- 1. Helpers
-- ============================================================================
SELECT assert_eq('_msg_negocio: 5 mensajes del contrato exactos + nota provisional + clave desconocida = NULL',
                 (public._msg_negocio('monto'), public._msg_negocio('destino'), public._msg_negocio('a_si_mismo'), public._msg_negocio('saldo'), public._msg_negocio('recurso'), public._msg_negocio('nota'), public._msg_negocio('x'))::text,
                 '("Monto inválido","Cuenta no encontrada","No puedes enviarte dinero a ti mismo","Saldo insuficiente","Recurso no encontrado","Nota inválida",)'::text);
SELECT assert_eq('_reglas_transferencia: nota_max = 140 (provisional D-E5-8, un solo lugar)', public._reglas_transferencia(), '{"nota_max":140}'::jsonb);
DO $do$
DECLARE r record; mal text := '';
BEGIN
  FOR r IN SELECT * FROM (VALUES ('0.01', true), ('1', true), ('150000.50', true), ('9999999999999.99', true), ('0', false), ('-5', false), ('0.001', false), ('1.234', false),
                                 ('NaN', false), ('Infinity', false), ('-Infinity', false), ('10000000000000', false), ('99999999999999999', false), (NULL, false)) v(m, ok)
  LOOP
    BEGIN PERFORM public._validar_monto(r.m::numeric); IF NOT r.ok THEN mal := mal || coalesce(r.m, 'NULL') || ' aceptado; '; END IF;
    EXCEPTION WHEN OTHERS THEN IF r.ok OR SQLERRM <> 'Monto inválido' THEN mal := mal || coalesce(r.m, 'NULL') || ' [' || SQLERRM || ']; '; END IF; END;
  END LOOP;
  PERFORM tests.assert_eq('_validar_monto: 14 casos (NULL, NaN, infinitos, <=0, mas de 2 decimales y sobre monto_maximo = Monto invalido)', mal, ''::text);
END $do$;

-- ============================================================================
-- 2. Validaciones y mensajes exactos, en orden (cada fallo deja el estado intacto)
-- ============================================================================
CREATE TEMP TABLE t_h0 AS SELECT tests.huella_registro() AS h;
SELECT assert_eq('monto invalido ANTES que destino: con destino inexistente tambien dice Monto invalido', (pg_temp.tr('0', '9999999999'), pg_temp.tr('1.234', 'abc'))::text, '("Monto inválido","Monto inválido")'::text);
SELECT assert_eq('destino: inexistente, mal formado (corto, letras, vacio, NULL) = Cuenta no encontrada',
                 (pg_temp.tr('10', '4999999999'), pg_temp.tr('10', '40000000'), pg_temp.tr('10', 'cuenta-uno'), pg_temp.tr('10', ''), pg_temp.tr('10', NULL))::text,
                 '("Cuenta no encontrada","Cuenta no encontrada","Cuenta no encontrada","Cuenta no encontrada","Cuenta no encontrada")'::text);
SELECT assert_eq('autoenvio = No puedes enviarte dinero a ti mismo (aunque el numero lleve espacios)', (pg_temp.tr('10', '4000000001'), pg_temp.tr('10', ' 40 0000 0001 '))::text,
                 '("No puedes enviarte dinero a ti mismo","No puedes enviarte dinero a ti mismo")'::text);
SELECT assert_eq('autoenvio ANTES que bolsillo y que saldo', pg_temp.tr('99999', '4000000001', NULL, 'no-es-uuid'), 'No puedes enviarte dinero a ti mismo'::text);
SELECT assert_eq('bolsillo: ajeno, inexistente y mal formado = Recurso no encontrado (nunca un error de driver)',
                 (pg_temp.tr('10', '4000000002', NULL, tests.b(4)::text), pg_temp.tr('10', '4000000002', NULL, gen_random_uuid()::text), pg_temp.tr('10', '4000000002', NULL, 'no-es-uuid'))::text,
                 '("Recurso no encontrado","Recurso no encontrado","Recurso no encontrado")'::text);
SELECT assert_eq('nota: 141 caracteres = Nota invalida (provisional); 140 se acepta mas abajo', pg_temp.tr('10', '4000000002', repeat('a', 141)), 'Nota inválida'::text);
SELECT assert_eq('saldo insuficiente (cuenta): un centavo mas del saldo', pg_temp.tr('700.01'), 'Saldo insuficiente'::text);
SELECT assert_eq('saldo insuficiente (bolsillo de 300): 300.01', pg_temp.tr('300.01', '4000000002', NULL, tests.b(1)::text), 'Saldo insuficiente'::text);
SELECT assert_eq('ningun rechazo deja rastro (usuarios, cuentas, patas, saldos)', tests.huella_registro(), (SELECT h FROM t_h0));
SELECT assert_eq('sesion: emisor inexistente, ADMIN y bloqueado', (tests.captura($$SELECT public.hacer_transferencia(gen_random_uuid(), '4000000002', 1, NULL, NULL)$$), tests.captura($$SELECT public.hacer_transferencia(NULL, '4000000002', 1, NULL, NULL)$$))::text,
                 '("Sesión inválida","Sesión inválida")'::text);
INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol)
VALUES ('adminz', tests.hash(), 'Adm', 'In', '9300001', 'adminz@mail.co', '3170000001', DATE '1980-01-01', 'ADMIN');
SELECT assert_eq('un ADMIN no transfiere (Acceso denegado)', tests.captura('SELECT public.hacer_transferencia((SELECT id FROM public.usuario WHERE username = ''adminz''), ''4000000002'', 1, NULL, NULL)'), 'Acceso denegado'::text);
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = tests.u(4);
SELECT assert_eq('un emisor BLOQUEADO recibe el mensaje de bloqueo', tests.captura('SELECT public.hacer_transferencia(' || quote_literal(tests.u(4)) || '::uuid, ''4000000002'', 1, NULL, NULL)'), 'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla'::text);
UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = tests.u(4);

-- ============================================================================
-- 3. Transferencia desde la cuenta: patas, contrapartes, nota, fecha, saldos
-- ============================================================================
CREATE TEMP TABLE t_o AS SELECT public.hacer_transferencia(tests.u(1), '40 0000 0002', 150.50, '  hola    mundo  ', NULL) AS r;
SELECT assert_json_shape('salida {id, fecha}', (SELECT r FROM t_o), '{"id":"string","fecha":"string"}'::jsonb);
SELECT assert_eq('saldos: emisor 700 - 150.50 = 549.50 y destino +150.50', (pg_temp.sal(1), pg_temp.sal(2))::text, '(549.50,150.50)'::text);
SELECT assert_eq('EXACTAMENTE 2 patas en UN grupo (el id devuelto): ENVIO CUENTA S del emisor y RECIBO CUENTA E del destino, mismo monto',
                 (SELECT (count(*), count(DISTINCT grupo_id), min(grupo_id::text) = (SELECT r ->> 'id' FROM t_o), bool_and(monto = 150.50),
                          (SELECT (t.tipo, t.contenedor, t.sentido, t.cuenta_id = tests.c(1))::text FROM public.transaccion t WHERE t.grupo_id = (SELECT (r ->> 'id')::uuid FROM t_o) AND t.tipo = 'ENVIO'),
                          (SELECT (t.tipo, t.contenedor, t.sentido, t.cuenta_id = tests.c(2))::text FROM public.transaccion t WHERE t.grupo_id = (SELECT (r ->> 'id')::uuid FROM t_o) AND t.tipo = 'RECIBO'))::text
                    FROM public.transaccion WHERE grupo_id = (SELECT (r ->> 'id')::uuid FROM t_o)),
                 '(2,1,t,t,"(ENVIO,CUENTA,S,t)","(RECIBO,CUENTA,E,t)")'::text);
SELECT assert_eq('ambas patas: misma fecha (= la de la salida), misma transaccion (tx_id) y la misma nota recortada y colapsada',
                 (SELECT (count(DISTINCT fecha), count(DISTINCT tx_id), min(fecha) = (SELECT (r ->> 'fecha')::timestamptz FROM t_o), min(nota), count(DISTINCT nota))::text FROM public.transaccion WHERE grupo_id = (SELECT (r ->> 'id')::uuid FROM t_o)),
                 '(1,1,t,"hola mundo",1)'::text);
SELECT assert_eq('contrapartes CRUZADAS: el ENVIO lleva nombre y cuenta del destino; el RECIBO, los del emisor (nombre completo)',
                 (SELECT (e.contraparte_nombre, e.contraparte_cuenta, r.contraparte_nombre, r.contraparte_cuenta)::text
                    FROM public.transaccion e JOIN public.transaccion r ON r.grupo_id = e.grupo_id AND r.tipo = 'RECIBO' WHERE e.grupo_id = (SELECT (o.r ->> 'id')::uuid FROM t_o o) AND e.tipo = 'ENVIO'),
                 '("Nombre2 Apellido",4000000002,"Nombre1 Apellido",4000000001)'::text);
CREATE TEMP TABLE t_n AS SELECT pg_temp.tr('0.01', '4.000.000.002', '   ') AS a, pg_temp.tr('0.01', '4000000002', repeat('b', 140)) AS b;
SELECT assert_eq('nota vacia = NULL; nota de 140 caracteres se acepta; monto de 2 decimales; destino con puntos',
                 ((SELECT a FROM t_n), (SELECT b FROM t_n),
                  (SELECT count(*) FROM public.transaccion WHERE tipo = 'ENVIO' AND monto = 0.01 AND nota IS NULL),
                  (SELECT count(*) FROM public.transaccion WHERE tipo = 'ENVIO' AND length(nota) = 140))::text, '(OK,OK,1,1)'::text);
SELECT assert_true('integridad global en orden tras las transferencias', (SELECT ok FROM public.v_integridad_global));
SELECT assert_eq('saldo EXACTO: se puede enviar todo lo que hay (y 1 centavo mas no)', (pg_temp.tr(((SELECT pg_temp.sal(1)) + 0.01)::text), pg_temp.tr((SELECT pg_temp.sal(1))::text), pg_temp.sal(1))::text, '("Saldo insuficiente",OK,0.00)'::text);

-- ============================================================================
-- 4. Desde un bolsillo (ENVIO_BOLSILLO)
-- ============================================================================
SELECT tests.fondear(tests.c(1), 100);
CREATE TEMP TABLE t_pre AS SELECT pg_temp.sal(2) AS d;
CREATE TEMP TABLE t_b AS SELECT public.hacer_transferencia(tests.u(1), '4000000002', 120, 'del bolsillo', tests.b(1)::text) AS r;
SELECT assert_eq('bolsillo: baja 300 - 120 = 180; la cuenta principal NO cambia (100); el destino sube',
                 ((SELECT balance::numeric FROM public.bolsillo WHERE id = tests.b(1)), pg_temp.sal(1), pg_temp.sal(2) - (SELECT d FROM t_pre))::text, '(180.00,100.00,120.00)'::text);
SELECT assert_eq('la pata ENVIO es del contenedor BOLSILLO (con bolsillo_id) y la RECIBO de CUENTA; mismo grupo, fecha y contrapartes',
                 (SELECT (e.contenedor, e.bolsillo_id = tests.b(1), r.contenedor, r.bolsillo_id IS NULL, e.fecha = r.fecha, e.contraparte_cuenta, r.contraparte_cuenta)::text
                    FROM public.transaccion e JOIN public.transaccion r ON r.grupo_id = e.grupo_id AND r.tipo = 'RECIBO' WHERE e.grupo_id = (SELECT (o.r ->> 'id')::uuid FROM t_b o) AND e.tipo = 'ENVIO'),
                 '(BOLSILLO,t,CUENTA,t,t,4000000002,4000000001)'::text);
SELECT assert_eq('bolsillo_origen vacio o en blanco = cuenta principal', (pg_temp.tr('1', '4000000002', NULL, ''), pg_temp.tr('1', '4000000002', NULL, '   '), pg_temp.sal(1))::text, '(OK,OK,98.00)'::text);
SELECT assert_eq('el uuid del bolsillo en MAYUSCULAS tambien funciona', pg_temp.tr('1', '4000000002', NULL, upper(tests.b(1)::text)), 'OK'::text);
SELECT assert_true('integridad global en orden tras mover desde el bolsillo', (SELECT ok FROM public.v_integridad_global));

-- ============================================================================
-- 5. Destino BLOQUEADO (D-E5-9 provisional): puede recibir
-- ============================================================================
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = tests.u(3);
CREATE TEMP TABLE t_s3 AS SELECT pg_temp.sal(3) AS s;
SELECT assert_eq('D-E5-9 (PROVISIONAL, negocio pendiente): una cuenta BLOQUEADA recibe dinero', (pg_temp.tr('5', '4000000003'), pg_temp.sal(3) = (SELECT s + 5 FROM t_s3))::text, '(OK,t)'::text);
UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = tests.u(3);

-- ============================================================================
-- 6. nombre_destinatario
-- ============================================================================
SELECT assert_json_shape('nombre_destinatario devuelve {nombre}', public.nombre_destinatario(tests.u(1), '4000000002'), '{"nombre":"string"}'::jsonb);
SELECT assert_eq('...= nombres + apellidos del dueño (admite espacios y puntos en el numero)', (public.nombre_destinatario(tests.u(1), '4000000002') ->> 'nombre', public.nombre_destinatario(tests.u(1), '40.0000.0003') ->> 'nombre')::text, '("Nombre2 Apellido","Nombre3 Apellido")'::text);
SELECT assert_eq('inexistente, mal formada o NULL = Cuenta no encontrada', (tests.captura($$SELECT public.nombre_destinatario(tests.u(1), '4999999999')$$), tests.captura($$SELECT public.nombre_destinatario(tests.u(1), 'xx')$$), tests.captura($$SELECT public.nombre_destinatario(tests.u(1), NULL)$$))::text,
                 '("Cuenta no encontrada","Cuenta no encontrada","Cuenta no encontrada")'::text);
SELECT assert_eq('exige SESION VIVA (D-E5-10, provisional): sin usuario, admin o bloqueado no se puede consultar',
                 (tests.captura($$SELECT public.nombre_destinatario(gen_random_uuid(), '4000000002')$$),
                  tests.captura('SELECT public.nombre_destinatario((SELECT id FROM public.usuario WHERE username = ''adminz''), ''4000000002'')'))::text, '("Sesión inválida","Acceso denegado")'::text);

-- ============================================================================
-- 7. Atomicidad: fallo en la 1.a y en la 2.a pata (la 2.a ya aplico el debito del emisor): nadie pierde ni gana nada
-- ============================================================================
SELECT tests.instalar_fallas();
CREATE TEMP TABLE t_a0 AS SELECT tests.huella_registro() AS h, pg_temp.sal(1) AS e, pg_temp.sal(2) AS d;
CREATE FUNCTION pg_temp.con_falla(p_regla text, p_bol text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v_msg text;
BEGIN
  PERFORM tests.falla(p_regla);
  v_msg := pg_temp.tr('10', '4000000002', NULL, p_bol);
  PERFORM tests.falla('');
  RETURN v_msg;
END $f$;
SELECT assert_eq('falla en la 1.a pata: nada cambia', (pg_temp.con_falla('tx:1', NULL), tests.huella_registro() = (SELECT h FROM t_a0), pg_temp.sal(1) = (SELECT e FROM t_a0), pg_temp.sal(2) = (SELECT d FROM t_a0))::text, '("FALLA INYECTADA en la pata 1",t,t,t)'::text);
SELECT assert_eq('falla en la 2.a pata (el debito del emisor YA estaba aplicado): se revierte, nadie pierde dinero', (pg_temp.con_falla('tx:2', NULL), tests.huella_registro() = (SELECT h FROM t_a0), pg_temp.sal(1) = (SELECT e FROM t_a0), pg_temp.sal(2) = (SELECT d FROM t_a0))::text, '("FALLA INYECTADA en la pata 2",t,t,t)'::text);
SELECT assert_eq('lo mismo desde un bolsillo (2.a pata)', (pg_temp.con_falla('tx:2', tests.b(1)::text), tests.huella_registro() = (SELECT h FROM t_a0), (SELECT balance::numeric FROM public.bolsillo WHERE id = tests.b(1)))::text, '("FALLA INYECTADA en la pata 2",t,179.00)'::text);
SELECT assert_eq('tras los fallos el reintento funciona y mueve el dinero UNA vez', (pg_temp.tr('10'), pg_temp.sal(1) = (SELECT e - 10 FROM t_a0), pg_temp.sal(2) = (SELECT d + 10 FROM t_a0))::text, '(OK,t,t)'::text);
SELECT tests.quitar_fallas();

-- ============================================================================
-- 8. Ningun camino alternativo al libro; reloj: una instantanea y misma fecha
-- ============================================================================
SELECT assert_true('el codigo de hacer_transferencia no escribe saldos ni el libro (solo _asentar_grupo) y no consulta el reloj del sistema',
                   (SELECT p.prosrc !~* 'insert\s+into|update\s+public\.|update\s+(cuenta|bolsillo)|delete\s+from' AND p.prosrc ~ '_asentar_grupo'
                           AND p.prosrc !~* '(now\s*\(|current_(date|time)|clock_timestamp|statement_timestamp|transaction_timestamp|localtime|hoy_banco|ahora_banco|_ahora_real|pg_sleep)'
                      FROM pg_proc p WHERE p.oid = 'public.hacer_transferencia(uuid,text,numeric,text,text)'::regprocedure));
SELECT assert_eq('_reloj_instantanea() aparece UNA vez en hacer_transferencia y NINGUNA en nombre_destinatario, _validar_monto, _msg_negocio ni _reglas_transferencia',
                 (SELECT array_agg(f || '=' || n ORDER BY f) FROM (SELECT p.proname::text AS f, (length(p.prosrc) - length(replace(p.prosrc, '_reloj_instantanea', ''))) / length('_reloj_instantanea') AS n
                    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('hacer_transferencia', 'nombre_destinatario', '_validar_monto', '_msg_negocio', '_reglas_transferencia')) z WHERE n > 0),
                 ARRAY['hacer_transferencia=1']::text[]);
-- conteo dinamico de lecturas del reloj (sustitucion de _ahora_real solo en banco_test/banco_mut, dentro de esta transaccion)
CREATE TEMP SEQUENCE sq_lect;
GRANT USAGE, SELECT, UPDATE ON SEQUENCE sq_lect TO banco_owner;
CREATE OR REPLACE FUNCTION public._ahora_real() RETURNS timestamptz LANGUAGE plpgsql VOLATILE SET search_path = public, pg_temp AS $f$
BEGIN
  RETURN '2026-11-21 10:00:00-05'::timestamptz + make_interval(secs => nextval('pg_temp.sq_lect')::int);
END $f$;
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT pg_temp.tr('1');
SELECT assert_eq('una transferencia lee el reloj 1 vez (instantanea) + 1 por pata del libro (2) = 3 lecturas',
                 (SELECT CASE WHEN is_called THEN last_value::int ELSE 0 END FROM pg_temp.sq_lect), 3);
SELECT assert_eq('...y ambas patas llevan EXACTAMENTE el ahora de esa instantanea (T+1s)',
                 (SELECT (count(*), count(DISTINCT fecha), min(fecha) = TIMESTAMPTZ '2026-11-21 10:00:01-05')::text FROM public.transaccion WHERE tipo IN ('ENVIO', 'RECIBO') AND fecha = TIMESTAMPTZ '2026-11-21 10:00:01-05'), '(2,1,t)'::text);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT assert_eq('un rechazo de validacion (monto o destino) no lee el reloj', (pg_temp.tr('0'), pg_temp.tr('5', '4999999999'), (SELECT CASE WHEN is_called THEN last_value::int ELSE 0 END FROM pg_temp.sq_lect))::text, '("Monto inválido","Cuenta no encontrada",0)'::text);

-- ============================================================================
-- 9. Permisos por ROL real
-- ============================================================================
SELECT set_config('tests.e', tests.u(1)::text, true);
SELECT assert_ok('banco_app ejecuta hacer_transferencia y nombre_destinatario', $$SET LOCAL ROLE banco_app; SELECT public.nombre_destinatario(current_setting('tests.e')::uuid, '4000000002'); SELECT public.hacer_transferencia(current_setting('tests.e')::uuid, '4000000002', 0.01, NULL, NULL)$$);
SELECT assert_ok('banco_dev (hereda de banco_app) tambien', $$SET LOCAL ROLE banco_dev; SELECT public.nombre_destinatario(current_setting('tests.e')::uuid, '4000000002')$$);
SELECT assert_raises('banco_lector NO ejecuta hacer_transferencia', $$SET LOCAL ROLE banco_lector; SELECT public.hacer_transferencia(current_setting('tests.e')::uuid, '4000000002', 1, NULL, NULL)$$, 'permission denied for function hacer_transferencia', '42501');
SELECT assert_raises('banco_lector NO ejecuta nombre_destinatario', $$SET LOCAL ROLE banco_lector; SELECT public.nombre_destinatario(current_setting('tests.e')::uuid, '4000000002')$$, 'permission denied for function nombre_destinatario', '42501');
DO $do$
DECLARE r text; f text; mal text := ''; v_msg text;
BEGIN
  FOREACH f IN ARRAY ARRAY['_validar_monto(1)', '_msg_negocio(''monto'')', '_reglas_transferencia()'] LOOP
    FOREACH r IN ARRAY ARRAY['banco_app', 'banco_lector', 'banco_dev'] LOOP
      v_msg := coalesce(tests.captura('SET LOCAL ROLE ' || r || '; SELECT public.' || f), ''); RESET ROLE;
      IF v_msg NOT LIKE 'permission denied for function%' THEN mal := mal || r || ':' || f || '; '; END IF;
    END LOOP;
  END LOOP;
  PERFORM tests.assert_eq('los 3 helpers internos dan permission denied a banco_app, banco_lector y banco_dev', mal, ''::text);
END $do$;
SELECT assert_raises('banco_app NO toca saldos ni el libro (permission denied)', $$SET LOCAL ROLE banco_app; UPDATE public.cuenta SET balance = balance + 1$$, NULL, '42501');
SELECT assert_eq('ACL: las 2 publicas solo banco_owner y banco_app; los 3 helpers solo banco_owner',
                 (SELECT (array_agg(DISTINCT pg_get_userbyid(a.grantee)::text) FILTER (WHERE p.proname IN ('hacer_transferencia', 'nombre_destinatario')),
                          array_agg(DISTINCT pg_get_userbyid(a.grantee)::text) FILTER (WHERE p.proname IN ('_validar_monto', '_msg_negocio', '_reglas_transferencia')))::text
                    FROM pg_proc p, aclexplode(p.proacl) a WHERE p.pronamespace = 'public'::regnamespace AND a.privilege_type = 'EXECUTE'),
                 '("{banco_app,banco_owner}",{banco_owner})'::text);
SELECT assert_eq('las 2 publicas son SECURITY DEFINER con search_path fijo y COMMENT; los helpers no',
                 (SELECT (count(*) FILTER (WHERE prosecdef), count(*) FILTER (WHERE NOT prosecdef), bool_and('search_path=public, pg_temp' = ANY (proconfig)), bool_and(obj_description(oid, 'pg_proc') IS NOT NULL))::text
                    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('hacer_transferencia', 'nombre_destinatario', '_validar_monto', '_msg_negocio', '_reglas_transferencia')),
                 '(2,3,t,t)'::text);
SELECT tests.detecta('GRANT EXECUTE de un helper interno a banco_app lo detecta la lista blanca de v_integridad_defensas',
   $s$GRANT EXECUTE ON FUNCTION public._validar_monto(numeric) TO banco_app$s$, $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_defensas WHERE NOT ok)$d$);
SELECT tests.detecta('REVOKE de hacer_transferencia a banco_app (el backend dejaria de funcionar) lo detecta la lista blanca',
   $s$REVOKE EXECUTE ON FUNCTION public.hacer_transferencia(uuid, text, numeric, text, text) FROM banco_app$s$, $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_defensas WHERE NOT ok AND control LIKE 'banco_app ejecuta EXACTAMENTE%')$d$);

ROLLBACK;

SELECT assert_eq('tras el ROLLBACK _ahora_real() es otra vez el reloj de pared (la sustitucion no sobrevive)', (SELECT pg_get_functiondef(oid) LIKE '%SELECT clock_timestamp()%' FROM pg_proc WHERE oid = 'public._ahora_real()'::regprocedure), true);
