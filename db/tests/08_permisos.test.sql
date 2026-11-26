-- 08_permisos.test.sql · Etapa 1 · permisos por rol: pruebas POSITIVAS y NEGATIVAS, incluida la proteccion
-- de usuario.password_hash. Corre como superusuario en banco_test; cada intento real usa SET LOCAL ROLE.

-- ============================================================================
-- 1. password_hash: banco_lector lee las columnas permitidas pero NO password_hash
--    (permiso concedido COLUMNA A COLUMNA: no hay SELECT de tabla que revocar despues)
-- ============================================================================
SELECT assert_eq('banco_lector NO tiene SELECT a nivel de TABLA sobre usuario (solo por columna)',
                 has_table_privilege('banco_lector', 'public.usuario', 'SELECT'), false);
SELECT assert_eq('banco_lector NO tiene SELECT sobre password_hash',
                 has_column_privilege('banco_lector', 'public.usuario', 'password_hash', 'SELECT'), false);
SELECT assert_eq('banco_lector SI tiene SELECT sobre las otras 15 columnas de usuario',
                 (SELECT count(*) FROM pg_attribute a
                   WHERE a.attrelid = 'public.usuario'::regclass AND a.attnum > 0 AND NOT a.attisdropped
                     AND a.attname <> 'password_hash'
                     AND has_column_privilege('banco_lector', 'public.usuario', a.attname, 'SELECT')), 15::bigint);
SELECT assert_eq('usuario tiene 16 columnas (15 legibles + password_hash)',
                 (SELECT count(*) FROM pg_attribute WHERE attrelid = 'public.usuario'::regclass AND attnum > 0 AND NOT attisdropped), 16::bigint);
SELECT assert_eq('ninguna columna de usuario es legible por banco_lector salvo las 15 permitidas (lista exacta)',
                 (SELECT array_agg(a.attname::text ORDER BY a.attname) FROM pg_attribute a
                   WHERE a.attrelid = 'public.usuario'::regclass AND a.attnum > 0 AND NOT a.attisdropped
                     AND NOT has_column_privilege('banco_lector', 'public.usuario', a.attname, 'SELECT')),
                 ARRAY['password_hash']::text[]);
SELECT assert_eq('banco_lector no puede escribir ninguna columna de usuario',
                 has_any_column_privilege('banco_lector', 'public.usuario', 'INSERT,UPDATE'), false);

-- Intentos reales (con una fila de por medio, para que el permiso se evalue de verdad)
BEGIN;
INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento)
  VALUES ('jperez483', '$2b$10$secreto', 'Juan', 'Perez', '1020304050', 'juan@correo.co', '3001234567', '1990-05-01');

SELECT assert_ok('POSITIVA: banco_lector lee username, nombres, cedula y estado',
                 $$SET LOCAL ROLE banco_lector; SELECT username, nombres, cedula, estado, rol FROM public.usuario$$);
SELECT assert_ok('POSITIVA: banco_lector lee las 15 columnas permitidas de una vez',
                 $$SET LOCAL ROLE banco_lector; SELECT id, username, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol, estado,
                                                       correoverificado, codigo_referido, referido_por, bono_referido_pagado, creado_en FROM public.usuario$$);
SELECT assert_ok('POSITIVA: banco_lector puede contar usuarios y filtrar por columnas permitidas',
                 $$SET LOCAL ROLE banco_lector; SELECT count(*) FROM public.usuario WHERE estado = 'ACTIVO' AND rol = 'CLIENTE'$$);
SELECT assert_raises('NEGATIVA: banco_lector NO puede leer password_hash',
                     $$SET LOCAL ROLE banco_lector; SELECT password_hash FROM public.usuario$$, 'permission denied for table usuario', '42501');
SELECT assert_raises('NEGATIVA: banco_lector NO puede hacer SELECT * (incluye password_hash)',
                     $$SET LOCAL ROLE banco_lector; SELECT * FROM public.usuario$$, 'permission denied for table usuario', '42501');
