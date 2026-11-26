# Etapa 1 — Esquema y permisos · paquete de entrega

**Estado:** ✅ **APROBADA por el responsable de BD (2026-11-21)** — estructura, restricciones, índices, permisos, 349 pruebas, pruebas de mutación y verificación en pgAdmin; desviaciones del diseño aceptadas. Siguiente: [E2 — Libro mayor (diseño)](02-libro-mayor-diseno.md). **Sin commits** (todo está sin versionar en `feat/db-core`). No se tocó `front/`, backend, `docs/specs`, `docs/superpowers` ni archivos de otros integrantes. No hay funciones de negocio, triggers del libro mayor ni nada de etapas posteriores. No se tomó ninguna decisión financiera.

El diseño aprobado está en [01-esquema-diseno.md](01-esquema-diseno.md) (ya actualizado con las correcciones de abajo).

## 1. Correcciones de tu revisión aplicadas

| Tema | Qué se hizo |
|---|---|
| **M4 — nombre de bolsillo único** | Se verificó en el spec (§5 lista `bolsillo` sin UNIQUE; §7.4 dice "varios, con nombre propio"), en el contrato (§3.3, §5) y en el mock (solo rechaza el nombre *vacío*). **Nada lo exige → no se implementó.** Se permiten nombres duplicados y hay prueba positiva que lo demuestra (y una prueba de mutación: agregar ese UNIQUE hace fallar la suite). Solo queda `ck_bolsillo_nombre_no_vacio`. |
| **A — CLIENTE–CUENTA** | Documentado en el diseño, en `03_schema.sql` y en los `COMMENT` de la BD: el esquema garantiza **como máximo una cuenta por usuario y solo para CLIENTE** (UNIQUE + FK compuesta), **no** que todo CLIENTE tenga cuenta. La existencia la garantizará `registrar_usuario` (E4) creando usuario y cuenta en una misma transacción. Una prueba lo deja explícito: *"el esquema NO obliga a que un CLIENTE tenga cuenta"*. |
| **B — `banco_lector` y `password_hash`** | `05_permisos.sql` **no** concede `SELECT` de tabla sobre `usuario`: concede `SELECT` **columna por columna** (las 15 columnas legibles), sin `password_hash`. Pruebas positivas y negativas abajo (§3.4). |
| **C — libro mayor** | Los CHECK de `transaccion` validan **cada fila** (matriz de 37 combinaciones, ids por familia, saldos, monto). **No** hay cuadre de grupos (es de E2): una prueba muestra que una pata suelta se acepta y que ese grupo queda descuadrado, a modo de frontera documentada. |

## 2. Qué contiene

| Archivo | Qué hace |
|---|---|
| `db/sql/01_roles.sql` | Roles `banco_owner`, `banco_ledger` (NOLOGIN), `banco_app`, `banco_lector`, `banco_dev` (LOGIN, contraseñas **de desarrollo local**); límites de sesión; membresías; `CONNECT`; privilegios por defecto (funciones no ejecutables por PUBLIC) |
| `db/sql/02_tipos_dominios.sql` | Dominios `dinero` y `porcentaje`; 7 enumerados |
| `db/sql/03_schema.sql` | 11 tablas en `public` + `audit.evento`, con 88 restricciones de tabla (más 2 de dominio) y `COMMENT` en cada tabla y columna; filas únicas de `reloj` y `parametro` |
| `db/sql/04_indices.sql` | 14 índices de aplicación |
| `db/sql/05_permisos.sql` | Permisos (converge al estado correcto) |
| `db/tests/helpers.sql` | + `assert_ok`, `assert_violates` (exige el **nombre exacto** de la restricción), `huella_catalogo` |
| `db/tests/02…09_*.test.sql` | 8 archivos de prueba nuevos (§3) |
| `db/docker/pgadmin/servers.json`, `db/compose.dev.yml` | pgAdmin registra 4 conexiones (admin, `banco_dev`, `banco_app`, `banco_lector`) |
| `db/ctl.ps1` / `ctl.sh` | Comando nuevo `pgadmin-servers` (M10): registra las conexiones sin recrear el volumen |

