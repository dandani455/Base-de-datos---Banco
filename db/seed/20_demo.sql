-- ============================================================================
-- 20_demo.sql - Etapa 14 - Seed de DEMOSTRACION (datos FICTICIOS; clave de todos: Banco2026; NO es para produccion, D-E14-D2)
--
-- Todo se crea con las funciones REALES del banco (registrar_usuario, hacer_transferencia, crear_cdt, solicitar_credito, admin_*...),
-- moviendo el reloj con admin_set_reloj desde R-120 hasta R-4 (R = hoy real al empezar) y volviendo al modo REAL.
-- La historia es UNA sola transaccion: si algo falla no queda NADA (ni usuarios ni reloj movido). Reproducible: setseed fija los random().
-- Solo corre sobre un banco VACIO. Requiere el catalogo (00_catalogo.sql) y las funciones solo-seed (10_funciones_seed.sql).
-- Despues: CALL sp_avanzar_todos() (E13) pone al dia lo GUARDADO y se elimina el esquema seed.
-- La mora (30 %) es un valor SOLO del seed (D-E14-D3, provisional del equipo).
-- ============================================================================
SELECT setseed(0.2026);

DO $guarda$
BEGIN
  PERFORM seed.exigir_banco_sin_operaciones();
  IF EXISTS (SELECT 1 FROM public.usuario) THEN
    RAISE EXCEPTION 'El seed solo corre sobre un banco vacio (ya hay usuarios)';
  END IF;
  IF (SELECT count(*) FROM public.cdt_definicion) < 3 OR (SELECT count(*) FROM public.credito_producto) < 4 THEN
    RAISE EXCEPTION 'Cargue primero el catalogo (ctl seed catalogo)';
  END IF;
END
$guarda$;

DO $demo$
DECLARE
  ad uuid; jp uuid; cg uuid; bl uuid; am uuid; lo uuid; sg uuid; fa uuid; pv uuid; vc uuid; sh uuid; dt uuid;
  v_cod_jp constant text := '8f3c2a10-5b7e-4d3a-9c21-6a7b1d0e42f9';
  v_viajes text; v_emerg text; v_ahorro text; v_libre text; v_vehiculo text;
  c90 text; c180 text; p_libre text; p_vehiculo text;
