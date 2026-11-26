-- ============================================================================
-- 07_libro_mayor_funciones.sql  ·  Etapa 2 (libro mayor y guardias) · parte 2/4
-- Propósito  : las funciones del libro mayor. Los triggers que las usan se crean en 08.
--
--   _asentar_grupo(fecha, patas jsonb) -> uuid   ÚNICO escritor autorizado del libro (SECURITY DEFINER)
--   trg_transaccion_a_validar()   BEFORE INSERT: fuerza registrado_en/tx_id, descarta saldos del llamador,
--                                 sella el grupo, comprueba que cada producto es de la cuenta de la pata
--   trg_transaccion_b_aplicar()   BEFORE INSERT: DUEÑO banco_ledger. Bloquea el contenedor, calcula saldo
--                                 previo/posterior y actualiza el acumulador (único camino de escritura)
--   ct_transaccion_cuadre()       trigger de restricción diferido: partida doble, plantilla, sellado...
--   ct_cdt_inversion()            trigger de restricción diferido: invariantes del CDT
--   trg_transaccion_inmutable()   BEFORE UPDATE/DELETE: el historial no se reescribe
--   trg_transaccion_truncate()    BEFORE TRUNCATE: el historial no se vacía
--   trg_zz_proteger_<tabla>()     guardias de acumuladores, columnas inmutables y ciclo de vida (SECURITY INVOKER
--                                 A PROPÓSITO: deben ver quién ejecuta el UPDATE, no al dueño de la función)
--   trg_cuenta_auditar_borrado()  deja en audit.evento lo que se destruye al borrar una cuenta
--   trg_evento_ddl() / trg_evento_drop()   funciones de los event triggers de DDL (se crean en 08)
--   _plantillas_validas()         catálogo de formas válidas de un grupo
--
-- Seguridad: todas con search_path fijo; ninguna es ejecutable por PUBLIC ni por banco_app/lector/dev.
-- Mensajes: solo "Saldo insuficiente" es del contrato; el resto son internos ("Libro mayor: ...", P0001).
-- Dependencias : 01 a 06.   Ejecución: como superusuario, IDEMPOTENTE (CREATE OR REPLACE), transaccional.
-- Verificar    : SELECT proname, pg_get_userbyid(proowner) AS dueno, prosecdef AS definer
--                  FROM pg_proc WHERE pronamespace = 'public'::regnamespace ORDER BY 1;
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- Catálogo de formas válidas de un grupo (plantillas). Cada forma = conjunto de
-- 'tipo|contenedor|sentido' ordenado (COLLATE "C"). CREDITO_CUOTA / CREDITO_ABONO / CREDITO_MORA NO
-- tienen plantilla hasta E9 (D-E9-7): desde E9 tienen 5 (cuota y abono con y sin interés, y mora). ct_transaccion_cuadre conserva sus reglas generales de coherencia.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._plantillas_validas()
RETURNS TABLE (plantilla text, patas text[])
LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT p.n, (SELECT array_agg(x ORDER BY x COLLATE "C") FROM unnest(p.a) AS x)
    FROM (VALUES
      ('ENVIO_CUENTA',        ARRAY['ENVIO|CUENTA|S',    'RECIBO|CUENTA|E']),
      ('ENVIO_BOLSILLO',      ARRAY['ENVIO|BOLSILLO|S',  'RECIBO|CUENTA|E']),
      ('BOLSO_INGRESO',       ARRAY['BOLSO_INGRESO|CUENTA|S',   'BOLSO_INGRESO|BOLSILLO|E']),
      ('BOLSO_RETIRO',        ARRAY['BOLSO_RETIRO|BOLSILLO|S',  'BOLSO_RETIRO|CUENTA|E']),
      ('BOLSO_MOVIMIENTO',    ARRAY['BOLSO_MOVIMIENTO|BOLSILLO|S', 'BOLSO_MOVIMIENTO|BOLSILLO|E']),
      ('INTERES_BOLSO',       ARRAY['INTERES_BOLSO|BOLSILLO|E', 'INTERES_BOLSO|RESULTADO|E']),
      ('CDT_CREACION',        ARRAY['CDT_CREACION|CUENTA|S',    'CDT_CREACION|CDT|E']),
      ('INTERES_CDT',         ARRAY['INTERES_CDT|CDT|E',        'INTERES_CDT|RESULTADO|E']),
      ('CDT_VENCIMIENTO',     ARRAY['CDT_VENCIMIENTO|CDT|S',    'CDT_VENCIMIENTO|CUENTA|E']),
      ('CREDITO_DESEMBOLSO',  ARRAY['CREDITO_DESEMBOLSO|CUENTA|E', 'CREDITO_DESEMBOLSO|CREDITO|E']),
      -- E9 (D-E9-7, prevista en D-E2-1): cuota, abono y mora (matriz contable C.4); sin pata de interés si el interés es 0 (una pata no puede ser de monto 0)
      ('CREDITO_CUOTA',               ARRAY['CREDITO_CUOTA|CUENTA|S', 'CREDITO_CUOTA|CREDITO|S', 'CREDITO_CUOTA|RESULTADO|S']),
      ('CREDITO_CUOTA_SIN_INTERES',   ARRAY['CREDITO_CUOTA|CUENTA|S', 'CREDITO_CUOTA|CREDITO|S']),
      ('CREDITO_ABONO',               ARRAY['CREDITO_ABONO|CUENTA|S', 'CREDITO_ABONO|CREDITO|S', 'CREDITO_ABONO|RESULTADO|S']),
      ('CREDITO_ABONO_SIN_INTERES',   ARRAY['CREDITO_ABONO|CUENTA|S', 'CREDITO_ABONO|CREDITO|S']),
      ('CREDITO_MORA',                ARRAY['CREDITO_MORA|CUENTA|S', 'CREDITO_MORA|RESULTADO|S']),
      ('INGRESO_SIMULADO',    ARRAY['INGRESO_SIMULADO|CUENTA|E', 'INGRESO_SIMULADO|RESULTADO|E']),
      ('BONO_REFERIDO',       ARRAY['BONO_REFERIDO|CUENTA|E',    'BONO_REFERIDO|RESULTADO|E']),
      ('DEPOSITO_BANCO',      ARRAY['DEPOSITO_BANCO|CUENTA|E',   'DEPOSITO_BANCO|RESULTADO|E']),
      ('AJUSTE_ADMIN_POS',    ARRAY['AJUSTE_ADMIN|CUENTA|E',     'AJUSTE_ADMIN|RESULTADO|E']),
      ('AJUSTE_ADMIN_NEG',    ARRAY['AJUSTE_ADMIN|CUENTA|S',     'AJUSTE_ADMIN|RESULTADO|S'])
    ) AS p(n, a)