Los cinco scripts son **idempotentes**, **transaccionales** (`BEGIN … COMMIT`; el rol de trabajo se restablece solo) y **no usan metacomandos de `psql`**: se ejecutan tal cual desde el Query Tool de pgAdmin. Se ejecutan como superusuario y crean los objetos con `SET LOCAL ROLE banco_owner`, así que **el dueño de todo es `banco_owner`**.

## 3. Resultados de las pruebas

**`db\ctl.ps1 test` → 349 passed, 0 failed** (log en `docs/db/evidencias/01-esquema.txt`).

| Archivo | Aserciones | Qué demuestra |
|---|---:|---|
| `00_smoke`, `01_entorno` (E0) | 16 + 16 | runner y entorno (el smoke creció de 12 a 16 por los helpers nuevos) |
| `02_roles` | 25 | 5 roles, atributos, contraseñas SCRAM, límites, membresías, `CONNECT`, PUBLIC sin privilegios, funciones nuevas no ejecutables por PUBLIC |
| `03_schema` | 25 | **exactamente 11 tablas en `public` y solo `evento` en `audit`**; sin funciones ni triggers; dueños; comentarios en todo; `audit` sin FKs; dominios y 7 enumerados exactos |
| `04_restricciones` | 122 | cada UNIQUE, CHECK, FK y NOT NULL de cada tabla, positivo y negativo, con el nombre exacto de la restricción |
| `05_libro_mayor` | 39 | la matriz contable completa (**37 permitidas entran, 133 prohibidas se rechazan**), `lado` generado, `orden`, saldos, ids por familia, frontera con E2 |
| `06_borrados` | 20 | eliminación completa de un usuario; protección de movimientos; `SET NULL` |
| `07_indices` | 16 | 14 índices con su definición, índice único parcial, **toda FK con índice de soporte**, PK en toda tabla |
| `08_permisos` | 59 | `password_hash`, matriz de privilegios, intentos reales por rol, `banco_ledger` |
| `09_idempotencia` | 11 | 3 aplicaciones → misma huella del catálogo; datos conservados; el script corrige una desviación |

### 3.1 Eliminación completa de un usuario con productos y transacciones
Escenario: A (cuenta, 2 bolsillos, CDT, crédito con 2 cuotas, 7 movimientos) refiere a B y le transfiere dinero. Un solo `DELETE FROM usuario` de A **tiene éxito** (la cascada pasa por las FK `NO ACTION` del libro sin bloquearse) y deja: de A, **nada** (usuario, cuenta, bolsillos, CDT, créditos, cuotas, movimientos); de B, su cuenta, su bolsillo y su `RECIBO` intactos con la contraparte guardada **como texto**; `B.referido_por = NULL`; la auditoría de A **sobrevive**; los catálogos no se tocan.

### 3.2 Protección de los movimientos históricos
`DELETE` individual de un **bolsillo**, un **CDT** o un **crédito** con movimientos → rechazado por `fk_transaccion_bolsillo` / `fk_transaccion_cdt` / `fk_transaccion_credito` (y el rechazo es completo: las cuotas siguen ahí). Un bolsillo **sin** movimientos sí se puede borrar. Un producto de crédito con créditos no se puede borrar.

### 3.3 Cuentas para ADMIN
Imposibles por tres vías, todas probadas: cuenta con `rol` por defecto para un ADMIN → `fk_cuenta_usuario`; forzar `rol = 'ADMIN'` en la cuenta → `ck_cuenta_rol_cliente`; cambiar a ADMIN el rol de un cliente con cuenta → `fk_cuenta_usuario`.

### 3.4 Protección de `password_hash`
- Catálogo: `banco_lector` **no** tiene `SELECT` de tabla sobre `usuario`; tiene `SELECT` en exactamente 15 de las 16 columnas; la única ilegible es `password_hash`.
- **Positivas:** lee `username, nombres, cedula, estado, rol`; lee las 15 columnas de una vez; cuenta y filtra por columnas permitidas; `banco_dev` (vía lector) también.
- **Negativas (todas `permission denied for table usuario`, SQLSTATE 42501):** `SELECT password_hash`, `SELECT *`, `WHERE password_hash …`, `ORDER BY password_hash`, `to_jsonb(u)`, subconsulta/JOIN que alcance la columna, `UPDATE` de la columna; `banco_app` no lee **ni** las columnas permitidas.
- **Verificado también en pgAdmin** conectado como `banco_lector`: `SELECT password_hash FROM public.usuario` → `ERROR: permission denied for table usuario · SQL state: 42501`.

