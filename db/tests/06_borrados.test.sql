-- 06_borrados.test.sql · Etapa 1 · politica de borrado de las FK.
--   * Eliminar un USUARIO con productos y movimientos lo borra TODO lo suyo (cascada) y NO bloquea por
--     las FK de proteccion del libro mayor (NO ACTION), pero deja intacto lo de los demas.
--   * Los movimientos historicos estan PROTEGIDOS frente a eliminaciones INDIVIDUALES de bolsillo/CDT/credito.
--   * SET NULL en referidos y en la plantilla de CDT; un producto con creditos no se puede borrar.
-- E2: el escenario inserta saldos y patas "a mano"; se apagan SOLO los triggers de usuario (libro mayor, guardias,
-- auditoria). Las FK y su politica de borrado (el objeto de estas pruebas) corren con su comportamiento NORMAL.
-- La cascada CON los triggers de E2 activos (auditoria CUENTA_BORRADA, inmutabilidad) se prueba en 15_libro_inmutable.
-- Una sola transaccion con ROLLBACK final. Corre como superusuario.
BEGIN;
SELECT tests.sin_triggers_de_usuario();

-- ---------------------------------------------------------------------------------------------
-- Escenario. Dos clientes que se refieren entre si y se transfieren dinero:
--   A (jperez483, referidor de B): cuenta, 2 bolsillos, 1 CDT, 1 credito con 2 cuotas, y movimientos de todo tipo
--   B (cgomez12, referido por A): cuenta con el RECIBO de la transferencia de A (contraparte guardada como TEXTO)
-- ---------------------------------------------------------------------------------------------
INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento) VALUES
  ('10000000-0000-4000-8000-00000000000a','jperez483','h','Juan','Perez','1020304050','juan@correo.co','3001234567','1990-05-01');
INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, referido_por) VALUES
  ('10000000-0000-4000-8000-00000000000b','cgomez12','h','Camila','Gomez','1012345678','camila@correo.co','3209876543','1995-01-15','10000000-0000-4000-8000-00000000000a');
INSERT INTO public.cuenta (id, usuario_id, numero_cuenta, balance) VALUES
  ('20000000-0000-4000-8000-00000000000a','10000000-0000-4000-8000-00000000000a','4001002003', 900),
  ('20000000-0000-4000-8000-00000000000b','10000000-0000-4000-8000-00000000000b','4003004005', 100);
INSERT INTO public.bolsillo (id, cuenta_id, nombre, balance, ultimo_cobro) VALUES
  ('30000000-0000-4000-8000-0000000000a1','20000000-0000-4000-8000-00000000000a','Viajes', 100,'2026-11-21'),
  ('30000000-0000-4000-8000-0000000000a2','20000000-0000-4000-8000-00000000000a','Emergencias', 0,'2026-11-21'),
  ('30000000-0000-4000-8000-0000000000b1','20000000-0000-4000-8000-00000000000b','Ahorro', 0,'2026-11-21');
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES ('40000000-0000-4000-8000-000000000001','CDT 90', 90, 10, 1);
INSERT INTO public.cdt (id, cuenta_id, definicion_id, nombre, monto, tasa_anual, plazo_dias, fecha_inicio, fecha_fin, ultimo_cobro)
  VALUES ('50000000-0000-4000-8000-0000000000a1','20000000-0000-4000-8000-00000000000a','40000000-0000-4000-8000-000000000001','CDT 90',1000,10,90,DATE '2026-11-01',DATE '2026-11-01'+90,'2026-11-01');
INSERT INTO public.credito_producto (id, nombre, tasa_anual, monto_min, monto_max, plazo_max_meses) VALUES ('60000000-0000-4000-8000-000000000001','Libre',20,1,1000000,24);
INSERT INTO public.credito (id, cuenta_id, producto_id, monto, tasa_anual, plazo_meses, fecha_desembolso, capital_pendiente, fecha_interes)
  VALUES ('70000000-0000-4000-8000-0000000000a1','20000000-0000-4000-8000-00000000000a','60000000-0000-4000-8000-000000000001',5000,20,2,'2026-11-21',5000,'2026-11-21');
INSERT INTO public.cuota (credito_id, numero, fecha_vencimiento, valor_cuota_original, valor_cuota, capital_programado, interes_programado) VALUES
  ('70000000-0000-4000-8000-0000000000a1',1,'2026-12-21',2600,2600,2500,100),
  ('70000000-0000-4000-8000-0000000000a1',2,'2027-01-21',2600,2600,2500,100);

