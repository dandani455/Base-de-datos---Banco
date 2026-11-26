#!/bin/sh
# respaldo.sh - Etapa 14 - Respaldo y restauracion PROTEGIDOS de la BD (P-DEMO-3), DENTRO del contenedor "db" (sh de busybox).
#   respaldo.sh backup  ARCHIVO [BASE]          pg_dump -Fc + manifiesto ARCHIVO.huella. RECHAZA una BD con v_integridad_global.ok = false y una BD que cambie mientras se respalda.
#   respaldo.sh restore ARCHIVO [BASE] --yes    restaura SIN riesgo: valida archivo y manifiesto (que declare integridad ok), restaura en una BD de paso, EXIGE integridad ok en
#                                               ella y la compara tabla por tabla con el manifiesto; solo entonces intercambia: BASE -> BASE_retirada, paso -> BASE y, al final, la
#                                               BASE_retirada pasa a BASE_previo (el _previo anterior se conserva HASTA ese ultimo paso). Ante un error o una senal (HUP, INT, TERM)
#                                               se recupera sola; ante un corte duro (kill -9) basta "respaldo.sh recuperar" (o repetir el restore). Sin --yes no hace nada.
#   respaldo.sh recuperar [BASE]                termina o deshace un intercambio interrumpido (idempotente)
#   respaldo.sh descartar [BASE]                elimina BASE_previo
#   respaldo.sh huella [BASE] | tablas [BASE] | manifiesto [BASE]     solo lectura
# BASE por defecto: banco. Solo se admiten nombres banco o banco_<letras/digitos>; NUNCA banco_test, *_restaurando, *_previo ni *_retirada.
# La restauracion es para el MISMO cluster (los roles banco_* son globales y no viajan en el volcado).
# Gancho de PRUEBAS: RESPALDO_FALLA = error_entre | term_entre | kill_entre provoca un fallo, una senal TERM o un kill -9 ENTRE los dos renombrados; kill_despues, un kill -9 justo DESPUES del segundo; cambio_durante, un cambio de datos mientras corre el backup.
U=${PGUSER:-postgres}
TABLAS="public.usuario public.cuenta public.bolsillo public.cdt_definicion public.cdt public.credito_producto public.credito public.cuota public.transaccion public.reloj public.parametro audit.evento"

die() { echo "ERROR: $*" >&2; exit 1; }
Q() { psql -X -q -At -v ON_ERROR_STOP=1 -U "$U" -d "$1" -c "$2"; }                                   # Q BASE SQL
QH() { PGOPTIONS='-c timezone=UTC -c datestyle=ISO,MDY -c intervalstyle=postgres' psql -X -q -At -v ON_ERROR_STOP=1 -U "$U" -d "$1" -c "$2"; }   # lecturas para la huella (independientes de la sesion)
existe() { Q postgres "SELECT count(*) FROM pg_database WHERE datname = '$1'"; }

base_valida() {
  case "$1" in
    banco_test|*_restaurando|*_previo|*_retirada) return 1 ;;
    banco) return 0 ;;
    banco_[a-z0-9]*) printf '%s' "$1" | grep -Eq '^banco_[a-z0-9]+$' ;;
    *) return 1 ;;
  esac
}

