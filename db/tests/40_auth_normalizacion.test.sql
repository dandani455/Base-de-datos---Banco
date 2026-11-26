-- 40_auth_normalizacion.test.sql · Etapa 4 · utilidades PURAS de 13: reglas y mensajes centralizados, normalizadores de texto,
-- cedula y telefono (el + solo al inicio del telefono, nunca en la cedula), base del username (regla B), edad y forma bcrypt.
BEGIN;

-- ============================================================================
-- 1. Reglas provisionales y mensajes: UN solo lugar, contenido exacto (cambiar una regla obliga a cambiar la prueba)
-- ============================================================================
SELECT assert_eq('_reglas_registro(): contenido exacto de todos los valores provisionales y tecnicos', public._reglas_registro(),
  '{"edad_minima":18,"edad_maxima":120,"cedula_min":6,"cedula_max":10,"telefono_nacional_digitos":10,"telefono_internacional_min":8,
    "telefono_internacional_max":15,"nombre_min":1,"nombre_max":60,"correo_max":254,"hash_max":100,"username_intentos_3_digitos":30,
    "username_intentos_4_digitos":30,"username_apellido_max":20,"cuenta_prefijo":"40","cuenta_intentos":50,"ingresos_ventana_dias":90,
    "ingresos_margen_segundos":60}'::jsonb);
SELECT assert_eq('_reglas_registro() es IMMUTABLE (valores, no consultas)', (SELECT provolatile::text FROM pg_proc WHERE oid = 'public._reglas_registro()'::regprocedure), 'i'::text);

DO $$
DECLARE r record; mal text := '';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('politica',      'Debe aceptar la política de datos'),
    ('bloqueado',     'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla'),
    ('denegado',      'Acceso denegado'),
    ('no_encontrado', 'Recurso no encontrado'),
    ('incompleto',    'Datos de registro incompletos'),
    ('invalido',      'Datos de registro inválidos'),
    ('nombre',        'Nombre inválido'),
    ('apellido',      'Apellido inválido'),
    ('cedula',        'Cédula inválida'),
    ('correo',        'Correo inválido'),
    ('telefono',      'Teléfono inválido'),
    ('nacimiento',    'Fecha de nacimiento inválida'),
    ('mayor_edad',    'Debes ser mayor de edad para registrarte'),
    ('dup_cedula',    'La cédula ya está registrada'),
    ('dup_correo',    'El correo ya está registrado'),
    ('dup_telefono',  'El teléfono ya está registrado'),
    ('referido',      'Código de referido inválido'),
    ('sesion',        'Sesión inválida'),
    ('agotado',       'No fue posible generar el usuario, intenta de nuevo')) v(k, m)
  LOOP
    IF public._msg_auth(r.k) IS DISTINCT FROM r.m THEN mal := mal || r.k || '; '; END IF;
  END LOOP;
  PERFORM tests.assert_eq('_msg_auth(): los 19 mensajes (4 del contrato exactos + 15 provisionales) son los esperados', mal, ''::text);
END $$;
SELECT assert_eq('_msg_auth(clave desconocida) devuelve NULL (error de programacion que una prueba puede vigilar)', public._msg_auth('no_existe'), NULL::text);

-- ============================================================================
-- 2. _norm_texto: conserva el nombre real (tildes, mayusculas, otros alfabetos)
-- ============================================================================
SELECT assert_eq('_norm_texto: recorta y colapsa espacios, conserva tildes y mayusculas', public._norm_texto('  Juan   Pérez  '), 'Juan Pérez'::text);
SELECT assert_eq('_norm_texto: tabuladores y saltos de linea cuentan como espacio', public._norm_texto(E'a\t\n b'), 'a b'::text);
SELECT assert_eq('_norm_texto: otros alfabetos intactos', public._norm_texto('  李   明 '), '李 明'::text);
SELECT assert_eq('_norm_texto(NULL) = NULL', public._norm_texto(NULL), NULL::text);

