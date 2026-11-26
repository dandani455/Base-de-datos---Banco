-- 02_roles.test.sql · Etapa 1 · roles, atributos, membresias, limites y privilegios de base de datos.
-- Corre como superusuario en banco_test despues de aplicar db/sql/01..05.

-- Existencia y atributos -------------------------------------------------------------------------------
SELECT assert_eq('los 5 roles del banco existen',
                 (SELECT array_agg(rolname::text ORDER BY rolname) FROM pg_roles WHERE rolname LIKE 'banco\_%'),
                 ARRAY['banco_app','banco_dev','banco_lector','banco_ledger','banco_owner']::text[]);

SELECT assert_eq('banco_owner no inicia sesion',  (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'banco_owner'),  false);
SELECT assert_eq('banco_ledger no inicia sesion', (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'banco_ledger'), false);
SELECT assert_eq('banco_app inicia sesion',       (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'banco_app'),    true);
SELECT assert_eq('banco_lector inicia sesion',    (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'banco_lector'), true);
SELECT assert_eq('banco_dev inicia sesion',       (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'banco_dev'),    true);

SELECT assert_eq('ningun rol del banco es superusuario ni puede crear roles/BD ni saltarse RLS ni replicar',
                 (SELECT count(*) FROM pg_roles WHERE rolname LIKE 'banco\_%'
                     AND (rolsuper OR rolcreaterole OR rolcreatedb OR rolbypassrls OR rolreplication)), 0::bigint);

SELECT assert_true('los roles con login tienen contrasena SCRAM (no vacia)',
                   (SELECT bool_and(rolpassword LIKE 'SCRAM-SHA-256$%')
                      FROM pg_authid WHERE rolname IN ('banco_app', 'banco_lector', 'banco_dev')));
SELECT assert_true('los roles sin login no tienen contrasena',
                   (SELECT bool_and(rolpassword IS NULL) FROM pg_authid WHERE rolname IN ('banco_owner', 'banco_ledger')));

-- Limites de sesion ------------------------------------------------------------------------------------
SELECT assert_eq('banco_app: statement_timeout, lock_timeout e idle_in_transaction',
                 (SELECT array_agg(c ORDER BY c) FROM pg_roles r, unnest(r.rolconfig) c WHERE r.rolname = 'banco_app'),
                 ARRAY['idle_in_transaction_session_timeout=15s','lock_timeout=3s','statement_timeout=5s']::text[]);
SELECT assert_eq('banco_lector: solo lectura por defecto y statement_timeout',
                 (SELECT array_agg(c ORDER BY c) FROM pg_roles r, unnest(r.rolconfig) c WHERE r.rolname = 'banco_lector'),
                 ARRAY['default_transaction_read_only=on','statement_timeout=15s']::text[]);
SELECT assert_eq('banco_dev: statement_timeout 30s',
                 (SELECT array_agg(c ORDER BY c) FROM pg_roles r, unnest(r.rolconfig) c WHERE r.rolname = 'banco_dev'),
                 ARRAY['statement_timeout=30s']::text[]);

-- Membresias -------------------------------------------------------------------------------------------
SELECT assert_eq('banco_dev es miembro de banco_lector y banco_app (y de nadie mas)',
                 (SELECT array_agg(r.rolname::text ORDER BY r.rolname)
                    FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.roleid JOIN pg_roles m ON m.oid = am.member
                   WHERE m.rolname = 'banco_dev'),
                 ARRAY['banco_app','banco_lector']::text[]);
SELECT assert_eq('nadie mas es miembro de un rol del banco',
                 (SELECT count(*) FROM pg_auth_members am JOIN pg_roles m ON m.oid = am.member
                   WHERE m.rolname LIKE 'banco\_%' AND m.rolname <> 'banco_dev'), 0::bigint);
SELECT assert_true('banco_app NO hereda de banco_owner (no puede ser dueno)',
                   NOT pg_has_role('banco_app', 'banco_owner', 'USAGE'));
SELECT assert_true('banco_lector NO hereda de banco_app',
                   NOT pg_has_role('banco_lector', 'banco_app', 'USAGE'));

-- Privilegios sobre la base de datos -------------------------------------------------------------------
SELECT assert_true('CONNECT: banco_app, banco_lector y banco_dev si',
                   has_database_privilege('banco_app', current_database(), 'CONNECT')
                   AND has_database_privilege('banco_lector', current_database(), 'CONNECT')
                   AND has_database_privilege('banco_dev', current_database(), 'CONNECT'));
SELECT assert_true('CONNECT: banco_ledger y banco_owner no (nadie inicia sesion con ellos)',
                   NOT has_database_privilege('banco_ledger', current_database(), 'CONNECT')
                   AND NOT has_database_privilege('banco_owner', current_database(), 'CONNECT'));
SELECT assert_eq('PUBLIC no tiene ningun privilegio sobre la base de datos',
                 (SELECT count(*) FROM pg_database d, aclexplode(d.datacl) a
                   WHERE d.datname = current_database() AND a.grantee = 0), 0::bigint);
SELECT assert_true('solo banco_owner puede crear esquemas en la base de datos',
                   has_database_privilege('banco_owner', current_database(), 'CREATE')
                   AND NOT has_database_privilege('banco_app', current_database(), 'CREATE')
                   AND NOT has_database_privilege('banco_lector', current_database(), 'CREATE')
                   AND NOT has_database_privilege('banco_dev', current_database(), 'CREATE'));
SELECT assert_true('nadie (salvo superusuario) puede crear tablas temporales',
                   NOT has_database_privilege('banco_app', current_database(), 'TEMPORARY')
                   AND NOT has_database_privilege('banco_lector', current_database(), 'TEMPORARY'));

-- Funciones: por defecto NO ejecutables por PUBLIC -------------------------------------------------------
SELECT assert_eq('existe un privilegio por defecto de funciones de banco_owner sin PUBLIC',
                 (SELECT count(*) FROM pg_default_acl d
                   WHERE d.defaclrole = 'banco_owner'::regrole AND d.defaclobjtype = 'f'
                     AND NOT EXISTS (SELECT 1 FROM aclexplode(d.defaclacl) a WHERE a.grantee = 0)), 1::bigint);

BEGIN;
SET LOCAL ROLE banco_owner;
CREATE FUNCTION public.t_funcion_prueba() RETURNS int LANGUAGE sql AS 'SELECT 1';
RESET ROLE;
SELECT assert_true('una funcion nueva de banco_owner NO es ejecutable por banco_app, banco_lector ni banco_dev',
                   NOT has_function_privilege('banco_app',    'public.t_funcion_prueba()', 'EXECUTE')
                   AND NOT has_function_privilege('banco_lector', 'public.t_funcion_prueba()', 'EXECUTE')
                   AND NOT has_function_privilege('banco_dev',    'public.t_funcion_prueba()', 'EXECUTE'));
SELECT assert_true('...y si por banco_owner',
                   has_function_privilege('banco_owner', 'public.t_funcion_prueba()', 'EXECUTE'));
SELECT assert_eq('...y PUBLIC no figura en su lista de privilegios',
                 (SELECT count(*) FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                   WHERE p.proname = 't_funcion_prueba' AND a.grantee = 0), 0::bigint);
ROLLBACK;
