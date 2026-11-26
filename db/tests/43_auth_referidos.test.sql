-- 43_auth_referidos.test.sql · Etapa 4 · referidos y bono: verificacion apagada (bono al registrar) y encendida (bono al verificar), idempotencia,
-- referidor invalido/borrado/bloqueado, monto de `parametro`, nota y contraparte, y los controles de integridad de E4. Una transaccion con ROLLBACK.
BEGIN;

CREATE FUNCTION pg_temp.saldo(p_usuario uuid) RETURNS numeric LANGUAGE sql STABLE AS $f$ SELECT balance::numeric FROM public.cuenta WHERE usuario_id = p_usuario $f$;
CREATE FUNCTION pg_temp.bonos(p_referidor uuid, p_referido uuid) RETURNS bigint LANGUAGE sql STABLE AS $f$
  SELECT count(*) FROM public.transaccion t WHERE t.tipo = 'BONO_REFERIDO' AND t.contenedor = 'CUENTA' AND t.cuenta_id = tests.cta(p_referidor)
     AND t.contraparte_cuenta = (SELECT numero_cuenta FROM public.cuenta WHERE usuario_id = p_referido) $f$;

CREATE TEMP TABLE t_a AS SELECT tests.uid(tests.reg(1)) AS u;                       -- el referidor
CREATE TEMP TABLE t_s0 AS SELECT pg_temp.saldo((SELECT u FROM t_a)) AS s;
SELECT assert_eq('el referidor nace con balance = Σ de sus 5 ingresos y sin bonos', (SELECT (s > 0, (SELECT count(*) FROM public.transaccion WHERE tipo = 'BONO_REFERIDO'))::text FROM t_s0), '(t,0)'::text);

-- ============================================================================
-- 1. Verificacion APAGADA: el bono se paga al completar el registro (spec 7.1)
-- ============================================================================
CREATE TEMP TABLE t_b AS SELECT tests.reg(2, 'María del Pilar', 'Núñez Pérez', (SELECT tests.cod(u) FROM t_a), false) AS r;
CREATE TEMP TABLE t_bu AS SELECT tests.uid(r) AS u FROM t_b;
SELECT assert_eq('el referidor recibio exactamente $50.000 (parametro.bono_referido) por el referido', pg_temp.saldo((SELECT u FROM t_a)), (SELECT s + 50000 FROM t_s0));
SELECT assert_eq('un grupo BONO_REFERIDO en la cuenta del referidor con la cuenta del referido como contraparte', pg_temp.bonos((SELECT u FROM t_a), (SELECT u FROM t_bu)), 1::bigint);
SELECT assert_eq('las 2 patas del bono: CUENTA E (referidor) + RESULTADO E, ambas 50000, nota "Bono por referir a <primer nombre> <primer apellido>", contraparte Banco Digital',
                 (SELECT (count(*), count(DISTINCT grupo_id), bool_and(monto = 50000 AND sentido = 'E' AND cuenta_id = tests.cta((SELECT u FROM t_a))),
                          bool_and(nota = 'Bono por referir a María Núñez' AND contraparte_nombre = 'Banco Digital'), array_agg(contenedor::text ORDER BY contenedor::text))::text
                    FROM public.transaccion WHERE tipo = 'BONO_REFERIDO'),
                 '(2,1,t,t,"{CUENTA,RESULTADO}")'::text);
SELECT assert_eq('el bono se fecha con el ahora de la MISMA instantanea del registro (= creado_en del referido)',
                 (SELECT (DISTINCT_f = u.creado_en)::text FROM (SELECT min(t.fecha) AS DISTINCT_f FROM public.transaccion t WHERE t.tipo = 'BONO_REFERIDO') x, public.usuario u WHERE u.id = (SELECT u FROM t_bu)), 'true'::text);
SELECT assert_eq('referido: referido_por = el referidor, bono marcado como pagado y correoverificado = false (D-E4-18 provisional)',
                 (SELECT (referido_por = (SELECT u FROM t_a), bono_referido_pagado, correoverificado)::text FROM public.usuario WHERE id = (SELECT u FROM t_bu)), '(t,t,f)'::text);
