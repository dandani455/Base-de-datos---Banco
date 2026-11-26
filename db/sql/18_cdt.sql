-- ============================================================================
-- 18_cdt.sql  ·  Etapa 7 (CDT) · parte 2/2
-- Propósito  : listar las definiciones de CDT, simular, crear (CDT_CREACION) y consultar los CDT del cliente. El devengo y el cierre de los CDT los
--              hace el motor de 17 (_avanzar_hasta); aquí el dinero se mueve SOLO por _asentar_grupo.
--
--   Públicas (EXECUTE solo banco_app; banco_dev por herencia):
--     listar_cdt_definiciones(usuario)                         -> jsonb [{id, nombre, tasa, plazo_dias, monto_min}]        (GET  /cdts/definiciones)
--     simular_cdt(usuario, definicion_id text, monto)          -> jsonb {generado_mes, generado_dia, generado_vencimiento}  (POST /cdts/simular)
--     crear_cdt(usuario, definicion_id text, monto)            -> jsonb {id, fecha}  (id = id del CDT)                       (POST /cdts)
--     vista_cdts(usuario)                                      -> jsonb [{id, monto, generado_hasta_hoy, tiempo_restante, fecha_cierre}]   (GET /cdts)
--   Internas (sin EXECUTE para nadie salvo el dueño):
--     _reglas_cdt()                    valores PROVISIONALES centralizados (D-E7-7: mes = 30 días; mensaje del mínimo, contrato §6)
--     _definicion_cdt(texto)           la definición de texto uuid válido, o 'Recurso no encontrado'
--     _texto_tiempo_restante(...)      'N días' / '1 día' / 'Cerrado'
--
-- Orden de validación (como E5/E6): sesión -> monto -> definición -> mínimo -> [instantánea] -> devengo -> libro (saldo).
-- Una sola _reloj_instantanea() por operación (crear_cdt y vista_cdts); simular_cdt y listar no leen el reloj ni escriben.
-- D1 / D11 (fórmula de interés y catálogo de CDT) son del EQUIPO: la fórmula es _factor_interes (17, PROVISIONAL) y no hay catálogo (las pruebas crean sus definiciones).
-- Dependencias : 00 a 17.   Ejecución: como superusuario, IDEMPOTENTE, transaccional.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- Helpers internos
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reglas_cdt()
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'mes_dias',   30,                                                   -- D-E7-7 (PROVISIONAL, equipo): "generado_mes" = lo generado en 30 días (o en el plazo, si es menor)
    'msg_minimo', 'Monto por debajo del mínimo del CDT')                -- contrato §6 (exacto)
$$;
COMMENT ON FUNCTION public._reglas_cdt() IS
  'E7. PURA. Valores de CDT en UN solo lugar: mes_dias = 30 (D-E7-7, PROVISIONAL: define "generado_mes" de la simulación) y el mensaje exacto del contrato §6 para el monto mínimo. Vive aquí y no en _msg_negocio porque esa función es de E5.';

CREATE OR REPLACE FUNCTION public._definicion_cdt(p_texto text)
RETURNS public.cdt_definicion LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_txt text := nullif(btrim(coalesce(p_texto, '')), '');
  d     public.cdt_definicion;
BEGIN
  -- texto (no uuid): un uuid mal formado sería un error de driver (503 en el backend); aquí es un error de negocio
  IF v_txt IS NULL OR v_txt !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO d FROM public.cdt_definicion x WHERE x.id = v_txt::uuid;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  RETURN d;
END
$$;
COMMENT ON FUNCTION public._definicion_cdt(text) IS
  'E7. Interna. La fila de cdt_definicion cuyo id es el uuid de p_texto; si el texto es nulo, vacío, mal formado o no existe: "Recurso no encontrado" (P0001), sin distinguir los casos.';

CREATE OR REPLACE FUNCTION public._texto_tiempo_restante(p_fecha_fin date, p_hoy date, p_estado public.estado_cdt)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p_estado = 'CERRADO' THEN 'Cerrado'
              WHEN p_fecha_fin - p_hoy = 1 THEN '1 día'
              ELSE greatest(p_fecha_fin - p_hoy, 0) || ' días' END
$$;
COMMENT ON FUNCTION public._texto_tiempo_restante(date, date, public.estado_cdt) IS
  'E7. PURA. Texto de "tiempo_restante" de vista_cdts: "Cerrado" si el CDT está CERRADO; "1 día" si falta uno; "N días" en otro caso (fecha_fin - hoy).';

-- ----------------------------------------------------------------------------
-- listar_cdt_definiciones
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.listar_cdt_definiciones(p_usuario_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u public.usuario;
BEGIN
  u := public._validar_cliente(p_usuario_id);
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', d.id, 'nombre', d.nombre, 'tasa', d.tasa_anual, 'plazo_dias', d.plazo_dias, 'monto_min', d.monto_min)
                                    ORDER BY d.plazo_dias, d.nombre)
                     FROM public.cdt_definicion d), '[]'::jsonb);
