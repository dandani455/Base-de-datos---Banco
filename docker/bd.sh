#!/usr/bin/env bash
# docker/bd.sh — atajos para la BD del stack completo mientras db/sql sigue cambiando.
#   docker/bd.sh recrear [demo|catalogo|ninguno]   borra SOLO el volumen de la BD y la vuelve a crear con el db/sql actual
#   docker/bd.sh logs                              muestra el log del init (qué archivos aplicó y si terminó bien)
#   docker/bd.sh psql                              psql como postgres en la BD banco
# pgAdmin y las imágenes no se tocan. Usa el .env de la raíz; COMPOSE_PROJECT_NAME y ENV_FILE para otro proyecto/archivo.
set -euo pipefail
cd "$(dirname "$0")/.."

PROYECTO="${COMPOSE_PROJECT_NAME:-banco}"
dc() { docker compose -p "$PROYECTO" ${ENV_FILE:+--env-file "$ENV_FILE"} "$@"; }

case "${1:-}" in
  recrear)
    seed="${2:-${SEED:-demo}}"
    echo "Esto BORRA todos los datos de la BD del proyecto '$PROYECTO' y la recrea desde db/sql (semilla: $seed)."
    read -r -p 'Escribe "si" para continuar: ' r; [ "$r" = "si" ] || { echo 'Cancelado.'; exit 1; }
    dc stop backend db
    dc rm -f db
    docker volume rm "${PROYECTO}_pgdata"
    SEED="$seed" dc up -d --wait db
    dc logs db | grep -E 'init\]|ERROR' || true
    dc up -d --wait backend
    echo "Listo."
    ;;
  logs) dc logs db | grep -E 'init\]|ERROR|FATAL' ;;
  psql) dc exec db psql -U postgres -d banco ;;
  *) sed -n '2,6p' "$0"; exit 64 ;;
esac
