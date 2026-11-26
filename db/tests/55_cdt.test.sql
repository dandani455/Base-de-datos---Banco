-- 55_cdt.test.sql · Etapa 7 · CDT: listar_cdt_definiciones, simular_cdt, crear_cdt y vista_cdts + el devengo y el cierre de los CDT del motor (objetivo
-- acumulado, tope en fecha_fin, vencimiento que acredita monto + generado, copia contractual), atomicidad, una sola instantanea y permisos por rol real.
-- No repite el libro (E2, plantillas CDT_*), el reloj (E3) ni el motor de bolsillos (54). Una transaccion con ROLLBACK final.
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y sustituye _ahora_real() y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 9) n;
INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol)
VALUES ('adminz', tests.hash(), 'Adm', 'In', '9300001', 'adminz@mail.co', '3170000001', DATE '1980-01-01', 'ADMIN');
UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = tests.u(3);

CREATE FUNCTION pg_temp.sig(p_n int) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(false, (public.hoy_banco() + p_n)::text); END $f$;
CREATE FUNCTION pg_temp.salta_a(p_fecha date) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(false, p_fecha::text); END $f$;
CREATE FUNCTION pg_temp.cs(p_n int) RETURNS numeric LANGUAGE sql VOLATILE AS $f$ SELECT balance::numeric FROM public.cuenta WHERE id = tests.c(p_n) $f$;
CREATE FUNCTION pg_temp.ref(p_monto numeric, p_tasa numeric, p_dias int) RETURNS numeric LANGUAGE plpgsql AS $f$   -- REFERENCIA INDEPENDIENTE (bucle por dia)
DECLARE v numeric := p_monto; r numeric := exp(ln(1 + p_tasa / 100) / 365); i int;
BEGIN
  FOR i IN 1..p_dias LOOP v := round(v * r, 14); END LOOP;
  RETURN round(v - p_monto, 2);
