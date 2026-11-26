-- 42_auth_ingresos.test.sql · Etapa 4 · los 5 INGRESO_SIMULADO del registro: montos enteros, fechas DISTINTAS, ASCENDENTES y dentro de los 90 dias
-- previos a la instantanea POR CONSTRUCCION (no por azar), solo por _asentar_grupo, balance = suma, con el reloj real, adelantado y atrasado.
-- Una transaccion con ROLLBACK final.
BEGIN;

CREATE TEMP TABLE t_r AS SELECT (now() AT TIME ZONE 'America/Bogota')::date AS r;

-- verificacion comun: para TODAS las cuentas existentes comprueba el contrato de los ingresos; devuelve '' si todo bien, o el detalle
CREATE FUNCTION pg_temp.revisa(p_n int) RETURNS text LANGUAGE sql STABLE AS $f$
  SELECT concat_ws('; ',
    (SELECT 'cuentas sin exactamente ' || p_n || ' grupos de ingreso: ' || count(*) FROM (
        SELECT c.id FROM public.cuenta c LEFT JOIN public.transaccion t ON t.cuenta_id = c.id AND t.tipo = 'INGRESO_SIMULADO'
         GROUP BY c.id HAVING count(DISTINCT t.grupo_id) <> p_n) x HAVING count(*) > 0),
    (SELECT 'grupos que no son de 2 patas CUENTA+RESULTADO (ambas E, mismo monto): ' || count(*) FROM (
        SELECT grupo_id FROM public.transaccion WHERE tipo = 'INGRESO_SIMULADO' GROUP BY grupo_id
        HAVING count(*) <> 2 OR count(DISTINCT contenedor) <> 2 OR bool_or(sentido <> 'E') OR count(DISTINCT monto) <> 1
               OR NOT bool_and(contenedor IN ('CUENTA', 'RESULTADO'))) x HAVING count(*) > 0),
    (SELECT 'montos no enteros o fuera de [min, max]: ' || count(*) FROM public.transaccion t, public.parametro p
      WHERE t.tipo = 'INGRESO_SIMULADO' AND (t.monto <> trunc(t.monto) OR t.monto < ceil(p.ingreso_simulado_min) OR t.monto > floor(p.ingreso_simulado_max)) HAVING count(*) > 0),
    (SELECT 'fechas repetidas o NO ascendentes (orden de insercion vs fecha): ' || count(*) FROM (
        SELECT t.fecha, lag(t.fecha) OVER (PARTITION BY t.cuenta_id ORDER BY t.orden) AS ant
          FROM public.transaccion t WHERE t.tipo = 'INGRESO_SIMULADO' AND t.contenedor = 'CUENTA') z
      WHERE z.ant IS NOT NULL AND z.fecha <= z.ant HAVING count(*) > 0),
    (SELECT 'fechas fuera de [creado_en - 90 dias, creado_en - 60 s]: ' || count(*) FROM public.transaccion t
        JOIN public.cuenta c ON c.id = t.cuenta_id
       WHERE t.tipo = 'INGRESO_SIMULADO' AND (t.fecha < c.creado_en - interval '90 days' OR t.fecha > c.creado_en - interval '60 seconds') HAVING count(*) > 0),
    (SELECT 'patas con nota/contraparte distintas de las esperadas: ' || count(*) FROM public.transaccion t
       WHERE t.tipo = 'INGRESO_SIMULADO' AND (t.nota IS DISTINCT FROM 'Ingreso simulado' OR t.contraparte_nombre IS DISTINCT FROM 'Banco Digital') HAVING count(*) > 0),
    (SELECT 'cuentas cuyo balance no es la suma de sus ingresos: ' || count(*) FROM public.cuenta c
       WHERE c.balance <> coalesce((SELECT sum(t.monto) FROM public.transaccion t WHERE t.cuenta_id = c.id AND t.contenedor = 'CUENTA'), 0) HAVING count(*) > 0),
    (SELECT 'las 2 patas de un grupo con fechas distintas: ' || count(*) FROM (
        SELECT grupo_id FROM public.transaccion WHERE tipo = 'INGRESO_SIMULADO' GROUP BY grupo_id HAVING count(DISTINCT fecha) <> 1) x HAVING count(*) > 0),
    (SELECT 'integridad global en error' WHERE NOT (SELECT ok FROM public.v_integridad_global)))
