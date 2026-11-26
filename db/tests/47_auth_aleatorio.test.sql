-- 47_auth_aleatorio.test.sql · Etapa 4 · entradas ALEATORIAS contra un ORACULO independiente: 700 intentos de registro (validos e invalidos, con 0 a 3
-- defectos a la vez, referidos con verificacion apagada/encendida/NULL, duplicados con otro formato). El oraculo conoce solo el ORDEN de las reglas
-- y el mensaje de cada una; no llama a las funciones de E4 para decidir. Cada rechazo debe dejar la foto del estado INTACTA; cada exito, exactamente
-- 1 usuario + 1 cuenta + 10 patas (+ 2 si se pago el bono). Semilla fija: reproducible.
BEGIN;

SELECT setseed(0.47);
CREATE TEMP TABLE t_reg (ced text, cor text, tel text, cod text, usr text);
CREATE TEMP TABLE t_res (resultado text, n int);

DO $do$
DECLARE
  N       constant int := 700;
  i int; k int; j int; kind int; nk int;
  kinds   int[]; usados int[];
  contador int := 0;
  hoy date := (now() AT TIME ZONE 'America/Bogota')::date;
  noms text[] := ARRAY['Ana', 'José María', '李明', 'Ivan', 'محمد', 'Μαρία', 'Jean-Luc', 'D’Artagnan', 'Ñandú', 'שלום'];
  apes text[] := ARRAY['Gómez', 'Núñez Pérez', '王', 'Петров', 'علي', 'Παπαδοπούλου', 'O''Brien', 'De la Cruz', 'Muñoz-Peña', 'כהן'];
  msgs text[] := ARRAY['Debe aceptar la política de datos', 'Datos de registro incompletos', 'Nombre inválido', 'Apellido inválido', 'Cédula inválida',
                       'Correo inválido', 'Teléfono inválido', 'Datos de registro inválidos', 'Fecha de nacimiento inválida', 'Código de referido inválido',
                       'Fecha de nacimiento inválida', 'Debes ser mayor de edad para registrarte', 'Código de referido inválido',
                       'La cédula ya está registrada', 'El correo ya está registrado', 'El teléfono ya está registrado'];
  p_pol boolean; p_nom text; p_ape text; p_ced text; p_cor text; p_tel text; p_nac text; p_hash text; p_ref text; p_ver boolean;
  r_ced text; r_cor text; r_tel text; r_cod text;
  v_esp text; v_msg text; v_h0 text; v_res jsonb; v_pat0 bigint;
  ok int := 0; rech int := 0; bonos int := 0; mal text := ''; v_target int;
  v_campo int;
  porn int; v_extra int;
