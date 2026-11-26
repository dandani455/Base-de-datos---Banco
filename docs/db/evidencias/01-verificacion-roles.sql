-- Banco Digital - Etapa 1 - verificacion de permisos por rol (consultas de evidencia)
--
-- El MISMO script se ejecuta con cada uno de los cuatro roles (postgres, banco_dev, banco_app, banco_lector).
-- Se puede pegar por partes en el Query Tool de pgAdmin (cada bloque "-- [Tn]" es independiente) o correr
-- completo con psql. Todo lo que escribe va dentro de BEGIN ... ROLLBACK: NO deja cambios en la base.
-- BEGIN READ WRITE: banco_lector tiene default_transaction_read_only=on (primera capa); al forzar lectura-escritura
-- se prueba la segunda capa, la de PRIVILEGIOS (debe seguir fallando con 42501).
-- Para el rol postgres (superusuario) las escrituras "funcionan" y se deshacen con ROLLBACK; es esperado:
-- por eso el superusuario solo se usa para aplicar DDL.

\set VERBOSITY default
\echo
\echo ===== [T1] Quien soy =====
SELECT current_user AS rol,
       (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) AS superusuario,
       current_database() AS base_de_datos,
       current_setting('default_transaction_read_only') AS solo_lectura_por_defecto;

\echo
\echo ===== [T2] Privilegios sobre las 11 tablas de public (+ audit.evento) =====
SELECT priv AS privilegio,
       count(*) FILTER (WHERE has_table_privilege(current_user, t.oid, priv)) AS tablas_con_privilegio,
       count(*) AS tablas_totales
  FROM pg_class t
  JOIN pg_namespace n ON n.oid = t.relnamespace
 CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) AS priv
 WHERE t.relkind = 'r' AND (n.nspname = 'public' OR (n.nspname = 'audit' AND t.relname = 'evento'))
 GROUP BY priv
 ORDER BY array_position(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'], priv);

\echo
\echo ===== [T3] Lectura directa de una tabla de dinero: SELECT * FROM public.cuenta =====
SELECT * FROM public.cuenta;

\echo
\echo ===== [T4] Lectura de otra tabla: SELECT count(*) FROM public.transaccion =====
SELECT count(*) FROM public.transaccion;

\echo
\echo ===== [T5] password_hash directo: SELECT password_hash FROM public.usuario =====
SELECT password_hash FROM public.usuario;

\echo
\echo ===== [T6] SELECT * FROM public.usuario (incluye password_hash) =====
SELECT * FROM public.usuario;

\echo
\echo ===== [T7] Evasion: to_jsonb(u) sobre la fila completa =====
SELECT to_jsonb(u) FROM public.usuario u;

\echo
\echo ===== [T8] Columnas permitidas de usuario (todas menos password_hash) =====
SELECT id, username, nombres, apellidos, cedula, correo, telefono, rol, estado FROM public.usuario;

\echo
\echo ===== [T9] Por columna: que columnas de usuario puede leer este rol =====
SELECT a.attname AS columna,
       has_column_privilege(current_user, 'public.usuario'::regclass, a.attnum, 'SELECT') AS puede_leer
  FROM pg_attribute a
 WHERE a.attrelid = 'public.usuario'::regclass AND a.attnum > 0 AND NOT a.attisdropped
   AND a.attname IN ('username', 'password_hash', 'correo', 'cedula')
 ORDER BY a.attname;

\echo
\echo ===== [T10] Auditoria: SELECT count(*) FROM audit.evento =====
SELECT count(*) FROM audit.evento;

\echo
\echo ===== [T11] Escrituras directas (dentro de BEGIN ... ROLLBACK) =====
BEGIN READ WRITE;
\echo -- [T11a] UPDATE public.cuenta SET balance = balance + 1000000;
UPDATE public.cuenta SET balance = balance + 1000000;
ROLLBACK;
BEGIN READ WRITE;
\echo -- [T11b] INSERT INTO public.transaccion DEFAULT VALUES;
INSERT INTO public.transaccion DEFAULT VALUES;
ROLLBACK;
BEGIN READ WRITE;
\echo -- [T11c] DELETE FROM public.usuario;
DELETE FROM public.usuario;
ROLLBACK;
BEGIN READ WRITE;
\echo -- [T11d] TRUNCATE public.transaccion;
TRUNCATE public.transaccion;
ROLLBACK;
BEGIN READ WRITE;
\echo -- [T11e] UPDATE public.parametro SET tasa_mora_anual = 99;
UPDATE public.parametro SET tasa_mora_anual = 99;
ROLLBACK;
BEGIN READ WRITE;
\echo -- [T11f] CREATE TABLE public.intruso (i int);
CREATE TABLE public.intruso (i int);
ROLLBACK;

\echo
\echo ===== [T12] Matriz resumen (cada sentencia en su propio sub-bloque; SQLSTATE 42501 = permission denied) =====
BEGIN READ WRITE;
DO $$
DECLARE
  s text;
  sentencias text[] := ARRAY[
    'SELECT * FROM public.cuenta',
    'SELECT * FROM public.usuario',
    'SELECT password_hash FROM public.usuario',
    'SELECT username FROM public.usuario',
    'SELECT count(*) FROM audit.evento',
    'UPDATE public.cuenta SET balance = balance + 1000000',
    'INSERT INTO public.transaccion DEFAULT VALUES',
    'DELETE FROM public.usuario',
    'TRUNCATE public.transaccion',
    'UPDATE public.parametro SET tasa_mora_anual = 99',
    'CREATE TABLE public.intruso (i int)'
  ];
BEGIN
  FOREACH s IN ARRAY sentencias LOOP
    BEGIN
      EXECUTE s;
      RAISE NOTICE '% | %  ->  PERMITIDO', current_user, s;
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE NOTICE '% | %  ->  DENEGADO (SQLSTATE %: %)', current_user, s, SQLSTATE, SQLERRM;
    WHEN OTHERS THEN
      RAISE NOTICE '% | %  ->  OTRO ERROR (SQLSTATE %: %)', current_user, s, SQLSTATE, SQLERRM;
    END;
  END LOOP;
END
$$;
ROLLBACK;
