-- 58_creditos.test.sql · Etapa 8 · productos_disponibles, productos_publicos, simular_credito, solicitar_credito y vista_creditos: topes efectivos (tope fijo, 100 x patrimonio
-- neto de Inmuebles, regla de edad), mensajes y orden de validacion, un credito vivo por producto, el asiento CREDITO_DESEMBOLSO y el plan de cuotas persistido,
-- sincronia capital_pendiente <-> plan <-> libro, atomicidad (falla inyectada en cada paso), devengo previo con el reloj adelantado, interes corriendo, permisos y
-- catalogo. NO repite el libro (E2), el reloj (E3), el motor (E7) ni la aritmetica del plan (57). Una transaccion con ROLLBACK final.
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 12) n;
INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol)
VALUES ('adminz', tests.hash(), 'Adm', 'In', '9300001', 'adminz@mail.co', '3170000001', DATE '1980-01-01', 'ADMIN');
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = tests.u(12);

CREATE FUNCTION pg_temp.sig(p_n int) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(false, (public.hoy_banco() + p_n)::text); END $f$;
CREATE FUNCTION pg_temp.cs(p_n int) RETURNS numeric LANGUAGE sql VOLATILE AS $f$ SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(p_n) $f$;
CREATE FUNCTION pg_temp.ncre(p_n int) RETURNS bigint LANGUAGE sql VOLATILE AS $f$ SELECT count(*) FROM public.credito WHERE cuenta_id = tests.c(p_n) $f$;
CREATE FUNCTION pg_temp.ncuo(p_n int) RETURNS bigint LANGUAGE sql VOLATILE AS $f$ SELECT count(*) FROM public.cuota q JOIN public.credito k ON k.id = q.credito_id WHERE k.cuenta_id = tests.c(p_n) $f$;
-- solicitar / simular con captura del error: 'OK:<id>' o el mensaje
CREATE FUNCTION pg_temp.sol(p_u int, p_prod int, p_monto text, p_plazo text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  RETURN 'OK:' || (public.solicitar_credito(tests.u(p_u), tests.p(p_prod)::text, p_monto::numeric, p_plazo::numeric) ->> 'id');
EXCEPTION WHEN OTHERS THEN RETURN regexp_replace(SQLERRM, '[0-9a-f]{8}-[0-9a-f-]{27}', '<id>', 'g');
END $f$;
CREATE FUNCTION pg_temp.sim(p_u int, p_prod int, p_monto text, p_plazo text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  RETURN public.simular_credito(tests.u(p_u), tests.p(p_prod)::text, p_monto::numeric, p_plazo::numeric)::text;
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM;
END $f$;
-- el producto de la lista de un usuario: (monto_min, monto_max, plazo_min, plazo_max)
CREATE FUNCTION pg_temp.lim(p_u int, p_prod int) RETURNS text LANGUAGE sql VOLATILE AS $f$
  SELECT (e ->> 'monto_min', e ->> 'monto_max', e ->> 'plazo_min', e ->> 'plazo_max')::text
    FROM jsonb_array_elements(public.productos_disponibles(tests.u(p_u))) e WHERE e ->> 'id' = tests.p(p_prod)::text $f$;

-- ============================================================================
-- 1. Catalogo vacio (D11, del equipo) y forma de las salidas
-- ============================================================================
SELECT assert_eq('sin catalogo: productos_disponibles y productos_publicos devuelven []', (public.productos_disponibles(tests.u(1))::text, public.productos_publicos()::text)::text, '([],[])'::text);
SELECT assert_eq('sin creditos: vista_creditos devuelve []', public.vista_creditos(tests.u(1))::text, '[]'::text);
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses, tope_absoluto, multiplicador_balance, aplica_regla_edad) VALUES
  (tests.p(901), 'Libre inversión', 'Dinero para lo que necesites', 23.9, 1000000, 50000000, 6, 24, 30000000, NULL, false),
  (tests.p(902), 'Vehículo',        'Estrena carro',                18.9, 50000000, 200000000, 12, 120, NULL, NULL, false),
  (tests.p(903), 'Educación',       'Invierte en tu formación',     15.4, 1000000, 100000000, 6, 240, NULL, NULL, false),
  (tests.p(904), 'Inmuebles',       'Tu casa',                      14.1, 1, 2000000000, 12, 360, 2000000000, 100, true);
SELECT assert_eq('productos_disponibles: 4 productos ordenados por nombre; id string; tasa, monto_min, monto_max, plazo_min y plazo_max numericos',
                 (SELECT (array_agg(e ->> 'nombre'), array_agg(DISTINCT jsonb_typeof(e -> 'id')), array_agg(DISTINCT jsonb_typeof(e -> 'tasa')), array_agg(DISTINCT jsonb_typeof(e -> 'monto_max')),
                          array_agg(DISTINCT jsonb_typeof(e -> 'plazo_max')), count(*))::text
                    FROM jsonb_array_elements(public.productos_disponibles(tests.u(1))) e),
                 '("{Educación,Inmuebles,""Libre inversión"",Vehículo}",{string},{number},{number},{number},4)'::text);
SELECT assert_json_shape('productos_publicos: {id, nombre, descripcion, tasa, monto_min, monto_max, plazo_min, plazo_max}', public.productos_publicos() -> 0,
                         '{"id":"string","nombre":"string","descripcion":"string","tasa":"number","monto_min":"number","monto_max":"number","plazo_min":"number","plazo_max":"number"}'::jsonb);
SELECT assert_eq('productos_publicos: topes BASE (sin multiplicador ni edad): Inmuebles 1 a 2.000M y 12 a 360 meses; Libre inversion 1M a 30M',
                 (SELECT string_agg((e ->> 'nombre') || '=' || (e ->> 'monto_min') || '/' || (e ->> 'monto_max') || '/' || (e ->> 'plazo_min') || '/' || (e ->> 'plazo_max'), '; ' ORDER BY e ->> 'nombre')
                    FROM jsonb_array_elements(public.productos_publicos()) e WHERE e ->> 'nombre' IN ('Inmuebles', 'Libre inversión')),
                 'Inmuebles=1.00/2000000000.00/12/360; Libre inversión=1000000.00/30000000.00/6/24'::text);

-- ============================================================================
-- 2. Topes efectivos (D-E8-5/7): tope fijo, 100 x patrimonio neto y regla de edad
-- ============================================================================
SELECT assert_eq('cuenta en 0: Inmuebles monto_max = 0 (100 x 0), el producto SE LISTA igual; los demas con sus topes; plazo_max de Inmuebles 360 (edad 36: (70-36)*12 = 408 > 360)',
                 (pg_temp.lim(1, 904), pg_temp.lim(1, 901), pg_temp.lim(1, 902))::text,
                 '("(1.00,0.00,12,360)","(1000000.00,30000000.00,6,24)","(50000000.00,200000000.00,12,120)")'::text);
SELECT tests.fondear(tests.c(1), 5000000);
SELECT assert_eq('con $5.000.000 en la cuenta: Inmuebles monto_max = 500.000.000 (100 x patrimonio)', pg_temp.lim(1, 904), '(1.00,500000000.00,12,360)'::text);
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES (tests.p(950), 'CDT 90', 90, 10, 100000);
SELECT public.mover_a_bolsillo(tests.u(1), public.crear_bolsillo(tests.u(1), 'Ahorro') ->> 'id', 1000000);
SELECT public.crear_cdt(tests.u(1), tests.p(950)::text, 500000);
SELECT assert_eq('mover a un bolsillo o invertir en un CDT NO cambia el patrimonio (balance_total = 5.000.000): el tope de Inmuebles sigue en 500.000.000',
                 (public.balance_total(tests.c(1)), pg_temp.lim(1, 904))::text, '(5000000.00,"(1.00,500000000.00,12,360)")'::text);
-- credito: el desembolso sube la cuenta y la deuda en lo mismo: el tope NO se infla (autoneutralizacion, spec 7.6)
CREATE TEMP TABLE t_r1 AS SELECT pg_temp.sol(1, 901, '10000000', '12') AS r;
SELECT assert_eq('Libre inversion $10.000.000 a 12 meses: se acepta', (SELECT left(r, 3) FROM t_r1), 'OK:'::text);
SELECT assert_eq('tras el credito: cuenta +10M, deuda 10M, patrimonio neto = 5.000.000 y el tope de Inmuebles NO se infla (500.000.000)',
                 (pg_temp.cs(1), (SELECT sum(capital_pendiente) FROM public.credito WHERE cuenta_id = tests.c(1)), public._patrimonio_neto(tests.c(1)), pg_temp.lim(1, 904))::text,
                 '(13500000.00,10000000.00,5000000.00,"(1.00,500000000.00,12,360)")'::text);
SELECT assert_eq('D-E8-5 PROVISIONAL (D6): balance_total NO resta la deuda (15.000.000 = 5M + 10M del credito); solo el TOPE usa el patrimonio neto',
                 (public.balance_total(tests.c(1)), (public.vista_balance(tests.u(1)) ->> 'total')::numeric)::text, '(15000000.00,15000000.00)'::text);
SELECT public.hacer_transferencia(tests.u(1), '4000000002', 13500000, 'gasto', NULL);
SELECT assert_eq('gastada la cuenta (13.500.000 enviados): activos 1.500.000 (bolsillo + CDT) - deuda 10.000.000 = patrimonio -8.500.000; el tope de Inmuebles queda en 0 (piso) y el producto se lista',
                 (public.balance_total(tests.c(1)), public._patrimonio_neto(tests.c(1)), pg_temp.lim(1, 904))::text, '(1500000.00,-8500000.00,"(1.00,0.00,12,360)")'::text);
-- regla de edad (cada cuenta con $1.000.000: el tope de Inmuebles es 100.000.000)
SELECT count(tests.fondear(tests.c(n), 1000000)) FROM generate_series(4, 9) n;
UPDATE public.usuario SET fecha_nacimiento = public.hoy_banco() - interval '43 years' - interval '100 days' WHERE id = tests.u(4);
UPDATE public.usuario SET fecha_nacimiento = public.hoy_banco() - interval '69 years' - interval '1 day' WHERE id = tests.u(5);
UPDATE public.usuario SET fecha_nacimiento = public.hoy_banco() - interval '70 years' - interval '1 day' WHERE id = tests.u(6);
UPDATE public.usuario SET fecha_nacimiento = public.hoy_banco() - interval '80 years' WHERE id = tests.u(7);
UPDATE public.usuario SET fecha_nacimiento = public.hoy_banco() - interval '43 years' WHERE id = tests.u(8);                      -- cumple 43 HOY
UPDATE public.usuario SET fecha_nacimiento = (public.hoy_banco() - interval '43 years' + interval '1 day')::date WHERE id = tests.u(9);   -- cumple 43 MAÑANA: aun 42
SELECT assert_eq('edad 43: plazo_max de Inmuebles = (70-43)*12 = 324 meses (el ejemplo del spec); edad 69: 12; edad 70 y 80: 0 (el producto se lista)',
                 (SELECT array_agg(pg_temp.lim(n, 904) ORDER BY n) FROM unnest(ARRAY[4, 5, 6, 7]) n),
                 ARRAY['(1.00,100000000.00,12,324)', '(1.00,100000000.00,12,12)', '(1.00,100000000.00,12,0)', '(1.00,100000000.00,12,0)']);
SELECT assert_eq('cumpleaños: quien cumple 43 HOY ya tiene 43 (324 meses); quien los cumple MAÑANA aun tiene 42 (336 meses)',
                 (pg_temp.lim(8, 904), pg_temp.lim(9, 904))::text, '("(1.00,100000000.00,12,324)","(1.00,100000000.00,12,336)")'::text);
SELECT assert_eq('la regla de edad solo aplica a Inmuebles: los otros productos de una persona de 80 años mantienen su plazo maximo', pg_temp.lim(7, 902), '(50000000.00,200000000.00,12,120)'::text);

-- ============================================================================
-- 3. Sesion, mensajes y orden de validacion (contrato §6; ningun mensaje inventado)
-- ============================================================================
SELECT tests.fondear(tests.c(2), 500000000);
SELECT assert_eq('Libre inversion 30.000.001 -> Monto fuera de rango; 999.999 (bajo el minimo) tambien; los limites exactos (1.000.000 y 30.000.000) se aceptan en simulacion',
                 (pg_temp.sol(2, 901, '30000001', '12'), pg_temp.sol(2, 901, '999999.99', '12'),
                  (pg_temp.sim(2, 901, '1000000', '12') LIKE '{%'), (pg_temp.sim(2, 901, '30000000', '12') LIKE '{%'))::text,
                 '("Monto fuera de rango","Monto fuera de rango",t,t)'::text);
SELECT assert_eq('plazo fuera de rango: 5 (< minimo 6), 25 (> 24), 0, 12.5 y NULL-> todos "Plazo fuera de rango"',
                 (pg_temp.sol(2, 901, '2000000', '5'), pg_temp.sol(2, 901, '2000000', '25'), pg_temp.sol(2, 901, '2000000', '0'), pg_temp.sol(2, 901, '2000000', '12.5'),
                  tests.captura($$SELECT public.solicitar_credito(tests.u(2), tests.p(901)::text, 2000000, NULL)$$))::text,
                 '("Plazo fuera de rango","Plazo fuera de rango","Plazo fuera de rango","Plazo fuera de rango","Plazo fuera de rango")'::text);
SELECT assert_eq('Inmuebles (edad 43): plazo 325 -> "Plazo excede el límite de edad"; plazo 361 (> maximo del producto) -> "Plazo fuera de rango" (NO el de edad); 11 (< minimo) -> "Plazo fuera de rango"',
                 (pg_temp.sol(4, 904, '1000', '325'), pg_temp.sol(4, 904, '1000', '361'), pg_temp.sol(4, 904, '1000', '11'))::text,
                 '("Plazo excede el límite de edad","Plazo fuera de rango","Plazo fuera de rango")'::text);
SELECT assert_eq('orden: monto invalido ANTES que plazo invalido ANTES que producto; producto mal formado / inexistente / NULL = Recurso no encontrado',
                 (pg_temp.sol(2, 901, '0', '0'), pg_temp.sol(2, 901, '1000000', '0'),
                  tests.captura($$SELECT public.solicitar_credito(tests.u(2), 'no-es-uuid', 1000000, 12)$$), tests.captura($$SELECT public.solicitar_credito(tests.u(2), NULL, 1000000, 12)$$),
                  tests.captura('SELECT public.solicitar_credito(tests.u(2), ' || quote_literal(gen_random_uuid()::text) || ', 1000000, 12)'))::text,
                 '("Monto inválido","Plazo fuera de rango","Recurso no encontrado","Recurso no encontrado","Recurso no encontrado")'::text);
SELECT assert_eq('monto con mas de 2 decimales, negativo y NaN -> Monto inválido (el mismo validador de E5)',
                 (pg_temp.sol(2, 901, '1000000.001', '12'), pg_temp.sol(2, 901, '-5', '12'), pg_temp.sol(2, 901, 'NaN', '12'))::text, '("Monto inválido","Monto inválido","Monto inválido")'::text);
DO $do$
DECLARE f text; u text; i int; r text; esp text[] := ARRAY['Sesión inválida', 'Acceso denegado', 'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla']; mal text := '';
BEGIN
  FOREACH f IN ARRAY ARRAY['productos_disponibles(%L)', 'vista_creditos(%L)', 'simular_credito(%L, ''x'', 1, 1)', 'solicitar_credito(%L, ''x'', 1, 1)'] LOOP
    i := 0;
    FOREACH u IN ARRAY ARRAY[gen_random_uuid()::text, (SELECT id::text FROM public.usuario WHERE username = 'adminz'), tests.u(12)::text] LOOP
      i := i + 1;
      r := tests.captura('SELECT public.' || format(f, u));
      IF r IS DISTINCT FROM esp[i] THEN mal := mal || f || '#' || i || ' [' || coalesce(r, 'NULL') || ']; '; END IF;
    END LOOP;
  END LOOP;
  PERFORM tests.assert_eq('las 4 funciones de cliente exigen sesion viva ANTES de todo (inexistente = Sesión inválida, ADMIN = Acceso denegado, BLOQUEADO = mensaje de bloqueo)', mal, ''::text);
END $do$;

-- ============================================================================
-- 4. Un credito vivo por producto
-- ============================================================================
SELECT tests.fondear(tests.c(5), 300000000);
CREATE TEMP TABLE t_r5 AS SELECT pg_temp.sol(5, 902, '60000000', '24') AS r;
SELECT assert_eq('segundo Vehiculo vivo: "Ya tienes un crédito vigente de este producto" (aun con un monto fuera de rango: la validacion del vigente va ANTES); Educacion SI se permite',
                 (SELECT left(r, 3) FROM t_r5) || '|' || pg_temp.sol(5, 902, '60000000', '24') || '|' || pg_temp.sol(5, 902, '1', '1') || '|' || left(pg_temp.sol(5, 903, '2000000', '12'), 3) || '|' || pg_temp.ncre(5),
                 'OK:|Ya tienes un crédito vigente de este producto|Ya tienes un crédito vigente de este producto|OK:|2'::text);
SELECT assert_eq('SIMULAR no valida el vigente (se puede simular un producto que ya tienes)', (pg_temp.sim(5, 902, '60000000', '24') LIKE '{%')::text, 'true'::text);

-- ============================================================================
-- 5. El desembolso: credito, plan persistido y asiento, sincronizados
-- ============================================================================
SELECT tests.fondear(tests.c(3), 1000000);
CREATE TEMP TABLE t_c3 AS SELECT pg_temp.cs(3) AS saldo0, public.hoy_banco() AS h0;
CREATE TEMP TABLE t_r3 AS SELECT public.solicitar_credito(tests.u(3), tests.p(901)::text, 10000000, 12) AS r;
SELECT assert_json_shape('solicitar_credito devuelve {id, fecha}', (SELECT r FROM t_r3), '{"id":"string","fecha":"string"}'::jsonb);
SELECT assert_eq('el credito COPIA tasa y plazo del producto; monto; fecha_desembolso = hoy; fecha_interes = hoy (inicio del periodo); capital_pendiente = monto; ACTIVO; sin mora ni descuento automatico',
                 (SELECT (producto_id = tests.p(901), monto, tasa_anual, plazo_meses, fecha_desembolso = (SELECT h0 FROM t_c3), fecha_interes = fecha_desembolso, capital_pendiente, estado::text, descuento_automatico, mora_acumulada)::text
                    FROM public.credito WHERE id = (SELECT (r ->> 'id')::uuid FROM t_r3)),
                 '(t,10000000.00,23.900,12,t,t,10000000.00,ACTIVO,f,0.00)'::text);
SELECT assert_eq('el plan: 12 cuotas numeradas 1..12, vencimientos = desembolso + k meses, valor_cuota = valor_cuota_original = capital + interes, nada pagado',
                 (SELECT (count(*), min(numero), max(numero), bool_and(fecha_vencimiento = public._fecha_vencimiento((SELECT h0 FROM t_c3), numero)), bool_and(valor_cuota = valor_cuota_original),
                          bool_and(valor_cuota = capital_programado + interes_programado), bool_or(pagada), sum(capital_pagado + intereses_pagados))::text
                    FROM public.cuota WHERE credito_id = (SELECT (r ->> 'id')::uuid FROM t_r3)),
                 '(12,1,12,t,t,t,f,0.00)'::text);
SELECT assert_eq('Σ capital_programado = monto = capital_pendiente (la regla de ct_credito_plan, comprobada a mano)',
                 (SELECT (sum(q.capital_programado) = k.monto, sum(q.capital_programado) = k.capital_pendiente)::text FROM public.credito k JOIN public.cuota q ON q.credito_id = k.id
                   WHERE k.id = (SELECT (r ->> 'id')::uuid FROM t_r3) GROUP BY k.monto, k.capital_pendiente), '(t,t)'::text);
SELECT assert_eq('el asiento CREDITO_DESEMBOLSO: 2 patas (CUENTA E + CREDITO E) por el monto, UNA fecha = la devuelta, contraparte = producto, CREDITO 0 -> 10M, CUENTA saldo +10M',
                 (SELECT (count(*), count(DISTINCT grupo_id), array_agg(contenedor::text || sentido::text ORDER BY contenedor::text), min(monto)::text, count(DISTINCT fecha),
                          bool_and(fecha = (SELECT (r ->> 'fecha')::timestamptz FROM t_r3)), min(contraparte_nombre),
                          max(saldo_posterior - saldo_previo)::text, bool_and(credito_id = (SELECT (r ->> 'id')::uuid FROM t_r3)))::text
                    FROM public.transaccion WHERE credito_id = (SELECT (r ->> 'id')::uuid FROM t_r3) AND tipo = 'CREDITO_DESEMBOLSO'),
                 '(2,1,"{CREDITOE,CUENTAE}",10000000.00,1,t,"Libre inversión",10000000.00,t)'::text);
SELECT assert_eq('la cuenta recibe el monto exacto: saldo0 + 10.000.000', pg_temp.cs(3) - (SELECT saldo0 FROM t_c3), 10000000.00::numeric);
SELECT assert_eq('el desembolso aparece en el historial como recibo (la pata visible es la de la CUENTA)',
                 (SELECT (count(*), min(monto)::text) FROM public.transaccion WHERE cuenta_id = tests.c(3) AND tipo = 'CREDITO_DESEMBOLSO' AND contenedor = 'CUENTA' AND sentido = 'E')::text, '(1,10000000.00)'::text);
SELECT assert_eq('LA SIMULACION ES LO QUE SE COBRA: cuota_mensual, total_a_pagar e intereses_totales de simular_credito = cuota 1, Σ cuotas y Σ intereses del plan persistido',
                 (SELECT ((s ->> 'cuota_mensual')::numeric = (SELECT valor_cuota FROM public.cuota WHERE credito_id = (SELECT (r ->> 'id')::uuid FROM t_r3) AND numero = 1),
                          (s ->> 'total_a_pagar')::numeric = (SELECT sum(valor_cuota) FROM public.cuota WHERE credito_id = (SELECT (r ->> 'id')::uuid FROM t_r3)),
                          (s ->> 'intereses_totales')::numeric = (SELECT sum(interes_programado) FROM public.cuota WHERE credito_id = (SELECT (r ->> 'id')::uuid FROM t_r3)),
                          (s ->> 'total_a_pagar')::numeric - (s ->> 'intereses_totales')::numeric)::text
                    FROM (SELECT public.simular_credito(tests.u(3), tests.p(901)::text, 10000000, 12) AS s) q), '(t,t,t,10000000.00)'::text);
SELECT assert_json_shape('simular_credito devuelve {cuota_mensual, total_a_pagar, intereses_totales} numericos', public.simular_credito(tests.u(3), tests.p(903)::text, 5000000, 36),
                         '{"cuota_mensual":"number","total_a_pagar":"number","intereses_totales":"number"}'::jsonb);
SELECT assert_eq('la integridad del libro y de los planes sigue en orden (v_integridad_global.ok, 0 creditos con plan incoherente)',
                 (SELECT (ok, creditos_con_plan_incoherente)::text FROM public.v_integridad_global), '(t,0)'::text);
-- Σ cuotas de 360 meses (Inmuebles) dentro del limite del contrato
CREATE TEMP TABLE t_t AS SELECT clock_timestamp() AS t0;
CREATE TEMP TABLE t_r10 AS SELECT pg_temp.sol(2, 904, '100000000', '360') AS r;
SELECT assert_eq('Inmuebles $100.000.000 a 360 meses: 360 cuotas, Σ capital = monto, en menos de 5 s (contrato §8)',
                 (SELECT (left(r, 3), (SELECT count(*) FROM public.cuota WHERE credito_id = substr(r, 4)::uuid), (SELECT sum(capital_programado) FROM public.cuota WHERE credito_id = substr(r, 4)::uuid),
                          clock_timestamp() - (SELECT t0 FROM t_t) < interval '5 seconds')::text FROM t_r10), '(OK:,360,100000000.00,t)'::text);
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES (tests.p(905), 'Plazo largo', '', 12, 1, 1000000000, 1, 480);
SELECT assert_eq('producto mal cargado con plazo_max_meses = 480: el plazo efectivo se topa en el tecnico 360 (en la lista y al solicitar 361)',
                 (pg_temp.lim(3, 905), pg_temp.sol(3, 905, '1000000', '361'))::text, '("(1.00,1000000000.00,1,360)","Plazo fuera de rango")'::text);
SELECT assert_eq('un 361 de plazo en Inmuebles se rechaza con Plazo fuera de rango (tecnico 360 = maximo del producto)', pg_temp.sol(3, 904, '1000000', '361'), 'Plazo fuera de rango'::text);

-- ============================================================================
-- 6. Atomicidad: una falla en CUALQUIER paso deja todo como estaba
-- ============================================================================
SELECT tests.fondear(tests.c(10), 20000000);
CREATE FUNCTION tests.trg_falla_e8() RETURNS trigger LANGUAGE plpgsql AS $f$
DECLARE v text := coalesce(current_setting('tests.falla_e8', true), '');
BEGIN
  IF TG_TABLE_NAME = 'credito' AND v = 'credito' THEN RAISE EXCEPTION 'FALLA INYECTADA al insertar el credito' USING ERRCODE = 'P0001'; END IF;
  IF TG_TABLE_NAME = 'cuota' THEN
    IF v = 'cuota_12' AND NEW.numero = 12 THEN RAISE EXCEPTION 'FALLA INYECTADA en la cuota 12' USING ERRCODE = 'P0001'; END IF;
    IF v = 'cuota_omite' AND NEW.numero = 12 THEN RETURN NULL; END IF;                                    -- el plan quedaria con 11 cuotas
    IF v = 'cuota_corrupta' AND NEW.numero = 1 THEN NEW.capital_programado := NEW.capital_programado + 1; NEW.valor_cuota := NEW.valor_cuota + 1; END IF;
  END IF;
  RETURN NEW;
END $f$;
CREATE TRIGGER trg_zz_falla_e8 BEFORE INSERT ON public.credito FOR EACH ROW EXECUTE FUNCTION tests.trg_falla_e8();
CREATE TRIGGER trg_zz_falla_e8 BEFORE INSERT ON public.cuota   FOR EACH ROW EXECUTE FUNCTION tests.trg_falla_e8();
SELECT tests.instalar_fallas();
DO $do$
DECLARE r text; h0 text; mal text := ''; v text;
BEGIN
  h0 := tests.huella_saldos();
  -- falla en el libro: pata 1 y pata 2 del desembolso
  FOR v IN SELECT unnest(ARRAY['tx:1', 'tx:2']) LOOP
    PERFORM tests.falla(v);
    r := pg_temp.sol(10, 901, '5000000', '12');
    IF r NOT LIKE 'FALLA INYECTADA%' OR tests.huella_saldos() <> h0 OR pg_temp.ncre(10) <> 0 OR pg_temp.ncuo(10) <> 0 THEN mal := mal || v || ':' || r || '; '; END IF;
  END LOOP;
  PERFORM tests.falla('');
  -- falla al insertar el credito, en la ultima cuota
  FOREACH v IN ARRAY ARRAY['credito', 'cuota_12'] LOOP
    PERFORM set_config('tests.falla_e8', v, true);
    r := pg_temp.sol(10, 901, '5000000', '12');
    IF r NOT LIKE 'FALLA INYECTADA%' OR tests.huella_saldos() <> h0 OR pg_temp.ncre(10) <> 0 OR pg_temp.ncuo(10) <> 0 THEN mal := mal || v || ':' || r || '; '; END IF;
  END LOOP;
  PERFORM tests.assert_eq('falla inyectada en la pata 1, la pata 2, el INSERT del credito y la ultima cuota: ni credito, ni cuotas, ni asiento, ni saldos (huella intacta)', mal, ''::text);
  -- plan INCOMPLETO (11 de 12 cuotas): la propia funcion lo detecta antes de asentar
  PERFORM set_config('tests.falla_e8', 'cuota_omite', true);
  r := pg_temp.sol(10, 901, '5000000', '12');
  PERFORM tests.assert_eq('plan con 11 de 12 cuotas: solicitar_credito lo rechaza ANTES de asentar y no queda nada',
                          (r, tests.huella_saldos() = h0, pg_temp.ncre(10), pg_temp.ncuo(10))::text, '("Créditos: el plan insertó 11 cuotas y se esperaban 12",t,0,0)'::text);
  -- plan CORRUPTO (capital de la cuota 1 +1): ct_credito_plan lo detecta DENTRO de la funcion (no en el COMMIT) y no queda nada
  PERFORM set_config('tests.falla_e8', 'cuota_corrupta', true);
  r := pg_temp.sol(10, 901, '5000000', '12');
  PERFORM tests.assert_eq('plan que no cuadra con el capital pendiente: ct_credito_plan falla DENTRO de solicitar_credito y se revierte todo',
                          (r LIKE 'Créditos: el plan del crédito <id> no cuadra con su capital pendiente (capital_pendiente=5000000.00, capital de las cuotas impagas=5000001.00)', tests.huella_saldos() = h0, pg_temp.ncre(10), pg_temp.ncuo(10))::text,
                          '(t,t,0,0)'::text);
  PERFORM set_config('tests.falla_e8', '', true);
END $do$;
DROP TRIGGER trg_zz_falla_e8 ON public.credito;
DROP TRIGGER trg_zz_falla_e8 ON public.cuota;
SELECT tests.falla('');
SELECT tests.quitar_fallas();
SELECT assert_eq('sin fallas: el mismo pedido se aprueba y queda UN credito con 12 cuotas y el diferido en orden', (left(pg_temp.sol(10, 901, '5000000', '12'), 3), pg_temp.ncre(10), pg_temp.ncuo(10))::text, '(OK:,1,12)'::text);
CREATE TEMP TABLE t_h6 AS SELECT tests.huella_saldos() AS h;
CREATE TEMP TABLE t_r6 AS SELECT pg_temp.sol(10, 903, '999', '12') AS r;
SELECT assert_eq('un rechazo de negocio (Monto fuera de rango) tampoco deja rastro: huella de saldos y patas intactas', ((SELECT r FROM t_r6), tests.huella_saldos() = (SELECT h FROM t_h6))::text, '("Monto fuera de rango",t)'::text);

-- ============================================================================
-- 7. vista_creditos: forma, ACTIVOS solamente, interes corriendo (derivado, D-E8-4 PROVISIONAL)
-- ============================================================================
SELECT assert_json_shape('vista_creditos: {id, producto, cuotas_pagadas, cuotas_faltantes, interes_mes, saldo}', public.vista_creditos(tests.u(3)) -> 0,
                         '{"id":"string","producto":"string","cuotas_pagadas":"number","cuotas_faltantes":"number","interes_mes":"number","saldo":"number"}'::jsonb);
SELECT assert_eq('credito recien desembolsado (dia 0): 0 pagadas, 12 faltantes, interes_mes 0 y saldo = 10.000.000',
                 (SELECT (e ->> 'producto', e ->> 'cuotas_pagadas', e ->> 'cuotas_faltantes', e ->> 'interes_mes', e ->> 'saldo')::text FROM jsonb_array_elements(public.vista_creditos(tests.u(3))) e),
                 '("Libre inversión",0,12,0.00,10000000.00)'::text);
CREATE TEMP TABLE t_i AS SELECT (SELECT interes_programado FROM public.cuota WHERE credito_id = (SELECT (r ->> 'id')::uuid FROM t_r3) AND numero = 1) AS int1,
                                (SELECT fecha_vencimiento - (SELECT h0 FROM t_c3) FROM public.cuota WHERE credito_id = (SELECT (r ->> 'id')::uuid FROM t_r3) AND numero = 1) AS dias_periodo;
SELECT pg_temp.sig(15);
SELECT assert_eq('a los 15 dias: interes corriendo = round(interes de la cuota 1 * 15 / dias del periodo, 2) (prorrata lineal), calculado de forma independiente',
                 (SELECT e ->> 'interes_mes' FROM jsonb_array_elements(public.vista_creditos(tests.u(3))) e)::numeric, (SELECT round(int1::numeric * 15 / dias_periodo, 2) FROM t_i));
SELECT pg_temp.sig((SELECT dias_periodo FROM t_i)::int - 15);
SELECT assert_eq('el dia del vencimiento: el interes completo de la cuota 1', (SELECT e ->> 'interes_mes' FROM jsonb_array_elements(public.vista_creditos(tests.u(3))) e)::numeric, (SELECT int1::numeric FROM t_i));
SELECT pg_temp.sig(20);
SELECT assert_eq('20 dias DESPUES del vencimiento sin pagar: sigue el interes completo de la cuota 1 (no crece, no hay mora en E8) y no se escribe nada',
                 (SELECT e ->> 'interes_mes' FROM jsonb_array_elements(public.vista_creditos(tests.u(3))) e)::numeric, (SELECT int1::numeric FROM t_i));
SELECT assert_eq('la lectura no escribe asientos de credito: sigue habiendo solo 2 patas de credito en toda la cuenta 3', (SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(3) AND credito_id IS NOT NULL), 2::bigint);
-- fixture de E9 (NO hay funcion publica de pago en E8): se paga la cuota 1 como lo hara E9 y se mueve fecha_interes al vencimiento
SELECT tests.asentar(tests.pata('CREDITO_CUOTA', 'CUENTA', 'S', q.valor_cuota, tests.c(3), NULL, NULL, q.credito_id),
                     tests.pata('CREDITO_CUOTA', 'CREDITO', 'S', q.capital_programado, tests.c(3), NULL, NULL, q.credito_id),
                     tests.pata('CREDITO_CUOTA', 'RESULTADO', 'S', q.interes_programado, tests.c(3), NULL, NULL, q.credito_id, 'Banco Digital'))
  FROM public.cuota q WHERE q.credito_id = (SELECT (r ->> 'id')::uuid FROM t_r3) AND q.numero = 1;
UPDATE public.cuota SET pagada = true, fecha_pago = public.hoy_banco(), capital_pagado = capital_programado, intereses_pagados = interes_programado
 WHERE credito_id = (SELECT (r ->> 'id')::uuid FROM t_r3) AND numero = 1;
UPDATE public.credito SET fecha_interes = public._fecha_vencimiento(fecha_desembolso, 1) WHERE id = (SELECT (r ->> 'id')::uuid FROM t_r3);
SELECT assert_eq('con la cuota 1 pagada (fixture): 1 pagada, 11 faltantes, saldo = 10M - capital de la cuota 1, y el plan sigue cuadrando con el libro',
                 (SELECT (e ->> 'cuotas_pagadas', e ->> 'cuotas_faltantes', (e ->> 'saldo')::numeric = 10000000 - (SELECT capital_programado FROM public.cuota WHERE credito_id = (e ->> 'id')::uuid AND numero = 1))::text
                    FROM jsonb_array_elements(public.vista_creditos(tests.u(3))) e),
                 '(1,11,t)'::text);
SELECT assert_eq('v_integridad_creditos / global en orden tras el pago de la fixture (capital_pendiente = Σ capital de las impagas)', (SELECT (ok, creditos_con_plan_incoherente)::text FROM public.v_integridad_global), '(t,0)'::text);
SELECT assert_eq('el interes corriendo pasa a la cuota 2: hoy = vencimiento 1 + 20 dias dentro de un periodo de ~30 -> mayor que 0 y menor que el interes de la cuota 2',
                 (SELECT ((e ->> 'interes_mes')::numeric > 0, (e ->> 'interes_mes')::numeric < (SELECT interes_programado FROM public.cuota WHERE credito_id = (e ->> 'id')::uuid AND numero = 2))::text
                    FROM jsonb_array_elements(public.vista_creditos(tests.u(3))) e), '(t,t)'::text);
SELECT public._reloj_actualizar(true, '');
SELECT assert_eq('de vuelta al reloj real (hoy < fecha_interes de la cuota 2): el interes corriendo se queda en 0.00 (nunca negativo)',
                 (SELECT e ->> 'interes_mes' FROM jsonb_array_elements(public.vista_creditos(tests.u(3))) e), '0.00'::text);
-- creditos PAGADOS no aparecen: fixture que liquida y cierra un credito
SELECT tests.fondear(tests.c(11), 5000000);
CREATE TEMP TABLE t_r11 AS SELECT pg_temp.sol(11, 901, '1000000', '6') AS r;
SELECT tests.asentar(tests.pata('CREDITO_ABONO', 'CUENTA', 'S', 1000000, tests.c(11), NULL, NULL, substr(r, 4)::uuid), tests.pata('CREDITO_ABONO', 'CREDITO', 'S', 1000000, tests.c(11), NULL, NULL, substr(r, 4)::uuid)) FROM t_r11;
UPDATE public.cuota SET pagada = true, fecha_pago = public.hoy_banco() WHERE credito_id = (SELECT substr(r, 4)::uuid FROM t_r11);
UPDATE public.credito SET estado = 'PAGADO' WHERE id = (SELECT substr(r, 4)::uuid FROM t_r11);
SELECT assert_eq('un credito PAGADO no aparece en vista_creditos y deja de bloquear el producto (se puede pedir otro Libre inversion)',
                 (public.vista_creditos(tests.u(11))::text, left(pg_temp.sol(11, 901, '1000000', '6'), 3))::text, '([],OK:)'::text);

-- ============================================================================
-- 8. Devengo previo (E7) con el reloj adelantado: el tope se calcula con el patrimonio DEVENGADO
-- ============================================================================
SELECT tests.fondear(tests.c(9), 4000000);
SELECT public.mover_a_bolsillo(tests.u(9), public.crear_bolsillo(tests.u(9), 'Ahorro') ->> 'id', 3000000);
CREATE TEMP TABLE t_d AS SELECT public.balance_total(tests.c(9)) AS total0, (SELECT balance FROM public.bolsillo WHERE cuenta_id = tests.c(9)) AS bol0, public.hoy_banco() AS h0;
SELECT pg_temp.sig(30);
CREATE TEMP TABLE t_d1 AS SELECT pg_temp.sol(9, 904, '1000', '12') AS r;                  -- una solicitud valida: devenga y desembolsa
SELECT assert_eq('solicitar con el reloj +30 dias: el motor devengo ANTES (1 grupo INTERES_BOLSO del bolsillo de 3.000.000) y el credito se acepto',
                 (left((SELECT r FROM t_d1), 3), (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE cuenta_id = tests.c(9) AND tipo = 'INTERES_BOLSO'),
                  (SELECT balance FROM public.bolsillo WHERE cuenta_id = tests.c(9)) > (SELECT bol0 FROM t_d))::text, '(OK:,1,t)'::text);
CREATE TEMP TABLE t_d2 AS SELECT (SELECT balance FROM public.bolsillo WHERE cuenta_id = tests.c(9)) - (SELECT bol0 FROM t_d) AS interes, pg_temp.cs(9) AS cuenta;
SELECT assert_eq('el patrimonio neto = patrimonio antes + interes devengado (el credito suma y resta lo mismo); el tope de Inmuebles = 100 x ese valor, calculado de forma independiente',
                 (public._patrimonio_neto(tests.c(9)) = (SELECT total0 + interes FROM t_d, t_d2), (pg_temp.lim(9, 904)::text LIKE '(1.00,' || ((SELECT total0 + interes FROM t_d, t_d2) * 100)::text || ',%'))::text, '(t,t)'::text);
SELECT assert_eq('un segundo Inmuebles queda rechazado por el vigente (u9 y u2)',
                 (pg_temp.sol(9, 904, '1000', '12'),
                  pg_temp.sol(2, 904, '1', '12'))::text, '("Ya tienes un crédito vigente de este producto","Ya tienes un crédito vigente de este producto")'::text);
SELECT assert_eq('tope exacto: cuenta con patrimonio 1.000.000 -> pedir 100.000.000,01 = Monto fuera de rango; 100.000.000,00 = se acepta',
                 (pg_temp.sol(8, 904, '100000000.01', '12'), left(pg_temp.sol(8, 904, '100000000', '12'), 3))::text, '("Monto fuera de rango",OK:)'::text);
SELECT pg_temp.sig(10);
CREATE TEMP TABLE t_g0 AS SELECT count(DISTINCT grupo_id) AS n FROM public.transaccion WHERE cuenta_id = tests.c(9) AND tipo = 'INTERES_BOLSO';
SELECT public.productos_disponibles(tests.u(9));
CREATE TEMP TABLE t_g1 AS SELECT count(DISTINCT grupo_id) AS n FROM public.transaccion WHERE cuenta_id = tests.c(9) AND tipo = 'INTERES_BOLSO';
SELECT public.productos_disponibles(tests.u(9)); SELECT public.vista_creditos(tests.u(9)); SELECT pg_temp.sim(9, 901, '2000000', '12');
SELECT assert_eq('el primer productos_disponibles tras el salto escribe 1 grupo de interes; las 3 lecturas siguientes (disponibles, vista, simular) NO escriben mas',
                 ((SELECT n - (SELECT n FROM t_g0) FROM t_g1), (SELECT count(DISTINCT grupo_id) - (SELECT n FROM t_g1) FROM public.transaccion WHERE cuenta_id = tests.c(9) AND tipo = 'INTERES_BOLSO'))::text, '(1,0)'::text);

-- ============================================================================
-- 9. Permisos y catalogo
-- ============================================================================
SELECT assert_eq('banco_app ejecuta las 5 publicas de E8 y NINGUNA interna; banco_lector no ejecuta ninguna; PUBLIC tampoco',
                 (SELECT (count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE') AND p.proname IN ('productos_disponibles', 'productos_publicos', 'simular_credito', 'solicitar_credito', 'vista_creditos')),
                          count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE') AND p.proname NOT IN ('productos_disponibles', 'productos_publicos', 'simular_credito', 'solicitar_credito', 'vista_creditos')),
                          count(*) FILTER (WHERE has_function_privilege('banco_lector', p.oid, 'EXECUTE')),
                          count(*) FILTER (WHERE EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))::text
                    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('productos_disponibles', 'productos_publicos', 'simular_credito', 'solicitar_credito', 'vista_creditos',
                         '_reglas_credito', '_tasa_mensual', '_fecha_vencimiento', '_plan_cuotas', '_patrimonio_neto', '_interes_corriendo', 'ct_credito_plan', '_producto_credito', '_validar_plazo', '_limites_credito', '_verificar_credito')),
                 '(5,0,0,0)'::text);
SELECT assert_eq('las 5 publicas son SECURITY DEFINER con search_path fijo y dueño banco_owner; ct_credito_plan tambien (el diferido corre con el usuario de la sesion)',
                 (SELECT bool_and(p.prosecdef AND pg_get_userbyid(p.proowner) = 'banco_owner' AND p.proconfig::text LIKE '%search_path=public, pg_temp%')::text FROM pg_proc p
                   WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('productos_disponibles', 'productos_publicos', 'simular_credito', 'solicitar_credito', 'vista_creditos', 'ct_credito_plan')), 'true'::text);
SELECT assert_eq('los 2 triggers ct_credito_plan existen, estan habilitados y son DIFERIDOS',
                 (SELECT count(*)::text || '/' || bool_and(tgenabled = 'O' AND tgdeferrable AND tginitdeferred)::text FROM pg_trigger WHERE tgname IN ('ct_credito_plan', 'ct_credito_plan_cuota') AND NOT tgisinternal), '2/true'::text);
SELECT assert_eq('las 4 que devengan llaman _avanzar_hasta EXACTAMENTE 1 vez y _reloj_instantanea EXACTAMENTE 1 vez, con la instantanea ANTES del devengo; productos_publicos ninguna',
                 (SELECT array_agg(DISTINCT p.proname::text ORDER BY p.proname::text) FILTER (WHERE (length(p.prosrc) - length(replace(p.prosrc, '_avanzar_hasta(', ''))) / length('_avanzar_hasta(') <> 1
                                                                                         OR (length(p.prosrc) - length(replace(p.prosrc, '_reloj_instantanea()', ''))) / length('_reloj_instantanea()') <> 1
                                                                                         OR strpos(p.prosrc, '_reloj_instantanea()') > strpos(p.prosrc, '_avanzar_hasta('))
                    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('productos_disponibles', 'simular_credito', 'solicitar_credito', 'vista_creditos')), NULL::text[]);
SELECT assert_eq('solicitar_credito bloquea la cuenta (_bloquear_cuentas) EXACTAMENTE 1 vez y DESPUES del devengo; ninguna otra funcion de E8 la bloquea por su cuenta',
                 (SELECT ((length(prosrc) - length(replace(prosrc, '_bloquear_cuentas(', ''))) / length('_bloquear_cuentas('), strpos(prosrc, '_avanzar_hasta(') < strpos(prosrc, '_bloquear_cuentas('))::text
                    FROM pg_proc WHERE proname = 'solicitar_credito' AND pronamespace = 'public'::regnamespace), '(1,t)'::text);
SELECT assert_eq('ninguna funcion de E8 lee el reloj ni el tiempo por su cuenta (now, current_date, current_timestamp, clock_timestamp, hoy_banco, ahora_banco, _ahora_real): solo la instantanea',
                 (SELECT array_agg(p.proname::text ORDER BY p.proname::text) FROM pg_proc p
                   WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('productos_disponibles', 'productos_publicos', 'simular_credito', 'solicitar_credito', 'vista_creditos',
                         '_plan_cuotas', '_patrimonio_neto', '_interes_corriendo', '_limites_credito', '_verificar_credito', '_fecha_vencimiento', '_tasa_mensual')
                     AND p.prosrc ~* '(now\(\)|current_date|current_timestamp|clock_timestamp|hoy_banco|ahora_banco|_ahora_real)'), NULL::text[]);
SELECT assert_eq('solicitar_credito escribe el libro SOLO por _asentar_grupo (ningun INSERT INTO transaccion) y los creditos/cuotas SOLO ahi',
                 (SELECT (prosrc !~* 'insert\s+into\s+public\.transaccion', prosrc LIKE '%public._asentar_grupo(%')::text FROM pg_proc WHERE proname = 'solicitar_credito' AND pronamespace = 'public'::regnamespace), '(t,t)'::text);
SELECT assert_eq('estado final: libro y planes de TODA la prueba en orden (partida doble, I5u por cuenta, plan = capital pendiente en cada credito)',
                 (SELECT (ok, contenedores_con_desvio, grupos_con_error, cuentas_con_desvio_i5u, defensas_fallidas, creditos_con_plan_incoherente)::text FROM public.v_integridad_global), '(t,0,0,0,0,0)'::text);

-- ============================================================================
-- 10. UNA instantanea del reloj por operacion (conteo dinamico; _ahora_real solo se sustituye en banco_test/banco_mut, dentro de esta transaccion)
-- ============================================================================
SELECT tests.cliente(13); SELECT tests.fondear(tests.c(13), 50000000);
SELECT public.mover_a_bolsillo(tests.u(13), public.crear_bolsillo(tests.u(13), 'Ahorro') ->> 'id', 1000000);
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
  SELECT (count(*), count(DISTINCT fecha))::text FROM public.transaccion WHERE registrado_en > (SELECT t0 FROM t_m) $f$;
SELECT pg_temp.sig(1);
SELECT setval('pg_temp.sq_lect', 1, false); UPDATE t_m SET t0 = clock_timestamp();
SELECT public.solicitar_credito(tests.u(13), tests.p(901)::text, 2000000, 12);
SELECT assert_eq('solicitar_credito con interes pendiente: 1 lectura (instantanea) + 4 patas (2 del devengo + 2 del desembolso) = 5, y las 4 patas con UN solo ahora', (pg_temp.lect(), pg_temp.legs())::text, '(5,"(4,1)")'::text);
SELECT pg_temp.sig(0);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.simular_credito(tests.u(13), tests.p(903)::text, 2000000, 12);
SELECT assert_eq('simular_credito sin nada pendiente: 1 lectura (solo la instantanea)', pg_temp.lect(), 1);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.vista_creditos(tests.u(13));
SELECT assert_eq('vista_creditos sin nada pendiente: 1 lectura', pg_temp.lect(), 1);
SELECT pg_temp.sig(1);
SELECT setval('pg_temp.sq_lect', 1, false); UPDATE t_m SET t0 = clock_timestamp();
SELECT public.productos_disponibles(tests.u(13));
SELECT assert_eq('productos_disponibles con interes pendiente: 1 + 2 patas = 3 lecturas y UN solo ahora', (pg_temp.lect(), pg_temp.legs())::text, '(3,"(2,1)")'::text);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.productos_publicos();
SELECT assert_eq('productos_publicos NO lee el reloj (0 lecturas)', pg_temp.lect(), 0);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT assert_eq('un rechazo de validacion (monto) no lee el reloj ni devenga', (tests.captura('SELECT public.solicitar_credito(' || quote_literal(tests.u(13)) || '::uuid, ' || quote_literal(tests.p(901)::text) || ', 0, 12)'), pg_temp.lect())::text, '("Monto inválido",0)'::text);
ROLLBACK;
SELECT assert_eq('tras el ROLLBACK _ahora_real() es otra vez el reloj de pared (la sustitucion no sobrevive)', (SELECT pg_get_functiondef(oid) LIKE '%SELECT clock_timestamp()%' FROM pg_proc WHERE oid = 'public._ahora_real()'::regprocedure), true);
