-- 03_schema.test.sql · Etapa 1 · inventario del esquema, documentacion, dominios y enumerados.
-- Corre como superusuario en banco_test despues de aplicar db/sql/01..05. No inserta datos.
-- (Las restricciones por tabla estan en 04, el libro mayor en 05, los borrados en 06, indices en 07,
--  permisos en 08 e idempotencia en 09.)

-- ============================================================================
-- 1. Inventario: exactamente 11 tablas en public y audit.evento en audit
-- ============================================================================
SELECT assert_eq('public tiene EXACTAMENTE estas 11 tablas',
                 (SELECT array_agg(tablename::text ORDER BY tablename) FROM pg_tables WHERE schemaname = 'public'),
                 ARRAY['bolsillo','cdt','cdt_definicion','credito','credito_producto','cuenta','cuota',
                       'parametro','reloj','transaccion','usuario']::text[]);
SELECT assert_eq('public tiene 11 tablas (conteo)', (SELECT count(*) FROM pg_tables WHERE schemaname = 'public'), 11::bigint);
SELECT assert_eq('audit tiene SOLO la tabla evento',
                 (SELECT array_agg(tablename::text ORDER BY tablename) FROM pg_tables WHERE schemaname = 'audit'),
                 ARRAY['evento']::text[]);
