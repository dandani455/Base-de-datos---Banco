-- ============================================================================
-- helpers.sql  ·  Utilidades de prueba (Etapa 0)
-- Se cargan SOLO en la base desechable "banco_test" (el runner lo hace); NUNCA en "banco".
-- Viven en el esquema "tests"; el runner pone search_path = public, tests en banco_test,
-- así que las pruebas las llaman sin prefijo:  SELECT assert_eq('etiqueta', a, b);
--
-- Convención del runner: cada aserción correcta emite   NOTICE: PASS: <etiqueta>
--                        cada aserción fallida lanza    EXCEPTION: FAIL: <detalle>
--                        (psql corre con ON_ERROR_STOP, así que la primera falla corta el archivo).
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS tests;
COMMENT ON SCHEMA tests IS 'Helpers de prueba. Existe solo en banco_test; nunca en la base banco.';

-- assert_eq: igualdad "NULL-safe". Con literales de texto usa cast: assert_eq('x', 'a'::text, 'a'::text).
CREATE OR REPLACE FUNCTION tests.assert_eq(p_label text, p_actual anyelement, p_expected anyelement)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_actual IS NOT DISTINCT FROM p_expected THEN
    RAISE NOTICE 'PASS: %', p_label;
  ELSE
    RAISE EXCEPTION 'FAIL: % (esperado=%, actual=%)', p_label, p_expected, p_actual;
  END IF;
END
$$;
COMMENT ON FUNCTION tests.assert_eq(text, anyelement, anyelement) IS
  'Pasa si actual IS NOT DISTINCT FROM esperado; si no, lanza FAIL con ambos valores.';