BEGIN
  FOR i IN 1 .. N LOOP
    contador := contador + 1;
    -- valores validos por defecto (unicos)
    p_pol := true; p_nom := noms[1 + floor(random() * 10)::int]; p_ape := apes[1 + floor(random() * 10)::int];
    p_ced := '5' || lpad(contador::text, 7, '0'); p_cor := 'a' || contador || '@mail.co'; p_tel := '33' || lpad(contador::text, 8, '0');
    p_nac := '1985-06-15'; p_hash := tests.hash(); p_ref := NULL;
    p_ver := (ARRAY[true, false, NULL])[1 + floor(random() * 3)::int];
    IF random() < 0.4 AND EXISTS (SELECT 1 FROM t_reg) THEN SELECT cod INTO p_ref FROM t_reg ORDER BY random() LIMIT 1; END IF;
    -- defectos: 0 (45 %), 1 (35 %), 2 (15 %), 3 (5 %)
    porn := floor(random() * 100)::int;
    nk := CASE WHEN porn < 45 THEN 0 WHEN porn < 80 THEN 1 WHEN porn < 95 THEN 2 ELSE 3 END;
    kinds := ARRAY[]::int[];
    FOR j IN 1 .. nk LOOP
      kind := 1 + floor(random() * 16)::int;
      IF kind IN (14, 15, 16) AND NOT EXISTS (SELECT 1 FROM t_reg) THEN CONTINUE; END IF;
      IF NOT kind = ANY (kinds) THEN kinds := kinds || kind; END IF;
    END LOOP;
    -- se aplican de MENOR prioridad a MAYOR: el defecto de menor indice (el que el oraculo espera) queda al final y gana
    FOR kind IN REVERSE 16 .. 1 LOOP
      CONTINUE WHEN NOT kind = ANY (kinds);
      CASE kind
        WHEN 16 THEN SELECT tel INTO r_tel FROM t_reg ORDER BY random() LIMIT 1; p_tel := r_tel;
        WHEN 15 THEN SELECT cor INTO r_cor FROM t_reg ORDER BY random() LIMIT 1; p_cor := upper(r_cor);
        WHEN 14 THEN SELECT ced INTO r_ced FROM t_reg ORDER BY random() LIMIT 1; p_ced := left(r_ced, 1) || '.' || substr(r_ced, 2);
        WHEN 13 THEN p_ref := gen_random_uuid()::text;
        WHEN 12 THEN p_nac := to_char(hoy - interval '17 years', 'YYYY-MM-DD');
        WHEN 11 THEN p_nac := (ARRAY['1899-12-31', '2999-01-01', to_char(hoy - interval '121 years', 'YYYY-MM-DD')])[1 + floor(random() * 3)::int];
        WHEN 10 THEN p_ref := 'no-es-un-uuid';
        WHEN 9  THEN p_nac := (ARRAY['1990/05/17', '1990-02-30', 'abcd', '1990-5-17'])[1 + floor(random() * 4)::int];
        WHEN 8  THEN p_hash := (ARRAY['Banco2026', '$2c$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy', '$2b$10$corto'])[1 + floor(random() * 3)::int];
        WHEN 7  THEN p_tel := (ARRAY['123', '+0123456789', '3001+234567', '573001234567'])[1 + floor(random() * 4)::int];
        WHEN 6  THEN p_cor := (ARRAY['sinarroba', 'a@b', 'a b@c.co', '@x.co'])[1 + floor(random() * 4)::int];
        WHEN 5  THEN p_ced := (ARRAY['12345', '12+34567', 'abc', '12345678901'])[1 + floor(random() * 4)::int];
        WHEN 4  THEN p_ape := (ARRAY['Perez3', 'Pe/rez', 'a;b'])[1 + floor(random() * 3)::int];
        WHEN 3  THEN p_nom := (ARRAY['Ju4n', 'a;b', 'Robert''); DROP TABLE usuario;--'])[1 + floor(random() * 3)::int];
        WHEN 2  THEN v_campo := 1 + floor(random() * 7)::int;
                     IF v_campo = 1 THEN p_nom := ''; ELSIF v_campo = 2 THEN p_ape := NULL; ELSIF v_campo = 3 THEN p_ced := '  ';
                     ELSIF v_campo = 4 THEN p_cor := ''; ELSIF v_campo = 5 THEN p_tel := NULL; ELSIF v_campo = 6 THEN p_nac := ''; ELSE p_hash := NULL; END IF;
        WHEN 1  THEN p_pol := (ARRAY[false, NULL])[1 + floor(random() * 2)::int];
      END CASE;
    END LOOP;
    -- ORACULO: el defecto de menor indice decide el mensaje; sin defectos, se espera exito
    v_esp := 'OK';
    IF array_length(kinds, 1) IS NOT NULL THEN SELECT msgs[min(x)] INTO v_esp FROM unnest(kinds) x; END IF;

    v_h0 := tests.huella_registro(); v_pat0 := (SELECT count(*) FROM public.transaccion);
    BEGIN
      v_res := public.registrar_usuario(p_nom, p_ape, p_ced, p_cor, p_tel, p_nac, p_hash, p_pol, p_ref, p_ver);
      v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN
      v_msg := SQLERRM; v_res := NULL;
    END;
    IF v_msg IS DISTINCT FROM v_esp THEN
      mal := mal || '#' || i || ' esperado [' || v_esp || '] obtenido [' || v_msg || '] kinds=' || coalesce(kinds::text, '{}') || '; ';
    END IF;
    IF v_msg = 'OK' THEN
      ok := ok + 1;
      v_extra := 0;
      IF p_ref IS NOT NULL AND p_ver IS NOT NULL AND NOT p_ver THEN bonos := bonos + 1; v_extra := 2; END IF;
      IF (SELECT count(*) FROM public.transaccion) <> v_pat0 + 10 + v_extra THEN
        mal := mal || '#' || i || ' numero de patas incorrecto; ';
      END IF;
      INSERT INTO t_reg SELECT u.cedula, u.correo, u.telefono, u.codigo_referido::text, u.username FROM public.usuario u WHERE u.id = (v_res ->> 'usuario_id')::uuid;
    ELSE
      rech := rech + 1;
      IF tests.huella_registro() IS DISTINCT FROM v_h0 THEN mal := mal || '#' || i || ' un RECHAZO dejo rastro; '; END IF;
    END IF;
    INSERT INTO t_res VALUES (v_msg, 1);
    IF length(mal) > 1500 THEN EXIT; END IF;
  END LOOP;
  PERFORM tests.assert_eq(format('%s intentos aleatorios: el resultado (OK o mensaje exacto) coincide con el oraculo en TODOS; cada rechazo deja el estado intacto y cada exito escribe exactamente 1+1+10(+2) filas', N), mal, ''::text);
  PERFORM tests.assert_true(format('el generador ejercito todo: %s registros exitosos (%s con bono inmediato) y %s rechazos de %s mensajes distintos', ok, bonos, rech, (SELECT count(DISTINCT resultado) - 1 FROM t_res)),
                            ok > 150 AND rech > 150 AND bonos > 10 AND (SELECT count(DISTINCT resultado) FROM t_res) >= 14);
