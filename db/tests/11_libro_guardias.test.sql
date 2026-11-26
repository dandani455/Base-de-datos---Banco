-- 11_libro_guardias.test.sql · Etapa 2 · ningun saldo se modifica directamente: guardias de acumuladores, columnas
-- inmutables, ciclo de vida y permisos del dueño. Corre como superusuario en banco_test (los roles se asumen con
-- SET LOCAL ROLE). Una sola transaccion con ROLLBACK final.
BEGIN;

SELECT tests.cliente(1);
SELECT tests.bolsillo(1, tests.c(1));
SELECT tests.credito(1, tests.c(1), 5000);
SELECT tests.fondear(tests.c(1), 1500);
-- un CDT sin su pata de apertura es incoherente: se crea CON su grupo CDT_CREACION (asi lo hara la funcion de negocio)
SELECT tests.cdt(1, tests.c(1), 1000);
SELECT tests.asentar(tests.pata('CDT_CREACION','CUENTA','S',1000,tests.c(1),NULL,tests.d(1)), tests.pata('CDT_CREACION','CDT','E',1000,tests.c(1),NULL,tests.d(1)));

-- ============================================================================
-- 1. Un contenedor nace con saldo cero (ningun saldo "de la nada")
-- ============================================================================
SELECT assert_raises('cuenta con balance inicial > 0', $$INSERT INTO public.cuenta (usuario_id, numero_cuenta, balance) VALUES (tests.u(1), '4099999999', 10)$$,
                     '%nace con balance 0%', 'P0001');
SELECT assert_raises('bolsillo con balance inicial > 0', $$INSERT INTO public.bolsillo (cuenta_id, nombre, balance, ultimo_cobro) VALUES (tests.c(1), 'X', 5, '2026-11-21')$$,
                     '%nace con balance 0%', 'P0001');
SELECT assert_raises('CDT con generado_acumulado inicial > 0',
                     $$INSERT INTO public.cdt (cuenta_id, nombre, monto, tasa_anual, plazo_dias, fecha_inicio, fecha_fin, generado_acumulado, ultimo_cobro)
                       VALUES (tests.c(1), 'X', 100, 10, 90, '2026-11-01', DATE '2026-11-01' + 90, 7, '2026-11-01')$$, '%nace con generado_acumulado 0%', 'P0001');
SELECT assert_raises('credito con capital_pendiente inicial > 0 (lo sube CREDITO_DESEMBOLSO)',
                     $$INSERT INTO public.credito (cuenta_id, producto_id, monto, tasa_anual, plazo_meses, fecha_desembolso, capital_pendiente, fecha_interes)
                       VALUES (tests.c(1), tests.p(1), 100, 20, 12, '2026-11-21', 100, '2026-11-21')$$, '%capital_pendiente 0%', 'P0001');

