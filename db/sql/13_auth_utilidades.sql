-- ============================================================================
-- 13_auth_utilidades.sql  ·  Etapa 4 (autenticación y registro) · parte 1/2
-- Propósito  : utilidades PURAS y valores/mensajes provisionales de E4. Las usan las funciones de 14.
--              Ninguna consulta el reloj ni una fecha del sistema: reciben todo por parámetro.
--
--   _reglas_registro()   jsonb   TODOS los valores provisionales/técnicos de E4 en UN solo lugar (edad, formatos, ventanas…)
--   _msg_auth(clave)     text    TODOS los mensajes de E4 en UN solo lugar (contractuales y provisionales hasta D13)
--   _nombre_valido       VALIDACIÓN A: ¿se puede almacenar el nombre? (letras de cualquier alfabeto; sin dígitos)
--   _norm_texto          trim + espacios colapsados; conserva mayúsculas, tildes y alfabetos (se guarda el nombre real)
--   _norm_digitos        solo dígitos ASCII; el signo + solo al inicio y solo si se permite (perfil teléfono)
--   _norm_cedula         cédula: separadores espacio y punto; nunca +; 6-10 dígitos (provisional D-E4-13)
--   _norm_telefono       teléfono: + solo al inicio; 10 dígitos nacional o 8-15 con + (E.164); +57 + 10 dígitos = nacional
--   _username_base       inicial + primer apellido (sin tildes, sin partículas) con respaldo para alfabetos no latinos
--   _edad_en             años cumplidos a una fecha dada (la del reloj del banco, que pasa quien llama)
--   _es_hash_bcrypt      forma de un hash bcrypt ($2a/$2b/$2y$NN$ + 53 caracteres): la BD nunca guarda una clave en claro
--
-- Dueño banco_owner. Internas: sin EXECUTE para nadie salvo el dueño.
-- Dependencias : 00 a 12 (unaccent de 00).   Ejecución: como superusuario, IDEMPOTENTE, transaccional.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- Valores provisionales y técnicos (UN solo lugar)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reglas_registro()
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'edad_minima',                    18,    -- D-E4-12 (PROVISIONAL, equipo)
    'edad_maxima',                    120,   -- D-E4-12 (PROVISIONAL, equipo)
    'cedula_min',                     6,     -- D-E4-13 (PROVISIONAL, equipo)
    'cedula_max',                     10,    -- D-E4-13 (PROVISIONAL, equipo)
    'telefono_nacional_digitos',      10,    -- D-E4-13 (PROVISIONAL, equipo)
    'telefono_internacional_min',     8,     -- D-E4-13 (PROVISIONAL, equipo)
    'telefono_internacional_max',     15,    -- D-E4-13 (PROVISIONAL, equipo): E.164
    'nombre_min',                     1,     -- técnico: 1 porque hay apellidos de un solo carácter (p. ej. 王)
    'nombre_max',                     60,    -- técnico
    'correo_max',                     254,   -- técnico
    'hash_max',                       100,   -- técnico
    'username_intentos_3_digitos',    30,    -- D-E4-3 (aprobada)
    'username_intentos_4_digitos',    30,    -- D-E4-3 (aprobada)
    'username_apellido_max',          20,    -- D-E4-3 (aprobada)
    'cuenta_prefijo',                 '40',  -- D-E4-4 (aprobada): '40' + 8 dígitos
    'cuenta_intentos',                50,    -- técnico
    'ingresos_ventana_dias',          90,    -- D-E4-5 (aprobada)
    'ingresos_margen_segundos',       60     -- D-E4-5: el último ingreso queda al menos 1 minuto antes de la instantánea
  )
$$;
COMMENT ON FUNCTION public._reglas_registro() IS
  'E4. PURA. Todos los valores provisionales (equipo: D-E4-12/13) y técnicos de E4 en UN solo lugar. Cambiar una regla = editar aquí y su prueba (la prueba fija el contenido exacto).';

