-- ============================================================================
-- 23_vistas.sql  ·  Etapa 10 (vistas del contrato: dashboard e historial)
-- Propósito  : las dos funciones de cliente del contrato que faltaban (GET /dashboard y GET /transacciones) y la regla de «fila visible» del historial, una sola vez.
--
--   Públicas (EXECUTE solo banco_app; banco_dev por herencia):
--     vista_dashboard(usuario)                 -> jsonb {nombre, balance_total, transacciones[<=8], cdts{activos, generado}, creditos{cuota_por_pagar, interes_corriendo}}
--     vista_historial(usuario, limite = 50)    -> jsonb [{id, tipo, tipo_detalle, monto, fecha, contraparte, nota}], recientes primero, limite acotado a [1, 50]
--   Internas (sin EXECUTE para nadie salvo el dueño; _reglas_historial tambien para banco_lector, que la necesita para leer la vista):
--     _reglas_historial()                      valores PROVISIONALES de D8 (qué familias se muestran) y el tope de 50 en UN solo lugar
--     _json_transacciones(cuenta, limite)      UN solo formateador de Transaccion[] (dashboard, historial y, en E11, admin_detalle_usuario)
--   Vista real:
--     v_transaccion_usuario                    UNA fila por operación del libro: la pata de la cuenta en un contenedor de liquidez
--                                              (prioridad CUENTA > BOLSILLO > CDT; en BOLSO_MOVIMIENTO la de sentido S); dirección = sentido (S = envio, E = recibo).
--                                              SELECT solo para banco_lector (banco_dev por herencia): banco_app NO la lee (miraría a todos los usuarios).
--
-- Orden de las públicas (igual que E6-E9): sesión -> UNA instantánea del reloj -> motor de devengo/cobro -> UNA sola sentencia (una sola foto).
-- D6 (qué cifra es el «balance total») y D8 (qué movimientos se muestran) son decisiones del EQUIPO: aquí solo hay valores provisionales centralizados.
-- Dependencias : 00 a 22.   Ejecución: como superusuario, IDEMPOTENTE, transaccional.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- _reglas_historial: D8 provisional (default = el del contrato: todo visible)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reglas_historial()
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'limite_max',            50,                 -- contrato §3.2: «limite máx. 50»
    'mostrar_bolso',         true,               -- D8 (PROVISIONAL, equipo/front): movimientos cuenta<->bolsillo (BOLSO_INGRESO/RETIRO/MOVIMIENTO); contrato §7.2: «default propuesto: mostrarlos»
    'mostrar_interes_bolso', true,               -- D8 (PROVISIONAL): intereses de bolsillo; contrato §3.2: «INTERES_* = entra»
    'mostrar_interes_cdt',   true,               -- D8 (PROVISIONAL): intereses de CDT (el diseño v3 proponía ocultarlos; el contrato los lista como «entra»)
    'contraparte_respaldo',  'Banco Digital')    -- contrato §3.2: «movimientos del banco: Banco Digital»; contraparte nunca es null
$$;
COMMENT ON FUNCTION public._reglas_historial() IS
  'E10. PURA. Valores provisionales de D8 (equipo/front) y el tope del historial en UN solo lugar: limite_max = 50, mostrar_bolso / mostrar_interes_bolso / mostrar_interes_cdt = true (el default del contrato) y la contraparte de respaldo "Banco Digital". Cambiar D8 = cambiar solo este cuerpo.';

