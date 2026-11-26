-- 46_auth_reloj.test.sql · Etapa 4 · el reloj en las funciones de negocio de E4 (regla del responsable de BD: UNA sola _reloj_instantanea() por operacion,
-- reutilizar su resultado y NUNCA now()/current_date/hoy_banco()/_ahora_real() en las funciones de E4).
--   1. Catalogo: el codigo de las 18 funciones se escanea (una llamada exacta en las 2 que necesitan tiempo, cero en el resto, ningun reloj del sistema).
--   2. Dinamico: con _ahora_real() sustituida por un contador (SOLO en banco_test/banco_mut, dentro de esta transaccion) se cuentan las lecturas del reloj.
--   3. Tiempo inyectado: mayoria de edad el dia exacto, frontera de medianoche, 29-feb, 120/121 años, reloj manual, fecha de creado_en/ingresos/bono.
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba sustituye _ahora_real() y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;

BEGIN;

-- ============================================================================
-- 1. Escaneo del catalogo
-- ============================================================================
CREATE TEMP TABLE t_fn AS
  SELECT p.proname::text AS f, p.prosrc AS src, p.proargnames AS args
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname IN ('registrar_usuario', 'obtener_credenciales', 'validar_sesion', 'verificar_correo', 'vista_perfil',
                       '_validar_cliente', '_validar_admin', '_pagar_bono_referido', '_reglas_registro', '_msg_auth', '_nombre_valido', '_norm_texto',
                       '_norm_digitos', '_norm_cedula', '_norm_telefono', '_username_base', '_edad_en', '_es_hash_bcrypt');
SELECT assert_eq('se escanean las 18 funciones de E4', (SELECT count(*) FROM t_fn), 18::bigint);
SELECT assert_eq('NINGUNA funcion de E4 usa now(), current_date/time/timestamp, clock/statement/transaction_timestamp, localtime, timeofday, hoy_banco(), ahora_banco(), _ahora_real() ni pg_sleep',
                 (SELECT string_agg(f, ', ') FROM t_fn WHERE src ~* '(now\s*\(|current_(date|time)|clock_timestamp|statement_timestamp|transaction_timestamp|localtime|timeofday|hoy_banco|ahora_banco|_ahora_real|pg_sleep)'), NULL::text);
SELECT assert_eq('_reloj_instantanea() aparece EXACTAMENTE una vez en registrar_usuario y una en verificar_correo, y NINGUNA en las otras 16',
                 (SELECT array_agg(f || '=' || n ORDER BY f) FROM (SELECT f, (length(src) - length(replace(src, '_reloj_instantanea', ''))) / length('_reloj_instantanea') AS n FROM t_fn) z WHERE n > 0),
                 ARRAY['registrar_usuario=1', 'verificar_correo=1']::text[]);
SELECT assert_true('las internas que necesitan tiempo lo RECIBEN por parametro (no lo consultan): _pagar_bono_referido(p_ahora), _edad_en(p_hoy)',
                   (SELECT bool_and(CASE f WHEN '_pagar_bono_referido' THEN 'p_ahora' = ANY (args) WHEN '_edad_en' THEN 'p_hoy' = ANY (args) ELSE true END) FROM t_fn));
SELECT assert_eq('ninguna funcion de E4 lee la tabla reloj directamente (todo pasa por la instantanea)', (SELECT count(*) FROM t_fn WHERE src ~* '(from|join)\s+(public\.)?reloj'), 0::bigint);

-- ============================================================================
-- 2. Sustitucion del reloj (solo banco_test/banco_mut, dentro de esta transaccion): contador + tiempo que avanza 1 s por lectura
-- ============================================================================
CREATE TEMP SEQUENCE sq_lect;          -- una SECUENCIA no se revierte con una excepcion: cuenta tambien las lecturas de llamadas que fallan
GRANT USAGE, SELECT, UPDATE ON SEQUENCE sq_lect TO banco_owner;
CREATE OR REPLACE FUNCTION public._ahora_real() RETURNS timestamptz LANGUAGE plpgsql VOLATILE SET search_path = public, pg_temp AS $f$
BEGIN
  RETURN current_setting('tests.ahora')::timestamptz + make_interval(secs => nextval('pg_temp.sq_lect')::int);