SELECT assert_raises('NEGATIVA: banco_lector NO puede filtrar por password_hash (WHERE)',
                     $$SET LOCAL ROLE banco_lector; SELECT username FROM public.usuario WHERE password_hash LIKE '$2b$%'$$, 'permission denied for table usuario', '42501');
SELECT assert_raises('NEGATIVA: banco_lector NO puede ordenar por password_hash',
                     $$SET LOCAL ROLE banco_lector; SELECT username FROM public.usuario ORDER BY password_hash$$, 'permission denied for table usuario', '42501');
SELECT assert_raises('NEGATIVA: banco_lector NO puede obtener la fila completa con row(u.*) / to_jsonb(u)',
                     $$SET LOCAL ROLE banco_lector; SELECT to_jsonb(u) FROM public.usuario u$$, 'permission denied for table usuario', '42501');
SELECT assert_raises('NEGATIVA: banco_lector NO puede alcanzar password_hash por un JOIN ni una subconsulta',
                     $$SET LOCAL ROLE banco_lector; SELECT (SELECT u2.password_hash FROM public.usuario u2 WHERE u2.id = u.id) FROM public.usuario u$$,
                     'permission denied for table usuario', '42501');
SELECT assert_raises('NEGATIVA: banco_lector NO puede leer password_hash ni siquiera de su propia sesion (banco_dev hereda lo mismo)',
                     $$SET LOCAL ROLE banco_dev; SELECT password_hash FROM public.usuario$$, 'permission denied for table usuario', '42501');
SELECT assert_ok('POSITIVA: banco_dev (via banco_lector) lee las columnas permitidas', $$SET LOCAL ROLE banco_dev; SELECT username, estado FROM public.usuario$$);
SELECT assert_raises('NEGATIVA: banco_app no lee NI las columnas permitidas de usuario',
                     $$SET LOCAL ROLE banco_app; SELECT username FROM public.usuario$$, 'permission denied for table usuario', '42501');
SELECT assert_raises('NEGATIVA: banco_lector NO puede cambiar password_hash',
                     $$SET LOCAL ROLE banco_lector; UPDATE public.usuario SET password_hash = 'x'$$, 'permission denied for table usuario', '42501');
ROLLBACK;

-- ============================================================================
-- 2. Matriz de privilegios de tabla: ningun rol de acceso escribe; solo banco_lector lee
-- ============================================================================
CREATE TEMP TABLE t_tablas AS
  SELECT c.oid, n.nspname || '.' || c.relname AS nombre, n.nspname AS esquema, c.relname
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname IN ('public','audit') AND c.relkind = 'r';
CREATE TEMP TABLE t_privs (p text);
INSERT INTO t_privs VALUES ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER');

SELECT assert_eq('hay 12 tablas inspeccionadas (11 public + 1 audit)', (SELECT count(*) FROM t_tablas), 12::bigint);

SELECT assert_eq('banco_app: CERO privilegios de tabla en las 12 tablas',
                 (SELECT count(*) FROM t_tablas t, t_privs p WHERE has_table_privilege('banco_app', t.oid, p.p)), 0::bigint);
SELECT assert_eq('banco_app: ningun privilegio de columna en ninguna tabla (ni SELECT)',
                 (SELECT count(*) FROM t_tablas t WHERE has_any_column_privilege('banco_app', t.oid, 'SELECT,INSERT,UPDATE,REFERENCES')), 0::bigint);
SELECT assert_eq('banco_lector: solo SELECT, y solo en 11 tablas (todas menos usuario, que es por columna)',
                 (SELECT array_agg(t.nombre || ':' || p.p ORDER BY t.nombre) FROM t_tablas t, t_privs p
                   WHERE has_table_privilege('banco_lector', t.oid, p.p)),
                 ARRAY['audit.evento:SELECT','public.bolsillo:SELECT','public.cdt:SELECT','public.cdt_definicion:SELECT','public.credito:SELECT',
                       'public.credito_producto:SELECT','public.cuenta:SELECT','public.cuota:SELECT','public.parametro:SELECT','public.reloj:SELECT',
                       'public.transaccion:SELECT']::text[]);
