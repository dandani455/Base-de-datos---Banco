# Etapa 0 — Entorno PostgreSQL + pgAdmin 4 · paquete de entrega

**Estado:** terminada, a la espera de tu revisión. **Sin commits** (los archivos están sin versionar en la rama `feat/db-core`). No se tocó `front/`, backend, docs del spec ni archivos de otros integrantes. No se implementó nada de etapas posteriores ni se tomó ninguna decisión financiera.

## 1. Qué se entrega

| Pieza | Archivo(s) |
|---|---|
| PostgreSQL 16 + pgAdmin 4 (versión fijada 9.19.0) en Docker | `db/compose.dev.yml`, `db/.env.example`, `db/docker/postgres/00_bootstrap.sql`, `db/docker/pgadmin/servers.json` |
| SQL versionado y ejecutable desde pgAdmin | `db/sql/00_extensiones.sql` (extensiones `unaccent`, `pg_trgm` y zona horaria `America/Bogota` de la BD) |
| Runner de pruebas con `psql` dentro del contenedor | `db/ctl.ps1` + `db/tests/run.ps1` (canónicos), `db/ctl.cmd` (lanzador Windows), `db/ctl.sh` + `db/tests/run.sh` (opcionales) |
| Helpers y pruebas | `db/tests/helpers.sql`, `db/tests/00_smoke.test.sql` (12 aserciones), `db/tests/01_entorno.test.sql` (16) |
| Fin de línea estable | `.gitattributes` |
| Documentación y evidencia | `docs/db/00-entorno.md`, este archivo, `docs/db/evidencias/00-entorno.txt`, `docs/db/evidencias/00-entorno-verificacion.txt` |

**Objetos creados en la BD `banco`:** solo las extensiones `unaccent` y `pg_trgm` (al aplicar `00_extensiones.sql`) y el ajuste `timezone = America/Bogota` de la base. No hay tablas ni funciones de negocio (empiezan en E1).

## 2. Cómo verificarlo tú (desde cero, ~5 minutos)

1. Abre Docker Desktop y, desde la raíz del repositorio: `db\ctl.cmd up`.
2. Abre <http://localhost:5050>: entra sin login. En el árbol, **Banco Digital → Banco - administración (postgres) → Databases → banco**.
3. Selecciona `banco`, `Alt+Shift+Q` (Query Tool) y ejecuta:
   ```sql
   SHOW timezone;                                       -- America/Bogota
   SELECT now();                                        -- con offset -05
   SELECT extname, extversion FROM pg_extension ORDER BY 1;   -- ya listará unaccent y pg_trgm si aplicaste el script
   ```
4. Ejecuta el script **desde pgAdmin**: icono de carpeta (*Open File*) → ruta `/work/sql/` → `00_extensiones.sql` → **F5**. Debe terminar con `Query returned successfully` (la segunda vez avisa `already exists, skipping`).
5. En PowerShell: `db\ctl.cmd test` → debe terminar en **`29 passed, 0 failed`** (código de salida 0).
6. Comprueba que una prueba que falla da código 1: crea temporalmente `db\tests\99_falla.test.sql` con `SELECT assert_eq('x', 1, 2);`, ejecuta `db\ctl.cmd test 99; $LASTEXITCODE` (debe dar `1`) y bórralo.
7. `db\ctl.cmd reset -Yes` y luego `db\ctl.cmd apply`: la BD se recrea vacía y se reaplica sin errores.
8. `git status`: solo aparecen `.gitattributes`, `db/` y `docs/db/` (y `db/.env` **no** aparece).

## 3. Pruebas de aceptación (F.2)

