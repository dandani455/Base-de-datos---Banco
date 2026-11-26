-- 67_contrato.test.sql · Etapa 10 · CONFORMIDAD con el contrato front-BD (PDF 2026-11-18 §2, §3, §6, §8) y con front/src/api/types.ts de las 26 funciones que ejecuta banco_app: UNA llamada de
-- cada una, con la sesion en UTC (la zona la fija el codigo): nombres de campo y tipos JSON, dinero como NUMERO (ningun numeric como string), fechas ISO con zona -05:00, listas [] (nunca null),
-- ids como string, y los mensajes de §6 presentes byte a byte (acentos incluidos) en el catalogo. No repite los casos de negocio de E4-E9: solo la FORMA de lo que ve el front.
-- Una transaccion con ROLLBACK final; solo corre en banco_test/banco_mut.
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 4) n;
SELECT tests.fondear(tests.c(1), 20000000); SELECT tests.fondear(tests.c(2), 1000000);
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES (tests.p(901), 'Libre', 'Dinero para lo que necesites', 18, 1, 1000000000, 1, 360);
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES (tests.p(930), 'CDT 30', 30, 10, 100000);
-- ayudantes: cada uno devuelve '' si todo coincide o el primer desajuste
CREATE FUNCTION pg_temp.desajuste(p_j jsonb, p_forma jsonb) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE k text; t text; v text;
BEGIN
  IF jsonb_typeof(p_j) IS DISTINCT FROM 'object' THEN RETURN 'no es un objeto: ' || coalesce(jsonb_typeof(p_j), 'NULL'); END IF;
  FOR k, t IN SELECT key, value #>> '{}' FROM jsonb_each(p_forma) LOOP
    IF NOT (p_j ? k) THEN RETURN 'falta ' || k; END IF;
    v := jsonb_typeof(p_j -> k);
    IF NOT (v = ANY (string_to_array(t, '|'))) THEN RETURN k || ' es ' || v || ' y se esperaba ' || t; END IF;
  END LOOP;
  RETURN '';
END $f$;
CREATE FUNCTION pg_temp.desajuste_arr(p_a jsonb, p_forma jsonb, p_min int) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE e jsonb; r text;
BEGIN
  IF jsonb_typeof(p_a) IS DISTINCT FROM 'array' THEN RETURN 'no es un arreglo: ' || coalesce(jsonb_typeof(p_a), 'NULL'); END IF;
  IF jsonb_array_length(p_a) < p_min THEN RETURN 'se esperaban >= ' || p_min || ' elementos y hay ' || jsonb_array_length(p_a); END IF;
  FOR e IN SELECT x FROM jsonb_array_elements(p_a) x LOOP r := pg_temp.desajuste(e, p_forma); IF r <> '' THEN RETURN r; END IF; END LOOP;
  RETURN '';
