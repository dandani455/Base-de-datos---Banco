-- ============================================================================
-- 26_mantenimiento.sql  ·  Etapa 13 (mantenimiento: cierre de todas las cuentas e informe de integridad)
-- Propósito  : los dos PROCEDIMIENTOS de la hoja de ruta (se ejecutan con CALL) y su interna.
--
--   Procedimientos (EXECUTE para NADIE salvo el dueño/superusuario: no los usa el backend ni ningún rol de acceso):
--     sp_avanzar_todos(INOUT resultado jsonb)        pone al dia TODAS las cuentas, UNA transaccion (y una instantanea del reloj) por cuenta
--     sp_verificar_integridad(INOUT resultado jsonb) informe de TODOS los controles v_integridad_*, en UNA sola sentencia (una sola foto); solo lectura
--   Interna (sin EXECUTE para nadie salvo el dueño):
--     _reglas_mantenimiento()                        lock_timeout, tope de errores y de filas de muestra, en UN solo lugar
--
-- Reglas (diseño 13-mantenimiento-diseno.md, D-E13-1 a D-E13-6 y los 2 ajustes de la aprobacion):
--   * Un procedimiento que hace COMMIT NO puede tener cláusula SET ni SECURITY DEFINER (verificado en PostgreSQL 16): son SECURITY INVOKER y sin SET. EXCEPCION DOCUMENTADA a «todo
--     SECURITY DEFINER con search_path fijo». Compensacion: nadie salvo dueño/superusuario puede ejecutarlos y el search_path se fija por set_config(..., true) AL INICIO DE CADA TRANSACCION.
--   * CADA COMMIT descarta lo configurado con set_config(..., true): por eso el search_path (y el lock_timeout) se vuelven a fijar (1) en la transaccion de captura de cuentas, (2) al empezar
--     CADA cuenta y (3) en la transaccion final de auditoria. Todo objeto se nombra ademas con su esquema (public. / pg_catalog.) por si algo corriera antes de fijarlo.
--   * sp_avanzar_todos: captura los ids de las cuentas (orden de id) y COMMIT; por cada cuenta: set_config -> UNA _reloj_instantanea() -> _avanzar_hasta (devenga, cobra y cierra; sale rapido si
--     no hay nada) dentro de un bloque EXCEPTION -> COMMIT. Un 55P03 (lock_not_available) = OMITIDA POR TIMEOUT DE BLOQUEO: puede ser la cuenta (el cliente opera) o el reloj (el admin lo cambia);
--     NO se asume cual. Cualquier otro error = con_error: solo esa cuenta se revierte y la corrida sigue. Al final UN evento MANTENIMIENTO_AVANZAR y un NOTICE. Idempotente.
--   * NO se puede llamar dentro de una transaccion (BEGIN ... CALL, scripts de varias sentencias, modo transaccion de pgAdmin): falla con 2D000 «invalid transaction termination».
-- Dependencias : 00 a 25.   Ejecución: como superusuario, IDEMPOTENTE, transaccional. NO modifica ningún objeto de E1-E12.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- _reglas_mantenimiento: lo provisional en un solo lugar
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reglas_mantenimiento()
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'lock_timeout', '2s',            -- D-E13-2: espera maxima por cada bloqueo de UNA cuenta (y del reloj); si no, se omite
    'errores_max',  20,              -- cuantos errores por cuenta se detallan en el resultado (el conteo es siempre el total)
    'muestra_max',  20)              -- cuantas filas defectuosas por control trae sp_verificar_integridad
$$;
COMMENT ON FUNCTION public._reglas_mantenimiento() IS
  'E13. PURA. Valores provisionales del mantenimiento en UN solo lugar: lock_timeout 2s (espera maxima por bloqueo en sp_avanzar_todos), errores_max 20 (errores detallados) y muestra_max 20 (filas defectuosas por control en sp_verificar_integridad).';