SELECT assert_true('integridad global y de autenticacion en orden tras el bono', (SELECT ok FROM public.v_integridad_global) AND (SELECT bool_and(ok) FROM public.v_integridad_auth));

-- ============================================================================
-- 2. Verificacion ENCENDIDA: el bono se paga al verificar el correo, una sola vez
-- ============================================================================
CREATE TEMP TABLE t_s1 AS SELECT pg_temp.saldo((SELECT u FROM t_a)) AS s;
CREATE TEMP TABLE t_c AS SELECT tests.uid(tests.reg(3, 'Carlos', 'Ruiz', (SELECT tests.cod(u) FROM t_a), true)) AS u;
SELECT assert_eq('con la verificacion activa el registro NO paga: el referidor conserva su saldo y el bono queda pendiente', (pg_temp.saldo((SELECT u FROM t_a)) = (SELECT s FROM t_s1), (SELECT bono_referido_pagado FROM public.usuario WHERE id = (SELECT u FROM t_c)))::text, '(t,f)'::text);
SELECT public.verificar_correo((SELECT u FROM t_c));
SELECT assert_eq('verificar_correo: el correo queda verificado y el referidor recibe $50.000', (pg_temp.saldo((SELECT u FROM t_a)) = (SELECT s + 50000 FROM t_s1), (SELECT correoverificado FROM public.usuario WHERE id = (SELECT u FROM t_c)), (SELECT bono_referido_pagado FROM public.usuario WHERE id = (SELECT u FROM t_c)))::text, '(t,t,t)'::text);
SELECT assert_eq('exactamente UN grupo de bono para ese referido', pg_temp.bonos((SELECT u FROM t_a), (SELECT u FROM t_c)), 1::bigint);
SELECT public.verificar_correo((SELECT u FROM t_c));
SELECT public.verificar_correo((SELECT u FROM t_c));
SELECT assert_eq('verificar_correo es IDEMPOTENTE: tres llamadas, un solo bono y el saldo no vuelve a subir', (pg_temp.bonos((SELECT u FROM t_a), (SELECT u FROM t_c)), pg_temp.saldo((SELECT u FROM t_a)) = (SELECT s + 50000 FROM t_s1))::text, '(1,t)'::text);
SELECT assert_eq('verificar_correo no devuelve datos (void)', (SELECT pg_get_function_result('public.verificar_correo(uuid)'::regprocedure)), 'void'::text);

-- verificacion NULL se trata como ACTIVA: no se paga dinero por una entrada ambigua
CREATE TEMP TABLE t_s2 AS SELECT pg_temp.saldo((SELECT u FROM t_a)) AS s;
CREATE TEMP TABLE t_d AS SELECT tests.uid(public.registrar_usuario('Diana', 'Vega', '800000004', 'reg4@mail.co', '3100000004', '1990-05-17', tests.hash(), true, (SELECT tests.cod(u) FROM t_a), NULL)) AS u;
SELECT assert_eq('p_verificacion_activa NULL = activa: el registro no paga', (pg_temp.saldo((SELECT u FROM t_a)) = (SELECT s FROM t_s2), (SELECT bono_referido_pagado FROM public.usuario WHERE id = (SELECT u FROM t_d)))::text, '(t,f)'::text);

-- ============================================================================
-- 3. Sin referidor, referidor inexistente, ADMIN, borrado, bloqueado
-- ============================================================================
CREATE TEMP TABLE t_e AS SELECT tests.uid(tests.reg(5, 'Elena', 'Soto')) AS u;
CREATE TEMP TABLE t_n0 AS SELECT count(*) AS n FROM public.transaccion WHERE tipo = 'BONO_REFERIDO';
SELECT public.verificar_correo((SELECT u FROM t_e));
SELECT assert_eq('un usuario SIN referidor verifica su correo y no se paga ningun bono', ((SELECT correoverificado FROM public.usuario WHERE id = (SELECT u FROM t_e)), (SELECT count(*) = (SELECT n FROM t_n0) FROM public.transaccion WHERE tipo = 'BONO_REFERIDO'))::text, '(t,t)'::text);

INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol)
VALUES ('adminx9', tests.hash(), 'Admin', 'Uno', '9100001', 'adminx9@mail.co', '3190000001', DATE '1980-01-01', 'ADMIN');
SELECT assert_eq('un codigo de referido de un ADMIN no sirve (solo los CLIENTES refieren)', tests.captura($$SELECT tests.reg(6, 'Fabio', 'Mora', (SELECT codigo_referido::text FROM public.usuario WHERE username = 'adminx9'), false)$$), 'Código de referido inválido'::text);
SELECT assert_eq('el uuid del referidor en MAYUSCULAS tambien se acepta',
                 (SELECT (tests.reg(7, 'Gina', 'Paz', (SELECT upper(tests.cod(u)) FROM t_a), true) ->> 'username') IS NOT NULL), true);

-- referidor BORRADO antes de que el referido verifique: referido_por pasa a NULL (SET NULL) y no hay bono ni error
CREATE TEMP TABLE t_g AS SELECT tests.uid(tests.reg(8, 'Hugo', 'Rey')) AS u;
CREATE TEMP TABLE t_f AS SELECT tests.uid(tests.reg(9, 'Irene', 'Sol', (SELECT tests.cod(u) FROM t_g), true)) AS u;
DELETE FROM public.usuario WHERE id = (SELECT u FROM t_g);
CREATE TEMP TABLE t_n1 AS SELECT count(*) AS n FROM public.transaccion WHERE tipo = 'BONO_REFERIDO';
SELECT assert_eq('referidor borrado: el referido queda sin referidor', (SELECT referido_por IS NULL FROM public.usuario WHERE id = (SELECT u FROM t_f)), true);
SELECT public.verificar_correo((SELECT u FROM t_f));
SELECT assert_eq('...verificar su correo no falla, no paga nada y no marca el bono', ((SELECT correoverificado FROM public.usuario WHERE id = (SELECT u FROM t_f)), (SELECT bono_referido_pagado FROM public.usuario WHERE id = (SELECT u FROM t_f)),
                                                                                  (SELECT count(*) = (SELECT n FROM t_n1) FROM public.transaccion WHERE tipo = 'BONO_REFERIDO'))::text, '(t,f,t)'::text);
SELECT assert_true('la integridad (incluida la conciliacion de la cuenta borrada) sigue en orden', (SELECT ok FROM public.v_integridad_global));

-- referidor BLOQUEADO: D-E4-19 (PROVISIONAL, negocio pendiente) - el bono se paga igual
CREATE TEMP TABLE t_h AS SELECT tests.uid(tests.reg(10, 'Julia', 'Luna')) AS u;
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = (SELECT u FROM t_h);
CREATE TEMP TABLE t_s3 AS SELECT pg_temp.saldo((SELECT u FROM t_h)) AS s;
CREATE TEMP TABLE t_i AS SELECT tests.uid(tests.reg(11, 'Kevin', 'Mar', (SELECT tests.cod(u) FROM t_h), false)) AS u;
SELECT assert_eq('referidor BLOQUEADO: recibe el bono (comportamiento provisional D-E4-19, un unico punto de cambio)', pg_temp.saldo((SELECT u FROM t_h)), (SELECT s + 50000 FROM t_s3));

-- el monto sale de parametro
UPDATE public.parametro SET bono_referido = 12345.67;
CREATE TEMP TABLE t_s4 AS SELECT pg_temp.saldo((SELECT u FROM t_a)) AS s;
CREATE TEMP TABLE t_j AS SELECT tests.uid(tests.reg(12, 'Laura', 'Gil', (SELECT tests.cod(u) FROM t_a), false)) AS u;
SELECT assert_eq('el monto del bono sale de parametro.bono_referido (12345.67)', pg_temp.saldo((SELECT u FROM t_a)), (SELECT s + 12345.67 FROM t_s4));
UPDATE public.parametro SET bono_referido = 50000;

