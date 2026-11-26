-- 10_libro_triggers.test.sql · Etapa 2 · inventario del libro mayor: columnas, triggers, funciones, dueños, seguridad,
-- roles privilegiados y vistas de integridad en estado sano. No inserta datos (la base esta vacia).

-- ============================================================================
-- 1. Columnas de trazabilidad
-- ============================================================================
SELECT assert_eq('transaccion.registrado_en: timestamptz NOT NULL con default clock_timestamp()',
                 (SELECT (format_type(a.atttypid, a.atttypmod), a.attnotnull, pg_get_expr(d.adbin, d.adrelid))::text
                    FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                   WHERE a.attrelid = 'public.transaccion'::regclass AND a.attname = 'registrado_en'),
                 '("timestamp with time zone",t,"clock_timestamp()")'::text);
SELECT assert_eq('transaccion.tx_id: xid8 NOT NULL con default pg_current_xact_id()',
                 (SELECT (format_type(a.atttypid, a.atttypmod), a.attnotnull, pg_get_expr(d.adbin, d.adrelid))::text
                    FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                   WHERE a.attrelid = 'public.transaccion'::regclass AND a.attname = 'tx_id'),
                 '(xid8,t,"pg_current_xact_id()")'::text);
SELECT assert_eq('public sigue teniendo EXACTAMENTE 11 tablas (E2 no agrega tablas)',
                 (SELECT count(*) FROM pg_tables WHERE schemaname = 'public'), 11::bigint);
SELECT assert_eq('las dos columnas nuevas tienen COMMENT',
                 (SELECT count(*) FROM pg_attribute a WHERE a.attrelid = 'public.transaccion'::regclass AND a.attname IN ('registrado_en','tx_id')
                     AND col_description(a.attrelid, a.attnum) IS NOT NULL), 2::bigint);

-- ============================================================================
-- 2. Triggers: exactamente los esperados, habilitados, con el momento y el orden correctos
-- ============================================================================
SELECT assert_eq('los 21 triggers de usuario son EXACTAMENTE estos',
                 (SELECT array_agg(c.relname || '.' || t.tgname ORDER BY c.relname, t.tgname)
                    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname IN ('public','audit') AND NOT t.tgisinternal),
                 ARRAY['bolsillo.trg_ultimo_cobro_monotono','bolsillo.trg_zz_proteger_bolsillo','cdt.ct_cdt_inversion','cdt.trg_ultimo_cobro_monotono','cdt.trg_zz_proteger_cdt','credito.ct_credito_plan','credito.trg_cobro_hasta_monotono','credito.trg_zz_proteger_credito',
                       'cuenta.trg_cuenta_auditar_borrado','cuenta.trg_zz_proteger_cuenta','cuota.ct_credito_plan_cuota','reloj.trg_reloj_a_validar','reloj.trg_reloj_auditar',
                       'reloj.trg_reloj_borrar','reloj.trg_reloj_truncate','transaccion.ct_transaccion_cdt',
                       'transaccion.ct_transaccion_cuadre','transaccion.trg_transaccion_a_validar','transaccion.trg_transaccion_b_aplicar',
                       'transaccion.trg_transaccion_inmutable','transaccion.trg_transaccion_truncate']::text[]);
SELECT assert_eq('todos estan habilitados (tgenabled = O)',
                 (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname = 'public' AND NOT t.tgisinternal AND t.tgenabled <> 'O'), 0::bigint);
SELECT assert_eq('los 5 triggers ct_* son de restriccion, DEFERRABLE e INITIALLY DEFERRED',
                 (SELECT array_agg(t.tgname::text ORDER BY t.tgname) FROM pg_trigger t
                   WHERE t.tgconstraint <> 0 AND NOT t.tgisinternal AND t.tgdeferrable AND t.tginitdeferred),
                 ARRAY['ct_cdt_inversion','ct_credito_plan','ct_credito_plan_cuota','ct_transaccion_cdt','ct_transaccion_cuadre']::text[]);
