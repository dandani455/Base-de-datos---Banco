-- ============================================================================
-- 01_roles.sql  ·  Etapa 1 (esquema y permisos)
-- Propósito  : crear los roles del banco, sus límites de sesión y los privilegios a nivel de
--              base de datos. No crea tablas (eso es 03_schema.sql) ni concede permisos sobre
--              tablas (eso es 05_permisos.sql).
--
--   banco_owner   NOLOGIN  dueño de todos los objetos del banco (nadie inicia sesión con él)
--   banco_ledger  NOLOGIN  único autorizado a mover los acumuladores (se usa desde E2)
--   banco_app     LOGIN    el backend: solo ejecuta funciones y lee vistas
--   banco_lector  LOGIN    solo lectura (pgAdmin / profesor), sin password_hash
--   banco_dev     LOGIN    explorar y probar funciones desde el Query Tool sin ser superusuario
--
-- Dependencias : ninguna (los roles son del clúster; este script puede correr en cualquier BD).
-- Ejecución    : como superusuario (conexión "administración" de pgAdmin o "ctl apply").
--                IDEMPOTENTE: crea lo que falta y reaplica atributos, límites y membresías.
--                Todo va en una transacción: o se aplica completo o no se aplica nada.
-- OJO         : las contraseñas de abajo son de DESARROLLO LOCAL (no secretas; los puertos solo se
--                publican en 127.0.0.1). NO usarlas fuera de un entorno local. Cada reaplicación
--                del script las restablece a estos valores.
-- Verificar    : SELECT rolname, rolcanlogin, rolsuper, rolconfig FROM pg_roles WHERE rolname LIKE 'banco_%';
-- ============================================================================

BEGIN;

-- 1) Creación (solo si faltan) ------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'banco_owner') THEN
    CREATE ROLE banco_owner NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'banco_ledger') THEN
    CREATE ROLE banco_ledger NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'banco_app') THEN
    CREATE ROLE banco_app LOGIN PASSWORD 'banco_app_dev';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'banco_lector') THEN
    CREATE ROLE banco_lector LOGIN PASSWORD 'banco_lector_dev';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'banco_dev') THEN
    CREATE ROLE banco_dev LOGIN PASSWORD 'banco_dev_dev';
  END IF;
END
$$;

-- 2) Atributos (se reaplican siempre: ningún rol del banco es superusuario ni puede crear roles/BD)
ALTER ROLE banco_owner  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOLOGIN;
ALTER ROLE banco_ledger NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOLOGIN;
ALTER ROLE banco_app    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS LOGIN PASSWORD 'banco_app_dev';
ALTER ROLE banco_lector NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS LOGIN PASSWORD 'banco_lector_dev';
ALTER ROLE banco_dev    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS LOGIN PASSWORD 'banco_dev_dev';

-- 3) Límites de sesión (se aplican a las sesiones NUEVAS de cada rol) -------------
ALTER ROLE banco_app    SET statement_timeout = '5s';
ALTER ROLE banco_app    SET lock_timeout = '3s';
ALTER ROLE banco_app    SET idle_in_transaction_session_timeout = '15s';
ALTER ROLE banco_lector SET default_transaction_read_only = 'on';
ALTER ROLE banco_lector SET statement_timeout = '15s';
ALTER ROLE banco_dev    SET statement_timeout = '30s';

-- 4) Membresías: banco_dev hereda lectura (banco_lector) y ejecución de funciones (banco_app).
--    Si ya eran miembros, PostgreSQL solo emite un NOTICE.
GRANT banco_lector TO banco_dev;
GRANT banco_app    TO banco_dev;

-- 5) Privilegios sobre esta base de datos ------------------------------------------
--    Se quita todo a PUBLIC (CONNECT y TEMP) y se concede solo a quien corresponde.
DO $$
BEGIN
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO banco_app, banco_lector, banco_dev', current_database());
  EXECUTE format('GRANT CREATE  ON DATABASE %I TO banco_owner', current_database());   -- para crear el esquema audit
END
$$;

-- banco_owner necesita crear objetos en public (los scripts 02-04 los crean con SET ROLE banco_owner).
-- El resto de permisos sobre esquemas se fija en 05_permisos.sql.
GRANT USAGE, CREATE ON SCHEMA public TO banco_owner;

-- 6) Por defecto, las funciones que cree banco_owner NO son ejecutables por PUBLIC
--    (PostgreSQL deja toda función nueva ejecutable por todos salvo que se revoque así).
--    Cada función pública se concederá a banco_app una a una, en su etapa.
ALTER DEFAULT PRIVILEGES FOR ROLE banco_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

COMMIT;
