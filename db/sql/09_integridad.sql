-- ============================================================================
-- 09_integridad.sql  ·  Etapa 2 (libro mayor y guardias) · parte 4/4
-- Propósito  : vistas de VERIFICACIÓN INDEPENDIENTE. Recalculan todo desde las patas del libro y
--              comprueban que las defensas siguen activas; detectan lo que escape a los triggers
--              (p. ej. un superusuario que desactivó un trigger o tocó un saldo).
--
--   v_integridad_saldos    I1/I2  cada acumulador almacenado vs suma de sus patas (por contenedor)
--   v_integridad_grupos    I3/I7  cada grupo: cuadre, forma/plantilla, una transacción y una fecha
--   v_integridad_usuario   I5u    por cuenta: Activos - Pasivos = Resultado + TransfNeto
--   v_integridad_global    I5g    una fila resumen (+ conciliación con las cuentas borradas auditadas)
--   v_integridad_defensas  I9     ¿están activos triggers (incl. los del reloj, E3), event triggers, permisos y roles esperados (E4: lista blanca de banco_app)?
--   v_integridad_auth      I10    E4: todo CLIENTE tiene cuenta; bono de referido pagado exactamente una vez
--
--   Cada vista es UNA sola sentencia: lee un único snapshot aunque haya escrituras concurrentes
--   (sin falsos positivos). Columna "ok": TRUE = sin desvío. Uso típico:
--     SELECT * FROM v_integridad_global;   SELECT * FROM v_integridad_defensas WHERE NOT ok;
--   Un grupo ENVIO/RECIBO con UNA sola pata cuya cuenta contraria ya no existe se clasifica
--   HUERFANO_POR_BORRADO (esperado: se borró al otro cliente); si la cuenta contraria SÍ existe, es un ERROR.
-- Dueño: banco_owner. Lectura: banco_lector (y banco_dev por herencia).
-- Dependencias : 01 a 08 (E3 agrega controles del reloj; E4 agrega v_integridad_auth y la lista blanca de banco_app).   Ejecución: como superusuario, IDEMPOTENTE, transaccional.
-- ============================================================================

BEGIN;

SET LOCAL ROLE banco_owner;

-- ----------------------------------------------------------------------------
-- I1/I2: acumuladores vs patas
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_integridad_saldos AS
SELECT 'CUENTA'::text AS contenedor, c.id AS contenedor_id, c.id AS cuenta_id,
       c.balance::numeric AS almacenado, coalesce(s.suma, 0) AS calculado,
       c.balance::numeric - coalesce(s.suma, 0) AS diferencia,
       (c.balance::numeric = coalesce(s.suma, 0) AND c.balance >= 0) AS ok
  FROM public.cuenta c
  LEFT JOIN (SELECT t.cuenta_id, sum(CASE t.sentido WHEN 'E' THEN t.monto ELSE -t.monto END) AS suma
               FROM public.transaccion t WHERE t.contenedor = 'CUENTA' GROUP BY t.cuenta_id) s ON s.cuenta_id = c.id
UNION ALL
SELECT 'BOLSILLO', b.id, b.cuenta_id, b.balance::numeric, coalesce(s.suma, 0),
       b.balance::numeric - coalesce(s.suma, 0),
       (b.balance::numeric = coalesce(s.suma, 0) AND b.balance >= 0)
  FROM public.bolsillo b
  LEFT JOIN (SELECT t.bolsillo_id, sum(CASE t.sentido WHEN 'E' THEN t.monto ELSE -t.monto END) AS suma
               FROM public.transaccion t WHERE t.contenedor = 'BOLSILLO' GROUP BY t.bolsillo_id) s ON s.bolsillo_id = b.id
UNION ALL
SELECT 'CDT_GENERADO', d.id, d.cuenta_id, d.generado_acumulado::numeric, coalesce(s.suma, 0),
       d.generado_acumulado::numeric - coalesce(s.suma, 0),
       (d.generado_acumulado::numeric = coalesce(s.suma, 0))
  FROM public.cdt d
  LEFT JOIN (SELECT t.cdt_id, sum(t.monto) AS suma
               FROM public.transaccion t WHERE t.contenedor = 'CDT' AND t.tipo = 'INTERES_CDT' GROUP BY t.cdt_id) s ON s.cdt_id = d.id
