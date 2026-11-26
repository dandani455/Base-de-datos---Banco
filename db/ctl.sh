#!/usr/bin/env bash
# ctl.sh - Equivalente OPCIONAL de ctl.ps1 para Linux, macOS, WSL o Git Bash.
# En Windows el camino soportado es db\ctl.cmd / db\ctl.ps1 (no requiere Bash). Este script solo hace falta
# si prefieres Bash; en ese caso necesitas Bash (Git Bash o WSL) ademas de Docker con "docker compose".
#
# Uso:  db/ctl.sh up | down [--purge] | status | apply [NN] | test [NN] [--evidence nombre]
#                 | psql [-c "SQL"] | reset --yes | logs [servicio] | pgadmin-servers
#                 | seed [catalogo|demo] | backup [nombre] | restore nombre --yes | recuperar | descartar-previo   (E14)
set -euo pipefail

# Git Bash en Windows convierte rutas como /work/sql en C:/Program Files/Git/...; se desactiva.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# En Git Bash/MSYS, docker.exe necesita rutas de Windows (C:/...), no /c/...
if command -v cygpath >/dev/null 2>&1; then RAIZ="$(cygpath -m "$RAIZ")"; fi
REPO="$(dirname "$RAIZ")"
COMPOSE="$RAIZ/compose.dev.yml"
ENVF="$RAIZ/.env"

cfg() { # cfg CLAVE DEFECTO
  local v=""
  [ -f "$ENVF" ] && v="$(grep -E "^[[:space:]]*$1=" "$ENVF" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
  echo "${v:-$2}"
}
PGUSER_="$(cfg POSTGRES_USER postgres)"