$f$;

-- ============================================================================
-- 1. Reloj ATRASADO (banco vacio, D5): el registro se fecha respecto de la instantanea, no del calendario real
-- ============================================================================
SELECT assert_eq('banco vacio al empezar (la clausula D5 permite mover el reloj hacia atras)', (SELECT count(*) FROM public.transaccion), 0::bigint);
SELECT public._reloj_actualizar(false, to_char((SELECT r - 60 FROM t_r), 'YYYY-MM-DD'));
SELECT assert_eq('(reloj manual R-60) registro con el reloj atrasado', (tests.reg(1) ->> 'username') IS NOT NULL, true);
SELECT assert_eq('con el reloj en R-60: creado_en esta en R-60 (fecha de negocio) y los 5 ingresos son anteriores y dentro de 90 dias',
                 (SELECT (c.creado_en AT TIME ZONE 'America/Bogota')::date = (SELECT r - 60 FROM t_r) FROM public.cuenta c), true);
SELECT assert_eq('con el reloj atrasado el contrato de los ingresos se cumple', pg_temp.revisa(5), ''::text);
SELECT assert_true('ningun ingreso quedo fechado en un dia POSTERIOR a la fecha del banco (la regla del libro lo habria rechazado; el mismo dia es valido: el ultimo tramo termina en ahora - margen)',
                   (SELECT max((fecha AT TIME ZONE 'America/Bogota')::date) <= (SELECT r - 60 FROM t_r) FROM public.transaccion));

-- ============================================================================
-- 2. Reloj ADELANTADO: los ingresos siguen siendo anteriores a la instantanea
-- ============================================================================
SELECT public._reloj_actualizar(false, to_char((SELECT r + 30 FROM t_r), 'YYYY-MM-DD'));
SELECT assert_eq('(reloj manual R+30) registro con el reloj adelantado', (tests.reg(2) ->> 'username') IS NOT NULL, true);
SELECT assert_eq('con el reloj en R+30: creado_en esta en R+30 y el contrato de los ingresos se cumple', (SELECT (c.creado_en AT TIME ZONE 'America/Bogota')::date = (SELECT r + 30 FROM t_r) FROM public.cuenta c WHERE c.id = tests.cta((SELECT id FROM public.usuario WHERE cedula = '800000002'))), true);
SELECT assert_eq('(R+30) todas las cuentas cumplen el contrato', pg_temp.revisa(5), ''::text);
SELECT public._reloj_actualizar(true, '');
SELECT assert_true('al volver a real el historial permanece y la integridad sigue en orden (las patas "futuras" son informativas)', (SELECT ok FROM public.v_integridad_global));

-- ============================================================================
-- 3. Reloj real: muchos registros
-- ============================================================================
SELECT assert_eq('120 registros con el reloj real: 120 usernames', (SELECT count(*) FROM (SELECT tests.reg(100 + g, 'Ana', 'Gómez') FROM generate_series(1, 120) g) s), 120::bigint);
SELECT assert_eq('las 122 cuentas cumplen TODO el contrato: exactamente 5 grupos de 2 patas, montos enteros en [10000, 1000000], fechas distintas y ascendentes en los 90 dias previos, nota y contraparte, balance = suma, integridad',
                 pg_temp.revisa(5), ''::text);
SELECT assert_eq('exactamente 5 ingresos por cuenta: 610 grupos y 1220 patas de ingreso',
                 (SELECT (count(DISTINCT grupo_id), count(*))::text FROM public.transaccion WHERE tipo = 'INGRESO_SIMULADO'), '(610,1220)'::text);