# Huella FUNCIONAL por tabla: el texto COMPLETO de cada fila (todas las columnas) de las 11 tablas de public y audit.evento, ordenado, y el esquema (funciones con dueño, permisos y
# SECURITY DEFINER, y triggers con su estado). Cualquier cambio de un dato o un permiso cambia su linea.
tablas_huella() {
  for t in $TABLAS; do
    h=$(QH "$1" "SELECT md5(coalesce(string_agg(x::text, E'\\n' ORDER BY x::text), '')) FROM $t x") || return 1
    printf 'tabla.%s=%s\n' "$t" "$h"
  done
  h=$(QH "$1" "SELECT md5(concat_ws('#', (SELECT coalesce(string_agg(p.oid::regprocedure::text || ':' || coalesce(p.proacl::text, '') || ':' || pg_get_userbyid(p.proowner) || ':' || p.prosecdef::text, ',' ORDER BY p.oid::regprocedure::text), '') FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')), (SELECT coalesce(string_agg(tgrelid::regclass::text || '.' || tgname || ':' || tgenabled::text, ',' ORDER BY tgrelid::regclass::text, tgname), '') FROM pg_trigger WHERE NOT tgisinternal)))") || return 1
  printf 'esquema=%s\n' "$h"
}
huella() { _l=$(tablas_huella "$1") || return 1; printf '%s\n' "$_l" | md5sum | cut -d' ' -f1; }
integridad() { Q "$1" "SELECT ok FROM public.v_integridad_global"; }
manifiesto() {
  _t=$(tablas_huella "$1") || return 1
  _h=$(printf '%s\n' "$_t" | md5sum | cut -d' ' -f1)
  _u=$(Q "$1" "SELECT count(*) FROM public.usuario") || return 1
  _p=$(Q "$1" "SELECT patas FROM public.v_integridad_global") || return 1
  _o=$(integridad "$1") || return 1
  _e=$(Q "$1" "SELECT count(*) FROM audit.evento") || return 1
  printf '%s\nhuella=%s\nusuarios=%s\npatas=%s\neventos=%s\nintegridad_ok=%s\nbase_origen=%s\n' "$_t" "$_h" "$_u" "$_p" "$_e" "$_o" "$1"
}
mval() { grep "^$2=" "$1" | head -n1 | cut -d= -f2-; }                                                 # mval ARCHIVO CLAVE

# Termina o deshace un intercambio interrumpido (idempotente). Estados:
#   BASE no existe y BASE_retirada si  -> el corte fue ENTRE los dos renombrados: se DEVUELVE la retirada a BASE (la BD anterior)
#   BASE y BASE_retirada existen       -> el intercambio ya se hizo: falta cerrar (la retirada pasa a BASE_previo)
# y siempre se elimina la BD de paso.
recuperar() {
  _B=$1; _R="${_B}_retirada"; _S="${_B}_restaurando"; _V="${_B}_previo"
  _eB=$(existe "$_B"); _eR=$(existe "$_R")
  if [ "$_eB" = "0" ] && [ "$_eR" = "1" ]; then
    _i=0
    while [ "$_i" -lt 5 ]; do
      _i=$((_i+1))
      Q postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$_R' AND pid <> pg_backend_pid()" >/dev/null 2>&1
      Q postgres "ALTER DATABASE \"$_R\" RENAME TO \"$_B\"" >/dev/null 2>&1 && { echo "Recuperada: la BD anterior volvio a llamarse '$_B'." >&2; break; }
      sleep 1
    done
  elif [ "$_eB" = "1" ] && [ "$_eR" = "1" ]; then
    Q postgres "DROP DATABASE IF EXISTS \"$_V\" WITH (FORCE)" >/dev/null 2>&1
    Q postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$_R' AND pid <> pg_backend_pid()" >/dev/null 2>&1
    Q postgres "ALTER DATABASE \"$_R\" RENAME TO \"$_V\"" >/dev/null 2>&1 && echo "Cerrado el intercambio pendiente: la BD anterior quedo como '$_V'." >&2
  fi
  Q postgres "DROP DATABASE IF EXISTS \"$_S\" WITH (FORCE)" >/dev/null 2>&1
  return 0
}

cmd_backup() {
  F=$1; B=${2:-banco}
  [ -n "$F" ] || die "falta el archivo: respaldo.sh backup ARCHIVO [BASE]"
  base_valida "$B" || die "base no permitida: $B"
  Q "$B" "SELECT 1" >/dev/null 2>&1 || die "la BD '$B' no existe o no responde"
  # 1) no se respalda un estado danado
  [ "$(integridad "$B")" = "t" ] || die "la BD '$B' NO tiene la integridad en orden (v_integridad_global.ok): no se respalda un estado danado"
  manifiesto "$B" > "$F.huella.tmp" || { rm -f "$F.huella.tmp"; die "no se pudo calcular el manifiesto de '$B'"; }
  pg_dump -U "$U" -Fc -d "$B" -f "$F.tmp" || { rm -f "$F.tmp" "$F.huella.tmp"; die "pg_dump fallo"; }
  [ "${RESPALDO_FALLA:-}" = "cambio_durante" ] && Q "$B" "UPDATE public.parametro SET bono_referido = bono_referido + 1" >/dev/null       # gancho de pruebas: la BD cambia durante el respaldo
  # 2) la BD no debe haber cambiado mientras se respaldaba (el manifiesto describe el volcado)
  manifiesto "$B" > "$F.huella.chk" 2>/dev/null
  if [ "$(grep '^huella=' "$F.huella.chk" | head -n1)" != "$(grep '^huella=' "$F.huella.tmp" | head -n1)" ]; then
    rm -f "$F.tmp" "$F.huella.tmp" "$F.huella.chk"; die "la BD '$B' cambio mientras se respaldaba: repite el respaldo"
  fi
  rm -f "$F.huella.chk"
  pg_restore -l "$F.tmp" >/dev/null 2>&1 || { rm -f "$F.tmp" "$F.huella.tmp"; die "el respaldo generado no se puede leer (pg_restore -l)"; }
  mv "$F.tmp" "$F"; mv "$F.huella.tmp" "$F.huella"
  echo "Respaldo de '$B' guardado en $F ($(wc -c < "$F" | tr -d ' ') bytes). Huella: $(mval "$F.huella" huella)"
}

