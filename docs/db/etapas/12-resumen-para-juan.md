# Etapa 12 — Control (visor de la BD) · resumen para el backend

**Aviso:** el backend actual de `origin/main` es un borrador temporal y **no es fuente de autoridad**; este resumen describe **la BD terminada** y el contrato. Cuando se desarrolle el backend definitivo, contrasta todo contra el contrato, `types.ts` y esta BD.

Dos funciones (con **`p_admin_id` primero**, el de la sesión; la BD vuelve a verificar que sea un **ADMIN activo** antes de leer nada) que devuelven **`jsonb`**. Los errores de negocio llegan como `P0001` con el mensaje exacto → **400** con ese texto (`Acceso denegado` → **403**); cualquier otro error sigue siendo 503.

| Endpoint | Llamada | Devuelve |
|---|---|---|
| `GET /admin/esquema` (y el **ping** de conexión cada 5 s) | `admin_esquema(admin)` | `{ tablas: [{ nombre, columnas: [{ nombre, tipo, llave, unico, no_nulo }], fks: [{ columna, tabla_destino, columna_destino }] }] }` — las **11 tablas** en el orden del grafo |
| `GET /admin/tabla/:nombre?pagina=N` | `admin_tabla(admin, nombre text, pagina text)` | `{ columnas: string[], filas: object[], pagina, total_paginas }` — **50 filas por página** |

* **`pagina` va como TEXTO tal cual llegue del query-string** (`q.query.pagina`, ausente = `NULL` o `1`): `NULL`, vacío, no numérico o `< 1` = página 1; cualquier entero positivo mayor que el total, **de cualquier longitud** (`1000000000`, 30 cifras…), = **la última** (la respuesta trae la página efectiva). Nunca falla por un valor raro ni desborda.
* **Lista blanca exacta** de las 11 tablas (`usuario, cuenta, bolsillo, cdt_definicion, cdt, credito_producto, credito, cuota, transaccion, reloj, parametro`): cualquier otra cosa (otro esquema, `audit.evento`, mayúsculas, `NULL`…) = **`Tabla no permitida`** (400). El nombre se valida **después** del administrador: un cliente recibe `Acceso denegado`, no sondea la lista.
* **`usuario.password_hash` sale siempre como `••••`**: el hash real nunca viaja. Nada más se enmascara (D-E12-D1, provisional del equipo).
* **Solo lectura y barato:** ambas son `STABLE` (la BD impide que escriban), no corren el motor de devengo y no auditan. **Muestran lo guardado, no lo derivado** (los saldos no incluyen intereses pendientes hasta que alguien opere). El `esquema` consulta solo `pg_catalog`: úsalo de ping sin miedo (12 llamadas por minuto por pestaña). No esperan al reloj ni a los bloqueos de cuentas.
* **Filas:** todas las columnas de la tabla; dinero como **número**, fechas ISO con zona de Bogotá (`-05:00`), uuid como texto; `transaccion.tx_id` (tipo `xid8`) sale como **texto**. Orden: lo más reciente primero (`transaccion` por `orden`, `usuario`/`cuenta`/`bolsillo` por `creado_en`, `cdt` por `fecha_inicio`, `credito` por `fecha_desembolso`).
* **`tipo`** del esquema es el tipo literal de PostgreSQL (`uuid`, `dinero`, `porcentaje`, `timestamp with time zone`, `estado_usuario`…); **`unico`** = `UNIQUE` de **una** columna (los compuestos no se marcan, la clave primaria va en `llave`); la FK **compuesta** de `cuenta` sale **una vez** (`usuario_id → id`).
* **Cambios del front que se desprenden** (el mock está obsoleto): páginas de **50** (el mock usa 10) y mensaje **`Tabla no permitida`** (el mock dice `Tabla no encontrada`).

**Decisiones provisionales del equipo:** D-E12-D1 (solo se enmascara `password_hash`; cédula, correo y teléfono salen) y D-E12-D2 (`audit.evento` no se muestra en Control). D10: `pagina` como texto.
