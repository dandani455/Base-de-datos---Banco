-- ============================================================================
-- harness.sql  ·  Utilidades de prueba de la Etapa 2 (libro mayor)
-- Se carga SOLO en la base desechable "banco_test" (el runner lo hace tras helpers.sql); NUNCA en "banco".
-- Vive en el esquema "tests". Contiene:
--   1. Constructores de datos (clientes, productos, patas, grupos) para las pruebas SQL.
--   2. FUNCIONES ARNES "app_*": imitan lo que haran las funciones de negocio de E4+ (SECURITY DEFINER,
--      dueno banco_owner, EXECUTE solo para banco_app). Sirven para probar, con una CONEXION REAL de banco_app,
--      que el camino completo app -> funcion -> libro solo mueve saldos por el libro y rechaza lo forjado.
--      NO existen en la base real: son solo de pruebas.
-- ============================================================================

-- ids deterministas (n pequeno) --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tests.u(p_n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('10000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid $$;
CREATE OR REPLACE FUNCTION tests.c(p_n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('20000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid $$;
CREATE OR REPLACE FUNCTION tests.b(p_n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('30000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid $$;
CREATE OR REPLACE FUNCTION tests.d(p_n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('50000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid $$;
CREATE OR REPLACE FUNCTION tests.p(p_n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('60000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid $$;
CREATE OR REPLACE FUNCTION tests.k(p_n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('70000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid $$;

-- cliente n: usuario cliN + cuenta 40NNNNNNNN (balance 0). Devuelve el id de la cuenta. -------------------------
CREATE OR REPLACE FUNCTION tests.cliente(p_n int) RETURNS uuid LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento)
  VALUES (tests.u(p_n), 'cli' || p_n, 'h', 'Nombre' || p_n, 'Apellido', '9' || lpad(p_n::text, 9, '0'),
          'c' || p_n || '@t.co', '3' || lpad(p_n::text, 9, '0'), DATE '1990-01-01');
  INSERT INTO public.cuenta (id, usuario_id, numero_cuenta) VALUES (tests.c(p_n), tests.u(p_n), '40' || lpad(p_n::text, 8, '0'));
  RETURN tests.c(p_n);
END $$;

CREATE OR REPLACE FUNCTION tests.bolsillo(p_n int, p_cuenta uuid) RETURNS uuid LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.bolsillo (id, cuenta_id, nombre, ultimo_cobro) VALUES (tests.b(p_n), p_cuenta, 'Bolsillo ' || p_n, public.hoy_banco());   -- E7: recien creado = al dia (una fecha anterior significaria intereses pendientes)
  RETURN tests.b(p_n);
END $$;

-- CDT ACTIVO sin patas todavia (generado 0): la apertura la hace el grupo CDT_CREACION
CREATE OR REPLACE FUNCTION tests.cdt(p_n int, p_cuenta uuid, p_monto numeric) RETURNS uuid LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.cdt (id, cuenta_id, nombre, monto, tasa_anual, plazo_dias, fecha_inicio, fecha_fin, ultimo_cobro)
  VALUES (tests.d(p_n), p_cuenta, 'CDT ' || p_n, p_monto, 10, 90, DATE '2026-11-01', DATE '2026-11-01' + 90, DATE '2026-11-01');
  RETURN tests.d(p_n);
END $$;

-- crédito sin desembolso todavia (capital_pendiente 0): lo sube el grupo CREDITO_DESEMBOLSO
CREATE OR REPLACE FUNCTION tests.credito(p_n int, p_cuenta uuid, p_monto numeric) RETURNS uuid LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.credito_producto (id, nombre, tasa_anual, monto_min, monto_max, plazo_max_meses)
  VALUES (tests.p(p_n), 'Producto ' || p_n, 20, 1, 100000000, 24) ON CONFLICT DO NOTHING;
  INSERT INTO public.credito (id, cuenta_id, producto_id, monto, tasa_anual, plazo_meses, fecha_desembolso, capital_pendiente, fecha_interes)
  VALUES (tests.k(p_n), p_cuenta, tests.p(p_n), p_monto, 20, 12, DATE '2026-11-21', 0, DATE '2026-11-21');
  RETURN tests.k(p_n);
END $$;

-- una pata y un grupo como JSON ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tests.pata(p_tipo text, p_cont text, p_sent text, p_monto numeric, p_cuenta uuid,
                                      p_bol uuid DEFAULT NULL, p_cdt uuid DEFAULT NULL, p_cre uuid DEFAULT NULL,
                                      p_cp_nombre text DEFAULT NULL, p_cp_cuenta text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('tipo', p_tipo, 'contenedor', p_cont, 'sentido', p_sent, 'monto', p_monto,
         'cuenta_id', p_cuenta, 'bolsillo_id', p_bol, 'cdt_id', p_cdt, 'credito_id', p_cre,
         'contraparte_nombre', p_cp_nombre, 'contraparte_cuenta', p_cp_cuenta)) $$;

-- asentar(pata, pata, ...) -> grupo_id  (llama al unico escritor autorizado)
CREATE OR REPLACE FUNCTION tests.asentar(VARIADIC p_patas jsonb[]) RETURNS uuid LANGUAGE sql AS $$
  SELECT public._asentar_grupo(now(), to_jsonb(p_patas)) $$;

-- grupos tipicos -------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tests.g_ingreso(p_cuenta uuid, p_monto numeric, p_tipo text DEFAULT 'INGRESO_SIMULADO') RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_array(tests.pata(p_tipo, 'CUENTA', 'E', p_monto, p_cuenta),
                           tests.pata(p_tipo, 'RESULTADO', 'E', p_monto, p_cuenta, NULL, NULL, NULL, 'Banco Digital')) $$;

CREATE OR REPLACE FUNCTION tests.g_envio(p_origen uuid, p_destino uuid, p_monto numeric, p_bolsillo uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_array(
    tests.pata('ENVIO', CASE WHEN p_bolsillo IS NULL THEN 'CUENTA' ELSE 'BOLSILLO' END, 'S', p_monto, p_origen, p_bolsillo, NULL, NULL,
               'Destino', (SELECT numero_cuenta FROM public.cuenta WHERE id = p_destino)),
    tests.pata('RECIBO', 'CUENTA', 'E', p_monto, p_destino, NULL, NULL, NULL,
               'Origen', (SELECT numero_cuenta FROM public.cuenta WHERE id = p_origen))) $$;

CREATE OR REPLACE FUNCTION tests.fondear(p_cuenta uuid, p_monto numeric) RETURNS uuid LANGUAGE sql AS $$
  SELECT public._asentar_grupo(now(), tests.g_ingreso(p_cuenta, p_monto)) $$;

-- Estado observable para comparar "antes/despues" (huella de saldos)
CREATE OR REPLACE FUNCTION tests.huella_saldos() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT md5(coalesce((SELECT string_agg(x, '|' ORDER BY x) FROM (
    SELECT 'c' || id || balance AS x FROM public.cuenta
    UNION ALL SELECT 'b' || id || balance FROM public.bolsillo
    UNION ALL SELECT 'd' || id || generado_acumulado || estado FROM public.cdt
    UNION ALL SELECT 'k' || id || capital_pendiente || estado FROM public.credito
    UNION ALL SELECT 't' || count(*) FROM public.transaccion) y), '')) $$;

-- Plan de ejecucion (una linea por fila) para comprobar el uso de indices
CREATE OR REPLACE FUNCTION tests.plan(p_sql text) RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE l text;
BEGIN
  FOR l IN EXECUTE 'EXPLAIN ' || p_sql LOOP RETURN NEXT l; END LOOP;
END $$;

-- Prueba de DETECCION: aplica un sabotaje, comprueba que una consulta booleana lo detecta (debe dar TRUE) y
-- SIEMPRE deshace el sabotaje (subtransaccion con excepcion centinela).
CREATE OR REPLACE FUNCTION tests.detecta(p_label text, p_sabotaje text, p_deteccion text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_det boolean; v_ok boolean := false;
BEGIN
  BEGIN
    EXECUTE p_sabotaje;
    EXECUTE p_deteccion INTO v_det;
    v_ok := coalesce(v_det, false);
    RAISE EXCEPTION 'deshacer sabotaje' USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;
  RESET ROLE;
  IF v_ok THEN
    RAISE NOTICE 'PASS: %', p_label;
  ELSE
    RAISE EXCEPTION 'FAIL: % (el sabotaje NO fue detectado por: %)', p_label, p_deteccion;
  END IF;
END $$;

-- ============================================================================
-- FUNCIONES ARNES (solo pruebas): dueno banco_owner, SECURITY DEFINER, EXECUTE solo para banco_app
-- ============================================================================
GRANT USAGE ON SCHEMA tests TO banco_owner, banco_app;

-- Fondea una cuenta (imita un ingreso del banco).
CREATE OR REPLACE FUNCTION tests.app_fondear(p_cuenta uuid, p_monto numeric) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$
  SELECT public._asentar_grupo(now(), tests.g_ingreso(p_cuenta, p_monto)) $$;

-- Imita hacer_transferencia(origen, destino, monto): construye las dos patas y las asienta.
CREATE OR REPLACE FUNCTION tests.app_envio(p_origen uuid, p_destino uuid, p_monto numeric) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$
  SELECT public._asentar_grupo(now(), tests.g_envio(p_origen, p_destino, p_monto)) $$;

-- Imita mover_a_bolsillo(cuenta, bolsillo, monto)
CREATE OR REPLACE FUNCTION tests.app_bolso_ingreso(p_cuenta uuid, p_bolsillo uuid, p_monto numeric) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$
  SELECT public._asentar_grupo(now(), jsonb_build_array(
    tests.pata('BOLSO_INGRESO', 'CUENTA',   'S', p_monto, p_cuenta, p_bolsillo),
    tests.pata('BOLSO_INGRESO', 'BOLSILLO', 'E', p_monto, p_cuenta, p_bolsillo))) $$;

-- Pasa patas ARBITRARIAS al escritor (para probar que lo forjado se rechaza aunque venga por una funcion definer).
CREATE OR REPLACE FUNCTION tests.app_forjar(p_patas jsonb) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$
  SELECT public._asentar_grupo(now(), p_patas) $$;

-- Una funcion DEFINER defectuosa (dueno banco_owner) que intenta tocar saldos y el libro directamente.
CREATE OR REPLACE FUNCTION tests.app_tocar_saldo(p_cuenta uuid, p_nuevo numeric) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$
  UPDATE public.cuenta SET balance = p_nuevo WHERE id = p_cuenta $$;
CREATE OR REPLACE FUNCTION tests.app_borrar_patas() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$
  DELETE FROM public.transaccion $$;
CREATE OR REPLACE FUNCTION tests.app_insertar_pata_suelta(p_cuenta uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$
  INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, cuenta_id)
  VALUES (gen_random_uuid(), now(), 'DEPOSITO_BANCO', 'CUENTA', 'E', 100, p_cuenta) $$;

-- ============================================================================
-- Etapa 3 (reloj): arneses de prueba
-- ============================================================================

-- Cobro NEUTRO de prueba (NO es una formula de interes ni decide nada financiero): por cada dia del rango (ultimo_cobro, hoy_banco()]
-- asienta 1 peso de interes de bolsillo y luego avanza ultimo_cobro. Sirve para demostrar, con las reglas de E3 (_dias_por_cobrar),
-- que tras volver a fecha real no se recobra nada, no hay rangos negativos y al adelantar de nuevo solo se cobra lo no cobrado.
CREATE OR REPLACE FUNCTION tests.cobro_simulado(p_bolsillo uuid) RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_cuenta uuid; v_ultimo date; v_hoy date; d date; n int := 0;
BEGIN
  SELECT cuenta_id, ultimo_cobro INTO v_cuenta, v_ultimo FROM public.bolsillo WHERE id = p_bolsillo;
  v_hoy := public.hoy_banco();
  FOR d IN SELECT x FROM public._dias_por_cobrar(v_ultimo, v_hoy) x ORDER BY x LOOP
    PERFORM public._asentar_grupo((d + time '12:00') AT TIME ZONE 'America/Bogota', jsonb_build_array(
      tests.pata('INTERES_BOLSO', 'BOLSILLO',  'E', 1, v_cuenta, p_bolsillo),
      tests.pata('INTERES_BOLSO', 'RESULTADO', 'E', 1, v_cuenta, p_bolsillo, NULL, NULL, 'Banco Digital')));
    n := n + 1;
  END LOOP;
  IF n > 0 THEN UPDATE public.bolsillo SET ultimo_cobro = v_hoy WHERE id = p_bolsillo; END IF;
  RETURN n;
END $$;

-- Arneses para conexiones REALES de banco_app (como las futuras funciones de negocio / admin)
CREATE OR REPLACE FUNCTION tests.app_reloj(p_usar boolean, p_fecha text) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$ SELECT public._reloj_actualizar(p_usar, p_fecha) $$;

-- Imita a una funcion de negocio de E4+: asienta con la fecha del reloj del banco (ahora_banco()), no con now().
CREATE OR REPLACE FUNCTION tests.app_fondear_banco(p_cuenta uuid, p_monto numeric) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$
  SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(p_cuenta, p_monto)) $$;

-- Como la anterior, pero PROTOCOLO ESTABLE: toma la instantanea del reloj (FOR SHARE hasta el COMMIT) y asienta con ESE instante. Asi el reloj
-- no puede cambiar entre fechar la pata y validarla (patron que usaran las funciones de negocio de E4+).
CREATE OR REPLACE FUNCTION tests.app_fondear_estable(p_cuenta uuid, p_monto numeric) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$
DECLARE v_ahora timestamptz;
BEGIN
  SELECT ahora INTO v_ahora FROM public._reloj_instantanea();
  RETURN public._asentar_grupo(v_ahora, tests.g_ingreso(p_cuenta, p_monto));
END $$;

-- Toma la instantanea y la DEVUELVE: 'hoy|epoch_ahora|epoch_inicio_tx|ahora_en_bogota'. Sirve para comprobar que el instante se toma
-- DESPUES del bloqueo (si la operacion espero, ahora es posterior al inicio de la transaccion) y que es el del estado bloqueado.
CREATE OR REPLACE FUNCTION tests.app_instantanea() RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$
DECLARE v_hoy date; v_ahora timestamptz;
BEGIN
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  RETURN v_hoy::text || '|' || extract(epoch FROM v_ahora)::numeric(20,3)::text || '|' || extract(epoch FROM now())::numeric(20,3)::text
         || '|' || to_char(v_ahora AT TIME ZONE 'America/Bogota', 'YYYY-MM-DD HH24:MI:SS');
END $$;

-- Operacion de VARIAS patas con el protocolo estable (UNA instantanea) que se AUTOVERIFICA: todas las patas del grupo llevan
-- exactamente esa fecha y su fecha de Bogota es el hoy de la instantanea. Devuelve 'patas|fechas_distintas|todas_=_ahora|todas_=_hoy|hoy|ahora_en_bogota'.
CREATE OR REPLACE FUNCTION tests.app_op_verificada(p_origen uuid, p_destino uuid, p_monto numeric) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$
DECLARE v_hoy date; v_ahora timestamptz; g uuid; n int; d int; t1 boolean; t2 boolean;
BEGIN
  SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;
  g := public._asentar_grupo(v_ahora, tests.g_envio(p_origen, p_destino, p_monto));
  SELECT count(*), count(DISTINCT t.fecha), bool_and(t.fecha = v_ahora), bool_and((t.fecha AT TIME ZONE 'America/Bogota')::date = v_hoy)
    INTO n, d, t1, t2 FROM public.transaccion t WHERE t.grupo_id = g;
  RETURN n || '|' || d || '|' || t1 || '|' || t2 || '|' || v_hoy || '|' || to_char(v_ahora AT TIME ZONE 'America/Bogota', 'YYYY-MM-DD HH24:MI:SS');
END $$;

CREATE OR REPLACE FUNCTION tests.app_hoy() RETURNS text
LANGUAGE sql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$ SELECT public.hoy_banco()::text $$;

-- Operacion LENTA: toma la instantanea del reloj, espera p_seg segundos y vuelve a leer hoy_banco(): devuelve 'hoy1|hoy2'.
CREATE OR REPLACE FUNCTION tests.app_operacion_lenta(p_seg numeric) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$
DECLARE a date; b date;
BEGIN
  SELECT hoy INTO a FROM public._reloj_instantanea();
  PERFORM pg_sleep(p_seg);
  b := public.hoy_banco();
  RETURN a::text || '|' || b::text;
END $$;

-- Cambio de reloj ALEATORIO (15 % vuelve a real; el resto fija una fecha manual entre hoy-5 y hoy+25): para la prueba de concurrencia
CREATE OR REPLACE FUNCTION tests.app_reloj_aleatorio() RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, tests, pg_temp AS $$
BEGIN
  IF random() < 0.15 THEN
    PERFORM public._reloj_actualizar(true, '');
    RETURN 'real';
  END IF;
  PERFORM public._reloj_actualizar(false, to_char(public.hoy_banco() + (floor(random() * 31) - 5)::int, 'YYYY-MM-DD'));
  RETURN 'manual';
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['tests.app_fondear(uuid,numeric)', 'tests.app_envio(uuid,uuid,numeric)',
                           'tests.app_bolso_ingreso(uuid,uuid,numeric)', 'tests.app_forjar(jsonb)',
                           'tests.app_tocar_saldo(uuid,numeric)', 'tests.app_borrar_patas()',
                           'tests.app_insertar_pata_suelta(uuid)', 'tests.app_reloj(boolean,text)', 'tests.app_hoy()',
                           'tests.app_fondear_banco(uuid,numeric)', 'tests.app_fondear_estable(uuid,numeric)', 'tests.app_instantanea()', 'tests.app_op_verificada(uuid,uuid,numeric)', 'tests.app_operacion_lenta(numeric)', 'tests.app_reloj_aleatorio()'] LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO banco_owner', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO banco_app', f);
  END LOOP;
END $$;

-- ============================================================================
-- Etapa 4 (autenticacion y registro): constructores y INYECCION DE FALLOS (solo pruebas)
-- ============================================================================

-- Un hash con la FORMA de bcrypt (60 caracteres); las pruebas nunca usan claves en claro.
CREATE OR REPLACE FUNCTION tests.hash() RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy'::text $$;

-- Registra al cliente n por la funcion REAL registrar_usuario (cedula, correo y telefono derivados de n: unicos).
-- Se ejecuta con el rol actual de la sesion (SET LOCAL ROLE banco_app en las pruebas de permisos).
CREATE OR REPLACE FUNCTION tests.reg(p_n int, p_nombres text DEFAULT 'Juan', p_apellidos text DEFAULT 'Perez',
                                     p_ref text DEFAULT NULL, p_verificacion boolean DEFAULT true) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT public.registrar_usuario(p_nombres, p_apellidos, '8' || lpad(p_n::text, 8, '0'), 'reg' || p_n || '@mail.co',
                                  '31' || lpad(p_n::text, 8, '0'), '1990-05-17', tests.hash(), true, p_ref, p_verificacion) $$;

-- id de usuario a partir del jsonb que devuelve registrar_usuario, su codigo de referido y su cuenta
CREATE OR REPLACE FUNCTION tests.uid(p_reg jsonb) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT (p_reg ->> 'usuario_id')::uuid $$;
CREATE OR REPLACE FUNCTION tests.cod(p_usuario uuid) RETURNS text LANGUAGE sql STABLE AS $$ SELECT codigo_referido::text FROM public.usuario WHERE id = p_usuario $$;
CREATE OR REPLACE FUNCTION tests.cta(p_usuario uuid) RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT id FROM public.cuenta WHERE usuario_id = p_usuario $$;

-- Foto del estado confirmado relevante para el registro (para comprobar que un fallo no deja NADA):
-- usuarios, cuentas, patas, eventos de auditoria, saldos y banderas de bono.
CREATE OR REPLACE FUNCTION tests.huella_registro() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT (SELECT count(*) FROM public.usuario) || '|' || (SELECT count(*) FROM public.cuenta) || '|' || (SELECT count(*) FROM public.transaccion)
         || '|' || (SELECT coalesce(sum(balance), 0) FROM public.cuenta) || '|' || (SELECT count(*) FROM public.usuario WHERE bono_referido_pagado)
         || '|' || (SELECT count(*) FROM public.usuario WHERE correoverificado) $$;

-- INYECCION DE FALLOS. Regla en el parametro de sesion  tests.falla :
--   tx:N        falla al insertar la N-esima pata del libro de la transaccion (despues de aplicar su saldo)
--   corte:N     corta la conexion (pg_terminate_backend) al insertar la N-esima pata
--   cuenta      falla al insertar la cuenta
--   usuario     falla al insertar el usuario
--   bono_flag   falla al marcar bono_referido_pagado (DESPUES de escribir las patas del bono)
--   verificar   falla al marcar correoverificado
CREATE OR REPLACE FUNCTION tests.trg_falla() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_regla text := coalesce(current_setting('tests.falla', true), '');
  v_c     int;
BEGIN
  IF v_regla = '' THEN RETURN NEW; END IF;
  IF TG_TABLE_NAME = 'transaccion' AND v_regla ~ '^(tx|corte):[0-9]+$' THEN
    v_c := coalesce(nullif(current_setting('tests.falla_c', true), ''), '0')::int + 1;
    PERFORM set_config('tests.falla_c', v_c::text, true);
    IF v_c = split_part(v_regla, ':', 2)::int THEN
      IF split_part(v_regla, ':', 1) = 'corte' THEN
        PERFORM pg_terminate_backend(pg_backend_pid());
        PERFORM pg_sleep(5);
      END IF;
      RAISE EXCEPTION 'FALLA INYECTADA en la pata %', v_c USING ERRCODE = 'P0001';
    END IF;
  ELSIF TG_TABLE_NAME = 'cuenta' THEN
    IF v_regla = 'cuenta' THEN
      RAISE EXCEPTION 'FALLA INYECTADA al insertar la cuenta' USING ERRCODE = 'P0001';
    END IF;
  ELSIF TG_TABLE_NAME = 'usuario' THEN
    IF TG_OP = 'INSERT' THEN
      IF v_regla = 'usuario' THEN
        RAISE EXCEPTION 'FALLA INYECTADA al insertar el usuario' USING ERRCODE = 'P0001';
      END IF;
    ELSIF v_regla = 'bono_flag' THEN
      IF NEW.bono_referido_pagado AND NOT OLD.bono_referido_pagado THEN
        RAISE EXCEPTION 'FALLA INYECTADA al marcar la bandera del bono' USING ERRCODE = 'P0001';
      END IF;
    ELSIF v_regla = 'verificar' THEN
      IF NEW.correoverificado AND NOT OLD.correoverificado THEN
        RAISE EXCEPTION 'FALLA INYECTADA al verificar el correo' USING ERRCODE = 'P0001';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION tests.instalar_fallas() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DROP TRIGGER IF EXISTS trg_zz_falla ON public.transaccion;
  DROP TRIGGER IF EXISTS trg_zz_falla ON public.cuenta;
  DROP TRIGGER IF EXISTS trg_zz_falla ON public.usuario;
  CREATE TRIGGER trg_zz_falla BEFORE INSERT ON public.transaccion FOR EACH ROW EXECUTE FUNCTION tests.trg_falla();
  CREATE TRIGGER trg_zz_falla BEFORE INSERT ON public.cuenta      FOR EACH ROW EXECUTE FUNCTION tests.trg_falla();
  CREATE TRIGGER trg_zz_falla BEFORE INSERT OR UPDATE ON public.usuario FOR EACH ROW EXECUTE FUNCTION tests.trg_falla();
END $$;

CREATE OR REPLACE FUNCTION tests.quitar_fallas() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DROP TRIGGER IF EXISTS trg_zz_falla ON public.transaccion;
  DROP TRIGGER IF EXISTS trg_zz_falla ON public.cuenta;
  DROP TRIGGER IF EXISTS trg_zz_falla ON public.usuario;
END $$;

-- Reinicia el contador de patas (dentro de la transaccion actual) y fija la regla
CREATE OR REPLACE FUNCTION tests.falla(p_regla text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('tests.falla_c', '0', true), set_config('tests.falla', p_regla, true) $$;

-- E8: el estado global SIN la comprobacion de planes de credito. Las pruebas de E2/E3 fabrican creditos sinteticos (desembolso y cuotas solo en el libro, sin plan de cuotas)
-- para probar el LIBRO; el control de planes (ct_credito_plan / v_integridad_creditos) se prueba en 57 y 58.
CREATE OR REPLACE FUNCTION tests.ok_sin_plan() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT g.contenedores_con_desvio = 0 AND g.grupos_con_error = 0 AND g.cuentas_con_desvio_i5u = 0 AND g.defensas_fallidas = 0
         AND g.desvio_transferencias = 0 AND g.controles_auth_fallidos = 0 FROM public.v_integridad_global g $$;
