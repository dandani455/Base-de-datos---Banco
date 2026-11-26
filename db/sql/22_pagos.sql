-- ============================================================================
-- 22_pagos.sql  ·  Etapa 9 (pagos, abonos, mora y descuento automático) · parte 2/2: funciones y cobro automático
-- Propósito  : pagar la próxima cuota, abonar a capital, activar/desactivar el descuento automático y el cobro automático CRONOLÓGICO que llama _avanzar_hasta (17).
--              TODO el dinero se mueve SOLO por _asentar_grupo; cada operación es una transacción: libro + cuotas + crédito + verificación de ct_credito_plan.
--
--   Públicas (EXECUTE solo banco_app; banco_dev por herencia):
--     pagar_cuota(usuario, credito_id text, numero int DEFAULT NULL)  -> jsonb {numero, pagado, mora, fecha}          (plan; sin endpoint en el contrato: D10)
--     abonar_credito(usuario, credito_id text, monto numeric)          -> jsonb {fecha, mora, interes, capital, saldo, cuota_nueva}   (POST /creditos/:id/abono)
--     activar_descuento_automatico(usuario, credito_id text, activo boolean) -> jsonb {id, descuento_automatico}      (plan: POST /creditos/:id/descuento: D10)
--   Internas (sin EXECUTE para nadie salvo el dueño):
--     _credito_propio(cuenta, texto)        el crédito ACTIVO de ESA cuenta o 'Recurso no encontrado'
--     _pagar_cuota_interna(cuenta, credito, numero, fecha, dia)   asienta CREDITO_CUOTA (+ CREDITO_MORA), marca la cuota, mueve el ancla, cierra el crédito
--     _cobrar_creditos(cuenta, hoy, ahora)  el cobro automático (§7 del diseño v1.2): cursores individuales, cierres de CDT desde el menor cursor, rondas cronológicas
--
-- Orden de validación (como E8): sesión -> monto/booleano -> crédito propio y vigente -> [instantánea] -> _avanzar_hasta -> bloqueo de la cuenta -> crédito de nuevo
--                                -> reglas del caso -> libro -> plan -> SET CONSTRAINTS ct_credito_plan IMMEDIATE.
-- D7 (mora, abono, cobro), D1 (tasas) y D10 (firmas) son decisiones del EQUIPO: aquí los valores son PROVISIONALES y viven en 21 (_mora_cuota, _plan_restante, _reglas_pago).
-- Dependencias : 00 a 21.   Ejecución: como superusuario, IDEMPOTENTE, transaccional.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- _credito_propio
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._credito_propio(p_cuenta_id uuid, p_texto text)
RETURNS public.credito LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_txt text := nullif(btrim(coalesce(p_texto, '')), '');
  k     public.credito;
BEGIN
  -- texto (no uuid): un uuid mal formado sería un error de driver (503 en el backend); aquí es un error de negocio
  IF v_txt IS NULL OR v_txt !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO k FROM public.credito x WHERE x.id = v_txt::uuid AND x.cuenta_id = p_cuenta_id AND x.estado = 'ACTIVO';
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';       -- ajeno, inexistente o ya PAGADO: no se distingue
  END IF;
  RETURN k;
END
$$;
COMMENT ON FUNCTION public._credito_propio(uuid, text) IS
  'E9. Interna. El crédito ACTIVO de esa cuenta cuyo id es el uuid de p_texto; texto nulo, vacío, mal formado, inexistente, de otra cuenta o ya PAGADO: "Recurso no encontrado" (P0001), sin distinguir los casos.';

-- ----------------------------------------------------------------------------
-- _pagar_cuota_interna: paga la cuota `numero` (impaga) con fecha de asiento p_fecha y mora calculada hasta p_dia
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._pagar_cuota_interna(p_cuenta_id uuid, p_credito_id uuid, p_numero integer, p_fecha timestamptz, p_dia date)
RETURNS numeric LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  q       public.cuota;
  k       public.credito;
  v_nom   text;
  v_mora  numeric;
  v_patas jsonb;
