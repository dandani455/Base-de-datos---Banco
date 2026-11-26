-- ============================================================================
-- 16_bolsillos.sql  ·  Etapa 6 (bolsillos sin interés + vista de balance)
-- Propósito  : crear bolsillos, mover dinero cuenta <-> bolsillo y entre bolsillos, y consultar el balance. TODO el dinero se mueve SOLO por
--              _asentar_grupo (plantillas BOLSO_INGRESO / BOLSO_RETIRO / BOLSO_MOVIMIENTO de E2); crear_bolsillo es el único INSERT (balance 0).
--
--   Públicas (EXECUTE solo banco_app; banco_dev por herencia):
--     crear_bolsillo(usuario, nombre)                                  -> jsonb {id, nombre}
--     mover_a_bolsillo(usuario, bolsillo_id, monto)                    -> jsonb {id, fecha}   cuenta -> bolsillo   (POST /bolsillos/:id/ingresar)
--     retirar_de_bolsillo(usuario, bolsillo_id, monto)                 -> jsonb {id, fecha}   bolsillo -> cuenta   (POST /bolsillos/:id/retirar)
--     mover_entre_bolsillos(usuario, bolsillo_origen, bolsillo_destino, monto) -> jsonb {id, fecha}               (POST /bolsillos/:id/mover)
--     vista_balance(usuario)                                           -> jsonb {total, principal, bolsillos:[{id, nombre, saldo}]}   (GET /bolsillos)
--   Internas (sin EXECUTE para nadie salvo el dueño; las reutilizarán E7-E10):
--     _reglas_bolsillo()               valores PROVISIONALES centralizados (D-E6-8 nombre 1-40, D-E6-9 mensajes nuevos)
--     _bolsillo_propio(cuenta, texto)  uuid válido (texto) de un bolsillo de ESA cuenta, o 'Recurso no encontrado'
--     _mover_bolsillo(...)             las 3 operaciones de movimiento: valida, arma las patas, UNA instantánea, libro, traduce carreras
--     balance_total(cuenta)            ÚNICA definición del "total" (D-E6-12 / D-E7-5, PROVISIONAL hasta D6): cuenta + bolsillos + CDT activos (monto + generado). STABLE.
--
-- Orden de validación (D-E6-2): sesión -> monto -> bolsillo(s) -> (mismo bolsillo) -> [instantánea] -> libro (saldo).
-- Una sola _reloj_instantanea() por operación. Las carreras (bolsillo o usuario borrados mientras espera) las detecta el libro, se revierten
-- por completo y se traducen a 'Recurso no encontrado' / 'Sesión inválida'.
-- E7 (D-E7-4): _avanzar_hasta (17) se integra en vista_balance, las 3 de movimiento (_mover_bolsillo) y crear_bolsillo: la instantánea se toma UNA
--         vez y (hoy, ahora) viajan al motor, que bloquea la cuenta con el mismo FOR NO KEY UPDATE del libro. balance_total incluye los CDT activos (D-E7-5).
-- Dependencias : 00 a 15.   Ejecución: como superusuario, IDEMPOTENTE, transaccional. NO modifica ningún objeto de E5.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- Helpers internos
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reglas_bolsillo()
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'nombre_min',    1,                                                                    -- D-E6-8 (PROVISIONAL, equipo)
    'nombre_max',    40,                                                                   -- D-E6-8 (PROVISIONAL, equipo)
    'msg_nombre',    'Nombre de bolsillo inválido',                                        -- D-E6-8 / D13 (PROVISIONAL)
    'msg_distintos', 'Los bolsillos de origen y destino deben ser distintos')              -- D-E6-9 / D13 (PROVISIONAL)
$$;
COMMENT ON FUNCTION public._reglas_bolsillo() IS
  'E6. PURA. Valores PROVISIONALES de bolsillos en UN solo lugar: D-E6-8 (nombre de 1 a 40 caracteres, mensaje "Nombre de bolsillo inválido") y D-E6-9 (mensaje al mover un bolsillo a sí mismo). Los mensajes viven aquí y no en _msg_negocio porque esa función es de E5 y E5 no se modifica.';