$$;
COMMENT ON FUNCTION public._plantillas_validas() IS
  'E2. Catálogo de las formas válidas (15 en E2; 20 desde E9) de un grupo del libro mayor (conjunto ordenado de tipo|contenedor|sentido). E9 (D-E9-7) las amplía a 20: CUOTA/ABONO (con y sin interés) y MORA de crédito.';

-- ----------------------------------------------------------------------------
-- BEFORE INSERT (1/2): validar. Corre ANTES que trg_transaccion_b_aplicar (orden alfabético).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_transaccion_a_validar()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  -- Trazabilidad: la fija el libro, nunca el llamador.
  NEW.registrado_en := clock_timestamp();
  NEW.tx_id         := pg_current_xact_id();
  -- Los saldos los calcula el libro (trg_transaccion_b_aplicar): lo que traiga el llamador se descarta.
  NEW.saldo_previo := NULL;
  NEW.saldo_posterior := NULL;

  -- Reloj del banco (E3): una pata no puede estar fechada DESPUÉS del "hoy" del banco. Se compara la FECHA de negocio en
  -- America/Bogota (no la zona de la sesión) con hoy_banco(); las fechas pasadas se aceptan (cobro lazy, seed, etc.).
  IF (NEW.fecha AT TIME ZONE 'America/Bogota')::date > public.hoy_banco() THEN
    RAISE EXCEPTION 'Libro mayor: la fecha de la pata (%) es posterior al reloj del banco (%)',
                    (NEW.fecha AT TIME ZONE 'America/Bogota')::date, public.hoy_banco()
      USING ERRCODE = 'P0001';
  END IF;

  -- Sellado: no se puede agregar una pata a un grupo ya confirmado por otra transacción.
  IF EXISTS (SELECT 1 FROM public.transaccion t WHERE t.grupo_id = NEW.grupo_id AND t.tx_id <> NEW.tx_id) THEN
    RAISE EXCEPTION 'Libro mayor: el grupo % ya fue confirmado; un grupo no se amplía después' , NEW.grupo_id
      USING ERRCODE = 'P0001';
  END IF;

  -- Propiedad: cada producto referenciado debe ser de la cuenta de la pata.
  IF NEW.bolsillo_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.bolsillo b WHERE b.id = NEW.bolsillo_id AND b.cuenta_id = NEW.cuenta_id) THEN
    RAISE EXCEPTION 'Libro mayor: el bolsillo % no pertenece a la cuenta %', NEW.bolsillo_id, NEW.cuenta_id
      USING ERRCODE = 'P0001';
  END IF;
  IF NEW.cdt_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.cdt c WHERE c.id = NEW.cdt_id AND c.cuenta_id = NEW.cuenta_id) THEN
    RAISE EXCEPTION 'Libro mayor: el CDT % no pertenece a la cuenta %', NEW.cdt_id, NEW.cuenta_id
      USING ERRCODE = 'P0001';
  END IF;
  IF NEW.credito_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.credito c WHERE c.id = NEW.credito_id AND c.cuenta_id = NEW.cuenta_id) THEN
    RAISE EXCEPTION 'Libro mayor: el crédito % no pertenece a la cuenta %', NEW.credito_id, NEW.cuenta_id
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;
COMMENT ON FUNCTION public.trg_transaccion_a_validar() IS
  'E2/E3. BEFORE INSERT en transaccion (1/2): fuerza registrado_en y tx_id, descarta saldos del llamador, rechaza patas fechadas después del hoy del banco (E3), sella el grupo y comprueba que cada producto referenciado es de la cuenta de la pata.';

-- ----------------------------------------------------------------------------
-- Trigger de restricción DIFERIDO: partida doble y forma del grupo.
-- SECURITY DEFINER (dueño banco_owner): un trigger diferido se dispara al COMMIT con el usuario de la SESIÓN (p. ej.
-- banco_app, que no puede leer transaccion), no con el de la función que insertó. Como definer la comprobación siempre puede
-- leer el libro y falla con su mensaje real. Solo lee tablas con SQL estático y search_path fijo.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ct_transaccion_cuadre()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  g        record;
  v_plant  text;
  e        record;
  r        record;
  v_num_e  text;
  v_num_r  text;