END $do$;

SELECT assert_eq('al final: usuarios = cuentas = registros exitosos del modelo', (SELECT (count(*) = (SELECT count(*) FROM public.cuenta), count(*) = (SELECT count(*) FROM t_reg))::text FROM public.usuario), '(t,t)'::text);
SELECT assert_eq('todos los usernames son distintos y cumplen el patron del banco', (SELECT (count(*) = count(DISTINCT username), bool_and(username ~ '^[a-z][a-z0-9]{3,29}$'))::text FROM public.usuario), '(t,t)'::text);
SELECT assert_eq('todas las cedulas, correos y telefonos son distintos (las restricciones UNIQUE nunca se vieron violadas por el camino normal)',
                 (SELECT (count(*) = count(DISTINCT cedula), count(*) = count(DISTINCT correo), count(*) = count(DISTINCT telefono))::text FROM public.usuario), '(t,t,t)'::text);
SELECT assert_eq('cada cuenta tiene exactamente 5 grupos de ingreso', (SELECT count(*) FROM (SELECT c.id FROM public.cuenta c LEFT JOIN public.transaccion t ON t.cuenta_id = c.id AND t.tipo = 'INGRESO_SIMULADO' GROUP BY c.id HAVING count(DISTINCT t.grupo_id) <> 5) x), 0::bigint);
SELECT assert_eq('bandera de bono = grupos de bono (v_integridad_auth) y conservacion del dinero (v_integridad_global) en orden', ((SELECT bool_and(ok) FROM public.v_integridad_auth), (SELECT ok FROM public.v_integridad_global))::text, '(t,t)'::text);
SELECT assert_eq('ningun usuario tiene un hash que no sea bcrypt ni un rol distinto de CLIENTE', (SELECT count(*) FROM public.usuario WHERE NOT public._es_hash_bcrypt(password_hash) OR rol <> 'CLIENTE'), 0::bigint);

ROLLBACK;