END $f$;
CREATE FUNCTION pg_temp.fija(p_t text) RETURNS void LANGUAGE sql AS $f$ SELECT set_config('tests.ahora', p_t, true), setval('pg_temp.sq_lect', 1, false)::text $f$;
CREATE FUNCTION pg_temp.lecturas() RETURNS int LANGUAGE sql STABLE AS $f$ SELECT CASE WHEN is_called THEN last_value::int ELSE 0 END FROM pg_temp.sq_lect $f$;

SELECT pg_temp.fija('2026-11-21 10:00:00-05');
SELECT assert_eq('la sustitucion funciona: la primera lectura vale T+1s', public.hoy_banco(), DATE '2026-11-21');
SELECT pg_temp.fija('2026-11-21 10:00:00-05');

-- ---- registro sin referidor: 1 lectura de la instantanea + 1 por cada pata (la regla del libro consulta el reloj en cada pata) ----
CREATE TEMP TABLE t_r1 AS SELECT tests.reg(1) AS r;
CREATE TEMP TABLE t_l1 AS SELECT pg_temp.lecturas() AS n, (SELECT count(*) FROM public.transaccion) AS patas;
SELECT assert_eq('registrar_usuario toma el reloj UNA vez: lecturas = 1 (instantanea) + patas del libro (10), ni una mas', (SELECT n - patas FROM t_l1), 1::bigint);
SELECT assert_eq('...creado_en de usuario y cuenta = la MISMA instantanea (T+1s)',
                 (SELECT (u.creado_en = TIMESTAMPTZ '2026-11-21 10:00:01-05', c.creado_en = u.creado_en)::text FROM public.usuario u JOIN public.cuenta c ON c.usuario_id = u.id), '(t,t)'::text);
SELECT assert_eq('...y los 5 ingresos se anclan en ESA misma instantanea: dentro de [T+1s - 90 dias, T+1s - 60 s]',
                 (SELECT (count(*), bool_and(fecha >= TIMESTAMPTZ '2026-11-21 10:00:01-05' - interval '90 days' AND fecha <= TIMESTAMPTZ '2026-11-21 10:00:01-05' - interval '60 seconds'))::text
                    FROM public.transaccion WHERE contenedor = 'CUENTA'), '(5,t)'::text);

-- ---- una peticion INVALIDA no toma el reloj ----
SELECT pg_temp.fija('2026-11-21 10:00:00-05');
SELECT assert_eq('politica no aceptada: 0 lecturas del reloj (las validaciones sin reloj van antes de la instantanea)', (tests.captura($$SELECT public.registrar_usuario('A','B','1234567','a@b.co','3000000000','1990-01-01',tests.hash(),false,NULL,true)$$), pg_temp.lecturas())::text,
                 '("Debe aceptar la política de datos",0)'::text);
SELECT pg_temp.fija('2026-11-21 10:00:00-05');
SELECT assert_eq('nombre invalido / cedula invalida / hash en claro: 0 lecturas del reloj', (tests.captura($$SELECT public.registrar_usuario('A1','B','1234567','a@b.co','3000000000','1990-01-01',tests.hash(),true,NULL,true)$$),
                  tests.captura($$SELECT public.registrar_usuario('Ana','B','12','a@b.co','3000000000','1990-01-01',tests.hash(),true,NULL,true)$$),
                  tests.captura($$SELECT public.registrar_usuario('Ana','B','1234567','a@b.co','3000000000','1990-01-01','Banco2026',true,NULL,true)$$), pg_temp.lecturas())::text,
                 '("Nombre inválido","Cédula inválida","Datos de registro inválidos",0)'::text);
-- con fecha de nacimiento (necesita 'hoy') SI toma la instantanea, una sola vez
SELECT pg_temp.fija('2026-11-21 10:00:00-05');
SELECT assert_eq('menor de edad: la edad se calcula con la fecha del banco, tras UNA lectura del reloj',
                 (tests.captura($$SELECT public.registrar_usuario('Ana','Bo','1234567','a@b.co','3000000000','2020-01-01',tests.hash(),true,NULL,true)$$), pg_temp.lecturas())::text,
                 '("Debes ser mayor de edad para registrarte",1)'::text);