UNION ALL
SELECT 'CDT_INVERSION', d.id, d.cuenta_id,
       (CASE WHEN d.estado = 'ACTIVO' THEN d.monto + d.generado_acumulado ELSE 0 END)::numeric, coalesce(s.suma, 0),
       (CASE WHEN d.estado = 'ACTIVO' THEN d.monto + d.generado_acumulado ELSE 0 END)::numeric - coalesce(s.suma, 0),
       ((CASE WHEN d.estado = 'ACTIVO' THEN d.monto + d.generado_acumulado ELSE 0 END)::numeric = coalesce(s.suma, 0))
  FROM public.cdt d
  LEFT JOIN (SELECT t.cdt_id, sum(CASE t.sentido WHEN 'E' THEN t.monto ELSE -t.monto END) AS suma
               FROM public.transaccion t WHERE t.contenedor = 'CDT' GROUP BY t.cdt_id) s ON s.cdt_id = d.id
UNION ALL
SELECT 'CREDITO', k.id, k.cuenta_id, k.capital_pendiente::numeric, coalesce(s.suma, 0),
       k.capital_pendiente::numeric - coalesce(s.suma, 0),
       (k.capital_pendiente::numeric = coalesce(s.suma, 0) AND k.capital_pendiente >= 0)
  FROM public.credito k
  LEFT JOIN (SELECT t.credito_id, sum(CASE t.sentido WHEN 'E' THEN t.monto ELSE -t.monto END) AS suma
               FROM public.transaccion t WHERE t.contenedor = 'CREDITO' GROUP BY t.credito_id) s ON s.credito_id = k.id;
COMMENT ON VIEW public.v_integridad_saldos IS
  'E2 (I1/I2). Por contenedor (CUENTA, BOLSILLO, CDT_GENERADO, CDT_INVERSION, CREDITO): valor almacenado vs suma de sus patas del libro. ok=FALSE indica un saldo que no se explica por el libro.';

-- ----------------------------------------------------------------------------
-- I3/I7: grupos
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_integridad_grupos AS
SELECT v.*, (v.estado <> 'ERROR') AS ok
  FROM (
    SELECT c.grupo_id, c.patas, c.cuentas, c.debitos, c.creditos, c.plantilla,
           CASE
             WHEN c.patas = 1 AND c.tipo_unico IN ('ENVIO', 'RECIBO') AND c.contraparte_unica IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM public.cuenta x WHERE x.numero_cuenta = c.contraparte_unica)
               THEN 'HUERFANO_POR_BORRADO'
             WHEN c.patas < 2 OR c.debitos <> c.creditos OR c.transacciones <> 1 OR c.fechas <> 1 THEN 'ERROR'
             WHEN c.algun_credito_pend AND NOT (c.solo_credito_pend AND c.cuentas = 1 AND c.n_creditos = 1) THEN 'ERROR'          -- E9: las formas de crédito ya tienen plantilla (SIN_PLANTILLA_CREDITO ya no se produce)
             WHEN c.plantilla IS NULL THEN 'ERROR'
             WHEN c.plantilla LIKE 'ENVIO%' THEN CASE WHEN c.cuentas = 2 THEN 'OK' ELSE 'ERROR' END
             WHEN c.cuentas = 1 THEN 'OK'
             ELSE 'ERROR'
           END AS estado
      FROM (
        SELECT g.*, (SELECT p.plantilla FROM public._plantillas_validas() p WHERE p.patas = g.forma) AS plantilla
          FROM (
            SELECT t.grupo_id,
                   count(*)                                    AS patas,
                   count(DISTINCT t.cuenta_id)                 AS cuentas,
                   count(DISTINCT t.tx_id)                     AS transacciones,
                   count(DISTINCT t.fecha)                     AS fechas,
                   count(DISTINCT t.credito_id)                AS n_creditos,
                   coalesce(sum(t.monto) FILTER (WHERE t.lado = 'D'), 0) AS debitos,
                   coalesce(sum(t.monto) FILTER (WHERE t.lado = 'C'), 0) AS creditos,
                   array_agg(t.tipo::text || '|' || t.contenedor::text || '|' || t.sentido::text
                             ORDER BY (t.tipo::text || '|' || t.contenedor::text || '|' || t.sentido::text) COLLATE "C") AS forma,
                   bool_and(t.tipo::text IN ('CREDITO_CUOTA','CREDITO_ABONO','CREDITO_MORA')) AS solo_credito_pend,
                   bool_or (t.tipo::text IN ('CREDITO_CUOTA','CREDITO_ABONO','CREDITO_MORA')) AS algun_credito_pend,
                   min(t.tipo::text)                           AS tipo_unico,
                   min(t.contraparte_cuenta)                   AS contraparte_unica
              FROM public.transaccion t
             GROUP BY t.grupo_id
          ) g
      ) c
  ) v;
COMMENT ON VIEW public.v_integridad_grupos IS
  'E2 (I3/I7). Por grupo: patas, cuentas, ΣD, ΣC, plantilla detectada y estado (OK, SIN_PLANTILLA_CREDITO ya no se produce desde E9, HUERFANO_POR_BORRADO esperado tras borrar a la contraparte, ERROR). ok=FALSE solo en ERROR.';