SELECT assert_eq('ningun otro trigger es diferible',
                 (SELECT count(*) FROM pg_trigger t WHERE NOT t.tgisinternal AND t.tgdeferrable AND t.tgname NOT LIKE 'ct\_%'), 0::bigint);
SELECT assert_eq('BEFORE INSERT FOR EACH ROW en transaccion, en orden de disparo (alfabetico): validar y luego aplicar',
                 (SELECT array_agg(t.tgname::text ORDER BY t.tgname COLLATE "C") FROM pg_trigger t
                   WHERE t.tgrelid = 'public.transaccion'::regclass AND NOT t.tgisinternal
                     AND (t.tgtype & 1) = 1 AND (t.tgtype & 2) = 2 AND (t.tgtype & 4) = 4),
                 ARRAY['trg_transaccion_a_validar','trg_transaccion_b_aplicar']::text[]);
SELECT assert_eq('en cada tabla de acumuladores el guardia es el ULTIMO BEFORE ROW (trg_zz_)',
                 (SELECT count(*) FROM (
                    SELECT t.tgrelid, max(t.tgname COLLATE "C") AS ultimo FROM pg_trigger t
                     WHERE t.tgrelid IN ('public.cuenta'::regclass, 'public.bolsillo'::regclass, 'public.cdt'::regclass, 'public.credito'::regclass)
                       AND NOT t.tgisinternal AND (t.tgtype & 1) = 1 AND (t.tgtype & 2) = 2
                     GROUP BY t.tgrelid) x WHERE x.ultimo LIKE 'trg\_zz\_proteger\_%'), 4::bigint);
SELECT assert_eq('trg_transaccion_truncate es BEFORE TRUNCATE por sentencia',
                 (SELECT (t.tgtype & 1) = 0 AND (t.tgtype & 2) = 2 AND (t.tgtype & 32) = 32 FROM pg_trigger t WHERE t.tgname = 'trg_transaccion_truncate'), true);
SELECT assert_eq('trg_cuenta_auditar_borrado es BEFORE DELETE por fila',
                 (SELECT (t.tgtype & 1) = 1 AND (t.tgtype & 2) = 2 AND (t.tgtype & 8) = 8 FROM pg_trigger t WHERE t.tgname = 'trg_cuenta_auditar_borrado'), true);
SELECT assert_eq('todo trigger de usuario tiene COMMENT',
                 (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname = 'public' AND NOT t.tgisinternal AND obj_description(t.oid, 'pg_trigger') IS NULL), 0::bigint);

-- ============================================================================
-- 3. Event triggers
-- ============================================================================
SELECT assert_eq('hay 2 event triggers habilitados: ALTER TABLE y DROP TRIGGER',
                 (SELECT array_agg(evtname || ':' || evtevent || ':' || array_to_string(evttags, ',') || ':' || evtenabled::text ORDER BY evtname) FROM pg_event_trigger),
                 ARRAY['evt_ddl_protegido:ddl_command_end:ALTER TABLE:O','evt_drop_protegido:sql_drop:DROP TRIGGER:O']::text[]);

-- ============================================================================
-- 4. Funciones: dueño, SECURITY, search_path, documentacion y permisos
-- ============================================================================
SELECT assert_eq('las funciones del libro son de banco_owner, salvo trg_transaccion_b_aplicar que es de banco_ledger',
                 (SELECT array_agg(p.proname::text ORDER BY p.proname) FROM pg_proc p
                   WHERE p.pronamespace = 'public'::regnamespace AND pg_get_userbyid(p.proowner) = 'banco_ledger'),
                 ARRAY['trg_transaccion_b_aplicar']::text[]);
SELECT assert_eq('el resto de las 130 funciones es de banco_owner',
                 (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND pg_get_userbyid(p.proowner) = 'banco_owner'), 130::bigint);
