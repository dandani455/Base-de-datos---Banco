-- 41_auth_registro.test.sql · Etapa 4 · registrar_usuario: registro completo, CADA validacion con su mensaje exacto y su orden, duplicados,
-- nombres internacionales, generacion de username (reintentos y agotamiento) y cuenta, entradas hostiles. Una transaccion con ROLLBACK final.
-- (Las pruebas de rol real, atomicidad, ingresos, referidos y concurrencia estan en 42-48 y reales/39-40.)
BEGIN;

CREATE TEMP SEQUENCE sq;
-- intenta(overrides jsonb): llama a registrar_usuario con valores validos por defecto (unicos) y los cambios indicados.
-- Devuelve 'OK' o el mensaje de error. Una clave presente con JSON null pasa NULL de verdad.
CREATE FUNCTION pg_temp.intenta(p jsonb) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n bigint := nextval('sq');
BEGIN
  PERFORM public.registrar_usuario(
    CASE WHEN p ? 'nombres'   THEN p ->> 'nombres'   ELSE 'Ana' END,
    CASE WHEN p ? 'apellidos' THEN p ->> 'apellidos' ELSE 'Gomez' END,
    CASE WHEN p ? 'cedula'    THEN p ->> 'cedula'    ELSE '5' || lpad(n::text, 7, '0') END,
    CASE WHEN p ? 'correo'    THEN p ->> 'correo'    ELSE 'u' || n || '@mail.co' END,
    CASE WHEN p ? 'tel'       THEN p ->> 'tel'       ELSE '32' || lpad(n::text, 8, '0') END,
    CASE WHEN p ? 'nac'       THEN p ->> 'nac'       ELSE '1990-05-17' END,
    CASE WHEN p ? 'hash'      THEN p ->> 'hash'      ELSE tests.hash() END,
    CASE WHEN p ? 'pol'       THEN (p ->> 'pol')::boolean ELSE true END,
    CASE WHEN p ? 'ref'       THEN p ->> 'ref'       ELSE NULL END,
    CASE WHEN p ? 'verif'     THEN (p ->> 'verif')::boolean ELSE true END);
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END $f$;

-- grupo(etiqueta, filas (override, esperado)): exige que cada fila devuelva exactamente el mensaje esperado
CREATE FUNCTION pg_temp.grupo(p_label text, p_casos jsonb) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE c jsonb; v_msg text; mal text := ''; n int := 0;
BEGIN
  FOR c IN SELECT * FROM jsonb_array_elements(p_casos) LOOP
    v_msg := pg_temp.intenta(c -> 'o');
    n := n + 1;
    IF v_msg IS DISTINCT FROM (c ->> 'e') THEN mal := mal || (c ->> 'o') || ' => [' || v_msg || '] (esperado [' || (c ->> 'e') || ']); '; END IF;
  END LOOP;
  PERFORM tests.assert_eq(p_label || ' (' || n || ' casos)', mal, ''::text);
END $f$;

-- ============================================================================
-- 1. Registro feliz: forma, username, cuenta, valores guardados normalizados
-- ============================================================================
SELECT assert_eq('estado inicial: sin usuarios ni cuentas ni patas', (SELECT (SELECT count(*) FROM public.usuario) + (SELECT count(*) FROM public.cuenta) + (SELECT count(*) FROM public.transaccion)), 0::bigint);
CREATE TEMP TABLE t_ok AS
  SELECT public.registrar_usuario('  María   del Pilar ', ' Núñez  Pérez', '1.234.567', '  Maria@Mail.COM ', '(300) 123-4567', '1990-05-17', tests.hash(), true, NULL, true) AS r;
SELECT assert_json_shape('la salida es exactamente {usuario_id, username} (jsonb): ni hash, ni rol, ni cuenta', (SELECT r FROM t_ok),
                         '{"usuario_id":"string","username":"string"}'::jsonb);
SELECT assert_eq('la salida tiene SOLO 2 claves', (SELECT count(*) FROM t_ok, jsonb_object_keys(t_ok.r)), 2::bigint);
SELECT assert_true('username = inicial + primer apellido sin tildes ni particulas + 3-4 digitos (Maria del Pilar Nunez Perez -> mnunez###)',
                   (SELECT r ->> 'username' ~ '^mnunez[0-9]{3,4}$' FROM t_ok));