-- ----------------------------------------------------------------------------
-- I5u: por cuenta, Activos - Pasivos = Resultado + TransfNeto
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_integridad_usuario AS
SELECT x.*,
       (x.cuenta + x.bolsillos + x.cdt_vigente) AS activos,
       (x.cuenta + x.bolsillos + x.cdt_vigente) - x.pasivos - (x.resultado + x.transf_neto) AS diferencia,
       ((x.cuenta + x.bolsillos + x.cdt_vigente) - x.pasivos - (x.resultado + x.transf_neto) = 0) AS ok
  FROM (
    SELECT c.id AS cuenta_id, c.usuario_id,
           c.balance::numeric AS cuenta,
           (SELECT coalesce(sum(b.balance), 0) FROM public.bolsillo b WHERE b.cuenta_id = c.id)::numeric AS bolsillos,
           (SELECT coalesce(sum(CASE t.sentido WHEN 'E' THEN t.monto ELSE -t.monto END), 0)
              FROM public.transaccion t WHERE t.cuenta_id = c.id AND t.contenedor = 'CDT')::numeric AS cdt_vigente,
           (SELECT coalesce(sum(k.capital_pendiente), 0) FROM public.credito k WHERE k.cuenta_id = c.id)::numeric AS pasivos,
           (SELECT coalesce(sum(CASE t.sentido WHEN 'E' THEN t.monto ELSE -t.monto END), 0)
              FROM public.transaccion t WHERE t.cuenta_id = c.id AND t.contenedor = 'RESULTADO')::numeric AS resultado,
           (SELECT coalesce(sum(CASE t.tipo WHEN 'RECIBO' THEN t.monto ELSE -t.monto END), 0)
              FROM public.transaccion t WHERE t.cuenta_id = c.id AND t.tipo IN ('RECIBO', 'ENVIO'))::numeric AS transf_neto
      FROM public.cuenta c
  ) x;
COMMENT ON VIEW public.v_integridad_usuario IS
  'E2 (I5u). Por cuenta: activos (cuenta + bolsillos + CDT vigente) - pasivos (capital pendiente) = resultado + transferencias netas. diferencia<>0 indica dinero que apareció o desapareció sin partida.';

-- ----------------------------------------------------------------------------
-- I9: defensas activas
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_integridad_defensas AS
WITH esperados (tabla, nombre, diferido) AS (
  VALUES ('transaccion', 'trg_transaccion_a_validar', false),
         ('transaccion', 'trg_transaccion_b_aplicar', false),
         ('transaccion', 'ct_transaccion_cuadre',     true),
         ('transaccion', 'ct_transaccion_cdt',        true),
         ('transaccion', 'trg_transaccion_inmutable', false),
         ('transaccion', 'trg_transaccion_truncate',  false),
         ('cdt',         'ct_cdt_inversion',          true),
         ('cdt',         'trg_zz_proteger_cdt',       false),
         ('cuenta',      'trg_zz_proteger_cuenta',    false),
         ('cuenta',      'trg_cuenta_auditar_borrado', false),
         ('bolsillo',    'trg_zz_proteger_bolsillo',  false),
         ('credito',     'trg_zz_proteger_credito',   false),
         ('credito',     'ct_credito_plan',           true),
         ('credito',     'trg_cobro_hasta_monotono',  false),
         ('cuota',       'ct_credito_plan_cuota',     true),
         ('reloj',       'trg_reloj_a_validar',       false),
         ('reloj',       'trg_reloj_auditar',         false),
         ('reloj',       'trg_reloj_borrar',          false),
         ('reloj',       'trg_reloj_truncate',        false)
),
acum (tabla, columna) AS (
  VALUES ('cuenta', 'balance'), ('bolsillo', 'balance'), ('cdt', 'generado_acumulado'), ('credito', 'capital_pendiente')
),
internas AS (
  SELECT p.oid, p.proname, p.proowner, p.proacl FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND (p.proname LIKE '\_%' OR p.proname LIKE 'trg\_%' OR p.proname LIKE 'ct\_%')
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
)
-- 1) triggers esperados: existen, habilitados (origin) y, los ct_*, diferidos
SELECT 'trigger activo: ' || e.tabla || '.' || e.nombre AS control,
       (t.oid IS NOT NULL AND t.tgenabled = 'O' AND (NOT e.diferido OR (t.tgdeferrable AND t.tginitdeferred))) AS ok,
       CASE WHEN t.oid IS NULL THEN 'NO EXISTE'
            WHEN t.tgenabled <> 'O' THEN 'DESACTIVADO (tgenabled=' || t.tgenabled::text || ')'
            WHEN e.diferido AND NOT (t.tgdeferrable AND t.tginitdeferred) THEN 'NO es diferido'
            ELSE 'activo' END AS detalle
  FROM esperados e
  LEFT JOIN pg_trigger t ON t.tgrelid = ('public.' || e.tabla)::regclass AND t.tgname = e.nombre AND NOT t.tgisinternal
