-- ============================================================================
-- 11_reloj_funciones.sql  ·  Etapa 3 (reloj bancario) · parte 2/3
-- Propósito  : las funciones del reloj. Los triggers que las usan se crean en 12.
--
--   Públicas de lectura (EXECUTE solo banco_lector y, por herencia, banco_dev):
--     hoy_banco()    -> date         fecha de negocio. Real: fecha actual de America/Bogota; manual: fecha_sistema
--     ahora_banco()  -> timestamptz  hoy_banco() + la hora REAL de Bogotá (en modo manual NO es monotónico: la hora
--                                    "da la vuelta" a medianoche mientras la fecha manual no cambia; el historial se
--                                    ordena por transaccion.orden y registrado_en, nunca por fecha)
--   Internas (sin EXECUTE para nadie salvo el dueño):
--     _ahora_real()            clock_timestamp() (reloj de pared, NO now()); único punto para INYECTAR tiempo en las pruebas (solo banco_test/banco_mut)
--     _hoy_de / _ahora_de      funciones PURAS (instante explícito): toda la aritmética de fechas
--     _reloj_instantanea()     (hoy, ahora): PRIMERO el bloqueo FOR SHARE, DESPUÉS el instante; toda operación de negocio la
--                              llama una vez al empezar y usa ese par en TODA su ejecución; el admin espera a las operaciones en vuelo
--     _reloj_vista()           jsonb del contrato GET /admin/reloj
--     _reloj_actualizar(usar, fecha text)  primitiva del PUT /admin/reloj (E11 la envolverá con la validación de ADMIN)
--     _dias_por_cobrar / _cuota_vencida    reglas puras para E7-E9 (sin ninguna decisión financiera)
--     trg_reloj_*()            funciones de los triggers (se crean en 12)
--
-- Zona horaria: siempre 'America/Bogota' POR CÓDIGO (no la de la sesión ni la de la BD).
-- Mensajes: "El reloj no puede retroceder" (contrato); "Fecha inválida" es PROVISIONAL hasta que el equipo resuelva D13.
-- Dependencias : 01 a 10.   Ejecución: como superusuario, IDEMPOTENTE (CREATE OR REPLACE), transaccional.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- Tiempo real y aritmética pura
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._ahora_real()
RETURNS timestamptz LANGUAGE sql VOLATILE SET search_path = public, pg_temp AS $$ SELECT clock_timestamp() $$;
COMMENT ON FUNCTION public._ahora_real() IS
  'E3. Instante real de PARED (clock_timestamp(), VOLATILE). NO es now(): now() es el inicio de la transacción y quedaría obsoleto si la operación espera un bloqueo (p. ej. cruzar la medianoche esperando el reloj). Única fuente de tiempo del reloj y único punto de inyección de las pruebas (solo banco_test/banco_mut). No hay variable de sesión que falsee la hora.';

CREATE OR REPLACE FUNCTION public._hoy_de(p_usar boolean, p_fecha date, p_instante timestamptz)
RETURNS date LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p_usar THEN (p_instante AT TIME ZONE 'America/Bogota')::date ELSE p_fecha END
$$;
COMMENT ON FUNCTION public._hoy_de(boolean, date, timestamptz) IS
  'E3. PURA. "Hoy" del banco para un estado del reloj y un instante: modo real = fecha de America/Bogota del instante (independiente de la zona de la sesión); modo manual = fecha_sistema.';

CREATE OR REPLACE FUNCTION public._ahora_de(p_usar boolean, p_fecha date, p_instante timestamptz)
RETURNS timestamptz LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT (public._hoy_de(p_usar, p_fecha, p_instante) + (p_instante AT TIME ZONE 'America/Bogota')::time) AT TIME ZONE 'America/Bogota'
$$;
COMMENT ON FUNCTION public._ahora_de(boolean, date, timestamptz) IS
  'E3. PURA. hoy del banco + la hora REAL de Bogotá del instante. En modo real es el propio instante; en modo manual conserva la hora local, por lo que NO es monotónico (la hora da la vuelta a medianoche con la fecha manual fija).';