END $f$;
-- crear_cdt con captura del error: 'OK:<id del cdt>' o el mensaje
CREATE FUNCTION pg_temp.cr(p_u int, p_def int, p_monto text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  RETURN 'OK:' || (public.crear_cdt(tests.u(p_u), tests.p(p_def)::text, p_monto::numeric) ->> 'id');
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM;
END $f$;
CREATE FUNCTION pg_temp.ncdt(p_cuenta int) RETURNS bigint LANGUAGE sql VOLATILE AS $f$ SELECT count(*) FROM public.cdt WHERE cuenta_id = tests.c(p_cuenta) $f$;
CREATE FUNCTION pg_temp.ngi(p_cdt uuid) RETURNS bigint LANGUAGE sql VOLATILE AS $f$ SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE cdt_id = p_cdt AND tipo = 'INTERES_CDT' $f$;
CREATE FUNCTION pg_temp.vista(p_u int) RETURNS jsonb LANGUAGE sql VOLATILE AS $f$ SELECT public.vista_cdts(tests.u(p_u)) $f$;

-- ============================================================================
-- 1. listar_cdt_definiciones y simular_cdt (no escriben ni leen el reloj)
-- ============================================================================
SELECT assert_eq('sin definiciones (el catalogo real es D11, del equipo): listar devuelve []', public.listar_cdt_definiciones(tests.u(1))::text, '[]'::text);
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES
  (tests.p(901), 'CDT 90', 90, 10, 100000), (tests.p(902), 'CDT 360', 360, 10, 1000000), (tests.p(903), 'CDT 20', 20, 8, 50000);
SELECT assert_eq('listar: [{id, nombre, tasa, plazo_dias, monto_min}] ordenado por plazo y nombre',
                 (SELECT (array_agg(e ->> 'nombre'), array_agg(jsonb_typeof(e -> 'tasa')) , array_agg(jsonb_typeof(e -> 'id')), array_agg(jsonb_typeof(e -> 'plazo_dias')), array_agg(jsonb_typeof(e -> 'monto_min')),
                          (array_agg(e ->> 'tasa'))[2], (array_agg(e ->> 'monto_min'))[2])::text
                    FROM jsonb_array_elements(public.listar_cdt_definiciones(tests.u(1))) e),
                 '("{""CDT 20"",""CDT 90"",""CDT 360""}","{number,number,number}","{string,string,string}","{number,number,number}","{number,number,number}",10.000,100000.00)'::text);
CREATE TEMP TABLE t_h0 AS SELECT tests.huella_saldos() AS h;
SELECT assert_json_shape('simular_cdt devuelve {generado_mes, generado_dia, generado_vencimiento} numericos', public.simular_cdt(tests.u(1), tests.p(902)::text, 1000000),
                         '{"generado_mes":"number","generado_dia":"number","generado_vencimiento":"number"}'::jsonb);
SELECT assert_eq('simular $1.000.000 al 10 % a 360 dias: vencimiento = $98.564,76; dia y mes coinciden con la referencia independiente (+-1 centavo)',
                 (SELECT ((s ->> 'generado_vencimiento')::numeric, abs((s ->> 'generado_dia')::numeric - pg_temp.ref(1000000, 10, 1)) <= 0.01, abs((s ->> 'generado_mes')::numeric - pg_temp.ref(1000000, 10, 30)) <= 0.01)::text
                    FROM (SELECT public.simular_cdt(tests.u(1), tests.p(902)::text, 1000000) AS s) q), '(98564.76,t,t)'::text);
SELECT assert_eq('plazo menor que un mes (20 dias): generado_mes = generado_vencimiento (el mes de 30 dias se topa en el plazo)',
                 (SELECT ((s ->> 'generado_mes') = (s ->> 'generado_vencimiento'))::text FROM (SELECT public.simular_cdt(tests.u(1), tests.p(903)::text, 100000) AS s) q), 'true'::text);
SELECT assert_eq('monto EXACTAMENTE igual al minimo: se acepta; un centavo por debajo: Monto por debajo del mínimo del CDT',
                 (tests.captura($$SELECT public.simular_cdt(tests.u(1), tests.p(901)::text, 100000)$$), tests.captura($$SELECT public.simular_cdt(tests.u(1), tests.p(901)::text, 99999.99)$$))::text,
                 '(,"Monto por debajo del mínimo del CDT")'::text);
SELECT assert_eq('orden de validacion: monto ANTES que definicion (monto 0 con definicion mala = Monto inválido); definicion mal formada/inexistente/NULL = Recurso no encontrado ANTES que el minimo',
                 (tests.captura($$SELECT public.simular_cdt(tests.u(1), 'no-es-uuid', 0)$$), tests.captura($$SELECT public.simular_cdt(tests.u(1), 'no-es-uuid', 1000)$$),
                  tests.captura('SELECT public.simular_cdt(tests.u(1), ' || quote_literal(gen_random_uuid()::text) || ', 1)'), tests.captura($$SELECT public.simular_cdt(tests.u(1), NULL, 1)$$),
                  tests.captura($$SELECT public.simular_cdt(tests.u(1), '', 1)$$))::text,
                 '("Monto inválido","Recurso no encontrado","Recurso no encontrado","Recurso no encontrado","Recurso no encontrado")'::text);
DO $do$
DECLARE f text; u text; i int; r text; esp text[] := ARRAY['Sesión inválida', 'Acceso denegado', 'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla']; mal text := '';
BEGIN
  FOREACH f IN ARRAY ARRAY['listar_cdt_definiciones(%L)', 'simular_cdt(%L, ''x'', 1)', 'crear_cdt(%L, ''x'', 1)', 'vista_cdts(%L)'] LOOP
    i := 0;
    FOREACH u IN ARRAY ARRAY[gen_random_uuid()::text, (SELECT id::text FROM public.usuario WHERE username = 'adminz'), tests.u(3)::text] LOOP
      i := i + 1;
      r := tests.captura('SELECT public.' || format(f, u));
      IF r IS DISTINCT FROM esp[i] THEN mal := mal || f || '#' || i || ' [' || coalesce(r, 'NULL') || ']; '; END IF;
    END LOOP;
  END LOOP;
  PERFORM tests.assert_eq('las 4 funciones exigen sesion viva ANTES de todo (inexistente = Sesión inválida, ADMIN = Acceso denegado, BLOQUEADO = mensaje de bloqueo)', mal, ''::text);
END $do$;
SELECT assert_eq('listar y simular no escriben: la huella de saldos y el numero de patas no cambian', tests.huella_saldos(), (SELECT h FROM t_h0));

-- ============================================================================
-- 2. crear_cdt: atomicidad, copia contractual, patas del libro y total
-- ============================================================================
SELECT tests.fondear(tests.c(1), 5000000);
SELECT tests.fondear(tests.c(6), 1000000);
CREATE TEMP TABLE t_c AS SELECT public.hoy_banco() AS h0, public.balance_total(tests.c(1)) AS total0;
CREATE TEMP TABLE t_r AS SELECT public.crear_cdt(tests.u(1), tests.p(901)::text, 1000000) AS r;
SELECT assert_json_shape('crear_cdt devuelve {id, fecha}', (SELECT r FROM t_r), '{"id":"string","fecha":"string"}'::jsonb);
SELECT assert_eq('el CDT COPIA nombre, monto, tasa y plazo; fecha_inicio = ultimo_cobro = hoy; fecha_fin = hoy + plazo; generado 0; ACTIVO; enlaza la definicion',
                 (SELECT (nombre, monto, tasa_anual, plazo_dias, fecha_fin - fecha_inicio, fecha_inicio = public.hoy_banco(), ultimo_cobro = fecha_inicio, generado_acumulado, estado::text, definicion_id = tests.p(901))::text
                    FROM public.cdt WHERE id = (SELECT (r ->> 'id')::uuid FROM t_r)),
                 '("CDT 90",1000000.00,10.000,90,90,t,t,0.00,ACTIVO,t)'::text);
SELECT assert_eq('el grupo CDT_CREACION: 2 patas (CUENTA S + CDT E) por el monto, UNA sola fecha = la que devuelve crear_cdt, contraparte = nombre del CDT',
                 (SELECT (count(*), count(DISTINCT grupo_id), array_agg(contenedor::text || sentido::text ORDER BY contenedor::text), min(monto)::text, count(DISTINCT fecha),
                          bool_and(fecha = (SELECT (r ->> 'fecha')::timestamptz FROM t_r)), min(contraparte_nombre))::text
                    FROM public.transaccion WHERE cdt_id = (SELECT (r ->> 'id')::uuid FROM t_r) AND tipo = 'CDT_CREACION'),
                 '(2,1,"{CDTE,CUENTAS}",1000000.00,1,t,"CDT 90")'::text);
SELECT assert_eq('la cuenta baja a 4.000.000 y el TOTAL no cambia al crear el CDT (D-E7-5: el total incluye los CDT activos)', (pg_temp.cs(1), public.balance_total(tests.c(1)) = (SELECT total0 FROM t_c))::text, '(4000000.00,t)'::text);
SELECT assert_eq('vista_balance().total tambien incluye el CDT (cuenta + bolsillos + CDT activos)', (public.vista_balance(tests.u(1)) ->> 'total')::numeric, 5000000.00::numeric);
SELECT assert_eq('Monto por debajo del minimo de la definicion: error y NO queda CDT ni patas', (pg_temp.cr(1, 901, '99999.99'), pg_temp.ncdt(1))::text, '("Monto por debajo del mínimo del CDT",1)'::text);
SELECT assert_eq('monto invalido, definicion inexistente y mal formada: sus mensajes y nada escrito',
                 (pg_temp.cr(1, 901, '0'), pg_temp.cr(1, 999, '100000'), tests.captura($$SELECT public.crear_cdt(tests.u(1), 'xx', 100000)$$), pg_temp.ncdt(1))::text,
                 '("Monto inválido","Recurso no encontrado","Recurso no encontrado",1)'::text);
CREATE TEMP TABLE t_h4 AS SELECT tests.huella_saldos() AS h;
CREATE TEMP TABLE t_r4 AS SELECT pg_temp.cr(1, 901, '9000000') AS r;
SELECT assert_eq('Saldo insuficiente (el CDT supera la cuenta): atomico, no queda el CDT ni patas', ((SELECT r FROM t_r4), pg_temp.ncdt(1), tests.huella_saldos() = (SELECT h FROM t_h4))::text, '("Saldo insuficiente",1,t)'::text);
SELECT tests.instalar_fallas();
DO $do$
DECLARE p int; mal text := ''; h0 text; r text;
BEGIN
  h0 := tests.huella_saldos();
  FOR p IN 1..2 LOOP
    PERFORM tests.falla('tx:' || p);
    r := pg_temp.cr(1, 901, '100000');
    IF r NOT LIKE 'FALLA INYECTADA%' OR tests.huella_saldos() <> h0 OR pg_temp.ncdt(1) <> 1 THEN mal := mal || p || ':' || r || '; '; END IF;
  END LOOP;
  PERFORM tests.assert_eq('un fallo en CADA pata de CDT_CREACION revierte el CDT y el asiento: no queda un CDT sin su grupo ni un grupo sin CDT', mal, ''::text);
END $do$;
SELECT tests.falla('');
SELECT tests.quitar_fallas();

-- ============================================================================
-- 3. Devengo por OBJETIVO ACUMULADO en puntos de control (CDT A: $1.000.000 al 10 %, 90 dias; el CDT B igual pero en otra cuenta y consultado UNA vez)
-- ============================================================================
SELECT public.crear_cdt(tests.u(6), tests.p(901)::text, 1000000);
CREATE TEMP TABLE t_ab AS SELECT (SELECT (r ->> 'id')::uuid FROM t_r) AS a, (SELECT id FROM public.cdt WHERE cuenta_id = tests.c(6)) AS b;
CREATE FUNCTION pg_temp.cp(p_d int) RETURNS text LANGUAGE plpgsql AS $f$   -- salta a H0 + p_d, consulta y resume el CDT A: (generado = objetivo(d), grupos INTERES_CDT, dias cobrados)
BEGIN
  PERFORM pg_temp.salta_a((SELECT h0 FROM t_c) + p_d);
  PERFORM public.vista_cdts(tests.u(1));
  RETURN (SELECT (generado_acumulado = round(monto * public._factor_interes(tasa_anual, p_d), 2), pg_temp.ngi(c.id), ultimo_cobro - fecha_inicio)::text FROM public.cdt c WHERE c.id = (SELECT a FROM t_ab));
END $f$;
SELECT assert_eq('dia 7: generado = round(monto * factor(7 dias)); 1 grupo; 7 dias cobrados', pg_temp.cp(7), '(t,1,7)'::text);
SELECT assert_eq('dia 7 OTRA VEZ (misma fecha): objetivo acumulado = lo ya generado; sigue 1 grupo (sin duplicar)', pg_temp.cp(7), '(t,1,7)'::text);
SELECT assert_eq('dia 30: 2 grupos (uno por avance), generado = objetivo(30)', pg_temp.cp(30), '(t,2,30)'::text);
SELECT assert_eq('dia 31: 3 grupos, generado = objetivo(31) (sin deriva de redondeo entre puntos de control)', pg_temp.cp(31), '(t,3,31)'::text);
SELECT assert_eq('vista_cdts a los 31 dias: [{id, monto, generado_hasta_hoy, tiempo_restante "59 dias", fecha_cierre = inicio + 90}]',
                 (SELECT (e ->> 'monto', abs((e ->> 'generado_hasta_hoy')::numeric - pg_temp.ref(1000000, 10, 31)) <= 0.01, e ->> 'tiempo_restante', (((e ->> 'fecha_cierre')::timestamptz AT TIME ZONE 'America/Bogota')::date = (SELECT h0 FROM t_c) + 90 AND (e ->> 'fecha_cierre') ~ 'T00:00:00-05:00$'),
                          jsonb_typeof(e -> 'monto'), jsonb_typeof(e -> 'generado_hasta_hoy'), e ->> 'id' = (SELECT a::text FROM t_ab), jsonb_array_length(pg_temp.vista(1)))::text
                    FROM jsonb_array_elements(pg_temp.vista(1)) e),
                 '(1000000.00,t,"59 días",t,number,number,t,1)'::text);
SELECT assert_eq('dia 89: 4 grupos, generado = objetivo(89); tiempo_restante = "1 dia"', (pg_temp.cp(89), pg_temp.vista(1) -> 0 ->> 'tiempo_restante')::text, '("(t,4,89)","1 día")'::text);
SELECT public.vista_cdts(tests.u(6));
SELECT assert_eq('INDEPENDENCIA DEL CAMINO EXACTA: el CDT consultado 4 veces (A) y el consultado UNA vez (B) tienen EXACTAMENTE el mismo generado a los 89 dias',
                 (SELECT (a.generado_acumulado = b.generado_acumulado, pg_temp.ngi(b.id))::text FROM public.cdt a, public.cdt b WHERE a.id = (SELECT a FROM t_ab) AND b.id = (SELECT b FROM t_ab)), '(t,1)'::text);
SELECT assert_eq('el TOTAL con un CDT activo = cuenta + monto + generado (la cuenta no cambia con el devengo)', public.balance_total(tests.c(1)) - pg_temp.cs(1),
                 1000000 + (SELECT generado_acumulado::numeric FROM public.cdt WHERE id = (SELECT a FROM t_ab)));
SELECT assert_raises('ultimo_cobro del CDT no retrocede (guardia monotonica, D-E7-8)', $$UPDATE public.cdt SET ultimo_cobro = ultimo_cobro - 1 WHERE cuenta_id = tests.c(1)$$, '%ultimo_cobro no puede retroceder%', 'P0001');
SELECT assert_ok('...pero un valor IGUAL se acepta', $$UPDATE public.cdt SET ultimo_cobro = ultimo_cobro WHERE cuenta_id = tests.c(1)$$);

-- ============================================================================
-- 4. Vencimiento: cierre, acreditacion de monto + generado, fechas, nada mas despues
-- ============================================================================
CREATE TEMP TABLE t_pre AS SELECT pg_temp.cs(1) AS cuenta, (SELECT generado_acumulado FROM public.cdt WHERE id = (SELECT a FROM t_ab)) AS gen89,
                                  (public.simular_cdt(tests.u(1), tests.p(901)::text, 1000000) ->> 'generado_vencimiento')::numeric AS sim;
SELECT pg_temp.salta_a((SELECT h0 FROM t_c) + 95);
CREATE TEMP TABLE t_v AS SELECT pg_temp.vista(1) AS v;
SELECT assert_eq('5 dias despues de fecha_fin: CERRADO, ultimo_cobro = fecha_fin, generado = objetivo(90) (el interes NO pasa de fecha_fin)',
                 (SELECT (estado::text, ultimo_cobro = fecha_fin, generado_acumulado = round(monto * public._factor_interes(tasa_anual, 90), 2), pg_temp.ngi(id))::text FROM public.cdt WHERE id = (SELECT a FROM t_ab)), '(CERRADO,t,t,5)'::text);
SELECT assert_eq('la simulacion hecha al crear coincide EXACTAMENTE con lo realmente generado al vencimiento (misma formula y redondeo)',
                 (SELECT sim = (SELECT generado_acumulado FROM public.cdt WHERE id = (SELECT a FROM t_ab)) FROM t_pre), true);
SELECT assert_eq('la cuenta recibe monto + generado: antes + 1.000.000 + generado final (y el total ya no cuenta el CDT cerrado)',
                 (pg_temp.cs(1) = (SELECT cuenta FROM t_pre) + 1000000 + (SELECT generado_acumulado FROM public.cdt WHERE id = (SELECT a FROM t_ab)),
                  public.balance_total(tests.c(1)) = pg_temp.cs(1))::text, '(t,t)'::text);
SELECT assert_eq('CDT_VENCIMIENTO: 2 patas (CDT S + CUENTA E) por monto + generado, fechadas en fecha_fin 00:00 de Bogota; el ultimo INTERES_CDT tiene la MISMA fecha',
                 (SELECT (count(*), count(DISTINCT grupo_id), array_agg(contenedor::text || sentido::text ORDER BY contenedor::text), min(monto) = 1000000 + (SELECT gen FROM (SELECT generado_acumulado AS gen FROM public.cdt WHERE id = (SELECT a FROM t_ab)) z),
                          bool_and(fecha = ((SELECT fecha_fin FROM public.cdt WHERE id = (SELECT a FROM t_ab))::timestamp AT TIME ZONE 'America/Bogota')),
                          (SELECT bool_and(t2.fecha = ((SELECT fecha_fin FROM public.cdt WHERE id = (SELECT a FROM t_ab))::timestamp AT TIME ZONE 'America/Bogota'))
                             FROM public.transaccion t2 WHERE t2.cdt_id = (SELECT a FROM t_ab) AND t2.tipo = 'INTERES_CDT' AND (t2.fecha AT TIME ZONE 'America/Bogota')::date > (SELECT h0 FROM t_c) + 89))::text
                    FROM public.transaccion WHERE cdt_id = (SELECT a FROM t_ab) AND tipo = 'CDT_VENCIMIENTO'),
                 '(2,1,"{CDTS,CUENTAE}",t,t,t)'::text);
SELECT assert_eq('vista_cdts muestra el CDT CERRADO: tiempo_restante "Cerrado", fecha_cierre, generado final',
                 (SELECT (e ->> 'tiempo_restante', (((e ->> 'fecha_cierre')::timestamptz AT TIME ZONE 'America/Bogota')::date = (SELECT h0 FROM t_c) + 90 AND (e ->> 'fecha_cierre') ~ 'T00:00:00-05:00$'), (e ->> 'generado_hasta_hoy')::numeric = (SELECT generado_acumulado FROM public.cdt WHERE id = (SELECT a FROM t_ab)))::text
                    FROM jsonb_array_elements((SELECT v FROM t_v)) e WHERE e ->> 'id' = (SELECT a::text FROM t_ab)), '(Cerrado,t,t)'::text);
CREATE TEMP TABLE t_h5 AS SELECT tests.huella_saldos() AS h;
SELECT pg_temp.salta_a((SELECT h0 FROM t_c) + 500);
SELECT public.vista_cdts(tests.u(1));
SELECT public.vista_balance(tests.u(1));
SELECT assert_eq('400 dias despues de cerrado NO se devenga ni se acredita nada mas (huella igual salvo el CDT B, que tambien cerro)', pg_temp.ngi((SELECT a FROM t_ab)), 5::bigint);
SELECT assert_eq('un CDT cerrado nunca se reabre (guardia de E2)', tests.captura($$UPDATE public.cdt SET estado = 'ACTIVO' WHERE cuenta_id = tests.c(1)$$), 'Libro mayor: un CDT cerrado no se reabre'::text);

-- ============================================================================
-- 5. Copia contractual: editar o borrar la definicion no afecta a los CDT creados (cuenta 2)
-- ============================================================================
SELECT tests.fondear(tests.c(2), 6000000);
SELECT pg_temp.cr(2, 902, '2000000');
UPDATE public.cdt_definicion SET tasa_anual = 50, plazo_dias = 30 WHERE id = tests.p(902);          -- simula la edicion de tasas del admin (E11)
SELECT pg_temp.cr(2, 902, '2000000');
SELECT assert_eq('tras editar la definicion: el CDT viejo conserva (10 %, 360 d) y el nuevo copia (50 %, 30 d)',
                 (SELECT array_agg((tasa_anual, plazo_dias)::text ORDER BY plazo_dias DESC) FROM public.cdt WHERE cuenta_id = tests.c(2)), '{"(10.000,360)","(50.000,30)"}'::text[]);
DELETE FROM public.cdt_definicion WHERE id = tests.p(902);
SELECT assert_eq('borrar la definicion deja los CDT ACTIVOS con definicion_id NULL (FK SET NULL)', (SELECT (count(*), count(definicion_id), count(*) FILTER (WHERE estado = 'ACTIVO'))::text FROM public.cdt WHERE cuenta_id = tests.c(2)), '(2,0,2)'::text);
SELECT pg_temp.sig(10);
SELECT public.vista_cdts(tests.u(2));
SELECT assert_eq('a los 10 dias cada CDT devenga segun SU copia (10 % y 50 %), no segun la definicion editada o borrada',
                 (SELECT array_agg(generado_acumulado = round(monto * public._factor_interes(tasa_anual, 10), 2) ORDER BY tasa_anual) FROM public.cdt WHERE cuenta_id = tests.c(2)), ARRAY[true, true]::boolean[]);
SELECT assert_eq('...y los dos generan algo distinto (la tasa copiada importa)', (SELECT count(DISTINCT generado_acumulado) FROM public.cdt WHERE cuenta_id = tests.c(2)), 2::bigint);

-- ============================================================================
-- 6. Salto de 10 anos en UNA llamada: interes topado en el plazo, un solo asiento de cada clase
-- ============================================================================
SELECT tests.fondear(tests.c(9), 1000000);
SELECT pg_temp.cr(9, 901, '1000000');
SELECT pg_temp.sig(3650);
SELECT public.vista_cdts(tests.u(9));
SELECT assert_eq('10 anos despues (3.650 dias): 1 grupo INTERES_CDT + 1 CDT_VENCIMIENTO; generado = objetivo del PLAZO (90 dias), no de 3.650',
                 (SELECT (estado::text, pg_temp.ngi(id), (SELECT count(DISTINCT grupo_id) FROM public.transaccion t WHERE t.cdt_id = c.id AND t.tipo = 'CDT_VENCIMIENTO'),
                          generado_acumulado = round(monto * public._factor_interes(tasa_anual, 90), 2), pg_temp.cs(9) = 1000000 + generado_acumulado)::text FROM public.cdt c WHERE c.cuenta_id = tests.c(9)),
                 '(CERRADO,1,1,t,t)'::text);

-- ============================================================================
-- 7. Varios CDT a la vez: se cierran en orden de fecha_fin y en una sola operacion (cuenta 4)
-- ============================================================================
SELECT tests.fondear(tests.c(4), 1000000);
SELECT pg_temp.cr(4, 901, '300000');                       -- 90 dias (se crea PRIMERO)
SELECT pg_temp.cr(4, 903, '300000');                       -- 20 dias
SELECT pg_temp.sig(100);
SELECT public.vista_cdts(tests.u(4));
SELECT assert_eq('un solo vista_cdts cierra los DOS; el de 20 dias se cierra ANTES (orden fecha_fin, id) aunque se creo despues',
                 (SELECT ((SELECT count(*) FROM public.cdt WHERE cuenta_id = tests.c(4) AND estado = 'CERRADO'),
                          (SELECT min(t.orden) FROM public.transaccion t JOIN public.cdt c ON c.id = t.cdt_id WHERE c.cuenta_id = tests.c(4) AND c.plazo_dias = 20 AND t.tipo = 'CDT_VENCIMIENTO')
                            < (SELECT min(t.orden) FROM public.transaccion t JOIN public.cdt c ON c.id = t.cdt_id WHERE c.cuenta_id = tests.c(4) AND c.plazo_dias = 90 AND t.tipo = 'CDT_VENCIMIENTO'))::text),
                 '(2,t)'::text);

-- ============================================================================
-- 8. Integracion con E5: la transferencia usa el dinero que el CDT vencido acaba de acreditar (cuenta 5)
-- ============================================================================
SELECT tests.fondear(tests.c(5), 1000000);
SELECT pg_temp.cr(5, 903, '1000000');
SELECT assert_eq('la cuenta queda en 0 al invertirlo todo', pg_temp.cs(5), 0.00::numeric);
SELECT pg_temp.sig(25);
CREATE TEMP TABLE t_g AS SELECT round(1000000 * public._factor_interes(8, 20), 2) AS gen;
SELECT assert_eq('hacer_transferencia por monto + generado (el CDT vencio hace 5 dias): el motor cierra y acredita ANTES del libro, y el envio funciona',
                 (SELECT public.hacer_transferencia(tests.u(5), '4000000008', 1000000 + (SELECT gen FROM t_g), NULL, NULL) IS NOT NULL), true);
SELECT assert_eq('origen en 0 y destino con el monto', (pg_temp.cs(5), pg_temp.cs(8) = 1000000 + (SELECT gen FROM t_g), (SELECT estado::text FROM public.cdt WHERE cuenta_id = tests.c(5)))::text, '(0.00,t,CERRADO)'::text);

-- ============================================================================
-- 9. Integridad global y permisos por rol real
-- ============================================================================
SELECT assert_true('v_integridad_global OK tras todo (partida doble, inversion del CDT, generado = suma de patas, I5u)', (SELECT ok FROM public.v_integridad_global));
SELECT assert_eq('_reglas_cdt: mes de 30 dias (D-E7-7, PROVISIONAL) y el mensaje exacto del contrato, en UN solo lugar', public._reglas_cdt(), '{"mes_dias":30,"msg_minimo":"Monto por debajo del mínimo del CDT"}'::jsonb);
SELECT assert_eq('_texto_tiempo_restante: 45 dias, 1 dia, Cerrado y el caso defensivo (0 dias)',
                 (public._texto_tiempo_restante(DATE '2027-01-15', DATE '2026-12-01', 'ACTIVO'), public._texto_tiempo_restante(DATE '2026-12-02', DATE '2026-12-01', 'ACTIVO'),
                  public._texto_tiempo_restante(DATE '2026-12-02', DATE '2026-12-01', 'CERRADO'), public._texto_tiempo_restante(DATE '2026-12-01', DATE '2026-12-01', 'ACTIVO'))::text,
                 '("45 días","1 día",Cerrado,"0 días")'::text);
SELECT set_config('tests.e', tests.u(1)::text, true);
SELECT set_config('tests.p', tests.p(901)::text, true);
SELECT assert_ok('banco_app ejecuta las 4 publicas de CDT',
   $$SET LOCAL ROLE banco_app; SELECT public.listar_cdt_definiciones(current_setting('tests.e')::uuid); SELECT public.simular_cdt(current_setting('tests.e')::uuid, current_setting('tests.p'), 200000);
     SELECT public.crear_cdt(current_setting('tests.e')::uuid, current_setting('tests.p'), 200000); SELECT public.vista_cdts(current_setting('tests.e')::uuid)$$);
SELECT assert_ok('banco_dev (hereda de banco_app) tambien: vista_cdts', $$SET LOCAL ROLE banco_dev; SELECT public.vista_cdts(current_setting('tests.e')::uuid)$$);
DO $do$
DECLARE f text; r text; mal text := ''; v_msg text;
BEGIN
  FOREACH f IN ARRAY ARRAY['listar_cdt_definiciones(current_setting(''tests.e'')::uuid)', 'simular_cdt(current_setting(''tests.e'')::uuid, ''x'', 1)', 'crear_cdt(current_setting(''tests.e'')::uuid, ''x'', 1)', 'vista_cdts(current_setting(''tests.e'')::uuid)'] LOOP
    v_msg := coalesce(tests.captura('SET LOCAL ROLE banco_lector; SELECT public.' || f), ''); RESET ROLE;
    IF v_msg NOT LIKE 'permission denied for function%' THEN mal := mal || 'lector:' || f || '; '; END IF;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['_reglas_cdt()', '_definicion_cdt(''x'')', '_texto_tiempo_restante(CURRENT_DATE, CURRENT_DATE, ''ACTIVO'')', '_factor_interes(12, 30)', '_avanzar_hasta(gen_random_uuid(), CURRENT_DATE, now())',
                           '_devengar_bolsillos(gen_random_uuid(), CURRENT_DATE, now())', '_devengar_cdts(gen_random_uuid(), CURRENT_DATE, now())', '_bloquear_cuentas(ARRAY[gen_random_uuid()])'] LOOP
    FOREACH r IN ARRAY ARRAY['banco_app', 'banco_lector', 'banco_dev'] LOOP
      v_msg := coalesce(tests.captura('SET LOCAL ROLE ' || r || '; SELECT public.' || f), ''); RESET ROLE;
      IF v_msg NOT LIKE 'permission denied for function%' THEN mal := mal || r || ':' || f || '; '; END IF;
    END LOOP;
  END LOOP;
  PERFORM tests.assert_eq('banco_lector NO ejecuta las 4 publicas, y las 8 internas dan permission denied a banco_app, banco_lector y banco_dev', mal, ''::text);
END $do$;
SELECT assert_eq('ACL: las 4 publicas solo banco_owner y banco_app; los 3 helpers de CDT solo banco_owner',
                 (SELECT (array_agg(DISTINCT pg_get_userbyid(a.grantee)::text) FILTER (WHERE p.proname IN ('listar_cdt_definiciones', 'simular_cdt', 'crear_cdt', 'vista_cdts')),
                          array_agg(DISTINCT pg_get_userbyid(a.grantee)::text) FILTER (WHERE p.proname IN ('_reglas_cdt', '_definicion_cdt', '_texto_tiempo_restante')))::text
                    FROM pg_proc p, aclexplode(p.proacl) a WHERE p.pronamespace = 'public'::regnamespace AND a.privilege_type = 'EXECUTE'),
                 '("{banco_app,banco_owner}",{banco_owner})'::text);
SELECT assert_eq('las 4 publicas son SECURITY DEFINER (simular/listar STABLE); los 3 helpers y las 6 internas del motor no; todas con search_path fijo y COMMENT',
                 (SELECT (count(*) FILTER (WHERE prosecdef), count(*) FILTER (WHERE NOT prosecdef), bool_and('search_path=public, pg_temp' = ANY (proconfig)), bool_and(obj_description(oid, 'pg_proc') IS NOT NULL),
                          count(*) FILTER (WHERE provolatile = 's'))::text
                    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('listar_cdt_definiciones', 'simular_cdt', 'crear_cdt', 'vista_cdts', '_reglas_cdt', '_definicion_cdt', '_texto_tiempo_restante',
                                                                                              '_avanzar_hasta', '_devengar_bolsillos', '_devengar_cdts', '_factor_interes', '_bloquear_cuentas', 'trg_ultimo_cobro_monotono')),
                 '(4,9,t,t,3)'::text);
SELECT assert_raises('banco_app NO inserta CDT ni toca saldos a mano (permission denied)', $$SET LOCAL ROLE banco_app; INSERT INTO public.cdt (cuenta_id, nombre, monto, tasa_anual, plazo_dias, fecha_inicio, fecha_fin, ultimo_cobro) VALUES (gen_random_uuid(), 'x', 1, 1, 1, CURRENT_DATE, CURRENT_DATE + 1, CURRENT_DATE)$$, NULL, '42501');
SELECT tests.detecta('REVOKE de crear_cdt a banco_app (el front no podria abrir CDT) lo detecta la lista blanca de v_integridad_defensas',
   $s$REVOKE EXECUTE ON FUNCTION public.crear_cdt(uuid, text, numeric) FROM banco_app$s$, $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_defensas WHERE NOT ok AND control LIKE 'banco_app ejecuta EXACTAMENTE%')$d$);