-- Movimientos (patas): transferencia A->B (con contraparte como texto), bolsillo, CDT y credito de A
INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, saldo_previo, saldo_posterior, cuenta_id, contraparte_nombre, contraparte_cuenta) VALUES
  ('a0000000-0000-4000-8000-000000000001', now(), 'ENVIO',  'CUENTA','S', 100, 1000, 900, '20000000-0000-4000-8000-00000000000a', 'Camila Gomez', '4003004005'),
  ('a0000000-0000-4000-8000-000000000001', now(), 'RECIBO', 'CUENTA','E', 100, 0, 100,   '20000000-0000-4000-8000-00000000000b', 'Juan Perez',   '4001002003');
INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, saldo_previo, saldo_posterior, cuenta_id, bolsillo_id) VALUES
  ('a0000000-0000-4000-8000-000000000002', now(), 'BOLSO_INGRESO','CUENTA',  'S', 100, 1000, 900, '20000000-0000-4000-8000-00000000000a','30000000-0000-4000-8000-0000000000a1'),
  ('a0000000-0000-4000-8000-000000000002', now(), 'BOLSO_INGRESO','BOLSILLO','E', 100, 0, 100,    '20000000-0000-4000-8000-00000000000a','30000000-0000-4000-8000-0000000000a1');
INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, saldo_previo, saldo_posterior, cuenta_id, cdt_id) VALUES
  ('a0000000-0000-4000-8000-000000000003', now(), 'CDT_CREACION','CUENTA','S', 1000, 2000, 1000, '20000000-0000-4000-8000-00000000000a','50000000-0000-4000-8000-0000000000a1'),
  ('a0000000-0000-4000-8000-000000000003', now(), 'CDT_CREACION','CDT',   'E', 1000, NULL, NULL, '20000000-0000-4000-8000-00000000000a','50000000-0000-4000-8000-0000000000a1');
INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, saldo_previo, saldo_posterior, cuenta_id, credito_id) VALUES
  ('a0000000-0000-4000-8000-000000000004', now(), 'CREDITO_DESEMBOLSO','CUENTA', 'E', 5000, 0, 5000,    '20000000-0000-4000-8000-00000000000a','70000000-0000-4000-8000-0000000000a1'),
  ('a0000000-0000-4000-8000-000000000004', now(), 'CREDITO_DESEMBOLSO','CREDITO','E', 5000, 0, 5000,    '20000000-0000-4000-8000-00000000000a','70000000-0000-4000-8000-0000000000a1');
INSERT INTO audit.evento (actor_id, actor_username, accion, entidad, entidad_id)
  VALUES ('10000000-0000-4000-8000-00000000000a', 'jperez483', 'USUARIO_CREADO', 'usuario', '10000000-0000-4000-8000-00000000000a');

SELECT assert_eq('escenario: 8 patas del libro (7 de A y 1 de B)', (SELECT count(*) FROM public.transaccion), 8::bigint);

-- ============================================================================
-- 1. Los movimientos historicos estan protegidos frente a eliminaciones individuales
-- ============================================================================
SELECT assert_violates('NO se puede borrar un BOLSILLO que tiene movimientos',
                       $$DELETE FROM public.bolsillo WHERE id = '30000000-0000-4000-8000-0000000000a1'$$, 'fk_transaccion_bolsillo', '23503');
SELECT assert_violates('NO se puede borrar un CDT que tiene movimientos',
                       $$DELETE FROM public.cdt WHERE id = '50000000-0000-4000-8000-0000000000a1'$$, 'fk_transaccion_cdt', '23503');
SELECT assert_violates('NO se puede borrar un CREDITO que tiene movimientos',
                       $$DELETE FROM public.credito WHERE id = '70000000-0000-4000-8000-0000000000a1'$$, 'fk_transaccion_credito', '23503');
SELECT assert_eq('...y el rechazo fue completo: sus cuotas siguen ahi', (SELECT count(*) FROM public.cuota), 2::bigint);
SELECT assert_ok('un bolsillo SIN movimientos si se puede borrar', $$DELETE FROM public.bolsillo WHERE id = '30000000-0000-4000-8000-0000000000a2'$$);
SELECT assert_violates('NO se puede borrar un producto de credito con creditos',
                       $$DELETE FROM public.credito_producto WHERE id = '60000000-0000-4000-8000-000000000001'$$, 'fk_credito_producto', '23503');

-- ============================================================================
-- 2. SET NULL: plantilla de CDT y referidor
-- ============================================================================
SELECT assert_ok('borrar la plantilla de CDT deja el CDT vivo con definicion_id NULL',
                 $$DELETE FROM public.cdt_definicion WHERE id = '40000000-0000-4000-8000-000000000001'$$);
SELECT assert_eq('...el CDT conserva sus copias y definicion_id es NULL',
                 (SELECT (definicion_id IS NULL, monto, tasa_anual, plazo_dias)::text FROM public.cdt WHERE id = '50000000-0000-4000-8000-0000000000a1'),
                 '(t,1000.00,10.000,90)'::text);

