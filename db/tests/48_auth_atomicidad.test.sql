-- 48_auth_atomicidad.test.sql · Etapa 4 · ATOMICIDAD: cualquier fallo durante el registro o la verificacion revierte TODO (usuario, cuenta, ingresos,
-- bono, bandera del bono, correo verificado y los saldos del referidor), incluso fallos POSTERIORES a haber escrito patas del libro.
-- Se inyecta el fallo con un trigger de PRUEBA (solo banco_test; tests.instalar_fallas) en cada punto del recorrido:
--   registrar_usuario con referidor y verificacion apagada escribe 12 patas (5 ingresos x 2 + bono x 2): falla en la pata 1, 2, 3 ... 12,
--   al insertar el usuario, al insertar la cuenta y al marcar la bandera del bono (tras escribir las patas del bono).
--   verificar_correo: falla en la 1.a y 2.a pata del bono, al marcar la bandera y al marcar el correo.
-- Tras cada fallo se compara con una FOTO del estado (usuarios, cuentas, patas, saldos, banderas) y se comprueba que un reintento funciona.
-- (El corte de la conexion a mitad del registro, con conexiones TCP reales, esta en reales/39.)
BEGIN;

SELECT tests.instalar_fallas();
CREATE TEMP TABLE t_a AS SELECT tests.uid(tests.reg(1)) AS u;                        -- referidor
CREATE TEMP TABLE t_cod AS SELECT tests.cod((SELECT u FROM t_a)) AS c;
SELECT assert_eq('(fixture) los disparadores de inyeccion estan instalados y apagados: un registro normal funciona', (SELECT (tests.reg(2) ->> 'username') IS NOT NULL), true);

-- caso(regla, n, referido, verificacion): ejecuta el registro con esa falla y devuelve el mensaje; luego APAGA la falla
CREATE FUNCTION pg_temp.caso(p_regla text, p_n int, p_ref text, p_verif boolean) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v_msg text;
BEGIN
  PERFORM tests.falla(p_regla);
  v_msg := tests.captura(format('SELECT tests.reg(%s, ''Zoe'', ''Vega'', %L, %L)', p_n, p_ref, p_verif));
  PERFORM tests.falla('');
  RETURN v_msg;
END $f$;
CREATE FUNCTION pg_temp.saldo(p_u uuid) RETURNS numeric LANGUAGE sql STABLE AS $f$ SELECT balance::numeric FROM public.cuenta WHERE usuario_id = p_u $f$;

-- ============================================================================
-- 1. Registro con referidor y verificacion APAGADA: fallo en cada una de las 12 patas
-- ============================================================================
DO $do$
DECLARE
  n int; v_h0 text; v_s0 numeric; v_msg text; mal text := ''; mal2 text := ''; v_cod text := (SELECT c FROM t_cod); v_a uuid := (SELECT u FROM t_a);
BEGIN
  FOR n IN 1 .. 12 LOOP
    v_h0 := tests.huella_registro(); v_s0 := pg_temp.saldo(v_a);
    v_msg := pg_temp.caso('tx:' || n, 100 + n, v_cod, false);
    IF v_msg IS DISTINCT FROM 'FALLA INYECTADA en la pata ' || n THEN mal := mal || 'pata ' || n || ' mensaje [' || coalesce(v_msg, 'NULL') || ']; '; END IF;
    IF tests.huella_registro() IS DISTINCT FROM v_h0 THEN mal := mal || 'pata ' || n || ' huella cambio; '; END IF;
    IF pg_temp.saldo(v_a) IS DISTINCT FROM v_s0 THEN mal := mal || 'pata ' || n || ' saldo del referidor cambio; '; END IF;
    IF EXISTS (SELECT 1 FROM public.usuario WHERE cedula = '8' || lpad((100 + n)::text, 8, '0')) THEN mal := mal || 'pata ' || n || ' quedo el usuario; '; END IF;
    IF EXISTS (SELECT 1 FROM public.cuenta c JOIN public.usuario u ON u.id = c.usuario_id WHERE u.correo = 'reg' || (100 + n) || '@mail.co') THEN mal := mal || 'pata ' || n || ' quedo la cuenta; '; END IF;
    IF NOT (SELECT ok FROM public.v_integridad_global) OR EXISTS (SELECT 1 FROM public.v_integridad_auth WHERE NOT ok) THEN mal := mal || 'pata ' || n || ' integridad en error; '; END IF;
    -- reintento SIN falla: debe funcionar y dejar el estado completo (usuario, cuenta, 5 ingresos y bono)
    BEGIN
      PERFORM tests.reg(100 + n, 'Zoe', 'Vega', v_cod, false);
    EXCEPTION WHEN OTHERS THEN mal2 := mal2 || 'reintento ' || n || ' fallo: ' || SQLERRM || '; ';
    END;
    IF (SELECT count(*) FROM public.transaccion t JOIN public.cuenta c ON c.id = t.cuenta_id JOIN public.usuario u ON u.id = c.usuario_id WHERE u.cedula = '8' || lpad((100 + n)::text, 8, '0')) <> 10 THEN mal2 := mal2 || 'reintento ' || n || ' sin sus 10 patas; '; END IF;
    IF pg_temp.saldo(v_a) IS DISTINCT FROM v_s0 + 50000 THEN mal2 := mal2 || 'reintento ' || n || ' bono mal; '; END IF;
  END LOOP;
  PERFORM tests.assert_eq('registro con bono: un fallo en CADA una de las 12 patas (1ª y 2ª de cada ingreso, y las 2 del bono, DESPUES de aplicar su saldo) revierte usuario, cuenta, ingresos y bono; el referidor conserva su saldo exacto', mal, ''::text);
  PERFORM tests.assert_eq('...y tras cada fallo un reintento sin falla registra completo (10 patas propias + 50000 al referidor, una sola vez)', mal2, ''::text);
