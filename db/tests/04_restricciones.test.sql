-- 04_restricciones.test.sql · Etapa 1 · restricciones de cada tabla (UNIQUE, CHECK, FK, NOT NULL).
-- Cada restriccion tiene prueba POSITIVA (el dato valido entra) y NEGATIVA (assert_violates exige el
-- NOMBRE EXACTO de la restriccion que falla, no solo "algun error").
-- Todo el archivo es UNA transaccion que termina en ROLLBACK: no deja datos. Corre como superusuario.
-- E2: estas pruebas aislan los CHECK/UNIQUE/FK de E1 (insertan cuentas con saldo, CDT y creditos "terminados", etc.).
-- Se apagan SOLO los triggers de usuario (guardias y libro mayor de E2); las FK (triggers internos de PostgreSQL)
-- SIGUEN ACTIVAS: es mas estricto que session_replication_role = replica, que tambien las apagaria.
BEGIN;
SELECT tests.sin_triggers_de_usuario();

-- ---------------------------------------------------------------------------------------------
-- Funciones temporales de ayuda (viven solo en esta sesion)
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION pg_temp.nu(p_username text, p_cedula text, p_correo text, p_tel text,
                           p_rol public.rol_usuario DEFAULT 'CLIENTE', p_nombres text DEFAULT 'Nombre',
                           p_apellidos text DEFAULT 'Apellido', p_nac date DEFAULT '1990-01-01',
                           p_hash text DEFAULT '$2b$10$hash') RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol)
  VALUES (p_username, p_hash, p_nombres, p_apellidos, p_cedula, p_correo, p_tel, p_nac, p_rol) RETURNING id $$;

CREATE FUNCTION pg_temp.nc(p_usuario uuid, p_num text, p_balance numeric DEFAULT 0,
                           p_rol public.rol_usuario DEFAULT 'CLIENTE') RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO public.cuenta (usuario_id, numero_cuenta, balance, rol) VALUES (p_usuario, p_num, p_balance, p_rol) RETURNING id $$;

CREATE FUNCTION pg_temp.nb(p_cuenta uuid, p_nombre text, p_balance numeric DEFAULT 0, p_cobro date DEFAULT '2026-11-21')
RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO public.bolsillo (cuenta_id, nombre, balance, ultimo_cobro) VALUES (p_cuenta, p_nombre, p_balance, p_cobro) RETURNING id $$;

CREATE FUNCTION pg_temp.nd(p_nombre text, p_plazo int, p_tasa numeric, p_min numeric) RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO public.cdt_definicion (nombre, plazo_dias, tasa_anual, monto_min) VALUES (p_nombre, p_plazo, p_tasa, p_min) RETURNING id $$;

CREATE FUNCTION pg_temp.ncdt(p_cuenta uuid, p_def uuid, p_monto numeric, p_ini date, p_fin date, p_plazo int,
                             p_gen numeric DEFAULT 0, p_ult date DEFAULT NULL, p_nombre text DEFAULT 'CDT') RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO public.cdt (cuenta_id, definicion_id, nombre, monto, tasa_anual, plazo_dias, fecha_inicio, fecha_fin, generado_acumulado, ultimo_cobro)
  VALUES (p_cuenta, p_def, p_nombre, p_monto, 10, p_plazo, p_ini, p_fin, p_gen, coalesce(p_ult, p_ini)) RETURNING id $$;

CREATE FUNCTION pg_temp.np(p_nombre text, p_tasa numeric, p_mmin numeric, p_mmax numeric, p_pmin int, p_pmax int,
                           p_tope numeric DEFAULT NULL, p_mult numeric DEFAULT NULL, p_edad boolean DEFAULT false) RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO public.credito_producto (nombre, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses, tope_absoluto, multiplicador_balance, aplica_regla_edad)
  VALUES (p_nombre, p_tasa, p_mmin, p_mmax, p_pmin, p_pmax, p_tope, p_mult, p_edad) RETURNING id $$;

CREATE FUNCTION pg_temp.nk(p_cuenta uuid, p_prod uuid, p_monto numeric, p_capital numeric,
                           p_estado public.estado_credito DEFAULT 'ACTIVO', p_plazo int DEFAULT 12) RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO public.credito (cuenta_id, producto_id, monto, tasa_anual, plazo_meses, fecha_desembolso, capital_pendiente, fecha_interes, estado)
  VALUES (p_cuenta, p_prod, p_monto, 20, p_plazo, '2026-11-21', p_capital, '2026-11-21', p_estado) RETURNING id $$;