BEGIN
  SELECT count(*)                                                        AS n,
         count(DISTINCT t.cuenta_id)                                     AS cuentas,
         count(DISTINCT t.tx_id)                                         AS txs,
         count(DISTINCT t.fecha)                                         AS fechas,
         count(DISTINCT t.bolsillo_id)                                   AS bolsillos,
         count(DISTINCT t.cdt_id)                                        AS cdts,
         count(DISTINCT t.credito_id)                                    AS creditos,
         coalesce(sum(t.monto) FILTER (WHERE t.lado = 'D'), 0)           AS debitos,
         coalesce(sum(t.monto) FILTER (WHERE t.lado = 'C'), 0)           AS creditos_monto,
         array_agg(t.tipo::text || '|' || t.contenedor::text || '|' || t.sentido::text
                   ORDER BY (t.tipo::text || '|' || t.contenedor::text || '|' || t.sentido::text) COLLATE "C") AS forma,
         bool_and(t.tipo::text IN ('CREDITO_CUOTA','CREDITO_ABONO','CREDITO_MORA')) AS solo_credito_pend,
         bool_or (t.tipo::text IN ('CREDITO_CUOTA','CREDITO_ABONO','CREDITO_MORA')) AS algun_credito_pend
    INTO g
    FROM public.transaccion t
   WHERE t.grupo_id = NEW.grupo_id;

  IF g.n = 0 THEN
    RETURN NULL;                         -- el grupo ya no existe (se borró en la misma transacción)
  END IF;

  -- G1: al menos dos patas
  IF g.n < 2 THEN
    RAISE EXCEPTION 'Libro mayor: el grupo % tiene una sola pata (partida doble exige al menos dos)', NEW.grupo_id
      USING ERRCODE = 'P0001';
  END IF;
  -- G2: cuadre ΣD = ΣC
  IF g.debitos <> g.creditos_monto THEN
    RAISE EXCEPTION 'Libro mayor: el grupo % está descuadrado (débitos=%, créditos=%)', NEW.grupo_id, g.debitos, g.creditos_monto
      USING ERRCODE = 'P0001';
  END IF;
  -- G3: sellado (una sola transacción) y G4: una sola fecha de negocio
  IF g.txs <> 1 THEN
    RAISE EXCEPTION 'Libro mayor: las patas del grupo % no nacieron en la misma transacción', NEW.grupo_id
      USING ERRCODE = 'P0001';
  END IF;
  IF g.fechas <> 1 THEN
    RAISE EXCEPTION 'Libro mayor: las patas del grupo % tienen fechas distintas', NEW.grupo_id
      USING ERRCODE = 'P0001';
  END IF;

  IF g.algun_credito_pend THEN
    -- CUOTA / ABONO / MORA de crédito (E9: ahora SÍ tienen plantilla, que se exige más abajo). Reglas de coherencia generales, con sus mensajes de E2:
    -- todas las patas son de esos tipos, de UNA cuenta propietaria y de UN mismo crédito (que pertenece a
    -- esa cuenta: lo comprueba trg_transaccion_a_validar), sin transferencias entre cuentas y con cuadre.
    IF NOT g.solo_credito_pend THEN
      RAISE EXCEPTION 'Libro mayor: el grupo % mezcla patas de crédito con patas de otra familia', NEW.grupo_id
        USING ERRCODE = 'P0001';
    END IF;
    IF g.cuentas <> 1 THEN
      RAISE EXCEPTION 'Libro mayor: el grupo de crédito % involucra más de una cuenta', NEW.grupo_id
        USING ERRCODE = 'P0001';
    END IF;
    IF g.creditos <> 1 THEN
      RAISE EXCEPTION 'Libro mayor: el grupo de crédito % mezcla créditos distintos', NEW.grupo_id
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  -- G6: plantilla
  SELECT p.plantilla INTO v_plant FROM public._plantillas_validas() p WHERE p.patas = g.forma;
  IF v_plant IS NULL THEN
    RAISE EXCEPTION 'Libro mayor: el grupo % no corresponde a ninguna forma contable válida (%)', NEW.grupo_id, g.forma
      USING ERRCODE = 'P0001';
  END IF;

  -- G5 + coherencia por plantilla
  IF v_plant IN ('ENVIO_CUENTA', 'ENVIO_BOLSILLO') THEN
    IF g.cuentas <> 2 THEN
      RAISE EXCEPTION 'Libro mayor: una transferencia (grupo %) debe involucrar exactamente dos cuentas distintas', NEW.grupo_id
        USING ERRCODE = 'P0001';
    END IF;
    SELECT t.cuenta_id, t.contraparte_cuenta, t.contraparte_nombre INTO e
      FROM public.transaccion t WHERE t.grupo_id = NEW.grupo_id AND t.tipo = 'ENVIO';
    SELECT t.cuenta_id, t.contraparte_cuenta, t.contraparte_nombre INTO r
      FROM public.transaccion t WHERE t.grupo_id = NEW.grupo_id AND t.tipo = 'RECIBO';
    SELECT c.numero_cuenta INTO v_num_e FROM public.cuenta c WHERE c.id = e.cuenta_id;
    SELECT c.numero_cuenta INTO v_num_r FROM public.cuenta c WHERE c.id = r.cuenta_id;
    IF e.contraparte_cuenta IS DISTINCT FROM v_num_r OR r.contraparte_cuenta IS DISTINCT FROM v_num_e THEN
      RAISE EXCEPTION 'Libro mayor: en la transferencia % la contraparte_cuenta de cada pata debe ser el número de cuenta de la otra', NEW.grupo_id
        USING ERRCODE = 'P0001';
    END IF;
    IF btrim(coalesce(e.contraparte_nombre, '')) = '' OR btrim(coalesce(r.contraparte_nombre, '')) = '' THEN
      RAISE EXCEPTION 'Libro mayor: en la transferencia % falta contraparte_nombre', NEW.grupo_id
        USING ERRCODE = 'P0001';
    END IF;
  ELSE
    IF g.cuentas <> 1 THEN
      RAISE EXCEPTION 'Libro mayor: el grupo % (%) solo puede involucrar una cuenta; el dinero cruza cuentas únicamente en un par ENVIO/RECIBO', NEW.grupo_id, v_plant
        USING ERRCODE = 'P0001';
    END IF;
    IF v_plant IN ('BOLSO_INGRESO', 'BOLSO_RETIRO', 'INTERES_BOLSO') AND g.bolsillos <> 1 THEN
      RAISE EXCEPTION 'Libro mayor: las patas del grupo % (%) deben referirse al mismo bolsillo', NEW.grupo_id, v_plant
        USING ERRCODE = 'P0001';
    ELSIF v_plant = 'BOLSO_MOVIMIENTO' AND g.bolsillos <> 2 THEN
      RAISE EXCEPTION 'Libro mayor: el movimiento entre bolsillos (grupo %) debe involucrar dos bolsillos distintos', NEW.grupo_id
        USING ERRCODE = 'P0001';
    ELSIF v_plant IN ('CDT_CREACION', 'INTERES_CDT', 'CDT_VENCIMIENTO') AND g.cdts <> 1 THEN
      RAISE EXCEPTION 'Libro mayor: las patas del grupo % (%) deben referirse al mismo CDT', NEW.grupo_id, v_plant
        USING ERRCODE = 'P0001';
    ELSIF v_plant = 'CREDITO_DESEMBOLSO' AND g.creditos <> 1 THEN
      RAISE EXCEPTION 'Libro mayor: las patas del grupo % (%) deben referirse al mismo crédito', NEW.grupo_id, v_plant
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NULL;
END
$$;
COMMENT ON FUNCTION public.ct_transaccion_cuadre() IS
  'E2. Trigger de restricción DIFERIDO (se evalúa al COMMIT y dentro de _asentar_grupo). Exige por grupo: >=2 patas, ΣD=ΣC, una sola transacción y fecha, y una forma válida (15 plantillas) con coherencia de cuenta/producto; el dinero solo cruza cuentas en un par ENVIO/RECIBO. CUOTA/ABONO/MORA de crédito: reglas generales hasta decidir D7.';