| # | Verificación | Resultado | Cómo se comprobó |
|---|---|---|---|
| A0.1 | `ctl up` | ✅ `db` *healthy*, `pgadmin` *running* | salida de `db\ctl.cmd up` |
| A0.2 | Abrir `localhost:5050` | ✅ Sin login; el servidor preregistrado conectó **sin pedir contraseña** | navegador integrado: se expandió `Banco - administración` y se listaron las bases `banco` y `postgres` |
| A0.3 | `SHOW timezone; SELECT now();` | ✅ `America/Bogota`; `now()` con hora de Bogotá | Query Tool de pgAdmin y `ctl psql` |
| A0.4 | `00_extensiones.sql` desde pgAdmin y luego `ctl apply` | ✅ Corrió desde pgAdmin (*Open File* `/work/sql/` + F5) y es idempotente (`already exists, skipping`) | Query Tool; `ctl apply 00` dos veces, ambas código 0 |
| A0.5 | `ctl test` | ✅ `29 passed, 0 failed`; los helpers **no** existen en `banco` | `docs/db/evidencias/00-entorno.txt` |
| A0.6 | `ctl reset` y reaplicar | ✅ BD recreada vacía (0 extensiones) y reaplicada (2) | `ctl reset -Yes`, `ctl apply` |
| A0.7 | `git status` | ✅ Solo `.gitattributes`, `db/`, `docs/db/`; `db/.env` ignorado (`.gitignore:4`); `front/` y demás sin cambios | `git status --short`, `git diff --stat` |
| A0.8 | Windows sin Bash | ✅ Ver §4 | `docs/db/evidencias/00-entorno-verificacion.txt` |

## 4. Compatibilidad con un Windows convencional (A0.8)

Verificado en Windows 11 con **Windows PowerShell 5.1.26100**:

- `ctl.ps1` directo con `-ExecutionPolicy Restricted` (la política por defecto de Windows cliente) → **bloqueado**, como se esperaba; por eso existe `ctl.cmd`.
- `ctl.cmd status` desde `cmd.exe` → OK, código 0.
- `ctl.cmd test 00` con un `PATH` que contiene **solo** `System32`, `WindowsPowerShell` y la carpeta de Docker (sin `git`, `node`, `python`, `psql` ni `bash`): **`13 passed, 0 failed`, código 0**.
- Una prueba que falla devuelve código 1 (también en `ctl.sh`).
- Dependencias: Windows 10/11, Docker Desktop en ejecución con Compose v2 y Windows PowerShell 5.1. **Git Bash/WSL solo se necesitan si se usa `ctl.sh`**, y así consta en `docs/db/00-entorno.md`.
- Limitación honesta: se comprobó en esta máquina (con una `ExecutionPolicy` `RemoteSigned` en el usuario y Docker Desktop con WSL2), no en un segundo equipo. El script usa solo sintaxis de PowerShell 5.1 y es ASCII puro (5.1 lee los `.ps1` sin BOM como ANSI).

## 5. Desviaciones respecto a F.2 (para que las apruebes)

| Cambio | Motivo |
|---|---|
| `DB_PORT` por defecto **5433** (no 5432) | En esta máquina ya hay un PostgreSQL local escuchando en 5432 (servicio `postgres`, PID 4524). Es configurable en `db\.env`. |
| `db/ctl.cmd` (nuevo) | Pedido en tu revisión: evitar la *ExecutionPolicy* sin presuponer Bash. |
| `ctl.sh`/`run.sh` quedan como equivalentes **opcionales** y `run.ps1` es el runner canónico | Tu revisión: no presuponer Bash en Windows. `ctl.sh` se probó con Git Bash (29 passed). |
| `db/sql` y `db/tests` también se montan (solo lectura) en el contenedor de **pgAdmin** | Su cuadro *Open File* navega por el sistema de archivos del contenedor; sin el montaje no se podrían abrir los `.sql` del repositorio desde el Query Tool (A0.4). |
| Parámetro `-Base` (no `-Db`) y `--quiet-pull` en `up` | `-Db` choca con un alias de `-Debug` de PowerShell; `--quiet-pull` evita cientos de líneas de progreso. |
| Script `ctl.ps1` en ASCII (mensajes sin tildes) | Windows PowerShell 5.1 lee `.ps1` sin BOM como ANSI y corrompería las tildes. |
| `servers.json` solo registra la conexión de administración | Las de `banco_dev`/`banco_app`/`banco_lector` se añaden en E1, cuando existan los roles (como se acordó). |

## 6. Pendientes y riesgos conocidos
- `servers.json` se importa solo al crear el volumen de pgAdmin; al añadir conexiones en E1 habrá que recrear ese volumen (procedimiento en `docs/db/00-entorno.md`). Se podría automatizar con un comando `ctl` en E1.
- Contraseñas de desarrollo en `db/.env.example` (no secretas); las de los roles de E1 seguirán la misma política.
- No se probó en Linux/macOS (el `ctl.sh` solo se probó con Git Bash en Windows).
