-- 71_control.test.sql · Etapa 12 · admin_esquema y admin_tabla (la pestaña Control).
-- Riesgos NUEVOS: el esquema coincide con un oraculo independiente (information_schema) y con la lista blanca de 11 tablas (deriva); la tabla pagina de a 50 con recorte de pagina y orden estable;
-- el HASH real nunca viaja; fuera de la lista blanca (con intentos de inyeccion) = 'Tabla no permitida'; el visor es de SOLO LECTURA (STABLE, sin motor, sin auditoria) y muestra lo guardado.
-- No repite el control de acceso de las 12 admin_* de E11 (69, G2-G4 ya recorre tambien estas 2) ni el libro, el motor o las vistas. Una transaccion con ROLLBACK final; solo en banco_test/banco_mut.
DO $$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'FAIL: esta prueba mueve el reloj y SOLO puede correr en banco_test/banco_mut (BD actual: %)', current_database();
  END IF;
END $$;
BEGIN;

SELECT count(tests.cliente(n)) FROM generate_series(1, 120) n;
INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol, estado) VALUES
  (tests.u(900), 'admin900', 'h', 'Ada', 'Admin', '9000000900', 'a900@t.co', '3000000900', DATE '1980-01-01', 'ADMIN', 'ACTIVO'),
  (tests.u(902), 'admin902', 'h', 'Cleo', 'Admin', '9000000902', 'a902@t.co', '3000000902', DATE '1980-01-01', 'ADMIN', 'BLOQUEADO');
