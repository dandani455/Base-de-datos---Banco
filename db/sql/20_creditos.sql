-- ============================================================================
-- 20_creditos.sql  ·  Etapa 8 (créditos) · parte 2/2: productos, simulación, solicitud y consulta
-- Propósito  : listar los productos con sus topes efectivos, simular, solicitar (CREDITO_DESEMBOLSO + plan de cuotas completo) y consultar los créditos del
--              cliente. El dinero se mueve SOLO por _asentar_grupo; el plan sale de _plan_cuotas (19), el MISMO que usa la simulación.
--
--   Públicas (EXECUTE solo banco_app; banco_dev por herencia):
--     productos_disponibles(usuario)                          -> jsonb [{id, nombre, tasa, monto_min, monto_max, plazo_min, plazo_max}] topes EFECTIVOS   (GET  /creditos/productos)
--     productos_publicos()                                    -> jsonb [{id, nombre, descripcion, tasa, monto_min, monto_max, plazo_min, plazo_max}] topes BASE, sin sesión
--     simular_credito(usuario, producto_id text, monto, plazo_meses numeric) -> jsonb {cuota_mensual, total_a_pagar, intereses_totales}             (POST /creditos/simular)
--     solicitar_credito(usuario, producto_id text, monto, plazo_meses numeric) -> jsonb {id, fecha}  (id = id del crédito)                           (POST /creditos)
--     vista_creditos(usuario)                                 -> jsonb [{id, producto, cuotas_pagadas, cuotas_faltantes, interes_mes, saldo}] ACTIVOS    (GET  /creditos/mis-creditos)
--   Internas (sin EXECUTE para nadie salvo el dueño):
--     _producto_credito(texto)         el producto del uuid (texto) o 'Recurso no encontrado'
--     _validar_plazo(numeric)          entero entre 1 y 1.000.000 o 'Plazo fuera de rango' (el plazo llega como numeric: un 12,5 no puede ser un error de driver)
--     _limites_credito(cuenta, nacimiento, producto, hoy)   topes efectivos (monto: tope fijo y multiplicador*patrimonio; plazo: técnico y regla de edad)
--     _verificar_credito(...)          monto / plazo / edad contra los topes, con los mensajes del contrato §6 (la comparten simular y solicitar)
--
-- Orden de validación: sesión -> monto -> plazo (formato) -> producto -> [instantánea] -> devengo -> [bloqueo de la cuenta y crédito vigente: solo solicitar]
--                      -> monto en rango -> plazo en rango -> plazo vs edad.
-- Una sola _reloj_instantanea() por operación; _avanzar_hasta (17) ANTES de calcular topes (devenga bolsillos y CDT); productos_publicos no devenga (no lee a nadie).
-- E9 (pagos, abonos, mora, descuento automático) NO está aquí. D1/D6/D7/D10/D11 son del EQUIPO: la tasa (D1) vive en _tasa_mensual, el patrimonio (D6) en
-- _patrimonio_neto, y no hay catálogo (D11): las pruebas crean sus productos.
-- Dependencias : 00 a 19.   Ejecución: como superusuario, IDEMPOTENTE, transaccional.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- Helpers internos
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._producto_credito(p_texto text)
RETURNS public.credito_producto LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_txt text := nullif(btrim(coalesce(p_texto, '')), '');
  d     public.credito_producto;
BEGIN
  -- texto (no uuid): un uuid mal formado sería un error de driver (503 en el backend); aquí es un error de negocio
  IF v_txt IS NULL OR v_txt !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO d FROM public.credito_producto x WHERE x.id = v_txt::uuid;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  RETURN d;
END
$$;
COMMENT ON FUNCTION public._producto_credito(text) IS
  'E8. Interna. La fila de credito_producto cuyo id es el uuid de p_texto; si el texto es nulo, vacío, mal formado o no existe: "Recurso no encontrado" (P0001), sin distinguir los casos.';

CREATE OR REPLACE FUNCTION public._validar_plazo(p_plazo numeric)
RETURNS integer LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
BEGIN
  IF p_plazo IS NULL OR p_plazo = 'NaN'::numeric OR p_plazo IN ('Infinity'::numeric, '-Infinity'::numeric)
     OR p_plazo < 1 OR p_plazo > 1000000 OR p_plazo <> trunc(p_plazo) THEN
    RAISE EXCEPTION '%', (public._reglas_credito() ->> 'msg_plazo') USING ERRCODE = 'P0001';
  END IF;
  RETURN p_plazo::integer;