-- ----------------------------------------------------------------------------
-- Trigger de restricción DIFERIDO: invariantes del CDT (sin fijar ninguna fórmula de interés)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ct_cdt_inversion()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cdt  uuid;
  c      record;
  s      record;
  v_esperada numeric;
BEGIN
  -- (IF y no CASE: plpgsql resuelve los campos de NEW al planificar la expresion y 'cdt' no tiene cdt_id)
  IF TG_TABLE_NAME = 'cdt' THEN
    v_cdt := NEW.id;
  ELSE
    v_cdt := NEW.cdt_id;
  END IF;
  SELECT x.estado, x.monto, x.generado_acumulado INTO c FROM public.cdt x WHERE x.id = v_cdt;
  IF NOT FOUND THEN
    RETURN NULL;                          -- el CDT ya no existe (cascada en la misma transacción)
  END IF;
  SELECT coalesce(sum(CASE t.sentido WHEN 'E' THEN t.monto ELSE -t.monto END), 0) AS inversion,
         coalesce(sum(t.monto) FILTER (WHERE t.tipo = 'INTERES_CDT'), 0)          AS generado
    INTO s
    FROM public.transaccion t WHERE t.cdt_id = v_cdt AND t.contenedor = 'CDT';
  v_esperada := CASE WHEN c.estado = 'ACTIVO' THEN c.monto + c.generado_acumulado ELSE 0 END;
  IF s.inversion <> v_esperada THEN
    RAISE EXCEPTION 'Libro mayor: el CDT % está incoherente (inversión en el libro=%, esperada=% con estado %)',
                    v_cdt, s.inversion, v_esperada, c.estado
      USING ERRCODE = 'P0001';
  END IF;
  IF s.generado <> c.generado_acumulado THEN
    RAISE EXCEPTION 'Libro mayor: el CDT % tiene generado_acumulado=% pero sus patas INTERES_CDT suman %',
                    v_cdt, c.generado_acumulado, s.generado
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NULL;
END
$$;
COMMENT ON FUNCTION public.ct_cdt_inversion() IS
  'E2. Trigger de restricción DIFERIDO sobre cdt y transaccion: la inversión en el libro (patas CDT) debe ser monto+generado mientras esté ACTIVO y 0 al cerrarse; generado_acumulado = suma de patas INTERES_CDT. No fija fórmulas de interés.';

-- ----------------------------------------------------------------------------
-- Inmutabilidad del libro
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_transaccion_inmutable()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'Libro mayor: las patas son inmutables (UPDATE rechazado sobre la pata %)', OLD.id
      USING ERRCODE = 'P0001';
  END IF;
  -- DELETE: solo como efecto del borrado de la CUENTA propietaria (cascada). En la cascada la fila de la
  -- cuenta ya no existe; en un DELETE directo sí. No depende de variables de sesión.
  IF EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = OLD.cuenta_id) THEN
    RAISE EXCEPTION 'Libro mayor: las patas no se pueden borrar (solo caen con la cuenta que las posee)'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN OLD;
END
$$;
COMMENT ON FUNCTION public.trg_transaccion_inmutable() IS
  'E2. BEFORE UPDATE OR DELETE en transaccion: el UPDATE siempre se rechaza; el DELETE solo vale si la cuenta de la pata ya no existe (cascada de borrado de cuenta).';

CREATE OR REPLACE FUNCTION public.trg_transaccion_truncate()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'Libro mayor: el historial no se puede vaciar (TRUNCATE rechazado)' USING ERRCODE = 'P0001';
END
$$;
COMMENT ON FUNCTION public.trg_transaccion_truncate() IS 'E2. BEFORE TRUNCATE en transaccion: rechaza siempre (también en TRUNCATE ... CASCADE).';