BEGIN
  SELECT * INTO q FROM public.cuota z WHERE z.credito_id = p_credito_id AND z.numero = p_numero AND NOT z.pagada FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Créditos: la cuota % del crédito % no existe o ya está pagada', p_numero, p_credito_id USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO k FROM public.credito x WHERE x.id = p_credito_id FOR NO KEY UPDATE;
  SELECT pr.nombre INTO v_nom FROM public.credito_producto pr WHERE pr.id = k.producto_id;
  v_mora := public._mora_de_cuota(p_credito_id, p_numero, p_dia);               -- hasta la fecha REAL del intento (D-E9-3 / v1.1)
  -- CREDITO_CUOTA: CUENTA S (capital + interes), CREDITO S capital, RESULTADO S interes (sin la pata de interes si es 0: una pata no puede ser de monto 0)
  v_patas := jsonb_build_array(
    jsonb_build_object('tipo', 'CREDITO_CUOTA', 'contenedor', 'CUENTA',  'sentido', 'S', 'monto', q.valor_cuota,         'cuenta_id', p_cuenta_id, 'credito_id', p_credito_id, 'contraparte_nombre', v_nom),
    jsonb_build_object('tipo', 'CREDITO_CUOTA', 'contenedor', 'CREDITO', 'sentido', 'S', 'monto', q.capital_programado,  'cuenta_id', p_cuenta_id, 'credito_id', p_credito_id, 'contraparte_nombre', v_nom));
  IF q.interes_programado > 0 THEN
    v_patas := v_patas || jsonb_build_array(
      jsonb_build_object('tipo', 'CREDITO_CUOTA', 'contenedor', 'RESULTADO', 'sentido', 'S', 'monto', q.interes_programado, 'cuenta_id', p_cuenta_id, 'credito_id', p_credito_id, 'contraparte_nombre', 'Banco Digital'));
  END IF;
  PERFORM public._asentar_grupo(p_fecha, v_patas);
  IF v_mora > 0 THEN                                                           -- la mora va en un grupo APARTE (CREDITO_MORA: CUENTA S + RESULTADO S)
    PERFORM public._asentar_grupo(p_fecha, jsonb_build_array(
      jsonb_build_object('tipo', 'CREDITO_MORA', 'contenedor', 'CUENTA',    'sentido', 'S', 'monto', v_mora, 'cuenta_id', p_cuenta_id, 'credito_id', p_credito_id, 'contraparte_nombre', v_nom,
                         'nota', 'Mora cuota ' || p_numero),
      jsonb_build_object('tipo', 'CREDITO_MORA', 'contenedor', 'RESULTADO', 'sentido', 'S', 'monto', v_mora, 'cuenta_id', p_cuenta_id, 'credito_id', p_credito_id, 'contraparte_nombre', 'Banco Digital',
                         'nota', 'Mora cuota ' || p_numero)));
  END IF;
  UPDATE public.cuota SET pagada = true, fecha_pago = p_dia, capital_pagado = capital_programado, intereses_pagados = intereses_pagados + interes_programado
   WHERE id = q.id;
  -- regla R: el ancla = vencimiento de la cuota pagada (futura si se pagó por adelantado) y nunca retrocede
  UPDATE public.credito SET fecha_interes = greatest(fecha_interes, q.fecha_vencimiento) WHERE id = p_credito_id;
  IF NOT EXISTS (SELECT 1 FROM public.cuota z WHERE z.credito_id = p_credito_id AND NOT z.pagada) THEN
    UPDATE public.credito SET estado = 'PAGADO' WHERE id = p_credito_id;      -- el libro ya dejó capital_pendiente en 0
  END IF;
  RETURN v_mora;
END
$$;
COMMENT ON FUNCTION public._pagar_cuota_interna(uuid, uuid, integer, timestamptz, date) IS
  'E9. Interna (la llaman pagar_cuota y _cobrar_creditos con la cuenta YA bloqueada). Paga la cuota p_numero (impaga): grupo CREDITO_CUOTA (CUENTA S valor, CREDITO S capital, RESULTADO S interés si > 0) con fecha p_fecha y, si hay mora a la fecha p_dia, un grupo CREDITO_MORA aparte; marca la cuota (pagada, fecha_pago, capital_pagado = capital_programado, intereses_pagados += interés), mueve fecha_interes al vencimiento (regla R) y cierra el crédito si era la última. Devuelve la mora cobrada. Todo el dinero por _asentar_grupo.';