END $f$;
-- recorre todo el JSON: devuelve las claves cuyo valor es una CADENA con forma de numero (menos las que el contrato define como texto: numero_cuenta, cedula, telefono)
CREATE FUNCTION pg_temp.num_como_texto(p_j jsonb, p_clave text DEFAULT '') RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE jsonb_typeof(p_j)
           WHEN 'object' THEN coalesce((SELECT string_agg(r, ',') FROM (SELECT pg_temp.num_como_texto(v, k) AS r FROM jsonb_each(p_j) x(k, v)) q WHERE r <> ''), '')
           WHEN 'array'  THEN coalesce((SELECT string_agg(r, ',') FROM (SELECT pg_temp.num_como_texto(v, p_clave) AS r FROM jsonb_array_elements(p_j) v) q WHERE r <> ''), '')
           WHEN 'string' THEN CASE WHEN (p_j #>> '{}') ~ '^-?[0-9]+([.][0-9]+)?$' AND p_clave NOT IN ('numero_cuenta', 'cedula', 'telefono') THEN p_clave ELSE '' END
           ELSE '' END $f$;
-- todas las cadenas de las claves de fecha (fecha, fecha_cierre) del JSON, a cualquier profundidad
CREATE FUNCTION pg_temp.fechas(p_j jsonb) RETURNS SETOF text LANGUAGE sql IMMUTABLE AS $f$
  SELECT m[1] FROM regexp_matches(p_j::text, '"(?:fecha|fecha_cierre)": "([^"]*)"', 'g') m $f$;

CREATE TEMP TABLE t_o (fn text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_fn text, p_j jsonb) RETURNS void LANGUAGE sql AS $f$ INSERT INTO t_o VALUES (p_fn, p_j) $f$;

-- ---- las 26 llamadas, con la sesion en UTC (la zona la pone el codigo de las funciones) ----
SET LOCAL TimeZone = 'UTC';
CREATE TEMP TABLE t_reg AS SELECT tests.reg(70, 'Camila', 'Rodriguez') AS r;
SELECT pg_temp.g('registrar_usuario', (SELECT r FROM t_reg));
SELECT pg_temp.g('obtener_credenciales', (SELECT to_jsonb(c) FROM public.obtener_credenciales('cli1') c));
SELECT pg_temp.g('validar_sesion', public.validar_sesion(tests.u(1)));
SELECT pg_temp.g('vista_perfil', public.vista_perfil(tests.u(1)));
SELECT pg_temp.g('nombre_destinatario', public.nombre_destinatario(tests.u(1), (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(2))));
SELECT pg_temp.g('hacer_transferencia', public.hacer_transferencia(tests.u(1), (SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(2)), 1000, 'nota', NULL));
CREATE TEMP TABLE t_b AS SELECT public.crear_bolsillo(tests.u(1), 'Viajes') AS r, public.crear_bolsillo(tests.u(1), 'Otro') AS r2;
SELECT pg_temp.g('crear_bolsillo', (SELECT r FROM t_b));
SELECT pg_temp.g('mover_a_bolsillo', public.mover_a_bolsillo(tests.u(1), (SELECT r ->> 'id' FROM t_b), 100000));
SELECT pg_temp.g('mover_entre_bolsillos', public.mover_entre_bolsillos(tests.u(1), (SELECT r ->> 'id' FROM t_b), (SELECT r2 ->> 'id' FROM t_b), 1000));
SELECT pg_temp.g('retirar_de_bolsillo', public.retirar_de_bolsillo(tests.u(1), (SELECT r2 ->> 'id' FROM t_b), 500));
SELECT pg_temp.g('listar_cdt_definiciones', public.listar_cdt_definiciones(tests.u(1)));
SELECT pg_temp.g('simular_cdt', public.simular_cdt(tests.u(1), tests.p(930)::text, 1000000));
SELECT pg_temp.g('crear_cdt', public.crear_cdt(tests.u(1), tests.p(930)::text, 1000000));
SELECT pg_temp.g('productos_publicos', public.productos_publicos());
SELECT pg_temp.g('productos_disponibles', public.productos_disponibles(tests.u(1)));
SELECT pg_temp.g('simular_credito', public.simular_credito(tests.u(1), tests.p(901)::text, 5000000, 12));
CREATE TEMP TABLE t_k AS SELECT public.solicitar_credito(tests.u(1), tests.p(901)::text, 5000000, 12) AS r;
SELECT pg_temp.g('solicitar_credito', (SELECT r FROM t_k));
SELECT pg_temp.g('pagar_cuota', public.pagar_cuota(tests.u(1), (SELECT r ->> 'id' FROM t_k), 1));
SELECT pg_temp.g('abonar_credito', public.abonar_credito(tests.u(1), (SELECT r ->> 'id' FROM t_k), 100000));
SELECT pg_temp.g('activar_descuento_automatico', public.activar_descuento_automatico(tests.u(1), (SELECT r ->> 'id' FROM t_k), true));
SELECT public._reloj_actualizar(false, (public.hoy_banco() + 45)::text);                                              -- el CDT vence y los bolsillos devengan: hay fila CERRADA y de interes
SELECT pg_temp.g('vista_cdts', public.vista_cdts(tests.u(1)));
SELECT pg_temp.g('vista_creditos', public.vista_creditos(tests.u(1)));
SELECT pg_temp.g('vista_balance', public.vista_balance(tests.u(1)));
SELECT pg_temp.g('vista_dashboard', public.vista_dashboard(tests.u(1)));
SELECT pg_temp.g('vista_historial', public.vista_historial(tests.u(1), 50));
RESET TimeZone;

-- ============================================================================
-- A. Nombres de campo y tipos JSON (contrato §3 + types.ts)
-- ============================================================================
SELECT assert_eq('A1 registrar_usuario -> {usuario_id, username} (el backend entrega solo {username}); validar_sesion -> {username, rol, estado}; vista_perfil -> {username, numero_cuenta (10 digitos), codigo_referido}',
                 concat_ws('|', pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'registrar_usuario'), '{"usuario_id":"string","username":"string"}'),
                           pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'validar_sesion'), '{"username":"string","rol":"string","estado":"string"}'),
                           pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'vista_perfil'), '{"username":"string","numero_cuenta":"string","codigo_referido":"string"}'),
                           (SELECT (j ->> 'numero_cuenta') ~ '^[0-9]{10}$' FROM t_o WHERE fn = 'vista_perfil')), '|||t'::text);