SELECT tests.detecta('GRANT EXECUTE de _avanzar_hasta (interna) a banco_app lo detecta la lista blanca',
   $s$GRANT EXECUTE ON FUNCTION public._avanzar_hasta(uuid, date, timestamptz) TO banco_app$s$, $d$SELECT EXISTS (SELECT 1 FROM public.v_integridad_defensas WHERE NOT ok)$d$);
SELECT assert_true('la lista blanca de banco_app tiene EXACTAMENTE 40 funciones (E4-E12) y esta en orden', (SELECT ok FROM public.v_integridad_defensas WHERE control LIKE 'banco_app ejecuta EXACTAMENTE las 40%'));

-- ============================================================================
-- 10. UNA instantanea del reloj por operacion (conteo dinamico; _ahora_real solo se sustituye en banco_test/banco_mut, dentro de esta transaccion)
-- ============================================================================
SELECT tests.fondear(tests.c(7), 3000000);
CREATE TEMP SEQUENCE sq_lect;
GRANT USAGE, SELECT, UPDATE ON SEQUENCE sq_lect TO banco_owner;
CREATE OR REPLACE FUNCTION public._ahora_real() RETURNS timestamptz LANGUAGE plpgsql VOLATILE SET search_path = public, pg_temp AS $f$
BEGIN
  RETURN '2026-11-21 10:00:00-05'::timestamptz + make_interval(secs => nextval('pg_temp.sq_lect')::int);
