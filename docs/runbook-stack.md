# Runbook del stack completo (Docker) y de la demo del apagón

Frente Docker/Infra y QA (§11, §10 y §14 del diseño). Cubre el `docker-compose.yml` de la raíz: **db + pgadmin + backend + front**. El runbook de detalle de la BD (reloj, respaldo/restauración) es [docs/db/runbook-demo.md](db/runbook-demo.md).

## 1. Levantar desde cero

```sh
cp .env.example .env                 # cambia JWT_SECRET (openssl rand -hex 32) y POSTGRES_PASSWORD
docker compose up -d --build --wait  # la primera vez: construye imágenes + crea la BD (≈1 min)
```

| Servicio | Dirección | Notas |
|---|---|---|
| App (front + `/api`) | <http://localhost:8080> | nginx sirve el build y hace proxy de `/api` al backend (un solo origen, sin CORS) |
| pgAdmin 4 | <http://localhost:5050> | sin login; 4 conexiones ya registradas (administración, `banco_dev`, `banco_app`, `banco_lector`) |
| PostgreSQL | `127.0.0.1:5433` | solo para psql/pruebas desde el host; el backend usa la red interna |

**Qué pasa al crear el volumen** (`docker/db-init/00_init.sh`, una sola vez): zona horaria → `db/sql/00…26` en orden → semilla (`SEED=demo` por defecto: `admin1`, `jperez483`, `cgomez12`, `bloqueado1`… clave `Banco2026`) → comprueba `v_integridad_global`. El healthcheck usa TCP, así que la BD no aparece *healthy* hasta que termina el init, y el backend no arranca antes.

Comprobar: `docker compose logs db | grep init]` debe terminar en `integridad_ok = true` y `BD lista`.

### Mientras la BD siga cambiando

El init solo corre con el volumen vacío. Cada vez que llegue una versión nueva de `db/sql` o `db/seed` (`git pull`):

```sh
docker/bd.sh recrear          # borra SOLO la BD (pide confirmar) y la recrea con el db/sql actual; pgAdmin y front no se tocan
docker/bd.sh recrear catalogo # igual, sin usuarios de demo (útil si la semilla aún no funciona con la versión nueva)
docker/bd.sh logs             # qué archivos aplicó y si terminó bien
```

No hay que tocar el compose: el init aplica **todos** los `db/sql/*.sql` en orden, sean los que sean. Si un archivo falla, la BD queda **unhealthy** a propósito: el backend no arranca y `docker/bd.sh logs` muestra el error. Avísale al equipo de BD y vuelve a correr `recrear` cuando lo corrijan.

> **No corras a la vez** `db/compose.dev.yml` (entorno del equipo de BD): comparten los puertos 5050 y 5433.

## 2. QA de punta a punta

```sh
qa/e2e.sh            # registro, login, cliente, seguridad y admin, por HTTP vía nginx
qa/e2e.sh --apagon   # además: para/inicia db y backend y verifica §10
```

Escribe datos de prueba (un usuario nuevo, envíos de $1.000, un bolsillo, un CDT). Para dejar el banco como recién creado: `docker compose down -v && docker compose up -d --wait`. Resultados y hallazgos abiertos: [qa/README.md](../qa/README.md).

## 3. La demo del apagón (§10)

| Paso | Comando | Debe verse |
|---|---|---|
| Antes | `docker compose ps` | los 4 servicios `Up`, db `(healthy)` |
| Caída | `docker compose stop db` | el front sigue navegable; cada panel muestra «Error de conexión, estamos trabajando para solucionarlo»; Control marca DESCONECTADO; `docker compose ps` muestra el backend **vivo** |
| Regreso | `docker compose start db` | en unos segundos todo vuelve con la misma sesión, sin reiniciar el backend; los datos siguen (volumen `pgdata`) |
| Extra | `docker compose stop backend` / `start backend` | nginx responde el mismo `503 {"error":"sin_conexion"}`: el front pinta el mismo banner |
| **Nunca** | `docker compose down -v` | borra el volumen (habría que recrear todo) |

## 4. Plan B sin wifi en la sala

* Antes de salir: `docker compose pull db pgadmin && docker compose build` (imágenes en caché local; `up` ya no descarga nada).
* `RESEND_ENABLED=false` en `.env` (es el valor por defecto): sin correo, el bono de referido se paga al registrar.

## 5. Si algo sale mal

* **`up` falla con «define JWT_SECRET/POSTGRES_PASSWORD»**: falta el `.env` (paso 1).
* **db `unhealthy` o reiniciando**: `docker/bd.sh logs`. Si el init falló a mitad (un `.sql` con error), corrige o espera el arreglo y `docker/bd.sh recrear`.
* **El login no guarda la sesión**: `COOKIE_SECURE` debe ser `false` con `http://localhost`.
* **«role postgres does not exist» / la BD no tiene tablas**: el volumen `banco_pgdata` es de una versión anterior del compose (p. ej. la de placeholders) → `docker compose down -v` y `up`.
* **Puerto ocupado**: cambia `FRONT_PORT`, `PGADMIN_PORT` o `DB_PORT` en `.env` (si cambias `FRONT_PORT`, ajusta `APP_URL`).