CREATE FUNCTION pg_temp.nq(p_credito uuid, p_num int, p_valor numeric, p_cap numeric, p_int numeric,
                           p_pagada boolean DEFAULT false, p_fpago date DEFAULT NULL) RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO public.cuota (credito_id, numero, fecha_vencimiento, valor_cuota_original, valor_cuota, capital_programado, interes_programado, pagada, fecha_pago)
  VALUES (p_credito, p_num, '2026-12-21', p_valor, p_valor, p_cap, p_int, p_pagada, p_fpago) RETURNING id $$;

-- ---------------------------------------------------------------------------------------------
-- Datos base (validos)
-- ---------------------------------------------------------------------------------------------
INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol, codigo_referido, referido_por) VALUES
  ('10000000-0000-4000-8000-000000000001','jperez483','$2b$10$h','Juan','Pérez','1020304050','juan.perez@correo.co','3001234567','1990-05-01','CLIENTE','c0000000-0000-4000-8000-000000000001',NULL),
  ('10000000-0000-4000-8000-000000000002','cgomez12','$2b$10$h','Camila','Rodríguez','1012345678','camila@correo.co','3209876543','1995-01-15','CLIENTE','c0000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001'),
  ('10000000-0000-4000-8000-0000000000aa','admin1','$2b$10$h','Administración','Banco','900100200','admin@bancodigital.co','3100000000','1985-03-03','ADMIN','c0000000-0000-4000-8000-0000000000aa',NULL);
INSERT INTO public.usuario (id, username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento)
  VALUES ('10000000-0000-4000-8000-000000000003','sincuenta1','$2b$10$h','Sin','Cuenta','555555555','sin.cuenta@correo.co','3155555555','1992-02-02');
INSERT INTO public.cuenta (id, usuario_id, numero_cuenta, balance) VALUES
  ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','4001002003', 1000),
  ('20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','4003004005', 0);
INSERT INTO public.bolsillo (id, cuenta_id, nombre, ultimo_cobro) VALUES
  ('30000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','Viajes','2026-11-21'),
  ('30000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001','Viajes','2026-11-21');   -- mismo nombre: permitido
INSERT INTO public.cdt_definicion (id, nombre, plazo_dias, tasa_anual, monto_min)
  VALUES ('40000000-0000-4000-8000-000000000001','CDT 90 dias', 90, 10, 100000);
INSERT INTO public.cdt (id, cuenta_id, definicion_id, nombre, monto, tasa_anual, plazo_dias, fecha_inicio, fecha_fin, ultimo_cobro)
  VALUES ('50000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001',
          'CDT 90 dias', 1000000, 10, 90, DATE '2026-11-01', DATE '2026-11-01' + 90, DATE '2026-11-01');
INSERT INTO public.credito_producto (id, nombre, tasa_anual, monto_min, monto_max, plazo_max_meses) VALUES
  ('60000000-0000-4000-8000-000000000001','Libre inversion', 20, 1000000, 30000000, 24),
  ('60000000-0000-4000-8000-000000000002','Vehiculo', 18, 50000000, 200000000, 120);
INSERT INTO public.credito (id, cuenta_id, producto_id, monto, tasa_anual, plazo_meses, fecha_desembolso, capital_pendiente, fecha_interes)
  VALUES ('70000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000001',
          5000000, 20, 24, '2026-11-21', 5000000, '2026-11-21');
INSERT INTO public.cuota (credito_id, numero, fecha_vencimiento, valor_cuota_original, valor_cuota, capital_programado, interes_programado)
  VALUES ('70000000-0000-4000-8000-000000000001', 1, '2026-12-21', 300000, 300000, 200000, 100000);

-- ============================================================================
-- usuario
-- ============================================================================
SELECT assert_eq('usuario: los datos base entraron (4 usuarios)', (SELECT count(*) FROM public.usuario), 4::bigint);
SELECT assert_eq('usuario: defaults (CLIENTE, ACTIVO, sin verificar, sin bono, codigo_referido generado)',
                 (SELECT (rol::text, estado::text, correoverificado, bono_referido_pagado, codigo_referido IS NOT NULL, creado_en IS NOT NULL)::text
                    FROM public.usuario WHERE username = 'sincuenta1'),
                 '(CLIENTE,ACTIVO,f,f,t,t)'::text);
SELECT assert_ok('usuario: un ADMIN valido entra (rol ADMIN, sin referidor)', $$SELECT pg_temp.nu('admin2','900100201','admin2@bancodigital.co','3100000001','ADMIN')$$);
SELECT assert_ok('usuario: un CLIENTE referido y con bono pagado es valido',
                 $$INSERT INTO public.usuario (username,password_hash,nombres,apellidos,cedula,correo,telefono,fecha_nacimiento,referido_por,bono_referido_pagado)
                   VALUES ('ref00001','h','R','R','800000001','ref1@x.co','3200000001','1990-01-01','10000000-0000-4000-8000-000000000001',true)$$);