-- ----------------------------------------------------------------------------
-- Guardias: acumuladores, columnas inmutables y ciclo de vida.
-- SECURITY INVOKER (obligatorio): current_user debe ser quien ejecuta el UPDATE.
-- Contexto confiable = current_user = 'banco_ledger' AND pg_trigger_depth() > 1 (validado en laboratorio).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_zz_proteger_cuenta()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.balance <> 0 THEN
      RAISE EXCEPTION 'Libro mayor: una cuenta nace con balance 0 (el saldo solo lo mueve el libro)' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.usuario_id IS DISTINCT FROM OLD.usuario_id OR NEW.rol IS DISTINCT FROM OLD.rol
     OR NEW.numero_cuenta IS DISTINCT FROM OLD.numero_cuenta OR NEW.creado_en IS DISTINCT FROM OLD.creado_en THEN
    RAISE EXCEPTION 'Libro mayor: id, usuario_id, rol, numero_cuenta y creado_en de una cuenta son inmutables' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.balance IS DISTINCT FROM OLD.balance AND NOT (current_user = 'banco_ledger' AND pg_trigger_depth() > 1) THEN
    RAISE EXCEPTION 'Libro mayor: cuenta.balance solo lo modifica el libro (trigger de transaccion); UPDATE directo rechazado'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;
COMMENT ON FUNCTION public.trg_zz_proteger_cuenta() IS
  'E2. Guardia (SECURITY INVOKER) de cuenta: balance 0 al crearla; id/usuario/rol/numero/creado_en inmutables; balance solo cambia en contexto confiable (current_user=banco_ledger y pg_trigger_depth()>1).';

CREATE OR REPLACE FUNCTION public.trg_zz_proteger_bolsillo()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.balance <> 0 THEN
      RAISE EXCEPTION 'Libro mayor: un bolsillo nace con balance 0 (el saldo solo lo mueve el libro)' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.cuenta_id IS DISTINCT FROM OLD.cuenta_id OR NEW.creado_en IS DISTINCT FROM OLD.creado_en THEN
    RAISE EXCEPTION 'Libro mayor: id, cuenta_id y creado_en de un bolsillo son inmutables' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.balance IS DISTINCT FROM OLD.balance AND NOT (current_user = 'banco_ledger' AND pg_trigger_depth() > 1) THEN
    RAISE EXCEPTION 'Libro mayor: bolsillo.balance solo lo modifica el libro (trigger de transaccion); UPDATE directo rechazado'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;
COMMENT ON FUNCTION public.trg_zz_proteger_bolsillo() IS
  'E2. Guardia (SECURITY INVOKER) de bolsillo: balance 0 al crearlo; id/cuenta_id/creado_en inmutables; balance solo cambia en contexto confiable.';

CREATE OR REPLACE FUNCTION public.trg_zz_proteger_cdt()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.generado_acumulado <> 0 THEN
      RAISE EXCEPTION 'Libro mayor: un CDT nace con generado_acumulado 0 (lo mueve el libro)' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.cuenta_id IS DISTINCT FROM OLD.cuenta_id OR NEW.nombre IS DISTINCT FROM OLD.nombre
     OR NEW.monto IS DISTINCT FROM OLD.monto OR NEW.tasa_anual IS DISTINCT FROM OLD.tasa_anual
     OR NEW.plazo_dias IS DISTINCT FROM OLD.plazo_dias OR NEW.fecha_inicio IS DISTINCT FROM OLD.fecha_inicio
     OR NEW.fecha_fin IS DISTINCT FROM OLD.fecha_fin THEN
    RAISE EXCEPTION 'Libro mayor: cuenta, nombre, monto, tasa, plazo y fechas de un CDT son inmutables (copias contractuales)' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.definicion_id IS DISTINCT FROM OLD.definicion_id AND NEW.definicion_id IS NOT NULL THEN
    RAISE EXCEPTION 'Libro mayor: definicion_id de un CDT solo puede pasar a NULL (FK SET NULL)' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.estado = 'CERRADO' AND NEW.estado <> 'CERRADO' THEN
    RAISE EXCEPTION 'Libro mayor: un CDT cerrado no se reabre' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.generado_acumulado IS DISTINCT FROM OLD.generado_acumulado AND NOT (current_user = 'banco_ledger' AND pg_trigger_depth() > 1) THEN
    RAISE EXCEPTION 'Libro mayor: cdt.generado_acumulado solo lo modifica el libro (trigger de transaccion); UPDATE directo rechazado'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;
COMMENT ON FUNCTION public.trg_zz_proteger_cdt() IS
  'E2. Guardia (SECURITY INVOKER) de cdt: generado_acumulado 0 al crearlo y solo cambia en contexto confiable; cuenta/nombre/monto/tasa/plazo/fechas inmutables; definicion_id solo a NULL; ACTIVO->CERRADO sin reabrir.';

CREATE OR REPLACE FUNCTION public.trg_zz_proteger_credito()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.capital_pendiente <> 0 THEN
      RAISE EXCEPTION 'Libro mayor: un crédito nace con capital_pendiente 0; lo sube la pata CREDITO_DESEMBOLSO' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.cuenta_id IS DISTINCT FROM OLD.cuenta_id OR NEW.producto_id IS DISTINCT FROM OLD.producto_id
     OR NEW.monto IS DISTINCT FROM OLD.monto OR NEW.tasa_anual IS DISTINCT FROM OLD.tasa_anual
     OR NEW.plazo_meses IS DISTINCT FROM OLD.plazo_meses OR NEW.fecha_desembolso IS DISTINCT FROM OLD.fecha_desembolso THEN
    RAISE EXCEPTION 'Libro mayor: cuenta, producto, monto, tasa, plazo y fecha de desembolso de un crédito son inmutables' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.estado = 'PAGADO' AND NEW.estado <> 'PAGADO' THEN
    RAISE EXCEPTION 'Libro mayor: un crédito pagado no se reabre' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.capital_pendiente IS DISTINCT FROM OLD.capital_pendiente AND NOT (current_user = 'banco_ledger' AND pg_trigger_depth() > 1) THEN
    RAISE EXCEPTION 'Libro mayor: credito.capital_pendiente solo lo modifica el libro (trigger de transaccion); UPDATE directo rechazado'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;