END
$$;
COMMENT ON FUNCTION public.listar_cdt_definiciones(uuid) IS
  'E7. GET /cdts/definiciones. [{id, nombre, tasa (% E.A.), plazo_dias, monto_min}] ordenado por plazo y nombre; [] si no hay (el catálogo real es D11, del equipo). Exige sesión viva (E4); D-E7-7 PROVISIONAL: el contrato no lleva p_usuario_id en esta función (lo coordina Juan). No consulta el reloj ni escribe.';

-- ----------------------------------------------------------------------------
-- simular_cdt
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.simular_cdt(p_usuario_id uuid, p_definicion_id text, p_monto numeric)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u       public.usuario;
  v_monto numeric;
  d       public.cdt_definicion;
  v_mes   integer;
BEGIN
  u       := public._validar_cliente(p_usuario_id);
  v_monto := public._validar_monto(p_monto);
  d       := public._definicion_cdt(p_definicion_id);
  IF v_monto < d.monto_min THEN
    RAISE EXCEPTION '%', (public._reglas_cdt() ->> 'msg_minimo') USING ERRCODE = 'P0001';
  END IF;
  v_mes := least((public._reglas_cdt() ->> 'mes_dias')::int, d.plazo_dias);
  -- la MISMA fórmula (y el mismo redondeo del objetivo acumulado) que el motor: lo simulado es lo que de verdad se genera
  RETURN jsonb_build_object(
    'generado_mes',         round(v_monto * public._factor_interes(d.tasa_anual, v_mes), 2),
    'generado_dia',         round(v_monto * public._factor_interes(d.tasa_anual, 1), 2),
    'generado_vencimiento', round(v_monto * public._factor_interes(d.tasa_anual, d.plazo_dias), 2));
END
$$;
COMMENT ON FUNCTION public.simular_cdt(uuid, text, numeric) IS
  'E7. POST /cdts/simular. {generado_mes, generado_dia, generado_vencimiento} = round(monto * _factor_interes(tasa de la definición, días), 2) para min(30, plazo) días (D-E7-7 PROVISIONAL), 1 día y el plazo completo: la MISMA fórmula y redondeo con que el motor devenga, así generado_vencimiento = generado_acumulado final del CDT. Orden: sesión, monto, definición (Recurso no encontrado), mínimo (Monto por debajo del mínimo del CDT). No escribe ni consulta el reloj. El backend debe pasar el monto como texto.';

-- ----------------------------------------------------------------------------
-- crear_cdt
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crear_cdt(p_usuario_id uuid, p_definicion_id text, p_monto numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u        public.usuario;
  v_monto  numeric;
  d        public.cdt_definicion;
  v_cta    uuid;
  v_hoy    date;
  v_ahora  timestamptz;
  v_id     uuid;
  v_con    text;
  v_msg    text;
BEGIN
  -- 1) sesión viva (E4) -> 2) monto (E5) -> 3) definición -> 4) mínimo
  u       := public._validar_cliente(p_usuario_id);
  v_monto := public._validar_monto(p_monto);
  d       := public._definicion_cdt(p_definicion_id);
  IF v_monto < d.monto_min THEN
    RAISE EXCEPTION '%', (public._reglas_cdt() ->> 'msg_minimo') USING ERRCODE = 'P0001';
  END IF;
  SELECT c.id INTO v_cta FROM public.cuenta c WHERE c.usuario_id = u.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';             -- el usuario fue borrado entre la sesión y esta lectura
  END IF;
  -- 5) UNA sola instantánea; (hoy, ahora) viajan al motor y al libro
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  -- 6) devengo previo bajo el bloqueo de la cuenta (el saldo que se va a invertir ya incluye lo devengado y lo vencido)
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);
  -- 7) el CDT y su grupo CDT_CREACION, UNO TRAS OTRO en la misma transacción (el diferido ct_cdt_inversion exige que existan juntos); copia contractual
  BEGIN
    INSERT INTO public.cdt (cuenta_id, definicion_id, nombre, monto, tasa_anual, plazo_dias, fecha_inicio, fecha_fin, ultimo_cobro)
    VALUES (v_cta, d.id, d.nombre, v_monto, d.tasa_anual, d.plazo_dias, v_hoy, v_hoy + d.plazo_dias, v_hoy)
    RETURNING id INTO v_id;
  EXCEPTION WHEN foreign_key_violation THEN
    GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
    IF v_con = 'fk_cdt_definicion' THEN
      RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';       -- la definición se borró entre la lectura y el INSERT
    END IF;
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';            -- la cuenta se borró (carrera con el borrado en cascada)
  END;
  BEGIN
    PERFORM public._asentar_grupo(v_ahora, jsonb_build_array(
      jsonb_build_object('tipo', 'CDT_CREACION', 'contenedor', 'CUENTA', 'sentido', 'S', 'monto', v_monto, 'cuenta_id', v_cta, 'cdt_id', v_id, 'contraparte_nombre', d.nombre),
      jsonb_build_object('tipo', 'CDT_CREACION', 'contenedor', 'CDT',    'sentido', 'E', 'monto', v_monto, 'cuenta_id', v_cta, 'cdt_id', v_id, 'contraparte_nombre', d.nombre)));
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    -- Carrera: la cuenta se borró entre el INSERT y el bloqueo. Todo se revierte (sub-bloque) y se traduce; 'Saldo insuficiente' pasa tal cual.
    IF v_msg LIKE 'Libro mayor:%' AND NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = v_cta) THEN
      RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
    END IF;
    RAISE;
  END;
  RETURN jsonb_build_object('id', v_id, 'fecha', v_ahora);