-- E1 comprobaba que NO habia funciones ni triggers (solo estructura). Desde E2 hay EXACTAMENTE estos (y ninguno de negocio:
-- las funciones de negocio son de E4+). El detalle de cada uno esta en 10_libro_triggers.
SELECT assert_eq('en public hay EXACTAMENTE las 131 funciones del libro mayor (E2), del reloj (E3), de autenticacion y registro (E4: 5 publicas + 13 internas), de transferencias (E5: 2 publicas + 3 internas), de bolsillos (E6: 5 publicas + 4 internas) del motor de devengo y CDT (E7: 4 publicas + 9 internas) de creditos (E8: 5 publicas + 11 internas) de pagos (E9: 3 publicas + 11 internas + 1 trigger) de vistas (E10: 2 publicas + 2 internas) de administracion (E11: 12 publicas + 4 internas) del visor Control (E12: 2 publicas + 1 interna) y de mantenimiento (E13: 2 PROCEDIMIENTOS + 1 interna)',
                 (SELECT array_agg(p.proname::text ORDER BY p.proname COLLATE "C") FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname = 'public' AND p.prokind IN ('f','p')
                     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')),
                 ARRAY['_ahora_de','_ahora_real','_asentar_grupo','_auditar_admin','_avanzar_hasta','_bloquear_cuentas','_bolsillo_propio','_cliente_objetivo','_cobrar_creditos','_credito_propio','_cuota_vencida','_definicion_cdt','_devengar_bolsillos','_devengar_cdts','_dias_mora','_dias_por_cobrar',
                       '_edad_en','_es_hash_bcrypt','_factor_interes','_fecha_vencimiento','_hoy_de','_inicio_periodo','_interes_corriendo','_json_transacciones','_limites_credito','_mora_cuota','_mora_de_cuota','_mora_pendiente','_mover_bolsillo','_msg_auth','_msg_negocio','_nombre_valido','_norm_cedula',
                       '_norm_digitos','_norm_telefono','_norm_texto','_pagar_bono_referido','_pagar_cuota_interna','_parse_tasa','_patrimonio_neto','_plan_cuotas','_plan_restante','_plantillas_validas','_producto_credito','_proxima_cuota','_reglas_admin','_reglas_bolsillo','_reglas_cdt','_reglas_control','_reglas_credito','_reglas_historial','_reglas_mantenimiento','_reglas_pago',
                       '_reglas_registro','_reglas_transferencia','_reloj_actualizar','_reloj_instantanea','_reloj_vista','_tasa_mensual','_texto_tiempo_restante','_username_base','_validar_admin','_validar_cliente',
                       '_validar_monto','_validar_plazo','_verificar_credito','abonar_credito','activar_descuento_automatico','admin_ajustar_balance','admin_bloquear','admin_borrar_usuario','admin_desbloquear','admin_detalle_usuario','admin_esquema','admin_get_reloj','admin_get_tasas','admin_listar_usuarios','admin_set_reloj','admin_set_tasa_cdt','admin_set_tasa_credito','admin_set_tasa_mora','admin_tabla','ahora_banco','balance_total','crear_bolsillo','crear_cdt','ct_cdt_inversion','ct_credito_plan','ct_transaccion_cuadre','hacer_transferencia',
                       'hoy_banco','listar_cdt_definiciones','mover_a_bolsillo','mover_entre_bolsillos','nombre_destinatario','obtener_credenciales','pagar_cuota','productos_disponibles','productos_publicos','registrar_usuario',
                       'retirar_de_bolsillo','simular_cdt','simular_credito','solicitar_credito','sp_avanzar_todos','sp_verificar_integridad','trg_cobro_hasta_monotono','trg_cuenta_auditar_borrado','trg_evento_ddl','trg_evento_drop','trg_reloj_a_validar','trg_reloj_auditar','trg_reloj_borrar',
                       'trg_reloj_truncate','trg_transaccion_a_validar','trg_transaccion_b_aplicar','trg_transaccion_inmutable','trg_transaccion_truncate','trg_ultimo_cobro_monotono','trg_zz_proteger_bolsillo','trg_zz_proteger_cdt',
                       'trg_zz_proteger_credito','trg_zz_proteger_cuenta','validar_sesion','verificar_correo','vista_balance','vista_cdts','vista_creditos','vista_dashboard','vista_historial','vista_perfil']::text[]);
SELECT assert_eq('hay EXACTAMENTE 21 triggers de usuario (12 del libro mayor y sus guardias, 4 del reloj, 2 de la guardia monotonica de ultimo_cobro de E7, 2 de ct_credito_plan de E8, 1 de la guardia de cobro_hasta de E9)',
                 (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname IN ('public','audit') AND NOT t.tgisinternal), 21::bigint);
SELECT assert_eq('las unicas vistas de public son las 7 v_integridad_* (incluida v_integridad_auth, E4, y v_integridad_creditos, E8), v_reloj_estado y v_transaccion_usuario (E10)',
                 (SELECT array_agg(c.relname::text ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname = 'public' AND c.relkind = 'v'),
                 ARRAY['v_integridad_auth','v_integridad_creditos','v_integridad_defensas','v_integridad_global','v_integridad_grupos','v_integridad_saldos','v_integridad_usuario','v_reloj_estado','v_transaccion_usuario']::text[]);
SELECT assert_eq('todas las tablas, esquemas, tipos y dominios son de banco_owner',
                 (SELECT count(*) FROM (
                    SELECT pg_get_userbyid(c.relowner) AS o FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                     WHERE n.nspname IN ('public','audit') AND c.relkind IN ('r','S','i')
                    UNION ALL SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'audit'
                    UNION ALL SELECT pg_get_userbyid(typowner) FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typtype IN ('d','e')
                  ) x WHERE o <> 'banco_owner'), 0::bigint);
SELECT assert_eq('toda tabla y toda columna tiene COMMENT (diccionario en la propia BD)',
                 (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                   WHERE n.nspname IN ('public','audit') AND c.relkind = 'r'
                     AND (obj_description(c.oid, 'pg_class') IS NULL OR col_description(c.oid, a.attnum) IS NULL)), 0::bigint);
SELECT assert_eq('audit.evento no tiene ninguna FK (ni hacia ni desde ella)',
                 (SELECT count(*) FROM pg_constraint WHERE contype = 'f'
                     AND (conrelid = 'audit.evento'::regclass OR confrelid = 'audit.evento'::regclass)), 0::bigint);
SELECT assert_eq('ninguna tabla de public referencia al esquema audit',
                 (SELECT count(*) FROM pg_constraint c JOIN pg_class r ON r.oid = c.confrelid JOIN pg_namespace n ON n.oid = r.relnamespace
                   WHERE c.contype = 'f' AND n.nspname = 'audit'), 0::bigint);

-- ============================================================================
-- 2. Dominios y enumerados
-- ============================================================================
SELECT assert_ok('dinero acepta el maximo 9999999999999.99 y el minimo negativo equivalente',
                 'SELECT 9999999999999.99::public.dinero, (-9999999999999.99)::public.dinero');
SELECT assert_violates('dinero rechaza 10^13', 'SELECT 10000000000000::numeric(18,2)::public.dinero', 'ck_dinero_rango', '23514');
SELECT assert_violates('dinero rechaza -10^13', 'SELECT (-10000000000000)::numeric(18,2)::public.dinero', 'ck_dinero_rango', '23514');
SELECT assert_eq('dinero conserva los 2 decimales', (12345.678::public.dinero)::numeric, 12345.68::numeric);
SELECT assert_ok('porcentaje acepta 0.001, 12, 13.5 y 100', 'SELECT 0.001::public.porcentaje, 12::public.porcentaje, 13.5::public.porcentaje, 100::public.porcentaje');
SELECT assert_violates('porcentaje rechaza 0', 'SELECT 0::public.porcentaje', 'ck_porcentaje_rango', '23514');
SELECT assert_violates('porcentaje rechaza 100.001', 'SELECT 100.001::public.porcentaje', 'ck_porcentaje_rango', '23514');
SELECT assert_violates('porcentaje rechaza negativos', 'SELECT (-1)::public.porcentaje', 'ck_porcentaje_rango', '23514');

SELECT assert_eq('enum rol_usuario', (SELECT array_agg(enumlabel::text ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = 'public.rol_usuario'::regtype), ARRAY['CLIENTE','ADMIN']::text[]);
SELECT assert_eq('enum estado_usuario', (SELECT array_agg(enumlabel::text ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = 'public.estado_usuario'::regtype), ARRAY['ACTIVO','BLOQUEADO']::text[]);
SELECT assert_eq('enum estado_cdt', (SELECT array_agg(enumlabel::text ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = 'public.estado_cdt'::regtype), ARRAY['ACTIVO','CERRADO']::text[]);
SELECT assert_eq('enum estado_credito', (SELECT array_agg(enumlabel::text ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = 'public.estado_credito'::regtype), ARRAY['ACTIVO','PAGADO']::text[]);
SELECT assert_eq('enum contenedor_contable', (SELECT array_agg(enumlabel::text ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = 'public.contenedor_contable'::regtype), ARRAY['CUENTA','BOLSILLO','CDT','CREDITO','RESULTADO']::text[]);
SELECT assert_eq('enum sentido_asiento', (SELECT array_agg(enumlabel::text ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = 'public.sentido_asiento'::regtype), ARRAY['E','S']::text[]);
SELECT assert_eq('enum tipo_transaccion tiene los 17 tipos del contrato',
                 (SELECT array_agg(enumlabel::text ORDER BY enumlabel COLLATE "C") FROM pg_enum WHERE enumtypid = 'public.tipo_transaccion'::regtype),
                 ARRAY['AJUSTE_ADMIN','BOLSO_INGRESO','BOLSO_MOVIMIENTO','BOLSO_RETIRO','BONO_REFERIDO','CDT_CREACION','CDT_VENCIMIENTO',
                       'CREDITO_ABONO','CREDITO_CUOTA','CREDITO_DESEMBOLSO','CREDITO_MORA','DEPOSITO_BANCO','ENVIO','INGRESO_SIMULADO',
                       'INTERES_BOLSO','INTERES_CDT','RECIBO']::text[]);
SELECT assert_raises('un valor fuera del enum de rol se rechaza', $$SELECT 'SUPERADMIN'::public.rol_usuario$$, NULL, '22P02');
