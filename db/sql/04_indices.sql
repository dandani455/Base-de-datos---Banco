-- ============================================================================
-- 04_indices.sql  ·  Etapa 1 (esquema y permisos)
-- Propósito  : índices no únicos. PostgreSQL crea solo los de PK y UNIQUE; aquí se agregan los
--              que sostienen (a) las claves foráneas (borrados en cascada y JOIN rápidos) y
--              (b) los accesos frecuentes del banco (historial, productos vigentes, cuotas pendientes).
--              El índice único parcial "un crédito vivo por producto" está en 03_schema.sql.
-- Diferido    : los índices GIN pg_trgm/unaccent de la búsqueda admin van en E11 (necesitan funciones).
-- Dependencias : 03_schema.sql.
-- Ejecución    : como superusuario (pgAdmin o "ctl apply"). IDEMPOTENTE (IF NOT EXISTS), transaccional.
-- Verificar    : SELECT schemaname, tablename, indexname, indexdef FROM pg_indexes
--                WHERE schemaname IN ('public','audit') ORDER BY tablename, indexname;
-- ============================================================================

BEGIN;
SET LOCAL ROLE banco_owner;

-- Libro mayor ---------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_transaccion_cuenta_orden ON public.transaccion (cuenta_id, orden DESC);   -- historial / "últimas N"
CREATE INDEX IF NOT EXISTS ix_transaccion_grupo        ON public.transaccion (grupo_id);                  -- recomponer una operación
CREATE INDEX IF NOT EXISTS ix_transaccion_bolsillo     ON public.transaccion (bolsillo_id) WHERE bolsillo_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_transaccion_cdt          ON public.transaccion (cdt_id)      WHERE cdt_id      IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_transaccion_credito      ON public.transaccion (credito_id)  WHERE credito_id  IS NOT NULL;

-- Productos de una cuenta (cubren también el borrado en cascada de cuenta -> producto) ----
CREATE INDEX IF NOT EXISTS ix_bolsillo_cuenta        ON public.bolsillo (cuenta_id);
CREATE INDEX IF NOT EXISTS ix_cdt_cuenta_estado      ON public.cdt (cuenta_id, estado);          -- CDT vigentes / historial
CREATE INDEX IF NOT EXISTS ix_credito_cuenta_estado  ON public.credito (cuenta_id, estado);      -- créditos vigentes / historial
CREATE INDEX IF NOT EXISTS ix_credito_producto       ON public.credito (producto_id);            -- FK (producto con créditos)
CREATE INDEX IF NOT EXISTS ix_cdt_definicion         ON public.cdt (definicion_id) WHERE definicion_id IS NOT NULL;   -- FK SET NULL

-- Cuotas pendientes: próxima cuota por pagar y mora -------------------------------
CREATE INDEX IF NOT EXISTS ix_cuota_pendiente        ON public.cuota (credito_id, numero) WHERE NOT pagada;

-- Referidos de un usuario (FK recursiva) --------------------------------------------
CREATE INDEX IF NOT EXISTS ix_usuario_referidor      ON public.usuario (referido_por) WHERE referido_por IS NOT NULL;

-- Auditoría ------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_evento_fecha           ON audit.evento (fecha DESC);
CREATE INDEX IF NOT EXISTS ix_evento_entidad         ON audit.evento (entidad, entidad_id);

COMMIT;