SELECT assert_eq('A2 obtener_credenciales -> (usuario_id, password_hash, rol, estado) como texto; nombre_destinatario -> {nombre}',
                 concat_ws('|', pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'obtener_credenciales'), '{"usuario_id":"string","password_hash":"string","rol":"string","estado":"string"}'),
                           pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'nombre_destinatario'), '{"nombre":"string"}')), '|'::text);
SELECT assert_eq('A3 vista_balance -> {total, principal: number, bolsillos: [{id: string, nombre: string, saldo: number}]}',
                 concat_ws('|', pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'vista_balance'), '{"total":"number","principal":"number","bolsillos":"array"}'),
                           pg_temp.desajuste_arr((SELECT j -> 'bolsillos' FROM t_o WHERE fn = 'vista_balance'), '{"id":"string","nombre":"string","saldo":"number"}', 2)), '|'::text);
SELECT assert_eq('A4 CDT: listar_cdt_definiciones -> [{id, nombre, tasa, plazo_dias, monto_min}] numericos; simular_cdt -> {generado_mes, generado_dia, generado_vencimiento}; vista_cdts -> [{id, monto, generado_hasta_hoy, tiempo_restante, fecha_cierre}]',
                 concat_ws('|', pg_temp.desajuste_arr((SELECT j FROM t_o WHERE fn = 'listar_cdt_definiciones'), '{"id":"string","nombre":"string","tasa":"number","plazo_dias":"number","monto_min":"number"}', 1),
                           pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'simular_cdt'), '{"generado_mes":"number","generado_dia":"number","generado_vencimiento":"number"}'),
                           pg_temp.desajuste_arr((SELECT j FROM t_o WHERE fn = 'vista_cdts'), '{"id":"string","monto":"number","generado_hasta_hoy":"number","tiempo_restante":"string","fecha_cierre":"string"}', 1)), '||'::text);
SELECT assert_eq('A5 creditos: productos_disponibles / productos_publicos -> [{id, nombre, tasa, monto_min, monto_max, plazo_min, plazo_max}] (publicos + descripcion); simular_credito -> {cuota_mensual, total_a_pagar, intereses_totales}; solicitar_credito -> {id, fecha}; vista_creditos -> [{id, producto, cuotas_pagadas, cuotas_faltantes, interes_mes, saldo}]',
                 concat_ws('|', pg_temp.desajuste_arr((SELECT j FROM t_o WHERE fn = 'productos_disponibles'), '{"id":"string","nombre":"string","tasa":"number","monto_min":"number","monto_max":"number","plazo_min":"number","plazo_max":"number"}', 1),
                           pg_temp.desajuste_arr((SELECT j FROM t_o WHERE fn = 'productos_publicos'), '{"id":"string","nombre":"string","descripcion":"string","tasa":"number","monto_min":"number","monto_max":"number","plazo_min":"number","plazo_max":"number"}', 1),
                           pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'simular_credito'), '{"cuota_mensual":"number","total_a_pagar":"number","intereses_totales":"number"}'),
                           pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'solicitar_credito'), '{"id":"string","fecha":"string"}'),
                           pg_temp.desajuste_arr((SELECT j FROM t_o WHERE fn = 'vista_creditos'), '{"id":"string","producto":"string","cuotas_pagadas":"number","cuotas_faltantes":"number","interes_mes":"number","saldo":"number","descuento_automatico":"boolean","mora_acumulada":"number"}', 1)),
                 '||||'::text);
