-- ============================================================================
-- 05_permisos.sql  ·  Etapa 1 (esquema y permisos)
-- Propósito  : concede (y revoca) permisos sobre esquemas y tablas. El script CONVERGE al estado
--              descrito aquí: primero quita todo a los roles de acceso y luego concede lo debido,
--              así reaplicarlo corrige cualquier desvío.
--
--   banco_app     ningún permiso sobre tablas ni sobre audit (solo ejecutará funciones y leerá vistas, E3+)
--   banco_lector  SELECT de lectura; sobre usuario SOLO por columna, SIN password_hash
--   banco_dev     hereda de banco_lector y banco_app (sin permisos propios)
--   banco_ledger  SELECT (mínimo, por columna) + UPDATE por columna solo de los acumuladores (se usa desde E2)
--
-- IMPORTANTE (privilegios acumulativos): a banco_lector NO se le concede SELECT sobre toda la tabla
--   usuario para después revocar una columna: el privilegio de tabla incluye todas las columnas y
--   REVOKE de una columna no lo anula. Se concede columna por columna, sin password_hash. Si una etapa
--   futura agrega columnas a usuario, hay que agregarlas aquí si deben ser legibles.
-- Dependencias : 01_roles.sql, 03_schema.sql.
-- Ejecución    : como superusuario (pgAdmin o "ctl apply"). IDEMPOTENTE, transaccional.
-- Verificar    : SELECT grantee, table_name, privilege_type FROM information_schema.table_privileges
--                WHERE table_schema IN ('public','audit') AND grantee LIKE 'banco_%' ORDER BY 2, 1, 3;
--                SELECT grantee, column_name, privilege_type FROM information_schema.column_privileges
--                WHERE table_name = 'usuario' AND grantee LIKE 'banco_%' ORDER BY 1, 2;
-- ============================================================================

BEGIN;

-- 1) Esquemas ----------------------------------------------------------------------
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM banco_app, banco_lector, banco_dev, banco_ledger;
GRANT USAGE ON SCHEMA public TO banco_app, banco_lector, banco_dev, banco_ledger;
GRANT USAGE, CREATE ON SCHEMA public TO banco_owner;

REVOKE ALL ON SCHEMA audit FROM PUBLIC;
REVOKE ALL ON SCHEMA audit FROM banco_app, banco_lector, banco_dev, banco_ledger;
GRANT USAGE ON SCHEMA audit TO banco_lector;               -- banco_dev lo hereda de banco_lector

-- 2) Tablas: se parte de cero para los roles de acceso -------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, banco_app, banco_lector, banco_dev, banco_ledger;
REVOKE ALL ON ALL TABLES IN SCHEMA audit  FROM PUBLIC, banco_app, banco_lector, banco_dev, banco_ledger;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, banco_app, banco_lector, banco_dev, banco_ledger;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA audit  FROM PUBLIC, banco_app, banco_lector, banco_dev, banco_ledger;

-- 3) banco_lector: lectura. usuario SOLO por columna, SIN password_hash ----------------
GRANT SELECT (id, username, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol, estado,
              correoverificado, codigo_referido, referido_por, bono_referido_pagado, creado_en)
  ON public.usuario TO banco_lector;
GRANT SELECT ON public.cuenta, public.bolsillo, public.cdt_definicion, public.cdt,
                public.credito_producto, public.credito, public.cuota, public.transaccion,
                public.reloj, public.parametro TO banco_lector;
GRANT SELECT ON audit.evento TO banco_lector;

-- 4) banco_ledger: solo los acumuladores. E2 afina el SELECT a lo MINIMO que usa su unica funcion
--    (trg_transaccion_b_aplicar): id y propietario (cuenta_id) para bloquear y validar el contenedor, y el
--    acumulador. Nada de tablas completas: no lee numero_cuenta, monto, tasa, nombre, estado, etc.
GRANT SELECT (id, balance)                        ON public.cuenta   TO banco_ledger;
GRANT SELECT (id, cuenta_id, balance)             ON public.bolsillo TO banco_ledger;
GRANT SELECT (id, cuenta_id, generado_acumulado)  ON public.cdt      TO banco_ledger;
GRANT SELECT (id, cuenta_id, capital_pendiente)   ON public.credito  TO banco_ledger;
GRANT UPDATE (balance)            ON public.cuenta   TO banco_ledger;
GRANT UPDATE (balance)            ON public.bolsillo TO banco_ledger;
GRANT UPDATE (generado_acumulado) ON public.cdt      TO banco_ledger;
GRANT UPDATE (capital_pendiente)  ON public.credito  TO banco_ledger;

-- 5) E2/E3: las vistas v_integridad_* (09_integridad.sql) , v_reloj_estado (12_reloj_triggers.sql) y v_transaccion_usuario (23_vistas.sql, E10) son de lectura para banco_lector. El REVOKE de arriba cubre
--    "todas las tablas" (incluye vistas); este bloque las vuelve a conceder SI existen, para que reaplicar este
--    script solo no las deje sin permiso. (En la 1a aplicacion aun no existen; 09_integridad.sql las concede.)
DO $$
DECLARE v record;
BEGIN
  FOR v IN SELECT c.oid::regclass AS nombre FROM pg_class c
            WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'v' AND (c.relname LIKE 'v\_integridad\_%' OR c.relname LIKE 'v\_reloj\_%' OR c.relname = 'v_transaccion_usuario')
  LOOP
    EXECUTE format('GRANT SELECT ON %s TO banco_lector', v.nombre);
  END LOOP;
END
$$;

-- banco_app y banco_dev: sin permisos propios sobre tablas. (banco_dev recibe lectura de banco_lector
-- y la ejecución de funciones de banco_app por herencia; nunca escritura.)

COMMIT;