SELECT assert_violates('usuario: username duplicado', $$SELECT pg_temp.nu('jperez483','999000001','d1@x.co','3100000011')$$, 'uq_usuario_username', '23505');
SELECT assert_violates('usuario: cedula duplicada',   $$SELECT pg_temp.nu('dup00002','1020304050','d2@x.co','3100000012')$$, 'uq_usuario_cedula', '23505');
SELECT assert_violates('usuario: correo duplicado',   $$SELECT pg_temp.nu('dup00003','999000003','juan.perez@correo.co','3100000013')$$, 'uq_usuario_correo', '23505');
SELECT assert_violates('usuario: telefono duplicado', $$SELECT pg_temp.nu('dup00004','999000004','d4@x.co','3001234567')$$, 'uq_usuario_telefono', '23505');
SELECT assert_violates('usuario: codigo_referido duplicado',
                       $$INSERT INTO public.usuario (username,password_hash,nombres,apellidos,cedula,correo,telefono,fecha_nacimiento,codigo_referido)
                         VALUES ('dup00005','h','N','A','999000005','d5@x.co','3100000015','1990-01-01','c0000000-0000-4000-8000-000000000001')$$,
                       'uq_usuario_codigo_referido', '23505');
SELECT assert_violates('usuario: id duplicado (PK)',
                       $$INSERT INTO public.usuario (id,username,password_hash,nombres,apellidos,cedula,correo,telefono,fecha_nacimiento,rol)
                         VALUES ('10000000-0000-4000-8000-000000000001','dup00006','h','N','A','999000006','d6@x.co','3100000016','1990-01-01','CLIENTE')$$,
                       'pk_usuario', '23505');

SELECT assert_violates('usuario: username con mayusculas', $$SELECT pg_temp.nu('Abc123','999000010','v10@x.co','3100000020')$$, 'ck_usuario_username');
SELECT assert_violates('usuario: username demasiado corto (2)', $$SELECT pg_temp.nu('ab','999000011','v11@x.co','3100000021')$$, 'ck_usuario_username');
SELECT assert_violates('usuario: username que empieza por digito', $$SELECT pg_temp.nu('1abc','999000012','v12@x.co','3100000022')$$, 'ck_usuario_username');
SELECT assert_violates('usuario: username con guion bajo', $$SELECT pg_temp.nu('ab_cd1','999000013','v13@x.co','3100000023')$$, 'ck_usuario_username');
SELECT assert_violates('usuario: username demasiado largo (31)', $$SELECT pg_temp.nu(repeat('a',31),'999000014','v14@x.co','3100000024')$$, 'ck_usuario_username');
SELECT assert_ok('usuario: username de 3 y de 30 caracteres', $$SELECT pg_temp.nu('abc','999000015','v15@x.co','3100000025'), pg_temp.nu(repeat('b',30),'999000016','v16@x.co','3100000026')$$);
SELECT assert_violates('usuario: correo sin arroba', $$SELECT pg_temp.nu('mail0001','999000020','sinarroba','3100000030')$$, 'ck_usuario_correo_formato');
SELECT assert_violates('usuario: correo sin punto en el dominio', $$SELECT pg_temp.nu('mail0002','999000021','a@b','3100000031')$$, 'ck_usuario_correo_formato');
SELECT assert_violates('usuario: correo con espacio', $$SELECT pg_temp.nu('mail0003','999000022','a b@c.co','3100000032')$$, 'ck_usuario_correo_formato');
SELECT assert_violates('usuario: correo con mayusculas (el UNIQUE debe ser insensible a mayusculas)', $$SELECT pg_temp.nu('mail0004','999000023','JUAN.PEREZ@CORREO.CO','3100000033')$$, 'ck_usuario_correo_minusculas');
SELECT assert_violates('usuario: cedula con letras', $$SELECT pg_temp.nu('ced00001','12a45','c1@x.co','3100000040')$$, 'ck_usuario_cedula_digitos');
SELECT assert_violates('usuario: telefono con guion', $$SELECT pg_temp.nu('tel00001','999000030','t1@x.co','300-123')$$, 'ck_usuario_telefono_digitos');
SELECT assert_violates('usuario: nombres en blanco', $$SELECT pg_temp.nu('nom00001','999000031','n1@x.co','3100000050','CLIENTE','   ')$$, 'ck_usuario_textos_no_vacios');
SELECT assert_violates('usuario: apellidos vacios', $$SELECT pg_temp.nu('nom00002','999000032','n2@x.co','3100000051','CLIENTE','N','')$$, 'ck_usuario_textos_no_vacios');
SELECT assert_violates('usuario: nacimiento anterior a 1900', $$SELECT pg_temp.nu('nac00001','999000033','na1@x.co','3100000052','CLIENTE','N','A','1899-12-31')$$, 'ck_usuario_nacimiento_rango');
SELECT assert_violates('usuario: password_hash en blanco', $$SELECT pg_temp.nu('hash0001','999000034','h1@x.co','3100000053','CLIENTE','N','A','1990-01-01','  ')$$, 'ck_usuario_password_hash');
SELECT assert_raises('usuario: username es NOT NULL',
                     $$INSERT INTO public.usuario (password_hash,nombres,apellidos,cedula,correo,telefono,fecha_nacimiento) VALUES ('h','N','A','999000040','nn@x.co','3100000060','1990-01-01')$$,
                     NULL, '23502');

