-- ============================================================================
-- 10_funciones_seed.sql - Etapa 14 - Funciones SOLO-SEED (D5) en el esquema TEMPORAL "seed"
--
-- Que es: el pegamento minimo para crear los usuarios FIJOS del contrato §5 (jperez483, cgomez12, admin1, bloqueado1, cuenta 4001002003)
-- con las funciones REALES de negocio. registrar_usuario genera username/cuenta al azar y la guardia de cuenta hace inmutable numero_cuenta,
-- asi que el usuario se crea con registrar_usuario (validaciones, 5 ingresos, bono) y, ANTES de cualquier otra operacion, seed.fijar_identidad
-- le pone los valores fijos. El ADMIN (sin cuenta) lo inserta seed.crear_admin.
--
-- Reglas: el esquema NO es del banco: lo crea sembrar.sh y lo ELIMINA siempre (incluso si algo falla); no quedan objetos ni permisos.
-- Todo se ejecuta como SUPERUSUARIO (ctl seed). Ninguna de estas funciones existe en el banco terminado.
-- ============================================================================
DROP SCHEMA IF EXISTS seed CASCADE;
CREATE SCHEMA seed;
REVOKE ALL ON SCHEMA seed FROM PUBLIC;

-- configuracion del seed: hoy REAL (Bogota) al empezar y el hash fijo de la clave demo (D-E14-D2)
CREATE TABLE seed.cfg (
  id    smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  r     date NOT NULL,
  hash  text NOT NULL
);
-- hash bcrypt (coste 10) de 'Banco2026', generado con pgcrypto; las pruebas lo verifican con crypt()
INSERT INTO seed.cfg (r, hash) VALUES ((now() AT TIME ZONE 'America/Bogota')::date, '$2a$10$NMLfLjyJywHJyB0aLK92VOZdoC4A82BHFFTmkfQhk8JSi9whFuDOa');

CREATE FUNCTION seed.r() RETURNS date LANGUAGE sql STABLE AS $$ SELECT r FROM seed.cfg $$;

-- el banco debe estar VACIO de operaciones (ninguna pata del libro)
CREATE FUNCTION seed.exigir_banco_sin_operaciones() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.transaccion) THEN
    RAISE EXCEPTION 'El seed solo corre sobre un banco vacio (ya hay operaciones en el libro)';
  END IF;
END $$;

CREATE FUNCTION seed.u(p_username text) RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT id FROM public.usuario WHERE username = p_username $$;
CREATE FUNCTION seed.admin_id() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT id FROM public.usuario WHERE username = 'admin1' $$;

-- ADMIN inicial: sin cuenta (modelo de la etapa 1), con el hash demo; no existe camino publico para esto
CREATE FUNCTION seed.crear_admin(p_username text, p_nombres text, p_apellidos text, p_cedula text, p_correo text, p_telefono text, p_nacimiento date)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM seed.exigir_banco_sin_operaciones();
  IF NOT public._es_hash_bcrypt((SELECT hash FROM seed.cfg)) THEN RAISE EXCEPTION 'seed: el hash demo no es bcrypt'; END IF;
  INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol, estado, correoverificado, creado_en)
  VALUES (p_username, (SELECT hash FROM seed.cfg), p_nombres, p_apellidos, p_cedula, lower(p_correo), p_telefono, p_nacimiento, 'ADMIN', 'ACTIVO', true, public.ahora_banco())
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Fija username, numero de cuenta y codigo de referido de un cliente RECIEN registrado (solo tiene sus 5 ingresos simulados).
-- session_replication_role = replica (solo superusuario) salta la guardia de numero_cuenta; se restablece SIEMPRE.
CREATE FUNCTION seed.fijar_identidad(p_usuario uuid, p_username text, p_cuenta text, p_codigo uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_old text; v_cta uuid;
BEGIN
  IF p_username !~ '^[a-z][a-z0-9]{2,29}$' THEN RAISE EXCEPTION 'seed: username invalido %', p_username; END IF;
  IF p_cuenta !~ '^[0-9]{10}$' THEN RAISE EXCEPTION 'seed: numero de cuenta invalido %', p_cuenta; END IF;
  SELECT c.id, c.numero_cuenta INTO v_cta, v_old FROM public.cuenta c WHERE c.usuario_id = p_usuario;
  IF v_cta IS NULL THEN RAISE EXCEPTION 'seed: el usuario no es un CLIENTE con cuenta'; END IF;
  -- solo antes de cualquier otra operacion: la cuenta tiene unicamente ingresos simulados y ningun producto
  IF EXISTS (SELECT 1 FROM public.transaccion t WHERE t.cuenta_id = v_cta AND t.tipo <> 'INGRESO_SIMULADO')
     OR EXISTS (SELECT 1 FROM public.bolsillo WHERE cuenta_id = v_cta) OR EXISTS (SELECT 1 FROM public.cdt WHERE cuenta_id = v_cta)
     OR EXISTS (SELECT 1 FROM public.credito WHERE cuenta_id = v_cta) THEN
    RAISE EXCEPTION 'seed: la identidad solo se fija justo despues de registrar (la cuenta ya tiene operaciones)';
  END IF;
  PERFORM pg_catalog.set_config('session_replication_role', 'replica', true);
  BEGIN
    UPDATE public.usuario SET username = p_username, codigo_referido = coalesce(p_codigo, codigo_referido) WHERE id = p_usuario;
    UPDATE public.cuenta  SET numero_cuenta = p_cuenta WHERE id = v_cta;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_catalog.set_config('session_replication_role', 'origin', true);
    RAISE;
  END;
  PERFORM pg_catalog.set_config('session_replication_role', 'origin', true);
  -- ningun asiento puede quedar apuntando al numero anterior (el bono del referidor lo guardaria como contraparte)
  IF EXISTS (SELECT 1 FROM public.transaccion WHERE contraparte_cuenta = v_old) THEN
    RAISE EXCEPTION 'seed: un asiento menciona el numero de cuenta anterior %', v_old;
  END IF;
END $$;

-- Cliente completo con las funciones reales: registrar_usuario (verificacion ACTIVA) -> identidad fija -> verificar_correo (paga el bono al referidor, ya con el numero fijo)
CREATE FUNCTION seed.cliente(p_nombres text, p_apellidos text, p_cedula text, p_correo text, p_telefono text, p_nacimiento text,
                             p_username text, p_cuenta text, p_codigo uuid DEFAULT NULL, p_referido text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  v_id := (public.registrar_usuario(p_nombres, p_apellidos, p_cedula, p_correo, p_telefono, p_nacimiento,
                                    (SELECT hash FROM seed.cfg), true, p_referido, true) ->> 'usuario_id')::uuid;
  PERFORM seed.fijar_identidad(v_id, p_username, p_cuenta, p_codigo);
  PERFORM public.verificar_correo(v_id);
  RETURN v_id;
END $$;

-- Mueve el reloj con la funcion REAL del administrador (admin_set_reloj): offset en dias respecto de R (hoy real al empezar)
CREATE FUNCTION seed.dia(p_offset integer) RETURNS date LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.admin_set_reloj(seed.admin_id(), false, (seed.r() + p_offset)::text);
  RETURN seed.r() + p_offset;
END $$;

-- Vuelve al modo REAL (siempre permitido): el hoy del banco es el de verdad y no queda ninguna pata en el futuro
CREATE FUNCTION seed.volver_a_real() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.admin_set_reloj(seed.admin_id(), true, NULL);
END $$;