-- ---- registro CON referidor y verificacion apagada: instantanea + 12 patas; el bono usa el mismo ahora ----
CREATE TEMP TABLE t_ref AS SELECT tests.cod(tests.uid((SELECT r FROM t_r1))) AS cod;
SELECT pg_temp.fija('2026-11-21 11:00:00-05');
CREATE TEMP TABLE t_r2 AS SELECT tests.reg(2, 'Beto', 'Blanco', (SELECT cod FROM t_ref), false) AS r;
CREATE TEMP TABLE t_l2 AS SELECT pg_temp.lecturas() AS n;
SELECT assert_eq('registro con bono: lecturas = 1 instantanea + 12 patas (10 ingresos + 2 del bono) = 13', (SELECT n FROM t_l2), 13);
SELECT assert_eq('el bono se fecha con la MISMA instantanea (T+1s) que creado_en del referido y que sus ingresos',
                 (SELECT (t.fecha = u.creado_en AND u.creado_en = TIMESTAMPTZ '2026-11-21 11:00:01-05')::text FROM public.transaccion t, public.usuario u
                   WHERE t.tipo = 'BONO_REFERIDO' AND t.contenedor = 'CUENTA' AND u.id = tests.uid((SELECT r FROM t_r2))), 'true'::text);

-- ---- verificar_correo: 1 lectura + 2 patas si paga; 0 si ya estaba verificado; inexistente: 0 ----
CREATE TEMP TABLE t_r3 AS SELECT tests.reg(3, 'Carla', 'Ruiz', (SELECT cod FROM t_ref), true) AS r;
SELECT pg_temp.fija('2026-11-21 12:00:00-05');
SELECT public.verificar_correo(tests.uid((SELECT r FROM t_r3)));
CREATE TEMP TABLE t_l3 AS SELECT pg_temp.lecturas() AS n;
SELECT assert_eq('verificar_correo con bono: 1 lectura de la instantanea + 2 patas del bono = 3', (SELECT n FROM t_l3), 3);
SELECT assert_eq('...el bono lleva el ahora de ESA instantanea (T+1s)',
                 (SELECT t.fecha FROM public.transaccion t WHERE t.tipo = 'BONO_REFERIDO' AND t.contenedor = 'CUENTA' AND t.contraparte_cuenta = (SELECT numero_cuenta FROM public.cuenta WHERE usuario_id = tests.uid((SELECT r FROM t_r3)))),
                 TIMESTAMPTZ '2026-11-21 12:00:01-05');
SELECT pg_temp.fija('2026-11-21 13:00:00-05');
SELECT public.verificar_correo(tests.uid((SELECT r FROM t_r3)));
SELECT assert_eq('verificar_correo ya verificado: 0 lecturas del reloj (nada que hacer)', pg_temp.lecturas(), 0);
SELECT pg_temp.fija('2026-11-21 13:00:00-05');
SELECT assert_eq('verificar_correo de un usuario inexistente: 0 lecturas', (tests.captura($$SELECT public.verificar_correo(gen_random_uuid())$$), pg_temp.lecturas())::text, '("Recurso no encontrado",0)'::text);
SELECT pg_temp.fija('2026-11-21 13:00:00-05');
SELECT public.verificar_correo(tests.uid((SELECT r FROM t_r1)));
SELECT assert_eq('verificar_correo sin referidor: UNA lectura (la instantanea) y ningun bono', pg_temp.lecturas(), 1);

-- ---- las funciones de lectura no leen el reloj ----
SELECT pg_temp.fija('2026-11-21 14:00:00-05');
SELECT public.validar_sesion(tests.uid((SELECT r FROM t_r1))); SELECT public.vista_perfil(tests.uid((SELECT r FROM t_r1))); SELECT count(*) FROM public.obtener_credenciales('nadie');
SELECT assert_eq('validar_sesion, vista_perfil y obtener_credenciales: 0 lecturas del reloj', pg_temp.lecturas(), 0);