-- ----------------------------------------------------------------------------
-- _cobrar_creditos: el cobro automático cronológico (diseño v1.2, §7)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._cobrar_creditos(p_cuenta_id uuid, p_hoy date, p_ahora timestamptz)
RETURNS integer LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_cmin   date;
  v_fechas date[];
  d        date;
  v_n      integer := 0;
  v_bloq   uuid[];
  v_fecha  timestamptz;
  v_saldo  numeric;
  v_corte  timestamptz;
  r        record;
  v_mora   numeric;
BEGIN
  -- elegibles: créditos ACTIVOS con descuento y cobro_hasta <= hoy (con cobro_hasta > hoy el reloj volvió a real: en pausa, no se procesa ni se escribe nada)
  SELECT min(k.cobro_hasta) INTO v_cmin
    FROM public.credito k
   WHERE k.cuenta_id = p_cuenta_id AND k.estado = 'ACTIVO' AND k.cobro_hasta IS NOT NULL AND k.cobro_hasta <= p_hoy;
  IF v_cmin IS NULL THEN
    RETURN 0;
  END IF;
  -- fechas-evento: vencimientos con el cursor INDIVIDUAL de cada crédito + cierres de CDT de la CUENTA desde el MENOR cursor + hoy
  SELECT array_agg(DISTINCT s.f ORDER BY s.f) INTO v_fechas FROM (
    SELECT q.fecha_vencimiento AS f
      FROM public.credito k JOIN public.cuota q ON q.credito_id = k.id
     WHERE k.cuenta_id = p_cuenta_id AND k.estado = 'ACTIVO' AND k.cobro_hasta IS NOT NULL AND k.cobro_hasta <= p_hoy
       AND NOT q.pagada AND q.fecha_vencimiento > k.cobro_hasta AND q.fecha_vencimiento <= p_hoy
    UNION
    SELECT c.fecha_fin FROM public.cdt c WHERE c.cuenta_id = p_cuenta_id AND c.estado = 'ACTIVO' AND c.fecha_fin > v_cmin AND c.fecha_fin <= p_hoy
    UNION
    SELECT p_hoy) s;
  FOREACH d IN ARRAY v_fechas LOOP
    -- 1) PRIMERO se cierran los CDT con fecha_fin <= d (cierre global de la cuenta; E7 sin cambios)
    v_n := v_n + public._devengar_cdts(p_cuenta_id, d, p_ahora);
    -- 2) DESPUÉS la ronda de cobro: candidata = la PRÓXIMA cuota impaga con v <= d de cada crédito elegible cuya ventana incluya d (d > cobro_hasta, o d = hoy)
    v_fecha := CASE WHEN d < p_hoy THEN (d::timestamp AT TIME ZONE 'America/Bogota') ELSE p_ahora END;
    v_bloq  := ARRAY[]::uuid[];
    v_corte := CASE WHEN d < p_hoy THEN v_fecha ELSE 'infinity'::timestamptz END;   -- instante del evento histórico (d 00:00 Bogotá): lo que entró DESPUÉS (aunque sea el mismo día) no existía; en la ronda de hoy cuenta todo
    LOOP
      SELECT k.id AS credito_id, q.numero, q.valor_cuota, q.fecha_vencimiento INTO r
        FROM public.credito k
        JOIN public.cuota q ON q.credito_id = k.id AND q.numero = (SELECT min(z.numero) FROM public.cuota z WHERE z.credito_id = k.id AND NOT z.pagada)
       WHERE k.cuenta_id = p_cuenta_id AND k.estado = 'ACTIVO' AND k.cobro_hasta IS NOT NULL AND k.cobro_hasta <= p_hoy
         AND (d = p_hoy OR d > k.cobro_hasta)
         AND q.fecha_vencimiento <= d
         AND NOT (k.id = ANY (v_bloq))
       ORDER BY q.fecha_vencimiento, k.fecha_desembolso, k.id
       LIMIT 1;
      EXIT WHEN NOT FOUND;
      v_mora  := public._mora_de_cuota(r.credito_id, r.numero, d);               -- la mora llega hasta la fecha REAL del intento d
      -- saldo DISPONIBLE al instante del evento: el saldo actual menos lo que ENTRÓ a la cuenta con fecha POSTERIOR a ese instante (un envío recibido el día 20 a las 14:00 no paga una cuota
      -- en la ronda histórica del día 20 ni en la del 15: se cobra en la ronda de hoy, con la mora hasta hoy). Los cierres de CDT de este recorrido llevan fecha = d 00:00 = el instante del evento y sí cuentan.
      SELECT c.balance - coalesce((SELECT sum(t.monto) FROM public.transaccion t
                                    WHERE t.cuenta_id = c.id AND t.contenedor = 'CUENTA' AND t.sentido = 'E' AND t.fecha > v_corte), 0)
        INTO v_saldo FROM public.cuenta c WHERE c.id = p_cuenta_id;
      IF v_saldo >= r.valor_cuota + v_mora THEN                                    -- todo o nada, con el saldo DISPONIBLE de la cuenta principal a la fecha d
        PERFORM public._pagar_cuota_interna(p_cuenta_id, r.credito_id, r.numero, v_fecha, d);
        v_n := v_n + 1 + CASE WHEN v_mora > 0 THEN 1 ELSE 0 END;
      ELSE
        v_bloq := v_bloq || r.credito_id;                                          -- ese crédito no cobra más en esta ronda; los demás siguen
      END IF;
    END LOOP;
  END LOOP;
  -- el cursor avanza en la MISMA transacción (solo si hoy lo supera; con hoy = cursor no se escribe)
  UPDATE public.credito k SET cobro_hasta = p_hoy
   WHERE k.cuenta_id = p_cuenta_id AND k.estado = 'ACTIVO' AND k.cobro_hasta IS NOT NULL AND k.cobro_hasta < p_hoy;
  RETURN v_n;
