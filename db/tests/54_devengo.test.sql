-- 54_devengo.test.sql · Etapa 7 · el MOTOR de devengo (_avanzar_hasta) sobre bolsillos: matematica contra una referencia independiente, idempotencia,
-- periodo repetido, volver al reloj real, guardia monotonica de ultimo_cobro, atomicidad (rollback y fallos en cada pata), integracion en las funciones
-- de E5/E6 (devengar ANTES de leer o mover saldos), cobertura por catalogo, UNA instantanea del reloj por operacion y limites documentados (D-E7-9).
-- No repite las pruebas exhaustivas del libro (E2), el reloj (E3), transferencias (E5) ni bolsillos (E6). Una transaccion con ROLLBACK final.
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y sustituye _ahora_real() y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 16) n;

-- ---------------------------------------------------------------------------------------------------------------------------------------------
-- Helpers (todos en pg_temp: desaparecen con la sesion)
-- ---------------------------------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION pg_temp.sig(p_n int) RETURNS void LANGUAGE plpgsql AS $f$       -- adelanta el reloj (manual) p_n dias desde el hoy actual del banco
BEGIN PERFORM public._reloj_actualizar(false, (public.hoy_banco() + p_n)::text); END $f$;
CREATE FUNCTION pg_temp.salta_a(p_fecha date) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN PERFORM public._reloj_actualizar(false, p_fecha::text); END $f$;
CREATE FUNCTION pg_temp.av(p_cuenta uuid) RETURNS int LANGUAGE sql AS $f$      -- el motor con UNA instantanea (como lo llama una funcion de negocio)
  SELECT public._avanzar_hasta(p_cuenta, i.hoy, i.ahora) FROM public._reloj_instantanea() i $f$;
CREATE FUNCTION pg_temp.bol(p_n int, p_cuenta uuid, p_saldo numeric) RETURNS uuid LANGUAGE plpgsql AS $f$   -- bolsillo p_n con saldo p_saldo y ultimo_cobro = hoy del banco
BEGIN
  INSERT INTO public.bolsillo (id, cuenta_id, nombre, ultimo_cobro) VALUES (tests.b(p_n), p_cuenta, 'B' || p_n, public.hoy_banco());
  IF p_saldo > 0 THEN PERFORM pg_temp.dep(p_n, p_cuenta, p_saldo); END IF;
  RETURN tests.b(p_n);
END $f$;
CREATE FUNCTION pg_temp.dep(p_n int, p_cuenta uuid, p_monto numeric) RETURNS void LANGUAGE plpgsql AS $f$  -- fondea la cuenta y mueve p_monto al bolsillo por el libro (BOLSO_INGRESO)
BEGIN
  PERFORM tests.fondear(p_cuenta, p_monto);
  PERFORM public._asentar_grupo(now(), jsonb_build_array(tests.pata('BOLSO_INGRESO', 'CUENTA', 'S', p_monto, p_cuenta, tests.b(p_n)),
                                                         tests.pata('BOLSO_INGRESO', 'BOLSILLO', 'E', p_monto, p_cuenta, tests.b(p_n))));
END $f$;
CREATE FUNCTION pg_temp.ngb(p_n int) RETURNS int LANGUAGE sql VOLATILE AS $f$ SELECT count(DISTINCT grupo_id)::int FROM public.transaccion WHERE tipo = 'INTERES_BOLSO' AND bolsillo_id = tests.b(p_n) $f$;
CREATE FUNCTION pg_temp.bs(p_n int) RETURNS numeric LANGUAGE sql VOLATILE AS $f$ SELECT balance::numeric FROM public.bolsillo WHERE id = tests.b(p_n) $f$;
CREATE FUNCTION pg_temp.cs(p_n int) RETURNS numeric LANGUAGE sql VOLATILE AS $f$ SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(p_n) $f$;
CREATE FUNCTION pg_temp.ref(p_monto numeric, p_tasa numeric, p_dias int) RETURNS numeric LANGUAGE plpgsql AS $f$   -- REFERENCIA INDEPENDIENTE: bucle dia por dia con exp(ln())
DECLARE v numeric := p_monto; r numeric := exp(ln(1 + p_tasa / 100) / 365); i int;
BEGIN
  FOR i IN 1..p_dias LOOP v := round(v * r, 14); END LOOP;
  RETURN round(v - p_monto, 2);