### 3.5 Pruebas de mutación (¿detectan las pruebas un esquema roto?)
Se rompió a propósito una cosa a la vez (matriz, permisos de `password_hash`, FK del libro, subtipo, índice único parcial, UNIQUE no solicitado, columna generada, trigger…): **12 de 12 mutaciones detectadas** (`docs/db/evidencias/01-esquema-mutaciones.txt`).

### 3.6 Idempotencia
`ctl apply` sobre `banco` **desde cero** (`reset` + 3 aplicaciones): 0 líneas de error en las tres (`docs/db/evidencias/01-esquema-aplicacion.txt`). Además `09_idempotencia` compara una **huella md5 del catálogo** (tablas, columnas, restricciones, índices, tipos, dueños, privilegios, roles, comentarios) tras 1, 2 y 3 aplicaciones: idéntica.

### 3.7 Autenticación
Contraseñas verificadas con una conexión TCP que sí exige `scram-sha-256` (`docs/db/evidencias/01-esquema-login.txt`): las 3 correctas entran; una incorrecta, una cruzada y `banco_owner`/`banco_ledger` fallan. *(Nota: dentro del contenedor `127.0.0.1` es `trust`; por eso se probó por el nombre de host `db`.)*

## 4. Comprobación de las 11 tablas
Sobre la BD `banco` (`docs/db/evidencias/01-esquema-aplicacion.txt`): `public` = **11** tablas (`bolsillo, cdt, cdt_definicion, credito, credito_producto, cuenta, cuota, parametro, reloj, transaccion, usuario`) y `audit` = **1** (`evento`). Además `pg_tables` de `public` = 11 y de `audit` = `evento` (consulta directa).

## 5. Cómo verificarlo desde pgAdmin

### 5.1 Preparación (una vez)
```powershell
db\ctl.cmd up
db\ctl.cmd apply          # aplica 00..05 a la BD banco (también se puede desde pgAdmin, ver 5.2)
db\ctl.cmd pgadmin-servers   # registra las conexiones nuevas (si ya tenías pgAdmin abierto de la E0)
```
Abre <http://localhost:5050>. En **Banco Digital** verás 4 servidores: *administración (postgres)*, *banco_dev*, *banco_app* y *banco_lector*. Para conectar uno: selecciónalo y *Object → Connect Server* (no pide contraseña). Los servidores nuevos se registran con `pgadmin-servers`; si tenías pestañas del Query Tool abiertas de la E0, ciérralas (apuntan a servidores reemplazados).

### 5.2 Aplicar los scripts desde el Query Tool (alternativa a `ctl apply`)
Conéctate como **administración (postgres)** → clic en la BD `banco` → *Tools → Query Tool* → icono de carpeta (*Open File*) → ruta `/work/sql/` → abre y ejecuta con **F5**, **en orden**: `01_roles.sql`, `02_tipos_dominios.sql`, `03_schema.sql`, `04_indices.sql`, `05_permisos.sql` (el `00_extensiones.sql` ya estaba de la E0). Cada uno termina con `COMMIT`; ejecutarlo de nuevo no da error. *Si un script fallara a la mitad, pgAdmin deja la transacción abortada: ejecuta `ROLLBACK;` y repite.*

### 5.3 Tablas, columnas y documentación
- Árbol: **Servers → … → Databases → banco → Schemas → public → Tables** (11) y **Schemas → audit → Tables** (1: `evento`). Refresca con clic derecho → *Refresh*.
- Clic en una tabla → pestaña **Properties** (comentario) y **Columns** (cada columna con su tipo y comentario); pestaña **Constraints** lista PK/FK/UNIQUE/CHECK con sus nombres (`pk_*`, `uq_*`, `fk_*`, `ck_*`); **Indexes** los índices.
- Diagrama: con la BD `banco` seleccionada, *Tools → ERD Tool* permite dibujar las tablas y sus FK (incluidas `usuario.referido_por` y la FK compuesta `cuenta → usuario(id, rol)`).
- Consulta (Query Tool sobre `banco`):
```sql
SELECT table_schema, table_name FROM information_schema.tables
 WHERE table_schema IN ('public','audit') AND table_type = 'BASE TABLE' ORDER BY 1, 2;   -- 11 en public, 1 en audit
SELECT c.relname AS tabla, obj_description(c.oid, 'pg_class') AS comentario
  FROM pg_class c WHERE c.relnamespace IN ('public'::regnamespace, 'audit'::regnamespace) AND c.relkind = 'r' ORDER BY 1;
```

