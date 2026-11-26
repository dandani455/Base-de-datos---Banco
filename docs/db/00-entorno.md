# Entorno de la base de datos: PostgreSQL 16 + pgAdmin 4

Este documento explica cómo levantar el entorno local de la capa de base de datos, conectarse con pgAdmin 4 y trabajar con los scripts SQL. El SQL versionado en `db/sql/` es la **fuente de verdad**; nada depende de que Docker lo ejecute solo.

## Requisitos

| Sistema | Necesitas | **No** necesitas |
|---|---|---|
| **Windows 10/11** (camino soportado) | Docker Desktop **en ejecución** (con Compose v2: `docker compose`) y Windows PowerShell 5.1 (viene instalado) o PowerShell 7 | Bash, Git Bash, WSL, `psql`, Node, Python |
| Linux / macOS / WSL / Git Bash (opcional) | Docker con `docker compose` y Bash. Se usa `db/ctl.sh` | — |

> **Git Bash o WSL solo hacen falta si prefieres `db/ctl.sh`.** En Windows todo funciona con `db\ctl.cmd` (o `db\ctl.ps1`).

## Primer uso (Windows)

Desde la raíz del repositorio:

```powershell
db\ctl.cmd up
```

Esto crea `db\.env` (valores de desarrollo, no secretos) si no existe, descarga las imágenes la primera vez y levanta:

| Servicio | Dirección | Notas |
|---|---|---|
| PostgreSQL 16 | `localhost:5433` (BD `banco`, usuario `postgres`) | Solo en `127.0.0.1`. El puerto es `DB_PORT` de `db\.env` (5433 para no chocar con un PostgreSQL local en 5432) |
| pgAdmin 4 (9.19.0) | <http://localhost:5050> | Modo escritorio: **sin pantalla de login** |

El arranque **solo** crea la BD `banco` vacía y le fija la zona horaria `America/Bogota`. **No crea el esquema.** Los objetos se aplican por etapas (más abajo).