SELECT assert_eq('banco_lector: ninguna columna escribible en ninguna tabla',
                 (SELECT count(*) FROM t_tablas t WHERE has_any_column_privilege('banco_lector', t.oid, 'INSERT,UPDATE,REFERENCES')), 0::bigint);
SELECT assert_eq('banco_dev: ningun privilegio propio de escritura (hereda solo lectura de banco_lector)',
                 (SELECT count(*) FROM t_tablas t, t_privs p WHERE p.p <> 'SELECT' AND has_table_privilege('banco_dev', t.oid, p.p)), 0::bigint);
SELECT assert_eq('banco_dev: lee lo mismo que banco_lector',
                 (SELECT count(*) FROM t_tablas t WHERE has_table_privilege('banco_dev', t.oid, 'SELECT') <> has_table_privilege('banco_lector', t.oid, 'SELECT')), 0::bigint);
-- E2: el dueno conserva todo EXCEPTO el UPDATE de tabla sobre las 4 tablas de acumuladores y UPDATE + TRUNCATE sobre transaccion
-- (los saldos y el libro solo los mueve banco_ledger / el trigger). El detalle esta en 11_libro_guardias.
SELECT assert_eq('banco_owner es dueno y tiene todo en las 12 tablas, salvo lo que E2 le quita a proposito',
                 (SELECT array_agg(t.relname || ':' || p.p ORDER BY t.relname, p.p) FROM t_tablas t, t_privs p WHERE NOT has_table_privilege('banco_owner', t.oid, p.p)),
                 ARRAY['bolsillo:UPDATE','cdt:UPDATE','credito:UPDATE','cuenta:UPDATE','reloj:UPDATE','transaccion:TRUNCATE','transaccion:UPDATE']::text[]);
SELECT assert_eq('PUBLIC no tiene NINGUN privilegio sobre ninguna tabla, esquema ni secuencia',
                 (SELECT count(*) FROM (
                    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a
                     WHERE n.nspname IN ('public','audit') AND a.grantee = 0
                    UNION ALL
                    SELECT 1 FROM pg_namespace n, aclexplode(n.nspacl) a WHERE n.nspname IN ('public','audit') AND a.grantee = 0
                  ) x), 0::bigint);

-- ============================================================================
-- 3. Esquemas
-- ============================================================================
SELECT assert_eq('esquema public: USAGE para app, lector, dev y ledger',
                 (SELECT array_agg(r ORDER BY r) FROM unnest(ARRAY['banco_app','banco_dev','banco_ledger','banco_lector']) r WHERE has_schema_privilege(r, 'public', 'USAGE')),
                 ARRAY['banco_app','banco_dev','banco_lector','banco_ledger']::text[]);
SELECT assert_eq('esquema public: solo banco_owner puede CREAR objetos',
                 (SELECT array_agg(r ORDER BY r) FROM unnest(ARRAY['banco_app','banco_dev','banco_ledger','banco_lector','banco_owner']) r WHERE has_schema_privilege(r, 'public', 'CREATE')),
                 ARRAY['banco_owner']::text[]);
SELECT assert_eq('esquema audit: USAGE solo para banco_lector y banco_dev (heredado); NADA para banco_app ni banco_ledger',
                 (SELECT array_agg(r ORDER BY r) FROM unnest(ARRAY['banco_app','banco_dev','banco_ledger','banco_lector']) r WHERE has_schema_privilege(r, 'audit', 'USAGE')),
                 ARRAY['banco_dev','banco_lector']::text[]);