COMMENT ON FUNCTION public.trg_zz_proteger_credito() IS
  'E2. Guardia (SECURITY INVOKER) de credito: capital_pendiente 0 al crearlo (lo sube CREDITO_DESEMBOLSO) y solo cambia en contexto confiable; cuenta/producto/monto/tasa/plazo/desembolso inmutables; ACTIVO->PAGADO sin reabrir.';

-- ----------------------------------------------------------------------------
-- Auditoría automática del borrado de una cuenta (directo o por cascada desde usuario)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_cuenta_auditar_borrado()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO audit.evento (actor_username, accion, entidad, entidad_id, antes)
  VALUES (
    nullif(current_setting('banco.actor', true), ''),          -- solo atribución, NO es control de seguridad
    'CUENTA_BORRADA', 'cuenta', OLD.id::text,
    jsonb_build_object(
      'usuario_id',    OLD.usuario_id,
      'numero_cuenta', OLD.numero_cuenta,
      'balance',       OLD.balance,
      'bolsillos',     (SELECT coalesce(sum(b.balance), 0) FROM public.bolsillo b WHERE b.cuenta_id = OLD.id),
      'cdt_vigente',   (SELECT coalesce(sum(CASE t.sentido WHEN 'E' THEN t.monto ELSE -t.monto END), 0)
                          FROM public.transaccion t WHERE t.cuenta_id = OLD.id AND t.contenedor = 'CDT'),
      'pasivos',       (SELECT coalesce(sum(c.capital_pendiente), 0) FROM public.credito c WHERE c.cuenta_id = OLD.id),
      'resultado',     (SELECT coalesce(sum(CASE t.sentido WHEN 'E' THEN t.monto ELSE -t.monto END), 0)
                          FROM public.transaccion t WHERE t.cuenta_id = OLD.id AND t.contenedor = 'RESULTADO'),
      'transf_neto',   (SELECT coalesce(sum(CASE t.tipo WHEN 'RECIBO' THEN t.monto ELSE -t.monto END), 0)
                          FROM public.transaccion t WHERE t.cuenta_id = OLD.id AND t.tipo IN ('RECIBO', 'ENVIO')),
      'patas',         (SELECT count(*) FROM public.transaccion t WHERE t.cuenta_id = OLD.id)
    ));
  RETURN OLD;
END
$$;
COMMENT ON FUNCTION public.trg_cuenta_auditar_borrado() IS
  'E2. BEFORE DELETE en cuenta (directo o por cascada desde usuario): registra CUENTA_BORRADA en audit.evento con balance, bolsillos, CDT vigente, pasivos, resultado y transferencias netas de lo que se destruye (conciliación de I5g).';

-- ----------------------------------------------------------------------------
-- Funciones de los event triggers (los EVENT TRIGGER se crean en 08, requieren superusuario)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_evento_ddl()
RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.object_identity, c.command_tag
      FROM pg_event_trigger_ddl_commands() c
     WHERE c.command_tag = 'ALTER TABLE'
       AND c.object_identity IN ('public.cuenta', 'public.bolsillo', 'public.cdt', 'public.credito', 'public.transaccion', 'public.reloj')
  LOOP
    INSERT INTO audit.evento (actor_username, accion, entidad, entidad_id, despues)
    VALUES (nullif(current_setting('banco.actor', true), ''), 'DDL', 'tabla_protegida', r.object_identity,
            jsonb_build_object('comando', r.command_tag, 'usuario_sesion', session_user, 'rol_actual', current_user));
  END LOOP;
END
$$;
COMMENT ON FUNCTION public.trg_evento_ddl() IS
  'E2. Función del event trigger evt_ddl_protegido: registra en audit.evento cada ALTER TABLE (incluye DISABLE TRIGGER) sobre las tablas del libro y sus acumuladores.';

CREATE OR REPLACE FUNCTION public.trg_evento_drop()
RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT d.object_identity
      FROM pg_event_trigger_dropped_objects() d
     WHERE d.object_type = 'trigger'
       AND d.object_identity ~ ' on public\.(cuenta|bolsillo|cdt|credito|transaccion|reloj)$'
  LOOP
    INSERT INTO audit.evento (actor_username, accion, entidad, entidad_id, despues)
    VALUES (nullif(current_setting('banco.actor', true), ''), 'DDL', 'trigger_protegido', r.object_identity,
            jsonb_build_object('comando', 'DROP TRIGGER', 'usuario_sesion', session_user, 'rol_actual', current_user));
  END LOOP;
END
$$;
COMMENT ON FUNCTION public.trg_evento_drop() IS
  'E2. Función del event trigger evt_drop_protegido: registra en audit.evento cada DROP TRIGGER sobre las tablas del libro y sus acumuladores.';

