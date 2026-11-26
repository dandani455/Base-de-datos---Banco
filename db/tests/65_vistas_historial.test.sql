-- 65_vistas_historial.test.sql · Etapa 10 · vista_historial, vista_dashboard y v_transaccion_usuario: la regla de «fila visible» (UNA fila por operacion del libro) con TODOS los tipos
-- de transaccion, la direccion por sentido, la contraparte y su respaldo, el orden por `orden` (cobros atrasados), el limite, D8 configurable, la coherencia del dashboard con los otros
-- endpoints, la falla inyectada en un cobro disparado por el dashboard, el uso del indice y UNA sola instantanea del reloj.
-- No repite el libro (E2), el motor (E7) ni los pagos (E9). Una transaccion con ROLLBACK final; solo corre en banco_test/banco_mut (mueve el reloj).
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 9) n;
UPDATE public.parametro SET tasa_mora_anual = 30;                           -- fixture de prueba (D7 provisional)
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES
  (tests.p(901), 'Libre', '', 18, 1, 1000000000, 1, 360), (tests.p(902), 'Vehiculo', '', 18, 1, 1000000000, 1, 360);
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES (tests.p(930), 'CDT 30', 30, 10, 1);
CREATE TEMP TABLE t_b AS SELECT public.hoy_banco() AS d;
CREATE FUNCTION pg_temp.dia(p_n int) RETURNS date LANGUAGE sql STABLE AS $f$ SELECT (SELECT d FROM t_b) + p_n $f$;
CREATE FUNCTION pg_temp.ir(p_n int) RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(false, pg_temp.dia(p_n)::text); END $f$;
CREATE FUNCTION pg_temp.real() RETURNS void LANGUAGE plpgsql AS $f$ BEGIN PERFORM public._reloj_actualizar(true, ''); END $f$;
CREATE FUNCTION pg_temp.num(p_u int) RETURNS text LANGUAGE sql STABLE AS $f$ SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(p_u) $f$;
CREATE FUNCTION pg_temp.cre(p_u int, p_prod int, p_monto numeric, p_plazo int) RETURNS uuid LANGUAGE sql AS $f$
  SELECT (public.solicitar_credito(tests.u(p_u), tests.p(p_prod)::text, p_monto, p_plazo) ->> 'id')::uuid $f$;
-- historial como filas 'tipo_detalle|tipo|monto|contraparte|nota' en orden de insercion ASCENDENTE (monto '#' en los importes calculados por el motor)
CREATE FUNCTION pg_temp.fila(e jsonb, p_enmascarar boolean) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT concat_ws('|', e ->> 'tipo_detalle', e ->> 'tipo', CASE WHEN p_enmascarar AND e ->> 'tipo_detalle' IN ('INTERES_CDT', 'CDT_VENCIMIENTO', 'CREDITO_CUOTA', 'CREDITO_MORA') THEN '#' ELSE e ->> 'monto' END,
                   e ->> 'contraparte', coalesce(CASE WHEN e ->> 'tipo_detalle' = 'INTERES_BOLSO' THEN 'dias' ELSE e ->> 'nota' END, '-')) $f$;
