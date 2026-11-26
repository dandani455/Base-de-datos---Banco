#!/bin/sh
# Inicializacion de la BD del stack completo (docker-compose.yml de la raiz).
# La imagen oficial de postgres ejecuta este script UNA sola vez: cuando el volumen pgdata esta vacio.
# Mientras corre, postgres solo escucha por socket local, asi que el healthcheck (TCP) no da "healthy"
# hasta que termine: el backend nunca arranca contra una BD a medio crear.
#
#   1. zona horaria de la BD          (db/docker/postgres/00_bootstrap.sql)
#   2. esquema completo, en orden     (db/sql/*.sql: roles, tablas, funciones, triggers, vistas)
#   3. semilla                        (db/seed/sembrar.sh): SEED=demo (por defecto) o SEED=catalogo
#
# Si algo falla, el contenedor se detiene y el volumen queda a medias: "docker compose down -v" y repetir.
set -eu

BASE="${POSTGRES_DB:-banco}"
U="${POSTGRES_USER:-postgres}"
P() { psql -X -q -v ON_ERROR_STOP=1 -U "$U" -d "$BASE" "$@"; }

echo "== [init] zona horaria"
P -f /work/bootstrap/00_bootstrap.sql

n=0
for f in $(ls /work/sql/*.sql | sort); do
  echo "== [init] aplicando $(basename "$f")"
  P -f "$f"
  n=$((n+1))
done
echo "== [init] esquema listo: $n archivo(s)"

modo="${SEED:-demo}"
case "$modo" in
  demo|catalogo)
    echo "== [init] semilla: $modo"
    BASE="$BASE" PGUSER="$U" SEED_DIR=/work/seed sh /work/seed/sembrar.sh "$modo"
    ;;
  ninguno) echo "== [init] sin semilla (SEED=ninguno)" ;;
  *) echo "ERROR: SEED debe ser demo, catalogo o ninguno (vino '$modo')" >&2; exit 1 ;;
esac

# La BD sigue en desarrollo: si la vista de integridad aun no existe, solo se avisa.
if [ "$(P -At -c "SELECT to_regclass('public.v_integridad_global') IS NOT NULL")" = "t" ]; then
  ok="$(P -At -c "SELECT ok FROM v_integridad_global")"
  echo "== [init] integridad_ok = $ok"
  [ "$ok" = "t" ] || [ "$ok" = "true" ] || { echo "ERROR: v_integridad_global.ok = $ok" >&2; exit 1; }
else
  echo "== [init] (aviso) no existe v_integridad_global: se omite la verificacion"
fi
# Marca de init completo: el healthcheck la exige. Si el init se corta a mitad, postgres se saltaria el init
# al reiniciar y quedaria "healthy" con un esquema incompleto; asi, en cambio, queda unhealthy y el backend no arranca.
touch "$PGDATA/.banco_init_ok"
echo "== [init] BD lista"