### 5.4 Restricciones
```sql
SELECT conrelid::regclass AS tabla, conname AS restriccion,
       CASE contype WHEN 'p' THEN 'PK' WHEN 'u' THEN 'UNIQUE' WHEN 'f' THEN 'FK' WHEN 'c' THEN 'CHECK' END AS tipo,
       pg_get_constraintdef(oid) AS definicion
  FROM pg_constraint WHERE connamespace IN ('public'::regnamespace, 'audit'::regnamespace) AND conrelid <> 0
 ORDER BY 1::text, 3, 2;
-- la matriz contable completa de transaccion:
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'ck_transaccion_tipo_contenedor_sentido';
```
Prueba una violación a mano (con el servidor *administración*; es una transacción que se deshace):
```sql
BEGIN;
INSERT INTO public.usuario (username,password_hash,nombres,apellidos,cedula,correo,telefono,fecha_nacimiento,rol)
VALUES ('admin9','h','A','B','900000001','admin9@x.co','3100000009','1990-01-01','ADMIN') RETURNING id;   -- anota el id
-- INSERT INTO public.cuenta (usuario_id, numero_cuenta) VALUES ('<ese id>', '4000000009');            -- ← falla: fk_cuenta_usuario
ROLLBACK;
```

### 5.5 Índices
```sql
SELECT tablename, indexname, indexdef FROM pg_indexes WHERE schemaname IN ('public','audit') ORDER BY 1, 2;   -- 40 (14 ix_*, 1 uq_credito_vivo_*, y los de PK/UNIQUE)
```

### 5.6 Roles y permisos
```sql
SELECT rolname, rolcanlogin, rolsuper, rolconfig FROM pg_roles WHERE rolname LIKE 'banco\_%' ORDER BY 1;
SELECT r.rolname AS miembro_de, m.rolname AS rol FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.roleid JOIN pg_roles m ON m.oid = am.member WHERE m.rolname LIKE 'banco\_%';
SELECT grantee, table_name, privilege_type FROM information_schema.table_privileges WHERE table_schema IN ('public','audit') AND grantee LIKE 'banco\_%' ORDER BY 2, 1, 3;
SELECT grantee, column_name, privilege_type FROM information_schema.column_privileges WHERE table_name = 'usuario' AND grantee LIKE 'banco\_%' ORDER BY 1, 2;   -- lector: 15 columnas, sin password_hash
```
**Prueba en vivo de los permisos** (cambia de servidor en el árbol y abre un Query Tool en cada uno):
| Conectado como | Ejecuta | Esperado |
|---|---|---|
| **banco_lector** | `SELECT username, estado FROM public.usuario;` | funciona |
| **banco_lector** | `SELECT password_hash FROM public.usuario;` | `ERROR: permission denied for table usuario` (42501) |
| **banco_lector** | `INSERT INTO public.parametro (id) VALUES (2);` | `permission denied for table parametro` |
| **banco_app** | `SELECT * FROM public.cuenta;` | `permission denied for table cuenta` |
| **banco_app** | `SELECT * FROM audit.evento;` | `permission denied for schema audit` |
| **banco_dev** | `SELECT count(*) FROM public.cuenta;` y luego `UPDATE public.cuenta SET balance = 0;` | el primero funciona; el segundo `permission denied` |
| **administración (postgres)** | `SET ROLE banco_ledger; UPDATE public.cuenta SET numero_cuenta = '0';` y luego `RESET ROLE;` | `permission denied for table cuenta` (solo `balance` es actualizable por el ledger) |

### 5.7 Pruebas automáticas
```powershell
db\ctl.cmd test -Evidence 01-esquema      # 349 passed, 0 failed
db\ctl.cmd test 05                        # solo el libro mayor (la matriz contable)
db\ctl.cmd test 08                        # solo permisos (password_hash)
```