dc()   { docker compose --env-file "$ENVF" -f "$COMPOSE" "$@"; }
psqlc() { # psqlc BASE args...   (psql dentro del contenedor, ON_ERROR_STOP)
  local base="$1"; shift
  dc exec -T db psql -X -v ON_ERROR_STOP=1 -U "$PGUSER_" -d "$base" "$@"
}
fail() { echo "ERROR: $*" >&2; exit 1; }
need_docker() { docker info >/dev/null 2>&1 || fail 'Docker no responde. Abre Docker Desktop / inicia el servicio y repite.'; }
need_env() { [ -f "$ENVF" ] || { cp "$RAIZ/.env.example" "$ENVF"; echo 'Creado db/.env a partir de db/.env.example (valores de desarrollo local).'; }; }
need_db() { need_docker; dc exec -T db pg_isready -q -d banco >/dev/null 2>&1 || fail 'La base de datos no esta lista. Ejecuta primero: db/ctl.sh up'; }
sqlfiles() { ls "$RAIZ/sql"/*.sql 2>/dev/null | sort | while read -r f; do b="$(basename "$f")"; case "$b" in "${1:-}"*) echo "$b";; esac; done; }

cmd_up() {
  need_docker; need_env
  dc up -d --quiet-pull --wait --wait-timeout 180
  cmd_status
}
cmd_status() {
  need_docker
  dc ps
  if dc exec -T db pg_isready -q -d banco >/dev/null 2>&1; then echo 'PostgreSQL: LISTO'; else echo 'PostgreSQL: NO listo'; fi
  echo "pgAdmin 4 : http://localhost:$(cfg PGADMIN_PORT 5050)"
  echo "PostgreSQL: localhost:$(cfg DB_PORT 5433)  (BD banco, usuario $PGUSER_)"
}
cmd_pgadmin_servers() {
  need_docker
  local email='pgadmin4@pgadmin.org'   # modo escritorio (SERVER_MODE=False): usuario fijo de pgAdmin
  dc exec -T pgadmin /venv/bin/python3 /pgadmin4/setup.py load-servers /pgadmin4/servers.json --user "$email" --replace
  echo 'Conexiones registradas. Recarga pgAdmin (F5) para verlas.'
}
cmd_down() { need_docker; if [ "${1:-}" = "--purge" ]; then dc down -v; echo 'Volumenes eliminados.'; else dc down; fi; }
cmd_apply() {
  need_db
  local n=0 f
  for f in $(sqlfiles "${1:-}"); do
    echo "== Aplicando $f"; psqlc banco -f "/work/sql/$f"; n=$((n+1))
  done
  [ "$n" -gt 0 ] || fail "No hay archivos en db/sql que coincidan con '${1:-}'."
  echo "Listo: $n archivo(s) aplicado(s) a la BD 'banco'."
}
cmd_reset() {
  need_db
  if [ "${1:-}" != "--yes" ]; then
    read -r -p 'Esto ELIMINA y recrea la BD "banco" (y borra banco_test). Escribe "si": ' r; [ "$r" = "si" ] || fail 'Cancelado.'
  fi
  psqlc postgres -c 'DROP DATABASE IF EXISTS banco_test WITH (FORCE)'
  psqlc postgres -c 'DROP DATABASE IF EXISTS banco WITH (FORCE)'
  psqlc postgres -c 'CREATE DATABASE banco'
  psqlc banco -f /docker-entrypoint-initdb.d/00_bootstrap.sql
  echo 'BD "banco" recreada vacia. Siguiente paso: db/ctl.sh apply'
}
cmd_psql() {
  need_db
  if [ "${1:-}" = "-c" ]; then psqlc banco -c "$2"; else dc exec db psql -X -U "$PGUSER_" -d banco; fi
}
cmd_test() { # test [NN] [--evidence nombre]
  need_db
  local pref="" evid=""
  while [ $# -gt 0 ]; do case "$1" in --evidence) evid="$2"; shift 2;; *) pref="$1"; shift;; esac; done
  local passed=0 failed=0 log; log="$(mktemp)"
  say() { echo "$*" | tee -a "$log"; }
  # El rol-sonda ledger_probe (conexiones reales de E2) es GLOBAL del cluster: se elimina al empezar y al terminar.
  limpiar_sonda() { psqlc postgres -q -f /work/tests/reales/limpiar_sonda.sql >/dev/null 2>&1 || true; }
  limpiar_sonda; trap limpiar_sonda EXIT
  say '=== Banco Digital - pruebas de la capa de base de datos ==='
  say "Fecha     : $(date '+%Y-%m-%d %H:%M:%S %z')"
  say "Docker    : $(docker --version)"
  say "PostgreSQL: $(psqlc postgres -At -c 'SELECT version()' | head -n1)"
  say "Rama git  : $(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
  [ -n "$pref" ] && say "Filtro    : pruebas que empiezan por '$pref'"
  say ''; say '== Preparando banco_test'
  psqlc postgres -c 'DROP DATABASE IF EXISTS banco_test WITH (FORCE)' >/dev/null
  psqlc postgres -c 'CREATE DATABASE banco_test' >/dev/null
  psqlc postgres -c "ALTER DATABASE banco_test SET timezone TO 'America/Bogota'" >/dev/null
  psqlc postgres -c 'ALTER DATABASE banco_test SET search_path TO public, tests' >/dev/null
  local f
  for f in $(sqlfiles ""); do psqlc banco_test -q -f "/work/sql/$f" >/dev/null; say "   aplicado $f"; done
  psqlc banco_test -q -f /work/tests/helpers.sql >/dev/null; say '   cargado helpers.sql (solo en banco_test)'
  psqlc banco_test -q -f /work/tests/harness.sql >/dev/null; say '   cargado harness.sql (funciones arnes, solo en banco_test)'; say ''
  local tf t out code any=0
  for tf in "$RAIZ"/tests/*.test.sql; do   # la ruta puede tener espacios: se itera con glob, no con ls
    [ -e "$tf" ] || continue
    t="$(basename "$tf")"
    case "$t" in "$pref"*) ;; *) continue;; esac
    any=1; say "== $t"
    set +e; out="$(psqlc banco_test -q -t -A -f "/work/tests/$t" 2>&1)"; code=$?; set -e
    while IFS= read -r l; do
      case "$l" in *"NOTICE:  PASS:"*) passed=$((passed+1)); say "   ok    ${l#*PASS: }";; esac
    done <<<"$out"
    if [ "$code" -ne 0 ]; then failed=$((failed+1)); echo "$out" | grep -v 'NOTICE:  PASS:' | sed 's/^/   /' | tee -a "$log"; say "   FALLO: $t (codigo $code)"; fi
  done
  # Pruebas con CONEXIONES REALES y CONCURRENCIA: scripts sh que corren dentro del contenedor (PASS:/FAIL:)
  local rf rn rout rcode rfail
  for rf in "$RAIZ"/tests/reales/[0-9][0-9]_*.sh; do
    [ -e "$rf" ] || continue
    rn="$(basename "$rf")"
    case "$rn" in "$pref"*) ;; *) continue;; esac
    any=1; say "== reales/$rn"
    set +e; rout="$(dc exec -T db sh -c "tr -d '\r' < /work/tests/reales/$rn | sh -s" 2>&1)"; rcode=$?; set -e
    rfail=0
    while IFS= read -r l; do
      case "$l" in
        PASS:*) passed=$((passed+1)); say "   ok    ${l#PASS: }";;
        FAIL:*) rfail=1; say "   $l";;
        RESUMEN*|"") ;;
        *) say "   $l";;
      esac
    done <<<"$rout"
    if [ "$rcode" -ne 0 ] || [ "$rfail" -eq 1 ]; then failed=$((failed+1)); say "   FALLO: reales/$rn (codigo $rcode)"; fi
  done
  [ "$any" -eq 1 ] || { say "No hay pruebas que coincidan con '$pref'."; exit 1; }
  say ''; say '== aislamiento'
  if [ "$(psqlc postgres -At -c "SELECT to_regrole('ledger_probe') IS NULL")" = "t" ]; then passed=$((passed+1)); say '   ok    el rol-sonda ledger_probe NO existe tras las pruebas reales'
  else failed=$((failed+1)); say '   FALLO: el rol ledger_probe sigue existiendo'; fi
  if [ "$(psqlc banco -At -c "SELECT to_regnamespace('tests') IS NULL")" = "t" ]; then passed=$((passed+1)); say '   ok    los helpers (esquema tests) NO existen en la BD banco'
  else failed=$((failed+1)); say '   FALLO: el esquema tests existe en la BD banco'; fi
  say ''; say "$passed passed, $failed failed"
  if [ -n "$evid" ]; then mkdir -p "$REPO/docs/db/evidencias"; cp "$log" "$REPO/docs/db/evidencias/$evid.txt"; echo "Evidencia guardada en docs/db/evidencias/$evid.txt"; fi
  rm -f "$log"
  [ "$failed" -eq 0 ]
}

# ---- E14: catalogo, seed de demostracion, respaldo y restauracion (la logica vive en db/seed/*.sh y corre DENTRO del contenedor) ----
nombre_ok() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$' || fail "nombre de respaldo invalido (solo letras, digitos, punto, guion y guion bajo): $1"; }
cmd_seed() { # seed [catalogo|demo]
  need_db
  case "${1:-demo}" in
    catalogo|demo) dc exec -T db sh -c "tr -d '\r' < /work/seed/sembrar.sh | sh -s -- ${1:-demo}" ;;
    *) fail 'Uso: ctl.sh seed [catalogo|demo]' ;;
  esac
}
cmd_backup() { # backup [nombre]
  need_db
  local n="${1:-$(date +%Y%m%d-%H%M%S)}"; nombre_ok "$n"
  dc exec -T db sh -c "tr -d '\r' < /work/seed/respaldo.sh | sh -s -- backup /tmp/banco_$n.dump banco"
  mkdir -p "$RAIZ/backups"
  dc cp "db:/tmp/banco_$n.dump" "$RAIZ/backups/banco_$n.dump"
  dc cp "db:/tmp/banco_$n.dump.huella" "$RAIZ/backups/banco_$n.dump.huella"
  dc exec -T db rm -f "/tmp/banco_$n.dump" "/tmp/banco_$n.dump.huella"
  echo "Respaldo copiado a db/backups/banco_$n.dump (+ .huella). Restaurar: db/ctl.sh restore $n --yes"
}
cmd_restore() { # restore nombre --yes
  need_db
  [ -n "${1:-}" ] || fail 'Uso: ctl.sh restore nombre --yes'
  local n="$1"; nombre_ok "$n"
  [ -s "$RAIZ/backups/banco_$n.dump" ] || fail "No existe db/backups/banco_$n.dump"
  [ "${2:-}" = "--yes" ] || fail "La restauracion REEMPLAZA la BD 'banco' (la actual queda como banco_previo). Repite con --yes."
  dc cp "$RAIZ/backups/banco_$n.dump" "db:/tmp/banco_$n.dump"
  [ -f "$RAIZ/backups/banco_$n.dump.huella" ] && dc cp "$RAIZ/backups/banco_$n.dump.huella" "db:/tmp/banco_$n.dump.huella"
  local rc=0
  dc exec -T db sh -c "tr -d '\r' < /work/seed/respaldo.sh | sh -s -- restore /tmp/banco_$n.dump banco --yes" || rc=$?
  dc exec -T db rm -f "/tmp/banco_$n.dump" "/tmp/banco_$n.dump.huella"
  return $rc
}
cmd_recuperar() { need_db; dc exec -T db sh -c "tr -d '\r' < /work/seed/respaldo.sh | sh -s -- recuperar banco"; }
cmd_descartar_previo() { need_db; dc exec -T db sh -c "tr -d '\r' < /work/seed/respaldo.sh | sh -s -- descartar banco"; }

case "${1:-help}" in
  up) cmd_up ;;  status) cmd_status ;;  down) shift; cmd_down "${1:-}" ;;
  apply) shift; cmd_apply "${1:-}" ;;  reset) shift; cmd_reset "${1:-}" ;;
  psql) shift; cmd_psql "$@" ;;  test) shift; cmd_test "$@" ;;
  logs) shift; need_docker; dc logs --tail 100 "$@" ;;
  pgadmin-servers) cmd_pgadmin_servers ;;
  seed) shift; cmd_seed "$@" ;;  backup) shift; cmd_backup "$@" ;;  restore) shift; cmd_restore "$@" ;;  descartar-previo) cmd_descartar_previo ;;  recuperar) cmd_recuperar ;;
  *) sed -n '2,9p' "${BASH_SOURCE[0]}" ;;
esac