UNION ALL
-- 2) event triggers
SELECT 'event trigger activo: ' || n.nombre,
       coalesce(et.evtenabled = 'O', false),
       CASE WHEN et.oid IS NULL THEN 'NO EXISTE' WHEN et.evtenabled <> 'O' THEN 'DESACTIVADO' ELSE 'activo' END
  FROM (VALUES ('evt_ddl_protegido'), ('evt_drop_protegido')) n(nombre)
  LEFT JOIN pg_event_trigger et ON et.evtname = n.nombre
UNION ALL
-- 3) funciones: aplicar es DEFINER de banco_ledger; las guardias son INVOKER (si fueran DEFINER verían al dueño)
SELECT 'trg_transaccion_b_aplicar: SECURITY DEFINER y dueño banco_ledger',
       coalesce(bool_and(p.prosecdef AND pg_get_userbyid(p.proowner) = 'banco_ledger'), false),
       coalesce(string_agg(pg_get_userbyid(p.proowner) || CASE WHEN p.prosecdef THEN ' definer' ELSE ' invoker' END, ', '), 'NO EXISTE')
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'trg_transaccion_b_aplicar'
UNION ALL
SELECT 'guardias: SECURITY INVOKER (cuenta, bolsillo, cdt, credito)',
       (count(*) = 4 AND bool_and(NOT p.prosecdef)),
       count(*) || ' guardias; ' || count(*) FILTER (WHERE p.prosecdef) || ' con SECURITY DEFINER'
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'trg\_zz\_proteger\_%'
UNION ALL
-- 4) permisos sobre acumuladores y libro
SELECT 'banco_owner sin UPDATE de acumuladores',
       NOT bool_or(has_column_privilege('banco_owner', ('public.' || a.tabla)::regclass, a.columna, 'UPDATE')),
       'columnas con UPDATE: ' || coalesce(string_agg(a.tabla || '.' || a.columna, ', ')
                                           FILTER (WHERE has_column_privilege('banco_owner', ('public.' || a.tabla)::regclass, a.columna, 'UPDATE')), 'ninguna')
  FROM acum a
UNION ALL
SELECT 'banco_owner sin UPDATE de tabla ni TRUNCATE sobre transaccion (solo la columna inocua registrado_en, que usan las FK)',
       (NOT has_table_privilege('banco_owner', 'public.transaccion', 'UPDATE')
        AND NOT has_table_privilege('banco_owner', 'public.transaccion', 'TRUNCATE')
        AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                         WHERE a.attrelid = 'public.transaccion'::regclass AND a.attnum > 0 AND NOT a.attisdropped
                           AND a.attname <> 'registrado_en' AND has_column_privilege('banco_owner', a.attrelid, a.attnum, 'UPDATE'))),
       'UPDATE de tabla=' || has_table_privilege('banco_owner', 'public.transaccion', 'UPDATE')
         || ' TRUNCATE=' || has_table_privilege('banco_owner', 'public.transaccion', 'TRUNCATE')
UNION ALL
SELECT 'reloj: banco_owner sin UPDATE de tabla (solo usar_fecha_real y fecha_sistema) y sin acceso para banco_app',
       (NOT has_table_privilege('banco_owner', 'public.reloj', 'UPDATE')
        AND (SELECT count(*) FROM pg_attribute a WHERE a.attrelid = 'public.reloj'::regclass AND a.attnum > 0 AND NOT a.attisdropped
                AND has_column_privilege('banco_owner', a.attrelid, a.attnum, 'UPDATE')) = 2
        AND NOT has_any_column_privilege('banco_app', 'public.reloj', 'SELECT,INSERT,UPDATE,REFERENCES')),
       'UPDATE de tabla=' || has_table_privilege('banco_owner', 'public.reloj', 'UPDATE')
UNION ALL
SELECT 'reloj: hoy_banco() y ahora_banco() ejecutables por banco_lector y no por banco_app ni PUBLIC',
       coalesce(bool_and(has_function_privilege('banco_lector', f.oid, 'EXECUTE')
                         AND NOT has_function_privilege('banco_app', f.oid, 'EXECUTE')
                         AND NOT EXISTS (SELECT 1 FROM pg_proc p2, aclexplode(coalesce(p2.proacl, acldefault('f', p2.proowner))) a
                                          WHERE p2.oid = f.oid AND a.grantee = 0 AND a.privilege_type = 'EXECUTE')), false),
       count(*) || ' funciones revisadas'
  FROM (SELECT to_regprocedure('public.hoy_banco()') AS oid UNION ALL SELECT to_regprocedure('public.ahora_banco()')) f
 WHERE f.oid IS NOT NULL