-- ============================================================================
-- 3. _norm_digitos: perfil cedula (false) y perfil telefono (true)
-- ============================================================================
SELECT assert_eq('_norm_digitos cedula: el + no se admite JAMAS', public._norm_digitos('+123', false), NULL::text);
SELECT assert_eq('_norm_digitos telefono: un + inicial se consume', public._norm_digitos('+123', true), '123'::text);
SELECT assert_eq('_norm_digitos telefono: el punto NO es separador de telefono', public._norm_digitos('1.2', true), NULL::text);
SELECT assert_eq('_norm_digitos cedula: el guion NO es separador de cedula', public._norm_digitos('1-2', false), NULL::text);
SELECT assert_eq('_norm_digitos cedula: punto y espacio si', public._norm_digitos('1.2 3', false), '123'::text);
SELECT assert_eq('_norm_digitos telefono: espacio, guion y parentesis si', public._norm_digitos('(1) 2-3', true), '123'::text);
SELECT assert_eq('_norm_digitos(NULL) = NULL', public._norm_digitos(NULL, true), NULL::text);
SELECT assert_eq('_norm_digitos: sin ningun digito = NULL', (public._norm_digitos('. .', false), public._norm_digitos('()', true), public._norm_digitos('+', true))::text, '(,,)'::text);

DO $$
DECLARE r record; mal text := '';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('1.234.567', '1234567'), ('80 123 456', '80123456'), ('  123456  ', '123456'), ('1234567890', '1234567890'),
    ('1 2 3 4 5 6', '123456'), ('1234567.', '1234567'),
    ('12345', NULL), ('12345678901', NULL), ('+1234567', NULL), ('12+34567', NULL), ('1234567+', NULL), ('123-4567', NULL),
    ('12a4567', NULL), ('', NULL), (NULL, NULL), ('. . .', NULL), ('١٢٣٤٥٦٧', NULL), (E'12\t34567', NULL), ('(123456)', NULL)) v(i, e)
  LOOP
    IF public._norm_cedula(r.i) IS DISTINCT FROM r.e THEN mal := mal || coalesce(r.i, 'NULL') || ' -> ' || coalesce(public._norm_cedula(r.i), 'NULL') || '; '; END IF;
  END LOOP;
  PERFORM tests.assert_eq('_norm_cedula: 19 casos (separadores solo espacio y punto; nunca +; 6-10 digitos; solo ASCII)', mal, ''::text);
END $$;

DO $$
DECLARE r record; mal text := '';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('3001234567', '3001234567'), ('300 123 4567', '3001234567'), ('(300) 123-4567', '3001234567'), ('300-123-4567', '3001234567'),
    ('+57 300 123 4567', '3001234567'), ('+573001234567', '3001234567'), (' +573001234567 ', '3001234567'), ('+ 57 3001234567', '3001234567'),
    ('+(57)3001234567', '3001234567'), ('+1 415 555 2671', '14155552671'), ('+14155552671', '14155552671'), ('+12345678', '12345678'),
    ('+123456789012345', '123456789012345'), ('+57 300 123 456', '57300123456'),
    ('573001234567', NULL), ('300123456', NULL), ('30012345678', NULL), ('+0123456789', NULL), ('+1234567', NULL), ('+1234567890123456', NULL),
    ('3001+234567', NULL), ('+57+3001234567', NULL), ('++573001234567', NULL), ('300 123 456a', NULL), ('', NULL), (NULL, NULL), ('+', NULL),
    ('()', NULL), ('300.123.4567', NULL), ('+57 300.123.4567', NULL), ((SELECT string_agg(chr(1632 + d::int), '') FROM unnest(string_to_array('3001234567', NULL)) d), NULL)) v(i, e)
  LOOP
    IF public._norm_telefono(r.i) IS DISTINCT FROM r.e THEN mal := mal || coalesce(r.i, 'NULL') || ' -> ' || coalesce(public._norm_telefono(r.i), 'NULL') || '; '; END IF;
  END LOOP;
  PERFORM tests.assert_eq('_norm_telefono: 31 casos (+ solo al inicio y una vez; 10 digitos nacional; 8-15 con +; +57 y 10 = nacional; 12 digitos sin + rechazado)', mal, ''::text);
END $$;
SELECT assert_eq('+57 y 10 digitos se guarda IGUAL que el nacional: la misma linea no puede registrarse dos veces con formas distintas',
                 public._norm_telefono('+57 301 765 4321') = public._norm_telefono('3017654321'), true);