END $f$;
CREATE FUNCTION pg_temp.ret(p_u int, p_b int, p_m text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM public.retirar_de_bolsillo(tests.u(p_u), tests.b(p_b)::text, p_m::numeric);
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM;
END $f$;
CREATE TEMP TABLE t_d AS SELECT public.hoy_banco() AS d0;

-- ============================================================================
-- 1. La formula (D1 PROVISIONAL): referencia independiente (bucle por dia), casos conocidos y bordes
-- ============================================================================
SELECT assert_eq('_factor_interes: $1.000.000 al 12 % por 30 dias = $9.358,20 (E.A. estricta; D1 PROVISIONAL)', round(1000000 * public._factor_interes(12, 30), 2), 9358.20::numeric);
SELECT assert_eq('_factor_interes: $10.000.000 al 10 % por 360 dias = $985.647,56', round(10000000 * public._factor_interes(10, 360), 2), 985647.56::numeric);
SELECT assert_eq('_factor_interes: 365 dias = la tasa efectiva anual exacta ($1.000.000 al 12 % = $120.000,00)', round(1000000 * public._factor_interes(12, 365), 2), 120000.00::numeric);
SELECT assert_eq('_factor_interes: 0 dias, dias negativos, NULL y tasa 0/NULL = 0',
                 (public._factor_interes(12, 0), public._factor_interes(12, -5), public._factor_interes(12, NULL), public._factor_interes(0, 30), public._factor_interes(NULL, 30))::text, '(0,0,0,0,0)'::text);
DO $do$
DECLARE r record; mal text := ''; v numeric; w numeric;
BEGIN
  FOR r IN SELECT * FROM (VALUES (1000000::numeric, 12::numeric, 1), (1000000, 12, 7), (2500000, 12, 30), (123456.78, 12, 45), (10000000, 10, 360), (5000000, 8, 90),
                                 (1000000, 12, 365), (1000000, 12, 730), (999.99, 12, 400), (50000000, 10, 3650)) q(m, t, d)
  LOOP
    v := round(r.m * public._factor_interes(r.t, r.d), 2);
    w := pg_temp.ref(r.m, r.t, r.d);
    IF abs(v - w) > 0.01 THEN mal := mal || r.m || '/' || r.t || '/' || r.d || ' (' || v || ' vs ' || w || '); '; END IF;
  END LOOP;
  PERFORM tests.assert_eq('la formula coincide (a +-1 centavo) con la referencia independiente dia por dia en 10 casos (1 dia, semana, mes, 1, 2 y 10 anos)', mal, ''::text);
END $do$;

-- ============================================================================
-- 2. Bolsillo con saldo: 30 dias en UNA llamada (forma cerrada), forma del grupo, idempotencia
-- ============================================================================
SELECT pg_temp.bol(1, tests.c(1), 1000000);
SELECT assert_eq('sin nada vencido (ultimo_cobro = hoy) el motor sale sin escribir: 0 grupos', pg_temp.av(tests.c(1)), 0);
SELECT pg_temp.sig(30);
SELECT assert_eq('30 dias despues el motor escribe EXACTAMENTE 1 grupo (INTERES_BOLSO del bolsillo)', pg_temp.av(tests.c(1)), 1);
SELECT assert_eq('saldo = 1.000.000 + 9.358,20 (12 % E.A., 30 dias)', pg_temp.bs(1), 1009358.20::numeric);
SELECT assert_eq('el grupo: 2 patas (BOLSILLO E + RESULTADO E), 9.358,20, nota "30 dias", contraparte "Banco Digital", UNA sola fecha',
                 (SELECT (count(*), count(DISTINCT grupo_id), array_agg(contenedor::text ORDER BY contenedor::text), min(monto)::text, min(nota), min(contraparte_nombre),
                          bool_and(sentido::text = 'E'), count(DISTINCT fecha))::text
                    FROM public.transaccion WHERE tipo = 'INTERES_BOLSO' AND bolsillo_id = tests.b(1)),
                 '(2,1,"{BOLSILLO,RESULTADO}",9358.20,"30 días","Banco Digital",t,1)'::text);
SELECT assert_eq('la pata BOLSILLO registra saldo previo 1.000.000 y posterior 1.009.358,20 (lo aplica el libro, no el motor)',
                 (SELECT (saldo_previo, saldo_posterior)::text FROM public.transaccion WHERE tipo = 'INTERES_BOLSO' AND contenedor = 'BOLSILLO' AND bolsillo_id = tests.b(1)), '(1000000.00,1009358.20)'::text);
SELECT assert_true('ultimo_cobro = hoy del banco', (SELECT ultimo_cobro = public.hoy_banco() FROM public.bolsillo WHERE id = tests.b(1)));
CREATE TEMP TABLE t_h1 AS SELECT tests.huella_saldos() AS h;
SELECT assert_eq('repetir _avanzar_hasta con el mismo hoy: 0 grupos (periodo ya cobrado)', pg_temp.av(tests.c(1)), 0);
SELECT public.vista_balance(tests.u(1));
SELECT assert_eq('ni la repeticion ni vista_balance cambian nada (huella de saldos y numero de patas)', tests.huella_saldos(), (SELECT h FROM t_h1));
SELECT assert_eq('_avanzar_hasta de una cuenta inexistente devuelve 0 (el llamador traduce la carrera) y con argumentos NULL falla con P0001',
                 (public._avanzar_hasta(gen_random_uuid(), public.hoy_banco(), now()), tests.captura($$SELECT public._avanzar_hasta(NULL, public.hoy_banco(), now())$$))::text,
                 '(0,"Motor de devengo: cuenta, hoy y ahora son obligatorios")'::text);

-- ============================================================================
-- 3. Saldo 0: ultimo_cobro avanza igual (no hay cobro retroactivo cuando llega dinero despues)
-- ============================================================================
SELECT pg_temp.bol(2, tests.c(1), 0);
SELECT pg_temp.sig(10);
SELECT assert_eq('10 dias despues: el bolsillo 1 genera su grupo y el bolsillo VACIO no genera ninguno (1 en total)', pg_temp.av(tests.c(1)), 1);
SELECT assert_eq('el bolsillo vacio avanzo ultimo_cobro igualmente (si no, un deposito posterior cobraria dias retroactivos)',
                 (SELECT (ultimo_cobro = public.hoy_banco(), (SELECT count(*) FROM public.transaccion WHERE bolsillo_id = tests.b(2) AND tipo = 'INTERES_BOLSO'))::text FROM public.bolsillo WHERE id = tests.b(2)), '(t,0)'::text);
SELECT pg_temp.dep(2, tests.c(1), 100000);
SELECT pg_temp.sig(10);
SELECT pg_temp.av(tests.c(1));
SELECT assert_eq('el deposito tardio gana SOLO los 10 dias posteriores a la llegada del dinero (no los 20 desde la creacion)', pg_temp.bs(2) - 100000, pg_temp.ref(100000, 12, 10));

-- ============================================================================
-- 4. Un dia: nota singular y valor
-- ============================================================================
SELECT pg_temp.bol(3, tests.c(2), 1000000);
SELECT pg_temp.sig(1);
SELECT pg_temp.av(tests.c(2));
SELECT assert_eq('1 dia: nota "1 dia" y el interes coincide con la referencia (+-1 centavo)',
                 (SELECT (min(nota), abs(min(monto) - pg_temp.ref(1000000, 12, 1)) <= 0.01)::text FROM public.transaccion WHERE tipo = 'INTERES_BOLSO' AND bolsillo_id = tests.b(3)), '("1 día",t)'::text);

-- ============================================================================
-- 5. Independencia del camino: 30 llamadas de 1 dia vs 1 llamada de 30 dias (la diferencia es solo el redondeo a centavos)
-- ============================================================================
SELECT pg_temp.bol(4, tests.c(3), 1000000);
SELECT pg_temp.bol(5, tests.c(4), 1000000);
DO $do$
BEGIN
  FOR i IN 1..30 LOOP
    PERFORM pg_temp.sig(1);
    PERFORM pg_temp.av(tests.c(3));
  END LOOP;
  PERFORM pg_temp.av(tests.c(4));
END $do$;
SELECT assert_eq('1 llamada de 30 dias: coincide con la referencia (+-1 centavo)', abs(pg_temp.bs(5) - 1000000 - pg_temp.ref(1000000, 12, 30)) <= 0.01, true);
SELECT assert_eq('30 llamadas diarias: 30 grupos (uno por llamada) frente a 1 grupo', (pg_temp.ngb(4), pg_temp.ngb(5))::text, '(30,1)'::text);
SELECT assert_true('independencia del camino: la diferencia entre 30 consultas diarias y 1 de 30 dias es solo redondeo (<= 0,50 sobre $1.000.000; D-E7-9)', abs(pg_temp.bs(4) - pg_temp.bs(5)) <= 0.50);

-- ============================================================================
-- 6. Salto de 30 anos: forma cerrada (UN grupo, sin bucle por dia)
-- ============================================================================
SELECT pg_temp.bol(6, tests.c(5), 10000000);
SELECT pg_temp.sig(10950);
SELECT assert_eq('30 anos (10.950 dias) en UNA llamada: 1 grupo', pg_temp.av(tests.c(5)), 1);
SELECT assert_true('el interes de 30 anos coincide con la referencia dia por dia (+-5 centavos sobre ~$2,9e8)', abs(pg_temp.bs(6) - 10000000 - pg_temp.ref(10000000, 12, 10950)) <= 0.05);
SELECT assert_eq('un solo grupo para 30 anos de saldo', pg_temp.ngb(6), 1);

-- ============================================================================
-- 7. Tope del dominio: el interes se recorta a monto_maximo (nunca un error de dominio)
-- ============================================================================
SELECT pg_temp.bol(7, tests.c(6), 9999999999000);
SELECT pg_temp.sig(365);
SELECT assert_eq('un saldo cercano al tope no desborda: el interes se recorta y el saldo queda en monto_maximo (sin error)', (pg_temp.av(tests.c(6)), pg_temp.bs(7))::text, '(1,9999999999999.99)'::text);
SELECT assert_eq('el grupo recortado es de $999,99', (SELECT min(monto) FROM public.transaccion WHERE tipo = 'INTERES_BOLSO' AND bolsillo_id = tests.b(7))::text, '999.99'::text);
SELECT pg_temp.sig(30);
CREATE TEMP TABLE t_r7 AS SELECT pg_temp.av(tests.c(6)) AS n;
SELECT assert_eq('con el saldo al tope no hay mas interes (0 grupos) y ultimo_cobro avanza', ((SELECT n FROM t_r7), (SELECT ultimo_cobro = public.hoy_banco() FROM public.bolsillo WHERE id = tests.b(7)))::text, '(0,t)'::text);

-- ============================================================================
-- 8. Limite aceptado D-E7-9: el redondeo a centavos por asiento
-- ============================================================================
SELECT pg_temp.bol(13, tests.c(14), 10);
SELECT pg_temp.bol(14, tests.c(15), 10);
DO $do$
BEGIN
  FOR i IN 1..30 LOOP PERFORM pg_temp.sig(1); PERFORM pg_temp.av(tests.c(14)); END LOOP;
  PERFORM pg_temp.av(tests.c(15));
END $do$;
SELECT assert_eq('D-E7-9 (limite documentado): un bolsillo de $10 consultado A DIARIO no gana nada (0,003/dia redondea a 0,00) y UNA consulta a los 30 dias si (0,09)',
                 (pg_temp.bs(13), pg_temp.bs(14))::text, '(10.00,10.09)'::text);
SELECT assert_true('...pero ultimo_cobro avanza en ambos (no hay cobro retroactivo)', (SELECT count(*) = 2 FROM public.bolsillo WHERE id IN (tests.b(13), tests.b(14)) AND ultimo_cobro = public.hoy_banco()));

-- ============================================================================
-- 9. Guardia monotonica de ultimo_cobro (D-E7-8) y volver al reloj real (periodo repetido)
-- ============================================================================
SELECT assert_raises('UPDATE de bolsillo.ultimo_cobro hacia atras: rechazado (P0001)', $$UPDATE public.bolsillo SET ultimo_cobro = ultimo_cobro - 1 WHERE id = tests.b(1)$$, '%ultimo_cobro no puede retroceder%', 'P0001');
SELECT assert_raises('...tambien para banco_owner (el rol del motor)', $$SET LOCAL ROLE banco_owner; UPDATE public.bolsillo SET ultimo_cobro = ultimo_cobro - 1 WHERE id = '30000000-0000-4000-8000-000000000001'$$, '%ultimo_cobro no puede retroceder%', 'P0001');
SELECT assert_ok('un valor IGUAL se acepta (UPDATE idempotente)', $$UPDATE public.bolsillo SET ultimo_cobro = ultimo_cobro WHERE id = tests.b(1)$$);
SELECT assert_ok('un UPDATE que no toca ultimo_cobro no dispara la guardia', $$UPDATE public.bolsillo SET nombre = nombre WHERE id = tests.b(1)$$);
CREATE TEMP TABLE t_u AS SELECT ultimo_cobro AS u, balance AS saldo FROM public.bolsillo WHERE id = tests.b(1);
CREATE TEMP TABLE t_h2 AS SELECT tests.huella_saldos() AS h;
SELECT public._reloj_actualizar(true, '');
SELECT assert_true('de vuelta al reloj real, hoy < ultimo_cobro del bolsillo', public.hoy_banco() < (SELECT u FROM t_u));
CREATE TEMP TABLE t_r9 AS SELECT pg_temp.av(tests.c(1)) AS n, (public.vista_balance(tests.u(1)) IS NOT NULL) AS v;
SELECT assert_eq('volver al reloj real: el motor NO escribe nada (ni recobra ni retrocede ultimo_cobro) y vista_balance tampoco', ((SELECT n FROM t_r9), (SELECT v FROM t_r9), tests.huella_saldos() = (SELECT h FROM t_h2))::text, '(0,t,t)'::text);
SELECT pg_temp.salta_a((SELECT u FROM t_u));
CREATE TEMP TABLE t_r9b AS SELECT pg_temp.av(tests.c(1)) AS n;
SELECT assert_eq('al volver a la fecha de ultimo_cobro el periodo ya cobrado NO se cobra de nuevo: 0 grupos y la misma huella', ((SELECT n FROM t_r9b), tests.huella_saldos() = (SELECT h FROM t_h2))::text, '(0,t)'::text);
CREATE TEMP TABLE t_n AS SELECT pg_temp.ngb(1) AS n1, pg_temp.bs(1) AS s1;
SELECT pg_temp.sig(1);
SELECT pg_temp.av(tests.c(1));
SELECT assert_eq('un dia despues SOLO se cobra ese dia (1 grupo mas, interes del dia sobre el saldo previo)',
                 (pg_temp.ngb(1) - (SELECT n1 FROM t_n), pg_temp.bs(1) - (SELECT s1 FROM t_n) = round((SELECT s1 FROM t_n) * public._factor_interes(12, 1), 2))::text, '(1,t)'::text);

-- un bolsillo ATRASADO convive con bolsillos ADELANTADOS (tras volver al reloj real): el motor devenga SOLO al atrasado y no retrocede el ultimo_cobro de los demas
SELECT public._reloj_actualizar(true, '');
INSERT INTO public.bolsillo (id, cuenta_id, nombre, ultimo_cobro) VALUES (tests.b(17), tests.c(1), 'B17', public.hoy_banco() - 5);
SELECT pg_temp.dep(17, tests.c(1), 100000);
CREATE TEMP TABLE t_u2 AS SELECT ultimo_cobro AS u1 FROM public.bolsillo WHERE id = tests.b(1);
CREATE TEMP TABLE t_r9c AS SELECT pg_temp.av(tests.c(1)) AS n;
SELECT assert_eq('un bolsillo atrasado (hoy - 5) conviviendo con otros adelantados: el motor devenga SOLO el atrasado (1 grupo, 5 dias) y NO toca el ultimo_cobro de los demas (sin error de guardia)',
                 ((SELECT n FROM t_r9c), abs(pg_temp.bs(17) - 100000 - pg_temp.ref(100000, 12, 5)) <= 0.01, (SELECT ultimo_cobro = (SELECT u1 FROM t_u2) FROM public.bolsillo WHERE id = tests.b(1)), pg_temp.ngb(17))::text, '(1,t,t,1)'::text);

-- ============================================================================
-- 10. Devengar ANTES de leer o mover: el saldo con intereses es el que se puede retirar / transferir
-- ============================================================================
SELECT pg_temp.bol(8, tests.c(7), 1000000);
SELECT pg_temp.bol(9, tests.c(9), 1000000);
SELECT pg_temp.sig(30);
SELECT assert_eq('retirar_de_bolsillo del saldo CON intereses (1.009.358,20) funciona: el motor devenga antes del libro', pg_temp.ret(7, 8, '1009358.20'), 'OK');
SELECT assert_eq('bolsillo en 0 y cuenta con el capital mas el interes', (pg_temp.bs(8), pg_temp.cs(7))::text, '(0.00,1009358.20)'::text);
SELECT assert_eq('hacer_transferencia desde el bolsillo por el saldo CON intereses funciona y el destino lo recibe',
                 (SELECT public.hacer_transferencia(tests.u(9), '4000000010', 1009358.20, NULL, tests.b(9)::text) IS NOT NULL), true);
SELECT assert_eq('...bolsillo 0, destino con 1.009.358,20', (pg_temp.bs(9), pg_temp.cs(10))::text, '(0.00,1009358.20)'::text);
SELECT pg_temp.bol(10, tests.c(11), 1000000);
SELECT pg_temp.sig(30);
CREATE TEMP TABLE t_h3 AS SELECT tests.huella_saldos() AS h, (SELECT ultimo_cobro FROM public.bolsillo WHERE id = tests.b(10)) AS u;
CREATE TEMP TABLE t_r10 AS SELECT pg_temp.ret(11, 10, '2000000') AS r;
SELECT assert_eq('un rechazo POSTERIOR al devengo (Saldo insuficiente) revierte tambien el devengo: huella y ultimo_cobro intactos', ((SELECT r FROM t_r10), tests.huella_saldos() = (SELECT h FROM t_h3),
                 (SELECT ultimo_cobro = (SELECT u FROM t_h3) FROM public.bolsillo WHERE id = tests.b(10)), pg_temp.ngb(10))::text, '("Saldo insuficiente",t,t,0)'::text);
SELECT assert_eq('la siguiente operacion valida devenga UNA sola vez (1 grupo) y el retiro se hace', (pg_temp.ret(11, 10, '1'), pg_temp.ngb(10))::text, '(OK,1)'::text);

-- fallo inyectado en CADA pata de la operacion (2 de interes + 2 del retiro): nada queda a medias
SELECT pg_temp.bol(11, tests.c(12), 1000000);
SELECT pg_temp.sig(30);
SELECT tests.instalar_fallas();
DO $do$
DECLARE p int; mal text := ''; h0 text; r text;
BEGIN
  h0 := tests.huella_saldos();
  FOR p IN 1..4 LOOP
    PERFORM tests.falla('tx:' || p);
    r := pg_temp.ret(12, 11, '100');
    IF r NOT LIKE 'FALLA INYECTADA%' OR tests.huella_saldos() <> h0 OR pg_temp.ngb(11) <> 0 THEN mal := mal || p || ':' || coalesce(r, 'NULL') || '; '; END IF;
  END LOOP;
  PERFORM tests.assert_eq('un fallo en CADA una de las 4 patas (2 del devengo + 2 del retiro) revierte devengo y operacion: huella intacta y 0 grupos de interes', mal, ''::text);
END $do$;
SELECT tests.falla('');
SELECT tests.quitar_fallas();
SELECT assert_eq('sin fallos: la operacion devenga UNA vez y retira', (pg_temp.ret(12, 11, '100'), pg_temp.ngb(11))::text, '(OK,1)'::text);

-- ============================================================================
-- 11. Cobertura POR CATALOGO: toda funcion publica esta clasificada; las que mueven o leen saldos devengan primero y con UNA instantanea
-- ============================================================================
CREATE TEMP TABLE t_cat (f text, impl text, devenga boolean);
INSERT INTO t_cat VALUES
  ('crear_bolsillo', 'crear_bolsillo', true), ('crear_cdt', 'crear_cdt', true), ('hacer_transferencia', 'hacer_transferencia', true),
  ('mover_a_bolsillo', '_mover_bolsillo', true), ('mover_entre_bolsillos', '_mover_bolsillo', true), ('retirar_de_bolsillo', '_mover_bolsillo', true),
  ('vista_balance', 'vista_balance', true), ('vista_cdts', 'vista_cdts', true),
  -- E8 (creditos): devengan antes de calcular topes / leer
  ('productos_disponibles', 'productos_disponibles', true), ('simular_credito', 'simular_credito', true), ('solicitar_credito', 'solicitar_credito', true), ('vista_creditos', 'vista_creditos', true),
  -- E9 (pagos): devengan y cobran lo automatico ANTES de pagar, abonar o cambiar el cursor
  ('pagar_cuota', 'pagar_cuota', true), ('abonar_credito', 'abonar_credito', true), ('activar_descuento_automatico', 'activar_descuento_automatico', true),
  -- E10 (vistas): devengan, cierran y cobran ANTES de leer
  ('vista_dashboard', 'vista_dashboard', true), ('vista_historial', 'vista_historial', true),
  -- E11 (admin): el detalle y el ajuste leen/mueven saldos de UN cliente: devengan y cobran ANTES
  ('admin_detalle_usuario', 'admin_detalle_usuario', true), ('admin_ajustar_balance', 'admin_ajustar_balance', true),
  -- EXENTAS (cada una con su razon): no leen ni mueven saldos de bolsillos/CDT
  ('listar_cdt_definiciones', 'listar_cdt_definiciones', false), ('nombre_destinatario', 'nombre_destinatario', false), ('obtener_credenciales', 'obtener_credenciales', false),
  ('registrar_usuario', 'registrar_usuario', false), ('simular_cdt', 'simular_cdt', false), ('validar_sesion', 'validar_sesion', false),
  ('verificar_correo', 'verificar_correo', false), ('vista_perfil', 'vista_perfil', false),
  ('productos_publicos', 'productos_publicos', false),
  -- E11: las otras 10 (lista, bloquear, desbloquear, borrar, reloj y tasas) no leen ni mueven saldos de bolsillos/CDT
  ('admin_listar_usuarios', 'admin_listar_usuarios', false), ('admin_bloquear', 'admin_bloquear', false), ('admin_desbloquear', 'admin_desbloquear', false),
  ('admin_borrar_usuario', 'admin_borrar_usuario', false), ('admin_get_reloj', 'admin_get_reloj', false), ('admin_set_reloj', 'admin_set_reloj', false),
  ('admin_get_tasas', 'admin_get_tasas', false), ('admin_set_tasa_cdt', 'admin_set_tasa_cdt', false), ('admin_set_tasa_credito', 'admin_set_tasa_credito', false),
  ('admin_set_tasa_mora', 'admin_set_tasa_mora', false),
  -- E12 (Control): el visor muestra lo GUARDADO y es de solo lectura (STABLE): no corre el motor
  ('admin_esquema', 'admin_esquema', false), ('admin_tabla', 'admin_tabla', false);                 -- E8: sin sesion, no lee a nadie
SELECT assert_eq('TODA funcion ejecutable por banco_app esta en la lista "devenga" o "exenta" (una funcion nueva sin clasificar HACE FALLAR esta prueba: E8-E10 la heredan)',
                 (SELECT array_agg(p.proname::text ORDER BY p.proname COLLATE "C") FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e') AND has_function_privilege('banco_app', p.oid, 'EXECUTE')),
                 (SELECT array_agg(f ORDER BY f COLLATE "C") FROM t_cat));
SELECT assert_eq('las 19 funciones que devengan llaman _avanzar_hasta EXACTAMENTE 1 vez, _reloj_instantanea EXACTAMENTE 1 vez y la instantanea va ANTES del devengo',
                 (SELECT array_agg(DISTINCT c.impl ORDER BY c.impl) FILTER (WHERE (length(p.prosrc) - length(replace(p.prosrc, '_avanzar_hasta(', ''))) / length('_avanzar_hasta(') <> 1
                                                                               OR (length(p.prosrc) - length(replace(p.prosrc, '_reloj_instantanea()', ''))) / length('_reloj_instantanea()') <> 1
                                                                               OR strpos(p.prosrc, '_reloj_instantanea()') > strpos(p.prosrc, '_avanzar_hasta('))
                    FROM t_cat c JOIN pg_proc p ON p.pronamespace = 'public'::regnamespace AND p.proname = c.impl WHERE c.devenga),
                 NULL::text[]);
SELECT assert_eq('hacer_transferencia: _bloquear_cuentas EXACTAMENTE 1 vez y ANTES del devengo (protocolo anti-deadlock, orden de id)',
                 (SELECT ((length(prosrc) - length(replace(prosrc, '_bloquear_cuentas(', ''))) / length('_bloquear_cuentas('), strpos(prosrc, '_bloquear_cuentas(') < strpos(prosrc, '_avanzar_hasta('),
                          strpos(prosrc, '_reloj_instantanea()') < strpos(prosrc, '_bloquear_cuentas('))::text
                    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'hacer_transferencia'), '(1,t,t)'::text);
SELECT assert_eq('las exentas NO llaman _avanzar_hasta (no leen ni mueven bolsillos ni CDT)',
                 (SELECT count(*) FROM t_cat c JOIN pg_proc p ON p.pronamespace = 'public'::regnamespace AND p.proname = c.impl WHERE NOT c.devenga AND p.prosrc LIKE '%_avanzar_hasta%'), 0::bigint);
SELECT assert_eq('las 19 que devengan no usan now()/current_date/clock_timestamp/hoy_banco/ahora_banco/_ahora_real: el unico acceso al reloj es la instantanea',
                 (SELECT count(*) FROM t_cat c JOIN pg_proc p ON p.pronamespace = 'public'::regnamespace AND p.proname = c.impl
                   WHERE c.devenga AND p.prosrc ~* '(now\s*\(|current_(date|time)|clock_timestamp|statement_timestamp|transaction_timestamp|localtime|hoy_banco|ahora_banco|_ahora_real|pg_sleep)'), 0::bigint);
SELECT assert_eq('el motor y sus 5 ayudantes NO leen el reloj (ni now(), ni hoy_banco(), ni _ahora_real(), ni la instantanea): reciben (hoy, ahora)',
                 (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                     AND p.proname IN ('_avanzar_hasta', '_devengar_bolsillos', '_devengar_cdts', '_factor_interes', '_bloquear_cuentas', '_texto_tiempo_restante', '_definicion_cdt')
                     AND p.prosrc ~* '(now\s*\(|current_(date|time)|clock_timestamp|statement_timestamp|transaction_timestamp|localtime|hoy_banco|ahora_banco|_ahora_real|pg_sleep|_reloj_instantanea)'), 0::bigint);
SELECT assert_eq('el dinero del devengo se mueve SOLO por _asentar_grupo: sin INSERT en transaccion ni UPDATE de saldos en el motor (solo ultimo_cobro/estado)',
                 (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('_avanzar_hasta', '_devengar_bolsillos', '_devengar_cdts')
                     AND (p.prosrc ~* 'insert\s+into\s+public\.transaccion' OR p.prosrc ~* 'update\s+public\.(cuenta|bolsillo)\s+set\s+balance' OR p.prosrc ~* 'generado_acumulado\s*=')), 0::bigint);
SELECT assert_eq('las 6 internas del motor: SIN EXECUTE para PUBLIC, banco_app, banco_lector ni banco_dev (solo el dueno)',
                 (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                     AND p.proname IN ('_avanzar_hasta', '_devengar_bolsillos', '_devengar_cdts', '_factor_interes', '_bloquear_cuentas', 'trg_ultimo_cobro_monotono')
                     AND (has_function_privilege('banco_app', p.oid, 'EXECUTE') OR has_function_privilege('banco_lector', p.oid, 'EXECUTE') OR has_function_privilege('banco_dev', p.oid, 'EXECUTE')
                          OR EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))), 0::bigint);

-- ============================================================================
-- 12. UNA instantanea del reloj por operacion (conteo dinamico). _ahora_real solo se sustituye en banco_test/banco_mut, dentro de esta transaccion
-- ============================================================================
SELECT pg_temp.bol(15, tests.c(13), 100000);                       -- origen con bolsillo (cuenta 13); el bolsillo 16 (cuenta 13) esta vacio
SELECT pg_temp.bol(16, tests.c(13), 0);
SELECT tests.fondear(tests.c(13), 5000);
CREATE TEMP SEQUENCE sq_lect;
GRANT USAGE, SELECT, UPDATE ON SEQUENCE sq_lect TO banco_owner;
CREATE OR REPLACE FUNCTION public._ahora_real() RETURNS timestamptz LANGUAGE plpgsql VOLATILE SET search_path = public, pg_temp AS $f$
BEGIN
  RETURN '2026-11-21 10:00:00-05'::timestamptz + make_interval(secs => nextval('pg_temp.sq_lect')::int);
END $f$;
CREATE FUNCTION pg_temp.lect() RETURNS int LANGUAGE sql VOLATILE AS $f$ SELECT CASE WHEN is_called THEN last_value::int ELSE 0 END FROM pg_temp.sq_lect $f$;
CREATE TEMP TABLE t_m (t0 timestamptz);
INSERT INTO t_m VALUES (clock_timestamp());
CREATE FUNCTION pg_temp.legs() RETURNS text LANGUAGE sql VOLATILE AS $f$
  SELECT (count(*), count(DISTINCT fecha), bool_and(to_char(fecha AT TIME ZONE 'America/Bogota', 'HH24:MI:SS') = '10:00:01'))::text FROM public.transaccion WHERE registrado_en > (SELECT t0 FROM t_m) $f$;

SELECT pg_temp.sig(1);
SELECT setval('pg_temp.sq_lect', 1, false); UPDATE t_m SET t0 = clock_timestamp();
SELECT public.mover_a_bolsillo(tests.u(13), tests.b(15)::text, 1);
SELECT assert_eq('mover_a_bolsillo con interes pendiente: 1 lectura (instantanea) + 4 patas (2 del devengo + 2 del movimiento) = 5', pg_temp.lect(), 5);
SELECT assert_eq('...y las 4 patas (devengo Y operacion) llevan EXACTAMENTE el mismo ahora (T+1s): una sola instantanea', pg_temp.legs(), '(4,1,t)'::text);
SELECT pg_temp.sig(1);
SELECT setval('pg_temp.sq_lect', 1, false); UPDATE t_m SET t0 = clock_timestamp();
SELECT public.vista_balance(tests.u(13));
SELECT assert_eq('vista_balance con interes pendiente: 1 + 2 patas = 3 lecturas (E6 tenia 0: ahora devenga)', (pg_temp.lect(), pg_temp.legs())::text, '(3,"(2,1,t)")'::text);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.vista_balance(tests.u(13));
SELECT assert_eq('vista_balance SIN nada vencido: 1 lectura (solo la instantanea)', pg_temp.lect(), 1);
SELECT pg_temp.sig(1);
SELECT setval('pg_temp.sq_lect', 1, false); UPDATE t_m SET t0 = clock_timestamp();
SELECT public.hacer_transferencia(tests.u(13), '4000000014', 1, 'x', NULL);
SELECT assert_eq('hacer_transferencia con interes pendiente en el origen: 1 + 2 (devengo) + 2 (ENVIO y RECIBO) = 5 lecturas y UN solo ahora', (pg_temp.lect(), pg_temp.legs())::text, '(5,"(4,1,t)")'::text);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.hacer_transferencia(tests.u(13), '4000000014', 1, 'x', NULL);
SELECT assert_eq('hacer_transferencia sin nada vencido: 1 + 2 = 3 lecturas (igual que en E5)', pg_temp.lect(), 3);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.crear_bolsillo(tests.u(13), 'Otro');
SELECT assert_eq('crear_bolsillo sin nada vencido: 1 lectura', pg_temp.lect(), 1);
SELECT pg_temp.sig(1);
SELECT setval('pg_temp.sq_lect', 1, false); UPDATE t_m SET t0 = clock_timestamp();
SELECT public.retirar_de_bolsillo(tests.u(13), tests.b(15)::text, 1);
SELECT assert_eq('retirar_de_bolsillo con interes pendiente: 5 lecturas y UN solo ahora', (pg_temp.lect(), pg_temp.legs())::text, '(5,"(4,1,t)")'::text);
SELECT pg_temp.sig(1);
SELECT setval('pg_temp.sq_lect', 1, false); UPDATE t_m SET t0 = clock_timestamp();
SELECT public.mover_entre_bolsillos(tests.u(13), tests.b(15)::text, tests.b(16)::text, 1);
SELECT assert_eq('mover_entre_bolsillos con interes pendiente: 5 lecturas y UN solo ahora', (pg_temp.lect(), pg_temp.legs())::text, '(5,"(4,1,t)")'::text);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT assert_eq('un rechazo de validacion (monto) no lee el reloj ni devenga', (tests.captura('SELECT public.retirar_de_bolsillo(' || quote_literal(tests.u(13)) || '::uuid, ' || quote_literal(tests.b(15)::text) || ', 0)'), pg_temp.lect())::text, '("Monto inválido",0)'::text);

ROLLBACK;

SELECT assert_eq('tras el ROLLBACK _ahora_real() es otra vez el reloj de pared (la sustitucion no sobrevive)', (SELECT pg_get_functiondef(oid) LIKE '%SELECT clock_timestamp()%' FROM pg_proc WHERE oid = 'public._ahora_real()'::regprocedure), true);
SELECT assert_eq('tras el ROLLBACK el reloj vuelve a modo real (los saltos de fecha no sobreviven)', (SELECT usar_fecha_real FROM public.reloj WHERE id = 1), true);