## 6. Decisiones menores aplicadas (M1–M12) y desviaciones del diseño
- **M4** no implementada (ver §1). El resto de M1–M12 aplicada tal como se aprobó.
- Se **eliminó `ck_transaccion_ids_por_contenedor`** (era redundante con la matriz y los tres CHECK de familia: la suite lo comprueba) y los CHECK de familia incluyen `BOLSO_* ⇒ bolsillo_id`, más una regla para `ENVIO` (lleva `bolsillo_id` si y solo si sale de un bolsillo).
- **Índices** `ix_cdt_cuenta_estado` y `ix_credito_cuenta_estado` son `(cuenta_id, estado)` **no parciales** (el diseño decía parciales `WHERE estado='ACTIVO'`): así también sirven al borrado en cascada de CDT/créditos cerrados. La suite exige que **toda FK tenga un índice de soporte**.
- **`01_roles.sql` también concede `USAGE, CREATE` sobre `public` a `banco_owner`** (el diseño lo ponía en 05): hace falta antes de crear objetos con ese rol.
- Se añadieron `bolsillo.nombre` no vacío y `ck_cdt_ultimo_cobro` (`ultimo_cobro ≥ fecha_inicio`), invariantes de estructura sin carga financiera.
- Cambió el **orden de los archivos de prueba** respecto del diseño (8 archivos por tema en vez de 3).

## 7. Observaciones y límites (honestidad)
- **`db_zip.zip` en la raíz del repo**: apareció sin versionar en `git status` al cerrar E1 (`evidencias/git_status_e1.txt`); **no lo creé yo** y no lo toqué. En la revisión posterior (2026-11-21) **ya no existe** en el disco ni en `git status` (`evidencias/git_status_revision_e1.txt`): lo quitó alguien ajeno a este trabajo. Nada versionado cambió.
- Las contraseñas de `banco_app`, `banco_dev` y `banco_lector` son **literales de desarrollo** en `01_roles.sql` (M1, aprobado); cada reaplicación del script las restablece a esos valores. Los puertos solo se publican en `127.0.0.1`.
- Las **pruebas corren como superusuario** y cambian de rol con `SET LOCAL ROLE`; no hay prueba automática de la **sesión real** de `banco_app`/`banco_lector` salvo la autenticación TCP (§3.7) y la prueba manual de `banco_lector` en pgAdmin. Los límites de sesión (`ALTER ROLE … SET`) se verifican en el catálogo y valen para sesiones **nuevas**.
- La **guardia de saldos** (`current_user = 'banco_ledger' AND pg_trigger_depth() > 1`), el cuadre diferido de grupos, la inmutabilidad del libro y el event trigger **no existen aún**: son de E2. Hoy un superusuario puede escribir saldos sin restricción (esperado en E1).
- `usuario.creado_en`, `cuenta.creado_en`, `bolsillo.creado_en` y `audit.evento.fecha` usan `now()` "técnico" (M12) hasta que existan las funciones con el reloj del banco (E3).
- El `COMMENT ON SCHEMA public` pisa el comentario por defecto de PostgreSQL.
- pgAdmin 9.19: `pgadmin-servers` usa `--replace`, así que **recrea los servidores** (nuevos ids) y descarta pestañas guardadas de los anteriores.

## 8. Checklist de lo que pediste
| Pedido | Estado |
|---|---|
| 5 scripts idempotentes y ejecutables desde pgAdmin | ✅ (3 aplicaciones sin error; huella idéntica; sin metacomandos) |
| Eliminación completa de usuario con productos y movimientos | ✅ §3.1 |
| Protección de movimientos frente a borrados individuales | ✅ §3.2 |
| Imposibilidad de cuentas para ADMIN | ✅ §3.3 |
| Integridad de la matriz contable (37 sí / 133 no) | ✅ §3 `05_libro_mayor` |
| Protección de `password_hash` (permiso por columna) | ✅ §3.4 |
| Idempotencia | ✅ §3.6 |
| M4 verificado antes de implementar | ✅ no implementada |
| A, B y C documentadas | ✅ §1 |
| Exactamente 11 tablas en `public` y `audit.evento` | ✅ §4 |
| Instrucciones de verificación en pgAdmin | ✅ §5 |
| No tocar front/backend, sin commits, sin E2 | ✅ |
