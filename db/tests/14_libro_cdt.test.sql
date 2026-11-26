-- 14_libro_cdt.test.sql · Etapa 2 · invariantes del CDT (trigger diferido ct_cdt_inversion), sin fijar ninguna formula de interes:
--   inversion en el libro (patas CDT) = monto + generado mientras ACTIVO, 0 al cerrarse; generado = suma de patas INTERES_CDT.
-- La evaluacion diferida se fuerza con SET CONSTRAINTS ... IMMEDIATE (equivale al COMMIT). Una transaccion con ROLLBACK final.
BEGIN;

SELECT tests.cliente(1);
SELECT tests.fondear(tests.c(1), 20000);

CREATE FUNCTION pg_temp.flush() RETURNS void LANGUAGE plpgsql AS $$ BEGIN SET CONSTRAINTS public.ct_transaccion_cuadre, public.ct_transaccion_cdt, public.ct_cdt_inversion IMMEDIATE; SET CONSTRAINTS public.ct_transaccion_cuadre, public.ct_transaccion_cdt, public.ct_cdt_inversion DEFERRED; END $$;

-- ============================================================================
-- 1. Apertura
-- ============================================================================
SELECT assert_raises('un CDT creado SIN su pata de apertura es incoherente (inversion 0, esperada 1000)',
                     $$SELECT tests.cdt(1, tests.c(1), 1000); SELECT pg_temp.flush()$$, '%CDT%incoherente%inversi%n en el libro=0%esperada=1000.00%', 'P0001');
SELECT tests.cdt(2, tests.c(1), 1000);
SELECT assert_ok('con su grupo CDT_CREACION el CDT es coherente',
                 $$SELECT tests.asentar(tests.pata('CDT_CREACION','CUENTA','S',1000,tests.c(1),NULL,tests.d(2)), tests.pata('CDT_CREACION','CDT','E',1000,tests.c(1),NULL,tests.d(2)))$$);
SELECT assert_raises('apertura por un monto distinto al del CDT (900 de 1000)',
                     $$SELECT tests.cdt(3, tests.c(1), 1000);
                       SELECT tests.asentar(tests.pata('CDT_CREACION','CUENTA','S',900,tests.c(1),NULL,tests.d(3)), tests.pata('CDT_CREACION','CDT','E',900,tests.c(1),NULL,tests.d(3)))$$,
                     '%incoherente%', 'P0001');
SELECT assert_raises('apertura duplicada (el libro ya tiene 1000 y se agregan otros 1000)',
                     $$SELECT tests.asentar(tests.pata('CDT_CREACION','CUENTA','S',1000,tests.c(1),NULL,tests.d(2)), tests.pata('CDT_CREACION','CDT','E',1000,tests.c(1),NULL,tests.d(2)))$$,
                     '%incoherente%', 'P0001');

-- ============================================================================
-- 2. Interes: solo por patas INTERES_CDT; el acumulador lo mueve el libro
-- ============================================================================
SELECT assert_ok('INTERES_CDT 40: generado_acumulado 40 y la inversion vale 1040',
                 $$SELECT tests.asentar(tests.pata('INTERES_CDT','CDT','E',40,tests.c(1),NULL,tests.d(2)), tests.pata('INTERES_CDT','RESULTADO','E',40,tests.c(1),NULL,tests.d(2)))$$);
SELECT assert_eq('generado 40.00', (SELECT generado_acumulado::numeric FROM public.cdt WHERE id = tests.d(2)), 40::numeric);
SELECT assert_eq('la vista confirma I1 para el CDT (generado e inversion)',
                 (SELECT bool_and(ok) FROM public.v_integridad_saldos WHERE contenedor_id = tests.d(2)), true);
SELECT assert_raises('generado_acumulado manipulado a mano: rechazado por el guardia',
                     $$UPDATE public.cdt SET generado_acumulado = 9999 WHERE id = tests.d(2)$$, '%solo lo modifica el libro%', 'P0001');
SELECT assert_raises('interes sin su contrapartida RESULTADO (una pata): no cuadra',
                     $$SELECT tests.asentar(tests.pata('INTERES_CDT','CDT','E',10,tests.c(1),NULL,tests.d(2)), tests.pata('INTERES_CDT','RESULTADO','E',9,tests.c(1),NULL,tests.d(2)))$$, '%descuadrado%', 'P0001');

