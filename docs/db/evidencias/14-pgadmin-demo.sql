-- Demostracion de E14 (seed y respaldo) para pgAdmin: conexion "Banco - administracion (postgres)", base banco YA SEMBRADA (db\ctl.cmd seed).
-- TODO va en BEGIN ... ROLLBACK: no cambia nada (ni el reloj). Los resultados salen como NOTICE (pestana Messages).
-- Para sembrar: db\ctl.cmd reset -Yes ; db\ctl.cmd apply ; db\ctl.cmd seed.  Para respaldar/restaurar: ver docs\db\runbook-demo.md.
BEGIN;
DO $demo$
DECLARE
  jp uuid := (SELECT id FROM public.usuario WHERE username = 'jperez483');
  ad uuid := (SELECT id FROM public.usuario WHERE username = 'admin1');
  bl uuid := (SELECT id FROM public.usuario WHERE username = 'bloqueado1');
  r jsonb; m0 numeric; m1 numeric;
BEGIN
  RAISE NOTICE '1) usuarios del seed: % (1 ADMIN sin cuenta, 11 clientes, 1 bloqueado)', (SELECT string_agg(username || CASE WHEN estado = 'BLOQUEADO' THEN ' [BLOQUEADO]' WHEN rol = 'ADMIN' THEN ' [ADMIN]' ELSE '' END, ', ' ORDER BY username) FROM public.usuario);
  RAISE NOTICE '2) identidades fijas del contrato: jperez483 = cuenta %, cgomez12 = cuenta %, codigo de referido de jperez483 = %',
               (SELECT c.numero_cuenta FROM public.cuenta c WHERE c.usuario_id = jp), (SELECT c.numero_cuenta FROM public.cuenta c JOIN public.usuario u ON u.id = c.usuario_id WHERE u.username = 'cgomez12'),
               (SELECT codigo_referido FROM public.usuario WHERE id = jp);
  RAISE NOTICE '3) estado del reloj (modo REAL, sin movimientos en el futuro): %', (SELECT to_jsonb(v) - 'ahora_banco' FROM public.v_reloj_estado v);
  RAISE NOTICE '4) integridad global: ok = %, defensas caidas = %, cuentas = %, patas = %', (SELECT ok FROM public.v_integridad_global), (SELECT defensas_fallidas FROM public.v_integridad_global), (SELECT cuentas FROM public.v_integridad_global), (SELECT patas FROM public.v_integridad_global);
  RAISE NOTICE '5) lo que ve jperez483 (vista_dashboard sin transacciones): %', public.vista_dashboard(jp) - 'transacciones';
  RAISE NOTICE '6) bolsillos y total (vista_balance): %', public.vista_balance(jp);
  RAISE NOTICE '7) CDT (uno ACTIVO y uno cerrado): %', public.vista_cdts(jp);
  RAISE NOTICE '8) creditos: Libre inversion al dia y Vehiculo CON MORA: %', public.vista_creditos(jp);
  RAISE NOTICE '9) ultimos 5 movimientos: %', (SELECT jsonb_agg(jsonb_build_object('tipo', e ->> 'tipo', 'detalle', e ->> 'tipo_detalle', 'monto', e -> 'monto', 'contraparte', e ->> 'contraparte', 'nota', e ->> 'nota')) FROM jsonb_array_elements(public.vista_historial(jp, 5)) e);
  BEGIN
    PERFORM public.validar_sesion(bl);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '10) bloqueado1 -> "%" (mensaje exacto del contrato)', SQLERRM;
  END;
  RAISE NOTICE '11) la clave de TODOS es Banco2026: el hash bcrypt de jperez483 empieza con % (cost 10)', left((SELECT password_hash FROM public.usuario WHERE id = jp), 7);

  -- un adelanto de +60 dias DENTRO de la transaccion: crece la mora del Vehiculo y el CDT activo vence; se revierte al final
  m0 := (SELECT (e ->> 'mora_acumulada')::numeric FROM jsonb_array_elements(public.vista_creditos(jp)) e WHERE e ->> 'producto' = 'Vehículo');
  PERFORM public.admin_set_reloj(ad, false, (public.hoy_banco() + 60)::text);
  m1 := (SELECT (e ->> 'mora_acumulada')::numeric FROM jsonb_array_elements(public.vista_creditos(jp)) e WHERE e ->> 'producto' = 'Vehículo');
  RAISE NOTICE '12) con el reloj +60 dias: mora del Vehiculo de % a %; CDT: %', m0, m1, (SELECT jsonb_agg(e ->> 'tiempo_restante') FROM jsonb_array_elements(public.vista_cdts(jp)) e);
  RAISE NOTICE '    (todo esto se revierte con el ROLLBACK: el reloj vuelve a modo real)';
END
$demo$;
ROLLBACK;

-- Consultas sueltas (solo lectura):
--   SELECT * FROM public.v_reloj_estado;
--   SELECT username, rol, estado FROM public.usuario ORDER BY rol, username;
--   SELECT nombre, plazo_dias, tasa_anual, monto_min FROM public.cdt_definicion ORDER BY plazo_dias;
--   SELECT nombre, tasa_anual, monto_min, monto_max, plazo_max_meses FROM public.credito_producto ORDER BY nombre;
--   SELECT to_regnamespace('seed') IS NULL AS esquema_seed_eliminado;
