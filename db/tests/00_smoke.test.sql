-- 00_smoke.test.sql · Etapa 0 · el propio runner y los helpers funcionan.
-- Si esto falla, ninguna prueba posterior es confiable.

SELECT assert_eq('smoke: 1 = 1', 1, 1);
SELECT assert_eq('assert_eq: texto', 'banco'::text, 'banco'::text);
SELECT assert_eq('assert_eq: NULL = NULL (NULL-safe)', NULL::int, NULL::int);
SELECT assert_true('assert_true: condicion verdadera', 2 + 2 = 4);

-- Los helpers deben FALLAR cuando corresponde (si no, serian aserciones vacias).
SELECT assert_raises('assert_eq falla si los valores difieren',
                     $$SELECT assert_eq('x', 1, 2)$$, 'FAIL: x (esperado=2, actual=1)');
SELECT assert_raises('assert_true falla con FALSE',
                     $$SELECT assert_true('x', false)$$, 'FAIL: x%');
SELECT assert_raises('assert_raises falla si NO hay excepcion',
                     $$SELECT assert_raises('x', 'SELECT 1')$$, 'FAIL: x (se esperaba una excepcion y no ocurrio)');

-- assert_raises con SQLSTATE y con mensaje de negocio (P0001 es el codigo de los errores del banco).
SELECT assert_raises('division por cero es 22012', 'SELECT 1/0', NULL, '22012');
SELECT assert_raises('RAISE EXCEPTION por defecto es P0001 con el mensaje exacto',
                     $q$DO $d$ BEGIN RAISE EXCEPTION 'Saldo insuficiente'; END $d$$q$,
                     'Saldo insuficiente', 'P0001');

-- assert_ok (prueba positiva) y assert_violates (prueba negativa por restriccion concreta).
SELECT assert_ok('assert_ok pasa con una sentencia valida', 'SELECT 1');
SELECT assert_raises('assert_ok falla si la sentencia lanza error',
                     $$SELECT assert_ok('x', 'SELECT 1/0')$$, 'FAIL: x (no debia fallar; SQLSTATE 22012: division by zero)');
SELECT assert_violates('assert_violates reconoce la restriccion exacta',
                       'CREATE TEMP TABLE t_smoke (x int, CONSTRAINT ck_smoke CHECK (x > 0)); INSERT INTO t_smoke VALUES (0)',
                       'ck_smoke', '23514');
SELECT assert_raises('assert_violates falla si la restriccion es otra',
                     $$SELECT assert_violates('x', 'SELECT 1/0', 'ck_cualquiera')$$, 'FAIL: x%');

-- assert_json_shape: forma correcta y forma incorrecta.
SELECT assert_json_shape('json: forma correcta',
                         '{"nombre":"Juan","saldo":10.5,"items":[],"nota":null}'::jsonb,
                         '{"nombre":"string","saldo":"number","items":"array","nota":"string|null"}'::jsonb);
SELECT assert_raises('json: clave faltante',
                     $$SELECT assert_json_shape('x', '{"a":1}'::jsonb, '{"b":"number"}'::jsonb)$$,
                     'FAIL: x (falta la clave "b")');
SELECT assert_raises('json: tipo incorrecto (numero llegando como string)',
                     $$SELECT assert_json_shape('x', '{"saldo":"10.50"}'::jsonb, '{"saldo":"number"}'::jsonb)$$,
                     'FAIL: x (la clave "saldo" es string y se esperaba number)');