UNION ALL
SELECT 'roles de acceso (app, lector, dev) sin UPDATE de acumuladores ni de transaccion',
       NOT bool_or(has_any_column_privilege(r.rol, t.oid, 'UPDATE')),
       'roles con UPDATE: ' || coalesce(string_agg(DISTINCT r.rol, ', ') FILTER (WHERE has_any_column_privilege(r.rol, t.oid, 'UPDATE')), 'ninguno')
  FROM (VALUES ('banco_app'), ('banco_lector'), ('banco_dev')) r(rol),
       (SELECT c.oid FROM pg_class c WHERE c.oid IN ('public.cuenta'::regclass, 'public.bolsillo'::regclass, 'public.cdt'::regclass,
                                                      'public.credito'::regclass, 'public.transaccion'::regclass)) t
UNION ALL
SELECT 'banco_ledger: UPDATE solo en los 4 acumuladores',
       (count(*) = 4),
       count(*) || ' columnas con UPDATE: ' || coalesce(string_agg(c.relname || '.' || a.attname, ', ' ORDER BY c.relname), '')
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
 WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
   AND has_column_privilege('banco_ledger', c.oid, a.attnum, 'UPDATE')
UNION ALL
SELECT 'banco_ledger: SELECT solo de 11 columnas (id, propietario y acumulador de 4 tablas) y sin privilegios de tabla',
       (count(*) FILTER (WHERE has_column_privilege('banco_ledger', c.oid, a.attnum, 'SELECT')) = 11
        AND NOT bool_or(has_table_privilege('banco_ledger', c.oid, 'SELECT,INSERT,DELETE,TRUNCATE,REFERENCES,TRIGGER')) ),
       count(*) FILTER (WHERE has_column_privilege('banco_ledger', c.oid, a.attnum, 'SELECT')) || ' columnas con SELECT'
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
 WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
UNION ALL
-- 5) roles: banco_owner y banco_ledger no inician sesión y nadie (que no sea superusuario) puede asumirlos
SELECT 'banco_owner y banco_ledger: NOLOGIN, sin superusuario',
       (count(*) = 2 AND NOT bool_or(r.rolcanlogin OR r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls)),
       count(*) || ' roles revisados'
  FROM pg_roles r WHERE r.rolname IN ('banco_owner', 'banco_ledger')
UNION ALL
SELECT 'nadie (salvo superusuarios) puede asumir banco_owner ni banco_ledger',
       NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles mm ON mm.oid = m.member
                    WHERE g.rolname IN ('banco_owner', 'banco_ledger') AND NOT mm.rolsuper),
       coalesce((SELECT string_agg(mm.rolname || ' -> ' || g.rolname, ', ') FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
                   JOIN pg_roles mm ON mm.oid = m.member WHERE g.rolname IN ('banco_owner', 'banco_ledger') AND NOT mm.rolsuper), 'ninguno')
UNION ALL
-- 6) funciones internas: sin EXECUTE para PUBLIC ni para roles de acceso
SELECT 'funciones internas sin EXECUTE para PUBLIC ni banco_app (ni banco_lector/dev, salvo _plantillas_validas y _reglas_historial)',
       NOT EXISTS (SELECT 1 FROM internas i, aclexplode(coalesce(i.proacl, acldefault('f', i.proowner))) a
                    WHERE a.privilege_type = 'EXECUTE'
                      AND (a.grantee = 0
                           OR a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'banco_app')
                           OR (i.proname NOT IN ('_plantillas_validas', '_reglas_historial')
                               AND a.grantee IN (SELECT oid FROM pg_roles WHERE rolname IN ('banco_lector', 'banco_dev'))))),
       (SELECT count(*) FROM internas) || ' funciones internas revisadas (_plantillas_validas y _reglas_historial: EXECUTE solo para banco_lector, que las necesitan las vistas v_integridad_grupos y v_transaccion_usuario)'