-- ----------------------------------------------------------------------------
-- sp_avanzar_todos: el cierre de todas las cuentas (COMMIT por cuenta)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_avanzar_todos(INOUT resultado jsonb DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
  rg        jsonb;
  v_ids     uuid[];
  v_id      uuid;
  v_hoy     date;
  v_ahora   timestamptz;
  v_g       integer;
  v_ok      boolean;
  v_cambios integer := 0;
  v_grupos  bigint  := 0;
  v_omit    integer := 0;
  v_err     integer := 0;
  v_errores jsonb   := '[]'::jsonb;
  v_desde   date;
  v_hasta   date;
BEGIN
  -- (1) transaccion de CAPTURA: search_path ANTES de cualquier otra cosa
  PERFORM pg_catalog.set_config('search_path', 'public, pg_temp', true);
  rg    := public._reglas_mantenimiento();
  v_ids := ARRAY(SELECT c.id FROM public.cuenta c ORDER BY c.id);
  COMMIT;                                                        -- libera la foto de la captura; descarta lo configurado

  -- (2) UNA transaccion por cuenta
  FOREACH v_id IN ARRAY v_ids LOOP
    PERFORM pg_catalog.set_config('search_path', 'public, pg_temp', true);                 -- el COMMIT anterior lo descarto: se fija de nuevo
    PERFORM pg_catalog.set_config('lock_timeout', rg ->> 'lock_timeout', true);
    v_g  := 0;                                                                              -- estado POR CUENTA: nada se arrastra de la anterior
    v_ok := false;
    BEGIN
      SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;        -- UNA instantanea por cuenta
      v_g  := public._avanzar_hasta(v_id, v_hoy, v_ahora);
      v_ok := true;                                                                        -- bandera de exito: LO ULTIMO del bloque (solo si la cuenta se proceso completa)
    EXCEPTION
      WHEN lock_not_available THEN                                                         -- 55P03: timeout de bloqueo (de la cuenta O del reloj): omitida
        v_omit := v_omit + 1;
      WHEN OTHERS THEN                                                                     -- cualquier otro error: solo ESTA cuenta se revierte
        v_err := v_err + 1;
        IF jsonb_array_length(v_errores) < (rg ->> 'errores_max')::integer THEN
          v_errores := v_errores || jsonb_build_array(jsonb_build_object('cuenta_id', v_id, 'mensaje', SQLERRM));
        END IF;
    END;
    IF v_ok THEN                                                                           -- los contadores y el rango de fechas SOLO cuentan cuentas procesadas con exito
      v_desde := least(coalesce(v_desde, v_hoy), v_hoy);
      v_hasta := greatest(coalesce(v_hasta, v_hoy), v_hoy);
      IF v_g > 0 THEN
        v_cambios := v_cambios + 1;
        v_grupos  := v_grupos + v_g;
      END IF;
    END IF;
    COMMIT;
  END LOOP;

  -- (3) transaccion FINAL de auditoria: search_path de nuevo
  PERFORM pg_catalog.set_config('search_path', 'public, pg_temp', true);
  resultado := jsonb_build_object('cuentas', cardinality(v_ids), 'procesadas', cardinality(v_ids) - v_omit - v_err, 'con_cambios', v_cambios, 'grupos', v_grupos,
                                  'omitidas_por_timeout_de_bloqueo', v_omit, 'con_error', v_err, 'errores', v_errores,
                                  'hoy_desde', v_desde, 'hoy_hasta', v_hasta);
  INSERT INTO audit.evento (actor_username, accion, entidad, despues)
  VALUES (session_user::text, 'MANTENIMIENTO_AVANZAR', 'banco', resultado - 'errores');
  COMMIT;
  RAISE NOTICE 'sp_avanzar_todos: %', resultado;
END
$$;
COMMENT ON PROCEDURE public.sp_avanzar_todos(jsonb) IS
  'E13. CALL public.sp_avanzar_todos(); (solo dueño/superusuario; SOLA, nunca dentro de BEGIN ni con otras sentencias: 2D000). Pone al dia TODAS las cuentas (intereses de bolsillos y CDT, cierre de CDT vencidos, cuotas con descuento automatico) con UNA transaccion y UNA instantanea del reloj por cuenta, reutilizando _avanzar_hasta de E7-E9 (todo el dinero sale de _asentar_grupo). Devuelve {cuentas, procesadas, con_cambios, grupos, omitidas_por_timeout_de_bloqueo, con_error, errores[<=20], hoy_desde, hoy_hasta}. Un timeout de bloqueo (55P03, lock_timeout 2s: puede ser la cuenta o el reloj, no se asume cual) deja la cuenta OMITIDA (la pone al dia su proxima operacion o la proxima corrida); otro error revierte solo esa cuenta. Un corte deja confirmado todo lo ya procesado. Idempotente. UN evento MANTENIMIENTO_AVANZAR por corrida completa. SECURITY INVOKER y sin SET (necesario para hacer COMMIT): search_path fijado con set_config al inicio de CADA transaccion.';

-- ----------------------------------------------------------------------------
-- sp_verificar_integridad: informe de todos los controles (solo lectura, UNA sentencia)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_verificar_integridad(INOUT resultado jsonb DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
  m    integer;
  v_sp text := pg_catalog.current_setting('search_path');         -- se puede llamar DENTRO de una transaccion del llamador: su search_path se RESTAURA al final
BEGIN
  PERFORM pg_catalog.set_config('search_path', 'public, pg_temp', true);
  m := (public._reglas_mantenimiento() ->> 'muestra_max')::integer;
  -- UNA sola sentencia = UNA sola foto: los conteos y las filas defectuosas nunca se contradicen (el objetivo de REPEATABLE READ READ ONLY del diseño v3 sin cambiar el nivel)
  SELECT jsonb_build_object(
           'ok', g.ok, 'cuentas', g.cuentas, 'patas', g.patas, 'grupos', g.grupos,
           'contenedores_con_desvio', g.contenedores_con_desvio, 'grupos_con_error', g.grupos_con_error, 'cuentas_con_desvio_i5u', g.cuentas_con_desvio_i5u,
           'defensas_fallidas', g.defensas_fallidas, 'desvio_transferencias', g.desvio_transferencias, 'controles_auth_fallidos', g.controles_auth_fallidos,
           'creditos_con_plan_incoherente', g.creditos_con_plan_incoherente, 'cuentas_borradas', g.cuentas_borradas,
           'detalle', jsonb_build_object(
             'saldos',   coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY to_jsonb(s)::text) FROM (SELECT x.* FROM public.v_integridad_saldos x   WHERE NOT x.ok ORDER BY to_jsonb(x)::text LIMIT m) s), '[]'::jsonb),
             'grupos',   coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY to_jsonb(s)::text) FROM (SELECT x.* FROM public.v_integridad_grupos x   WHERE NOT x.ok ORDER BY to_jsonb(x)::text LIMIT m) s), '[]'::jsonb),
             'usuario',  coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY to_jsonb(s)::text) FROM (SELECT x.* FROM public.v_integridad_usuario x  WHERE NOT x.ok ORDER BY to_jsonb(x)::text LIMIT m) s), '[]'::jsonb),
             'defensas', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY to_jsonb(s)::text) FROM (SELECT x.* FROM public.v_integridad_defensas x WHERE NOT x.ok ORDER BY to_jsonb(x)::text LIMIT m) s), '[]'::jsonb),
             'auth',     coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY to_jsonb(s)::text) FROM (SELECT x.* FROM public.v_integridad_auth x     WHERE NOT x.ok ORDER BY to_jsonb(x)::text LIMIT m) s), '[]'::jsonb),
             'creditos', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY to_jsonb(s)::text) FROM (SELECT x.* FROM public.v_integridad_creditos x WHERE NOT x.ok ORDER BY to_jsonb(x)::text LIMIT m) s), '[]'::jsonb)))
    INTO resultado
    FROM public.v_integridad_global g;
  RAISE NOTICE 'sp_verificar_integridad: ok = %, desvios de saldos = %, grupos con error = %, desvios I5u = %, defensas caidas = %, auth = %, planes = %, desvio de transferencias = %',
               resultado ->> 'ok', resultado ->> 'contenedores_con_desvio', resultado ->> 'grupos_con_error', resultado ->> 'cuentas_con_desvio_i5u', resultado ->> 'defensas_fallidas',
               resultado ->> 'controles_auth_fallidos', resultado ->> 'creditos_con_plan_incoherente', resultado ->> 'desvio_transferencias';
  PERFORM pg_catalog.set_config('search_path', v_sp, true);          -- el set_config local dura hasta el fin de la transaccion: no se deja al llamador con otro search_path