-- ============================================================================
-- 4. Intentos reales por rol (negativos y positivos)
-- ============================================================================
SELECT assert_raises('banco_app NO puede leer cuenta', $$SET LOCAL ROLE banco_app; SELECT * FROM public.cuenta$$, 'permission denied for table cuenta', '42501');
SELECT assert_raises('banco_app NO puede insertar en cuenta', $$SET LOCAL ROLE banco_app; INSERT INTO public.cuenta (usuario_id, numero_cuenta) VALUES (gen_random_uuid(), '1234567890')$$, 'permission denied for table cuenta', '42501');
SELECT assert_raises('banco_app NO puede actualizar el balance', $$SET LOCAL ROLE banco_app; UPDATE public.cuenta SET balance = balance + 1$$, 'permission denied for table cuenta', '42501');
SELECT assert_raises('banco_app NO puede borrar usuarios', $$SET LOCAL ROLE banco_app; DELETE FROM public.usuario$$, 'permission denied for table usuario', '42501');
SELECT assert_raises('banco_app NO puede vaciar transaccion (TRUNCATE)', $$SET LOCAL ROLE banco_app; TRUNCATE public.transaccion$$, 'permission denied for table transaccion', '42501');
SELECT assert_raises('banco_app NO puede entrar al esquema audit', $$SET LOCAL ROLE banco_app; SELECT * FROM audit.evento$$, 'permission denied for schema audit', '42501');
SELECT assert_raises('banco_app NO puede crear tablas en public', $$SET LOCAL ROLE banco_app; CREATE TABLE public.intruso (x int)$$, 'permission denied for schema public', '42501');
SELECT assert_raises('banco_app NO puede crear tablas temporales', $$SET LOCAL ROLE banco_app; CREATE TEMP TABLE t_intruso (x int)$$, 'permission denied%', '42501');

SELECT assert_ok('banco_lector lee cuenta, transaccion, parametro y audit.evento',
                 $$SET LOCAL ROLE banco_lector; SELECT count(*) FROM public.cuenta; SELECT count(*) FROM public.transaccion; SELECT count(*) FROM public.parametro; SELECT count(*) FROM audit.evento$$);
SELECT assert_raises('banco_lector NO puede insertar', $$SET LOCAL ROLE banco_lector; INSERT INTO public.parametro (id) VALUES (2)$$, 'permission denied for table parametro', '42501');
SELECT assert_raises('banco_lector NO puede actualizar', $$SET LOCAL ROLE banco_lector; UPDATE public.reloj SET usar_fecha_real = true$$, 'permission denied for table reloj', '42501');
SELECT assert_raises('banco_lector NO puede borrar', $$SET LOCAL ROLE banco_lector; DELETE FROM public.bolsillo$$, 'permission denied for table bolsillo', '42501');
SELECT assert_raises('banco_lector NO puede vaciar tablas', $$SET LOCAL ROLE banco_lector; TRUNCATE public.cuenta$$, 'permission denied for table cuenta', '42501');
SELECT assert_raises('banco_lector NO puede escribir en la auditoria', $$SET LOCAL ROLE banco_lector; INSERT INTO audit.evento (accion) VALUES ('X')$$, 'permission denied for table evento', '42501');
SELECT assert_raises('banco_dev NO puede escribir (ni siquiera con banco_app heredado)', $$SET LOCAL ROLE banco_dev; UPDATE public.cuenta SET balance = 0$$, 'permission denied for table cuenta', '42501');

-- ============================================================================
-- 5. banco_ledger: unico con UPDATE, y solo de los 4 acumuladores
-- ============================================================================
SELECT assert_eq('banco_ledger puede actualizar EXACTAMENTE estas 4 columnas y ninguna otra',
                 (SELECT array_agg(t.relname || '.' || a.attname ORDER BY t.relname, a.attname)
                    FROM t_tablas t JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped
                   WHERE has_column_privilege('banco_ledger', t.oid, a.attnum, 'UPDATE')),
                 ARRAY['bolsillo.balance','cdt.generado_acumulado','credito.capital_pendiente','cuenta.balance']::text[]);
SELECT assert_eq('ningun otro rol de acceso puede actualizar esas columnas',
                 (SELECT count(*) FROM unnest(ARRAY['banco_app','banco_lector','banco_dev']) r, t_tablas t
                   WHERE has_any_column_privilege(r, t.oid, 'UPDATE')), 0::bigint);