UNION ALL
-- 7) E4-E12: banco_app ejecuta EXACTAMENTE las 40 funciones públicas (autenticación, registro, transferencias, bolsillos, CDT, créditos, pagos, vistas, administración y el visor Control) (y PUBLIC/lector ninguna de ellas)
SELECT 'banco_app ejecuta EXACTAMENTE las 40 funciones publicas de E4-E12 (abonar_credito, activar_descuento_automatico, admin_ajustar_balance, admin_bloquear, admin_borrar_usuario, admin_desbloquear, admin_detalle_usuario, admin_esquema, admin_get_reloj, admin_get_tasas, admin_listar_usuarios, admin_set_reloj, admin_set_tasa_cdt, admin_set_tasa_credito, admin_set_tasa_mora, admin_tabla, crear_bolsillo, crear_cdt, hacer_transferencia, listar_cdt_definiciones, mover_a_bolsillo, mover_entre_bolsillos, nombre_destinatario, obtener_credenciales, pagar_cuota, productos_disponibles, productos_publicos, registrar_usuario, retirar_de_bolsillo, simular_cdt, simular_credito, solicitar_credito, validar_sesion, verificar_correo, vista_balance, vista_cdts, vista_creditos, vista_dashboard, vista_historial, vista_perfil); PUBLIC y banco_lector ninguna',
       (coalesce((SELECT array_agg(p.proname ORDER BY p.proname COLLATE "C") FROM pg_proc p
                   WHERE p.pronamespace = 'public'::regnamespace
                     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
                     AND has_function_privilege('banco_app', p.oid, 'EXECUTE')), ARRAY[]::name[])
          = ARRAY['abonar_credito', 'activar_descuento_automatico', 'admin_ajustar_balance', 'admin_bloquear', 'admin_borrar_usuario', 'admin_desbloquear', 'admin_detalle_usuario', 'admin_esquema', 'admin_get_reloj', 'admin_get_tasas', 'admin_listar_usuarios', 'admin_set_reloj', 'admin_set_tasa_cdt', 'admin_set_tasa_credito', 'admin_set_tasa_mora', 'admin_tabla', 'crear_bolsillo', 'crear_cdt', 'hacer_transferencia', 'listar_cdt_definiciones', 'mover_a_bolsillo', 'mover_entre_bolsillos', 'nombre_destinatario', 'obtener_credenciales', 'pagar_cuota', 'productos_disponibles', 'productos_publicos', 'registrar_usuario', 'retirar_de_bolsillo', 'simular_cdt', 'simular_credito', 'solicitar_credito', 'validar_sesion', 'verificar_correo', 'vista_balance', 'vista_cdts', 'vista_creditos', 'vista_dashboard', 'vista_historial', 'vista_perfil']::name[]
        AND NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                         WHERE p.pronamespace = 'public'::regnamespace AND a.privilege_type = 'EXECUTE' AND a.grantee = 0
                           AND p.proname IN ('abonar_credito', 'activar_descuento_automatico', 'admin_ajustar_balance', 'admin_bloquear', 'admin_borrar_usuario', 'admin_desbloquear', 'admin_detalle_usuario', 'admin_esquema', 'admin_get_reloj', 'admin_get_tasas', 'admin_listar_usuarios', 'admin_set_reloj', 'admin_set_tasa_cdt', 'admin_set_tasa_credito', 'admin_set_tasa_mora', 'admin_tabla', 'crear_bolsillo', 'crear_cdt', 'hacer_transferencia', 'listar_cdt_definiciones', 'mover_a_bolsillo', 'mover_entre_bolsillos', 'nombre_destinatario', 'obtener_credenciales', 'pagar_cuota', 'productos_disponibles', 'productos_publicos', 'registrar_usuario', 'retirar_de_bolsillo', 'simular_cdt', 'simular_credito', 'solicitar_credito', 'validar_sesion', 'verificar_correo', 'vista_balance', 'vista_cdts', 'vista_creditos', 'vista_dashboard', 'vista_historial', 'vista_perfil'))
        AND NOT EXISTS (SELECT 1 FROM pg_proc p
                         WHERE p.pronamespace = 'public'::regnamespace
                           AND p.proname IN ('abonar_credito', 'activar_descuento_automatico', 'admin_ajustar_balance', 'admin_bloquear', 'admin_borrar_usuario', 'admin_desbloquear', 'admin_detalle_usuario', 'admin_esquema', 'admin_get_reloj', 'admin_get_tasas', 'admin_listar_usuarios', 'admin_set_reloj', 'admin_set_tasa_cdt', 'admin_set_tasa_credito', 'admin_set_tasa_mora', 'admin_tabla', 'crear_bolsillo', 'crear_cdt', 'hacer_transferencia', 'listar_cdt_definiciones', 'mover_a_bolsillo', 'mover_entre_bolsillos', 'nombre_destinatario', 'obtener_credenciales', 'pagar_cuota', 'productos_disponibles', 'productos_publicos', 'registrar_usuario', 'retirar_de_bolsillo', 'simular_cdt', 'simular_credito', 'solicitar_credito', 'validar_sesion', 'verificar_correo', 'vista_balance', 'vista_cdts', 'vista_creditos', 'vista_dashboard', 'vista_historial', 'vista_perfil')
                           AND has_function_privilege('banco_lector', p.oid, 'EXECUTE'))),
       'funciones de public ejecutables por banco_app: '
         || coalesce((SELECT string_agg(p.proname, ', ' ORDER BY p.proname COLLATE "C") FROM pg_proc p
                       WHERE p.pronamespace = 'public'::regnamespace
                         AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
                         AND has_function_privilege('banco_app', p.oid, 'EXECUTE')), 'ninguna')
