-- ============================================================================
-- 14_auth_funciones.sql  ·  Etapa 4 (autenticación y registro) · parte 2/2
-- Propósito  : las funciones de negocio de E4. Son las PRIMERAS ejecutables por banco_app (EXECUTE; ni lector ni PUBLIC).
--
--   Públicas (5):
--     registrar_usuario(...)        -> jsonb { usuario_id, username }   usuario + cuenta + 5 INGRESO_SIMULADO (+ bono si la verificación está apagada)
--     obtener_credenciales(user)    -> TABLE(usuario_id, password_hash, rol, estado); 0 filas si no existe; la ÚNICA que entrega el hash
--     validar_sesion(usuario)       -> jsonb { username, rol, estado }; lanza el mensaje de bloqueo
--     verificar_correo(usuario)     -> void; idempotente; paga el bono de referido una sola vez
--     vista_perfil(usuario)         -> jsonb { username, numero_cuenta, codigo_referido }
--   Internas (sin EXECUTE para nadie salvo el dueño):
--     _validar_cliente(uuid) / _validar_admin(uuid)    helpers de autenticación para E5-E12
--     _pagar_bono_referido(usuario, ahora)             ÚNICA implementación del bono; idempotente
--   NO incluida (decisión D-E4-9 pendiente de Juan): datos_reenvio_verificacion. No se crea ni se concede hasta que él confirme.
--
-- Reglas que esta etapa hace cumplir:
--   * El reloj se toma UNA sola vez por operación (registrar_usuario y verificar_correo) y ese resultado se pasa a las internas.
--     Ninguna función de E4 usa el reloj del sistema ni las lecturas sueltas del reloj del banco.
--   * Todo lo que toca el libro pasa por _asentar_grupo (ni un INSERT directo en transaccion).
--   * Una llamada = una sentencia = una transacción: cualquier fallo revierte usuario, cuenta, ingresos y bono.
--   * Mensajes y valores provisionales: solo en _msg_auth() y _reglas_registro() (13).
--   * Excepción consciente del contrato §1: vista_perfil NO ejecuta avanzar_hasta (no devuelve nada financiero ni dependiente del tiempo).
-- Dueño banco_owner · SECURITY DEFINER las públicas · search_path fijo.
-- Dependencias : 00 a 13.   Ejecución: como superusuario, IDEMPOTENTE, transaccional.
-- Verificar    : SELECT proname, prosecdef, proacl FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname ~ 'registrar|credenciales|sesion|verificar_correo|perfil|validar|bono';
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- Helpers de autenticación (internos)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._validar_cliente(p_usuario_id uuid)
RETURNS public.usuario LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  u public.usuario;
BEGIN
  SELECT * INTO u FROM public.usuario WHERE id = p_usuario_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END IF;
  IF u.rol <> 'CLIENTE' THEN
    RAISE EXCEPTION '%', public._msg_auth('denegado') USING ERRCODE = 'P0001';
  END IF;
  IF u.estado = 'BLOQUEADO' THEN
    RAISE EXCEPTION '%', public._msg_auth('bloqueado') USING ERRCODE = 'P0001';
  END IF;
  RETURN u;
END
$$;
COMMENT ON FUNCTION public._validar_cliente(uuid) IS
  'E4. Interna. El usuario existe (si no: Sesión inválida), es CLIENTE (si no: Acceso denegado) y no está BLOQUEADO (si lo está: el mensaje exacto de bloqueo). Lee el estado VIVO. Helper para las funciones de cliente de E5-E10.';

CREATE OR REPLACE FUNCTION public._validar_admin(p_admin_id uuid)
RETURNS public.usuario LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  u public.usuario;
BEGIN
  SELECT * INTO u FROM public.usuario WHERE id = p_admin_id;
  IF NOT FOUND OR u.rol <> 'ADMIN' THEN
    RAISE EXCEPTION '%', public._msg_auth('denegado') USING ERRCODE = 'P0001';
  END IF;
  IF u.estado = 'BLOQUEADO' THEN
    RAISE EXCEPTION '%', public._msg_auth('bloqueado') USING ERRCODE = 'P0001';
  END IF;
  RETURN u;
END
$$;
COMMENT ON FUNCTION public._validar_admin(uuid) IS
  'E4. Interna. El usuario existe y es ADMIN (si no: Acceso denegado, el mensaje del contrato) y no está bloqueado (si lo está: el mensaje de bloqueo). Helper para E11-E12.';

