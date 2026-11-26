-- ============================================================================
-- 15_transferencias.sql  ·  Etapa 5 (transferencias entre cuentas)
-- Propósito  : enviar dinero de una cuenta (o de un bolsillo) a otra cuenta, SOLO por _asentar_grupo (plantillas ENVIO_CUENTA / ENVIO_BOLSILLO de E2).
--
--   Públicas (EXECUTE solo banco_app; banco_dev por herencia):
--     nombre_destinatario(usuario, numero_cuenta)  -> jsonb {nombre}           exige sesión viva (D-E5-10, provisional: lo coordina Juan)
--     hacer_transferencia(usuario, numero_destino, monto, nota, bolsillo_origen) -> jsonb {id, fecha}
--   Internas (sin EXECUTE para nadie salvo el dueño; las reutilizarán E6-E9):
--     _validar_monto(numeric)  'Monto inválido' si es NULL, NaN, infinito, <= 0, con más de 2 decimales o mayor que parametro.monto_maximo
--     _msg_negocio(clave)      mensajes de negocio compartidos (contrato §6 exactos; 'nota' provisional hasta D13)
--     _reglas_transferencia()  valores provisionales centralizados (D-E5-8: longitud máxima de la nota)
--
-- Orden de validación (D-E5-2): sesión -> monto -> destino -> autoenvío -> bolsillo -> nota -> [instantánea del reloj] -> libro (saldo).
-- Una sola _reloj_instantanea() por transferencia; ambas patas con el mismo ahora, grupo y tx. Las carreras (destino o bolsillo borrados
-- mientras la operación espera) las detecta el libro, se revierten por completo y se traducen a su mensaje de negocio.
-- E7 (D-E7-4): el devengo previo del emisor (_avanzar_hasta, 17) se integra tras la instantánea, con ambas cuentas ya bloqueadas en orden de id.
-- D-E5-9 (PROVISIONAL, negocio pendiente): se puede enviar a una cuenta BLOQUEADA (bloquear restringe al titular, no la recepción).
-- Dependencias : 00 a 14.   Ejecución: como superusuario, IDEMPOTENTE, transaccional.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- Helpers internos
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._msg_negocio(p_clave text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
BEGIN
  RETURN CASE p_clave
    -- contrato §6 (exactos)
    WHEN 'monto'      THEN 'Monto inválido'
    WHEN 'destino'    THEN 'Cuenta no encontrada'
    WHEN 'a_si_mismo' THEN 'No puedes enviarte dinero a ti mismo'
    WHEN 'saldo'      THEN 'Saldo insuficiente'
    WHEN 'recurso'    THEN 'Recurso no encontrado'
    -- PROVISIONAL (D-E5-8 / D13)
    WHEN 'nota'       THEN 'Nota inválida'
    ELSE NULL
  END;
END
$$;
COMMENT ON FUNCTION public._msg_negocio(text) IS
  'E5. PURA. Mensajes de negocio compartidos por las funciones de cliente: monto, destino, a_si_mismo, saldo y recurso son los EXACTOS del contrato §6; nota es provisional (D-E5-8, D13). Clave desconocida: NULL.';

CREATE OR REPLACE FUNCTION public._reglas_transferencia()
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('nota_max', 140)        -- D-E5-8 (PROVISIONAL, equipo): longitud máxima de la nota
$$;
COMMENT ON FUNCTION public._reglas_transferencia() IS
  'E5. PURA. Valores provisionales de las transferencias en UN solo lugar (D-E5-8: nota_max = 140).';

CREATE OR REPLACE FUNCTION public._validar_monto(p_monto numeric)
RETURNS numeric LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_max numeric;
BEGIN
  SELECT p.monto_maximo INTO v_max FROM public.parametro p WHERE p.id = 1;
  IF p_monto IS NULL OR p_monto = 'NaN'::numeric OR p_monto IN ('Infinity'::numeric, '-Infinity'::numeric)
     OR p_monto <= 0 OR scale(p_monto) > 2 OR p_monto > v_max THEN
    RAISE EXCEPTION '%', public._msg_negocio('monto') USING ERRCODE = 'P0001';
  END IF;
  RETURN p_monto;
END
$$;
COMMENT ON FUNCTION public._validar_monto(numeric) IS
  'E5. Devuelve el monto si es válido; si no, "Monto inválido" (P0001): NULL, NaN, infinito, <= 0, más de 2 decimales o mayor que parametro.monto_maximo. Reutilizable por E6-E9.';

-- ----------------------------------------------------------------------------
-- nombre_destinatario: «¿Envías a <nombre>?» (exige sesión viva: sin enumeración anónima)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.nombre_destinatario(p_usuario_id uuid, p_numero_cuenta text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u        public.usuario;
  v_num    text;
  v_nombre text;
BEGIN
  u := public._validar_cliente(p_usuario_id);
  v_num := public._norm_digitos(p_numero_cuenta, false);
  IF v_num IS NULL OR v_num !~ '^[0-9]{10}$' THEN
    RAISE EXCEPTION '%', public._msg_negocio('destino') USING ERRCODE = 'P0001';
  END IF;
  SELECT us.nombres || ' ' || us.apellidos INTO v_nombre
    FROM public.cuenta c JOIN public.usuario us ON us.id = c.usuario_id WHERE c.numero_cuenta = v_num;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('destino') USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object('nombre', v_nombre);
END
$$;
COMMENT ON FUNCTION public.nombre_destinatario(uuid, text) IS
  'E5. {nombre} = nombres + apellidos del dueño de la cuenta (10 dígitos; admite espacios y puntos). Cuenta inexistente o mal formada: "Cuenta no encontrada". Exige sesión viva (D-E5-10, PROVISIONAL: el contrato no lleva p_usuario_id; lo coordina Juan). No consulta el reloj ni el libro.';

-- ----------------------------------------------------------------------------
-- hacer_transferencia
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hacer_transferencia(
  p_usuario_id uuid, p_numero_destino text, p_monto numeric, p_nota text, p_bolsillo_origen text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u          public.usuario;
  v_monto    numeric;
  v_num      text;
  v_dest_id  uuid;
  v_dest_num text;
  v_dest_nom text;
  v_orig_id  uuid;
  v_orig_num text;
  v_bol_txt  text;
  v_bol      uuid;
  v_nota     text;
  v_hoy      date;
  v_ahora    timestamptz;
  v_grupo    uuid;
  v_msg      text;
BEGIN
  -- 1) sesión viva: CLIENTE y no bloqueado (E4)
  u := public._validar_cliente(p_usuario_id);
  -- 2) monto (antes que el destino: un monto malformado no sirve para sondear números de cuenta)
  v_monto := public._validar_monto(p_monto);
  -- 3) destino
  v_num := public._norm_digitos(p_numero_destino, false);
  IF v_num IS NULL OR v_num !~ '^[0-9]{10}$' THEN
    RAISE EXCEPTION '%', public._msg_negocio('destino') USING ERRCODE = 'P0001';
  END IF;
  -- D-E5-9 (PROVISIONAL, negocio pendiente): no se mira el estado del destino: una cuenta BLOQUEADA puede recibir dinero. Único punto de cambio.
  SELECT c.id, c.numero_cuenta, us.nombres || ' ' || us.apellidos INTO v_dest_id, v_dest_num, v_dest_nom
    FROM public.cuenta c JOIN public.usuario us ON us.id = c.usuario_id WHERE c.numero_cuenta = v_num;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('destino') USING ERRCODE = 'P0001';
  END IF;
  -- 4) autoenvío
  SELECT c.id, c.numero_cuenta INTO v_orig_id, v_orig_num FROM public.cuenta c WHERE c.usuario_id = u.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  IF v_dest_id = v_orig_id THEN
    RAISE EXCEPTION '%', public._msg_negocio('a_si_mismo') USING ERRCODE = 'P0001';
  END IF;
  -- 5) bolsillo de origen (texto: un uuid mal formado es un error de negocio, no de driver); vacío = cuenta principal
  v_bol_txt := nullif(btrim(coalesce(p_bolsillo_origen, '')), '');
  IF v_bol_txt IS NOT NULL THEN
    IF v_bol_txt !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
    END IF;
    SELECT b.id INTO v_bol FROM public.bolsillo b WHERE b.id = v_bol_txt::uuid AND b.cuenta_id = v_orig_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
    END IF;
  END IF;
  -- 6) nota
  v_nota := nullif(public._norm_texto(p_nota), '');
  IF length(v_nota) > (public._reglas_transferencia() ->> 'nota_max')::int THEN
    RAISE EXCEPTION '%', public._msg_negocio('nota') USING ERRCODE = 'P0001';         -- D-E5-8 (PROVISIONAL)
  END IF;

  -- 7) UNA sola instantánea del reloj; su ahora fecha ambas patas y el (hoy, ahora) viaja al motor de devengo (E7)
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;

  -- 7b) (E7) bloqueo ORDENADO de ambas cuentas (orden de id) ANTES de devengar: devengar primero solo la del emisor rompería el orden del libro
  --     y A->B || B->A haría deadlock. Después, devengo previo del ORIGEN (bolsillos y CDT) bajo ese mismo bloqueo, que conserva el libro.
  IF public._bloquear_cuentas(ARRAY[v_orig_id, v_dest_id]) <> 2 THEN
    IF NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = v_orig_id) THEN
      RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';          -- el propio emisor fue borrado (borrado en cascada por el admin)
    END IF;
    RAISE EXCEPTION '%', public._msg_negocio('destino') USING ERRCODE = 'P0001';          -- el destino fue borrado
  END IF;
  PERFORM public._avanzar_hasta(v_orig_id, v_hoy, v_ahora);

  -- 8) el libro hace TODO: bloquea ambas cuentas en orden de id, aplica los saldos y verifica cuadre y saldo suficiente
  BEGIN
    v_grupo := public._asentar_grupo(v_ahora, jsonb_build_array(
      jsonb_strip_nulls(jsonb_build_object('tipo', 'ENVIO', 'contenedor', CASE WHEN v_bol IS NULL THEN 'CUENTA' ELSE 'BOLSILLO' END, 'sentido', 'S',
                        'monto', v_monto, 'cuenta_id', v_orig_id, 'bolsillo_id', v_bol, 'nota', v_nota,
                        'contraparte_nombre', v_dest_nom, 'contraparte_cuenta', v_dest_num)),
      jsonb_strip_nulls(jsonb_build_object('tipo', 'RECIBO', 'contenedor', 'CUENTA', 'sentido', 'E',
                        'monto', v_monto, 'cuenta_id', v_dest_id, 'nota', v_nota,
                        'contraparte_nombre', u.nombres || ' ' || u.apellidos, 'contraparte_cuenta', v_orig_num))));
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    -- Carreras: el destino o el bolsillo se borraron entre la validación y el bloqueo. Todo se revierte (sub-bloque) y se traduce.
    IF v_msg LIKE 'Libro mayor:%' THEN
      IF NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = v_orig_id) THEN
        RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';        -- el propio emisor fue borrado (borrado en cascada por el admin)
      ELSIF NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = v_dest_id) THEN
        RAISE EXCEPTION '%', public._msg_negocio('destino') USING ERRCODE = 'P0001';
      ELSIF v_bol IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.bolsillo b WHERE b.id = v_bol) THEN
        RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
      END IF;
    END IF;
    RAISE;                                                       -- cualquier otro (p. ej. Saldo insuficiente) pasa tal cual
  END;
  RETURN jsonb_build_object('id', v_grupo, 'fecha', v_ahora);