-- ============================================================================
-- 3. ELIMINACION COMPLETA de un usuario con productos y transacciones asociadas
-- ============================================================================
SELECT assert_eq('antes: A tiene 1 cuenta, 1 bolsillo, 1 CDT, 1 credito, 2 cuotas y 7 patas',
                 (SELECT (
                    (SELECT count(*) FROM public.cuenta   WHERE usuario_id = '10000000-0000-4000-8000-00000000000a'),
                    (SELECT count(*) FROM public.bolsillo WHERE cuenta_id = '20000000-0000-4000-8000-00000000000a'),
                    (SELECT count(*) FROM public.cdt      WHERE cuenta_id = '20000000-0000-4000-8000-00000000000a'),
                    (SELECT count(*) FROM public.credito  WHERE cuenta_id = '20000000-0000-4000-8000-00000000000a'),
                    (SELECT count(*) FROM public.cuota    WHERE credito_id = '70000000-0000-4000-8000-0000000000a1'),
                    (SELECT count(*) FROM public.transaccion WHERE cuenta_id = '20000000-0000-4000-8000-00000000000a'))::text),
                 '(1,1,1,1,2,7)'::text);
SELECT assert_eq('antes: B tiene el RECIBO de A y es su referido',
                 (SELECT ((SELECT count(*) FROM public.transaccion WHERE cuenta_id = '20000000-0000-4000-8000-00000000000b'),
                          (SELECT referido_por FROM public.usuario WHERE id = '10000000-0000-4000-8000-00000000000b'))::text),
                 '(1,10000000-0000-4000-8000-00000000000a)'::text);

-- EL BORRADO: una sola sentencia. Debe cascadear por cuenta -> bolsillo/cdt/credito/cuota/transaccion
-- sin que las FK NO ACTION del libro mayor la bloqueen.
SELECT assert_ok('DELETE del usuario A (con cuenta, bolsillos, CDT, credito, cuotas y movimientos) tiene exito',
                 $$DELETE FROM public.usuario WHERE id = '10000000-0000-4000-8000-00000000000a'$$);

SELECT assert_eq('despues: de A no queda NADA (usuario, cuenta, bolsillos, CDT, creditos, cuotas, movimientos)',
                 (SELECT (
                    (SELECT count(*) FROM public.usuario WHERE id = '10000000-0000-4000-8000-00000000000a'),
                    (SELECT count(*) FROM public.cuenta),
                    (SELECT count(*) FROM public.bolsillo WHERE cuenta_id = '20000000-0000-4000-8000-00000000000a'),
                    (SELECT count(*) FROM public.cdt),
                    (SELECT count(*) FROM public.credito),
                    (SELECT count(*) FROM public.cuota),
                    (SELECT count(*) FROM public.transaccion WHERE cuenta_id = '20000000-0000-4000-8000-00000000000a'))::text),
                 '(0,1,0,0,0,0,0)'::text);     -- queda solo la cuenta de B

SELECT assert_eq('B sigue existiendo y su referido_por quedo en NULL (SET NULL)',
                 (SELECT (username, referido_por IS NULL)::text FROM public.usuario WHERE id = '10000000-0000-4000-8000-00000000000b'),
                 '(cgomez12,t)'::text);
SELECT assert_eq('el RECIBO de B sobrevive y la contraparte (A) queda guardada como TEXTO, sin FK huerfana',
                 (SELECT (tipo::text, contraparte_nombre, contraparte_cuenta)::text FROM public.transaccion WHERE cuenta_id = '20000000-0000-4000-8000-00000000000b'),
                 '(RECIBO,"Juan Perez",4001002003)'::text);
SELECT assert_eq('el bolsillo de B y su cuenta siguen intactos',
                 (SELECT ((SELECT count(*) FROM public.bolsillo), (SELECT balance FROM public.cuenta))::text), '(1,100.00)'::text);
SELECT assert_eq('el catalogo (producto de credito) no se toca', (SELECT count(*) FROM public.credito_producto), 1::bigint);
SELECT assert_eq('la auditoria SOBREVIVE al borrado del usuario (sin FK, con snapshot)',
                 (SELECT (actor_username, accion)::text FROM audit.evento WHERE entidad_id = '10000000-0000-4000-8000-00000000000a'),
                 '(jperez483,USUARIO_CREADO)'::text);

-- Tambien se puede borrar una cuenta (y con ella todo lo suyo) directamente
SELECT assert_ok('borrar la cuenta de B por si sola tambien cascadea a sus movimientos', $$DELETE FROM public.cuenta WHERE id = '20000000-0000-4000-8000-00000000000b'$$);
SELECT assert_eq('...y no quedan patas ni bolsillos huerfanos', (SELECT (SELECT count(*) FROM public.transaccion) + (SELECT count(*) FROM public.bolsillo)), 0::bigint);

ROLLBACK;