-- ----------------------------------------------------------------------------
-- v_transaccion_usuario: la regla de «fila visible»
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_transaccion_usuario AS
SELECT t.cuenta_id,
       c.usuario_id,
       t.id,
       t.orden,
       t.grupo_id,
       t.fecha,
       CASE t.sentido WHEN 'S' THEN 'envio' ELSE 'recibo' END                                              AS tipo,
       t.tipo::text                                                                                         AS tipo_detalle,
       t.monto,
       -- contraparte: (1) el snapshot de la pata (con la cuenta SOLO entre cuentas), (2) el nombre de su bolsillo / CDT / producto, (3) «Banco Digital»
       coalesce(CASE WHEN t.tipo IN ('ENVIO', 'RECIBO') AND t.contraparte_cuenta IS NOT NULL AND t.contraparte_nombre IS NOT NULL
                     THEN t.contraparte_nombre || ' · ' || t.contraparte_cuenta
                     ELSE t.contraparte_nombre END,
                b.nombre, d.nombre, pr.nombre,
                public._reglas_historial() ->> 'contraparte_respaldo')                                      AS contraparte,
       t.nota
  FROM public.transaccion t
  JOIN public.cuenta c ON c.id = t.cuenta_id
  LEFT JOIN public.bolsillo b ON b.id = t.bolsillo_id
  LEFT JOIN public.cdt d ON d.id = t.cdt_id
  LEFT JOIN public.credito k ON k.id = t.credito_id
  LEFT JOIN public.credito_producto pr ON pr.id = k.producto_id
 WHERE t.contenedor IN ('CUENTA', 'BOLSILLO', 'CDT')
   AND (   t.contenedor = 'CUENTA'
        OR (t.contenedor = 'BOLSILLO' AND (t.tipo <> 'BOLSO_MOVIMIENTO' OR t.sentido = 'S')
            AND NOT EXISTS (SELECT 1 FROM public.transaccion x WHERE x.grupo_id = t.grupo_id AND x.cuenta_id = t.cuenta_id AND x.contenedor = 'CUENTA'))
        OR (t.contenedor = 'CDT'
            AND NOT EXISTS (SELECT 1 FROM public.transaccion x WHERE x.grupo_id = t.grupo_id AND x.cuenta_id = t.cuenta_id AND x.contenedor IN ('CUENTA', 'BOLSILLO'))))
   AND (t.tipo::text NOT IN ('BOLSO_INGRESO', 'BOLSO_RETIRO', 'BOLSO_MOVIMIENTO') OR (public._reglas_historial() ->> 'mostrar_bolso')::boolean)
   AND (t.tipo::text <> 'INTERES_BOLSO' OR (public._reglas_historial() ->> 'mostrar_interes_bolso')::boolean)
   AND (t.tipo::text <> 'INTERES_CDT' OR (public._reglas_historial() ->> 'mostrar_interes_cdt')::boolean);
COMMENT ON VIEW public.v_transaccion_usuario IS
  'E10. Historial del usuario: UNA fila por operación (grupo) del libro. Fila = la pata de la cuenta en un contenedor de liquidez, con prioridad CUENTA > BOLSILLO > CDT (en BOLSO_MOVIMIENTO, la de sentido S); las patas CREDITO y RESULTADO nunca se muestran. tipo = envio (sentido S) o recibo (E); tipo_detalle = el tipo real; contraparte nunca es null (snapshot -> bolsillo/CDT/producto -> Banco Digital). D8 (familias visibles) en _reglas_historial(). Mira a TODOS los usuarios: solo banco_lector/banco_dev la leen; banco_app recibe los datos por vista_historial y vista_dashboard, que filtran por la cuenta del usuario de la sesión.';

-- ----------------------------------------------------------------------------
-- _json_transacciones: UN solo formateador de Transaccion[]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._json_transacciones(p_cuenta_id uuid, p_limite integer)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = public, pg_temp SET TimeZone = 'America/Bogota' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'tipo', v.tipo, 'tipo_detalle', v.tipo_detalle, 'monto', v.monto,
                                               'fecha', v.fecha, 'contraparte', v.contraparte, 'nota', v.nota) ORDER BY v.orden DESC), '[]'::jsonb)
    FROM (SELECT x.* FROM public.v_transaccion_usuario x
           WHERE x.cuenta_id = p_cuenta_id
           ORDER BY x.orden DESC
           LIMIT greatest(1, least(coalesce(p_limite, (public._reglas_historial() ->> 'limite_max')::integer), (public._reglas_historial() ->> 'limite_max')::integer))) v
$$;
COMMENT ON FUNCTION public._json_transacciones(uuid, integer) IS
  'E10. Interna, STABLE. Transaccion[] de una cuenta: [{id, tipo, tipo_detalle, monto, fecha, contraparte, nota}] recientes primero (por orden, no por fecha: los cobros del motor llevan la fecha del día en que debieron ocurrir), limite acotado a [1, limite_max] (NULL = el máximo), [] si no hay. Fechas ISO con zona de Bogotá por código. Única forma de armar este JSON (dashboard, historial y, en E11, el detalle de admin).';

-- ----------------------------------------------------------------------------
-- vista_historial: GET /transacciones?limite=N
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.vista_historial(p_usuario_id uuid, p_limite integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp SET TimeZone = 'America/Bogota' AS $$
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
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);                 -- devenga, cierra y cobra lo vencido ANTES de leer
  SELECT public._json_transacciones(c.id, p_limite) INTO r FROM public.cuenta c WHERE c.id = v_cta;   -- UNA sola sentencia = una sola foto
  IF r IS NULL THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';             -- el usuario fue borrado durante la operación
  END IF;
  RETURN r;
END
$$;
COMMENT ON FUNCTION public.vista_historial(uuid, integer) IS
  'E10. GET /transacciones?limite=N. [{id, tipo (envio|recibo), tipo_detalle, monto, fecha, contraparte, nota}] recientes primero (por orden), UNA fila por operación (v_transaccion_usuario), p_limite NULL = 50 y acotado a [1, 50] (sin mensaje nuevo). Orden de E6-E9: sesión, UNA instantánea del reloj, motor de devengo/cobro ANTES de leer, una sola sentencia. [] si no hay movimientos. Usuario borrado en carrera = Sesión inválida.';