-- ----------------------------------------------------------------------------
-- Lectura
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hoy_banco()
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._hoy_de(r.usar_fecha_real, r.fecha_sistema, public._ahora_real()) FROM public.reloj r WHERE r.id = 1
$$;
COMMENT ON FUNCTION public.hoy_banco() IS
  'E3. Fecha de negocio del banco. Modo real: fecha actual de America/Bogota (sin desfase, independiente de la zona de la sesión). Modo manual: fecha_sistema. Todas las fechas de negocio salen de aquí, nunca de now()/current_date. Las operaciones usan _reloj_instantanea() para ver UNA sola fecha.';

CREATE OR REPLACE FUNCTION public.ahora_banco()
RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._ahora_de(r.usar_fecha_real, r.fecha_sistema, public._ahora_real()) FROM public.reloj r WHERE r.id = 1
$$;
COMMENT ON FUNCTION public.ahora_banco() IS
  'E3. hoy_banco() más la hora real de Bogotá. En modo manual NO es monotónico (la hora da la vuelta a medianoche): ordenar el historial por transaccion.orden y registrado_en.';

CREATE OR REPLACE FUNCTION public._reloj_instantanea()
RETURNS TABLE (hoy date, ahora timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r       record;
  v_inst  timestamptz;
BEGIN
  -- 1) PRIMERO el bloqueo. FOR SHARE se mantiene hasta el COMMIT. Todas las operaciones comparten el bloqueo (no se estorban);
  --    el UPDATE del admin espera a que terminen las operaciones en vuelo y las nuevas esperan ese UPDATE (milisegundos).
  --    En READ COMMITTED, tras esperar se lee la versión CONFIRMADA más reciente de la fila (el estado posterior al admin).
  SELECT x.usar_fecha_real AS usar, x.fecha_sistema AS fecha INTO r FROM public.reloj x WHERE x.id = 1 FOR SHARE;
  -- 2) DESPUÉS el instante (reloj de pared): si la espera cruzó la medianoche, el hoy es el de AHORA, no el del inicio de la transacción.
  v_inst := public._ahora_real();
  -- 3) Un único par (hoy, ahora) derivado del estado bloqueado y de ese instante.
  hoy   := public._hoy_de(r.usar, r.fecha, v_inst);
  ahora := public._ahora_de(r.usar, r.fecha, v_inst);
  RETURN NEXT;
END
$$;
COMMENT ON FUNCTION public._reloj_instantanea() IS
  'E3. Instantánea del reloj para UNA operación: toma PRIMERO el bloqueo FOR SHARE (hasta el COMMIT) y DESPUÉS captura el instante de pared (_ahora_real), de modo que una espera por el reloj (o por un cambio del admin) no deja una fecha obsoleta, ni siquiera al cruzar la medianoche. Toda función de negocio la llama UNA vez al empezar y usa ese par (hoy, ahora) en todas las patas de su operación (una llamada posterior en la misma transacción toma un instante nuevo); el admin no puede cambiar el reloj mientras haya operaciones en vuelo.';

CREATE OR REPLACE FUNCTION public._reloj_vista()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
           'usar_fecha_real', r.usar_fecha_real,
           'fecha_sistema',   CASE WHEN r.usar_fecha_real THEN NULL ELSE to_char(r.fecha_sistema, 'YYYY-MM-DD') END,
           'fecha_actual',    to_char(public._hoy_de(r.usar_fecha_real, r.fecha_sistema, public._ahora_real()), 'YYYY-MM-DD'))
    FROM public.reloj r WHERE r.id = 1
$$;
COMMENT ON FUNCTION public._reloj_vista() IS
  'E3. Contrato GET /admin/reloj: { usar_fecha_real: bool, fecha_sistema: "YYYY-MM-DD" | null (null en modo real), fecha_actual: "YYYY-MM-DD" = hoy_banco() }.';