CREATE OR REPLACE FUNCTION public._bolsillo_propio(p_cuenta_id uuid, p_texto text)
RETURNS uuid LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_txt text := nullif(btrim(coalesce(p_texto, '')), '');
  v_id  uuid;
BEGIN
  -- texto (no uuid): un uuid mal formado sería un error de driver (503 en el backend); aquí es un error de negocio
  IF v_txt IS NULL OR v_txt !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  SELECT b.id INTO v_id FROM public.bolsillo b WHERE b.id = v_txt::uuid AND b.cuenta_id = p_cuenta_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';       -- inexistente o de otra cuenta: indistinguible a propósito
  END IF;
  RETURN v_id;
END
$$;
COMMENT ON FUNCTION public._bolsillo_propio(uuid, text) IS
  'E6. Interna. Devuelve el id del bolsillo de texto p_texto si es un uuid bien formado Y pertenece a la cuenta p_cuenta_id; si no (mal formado, inexistente o ajeno) "Recurso no encontrado" (P0001), sin distinguir los casos. Reutilizable por E7-E9.';

CREATE OR REPLACE FUNCTION public.balance_total(p_cuenta_id uuid)
RETURNS numeric LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  -- D-E6-12 / D-E7-5 (PROVISIONAL, D6 pendiente del equipo): total = cuenta + bolsillos + CDT ACTIVOS (monto + generado_acumulado). La deuda de crédito
  -- NO se resta todavía (E8, D6). Cuando D6 se resuelva SOLO cambia esta función.
  SELECT c.balance + coalesce((SELECT sum(b.balance) FROM public.bolsillo b WHERE b.cuenta_id = c.id), 0)
                   + coalesce((SELECT sum(d.monto + d.generado_acumulado) FROM public.cdt d WHERE d.cuenta_id = c.id AND d.estado = 'ACTIVO'), 0)
    FROM public.cuenta c WHERE c.id = p_cuenta_id
$$;
COMMENT ON FUNCTION public.balance_total(uuid) IS
  'E6/E7. Interna, STABLE (usa la foto de la sentencia que la llama: lectura consistente). ÚNICA definición del "total" (contrato: balance_total()). D-E6-12 / D-E7-5 PROVISIONAL (D6 pendiente): cuenta.balance + suma de los bolsillos + monto y generado_acumulado de los CDT ACTIVOS (coincide con la inversión del libro; crear un CDT no baja el total). Los créditos (capital pendiente) se incorporan cuando el equipo decida D6 (cambia solo esta función). NULL si la cuenta no existe. La reutilizará vista_dashboard (E10).';

-- ----------------------------------------------------------------------------
-- _mover_bolsillo: las 3 operaciones de movimiento (las públicas son delgadas)
--   p_plantilla: BOLSO_INGRESO (cuenta -> bolsillo A), BOLSO_RETIRO (bolsillo A -> cuenta), BOLSO_MOVIMIENTO (bolsillo A -> bolsillo B)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mover_bolsillo(
  p_usuario_id uuid, p_plantilla text, p_bol_a text, p_bol_b text, p_monto numeric)
RETURNS jsonb LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  u        public.usuario;
  v_monto  numeric;
  v_cta    uuid;
  v_a      uuid;
  v_b      uuid;
  v_na     text;
  v_nb     text;
  v_hoy    date;
  v_ahora  timestamptz;
  v_patas  jsonb;
  v_grupo  uuid;
  v_msg    text;