SELECT assert_eq('SECURITY DEFINER: _asentar_grupo, los 2 triggers diferidos (se disparan al COMMIT con el usuario de la sesion), la de aplicar, la auditoria del borrado, las 2 de event triggers, las del reloj y las 40 funciones publicas de E4-E12 (y ct_credito_plan, el diferido de creditos)',
                 (SELECT array_agg(p.proname::text ORDER BY p.proname COLLATE "C") FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef),
                 ARRAY['_asentar_grupo','_reloj_actualizar','_reloj_instantanea','_reloj_vista','abonar_credito','activar_descuento_automatico','admin_ajustar_balance','admin_bloquear','admin_borrar_usuario','admin_desbloquear','admin_detalle_usuario','admin_esquema','admin_get_reloj','admin_get_tasas','admin_listar_usuarios','admin_set_reloj','admin_set_tasa_cdt','admin_set_tasa_credito','admin_set_tasa_mora','admin_tabla','ahora_banco','crear_bolsillo','crear_cdt','ct_cdt_inversion','ct_credito_plan','ct_transaccion_cuadre','hacer_transferencia',
                       'hoy_banco','listar_cdt_definiciones','mover_a_bolsillo','mover_entre_bolsillos','nombre_destinatario','obtener_credenciales','pagar_cuota','productos_disponibles','productos_publicos','registrar_usuario','retirar_de_bolsillo','simular_cdt','simular_credito','solicitar_credito','trg_cuenta_auditar_borrado','trg_evento_ddl','trg_evento_drop',
                       'trg_reloj_a_validar','trg_reloj_auditar','trg_transaccion_b_aplicar','validar_sesion','verificar_correo','vista_balance','vista_cdts','vista_creditos','vista_dashboard','vista_historial','vista_perfil']::text[]);
SELECT assert_eq('los 4 guardias son SECURITY INVOKER (si fueran DEFINER verian al dueño y no a quien actualiza)',
                 (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'trg\_zz\_proteger\_%' AND NOT p.prosecdef), 4::bigint);
SELECT assert_eq('TODAS las funciones del banco tienen search_path fijo (public, pg_temp) (se excluyen las de extensiones y, desde E13, los 2 PROCEDIMIENTOS que hacen COMMIT: no pueden llevar clausula SET; fijan el search_path con set_config en cada transaccion)',
                 (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
                     AND p.prokind = 'f'
                     AND NOT ('search_path=public, pg_temp' = ANY (coalesce(p.proconfig, ARRAY[]::text[])))), 0::bigint);