-- ----------------------------------------------------------------------------
-- Bono de referido: ÚNICA implementación (sin trigger). Recibe el "ahora" de la operación que la llama.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._pagar_bono_referido(p_usuario_id uuid, p_ahora timestamptz)
RETURNS boolean LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  u            public.usuario;
  v_cuenta_ref uuid;
  v_num_nuevo  text;
  v_monto      numeric;
  v_nota       text;
BEGIN
  -- Bloqueo de la fila del referido: serializa verificaciones simultáneas y protege la bandera
  SELECT * INTO u FROM public.usuario WHERE id = p_usuario_id FOR UPDATE;
  IF NOT FOUND OR u.bono_referido_pagado OR u.referido_por IS NULL THEN
    RETURN false;                       -- sin referido, referidor borrado (SET NULL) o bono ya pagado: no se hace nada
  END IF;
  -- D-E4-19 (PROVISIONAL, negocio pendiente): el bono se paga también a un referidor BLOQUEADO. Único punto a cambiar.
  SELECT c.id INTO v_cuenta_ref FROM public.cuenta c WHERE c.usuario_id = u.referido_por;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_auth('invalido') USING ERRCODE = 'P0001';     -- invariante rota: todo cliente tiene cuenta
  END IF;
  SELECT c.numero_cuenta INTO v_num_nuevo FROM public.cuenta c WHERE c.usuario_id = p_usuario_id;
  SELECT p.bono_referido INTO v_monto FROM public.parametro p WHERE p.id = 1;
  v_nota := 'Bono por referir a ' || split_part(u.nombres, ' ', 1) || ' ' || split_part(u.apellidos, ' ', 1);

  PERFORM public._asentar_grupo(p_ahora, jsonb_build_array(
    jsonb_build_object('tipo', 'BONO_REFERIDO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', v_monto, 'cuenta_id', v_cuenta_ref,
                       'nota', v_nota, 'contraparte_nombre', 'Banco Digital', 'contraparte_cuenta', v_num_nuevo),
    jsonb_build_object('tipo', 'BONO_REFERIDO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', v_monto, 'cuenta_id', v_cuenta_ref,
                       'nota', v_nota, 'contraparte_nombre', 'Banco Digital')));
  -- La bandera y el movimiento contable van en la MISMA transacción: o ocurren las dos cosas o ninguna
  UPDATE public.usuario SET bono_referido_pagado = true WHERE id = p_usuario_id;
  RETURN true;
END
$$;
COMMENT ON FUNCTION public._pagar_bono_referido(uuid, timestamptz) IS
  'E4. Interna. ÚNICA implementación del bono de referido (parametro.bono_referido, BONO_REFERIDO) por _asentar_grupo con el ahora de la operación que la llama (no consulta el reloj). Idempotente: bloquea al referido (FOR UPDATE) y usa bono_referido_pagado en la misma transacción. Devuelve TRUE si pagó. Sin trigger. D-E4-19 provisional: paga también a referidores bloqueados.';

-- ----------------------------------------------------------------------------
-- registrar_usuario
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_usuario(
  p_nombres text, p_apellidos text, p_cedula text, p_correo text, p_telefono text, p_fecha_nacimiento text,
  p_password_hash text, p_acepta_politica boolean, p_codigo_referido text, p_verificacion_activa boolean)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_nombres   text;
  v_apellidos text;
  v_cedula    text;
  v_correo    text;
  v_telefono  text;
  v_nac       date;
  v_ref_txt   text;
  v_ref_uuid  uuid;
  v_ref_id    uuid;
  v_hoy       date;
  v_ahora     timestamptz;
  v_edad      integer;
  v_base      text;
  v_username  text;
  v_id        uuid;
  v_ok        boolean := false;
  v_con       text;
  v_i         integer;
  v_cuenta_id uuid;
  v_numero    text;
  v_n         integer;
  v_min       numeric;
  v_max       numeric;
  v_lo        bigint;
  v_hi        bigint;
  v_ini       timestamptz;
  v_margen    integer := (public._reglas_registro() ->> 'ingresos_margen_segundos')::integer;
  v_dias      integer := (public._reglas_registro() ->> 'ingresos_ventana_dias')::integer;
  v_total     bigint;
  v_ancho     bigint;
  v_fechas    timestamptz[] := ARRAY[]::timestamptz[];
  v_monto     bigint;
  v_k         integer;