END $do$;
SELECT assert_true('integridad global y de autenticacion en orden tras los 12 fallos y 12 reintentos', (SELECT ok FROM public.v_integridad_global) AND (SELECT bool_and(ok) FROM public.v_integridad_auth));
SELECT assert_eq('12 referidos con bono pagado = 12 grupos de bono (ninguno duplicado, ninguno perdido)', (SELECT count(*) FROM public.transaccion WHERE tipo = 'BONO_REFERIDO' AND contenedor = 'CUENTA'), 12::bigint);

-- ============================================================================
-- 2. Otros puntos de fallo del registro
-- ============================================================================
CREATE TEMP TABLE t_p AS SELECT tests.huella_registro() AS h, pg_temp.saldo((SELECT u FROM t_a)) AS s;
SELECT assert_eq('fallo al INSERTAR EL USUARIO: no queda nada', (pg_temp.caso('usuario', 200, (SELECT c FROM t_cod), false), tests.huella_registro() = (SELECT h FROM t_p))::text, '("FALLA INYECTADA al insertar el usuario",t)'::text);
SELECT assert_eq('fallo al INSERTAR LA CUENTA (el usuario ya estaba escrito): se revierte tambien el usuario', (pg_temp.caso('cuenta', 201, (SELECT c FROM t_cod), false), tests.huella_registro() = (SELECT h FROM t_p))::text, '("FALLA INYECTADA al insertar la cuenta",t)'::text);
SELECT assert_eq('fallo al MARCAR LA BANDERA del bono, DESPUES de escribir las 12 patas: se revierte todo, incluidas las patas del bono y el saldo del referidor',
                 (pg_temp.caso('bono_flag', 202, (SELECT c FROM t_cod), false), tests.huella_registro() = (SELECT h FROM t_p), pg_temp.saldo((SELECT u FROM t_a)) = (SELECT s FROM t_p))::text,
                 '("FALLA INYECTADA al marcar la bandera del bono",t,t)'::text);
SELECT assert_eq('registro SIN referidor: fallo en la ultima pata de ingreso (10) tambien revierte todo', (pg_temp.caso('tx:10', 203, NULL, true), tests.huella_registro() = (SELECT h FROM t_p))::text, '("FALLA INYECTADA en la pata 10",t)'::text);
SELECT assert_eq('registro SIN referidor: fallo en la pata 5 (mitad del tercer ingreso) revierte todo', (pg_temp.caso('tx:5', 204, NULL, true), tests.huella_registro() = (SELECT h FROM t_p))::text, '("FALLA INYECTADA en la pata 5",t)'::text);
CREATE TEMP TABLE t_205 AS SELECT pg_temp.caso('tx:11', 205, (SELECT c FROM t_cod), true) AS m;
SELECT assert_eq('con verificacion ACTIVA no se escriben patas de bono: la falla en la pata 11 NO ocurre y el registro completa', (SELECT m FROM t_205), NULL::text);
SELECT assert_eq('...el registro completo tiene exactamente 10 patas propias (5 ingresos) y ninguna de bono',
                 (SELECT count(*) FROM public.transaccion t JOIN public.cuenta c ON c.id = t.cuenta_id JOIN public.usuario u ON u.id = c.usuario_id WHERE u.cedula = '800000205'), 10::bigint);