UNION ALL
-- 8) E10: la vista del historial mira a TODOS los usuarios: banco_app no la lee (recibe los datos por vista_historial/vista_dashboard, que filtran por su cuenta); banco_lector sí
SELECT 'banco_app NO tiene SELECT sobre v_transaccion_usuario (mira a todos los usuarios) y banco_lector si',
       -- la vista DEBE existir: si desaparece el control FALLA (to_regclass IS NULL => ok = FALSE); sin ella no hay nada que proteger pero tampoco historial que entregar
       coalesce(to_regclass('public.v_transaccion_usuario') IS NOT NULL
                AND NOT has_table_privilege('banco_app', to_regclass('public.v_transaccion_usuario'), 'SELECT')
                AND has_table_privilege('banco_lector', to_regclass('public.v_transaccion_usuario'), 'SELECT'), false),
       'v_transaccion_usuario: SELECT banco_app = ' || coalesce(has_table_privilege('banco_app', to_regclass('public.v_transaccion_usuario'), 'SELECT')::text, 'VISTA AUSENTE')
ORDER BY 1;
COMMENT ON VIEW public.v_integridad_defensas IS
  'E2 (I9). Una fila por control de seguridad: triggers esperados activos (y diferidos los ct_*), event triggers, SECURITY DEFINER/INVOKER, permisos del dueño y de banco_ledger, roles NOLOGIN sin miembros, funciones internas sin EXECUTE; E3: reloj; E4-E12: banco_app ejecuta exactamente las 40 funciones públicas (autenticación, registro, transferencias, bolsillos, CDT, créditos, pagos, vistas, las 12 admin_* de administración y las 2 del visor Control); E10: banco_app no tiene SELECT sobre v_transaccion_usuario (mira a todos los usuarios), banco_lector sí, y la vista debe existir. ok=FALSE = una defensa desapareció.';

-- ----------------------------------------------------------------------------
-- E4 (I10): invariantes de registro y referidos
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_integridad_auth AS
SELECT 'usuarios: todo CLIENTE tiene su cuenta y ningun ADMIN tiene cuenta'::text AS control,
       (x.clientes_sin_cuenta = 0 AND x.admins_con_cuenta = 0) AS ok,
       x.clientes_sin_cuenta || ' clientes sin cuenta; ' || x.admins_con_cuenta || ' cuentas de no-clientes' AS detalle
  FROM (SELECT (SELECT count(*) FROM public.usuario u
                 WHERE u.rol = 'CLIENTE' AND NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.usuario_id = u.id)) AS clientes_sin_cuenta,
               (SELECT count(*) FROM public.cuenta c JOIN public.usuario u ON u.id = c.usuario_id WHERE u.rol <> 'CLIENTE') AS admins_con_cuenta) x
UNION ALL
SELECT 'referidos: bono_referido_pagado equivale a exactamente UN grupo BONO_REFERIDO en la cuenta del referidor con la cuenta del referido',
       (count(*) FILTER (WHERE (r.pagado AND r.bonos <> 1) OR (NOT r.pagado AND r.bonos <> 0)) = 0),
       count(*) FILTER (WHERE (r.pagado AND r.bonos <> 1) OR (NOT r.pagado AND r.bonos <> 0)) || ' referidos con desvio de ' || count(*) || ' revisados'
  FROM (SELECT u.bono_referido_pagado AS pagado,
               (SELECT count(*) FROM public.transaccion t
                 WHERE t.tipo = 'BONO_REFERIDO' AND t.contenedor = 'CUENTA' AND t.cuenta_id = rc.id
                   AND t.contraparte_cuenta = uc.numero_cuenta) AS bonos
          FROM public.usuario u
          JOIN public.cuenta uc ON uc.usuario_id = u.id
          JOIN public.cuenta rc ON rc.usuario_id = u.referido_por) r;
COMMENT ON VIEW public.v_integridad_auth IS
  'E4 (I10). Una fila por control: (1) todo CLIENTE tiene cuenta y ningún ADMIN la tiene; (2) cada referido con referidor vivo tiene exactamente un grupo BONO_REFERIDO (en la cuenta del referidor, con la cuenta del referido como contraparte) si y solo si bono_referido_pagado. ok=FALSE detecta un cliente sin cuenta, un bono pagado dos veces o una bandera sin pago. (Un referidor borrado deja referido_por NULL: ya no hay nada que comprobar.)';