END
$$;
COMMENT ON FUNCTION public._validar_plazo(numeric) IS
  'E8. Interna. El plazo en meses como entero, o "Plazo fuera de rango" (P0001) si es NULL, NaN, infinito, < 1, > 1.000.000 o fraccionario. Llega como numeric (el front manda números JSON) para que 12,5 sea un error de negocio y no de driver.';

CREATE OR REPLACE FUNCTION public._limites_credito(p_cuenta_id uuid, p_nacimiento date, p_prod public.credito_producto, p_hoy date)
RETURNS TABLE (l_monto_min numeric, l_monto_max numeric, l_plazo_min integer, l_plazo_max_prod integer, l_plazo_max integer)
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_max  numeric;
  v_lim  integer;
  v_edad integer;
BEGIN
  l_monto_min      := p_prod.monto_min;
  l_plazo_min      := p_prod.plazo_min_meses;
  l_plazo_max_prod := least(p_prod.plazo_max_meses, (public._reglas_credito() ->> 'plazo_tecnico_max')::int);
  -- monto: el menor entre el rango del producto, su tope fijo y multiplicador * patrimonio neto (D-E8-5, PROVISIONAL / D6); nunca negativo
  v_max := p_prod.monto_max;
  IF p_prod.tope_absoluto IS NOT NULL THEN
    v_max := least(v_max, p_prod.tope_absoluto);
  END IF;
  IF p_prod.multiplicador_balance IS NOT NULL THEN
    v_max := least(v_max, trunc(p_prod.multiplicador_balance * public._patrimonio_neto(p_cuenta_id), 2));
  END IF;
  l_monto_max := greatest(0.00, v_max);
  -- plazo: el del producto (y el técnico) y, si aplica la regla de edad, (límite - edad) * 12 con la edad en AÑOS CUMPLIDOS a la fecha p_hoy (D-E8-7)
  l_plazo_max := l_plazo_max_prod;
  IF p_prod.aplica_regla_edad THEN
    SELECT pa.edad_limite_inmuebles INTO v_lim FROM public.parametro pa WHERE pa.id = 1;
    v_edad := date_part('year', age(p_hoy, p_nacimiento))::int;
    l_plazo_max := least(l_plazo_max_prod, greatest(0, (v_lim - v_edad) * 12));
  END IF;
  RETURN NEXT;
END
$$;
COMMENT ON FUNCTION public._limites_credito(uuid, date, public.credito_producto, date) IS
  'E8. Interna. Topes EFECTIVOS de un producto para una cuenta: monto_max = max(0, min(monto_max, tope_absoluto, trunc(multiplicador * _patrimonio_neto, 2))) (D-E8-5 PROVISIONAL); plazo_max_prod = min(plazo_max_meses, plazo técnico 360); plazo_max = además min(·, (edad_limite_inmuebles - edad) * 12) si aplica_regla_edad, con la edad en años cumplidos a p_hoy (D-E8-7). STABLE: el llamador devenga antes. Un producto siempre tiene topes (pueden ser 0).';

CREATE OR REPLACE FUNCTION public._verificar_credito(p_cuenta_id uuid, p_nacimiento date, p_prod public.credito_producto, p_hoy date, p_monto numeric, p_plazo integer)
RETURNS void LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  l record;
BEGIN
  SELECT * INTO l FROM public._limites_credito(p_cuenta_id, p_nacimiento, p_prod, p_hoy);
  IF p_monto < l.l_monto_min OR p_monto > l.l_monto_max THEN
    RAISE EXCEPTION '%', (public._reglas_credito() ->> 'msg_monto') USING ERRCODE = 'P0001';
  END IF;
  IF p_plazo < l.l_plazo_min OR p_plazo > l.l_plazo_max_prod THEN
    RAISE EXCEPTION '%', (public._reglas_credito() ->> 'msg_plazo') USING ERRCODE = 'P0001';
  END IF;
  IF p_plazo > l.l_plazo_max THEN
    RAISE EXCEPTION '%', (public._reglas_credito() ->> 'msg_edad') USING ERRCODE = 'P0001';
  END IF;
END
$$;
COMMENT ON FUNCTION public._verificar_credito(uuid, date, public.credito_producto, date, numeric, integer) IS
  'E8. Interna. Valida monto y plazo contra los topes efectivos con los mensajes del contrato §6, en este orden: "Monto fuera de rango" (fuera de [monto_min, monto_max efectivo]), "Plazo fuera de rango" (fuera de [plazo_min, plazo máximo del producto]) y "Plazo excede el límite de edad" (cabe en el producto pero supera (límite - edad) * 12). La comparten simular_credito y solicitar_credito.';