-- ----------------------------------------------------------------------------
-- vista_dashboard: GET /dashboard
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.vista_dashboard(p_usuario_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp SET TimeZone = 'America/Bogota' AS $$
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
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);                 -- el dashboard «incluye el avance de reloj» (contrato §3.2)
  -- UNA sola sentencia = UNA sola foto: total, últimas 8, CDT y créditos nunca se ven a medias de un movimiento concurrente.
  -- Cada sección usa la MISMA función que su endpoint propio (balance_total, _proxima_cuota, _interes_corriendo): no pueden discrepar.
  SELECT jsonb_build_object(
           'nombre',        us.nombres,
           'balance_total', public.balance_total(c.id),
           'transacciones', public._json_transacciones(c.id, 8),
           'cdts',          jsonb_build_object(
                              'activos',  (SELECT count(*) FROM public.cdt d WHERE d.cuenta_id = c.id AND d.estado = 'ACTIVO'),
                              'generado', (SELECT coalesce(sum(d.generado_acumulado), 0) FROM public.cdt d WHERE d.cuenta_id = c.id AND d.estado = 'ACTIVO')),
           'creditos',      jsonb_build_object(
                              'cuota_por_pagar',   (SELECT coalesce(sum((public._proxima_cuota(k.id)).valor_cuota), 0) FROM public.credito k WHERE k.cuenta_id = c.id AND k.estado = 'ACTIVO'),
                              'interes_corriendo', (SELECT coalesce(sum(public._interes_corriendo(k.id, v_hoy)), 0) FROM public.credito k WHERE k.cuenta_id = c.id AND k.estado = 'ACTIVO')))
    INTO r
    FROM public.cuenta c JOIN public.usuario us ON us.id = c.usuario_id
   WHERE c.id = v_cta;
  IF r IS NULL THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END IF;
  RETURN r;
END
$$;
COMMENT ON FUNCTION public.vista_dashboard(uuid) IS
  'E10. GET /dashboard. {nombre (nombres), balance_total (= balance_total(), la misma función de vista_balance: D6 sigue provisional), transacciones (las últimas 8 de vista_historial), cdts {activos, generado: suma de generado_acumulado de los CDT ACTIVOS}, creditos {cuota_por_pagar: suma de valor_cuota de la próxima cuota impaga de cada crédito ACTIVO, sin mora; interes_corriendo: suma de _interes_corriendo}}. UNA instantánea del reloj, motor de devengo/cobro ANTES de leer y una sola sentencia (una sola foto).';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- Permisos: las 2 públicas -> banco_app (banco_dev las hereda); los helpers -> nadie salvo el dueño; la vista -> solo banco_lector (banco_dev por herencia)
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma, p.proname FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('vista_dashboard', 'vista_historial', '_reglas_historial', '_json_transacciones')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
    IF f.proname IN ('vista_dashboard', 'vista_historial') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO banco_app', f.firma);
    END IF;
  END LOOP;
END
$$;
-- ----------------------------------------------------------------------------
-- D-E10-8: las funciones YA aprobadas que emiten un timestamptz (fecha de un asiento, fecha_cierre) fijan la zona de Bogota POR CODIGO, como las nuevas: ALTER FUNCTION ... SET TimeZone
-- es solo configuracion de la funcion (no cambia su cuerpo). El contrato pide «ISO 8601 con zona» y el servidor corre en UTC: sin esto dependian del TimeZone del DB. NOTA: si se reaplica
-- el script de una de ellas SOLA (CREATE OR REPLACE), esta configuracion se pierde hasta reaplicar este script (23): por eso 09_idempotencia reaplica 23 al final.
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('hacer_transferencia', 'mover_a_bolsillo', 'retirar_de_bolsillo', 'mover_entre_bolsillos', 'crear_cdt', 'vista_cdts', 'solicitar_credito', 'pagar_cuota', 'abonar_credito')
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET TimeZone TO ''America/Bogota''', f.firma);
  END LOOP;
END
$$;

REVOKE ALL ON public.v_transaccion_usuario FROM PUBLIC, banco_app, banco_lector, banco_dev;
GRANT SELECT ON public.v_transaccion_usuario TO banco_lector;
-- las funciones que llama una vista corren con los privilegios de QUIEN CONSULTA (no del dueño): para que banco_lector/banco_dev puedan leer la vista necesitan EXECUTE de la unica funcion que usa
-- (_reglas_historial: PURA, solo devuelve constantes; igual que _plantillas_validas con v_integridad_grupos). banco_app NO la recibe.
GRANT EXECUTE ON FUNCTION public._reglas_historial() TO banco_lector;

COMMIT;