-- ----------------------------------------------------------------------------
-- Mensajes (UN solo lugar). Contractuales: politica, bloqueado, denegado, no_encontrado. El resto: PROVISIONALES hasta D13.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._msg_auth(p_clave text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
BEGIN
  RETURN CASE p_clave
    -- contrato §6 (exactos)
    WHEN 'politica'      THEN 'Debe aceptar la política de datos'
    WHEN 'bloqueado'     THEN 'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla'
    WHEN 'denegado'      THEN 'Acceso denegado'
    WHEN 'no_encontrado' THEN 'Recurso no encontrado'
    -- PROVISIONALES (D-E4-15 / D13)
    WHEN 'incompleto'    THEN 'Datos de registro incompletos'
    WHEN 'invalido'      THEN 'Datos de registro inválidos'
    WHEN 'nombre'        THEN 'Nombre inválido'
    WHEN 'apellido'      THEN 'Apellido inválido'
    WHEN 'cedula'        THEN 'Cédula inválida'
    WHEN 'correo'        THEN 'Correo inválido'
    WHEN 'telefono'      THEN 'Teléfono inválido'
    WHEN 'nacimiento'    THEN 'Fecha de nacimiento inválida'
    WHEN 'mayor_edad'    THEN 'Debes ser mayor de edad para registrarte'
    -- D-E4-17 (negocio pendiente): mensajes ESPECÍFICOS de duplicado; pasar a uno genérico = cambiar estas tres líneas
    WHEN 'dup_cedula'    THEN 'La cédula ya está registrada'
    WHEN 'dup_correo'    THEN 'El correo ya está registrado'
    WHEN 'dup_telefono'  THEN 'El teléfono ya está registrado'
    WHEN 'referido'      THEN 'Código de referido inválido'
    WHEN 'sesion'        THEN 'Sesión inválida'                                           -- D-E4-16
    WHEN 'agotado'       THEN 'No fue posible generar el usuario, intenta de nuevo'
    ELSE NULL                                                            -- clave desconocida: NULL (error de programación que las pruebas vigilan)
  END;
END
$$;
COMMENT ON FUNCTION public._msg_auth(text) IS
  'E4. PURA. Todos los mensajes de E4. Contrato §6 (exactos): politica, bloqueado, denegado, no_encontrado. Provisionales hasta D13: el resto (D-E4-15/16/17). Una clave desconocida devuelve NULL (las pruebas lo vigilan).';

-- ----------------------------------------------------------------------------
-- Normalización
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._norm_texto(p_texto text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT btrim(regexp_replace(p_texto, '[[:space:]]+', ' ', 'g'))
$$;
COMMENT ON FUNCTION public._norm_texto(text) IS
  'E4. PURA. Recorta y colapsa espacios (también tabuladores y saltos); conserva mayúsculas, tildes y cualquier alfabeto: el nombre real se guarda tal cual.';

-- VALIDACIÓN A (para ALMACENAR el nombre): letras de CUALQUIER alfabeto, espacio, apóstrofo (' o ’), punto, guion y marcas combinantes.
-- Sin dígitos: [[:alpha:]] en esta configuración regional también acepta dígitos no ASCII (p. ej. ٣), por eso se excluyen
-- explícitamente. Recibe el texto ya normalizado (_norm_texto). NO exige ninguna letra a-z (eso es de la regla B, el username).
CREATE OR REPLACE FUNCTION public._nombre_valido(p_texto text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT coalesce(
           length(p_texto) BETWEEN (public._reglas_registro() ->> 'nombre_min')::int AND (public._reglas_registro() ->> 'nombre_max')::int
           AND p_texto ~ '^[[:alpha:]]'
           AND p_texto ~ '^[[:alpha:] ''’.\u0300-\u036f-]+$'
           AND p_texto !~ '[0-9\u0660-\u0669\u06f0-\u06f9\u0966-\u096f\u09e6-\u09ef\uff10-\uff19]', false)
$$;
COMMENT ON FUNCTION public._nombre_valido(text) IS
  'E4. PURA. Validación A: ¿se puede ALMACENAR este nombre/apellido (ya normalizado)? 1-60 caracteres; letras de cualquier alfabeto, espacio, apóstrofo, punto, guion y marcas combinantes; sin dígitos (ASCII ni de otros alfabetos). No exige letras a-z: el username se genera aparte (regla B) y nunca rechaza el registro.';

-- p_permite_mas_inicial = false -> perfil CÉDULA (separadores admitidos: espacio y punto; ningún +)
-- p_permite_mas_inicial = true  -> perfil TELÉFONO (separadores: espacio, guion y paréntesis; un + solo como PRIMER carácter)
-- Devuelve solo dígitos ASCII, o NULL si hay un carácter no permitido, un + fuera de la primera posición, un + no permitido o ningún dígito.
CREATE OR REPLACE FUNCTION public._norm_digitos(p_texto text, p_permite_mas_inicial boolean)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE
  v text := btrim(p_texto);
BEGIN
  IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
  IF left(v, 1) = '+' THEN
    IF NOT coalesce(p_permite_mas_inicial, false) THEN RETURN NULL; END IF;
    v := substr(v, 2);                                    -- el + inicial se consume; cualquier otro + queda y falla abajo
  END IF;
  IF coalesce(p_permite_mas_inicial, false) THEN
    IF v !~ '^[0-9 ()-]+$' THEN RETURN NULL; END IF;      -- teléfono
    v := regexp_replace(v, '[ ()-]', '', 'g');
  ELSE
    IF v !~ '^[0-9 .]+$' THEN RETURN NULL; END IF;        -- cédula
    v := regexp_replace(v, '[ .]', '', 'g');
  END IF;
  IF v = '' THEN RETURN NULL; END IF;
  RETURN v;
END
$$;
COMMENT ON FUNCTION public._norm_digitos(text, boolean) IS
  'E4. PURA. Solo dígitos ASCII. Perfil cédula (false): separadores espacio y punto, nunca +. Perfil teléfono (true): separadores espacio, guion y paréntesis, y un + únicamente como primer carácter. NULL si hay cualquier otro carácter, un + mal ubicado o ningún dígito.';

CREATE OR REPLACE FUNCTION public._norm_cedula(p_texto text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE
  d text := public._norm_digitos(p_texto, false);
BEGIN
  IF d IS NULL THEN RETURN NULL; END IF;
  IF length(d) NOT BETWEEN (public._reglas_registro() ->> 'cedula_min')::int AND (public._reglas_registro() ->> 'cedula_max')::int THEN
    RETURN NULL;
  END IF;
  RETURN d;
END
$$;
COMMENT ON FUNCTION public._norm_cedula(text) IS
  'E4. PURA. Cédula en dígitos o NULL: separadores solo espacio y punto, nunca +, longitud según _reglas_registro() (provisional D-E4-13: 6-10).';

CREATE OR REPLACE FUNCTION public._norm_telefono(p_texto text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_mas boolean := left(btrim(p_texto), 1) = '+';
  d     text    := public._norm_digitos(p_texto, true);
BEGIN
  IF d IS NULL THEN RETURN NULL; END IF;
  IF v_mas THEN
    -- internacional (E.164): el código de país no empieza en 0; 8-15 dígitos en total
    IF d !~ '^[1-9]' THEN RETURN NULL; END IF;
    IF length(d) NOT BETWEEN (public._reglas_registro() ->> 'telefono_internacional_min')::int
                         AND (public._reglas_registro() ->> 'telefono_internacional_max')::int THEN
      RETURN NULL;
    END IF;
    -- forma canónica: +57 seguido de 10 dígitos es el mismo número nacional (una línea no puede registrarse con dos formas)
    IF d ~ '^57[0-9]{10}$' THEN RETURN substr(d, 3); END IF;
    RETURN d;
  END IF;
  -- sin +: exactamente los dígitos de un número nacional (12 dígitos sin + son ambiguos y se rechazan)
  IF length(d) <> (public._reglas_registro() ->> 'telefono_nacional_digitos')::int THEN RETURN NULL; END IF;
  RETURN d;
END
$$;
COMMENT ON FUNCTION public._norm_telefono(text) IS
  'E4. PURA. Teléfono en dígitos o NULL: un + solo como primer carácter; sin + exactamente 10 dígitos; con + de 8 a 15 dígitos (el código de país no empieza en 0); +57 y 10 dígitos se guarda como esos 10 (misma línea = misma cadena, para que el UNIQUE no se burle). Provisional D-E4-13.';

-- ----------------------------------------------------------------------------
-- Username (regla B: NO es la validación del nombre; nunca rechaza un registro)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._username_base(p_nombres text, p_apellidos text)
RETURNS text LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_n        text := lower(public.unaccent(coalesce(p_nombres, '')));
  v_a        text := lower(public.unaccent(coalesce(p_apellidos, '')));
  v_inicial  text;
  v_tokens   text[];
  v_apellido text := NULL;
  t          text;
BEGIN
  -- inicial: primera letra a-z del nombre; si no hay (alfabeto sin equivalente latino) -> 'u'
  v_inicial := coalesce(substring(v_n FROM '[a-z]'), 'u');
  -- apellido: apóstrofos se unen (O'Brien -> obrien); cualquier otro no alfanumérico separa (Pérez-Gómez -> perez gomez)
  v_a := regexp_replace(v_a, '[''’]', '', 'g');
  v_a := btrim(regexp_replace(v_a, '[^a-z0-9]+', ' ', 'g'));
  IF v_a <> '' THEN
    v_tokens := string_to_array(v_a, ' ');
    FOREACH t IN ARRAY v_tokens LOOP
      IF t NOT IN ('de', 'del', 'la', 'las', 'los', 'y', 'e', 'da', 'di', 'do', 'van', 'von') THEN
        v_apellido := t; EXIT;
      END IF;
    END LOOP;
    IF v_apellido IS NULL THEN v_apellido := v_tokens[1]; END IF;      -- todas eran partículas: se usa la primera
  END IF;
  IF v_apellido IS NULL OR v_apellido = '' THEN v_apellido := 'usuario'; END IF;
  RETURN v_inicial || left(v_apellido, (public._reglas_registro() ->> 'username_apellido_max')::int);
END
$$;
COMMENT ON FUNCTION public._username_base(text, text) IS
  'E4. Base del username (regla B, independiente de la validación del nombre): inicial (primera letra a-z del nombre, o u) + primer apellido que no sea partícula (sin tildes, apóstrofos unidos, máx. 20; o usuario). Un nombre en otro alfabeto SE REGISTRA igual y usa el respaldo. STABLE porque unaccent() lo es.';

-- ----------------------------------------------------------------------------
-- Edad y hash
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._edad_en(p_nacimiento date, p_hoy date)
RETURNS integer LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p_nacimiento IS NULL OR p_hoy IS NULL THEN NULL ELSE date_part('year', age(p_hoy, p_nacimiento))::integer END
$$;
COMMENT ON FUNCTION public._edad_en(date, date) IS
  'E4. PURA. Años cumplidos de p_nacimiento a p_hoy (la fecha del reloj del banco, que pasa la función que llama; nunca la del sistema).';

CREATE OR REPLACE FUNCTION public._es_hash_bcrypt(p_hash text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT coalesce(p_hash ~ '^\$2[aby]\$(0[4-9]|[12][0-9]|3[01])\$[./A-Za-z0-9]{53}$', false)
$$;
COMMENT ON FUNCTION public._es_hash_bcrypt(text) IS
  'E4. PURA. TRUE solo si el texto tiene la forma exacta de un hash bcrypt ($2a$/$2b$/$2y$, coste 04-31, 53 caracteres del alfabeto bcrypt = 60 en total). La BD rechaza cualquier otra cosa: nunca guarda una clave en claro.';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- Permisos: utilidades internas, sin EXECUTE para nadie salvo el dueño
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname = ANY (ARRAY['_reglas_registro', '_msg_auth', '_nombre_valido', '_norm_texto', '_norm_digitos', '_norm_cedula', '_norm_telefono',
                                  '_username_base', '_edad_en', '_es_hash_bcrypt'])
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
  END LOOP;
END
$$;

COMMIT;