CREATE FUNCTION pg_temp.lista(p_h jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT coalesce(string_agg(pg_temp.fila(e, true), E'\n' ORDER BY o DESC) FILTER (WHERE e ->> 'tipo_detalle' <> 'INTERES_BOLSO'), '') FROM jsonb_array_elements(p_h) WITH ORDINALITY x(e, o) $f$;

-- ============================================================================
-- A. Historial con TODOS los tipos (usuario 1): una fila por operacion, direccion por sentido, contraparte y nota
-- ============================================================================
SELECT pg_temp.real();
SELECT tests.fondear(tests.c(1), 5000000);                                                                           -- INGRESO_SIMULADO: la pata CUENTA no trae contraparte -> respaldo «Banco Digital»
SELECT public._asentar_grupo(now(), tests.g_ingreso(tests.c(1), 50000, 'BONO_REFERIDO'));
SELECT public._asentar_grupo(now(), tests.g_ingreso(tests.c(1), 1000000, 'DEPOSITO_BANCO'));
SELECT public._asentar_grupo(now(), jsonb_build_array(tests.pata('AJUSTE_ADMIN', 'CUENTA', 'E', 100000, tests.c(1)) || jsonb_build_object('nota', 'ajuste admin +'), tests.pata('AJUSTE_ADMIN', 'RESULTADO', 'E', 100000, tests.c(1))));
SELECT public._asentar_grupo(now(), jsonb_build_array(tests.pata('AJUSTE_ADMIN', 'CUENTA', 'S', 20000, tests.c(1)) || jsonb_build_object('nota', 'ajuste admin -'), tests.pata('AJUSTE_ADMIN', 'RESULTADO', 'S', 20000, tests.c(1))));
SELECT tests.fondear(tests.c(2), 1000000);
SELECT public.hacer_transferencia(tests.u(1), pg_temp.num(2), 300000, 'arriendo', NULL);
SELECT public.hacer_transferencia(tests.u(2), pg_temp.num(1), 50000, 'devuelta', NULL);
CREATE TEMP TABLE t_bol AS SELECT public.crear_bolsillo(tests.u(1), 'Viajes') ->> 'id' AS b1, public.crear_bolsillo(tests.u(1), 'Emergencias') ->> 'id' AS b2;
SELECT public.mover_a_bolsillo(tests.u(1), (SELECT b1 FROM t_bol), 1000000);
SELECT public.mover_entre_bolsillos(tests.u(1), (SELECT b1 FROM t_bol), (SELECT b2 FROM t_bol), 200000);
SELECT public.retirar_de_bolsillo(tests.u(1), (SELECT b2 FROM t_bol), 50000);
SELECT public.hacer_transferencia(tests.u(1), pg_temp.num(2), 30000, 'desde bolsillo', (SELECT b1 FROM t_bol));
SELECT public.crear_cdt(tests.u(1), tests.p(930)::text, 2000000);
CREATE TEMP TABLE t_k AS SELECT pg_temp.cre(1, 901, 5000000, 12) AS k;
SELECT public.pagar_cuota(tests.u(1), (SELECT k FROM t_k)::text);
SELECT pg_temp.ir(45);                                                                                               -- el CDT (30 dias) vence y los bolsillos devengan: lo escribe el motor al leer
SELECT public.abonar_credito(tests.u(1), (SELECT k FROM t_k)::text, 1000000);
SELECT pg_temp.ir((SELECT fecha_vencimiento - (SELECT d FROM t_b) + 10 FROM public.cuota WHERE credito_id = (SELECT k FROM t_k) AND numero = 2));
SELECT public.pagar_cuota(tests.u(1), (SELECT k FROM t_k)::text);                                                    -- cuota 2 con 10 dias de mora
CREATE TEMP TABLE t_h1 AS SELECT public.vista_historial(tests.u(1), 50) AS h;

SELECT assert_eq('A1 una fila por OPERACION: tantas filas como grupos con una pata de liquidez (CUENTA/BOLSILLO/CDT) de la cuenta (oraculo independiente, 23 operaciones)',
                 concat_ws('|', jsonb_array_length((SELECT h FROM t_h1)), (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE cuenta_id = tests.c(1) AND contenedor IN ('CUENTA', 'BOLSILLO', 'CDT'))), '23|23'::text);
SELECT assert_eq('A2 las 19 filas no-interes-de-bolsillo, en orden de insercion: tipo real, direccion por sentido, monto, contraparte (con la cuenta SOLO entre cuentas) y nota; # = importe del motor',
                 pg_temp.lista((SELECT h FROM t_h1)),
                 concat_ws(E'\n', 'INGRESO_SIMULADO|recibo|5000000.00|Banco Digital|-', 'BONO_REFERIDO|recibo|50000.00|Banco Digital|-', 'DEPOSITO_BANCO|recibo|1000000.00|Banco Digital|-',
                   'AJUSTE_ADMIN|recibo|100000.00|Banco Digital|ajuste admin +', 'AJUSTE_ADMIN|envio|20000.00|Banco Digital|ajuste admin -',
                   'ENVIO|envio|300000.00|Nombre2 Apellido · 4000000002|arriendo', 'RECIBO|recibo|50000.00|Nombre2 Apellido · 4000000002|devuelta',
                   'BOLSO_INGRESO|envio|1000000.00|Viajes|-', 'BOLSO_MOVIMIENTO|envio|200000.00|Emergencias|-', 'BOLSO_RETIRO|recibo|50000.00|Emergencias|-',
                   'ENVIO|envio|30000.00|Nombre2 Apellido · 4000000002|desde bolsillo', 'CDT_CREACION|envio|2000000.00|CDT 30|-', 'CREDITO_DESEMBOLSO|recibo|5000000.00|Libre|-',
                   'CREDITO_CUOTA|envio|#|Libre|-', 'INTERES_CDT|recibo|#|Banco Digital|30 días', 'CDT_VENCIMIENTO|recibo|#|CDT 30|-', 'CREDITO_ABONO|envio|1000000.00|Libre|-',
                   'CREDITO_CUOTA|envio|#|Libre|-', 'CREDITO_MORA|envio|#|Libre|Mora cuota 2'));
SELECT assert_eq('A3 los 4 INTERES_BOLSO que escribio el motor (2 bolsillos x 2 saltos): recibo, "Banco Digital", nota "N dias" y monto > 0',
                 (SELECT concat_ws('|', count(*), bool_and(e ->> 'tipo' = 'recibo'), bool_and(e ->> 'contraparte' = 'Banco Digital'), bool_and(e ->> 'nota' ~ '^[0-9]+ días$'), bool_and((e ->> 'monto')::numeric > 0))
                    FROM jsonb_array_elements((SELECT h FROM t_h1)) e WHERE e ->> 'tipo_detalle' = 'INTERES_BOLSO'), '4|t|t|t|t'::text);
SELECT assert_eq('A4 cada fila es una pata REAL de MI cuenta en un contenedor de liquidez, con el mismo tipo, monto y sentido (envio = S, recibo = E); nunca una pata CREDITO ni RESULTADO',
                 (SELECT count(*) FROM jsonb_array_elements((SELECT h FROM t_h1)) e
                   WHERE NOT EXISTS (SELECT 1 FROM public.transaccion t WHERE t.id = (e ->> 'id')::uuid AND t.cuenta_id = tests.c(1) AND t.contenedor IN ('CUENTA', 'BOLSILLO', 'CDT')
                                        AND t.tipo::text = e ->> 'tipo_detalle' AND t.monto = (e ->> 'monto')::numeric AND (t.sentido = 'S') = (e ->> 'tipo' = 'envio'))), 0::bigint);
SELECT assert_eq('A5 recientes primero POR ORDEN (estrictamente decreciente), ids unicos, tipo solo envio/recibo, contraparte nunca null y fecha ISO con zona de Bogota',
                 (SELECT concat_ws('|', bool_and(o_ant IS NULL OR o_ant > o), count(DISTINCT id) = count(*), bool_and(tipo IN ('envio', 'recibo')), bool_and(cp IS NOT NULL), bool_and(f ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+-05:00$'))
                    FROM (SELECT t.orden AS o, lag(t.orden) OVER (ORDER BY x.n) AS o_ant, e ->> 'id' AS id, e ->> 'tipo' AS tipo, e ->> 'contraparte' AS cp, e ->> 'fecha' AS f
                            FROM jsonb_array_elements((SELECT h FROM t_h1)) WITH ORDINALITY x(e, n) JOIN public.transaccion t ON t.id = (x.e ->> 'id')::uuid) q), 't|t|t|t|t'::text);
SELECT tests.assert_json_shape('A6 forma de una Transaccion (contrato §3.2 / types.ts): id, tipo, tipo_detalle, monto (number), fecha, contraparte, nota', (SELECT h -> 0 FROM t_h1),
                               '{"id":"string","tipo":"string","tipo_detalle":"string","monto":"number","fecha":"string","contraparte":"string","nota":"string|null"}'::jsonb);
SELECT assert_eq('A7 la contraparte de un movimiento SIN nota es JSON null (no la cadena "null"), y el contrato la admite', (SELECT jsonb_typeof(e -> 'nota') FROM jsonb_array_elements((SELECT h FROM t_h1)) e WHERE e ->> 'tipo_detalle' = 'BONO_REFERIDO'), 'null'::text);
SELECT assert_eq('A8 el receptor ve el MISMO envio como RECIBO: 300.000 de "Nombre1 Apellido · 4000000001" con la nota del emisor; y el envio desde un bolsillo le llega como RECIBO tambien',
                 (SELECT string_agg(pg_temp.fila(e, false), ' ; ' ORDER BY o DESC) FROM jsonb_array_elements(public.vista_historial(tests.u(2), 50)) WITH ORDINALITY x(e, o) WHERE e ->> 'tipo_detalle' = 'RECIBO'),
                 'RECIBO|recibo|300000.00|Nombre1 Apellido · 4000000001|arriendo ; RECIBO|recibo|30000.00|Nombre1 Apellido · 4000000001|desde bolsillo'::text);
SELECT assert_eq('A9 p_limite: NULL y 1000 = todas (23), 51 = 23, 5 = 5, 1 = 1 y 0 / -7 se acotan a 1 (sin error ni mensaje nuevo)',
                 (SELECT concat_ws('|', jsonb_array_length(public.vista_historial(tests.u(1), NULL)), jsonb_array_length(public.vista_historial(tests.u(1), 1000)), jsonb_array_length(public.vista_historial(tests.u(1), 51)),
                                   jsonb_array_length(public.vista_historial(tests.u(1), 5)), jsonb_array_length(public.vista_historial(tests.u(1), 1)), jsonb_array_length(public.vista_historial(tests.u(1), 0)), jsonb_array_length(public.vista_historial(tests.u(1), -7)))),
                 '23|23|23|5|1|1|1'::text);
SELECT assert_eq('A10 un usuario sin movimientos recibe [] (nunca null) y un dashboard con ceros', concat_ws('|', public.vista_historial(tests.u(5), 50), (public.vista_dashboard(tests.u(5)) -> 'transacciones')), '[]|[]'::text);

-- A11. Respaldo de la contraparte: patas SIN snapshot de contraparte toman el nombre de su bolsillo / CDT / producto (el JOIN de la vista), y sin nada, "Banco Digital"
SELECT tests.fondear(tests.c(8), 1000000);
SELECT tests.bolsillo(801, tests.c(8));
SELECT tests.asentar(tests.pata('BOLSO_INGRESO', 'CUENTA', 'S', 1000, tests.c(8), tests.b(801)), tests.pata('BOLSO_INGRESO', 'BOLSILLO', 'E', 1000, tests.c(8), tests.b(801)));
SELECT tests.cdt(802, tests.c(8), 100000);                                                     -- el CDT nace justo antes de su grupo (el diferido exige la inversion al confirmar)
SELECT tests.asentar(tests.pata('CDT_CREACION', 'CUENTA', 'S', 100000, tests.c(8), NULL, tests.d(802)), tests.pata('CDT_CREACION', 'CDT', 'E', 100000, tests.c(8), NULL, tests.d(802)));
SELECT tests.credito(803, tests.c(8), 100000);                                                      -- credito sintetico sin plan: solo para probar el respaldo del nombre del producto
SELECT tests.asentar(tests.pata('CREDITO_MORA', 'CUENTA', 'S', 500, tests.c(8), NULL, NULL, tests.k(803)), tests.pata('CREDITO_MORA', 'RESULTADO', 'S', 500, tests.c(8), NULL, NULL, tests.k(803)));
SELECT tests.asentar(tests.pata('BONO_REFERIDO', 'CUENTA', 'E', 50000, tests.c(8), NULL, NULL, NULL, 'Banco Digital', '4000000099'), tests.pata('BONO_REFERIDO', 'RESULTADO', 'E', 50000, tests.c(8)));   -- el bono guarda la cuenta del referido: NO debe mostrarse
SELECT assert_eq('A11 sin snapshot de contraparte: el bolsillo, el CDT y el producto dan su NOMBRE (JOIN de la vista), un ingreso sin nada "Banco Digital" y el bono NO muestra la cuenta que guarda; en orden reciente -> antiguo',
                 (SELECT string_agg(e ->> 'tipo_detalle' || ':' || (e ->> 'contraparte'), ' ; ' ORDER BY o) FROM jsonb_array_elements(public.vista_historial(tests.u(8), 50)) WITH ORDINALITY x(e, o) WHERE e ->> 'tipo_detalle' IN ('BONO_REFERIDO', 'CREDITO_MORA', 'CDT_CREACION', 'BOLSO_INGRESO', 'INGRESO_SIMULADO')),
                 'BONO_REFERIDO:Banco Digital ; CREDITO_MORA:Producto 803 ; CDT_CREACION:CDT 802 ; BOLSO_INGRESO:Bolsillo 801 ; INGRESO_SIMULADO:Banco Digital'::text);

-- ============================================================================
-- B. Orden por `orden` con un cobro ATRASADO: el CDT cerro el dia 30 pero se descubre el dia 40, DESPUES de un recibo del dia 35
-- ============================================================================
SELECT pg_temp.real();
SELECT tests.fondear(tests.c(3), 3000000); SELECT tests.fondear(tests.c(4), 1000000);
SELECT public.crear_cdt(tests.u(3), tests.p(930)::text, 1000000);
SELECT pg_temp.ir(35);
SELECT public.hacer_transferencia(tests.u(4), pg_temp.num(3), 25000, 'llega el dia 35', NULL);                          -- no corre el motor de la cuenta 3
SELECT pg_temp.ir(40);
CREATE TEMP TABLE t_h3 AS SELECT public.vista_historial(tests.u(3), 4) AS h;                                            -- aqui se descubre el cierre del dia 30
SELECT assert_eq('B1 el cierre del CDT (fecha dia 30) se escribio DESPUES del recibo del dia 35: aparece PRIMERO (por orden) y conserva su fecha real, anterior a la del recibo',
                 (SELECT concat_ws('|', h -> 0 ->> 'tipo_detalle', h -> 1 ->> 'tipo_detalle', h -> 2 ->> 'tipo_detalle',
                                   ((h -> 0 ->> 'fecha')::timestamptz AT TIME ZONE 'America/Bogota')::date - pg_temp.dia(0), ((h -> 2 ->> 'fecha')::timestamptz AT TIME ZONE 'America/Bogota')::date - pg_temp.dia(0)) FROM t_h3),
                 'CDT_VENCIMIENTO|INTERES_CDT|RECIBO|30|35'::text);
SELECT assert_eq('B2 con limite 2 el corte es por orden de ESCRITURA: trae las 2 filas escritas al descubrir el cierre (CDT_VENCIMIENTO e INTERES_CDT, fecha dia 30) y NO el recibo del dia 35, que tiene fecha mas reciente',
                 (SELECT string_agg(e ->> 'tipo_detalle', '|' ORDER BY o) FROM jsonb_array_elements(public.vista_historial(tests.u(3), 2)) WITH ORDINALITY x(e, o)), 'CDT_VENCIMIENTO|INTERES_CDT'::text);

-- ============================================================================
-- C. Dashboard: cada seccion es la MISMA fuente que su endpoint (usuario 1 con 1 CDT activo y 2 creditos; interes de bolsillos, CDT y cuotas ya corriendo)
-- ============================================================================
SELECT pg_temp.real();
SELECT pg_temp.ir(120);                                                                                               -- adelante de todo lo anterior (el reloj solo avanza)
SELECT public.crear_cdt(tests.u(1), tests.p(930)::text, 300000);
CREATE TEMP TABLE t_k2 AS SELECT pg_temp.cre(1, 902, 1000000, 6) AS k;
SELECT pg_temp.ir(135);
CREATE TEMP TABLE t_d AS SELECT public.vista_dashboard(tests.u(1)) AS d;
SELECT tests.assert_json_shape('C1 forma del Dashboard (contrato §3.2 / types.ts)', (SELECT d FROM t_d),
                               '{"nombre":"string","balance_total":"number","transacciones":"array","cdts":"object","creditos":"object"}'::jsonb);
SELECT tests.assert_json_shape('C1 ...cdts {activos, generado} y creditos {cuota_por_pagar, interes_corriendo}, todos numeros', (SELECT d -> 'cdts' || (d -> 'creditos') FROM t_d),
                               '{"activos":"number","generado":"number","cuota_por_pagar":"number","interes_corriendo":"number"}'::jsonb);
SELECT assert_eq('C2 nombre = nombres; balance_total = vista_balance.total (la MISMA funcion); transacciones = las 8 primeras de vista_historial',
                 (SELECT concat_ws('|', d ->> 'nombre', (d ->> 'balance_total')::numeric = (public.vista_balance(tests.u(1)) ->> 'total')::numeric, d -> 'transacciones' = public.vista_historial(tests.u(1), 8), jsonb_array_length(d -> 'transacciones')) FROM t_d),
                 'Nombre1|t|t|8'::text);
SELECT assert_eq('C3 cdts = (cantidad y Σ generado) de los CDT ACTIVOS de vista_cdts: el cerrado NO suma; hay 1 activo con interes > 0',
                 (SELECT concat_ws('|', (d -> 'cdts' ->> 'activos')::int, (d -> 'cdts' ->> 'generado')::numeric = (SELECT coalesce(sum((e ->> 'generado_hasta_hoy')::numeric), 0) FROM jsonb_array_elements(public.vista_cdts(tests.u(1))) e WHERE e ->> 'tiempo_restante' <> 'Cerrado'),
                                   (d -> 'cdts' ->> 'generado')::numeric > 0) FROM t_d), '1|t|t'::text);
SELECT assert_eq('C4 creditos: interes_corriendo = Σ interes_mes de vista_creditos; cuota_por_pagar = Σ valor_cuota de la PROXIMA cuota impaga de cada credito ACTIVO (2 creditos), sin mora',
                 (SELECT concat_ws('|', (d -> 'creditos' ->> 'interes_corriendo')::numeric = (SELECT sum((e ->> 'interes_mes')::numeric) FROM jsonb_array_elements(public.vista_creditos(tests.u(1))) e),
                                   (d -> 'creditos' ->> 'cuota_por_pagar')::numeric = (SELECT sum(q.valor_cuota) FROM (SELECT DISTINCT ON (q2.credito_id) q2.valor_cuota FROM public.cuota q2 JOIN public.credito k ON k.id = q2.credito_id
                                                                                                                      WHERE k.cuenta_id = tests.c(1) AND k.estado = 'ACTIVO' AND NOT q2.pagada ORDER BY q2.credito_id, q2.numero) q),
                                   (SELECT count(*) FROM public.credito WHERE cuenta_id = tests.c(1) AND estado = 'ACTIVO'), (d -> 'creditos' ->> 'interes_corriendo')::numeric > 0) FROM t_d), 't|t|2|t'::text);
SELECT assert_eq('C5 usuario sin productos: balance_total 0 y todo en 0 / []', public.vista_dashboard(tests.u(5))::text,
                 '{"cdts": {"activos": 0, "generado": 0}, "nombre": "Nombre5", "creditos": {"cuota_por_pagar": 0, "interes_corriendo": 0}, "balance_total": 0.00, "transacciones": []}'::text);
SELECT assert_eq('C6 «recientes primero»: el dashboard trae el MISMO orden por orden que el historial y cada fecha es ISO -05:00',
                 (SELECT bool_and(f ~ '-05:00$') FROM (SELECT e ->> 'fecha' AS f FROM jsonb_array_elements((SELECT d -> 'transacciones' FROM t_d)) e) q), true);

-- ============================================================================
-- D. El dashboard dispara el cobro automatico (descuento activo con cuota vencida): atomico con falla inyectada y UN solo cobro
-- ============================================================================
SELECT pg_temp.real();
SELECT tests.fondear(tests.c(6), 4000000);
CREATE TEMP TABLE t_k6 AS SELECT pg_temp.cre(6, 901, 3000000, 6) AS k;
UPDATE public.cuota SET fecha_vencimiento = pg_temp.dia(CASE WHEN numero = 1 THEN 150 ELSE 300 + numero END) WHERE credito_id = (SELECT k FROM t_k6);   -- solo la cuota 1 esta vencida el dia 170
SELECT pg_temp.ir(160);
SELECT public.activar_descuento_automatico(tests.u(6), (SELECT k FROM t_k6)::text, true);                             -- la cuota (dia 150) ya estaba vencida al activar: la primera ronda es la de hoy
SELECT pg_temp.ir(170);
CREATE FUNCTION pg_temp.dash_txt(p_u int) RETURNS text LANGUAGE plpgsql AS $f$ BEGIN PERFORM public.vista_dashboard(tests.u(p_u)); RETURN 'OK'; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $f$;
SELECT tests.instalar_fallas();
DO $do$
DECLARE p int; mal text := ''; h0 text; r text; k uuid := (SELECT k FROM t_k6);
BEGIN
  h0 := tests.huella_saldos();
  FOR p IN 1..5 LOOP                                                                                                   -- el cobro de la cuota con mora de 20 dias: 3 patas de cuota + 2 de mora
    PERFORM tests.falla('tx:' || p);
    r := pg_temp.dash_txt(6);
    IF r NOT LIKE '%' || 'FALLA INYECTADA' || '%' OR tests.huella_saldos() <> h0 OR EXISTS (SELECT 1 FROM public.cuota WHERE credito_id = k AND pagada) THEN mal := mal || p || ':' || coalesce(r, 'NULL') || '; '; END IF;
  END LOOP;
  PERFORM tests.falla('');
  PERFORM tests.assert_eq('D1 el dashboard dispara el cobro automatico y una falla inyectada en cada una de las 5 patas lo revierte TODO (huella, cuota impaga): nada a medias', mal, ''::text);
END $do$;
SELECT tests.quitar_fallas();
SELECT public.vista_dashboard(tests.u(6)); SELECT public.vista_dashboard(tests.u(6));
SELECT assert_eq('D2 sin fallas, el dashboard cobra la cuota vencida UNA vez (con su mora, 2 grupos) y la segunda lectura no escribe nada',
                 (SELECT concat_ws('|', count(*) FILTER (WHERE pagada), (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE credito_id = (SELECT k FROM t_k6) AND tipo IN ('CREDITO_CUOTA', 'CREDITO_MORA')))
                    FROM public.cuota WHERE credito_id = (SELECT k FROM t_k6)), '1|2'::text);
SELECT assert_eq('D3 ...y ese cobro aparece en el historial del mismo usuario (CREDITO_CUOTA y CREDITO_MORA, ambos envio, el nombre del producto)',
                 (SELECT string_agg(e ->> 'tipo_detalle' || ':' || (e ->> 'tipo') || ':' || (e ->> 'contraparte'), ' ; ' ORDER BY o) FROM jsonb_array_elements(public.vista_historial(tests.u(6), 2)) WITH ORDINALITY x(e, o)),
                 'CREDITO_MORA:envio:Libre ; CREDITO_CUOTA:envio:Libre'::text);

-- ============================================================================
-- E. Catalogo, permisos y plan
-- ============================================================================
SELECT assert_eq('E1 vista_dashboard y vista_historial: _avanzar_hasta( y _reloj_instantanea() EXACTAMENTE 1 vez con la instantanea ANTES; sin leer el reloj por su cuenta ni INSERT en el libro; SECURITY DEFINER, search_path y TimeZone fijos, dueño banco_owner',
                 (SELECT array_agg(p.proname::text ORDER BY p.proname::text) FILTER (WHERE (length(p.prosrc) - length(replace(p.prosrc, '_avanzar_hasta(', ''))) / length('_avanzar_hasta(') <> 1
                                                                                           OR (length(p.prosrc) - length(replace(p.prosrc, '_reloj_instantanea()', ''))) / length('_reloj_instantanea()') <> 1
                                                                                           OR strpos(p.prosrc, '_reloj_instantanea()') > strpos(p.prosrc, '_avanzar_hasta(')
                                                                                           OR p.prosrc ~* '(now\(\)|current_date|current_timestamp|clock_timestamp|hoy_banco|ahora_banco|_ahora_real|insert\s+into)'
                                                                                           OR NOT (p.prosecdef AND pg_get_userbyid(p.proowner) = 'banco_owner' AND p.proconfig::text LIKE '%search_path=public, pg_temp%' AND p.proconfig::text LIKE '%TimeZone=America/Bogota%'))
                    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('vista_dashboard', 'vista_historial')), NULL::text[]);
SELECT assert_eq('E2 banco_app ejecuta las 2 publicas y NINGUNA de las 2 internas; PUBLIC ninguna de las 4; banco_lector SOLO _reglas_historial (la necesita para leer la vista: las funciones de una vista corren con los privilegios de quien consulta)',
                 (SELECT concat_ws('|', count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE') AND p.proname IN ('vista_dashboard', 'vista_historial')),
                                   count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE') AND p.proname NOT IN ('vista_dashboard', 'vista_historial')),
                                   count(*) FILTER (WHERE has_function_privilege('banco_lector', p.oid, 'EXECUTE')),
                                   count(*) FILTER (WHERE EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))
                    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('vista_dashboard', 'vista_historial', '_json_transacciones', '_reglas_historial')), '2|0|1|0'::text);
SELECT assert_eq('E3 la vista v_transaccion_usuario: SELECT para banco_lector y banco_dev (herencia), NINGUNO para banco_app ni PUBLIC (mira a todos los usuarios)',
                 concat_ws('|', has_table_privilege('banco_lector', 'public.v_transaccion_usuario', 'SELECT'), has_table_privilege('banco_dev', 'public.v_transaccion_usuario', 'SELECT'),
                           has_table_privilege('banco_app', 'public.v_transaccion_usuario', 'SELECT'), (SELECT count(*) FROM aclexplode((SELECT relacl FROM pg_class WHERE oid = 'public.v_transaccion_usuario'::regclass)) a WHERE a.grantee = 0)), 't|t|f|0'::text);
SELECT assert_eq('E4 el control de integridad de la vista y la lista blanca de 40 funciones estan en orden',
                 (SELECT concat_ws('|', bool_and(ok), count(*)) FROM public.v_integridad_defensas WHERE control LIKE 'banco_app NO tiene SELECT sobre v_transaccion_usuario%' OR control LIKE 'banco_app ejecuta EXACTAMENTE las 40%'), 't|2'::text);
SET LOCAL enable_seqscan = off;
SELECT assert_true('E5 la consulta del historial puede resolverse POR EL INDICE (cuenta_id, orden DESC) y no por un recorrido de toda la tabla (el plan exacto, sin Sort, se documenta con EXPLAIN en 10-vistas.md: depende de las estadisticas de cada corrida)',
                   (SELECT bool_or(l LIKE '%ix_transaccion_cuenta_orden%') FROM tests.plan($$SELECT * FROM public.v_transaccion_usuario WHERE cuenta_id = '20000000-0000-4000-8000-000000000001' ORDER BY orden DESC LIMIT 8$$) l));
RESET enable_seqscan;
SAVEPOINT sg_vista;
DROP VIEW public.v_transaccion_usuario;
SELECT assert_eq('E6 si la vista DESAPARECE, la defensa FALLA (ok = false, detalle "VISTA AUSENTE") y v_integridad_global.ok tambien: un control sobre algo que no existe no se da por bueno',
                 (SELECT concat_ws('|', (SELECT d.ok FROM public.v_integridad_defensas d WHERE d.control LIKE 'banco_app NO tiene SELECT sobre v_transaccion_usuario%'),
                                   (SELECT d.detalle FROM public.v_integridad_defensas d WHERE d.control LIKE 'banco_app NO tiene SELECT sobre v_transaccion_usuario%'), (SELECT g.ok FROM public.v_integridad_global g))),
                 'f|v_transaccion_usuario: SELECT banco_app = VISTA AUSENTE|f'::text);
ROLLBACK TO sg_vista;
SELECT assert_eq('E6 ...y al restaurar la vista la defensa vuelve a estar en orden (la vista existe, banco_app no la lee y banco_lector si)',
                 (SELECT d.ok FROM public.v_integridad_defensas d WHERE d.control LIKE 'banco_app NO tiene SELECT sobre v_transaccion_usuario%'), true);

-- ============================================================================
-- F. D8 (PROVISIONAL, equipo/front) es UN solo punto: _reglas_historial() controla lo que se muestra
-- ============================================================================
CREATE TEMP TABLE t_f AS SELECT jsonb_array_length(h) AS n, count(*) FILTER (WHERE e ->> 'tipo_detalle' LIKE 'BOLSO_%') AS bolso, count(*) FILTER (WHERE e ->> 'tipo_detalle' = 'INTERES_BOLSO') AS ib,
  count(*) FILTER (WHERE e ->> 'tipo_detalle' = 'INTERES_CDT') AS icdt FROM (SELECT public.vista_historial(tests.u(1), 50) AS h) x, jsonb_array_elements(h) e GROUP BY h;
SELECT assert_true('F0 base: el usuario 1 tiene movimientos de todas las familias que D8 controla (bolsillo, interes de bolsillo, interes de CDT)', (SELECT bolso >= 3 AND ib >= 4 AND icdt >= 1 FROM t_f));
SAVEPOINT sg_d8;
CREATE OR REPLACE FUNCTION public._reglas_historial() RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $f$
  SELECT jsonb_build_object('limite_max', 50, 'mostrar_bolso', false, 'mostrar_interes_bolso', true, 'mostrar_interes_cdt', true, 'contraparte_respaldo', 'Banco Digital') $f$;
SELECT assert_eq('F1 mostrar_bolso = false oculta SOLO los movimientos cuenta<->bolsillo (n -> n - bolso)', jsonb_array_length(public.vista_historial(tests.u(1), 50)), (SELECT (n - bolso)::int FROM t_f));
CREATE OR REPLACE FUNCTION public._reglas_historial() RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $f$
  SELECT jsonb_build_object('limite_max', 50, 'mostrar_bolso', true, 'mostrar_interes_bolso', false, 'mostrar_interes_cdt', false, 'contraparte_respaldo', 'Banco Digital') $f$;
SELECT assert_eq('F2 mostrar_interes_bolso y mostrar_interes_cdt = false ocultan SOLO los intereses (n -> n - ib - icdt) y el dashboard sigue coherente con el historial',
                 concat_ws('|', jsonb_array_length(public.vista_historial(tests.u(1), 50)) = (SELECT n - ib - icdt FROM t_f), public.vista_dashboard(tests.u(1)) -> 'transacciones' = public.vista_historial(tests.u(1), 8)), 't|t'::text);
CREATE OR REPLACE FUNCTION public._reglas_historial() RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $f$
  SELECT jsonb_build_object('limite_max', 10, 'mostrar_bolso', true, 'mostrar_interes_bolso', true, 'mostrar_interes_cdt', true, 'contraparte_respaldo', 'Banco X') $f$;
SELECT assert_eq('F3 limite_max = 10 acota tambien p_limite = 50 y NULL; la contraparte de respaldo sale de la regla (Banco X en un ingreso sin snapshot)',
                 concat_ws('|', jsonb_array_length(public.vista_historial(tests.u(1), 50)), jsonb_array_length(public.vista_historial(tests.u(1), NULL)),
                           (SELECT e ->> 'contraparte' FROM jsonb_array_elements(public.vista_historial(tests.u(2), 50)) e WHERE e ->> 'tipo_detalle' = 'INGRESO_SIMULADO')), '10|10|Banco X'::text);
ROLLBACK TO sg_d8;
SELECT assert_eq('F4 tras restaurar, el default del contrato vuelve (todas las filas, limite 50)', concat_ws('|', jsonb_array_length(public.vista_historial(tests.u(1), 50)) = (SELECT n FROM t_f), public._reglas_historial() ->> 'limite_max'), 't|50'::text);

-- ============================================================================
-- G. Zona horaria por codigo (la sesion en UTC no cambia el offset) y UNA sola instantanea del reloj (conteo dinamico)
-- ============================================================================
SET LOCAL TimeZone = 'UTC';
SELECT assert_eq('G1 con la sesion en UTC las fechas del historial y del dashboard siguen saliendo con -05:00 (SET TimeZone por codigo)',
                 (SELECT bool_and((e ->> 'fecha') ~ '-05:00$') FROM jsonb_array_elements(public.vista_historial(tests.u(1), 50) || (public.vista_dashboard(tests.u(1)) -> 'transacciones')) e), true);
RESET TimeZone;
SELECT pg_temp.real();
CREATE TEMP SEQUENCE sq_lect;
GRANT USAGE, SELECT, UPDATE ON SEQUENCE sq_lect TO banco_owner;
CREATE OR REPLACE FUNCTION public._ahora_real() RETURNS timestamptz LANGUAGE plpgsql VOLATILE SET search_path = public, pg_temp AS $f$
BEGIN RETURN '2026-11-21 10:00:00-05'::timestamptz + make_interval(secs => nextval('pg_temp.sq_lect')::int); END $f$;
CREATE FUNCTION pg_temp.lect() RETURNS int LANGUAGE sql VOLATILE AS $f$ SELECT CASE WHEN is_called THEN last_value::int ELSE 0 END FROM pg_temp.sq_lect $f$;
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.vista_dashboard(tests.u(5));
SELECT assert_eq('G2 vista_dashboard sin nada vencido: UNA sola lectura del reloj (la instantanea)', pg_temp.lect(), 1);
SELECT setval('pg_temp.sq_lect', 1, false);
SELECT public.vista_historial(tests.u(5), 50);
SELECT assert_eq('G3 vista_historial sin nada vencido: UNA sola lectura del reloj', pg_temp.lect(), 1);
SELECT assert_true('estado global en orden (partida doble, I5u y defensas; sin la regla de planes por el credito sintetico de A11) tras todos los escenarios', tests.ok_sin_plan());
ROLLBACK;