-- ============================================================================
-- 4. _username_base (regla B): nunca rechaza; respaldo para alfabetos sin equivalente latino
-- ============================================================================
DO $$
DECLARE r record; mal text := '';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('Juan', 'Pérez', 'jperez'), ('María del Pilar', 'Núñez Pérez', 'mnunez'), ('Ñandú', 'Rodríguez-Peña', 'nrodriguez'),
    ('José', 'De la Cruz Pérez', 'jcruz'), ('Ana', 'de la', 'ade'), ('Pat', 'O''Brien', 'pobrien'), ('Pat', 'O’Brien', 'pobrien'),
    ('ÁNGEL', 'MÜLLER', 'amuller'), ('Juan', 'Pérez Gómez', 'jperez'), ('  Juan', 'Pérez', 'jperez'), ('Juan Carlos', 'Pérez', 'jperez'),
    ('Juan', 'Pérez2', 'jperez2'), ('A', 'Abcdefghijklmnopqrstuvwxyz', 'aabcdefghijklmnopqrst'),
    ('Zoë', 'Łukasz', 'zlukasz'), ('Žofia', 'Østergaard', 'zostergaard'), ('Jürgen', 'Straße', 'jstrasse'),
    ('李明', '王', 'uusuario'), ('Ivan', 'Петров', 'iusuario'), ('Жан', 'Dupont', 'udupont'), ('محمد', 'علي', 'uusuario'),
    ('', '', 'uusuario'), (NULL, NULL, 'uusuario')) v(n, a, e)
  LOOP
    IF public._username_base(r.n, r.a) IS DISTINCT FROM r.e THEN mal := mal || coalesce(r.n, 'NULL') || '/' || coalesce(r.a, 'NULL') || ' -> ' || public._username_base(r.n, r.a) || '; '; END IF;
    IF public._username_base(r.n, r.a) || '123' !~ '^[a-z][a-z0-9]{2,29}$' THEN mal := mal || 'ck(' || coalesce(r.n, 'NULL') || '); '; END IF;
  END LOOP;
  PERFORM tests.assert_eq('_username_base: 22 casos (tildes, enie, particulas, apostrofos, compuestos, alfabetos no latinos con respaldo) y SIEMPRE cumple ck_usuario_username al agregar 3 digitos', mal, ''::text);
END $$;
SELECT assert_eq('un nombre en OTRO alfabeto no produce error en la generacion del username (regla B nunca rechaza)',
                 (public._username_base('Μαρία', 'Παπαδοπούλου') IS NOT NULL), true);

-- ============================================================================
-- 5. _edad_en: con la fecha que se le pasa (la del reloj del banco), no con la del sistema
-- ============================================================================
SELECT assert_eq('edad el dia exacto del cumpleaños', public._edad_en(DATE '1990-05-17', DATE '2026-05-17'), 36);
SELECT assert_eq('edad un dia antes del cumpleaños', public._edad_en(DATE '1990-05-17', DATE '2026-05-16'), 35);
SELECT assert_eq('29-feb: el 28-feb del año no bisiesto aun tiene 17', public._edad_en(DATE '2008-02-29', DATE '2026-02-28'), 17);
SELECT assert_eq('29-feb: el 1-mar ya tiene 18', public._edad_en(DATE '2008-02-29', DATE '2026-03-01'), 18);
SELECT assert_eq('mismo dia: edad 0', public._edad_en(DATE '2000-01-01', DATE '2000-01-01'), 0);
SELECT assert_eq('edad con NULL = NULL', (public._edad_en(NULL, DATE '2026-01-01'), public._edad_en(DATE '2000-01-01', NULL))::text, '(,)'::text);