-- ----------------------------------------------------------------------------
-- productos_disponibles
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.productos_disponibles(p_usuario_id uuid)
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
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);               -- devenga bolsillos y CDT ANTES de calcular el tope (el patrimonio ya los incluye)
  -- UNA sola sentencia = UNA sola foto del patrimonio y de los productos
  SELECT coalesce((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'nombre', p.nombre, 'tasa', p.tasa_anual, 'monto_min', l.l_monto_min, 'monto_max', l.l_monto_max,
                                                       'plazo_min', l.l_plazo_min, 'plazo_max', l.l_plazo_max) ORDER BY p.nombre, p.id)
                     FROM public.credito_producto p
                    CROSS JOIN LATERAL public._limites_credito(c.id, u.fecha_nacimiento, p, v_hoy) l), '[]'::jsonb)
    INTO r FROM public.cuenta c WHERE c.id = v_cta;
  IF r IS NULL THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';             -- el usuario fue borrado durante la operación
  END IF;
  RETURN r;
END
$$;
COMMENT ON FUNCTION public.productos_disponibles(uuid) IS
  'E8. GET /creditos/productos. [{id, nombre, tasa (% E.A.), monto_min, monto_max, plazo_min, plazo_max}] ordenado por nombre con los topes EFECTIVOS del usuario (tope fijo, multiplicador * patrimonio neto, regla de edad); un producto siempre se lista aunque sus topes queden en 0; [] si no hay catálogo (D11, del equipo). UNA _reloj_instantanea() y _avanzar_hasta ANTES de calcular. D-E8-8 PROVISIONAL (D10).';

-- ----------------------------------------------------------------------------
-- productos_publicos (sin sesión; sin datos personales)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.productos_publicos()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'nombre', p.nombre, 'descripcion', p.descripcion, 'tasa', p.tasa_anual,
                                               'monto_min', p.monto_min, 'monto_max', least(p.monto_max, coalesce(p.tope_absoluto, p.monto_max)),
                                               'plazo_min', p.plazo_min_meses, 'plazo_max', least(p.plazo_max_meses, (public._reglas_credito() ->> 'plazo_tecnico_max')::int))
                                ORDER BY p.nombre, p.id), '[]'::jsonb)
    FROM public.credito_producto p
$$;
COMMENT ON FUNCTION public.productos_publicos() IS
  'E8. Landing sin sesión (contrato §7.3). [{id, nombre, descripcion, tasa, monto_min, monto_max, plazo_min, plazo_max}] con topes BASE (rango y tope fijo del producto; sin multiplicador ni regla de edad: no hay datos personales). No devenga (no lee a nadie) ni toca el reloj. D-E8-8 PROVISIONAL: que el endpoint público lo exponga Juan.';

-- ----------------------------------------------------------------------------
-- simular_credito
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.simular_credito(p_usuario_id uuid, p_producto_id text, p_monto numeric, p_plazo_meses numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u       public.usuario;
  v_monto numeric;
  v_plazo integer;
  d       public.credito_producto;
  v_cta   uuid;
  v_hoy   date;
  v_ahora timestamptz;
  r       record;
BEGIN
  u       := public._validar_cliente(p_usuario_id);
  v_monto := public._validar_monto(p_monto);
  v_plazo := public._validar_plazo(p_plazo_meses);
  d       := public._producto_credito(p_producto_id);
  SELECT c.id INTO v_cta FROM public.cuenta c WHERE c.usuario_id = u.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END IF;
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);               -- el tope de Inmuebles depende del patrimonio devengado
  PERFORM public._verificar_credito(v_cta, u.fecha_nacimiento, d, v_hoy, v_monto, v_plazo);
  SELECT max(p.cuota) FILTER (WHERE p.numero = 1) AS cuota_mensual, sum(p.cuota) AS total, sum(p.interes) AS intereses
    INTO r FROM public._plan_cuotas(v_monto, d.tasa_anual, v_plazo) p;
  RETURN jsonb_build_object('cuota_mensual', r.cuota_mensual, 'total_a_pagar', r.total, 'intereses_totales', r.intereses);