END $f$;
CREATE FUNCTION pg_temp.lect() RETURNS int LANGUAGE sql VOLATILE AS $f$ SELECT CASE WHEN is_called THEN last_value::int ELSE 0 END FROM pg_temp.sq_lect $f$;
SELECT setval('pg_temp.sq_lect', 1, false);
CREATE TEMP TABLE t_x AS SELECT public.crear_cdt(tests.u(7), tests.p(903)::text, 100000) AS r;
SELECT assert_eq('crear_cdt: 1 lectura (instantanea) + 2 patas de CDT_CREACION = 3; ambas patas con el ahora de la instantanea (T+1s) y el mismo que devuelve la funcion',
                 (pg_temp.lect(), (SELECT (count(*), count(DISTINCT fecha), bool_and(fecha = (SELECT (r ->> 'fecha')::timestamptz FROM t_x)), bool_and(to_char(fecha AT TIME ZONE 'America/Bogota', 'HH24:MI:SS') = '10:00:01'))::text
                                      FROM public.transaccion WHERE cdt_id = (SELECT (r ->> 'id')::uuid FROM t_x) AND tipo = 'CDT_CREACION'))::text, '(3,"(2,1,t,t)")'::text);
SELECT pg_temp.sig(5);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.vista_cdts(tests.u(7));
SELECT assert_eq('vista_cdts con interes pendiente: 1 + 2 patas de INTERES_CDT = 3 lecturas', pg_temp.lect(), 3);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.vista_cdts(tests.u(7));
SELECT assert_eq('vista_cdts sin nada pendiente: 1 lectura (solo la instantanea)', pg_temp.lect(), 1);
SELECT pg_temp.sig(30);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.vista_cdts(tests.u(7));
SELECT assert_eq('vista_cdts que CIERRA el CDT: 1 + 2 (ultimo interes) + 2 (vencimiento) = 5 lecturas', pg_temp.lect(), 5);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT assert_eq('un rechazo de validacion (monto bajo el minimo) no lee el reloj ni devenga', (pg_temp.cr(7, 903, '1'), pg_temp.lect())::text, '("Monto por debajo del mínimo del CDT",0)'::text);

ROLLBACK;

SELECT assert_eq('tras el ROLLBACK _ahora_real() es otra vez el reloj de pared (la sustitucion no sobrevive)', (SELECT pg_get_functiondef(oid) LIKE '%SELECT clock_timestamp()%' FROM pg_proc WHERE oid = 'public._ahora_real()'::regprocedure), true);
SELECT assert_eq('tras el ROLLBACK el reloj vuelve a modo real (los saltos de fecha no sobreviven)', (SELECT usar_fecha_real FROM public.reloj WHERE id = 1), true);