END
$$;
COMMENT ON FUNCTION public._cobrar_creditos(uuid, date, timestamptz) IS
  'E9. Interna (la llama _avanzar_hasta con la cuenta YA bloqueada). Cobro automático cronológico (diseño v1.2 §7): elegibles = créditos ACTIVOS con descuento y cobro_hasta <= hoy (con cobro_hasta > hoy no hace nada); fechas-evento = vencimientos de cada crédito con SU cursor + cierres de CDT desde el MENOR cursor + hoy; en cada fecha d: 1) _devengar_cdts(d) cierra los CDT; 2) ronda: la próxima cuota impaga con v <= d de cada crédito con d en su ventana, la más antigua primero, se paga con fecha d (00:00 Bogotá si d < hoy, la instantánea si d = hoy) y mora hasta d si el saldo de la cuenta principal alcanza (todo o nada; un crédito inalcanzable no bloquea a los demás); el saldo disponible al instante del evento (d 00:00 Bogotá si d < hoy; todo si d = hoy) excluye lo que entró a la cuenta con fecha posterior a ese instante, aunque sea del mismo día d; al final cobro_hasta = hoy. No lee el reloj. Devuelve los grupos escritos.';

-- ----------------------------------------------------------------------------
-- pagar_cuota
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pagar_cuota(p_usuario_id uuid, p_credito_id text, p_numero integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u       public.usuario;
  v_cta   uuid;
  k       public.credito;
  q       public.cuota;
  v_hoy   date;
  v_ahora timestamptz;
  v_mora  numeric;
  v_msg   text;
BEGIN
  u := public._validar_cliente(p_usuario_id);
  IF p_numero IS NOT NULL AND p_numero < 1 THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  SELECT c.id INTO v_cta FROM public.cuenta c WHERE c.usuario_id = u.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END IF;
  k := public._credito_propio(v_cta, p_credito_id);
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);                          -- devenga y cobra lo automático ANTES de decidir qué cuota toca
  IF public._bloquear_cuentas(ARRAY[v_cta]) <> 1 THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END IF;
  k := public._credito_propio(v_cta, p_credito_id);                              -- bajo el bloqueo: el motor pudo haber pagado la última cuota
  q := public._proxima_cuota(k.id);
  IF q.id IS NULL OR (p_numero IS NOT NULL AND p_numero <> q.numero) THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';  -- D-E9-8: con `numero` la cuota ya pagada (o no la próxima) NO paga otra
  END IF;
  BEGIN
    v_mora := public._pagar_cuota_interna(v_cta, k.id, q.numero, v_ahora, v_hoy);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'Libro mayor:%' AND NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = v_cta) THEN
      RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';   -- carrera con el borrado: se traduce
    END IF;
    RAISE;                                                                          -- 'Saldo insuficiente' pasa tal cual y revierte TODO
  END;
  SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota IMMEDIATE;
  SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota DEFERRED;
  RETURN jsonb_build_object('numero', q.numero, 'pagado', q.valor_cuota + v_mora, 'mora', v_mora, 'fecha', v_ahora);