SELECT assert_true('los montos son realmente aleatorios: hay mas de 400 valores distintos entre 610 y se usa el rango completo (min < 100000, max > 800000)',
                   (SELECT count(DISTINCT monto) > 400 AND min(monto) < 100000 AND max(monto) > 800000 FROM public.transaccion WHERE tipo = 'INGRESO_SIMULADO' AND contenedor = 'CUENTA'));
SELECT assert_true('las fechas usan toda la ventana: hay ingresos de cada tramo de 18 dias (los 5 estratos)',
                   (SELECT count(DISTINCT least(4, floor(extract(epoch FROM (c.creado_en - t.fecha)) / 1555188)::int)) = 5
                      FROM public.transaccion t JOIN public.cuenta c ON c.id = t.cuenta_id WHERE t.tipo = 'INGRESO_SIMULADO' AND t.contenedor = 'CUENTA'));
SELECT assert_eq('el ingreso k de cada cuenta cae en SU estrato (k = 1..5, de la mas antigua a la mas reciente): la separacion minima entre fechas contiguas es positiva y no hay solapes',
                 (SELECT count(*) FROM (
                    SELECT floor(extract(epoch FROM (t.fecha - (c.creado_en - interval '90 days'))) / 1555188)::int AS estrato,
                           row_number() OVER (PARTITION BY t.cuenta_id ORDER BY t.orden) - 1 AS k
                      FROM public.transaccion t JOIN public.cuenta c ON c.id = t.cuenta_id WHERE t.tipo = 'INGRESO_SIMULADO' AND t.contenedor = 'CUENTA') z
                  WHERE z.estrato <> z.k), 0::bigint);

-- ============================================================================
-- 4. Parametros: cantidad, minimo y maximo salen de `parametro`
-- ============================================================================
-- nuevo(n): registra al cliente n UNA sola vez y devuelve su cuenta (volatil: se guarda en una tabla para no repetirlo)
CREATE FUNCTION pg_temp.nuevo(p int) RETURNS uuid LANGUAGE plpgsql AS $f$ DECLARE r jsonb; BEGIN r := tests.reg(p); RETURN tests.cta(tests.uid(r)); END $f$;

UPDATE public.parametro SET ingresos_simulados_cantidad = 1;
CREATE TEMP TABLE t_n1 AS SELECT pg_temp.nuevo(900) AS cta;
SELECT assert_eq('(n=1) un solo ingreso: 1 grupo de 2 patas', (SELECT (count(DISTINCT grupo_id), count(*))::text FROM public.transaccion t, t_n1 WHERE t.cuenta_id = t_n1.cta), '(1,2)'::text);

UPDATE public.parametro SET ingresos_simulados_cantidad = 0;
CREATE TEMP TABLE t_n0 AS SELECT pg_temp.nuevo(901) AS cta;
SELECT assert_eq('(n=0) la cuenta nace con balance 0 y sin patas', (SELECT (c.balance, (SELECT count(*) FROM public.transaccion t WHERE t.cuenta_id = c.id))::text FROM public.cuenta c, t_n0 WHERE c.id = t_n0.cta), '(0.00,0)'::text);

UPDATE public.parametro SET ingresos_simulados_cantidad = 500;
CREATE TEMP TABLE t_n500 AS SELECT pg_temp.nuevo(902) AS cta;
SELECT assert_eq('(n=500) un registro con 500 ingresos: fechas estrictamente ascendentes, todas distintas y dentro de la ventana (estratos de ~4 horas)', (
    SELECT (count(*), count(DISTINCT q.fecha), bool_and(q.fecha > q.prev) FILTER (WHERE q.prev IS NOT NULL),
            min(q.fecha) >= min(c.creado_en) - interval '90 days' AND max(q.fecha) <= min(c.creado_en) - interval '60 seconds')::text
      FROM (SELECT t.fecha, lag(t.fecha) OVER (ORDER BY t.orden) AS prev FROM public.transaccion t, t_n500 WHERE t.cuenta_id = t_n500.cta AND t.contenedor = 'CUENTA') q,
           public.cuenta c, t_n500 WHERE c.id = t_n500.cta),
    '(500,500,t,t)'::text);