SELECT assert_violates('usuario: un ADMIN no puede tener referidor (subtipo)',
                       $$INSERT INTO public.usuario (username,password_hash,nombres,apellidos,cedula,correo,telefono,fecha_nacimiento,rol,referido_por)
                         VALUES ('adm00001','h','N','A','999000050','ad1@x.co','3100000070','1990-01-01','ADMIN','10000000-0000-4000-8000-000000000001')$$,
                       'ck_usuario_subtipo');
SELECT assert_violates('usuario: un ADMIN no puede tener bono de referido pagado (subtipo)',
                       $$INSERT INTO public.usuario (username,password_hash,nombres,apellidos,cedula,correo,telefono,fecha_nacimiento,rol,bono_referido_pagado)
                         VALUES ('adm00002','h','N','A','999000051','ad2@x.co','3100000071','1990-01-01','ADMIN',true)$$,
                       'ck_usuario_subtipo');
SELECT assert_violates('usuario: nadie se refiere a si mismo',
                       $$UPDATE public.usuario SET referido_por = id WHERE username = 'sincuenta1'$$, 'ck_usuario_no_se_refiere_a_si_mismo');
SELECT assert_violates('usuario: referido_por debe existir (FK recursiva)',
                       $$UPDATE public.usuario SET referido_por = '99999999-9999-4999-8999-999999999999' WHERE username = 'sincuenta1'$$,
                       'fk_usuario_referidor', '23503');
SELECT assert_raises('usuario: rol/estado fuera de los enumerados se rechazan',
                     $$UPDATE public.usuario SET estado = 'SUSPENDIDO' WHERE username = 'sincuenta1'$$, NULL, '22P02');

-- ============================================================================
-- cuenta  (subtipo CLIENTE; "como maximo una", NO "exactamente una")
-- ============================================================================
SELECT assert_ok('cuenta: un CLIENTE puede tener cuenta (positiva)', $$SELECT pg_temp.nc(pg_temp.nu('cli00001','777000001','cli1@x.co','3100000080'), '4000000001', 100.50)$$);
SELECT assert_eq('cuenta: el balance conserva 2 decimales', (SELECT balance::numeric FROM public.cuenta WHERE numero_cuenta = '4000000001'), 100.50::numeric);
SELECT assert_violates('cuenta: NO se puede crear una cuenta para un ADMIN (FK compuesta, rol por defecto)',
                       $$SELECT pg_temp.nc('10000000-0000-4000-8000-0000000000aa', '7000000001')$$, 'fk_cuenta_usuario', '23503');
SELECT assert_violates('cuenta: NO se puede forzar rol ADMIN en cuenta (CHECK)',
                       $$SELECT pg_temp.nc('10000000-0000-4000-8000-0000000000aa', '7000000002', 0, 'ADMIN')$$, 'ck_cuenta_rol_cliente');
SELECT assert_violates('cuenta: NO se puede cambiar a ADMIN el rol de un cliente que ya tiene cuenta',
                       $$UPDATE public.usuario SET rol = 'ADMIN' WHERE id = '10000000-0000-4000-8000-000000000001'$$, 'fk_cuenta_usuario', '23503');
SELECT assert_eq('cuenta: el esquema NO obliga a que un CLIENTE tenga cuenta (eso lo garantiza registrar_usuario, E4)',
                 (SELECT count(*) FROM public.usuario u WHERE u.rol = 'CLIENTE' AND u.username = 'sincuenta1'
                     AND NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.usuario_id = u.id)), 1::bigint);