-- ============================================================================
-- 2. UPDATE directo de cada acumulador: rechazado para dueño, banco_ledger, superusuario, app, lector y dev
-- ============================================================================
-- superusuario: tiene todos los privilegios, pero el guardia lo frena
SELECT assert_raises('superusuario: UPDATE cuenta.balance', $$UPDATE public.cuenta SET balance = balance + 1000$$, '%cuenta.balance solo lo modifica el libro%', 'P0001');
SELECT assert_raises('superusuario: UPDATE bolsillo.balance', $$UPDATE public.bolsillo SET balance = balance + 1$$, '%bolsillo.balance solo lo modifica el libro%', 'P0001');
SELECT assert_raises('superusuario: UPDATE cdt.generado_acumulado', $$UPDATE public.cdt SET generado_acumulado = generado_acumulado + 1$$, '%generado_acumulado solo lo modifica el libro%', 'P0001');
SELECT assert_raises('superusuario: UPDATE credito.capital_pendiente', $$UPDATE public.credito SET capital_pendiente = capital_pendiente + 1$$, '%capital_pendiente solo lo modifica el libro%', 'P0001');
-- banco_ledger: tiene el privilegio de columna, pero a profundidad 1 el guardia lo frena
SELECT assert_raises('banco_ledger fuera del trigger: UPDATE cuenta.balance', $$SET LOCAL ROLE banco_ledger; UPDATE public.cuenta SET balance = balance + 1000$$, '%cuenta.balance solo lo modifica el libro%', 'P0001');
SELECT assert_raises('banco_ledger fuera del trigger: UPDATE bolsillo.balance', $$SET LOCAL ROLE banco_ledger; UPDATE public.bolsillo SET balance = balance + 1$$, '%bolsillo.balance solo lo modifica el libro%', 'P0001');
SELECT assert_raises('banco_ledger fuera del trigger: UPDATE cdt.generado_acumulado', $$SET LOCAL ROLE banco_ledger; UPDATE public.cdt SET generado_acumulado = generado_acumulado + 1$$, '%generado_acumulado solo lo modifica el libro%', 'P0001');
SELECT assert_raises('banco_ledger fuera del trigger: UPDATE credito.capital_pendiente', $$SET LOCAL ROLE banco_ledger; UPDATE public.credito SET capital_pendiente = capital_pendiente + 1$$, '%capital_pendiente solo lo modifica el libro%', 'P0001');
-- banco_owner: ni siquiera tiene el privilegio (capa 1)
SELECT assert_raises('banco_owner: UPDATE cuenta.balance (sin privilegio)', $$SET LOCAL ROLE banco_owner; UPDATE public.cuenta SET balance = balance + 1000$$, 'permission denied for table cuenta', '42501');
SELECT assert_raises('banco_owner: UPDATE bolsillo.balance (sin privilegio)', $$SET LOCAL ROLE banco_owner; UPDATE public.bolsillo SET balance = balance + 1$$, 'permission denied for table bolsillo', '42501');
SELECT assert_raises('banco_owner: UPDATE cdt.generado_acumulado (sin privilegio)', $$SET LOCAL ROLE banco_owner; UPDATE public.cdt SET generado_acumulado = 5$$, 'permission denied for table cdt', '42501');
SELECT assert_raises('banco_owner: UPDATE credito.capital_pendiente (sin privilegio)', $$SET LOCAL ROLE banco_owner; UPDATE public.credito SET capital_pendiente = 5$$, 'permission denied for table credito', '42501');
-- roles de acceso
SELECT assert_raises('banco_app: UPDATE cuenta.balance', $$SET LOCAL ROLE banco_app; UPDATE public.cuenta SET balance = balance + 1$$, 'permission denied for table cuenta', '42501');
SELECT assert_raises('banco_dev: UPDATE cuenta.balance', $$SET LOCAL ROLE banco_dev; UPDATE public.cuenta SET balance = balance + 1$$, 'permission denied for table cuenta', '42501');
SELECT assert_raises('banco_lector: UPDATE cuenta.balance', $$SET LOCAL ROLE banco_lector; UPDATE public.cuenta SET balance = balance + 1$$, 'permission denied for table cuenta', '42501');
-- el saldo no cambio
SELECT assert_eq('despues de todos los intentos, el saldo sigue siendo el del libro (500.00)', (SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(1)), 500::numeric);
-- ...pero un UPDATE que no cambia el acumulador SI pasa (el guardia bloquea cambios, no sentencias)
SELECT assert_ok('banco_ledger: UPDATE que deja el acumulador igual (balance = balance) pasa', $$SET LOCAL ROLE banco_ledger; UPDATE public.cuenta SET balance = balance$$);

-- ============================================================================
-- 3. Columnas inmutables
-- ============================================================================
SELECT assert_raises('cuenta.numero_cuenta es inmutable', $$UPDATE public.cuenta SET numero_cuenta = '4011111111'$$, '%son inmutables%', 'P0001');
SELECT assert_raises('cuenta.usuario_id es inmutable', $$UPDATE public.cuenta SET usuario_id = gen_random_uuid()$$, '%son inmutables%');
SELECT assert_raises('cuenta.creado_en es inmutable', $$UPDATE public.cuenta SET creado_en = now() + interval '1 day'$$, '%son inmutables%');
SELECT assert_raises('cuenta.id es inmutable', $$UPDATE public.cuenta SET id = gen_random_uuid()$$, '%son inmutables%');
SELECT assert_raises('bolsillo.cuenta_id es inmutable', $$UPDATE public.bolsillo SET cuenta_id = gen_random_uuid()$$, '%son inmutables%');
SELECT assert_raises('cdt.monto es inmutable', $$UPDATE public.cdt SET monto = 1$$, '%son inmutables%');
SELECT assert_raises('cdt.tasa_anual es inmutable', $$UPDATE public.cdt SET tasa_anual = 50$$, '%son inmutables%');
SELECT assert_raises('cdt.plazo_dias y fechas son inmutables', $$UPDATE public.cdt SET plazo_dias = 30, fecha_fin = fecha_inicio + 30$$, '%son inmutables%');
SELECT assert_raises('cdt.cuenta_id es inmutable', $$UPDATE public.cdt SET cuenta_id = gen_random_uuid()$$, '%son inmutables%');
SELECT assert_raises('cdt.nombre es inmutable', $$UPDATE public.cdt SET nombre = 'otro'$$, '%son inmutables%');
SELECT assert_raises('credito.monto es inmutable', $$UPDATE public.credito SET monto = 1$$, '%son inmutables%');
SELECT assert_raises('credito.tasa_anual es inmutable', $$UPDATE public.credito SET tasa_anual = 1$$, '%son inmutables%');
SELECT assert_raises('credito.plazo_meses es inmutable', $$UPDATE public.credito SET plazo_meses = 24$$, '%son inmutables%');
SELECT assert_raises('credito.fecha_desembolso es inmutable', $$UPDATE public.credito SET fecha_desembolso = '2020-01-01'$$, '%son inmutables%');
SELECT assert_raises('credito.producto_id es inmutable', $$UPDATE public.credito SET producto_id = gen_random_uuid()$$, '%son inmutables%');
SELECT assert_raises('cdt.definicion_id no puede pasar a otro valor, solo a NULL',
                     $$UPDATE public.cdt SET definicion_id = gen_random_uuid()$$, '%definicion_id%solo puede pasar a NULL%', 'P0001');