SELECT assert_eq('el usuario quedo guardado: id, nombres y apellidos normalizados (conservan tildes), cedula en digitos, correo en minusculas, telefono en digitos',
                 (SELECT (u.nombres, u.apellidos, u.cedula, u.correo, u.telefono, u.fecha_nacimiento::text)::text
                    FROM public.usuario u, t_ok WHERE u.id = (t_ok.r ->> 'usuario_id')::uuid),
                 '("María del Pilar","Núñez Pérez",1234567,maria@mail.com,3001234567,1990-05-17)'::text);
SELECT assert_eq('rol CLIENTE, estado ACTIVO, correo sin verificar, bono no pagado, sin referidor',
                 (SELECT (u.rol, u.estado, u.correoverificado, u.bono_referido_pagado, u.referido_por IS NULL)::text FROM public.usuario u, t_ok WHERE u.id = (t_ok.r ->> 'usuario_id')::uuid),
                 '(CLIENTE,ACTIVO,f,f,t)'::text);
SELECT assert_true('codigo_referido es un uuid propio, distinto del id',
                   (SELECT u.codigo_referido IS NOT NULL AND u.codigo_referido <> u.id FROM public.usuario u, t_ok WHERE u.id = (t_ok.r ->> 'usuario_id')::uuid));
SELECT assert_true('numero_cuenta de 10 digitos con prefijo 40 y exactamente UNA cuenta, de rol CLIENTE',
                   (SELECT count(*) = 1 AND bool_and(c.numero_cuenta ~ '^40[0-9]{8}$' AND c.rol = 'CLIENTE') FROM public.cuenta c, t_ok WHERE c.usuario_id = (t_ok.r ->> 'usuario_id')::uuid));
SELECT assert_true('password_hash guardado = el recibido (bcrypt); ninguna clave en claro',
                   (SELECT u.password_hash = tests.hash() FROM public.usuario u, t_ok WHERE u.id = (t_ok.r ->> 'usuario_id')::uuid));
SELECT assert_true('usuario.creado_en y cuenta.creado_en son el MISMO instante (el ahora de la instantanea) y estan en el pasado inmediato',
                   (SELECT u.creado_en = c.creado_en AND u.creado_en BETWEEN now() - interval '1 minute' AND clock_timestamp() FROM public.usuario u JOIN public.cuenta c ON c.usuario_id = u.id, t_ok WHERE u.id = (t_ok.r ->> 'usuario_id')::uuid));
SELECT assert_eq('registrar Juan Perez', pg_temp.intenta('{"nombres":"Juan","apellidos":"Pérez"}'::jsonb), 'OK'::text);
SELECT assert_eq('Juan Perez -> jperez### (inicial + primer apellido sin tilde)', (SELECT count(*) FROM public.usuario WHERE username ~ '^jperez[0-9]{3,4}$'), 1::bigint);
SELECT assert_eq('registrar Jose De la Cruz', pg_temp.intenta('{"nombres":"José","apellidos":"De la Cruz"}'::jsonb), 'OK'::text);
SELECT assert_eq('Jose De la Cruz -> jcruz### (se salta la particula "De la")', (SELECT count(*) FROM public.usuario WHERE username ~ '^jcruz[0-9]{3,4}$'), 1::bigint);

-- ============================================================================
-- 2. Validaciones: orden y mensajes exactos
-- ============================================================================
SELECT pg_temp.grupo('POLITICA primero (contrato §6): aun con otros campos invalidos o vacios, el mensaje es el de la politica', '[
  {"o":{"pol":false},"e":"Debe aceptar la política de datos"},
  {"o":{"pol":null},"e":"Debe aceptar la política de datos"},
  {"o":{"pol":false,"nombres":"Ju4n","cedula":"x","correo":"x","tel":"x","nac":"x","hash":"x"},"e":"Debe aceptar la política de datos"},
  {"o":{"pol":false,"nombres":"","apellidos":null,"cedula":null},"e":"Debe aceptar la política de datos"}]'::jsonb);
