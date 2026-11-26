-- ============================================================================
-- 25_control.sql  ·  Etapa 12 (Control: visor de la base de datos en vivo)
-- Propósito  : las dos funciones de la pestaña Control del front: el esquema (grafo de tablas y relaciones, que además es el «ping» de conexión) y las filas paginadas de una tabla.
--
--   Públicas (EXECUTE solo banco_app; banco_dev por herencia). p_admin_id es SIEMPRE el primer parámetro:
--     admin_esquema(admin)                          -> jsonb {tablas: [{nombre, columnas: [{nombre, tipo, llave, unico, no_nulo}], fks: [{columna, tabla_destino, columna_destino}]}]}
--     admin_tabla(admin, tabla text, pagina text)   -> jsonb {columnas: [..], filas: [{..}], pagina, total_paginas}      50 filas por página; password_hash siempre «••••»
--   Interna (sin EXECUTE para nadie salvo el dueño):
--     _reglas_control()                             lista blanca de las 11 tablas (y su orden), tamaño de página, orden de cada tabla, columnas enmascaradas y mensaje, en UN solo lugar
--
-- Reglas (diseño 12-control-diseno.md, D-E12-1 a D-E12-6):
--   * _validar_admin PRIMERO (Acceso denegado / mensaje de bloqueo; el estado se relee en cada ping).
--   * SOLO LECTURA garantizada por el catálogo: ambas son STABLE (PostgreSQL impide que una función STABLE escriba). No corren el motor de devengo (el visor muestra lo GUARDADO, no lo derivado)
--     y no auditan (no son una acción administrativa).
--   * Lista blanca EXPLÍCITA: el nombre de tabla se compara de forma exacta con la lista; el SQL dinámico usa el nombre TOMADO DE LA LISTA con %I, nunca el texto recibido. Fuera de ella: 'Tabla no permitida'.
--   * El hash NUNCA entra al JSON: la fila se arma como «fila menos las columnas enmascaradas» más «••••».
--   * p_pagina es TEXTO (D10): NULL, vacío, no numérico, con signo o decimales, o < 1 = 1; CUALQUIER entero positivo mayor que el total (de cualquier longitud: 1000000000, 30 cifras...) = la última página, sin desbordamiento
--     (la respuesta trae la página efectiva).
-- PROVISIONAL (equipo): D-E12-D1 (solo password_hash se enmascara) y D-E12-D2 (audit.evento fuera del visor): ambos son valores de _reglas_control().
-- Dependencias : 00 a 24.   Ejecución: como superusuario, IDEMPOTENTE, transaccional. NO modifica ningún objeto de E1-E11.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- _reglas_control: TODO lo provisional del visor en un solo lugar
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reglas_control()
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    -- las 11 tablas del contrato, en el orden del grafo; D-E12-D2 (PROVISIONAL): el esquema de auditoría no está en la lista
    'tablas',     jsonb_build_array('usuario', 'cuenta', 'bolsillo', 'cdt_definicion', 'cdt', 'credito_producto', 'credito', 'cuota', 'transaccion', 'reloj', 'parametro'),
    'pagina_tam', 50,                                              -- contrato §3.6: 50 filas por página
    -- D-E12-5: más reciente primero donde hay marca de tiempo u orden; desempate por id (alias de la tabla: t)
    'orden',      jsonb_build_object('usuario', 't.creado_en DESC, t.id', 'cuenta', 't.creado_en DESC, t.id', 'bolsillo', 't.creado_en DESC, t.id',
                                     'cdt_definicion', 't.nombre, t.id', 'cdt', 't.fecha_inicio DESC, t.id', 'credito_producto', 't.nombre, t.id',
                                     'credito', 't.fecha_desembolso DESC, t.id', 'cuota', 't.credito_id, t.numero', 'transaccion', 't.orden DESC',
                                     'reloj', 't.id', 'parametro', 't.id'),
    -- D-E12-D1 (PROVISIONAL, equipo): solo el hash; el contrato no nombra otras columnas
    'enmascarar', jsonb_build_object('usuario', jsonb_build_array('password_hash')),
    'mascara',    '••••',                                          -- contrato §3.6: el front lo pinta tal cual
    'msg_tabla',  'Tabla no permitida')                            -- contrato §6 (exacto)