BEGIN
  -- 1) Política de datos (contrato §6): siempre el primer mensaje, aunque otros campos estén mal
  IF p_acepta_politica IS NOT TRUE THEN
    RAISE EXCEPTION '%', public._msg_auth('politica') USING ERRCODE = 'P0001';
  END IF;
  -- 2) Presencia
  IF nullif(btrim(p_nombres), '') IS NULL OR nullif(btrim(p_apellidos), '') IS NULL OR nullif(btrim(p_cedula), '') IS NULL
     OR nullif(btrim(p_correo), '') IS NULL OR nullif(btrim(p_telefono), '') IS NULL OR nullif(btrim(p_fecha_nacimiento), '') IS NULL
     OR nullif(p_password_hash, '') IS NULL THEN
    RAISE EXCEPTION '%', public._msg_auth('incompleto') USING ERRCODE = 'P0001';
  END IF;

  -- 3) Formato (sin reloj). VALIDACIÓN A, para ALMACENAR: el nombre real conserva sus caracteres (cualquier alfabeto).
  --    La regla B (generar el username) es independiente y nunca rechaza el registro.
  v_nombres := public._norm_texto(p_nombres);
  IF NOT public._nombre_valido(v_nombres) THEN
    RAISE EXCEPTION '%', public._msg_auth('nombre') USING ERRCODE = 'P0001';
  END IF;
  v_apellidos := public._norm_texto(p_apellidos);
  IF NOT public._nombre_valido(v_apellidos) THEN
    RAISE EXCEPTION '%', public._msg_auth('apellido') USING ERRCODE = 'P0001';
  END IF;
  v_cedula := public._norm_cedula(p_cedula);
  IF v_cedula IS NULL THEN
    RAISE EXCEPTION '%', public._msg_auth('cedula') USING ERRCODE = 'P0001';
  END IF;
  v_correo := lower(btrim(p_correo));
  IF length(v_correo) > (public._reglas_registro() ->> 'correo_max')::int
     OR v_correo !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RAISE EXCEPTION '%', public._msg_auth('correo') USING ERRCODE = 'P0001';
  END IF;
  v_telefono := public._norm_telefono(p_telefono);
  IF v_telefono IS NULL THEN
    RAISE EXCEPTION '%', public._msg_auth('telefono') USING ERRCODE = 'P0001';
  END IF;
  IF length(p_password_hash) > (public._reglas_registro() ->> 'hash_max')::int OR NOT public._es_hash_bcrypt(p_password_hash) THEN
    RAISE EXCEPTION '%', public._msg_auth('invalido') USING ERRCODE = 'P0001';        -- la BD nunca guarda una clave en claro
  END IF;
  -- fecha de nacimiento: llega como texto para que una entrada inválida sea un error de negocio y no de driver
  IF btrim(p_fecha_nacimiento) !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
    RAISE EXCEPTION '%', public._msg_auth('nacimiento') USING ERRCODE = 'P0001';
  END IF;
  BEGIN
    v_nac := btrim(p_fecha_nacimiento)::date;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION '%', public._msg_auth('nacimiento') USING ERRCODE = 'P0001';
  END;
  -- código de referido: texto opcional (el front manda el ?ref= de la URL sin validar)
  v_ref_txt := nullif(btrim(coalesce(p_codigo_referido, '')), '');
  IF v_ref_txt IS NOT NULL THEN
    IF v_ref_txt !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION '%', public._msg_auth('referido') USING ERRCODE = 'P0001';       -- D-E4-14 (PROVISIONAL): error, no se ignora
    END IF;
    v_ref_uuid := v_ref_txt::uuid;
  END IF;

  -- 4) UNA sola instantánea del reloj; hoy y ahora se reutilizan en toda la operación (y se pasan a las internas)
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;

  -- 5) Edad, con la fecha del banco
  IF v_nac < DATE '1900-01-01' OR v_nac > v_hoy THEN
    RAISE EXCEPTION '%', public._msg_auth('nacimiento') USING ERRCODE = 'P0001';
  END IF;
  v_edad := public._edad_en(v_nac, v_hoy);
  IF v_edad > (public._reglas_registro() ->> 'edad_maxima')::int THEN
    RAISE EXCEPTION '%', public._msg_auth('nacimiento') USING ERRCODE = 'P0001';
  END IF;
  IF v_edad < (public._reglas_registro() ->> 'edad_minima')::int THEN
    RAISE EXCEPTION '%', public._msg_auth('mayor_edad') USING ERRCODE = 'P0001';       -- D-E4-12 (PROVISIONAL)
  END IF;

  -- 6) Referidor (solo un CLIENTE puede referir)
  IF v_ref_uuid IS NOT NULL THEN
    SELECT u.id INTO v_ref_id FROM public.usuario u WHERE u.codigo_referido = v_ref_uuid AND u.rol = 'CLIENTE';
    IF NOT FOUND THEN
      RAISE EXCEPTION '%', public._msg_auth('referido') USING ERRCODE = 'P0001';       -- D-E4-14 (PROVISIONAL): error, no se ignora
    END IF;
  END IF;

  -- 7) Duplicados (en este orden). La carrera la cubre el UNIQUE (más abajo)
  IF EXISTS (SELECT 1 FROM public.usuario WHERE cedula = v_cedula) THEN
    RAISE EXCEPTION '%', public._msg_auth('dup_cedula') USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.usuario WHERE correo = v_correo) THEN
    RAISE EXCEPTION '%', public._msg_auth('dup_correo') USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.usuario WHERE telefono = v_telefono) THEN
    RAISE EXCEPTION '%', public._msg_auth('dup_telefono') USING ERRCODE = 'P0001';
  END IF;

  -- 8) Usuario: base + 3 dígitos (30 intentos) y luego + 4 dígitos (30). Cada intento es una subtransacción que captura
  --    uq_usuario_username (también cubre la carrera); el resto de violaciones se traducen a su mensaje de negocio.
  v_base := public._username_base(v_nombres, v_apellidos);
  FOR v_i IN 1 .. ((public._reglas_registro() ->> 'username_intentos_3_digitos')::int + (public._reglas_registro() ->> 'username_intentos_4_digitos')::int) LOOP
    IF v_i <= (public._reglas_registro() ->> 'username_intentos_3_digitos')::int THEN
      v_username := v_base || (100 + floor(random() * 900)::int)::text;
    ELSE
      v_username := v_base || (1000 + floor(random() * 9000)::int)::text;
    END IF;
    BEGIN
      INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, referido_por, creado_en)
      VALUES (v_username, p_password_hash, v_nombres, v_apellidos, v_cedula, v_correo, v_telefono, v_nac, v_ref_id, v_ahora)
      RETURNING id INTO v_id;
      v_ok := true;
      EXIT;
    EXCEPTION
      WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
        IF v_con = 'uq_usuario_cedula' THEN
          RAISE EXCEPTION '%', public._msg_auth('dup_cedula') USING ERRCODE = 'P0001';
        ELSIF v_con = 'uq_usuario_correo' THEN
          RAISE EXCEPTION '%', public._msg_auth('dup_correo') USING ERRCODE = 'P0001';
        ELSIF v_con = 'uq_usuario_telefono' THEN
          RAISE EXCEPTION '%', public._msg_auth('dup_telefono') USING ERRCODE = 'P0001';
        ELSIF v_con <> 'uq_usuario_username' THEN
          RAISE EXCEPTION '%', public._msg_auth('invalido') USING ERRCODE = 'P0001';
        END IF;                                              -- uq_usuario_username: se reintenta con otros dígitos
      WHEN check_violation OR string_data_right_truncation OR not_null_violation THEN
        RAISE EXCEPTION '%', public._msg_auth('invalido') USING ERRCODE = 'P0001';
    END;
  END LOOP;
  IF NOT v_ok THEN
    RAISE EXCEPTION '%', public._msg_auth('agotado') USING ERRCODE = 'P0001';
  END IF;

  -- 9) Cuenta: prefijo + 8 dígitos aleatorios, único (reintento por uq_cuenta_numero)
  v_ok := false;
  FOR v_i IN 1 .. (public._reglas_registro() ->> 'cuenta_intentos')::int LOOP
    v_numero := (public._reglas_registro() ->> 'cuenta_prefijo') || lpad((floor(random() * 100000000))::bigint::text, 8, '0');
    BEGIN
      INSERT INTO public.cuenta (usuario_id, numero_cuenta, creado_en)
      VALUES (v_id, v_numero, v_ahora)
      RETURNING id INTO v_cuenta_id;
      v_ok := true;
      EXIT;
    EXCEPTION
      WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
        IF v_con <> 'uq_cuenta_numero' THEN
          RAISE EXCEPTION '%', public._msg_auth('invalido') USING ERRCODE = 'P0001';
        END IF;
      WHEN check_violation OR string_data_right_truncation OR not_null_violation THEN
        RAISE EXCEPTION '%', public._msg_auth('invalido') USING ERRCODE = 'P0001';
    END;
  END LOOP;
  IF NOT v_ok THEN
    RAISE EXCEPTION '%', public._msg_auth('agotado') USING ERRCODE = 'P0001';
  END IF;

  -- 10) Ingresos simulados. Fechas DISTINTAS, ASCENDENTES y dentro de la ventana POR CONSTRUCCIÓN (no por azar):
  --     la ventana [ahora - 90 días, ahora - 1 minuto] se divide en n estratos consecutivos y disjuntos de ancho entero en
  --     segundos; la fecha k cae dentro del estrato k. Después se autoverifica antes de escribir nada en el libro.
  SELECT p.ingresos_simulados_cantidad, p.ingreso_simulado_min, p.ingreso_simulado_max
    INTO v_n, v_min, v_max FROM public.parametro p WHERE p.id = 1;
  v_lo := ceil(v_min)::bigint;
  v_hi := floor(v_max)::bigint;
  IF v_n > 0 THEN
    v_ini   := v_ahora - make_interval(days => v_dias);
    v_total := v_dias::bigint * 86400 - v_margen;
    v_ancho := v_total / v_n;                                     -- división entera: estratos de ancho entero
    IF v_ancho < 1 OR v_hi < v_lo THEN
      RAISE EXCEPTION '%', public._msg_auth('invalido') USING ERRCODE = 'P0001';
    END IF;
    FOR v_k IN 0 .. v_n - 1 LOOP
      v_fechas := v_fechas || (v_ini + make_interval(secs => (v_k * v_ancho + floor(random() * v_ancho))::bigint));
    END LOOP;
    -- autoverificación defensiva (si el invariante se rompiera por un error de programación, todo se revierte)
    FOR v_k IN 1 .. v_n LOOP
      IF v_fechas[v_k] < v_ini OR v_fechas[v_k] > v_ahora - make_interval(secs => v_margen)
         OR (v_k > 1 AND v_fechas[v_k] <= v_fechas[v_k - 1]) THEN
        RAISE EXCEPTION '%', public._msg_auth('invalido') USING ERRCODE = 'P0001';
      END IF;
    END LOOP;
    -- Un grupo por ingreso, en orden ascendente de fecha, SOLO por _asentar_grupo
    FOR v_k IN 1 .. v_n LOOP
      v_monto := v_lo + floor(random() * (v_hi - v_lo + 1))::bigint;
      PERFORM public._asentar_grupo(v_fechas[v_k], jsonb_build_array(
        jsonb_build_object('tipo', 'INGRESO_SIMULADO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', v_monto, 'cuenta_id', v_cuenta_id,
                           'nota', 'Ingreso simulado', 'contraparte_nombre', 'Banco Digital'),
        jsonb_build_object('tipo', 'INGRESO_SIMULADO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', v_monto, 'cuenta_id', v_cuenta_id,
                           'nota', 'Ingreso simulado', 'contraparte_nombre', 'Banco Digital')));
    END LOOP;
  END IF;

  -- 11) Bono: con verificación APAGADA se paga al completar el registro (spec 7.1). NULL se trata como verificación ACTIVA
  --     (no se paga dinero por una entrada ambigua). D-E4-18 (PROVISIONAL): correoverificado queda en false (nunca se verificó).
  IF v_ref_id IS NOT NULL AND NOT coalesce(p_verificacion_activa, true) THEN
    PERFORM public._pagar_bono_referido(v_id, v_ahora);
  END IF;

  RETURN jsonb_build_object('usuario_id', v_id, 'username', v_username);
