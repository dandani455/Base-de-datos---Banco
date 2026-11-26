-- 01_entorno.test.sql · Etapa 0 · el entorno cumple lo que el diseño da por supuesto.
-- Corre en banco_test DESPUES de aplicar db/sql/00_extensiones.sql.

-- Version del servidor: PostgreSQL 16 (spec).
SELECT assert_true('PostgreSQL 16.x', current_setting('server_version_num')::int BETWEEN 160000 AND 169999);

-- Extensiones previstas para etapas posteriores.
SELECT assert_true('extension unaccent instalada', EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'unaccent'));
SELECT assert_true('extension pg_trgm instalada',  EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm'));
SELECT assert_eq('unaccent quita tildes (busqueda de usuarios)', unaccent('Rodríguez Peña')::text, 'Rodriguez Pena'::text);
SELECT assert_eq('pg_trgm: texto identico = similitud 1', similarity('banco', 'banco')::numeric, 1::numeric);

-- uuid: gen_random_uuid() es nativo desde PostgreSQL 13 (el spec exige UUID generados por la BD).
SELECT assert_eq('gen_random_uuid() genera 36 caracteres', length(gen_random_uuid()::text), 36);

-- Zona horaria del banco (D.8 / E.3-M11): Bogota, UTC-5 sin horario de verano.
SELECT assert_eq('TimeZone de la BD', current_setting('TimeZone'), 'America/Bogota');
SELECT assert_eq('offset de now() es -05:00', extract(timezone FROM now())::int, -18000);
SELECT assert_true('timestamptz se serializa a JSON con offset -05:00 (contrato: ISO 8601 con zona)',
                   to_jsonb(now())::text LIKE '%-05:00"');

-- "hoy" del banco no puede salir de current_date del servidor en UTC: a las 21:00 de Bogota
-- ya es el dia siguiente en UTC. Se demuestra con un instante fijo.
SELECT assert_eq('02:00 UTC del 21-nov es el 20-nov en Bogota',
                 ((TIMESTAMPTZ '2026-11-21 02:00:00+00') AT TIME ZONE 'America/Bogota')::date,
                 DATE '2026-11-20');
SELECT assert_eq('hoy en Bogota = current_date de una sesion Bogota',
                 (now() AT TIME ZONE 'America/Bogota')::date, current_date);

-- Transporte NUMERIC -> jsonb (D.8): el importe sale como NUMERO JSON con sus dos decimales,
-- nunca como string, y las fechas salen como texto ISO.
SELECT assert_eq('NUMERIC(18,2) a jsonb conserva los 2 decimales', to_jsonb(100::numeric(18,2))::text, '100.00'::text);
SELECT assert_eq('NUMERIC(18,2) en jsonb es de tipo number', jsonb_typeof(to_jsonb(1234.50::numeric(18,2))), 'number'::text);
SELECT assert_eq('date en jsonb es texto ISO', to_jsonb(DATE '2026-11-21')::text, '"2026-11-21"'::text);

-- Aislamiento: los helpers viven aqui (banco_test); el runner comprueba ademas que NO existen en "banco".
SELECT assert_true('esquema tests presente en banco_test', to_regnamespace('tests') IS NOT NULL);
SELECT assert_eq('la BD de pruebas es banco_test', current_database(), 'banco_test'::name);