$$;
COMMENT ON FUNCTION public._reglas_control() IS
  'E12. PURA. TODO lo provisional del visor Control en UN solo lugar: tablas (lista blanca de 11 y su orden en el grafo; D-E12-D2: sin audit.evento), pagina_tam 50, orden de cada tabla (más reciente primero; D-E12-5), enmascarar {usuario: [password_hash]} (D-E12-D1, solo el hash), mascara "••••" y msg_tabla "Tabla no permitida" (contrato §6). El mensaje vive aquí y no en _msg_negocio porque esa función es de E5 y E5 no se modifica.';

-- ----------------------------------------------------------------------------
-- admin_esquema: GET /admin/esquema (el grafo y el «ping» de conexión)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_esquema(p_admin_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp SET TimeZone = 'America/Bogota' AS $$
DECLARE
  r jsonb;
BEGIN
  PERFORM public._validar_admin(p_admin_id);                    -- ANTES de leer nada
  WITH wl AS (
    SELECT t.nombre, t.ord, c.oid AS rel
      FROM jsonb_array_elements_text(public._reglas_control() -> 'tablas') WITH ORDINALITY t(nombre, ord)
      JOIN pg_class c ON c.relname = t.nombre AND c.relnamespace = 'public'::regnamespace AND c.relkind = 'r')
  SELECT jsonb_build_object('tablas', coalesce(jsonb_agg(jsonb_build_object(
           'nombre',   wl.nombre,
           'columnas', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                  'nombre',  a.attname,
                                  'tipo',    format_type(a.atttypid, a.atttypmod),
                                  'llave',   EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = wl.rel AND k.contype = 'p' AND a.attnum = ANY (k.conkey)),
                                  'unico',   EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = wl.rel AND k.contype = 'u' AND k.conkey = ARRAY[a.attnum]),   -- UNIQUE de UNA columna
                                  'no_nulo', a.attnotnull) ORDER BY a.attnum), '[]'::jsonb)
                          FROM pg_attribute a WHERE a.attrelid = wl.rel AND a.attnum > 0 AND NOT a.attisdropped),
           -- una entrada por restriccion FK (la primera columna: la compuesta cuenta -> usuario sale una sola vez), solo entre tablas de la lista
           'fks',      (SELECT coalesce(jsonb_agg(jsonb_build_object('columna', ca.attname, 'tabla_destino', tr.relname, 'columna_destino', ra.attname) ORDER BY k.conname), '[]'::jsonb)
                          FROM pg_constraint k
                          JOIN pg_class tr ON tr.oid = k.confrelid
                          JOIN pg_attribute ca ON ca.attrelid = k.conrelid  AND ca.attnum = k.conkey[1]
                          JOIN pg_attribute ra ON ra.attrelid = k.confrelid AND ra.attnum = k.confkey[1]
                         WHERE k.conrelid = wl.rel AND k.contype = 'f' AND tr.relnamespace = 'public'::regnamespace AND tr.relname IN (SELECT w2.nombre FROM wl w2))
         ) ORDER BY wl.ord), '[]'::jsonb))
    INTO r
    FROM wl;
  RETURN r;
END
$$;
COMMENT ON FUNCTION public.admin_esquema(uuid) IS
  'E12. GET /admin/esquema. {tablas: [{nombre, columnas: [{nombre, tipo (format_type literal), llave (clave primaria), unico (UNIQUE de UNA columna), no_nulo}], fks: [{columna, tabla_destino, columna_destino}]}]} de las 11 tablas de la lista blanca (_reglas_control) en su orden, sacado de pg_catalog. Una FK por restricción (la compuesta de cuenta sale una vez, con su primera columna). Es también el ping de conexión del front (cada 5 s): STABLE, sin motor de devengo, sin escribir ni auditar. Validación de admin primero.';