BEGIN
  SELECT id::text INTO c90  FROM public.cdt_definicion WHERE nombre = 'CDT 90 días';
  SELECT id::text INTO c180 FROM public.cdt_definicion WHERE nombre = 'CDT 180 días';
  SELECT id::text INTO p_libre    FROM public.credito_producto WHERE nombre = 'Libre inversión';
  SELECT id::text INTO p_vehiculo FROM public.credito_producto WHERE nombre = 'Vehículo';

  -- ---- R-120: el administrador, la mora y los clientes (el banco esta vacio: el reloj puede ir al pasado) ----
  ad := seed.crear_admin('admin1', 'Administración', 'Banco', '900100200', 'admin@bancodigital.co', '3100000000', DATE '1985-03-12');
  PERFORM public.admin_set_tasa_mora(ad, '30');
  PERFORM seed.dia(-120);
  jp := seed.cliente('Juan',          'Pérez Gutiérrez', '1020304050', 'juan.perez@correo.co',        '3001234567', '1990-05-17', 'jperez483',   '4001002003', v_cod_jp::uuid);
  cg := seed.cliente('Camila',        'Rodríguez Peña',  '1012345678', 'camila.rodriguez@correo.co',  '3209876543', '1993-08-02', 'cgomez12',    '4003004005', 'c4000000-0000-4000-8000-000000000004');
  bl := seed.cliente('Mateo',         'Ríos Salazar',    '1098765432', 'mateo.rios@correo.co',        '3157654321', '1988-11-30', 'bloqueado1',  '4005006007', 'b1000000-0000-4000-8000-000000000003');
  am := seed.cliente('Andrés Felipe', 'Mora Cifuentes',  '1030405060', 'andres.mora@correo.co',       '3112223344', '1991-02-14', 'amora271',    '4007008009');
  lo := seed.cliente('Laura Valentina', 'Ospina Duque',  '1040506070', 'laura.ospina@correo.co',      '3123334455', '1995-07-09', 'lospina604',  '4008009001');
  sg := seed.cliente('Santiago',      'Gómez Ruiz',      '1050607080', 'santiago.gomez@correo.co',    '3134445566', '1989-12-21', 'sgomez118',   '4001112223');
  fa := seed.cliente('Felipe',        'Arango Duarte',   '1060708090', 'felipe.arango@correo.co',     '3145556677', '1986-04-03', 'farango352',  '4002223334');
  pv := seed.cliente('Paula Andrea',  'Vargas Londoño',  '1070809010', 'paula.vargas@correo.co',      '3156667788', '1994-09-27', 'pvargas907',  '4003334445');
  vc := seed.cliente('Valentina',     'Castaño Mejía',   '1080901020', 'valentina.castano@correo.co', '3167778899', '1997-01-18', 'vcastano445', '4004445556');
  sh := seed.cliente('Sebastián',     'Herrera Cano',    '1091012030', 'sebastian.herrera@correo.co', '3178889900', '1992-06-11', 'sherrera630', '4005556667');

  -- ---- R-119: una clienta referida por jperez483 (el bono de $50.000 lo paga verificar_correo) ----
  PERFORM seed.dia(-119);
  dt := seed.cliente('Daniela',       'Torres Ruiz',     '1101123040', 'daniela.torres@correo.co',    '3189990011', '1998-03-25', 'dtorres219',  '4006667778', NULL, v_cod_jp);

  -- ---- R-118: el banco envia saldo de bienvenida (admin_ajustar_balance) ----
  PERFORM seed.dia(-118);
  PERFORM public.admin_ajustar_balance(ad, 'jperez483',   5000000, 'El banco ha enviado un bono de bienvenida');
  PERFORM public.admin_ajustar_balance(ad, 'cgomez12',    1500000, 'El banco ha enviado un bono de bienvenida');
  PERFORM public.admin_ajustar_balance(ad, 'bloqueado1',  1000000, 'El banco ha enviado un bono de bienvenida');
  PERFORM public.admin_ajustar_balance(ad, 'amora271',    1000000, 'El banco ha enviado un bono de bienvenida');
  PERFORM public.admin_ajustar_balance(ad, 'lospina604',  1000000, 'El banco ha enviado un bono de bienvenida');
  PERFORM public.admin_ajustar_balance(ad, 'sgomez118',   1000000, 'El banco ha enviado un bono de bienvenida');
  PERFORM public.admin_ajustar_balance(ad, 'farango352',  1000000, 'El banco ha enviado un bono de bienvenida');
  PERFORM public.admin_ajustar_balance(ad, 'pvargas907',  1000000, 'El banco ha enviado un bono de bienvenida');
  PERFORM public.admin_ajustar_balance(ad, 'vcastano445', 1000000, 'El banco ha enviado un bono de bienvenida');
  PERFORM public.admin_ajustar_balance(ad, 'sherrera630', 1000000, 'El banco ha enviado un bono de bienvenida');

  -- ---- bolsillos de jperez483 ----
  PERFORM seed.dia(-116); v_viajes := public.crear_bolsillo(jp, 'Viajes') ->> 'id';
  PERFORM seed.dia(-115); PERFORM public.mover_a_bolsillo(jp, v_viajes, 800000);
  PERFORM seed.dia(-114); v_emerg := public.crear_bolsillo(jp, 'Emergencias') ->> 'id';
  PERFORM seed.dia(-113); PERFORM public.mover_a_bolsillo(jp, v_emerg, 1500000);

  -- ---- envios, recibos y productos (en orden de fecha) ----
  PERFORM seed.dia(-112); PERFORM public.hacer_transferencia(jp, '4003334445', 180000, 'Taller de cerámica', NULL);
  PERFORM seed.dia(-110); PERFORM public.crear_cdt(jp, c90, 1000000);                                  -- CDT cerrado: vence el R-20
  PERFORM seed.dia(-108); PERFORM public.hacer_transferencia(fa, '4001002003', 320000, 'Pago de la camioneta', NULL);
  PERFORM seed.dia(-106); PERFORM public.hacer_transferencia(jp, '4007008009',  45000, 'Onces', NULL);
  PERFORM seed.dia(-104); PERFORM public.hacer_transferencia(jp, '4008009001',  95000, 'Almuerzo del domingo', NULL);
  PERFORM seed.dia(-100); PERFORM public.hacer_transferencia(cg, '4001002003', 150000, 'Mi parte del arriendo', NULL);
  v_ahorro := public.crear_bolsillo(cg, 'Ahorro') ->> 'id';
  PERFORM public.mover_a_bolsillo(cg, v_ahorro, 300000);
  PERFORM seed.dia(-96);  PERFORM public.hacer_transferencia(jp, '4001112223', 450000, 'Préstamo para el trasteo', NULL);
  PERFORM seed.dia(-92);  PERFORM public.hacer_transferencia(am, '4001002003',  60000, 'Entradas al cine', NULL);
  PERFORM seed.dia(-90);  v_libre := public.solicitar_credito(jp, p_libre, 6000000, 24) ->> 'id';       -- al dia: descuento automatico
  PERFORM public.activar_descuento_automatico(jp, v_libre, true);
  PERFORM public.hacer_transferencia(cg, '4005006007', 120000, 'Para el mercado', NULL);
  PERFORM seed.dia(-86);  PERFORM public.hacer_transferencia(jp, '4003004005', 210000, 'Regalo de cumpleaños', NULL);
  PERFORM seed.dia(-80);  PERFORM public.hacer_transferencia(sg, '4001002003', 450000, 'Devolución del préstamo', NULL);
  PERFORM seed.dia(-76);  PERFORM public.hacer_transferencia(pv, '4001002003',  85000, 'Reembolso del taller', NULL);
  PERFORM seed.dia(-75);  v_vehiculo := public.solicitar_credito(jp, p_vehiculo, 50000000, 48) ->> 'id'; -- SIN descuento automatico: cuotas vencidas y mora
  PERFORM seed.dia(-70);  PERFORM public.hacer_transferencia(jp, '4007008009', 130000, 'Mercado', NULL);
  PERFORM seed.dia(-64);  PERFORM public.hacer_transferencia(vc, '4001002003', 275000, 'Pago de servicios', NULL);
  PERFORM seed.dia(-60);  PERFORM public.retirar_de_bolsillo(jp, v_viajes, 100000);
  PERFORM public.hacer_transferencia(bl, '4001112223', 50000, 'Gracias por todo', NULL);
  PERFORM seed.dia(-58);  PERFORM public.hacer_transferencia(jp, '4005556667',  88000, 'Domicilio', NULL);
  PERFORM seed.dia(-50);  PERFORM public.hacer_transferencia(lo, '4001002003', 400000, 'Cuota del apartamento', NULL);
  PERFORM seed.dia(-42);  PERFORM public.hacer_transferencia(jp, '4002223334', 160000, 'Pasajes', NULL);
  PERFORM seed.dia(-36);  PERFORM public.hacer_transferencia(cg, '4001002003', 120000, 'Paseo a Villa de Leyva', NULL);
  PERFORM seed.dia(-30);  PERFORM public.crear_cdt(jp, c180, 2000000);                                 -- CDT activo
  PERFORM seed.dia(-26);  PERFORM public.hacer_transferencia(jp, '4001112223', 120000, 'Gasolina', NULL);
  PERFORM seed.dia(-22);  PERFORM public.hacer_transferencia(jp, '4003334445',  54000, 'Mercado', NULL);
  PERFORM seed.dia(-14);  PERFORM public.hacer_transferencia(sh, '4001002003', 190000, 'Venta de la bicicleta', NULL);
  PERFORM seed.dia(-10);  PERFORM public.admin_bloquear(ad, bl::text);
  PERFORM seed.dia(-8);   PERFORM public.hacer_transferencia(jp, '4008009001',  72000, 'Cumpleaños de Laura', NULL);
  PERFORM seed.dia(-4);   PERFORM public.hacer_transferencia(am, '4001002003', 110000, 'Para el almuerzo', NULL);

  -- ---- vuelta al modo REAL: el hoy del banco es el de verdad y no hay patas en el futuro ----
  PERFORM seed.volver_a_real();
END
$demo$;

-- Estado GUARDADO al dia (el visor Control y pgAdmin lo muestran): una transaccion por cuenta, en autocommit
CALL public.sp_avanzar_todos();

-- Resumen de verificacion
SELECT g.ok AS integridad_ok, g.defensas_fallidas, g.cuentas, g.grupos, g.patas,
       (SELECT usar_fecha_real FROM public.reloj) AS reloj_real,
       (SELECT count(*) FROM public.usuario) AS usuarios,
       (SELECT count(*) FROM public.cdt WHERE estado = 'ACTIVO') AS cdt_activos,
       (SELECT count(*) FROM public.cdt WHERE estado = 'CERRADO') AS cdt_cerrados,
       (SELECT count(*) FROM public.credito) AS creditos
FROM public.v_integridad_global g;

DROP SCHEMA IF EXISTS seed CASCADE;