END
$$;
COMMENT ON FUNCTION public.crear_cdt(uuid, text, numeric) IS
  'E7. POST /cdts. Abre un CDT de la definición p_definicion_id (texto uuid) por p_monto (texto en el backend). Orden: sesión, monto, definición (Recurso no encontrado), mínimo (Monto por debajo del mínimo del CDT), UNA _reloj_instantanea(), _avanzar_hasta (devengo previo, bajo el bloqueo de la cuenta), INSERT del CDT (COPIA nombre, tasa, plazo y monto; fecha_inicio = ultimo_cobro = hoy; fecha_fin = hoy + plazo) y grupo CDT_CREACION (CUENTA S + CDT E) por _asentar_grupo en la misma transacción: atómico. Saldo insuficiente lo da el libro. Devuelve {id (del CDT), fecha}. Las ediciones posteriores de la definición no afectan al CDT creado.';

-- ----------------------------------------------------------------------------
-- vista_cdts
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.vista_cdts(p_usuario_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u       public.usuario;
  v_cta   uuid;
  v_hoy   date;
  v_ahora timestamptz;
  r       jsonb;
BEGIN
  u := public._validar_cliente(p_usuario_id);
  SELECT c.id INTO v_cta FROM public.cuenta c WHERE c.usuario_id = u.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END IF;
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);               -- devenga y cierra lo vencido ANTES de leer
  -- UNA sola sentencia = UNA sola foto de todos los CDT de la cuenta
  SELECT coalesce((SELECT jsonb_agg(jsonb_build_object('id', d.id, 'monto', d.monto, 'generado_hasta_hoy', d.generado_acumulado,
                                                       'tiempo_restante', public._texto_tiempo_restante(d.fecha_fin, v_hoy, d.estado),
                                                       'fecha_cierre', (d.fecha_fin::timestamp AT TIME ZONE 'America/Bogota'))
                                    ORDER BY (d.estado = 'CERRADO'), d.fecha_fin, d.id)
                     FROM public.cdt d WHERE d.cuenta_id = c.id), '[]'::jsonb)
    INTO r FROM public.cuenta c WHERE c.id = v_cta;
  IF r IS NULL THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';             -- el usuario fue borrado durante la operación
  END IF;
  RETURN r;
END
$$;
COMMENT ON FUNCTION public.vista_cdts(uuid) IS
  'E7. GET /cdts. [{id, monto, generado_hasta_hoy, tiempo_restante, fecha_cierre}]: UNA _reloj_instantanea() y _avanzar_hasta ANTES de leer (devenga y cierra lo vencido), luego una sola sentencia. generado_hasta_hoy = generado_acumulado; tiempo_restante = "N días" / "1 día" / "Cerrado" (D-E7-7 PROVISIONAL: incluye los CDT cerrados); fecha_cierre = instante ISO 8601 con zona: fecha_fin a las 00:00 de America/Bogota (p. ej. 2026-12-24T00:00:00-05:00; E10, D-E10-5: contrato §3.4 «timestamptz ISO»), no una fecha simple. Vigentes primero (fecha_fin, id), luego cerrados; [] si no hay. Escribe (primer GET del día).';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- Permisos: las 4 públicas -> banco_app (banco_dev las hereda); los helpers -> nadie salvo el dueño
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma, p.proname FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('listar_cdt_definiciones', 'simular_cdt', 'crear_cdt', 'vista_cdts', '_reglas_cdt', '_definicion_cdt', '_texto_tiempo_restante')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
    IF f.proname IN ('listar_cdt_definiciones', 'simular_cdt', 'crear_cdt', 'vista_cdts') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO banco_app', f.firma);
    END IF;
  END LOOP;
END
$$;

COMMIT;