END
$$;
COMMENT ON FUNCTION public.simular_credito(uuid, text, numeric, numeric) IS
  'E8. POST /creditos/simular. {cuota_mensual, total_a_pagar, intereses_totales} del MISMO _plan_cuotas que solicitar_credito (cuota_mensual = cuota fija; total = Σ cuotas con la última absorbiendo el redondeo; intereses = total - monto). Orden: sesión, monto (Monto inválido), plazo (Plazo fuera de rango), producto (Recurso no encontrado), UNA _reloj_instantanea(), _avanzar_hasta, topes (Monto fuera de rango / Plazo fuera de rango / Plazo excede el límite de edad). No escribe el libro. D-E8-8 PROVISIONAL (D10): recibe p_usuario_id (el contrato no lo lleva) y el plazo como numeric.';

-- ----------------------------------------------------------------------------
-- solicitar_credito
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.solicitar_credito(p_usuario_id uuid, p_producto_id text, p_monto numeric, p_plazo_meses numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u       public.usuario;
  v_monto numeric;
  v_plazo integer;
  d       public.credito_producto;
  v_cta   uuid;
  v_hoy   date;
  v_ahora timestamptz;
  v_id    uuid;
  v_n     bigint;
  v_con   text;
  v_msg   text;
BEGIN
  -- 1) sesión viva (E4) -> 2) monto (E5) -> 3) plazo (formato) -> 4) producto
  u       := public._validar_cliente(p_usuario_id);
  v_monto := public._validar_monto(p_monto);
  v_plazo := public._validar_plazo(p_plazo_meses);
  d       := public._producto_credito(p_producto_id);
  SELECT c.id INTO v_cta FROM public.cuenta c WHERE c.usuario_id = u.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END IF;
  -- 5) UNA sola instantánea; (hoy, ahora) viajan al motor y al libro
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  -- 6) devengo previo y DESPUÉS el bloqueo explícito de la cuenta (el mismo FOR NO KEY UPDATE del libro): todo lo que decide el desembolso se lee bajo él
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);
  IF public._bloquear_cuentas(ARRAY[v_cta]) <> 1 THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';             -- la cuenta se borró mientras esperaba el bloqueo
  END IF;
  -- 7) un crédito vivo por producto -> topes (monto, plazo, edad)
  IF EXISTS (SELECT 1 FROM public.credito k WHERE k.cuenta_id = v_cta AND k.producto_id = d.id AND k.estado = 'ACTIVO') THEN
    RAISE EXCEPTION '%', (public._reglas_credito() ->> 'msg_vigente') USING ERRCODE = 'P0001';
  END IF;
  PERFORM public._verificar_credito(v_cta, u.fecha_nacimiento, d, v_hoy, v_monto, v_plazo);
  -- 8) el crédito (capital 0: lo sube el libro), su plan COMPLETO y el grupo CREDITO_DESEMBOLSO, en la misma transacción; copia contractual de tasa y plazo
  BEGIN
    INSERT INTO public.credito (cuenta_id, producto_id, monto, tasa_anual, plazo_meses, fecha_desembolso, capital_pendiente, fecha_interes)
    VALUES (v_cta, d.id, v_monto, d.tasa_anual, v_plazo, v_hoy, 0, v_hoy)
    RETURNING id INTO v_id;
  EXCEPTION
    WHEN unique_violation THEN                                    -- backstop del índice uq_credito_vivo_por_producto (el bloqueo ya serializa)
      RAISE EXCEPTION '%', (public._reglas_credito() ->> 'msg_vigente') USING ERRCODE = 'P0001';
    WHEN foreign_key_violation THEN
      GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
      IF v_con = 'fk_credito_producto' THEN
        RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';     -- el producto se borró entre la lectura y el INSERT
      END IF;
      RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';          -- la cuenta se borró
  END;
  INSERT INTO public.cuota (credito_id, numero, fecha_vencimiento, valor_cuota_original, valor_cuota, capital_programado, interes_programado)
  SELECT v_id, p.numero, public._fecha_vencimiento(v_hoy, p.numero), p.cuota, p.cuota, p.capital, p.interes
    FROM public._plan_cuotas(v_monto, d.tasa_anual, v_plazo) p;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> v_plazo THEN                                           -- completitud del plan AL CREAR (no es un trigger permanente: D-E8-9 v1.1)
    RAISE EXCEPTION 'Créditos: el plan insertó % cuotas y se esperaban %', v_n, v_plazo USING ERRCODE = 'P0001';
  END IF;
  BEGIN
    PERFORM public._asentar_grupo(v_ahora, jsonb_build_array(
      jsonb_build_object('tipo', 'CREDITO_DESEMBOLSO', 'contenedor', 'CUENTA',   'sentido', 'E', 'monto', v_monto, 'cuenta_id', v_cta, 'credito_id', v_id, 'contraparte_nombre', d.nombre),
      jsonb_build_object('tipo', 'CREDITO_DESEMBOLSO', 'contenedor', 'CREDITO',  'sentido', 'E', 'monto', v_monto, 'cuenta_id', v_cta, 'credito_id', v_id, 'contraparte_nombre', d.nombre)));
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'Libro mayor:%' AND NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = v_cta) THEN
      RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
    END IF;
    RAISE;
  END;
  -- 9) el plan debe cuadrar con el capital pendiente que acaba de subir el libro: falla AQUÍ (dentro de la función) y no en el COMMIT del backend
  SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota IMMEDIATE;
  SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota DEFERRED;
  RETURN jsonb_build_object('id', v_id, 'fecha', v_ahora);
