# E1 - Verificación de permisos con los cuatro roles (psql y pgAdmin)

Fecha: 2026-11-21 · Rama `feat/db-core` · Base `banco` (vacía en E1: sin filas, sin funciones).

## Qué hay aquí

| Evidencia | Archivo |
|---|---|
| Estado de Git (`git status --short`) | `git_status_revision_e1.txt` (+ `git_status_revision_e1_detalle.txt`) |
| Consultas ejecutadas con los 4 roles (script) | `01-verificacion-roles.sql` |
| Salida completa de esas consultas con psql, por rol | `01-verificacion-roles-psql.txt` |
| Capturas de pgAdmin (7 imágenes, Query Tool con cada rol) | `capturas-pgadmin/` |

El script no está en las carpetas montadas en pgAdmin (`/work/sql`, `/work/tests`): copia y pega los bloques `[Tn]` en el Query Tool. Todo lo que escribe va dentro de `BEGIN … ROLLBACK`: tras la prueba `banco` sigue con 11 tablas en `public`, `audit.evento`, 0 filas y sin la tabla `intruso` (comprobado).

## Resultado: matriz de permisos (misma sentencia, cuatro roles)

Cada fila es una sentencia ejecutada **como ese rol** (conexión con su propia contraseña). 42501 = `permission denied`.

| Sentencia | postgres | banco_dev | banco_app | banco_lector |
|---|---|---|---|---|
| `SELECT * FROM cuenta` | permitido | permitido | **denegado 42501** | permitido |
| `SELECT * FROM usuario` | permitido | denegado 42501 | **denegado 42501** | denegado 42501 |
| `SELECT password_hash FROM usuario` | permitido | **denegado 42501** | **denegado 42501** | **denegado 42501** |
| `SELECT username FROM usuario` | permitido | permitido | **denegado 42501** | permitido |
| `UPDATE cuenta SET balance = balance + 1000000` | permitido | **denegado 42501** | **denegado 42501** | **denegado 42501** |
| `INSERT INTO transaccion DEFAULT VALUES` | error 23502 (NOT NULL) | denegado 42501 | **denegado 42501** | denegado 42501 |
| `DELETE FROM usuario` | permitido | denegado 42501 | **denegado 42501** | denegado 42501 |
| `TRUNCATE transaccion` | permitido | denegado 42501 | **denegado 42501** | denegado 42501 |
| `CREATE TABLE public.intruso` (solo psql) | permitido | denegado 42501 | denegado 42501 | denegado 42501 |
| `SELECT count(*) FROM audit.evento` (solo psql) | permitido | permitido | **denegado 42501** (schema audit) | permitido |

Fuente: `01-verificacion-roles-psql.txt` (sección `[T12]` de cada rol) y las capturas.

### Lo que se pidió demostrar

1. **`banco_app` no puede consultar ni modificar las tablas.** `SELECT`, `UPDATE`, `INSERT`, `DELETE`, `TRUNCATE`, `CREATE` y hasta `audit.evento` terminan en 42501. `[T2]` de psql lo confirma con `has_table_privilege`: 0 de 12 tablas con cualquiera de los 7 privilegios.
   Capturas: `banco_app-1-select-cuenta-denegado.jpg` (`ERROR: permission denied for table cuenta`, SQL state 42501), `banco_app-2-update-cuenta-denegado.jpg`, `banco_app-3-matriz-todo-denegado.jpg`.
2. **`banco_lector` no puede acceder a `password_hash`.** `SELECT password_hash`, `SELECT *`, `to_jsonb(u)` sobre `usuario` terminan en 42501; `SELECT username` sí funciona y `has_column_privilege` da `password_hash = f`, `username/correo/cedula = t` (`[T9]`).
   Capturas: `banco_lector-1-password_hash-denegado.jpg`, `banco_lector-2-matriz.jpg`.

## Cosas que conviene saber (para no malinterpretar las pruebas)

- **La base está vacía.** Las lecturas permitidas devuelven 0 filas. Las denegaciones **no dependen de que haya filas**: PostgreSQL valida privilegios al analizar la consulta. Cuando existan datos (E4 en adelante) conviene repetir estas pruebas.
- **`banco_lector` tiene dos capas.** Por defecto sus transacciones son de solo lectura (`default_transaction_read_only = on`, error 25006 si se intenta escribir). Para probar la segunda capa, la de **privilegios**, el script abre `BEGIN READ WRITE`; ahí las escrituras fallan con 42501. Ambas capas están activas.
- **`banco_dev` hereda de `banco_lector` y `banco_app`** (membresía diseñada en E1), por eso puede leer `cuenta` y `username`; no puede leer `password_hash` ni escribir nada. Es esperado.
- **`postgres` (superusuario) lo puede todo**: por eso solo se usa para aplicar DDL y en las pruebas sus escrituras van en `ROLLBACK`. El único error (23502 en el INSERT) es una restricción NOT NULL, no un permiso. No se pretende protegerse de un superusuario (límite honesto, ver diseño D.6).
- **Las capturas son del panel de navegador integrado de la app**, que es angosto: el editor muestra solo el final de cada script. La consulta completa está en `01-verificacion-roles.sql`; las capturas se hicieron con una versión compacta de la matriz (nombres de tabla sin `public.`, sin `current_user` en cada línea). El rol de cada pestaña se ve en el título (`banco/<rol>@Banco - …`) y en el primer `NOTICE: Rol: …`.
- En pgAdmin solo se conectaron los 4 servidores preregistrados con la contraseña de desarrollo del `pgpass` del contenedor; no se escribió ninguna contraseña en la interfaz.

## Reproducir

```powershell
db\ctl.cmd up
db\ctl.cmd psql -Sql "SELECT 1"
```

En pgAdmin: *Object → Connect Server* en cada una de las 4 conexiones, seleccionar la base `banco`, *Tools → Query Tool*, pegar el bloque `[T12]` de `01-verificacion-roles.sql` y pulsar F5; la pestaña *Messages* muestra una línea por sentencia.