-- ----------------------------------------------------------------------------
-- admin_tabla: GET /admin/tabla/:nombre?pagina=N
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_tabla(p_admin_id uuid, p_tabla text, p_pagina text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp SET TimeZone = 'America/Bogota' AS $$
DECLARE
  rg        jsonb;
  v_tabla   text;
  v_tam     integer;
  v_total   bigint;
  v_paginas integer;
  v_pag     integer;
  v_cols    jsonb;
  v_menos   text[];
  v_mascara jsonb;
  v_filas   jsonb;
  v_txt     text;
BEGIN
  PERFORM public._validar_admin(p_admin_id);                    -- ANTES de leer nada
  rg := public._reglas_control();
  -- lista blanca: comparacion EXACTA; v_tabla sale de la LISTA (nunca del texto recibido) y es lo unico que llega al SQL dinamico
  SELECT t.nombre INTO v_tabla FROM jsonb_array_elements_text(rg -> 'tablas') t(nombre) WHERE t.nombre = p_tabla;
  IF v_tabla IS NULL OR to_regclass(format('public.%I', v_tabla)) IS NULL THEN
    RAISE EXCEPTION '%', (rg ->> 'msg_tabla') USING ERRCODE = 'P0001';
  END IF;
  v_tam := (rg ->> 'pagina_tam')::integer;
  SELECT jsonb_agg(a.attname ORDER BY a.attnum) INTO v_cols
    FROM pg_attribute a WHERE a.attrelid = to_regclass(format('public.%I', v_tabla)) AND a.attnum > 0 AND NOT a.attisdropped;
  -- columnas enmascaradas: salen de la fila y vuelven con la mascara (el valor real nunca llega al JSON de salida)
  SELECT coalesce(array_agg(c.col), ARRAY[]::text[]), coalesce(jsonb_object_agg(c.col, rg ->> 'mascara'), '{}'::jsonb)
    INTO v_menos, v_mascara
    FROM jsonb_array_elements_text(rg -> 'enmascarar' -> v_tabla) c(col);
  -- pagina: texto no numerico o < 1 = 1; mayor que el total = la ultima
  EXECUTE format('SELECT count(*) FROM public.%I', v_tabla) INTO v_total;
  v_paginas := greatest(1, ceil(v_total::numeric / v_tam)::integer);
  -- solo digitos (cualquier longitud): sin ceros a la izquierda, mas de 18 cifras NUNCA caben en un bigint = mas que cualquier total = la ultima (sin convertir: no hay desbordamiento posible)
  v_txt := ltrim(btrim(coalesce(p_pagina, '')), '0');
  v_pag := CASE WHEN btrim(coalesce(p_pagina, '')) !~ '^[0-9]+$' THEN 1
                WHEN v_txt = '' THEN 1
                WHEN length(v_txt) > 18 THEN v_paginas
                ELSE greatest(1, least(v_txt::bigint, v_paginas::bigint))::integer END;
  EXECUTE format('SELECT coalesce(jsonb_agg(f.j ORDER BY f.rn), ''[]''::jsonb)
                    FROM (SELECT ((to_jsonb(t) - %L::text[]) || %L::jsonb) AS j, row_number() OVER (ORDER BY %s) AS rn
                            FROM public.%I t ORDER BY rn LIMIT %s OFFSET %s) f',
                 v_menos, v_mascara, rg -> 'orden' ->> v_tabla, v_tabla, v_tam, (v_pag - 1) * v_tam)
    INTO v_filas;
  RETURN jsonb_build_object('columnas', v_cols, 'filas', v_filas, 'pagina', v_pag, 'total_paginas', v_paginas);
END
$$;
COMMENT ON FUNCTION public.admin_tabla(uuid, text, text) IS
  'E12. GET /admin/tabla/:nombre?pagina=N. {columnas, filas, pagina, total_paginas}: las filas REALES de una de las 11 tablas de la lista blanca, 50 por página, en el orden de _reglas_control (más reciente primero). Fuera de la lista (comparación exacta; incluye audit.evento, otros esquemas, NULL y texto con comillas) = "Tabla no permitida". usuario.password_hash sale SIEMPRE como "••••": el hash real nunca entra al JSON. p_pagina es TEXTO (D10): NULL, vacío, no numérico (con signo, decimales o texto) o < 1 = 1; cualquier entero positivo mayor que el total, de cualquier longitud (también más de 9 o 18 cifras), = la última (la respuesta trae la página efectiva), sin desbordamiento; total_paginas = max(1, ceil(filas / 50)). STABLE: solo lectura por catálogo; sin motor de devengo ni auditoría (muestra lo guardado, no lo derivado). Una sola foto para filas y conteo. Validación de admin primero.';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- Permisos: las 2 públicas -> banco_app (banco_dev las hereda); el helper -> nadie salvo el dueño
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma, p.proname FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('admin_esquema', 'admin_tabla', '_reglas_control')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
    IF f.proname LIKE 'admin\_%' THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO banco_app', f.firma);
    END IF;
  END LOOP;
END
$$;

COMMIT;