SELECT assert_eq('banco_ledger no puede insertar, borrar ni vaciar nada',
                 (SELECT count(*) FROM t_tablas t, t_privs p WHERE p.p IN ('INSERT','DELETE','TRUNCATE') AND has_table_privilege('banco_ledger', t.oid, p.p)), 0::bigint);
-- E2 afina el SELECT de banco_ledger a lo MINIMO que usa su funcion: ningun privilegio de tabla, solo 11 columnas.
SELECT assert_eq('banco_ledger no tiene SELECT de TABLA sobre ninguna tabla (solo por columna)',
                 (SELECT count(*) FROM t_tablas t WHERE has_table_privilege('banco_ledger', t.oid, 'SELECT')), 0::bigint);
SELECT assert_eq('banco_ledger lee EXACTAMENTE id, el propietario y el acumulador de cuenta, bolsillo, cdt y credito',
                 (SELECT array_agg(t.relname || '.' || a.attname ORDER BY t.relname, a.attname)
                    FROM t_tablas t JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped
                   WHERE has_column_privilege('banco_ledger', t.oid, a.attnum, 'SELECT')),
                 ARRAY['bolsillo.balance','bolsillo.cuenta_id','bolsillo.id','cdt.cuenta_id','cdt.generado_acumulado','cdt.id',
                       'credito.capital_pendiente','credito.cuenta_id','credito.id','cuenta.balance','cuenta.id']::text[]);
SELECT assert_ok('banco_ledger SI puede actualizar cuenta.balance, bolsillo.balance, cdt.generado_acumulado y credito.capital_pendiente',
                 $$SET LOCAL ROLE banco_ledger; UPDATE public.cuenta SET balance = balance; UPDATE public.bolsillo SET balance = balance;
                   UPDATE public.cdt SET generado_acumulado = generado_acumulado; UPDATE public.credito SET capital_pendiente = capital_pendiente$$);
SELECT assert_raises('banco_ledger NO puede cambiar el numero de cuenta', $$SET LOCAL ROLE banco_ledger; UPDATE public.cuenta SET numero_cuenta = '0000000000'$$, 'permission denied for table cuenta', '42501');
SELECT assert_raises('banco_ledger NO puede cambiar el monto de un CDT (inmutable)', $$SET LOCAL ROLE banco_ledger; UPDATE public.cdt SET monto = 1$$, 'permission denied for table cdt', '42501');
SELECT assert_raises('banco_ledger NO puede cambiar el monto de un credito', $$SET LOCAL ROLE banco_ledger; UPDATE public.credito SET monto = 1$$, 'permission denied for table credito', '42501');
SELECT assert_raises('banco_ledger NO puede leer usuario', $$SET LOCAL ROLE banco_ledger; SELECT username FROM public.usuario$$, 'permission denied for table usuario', '42501');
SELECT assert_raises('banco_ledger NO puede insertar en el libro', $$SET LOCAL ROLE banco_ledger; INSERT INTO public.transaccion (grupo_id) VALUES (gen_random_uuid())$$, 'permission denied for table transaccion', '42501');

-- ============================================================================
-- 6. Los roles de acceso no son dueños de nada (no pueden alterar permisos ni estructura)
-- ============================================================================
SELECT assert_eq('ningun rol de acceso es dueno de tablas, esquemas ni tipos',
                 (SELECT count(*) FROM (
                    SELECT pg_get_userbyid(c.relowner) o FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname IN ('public','audit') AND c.relkind IN ('r','S','i')
                    UNION ALL SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'audit'
                    UNION ALL SELECT pg_get_userbyid(typowner) FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typtype IN ('d','e')
                  ) x WHERE o IN ('banco_app','banco_lector','banco_dev','banco_ledger')), 0::bigint);
SELECT assert_raises('banco_app NO puede darse permisos (GRANT)', $$SET LOCAL ROLE banco_app; GRANT SELECT ON public.cuenta TO banco_app$$, NULL, '42501');
SELECT assert_raises('banco_lector NO puede alterar la estructura', $$SET LOCAL ROLE banco_lector; ALTER TABLE public.cuenta ADD COLUMN x int$$, 'must be owner of table cuenta', '42501');