SELECT assert_violates('cuenta: como MAXIMO una por usuario', $$SELECT pg_temp.nc('10000000-0000-4000-8000-000000000001', '4000000002')$$, 'uq_cuenta_usuario', '23505');
SELECT assert_violates('cuenta: numero de cuenta unico', $$SELECT pg_temp.nc('10000000-0000-4000-8000-000000000003', '4001002003')$$, 'uq_cuenta_numero', '23505');
SELECT assert_violates('cuenta: numero de 9 digitos', $$SELECT pg_temp.nc('10000000-0000-4000-8000-000000000003', '123456789')$$, 'ck_cuenta_numero_formato');
SELECT assert_violates('cuenta: numero de 11 digitos', $$SELECT pg_temp.nc('10000000-0000-4000-8000-000000000003', '12345678901')$$, 'ck_cuenta_numero_formato');
SELECT assert_violates('cuenta: numero con letras', $$SELECT pg_temp.nc('10000000-0000-4000-8000-000000000003', '40010020a3')$$, 'ck_cuenta_numero_formato');
SELECT assert_violates('cuenta: balance negativo', $$SELECT pg_temp.nc('10000000-0000-4000-8000-000000000003', '4000000003', -0.01)$$, 'ck_cuenta_balance_no_negativo');
SELECT assert_violates('cuenta: balance fuera del dominio dinero (10^13)', $$SELECT pg_temp.nc('10000000-0000-4000-8000-000000000003', '4000000004', 10000000000000)$$, 'ck_dinero_rango');
SELECT assert_violates('cuenta: el usuario debe existir', $$SELECT pg_temp.nc('99999999-9999-4999-8999-999999999999', '4000000005')$$, 'fk_cuenta_usuario', '23503');

-- ============================================================================
-- bolsillo  (el spec NO exige nombres unicos: se permiten duplicados)
-- ============================================================================
SELECT assert_eq('bolsillo: DOS bolsillos con el mismo nombre en la misma cuenta SI se permiten',
                 (SELECT count(*) FROM public.bolsillo WHERE cuenta_id = '20000000-0000-4000-8000-000000000001' AND nombre = 'Viajes'), 2::bigint);
SELECT assert_ok('bolsillo: bolsillo valido con saldo', $$SELECT pg_temp.nb('20000000-0000-4000-8000-000000000002', 'Emergencias', 250000)$$);
SELECT assert_violates('bolsillo: nombre en blanco', $$SELECT pg_temp.nb('20000000-0000-4000-8000-000000000002', '   ')$$, 'ck_bolsillo_nombre_no_vacio');
SELECT assert_violates('bolsillo: balance negativo', $$SELECT pg_temp.nb('20000000-0000-4000-8000-000000000002', 'X', -1)$$, 'ck_bolsillo_balance_no_negativo');
SELECT assert_violates('bolsillo: la cuenta debe existir', $$SELECT pg_temp.nb('99999999-9999-4999-8999-999999999999', 'X')$$, 'fk_bolsillo_cuenta', '23503');
SELECT assert_raises('bolsillo: ultimo_cobro es NOT NULL (lo fija la funcion al crear)',
                     $$INSERT INTO public.bolsillo (cuenta_id, nombre) VALUES ('20000000-0000-4000-8000-000000000002', 'X')$$, NULL, '23502');

-- ============================================================================
-- cdt_definicion y cdt
-- ============================================================================
SELECT assert_ok('cdt_definicion: definicion valida (tasa 0.001 y 100 son los extremos)', $$SELECT pg_temp.nd('CDT 180', 180, 100, 500000), pg_temp.nd('CDT 360', 360, 0.001, 1)$$);
SELECT assert_violates('cdt_definicion: nombre unico', $$SELECT pg_temp.nd('CDT 90 dias', 90, 10, 1)$$, 'uq_cdt_definicion_nombre', '23505');
SELECT assert_violates('cdt_definicion: nombre en blanco', $$SELECT pg_temp.nd(' ', 90, 10, 1)$$, 'ck_cdt_definicion_nombre_no_vacio');
SELECT assert_violates('cdt_definicion: plazo 0', $$SELECT pg_temp.nd('P0', 0, 10, 1)$$, 'ck_cdt_definicion_plazo');
SELECT assert_violates('cdt_definicion: monto minimo 0', $$SELECT pg_temp.nd('M0', 30, 10, 0)$$, 'ck_cdt_definicion_monto_min');
SELECT assert_violates('cdt_definicion: tasa 0', $$SELECT pg_temp.nd('T0', 30, 0, 1)$$, 'ck_porcentaje_rango');
SELECT assert_violates('cdt_definicion: tasa 100.001', $$SELECT pg_temp.nd('T101', 30, 100.001, 1)$$, 'ck_porcentaje_rango');

SELECT assert_ok('cdt: CDT valido con fin = inicio + plazo',
                 $$SELECT pg_temp.ncdt('20000000-0000-4000-8000-000000000002','40000000-0000-4000-8000-000000000001', 500000, '2026-11-01', DATE '2026-11-01' + 90, 90)$$);
SELECT assert_violates('cdt: fecha_fin distinta de inicio + plazo',
                       $$SELECT pg_temp.ncdt('20000000-0000-4000-8000-000000000002', NULL, 500000, '2026-11-01', '2027-02-01', 90)$$, 'ck_cdt_fechas_coherentes');