END
$$;
COMMENT ON FUNCTION public.registrar_usuario(text, text, text, text, text, text, text, boolean, text, boolean) IS
  'E4. Registra un CLIENTE: usuario (username inicial+apellido+3-4 dígitos), cuenta de 10 dígitos (prefijo 40), 5 INGRESO_SIMULADO por _asentar_grupo (fechas distintas y ascendentes en los 90 días previos a la instantánea, por construcción) y, con p_verificacion_activa=false, el bono del referidor. Fecha de nacimiento y código de referido llegan como TEXT (una entrada inválida es un error de negocio, no de driver). La contraseña llega ya como hash bcrypt (la BD rechaza otra cosa). Toma _reloj_instantanea UNA vez. Atómica. Devuelve {usuario_id, username}; el backend responde solo {username}. Reglas y mensajes provisionales en _reglas_registro()/_msg_auth().';

-- ----------------------------------------------------------------------------
-- obtener_credenciales / validar_sesion / vista_perfil / verificar_correo
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_credenciales(p_username text)
RETURNS TABLE (usuario_id uuid, password_hash text, rol text, estado text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT u.id, u.password_hash, u.rol::text, u.estado::text
    FROM public.usuario u
   WHERE u.username = lower(btrim(p_username))
$$;
COMMENT ON FUNCTION public.obtener_credenciales(text) IS
  'E4. Login paso 1: 0 filas si el usuario no existe (nunca lanza); si existe, usuario_id, password_hash, rol y estado (también del bloqueado: el backend compara bcrypt ANTES de llamar a validar_sesion, así el mensaje de bloqueo solo se ve con la clave correcta). La ÚNICA función que entrega el hash.';

CREATE OR REPLACE FUNCTION public.validar_sesion(p_usuario_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u public.usuario;
BEGIN
  SELECT * INTO u FROM public.usuario WHERE id = p_usuario_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END IF;
  IF u.estado = 'BLOQUEADO' THEN
    RAISE EXCEPTION '%', public._msg_auth('bloqueado') USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object('username', u.username, 'rol', u.rol::text, 'estado', u.estado::text);
END
$$;
COMMENT ON FUNCTION public.validar_sesion(uuid) IS
  'E4. Se llama en cada petición autenticada (GET /yo y el resto): lee el estado y el rol VIVOS; BLOQUEADO lanza el mensaje exacto del contrato; usuario inexistente lanza Sesión inválida (provisional D-E4-16). Devuelve {username, rol, estado}.';

CREATE OR REPLACE FUNCTION public.vista_perfil(p_usuario_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u        public.usuario;
  v_numero text;
BEGIN
  u := public._validar_cliente(p_usuario_id);
  SELECT c.numero_cuenta INTO v_numero FROM public.cuenta c WHERE c.usuario_id = u.id;
  RETURN jsonb_build_object('username', u.username, 'numero_cuenta', v_numero, 'codigo_referido', u.codigo_referido::text);
END
$$;
COMMENT ON FUNCTION public.vista_perfil(uuid) IS
  'E4. {username, numero_cuenta (10 dígitos), codigo_referido (uuid)}. Valida sesión, rol y bloqueo. DESVIACIÓN CONSCIENTE del contrato §1: NO ejecuta avanzar_hasta (no devuelve nada financiero ni dependiente del tiempo; aprobada por el responsable de BD).';

CREATE OR REPLACE FUNCTION public.verificar_correo(p_usuario_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u       public.usuario;
  v_ahora timestamptz;
BEGIN
  SELECT * INTO u FROM public.usuario WHERE id = p_usuario_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_auth('no_encontrado') USING ERRCODE = 'P0001';
  END IF;
  IF u.correoverificado THEN
    RETURN;                                                     -- idempotente: ya verificado, nada que hacer ni que pagar
  END IF;
  -- UNA sola instantánea; su ahora se pasa al bono
  SELECT i.ahora INTO v_ahora FROM public._reloj_instantanea() i;
  UPDATE public.usuario SET correoverificado = true WHERE id = p_usuario_id;
  PERFORM public._pagar_bono_referido(p_usuario_id, v_ahora);
END
$$;
COMMENT ON FUNCTION public.verificar_correo(uuid) IS
  'E4. Marca el correo como verificado y paga el bono de referido (si lo hay y no se pagó) con el ahora de UNA instantánea del reloj. Idempotente (una segunda llamada no hace nada y no paga otra vez); bloquea al usuario (FOR UPDATE) para que llamadas simultáneas paguen una sola vez. Inexistente: Recurso no encontrado.';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- Permisos: públicas -> solo banco_app (banco_dev las hereda); internas -> nadie salvo el dueño
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma, p.proname FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname = ANY (ARRAY['registrar_usuario', 'obtener_credenciales', 'validar_sesion', 'verificar_correo', 'vista_perfil',
                                  '_validar_cliente', '_validar_admin', '_pagar_bono_referido'])
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
    IF f.proname IN ('registrar_usuario', 'obtener_credenciales', 'validar_sesion', 'verificar_correo', 'vista_perfil') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO banco_app', f.firma);
    END IF;
  END LOOP;
END
$$;

COMMIT;