END
$$;
COMMENT ON FUNCTION public.pagar_cuota(uuid, text, integer) IS
  'E9. Paga la PRÓXIMA cuota impaga completa (D-E9-2, D7 PROVISIONAL): sesión, crédito propio y vigente (Recurso no encontrado), UNA _reloj_instantanea(), _avanzar_hasta, bloqueo de la cuenta; `numero` opcional (D-E9-8, D10): si se envía y no es la próxima impaga responde Recurso no encontrado y NO paga otra. Importe = valor_cuota + mora hasta hoy; grupo CREDITO_CUOTA (+ CREDITO_MORA), cuota pagada, ancla fecha_interes = vencimiento, la última cierra el crédito; Saldo insuficiente revierte todo; ct_credito_plan se verifica antes de volver. Devuelve {numero, pagado, mora, fecha} (D-E9-11, D10). Sin endpoint en el contrato.';

-- ----------------------------------------------------------------------------
-- abonar_credito
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.abonar_credito(p_usuario_id uuid, p_credito_id text, p_monto numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u       public.usuario;
  v_monto numeric;
  v_cta   uuid;
  k       public.credito;
  q       public.cuota;
  v_hoy   date;
  v_ahora timestamptz;
  v_mora  numeric;      -- M: mora vencida
  v_int   numeric;      -- I: interés corriendo del período
  v_cap   numeric;      -- capital pendiente antes del abono
  v_r     numeric;      -- capital abonado
  v_nom   text;
  v_s     date;
  v_v     date;
  v_eff   date;
  v_l     integer;
  v_rem   numeric;
  v_j0    numeric;
  v_m     integer;
  v_nueva numeric := 0;
  v_patas jsonb;
  v_msg   text;
BEGIN
  u       := public._validar_cliente(p_usuario_id);
  v_monto := public._validar_monto(p_monto);
  SELECT c.id INTO v_cta FROM public.cuenta c WHERE c.usuario_id = u.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END IF;
  k := public._credito_propio(v_cta, p_credito_id);
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);
  IF public._bloquear_cuentas(ARRAY[v_cta]) <> 1 THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END IF;
  k := public._credito_propio(v_cta, p_credito_id);                              -- bajo el bloqueo
  q := public._proxima_cuota(k.id);
  IF q.id IS NULL THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  SELECT pr.nombre INTO v_nom FROM public.credito_producto pr WHERE pr.id = k.producto_id;
  -- D-E9-4 (PROVISIONAL, D7): (1) mora vencida -> (2) interés corriendo del período -> (3) capital
  v_mora := public._mora_pendiente(k.id, v_hoy);
  v_int  := public._interes_corriendo(k.id, v_hoy);
  v_cap  := k.capital_pendiente;
  IF v_monto <= v_mora + v_int OR v_monto > v_mora + v_int + v_cap THEN          -- no reduciría capital, o excede la liquidación
    RAISE EXCEPTION '%', (public._reglas_credito() ->> 'msg_monto') USING ERRCODE = 'P0001';
  END IF;
  v_r := v_monto - v_mora - v_int;
  BEGIN
    IF v_mora > 0 THEN                                                            -- CREDITO_MORA: CUENTA S + RESULTADO S
      PERFORM public._asentar_grupo(v_ahora, jsonb_build_array(
        jsonb_build_object('tipo', 'CREDITO_MORA', 'contenedor', 'CUENTA',    'sentido', 'S', 'monto', v_mora, 'cuenta_id', v_cta, 'credito_id', k.id, 'contraparte_nombre', v_nom, 'nota', 'Mora en abono'),
        jsonb_build_object('tipo', 'CREDITO_MORA', 'contenedor', 'RESULTADO', 'sentido', 'S', 'monto', v_mora, 'cuenta_id', v_cta, 'credito_id', k.id, 'contraparte_nombre', 'Banco Digital', 'nota', 'Mora en abono')));
    END IF;
    -- CREDITO_ABONO: CUENTA S (capital + interés), CREDITO S capital, RESULTADO S interés (sin la pata de interés si es 0)
    v_patas := jsonb_build_array(
      jsonb_build_object('tipo', 'CREDITO_ABONO', 'contenedor', 'CUENTA',  'sentido', 'S', 'monto', v_r + v_int, 'cuenta_id', v_cta, 'credito_id', k.id, 'contraparte_nombre', v_nom),
      jsonb_build_object('tipo', 'CREDITO_ABONO', 'contenedor', 'CREDITO', 'sentido', 'S', 'monto', v_r,          'cuenta_id', v_cta, 'credito_id', k.id, 'contraparte_nombre', v_nom));
    IF v_int > 0 THEN
      v_patas := v_patas || jsonb_build_array(
        jsonb_build_object('tipo', 'CREDITO_ABONO', 'contenedor', 'RESULTADO', 'sentido', 'S', 'monto', v_int, 'cuenta_id', v_cta, 'credito_id', k.id, 'contraparte_nombre', 'Banco Digital'));
    END IF;
    PERFORM public._asentar_grupo(v_ahora, v_patas);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'Libro mayor:%' AND NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = v_cta) THEN
      RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
    END IF;
    RAISE;                                                                          -- 'Saldo insuficiente' pasa tal cual
  END;
  -- el plan: período de la primera impaga j = [s_j, v_j]; ancla efectiva = clamp(hoy, s_j, v_j) sin retroceder (regla R)
  v_s   := public._inicio_periodo(k.id, q.numero);
  v_v   := q.fecha_vencimiento;
  v_eff := least(greatest(v_hoy, k.fecha_interes, v_s), v_v);
  IF v_r = v_cap THEN
    -- LIQUIDACIÓN (D-E9-5): las cuotas restantes quedan pagadas (extinguidas por abono: capital_pagado = 0) y el crédito PAGADO
    UPDATE public.cuota SET intereses_pagados = intereses_pagados + v_int WHERE id = q.id;
    UPDATE public.cuota SET pagada = true, fecha_pago = v_hoy WHERE credito_id = k.id AND NOT pagada;
    UPDATE public.credito SET estado = 'PAGADO', fecha_interes = v_eff WHERE id = k.id;
  ELSE
    SELECT count(*) INTO v_m FROM public.cuota z WHERE z.credito_id = k.id AND NOT z.pagada;
    v_l   := v_v - v_s;
    v_rem := CASE WHEN v_l > 0 THEN (v_v - v_eff)::numeric / v_l ELSE 0 END;     -- parte del período COMPLETO que aún falta (no «1 - f» del abono)
    v_j0  := round((v_cap - v_r) * public._tasa_mensual(k.tasa_anual) * v_rem, 2);
    UPDATE public.cuota c SET capital_programado = p.capital, interes_programado = p.interes, valor_cuota = p.cuota
      FROM (SELECT z.id, row_number() OVER (ORDER BY z.numero) AS rn FROM public.cuota z WHERE z.credito_id = k.id AND NOT z.pagada) u2
      JOIN public._plan_restante(v_cap - v_r, k.tasa_anual, v_m, v_j0) p ON p.numero = u2.rn
     WHERE c.id = u2.id;
    UPDATE public.cuota SET intereses_pagados = intereses_pagados + v_int WHERE id = q.id;
    UPDATE public.credito SET fecha_interes = v_eff WHERE id = k.id;
    SELECT p.cuota INTO v_nueva FROM public._plan_restante(v_cap - v_r, k.tasa_anual, v_m, v_j0) p WHERE p.numero = 1;
  END IF;
  IF v_mora > 0 THEN                                                              -- la mora ya cobrada no se vuelve a cobrar: el reloj de la mora de las vencidas arranca hoy
    UPDATE public.credito SET mora_hasta = greatest(coalesce(mora_hasta, v_hoy), v_hoy) WHERE id = k.id;
  END IF;
  SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota IMMEDIATE;
  SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota DEFERRED;
  RETURN jsonb_build_object('fecha', v_ahora, 'mora', v_mora, 'interes', v_int, 'capital', v_r, 'saldo', v_cap - v_r, 'cuota_nueva', v_nueva);