END
$$;
COMMENT ON PROCEDURE public.sp_verificar_integridad(jsonb) IS
  'E13. CALL public.sp_verificar_integridad(); (solo dueño/superusuario). Informe de TODO lo que mide v_integridad_global (saldos I1, cuadre y plantillas de grupos, I5u por cuenta, conservacion I5g con los borrados, defensas, autenticacion y planes de credito): {ok, cuentas, patas, grupos, contenedores_con_desvio, grupos_con_error, cuentas_con_desvio_i5u, defensas_fallidas, desvio_transferencias, controles_auth_fallidos, creditos_con_plan_incoherente, cuentas_borradas, detalle {saldos, grupos, usuario, defensas, auth, creditos: SOLO las filas defectuosas, hasta 20 por control}}. UNA sola sentencia (una sola foto). SOLO LECTURA: no escribe ni audita; informa, no lanza error (leer resultado->>ok). Puede llamarse dentro de una transaccion: fija el search_path con set_config local y lo RESTAURA al terminar (no cambia el del llamador).';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- Permisos: NADIE salvo el dueño y el superusuario (ni PUBLIC, ni banco_app, ni lector, ni dev)
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('sp_avanzar_todos', 'sp_verificar_integridad', '_reglas_mantenimiento')
  LOOP
    EXECUTE format('REVOKE ALL ON ROUTINE %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON ROUTINE %s FROM banco_app, banco_lector, banco_dev', f.firma);
  END LOOP;
END
$$;

COMMIT;