SELECT assert_eq('TODAS las funciones tienen COMMENT',
                 (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e') AND obj_description(p.oid, 'pg_proc') IS NULL), 0::bigint);
SELECT assert_eq('ninguna funcion es ejecutable por PUBLIC; banco_app ejecuta SOLO las 40 funciones publicas de E4-E12; banco_lector/banco_dev, solo _plantillas_validas, _reglas_historial, hoy_banco y ahora_banco (las usan las vistas)',
                 (SELECT count(*) FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                   WHERE p.pronamespace = 'public'::regnamespace AND a.privilege_type = 'EXECUTE' AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
                     AND (a.grantee = 0
                          OR (a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'banco_app')
                              AND p.proname NOT IN ('abonar_credito', 'activar_descuento_automatico', 'admin_ajustar_balance', 'admin_bloquear', 'admin_borrar_usuario', 'admin_desbloquear', 'admin_detalle_usuario', 'admin_esquema', 'admin_get_reloj', 'admin_get_tasas', 'admin_listar_usuarios', 'admin_set_reloj', 'admin_set_tasa_cdt', 'admin_set_tasa_credito', 'admin_set_tasa_mora', 'admin_tabla', 'crear_bolsillo', 'crear_cdt', 'hacer_transferencia', 'listar_cdt_definiciones', 'mover_a_bolsillo', 'mover_entre_bolsillos', 'nombre_destinatario', 'obtener_credenciales', 'pagar_cuota', 'productos_disponibles', 'productos_publicos', 'registrar_usuario', 'retirar_de_bolsillo', 'simular_cdt', 'simular_credito', 'solicitar_credito', 'validar_sesion', 'verificar_correo', 'vista_balance', 'vista_cdts', 'vista_creditos', 'vista_dashboard', 'vista_historial', 'vista_perfil'))
                          OR (p.proname NOT IN ('_plantillas_validas', '_reglas_historial', 'hoy_banco', 'ahora_banco') AND a.grantee IN (SELECT oid FROM pg_roles WHERE rolname IN ('banco_lector','banco_dev'))))), 0::bigint);
SELECT assert_eq('banco_app tiene EXECUTE exactamente en las 40 funciones publicas de E4-E12 (y banco_dev lo hereda; banco_lector no)',
                 (SELECT (array_agg(p.proname::text ORDER BY p.proname COLLATE "C") FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE')),
                          count(*) FILTER (WHERE has_function_privilege('banco_dev', p.oid, 'EXECUTE') AND p.proname IN ('abonar_credito', 'activar_descuento_automatico', 'admin_ajustar_balance', 'admin_bloquear', 'admin_borrar_usuario', 'admin_desbloquear', 'admin_detalle_usuario', 'admin_esquema', 'admin_get_reloj', 'admin_get_tasas', 'admin_listar_usuarios', 'admin_set_reloj', 'admin_set_tasa_cdt', 'admin_set_tasa_credito', 'admin_set_tasa_mora', 'admin_tabla', 'crear_bolsillo', 'crear_cdt', 'hacer_transferencia', 'listar_cdt_definiciones', 'mover_a_bolsillo', 'mover_entre_bolsillos', 'nombre_destinatario', 'obtener_credenciales', 'pagar_cuota', 'productos_disponibles', 'productos_publicos', 'registrar_usuario', 'retirar_de_bolsillo', 'simular_cdt', 'simular_credito', 'solicitar_credito', 'validar_sesion', 'verificar_correo', 'vista_balance', 'vista_cdts', 'vista_creditos', 'vista_dashboard', 'vista_historial', 'vista_perfil')),
                          count(*) FILTER (WHERE has_function_privilege('banco_lector', p.oid, 'EXECUTE') AND p.proname IN ('abonar_credito', 'activar_descuento_automatico', 'admin_ajustar_balance', 'admin_bloquear', 'admin_borrar_usuario', 'admin_desbloquear', 'admin_detalle_usuario', 'admin_esquema', 'admin_get_reloj', 'admin_get_tasas', 'admin_listar_usuarios', 'admin_set_reloj', 'admin_set_tasa_cdt', 'admin_set_tasa_credito', 'admin_set_tasa_mora', 'admin_tabla', 'crear_bolsillo', 'crear_cdt', 'hacer_transferencia', 'listar_cdt_definiciones', 'mover_a_bolsillo', 'mover_entre_bolsillos', 'nombre_destinatario', 'obtener_credenciales', 'pagar_cuota', 'productos_disponibles', 'productos_publicos', 'registrar_usuario', 'retirar_de_bolsillo', 'simular_cdt', 'simular_credito', 'solicitar_credito', 'validar_sesion', 'verificar_correo', 'vista_balance', 'vista_cdts', 'vista_creditos', 'vista_dashboard', 'vista_historial', 'vista_perfil')))::text
                    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')),
                 '("{abonar_credito,activar_descuento_automatico,admin_ajustar_balance,admin_bloquear,admin_borrar_usuario,admin_desbloquear,admin_detalle_usuario,admin_esquema,admin_get_reloj,admin_get_tasas,admin_listar_usuarios,admin_set_reloj,admin_set_tasa_cdt,admin_set_tasa_credito,admin_set_tasa_mora,admin_tabla,crear_bolsillo,crear_cdt,hacer_transferencia,listar_cdt_definiciones,mover_a_bolsillo,mover_entre_bolsillos,nombre_destinatario,obtener_credenciales,pagar_cuota,productos_disponibles,productos_publicos,registrar_usuario,retirar_de_bolsillo,simular_cdt,simular_credito,solicitar_credito,validar_sesion,verificar_correo,vista_balance,vista_cdts,vista_creditos,vista_dashboard,vista_historial,vista_perfil}",40,0)'::text);
SELECT assert_eq('_plantillas_validas: EXECUTE para banco_lector y banco_dev (heredado), no para banco_app ni PUBLIC',
                 (has_function_privilege('banco_lector', 'public._plantillas_validas()', 'EXECUTE'), has_function_privilege('banco_dev', 'public._plantillas_validas()', 'EXECUTE'),
                  has_function_privilege('banco_app', 'public._plantillas_validas()', 'EXECUTE'),
                  (SELECT count(*) FROM pg_proc p, aclexplode(p.proacl) a WHERE p.proname = '_plantillas_validas' AND a.grantee = 0))::text, '(t,t,f,0)'::text);
SELECT assert_eq('trg_transaccion_b_aplicar: EXECUTE solo para su dueño banco_ledger y para banco_owner',
                 (SELECT array_agg(pg_get_userbyid(a.grantee)::text ORDER BY pg_get_userbyid(a.grantee)::text)
                    FROM pg_proc p, aclexplode(p.proacl) a WHERE p.proname = 'trg_transaccion_b_aplicar' AND a.privilege_type = 'EXECUTE'),
                 ARRAY['banco_ledger','banco_owner']::text[]);
SELECT assert_raises('un trigger-function no se puede llamar a mano (aunque seas superusuario)',
                     $$SELECT public.trg_transaccion_b_aplicar()$$, '%trigger functions can only be called as triggers%');

-- ============================================================================
-- 5. Catalogo de plantillas
-- ============================================================================
SELECT assert_eq('hay 20 plantillas (15 de E2 + 5 de E9), todas distintas entre si: 18 de 2 patas y 2 de 3 patas (CUOTA y ABONO con interes)',
                 (SELECT (count(*), count(DISTINCT patas), count(*) FILTER (WHERE cardinality(patas) = 2), count(*) FILTER (WHERE cardinality(patas) = 3))::text FROM public._plantillas_validas()), '(20,20,18,2)'::text);
SELECT assert_eq('las plantillas usan las 37 combinaciones (tipo|contenedor|sentido) de la matriz: desde E9 las 8 de CUOTA, ABONO y MORA (D7) tienen plantilla',
                 (SELECT count(DISTINCT x) FROM public._plantillas_validas(), unnest(patas) x), 37::bigint);
SELECT assert_eq('...y CREDITO_CUOTA, CREDITO_ABONO y CREDITO_MORA aparecen en 12 patas de plantilla (CUOTA 3+2, ABONO 3+2, MORA 2)',
                 (SELECT count(*) FROM public._plantillas_validas(), unnest(patas) x WHERE x ~ '^CREDITO_(CUOTA|ABONO|MORA)\|'), 12::bigint);
-- (que cada pata de cada plantilla es una combinacion permitida por la matriz de E1 lo prueba 12_libro_asentar: las 15 entran.)

-- ============================================================================
-- 6. Roles privilegiados
-- ============================================================================
SELECT assert_eq('banco_owner y banco_ledger: NOLOGIN, sin superusuario ni ningun atributo especial',
                 (SELECT count(*) FROM pg_roles WHERE rolname IN ('banco_owner','banco_ledger')
                     AND NOT rolcanlogin AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls), 2::bigint);
SELECT assert_eq('NADIE (salvo superusuarios) es miembro de banco_owner ni de banco_ledger',
                 (SELECT count(*) FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles mm ON mm.oid = m.member
                   WHERE g.rolname IN ('banco_owner','banco_ledger') AND NOT mm.rolsuper), 0::bigint);
-- (Un "SET ROLE" desde esta sesion de superusuario no demostraria nada: se valida contra el usuario de sesion. La prueba
--  con conexiones REALES esta en reales/19, 20 y 21. Aqui se comprueba la capacidad por el catalogo.)
SELECT assert_eq('ningun rol de aplicacion (app, dev, lector) es miembro, hereda ni puede hacer SET ROLE de banco_owner ni banco_ledger',
                 (SELECT count(*) FROM (VALUES ('banco_app'), ('banco_dev'), ('banco_lector')) r(x),
                                       (VALUES ('banco_owner'), ('banco_ledger')) t(y),
                                       (VALUES ('MEMBER'), ('USAGE'), ('SET')) p(z)
                   WHERE pg_has_role(r.x, t.y, p.z)), 0::bigint);
SELECT assert_eq('ni banco_owner ni banco_ledger pueden asumir al otro',
                 (SELECT count(*) FROM (VALUES ('banco_owner','banco_ledger'), ('banco_ledger','banco_owner')) v(x, y)
                   WHERE pg_has_role(v.x, v.y, 'MEMBER') OR pg_has_role(v.x, v.y, 'SET')), 0::bigint);
SELECT assert_raises('un rol de aplicacion no puede usar session_replication_role',
                     $$SET LOCAL ROLE banco_app; SET session_replication_role = replica$$, NULL, '42501');
SELECT assert_raises('un rol de aplicacion no puede desactivar triggers del libro',
                     $$SET LOCAL ROLE banco_app; ALTER TABLE public.transaccion DISABLE TRIGGER ALL$$, 'must be owner of table transaccion', '42501');
SELECT assert_raises('ni siquiera banco_ledger puede desactivar triggers',
                     $$SET LOCAL ROLE banco_ledger; ALTER TABLE public.cuenta DISABLE TRIGGER trg_zz_proteger_cuenta$$, 'must be owner of table cuenta', '42501');

-- ============================================================================
-- 7. Vistas de integridad: existen, son de banco_owner, las lee banco_lector y NO banco_app; estado sano
-- ============================================================================
SELECT assert_eq('las 9 vistas (7 v_integridad_*, incluidas v_integridad_auth de E4 y v_integridad_creditos de E8, v_reloj_estado y v_transaccion_usuario de E10) son de banco_owner y tienen COMMENT',
                 (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'v'
                     AND pg_get_userbyid(c.relowner) = 'banco_owner' AND obj_description(c.oid, 'pg_class') IS NOT NULL), 9::bigint);
SELECT assert_eq('banco_lector y banco_dev leen las 9 vistas; banco_app no lee ninguna',
                 (SELECT (count(*) FILTER (WHERE has_table_privilege('banco_lector', c.oid, 'SELECT')),
                          count(*) FILTER (WHERE has_table_privilege('banco_dev', c.oid, 'SELECT')),
                          count(*) FILTER (WHERE has_table_privilege('banco_app', c.oid, 'SELECT' ))
                          )::text FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'v'), '(9,9,0)'::text);
SELECT assert_ok('banco_lector puede consultar las vistas',
                 $$SET LOCAL ROLE banco_lector; SELECT * FROM public.v_integridad_global; SELECT * FROM public.v_integridad_defensas$$);
SELECT assert_raises('banco_app NO puede consultar las vistas', $$SET LOCAL ROLE banco_app; SELECT * FROM public.v_integridad_global$$,
                     'permission denied for view v_integridad_global', '42501');
SELECT assert_true('v_integridad_defensas tiene al menos 20 controles y TODOS estan en orden',
                   (SELECT count(*) >= 20 AND bool_and(ok) FROM public.v_integridad_defensas));
SELECT assert_eq('v_integridad_global en base vacia: ok y todo en cero',
                 (SELECT (ok, cuentas, patas, grupos, contenedores_con_desvio, grupos_con_error, cuentas_con_desvio_i5u, defensas_fallidas)::text FROM public.v_integridad_global),
                 '(t,0,0,0,0,0,0,0)'::text);