SELECT assert_violates('cdt: monto 0', $$SELECT pg_temp.ncdt('20000000-0000-4000-8000-000000000002', NULL, 0, '2026-11-01', DATE '2026-11-01' + 90, 90)$$, 'ck_cdt_monto_positivo');
SELECT assert_violates('cdt: plazo 0', $$SELECT pg_temp.ncdt('20000000-0000-4000-8000-000000000002', NULL, 100, '2026-11-01', '2026-11-01', 0)$$, 'ck_cdt_plazo_positivo');
SELECT assert_violates('cdt: generado negativo', $$SELECT pg_temp.ncdt('20000000-0000-4000-8000-000000000002', NULL, 100, '2026-11-01', DATE '2026-11-01' + 90, 90, -1)$$, 'ck_cdt_generado_no_negativo');
SELECT assert_violates('cdt: ultimo_cobro anterior al inicio', $$SELECT pg_temp.ncdt('20000000-0000-4000-8000-000000000002', NULL, 100, '2026-11-01', DATE '2026-11-01' + 90, 90, 0, '2026-10-31')$$, 'ck_cdt_ultimo_cobro');
SELECT assert_violates('cdt: nombre en blanco', $$SELECT pg_temp.ncdt('20000000-0000-4000-8000-000000000002', NULL, 100, '2026-11-01', DATE '2026-11-01' + 90, 90, 0, NULL, ' ')$$, 'ck_cdt_nombre_no_vacio');
SELECT assert_violates('cdt: la cuenta debe existir', $$SELECT pg_temp.ncdt('99999999-9999-4999-8999-999999999999', NULL, 100, '2026-11-01', DATE '2026-11-01' + 90, 90)$$, 'fk_cdt_cuenta', '23503');
SELECT assert_violates('cdt: la definicion, si se indica, debe existir', $$SELECT pg_temp.ncdt('20000000-0000-4000-8000-000000000002', '99999999-9999-4999-8999-999999999999', 100, '2026-11-01', DATE '2026-11-01' + 90, 90)$$, 'fk_cdt_definicion', '23503');
SELECT assert_ok('cdt: puede existir sin definicion (definicion_id NULL)', $$SELECT pg_temp.ncdt('20000000-0000-4000-8000-000000000002', NULL, 100, '2026-11-01', DATE '2026-11-01' + 90, 90)$$);
SELECT assert_raises('cdt: estado fuera del enum', $$UPDATE public.cdt SET estado = 'VENCIDO'$$, NULL, '22P02');

-- ============================================================================
-- credito_producto, credito (indice unico parcial) y cuota (entidad debil)
-- ============================================================================
SELECT assert_ok('credito_producto: producto con tope absoluto, multiplicador y regla de edad',
                 $$SELECT pg_temp.np('Inmuebles', 14.1, 20000000, 2000000000, 1, 360, 2000000000, 100, true)$$);
SELECT assert_violates('credito_producto: nombre unico', $$SELECT pg_temp.np('Vehiculo', 10, 1, 2, 1, 12)$$, 'uq_credito_producto_nombre', '23505');
SELECT assert_violates('credito_producto: nombre en blanco', $$SELECT pg_temp.np(' ', 10, 1, 2, 1, 12)$$, 'ck_credito_producto_nombre_no_vacio');
SELECT assert_violates('credito_producto: monto minimo 0', $$SELECT pg_temp.np('A1', 10, 0, 2, 1, 12)$$, 'ck_credito_producto_montos');
SELECT assert_violates('credito_producto: monto minimo mayor que el maximo', $$SELECT pg_temp.np('A2', 10, 5, 2, 1, 12)$$, 'ck_credito_producto_montos');
SELECT assert_violates('credito_producto: plazo minimo 0', $$SELECT pg_temp.np('A3', 10, 1, 2, 0, 12)$$, 'ck_credito_producto_plazos');
SELECT assert_violates('credito_producto: plazo minimo mayor que el maximo', $$SELECT pg_temp.np('A4', 10, 1, 2, 13, 12)$$, 'ck_credito_producto_plazos');
SELECT assert_violates('credito_producto: tope absoluto 0', $$SELECT pg_temp.np('A5', 10, 1, 2, 1, 12, 0)$$, 'ck_credito_producto_tope');
SELECT assert_violates('credito_producto: multiplicador 0', $$SELECT pg_temp.np('A6', 10, 1, 2, 1, 12, NULL, 0)$$, 'ck_credito_producto_multiplicador');
SELECT assert_violates('credito_producto: tasa 101', $$SELECT pg_temp.np('A7', 101, 1, 2, 1, 12)$$, 'ck_porcentaje_rango');

SELECT assert_violates('credito: segundo credito ACTIVO del mismo producto en la misma cuenta',
                       $$SELECT pg_temp.nk('20000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000001', 1000000, 1000000)$$,
                       'uq_credito_vivo_por_producto', '23505');
