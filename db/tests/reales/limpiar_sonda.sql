-- limpiar_sonda.sql: elimina el rol-sonda ledger_probe (conexiones reales de la Etapa 2). IDEMPOTENTE.
-- ledger_probe es un rol GLOBAL del cluster que solo existe mientras corren las pruebas reales. El runner (ctl.ps1 /
-- ctl.sh) ejecuta este archivo al EMPEZAR y al TERMINAR (try/finally o trap) y los scripts 20_* lo ejecutan en su
-- propio trap: asi desaparece aunque una prueba falle o se interrumpa.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledger_probe') THEN
    PERFORM pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'ledger_probe';
    IF EXISTS (SELECT 1 FROM pg_database WHERE datname = 'banco_test') THEN
      EXECUTE 'REVOKE ALL ON DATABASE banco_test FROM ledger_probe';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_database WHERE datname = 'banco') THEN
      EXECUTE 'REVOKE ALL ON DATABASE banco FROM ledger_probe';
    END IF;
    DROP ROLE ledger_probe;
  END IF;
END
$$;