UPDATE public.parametro SET ingresos_simulados_cantidad = 5, ingreso_simulado_min = 12345, ingreso_simulado_max = 12345;
CREATE TEMP TABLE t_n903 AS SELECT pg_temp.nuevo(903) AS cta;
SELECT assert_eq('(min = max = 12345) los 5 ingresos valen 12345', (SELECT (count(*), min(t.monto), max(t.monto))::text FROM public.transaccion t, t_n903 WHERE t.cuenta_id = t_n903.cta AND t.contenedor = 'CUENTA'), '(5,12345.00,12345.00)'::text);

UPDATE public.parametro SET ingreso_simulado_min = 10000.50, ingreso_simulado_max = 10003.40;
CREATE TEMP TABLE t_n904 AS SELECT pg_temp.nuevo(904) AS cta;
SELECT assert_true('(min 10000.50, max 10003.40) montos ENTEROS en [ceil(min), floor(max)] = [10001, 10003]',
                   (SELECT min(t.monto) >= 10001 AND max(t.monto) <= 10003 AND bool_and(t.monto = trunc(t.monto)) FROM public.transaccion t, t_n904 WHERE t.cuenta_id = t_n904.cta AND t.contenedor = 'CUENTA'));

UPDATE public.parametro SET ingreso_simulado_min = 10.50, ingreso_simulado_max = 10.90;
CREATE TEMP TABLE t_antes AS SELECT tests.huella_registro() AS h;
CREATE TEMP TABLE t_msg AS SELECT tests.captura($$SELECT tests.reg(905)$$) AS m;
SELECT assert_eq('(min 10.50, max 10.90: no hay ningun entero) el registro se rechaza con el mensaje de datos invalidos', (SELECT m FROM t_msg), 'Datos de registro inválidos'::text);
SELECT assert_eq('...y no deja NADA', tests.huella_registro(), (SELECT h FROM t_antes));
UPDATE public.parametro SET ingreso_simulado_min = 10000, ingreso_simulado_max = 1000000;

-- ============================================================================
-- 5. Solo por _asentar_grupo: ningun camino alternativo al libro
-- ============================================================================
SELECT assert_true('registrar_usuario NO inserta en transaccion: ni INSERT directo ni nombre de la tabla en su codigo (solo llama a _asentar_grupo)',
                   (SELECT p.prosrc !~* 'insert\s+into\s+public\.transaccion|insert\s+into\s+transaccion|update\s+public\.(cuenta|bolsillo)|update\s+(cuenta|bolsillo)' AND p.prosrc ~ '_asentar_grupo'
                      FROM pg_proc p WHERE p.oid = 'public.registrar_usuario(text,text,text,text,text,text,text,boolean,text,boolean)'::regprocedure));
SELECT assert_true('_pagar_bono_referido tampoco: solo _asentar_grupo y la bandera del usuario',
                   (SELECT p.prosrc !~* 'insert\s+into\s+public\.transaccion|update\s+public\.(cuenta|bolsillo)' AND p.prosrc ~ '_asentar_grupo' FROM pg_proc p WHERE p.proname = '_pagar_bono_referido'));
SELECT assert_eq('tras todo, el contrato de los ingresos sigue cumpliendose para las cuentas con 5 ingresos',
                 (SELECT count(*) FROM (SELECT t.cuenta_id FROM public.transaccion t WHERE t.tipo = 'INGRESO_SIMULADO' AND t.contenedor = 'CUENTA' GROUP BY t.cuenta_id
                                         HAVING count(*) NOT IN (5, 1, 500)) z), 0::bigint);
SELECT assert_true('la integridad global y la de autenticacion siguen en orden', (SELECT ok FROM public.v_integridad_global) AND (SELECT bool_and(ok) FROM public.v_integridad_auth));

ROLLBACK;