CREATE OR REPLACE FUNCTION tests.assert_true(p_label text, p_condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_condition IS TRUE THEN
    RAISE NOTICE 'PASS: %', p_label;
  ELSE
    RAISE EXCEPTION 'FAIL: % (la condicion no se cumplio: %)', p_label, p_condition;
  END IF;
END
$$;
COMMENT ON FUNCTION tests.assert_true(text, boolean) IS 'Pasa solo si la condicion es TRUE (NULL y FALSE fallan).';

-- assert_raises: ejecuta p_sql y exige que lance una excepcion.
--   p_expected_msg : si se da, el mensaje debe ser exactamente ese (o coincidir como LIKE si contiene %).
--   p_sqlstate     : si se da, el SQLSTATE debe coincidir (los errores de negocio del banco son P0001).
CREATE OR REPLACE FUNCTION tests.assert_raises(
  p_label text, p_sql text, p_expected_msg text DEFAULT NULL, p_sqlstate text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_state text;
  v_msg   text;
  v_ok    boolean;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF p_sqlstate IS NOT NULL AND v_state <> p_sqlstate THEN
      RAISE EXCEPTION 'FAIL: % (SQLSTATE esperado %, recibido % con mensaje: %)', p_label, p_sqlstate, v_state, v_msg;
    END IF;
    IF p_expected_msg IS NOT NULL THEN
      v_ok := CASE WHEN position('%' IN p_expected_msg) > 0
                   THEN v_msg LIKE p_expected_msg
                   ELSE v_msg = p_expected_msg END;
      IF NOT v_ok THEN
        RAISE EXCEPTION 'FAIL: % (mensaje esperado "%", recibido "%")', p_label, p_expected_msg, v_msg;
      END IF;
    END IF;
    RAISE NOTICE 'PASS: %', p_label;
    RETURN;
  END;
  RAISE EXCEPTION 'FAIL: % (se esperaba una excepcion y no ocurrio)', p_label;
END
$$;
COMMENT ON FUNCTION tests.assert_raises(text, text, text, text) IS
  'Pasa si p_sql lanza una excepcion (con el mensaje/SQLSTATE indicados, si se dan).';

-- assert_json_shape: verifica que un jsonb tenga las claves y tipos pedidos.
--   p_shape ejemplo: {"nombre":"string","saldo":"number","items":"array","nota":"string|null","x":"any"}
--   Tipos jsonb: object, array, string, number, boolean, null. Se admiten alternativas con "|".
--   Claves extra en p_json se aceptan (el contrato dice que agregar campos no rompe nada).
CREATE OR REPLACE FUNCTION tests.assert_json_shape(p_label text, p_json jsonb, p_shape jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_key    text;
  v_type   text;
  v_actual text;
BEGIN
  IF jsonb_typeof(p_json) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'FAIL: % (se esperaba un objeto jsonb, llego %)', p_label, coalesce(jsonb_typeof(p_json), 'NULL');
  END IF;
  FOR v_key, v_type IN SELECT key, value #>> '{}' FROM jsonb_each(p_shape) LOOP
    IF NOT (p_json ? v_key) THEN
      RAISE EXCEPTION 'FAIL: % (falta la clave "%")', p_label, v_key;
    END IF;
    v_actual := jsonb_typeof(p_json -> v_key);
    IF v_type <> 'any' AND NOT (v_actual = ANY (string_to_array(v_type, '|'))) THEN
      RAISE EXCEPTION 'FAIL: % (la clave "%" es % y se esperaba %)', p_label, v_key, v_actual, v_type;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: %', p_label;
END
$$;
COMMENT ON FUNCTION tests.assert_json_shape(text, jsonb, jsonb) IS
  'Pasa si el objeto jsonb tiene todas las claves de la forma con el tipo pedido (se aceptan claves extra).';

-- ----------------------------------------------------------------------------
-- Helpers agregados en la Etapa 1
-- ----------------------------------------------------------------------------

-- assert_ok: prueba POSITIVA. Ejecuta p_sql y exige que NO lance ninguna excepcion.
-- Restablece el rol al terminar (las pruebas de permisos usan SET LOCAL ROLE dentro de p_sql).
CREATE OR REPLACE FUNCTION tests.assert_ok(p_label text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_state text;
  v_msg   text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RAISE EXCEPTION 'FAIL: % (no debia fallar; SQLSTATE %: %)', p_label, v_state, v_msg;
  END;
  RESET ROLE;
  RAISE NOTICE 'PASS: %', p_label;
END
$$;
COMMENT ON FUNCTION tests.assert_ok(text, text) IS 'Pasa si p_sql se ejecuta sin excepcion (prueba positiva).';

-- assert_violates: prueba NEGATIVA de integridad. Exige una excepcion causada por la restriccion
-- p_constraint (nombre exacto de CHECK/UNIQUE/FK/dominio), y opcionalmente un SQLSTATE.
CREATE OR REPLACE FUNCTION tests.assert_violates(
  p_label text, p_sql text, p_constraint text, p_sqlstate text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_state text;
  v_msg   text;
  v_con   text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_con = CONSTRAINT_NAME;
    IF v_con IS DISTINCT FROM p_constraint THEN
      RAISE EXCEPTION 'FAIL: % (restriccion esperada "%", recibida "%"; SQLSTATE %: %)', p_label, p_constraint, v_con, v_state, v_msg;
    END IF;
    IF p_sqlstate IS NOT NULL AND v_state <> p_sqlstate THEN
      RAISE EXCEPTION 'FAIL: % (SQLSTATE esperado %, recibido %)', p_label, p_sqlstate, v_state;
    END IF;
    RAISE NOTICE 'PASS: %', p_label;
    RETURN;
  END;
  RESET ROLE;
  RAISE EXCEPTION 'FAIL: % (se esperaba violar "%" y la sentencia tuvo exito)', p_label, p_constraint;
END
$$;
COMMENT ON FUNCTION tests.assert_violates(text, text, text, text) IS
  'Pasa si p_sql falla por la restriccion nombrada (CONSTRAINT_NAME exacto), no por otra cosa.';

-- Normaliza una lista de privilegios (aclitem[]) para que el orden no cambie la huella.
CREATE OR REPLACE FUNCTION tests.acl_norm(p_acl aclitem[])
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce((SELECT string_agg(x::text, ',' ORDER BY x::text) FROM unnest(p_acl) AS x), '')
$$;

-- huella_catalogo: md5 de todo lo que define el esquema del banco (tablas, columnas, restricciones,
-- indices, tipos, duenos, privilegios, roles, comentarios). Si un script es idempotente, aplicarlo dos
-- veces deja la misma huella.
CREATE OR REPLACE FUNCTION tests.huella_catalogo()
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT md5(string_agg(linea, E'\n' ORDER BY linea)) FROM (
    SELECT 'rel|' || n.nspname || '.' || c.relname || '|' || c.relkind::text || '|' || pg_get_userbyid(c.relowner)
           || '|' || tests.acl_norm(c.relacl) AS linea
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname IN ('public', 'audit') AND c.relkind IN ('r', 'S', 'i')
    UNION ALL
    SELECT 'col|' || a.attrelid::regclass::text || '|' || a.attname || '|' || format_type(a.atttypid, a.atttypmod)
           || '|' || a.attnotnull::text || '|' || coalesce(pg_get_expr(d.adbin, d.adrelid), '') || '|' || a.attgenerated::text
           || '|' || a.attidentity::text || '|' || tests.acl_norm(a.attacl) || '|' || coalesce(col_description(a.attrelid, a.attnum), '')
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid AND c.relkind = 'r'
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname IN ('public', 'audit')
      LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
     WHERE a.attnum > 0 AND NOT a.attisdropped
    UNION ALL
    SELECT 'tbl|' || c.oid::regclass::text || '|' || coalesce(obj_description(c.oid, 'pg_class'), '')
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname IN ('public', 'audit') AND c.relkind = 'r'
    UNION ALL
    SELECT 'con|' || coalesce(c.conrelid::regclass::text, c.contypid::regtype::text) || '|' || c.conname || '|' || pg_get_constraintdef(c.oid)
      FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
     WHERE n.nspname IN ('public', 'audit')
    UNION ALL
    SELECT 'idx|' || indexdef FROM pg_indexes WHERE schemaname IN ('public', 'audit')
    UNION ALL
    SELECT 'typ|' || t.typname || '|' || t.typtype::text || '|' || pg_get_userbyid(t.typowner) || '|' || coalesce(obj_description(t.oid, 'pg_type'), '')
      FROM pg_type t WHERE t.typnamespace = 'public'::regnamespace AND t.typtype IN ('d', 'e')
    UNION ALL
    SELECT 'enum|' || t.typname || '|' || e.enumsortorder || '|' || e.enumlabel
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typnamespace = 'public'::regnamespace
    UNION ALL
    SELECT 'nsp|' || nspname || '|' || pg_get_userbyid(nspowner) || '|' || tests.acl_norm(nspacl) || '|' || coalesce(obj_description(oid, 'pg_namespace'), '')
      FROM pg_namespace WHERE nspname IN ('public', 'audit')
    UNION ALL
    SELECT 'rol|' || rolname || '|' || rolsuper::int::text || rolinherit::int::text || rolcreaterole::int::text || rolcreatedb::int::text || rolcanlogin::int::text || rolreplication::int::text || rolbypassrls::int::text
           || '|' || coalesce(rolconfig::text, '')
      FROM pg_roles WHERE rolname LIKE 'banco\_%'
    UNION ALL
    SELECT 'mem|' || r.rolname || '|' || m.rolname
      FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.roleid JOIN pg_roles m ON m.oid = am.member
     WHERE r.rolname LIKE 'banco\_%' OR m.rolname LIKE 'banco\_%'
    UNION ALL
    SELECT 'dacl|' || pg_get_userbyid(defaclrole) || '|' || defaclobjtype::text || '|' || tests.acl_norm(defaclacl) FROM pg_default_acl
    UNION ALL
    SELECT 'db|' || tests.acl_norm(datacl) FROM pg_database WHERE datname = current_database()
    -- Etapa 2: funciones, triggers, event triggers y vistas
    UNION ALL
    SELECT 'fn|' || p.oid::regprocedure::text || '|' || pg_get_userbyid(p.proowner) || '|' || p.prosecdef::text || '|'
           || tests.acl_norm(p.proacl) || '|' || md5(p.prosrc) || '|' || coalesce(array_to_string(p.proconfig, ','), '')
           || '|' || coalesce(obj_description(p.oid, 'pg_proc'), '')
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
    UNION ALL
    SELECT 'trg|' || t.tgrelid::regclass::text || '|' || t.tgname || '|' || t.tgenabled::text || '|' || pg_get_triggerdef(t.oid)
           || '|' || coalesce(obj_description(t.oid, 'pg_trigger'), '')
      FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE NOT t.tgisinternal AND n.nspname IN ('public', 'audit')
    UNION ALL
    SELECT 'evt|' || e.evtname || '|' || e.evtenabled::text || '|' || e.evtevent || '|' || e.evtfoid::regproc::text
           || '|' || coalesce(array_to_string(e.evttags, ','), '') || '|' || coalesce(obj_description(e.oid, 'pg_event_trigger'), '')
      FROM pg_event_trigger e
    UNION ALL
    SELECT 'view|' || c.oid::regclass::text || '|' || pg_get_userbyid(c.relowner) || '|' || tests.acl_norm(c.relacl)
           || '|' || md5(pg_get_viewdef(c.oid)) || '|' || coalesce(obj_description(c.oid, 'pg_class'), '')
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname IN ('public', 'audit') AND c.relkind = 'v'
  ) x
$$;
COMMENT ON FUNCTION tests.huella_catalogo() IS 'md5 de la definicion completa del esquema del banco (tablas, funciones, triggers, vistas, permisos); sirve para probar idempotencia.';

-- ----------------------------------------------------------------------------
-- Helpers agregados en la Etapa 2
-- ----------------------------------------------------------------------------

-- Desactiva SOLO los triggers de usuario (los del libro mayor, guardias, auditoria) de las 5 tablas del libro y
-- sus acumuladores, dentro de la transaccion actual. Las FK (triggers internos de PostgreSQL) SIGUEN ACTIVAS:
-- es mas estricto que session_replication_role = replica, que tambien apaga las FK. Sirve para ejercitar los CHECK de
-- FILA y las FK de E1 sin la logica de E2. Se deshace con el ROLLBACK final del archivo de pruebas.
CREATE OR REPLACE FUNCTION tests.sin_triggers_de_usuario()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  ALTER TABLE public.cuenta      DISABLE TRIGGER USER;
  ALTER TABLE public.bolsillo    DISABLE TRIGGER USER;
  ALTER TABLE public.cdt         DISABLE TRIGGER USER;
  ALTER TABLE public.credito     DISABLE TRIGGER USER;
  ALTER TABLE public.transaccion DISABLE TRIGGER USER;
  ALTER TABLE public.reloj       DISABLE TRIGGER USER;
END
$$;
COMMENT ON FUNCTION tests.sin_triggers_de_usuario() IS
  'Apaga solo los triggers de usuario de las tablas del libro y del reloj (no las FK) en la transaccion actual; para probar CHECK y FK de E1 sin la logica de E2.';

-- Etapa 3: captura el mensaje de error de una sentencia (NULL si no falla); sirve para comprobar el TEXTO de un error.
CREATE OR REPLACE FUNCTION tests.captura(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END $$;
COMMENT ON FUNCTION tests.captura(text) IS 'Ejecuta p_sql y devuelve el mensaje de la excepcion (NULL si no lanza ninguna).';