END
$$;
COMMENT ON FUNCTION public.solicitar_credito(uuid, text, numeric, numeric) IS
  'E8. POST /creditos. Desembolso instantáneo: valida (sesión, Monto inválido, Plazo fuera de rango, Recurso no encontrado), UNA _reloj_instantanea(), _avanzar_hasta y bloqueo explícito de la cuenta, un crédito vivo por producto (Ya tienes un crédito vigente de este producto), topes (Monto fuera de rango, Plazo fuera de rango, Plazo excede el límite de edad); inserta el crédito (capital 0, tasa y plazo copiados), TODAS las cuotas del plan (_plan_cuotas), asienta CREDITO_DESEMBOLSO por _asentar_grupo (cuenta +M, capital_pendiente +M) y verifica ct_credito_plan antes de volver. Todo o nada. Devuelve {id, fecha}. Sin pagos, abonos ni mora (E9). D-E8-8 PROVISIONAL (D10).';

-- ----------------------------------------------------------------------------
-- vista_creditos
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.vista_creditos(p_usuario_id uuid)
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
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);               -- uniformidad del cobro perezoso: el saldo y los intereses de bolsillos/CDT quedan al día
  -- UNA sola sentencia = UNA sola foto de todos los créditos vigentes
  SELECT coalesce((SELECT jsonb_agg(jsonb_build_object('id', k.id, 'producto', p.nombre,
                                                       'cuotas_pagadas',   (SELECT count(*) FROM public.cuota q WHERE q.credito_id = k.id AND q.pagada),
                                                       'cuotas_faltantes', (SELECT count(*) FROM public.cuota q WHERE q.credito_id = k.id AND NOT q.pagada),
                                                       'interes_mes',      public._interes_corriendo(k.id, v_hoy),
                                                       'saldo',            k.capital_pendiente,
                                                       'descuento_automatico', k.descuento_automatico,                       -- E9: los «opcionales futuros» del contrato §3.5
                                                       'mora_acumulada',   public._mora_pendiente(k.id, v_hoy))
                                    ORDER BY k.fecha_desembolso, k.id)
                     FROM public.credito k JOIN public.credito_producto p ON p.id = k.producto_id
                    WHERE k.cuenta_id = c.id AND k.estado = 'ACTIVO'), '[]'::jsonb)
    INTO r FROM public.cuenta c WHERE c.id = v_cta;
  IF r IS NULL THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';             -- el usuario fue borrado durante la operación
  END IF;
  RETURN r;
END
$$;
COMMENT ON FUNCTION public.vista_creditos(uuid) IS
  'E8. GET /creditos/mis-creditos. [{id, producto, cuotas_pagadas, cuotas_faltantes, interes_mes, saldo}] de los créditos ACTIVOS (por fecha de desembolso e id): saldo = capital_pendiente; interes_mes = _interes_corriendo (derivado, D-E8-4 PROVISIONAL). UNA _reloj_instantanea() y _avanzar_hasta antes de leer; luego una sola sentencia. E9 añade descuento_automatico (bool) y mora_acumulada (mora derivada de las cuotas impagas vencidas hoy, _mora_pendiente). [] si no hay créditos.';

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
       AND p.proname IN ('productos_disponibles', 'productos_publicos', 'simular_credito', 'solicitar_credito', 'vista_creditos',
                         '_producto_credito', '_validar_plazo', '_limites_credito', '_verificar_credito')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
    IF f.proname IN ('productos_disponibles', 'productos_publicos', 'simular_credito', 'solicitar_credito', 'vista_creditos') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO banco_app', f.firma);
    END IF;
  END LOOP;
END
$$;

COMMIT;