END
$$;
COMMENT ON FUNCTION public.abonar_credito(uuid, text, numeric) IS
  'E9. POST /creditos/:id/abono. Abono extraordinario (D-E9-4/5, D7 PROVISIONAL): orden de cobro mora vencida -> interés corriendo -> capital; monto <= mora + interés (no reduce capital) o mayor que la liquidación = Monto fuera de rango (mensaje del contrato; ninguno nuevo). Libro: CREDITO_MORA (si hay) + CREDITO_ABONO. Recalcula las cuotas impagas SIN cambiar plazo ni vencimientos: primer período corto j0 = K''·i·rem (rem medida contra el período COMPLETO), cuota fija _plan_restante, la última absorbe; fecha_interes = clamp(hoy, s_j, v_j) sin retroceder; intereses_pagados de la cuota j suma el interés cobrado; liquidación (capital = pendiente) marca las cuotas restantes pagadas y el crédito PAGADO; la mora cobrada fija mora_hasta = hoy. ct_credito_plan se verifica antes de volver. Devuelve {fecha, mora, interes, capital, saldo, cuota_nueva} (D10).';

-- ----------------------------------------------------------------------------
-- activar_descuento_automatico
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.activar_descuento_automatico(p_usuario_id uuid, p_credito_id text, p_activo boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u       public.usuario;
  v_cta   uuid;
  k       public.credito;
  v_hoy   date;
  v_ahora timestamptz;
BEGIN
  u := public._validar_cliente(p_usuario_id);
  IF p_activo IS NULL THEN
    RAISE EXCEPTION '%', public._msg_negocio('recurso') USING ERRCODE = 'P0001';
  END IF;
  SELECT c.id INTO v_cta FROM public.cuenta c WHERE c.usuario_id = u.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END IF;
  k := public._credito_propio(v_cta, p_credito_id);
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);                          -- el motor procesa lo pendiente ANTES de cambiar el cursor
  IF public._bloquear_cuentas(ARRAY[v_cta]) <> 1 THEN
    RAISE EXCEPTION '%', public._msg_auth('sesion') USING ERRCODE = 'P0001';
  END IF;
  k := public._credito_propio(v_cta, p_credito_id);
  IF p_activo AND k.cobro_hasta IS NULL THEN
    -- NULL -> hoy: lo vencido antes de hoy NO se cobra con fecha retroactiva (queda fuera de la ventana; se cobra en la primera ronda con fecha >= hoy)
    UPDATE public.credito SET descuento_automatico = true, cobro_hasta = v_hoy WHERE id = k.id;
  ELSIF NOT p_activo AND k.cobro_hasta IS NOT NULL THEN
    UPDATE public.credito SET descuento_automatico = false, cobro_hasta = NULL WHERE id = k.id;   -- fecha -> NULL: siempre permitido
  END IF;                                                                          -- activar un crédito ya activo (o desactivar uno apagado): no-op, el cursor NO se mueve
  RETURN jsonb_build_object('id', k.id, 'descuento_automatico', p_activo);
END
$$;
COMMENT ON FUNCTION public.activar_descuento_automatico(uuid, text, boolean) IS
  'E9. Activa o desactiva el descuento automático de un crédito (D-E9-6, D7 PROVISIONAL; sin endpoint en el contrato, D10). Activar con el descuento apagado: cobro_hasta = hoy (NULL -> fecha; sin cobros retroactivos); ya activo: no-op idempotente (el cursor no se mueve); desactivar: cobro_hasta = NULL (fecha -> NULL, también con el reloj por detrás del cursor). Corre _avanzar_hasta antes. Devuelve {id, descuento_automatico}.';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- Permisos: las 3 públicas -> banco_app (banco_dev las hereda); los helpers -> nadie salvo el dueño
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma, p.proname FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('pagar_cuota', 'abonar_credito', 'activar_descuento_automatico', '_credito_propio', '_pagar_cuota_interna', '_cobrar_creditos')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
    IF f.proname IN ('pagar_cuota', 'abonar_credito', 'activar_descuento_automatico') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO banco_app', f.firma);
    END IF;
  END LOOP;
END
$$;

COMMIT;