BEGIN
  -- 1) sesión viva: CLIENTE y no bloqueado (E4)
  u := public._validar_cliente(p_usuario_id);
  -- 2) monto (E5)
  v_monto := public._validar_monto(p_monto);
  -- 3) bolsillo(s): uuid válido y de MI cuenta
  SELECT c.id INTO v_cta FROM public.cuenta c WHERE c.usuario_id = u.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';             -- el usuario fue borrado entre la sesión y esta lectura
  END IF;
  v_a := public._bolsillo_propio(v_cta, p_bol_a);
  IF p_plantilla = 'BOLSO_MOVIMIENTO' THEN
    v_b := public._bolsillo_propio(v_cta, p_bol_b);
    -- 4) D-E6-9 (PROVISIONAL): mover un bolsillo a sí mismo
    IF v_a = v_b THEN
      RAISE EXCEPTION '%', (public._reglas_bolsillo() ->> 'msg_distintos') USING ERRCODE = 'P0001';
    END IF;
  ELSIF p_plantilla NOT IN ('BOLSO_INGRESO', 'BOLSO_RETIRO') THEN
    RAISE EXCEPTION 'plantilla de bolsillo desconocida: %', p_plantilla;
  END IF;
  -- nombres de los bolsillos (snapshot de texto para la contraparte del libro)
  SELECT b.nombre INTO v_na FROM public.bolsillo b WHERE b.id = v_a;
  IF NOT FOUND THEN RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001'; END IF;
  IF v_b IS NOT NULL THEN
    SELECT b.nombre INTO v_nb FROM public.bolsillo b WHERE b.id = v_b;
    IF NOT FOUND THEN RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001'; END IF;
  END IF;

  -- 5) UNA sola instantánea del reloj; su ahora fecha ambas patas y el (hoy, ahora) viaja al motor de devengo (E7)
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  -- 5b) (E7) devengo previo bajo el bloqueo de la cuenta (el mismo que conserva el libro): el saldo del bolsillo ya incluye sus intereses.
  --     El devengo cambia saldos, no nombres: el snapshot de nombres de arriba sigue siendo válido.
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);

  v_patas := CASE p_plantilla
    WHEN 'BOLSO_INGRESO' THEN jsonb_build_array(
      jsonb_build_object('tipo', 'BOLSO_INGRESO', 'contenedor', 'CUENTA',   'sentido', 'S', 'monto', v_monto, 'cuenta_id', v_cta, 'bolsillo_id', v_a, 'contraparte_nombre', v_na),
      jsonb_build_object('tipo', 'BOLSO_INGRESO', 'contenedor', 'BOLSILLO', 'sentido', 'E', 'monto', v_monto, 'cuenta_id', v_cta, 'bolsillo_id', v_a, 'contraparte_nombre', v_na))
    WHEN 'BOLSO_RETIRO' THEN jsonb_build_array(
      jsonb_build_object('tipo', 'BOLSO_RETIRO',  'contenedor', 'BOLSILLO', 'sentido', 'S', 'monto', v_monto, 'cuenta_id', v_cta, 'bolsillo_id', v_a, 'contraparte_nombre', v_na),
      jsonb_build_object('tipo', 'BOLSO_RETIRO',  'contenedor', 'CUENTA',   'sentido', 'E', 'monto', v_monto, 'cuenta_id', v_cta, 'bolsillo_id', v_a, 'contraparte_nombre', v_na))
    ELSE jsonb_build_array(
      jsonb_build_object('tipo', 'BOLSO_MOVIMIENTO', 'contenedor', 'BOLSILLO', 'sentido', 'S', 'monto', v_monto, 'cuenta_id', v_cta, 'bolsillo_id', v_a, 'contraparte_nombre', v_nb),
      jsonb_build_object('tipo', 'BOLSO_MOVIMIENTO', 'contenedor', 'BOLSILLO', 'sentido', 'E', 'monto', v_monto, 'cuenta_id', v_cta, 'bolsillo_id', v_b, 'contraparte_nombre', v_na))
  END;

  -- 6) el libro hace TODO: bloquea la cuenta (orden de id), aplica los saldos y verifica cuadre y saldo suficiente
  BEGIN
    v_grupo := public._asentar_grupo(v_ahora, v_patas);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    -- Carreras: el usuario o algún bolsillo se borraron entre la validación y el bloqueo. Todo se revierte (sub-bloque) y se traduce.
    IF v_msg LIKE 'Libro mayor:%' THEN
      IF NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = v_cta) THEN
        RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
      ELSIF NOT EXISTS (SELECT 1 FROM public.bolsillo b WHERE b.id = v_a)
         OR (v_b IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.bolsillo b WHERE b.id = v_b)) THEN
        RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
      END IF;
    END IF;
    RAISE;                                                       -- cualquier otro (p. ej. Saldo insuficiente) pasa tal cual
  END;
  RETURN jsonb_build_object('id', v_grupo, 'fecha', v_ahora);