-- ----------------------------------------------------------------------------
-- E8: el plan de cuotas de cada crédito cuadra con su capital pendiente (la misma regla que ct_credito_plan, D-E8-9 v1.1)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_integridad_creditos AS
SELECT k.id AS credito_id, k.cuenta_id, k.estado::text AS estado, k.capital_pendiente::numeric AS capital_pendiente,
       coalesce(sum(q.capital_programado - q.capital_pagado) FILTER (WHERE NOT q.pagada), 0)::numeric AS capital_plan_impago,
       k.capital_pendiente::numeric - coalesce(sum(q.capital_programado - q.capital_pagado) FILTER (WHERE NOT q.pagada), 0)::numeric AS diferencia,
       (k.capital_pendiente::numeric = coalesce(sum(q.capital_programado - q.capital_pagado) FILTER (WHERE NOT q.pagada), 0)::numeric) AS ok
  FROM public.credito k
  LEFT JOIN public.cuota q ON q.credito_id = k.id
 GROUP BY k.id, k.cuenta_id, k.estado, k.capital_pendiente;
COMMENT ON VIEW public.v_integridad_creditos IS
  'E8 (D-E8-9 v1.1). Por crédito: capital_pendiente (acumulador del libro) frente a Σ (capital_programado - capital_pagado) de sus cuotas impagas. ok=FALSE indica un plan que no explica la deuda. La misma regla que el trigger diferido ct_credito_plan (esta vista la detecta aunque un superusuario lo haya desactivado).';

-- ----------------------------------------------------------------------------
-- I5g y resumen
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_integridad_global AS
SELECT z.*,
       (z.transf_neto_vivos + z.transf_neto_borrados) AS desvio_transferencias,
       (z.contenedores_con_desvio = 0 AND z.grupos_con_error = 0 AND z.cuentas_con_desvio_i5u = 0
        AND z.defensas_fallidas = 0 AND z.transf_neto_vivos + z.transf_neto_borrados = 0
        AND (SELECT count(*) FROM public.v_integridad_auth WHERE NOT ok) = 0
        AND (SELECT count(*) FROM public.v_integridad_creditos WHERE NOT ok) = 0) AS ok,
       (SELECT count(*) FROM public.v_integridad_auth WHERE NOT ok) AS controles_auth_fallidos,      -- E4 (columna agregada al final)
       (SELECT count(*) FROM public.v_integridad_creditos WHERE NOT ok) AS creditos_con_plan_incoherente   -- E8 (columna agregada al final)
  FROM (
    SELECT (SELECT count(*) FROM public.cuenta)                                         AS cuentas,
           (SELECT count(*) FROM public.transaccion)                                    AS patas,
           (SELECT count(DISTINCT grupo_id) FROM public.transaccion)                    AS grupos,
           (SELECT count(*) FROM public.v_integridad_saldos   WHERE NOT ok)             AS contenedores_con_desvio,
           (SELECT count(*) FROM public.v_integridad_grupos   WHERE NOT ok)             AS grupos_con_error,
           (SELECT count(*) FROM public.v_integridad_grupos   WHERE estado = 'HUERFANO_POR_BORRADO') AS grupos_huerfanos_por_borrado,
           (SELECT count(*) FROM public.v_integridad_grupos   WHERE estado = 'SIN_PLANTILLA_CREDITO') AS grupos_credito_sin_plantilla,
           (SELECT count(*) FROM public.v_integridad_usuario  WHERE NOT ok)             AS cuentas_con_desvio_i5u,
           (SELECT count(*) FROM public.v_integridad_defensas WHERE NOT ok)             AS defensas_fallidas,
           (SELECT coalesce(sum(transf_neto), 0) FROM public.v_integridad_usuario)      AS transf_neto_vivos,
           (SELECT coalesce(sum((e.antes ->> 'transf_neto')::numeric), 0)
              FROM audit.evento e WHERE e.accion = 'CUENTA_BORRADA')                    AS transf_neto_borrados,
           (SELECT count(*) FROM audit.evento e WHERE e.accion = 'CUENTA_BORRADA')      AS cuentas_borradas
  ) z;
COMMENT ON VIEW public.v_integridad_global IS
  'E2 (I5g y resumen). Una fila: conteos, desvíos de saldos, grupos con error, desvíos I5u, defensas caídas y conservación del dinero entre clientes (transferencias netas de cuentas vivas + de cuentas borradas auditadas = 0). ok=TRUE si todo está en orden.';

RESET ROLE;

-- Lectura para banco_lector (y banco_dev por herencia). banco_app NO las ve. -------------------------------
GRANT SELECT ON public.v_integridad_saldos, public.v_integridad_grupos, public.v_integridad_usuario, public.v_integridad_auth,
                public.v_integridad_defensas, public.v_integridad_global, public.v_integridad_creditos TO banco_lector;

COMMIT;