-- ============================================================================
-- 3. verificar_correo: fallo despues de escribir patas del bono
-- ============================================================================
CREATE TEMP TABLE t_v AS SELECT tests.uid(tests.reg(300, 'Vero', 'Gil', (SELECT c FROM t_cod), true)) AS u;
CREATE TEMP TABLE t_pv AS SELECT tests.huella_registro() AS h, pg_temp.saldo((SELECT u FROM t_a)) AS s;
CREATE FUNCTION pg_temp.verifica_con(p_regla text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v_msg text;
BEGIN
  PERFORM tests.falla(p_regla);
  v_msg := tests.captura(format('SELECT public.verificar_correo(%L::uuid)', (SELECT u FROM t_v)));
  PERFORM tests.falla('');
  RETURN v_msg;
END $f$;
SELECT assert_eq('verificar_correo con fallo en la 1.a pata del bono: nada cambia (correo sin verificar, sin bono, saldo igual)',
                 (pg_temp.verifica_con('tx:1'), tests.huella_registro() = (SELECT h FROM t_pv), pg_temp.saldo((SELECT u FROM t_a)) = (SELECT s FROM t_pv),
                  (SELECT (correoverificado, bono_referido_pagado)::text FROM public.usuario WHERE id = (SELECT u FROM t_v)))::text,
                 '("FALLA INYECTADA en la pata 1",t,t,"(f,f)")'::text);
SELECT assert_eq('verificar_correo con fallo en la 2.a pata del bono (la del referidor ya escrita): nada cambia',
                 (pg_temp.verifica_con('tx:2'), tests.huella_registro() = (SELECT h FROM t_pv), pg_temp.saldo((SELECT u FROM t_a)) = (SELECT s FROM t_pv),
                  (SELECT (correoverificado, bono_referido_pagado)::text FROM public.usuario WHERE id = (SELECT u FROM t_v)))::text,
                 '("FALLA INYECTADA en la pata 2",t,t,"(f,f)")'::text);
SELECT assert_eq('verificar_correo con fallo al marcar la bandera, DESPUES de escribir las 2 patas del bono: se revierte todo',
                 (pg_temp.verifica_con('bono_flag'), tests.huella_registro() = (SELECT h FROM t_pv), pg_temp.saldo((SELECT u FROM t_a)) = (SELECT s FROM t_pv),
                  (SELECT (correoverificado, bono_referido_pagado)::text FROM public.usuario WHERE id = (SELECT u FROM t_v)))::text,
                 '("FALLA INYECTADA al marcar la bandera del bono",t,t,"(f,f)")'::text);
SELECT assert_eq('verificar_correo con fallo al marcar el correo: nada cambia',
                 (pg_temp.verifica_con('verificar'), tests.huella_registro() = (SELECT h FROM t_pv), (SELECT (correoverificado, bono_referido_pagado)::text FROM public.usuario WHERE id = (SELECT u FROM t_v)))::text,
                 '("FALLA INYECTADA al verificar el correo",t,"(f,f)")'::text);
SELECT public.verificar_correo((SELECT u FROM t_v));
SELECT assert_eq('tras los 4 fallos, el reintento sin falla verifica y paga el bono UNA sola vez (+50000)',
                 (pg_temp.saldo((SELECT u FROM t_a)) = (SELECT s + 50000 FROM t_pv), (SELECT (correoverificado, bono_referido_pagado)::text FROM public.usuario WHERE id = (SELECT u FROM t_v)),
                  (SELECT count(*) FROM public.transaccion WHERE tipo = 'BONO_REFERIDO' AND contraparte_cuenta = (SELECT numero_cuenta FROM public.cuenta WHERE usuario_id = (SELECT u FROM t_v))))::text,
                 '(t,"(t,t)",1)'::text);

-- ============================================================================
-- 4. Un fallo no contamina a los demas: lo anterior y lo posterior siguen intactos
-- ============================================================================
SELECT assert_eq('los registros hechos antes de los fallos siguen completos: todo CLIENTE tiene su cuenta y cada cuenta sus ingresos', (SELECT count(*) FROM public.v_integridad_auth WHERE NOT ok), 0::bigint);
SELECT assert_eq('las patas de ingreso por cuenta: ninguna cuenta tiene mas ni menos de 5 grupos de ingreso (un fallo no dejo patas sueltas)',
                 (SELECT count(*) FROM (SELECT c.id FROM public.cuenta c LEFT JOIN public.transaccion t ON t.cuenta_id = c.id AND t.tipo = 'INGRESO_SIMULADO' GROUP BY c.id HAVING count(DISTINCT t.grupo_id) <> 5) x), 0::bigint);
SELECT assert_true('v_integridad_global.ok y TODAS las defensas siguen en orden', (SELECT ok FROM public.v_integridad_global));

SELECT tests.quitar_fallas();
SELECT assert_eq('los disparadores de inyeccion se retiraron (esta transaccion no los deja)', (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_zz_falla'), 0::bigint);

ROLLBACK;