-- ----------------------------------------------------------------------------
-- _asentar_grupo: el ÚNICO escritor autorizado del libro mayor
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._asentar_grupo(p_fecha timestamptz, p_patas jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_grupo   uuid := gen_random_uuid();
  v_cuentas uuid[];
  v_n       integer;
  v_pat     integer;
  r         record;
  v_msg     text;
  v_det     text;
  v_con     text;
BEGIN
  -- 1) Aislamiento: FOR NO KEY UPDATE exige READ COMMITTED (en otros niveles daría 40001)
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'Libro mayor: _asentar_grupo exige el nivel de aislamiento READ COMMITTED (actual: %)', current_setting('transaction_isolation')
      USING ERRCODE = 'P0001';
  END IF;
  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'Libro mayor: la fecha del grupo es obligatoria' USING ERRCODE = 'P0001';
  END IF;
  IF p_patas IS NULL OR jsonb_typeof(p_patas) <> 'array' THEN
    RAISE EXCEPTION 'Libro mayor: las patas deben ser un arreglo JSON' USING ERRCODE = 'P0001';
  END IF;

  BEGIN
    -- 2) Validación de forma del JSON (tipos, montos, cuenta) con errores limpios
    SELECT count(*), array_agg(DISTINCT x.cuenta_id) FILTER (WHERE x.cuenta_id IS NOT NULL),
           count(*) FILTER (WHERE x.cuenta_id IS NULL)
      INTO v_n, v_cuentas, v_pat
      FROM jsonb_to_recordset(p_patas) AS x(cuenta_id uuid);
    IF v_n < 2 THEN
      RAISE EXCEPTION 'Libro mayor: un grupo necesita al menos dos patas' USING ERRCODE = 'P0001';
    END IF;
    IF v_pat > 0 THEN
      RAISE EXCEPTION 'Libro mayor: toda pata necesita cuenta_id' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_patas) AS x(monto numeric)
                WHERE x.monto IS NULL OR x.monto <= 0 OR scale(x.monto) > 2) THEN
      RAISE EXCEPTION 'Monto inválido' USING ERRCODE = 'P0001';
    END IF;

    -- 3) Bloqueo raíz: las cuentas involucradas, en ORDEN ASCENDENTE de id (protocolo anti-deadlock)
    PERFORM 1 FROM public.cuenta c WHERE c.id = ANY (v_cuentas) ORDER BY c.id FOR NO KEY UPDATE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n <> cardinality(v_cuentas) THEN
      RAISE EXCEPTION 'Libro mayor: alguna cuenta del grupo no existe' USING ERRCODE = 'P0001';
    END IF;

    -- 4) Inserción en orden determinista; cada pata dispara validar -> aplicar
    FOR r IN
      SELECT x.*
        FROM jsonb_to_recordset(p_patas) AS x(tipo text, contenedor text, sentido text, monto numeric, cuenta_id uuid,
                                              bolsillo_id uuid, cdt_id uuid, credito_id uuid, nota text,
                                              contraparte_nombre text, contraparte_cuenta text)
       ORDER BY x.cuenta_id, x.contenedor, coalesce(x.bolsillo_id, x.cdt_id, x.credito_id), x.sentido, x.tipo
    LOOP
      INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, nota, cuenta_id,
                                      bolsillo_id, cdt_id, credito_id, contraparte_nombre, contraparte_cuenta)
      VALUES (v_grupo, p_fecha, r.tipo::public.tipo_transaccion, r.contenedor::public.contenedor_contable,
              r.sentido::public.sentido_asiento, r.monto, r.nota, r.cuenta_id,
              r.bolsillo_id, r.cdt_id, r.credito_id, r.contraparte_nombre, r.contraparte_cuenta);
    END LOOP;

    -- 5) Cuadre y demás invariantes AHORA (no solo al COMMIT): errores limpios dentro de la función
    SET CONSTRAINTS public.ct_transaccion_cuadre, public.ct_transaccion_cdt, public.ct_cdt_inversion IMMEDIATE;
    SET CONSTRAINTS public.ct_transaccion_cuadre, public.ct_transaccion_cdt, public.ct_cdt_inversion DEFERRED;
  EXCEPTION
    WHEN data_exception OR integrity_constraint_violation THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL, v_con = CONSTRAINT_NAME;
      RAISE EXCEPTION 'Libro mayor: pata inválida (%)%', v_msg,
                      CASE WHEN v_con IS NOT NULL THEN ' [' || v_con || ']' ELSE '' END
        USING ERRCODE = 'P0001', DETAIL = v_det;
  END;
  RETURN v_grupo;
END
$$;
COMMENT ON FUNCTION public._asentar_grupo(timestamptz, jsonb) IS
  'E2. ÚNICO escritor autorizado del libro mayor. Recibe fecha y un arreglo JSON de patas {tipo, contenedor, sentido, monto, cuenta_id, bolsillo_id?, cdt_id?, credito_id?, nota?, contraparte_nombre?, contraparte_cuenta?}. Exige READ COMMITTED, bloquea las cuentas en orden de id, inserta las patas en orden determinista y valida el cuadre dentro de la función. Atómica: o entra todo el grupo o nada. Interna: sin EXECUTE para banco_app/lector/dev.';

RESET ROLE;

-- ----------------------------------------------------------------------------
-- trg_transaccion_b_aplicar: la ÚNICA función que mueve saldos. DUEÑO banco_ledger (SECURITY DEFINER).
-- Se crea como superusuario y se le cambia el dueño. banco_ledger solo tiene SELECT por columna de lo
-- que lee aquí (id, cuenta_id y el acumulador) y UPDATE de los 4 acumuladores (05_permisos.sql).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_transaccion_b_aplicar()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_previo numeric;
  v_post   numeric;
  v_delta  numeric := CASE WHEN NEW.sentido = 'E' THEN NEW.monto ELSE -NEW.monto END;
  v_max    CONSTANT numeric := 9999999999999.99;