END
$$;
COMMENT ON FUNCTION public._mover_bolsillo(uuid, text, text, text, numeric) IS
  'E6. Interna. Núcleo de mover_a_bolsillo (BOLSO_INGRESO), retirar_de_bolsillo (BOLSO_RETIRO) y mover_entre_bolsillos (BOLSO_MOVIMIENTO). Orden: sesión, monto, bolsillo(s) propios, mismo bolsillo (D-E6-9), UNA _reloj_instantanea(), _asentar_grupo (dos patas con la misma fecha y grupo; contraparte_nombre = nombre del bolsillo del otro lado). Carreras por borrado traducidas a Sesión inválida / Recurso no encontrado. Devuelve {id, fecha}. E7: tras la instantánea llama _avanzar_hasta (devengo previo bajo el bloqueo de la cuenta).';

-- ----------------------------------------------------------------------------
-- Funciones públicas de movimiento (delgadas)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mover_a_bolsillo(p_usuario_id uuid, p_bolsillo_id text, p_monto numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  RETURN public._mover_bolsillo(p_usuario_id, 'BOLSO_INGRESO', p_bolsillo_id, NULL, p_monto);
END
$$;
COMMENT ON FUNCTION public.mover_a_bolsillo(uuid, text, numeric) IS
  'E6. POST /bolsillos/:id/ingresar. Mueve p_monto de la cuenta principal al bolsillo p_bolsillo_id (texto uuid, debe ser de MI cuenta). Solo _asentar_grupo (BOLSO_INGRESO); UNA _reloj_instantanea(). Errores: Monto inválido, Recurso no encontrado, Saldo insuficiente (+ sesión de E4). Devuelve {id, fecha}. El backend debe pasar el monto como texto.';

CREATE OR REPLACE FUNCTION public.retirar_de_bolsillo(p_usuario_id uuid, p_bolsillo_id text, p_monto numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  RETURN public._mover_bolsillo(p_usuario_id, 'BOLSO_RETIRO', p_bolsillo_id, NULL, p_monto);
END
$$;
COMMENT ON FUNCTION public.retirar_de_bolsillo(uuid, text, numeric) IS
  'E6. POST /bolsillos/:id/retirar. Mueve p_monto del bolsillo p_bolsillo_id (texto uuid, de MI cuenta) a la cuenta principal. Solo _asentar_grupo (BOLSO_RETIRO); UNA _reloj_instantanea(). Errores: Monto inválido, Recurso no encontrado, Saldo insuficiente (+ sesión de E4). Devuelve {id, fecha}.';

CREATE OR REPLACE FUNCTION public.mover_entre_bolsillos(p_usuario_id uuid, p_bolsillo_origen text, p_bolsillo_destino text, p_monto numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  RETURN public._mover_bolsillo(p_usuario_id, 'BOLSO_MOVIMIENTO', p_bolsillo_origen, p_bolsillo_destino, p_monto);
END
$$;
COMMENT ON FUNCTION public.mover_entre_bolsillos(uuid, text, text, numeric) IS
  'E6. POST /bolsillos/:id/mover {monto, destino_id}. Mueve p_monto de un bolsillo a OTRO de la misma cuenta (ambos textos uuid, de MI cuenta; si son el mismo: mensaje provisional D-E6-9). Solo _asentar_grupo (BOLSO_MOVIMIENTO); UNA _reloj_instantanea(). Devuelve {id, fecha}.';

-- ----------------------------------------------------------------------------
-- crear_bolsillo
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crear_bolsillo(p_usuario_id uuid, p_nombre text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u        public.usuario;
  v_nombre text;
  v_cta    uuid;
  v_hoy    date;
  v_ahora  timestamptz;
  v_id     uuid;
BEGIN
  -- 1) sesión viva (E4)
  u := public._validar_cliente(p_usuario_id);
  -- 2) nombre (D-E6-8, PROVISIONAL): normalizado (recorte y colapso de espacios), 1-40 caracteres, sin caracteres de control; duplicados permitidos
  v_nombre := public._norm_texto(p_nombre);
  IF v_nombre IS NULL
     OR length(v_nombre) NOT BETWEEN (public._reglas_bolsillo() ->> 'nombre_min')::int AND (public._reglas_bolsillo() ->> 'nombre_max')::int
     OR v_nombre ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION '%', (public._reglas_bolsillo() ->> 'msg_nombre') USING ERRCODE = 'P0001';
  END IF;
  SELECT c.id INTO v_cta FROM public.cuenta c WHERE c.usuario_id = u.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END IF;
  -- 3) UNA sola instantánea (D-E6-6): ultimo_cobro = hoy del banco, creado_en = ahora del banco (como cuenta.creado_en en E4)
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  -- 3b) (E7) devengo previo de los demás productos de la cuenta, con la misma instantánea (uniformidad: toda operación que mueve o crea productos devenga primero)
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);
  -- 4) el bolsillo nace con balance 0 (lo exige la guardia del libro); la FK captura la carrera «usuario borrado»
  BEGIN
    INSERT INTO public.bolsillo (cuenta_id, nombre, ultimo_cobro, creado_en)
    VALUES (v_cta, v_nombre, v_hoy, v_ahora) RETURNING id INTO v_id;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END;
  RETURN jsonb_build_object('id', v_id, 'nombre', v_nombre);
