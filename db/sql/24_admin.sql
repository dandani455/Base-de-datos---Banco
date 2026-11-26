-- ============================================================================
-- 24_admin.sql  ·  Etapa 11 (administración: usuarios, ajuste de balance, reloj y tasas)
-- Propósito  : las 12 funciones /admin/* del contrato (excepto el visor de tablas, que es E12) y sus 4 helpers. Todo el dinero se mueve SOLO por
--              _asentar_grupo (plantillas AJUSTE_ADMIN_POS / AJUSTE_ADMIN_NEG de E2); toda acción que cambia algo queda en audit.evento.
--
--   Públicas (EXECUTE solo banco_app; banco_dev por herencia). p_admin_id es SIEMPRE el primer parámetro:
--     admin_listar_usuarios(admin, busqueda = NULL)                    -> jsonb [{id, username, nombre, cedula, correo, numero_cuenta, estado}]   (solo CLIENTES)
--     admin_detalle_usuario(admin, usuario_id text)                    -> jsonb {..., balance{total, principal, bolsillos, cdts, creditos}, historial[<=50]}
--     admin_bloquear(admin, usuario_id text) / admin_desbloquear(...)  -> jsonb {id, estado}
--     admin_borrar_usuario(admin, usuario_id text)                     -> jsonb {id, borrado}                 (cascada de E1; CUENTA_BORRADA conserva los saldos)
--     admin_ajustar_balance(admin, usuario text, monto, nota = NULL)   -> jsonb {id, monto, fecha}            (monto con signo; uuid, username o número de cuenta)
--     admin_get_reloj(admin) / admin_set_reloj(admin, usar, fecha)     -> jsonb {usar_fecha_real, fecha_sistema, fecha_actual}   (envuelven _reloj_vista / _reloj_actualizar de E3)
--     admin_get_tasas(admin)                                           -> jsonb {cdts[{id, nombre, tasa}], creditos[{id, nombre, tasa}], mora}
--     admin_set_tasa_cdt(admin, definicion_id text, tasa text)         -> jsonb {id, tasa}
--     admin_set_tasa_credito(admin, producto_id text, tasa text)       -> jsonb {id, tasa}
--     admin_set_tasa_mora(admin, tasa text)                            -> jsonb {mora}
--   Internas (sin EXECUTE para nadie salvo el dueño):
--     _reglas_admin()                       valores y mensajes PROVISIONALES centralizados (tope de la lista, nota, tasas; D13 'Tasa inválida')
--     _parse_tasa(texto, permite_cero)      ÚNICA validación de una tasa que llega como texto (0 < t <= 100, <= 3 decimales)
--     _cliente_objetivo(texto, por_ref)     el CLIENTE al que apunta un id (o username / número de cuenta), o 'Recurso no encontrado'
--     _auditar_admin(admin, accion, ...)    ÚNICO escritor de los eventos admin en audit.evento (y fija banco.actor para los 2 disparadores de E2/E3)
--
-- Reglas: _validar_admin PRIMERO (antes de leer nada); las acciones solo alcanzan a CLIENTES (un ADMIN, uno mismo o un id mal formado = Recurso no encontrado:
-- así las protecciones de D12a quedan cubiertas por construcción); una llamada = una sentencia = una transacción: acción y evento entran juntos o no entran.
-- Las que leen o mueven saldos (detalle, ajuste) toman UNA instantánea del reloj y devengan ANTES; las otras 10 no tocan saldos de bolsillos/CDT.
-- Tasas: se parsean como TEXTO (el front las manda como string) y un id mal formado es de negocio, no un error de driver; las 3 se serializan con un
-- advisory lock de transacción (la atomicidad de UN formulario completo la da la transacción del backend: db.tx).
-- PROVISIONAL (equipo): D-E11-D7a (la mora sin valor se lee 0 y guardar 0 = sin mora, centralizado en _parse_tasa y admin_get_tasas), D13 (mensaje 'Tasa inválida'),
--   D10 (firmas). D-E11-D7b (efecto retroactivo del cambio de la tasa de mora sobre la mora ya vencida, que E9 DERIVA) NO está decidido y E11 no añade lógica sobre él.
-- Dependencias : 00 a 23.   Ejecución: como superusuario, IDEMPOTENTE, transaccional. NO modifica ningún objeto de E1-E10.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- Helpers internos
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reglas_admin()
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'lista_max',       200,                    -- contrato §3.6: «límite razonable, p. ej. 200» (PROVISIONAL)
    'historial_max',   50,                     -- contrato §3.6: «historial: últimas 50»
    'nota_max',        140,                    -- misma longitud que la nota de una transferencia (D-E5-8, PROVISIONAL)
    'tasa_max',        100,                    -- dominio porcentaje: 0 < tasa <= 100
    'tasa_decimales',  3,                      -- dominio porcentaje: NUMERIC(6,3)
    'msg_tasa',        'Tasa inválida')        -- D13 (PROVISIONAL): el contrato no trae mensaje; el mock del front usa este
$$;
COMMENT ON FUNCTION public._reglas_admin() IS
  'E11. PURA. Valores y mensajes PROVISIONALES de la administración en UN solo lugar: lista_max 200 (tope de admin_listar_usuarios), historial_max 50 (detalle), nota_max 140 (como E5), tasa_max 100 y tasa_decimales 3 (dominio porcentaje) y msg_tasa = "Tasa inválida" (D13). El mensaje vive aquí y no en _msg_negocio porque esa función es de E5 y E5 no se modifica.';

CREATE OR REPLACE FUNCTION public._parse_tasa(p_texto text, p_permite_cero boolean)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_txt text := btrim(coalesce(p_texto, ''));
  v_num numeric;
BEGIN
  -- solo dígitos con punto decimal opcional (sin signo, exponente, comas ni espacios internos): lo que el front manda como String(number)
  IF v_txt !~ '^[0-9]{1,3}([.][0-9]{1,8})?$' THEN
    RAISE EXCEPTION '%', (public._reglas_admin() ->> 'msg_tasa') USING ERRCODE = 'P0001';
  END IF;
  v_num := trim_scale(v_txt::numeric);                     -- «12.5000» == 12.5: los ceros a la derecha no son información
  IF scale(v_num) > (public._reglas_admin() ->> 'tasa_decimales')::int
     OR v_num > (public._reglas_admin() ->> 'tasa_max')::numeric
     OR v_num < 0 OR (v_num = 0 AND NOT coalesce(p_permite_cero, false)) THEN
    RAISE EXCEPTION '%', (public._reglas_admin() ->> 'msg_tasa') USING ERRCODE = 'P0001';
  END IF;
  RETURN v_num;
END
$$;
COMMENT ON FUNCTION public._parse_tasa(text, boolean) IS
  'E11. Interna. ÚNICA validación de una tasa que llega como TEXTO ("12.5"): solo dígitos y punto, 0 < tasa <= 100 con hasta 3 decimales (los ceros a la derecha no cuentan); si no, "Tasa inválida" (P0001, nunca un error de driver). p_permite_cero = true solo para la mora (D-E11-D7a, PROVISIONAL: 0 = "sin mora"; el llamador lo guarda como NULL). Devuelve numeric(6,3)-compatible.';

CREATE OR REPLACE FUNCTION public._cliente_objetivo(p_ref text, p_por_referencia boolean)
RETURNS public.usuario LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_ref text := nullif(btrim(coalesce(p_ref, '')), '');
  u     public.usuario;
BEGIN
  -- texto (no uuid): un id mal formado sería un error de driver (503 en el backend); aquí es de negocio. Solo CLIENTES: un ADMIN (uno mismo incluido)
  -- es indistinguible de un id inexistente.
  IF v_ref IS NOT NULL AND v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    SELECT us.* INTO u FROM public.usuario us WHERE us.id = v_ref::uuid AND us.rol = 'CLIENTE';
  ELSIF v_ref IS NOT NULL AND coalesce(p_por_referencia, false) THEN
    -- el front no muestra el uuid: el ajuste acepta también username o número de cuenta (README del backend, C16)
    SELECT us.* INTO u FROM public.usuario us
     WHERE us.rol = 'CLIENTE'
       AND (us.username = lower(v_ref)
            OR (v_ref ~ '^[0-9]{10}$' AND EXISTS (SELECT 1 FROM public.cuenta c WHERE c.usuario_id = us.id AND c.numero_cuenta = v_ref)))
     ORDER BY us.id LIMIT 1;
  END IF;
  IF u.id IS NULL THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  RETURN u;
END
$$;
COMMENT ON FUNCTION public._cliente_objetivo(text, boolean) IS
  'E11. Interna. El CLIENTE al que apunta p_ref: un uuid (texto) o, si p_por_referencia, un username o un número de cuenta de 10 dígitos. Cualquier otra cosa (mal formado, inexistente, un ADMIN) = "Recurso no encontrado", sin distinguir los casos. Lee el estado vivo, sin bloquear.';

CREATE OR REPLACE FUNCTION public._auditar_admin(p_admin public.usuario, p_accion text, p_entidad text, p_entidad_id text, p_antes jsonb, p_despues jsonb)
RETURNS void LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  -- atribución para los 2 disparadores de auditoría de E2/E3 (CUENTA_BORRADA, RELOJ_CAMBIO): solo atribución, NO es control de seguridad
  PERFORM set_config('banco.actor', p_admin.username, true);
  INSERT INTO audit.evento (actor_id, actor_username, accion, entidad, entidad_id, antes, despues)
  VALUES (p_admin.id, p_admin.username, p_accion, p_entidad, p_entidad_id, p_antes, p_despues);
END
$$;
COMMENT ON FUNCTION public._auditar_admin(public.usuario, text, text, text, jsonb, jsonb) IS
  'E11. Interna. ÚNICO escritor de los eventos de administración en audit.evento (actor = el admin, snapshot de su username) y fija banco.actor (solo para esta transacción) para que CUENTA_BORRADA y RELOJ_CAMBIO queden atribuidos al admin. Atómico con la acción: si ésta falla no queda evento. Los eventos no son un control de seguridad.';

-- ----------------------------------------------------------------------------
-- admin_listar_usuarios: GET /admin/usuarios?busqueda=
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_listar_usuarios(p_admin_id uuid, p_busqueda text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_q   text;
  v_pat text;
  r     jsonb;
BEGIN
  PERFORM public._validar_admin(p_admin_id);                    -- ANTES de leer nada
  v_q := btrim(coalesce(p_busqueda, ''));
  IF v_q <> '' THEN
    -- los comodines que escribe el usuario (% _ \) se toman LITERALES; sin tildes ni mayúsculas
    v_pat := '%' || replace(replace(replace(v_q, chr(92), chr(92) || chr(92)), '%', chr(92) || '%'), '_', chr(92) || '_') || '%';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'username', x.username, 'nombre', x.nombre, 'cedula', x.cedula, 'correo', x.correo,
                                               'numero_cuenta', x.numero_cuenta, 'estado', x.estado) ORDER BY x.nombres, x.apellidos, x.id), '[]'::jsonb)
    INTO r
    FROM (SELECT us.id, us.username, us.nombres, us.apellidos, us.nombres || ' ' || us.apellidos AS nombre, us.cedula, us.correo,
                 c.numero_cuenta, us.estado::text AS estado
            FROM public.usuario us JOIN public.cuenta c ON c.usuario_id = us.id
           WHERE us.rol = 'CLIENTE'
             AND (v_q = '' OR public.unaccent(us.nombres || ' ' || us.apellidos) ILIKE public.unaccent(v_pat)
                           OR public.unaccent(us.cedula)        ILIKE public.unaccent(v_pat)
                           OR public.unaccent(us.correo)        ILIKE public.unaccent(v_pat)
                           OR c.numero_cuenta                   ILIKE v_pat)
           ORDER BY us.nombres, us.apellidos, us.id
           LIMIT (public._reglas_admin() ->> 'lista_max')::int) x;
  RETURN r;
END
$$;
COMMENT ON FUNCTION public.admin_listar_usuarios(uuid, text) IS
  'E11. GET /admin/usuarios?busqueda=. [{id, username, nombre (nombres + apellidos), cedula, correo, numero_cuenta, estado}] SOLO de CLIENTES (un ADMIN no tiene cuenta), ordenados por nombre y limitados a 200. p_busqueda NULL o vacío = todos; si no, ILIKE sin tildes por nombre, cédula, correo o número de cuenta, con los comodines del usuario tomados literales. [] si no hay. No devuelve password_hash. No toca saldos de bolsillos ni CDT: no corre el motor de devengo.';

-- ----------------------------------------------------------------------------
-- admin_detalle_usuario: GET /admin/usuarios/:id
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_detalle_usuario(p_admin_id uuid, p_usuario_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp SET TimeZone = 'America/Bogota' AS $$
DECLARE
  t       public.usuario;
  v_cta   uuid;
  v_hoy   date;
  v_ahora timestamptz;
  r       jsonb;
BEGIN
  PERFORM public._validar_admin(p_admin_id);                    -- ANTES de leer nada
  t := public._cliente_objetivo(p_usuario_id, false);
  SELECT c.id INTO v_cta FROM public.cuenta c WHERE c.usuario_id = t.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  -- el detalle muestra saldos: igual que las funciones de cliente, UNA instantánea y devengo/cobro ANTES de leer (semántica perezosa de todo el banco)
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);
  -- UNA sola sentencia = UNA sola foto: total, principal, productos e historial nunca se ven a medias de un movimiento concurrente
  SELECT jsonb_build_object(
           'id', us.id, 'username', us.username, 'nombre', us.nombres || ' ' || us.apellidos, 'cedula', us.cedula, 'correo', us.correo,
           'numero_cuenta', c.numero_cuenta, 'estado', us.estado::text,
           'balance', jsonb_build_object(
             'total',     public.balance_total(c.id),
             'principal', c.balance,
             'bolsillos', coalesce((SELECT jsonb_agg(jsonb_build_object('id', b.id, 'nombre', b.nombre, 'saldo', b.balance) ORDER BY b.creado_en, b.id)
                                      FROM public.bolsillo b WHERE b.cuenta_id = c.id), '[]'::jsonb),
             'cdts',      coalesce((SELECT jsonb_agg(jsonb_build_object('id', d.id, 'monto', d.monto) ORDER BY d.fecha_inicio, d.id)
                                      FROM public.cdt d WHERE d.cuenta_id = c.id AND d.estado = 'ACTIVO'), '[]'::jsonb),
             'creditos',  coalesce((SELECT jsonb_agg(jsonb_build_object('id', k.id, 'producto', pr.nombre, 'saldo', k.capital_pendiente) ORDER BY k.fecha_desembolso, k.id)
                                      FROM public.credito k JOIN public.credito_producto pr ON pr.id = k.producto_id
                                     WHERE k.cuenta_id = c.id AND k.estado = 'ACTIVO'), '[]'::jsonb)),
           'historial', public._json_transacciones(c.id, (public._reglas_admin() ->> 'historial_max')::int))
    INTO r
    FROM public.cuenta c JOIN public.usuario us ON us.id = c.usuario_id
   WHERE c.id = v_cta;
  IF r IS NULL THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';       -- el usuario fue borrado durante la operación
  END IF;
  RETURN r;
END
$$;
COMMENT ON FUNCTION public.admin_detalle_usuario(uuid, text) IS
  'E11. GET /admin/usuarios/:id. {id, username, nombre, cedula, correo, numero_cuenta, estado, balance {total (= balance_total(): D6 sigue PROVISIONAL), principal, bolsillos [{id, nombre, saldo}], cdts [{id, monto}] solo ACTIVOS, creditos [{id, producto, saldo}] solo ACTIVOS}, historial (las últimas 50 de _json_transacciones)}. p_usuario_id es TEXTO: un id mal formado, inexistente o de un ADMIN = "Recurso no encontrado". Orden: admin, objetivo, UNA instantánea del reloj, devengo/cobro de la cuenta consultada (consultar a un usuario puede cobrarle una cuota automática o cerrar su CDT, como cualquier lectura de saldos) y una sola sentencia. Nunca expone password_hash.';

-- ----------------------------------------------------------------------------
-- admin_bloquear / admin_desbloquear
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_bloquear(p_admin_id uuid, p_usuario_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  adm     public.usuario;
  t       public.usuario;
  v_antes text;
BEGIN
  adm := public._validar_admin(p_admin_id);
  t   := public._cliente_objetivo(p_usuario_id, false);
  -- relee y bloquea la fila: dos admins sobre el mismo usuario se serializan y el evento refleja el estado real
  SELECT us.estado::text INTO v_antes FROM public.usuario us WHERE us.id = t.id AND us.rol = 'CLIENTE' FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';       -- borrado entre la lectura y el bloqueo
  END IF;
  IF v_antes <> 'BLOQUEADO' THEN                                                        -- idempotente: sin cambio no hay UPDATE ni evento
    UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = t.id;
    PERFORM public._auditar_admin(adm, 'USUARIO_BLOQUEADO', 'usuario', t.id::text,
                                  jsonb_build_object('estado', v_antes, 'username', t.username),
                                  jsonb_build_object('estado', 'BLOQUEADO', 'username', t.username));
  END IF;
  RETURN jsonb_build_object('id', t.id, 'estado', 'BLOQUEADO');
END
$$;
COMMENT ON FUNCTION public.admin_bloquear(uuid, text) IS
  'E11. POST /admin/usuarios/:id/bloquear. {id, estado: BLOQUEADO}. Solo CLIENTES (un ADMIN, uno mismo o un id inválido = "Recurso no encontrado"). Bloquea la fila del usuario (dos admins se serializan). Idempotente: si ya estaba bloqueado no hay UPDATE ni evento. Rige desde la SIGUIENTE petición del usuario (validar_sesion relee el estado). Recibir dinero estando bloqueado sigue siendo posible (D-E5-9, equipo). Evento USUARIO_BLOQUEADO con el estado anterior.';

CREATE OR REPLACE FUNCTION public.admin_desbloquear(p_admin_id uuid, p_usuario_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  adm     public.usuario;
  t       public.usuario;
  v_antes text;
BEGIN
  adm := public._validar_admin(p_admin_id);
  t   := public._cliente_objetivo(p_usuario_id, false);
  -- relee y bloquea la fila: dos admins sobre el mismo usuario se serializan y el evento refleja el estado real
  SELECT us.estado::text INTO v_antes FROM public.usuario us WHERE us.id = t.id AND us.rol = 'CLIENTE' FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';       -- borrado entre la lectura y el bloqueo
  END IF;
  IF v_antes <> 'ACTIVO' THEN                                                        -- idempotente: sin cambio no hay UPDATE ni evento
    UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = t.id;
    PERFORM public._auditar_admin(adm, 'USUARIO_DESBLOQUEADO', 'usuario', t.id::text,
                                  jsonb_build_object('estado', v_antes, 'username', t.username),
                                  jsonb_build_object('estado', 'ACTIVO', 'username', t.username));
  END IF;
  RETURN jsonb_build_object('id', t.id, 'estado', 'ACTIVO');
END
$$;
COMMENT ON FUNCTION public.admin_desbloquear(uuid, text) IS
  'E11. POST /admin/usuarios/:id/desbloquear. {id, estado: ACTIVO}. Igual que admin_bloquear en sentido contrario. Evento USUARIO_DESBLOQUEADO.';

-- ----------------------------------------------------------------------------
-- admin_borrar_usuario: DELETE /admin/usuarios/:id
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_borrar_usuario(p_admin_id uuid, p_usuario_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  adm   public.usuario;
  t     public.usuario;
  v_num text;
BEGIN
  adm := public._validar_admin(p_admin_id);
  t   := public._cliente_objetivo(p_usuario_id, false);
  -- 1) bloqueo de la cuenta objetivo (el mismo FOR NO KEY UPDATE del libro): espera a las operaciones en vuelo; las que lleguen después fallan limpias
  SELECT c.numero_cuenta INTO v_num FROM public.cuenta c WHERE c.usuario_id = t.id;
  PERFORM public._bloquear_cuentas(ARRAY(SELECT c.id FROM public.cuenta c WHERE c.usuario_id = t.id));
  -- 2) evento ANTES del borrado (misma transacción; fija banco.actor para que el CUENTA_BORRADA de E2 también quede atribuido al admin)
  PERFORM public._auditar_admin(adm, 'USUARIO_BORRADO', 'usuario', t.id::text,
                                jsonb_build_object('username', t.username, 'estado', t.estado::text, 'numero_cuenta', v_num), NULL);
  -- 3) cascada de E1: cuenta, bolsillos, CDT, créditos, cuotas y libro; los referidos quedan con referido_por NULL. La contraparte de los demás es texto.
  DELETE FROM public.usuario WHERE id = t.id AND rol = 'CLIENTE';
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';       -- otro admin lo borró primero: se revierte también este evento
  END IF;
  RETURN jsonb_build_object('id', t.id, 'borrado', true);
END
$$;
COMMENT ON FUNCTION public.admin_borrar_usuario(uuid, text) IS
  'E11. DELETE /admin/usuarios/:id. {id, borrado: true}. Solo CLIENTES. Bloquea la cuenta, escribe USUARIO_BORRADO (username, estado, número de cuenta) y borra al usuario con la cascada de E1 (productos y libro; el trigger de E2 deja CUENTA_BORRADA con los saldos y la deuda que se destruyen, atribuido al admin); los referidos quedan con referido_por NULL. El historial de terceros conserva "Nombre · cuenta" (la contraparte es texto al insertar: nada que reescribir). Una operación del usuario en vuelo recibe "Sesión inválida". No reversible.';

-- ----------------------------------------------------------------------------
-- admin_ajustar_balance: POST /admin/balance
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_ajustar_balance(p_admin_id uuid, p_usuario_id text, p_monto numeric, p_nota text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp SET TimeZone = 'America/Bogota' AS $$
DECLARE
  adm      public.usuario;
  t        public.usuario;
  v_cta    uuid;
  v_nota   text;
  v_hoy    date;
  v_ahora  timestamptz;
  v_antes  numeric;
  v_despues numeric;
  v_grupo  uuid;
  v_msg    text;
BEGIN
  -- 1) admin; 2) monto (con signo: 0, NaN, infinito, más de 2 decimales o mayor que monto_maximo = Monto inválido)
  adm := public._validar_admin(p_admin_id);
  PERFORM public._validar_monto(abs(p_monto));
  -- 3) objetivo (uuid, username o número de cuenta)
  t := public._cliente_objetivo(p_usuario_id, true);
  SELECT c.id INTO v_cta FROM public.cuenta c WHERE c.usuario_id = t.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  -- 4) nota (vacía = sin nota)
  v_nota := nullif(public._norm_texto(p_nota), '');
  IF length(v_nota) > (public._reglas_admin() ->> 'nota_max')::int THEN
    RAISE EXCEPTION '%', public._msg_negocio('nota') USING ERRCODE = 'P0001';
  END IF;

  -- 5) UNA sola instantánea del reloj; (hoy, ahora) viaja al devengo y fecha ambas patas
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  -- 5b) bloqueo de la cuenta (cero filas = fue borrada) y devengo/cobro ANTES: el saldo ya incluye intereses, CDT vencidos y cuotas automáticas
  IF public._bloquear_cuentas(ARRAY[v_cta]) <> 1 THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);
  SELECT c.balance INTO v_antes FROM public.cuenta c WHERE c.id = v_cta;

  -- 6) el libro hace TODO (plantilla AJUSTE_ADMIN_POS o _NEG): cuadre, tope y saldo >= 0 (un ajuste negativo que dejaría la cuenta bajo cero = Saldo insuficiente)
  BEGIN
    v_grupo := public._asentar_grupo(v_ahora, jsonb_build_array(
      jsonb_strip_nulls(jsonb_build_object('tipo', 'AJUSTE_ADMIN', 'contenedor', 'CUENTA', 'sentido', CASE WHEN p_monto > 0 THEN 'E' ELSE 'S' END,
                        'monto', abs(p_monto), 'cuenta_id', v_cta, 'nota', v_nota, 'contraparte_nombre', 'Banco Digital')),
      jsonb_strip_nulls(jsonb_build_object('tipo', 'AJUSTE_ADMIN', 'contenedor', 'RESULTADO', 'sentido', CASE WHEN p_monto > 0 THEN 'E' ELSE 'S' END,
                        'monto', abs(p_monto), 'cuenta_id', v_cta, 'nota', v_nota, 'contraparte_nombre', 'Banco Digital'))));
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'Libro mayor:%' AND NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = v_cta) THEN
      RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';   -- carrera: el usuario fue borrado
    END IF;
    RAISE;                                                                            -- cualquier otro (p. ej. Saldo insuficiente) pasa tal cual
  END;
  SELECT c.balance INTO v_despues FROM public.cuenta c WHERE c.id = v_cta;

  PERFORM public._auditar_admin(adm, 'AJUSTE_ADMIN', 'cuenta', v_cta::text,
                                jsonb_build_object('balance', v_antes),
                                jsonb_build_object('balance', v_despues, 'monto', p_monto, 'nota', v_nota, 'grupo_id', v_grupo,
                                                   'usuario_id', t.id, 'username', t.username));
  RETURN jsonb_build_object('id', v_grupo, 'monto', p_monto, 'fecha', v_ahora);
END
$$;
COMMENT ON FUNCTION public.admin_ajustar_balance(uuid, text, numeric, text) IS
  'E11. POST /admin/balance. Ajusta la cuenta principal de un CLIENTE (p_usuario_id: uuid, username o número de cuenta de 10 dígitos; el front no muestra el uuid) en p_monto, CON SIGNO: positivo = AJUSTE_ADMIN_POS, negativo = AJUSTE_ADMIN_NEG (contraparte "Banco Digital", nota opcional de hasta 140). 0, NaN, infinito, más de 2 decimales o mayor que monto_maximo = "Monto inválido"; un ajuste negativo que dejaría la cuenta bajo cero = "Saldo insuficiente". Orden: admin, monto, objetivo, nota, UNA instantánea, bloqueo de la cuenta, devengo/cobro, libro (solo _asentar_grupo; todo o nada). Se puede ajustar a un cliente bloqueado. Evento AJUSTE_ADMIN. Devuelve {id (grupo), monto, fecha}. El backend debe pasar el monto como texto/número exacto.';

-- ----------------------------------------------------------------------------
-- Reloj: envoltorios de E3
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_reloj(p_admin_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM public._validar_admin(p_admin_id);
  RETURN public._reloj_vista();
END
$$;
COMMENT ON FUNCTION public.admin_get_reloj(uuid) IS
  'E11. GET /admin/reloj. {usar_fecha_real, fecha_sistema ("YYYY-MM-DD" o null en modo real), fecha_actual (= hoy del banco)}: la vista de E3 (_reloj_vista) tras validar al admin. No toca saldos.';

CREATE OR REPLACE FUNCTION public.admin_set_reloj(p_admin_id uuid, p_usar_fecha_real boolean, p_fecha_sistema text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  adm public.usuario;
BEGIN
  adm := public._validar_admin(p_admin_id);
  -- atribución del RELOJ_CAMBIO que escribe el disparador de E3 (solo atribución; el cambio sin efecto no se audita)
  PERFORM set_config('banco.actor', adm.username, true);
  RETURN public._reloj_actualizar(p_usar_fecha_real, p_fecha_sistema);
END
$$;
COMMENT ON FUNCTION public.admin_set_reloj(uuid, boolean, text) IS
  'E11. PUT /admin/reloj. Envuelve _reloj_actualizar de E3 tras validar al admin: usar = true vuelve SIEMPRE a la fecha real e ignora la fecha (el front la manda igual); usar = false exige una fecha YYYY-MM-DD que solo puede igualar o adelantar el hoy del banco ("El reloj no puede retroceder"; "Fecha inválida" si falta o no existe). Devuelve la misma vista que admin_get_reloj. El RELOJ_CAMBIO de E3 queda atribuido al admin. No se limita a un único adelanto (P-DEMO, política del equipo, no implementada).';

-- ----------------------------------------------------------------------------
-- Tasas
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_tasas(p_admin_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM public._validar_admin(p_admin_id);
  RETURN jsonb_build_object(
    'cdts',     coalesce((SELECT jsonb_agg(jsonb_build_object('id', d.id, 'nombre', d.nombre, 'tasa', d.tasa_anual) ORDER BY d.nombre, d.id)
                            FROM public.cdt_definicion d), '[]'::jsonb),
    'creditos', coalesce((SELECT jsonb_agg(jsonb_build_object('id', k.id, 'nombre', k.nombre, 'tasa', k.tasa_anual) ORDER BY k.nombre, k.id)
                            FROM public.credito_producto k), '[]'::jsonb),
    -- D-E11-D7a (PROVISIONAL, equipo): la mora sin valor (NULL = sin mora, E9) se lee 0 para que el formulario del front pueda guardarse
    'mora',     coalesce((SELECT p.tasa_mora_anual FROM public.parametro p WHERE p.id = 1), 0));
END
$$;
COMMENT ON FUNCTION public.admin_get_tasas(uuid) IS
  'E11. GET /admin/tasas. {cdts [{id, nombre, tasa}], creditos [{id, nombre, tasa}], mora}: todas las definiciones de CDT y productos de crédito (por nombre) y la tasa de mora como número (porcentaje, 12 = 12 %). D-E11-D7a (PROVISIONAL, equipo): una mora sin valor (NULL) se lee como 0, porque el front pinta String(mora) y reenvía los tres campos. No toca saldos.';

CREATE OR REPLACE FUNCTION public.admin_set_tasa_cdt(p_admin_id uuid, p_definicion_id text, p_tasa text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  adm     public.usuario;
  v_tasa  numeric;
  v_id    text := nullif(btrim(coalesce(p_definicion_id, '')), '');
  v_antes numeric;
BEGIN
  adm    := public._validar_admin(p_admin_id);
  v_tasa := public._parse_tasa(p_tasa, false);
  IF v_id IS NULL OR v_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('banco.admin.tasas', 0));      -- un formulario completo a la vez (se libera al terminar la transacción)
  SELECT d.tasa_anual INTO v_antes FROM public.cdt_definicion d WHERE d.id = v_id::uuid FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  IF v_antes IS DISTINCT FROM v_tasa THEN
    UPDATE public.cdt_definicion SET tasa_anual = v_tasa WHERE id = v_id::uuid;   -- los CDT ya creados conservan su tasa copiada
    PERFORM public._auditar_admin(adm, 'TASA_CAMBIO', 'cdt_definicion', v_id, jsonb_build_object('tasa', v_antes), jsonb_build_object('tasa', v_tasa));
  END IF;
  RETURN jsonb_build_object('id', v_id::uuid, 'tasa', v_tasa);
END
$$;
COMMENT ON FUNCTION public.admin_set_tasa_cdt(uuid, text, text) IS
  'E11. Una de las 3 llamadas de PUT /admin/tasas. Cambia la tasa de una definición de CDT: p_tasa es TEXTO ("12.5"; 0 < t <= 100, hasta 3 decimales; si no, "Tasa inválida"); un id mal formado o inexistente = "Recurso no encontrado" (no se ignora en silencio). Solo afecta a los CDT que se abran DESPUÉS (la tasa se copia al crear). Toma el advisory lock de tasas hasta el fin de la transacción: dos formularios simultáneos se serializan y el estado final es el de UNO completo. Evento TASA_CAMBIO solo si el valor cambia. Atómica por sí sola; el conjunto del formulario es atómico porque el backend lo ejecuta en UNA transacción.';

CREATE OR REPLACE FUNCTION public.admin_set_tasa_credito(p_admin_id uuid, p_producto_id text, p_tasa text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  adm     public.usuario;
  v_tasa  numeric;
  v_id    text := nullif(btrim(coalesce(p_producto_id, '')), '');
  v_antes numeric;
BEGIN
  adm    := public._validar_admin(p_admin_id);
  v_tasa := public._parse_tasa(p_tasa, false);
  IF v_id IS NULL OR v_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('banco.admin.tasas', 0));
  SELECT k.tasa_anual INTO v_antes FROM public.credito_producto k WHERE k.id = v_id::uuid FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  IF v_antes IS DISTINCT FROM v_tasa THEN
    UPDATE public.credito_producto SET tasa_anual = v_tasa WHERE id = v_id::uuid;  -- los créditos ya desembolsados conservan su tasa y su plan
    PERFORM public._auditar_admin(adm, 'TASA_CAMBIO', 'credito_producto', v_id, jsonb_build_object('tasa', v_antes), jsonb_build_object('tasa', v_tasa));
  END IF;
  RETURN jsonb_build_object('id', v_id::uuid, 'tasa', v_tasa);
END
$$;
COMMENT ON FUNCTION public.admin_set_tasa_credito(uuid, text, text) IS
  'E11. Una de las 3 llamadas de PUT /admin/tasas. Cambia la tasa de un producto de crédito (mismas reglas que admin_set_tasa_cdt). Solo afecta a los créditos que se soliciten DESPUÉS (la tasa se copia al desembolsar y el plan queda fijo). Evento TASA_CAMBIO solo si el valor cambia.';

CREATE OR REPLACE FUNCTION public.admin_set_tasa_mora(p_admin_id uuid, p_tasa text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  adm     public.usuario;
  v_tasa  numeric;
  v_antes numeric;
BEGIN
  adm    := public._validar_admin(p_admin_id);
  v_tasa := public._parse_tasa(p_tasa, true);                  -- D-E11-D7a (PROVISIONAL): 0 = «sin mora» (se guarda NULL, el mismo significado de E9)
  PERFORM pg_advisory_xact_lock(hashtextextended('banco.admin.tasas', 0));
  SELECT coalesce(p.tasa_mora_anual, 0) INTO v_antes FROM public.parametro p WHERE p.id = 1 FOR NO KEY UPDATE;
  IF v_antes IS DISTINCT FROM v_tasa THEN
    UPDATE public.parametro SET tasa_mora_anual = nullif(v_tasa, 0) WHERE id = 1;
    PERFORM public._auditar_admin(adm, 'TASA_CAMBIO', 'parametro', '1', jsonb_build_object('mora', v_antes), jsonb_build_object('mora', v_tasa));
  END IF;
  RETURN jsonb_build_object('mora', v_tasa);
END
$$;
COMMENT ON FUNCTION public.admin_set_tasa_mora(uuid, text) IS
  'E11. Una de las 3 llamadas de PUT /admin/tasas. Cambia parametro.tasa_mora_anual. D-E11-D7a (PROVISIONAL, equipo): 0 = "sin mora" y se guarda NULL (el mismo significado de E9); 0 < t <= 100 con hasta 3 decimales. D-E11-D7b (NO decidido por el equipo): la mora de E9 es DERIVADA y esta función no la copia a ningún crédito, así que cambiar la tasa cambia la mora de las cuotas que ya están vencidas; E11 no añade ninguna lógica sobre ese efecto. Evento TASA_CAMBIO solo si el valor cambia.';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- Permisos: las 12 públicas -> banco_app (banco_dev las hereda); los helpers -> nadie salvo el dueño
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma, p.proname FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('admin_listar_usuarios', 'admin_detalle_usuario', 'admin_bloquear', 'admin_desbloquear', 'admin_borrar_usuario', 'admin_ajustar_balance',
                         'admin_get_reloj', 'admin_set_reloj', 'admin_get_tasas', 'admin_set_tasa_cdt', 'admin_set_tasa_credito', 'admin_set_tasa_mora',
                         '_reglas_admin', '_parse_tasa', '_cliente_objetivo', '_auditar_admin')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
    IF f.proname LIKE 'admin\_%' THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO banco_app', f.firma);
    END IF;
  END LOOP;
END
$$;

COMMIT;