SELECT assert_eq('A6 pagos (D10): pagar_cuota -> {numero, pagado, mora, fecha}; abonar_credito -> {fecha, mora, interes, capital, saldo, cuota_nueva}; activar_descuento_automatico -> {id, descuento_automatico: boolean}',
                 concat_ws('|', pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'pagar_cuota'), '{"numero":"number","pagado":"number","mora":"number","fecha":"string"}'),
                           pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'abonar_credito'), '{"fecha":"string","mora":"number","interes":"number","capital":"number","saldo":"number","cuota_nueva":"number"}'),
                           pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'activar_descuento_automatico'), '{"id":"string","descuento_automatico":"boolean"}')), '||'::text);
SELECT assert_eq('A7 Dashboard (types.ts) y Transaccion[] (historial y dashboard): {nombre, balance_total, transacciones, cdts, creditos} y [{id, tipo, tipo_detalle, monto, fecha, contraparte, nota}]',
                 concat_ws('|', pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'vista_dashboard'), '{"nombre":"string","balance_total":"number","transacciones":"array","cdts":"object","creditos":"object"}'),
                           pg_temp.desajuste((SELECT j -> 'cdts' FROM t_o WHERE fn = 'vista_dashboard'), '{"activos":"number","generado":"number"}'),
                           pg_temp.desajuste((SELECT j -> 'creditos' FROM t_o WHERE fn = 'vista_dashboard'), '{"cuota_por_pagar":"number","interes_corriendo":"number"}'),
                           pg_temp.desajuste_arr((SELECT j FROM t_o WHERE fn = 'vista_historial'), '{"id":"string","tipo":"string","tipo_detalle":"string","monto":"number","fecha":"string","contraparte":"string","nota":"string|null"}', 10),
                           pg_temp.desajuste_arr((SELECT j -> 'transacciones' FROM t_o WHERE fn = 'vista_dashboard'), '{"id":"string","tipo":"string","tipo_detalle":"string","monto":"number","fecha":"string","contraparte":"string","nota":"string|null"}', 8)), '||||'::text);
SELECT assert_eq('A8 las operaciones de bolsillo y transferencia devuelven un objeto (el front no lee la salida: basta 200); crear_bolsillo -> {id, nombre}; crear_cdt -> objeto con id',
                 concat_ws('|', pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'crear_bolsillo'), '{"id":"string","nombre":"string"}'),
                           pg_temp.desajuste((SELECT j FROM t_o WHERE fn = 'crear_cdt'), '{"id":"string"}'),
                           (SELECT bool_and(jsonb_typeof(j) = 'object') FROM t_o WHERE fn IN ('hacer_transferencia', 'mover_a_bolsillo', 'mover_entre_bolsillos', 'retirar_de_bolsillo'))), '||t'::text);
