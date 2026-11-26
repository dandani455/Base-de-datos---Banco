#!/bin/sh
# sembrar.sh - Etapa 14 - Ejecuta el catalogo y/o el seed de demostracion DENTRO del contenedor "db" (sh de busybox; sin bash).
#   sembrar.sh catalogo   carga el catalogo de CDT y creditos (idempotente; cualquier banco)
#   sembrar.sh demo       catalogo + funciones solo-seed + historia de demostracion (SOLO sobre un banco vacio)
#   sembrar.sh todo       = demo
# Variables: BASE (por defecto banco), SEED_DIR (por defecto /work/seed), PGUSER (por defecto postgres).
# El esquema temporal "seed" se ELIMINA SIEMPRE al terminar: con exito, con error o si el script se interrumpe (EXIT, HUP, INT o TERM). Ante una interrupcion tambien se
# cierra la sesion del seed (la historia es UNA transaccion: se revierte y no queda nada) y se reintenta el DROP mientras esa sesion libera sus bloqueos.
BASE=${BASE:-banco}
SEED_DIR=${SEED_DIR:-/work/seed}
U=${PGUSER:-postgres}
export PGAPPNAME=sembrar_seed
CH=""

P() { psql -X -q -v ON_ERROR_STOP=1 -U "$U" -d "$BASE" "$@"; }
# ejecuta psql en segundo plano y ESPERA con "wait": asi una senal interrumpe la espera de inmediato y el trap puede actuar
EJEC() { P "$@" & CH=$!; wait "$CH"; _rc=$?; CH=""; return $_rc; }
limpiar() {
  [ -n "$CH" ] && kill "$CH" 2>/dev/null
  P -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'sembrar_seed' AND pid <> pg_backend_pid()" >/dev/null 2>&1
  _i=0
  while [ "$_i" -lt 10 ]; do
    P -c "DROP SCHEMA IF EXISTS seed CASCADE" >/dev/null 2>&1 && break
    _i=$((_i+1)); sleep 1
  done
}
salir() { trap - EXIT HUP INT TERM; limpiar; exit "$1"; }

catalogo() { echo "== Catalogo (00_catalogo.sql) en la BD '$BASE'"; EJEC -f "$SEED_DIR/00_catalogo.sql"; }

demo() {
  # el banco debe estar vacio ANTES de crear nada (ni usuarios ni libro)
  n=$(P -At -c "SELECT (SELECT count(*) FROM public.usuario) + (SELECT count(*) FROM public.transaccion)") || exit 1
  if [ "$n" != "0" ]; then
    echo "ERROR: el seed solo corre sobre un banco vacio (la BD '$BASE' ya tiene datos). Para repetirlo: ctl reset --yes, ctl apply y ctl seed." >&2
    exit 2
  fi
  trap limpiar EXIT
  trap 'salir 129' HUP
  trap 'salir 130' INT
  trap 'salir 143' TERM
  catalogo || exit 1
  echo "== Funciones solo-seed (esquema temporal seed)"
  EJEC -f "$SEED_DIR/10_funciones_seed.sql" || exit 1
  echo "== Historia de demostracion (20_demo.sql)"
  EJEC -f "$SEED_DIR/20_demo.sql" || exit 1
  echo "== Seed completo. Esquema seed eliminado."
}

case "${1:-}" in
  catalogo)  catalogo ;;
  demo|todo) demo ;;
  *) echo "Uso: sembrar.sh catalogo | demo" >&2; exit 64 ;;
esac