cmd_restore() {
  F=$1; B=${2:-banco}; SI=$3
  [ -n "$F" ] || die "falta el archivo: respaldo.sh restore ARCHIVO [BASE] --yes"
  base_valida "$B" || die "base no permitida: $B"
  [ "$SI" = "--yes" ] || die "la restauracion REEMPLAZA la BD '$B' (la actual queda como ${B}_previo). Repite con --yes para confirmar."
  recuperar "$B"                                                      # un intercambio interrumpido antes se termina/deshace primero
  # 1) validar el archivo y su manifiesto ANTES de tocar nada
  [ -s "$F" ] || die "el archivo no existe o esta vacio: $F"
  [ -s "$F.huella" ] || die "falta el manifiesto $F.huella (un respaldo hecho con 'backup' siempre lo trae)"
  [ "$(mval "$F.huella" integridad_ok)" = "t" ] || die "el manifiesto NO declara integridad en orden (integridad_ok=$(mval "$F.huella" integridad_ok)): no se restaura"
  pg_restore -l "$F" > /tmp/respaldo_toc.$$ 2>/dev/null || { rm -f /tmp/respaldo_toc.$$; die "el archivo no es un respaldo valido de pg_dump -Fc"; }
  for t in 'public usuario' 'public transaccion' 'public reloj' 'audit evento'; do
    grep -q "TABLE $t " /tmp/respaldo_toc.$$ || { rm -f /tmp/respaldo_toc.$$; die "el respaldo no parece ser el de este banco (falta la tabla ${t#* })"; }
  done
  rm -f /tmp/respaldo_toc.$$
  S="${B}_restaurando"; V="${B}_previo"; R="${B}_retirada"
  # a partir de aqui, cualquier error o senal deja la BD recuperable
  trap 'trap - EXIT INT TERM HUP; recuperar "$B"; exit 129' HUP
  trap 'trap - EXIT INT TERM HUP; recuperar "$B"; exit 130' INT
  trap 'trap - EXIT INT TERM HUP; recuperar "$B"; exit 143' TERM
  trap 'recuperar "$B"' EXIT
  # 2) restaurar en una BD de PASO (la BD actual no se toca)
  Q postgres "DROP DATABASE IF EXISTS \"$S\" WITH (FORCE)" >/dev/null || die "no se pudo preparar la BD de paso"
  Q postgres "CREATE DATABASE \"$S\"" >/dev/null || die "no se pudo crear la BD de paso"
  Q postgres "ALTER DATABASE \"$S\" SET timezone TO 'America/Bogota'" >/dev/null
  if ! pg_restore -U "$U" --exit-on-error -d "$S" "$F" >/tmp/respaldo_rest.$$ 2>&1; then
    cat /tmp/respaldo_rest.$$ >&2; rm -f /tmp/respaldo_rest.$$
    die "pg_restore fallo; la BD '$B' NO se modifico"
  fi
  rm -f /tmp/respaldo_rest.$$
  # 3) verificar la BD de paso: integridad EXIGIDA (no solo igual al manifiesto) y tabla por tabla contra el manifiesto
  OK=$(integridad "$S")
  [ "$OK" = "t" ] || die "la BD restaurada NO tiene la integridad en orden (v_integridad_global.ok = '$OK'); la BD '$B' NO se modifico"
  tablas_huella "$S" > /tmp/respaldo_h.$$ 2>/dev/null
  grep '^tabla\.\|^esquema=' "$F.huella" > /tmp/respaldo_m.$$
  if ! cmp -s /tmp/respaldo_h.$$ /tmp/respaldo_m.$$; then
    DIF=$(while IFS= read -r _l; do grep -qxF "$_l" /tmp/respaldo_m.$$ || printf '%s ' "${_l%%=*}"; done < /tmp/respaldo_h.$$)
    rm -f /tmp/respaldo_h.$$ /tmp/respaldo_m.$$
    die "la BD restaurada NO coincide con el manifiesto (difieren: ${DIF:-el contenido}); la BD '$B' NO se modifico"
  fi
  rm -f /tmp/respaldo_h.$$ /tmp/respaldo_m.$$
  # 4) intercambio. El _previo anterior se conserva hasta el ultimo paso.
  eB=$(existe "$B")
  if [ "$eB" = "1" ]; then
    hecho=0; i=0
    while [ "$i" -lt 5 ] && [ "$hecho" -eq 0 ]; do
      i=$((i+1))
      Q postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$B' AND pid <> pg_backend_pid()" >/dev/null
      Q postgres "ALTER DATABASE \"$B\" RENAME TO \"$R\"" >/dev/null 2>&1 && hecho=1 || sleep 1
    done
    [ "$hecho" -eq 1 ] || die "no se pudo retirar la BD '$B' (hay conexiones que vuelven a abrirse: deten el backend/pgAdmin y repite); la BD '$B' NO se modifico"
  fi
  # --- ventana entre los dos renombrados: aqui es donde se prueba la recuperacion ---
  case "${RESPALDO_FALLA:-}" in
    term_entre)  kill -TERM $$; sleep 2 ;;
    kill_entre)  kill -KILL $$ ;;
  esac
  if [ "${RESPALDO_FALLA:-}" = "error_entre" ]; then
    die "fallo simulado entre los dos renombrados (RESPALDO_FALLA=error_entre)"
  fi
  Q postgres "ALTER DATABASE \"$S\" RENAME TO \"$B\"" >/dev/null 2>&1 || die "no se pudo poner la BD restaurada como '$B'; la BD anterior se recupera"
  [ "${RESPALDO_FALLA:-}" = "kill_despues" ] && kill -KILL $$
  # 5) cerrar: recien ahora se reemplaza el _previo anterior por la BD retirada
  if [ "$eB" = "1" ]; then
    Q postgres "DROP DATABASE IF EXISTS \"$V\" WITH (FORCE)" >/dev/null
    Q postgres "ALTER DATABASE \"$R\" RENAME TO \"$V\"" >/dev/null 2>&1 || die "restaurada, pero no se pudo renombrar la BD retirada a '$V' (respaldo.sh recuperar la cierra)"
  fi
  trap - EXIT INT TERM HUP
  echo "Restaurado: '$B' = respaldo $F (huella $(mval "$F.huella" huella)). La BD anterior quedo como '$V' (respaldo.sh descartar $B la elimina)."
}

cmd_descartar() {
  B=${1:-banco}; base_valida "$B" || die "base no permitida: $B"
  Q postgres "DROP DATABASE IF EXISTS \"${B}_previo\" WITH (FORCE)" >/dev/null && echo "Eliminada '${B}_previo' (si existia)."
}

lectura() { case "${2:-banco}" in banco*) "$1" "${2:-banco}" ;; *) die "base no permitida" ;; esac; }   # solo lectura: admite tambien _previo

case "${1:-}" in
  backup)    shift; cmd_backup "$@" ;;
  restore)   shift; cmd_restore "$@" ;;
  recuperar) shift; base_valida "${1:-banco}" || die "base no permitida"; recuperar "${1:-banco}"; echo "Recuperacion terminada para '${1:-banco}'." ;;
  descartar) shift; cmd_descartar "$@" ;;
  huella)    lectura huella "$2" ;;
  tablas)    lectura tablas_huella "$2" ;;
  manifiesto) lectura manifiesto "$2" ;;
  *) echo "Uso: respaldo.sh backup ARCHIVO [BASE] | restore ARCHIVO [BASE] --yes | recuperar [BASE] | descartar [BASE] | huella|tablas|manifiesto [BASE]" >&2; exit 64 ;;
esac