SELECT assert_ok('credito: un credito ACTIVO de OTRO producto en la misma cuenta si',
                 $$SELECT pg_temp.nk('20000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000002', 60000000, 60000000)$$);
SELECT assert_ok('credito: el mismo producto en OTRA cuenta si',
                 $$SELECT pg_temp.nk('20000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000001', 1000000, 1000000)$$);
SELECT assert_ok('credito: dos creditos PAGADOS del mismo producto conviven con el ACTIVO',
                 $$SELECT pg_temp.nk('20000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000001', 1000, 0, 'PAGADO'),
                          pg_temp.nk('20000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000001', 2000, 0, 'PAGADO')$$);
SELECT assert_violates('credito: capital pendiente mayor que el monto', $$SELECT pg_temp.nk('20000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000002', 1000, 2000)$$, 'ck_credito_capital_rango');
SELECT assert_violates('credito: capital pendiente negativo', $$SELECT pg_temp.nk('20000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000002', 1000, -1)$$, 'ck_credito_capital_rango');
SELECT assert_violates('credito: PAGADO con deuda pendiente', $$SELECT pg_temp.nk('20000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000002', 1000, 100, 'PAGADO')$$, 'ck_credito_pagado_sin_deuda');
SELECT assert_violates('credito: monto 0', $$SELECT pg_temp.nk('20000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000002', 0, 0)$$, 'ck_credito_monto_positivo');
SELECT assert_violates('credito: plazo 0', $$SELECT pg_temp.nk('20000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000002', 1000, 1000, 'ACTIVO', 0)$$, 'ck_credito_plazo_positivo');
SELECT assert_violates('credito: mora negativa',
                       $$INSERT INTO public.credito (cuenta_id, producto_id, monto, tasa_anual, plazo_meses, fecha_desembolso, capital_pendiente, mora_acumulada, fecha_interes)
                         VALUES ('20000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000002', 1000, 20, 12, '2026-11-21', 1000, -1, '2026-11-21')$$,
                       'ck_credito_mora_no_negativa');
SELECT assert_violates('credito: el producto debe existir', $$SELECT pg_temp.nk('20000000-0000-4000-8000-000000000002','99999999-9999-4999-8999-999999999999', 1000, 1000)$$, 'fk_credito_producto', '23503');
SELECT assert_violates('credito: la cuenta debe existir', $$SELECT pg_temp.nk('99999999-9999-4999-8999-999999999999','60000000-0000-4000-8000-000000000002', 1000, 1000)$$, 'fk_credito_cuenta', '23503');

SELECT assert_ok('cuota: cuota valida (capital + interes = valor)', $$SELECT pg_temp.nq('70000000-0000-4000-8000-000000000001', 2, 300000, 210000, 90000)$$);
SELECT assert_ok('cuota: cuota pagada con fecha de pago', $$SELECT pg_temp.nq('70000000-0000-4000-8000-000000000001', 3, 300000, 220000, 80000, true, '2026-12-21')$$);
SELECT assert_violates('cuota: (credito_id, numero) unico (clave real de la entidad debil)', $$SELECT pg_temp.nq('70000000-0000-4000-8000-000000000001', 1, 300000, 200000, 100000)$$, 'uq_cuota_credito_numero', '23505');
SELECT assert_violates('cuota: numero 0', $$SELECT pg_temp.nq('70000000-0000-4000-8000-000000000001', 0, 300000, 200000, 100000)$$, 'ck_cuota_numero_positivo');
SELECT assert_violates('cuota: valor 0', $$SELECT pg_temp.nq('70000000-0000-4000-8000-000000000001', 4, 0, 0, 0)$$, 'ck_cuota_valores_positivos');
SELECT assert_violates('cuota: capital + interes distinto del valor', $$SELECT pg_temp.nq('70000000-0000-4000-8000-000000000001', 5, 100, 60, 30)$$, 'ck_cuota_desglose');
SELECT assert_violates('cuota: capital programado negativo', $$SELECT pg_temp.nq('70000000-0000-4000-8000-000000000001', 6, 100, 110, -10)$$, 'ck_cuota_desglose');
SELECT assert_violates('cuota: pagada sin fecha de pago', $$SELECT pg_temp.nq('70000000-0000-4000-8000-000000000001', 7, 100, 60, 40, true, NULL)$$, 'ck_cuota_pagada_con_fecha');
SELECT assert_violates('cuota: fecha de pago sin estar pagada', $$SELECT pg_temp.nq('70000000-0000-4000-8000-000000000001', 8, 100, 60, 40, false, '2026-12-21')$$, 'ck_cuota_pagada_con_fecha');
SELECT assert_violates('cuota: pagos negativos',
                       $$INSERT INTO public.cuota (credito_id, numero, fecha_vencimiento, valor_cuota_original, valor_cuota, capital_programado, interes_programado, capital_pagado)
                         VALUES ('70000000-0000-4000-8000-000000000001', 9, '2026-12-21', 100, 100, 60, 40, -1)$$, 'ck_cuota_pagos_no_negativos');