SELECT pg_temp.grupo('PRESENCIA: cualquier campo obligatorio vacio, NULL o en blanco', '[
  {"o":{"nombres":null},"e":"Datos de registro incompletos"},{"o":{"nombres":""},"e":"Datos de registro incompletos"},{"o":{"nombres":"   "},"e":"Datos de registro incompletos"},
  {"o":{"apellidos":null},"e":"Datos de registro incompletos"},{"o":{"apellidos":"  "},"e":"Datos de registro incompletos"},
  {"o":{"cedula":null},"e":"Datos de registro incompletos"},{"o":{"cedula":""},"e":"Datos de registro incompletos"},
  {"o":{"correo":null},"e":"Datos de registro incompletos"},{"o":{"correo":" "},"e":"Datos de registro incompletos"},
  {"o":{"tel":null},"e":"Datos de registro incompletos"},{"o":{"tel":""},"e":"Datos de registro incompletos"},
  {"o":{"nac":null},"e":"Datos de registro incompletos"},{"o":{"nac":""},"e":"Datos de registro incompletos"},
  {"o":{"hash":null},"e":"Datos de registro incompletos"},{"o":{"hash":""},"e":"Datos de registro incompletos"}]'::jsonb);
SELECT pg_temp.grupo('NOMBRES y APELLIDOS (validacion A): digitos, simbolos, SQL, signos, longitud', '[
  {"o":{"nombres":"Juan2"},"e":"Nombre inválido"},{"o":{"nombres":"Ju_an"},"e":"Nombre inválido"},{"o":{"nombres":"Juan;"},"e":"Nombre inválido"},
  {"o":{"nombres":"Robert''); DROP TABLE usuario;--"},"e":"Nombre inválido"},{"o":{"nombres":"<script>alert(1)</script>"},"e":"Nombre inválido"},
  {"o":{"nombres":"-Juan"},"e":"Nombre inválido"},{"o":{"nombres":".Juan"},"e":"Nombre inválido"},{"o":{"nombres":"J@n"},"e":"Nombre inválido"},
  {"o":{"nombres":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"e":"Nombre inválido"},
  {"o":{"apellidos":"Perez3"},"e":"Apellido inválido"},{"o":{"apellidos":"Pe/rez"},"e":"Apellido inválido"},{"o":{"apellidos":"1"},"e":"Apellido inválido"},
  {"o":{"apellidos":"Perez=1"},"e":"Apellido inválido"},{"o":{"nombres":"Ju4n","apellidos":"P3rez"},"e":"Nombre inválido"}]'::jsonb);
SELECT pg_temp.grupo('CEDULA: longitud 6-10, + jamas, solo punto/espacio como separadores', '[
  {"o":{"cedula":"12345"},"e":"Cédula inválida"},{"o":{"cedula":"12345678901"},"e":"Cédula inválida"},{"o":{"cedula":"+1234567"},"e":"Cédula inválida"},
  {"o":{"cedula":"12+34567"},"e":"Cédula inválida"},{"o":{"cedula":"1234567+"},"e":"Cédula inválida"},{"o":{"cedula":"123-4567"},"e":"Cédula inválida"},
  {"o":{"cedula":"12a4567"},"e":"Cédula inválida"},{"o":{"cedula":"(1234567)"},"e":"Cédula inválida"}]'::jsonb);
SELECT pg_temp.grupo('CORREO: formato y longitud', '[
  {"o":{"correo":"sinarroba"},"e":"Correo inválido"},{"o":{"correo":"a@b"},"e":"Correo inválido"},{"o":{"correo":"a@b."},"e":"Correo inválido"},
  {"o":{"correo":"@b.co"},"e":"Correo inválido"},{"o":{"correo":"a b@c.co"},"e":"Correo inválido"},{"o":{"correo":"a@@b.co"},"e":"Correo inválido"},
  {"o":{"correo":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@b.co"},"e":"Correo inválido"}]'::jsonb);
SELECT pg_temp.grupo('TELEFONO: + solo al inicio, 10 digitos nacional, 8-15 con +', '[
  {"o":{"tel":"300123"},"e":"Teléfono inválido"},{"o":{"tel":"+0123456789"},"e":"Teléfono inválido"},{"o":{"tel":"3001+234567"},"e":"Teléfono inválido"},
  {"o":{"tel":"+57+3001234567"},"e":"Teléfono inválido"},{"o":{"tel":"573001234567"},"e":"Teléfono inválido"},{"o":{"tel":"300.123.4567"},"e":"Teléfono inválido"},
  {"o":{"tel":"abcdefghij"},"e":"Teléfono inválido"},{"o":{"tel":"+1234567"},"e":"Teléfono inválido"}]'::jsonb);
SELECT pg_temp.grupo('HASH: la BD rechaza todo lo que no tenga forma de bcrypt (nunca una clave en claro)', '[
  {"o":{"hash":"Banco2026"},"e":"Datos de registro inválidos"},{"o":{"hash":"texto plano largo con espacios y simbolos!!"},"e":"Datos de registro inválidos"},
  {"o":{"hash":"$2b$10$corto"},"e":"Datos de registro inválidos"},{"o":{"hash":"$2c$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy"},"e":"Datos de registro inválidos"},
  {"o":{"hash":"$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWyZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"},"e":"Datos de registro inválidos"}]'::jsonb);
SELECT pg_temp.grupo('FECHA de nacimiento: formato, fecha inexistente, futura, anterior a 1900', '[
  {"o":{"nac":"1990/05/17"},"e":"Fecha de nacimiento inválida"},{"o":{"nac":"17-05-1990"},"e":"Fecha de nacimiento inválida"},
  {"o":{"nac":"1990-5-17"},"e":"Fecha de nacimiento inválida"},{"o":{"nac":"1990-02-30"},"e":"Fecha de nacimiento inválida"},
  {"o":{"nac":"1990-13-01"},"e":"Fecha de nacimiento inválida"},{"o":{"nac":"abcd-ef-gh"},"e":"Fecha de nacimiento inválida"},
  {"o":{"nac":"1990-05-17 10:00"},"e":"Fecha de nacimiento inválida"},{"o":{"nac":"2999-01-01"},"e":"Fecha de nacimiento inválida"},
  {"o":{"nac":"1899-12-31"},"e":"Fecha de nacimiento inválida"},{"o":{"nac":"1900-01-01"},"e":"Fecha de nacimiento inválida"}]'::jsonb);

-- edad respecto a la fecha del BANCO (hoy de Bogota): 17 años y 364 dias rechaza; justo 18 acepta; 120 acepta; 121 rechaza
CREATE TEMP TABLE t_h AS SELECT (now() AT TIME ZONE 'America/Bogota')::date AS hoy;
SELECT pg_temp.grupo('EDAD: 18 años exactos hoy SI; faltando un dia NO (mayor_edad); 120 SI; 121 NO (fecha invalida)', (
  SELECT jsonb_build_array(
    jsonb_build_object('o', jsonb_build_object('nac', to_char(hoy - interval '18 years', 'YYYY-MM-DD')), 'e', 'OK'),
    jsonb_build_object('o', jsonb_build_object('nac', to_char(hoy - interval '18 years' + interval '1 day', 'YYYY-MM-DD')), 'e', 'Debes ser mayor de edad para registrarte'),
    jsonb_build_object('o', jsonb_build_object('nac', to_char(hoy - interval '10 years', 'YYYY-MM-DD')), 'e', 'Debes ser mayor de edad para registrarte'),
    jsonb_build_object('o', jsonb_build_object('nac', to_char(hoy, 'YYYY-MM-DD')), 'e', 'Debes ser mayor de edad para registrarte'),
    jsonb_build_object('o', jsonb_build_object('nac', to_char(hoy + 1, 'YYYY-MM-DD')), 'e', 'Fecha de nacimiento inválida'),
    jsonb_build_object('o', jsonb_build_object('nac', to_char(hoy - interval '120 years', 'YYYY-MM-DD')), 'e', 'OK'),
    jsonb_build_object('o', jsonb_build_object('nac', to_char(hoy - interval '121 years', 'YYYY-MM-DD')), 'e', 'Fecha de nacimiento inválida'))
  FROM t_h));
SELECT pg_temp.grupo('CODIGO DE REFERIDO (texto): malformado, inexistente, uuid de otro tipo = error; vacio o en blanco = sin referido', '[
  {"o":{"ref":"abc"},"e":"Código de referido inválido"},{"o":{"ref":"12345678-1234-1234-1234-12345678901"},"e":"Código de referido inválido"},
  {"o":{"ref":"zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"},"e":"Código de referido inválido"},{"o":{"ref":"00000000-0000-4000-8000-000000000000"},"e":"Código de referido inválido"},
  {"o":{"ref":"; DROP TABLE usuario;--"},"e":"Código de referido inválido"},
  {"o":{"ref":""},"e":"OK"},{"o":{"ref":"   "},"e":"OK"},{"o":{"ref":null},"e":"OK"}]'::jsonb);

-- ============================================================================
-- 3. Duplicados (en el orden cedula, correo, telefono); las formas equivalentes cuentan como la misma
-- ============================================================================
SELECT assert_eq('(fixture) un usuario base con cedula 6000001, correo base@mail.co y telefono 3209990001', pg_temp.intenta('{"cedula":"6000001","correo":"base@mail.co","tel":"3209990001"}'::jsonb), 'OK'::text);
SELECT pg_temp.grupo('DUPLICADOS: cedula, correo (sin distinguir mayusculas), telefono (con otro formato) y su precedencia', '[
  {"o":{"cedula":"6000001"},"e":"La cédula ya está registrada"},
  {"o":{"cedula":"6.000.001"},"e":"La cédula ya está registrada"},
  {"o":{"cedula":" 6 000 001 "},"e":"La cédula ya está registrada"},
  {"o":{"correo":"base@mail.co"},"e":"El correo ya está registrado"},
  {"o":{"correo":"BASE@Mail.CO"},"e":"El correo ya está registrado"},
  {"o":{"correo":"  base@mail.co "},"e":"El correo ya está registrado"},
  {"o":{"tel":"3209990001"},"e":"El teléfono ya está registrado"},
  {"o":{"tel":"320 999 0001"},"e":"El teléfono ya está registrado"},
  {"o":{"tel":"(320) 999-0001"},"e":"El teléfono ya está registrado"},
  {"o":{"tel":"+57 320 999 0001"},"e":"El teléfono ya está registrado"},
  {"o":{"cedula":"6000001","correo":"base@mail.co","tel":"3209990001"},"e":"La cédula ya está registrada"},
  {"o":{"correo":"base@mail.co","tel":"3209990001"},"e":"El correo ya está registrado"}]'::jsonb);
SELECT assert_eq('un registro duplicado NO deja rastro (sigue habiendo un solo usuario con esa cedula/correo/telefono)',
                 (SELECT count(*) FROM public.usuario WHERE cedula = '6000001' OR correo = 'base@mail.co' OR telefono = '3209990001'), 1::bigint);

-- ============================================================================
-- 4. Nombres internacionales: se ALMACENAN intactos (validacion A); el username usa su regla propia (B)
-- ============================================================================
SELECT pg_temp.grupo('NOMBRES internacionales aceptados: tildes, apostrofes, guiones, cirilico, chino, arabe, griego, hebreo, marcas combinantes', '[
  {"o":{"nombres":"José María","apellidos":"Muñoz-Peña"},"e":"OK"},{"o":{"nombres":"Jean-Luc","apellidos":"O''Brien"},"e":"OK"},
  {"o":{"nombres":"Ivan","apellidos":"Петров"},"e":"OK"},{"o":{"nombres":"李明","apellidos":"王"},"e":"OK"},{"o":{"nombres":"محمد","apellidos":"علي"},"e":"OK"},
  {"o":{"nombres":"Μαρία","apellidos":"Παπαδοπούλου"},"e":"OK"},{"o":{"nombres":"שלום","apellidos":"כהן"},"e":"OK"},
  {"o":{"nombres":"Ж","apellidos":"Ж"},"e":"OK"},{"o":{"nombres":"D’Artagnan","apellidos":"Dr. Jr."},"e":"OK"}]'::jsonb);
SELECT assert_eq('el nombre chino se guardo INTACTO (no se rechaza ni se transliterera) y su username usa el respaldo',
                 (SELECT (nombres, apellidos, username ~ '^uusuario[0-9]{3,4}$')::text FROM public.usuario WHERE nombres = '李明'), '(李明,王,t)'::text);
SELECT assert_eq('Ivan Петров: nombre y apellido intactos; username = i + usuario (el apellido no tiene letras a-z)',
                 (SELECT (apellidos, username ~ '^iusuario[0-9]{3,4}$')::text FROM public.usuario WHERE apellidos = 'Петров'), '(Петров,t)'::text);
SELECT assert_eq('Muñoz-Peña: el username usa el primer apellido sin tildes (munoz)',
                 (SELECT username ~ '^jmunoz[0-9]{3,4}$' FROM public.usuario WHERE apellidos = 'Muñoz-Peña'), true);
SELECT pg_temp.grupo('TELEFONOS aceptados: separadores, internacional con + inicial y +57 canonico', '[
  {"o":{"tel":"(321) 111-2222"},"e":"OK"},{"o":{"tel":"+1 415 555 2671"},"e":"OK"},{"o":{"tel":"+57 322 333 4444"},"e":"OK"},{"o":{"tel":"323-444-5555"},"e":"OK"}]'::jsonb);
SELECT assert_eq('+57 322 333 4444 se guardo como los 10 digitos nacionales; +1 415... con su codigo de pais',
                 (SELECT array_agg(telefono ORDER BY telefono) FROM public.usuario WHERE telefono IN ('3223334444', '14155552671')), ARRAY['14155552671', '3223334444']::text[]);
SELECT assert_eq('registrar con cedula 1.098.765.432 (separadores de miles)', pg_temp.intenta('{"cedula":"1.098.765.432"}'::jsonb), 'OK'::text);
SELECT assert_eq('...la cedula con separadores se guardo en digitos', (SELECT count(*) FROM public.usuario WHERE cedula = '1098765432'), 1::bigint);

-- ============================================================================
-- 5. Los mensajes NUNCA repiten la entrada del usuario
-- ============================================================================
DO $$
DECLARE k text; v_msg text; mal text := '';
BEGIN
  FOREACH k IN ARRAY ARRAY['nombres', 'apellidos', 'cedula', 'correo', 'tel', 'nac', 'hash', 'ref'] LOOP
    v_msg := pg_temp.intenta(jsonb_build_object(k, 'ZZMARCA9'));
    IF v_msg IS NULL OR v_msg = 'OK' OR v_msg LIKE '%ZZMARCA9%' THEN mal := mal || k || ' [' || coalesce(v_msg, 'NULL') || ']; '; END IF;
  END LOOP;
  PERFORM tests.assert_eq('ningun mensaje de error contiene el valor que escribio el usuario (8 campos)', mal, ''::text);
END $$;

-- ============================================================================
-- 6. Username: miles de nombres iguales, reintentos y agotamiento (3 digitos -> 4 digitos -> error)
-- ============================================================================
SELECT assert_eq('150 registros del MISMO nombre (Juan Perez): todos los usernames son distintos y cumplen el patron',
                 (SELECT (count(DISTINCT x ->> 'username'), count(*) FILTER (WHERE x ->> 'username' ~ '^jperez[0-9]{3,4}$'))::text
                    FROM (SELECT tests.reg(1000 + g, 'Juan', 'Pérez') AS x FROM generate_series(1, 150) g) s),
                 '(150,150)'::text);
-- se ocupan los 900 usernames de 3 digitos (jperez100..jperez999) para forzar el paso a 4 digitos, y luego los 9000 de 4 digitos
INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento)
SELECT 'jperez' || g, tests.hash(), 'N', 'A', '7' || lpad(g::text, 8, '0'), 'ocupa' || g || '@mail.co', '33' || lpad(g::text, 8, '0'), DATE '1990-01-01'
  FROM generate_series(100, 999) g ON CONFLICT (username) DO NOTHING;
SELECT assert_true('con los 900 usernames de 3 digitos ocupados, el registro pasa a 4 digitos (jperez####)',
                   (SELECT (tests.reg(2000, 'Juan', 'Pérez') ->> 'username') ~ '^jperez[0-9]{4}$'));
INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento)
SELECT 'jperez' || g, tests.hash(), 'N', 'A', '6' || lpad(g::text, 8, '0'), 'ocupb' || g || '@mail.co', '34' || lpad(g::text, 8, '0'), DATE '1990-01-01'
  FROM generate_series(1000, 9999) g ON CONFLICT (username) DO NOTHING;
CREATE TEMP TABLE t_antes AS SELECT tests.huella_registro() AS h;
SELECT assert_eq('con TODOS los usernames (3 y 4 digitos) ocupados: mensaje de agotamiento y no queda nada',
                 tests.captura($$SELECT tests.reg(2001, 'Juan', 'Pérez')$$), 'No fue posible generar el usuario, intenta de nuevo'::text);
SELECT assert_eq('...el agotamiento revirtio TODO (usuario, cuenta y patas)', tests.huella_registro(), (SELECT h FROM t_antes));
DELETE FROM public.usuario WHERE nombres = 'N' AND apellidos = 'A';        -- limpia los usuarios de relleno (no tienen cuenta)

-- ============================================================================
-- 7. Numero de cuenta: 10 digitos, prefijo 40, unico; reintento si colisiona
-- ============================================================================
SELECT assert_eq('todas las cuentas creadas: 10 digitos con prefijo 40 y numeros distintos',
                 (SELECT (count(*) = count(DISTINCT numero_cuenta), bool_and(numero_cuenta ~ '^40[0-9]{8}$'))::text FROM public.cuenta), '(t,t)'::text);
SELECT assert_eq('todo CLIENTE registrado tiene su cuenta (la integridad de E4 lo vigila)', (SELECT count(*) FROM public.v_integridad_auth WHERE NOT ok), 0::bigint);
SELECT assert_true('la integridad global sigue en orden tras cientos de registros', (SELECT ok FROM public.v_integridad_global));
-- colision de numero de cuenta: se ocupa un numero y se fuerza la semilla del azar para que el primer intento coincida
DO $$
DECLARE v_num text; v_id uuid; v_ok boolean := false; i int;
BEGIN
  -- con la semilla 0.31 el primer numero aleatorio es siempre el mismo: se ocupa y se vuelve a sembrar
  PERFORM setseed(0.31);
  v_num := '40' || lpad((floor(random() * 100000000))::bigint::text, 8, '0');
  INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento)
  VALUES ('colision1', tests.hash(), 'C', 'C', '5550001', 'colision1@mail.co', '3250001111', DATE '1990-01-01') RETURNING id INTO v_id;
  INSERT INTO public.cuenta (usuario_id, numero_cuenta) VALUES (v_id, v_num);
  PERFORM setseed(0.31);                                       -- el primer intento de registrar_usuario coincidira con v_num salvo por el consumo del azar previo
  FOR i IN 1 .. 3 LOOP
    PERFORM tests.reg(3000 + i, 'Carla', 'Lopez');
  END LOOP;
  PERFORM tests.assert_eq('el registro con un numero de cuenta ocupado sigue funcionando (reintenta) y los numeros siguen siendo unicos',
                          (SELECT (count(*) = count(DISTINCT numero_cuenta))::text FROM public.cuenta), 'true'::text);
END $$;

-- ============================================================================
-- 8. Entradas hostiles no rompen nada
-- ============================================================================
SELECT assert_true('las tablas siguen existiendo tras los intentos de inyeccion SQL en nombres, referido y correo',
                   (SELECT count(*) = 3 FROM pg_tables WHERE schemaname = 'public' AND tablename IN ('usuario', 'cuenta', 'transaccion')));
SELECT assert_eq('un correo con comillas y punto y coma se rechaza como formato (no se interpreta como SQL)',
                 pg_temp.intenta('{"correo":"a''; DROP TABLE usuario; --@x.co"}'::jsonb), 'Correo inválido'::text);
SELECT assert_eq('emoji y caracteres de control en el nombre se rechazan', (pg_temp.intenta(jsonb_build_object('nombres', 'Juan' || chr(128512))),
                                                                          pg_temp.intenta(jsonb_build_object('nombres', 'Ju' || chr(7) || 'an')))::text,
                 '("Nombre inválido","Nombre inválido")'::text);
SELECT assert_eq('una tarjeta de credito pegada en la cedula se rechaza', pg_temp.intenta('{"cedula":"4111 1111 1111 1111"}'::jsonb), 'Cédula inválida'::text);

-- ============================================================================
-- 9. Garantias globales del registro
-- ============================================================================
SELECT assert_eq('no existe ningun parametro para elegir rol, username ni cuenta: la firma tiene exactamente 10 parametros y ninguno es rol/username/cuenta',
                 (SELECT (pronargs, proargnames::text !~ 'rol|username|numero_cuenta|usuario')::text FROM pg_proc WHERE oid = 'public.registrar_usuario(text,text,text,text,text,text,text,boolean,text,boolean)'::regprocedure),
                 '(10,t)'::text);
SELECT assert_eq('todos los registrados son CLIENTE y ACTIVO', (SELECT count(*) FROM public.usuario WHERE rol <> 'CLIENTE' OR estado <> 'ACTIVO'), 0::bigint);
SELECT assert_eq('ningun hash guardado es otra cosa que un bcrypt', (SELECT count(*) FROM public.usuario WHERE NOT public._es_hash_bcrypt(password_hash)), 0::bigint);

ROLLBACK;
