-- 09_idempotencia.test.sql · Etapa 1 · cada script de db/sql se puede ejecutar de nuevo sin error y sin
-- cambiar NADA del catalogo (tablas, columnas, restricciones, indices, tipos, duenos, privilegios, roles,
-- comentarios). Este archivo usa \i (metacomando de psql): solo existe en el runner, no en db/sql.
-- El runner ya aplico 00..18 una vez (E1 = 00..05, E2 = 06..09, E3 = 10..12, E4 = 13..14, E5 = 15, E6 = 16, E7 = 17..18); aqui se toma la huella, se reaplican DOS veces mas
-- (hasta el 12 y, desde E6, tambien el 16, desde E7 el 17 y el 18, desde E8 el 19 y el 20 y desde E9 el 21 y el 22 desde E10 el 23 y desde E11 el 24 desde E12 el 25 y desde E13 el 26) y se compara. (Los scripts 13-15 se reaplican en las pruebas de su etapa y en el 'apply' x3 de la evidencia.)
-- Desde E2 la huella incluye funciones, triggers, event triggers, vistas y los privilegios por columna.

CREATE TABLE tests.huella (momento text PRIMARY KEY, huella text NOT NULL, filas text NOT NULL);
INSERT INTO tests.huella
  SELECT 'despues de la 1a aplicacion', tests.huella_catalogo(),
         (SELECT (SELECT count(*) FROM public.reloj) || '/' || (SELECT count(*) FROM public.parametro))::text;

SELECT assert_true('la huella del catalogo no es vacia', (SELECT length(huella) = 32 FROM tests.huella));

-- 2a aplicacion: los 6 scripts en orden (ON_ERROR_STOP del runner corta el archivo si alguno falla)
\i /work/sql/00_extensiones.sql
\i /work/sql/01_roles.sql
\i /work/sql/02_tipos_dominios.sql
\i /work/sql/03_schema.sql
\i /work/sql/04_indices.sql
\i /work/sql/05_permisos.sql
\i /work/sql/06_libro_mayor_estructura.sql
\i /work/sql/07_libro_mayor_funciones.sql
\i /work/sql/08_libro_mayor_triggers.sql
\i /work/sql/09_integridad.sql
\i /work/sql/10_reloj_estructura.sql
\i /work/sql/11_reloj_funciones.sql
\i /work/sql/12_reloj_triggers.sql
\i /work/sql/16_bolsillos.sql
\i /work/sql/17_motor_devengo.sql
\i /work/sql/18_cdt.sql
\i /work/sql/19_creditos_calculo.sql
\i /work/sql/20_creditos.sql
\i /work/sql/21_pagos_calculo.sql
\i /work/sql/22_pagos.sql
\i /work/sql/23_vistas.sql
\i /work/sql/24_admin.sql
\i /work/sql/25_control.sql
\i /work/sql/26_mantenimiento.sql

INSERT INTO tests.huella
  SELECT 'despues de la 2a aplicacion', tests.huella_catalogo(),
         (SELECT (SELECT count(*) FROM public.reloj) || '/' || (SELECT count(*) FROM public.parametro))::text;
SELECT assert_eq('2a aplicacion: el catalogo no cambia (misma huella)',
                 (SELECT huella FROM tests.huella WHERE momento = 'despues de la 2a aplicacion'),
                 (SELECT huella FROM tests.huella WHERE momento = 'despues de la 1a aplicacion'));

-- 3a aplicacion, por si acaso
\i /work/sql/00_extensiones.sql
\i /work/sql/01_roles.sql
\i /work/sql/02_tipos_dominios.sql
\i /work/sql/03_schema.sql
\i /work/sql/04_indices.sql
\i /work/sql/05_permisos.sql
\i /work/sql/06_libro_mayor_estructura.sql
\i /work/sql/07_libro_mayor_funciones.sql
\i /work/sql/08_libro_mayor_triggers.sql
\i /work/sql/09_integridad.sql
\i /work/sql/10_reloj_estructura.sql
\i /work/sql/11_reloj_funciones.sql
\i /work/sql/12_reloj_triggers.sql
\i /work/sql/16_bolsillos.sql
\i /work/sql/17_motor_devengo.sql
\i /work/sql/18_cdt.sql
\i /work/sql/19_creditos_calculo.sql
\i /work/sql/20_creditos.sql
\i /work/sql/21_pagos_calculo.sql
\i /work/sql/22_pagos.sql
\i /work/sql/23_vistas.sql
\i /work/sql/24_admin.sql
\i /work/sql/25_control.sql
\i /work/sql/26_mantenimiento.sql

INSERT INTO tests.huella
  SELECT 'despues de la 3a aplicacion', tests.huella_catalogo(),
         (SELECT (SELECT count(*) FROM public.reloj) || '/' || (SELECT count(*) FROM public.parametro))::text;
SELECT assert_eq('3a aplicacion: el catalogo sigue igual',
                 (SELECT huella FROM tests.huella WHERE momento = 'despues de la 3a aplicacion'),
                 (SELECT huella FROM tests.huella WHERE momento = 'despues de la 1a aplicacion'));
SELECT assert_eq('las filas unicas de reloj y parametro no se duplican',
                 (SELECT filas FROM tests.huella WHERE momento = 'despues de la 3a aplicacion'), '1/1'::text);

-- Los datos NO se pierden al reaplicar (CREATE TABLE IF NOT EXISTS no recrea nada)
BEGIN;
INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento)
  VALUES ('10000000-0000-4000-8000-000000000001','idem0001','h','N','A','111111111','idem@x.co','3111111111','1990-01-01');
COMMIT;
\i /work/sql/03_schema.sql
SELECT assert_eq('reaplicar 03_schema.sql conserva los datos existentes',
                 (SELECT count(*) FROM public.usuario WHERE username = 'idem0001'), 1::bigint);
SELECT assert_eq('...y reaplicar los permisos tampoco los toca',
                 (SELECT count(*) FROM public.usuario), 1::bigint);
\i /work/sql/05_permisos.sql
SELECT assert_eq('despues de reaplicar permisos el catalogo es identico (incluye las vistas de integridad y los permisos de banco_ledger)', tests.huella_catalogo(),
                 (SELECT huella FROM tests.huella WHERE momento = 'despues de la 1a aplicacion'));

-- Una desviacion se CORRIGE al reaplicar: se concede algo indebido a mano y 05_permisos.sql lo revoca
GRANT UPDATE ON public.cuenta TO banco_app;
SELECT assert_true('desviacion provocada: banco_app tiene UPDATE sobre cuenta', has_table_privilege('banco_app', 'public.cuenta', 'UPDATE'));
\i /work/sql/05_permisos.sql
SELECT assert_eq('05_permisos.sql corrige la desviacion (banco_app vuelve a no tener UPDATE)',
                 has_table_privilege('banco_app', 'public.cuenta', 'UPDATE'), false);
SELECT assert_eq('...y el catalogo vuelve a ser identico', tests.huella_catalogo(),
                 (SELECT huella FROM tests.huella WHERE momento = 'despues de la 1a aplicacion'));

DELETE FROM public.usuario WHERE username = 'idem0001';