### ¿Por qué `ctl.cmd` y no `ctl.ps1`?
Windows cliente trae la *ExecutionPolicy* `Restricted`, que bloquea cualquier `.ps1`. `ctl.cmd` lanza `ctl.ps1` con `-ExecutionPolicy Bypass` **solo para ese proceso** (no cambia la configuración del sistema). Si prefieres ejecutar `ctl.ps1` directo: `Set-Location db; Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

## Conectarte con pgAdmin 4

1. Abre <http://localhost:5050>. No pide usuario ni contraseña.
2. En el árbol izquierdo: **Banco Digital → Banco - administración (postgres)**. La conexión ya está registrada y la contraseña se resuelve sola (archivo `pgpass` generado dentro del contenedor desde `db\.env`).
3. Expande **Databases → banco**.
4. **Query Tool**: selecciona `banco` y pulsa `Alt+Shift+Q` (o *Tools → Query Tool*). Prueba:
   ```sql
   SELECT current_database() AS bd, current_setting('TimeZone') AS zona, now() AS ahora,
          (SELECT string_agg(extname, ', ' ORDER BY extname) FROM pg_extension) AS extensiones;
   ```
5. **Ejecutar un script del repositorio desde pgAdmin:** en el Query Tool pulsa el icono de carpeta (*Open File*), escribe en la ruta `/work/sql/` y pulsa Enter; abre el `.sql` y ejecútalo con **F5**. (`/work/sql` y `/work/tests` son los directorios `db/sql` y `db/tests` del repositorio montados en el contenedor, de solo lectura.)
6. Para **ver** lo que cree cada etapa, refresca el árbol (clic derecho → *Refresh*): *Schemas → public → Tables / Views / Functions / Triggers*, y la pestaña *Comments* de cada objeto muestra su documentación.

> Los archivos `db/sql/*.sql` no usan metacomandos de `psql` (`\i`, `\set`…) y son idempotentes: se pueden ejecutar desde pgAdmin tantas veces como quieras.

> Desde la Etapa 1 hay **4 conexiones** registradas: *administración (postgres)* (superusuario: úsala solo para aplicar DDL), *banco_dev* (explorar y, desde E3, probar funciones sin ser superusuario), *banco_app* (simula al backend: sin permisos sobre tablas) y *banco_lector* (solo lectura, sin `password_hash`). Para conectar una: selecciónala y *Object → Connect Server* (no pide contraseña). Si actualizas desde la E0, ejecuta `db\ctl.cmd up` (recrea pgAdmin con el nuevo `pgpass`) y luego `db\ctl.cmd pgadmin-servers`. Las contraseñas de los roles son de **desarrollo local** (definidas en `db/sql/01_roles.sql`).

## Comandos

| Comando | Qué hace |
|---|---|
| `db\ctl.cmd up` | Levanta PostgreSQL y pgAdmin (crea `db\.env` si falta) |
| `db\ctl.cmd status` | Estado de los contenedores y direcciones |
| `db\ctl.cmd apply [NN]` | Aplica `db\sql\*.sql` a la BD `banco` (o solo los que empiecen por `NN`) |
| `db\ctl.cmd test [NN]` | Corre las pruebas en la BD desechable `banco_test` (con `psql` **dentro** del contenedor) |
| `db\ctl.cmd test -Evidence 00-entorno` | Igual, y guarda el log en `docs\db\evidencias\00-entorno.txt` |
| `db\ctl.cmd psql -Sql "SELECT 1"` | Ejecuta SQL (`-Base banco_test` para otra BD); sin `-Sql` abre `psql` interactivo |
| `db\ctl.cmd reset -Yes` | **Destructivo:** elimina y recrea la BD `banco` vacía (y borra `banco_test`) |
| `db\ctl.cmd logs [db\|pgadmin]` | Últimas 100 líneas de log |
| `db\ctl.cmd pgadmin-servers` | (Re)registra en pgAdmin las conexiones de `docker\pgadmin\servers.json` sin recrear su volumen (usa `--replace`: crea servidores nuevos y descarta pestañas guardadas de los anteriores) |
| `db\ctl.cmd down` | Detiene los contenedores (los datos se conservan) |
| `db\ctl.cmd down -Purge` | Detiene y **borra los volúmenes** (BD y estado de pgAdmin) |

En Linux/macOS/WSL/Git Bash: `db/ctl.sh up|status|apply|test|psql|reset --yes|logs|down` (equivalente opcional).

## Cómo funcionan las pruebas
`ctl test` recrea `banco_test`, aplica `db/sql/*.sql` en orden, carga `db/tests/helpers.sql` (helpers `assert_eq`, `assert_true`, `assert_raises`, `assert_violates`, `detecta`…, **solo** en `banco_test`) y `db/tests/harness.sql` (constructores de datos y **funciones arnés** `tests.app_*` que imitan a las funciones de negocio; también solo en `banco_test`), y ejecuta cada `db/tests/*.test.sql` con `psql -v ON_ERROR_STOP=1`. Cada aserción correcta imprime `PASS`; una falla corta el archivo, marca la prueba como fallida y el comando termina con código 1.

Desde la Etapa 2 corre además los scripts `db/tests/reales/NN_*.sh` **dentro del contenedor** (conexiones reales por TCP con contraseña de `banco_app`, `banco_lector`, `banco_dev` y de la sonda `ledger_probe` que asume `banco_ledger`; concurrencia con varios procesos `psql` en paralelo). `ledger_probe` es un rol global que existe solo durante la prueba y se elimina siempre (`db/tests/reales/limpiar_sonda.sql`, al empezar y al terminar, con `try/finally`). `ctl test 12` filtra por prefijo también esos scripts. Al final comprueba que el esquema `tests` **no existe** en la BD `banco` y que la sonda ya no existe. Resumen: `N passed, M failed`.

Pruebas de mutación (rompen una defensa a propósito y exigen que alguna prueba falle): `docker compose -f db\compose.dev.yml exec -T db sh -c "tr -d '\r' < /work/tests/mutaciones/mutaciones.sh | sh -s"` (detalle en `docs/db/etapas/02-libro-mayor.md` y `03-reloj.md`).

**Pruebas de tiempo (E3):** `db/tests/35_reloj_viaje_tiempo.test.sql` sustituye `public._ahora_real()` por una versión que lee `current_setting('tests.ahora')`, **solo** dentro de su transacción y **solo** en `banco_test`/`banco_mut` (la prueba aborta en cualquier otra base; el `ROLLBACK` restaura la función original). `_ahora_real()` es `now()` en la BD `banco`: no hay variable de sesión ni parámetro que falsee la hora del banco. `reales/38_reloj_instantanea.sh` la sustituye también con sesiones reales (tabla `tests.reloj_falso`, solo si la base es `banco_test`/`banco_mut`; si no, el script de inyección se niega) y la restaura al terminar. `_ahora_real()` es `clock_timestamp()` (reloj de pared, no `now()`). Las pruebas `reales/36`, `37` y `38` dejan siempre el reloj en **modo real** al terminar (`trap`).

## Solución de problemas
| Síntoma | Causa y arreglo |
|---|---|
| `Docker no responde` | Abre Docker Desktop y espera a "Engine running". |
| `El puerto N del host ya esta en uso` | Otro programa usa 5433/5050. Cambia `DB_PORT` / `PGADMIN_PORT` en `db\.env` y repite `up`. |
| pgAdmin no carga justo después de `up` o de recrear el contenedor | Tarda unos segundos en arrancar; recarga la página. |
| Cambié `docker\pgadmin\servers.json` y no aparece | pgAdmin importa ese archivo solo al crear su volumen. `db\ctl.cmd down`, `docker volume rm banco-db_pgadmin-data`, `db\ctl.cmd up`. (No uses `-Purge` si no quieres borrar la BD.) |
| Quiero empezar de cero | `db\ctl.cmd reset -Yes` (solo la BD) o `db\ctl.cmd down -Purge` (todo). |

## Seguridad del entorno
Los puertos se publican solo en `127.0.0.1`. Las credenciales de `db\.env.example` son de desarrollo local y no secretas; `db\.env` está en `.gitignore`. `log_statement=none` evita que se registren sentencias con hashes.

## Estructura
```
.gitattributes                  fin de línea estable (LF en .sh/.sql/.json/.yml/.md; CRLF en .cmd/.ps1)
db/
  compose.dev.yml               PostgreSQL + pgAdmin (Compose propio; no es el docker-compose.yml final)
  .env.example                  variables de desarrollo (db/.env no se versiona)
  ctl.cmd  ctl.ps1  ctl.sh      control del entorno (cmd/PowerShell canónicos en Windows; sh opcional)
  docker/postgres/00_bootstrap.sql   zona horaria de la BD en el primer arranque
  docker/pgadmin/servers.json        conexiones preregistradas de pgAdmin
  sql/                          SQL versionado: 00 (E0) · 01–05 (E1: roles, tipos, esquema, índices, permisos) · 06–09 (E2: libro mayor) · 10–12 (E3: reloj) · 13–14 (E4: autenticación y registro)
  tests/                        helpers.sql, harness.sql, *.test.sql, run.ps1 (y run.sh opcional)
  tests/reales/                 scripts sh (corren DENTRO del contenedor): conexiones reales y concurrencia (E2, E3, E4: 39 y 40); 99_integridad_final.sh siempre es el último
  tests/mutaciones/             pruebas de mutación (E2, E3 y E4; `DESDE=N` ejecuta solo las mutaciones M>=N)
docs/db/                        esta documentación, etapas/ y evidencias/
```

## Pruebas de la Etapa 4 (autenticación y registro)
* **Inyección de fallos (solo `banco_test`):** `tests.instalar_fallas()` crea un trigger de prueba `trg_zz_falla` en `transaccion`, `cuenta` y `usuario`; la regla se pasa en el parámetro de sesión `tests.falla` (`tx:N`, `corte:N`, `cuenta`, `usuario`, `bono_flag`, `verificar`). Las pruebas `48` (transaccionales) y `reales/39` (conexiones TCP; `PGOPTIONS='-c tests.falla=tx:7'`) la usan para comprobar que un fallo en cualquier punto, incluso después de escribir patas del libro o con la conexión cortada, no deja nada. `tests.quitar_fallas()` la retira (también en el `trap` del script real). Nunca existe en la base `banco`.
* **Conteo del reloj (`46_auth_reloj`):** sustituye `_ahora_real()` (solo `banco_test`/`banco_mut`, dentro de una transacción) por una versión que cuenta cada lectura con una **secuencia** (no se revierte con una excepción) para demostrar que `registrar_usuario` y `verificar_correo` leen el reloj **una** vez y que una petición inválida no lo lee.
* **Medianoche (`reales/39`, sección D):** mismo mecanismo de inyección persistente que `reales/38` (tabla `tests.reloj_falso`; se niega en cualquier otra base y se restaura al terminar).
* Nota de mantenimiento: las expresiones regulares de `13_auth_utilidades.sql` usan escapes `\uXXXX` (marcas combinantes y dígitos no ASCII); si se editan con una herramienta que expande los escapes Unicode quedarían caracteres literales invisibles (la prueba `40` lo detecta porque verifica el comportamiento). Las pruebas construyen los caracteres especiales con `chr()`.