-- ============================================================================
-- 6. _es_hash_bcrypt: la BD nunca guarda una clave en claro
-- ============================================================================
SELECT assert_eq('hash bcrypt de ejemplo ($2b$10$...)', public._es_hash_bcrypt(tests.hash()), true);
SELECT assert_eq('hash con prefijo $2a$ y coste 04', public._es_hash_bcrypt('$2a$04$' || repeat('a', 53)), true);
SELECT assert_eq('hash con prefijo $2y$ y coste 31', public._es_hash_bcrypt('$2y$31$' || repeat('./Az09', 8) || 'abcde'), true);
DO $$
DECLARE r record; mal text := '';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('Banco2026'), (''), ('texto plano con espacios'), ('$2b$10$' || repeat('a', 52)), ('$2b$10$' || repeat('a', 54)), ('$2b$03$' || repeat('a', 53)),
    ('$2b$32$' || repeat('a', 53)), ('$2c$10$' || repeat('a', 53)), ('$2B$10$' || repeat('a', 53)), ('$2b$10$' || repeat('a', 52) || '!'),
    (' ' || tests.hash()), (tests.hash() || E'\n'), ('$1$salt$' || repeat('a', 22)), ('$2b$10' || repeat('a', 53)), ('2b$10$' || repeat('a', 53)),
    ('$2b$1$' || repeat('a', 54)), ('$2b$10$' || repeat('a', 53) || 'x'), (repeat('a', 60)), ('$argon2id$v=19$m=65536,t=3,p=4$c29tZXNhbHQ$RdescudvJCsgt3ub+b+dWRWJTmaaJObG')) v(h)
  LOOP
    IF public._es_hash_bcrypt(r.h) THEN mal := mal || left(r.h, 12) || '; '; END IF;
  END LOOP;
  PERFORM tests.assert_eq('_es_hash_bcrypt rechaza 19 formas que NO son bcrypt (claro, longitudes, costes, prefijos, caracteres, argon2)', mal, ''::text);
END $$;
SELECT assert_eq('_es_hash_bcrypt(NULL) = false (no NULL)', public._es_hash_bcrypt(NULL), false);

-- ============================================================================
-- 7. Alfabetos: la BD reconoce letras de cualquier alfabeto (L7); depende de la configuracion regional de la base
-- ============================================================================
SELECT assert_true('la BD esta en UTF8 con una configuracion regional que reconoce letras no latinas como [[:alpha:]] (cirilico, chino, arabe, griego, hebreo) y no los digitos',
                   ('Ж' ~ '^[[:alpha:]]$') AND ('李' ~ '^[[:alpha:]]+$') AND ('محمد' ~ '^[[:alpha:]]+$') AND ('Μαρία' ~ '^[[:alpha:]]+$')
                   AND ('שלום' ~ '^[[:alpha:]]+$') AND ('é' ~ '^[[:alpha:]]$') AND ('1' !~ '[[:alpha:]]')
                   AND (SELECT pg_encoding_to_char(encoding) = 'UTF8' FROM pg_database WHERE datname = current_database()));
DO $$
DECLARE r record; mal text := '';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('Jean-Luc', true), ('O''Brien', true), ('D’Artagnan', true), ('Jr.', true), ('José', true), ('Jose' || chr(769), true),
    ('李明', true), ('王', true), ('Ж', true), ('Μαρία', true), ('محمد', true), ('שלום', true), ('María del Pilar', true), (repeat('a', 60), true),
    ('Juan2', false), ('Ju_an', false), ('Juan;', false), ('J@n', false), ('Ju' || chr(1) || 'an', false), ('Ahmed' || chr(1635), false),
    ('Ahmed' || chr(65299), false), ('Ahmed' || chr(2407), false), ('-Juan', false), ('.Juan', false), ('1', false), ('', false), (NULL, false),
    (repeat('a', 61), false), (' Juan', false), ('Robert''); DROP TABLE usuario;--', false), ('Juan<script>', false)) v(n, e)
  LOOP
    IF public._nombre_valido(r.n) IS DISTINCT FROM r.e THEN mal := mal || coalesce(left(r.n, 20), 'NULL') || ' (esperado ' || r.e || '); '; END IF;
  END LOOP;
  PERFORM tests.assert_eq('_nombre_valido: 31 casos (letras de cualquier alfabeto SI; digitos de cualquier alfabeto, simbolos, controles, inicio con signo, vacio y longitud NO)', mal, ''::text);
END $$;

-- ============================================================================
-- 8. Convenciones de E4: puras, sin EXECUTE publico, con COMMENT
-- ============================================================================
SELECT assert_eq('las 10 utilidades puras existen con COMMENT y dueño banco_owner',
                 (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND pg_get_userbyid(p.proowner) = 'banco_owner'
                     AND p.proname IN ('_reglas_registro','_msg_auth','_nombre_valido','_norm_texto','_norm_digitos','_norm_cedula','_norm_telefono','_username_base','_edad_en','_es_hash_bcrypt')
                     AND obj_description(p.oid, 'pg_proc') IS NOT NULL), 10::bigint);

ROLLBACK;
