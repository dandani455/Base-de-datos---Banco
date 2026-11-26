-- ============================================================================
-- 00_extensiones.sql  ·  Etapa 0 (entorno)
-- Propósito : habilitar las extensiones que usarán etapas posteriores y fijar la zona horaria
--             de la base de datos a la del banco (America/Bogota).
--               - unaccent : búsqueda de usuarios sin distinguir tildes (admin_listar_usuarios, E11)
--               - pg_trgm  : índices GIN para ILIKE '%texto%' (E1/E11)
-- Dependencias : ninguna.
-- Ejecución  : desde pgAdmin (Query Tool > Open File > F5) o con "db\ctl.ps1 apply 00".
--              Es IDEMPOTENTE (se puede ejecutar cuantas veces se quiera) y no usa
--              metacomandos de psql, así que corre igual en pgAdmin.
-- Verificar  : SELECT extname, extversion FROM pg_extension WHERE extname IN ('unaccent','pg_trgm');
--              SHOW timezone;   -- (en una conexión NUEVA) America/Bogota
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Zona horaria por BD: el contenedor corre en UTC; sin esto "hoy" cambiaría a las 7 p. m. de Bogotá.
-- Afecta a las conexiones NUEVAS a esta base de datos (la sesión actual conserva la suya).
DO $$
BEGIN
  EXECUTE format('ALTER DATABASE %I SET timezone TO %L', current_database(), 'America/Bogota');
END
$$;