SELECT assert_violates('cuota: el credito debe existir', $$SELECT pg_temp.nq('99999999-9999-4999-8999-999999999999', 1, 100, 60, 40)$$, 'fk_cuota_credito', '23503');

-- ============================================================================
-- reloj, parametro (filas unicas) y audit.evento
-- ============================================================================
SELECT assert_eq('reloj: una sola fila, modo real, sin fecha manual',
                 (SELECT (count(*), bool_and(id = 1), bool_and(usar_fecha_real), bool_and(fecha_sistema IS NULL))::text FROM public.reloj), '(1,t,t,t)'::text);
SELECT assert_violates('reloj: no admite una segunda fila (id <> 1)', $$INSERT INTO public.reloj (id) VALUES (2)$$, 'ck_reloj_fila_unica');
SELECT assert_violates('reloj: no admite repetir el id 1', $$INSERT INTO public.reloj (id) VALUES (1)$$, 'pk_reloj', '23505');
SELECT assert_violates('reloj: modo manual exige fecha_sistema', $$UPDATE public.reloj SET usar_fecha_real = false$$, 'ck_reloj_fecha_si_manual');
SELECT assert_ok('reloj: modo manual con fecha es valido', $$UPDATE public.reloj SET usar_fecha_real = false, fecha_sistema = '2027-01-01'$$);

SELECT assert_eq('parametro: una sola fila con los valores del spec y sin tasa de mora',
                 (SELECT (count(*), max(tasa_bolsillo_anual), max(bono_referido), max(edad_limite_inmuebles), max(ingresos_simulados_cantidad),
                          max(ingreso_simulado_min), max(ingreso_simulado_max), max(monto_maximo), count(tasa_mora_anual))::text FROM public.parametro),
                 '(1,12.000,50000.00,70,5,10000.00,1000000.00,9999999999999.99,0)'::text);
SELECT assert_violates('parametro: no admite una segunda fila', $$INSERT INTO public.parametro (id) VALUES (2)$$, 'ck_parametro_fila_unica');
SELECT assert_violates('parametro: no admite repetir el id 1', $$INSERT INTO public.parametro (id) VALUES (1)$$, 'pk_parametro', '23505');
SELECT assert_ok('parametro: tasa de mora valida', $$UPDATE public.parametro SET tasa_mora_anual = 30$$);
SELECT assert_violates('parametro: tasa de mora 0', $$UPDATE public.parametro SET tasa_mora_anual = 0$$, 'ck_porcentaje_rango');
SELECT assert_violates('parametro: tasa de mora 100.001', $$UPDATE public.parametro SET tasa_mora_anual = 100.001$$, 'ck_porcentaje_rango');
SELECT assert_violates('parametro: bono 0', $$UPDATE public.parametro SET bono_referido = 0$$, 'ck_parametro_valores_positivos');
SELECT assert_violates('parametro: ingreso simulado minimo mayor que el maximo', $$UPDATE public.parametro SET ingreso_simulado_min = 2000000$$, 'ck_parametro_rango_simulado');
SELECT assert_violates('parametro: monto maximo fuera del dominio dinero', $$UPDATE public.parametro SET monto_maximo = 10000000000000$$, 'ck_dinero_rango');

SELECT assert_ok('audit.evento: evento con actor que NO existe en usuario (sin FK)',
                 $$INSERT INTO audit.evento (actor_id, actor_username, accion, entidad, entidad_id, antes, despues)
                   VALUES ('99999999-9999-4999-8999-999999999999', 'fantasma1', 'USUARIO_BLOQUEADO', 'usuario', '123', '{"estado":"ACTIVO"}', '{"estado":"BLOQUEADO"}')$$);
SELECT assert_ok('audit.evento: evento del sistema (sin actor)', $$INSERT INTO audit.evento (accion) VALUES ('RELOJ_AJUSTADO')$$);
SELECT assert_violates('audit.evento: accion en blanco', $$INSERT INTO audit.evento (accion) VALUES ('   ')$$, 'ck_evento_accion_no_vacia');
SELECT assert_true('audit.evento: orden es creciente',
                   (SELECT bool_and(orden > anterior) FROM (SELECT orden, lag(orden) OVER (ORDER BY orden) AS anterior FROM audit.evento) x WHERE anterior IS NOT NULL));
SELECT assert_raises('audit.evento: orden no se puede fijar a mano (GENERATED ALWAYS)', $$INSERT INTO audit.evento (orden, accion) VALUES (1, 'X')$$, NULL, '428C9');

ROLLBACK;