END
$$;
COMMENT ON FUNCTION public.crear_bolsillo(uuid, text) IS
  'E6. POST /bolsillos {nombre}. Crea un bolsillo con balance 0 en la cuenta del cliente. Nombre normalizado de 1 a 40 caracteres sin caracteres de control (D-E6-8, PROVISIONAL; error "Nombre de bolsillo inválido"); nombres repetidos permitidos; sin tope. UNA _reloj_instantanea(): ultimo_cobro = hoy del banco, creado_en = ahora del banco (D-E6-6). Usuario borrado en carrera: Sesión inválida. Devuelve {id, nombre}.';

-- ----------------------------------------------------------------------------
-- vista_balance: GET /bolsillos
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.vista_balance(p_usuario_id uuid)
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
  -- (E7) UNA instantánea y devengo previo ANTES de leer: si devengó, el bloqueo de la cuenta (que se conserva hasta el COMMIT) impide que otro
  -- movimiento del cliente se interponga; si no devengó, la lectura de abajo es una sola foto.
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);
  -- UNA sola sentencia = UNA sola foto: principal, bolsillos y total (balance_total es STABLE) nunca se ven a medias de un movimiento concurrente.
  SELECT jsonb_build_object(
           'total',     public.balance_total(c.id),
           'principal', c.balance,
           'bolsillos', coalesce((SELECT jsonb_agg(jsonb_build_object('id', b.id, 'nombre', b.nombre, 'saldo', b.balance) ORDER BY b.creado_en, b.id)
                                    FROM public.bolsillo b WHERE b.cuenta_id = c.id), '[]'::jsonb))
    INTO r
    FROM public.cuenta c WHERE c.id = v_cta;
  IF r IS NULL THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';             -- el usuario fue borrado entre la sesión y la lectura
  END IF;
  RETURN r;
END
$$;
COMMENT ON FUNCTION public.vista_balance(uuid) IS
  'E6. GET /bolsillos. {total, principal, bolsillos:[{id, nombre, saldo}]}: total = balance_total() (única definición, D-E6-12 provisional), principal = cuenta.balance, bolsillos = SOLO los de mi cuenta, orden creado_en/id, [] si no hay. Lectura consistente (una sola sentencia). E7: UNA _reloj_instantanea() y _avanzar_hasta (devengo de bolsillos y CDT vencidos) ANTES de leer, por lo que puede escribir (primer GET del día). Exige sesión viva (mensajes de E4).';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- Permisos: las 5 públicas -> banco_app (banco_dev las hereda); los helpers -> nadie salvo el dueño
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma, p.proname FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('crear_bolsillo', 'mover_a_bolsillo', 'retirar_de_bolsillo', 'mover_entre_bolsillos', 'vista_balance',
                         '_reglas_bolsillo', '_bolsillo_propio', '_mover_bolsillo', 'balance_total')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
    IF f.proname IN ('crear_bolsillo', 'mover_a_bolsillo', 'retirar_de_bolsillo', 'mover_entre_bolsillos', 'vista_balance') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO banco_app', f.firma);
    END IF;
  END LOOP;
END
$$;

COMMIT;