BEGIN
  -- Bloqueo raíz: la cuenta (idempotente si _asentar_grupo ya la tiene). Para CUENTA se lee en el mismo paso.
  IF NEW.contenedor = 'CUENTA' THEN
    SELECT c.balance INTO v_previo FROM public.cuenta c WHERE c.id = NEW.cuenta_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Libro mayor: la cuenta % no existe', NEW.cuenta_id USING ERRCODE = 'P0001';
    END IF;
    v_post := v_previo + v_delta;
    IF v_post < 0 THEN
      RAISE EXCEPTION 'Saldo insuficiente' USING ERRCODE = 'P0001';
    END IF;
    IF v_post > v_max THEN
      RAISE EXCEPTION 'Libro mayor: el saldo de la cuenta excedería el máximo permitido' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.cuenta SET balance = v_post WHERE id = NEW.cuenta_id;
    NEW.saldo_previo := v_previo;
    NEW.saldo_posterior := v_post;
    RETURN NEW;
  END IF;

  PERFORM 1 FROM public.cuenta c WHERE c.id = NEW.cuenta_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Libro mayor: la cuenta % no existe', NEW.cuenta_id USING ERRCODE = 'P0001';
  END IF;

  IF NEW.contenedor = 'BOLSILLO' THEN
    SELECT b.balance INTO v_previo FROM public.bolsillo b
     WHERE b.id = NEW.bolsillo_id AND b.cuenta_id = NEW.cuenta_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Libro mayor: el bolsillo % no pertenece a la cuenta %', NEW.bolsillo_id, NEW.cuenta_id USING ERRCODE = 'P0001';
    END IF;
    v_post := v_previo + v_delta;
    IF v_post < 0 THEN
      RAISE EXCEPTION 'Saldo insuficiente' USING ERRCODE = 'P0001';
    END IF;
    IF v_post > v_max THEN
      RAISE EXCEPTION 'Libro mayor: el saldo del bolsillo excedería el máximo permitido' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.bolsillo SET balance = v_post WHERE id = NEW.bolsillo_id;
    NEW.saldo_previo := v_previo;
    NEW.saldo_posterior := v_post;

  ELSIF NEW.contenedor = 'CREDITO' THEN
    SELECT c.capital_pendiente INTO v_previo FROM public.credito c
     WHERE c.id = NEW.credito_id AND c.cuenta_id = NEW.cuenta_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Libro mayor: el crédito % no pertenece a la cuenta %', NEW.credito_id, NEW.cuenta_id USING ERRCODE = 'P0001';
    END IF;
    v_post := v_previo + v_delta;
    IF v_post < 0 THEN
      RAISE EXCEPTION 'Libro mayor: el capital pendiente del crédito no puede quedar negativo' USING ERRCODE = 'P0001';
    END IF;
    IF v_post > v_max THEN
      RAISE EXCEPTION 'Libro mayor: el capital pendiente excedería el máximo permitido' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.credito SET capital_pendiente = v_post WHERE id = NEW.credito_id;
    NEW.saldo_previo := v_previo;
    NEW.saldo_posterior := v_post;

  ELSIF NEW.contenedor = 'CDT' THEN
    -- El CDT no tiene saldo almacenado: su inversión es derivada. Solo INTERES_CDT mueve un acumulador.
    SELECT d.generado_acumulado INTO v_previo FROM public.cdt d
     WHERE d.id = NEW.cdt_id AND d.cuenta_id = NEW.cuenta_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Libro mayor: el CDT % no pertenece a la cuenta %', NEW.cdt_id, NEW.cuenta_id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.tipo = 'INTERES_CDT' THEN
      v_post := v_previo + v_delta;
      IF v_post < 0 OR v_post > v_max THEN
        RAISE EXCEPTION 'Libro mayor: generado_acumulado del CDT fuera de rango' USING ERRCODE = 'P0001';
      END IF;
      UPDATE public.cdt SET generado_acumulado = v_post WHERE id = NEW.cdt_id;
    END IF;
    NEW.saldo_previo := NULL;
    NEW.saldo_posterior := NULL;

  ELSE
    -- RESULTADO: derivado (suma de sus patas); no hay acumulador que mover.
    NEW.saldo_previo := NULL;
    NEW.saldo_posterior := NULL;
  END IF;
  RETURN NEW;
END
$$;

ALTER FUNCTION public.trg_transaccion_b_aplicar() OWNER TO banco_ledger;
COMMENT ON FUNCTION public.trg_transaccion_b_aplicar() IS
  'E2. BEFORE INSERT en transaccion (2/2). DUEÑO banco_ledger, SECURITY DEFINER: único camino que mueve cuenta.balance, bolsillo.balance, cdt.generado_acumulado y credito.capital_pendiente. Bloquea el contenedor (FOR NO KEY UPDATE), fija saldo previo/posterior, rechaza saldos negativos ("Saldo insuficiente") y contenedores ajenos.';

-- ----------------------------------------------------------------------------
-- Ninguna de estas funciones es ejecutable por PUBLIC ni por los roles de acceso.
-- (Las creadas por banco_owner ya nacen sin EXECUTE para PUBLIC por ALTER DEFAULT PRIVILEGES; la de
-- banco_ledger la creó el superusuario, por eso se revoca aquí de forma explícita para TODAS.)
-- ----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS firma, pg_get_userbyid(p.proowner) AS dueno
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND (p.proname LIKE '\_%' OR p.proname LIKE 'trg\_%' OR p.proname LIKE 'ct\_%')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM banco_app, banco_lector, banco_dev', f.firma);
  END LOOP;
END
$$;
GRANT EXECUTE ON FUNCTION public.trg_transaccion_b_aplicar() TO banco_owner;   -- para (re)crear el trigger como dueño de la tabla
-- Excepcion: _plantillas_validas() es un catalogo de CONSTANTES que usa la vista v_integridad_grupos. Las funciones que llama
-- una vista se ejecutan con los privilegios de QUIEN CONSULTA la vista (no del dueño), asi que banco_lector (y banco_dev,
-- que hereda de el) necesita EXECUTE. banco_app y PUBLIC siguen sin poder ejecutarla.
GRANT EXECUTE ON FUNCTION public._plantillas_validas() TO banco_lector;

COMMIT;