SELECT assert_eq('A9 las 26 funciones de cliente de banco_app (las admin_* de E11 tienen su propio archivo, 68-69) estan cubiertas por una llamada (menos verificar_correo, void): cada funcion publica del catalogo aparece en la tabla de salidas',
                 (SELECT array_agg(p.proname::text ORDER BY p.proname::text) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND has_function_privilege('banco_app', p.oid, 'EXECUTE')
                     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e') AND p.proname <> 'verificar_correo' AND p.proname NOT LIKE 'admin\_%' AND NOT EXISTS (SELECT 1 FROM t_o WHERE fn = p.proname)), NULL::text[]);

-- ============================================================================
-- B. Dinero como numero, fechas ISO con zona, listas [] (contrato §2 y §8) — con la sesion en UTC
-- ============================================================================
SELECT assert_eq('B1 ningun numeric sale como string en ninguna de las salidas (solo numero_cuenta, cedula y telefono son texto, por contrato)',
                 (SELECT coalesce(string_agg(fn || ':' || pg_temp.num_como_texto(j), ' ; '), '') FROM t_o WHERE pg_temp.num_como_texto(j) <> ''), ''::text);
SELECT assert_eq('B2 TODA fecha (fecha, fecha_cierre) es ISO 8601 con la zona de Bogota (-05:00) aunque la sesion este en UTC: solicitar_credito, pagar_cuota, abonar_credito, vista_cdts, vista_historial y el dashboard',
                 (SELECT coalesce(string_agg(DISTINCT fn || ':' || f, ' ; '), '') FROM t_o, LATERAL pg_temp.fechas(j) f WHERE f !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+-05:00$'), ''::text);
SELECT assert_eq('B3 hay fechas que comprobar en las 11 funciones que las emiten (la prueba B2 no es vacia)',
                 (SELECT string_agg(DISTINCT fn, ',' ORDER BY fn) FROM t_o, LATERAL pg_temp.fechas(j) f), 'abonar_credito,crear_cdt,hacer_transferencia,mover_a_bolsillo,mover_entre_bolsillos,pagar_cuota,retirar_de_bolsillo,solicitar_credito,vista_cdts,vista_dashboard,vista_historial'::text);
SELECT assert_eq('B4 un usuario nuevo recibe [] (nunca null) en vista_balance.bolsillos, vista_cdts, vista_creditos y vista_historial',
                 concat_ws('|', public.vista_balance(tests.u(3)) -> 'bolsillos', public.vista_cdts(tests.u(3)), public.vista_creditos(tests.u(3)), public.vista_historial(tests.u(3), 50)), '[]|[]|[]|[]'::text);
SELECT assert_eq('B5 el CDT cerrado sale con tiempo_restante "Cerrado" y su fecha de cierre como instante ISO (D-E10-5): el dia del cierre a las 00:00 de Bogota',
                 (SELECT concat_ws('|', e ->> 'tiempo_restante', (e ->> 'fecha_cierre') ~ 'T00:00:00-05:00$') FROM jsonb_array_elements((SELECT j FROM t_o WHERE fn = 'vista_cdts')) e LIMIT 1), 'Cerrado|t'::text);

-- ============================================================================
-- C. Mensajes de §6: presentes byte a byte (acentos incluidos) en el catalogo de funciones; los dos que no emite la BD se declaran
-- ============================================================================
CREATE TEMP TABLE t_msg (m text, quien text);
INSERT INTO t_msg VALUES
  ('Tu cuenta ha sido restringida, contacte con el banco para desbloquearla', 'BD'), ('Debe aceptar la política de datos', 'BD'), ('Saldo insuficiente', 'BD'), ('Cuenta no encontrada', 'BD'),
  ('No puedes enviarte dinero a ti mismo', 'BD'), ('Monto inválido', 'BD'), ('Recurso no encontrado', 'BD'), ('Ya tienes un crédito vigente de este producto', 'BD'), ('Monto fuera de rango', 'BD'),
  ('Plazo excede el límite de edad', 'BD'), ('Plazo fuera de rango', 'BD'), ('Monto por debajo del mínimo del CDT', 'BD'), ('Acceso denegado', 'BD'), ('El reloj no puede retroceder', 'BD'),
  ('Credenciales inválidas', 'backend'), ('Tabla no permitida', 'E12');
SELECT assert_eq('C1 los 14 mensajes de §6 que emite la BD existen EXACTAMENTE (texto y acentos) en el catalogo de funciones; "Credenciales inválidas" es del backend y "Tabla no permitida" de E12',
                 (SELECT string_agg(m, ' ; ' ORDER BY m) FROM t_msg t WHERE t.quien = 'BD' AND NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prosrc LIKE '%' || t.m || '%')), NULL::text);
SELECT assert_eq('C2 en vivo: Recurso no encontrado, Monto inválido y Saldo insuficiente llegan como P0001 con ese texto exacto desde las funciones nuevas del contrato (credito ajeno, monto con 3 decimales, cuota sin saldo)',
                 concat_ws('|', tests.captura($$SELECT public.pagar_cuota(tests.u(2), '$$ || (SELECT r ->> 'id' FROM t_k) || $$')$$),
                           tests.captura($$SELECT public.abonar_credito(tests.u(1), '$$ || (SELECT r ->> 'id' FROM t_k) || $$', 1.005)$$),
                           tests.captura($$SELECT public.hacer_transferencia(tests.u(3), '4000000001', 1000000, 'x', NULL)$$)), 'Recurso no encontrado|Monto inválido|Saldo insuficiente'::text);
SELECT assert_eq('estado global en orden', (SELECT ok FROM public.v_integridad_global), true);
ROLLBACK;