UPDATE public.usuario SET password_hash = 'REALHASH-' || username || '-' || md5(username);          -- un hash RECONOCIBLE y distinto por usuario
CREATE TEMP TABLE t_b AS SELECT public.hoy_banco() AS d;
CREATE FUNCTION pg_temp.dia(p_n int) RETURNS date LANGUAGE sql STABLE AS $f$ SELECT (SELECT d FROM t_b) + p_n $f$;
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN EXECUTE p_sql; RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN CASE WHEN SQLSTATE = 'P0001' THEN SQLERRM ELSE 'NO-P0001 ' || SQLSTATE || ': ' || SQLERRM END; END $f$;
CREATE FUNCTION pg_temp.tabla(p_t text, p_p text DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE AS $f$ SELECT public.admin_tabla(tests.u(900), p_t, p_p) $f$;
CREATE FUNCTION pg_temp.cnt(p_t text) RETURNS bigint LANGUAGE plpgsql AS $f$ DECLARE n bigint; BEGIN EXECUTE format('SELECT count(*) FROM public.%I', p_t) INTO n; RETURN n; END $f$;
CREATE TEMP TABLE t_tablas (n int, t text);
INSERT INTO t_tablas VALUES (1, 'usuario'), (2, 'cuenta'), (3, 'bolsillo'), (4, 'cdt_definicion'), (5, 'cdt'), (6, 'credito_producto'), (7, 'credito'), (8, 'cuota'), (9, 'transaccion'), (10, 'reloj'), (11, 'parametro');

-- ============================================================================
-- A. admin_esquema
-- ============================================================================
CREATE TEMP TABLE t_h0 AS SELECT tests.huella_saldos() AS h, (SELECT count(*) FROM audit.evento) AS ev;
CREATE TEMP TABLE t_e AS SELECT public.admin_esquema(tests.u(900)) AS j;
SELECT assert_eq('A1 forma del contrato (types.ts Esquema): {tablas}; cada tabla {nombre, columnas, fks}; cada columna {nombre, tipo, llave, unico, no_nulo}; cada fk {columna, tabla_destino, columna_destino}',
                 (SELECT ((SELECT array_agg(DISTINCT k ORDER BY k) FROM t_e, jsonb_object_keys(j) k),
                          (SELECT array_agg(DISTINCT k ORDER BY k) FROM t_e, jsonb_array_elements(j -> 'tablas') t, jsonb_object_keys(t) k),
                          (SELECT array_agg(DISTINCT k ORDER BY k) FROM t_e, jsonb_array_elements(j -> 'tablas') t, jsonb_array_elements(t -> 'columnas') c, jsonb_object_keys(c) k),
                          (SELECT array_agg(DISTINCT k ORDER BY k) FROM t_e, jsonb_array_elements(j -> 'tablas') t, jsonb_array_elements(t -> 'fks') f, jsonb_object_keys(f) k))::text),
                 '({tablas},"{columnas,fks,nombre}","{llave,no_nulo,nombre,tipo,unico}","{columna,columna_destino,tabla_destino}")'::text);
SELECT assert_eq('A2 son EXACTAMENTE las 11 tablas de la lista, en el orden del grafo (la lista blanca de _reglas_control)',
                 (SELECT array_agg(t ->> 'nombre' ORDER BY o) FROM t_e, jsonb_array_elements(j -> 'tablas') WITH ORDINALITY x(t, o)),
                 ARRAY['usuario', 'cuenta', 'bolsillo', 'cdt_definicion', 'cdt', 'credito_producto', 'credito', 'cuota', 'transaccion', 'reloj', 'parametro']::text[]);
SELECT assert_eq('A3 DERIVA: la lista blanca = las tablas base REALES de public (si alguien agrega una tabla, esta prueba falla hasta que se decida su visibilidad); audit.evento y el esquema tests no estan',
                 (SELECT array_agg(table_name::text ORDER BY table_name) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'),
                 (SELECT array_agg(t ORDER BY t) FROM jsonb_array_elements_text(public._reglas_control() -> 'tablas') t));
-- oraculo INDEPENDIENTE (information_schema) de columnas, tipos y banderas
CREATE TEMP TABLE t_or AS
  SELECT c.table_name::text AS tabla, c.column_name::text AS col, row_number() OVER (PARTITION BY c.table_name ORDER BY c.ordinal_position) AS rk,
         EXISTS (SELECT 1 FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage k USING (constraint_schema, constraint_name, table_name)
                  WHERE tc.constraint_type = 'PRIMARY KEY' AND k.table_schema = 'public' AND k.table_name = c.table_name AND k.column_name = c.column_name) AS llave,
         EXISTS (SELECT 1 FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage k USING (constraint_schema, constraint_name, table_name)
                  WHERE tc.constraint_type = 'UNIQUE' AND k.table_schema = 'public' AND k.table_name = c.table_name AND k.column_name = c.column_name
                    AND (SELECT count(*) FROM information_schema.key_column_usage k2 WHERE k2.constraint_schema = k.constraint_schema AND k2.constraint_name = k.constraint_name) = 1) AS unico,
         (c.is_nullable = 'NO') AS no_nulo,
         (SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a WHERE a.attrelid = ('public.' || quote_ident(c.table_name))::regclass AND a.attname = c.column_name) AS tipo
    FROM information_schema.columns c JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
   WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE';
CREATE TEMP TABLE t_es AS
  SELECT (t ->> 'nombre')::text AS tabla, (c ->> 'nombre')::text AS col, row_number() OVER (PARTITION BY t ->> 'nombre' ORDER BY o) AS rk,
         (c ->> 'llave')::boolean AS llave, (c ->> 'unico')::boolean AS unico, (c ->> 'no_nulo')::boolean AS no_nulo, (c ->> 'tipo')::text AS tipo
    FROM t_e, jsonb_array_elements(j -> 'tablas') t, jsonb_array_elements(t -> 'columnas') WITH ORDINALITY x(c, o);
SELECT assert_eq('A4 las columnas de las 11 tablas (nombre, ORDEN, llave, unico, no_nulo y tipo) coinciden una a una con el oraculo de information_schema: 0 diferencias en ambos sentidos y mas de 100 columnas comparadas',
                 ((SELECT count(*) FROM ((SELECT * FROM t_or EXCEPT SELECT * FROM t_es) UNION ALL (SELECT * FROM t_es EXCEPT SELECT * FROM t_or)) z), (SELECT count(*) > 100 FROM t_or))::text, '(0,t)'::text);
CREATE TEMP TABLE t_fo AS
  SELECT kcu.table_name::text AS tabla, kcu.column_name::text AS col, ccu.table_name::text AS destino, ccu.column_name::text AS col_destino
    FROM information_schema.referential_constraints rc
    JOIN information_schema.key_column_usage kcu ON kcu.constraint_schema = rc.constraint_schema AND kcu.constraint_name = rc.constraint_name AND kcu.ordinal_position = 1
    JOIN information_schema.key_column_usage ccu ON ccu.constraint_schema = rc.unique_constraint_schema AND ccu.constraint_name = rc.unique_constraint_name AND ccu.ordinal_position = kcu.position_in_unique_constraint
   WHERE rc.constraint_schema = 'public';
CREATE TEMP TABLE t_fe AS SELECT (t ->> 'nombre')::text AS tabla, (f ->> 'columna')::text AS col, (f ->> 'tabla_destino')::text AS destino, (f ->> 'columna_destino')::text AS col_destino
                            FROM t_e, jsonb_array_elements(j -> 'tablas') t, jsonb_array_elements(t -> 'fks') f;
SELECT assert_eq('A5 las FK coinciden con el oraculo de information_schema (una entrada por restriccion, con su primera columna): 0 diferencias y las 12 del catalogo',
                 ((SELECT count(*) FROM ((SELECT * FROM t_fo EXCEPT SELECT * FROM t_fe) UNION ALL (SELECT * FROM t_fe EXCEPT SELECT * FROM t_fo)) z), (SELECT count(*) FROM t_fe))::text, '(0,12)'::text);
SELECT assert_eq('A6 incluye la FK propia usuario.referido_por -> usuario.id (checklist del contrato) y la compuesta de cuenta (usuario_id, rol) sale UNA sola vez (usuario_id -> id), sin una arista duplicada rol -> rol',
                 ((SELECT count(*) FROM t_fe WHERE tabla = 'usuario' AND col = 'referido_por' AND destino = 'usuario' AND col_destino = 'id'),
                  (SELECT array_agg(col || '->' || destino || '.' || col_destino) FROM t_fe WHERE tabla = 'cuenta'))::text, '(1,{usuario_id->usuario.id})'::text);
SELECT assert_eq('A7 las banderas con sentido (PK, UNIQUE de una columna, NOT NULL, tipo literal): usuario.id llave sin unico; username unico; cuota.numero (UNIQUE compuesto) NO es unico; cuenta.usuario_id unico y no nulo; tipos dinero / uuid / estado_usuario',
                 (SELECT concat_ws('|', (SELECT (llave, unico)::text FROM t_es WHERE tabla = 'usuario' AND col = 'id'), (SELECT unico::text FROM t_es WHERE tabla = 'usuario' AND col = 'username'),
                                        (SELECT unico::text FROM t_es WHERE tabla = 'cuota' AND col = 'numero'), (SELECT (unico, no_nulo)::text FROM t_es WHERE tabla = 'cuenta' AND col = 'usuario_id'),
                                        (SELECT tipo FROM t_es WHERE tabla = 'cuenta' AND col = 'balance'), (SELECT tipo FROM t_es WHERE tabla = 'usuario' AND col = 'id'), (SELECT tipo FROM t_es WHERE tabla = 'usuario' AND col = 'estado'))),
                 '(t,f)|true|false|(t,t)|dinero|uuid|estado_usuario'::text);
SELECT assert_eq('A8 el esquema NO escribe nada ni corre el motor: huella de saldos y eventos de auditoria intactos', (tests.huella_saldos() = (SELECT h FROM t_h0), (SELECT count(*) FROM audit.evento) = (SELECT ev FROM t_h0))::text, '(t,t)'::text);

-- ============================================================================
-- B. admin_tabla
-- ============================================================================
DELETE FROM public.cdt_definicion;                                                            -- (en esta transaccion) para tener una tabla vacia
SELECT assert_eq('B1 tabla vacia (cdt_definicion): filas [] , pagina 1 de 1 y las columnas del esquema', (SELECT (j -> 'filas', j -> 'pagina', j -> 'total_paginas', jsonb_array_length(j -> 'columnas') = (SELECT count(*) FROM t_es WHERE tabla = 'cdt_definicion'))::text FROM (SELECT pg_temp.tabla('cdt_definicion') AS j) x),
                 '([],1,1,t)'::text);
-- datos en las 11 tablas
SELECT tests.fondear(tests.c(1), 20000000);
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min) VALUES (tests.p(930), 'CDT 30', 30, 10, 1);
INSERT INTO public.credito_producto (id, nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES (tests.p(901), 'Libre', '', 18, 1, 1000000000, 1, 360);
SELECT public.crear_bolsillo(tests.u(1), 'Viajes');
SELECT public.crear_cdt(tests.u(1), tests.p(930)::text, 1000000);
SELECT public.solicitar_credito(tests.u(1), tests.p(901)::text, 2000000, 12);
SELECT tests.fondear(tests.c(1), 1000 + g) FROM generate_series(1, 60) g;                       -- mas de 50 movimientos
CREATE TEMP TABLE t_p1 AS SELECT pg_temp.tabla('usuario') AS j, pg_temp.cnt('usuario') AS n;
SELECT assert_json_shape('B2 forma del contrato (PaginaTabla): {columnas, filas, pagina, total_paginas}', (SELECT j FROM t_p1), '{"columnas":"array","filas":"array","pagina":"number","total_paginas":"number"}'::jsonb);
SELECT assert_eq('B3 50 por pagina: >= 122 usuarios (120 clientes + 2 admin) = ceil(n/50) paginas (>= 3); las dos primeras traen 50 y la ultima el resto',
                 (SELECT ((j ->> 'total_paginas')::int = ceil(n / 50.0)::int AND n >= 122, jsonb_array_length(j -> 'filas'), jsonb_array_length(pg_temp.tabla('usuario', '2') -> 'filas'), jsonb_array_length(pg_temp.tabla('usuario', ceil(n / 50.0)::int::text) -> 'filas') = n - 50 * (ceil(n / 50.0)::int - 1))::text FROM t_p1), '(t,50,50,t)'::text);
SELECT assert_eq('B4 el orden es el de _reglas_control (creado_en DESC, id): la pagina 1 es EXACTAMENTE las 50 primeras ids del oraculo',
                 (SELECT array_agg((f ->> 'id')::uuid ORDER BY o) FROM t_p1, jsonb_array_elements(j -> 'filas') WITH ORDINALITY x(f, o)),
                 (SELECT array_agg(id ORDER BY creado_en DESC, id) FROM (SELECT id, creado_en FROM public.usuario ORDER BY creado_en DESC, id LIMIT 50) z));
SELECT assert_eq('B5 p_pagina es TEXTO y se recorta: NULL, vacio, espacios, "abc", "0", "-3", "1.5", "1; DROP TABLE usuario" = pagina 1; "99" y "999999999" = la ULTIMA; "2" = 2; " 3 " = 3',
                 (SELECT array_agg(pg_temp.tabla('usuario', v) ->> 'pagina' ORDER BY o) FROM unnest(ARRAY[NULL, '', '   ', 'abc', '0', '-3', '1.5', '1; DROP TABLE usuario', '99', '999999999', '2', ' 3 ']) WITH ORDINALITY x(v, o)),
                 (SELECT ARRAY['1', '1', '1', '1', '1', '1', '1', '1', ceil(n / 50.0)::int::text, ceil(n / 50.0)::int::text, '2', '3']::text[] FROM t_p1));
-- caso limite (auditoria): enteros positivos de MAS de 9 digitos son validos y mayores que el total = la ULTIMA pagina, sin desbordar integer ni bigint; el resto del comportamiento se conserva
SELECT assert_eq('B5b enteros positivos de cualquier longitud mayores que el total = la ULTIMA pagina y NUNCA un error: 10 digitos (1000000000), mas que un integer (2147483648, 4294967296), 19 y 20 digitos, 30 digitos, 5000 digitos, con ceros a la izquierda y con espacios',
                 (SELECT array_agg(coalesce(pg_temp.err(format('SELECT pg_temp.tabla(''usuario'', %L)', v)), 'NULL') || ':' || (pg_temp.tabla('usuario', v) ->> 'pagina') ORDER BY o)
                    FROM unnest(ARRAY['1000000000', '2147483647', '2147483648', '4294967296', '9223372036854775807', '9223372036854775808', '99999999999999999999', repeat('9', 30), repeat('9', 5000), '0000000000000000000000000000000000000000001000000000', ' 1000000000 ']) WITH ORDINALITY x(v, o)),
                 (SELECT array_agg('OK:' || ceil(n / 50.0)::int::text) FROM t_p1, generate_series(1, 11)));
SELECT assert_eq('B5c ...y se conserva lo demas: ceros a la izquierda de una pagina valida ("0000000000002" = 2), solo ceros = 1, y NULL, vacio, "-1000000000", "+5", "1e9", "1000000000.5", "1,5", "mil" y 5000 letras = pagina 1 sin error',
                 (SELECT array_agg(pg_temp.err(format('SELECT pg_temp.tabla(''usuario'', %L)', v)) || ':' || (pg_temp.tabla('usuario', v) ->> 'pagina') ORDER BY o)
                    FROM unnest(ARRAY['0000000000002', '0000000000000000000000000000000', NULL, '', '-1000000000', '+5', '1e9', '1000000000.5', '1,5', 'mil', repeat('a', 5000)]) WITH ORDINALITY x(v, o)),
                 ARRAY['OK:2', 'OK:1', 'OK:1', 'OK:1', 'OK:1', 'OK:1', 'OK:1', 'OK:1', 'OK:1', 'OK:1', 'OK:1']::text[]);
SELECT assert_eq('B6 la tabla sigue en pie tras el "1; DROP TABLE usuario" (no es SQL: es un texto no numerico)', (SELECT count(*) FROM public.usuario), (SELECT n FROM t_p1));
SELECT assert_eq('B7 total_paginas = max(1, ceil(filas / 50)) y las filas de la pagina = min(50, resto) para las 11 tablas (oraculo: count(*))',
                 (SELECT count(*) FROM t_tablas t,
                         LATERAL (SELECT pg_temp.tabla(t.t) AS j, pg_temp.cnt(t.t) AS n) z
                   WHERE (z.j ->> 'total_paginas')::int <> greatest(1, ceil(z.n / 50.0)::int) OR jsonb_array_length(z.j -> 'filas') <> least(50, z.n)),
                 0::bigint);
SELECT assert_eq('B8 las 11 tablas tienen al menos una fila en esta prueba (la comparacion de claves de abajo no es vacia)',
                 (SELECT count(*) FROM t_tablas t WHERE jsonb_array_length(pg_temp.tabla(t.t) -> 'filas') = 0), 0::bigint);
SELECT assert_eq('B9 para las 11 tablas: columnas = las del esquema (mismo orden) y las claves de CADA fila son exactamente esas columnas',
                 (SELECT count(*) FROM t_tablas t, LATERAL (SELECT pg_temp.tabla(t.t) AS j) z
                   WHERE (SELECT array_agg(c ORDER BY o) FROM jsonb_array_elements_text(z.j -> 'columnas') WITH ORDINALITY x(c, o)) IS DISTINCT FROM (SELECT array_agg(col ORDER BY rk) FROM t_es WHERE tabla = t.t)
                      OR EXISTS (SELECT 1 FROM jsonb_array_elements(z.j -> 'filas') f
                                  WHERE (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(f) k) IS DISTINCT FROM (SELECT array_agg(c ORDER BY c) FROM jsonb_array_elements_text(z.j -> 'columnas') c))),
                 0::bigint);
-- el hash
SELECT assert_eq('B10 usuario: TODAS las filas (3 paginas) traen password_hash = "••••" exacto (U+2022 x4) y el hash real de nadie aparece en ninguna parte de la respuesta',
                 (SELECT ((SELECT count(*) FROM generate_series(1, 3) p, jsonb_array_elements(pg_temp.tabla('usuario', p::text) -> 'filas') f WHERE f ->> 'password_hash' IS DISTINCT FROM repeat(chr(8226), 4)),
                          (SELECT count(*) FROM generate_series(1, 3) p WHERE pg_temp.tabla('usuario', p::text)::text LIKE '%REALHASH%' OR pg_temp.tabla('usuario', p::text)::text LIKE '%' || md5('cli1') || '%'),
                          (SELECT count(*) FROM generate_series(1, 3) p, jsonb_array_elements(pg_temp.tabla('usuario', p::text) -> 'filas') f WHERE NOT f ? 'password_hash'))::text), '(0,0,0)'::text);
SELECT assert_eq('B11 ninguna de las 11 tablas deja pasar un hash real (busqueda del texto REALHASH en toda la respuesta)', (SELECT count(*) FROM t_tablas t WHERE pg_temp.tabla(t.t)::text LIKE '%REALHASH%'), 0::bigint);
SELECT assert_eq('B12 sin sobre-enmascarar: la fila de usuario es la real MENOS el hash (el resto de columnas intacto) y una fila de cuenta es EXACTAMENTE to_jsonb de la fila',
                 ((SELECT (f - 'password_hash') = (to_jsonb(u) - 'password_hash') FROM t_p1, jsonb_array_elements(j -> 'filas') f JOIN public.usuario u ON u.id = (f ->> 'id')::uuid LIMIT 1),
                  (SELECT bool_and(f = to_jsonb(c)) FROM jsonb_array_elements(pg_temp.tabla('cuenta') -> 'filas') f JOIN public.cuenta c ON c.id = (f ->> 'id')::uuid))::text, '(t,t)'::text);
-- tipos y zona
SELECT set_config('TimeZone', 'UTC', true);
CREATE TEMP TABLE t_tz AS SELECT pg_temp.tabla('transaccion') AS tx, pg_temp.tabla('cdt') AS cdt, pg_temp.tabla('cuenta') AS cta;
SELECT set_config('TimeZone', 'America/Bogota', true);
SELECT assert_eq('B13 tipos JSON: dinero y orden = NUMERO (nunca texto), fecha ISO con -05:00 aunque la sesion pida UTC (por codigo), date = YYYY-MM-DD, uuid = texto; tx_id (xid8) sale como texto (decision D-E12-6)',
                 (SELECT (jsonb_typeof(tx #> '{filas,0,monto}'), jsonb_typeof(tx #> '{filas,0,orden}'), tx #>> '{filas,0,fecha}' LIKE '%-05:00', (cdt #>> '{filas,0,fecha_inicio}') ~ '^\d{4}-\d{2}-\d{2}$', jsonb_typeof(cta #> '{filas,0,balance}'),
                          (tx #>> '{filas,0,id}') ~ '^[0-9a-f-]{36}$', jsonb_typeof(tx #> '{filas,0,tx_id}'))::text FROM t_tz), '(number,number,t,t,number,t,string)'::text);
SELECT assert_eq('B14 transaccion: mas reciente primero (orden DESC) y estrictamente decreciente en la pagina; cuota: (credito_id, numero) ascendente',
                 ((SELECT (f0 ->> 'orden')::bigint = (SELECT max(orden) FROM public.transaccion) FROM (SELECT pg_temp.tabla('transaccion') #> '{filas,0}' AS f0) z),
                  (SELECT bool_and((f ->> 'orden')::bigint < lag) FROM (SELECT f, lag((f ->> 'orden')::bigint) OVER (ORDER BY o) AS lag FROM jsonb_array_elements(pg_temp.tabla('transaccion') -> 'filas') WITH ORDINALITY x(f, o)) q WHERE lag IS NOT NULL),
                  (SELECT array_agg((f ->> 'numero')::int ORDER BY o) = (SELECT array_agg(numero ORDER BY credito_id, numero) FROM public.cuota) FROM jsonb_array_elements(pg_temp.tabla('cuota') -> 'filas') WITH ORDINALITY x(f, o)))::text, '(t,t,t)'::text);
-- lista blanca
SELECT assert_eq('B15 FUERA de la lista = "Tabla no permitida" (mensaje del contrato, P0001): audit.evento, evento, public.usuario, mayusculas, espacios, pg_user, pg_catalog.*, information_schema.*, tests.*, vacio y NULL',
                 (SELECT array_agg(DISTINCT pg_temp.err(format('SELECT public.admin_tabla(tests.u(900), %L)', v))) FROM unnest(ARRAY['audit.evento', 'evento', 'public.usuario', 'Usuario', 'USUARIO', ' usuario', 'usuario ', 'pg_user', 'pg_catalog.pg_user', 'information_schema.tables', 'tests.cliente', '']) v),
                 ARRAY['Tabla no permitida']::text[]);
SELECT assert_eq('B16 ...y NULL tambien', pg_temp.err($$SELECT public.admin_tabla(tests.u(900), NULL)$$), 'Tabla no permitida'::text);
SELECT assert_eq('B17 inyeccion: nombres con comillas, punto y coma y comentarios son un nombre no permitido y NO ejecutan nada (las tablas siguen)',
                 ((SELECT array_agg(DISTINCT pg_temp.err(format('SELECT public.admin_tabla(tests.u(900), %L)', v))) FROM unnest(ARRAY['usuario; DROP TABLE cuenta; --', 'usuario" CASCADE', 'usuario'' OR ''1''=''1', 'cuenta) t; DELETE FROM usuario; --', 'usuario UNION SELECT 1']) v),
                  (SELECT count(*) FROM public.cuenta) > 0, (SELECT count(*) FROM public.usuario))::text, '("{""Tabla no permitida""}",t,' || (SELECT n FROM t_p1) || ')'::text);
SELECT assert_eq('B18 el administrador se valida ANTES que la tabla: un cliente o un admin bloqueado con una tabla invalida recibe Acceso denegado / el mensaje de bloqueo, no "Tabla no permitida" (no sondea la lista)',
                 (pg_temp.err(format('SELECT public.admin_tabla(%L, ''audit.evento'')', tests.u(1))), pg_temp.err(format('SELECT public.admin_tabla(%L, ''audit.evento'')', tests.u(902))))::text,
                 ('("Acceso denegado","' || public._msg_auth('bloqueado') || '")')::text);

-- ============================================================================
-- C. Solo lectura y valores provisionales
-- ============================================================================
SELECT assert_eq('C1 SOLO LECTURA por catalogo: ambas son STABLE (PostgreSQL impide que escriban) y su codigo no contiene INSERT / UPDATE / DELETE / TRUNCATE',
                 (SELECT (count(*), bool_and(provolatile = 's'), count(*) FILTER (WHERE prosrc ~* '\m(insert|update|delete|truncate)\M'))::text FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('admin_esquema', 'admin_tabla')), '(2,t,0)'::text);
CREATE TEMP TABLE t_h1 AS SELECT tests.huella_saldos() AS h, (SELECT count(*) FROM audit.evento) AS ev, (SELECT count(*) FROM public.transaccion) AS n;
SELECT public.admin_esquema(tests.u(900)), pg_temp.tabla('usuario'), pg_temp.tabla('transaccion', '2'), pg_temp.tabla('bolsillo');
SELECT assert_eq('C2 ni esquema ni tabla cambian saldos, libro ni auditoria al llamarse (tampoco con la tabla de la que depende el motor)', (tests.huella_saldos() = (SELECT h FROM t_h1), (SELECT count(*) FROM audit.evento) = (SELECT ev FROM t_h1))::text, '(t,t)'::text);
-- el visor muestra lo GUARDADO: con intereses pendientes (reloj +40 dias) NO corre el motor
CREATE TEMP TABLE t_u AS SELECT (SELECT ultimo_cobro FROM public.bolsillo WHERE cuenta_id = tests.c(1) AND nombre = 'Viajes') AS uc;
SELECT public._reloj_actualizar(false, pg_temp.dia(40)::text);
SELECT pg_temp.tabla('bolsillo'), pg_temp.tabla('cdt'), pg_temp.tabla('cuenta'), public.admin_esquema(tests.u(900));
SELECT assert_eq('C3 con el reloj adelantado (intereses y cierres pendientes) el visor NO devenga ni cobra: el libro no crece, el bolsillo conserva su ultimo_cobro y el CDT sigue ACTIVO (muestra lo guardado, no lo derivado)',
                 ((SELECT count(*) FROM public.transaccion) = (SELECT n FROM t_h1), (SELECT ultimo_cobro FROM public.bolsillo WHERE cuenta_id = tests.c(1) AND nombre = 'Viajes') = (SELECT uc FROM t_u), (SELECT estado::text FROM public.cdt WHERE cuenta_id = tests.c(1)))::text, '(t,t,ACTIVO)'::text);
SELECT assert_eq('C4 los valores PROVISIONALES estan fijados en _reglas_control(): 11 tablas, 50 por pagina, solo password_hash enmascarado (D-E12-D1), "••••", el mensaje del contrato y SIN audit.evento (D-E12-D2)',
                 public._reglas_control() - 'orden',
                 jsonb_build_object('tablas', jsonb_build_array('usuario', 'cuenta', 'bolsillo', 'cdt_definicion', 'cdt', 'credito_producto', 'credito', 'cuota', 'transaccion', 'reloj', 'parametro'),
                                    'pagina_tam', 50, 'enmascarar', jsonb_build_object('usuario', jsonb_build_array('password_hash')), 'mascara', repeat(chr(8226), 4), 'msg_tabla', 'Tabla no permitida'));
SELECT assert_eq('C5 cada tabla de la lista tiene su orden definido y es una expresion que funciona (las 11 paginas responden)', (SELECT count(*) FROM t_tablas t WHERE public._reglas_control() -> 'orden' ->> t.t IS NULL), 0::bigint);

-- ============================================================================
-- D. Catalogo y permisos
-- ============================================================================
SELECT assert_eq('D1 _validar_admin es lo primero en ambas (antes de leer, validar o armar SQL); sin motor, sin libro, sin auditoria, sin reloj suelto; el SQL dinamico solo con %I y el nombre de la lista',
                 (SELECT (count(*), bool_and(strpos(prosrc, '_validar_admin(') > 0 AND strpos(prosrc, '_validar_admin(') < strpos(prosrc, '_reglas_control()')),
                          count(*) FILTER (WHERE prosrc ~* '(_avanzar_hasta|_asentar_grupo|_auditar_admin|_reloj_instantanea|audit\.evento|now\s*\(|current_(date|time)|hoy_banco|ahora_banco|_ahora_real)'),
                          (SELECT strpos(prosrc, 'public.%I') > 0 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'admin_tabla'))::text
                    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('admin_esquema', 'admin_tabla')), '(2,t,0,t)'::text);
SELECT assert_eq('D2 SECURITY DEFINER, search_path fijo, zona de Bogota por codigo y jsonb en ambas',
                 (SELECT (count(*), bool_and(prosecdef), bool_and('search_path=public, pg_temp' = ANY (proconfig)), bool_and('TimeZone=America/Bogota' = ANY (proconfig)), bool_and(prorettype = 'jsonb'::regtype))::text FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('admin_esquema', 'admin_tabla')),
                 '(2,t,t,t,t)'::text);
SELECT assert_eq('D3 permisos: banco_app y banco_dev ejecutan las 2; PUBLIC y banco_lector ninguna; _reglas_control: nadie salvo el dueño',
                 (SELECT (count(*) FILTER (WHERE proname <> '_reglas_control' AND has_function_privilege('banco_app', oid, 'EXECUTE')), count(*) FILTER (WHERE proname <> '_reglas_control' AND has_function_privilege('banco_dev', oid, 'EXECUTE')),
                          count(*) FILTER (WHERE has_function_privilege('banco_lector', oid, 'EXECUTE')),
                          count(*) FILTER (WHERE EXISTS (SELECT 1 FROM aclexplode(coalesce(proacl, acldefault('f', proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')),
                          count(*) FILTER (WHERE proname = '_reglas_control' AND (has_function_privilege('banco_app', oid, 'EXECUTE') OR has_function_privilege('banco_dev', oid, 'EXECUTE'))))::text
                    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('admin_esquema', 'admin_tabla', '_reglas_control')), '(2,2,0,0,0)'::text);
SELECT assert_ok('D4 banco_app ejecuta las 2 con un admin valido (y el hash sale enmascarado)', $$SET LOCAL ROLE banco_app; SELECT public.admin_esquema(tests.u(900)), public.admin_tabla(tests.u(900), 'usuario', '1')$$);
SELECT assert_raises('D5 banco_lector NO ejecuta admin_tabla (permiso denegado)', $$SET LOCAL ROLE banco_lector; SELECT public.admin_tabla(tests.u(900), 'usuario')$$, NULL, '42501');
SELECT assert_raises('D6 ni siquiera banco_dev ejecuta el helper _reglas_control', $$SET LOCAL ROLE banco_dev; SELECT public._reglas_control()$$, NULL, '42501');
SELECT assert_eq('D7 la secuencia entera deja el banco sano: v_integridad_global.ok', (SELECT ok FROM public.v_integridad_global), true);

ROLLBACK;