-- ============================================================================
-- 3. Mayoria de edad con la fecha del BANCO (tiempo inyectado)
-- ============================================================================
CREATE FUNCTION pg_temp.nac(p_t text, p_nac text, p_n int) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.fija(p_t);
  PERFORM public.registrar_usuario('Edad', 'Prueba', (7000000 + p_n)::text, 'edad' || p_n || '@mail.co', (3290000000 + p_n)::text, p_nac, tests.hash(), true, NULL, true);
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM;
END $f$;
SELECT assert_eq('el dia EXACTO de los 18: 2026-11-21 10:00 y nacido 2008-11-21 = mayor de edad', pg_temp.nac('2026-11-21 10:00:00-05', '2008-11-21', 1), 'OK'::text);
SELECT assert_eq('un dia antes de los 18: nacido 2008-11-22 = menor', pg_temp.nac('2026-11-21 10:00:00-05', '2008-11-22', 2), 'Debes ser mayor de edad para registrarte'::text);
SELECT assert_eq('frontera de MEDIANOCHE de Bogota: 23:59:58 (T+1s = 23:59:59) del 21 y nacido 2008-11-22 = menor', pg_temp.nac('2026-11-21 23:59:58-05', '2008-11-22', 3), 'Debes ser mayor de edad para registrarte'::text);
SELECT assert_eq('...pasada la medianoche: 00:00:00 (T+1s = 00:00:01) del 22 y nacido 2008-11-22 = mayor', pg_temp.nac('2026-11-22 00:00:00-05', '2008-11-22', 4), 'OK'::text);
SELECT assert_eq('nacido un 29-feb: el 2026-02-28 aun tiene 17', pg_temp.nac('2026-02-28 12:00:00-05', '2008-02-29', 5), 'Debes ser mayor de edad para registrarte'::text);
SELECT assert_eq('...y el 2026-03-01 ya tiene 18', pg_temp.nac('2026-03-01 00:00:00-05', '2008-02-29', 6), 'OK'::text);
SELECT assert_eq('120 años cumplidos hoy = aceptado', pg_temp.nac('2026-11-21 10:00:00-05', '1906-11-21', 7), 'OK'::text);
SELECT assert_eq('121 años = fecha de nacimiento invalida', pg_temp.nac('2026-11-21 10:00:00-05', '1905-11-21', 8), 'Fecha de nacimiento inválida'::text);
SELECT assert_eq('nacido "hoy" del banco (aun no ha nacido para el calendario del banco si es futuro): 2026-11-22 con T = 2026-11-21 = invalida', pg_temp.nac('2026-11-21 10:00:00-05', '2026-11-22', 9), 'Fecha de nacimiento inválida'::text);
SELECT assert_eq('la edad usa la fecha de BOGOTA: 2026-11-22 04:59:58 UTC (= 23:59:58 del 21 en Bogota; T+1s = 23:59:59) y nacido 2008-11-22 = menor',
                 pg_temp.nac('2026-11-22 04:59:58+00', '2008-11-22', 10), 'Debes ser mayor de edad para registrarte'::text);
SELECT assert_eq('...y 05:00:00 UTC (= 00:00:00 del 22 en Bogota) ya es mayor', pg_temp.nac('2026-11-22 05:00:00+00', '2008-11-22', 11), 'OK'::text);

-- reloj MANUAL: la edad y las fechas son las del reloj del banco, no las del calendario
SELECT public._reloj_actualizar(false, '2027-03-01');
SELECT assert_eq('(reloj manual 2027-03-01) nacido 2009-03-01 = 18 exactos', pg_temp.nac('2026-11-21 10:00:00-05', '2009-03-01', 12), 'OK'::text);
SELECT assert_eq('(reloj manual 2027-03-01) nacido 2009-03-02 = menor', pg_temp.nac('2026-11-21 10:00:00-05', '2009-03-02', 13), 'Debes ser mayor de edad para registrarte'::text);
SELECT assert_eq('(reloj manual) creado_en = fecha manual + hora real (2027-03-01 10:00:01 -05) y los ingresos anteriores a esa instantanea',
                 (SELECT (u.creado_en = TIMESTAMPTZ '2027-03-01 10:00:01-05', (SELECT max(t.fecha) < u.creado_en FROM public.transaccion t WHERE t.cuenta_id = c.id))::text
                    FROM public.usuario u JOIN public.cuenta c ON c.usuario_id = u.id WHERE u.cedula = '7000012'), '(t,t)'::text);
SELECT public._reloj_actualizar(true, '');
SELECT assert_true('integridad global y de autenticacion en orden tras todo (las patas "futuras" del reloj manual son informativas)', (SELECT ok FROM public.v_integridad_global) AND (SELECT bool_and(ok) FROM public.v_integridad_auth));

ROLLBACK;

-- El ROLLBACK restauro la funcion original (la sustitucion no sobrevive)
SELECT assert_eq('tras el ROLLBACK _ahora_real() es otra vez el reloj de pared (clock_timestamp) y VOLATILE',
                 (SELECT (pg_get_functiondef(oid) LIKE '%SELECT clock_timestamp()%' AND provolatile = 'v') FROM pg_proc WHERE oid = 'public._ahora_real()'::regprocedure), true);
SELECT assert_eq('...y hoy_banco() = fecha actual de Bogota', public.hoy_banco(), (now() AT TIME ZONE 'America/Bogota')::date);