-- ----------------------------------------------------------------------------
-- Escritura (primitiva del PUT /admin/reloj)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reloj_actualizar(p_usar boolean, p_fecha text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_fecha date;
BEGIN
  IF p_usar IS NULL THEN
    RAISE EXCEPTION 'Reloj: usar_fecha_real es obligatorio' USING ERRCODE = 'P0001';
  END IF;
  IF p_usar THEN
    -- Modo real: SIEMPRE permitido (aunque la fecha real sea anterior a la simulada). La fecha que mande el front se ignora.
    UPDATE public.reloj SET usar_fecha_real = true, fecha_sistema = NULL WHERE id = 1;
  ELSE
    -- La fecha llega como TEXTO a propósito: el front manda '' en modo real y un parámetro date fallaría en el driver con un
    -- error que el backend vería como 503. Aquí todo error de fecha es de negocio (P0001).
    IF p_fecha IS NULL OR btrim(p_fecha) !~ '^\d{4}-\d{2}-\d{2}$' THEN
      RAISE EXCEPTION 'Fecha inválida' USING ERRCODE = 'P0001';
    END IF;
    BEGIN
      v_fecha := btrim(p_fecha)::date;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Fecha inválida' USING ERRCODE = 'P0001';
    END;
    IF v_fecha NOT BETWEEN DATE '2000-01-01' AND DATE '2100-12-31' THEN
      RAISE EXCEPTION 'Fecha inválida' USING ERRCODE = 'P0001';
    END IF;
    -- El trigger trg_reloj_a_validar rechaza el retroceso con "El reloj no puede retroceder".
    UPDATE public.reloj SET usar_fecha_real = false, fecha_sistema = v_fecha WHERE id = 1;
  END IF;
  RETURN public._reloj_vista();
END
$$;
COMMENT ON FUNCTION public._reloj_actualizar(boolean, text) IS
  'E3. Primitiva del PUT /admin/reloj (E11 la envolverá con la validación de ADMIN). usar=true: vuelve SIEMPRE a la fecha real (ignora la fecha). usar=false: fecha en texto YYYY-MM-DD; solo puede igualar o adelantar el hoy del banco (El reloj no puede retroceder); fecha vacía o inválida: Fecha inválida (P0001). Devuelve el jsonb del contrato.';

-- ----------------------------------------------------------------------------
-- Reglas puras para E7-E9 (sin ninguna decisión financiera): cobro por rangos y cuotas vencidas
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._dias_por_cobrar(p_ultimo_cobro date, p_hasta date)
RETURNS SETOF date LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT p_ultimo_cobro + g FROM generate_series(1, p_hasta - p_ultimo_cobro) AS g
$$;
COMMENT ON FUNCTION public._dias_por_cobrar(date, date) IS
  'E3. PURA. Días por cobrar en el rango (ultimo_cobro, hasta]. VACÍA si hasta <= ultimo_cobro: avanzar_hasta() no hace nada, no genera movimientos con rangos negativos y no recobra períodos ya cobrados (también tras volver a fecha real).';

CREATE OR REPLACE FUNCTION public._cuota_vencida(p_fecha_vencimiento date, p_pagada boolean, p_hoy date)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT coalesce(NOT p_pagada AND p_fecha_vencimiento < p_hoy, false)
$$;
COMMENT ON FUNCTION public._cuota_vencida(date, boolean, date) IS
  'E3. PURA. Una cuota está vencida si NO está pagada y su fecha_vencimiento < hoy. Se calcula SIEMPRE al consultar (no se guarda ninguna bandera de vencimiento): al volver a una fecha anterior la cuota deja de aparecer vencida. La mora ya registrada se conserva.';

-- ----------------------------------------------------------------------------
-- Funciones de los triggers del reloj (los triggers se crean en 12)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_reloj_a_validar()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_hoy_old date;
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Reloj: el id es inmutable' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.usar_fecha_real THEN
    -- Modo real: salida explícita de la simulación, SIEMPRE permitida. No se conserva ninguna fecha ni desfase.
    NEW.fecha_sistema := NULL;
    RETURN NEW;
  END IF;
  -- Modo manual
  IF NEW.fecha_sistema IS NULL THEN
    RAISE EXCEPTION 'Fecha inválida' USING ERRCODE = 'P0001';
  END IF;
  v_hoy_old := public._hoy_de(OLD.usar_fecha_real, OLD.fecha_sistema, public._ahora_real());
  -- Solo puede igualarse o adelantarse. Excepción (D5 / D-E3-2): con el banco VACÍO (ninguna fila en transaccion) el seed
  -- puede arrancar en el pasado.
  IF NEW.fecha_sistema < v_hoy_old AND EXISTS (SELECT 1 FROM public.transaccion) THEN
    RAISE EXCEPTION 'El reloj no puede retroceder' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;
COMMENT ON FUNCTION public.trg_reloj_a_validar() IS
  'E3. BEFORE UPDATE en reloj: en modo manual la fecha solo puede igualarse o adelantarse respecto al hoy del banco (El reloj no puede retroceder; con el banco vacío se permite). Pasar a modo real SIEMPRE se permite y deja fecha_sistema en NULL (sin desfase). Rige también para el superusuario.';

CREATE OR REPLACE FUNCTION public.trg_reloj_auditar()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF (OLD.usar_fecha_real, OLD.fecha_sistema) IS NOT DISTINCT FROM (NEW.usar_fecha_real, NEW.fecha_sistema) THEN
    RETURN NULL;                                   -- no hubo cambio (p. ej. real -> real): no se audita
  END IF;
  INSERT INTO audit.evento (actor_username, accion, entidad, entidad_id, antes, despues)
  VALUES (nullif(current_setting('banco.actor', true), ''),       -- solo atribución, NO es control de seguridad
          'RELOJ_CAMBIO', 'reloj', '1',
          jsonb_build_object('usar_fecha_real', OLD.usar_fecha_real, 'fecha_sistema', OLD.fecha_sistema,
                             'hoy_banco', public._hoy_de(OLD.usar_fecha_real, OLD.fecha_sistema, public._ahora_real())),
          jsonb_build_object('usar_fecha_real', NEW.usar_fecha_real, 'fecha_sistema', NEW.fecha_sistema,
                             'hoy_banco', public._hoy_de(NEW.usar_fecha_real, NEW.fecha_sistema, public._ahora_real())));
  RETURN NULL;
END
$$;
COMMENT ON FUNCTION public.trg_reloj_auditar() IS
  'E3. AFTER UPDATE en reloj: registra RELOJ_CAMBIO en audit.evento con el estado y el hoy del banco antes y después. No audita los UPDATE sin cambio. Atómico con el UPDATE: si el cambio falla no queda evento.';

CREATE OR REPLACE FUNCTION public.trg_reloj_borrar()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'Reloj: el registro único del reloj no se puede borrar' USING ERRCODE = 'P0001';
END
$$;
COMMENT ON FUNCTION public.trg_reloj_borrar() IS 'E3. BEFORE DELETE en reloj: rechaza siempre (el reloj es un registro único permanente).';

CREATE OR REPLACE FUNCTION public.trg_reloj_truncate()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'Reloj: la tabla del reloj no se puede vaciar (TRUNCATE rechazado)' USING ERRCODE = 'P0001';
END
$$;
COMMENT ON FUNCTION public.trg_reloj_truncate() IS 'E3. BEFORE TRUNCATE en reloj: rechaza siempre.';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- Permisos de ejecución: las funciones internas y de trigger no son ejecutables por nadie salvo su dueño;
-- hoy_banco() y ahora_banco() solo por banco_lector (banco_dev lo hereda). banco_app NO (el backend las recibe dentro de
-- las vistas del contrato).
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname = ANY (ARRAY['_ahora_real', '_hoy_de', '_ahora_de', '_reloj_instantanea', '_reloj_vista', '_reloj_actualizar',
                                  '_dias_por_cobrar', '_cuota_vencida', 'trg_reloj_a_validar', 'trg_reloj_auditar', 'trg_reloj_borrar',
                                  'trg_reloj_truncate', 'hoy_banco', 'ahora_banco'])
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
  END LOOP;
END
$$;
GRANT EXECUTE ON FUNCTION public.hoy_banco(), public.ahora_banco() TO banco_lector;

COMMIT;