-- ============================================================================
-- 4. Ciclo de vida: ACTIVO -> CERRADO / PAGADO, sin reabrir
-- ============================================================================
SELECT assert_ok('cdt ACTIVO -> CERRADO se permite al guardia (la coherencia contable la exige el trigger diferido)',
                 $$UPDATE public.cdt SET estado = 'CERRADO'$$);
SELECT assert_raises('un CDT cerrado no se reabre', $$UPDATE public.cdt SET estado = 'ACTIVO'$$, '%no se reabre%', 'P0001');
SELECT assert_ok('credito ACTIVO -> PAGADO (capital 0)', $$UPDATE public.credito SET estado = 'PAGADO'$$);
SELECT assert_raises('un credito pagado no se reabre', $$UPDATE public.credito SET estado = 'ACTIVO'$$, '%no se reabre%', 'P0001');

-- ============================================================================
-- 5. Lo que SI puede hacer el dueño (sus columnas no-acumulador) y lo que no
-- ============================================================================
SELECT assert_ok('banco_owner actualiza bolsillo.nombre y ultimo_cobro',
                 $$SET LOCAL ROLE banco_owner; UPDATE public.bolsillo SET nombre = 'Viajes', ultimo_cobro = ultimo_cobro + 1$$);   -- E7: ultimo_cobro solo avanza (guardia monotonica)
SELECT assert_ok('banco_owner actualiza cdt.ultimo_cobro', $$SET LOCAL ROLE banco_owner; UPDATE public.cdt SET ultimo_cobro = '2026-11-05'$$);
SELECT assert_ok('banco_owner actualiza credito.descuento_automatico, cobro_hasta (E9, siempre juntos por ck_credito_cobro_hasta), mora_hasta (E9), mora_acumulada y fecha_interes',
                 $$SET LOCAL ROLE banco_owner; UPDATE public.credito SET descuento_automatico = true, cobro_hasta = '2026-12-01', mora_hasta = '2026-12-01', mora_acumulada = 3, fecha_interes = '2026-12-01'$$);
SELECT assert_raises('banco_owner NO actualiza cuenta.numero_cuenta (sin privilegio)', $$SET LOCAL ROLE banco_owner; UPDATE public.cuenta SET numero_cuenta = '4022222222'$$, 'permission denied for table cuenta', '42501');
SELECT assert_raises('banco_owner NO actualiza cdt.monto (sin privilegio)', $$SET LOCAL ROLE banco_owner; UPDATE public.cdt SET monto = 5$$, 'permission denied for table cdt', '42501');
SELECT assert_raises('banco_owner NO actualiza credito.monto (sin privilegio)', $$SET LOCAL ROLE banco_owner; UPDATE public.credito SET monto = 5$$, 'permission denied for table credito', '42501');
SELECT assert_ok('las FK siguen funcionando con los permisos reducidos del dueño: insertar un bolsillo exige bloquear la cuenta (FOR KEY SHARE)',
                 $$SET LOCAL ROLE banco_owner; INSERT INTO public.bolsillo (cuenta_id, nombre, ultimo_cobro) VALUES (tests.c(1), 'Otro', '2026-11-21')$$);
SELECT assert_ok('...y borrar la plantilla de un CDT (FK SET NULL) funciona con el dueño',
                 $$INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES (tests.p(77), 'D', 30, 5, 1);
                   INSERT INTO public.cdt (cuenta_id, definicion_id, nombre, monto, tasa_anual, plazo_dias, fecha_inicio, fecha_fin, ultimo_cobro)
                     VALUES (tests.c(1), tests.p(77), 'D', 10, 5, 30, '2026-11-01', DATE '2026-11-01' + 30, '2026-11-01');
                   SET LOCAL ROLE banco_owner; DELETE FROM public.cdt_definicion WHERE id = tests.p(77)$$);
SELECT assert_eq('...y la FK dejo definicion_id en NULL (el guardia permite el paso a NULL)',
                 (SELECT definicion_id IS NULL FROM public.cdt WHERE nombre = 'D'), true);

ROLLBACK;