END
$$;
COMMENT ON FUNCTION public.hacer_transferencia(uuid, text, numeric, text, text) IS
  'E5. Envía p_monto de la cuenta principal (o del bolsillo p_bolsillo_origen, texto uuid, vacío = principal) a la cuenta p_numero_destino. Orden: sesión, monto, destino, autoenvío, bolsillo, nota. Solo _asentar_grupo (ENVIO + RECIBO con nota y contrapartes cruzadas, mismo grupo y fecha); UNA _reloj_instantanea(). E7: tras la instantánea bloquea AMBAS cuentas en orden de id (_bloquear_cuentas) y devenga el origen (_avanzar_hasta) antes del libro, para que el saldo (y los bolsillos) ya incluyan intereses y CDT vencidos. Atómica; carreras por destino o bolsillo borrados se traducen a Cuenta no encontrada / Recurso no encontrado. Devuelve {id, fecha}. El backend debe pasar el monto como texto. D-E5-9: una cuenta bloqueada puede recibir (provisional). Sin límites, comisiones ni idempotencia (no están en el contrato).';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- Permisos: las 2 públicas -> banco_app (banco_dev las hereda); los helpers -> nadie salvo el dueño
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma, p.proname FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('nombre_destinatario', 'hacer_transferencia', '_msg_negocio', '_reglas_transferencia', '_validar_monto')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
    IF f.proname IN ('nombre_destinatario', 'hacer_transferencia') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO banco_app', f.firma);
    END IF;
  END LOOP;
END
$$;

COMMIT;