-- ============================================================================
-- 4. _pagar_bono_referido directa: idempotente y sin efectos si no corresponde
-- ============================================================================
CREATE TEMP TABLE t_k AS SELECT tests.uid(tests.reg(13, 'Marco', 'Polo', (SELECT tests.cod(u) FROM t_a), true)) AS u;
CREATE TEMP TABLE t_p1 AS SELECT public._pagar_bono_referido((SELECT u FROM t_k), clock_timestamp()) AS r;
CREATE TEMP TABLE t_p2 AS SELECT public._pagar_bono_referido((SELECT u FROM t_k), clock_timestamp()) AS r;
SELECT assert_eq('_pagar_bono_referido: la 1.a llamada paga (true) y la 2.a no (false)', ((SELECT r FROM t_p1), (SELECT r FROM t_p2))::text, '(t,f)'::text);
SELECT assert_eq('...y hay un solo grupo de bono para ese referido', pg_temp.bonos((SELECT u FROM t_a), (SELECT u FROM t_k)), 1::bigint);
SELECT assert_eq('_pagar_bono_referido: usuario inexistente o sin referidor = false, sin error',
                 (public._pagar_bono_referido(gen_random_uuid(), clock_timestamp()), public._pagar_bono_referido((SELECT u FROM t_a), clock_timestamp()))::text, '(f,f)'::text);
SELECT assert_eq('verificar_correo de un usuario inexistente o NULL: Recurso no encontrado',
                 (tests.captura($$SELECT public.verificar_correo(gen_random_uuid())$$), tests.captura($$SELECT public.verificar_correo(NULL)$$))::text,
                 '("Recurso no encontrado","Recurso no encontrado")'::text);

-- ============================================================================
-- 5. Los controles de integridad de E4 detectan sabotajes (y estan en orden en estado sano)
-- ============================================================================
SELECT assert_true('estado sano: los 2 controles de v_integridad_auth estan en orden', (SELECT count(*) = 2 AND bool_and(ok) FROM public.v_integridad_auth));
SELECT tests.detecta('un BONO duplicado (segundo grupo con la misma contraparte) lo detecta v_integridad_auth y v_integridad_global',
   $s$SELECT public._asentar_grupo(clock_timestamp(), jsonb_build_array(
        jsonb_build_object('tipo','BONO_REFERIDO','contenedor','CUENTA','sentido','E','monto',50000,'cuenta_id',tests.cta((SELECT u FROM t_a)),'contraparte_cuenta',(SELECT numero_cuenta FROM public.cuenta WHERE usuario_id = (SELECT u FROM t_bu))),
        jsonb_build_object('tipo','BONO_REFERIDO','contenedor','RESULTADO','sentido','E','monto',50000,'cuenta_id',tests.cta((SELECT u FROM t_a)))))$s$,
   $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_auth WHERE NOT ok AND control LIKE 'referidos%') AND NOT (SELECT ok FROM public.v_integridad_global)$d$);
SELECT tests.detecta('una bandera de bono en TRUE sin ningun pago la detecta v_integridad_auth',
   $s$UPDATE public.usuario SET bono_referido_pagado = true WHERE id = (SELECT u FROM t_d)$s$,
   $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_auth WHERE NOT ok AND control LIKE 'referidos%')$d$);
SELECT tests.detecta('un bono pagado pero con la bandera en FALSE lo detecta v_integridad_auth',
   $s$UPDATE public.usuario SET bono_referido_pagado = false WHERE id = (SELECT u FROM t_bu)$s$,
   $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_auth WHERE NOT ok AND control LIKE 'referidos%')$d$);
SELECT tests.detecta('un CLIENTE sin cuenta lo detecta v_integridad_auth',
   $s$DELETE FROM public.cuenta WHERE usuario_id = (SELECT u FROM t_e)$s$,
   $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_auth WHERE NOT ok AND control LIKE 'usuarios%')$d$);
SELECT assert_true('tras deshacer los sabotajes todo vuelve a estar en orden', (SELECT ok FROM public.v_integridad_global) AND (SELECT bool_and(ok) FROM public.v_integridad_auth));
SELECT assert_eq('conservacion: cada bono es una pata CUENTA E + una RESULTADO E de igual monto (cuadre) y la suma de bonos = bonos pagados x monto de su momento',
                 (SELECT (count(*) FILTER (WHERE contenedor = 'CUENTA') = count(*) FILTER (WHERE contenedor = 'RESULTADO'))::text FROM public.transaccion WHERE tipo = 'BONO_REFERIDO'), 'true'::text);

ROLLBACK;