-- ============================================================================
-- 3. Vencimiento: devuelve EXACTAMENTE monto + generado y cierra el CDT
-- ============================================================================
SELECT assert_raises('vencimiento SIN cerrar el CDT (estado sigue ACTIVO): la inversion deberia seguir siendo 1040 y es 0',
                     $$SELECT tests.asentar(tests.pata('CDT_VENCIMIENTO','CDT','S',1040,tests.c(1),NULL,tests.d(2)), tests.pata('CDT_VENCIMIENTO','CUENTA','E',1040,tests.c(1),NULL,tests.d(2)))$$,
                     '%incoherente%estado ACTIVO%', 'P0001');
SELECT assert_raises('vencimiento devolviendo solo el principal (1000) cuando hay 40 de intereses',
                     $$UPDATE public.cdt SET estado = 'CERRADO' WHERE id = tests.d(2);
                       SELECT tests.asentar(tests.pata('CDT_VENCIMIENTO','CDT','S',1000,tests.c(1),NULL,tests.d(2)), tests.pata('CDT_VENCIMIENTO','CUENTA','E',1000,tests.c(1),NULL,tests.d(2)))$$,
                     '%incoherente%estado CERRADO%', 'P0001');
SELECT assert_raises('vencimiento devolviendo de mas (1100)',
                     $$UPDATE public.cdt SET estado = 'CERRADO' WHERE id = tests.d(2);
                       SELECT tests.asentar(tests.pata('CDT_VENCIMIENTO','CDT','S',1100,tests.c(1),NULL,tests.d(2)), tests.pata('CDT_VENCIMIENTO','CUENTA','E',1100,tests.c(1),NULL,tests.d(2)))$$,
                     '%incoherente%', 'P0001');
SELECT assert_raises('cerrar el CDT sin devolver nada (estado CERRADO con la inversion aun en el libro)',
                     $$UPDATE public.cdt SET estado = 'CERRADO' WHERE id = tests.d(2); SELECT pg_temp.flush()$$, '%incoherente%estado CERRADO%', 'P0001');
SELECT assert_eq('tras los rechazos el CDT sigue ACTIVO y con el libro intacto',
                 (SELECT (estado::text, generado_acumulado::numeric)::text FROM public.cdt WHERE id = tests.d(2)), '(ACTIVO,40.00)'::text);
UPDATE public.cdt SET estado = 'CERRADO' WHERE id = tests.d(2);
SELECT assert_ok('vencimiento correcto: CERRADO y devuelve 1040 (monto + generado)',
                 $$SELECT tests.asentar(tests.pata('CDT_VENCIMIENTO','CDT','S',1040,tests.c(1),NULL,tests.d(2)), tests.pata('CDT_VENCIMIENTO','CUENTA','E',1040,tests.c(1),NULL,tests.d(2)))$$);
SELECT assert_eq('cuenta 20000 - 1000 + 1040 = 20040.00', (SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(1)), 20040::numeric);
SELECT assert_raises('un CDT ya cerrado no admite mas interes (la inversion dejaria de ser 0)',
                     $$SELECT tests.asentar(tests.pata('INTERES_CDT','CDT','E',5,tests.c(1),NULL,tests.d(2)), tests.pata('INTERES_CDT','RESULTADO','E',5,tests.c(1),NULL,tests.d(2)))$$, '%incoherente%', 'P0001');
SELECT assert_raises('un CDT cerrado no se reabre', $$UPDATE public.cdt SET estado = 'ACTIVO' WHERE id = tests.d(2)$$, '%no se reabre%', 'P0001');

-- ============================================================================
-- 4. Propiedad
-- ============================================================================
SELECT tests.cliente(2);
SELECT assert_raises('una pata CDT de otra cuenta se rechaza',
                     $$SELECT tests.asentar(tests.pata('INTERES_CDT','CDT','E',5,tests.c(2),NULL,tests.d(2)), tests.pata('INTERES_CDT','RESULTADO','E',5,tests.c(2),NULL,tests.d(2)))$$, '%no pertenece a la cuenta%', 'P0001');
SELECT assert_true('las vistas de integridad siguen en orden', tests.ok_sin_plan());

ROLLBACK;
