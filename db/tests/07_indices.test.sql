-- 07_indices.test.sql · Etapa 1 · indices: existen, son parciales/unicos donde corresponde y cada FK tiene soporte.

-- Los 14 indices no unicos de 04_indices.sql ----------------------------------------------------------------
SELECT assert_eq('indices de aplicacion (ix_*): exactamente los 14 previstos',
                 (SELECT array_agg(indexname::text ORDER BY indexname) FROM pg_indexes
                   WHERE schemaname IN ('public','audit') AND indexname LIKE 'ix\_%'),
                 ARRAY['ix_bolsillo_cuenta','ix_cdt_cuenta_estado','ix_cdt_definicion','ix_credito_cuenta_estado','ix_credito_producto',
                       'ix_cuota_pendiente','ix_evento_entidad','ix_evento_fecha','ix_transaccion_bolsillo','ix_transaccion_cdt',
                       'ix_transaccion_credito','ix_transaccion_cuenta_orden','ix_transaccion_grupo','ix_usuario_referidor']::text[]);

SELECT assert_true('historial: ix_transaccion_cuenta_orden es (cuenta_id, orden DESC)',
                   (SELECT indexdef LIKE '%(cuenta_id, orden DESC)' FROM pg_indexes WHERE indexname = 'ix_transaccion_cuenta_orden'));
SELECT assert_true('ix_transaccion_grupo es (grupo_id)', (SELECT indexdef LIKE '%(grupo_id)' FROM pg_indexes WHERE indexname = 'ix_transaccion_grupo'));
SELECT assert_true('ix_transaccion_bolsillo es parcial (bolsillo_id IS NOT NULL)',
                   (SELECT indexdef LIKE '%(bolsillo_id) WHERE (bolsillo_id IS NOT NULL)' FROM pg_indexes WHERE indexname = 'ix_transaccion_bolsillo'));
SELECT assert_true('ix_transaccion_cdt es parcial (cdt_id IS NOT NULL)',
                   (SELECT indexdef LIKE '%(cdt_id) WHERE (cdt_id IS NOT NULL)' FROM pg_indexes WHERE indexname = 'ix_transaccion_cdt'));
SELECT assert_true('ix_transaccion_credito es parcial (credito_id IS NOT NULL)',
                   (SELECT indexdef LIKE '%(credito_id) WHERE (credito_id IS NOT NULL)' FROM pg_indexes WHERE indexname = 'ix_transaccion_credito'));
SELECT assert_true('ix_cdt_cuenta_estado es (cuenta_id, estado)', (SELECT indexdef LIKE '%(cuenta_id, estado)' FROM pg_indexes WHERE indexname = 'ix_cdt_cuenta_estado'));
SELECT assert_true('ix_credito_cuenta_estado es (cuenta_id, estado)', (SELECT indexdef LIKE '%(cuenta_id, estado)' FROM pg_indexes WHERE indexname = 'ix_credito_cuenta_estado'));
SELECT assert_true('ix_cuota_pendiente es parcial (NOT pagada)',
                   (SELECT indexdef LIKE '%(credito_id, numero) WHERE (NOT pagada)' FROM pg_indexes WHERE indexname = 'ix_cuota_pendiente'));
SELECT assert_true('ix_usuario_referidor es parcial (referido_por IS NOT NULL)',
                   (SELECT indexdef LIKE '%(referido_por) WHERE (referido_por IS NOT NULL)' FROM pg_indexes WHERE indexname = 'ix_usuario_referidor'));
SELECT assert_true('ix_evento_fecha ordena por fecha DESC', (SELECT indexdef LIKE '%(fecha DESC)' FROM pg_indexes WHERE indexname = 'ix_evento_fecha'));

-- El indice unico parcial que implementa "un credito vivo por producto" ---------------------------------------
SELECT assert_true('uq_credito_vivo_por_producto es UNICO y parcial (estado = ACTIVO)',
                   (SELECT indexdef LIKE 'CREATE UNIQUE INDEX uq_credito_vivo_por_producto ON public.credito %(cuenta_id, producto_id) WHERE (estado = ''ACTIVO''::estado_credito)'
                      FROM pg_indexes WHERE indexname = 'uq_credito_vivo_por_producto'));

-- Todas las claves foraneas tienen un indice que empieza por su primera columna ------------------------------
SELECT assert_eq('toda FK del banco tiene un indice de soporte (primera columna) para joins y borrados en cascada',
                 (SELECT coalesce(string_agg(c.conname::text, ', ' ORDER BY c.conname), '(ninguna)')
                    FROM pg_constraint c
                   WHERE c.contype = 'f' AND c.connamespace IN ('public'::regnamespace, 'audit'::regnamespace)
                     AND NOT EXISTS (SELECT 1 FROM pg_index i
                                      WHERE i.indrelid = c.conrelid AND i.indisvalid
                                        AND i.indkey[0] = c.conkey[1])),
                 '(ninguna)'::text);

-- Salud de los indices -----------------------------------------------------------------------------------------
SELECT assert_eq('todos los indices son validos y pertenecen a banco_owner',
                 (SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname IN ('public','audit') AND (NOT i.indisvalid OR pg_get_userbyid(c.relowner) <> 'banco_owner')), 0::bigint);
SELECT assert_eq('cada tabla de public y audit tiene clave primaria',
                 (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname IN ('public','audit') AND c.relkind = 'r'
                     AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p')), 0::bigint);
SELECT assert_eq('todos los ids de entidad son uuid con gen_random_uuid() por defecto',
                 (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                   WHERE n.nspname IN ('public','audit') AND c.relkind = 'r' AND a.attname = 'id'
                     AND c.relname NOT IN ('reloj','parametro')
                     AND (a.atttypid <> 'uuid'::regtype OR pg_get_expr(d.adbin, d.adrelid) IS DISTINCT FROM 'gen_random_uuid()')), 0::bigint);
