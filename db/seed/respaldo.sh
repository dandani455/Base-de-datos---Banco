#!/bin/sh
# respaldo.sh - Etapa 14 - Respaldo y restauracion PROTEGIDOS de la BD (P-DEMO-3), DENTRO del contenedor "db" (sh de busybox).
#   respaldo.sh backup  ARCHIVO [BASE]          pg_dump -Fc + manifiesto ARCHIVO.huella. El manifiesto y el volcado salen de UN MISMO SNAPSHOT (transaccion REPEATABLE READ que
#                                               exporta su snapshot y pg_dump --snapshot): corresponden EXACTAMENTE al mismo contenido aunque la BD cambie (o cambie y se revierta)
#                                               durante el respaldo. RECHAZA una BD con v_integridad_global.ok = false (evaluado en ese mismo snapshot).
#   respaldo.sh restore ARCHIVO [BASE] --yes    restaura SIN riesgo: valida archivo y manifiesto (que declare integridad ok), restaura en una BD de paso, EXIGE integridad ok en
#                                               ella y la compara tabla por tabla con el manifiesto; solo entonces intercambia: BASE -> BASE_retirada, paso -> BASE y, al final,
#                                               la BASE_retirada pasa a BASE_previo SIN eliminar el _previo anterior antes de que ese renombrado termine (se aparta como
#                                               BASE_previo_antiguo y solo se elimina cuando el nuevo _previo ya existe). Ante un error o una senal (HUP, INT, TERM) intenta
#                                               recuperarse sola; si NO lo consigue, termina con ERROR explicito (RECUPERACION INCOMPLETA) y deja las bases en un estado
#                                               recuperable con "respaldo.sh recuperar". Sin --yes no hace nada.
#   respaldo.sh recuperar [BASE]                termina o deshace un intercambio interrumpido (idempotente) y EXIGE un estado final consistente: la BD BASE existe y no quedan
#                                               BASE_retirada, BASE_previo_antiguo ni BASE_restaurando. Devuelve ERROR (codigo 1) si no lo consigue o si el estado es ambiguo.
#   respaldo.sh descartar [BASE]                elimina BASE_previo
#   respaldo.sh huella [BASE] | tablas [BASE] | manifiesto [BASE]     solo lectura (manifiesto: diagnostico y pruebas; NO es atomico, el de backup si)
# SERIALIZACION: backup, restore, recuperar y descartar sobre la MISMA base toman un candado consultivo de PostgreSQL (pg_try_advisory_lock, por base): sirve entre procesos y
#   conexiones independientes. Si esta ocupado esperan RESPALDO_ESPERA segundos (60 por omision; 0 = rechazar de inmediato) y luego terminan con ERROR "ocupado" (codigo 75).
#   El candado lo sostiene una sesion propia que se libera al terminar el script (con exito, error o senal) y tambien si el proceso muere por kill -9 (un vigilante la cierra).
# BASE por defecto: banco. Solo se admiten nombres banco o banco_<letras/digitos>; NUNCA banco_test, *_restaurando, *_previo, *_retirada ni *_previo_antiguo.
# La restauracion es para el MISMO cluster (los roles banco_* son globales y no viajan en el volcado).
# GANCHOS DE PRUEBAS (solo si RESPALDO_ENTORNO_PRUEBAS=1 y la base NO es "banco"; si no, se IGNORAN y se avisa): RESPALDO_FALLA = error_entre | term_entre | kill_entre |
#   kill_despues | kill_apartado | pausa_dump | pausa_restore | pausa_entre ; RESPALDO_FALLA_RENAME = transiciones que FALLAN: retirar, poner, apartar, cerrar,
#   deshacer_apartar, recuperar_retirada.
U=${PGUSER:-postgres}
TABLAS="public.usuario public.cuenta public.bolsillo public.cdt_definicion public.cdt public.credito_producto public.credito public.cuota public.transaccion public.reloj public.parametro audit.evento"

# Ganchos protegidos: sin el indicador explicito de entorno de pruebas las variables de fallo se descartan (no pueden provocar terminaciones ni alterar operaciones reales).
if [ "${RESPALDO_ENTORNO_PRUEBAS:-}" != "1" ]; then
  if [ -n "${RESPALDO_FALLA:-}${RESPALDO_FALLA_RENAME:-}" ]; then echo "AVISO: RESPALDO_FALLA / RESPALDO_FALLA_RENAME se IGNORAN (falta RESPALDO_ENTORNO_PRUEBAS=1)." >&2; fi
  unset RESPALDO_FALLA RESPALDO_FALLA_RENAME
fi
# hook NOMBRE : verdadero solo si el entorno de pruebas esta habilitado, la base objetivo NO es la real ("banco") y RESPALDO_FALLA = NOMBRE
hook() { [ "${RESPALDO_ENTORNO_PRUEBAS:-}" = "1" ] && [ "${B:-banco}" != "banco" ] && [ "${RESPALDO_FALLA:-}" = "$1" ]; }
falla_rename() {
  [ "${RESPALDO_ENTORNO_PRUEBAS:-}" = "1" ] && [ "${B:-banco}" != "banco" ] || return 1
  case ",${RESPALDO_FALLA_RENAME:-}," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

die() { echo "ERROR: $*" >&2; exit 1; }
Q() { psql -X -q -At -v ON_ERROR_STOP=1 -U "$U" -d "$1" -c "$2"; }                                   # Q BASE SQL
QH() { psql -X -q -At -v ON_ERROR_STOP=1 -U "$U" -d "$1" -c "SET TimeZone = 'UTC'" -c "SET DateStyle = 'ISO, MDY'" -c "SET IntervalStyle = 'postgres'" -c "$2"; }   # lecturas para la huella: ajustes EXPLICITOS de sesion (el ALTER DATABASE ... SET timezone pesa mas que PGOPTIONS), iguales a los de la transaccion del backup
existe() { Q postgres "SELECT count(*) FROM pg_database WHERE datname = '$1'"; }

base_valida() {
  case "$1" in
    banco_test|*_restaurando|*_previo|*_retirada|*_previo_antiguo) return 1 ;;
    banco) return 0 ;;
    banco_[a-z0-9]*) printf '%s' "$1" | grep -Eq '^banco_[a-z0-9]+$' ;;
    *) return 1 ;;
  esac
}

# --- candado entre procesos ----------------------------------------------------------------------------------------------------------------------------------
# IMPORTANTE (contenedor "db"): el PID 1 del contenedor es el POSTMASTER y ADOPTA a todo proceso huerfano; si un hijo adoptado muere POR UNA SENAL o sale con un codigo distinto de 0
# (psql sale con 2 al perder la conexion), el postmaster lo toma por un proceso de servidor caido y REINICIA toda la instancia (recuperacion). Por eso aqui: (1) el titular del candado y el
# vigilante son subshells que SIEMPRE salen con 0 (envuelven a psql); (2) la sesion del candado se cierra desde el SERVIDOR (pg_terminate_backend), nunca con senales a psql; (3) liberar
# ESPERA (wait) a esos hijos antes de salir, para que no queden huerfanos; si el script muere por kill -9, el vigilante huerfano cierra la sesion y ambos salen con 0.
LOCK_SQL=/tmp/respaldo_lock.$$.sql; LOCK_OK=/tmp/respaldo_lock.$$.ok; LOCK_PID=/tmp/respaldo_lock.$$.pid; HOLDER=""; WATCH=""
# cerrar_sesion / liberar : cierra la sesion que sostiene el candado (en el servidor), espera a que titular y vigilante terminen y limpia; idempotente
cerrar_sesion() {
  if [ -s "$LOCK_PID" ]; then
    _bp=$(cat "$LOCK_PID")
    Q postgres "SELECT pg_terminate_backend($_bp)" >/dev/null 2>&1
  fi
  for _h in $HOLDER $WATCH; do
    _i=0; while kill -0 "$_h" 2>/dev/null && [ "$_i" -lt 60 ]; do _i=$((_i+1)); sleep 0.1; done
    kill -0 "$_h" 2>/dev/null || wait "$_h" 2>/dev/null
  done
  HOLDER=""; WATCH=""
}
liberar() { cerrar_sesion; rm -f "$LOCK_SQL" "$LOCK_OK" "$LOCK_PID"; }
# adquirir BASE : toma el candado de las operaciones sobre BASE (una sesion de PostgreSQL independiente lo sostiene); espera RESPALDO_ESPERA s y si sigue ocupado termina (75)
adquirir() {
  _base=$1; _espera=${RESPALDO_ESPERA:-60}; _t=0
  _k=$(Q postgres "SELECT hashtext('respaldo:$_base')") || die "no se pudo calcular el candado de '$_base'"
  cat > "$LOCK_SQL" <<SQL
SELECT pg_try_advisory_lock(7314, $_k) AS got \gset
\if :got
\o $LOCK_PID
SELECT pg_backend_pid();
\o
\! echo OK > "$LOCK_OK"
SELECT 1 \watch 1
\else
\! echo BUSY > "$LOCK_OK"
\endif
SQL
  while :; do
    rm -f "$LOCK_OK" "$LOCK_PID"
    ( psql -X -q -At -U "$U" -d postgres -f "$LOCK_SQL" >/dev/null 2>&1 </dev/null; exit 0 ) &
    HOLDER=$!
    # vigilante: si el script muere (kill -9) mientras el titular sigue vivo, cierra su sesion DESDE EL SERVIDOR; si el titular ya termino (BUSY, o liberar) sale sin hacer nada. Sale siempre con 0.
    ( while kill -0 $$ 2>/dev/null && kill -0 $HOLDER 2>/dev/null; do sleep 0.2; done
      if kill -0 $HOLDER 2>/dev/null && [ -s "$LOCK_PID" ]; then psql -X -q -At -U "$U" -d postgres -c "SELECT pg_terminate_backend($(cat "$LOCK_PID"))" >/dev/null 2>&1; fi
      exit 0 ) >/dev/null 2>&1 &
    WATCH=$!
    _w=0; while [ ! -s "$LOCK_OK" ] && [ "$_w" -lt 100 ]; do sleep 0.2; _w=$((_w+1)); done
    case "$(cat "$LOCK_OK" 2>/dev/null)" in
      OK) return 0 ;;
      BUSY)
        cerrar_sesion
        if [ "$_t" -ge "$_espera" ]; then
          rm -f "$LOCK_SQL" "$LOCK_OK" "$LOCK_PID"
          echo "ERROR: ocupado: otra operacion de respaldo/restauracion/recuperacion sobre '$_base' esta en curso (espera agotada: ${_espera}s)" >&2; exit 75
        fi
        _t=$((_t+1)); sleep 1 ;;
      *) liberar; die "no se pudo obtener el candado de '$_base' (PostgreSQL no respondio)" ;;
    esac
  done
}

# --- renombrados con reintentos y gancho de fallo ----------------------------------------------------------------------------------------------------------------
# renombrar TRANSICION ORIGEN DESTINO : cierra las conexiones del ORIGEN y reintenta hasta 5 veces; 0 = renombrado, 1 = no se pudo (nada cambio)
renombrar() {
  _et=$1; _o=$2; _d=$3; _i=0
  if falla_rename "$_et"; then echo "(fallo simulado de la transicion '$_et')" >&2; return 1; fi
  while [ "$_i" -lt 5 ]; do
    _i=$((_i+1))
    Q postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$_o' AND pid <> pg_backend_pid()" >/dev/null 2>&1
    Q postgres "ALTER DATABASE \"$_o\" RENAME TO \"$_d\"" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# --- huella ------------------------------------------------------------------------------------------------------------------------------------------------------
# SQL que devuelve las lineas de la huella: una por tabla (texto COMPLETO de cada fila, todas las columnas, ordenado) y una del esquema (funciones con dueño, permisos y
# SECURITY DEFINER; triggers con su estado). UNA sola sentencia: se usa tal cual dentro del snapshot del backup y en las lecturas de verificacion.
sql_lineas() {
  _s=""; _n=1
  for t in $TABLAS; do
    _s="${_s}SELECT 'tabla.$t=' || md5(coalesce((SELECT string_agg(x::text, E'\\n' ORDER BY x::text) FROM $t x), '')) AS l, $_n AS o UNION ALL "
    _n=$((_n+1))
  done
  _s="${_s}SELECT 'esquema=' || md5(concat_ws('#', (SELECT coalesce(string_agg(p.oid::regprocedure::text || ':' || coalesce(p.proacl::text, '') || ':' || pg_get_userbyid(p.proowner) || ':' || p.prosecdef::text, ',' ORDER BY p.oid::regprocedure::text), '') FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')), (SELECT coalesce(string_agg(tgrelid::regclass::text || '.' || tgname || ':' || tgenabled::text, ',' ORDER BY tgrelid::regclass::text, tgname), '') FROM pg_trigger WHERE NOT tgisinternal))), 99"
  printf '%s' "SELECT l FROM ($_s) z ORDER BY o"
}
tablas_huella() { QH "$1" "$(sql_lineas)"; }
huella() { _l=$(tablas_huella "$1") || return 1; printf '%s\n' "$_l" | md5sum | cut -d' ' -f1; }
integridad() { Q "$1" "SELECT ok FROM public.v_integridad_global"; }
manifiesto() {                                                                                            # NO atomico: diagnostico y pruebas (el backup usa un snapshot)
  _t=$(tablas_huella "$1") || return 1
  _h=$(printf '%s\n' "$_t" | md5sum | cut -d' ' -f1)
  _u=$(Q "$1" "SELECT count(*) FROM public.usuario") || return 1
  _p=$(Q "$1" "SELECT patas FROM public.v_integridad_global") || return 1
  _o=$(integridad "$1") || return 1
  _e=$(Q "$1" "SELECT count(*) FROM audit.evento") || return 1
  printf '%s\nhuella=%s\nusuarios=%s\npatas=%s\neventos=%s\nintegridad_ok=%s\nbase_origen=%s\n' "$_t" "$_h" "$_u" "$_p" "$_e" "$_o" "$1"
}
mval() { grep "^$2=" "$1" | head -n1 | cut -d= -f2-; }                                                 # mval ARCHIVO CLAVE

# --- cierre del intercambio y recuperacion -------------------------------------------------------------------------------------------------------------------------
# cerrar BASE : la BASE_retirada pasa a BASE_previo SIN perder el _previo anterior en ningun momento:
#   1) el _previo anterior se APARTA (renombra) como BASE_previo_antiguo; 2) la retirada pasa a _previo; 3) SOLO ENTONCES se elimina el apartado.
#   Si el paso 2 falla, el previo anterior vuelve a su nombre. Retoma un cierre interrumpido en cualquier punto. Devuelve 0 solo si TODO termino.
cerrar() {
  _B=$1; _R="${_B}_retirada"; _V="${_B}_previo"; _O="${_B}_previo_antiguo"
  _eV=$(existe "$_V"); _eO=$(existe "$_O")
  if [ "$_eV" = "1" ] && [ "$_eO" = "1" ]; then
    echo "ERROR: estado ambiguo: existen '$_V' y '$_O' a la vez con '$_R' pendiente; nada se elimino. Revisa a mano cual conservar." >&2; return 1
  fi
  if [ "$_eV" = "1" ]; then
    renombrar apartar "$_V" "$_O" || { echo "ERROR: no se pudo apartar '$_V'; NO se elimino nada y el intercambio queda pendiente de cerrar ('$_R'): respaldo.sh recuperar" >&2; return 1; }
    hook kill_apartado && kill -KILL $$
  fi
  if ! renombrar cerrar "$_R" "$_V"; then
    if [ "$(existe "$_O")" = "1" ] && [ "$(existe "$_V")" = "0" ]; then
      renombrar deshacer_apartar "$_O" "$_V" || { echo "ERROR: RECUPERACION INCOMPLETA: '$_R' no pudo pasar a '$_V' y el previo anterior no pudo volver a su nombre; sigue INTACTO como '$_O'. Ejecuta: respaldo.sh recuperar" >&2; return 1; }
    fi
    echo "ERROR: no se pudo renombrar '$_R' a '$_V'; el previo anterior se conserva. Ejecuta: respaldo.sh recuperar" >&2; return 1
  fi
  if [ "$_eV" = "1" ] || [ "$(existe "$_O")" = "1" ]; then
    Q postgres "DROP DATABASE IF EXISTS \"$_O\" WITH (FORCE)" >/dev/null 2>&1
    [ "$(existe "$_O")" = "0" ] || { echo "ERROR: el intercambio quedo cerrado pero no se pudo eliminar '$_O' (inofensiva); respaldo.sh recuperar la elimina" >&2; return 1; }
  fi
  return 0
}

# sanear BASE : termina o deshace un intercambio interrumpido (idempotente). Estados (B = BASE, R = retirada, V = previo, O = previo_antiguo):
#   B ausente, R presente, O ausente -> el corte fue ENTRE los dos renombrados: R vuelve a llamarse B (la BD anterior)
#   B y R presentes (V y O no a la vez)  -> el intercambio ya se hizo: se CIERRA (cerrar)
#   B presente, R ausente, O presente    -> cierre casi terminado: si V existe se elimina O; si no, O vuelve a ser V
#   AMBIGUOS (se detiene sin tocar nada): B ausente con R y O a la vez; B, R, V y O a la vez.
# Siempre elimina la BD de paso. NO exige que B exista (una primera restauracion parte de una BASE inexistente). Devuelve 0 solo si no queda ningun estado intermedio.
sanear() {
  _B=$1; _R="${_B}_retirada"; _S="${_B}_restaurando"; _V="${_B}_previo"; _O="${_B}_previo_antiguo"
  _eB=$(existe "$_B"); _eR=$(existe "$_R"); _eV=$(existe "$_V"); _eO=$(existe "$_O")
  if [ "$_eB" = "0" ] && [ "$_eR" = "1" ] && [ "$_eO" = "1" ]; then
    echo "ERROR: estado AMBIGUO: no existe '$_B' pero existen '$_R' y '$_O' a la vez (no se sabe cual es la BD vigente); NO se toco nada. Revisa a mano." >&2; return 1
  fi
  if [ "$_eB" = "1" ] && [ "$_eR" = "1" ] && [ "$_eV" = "1" ] && [ "$_eO" = "1" ]; then
    echo "ERROR: estado AMBIGUO: existen '$_B', '$_R', '$_V' y '$_O' a la vez; NO se toco nada. Revisa a mano cual conservar." >&2; return 1
  fi
  if [ "$_eB" = "0" ] && [ "$_eR" = "1" ]; then
    if renombrar recuperar_retirada "$_R" "$_B"; then echo "Recuperada: la BD anterior volvio a llamarse '$_B'." >&2
    else echo "ERROR: RECUPERACION INCOMPLETA: no se pudo devolver '$_R' a '$_B'. La BD anterior sigue INTACTA como '$_R'. Repite: respaldo.sh recuperar" >&2; return 1; fi
  elif [ "$_eB" = "1" ] && [ "$_eR" = "1" ]; then
    cerrar "$_B" || { echo "ERROR: RECUPERACION INCOMPLETA: el intercambio de '$_B' no pudo cerrarse. Ninguna BD se elimino. Repite: respaldo.sh recuperar" >&2; return 1; }
    echo "Cerrado el intercambio pendiente: la BD anterior quedo como '$_V'." >&2
  elif [ "$_eB" = "1" ] && [ "$_eO" = "1" ]; then
    if [ "$_eV" = "1" ]; then
      Q postgres "DROP DATABASE IF EXISTS \"$_O\" WITH (FORCE)" >/dev/null 2>&1
      [ "$(existe "$_O")" = "0" ] || { echo "ERROR: RECUPERACION INCOMPLETA: no se pudo eliminar el resto '$_O'. Repite: respaldo.sh recuperar" >&2; return 1; }
    else
      renombrar deshacer_apartar "$_O" "$_V" || { echo "ERROR: RECUPERACION INCOMPLETA: no se pudo devolver '$_O' a '$_V' (sigue INTACTA). Repite: respaldo.sh recuperar" >&2; return 1; }
      echo "Recuperado: el previo anterior volvio a llamarse '$_V'." >&2
    fi
  fi
  Q postgres "DROP DATABASE IF EXISTS \"$_S\" WITH (FORCE)" >/dev/null 2>&1
  return 0
}
# recuperar_estricto BASE EXIGE_BASE : sanear + verificacion EXPLICITA del estado final. Con EXIGE_BASE=1 (comando recuperar y restauraciones sobre una BD que existia) la BD BASE
# debe existir: si no, ERROR y codigo 1 (nunca "exito" sin base principal). En todos los casos no debe quedar ningun estado intermedio (retirada, apartado, paso).
recuperar_estricto() {
  sanear "$1" || return 1
  if [ "${2:-1}" = "1" ] && [ "$(existe "$1")" != "1" ]; then
    echo "ERROR: RECUPERACION INCOMPLETA: la BD principal '$1' NO existe y no hay nada de donde recuperarla (retirada: $(existe "${1}_retirada"), previo: $(existe "${1}_previo"), apartado: $(existe "${1}_previo_antiguo")). Si '${1}_previo' es la que buscas, renombrala a mano." >&2; return 1
  fi
  for _n in "${1}_retirada" "${1}_previo_antiguo" "${1}_restaurando"; do
    [ "$(existe "$_n")" = "0" ] || { echo "ERROR: RECUPERACION INCOMPLETA: queda el estado intermedio '$_n'." >&2; return 1; }
  done
  return 0
}
recuperar_cmd() { if recuperar_estricto "$1" 1; then echo "Recuperacion terminada para '$1'."; else exit 1; fi; }

# --- backup --------------------------------------------------------------------------------------------------------------------------------------------------
cmd_backup() {
  F=$1
  [ -n "$F" ] || die "falta el archivo: respaldo.sh backup ARCHIVO [BASE]"
  Q "$B" "SELECT 1" >/dev/null 2>&1 || die "la BD '$B' no existe o no responde"
  [ "$(integridad "$B")" = "t" ] || die "la BD '$B' NO tiene la integridad en orden (v_integridad_global.ok): no se respalda un estado danado"
  rm -f "$F.tmp" "$F.huella.tmp" "$F.lineas.tmp" "$F.extra.tmp" "$F.rc" "$F.err.tmp"
  PAUSA=0; hook pausa_dump && PAUSA=4
  # UN solo snapshot para el manifiesto Y el volcado: una transaccion REPEATABLE READ exporta su snapshot, calcula las lineas de la huella y, SIN cerrar la transaccion,
  # lanza pg_dump --snapshot (psql \!): el volcado y el manifiesto describen exactamente el mismo estado, aunque la BD cambie (o cambie y se revierta) mientras tanto.
  cat > "$F.sql.tmp" <<SQL
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL TimeZone = 'UTC';
SET LOCAL DateStyle = 'ISO, MDY';
SET LOCAL IntervalStyle = 'postgres';
SELECT pg_export_snapshot() AS snap \gset
SELECT CASE WHEN ok THEN 't' ELSE 'f' END AS integ FROM public.v_integridad_global \gset
\o $F.lineas.tmp
$(sql_lineas);
\o
\o $F.extra.tmp
SELECT 'usuarios=' || (SELECT count(*) FROM public.usuario) || E'\npatas=' || (SELECT patas FROM public.v_integridad_global) || E'\neventos=' || (SELECT count(*) FROM audit.evento) || E'\nintegridad_ok=' || :'integ';
\o
\setenv SNAP :snap
\if :integ
\! sleep $PAUSA; pg_dump -U $U -Fc -d $B --snapshot="\$SNAP" -f "$F.tmp"; echo \$? > "$F.rc"
\endif
COMMIT;
SQL
  psql -X -q -v ON_ERROR_STOP=1 -U "$U" -d "$B" -f "$F.sql.tmp" >/dev/null 2>"$F.err.tmp" || { cat "$F.err.tmp" >&2; rm -f "$F.sql.tmp" "$F.err.tmp" "$F.tmp" "$F.lineas.tmp" "$F.extra.tmp" "$F.rc"; die "fallo la sesion de respaldo (snapshot y manifiesto)"; }
  rm -f "$F.sql.tmp" "$F.err.tmp"
  [ "$(mval "$F.extra.tmp" integridad_ok)" = "t" ] || { rm -f "$F.tmp" "$F.lineas.tmp" "$F.extra.tmp" "$F.rc"; die "la BD '$B' NO tiene la integridad en orden (v_integridad_global.ok): no se respalda un estado danado"; }
  [ "$(cat "$F.rc" 2>/dev/null)" = "0" ] || { rm -f "$F.tmp" "$F.lineas.tmp" "$F.extra.tmp" "$F.rc"; die "pg_dump fallo"; }
  pg_restore -l "$F.tmp" >/dev/null 2>&1 || { rm -f "$F.tmp" "$F.lineas.tmp" "$F.extra.tmp" "$F.rc"; die "el respaldo generado no se puede leer (pg_restore -l)"; }
  { cat "$F.lineas.tmp"; printf 'huella=%s\n' "$(md5sum < "$F.lineas.tmp" | cut -d' ' -f1)"; cat "$F.extra.tmp"; printf 'base_origen=%s\nconsistencia=snapshot\n' "$B"; } > "$F.huella.tmp"
  rm -f "$F.lineas.tmp" "$F.extra.tmp" "$F.rc"
  mv "$F.tmp" "$F"; mv "$F.huella.tmp" "$F.huella"
  echo "Respaldo de '$B' guardado en $F ($(wc -c < "$F" | tr -d ' ') bytes). Huella: $(mval "$F.huella" huella)"
}

# --- restore -------------------------------------------------------------------------------------------------------------------------------------------------
# espera cortable: "sleep N" en segundo plano + wait, para que una senal (TERM, HUP) actue de inmediato (solo ganchos de pruebas)
pausar() { sleep "$1" & _sl=$!; wait "$_sl"; }
cmd_restore() {
  F=$1; SI=$2
  [ -n "$F" ] || die "falta el archivo: respaldo.sh restore ARCHIVO [BASE] --yes"
  [ "$SI" = "--yes" ] || die "la restauracion REEMPLAZA la BD '$B' (la actual queda como ${B}_previo). Repite con --yes para confirmar."
  eB0=$(existe "$B")                                                  # ¿existia la BD al empezar? (una primera restauracion parte de una BASE inexistente)
  sanear "$B" || die "hay un intercambio anterior sin terminar (o un estado ambiguo) y no se pudo sanear; no se restaura nada (ejecuta respaldo.sh recuperar)"
  # 1) validar el archivo y su manifiesto ANTES de tocar nada
  [ -s "$F" ] || die "el archivo no existe o esta vacio: $F"
  [ -s "$F.huella" ] || die "falta el manifiesto $F.huella (un respaldo hecho con 'backup' siempre lo trae)"
  [ "$(mval "$F.huella" integridad_ok)" = "t" ] || die "el manifiesto NO declara integridad en orden (integridad_ok=$(mval "$F.huella" integridad_ok)): no se restaura"
  pg_restore -l "$F" > /tmp/respaldo_toc.$$ 2>/dev/null || { rm -f /tmp/respaldo_toc.$$; die "el archivo no es un respaldo valido de pg_dump -Fc"; }
  for t in 'public usuario' 'public transaccion' 'public reloj' 'audit evento'; do
    grep -q "TABLE $t " /tmp/respaldo_toc.$$ || { rm -f /tmp/respaldo_toc.$$; die "el respaldo no parece ser el de este banco (falta la tabla ${t#* })"; }
  done
  rm -f /tmp/respaldo_toc.$$
  S="${B}_restaurando"; R="${B}_retirada"
  # a partir de aqui, cualquier error o senal intenta dejar la BD recuperable; si no lo consigue, lo dice con un ERROR explicito y termina con codigo distinto de 0.
  # Los traps tambien liberan el candado de la operacion.
  trap 'trap - EXIT INT TERM HUP; recuperar_estricto "$B" "$eB0" || echo "ERROR: RECUPERACION INCOMPLETA tras la senal HUP: ejecuta respaldo.sh recuperar" >&2; liberar; exit 129' HUP
  trap 'trap - EXIT INT TERM HUP; recuperar_estricto "$B" "$eB0" || echo "ERROR: RECUPERACION INCOMPLETA tras la senal INT: ejecuta respaldo.sh recuperar" >&2; liberar; exit 130' INT
  trap 'trap - EXIT INT TERM HUP; recuperar_estricto "$B" "$eB0" || echo "ERROR: RECUPERACION INCOMPLETA tras la senal TERM: ejecuta respaldo.sh recuperar" >&2; liberar; exit 143' TERM
  trap '_rc=$?; trap - EXIT; recuperar_estricto "$B" "$eB0" || { echo "ERROR: RECUPERACION INCOMPLETA: ejecuta respaldo.sh recuperar" >&2; liberar; exit 1; }; liberar; exit $_rc' EXIT
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
  hook pausa_restore && pausar 8                                       # gancho de pruebas: la BD de paso ya esta lista y el candado tomado
  # 4) intercambio. Cada transicion es un renombrado verificado; el _previo anterior se conserva hasta que la nueva retirada ya es el _previo.
  eB=$(existe "$B")
  if [ "$eB" = "1" ]; then
    renombrar retirar "$B" "$R" || die "no se pudo retirar la BD '$B' (hay conexiones que vuelven a abrirse: deten el backend/pgAdmin y repite); la BD '$B' NO se modifico"
  fi
  # --- ventana entre los dos renombrados: aqui es donde se prueba la recuperacion ---
  hook pausa_entre && pausar 8
  hook term_entre && { kill -TERM $$; sleep 2; }
  hook kill_entre && kill -KILL $$
  if hook error_entre; then
    die "fallo simulado entre los dos renombrados (RESPALDO_FALLA=error_entre)"
  fi
  renombrar poner "$S" "$B" || die "no se pudo poner la BD restaurada como '$B'; la BD anterior se recupera"
  hook kill_despues && kill -KILL $$
  # 5) cerrar: la retirada pasa a _previo sin perder el _previo anterior
  if [ "$eB" = "1" ]; then
    cerrar "$B" || die "restaurada, pero el intercambio no pudo cerrarse: la BD anterior sigue como '$R' y el _previo anterior esta intacto (respaldo.sh recuperar lo termina)"
  fi
  trap - INT TERM HUP
  trap liberar EXIT
  echo "Restaurado: '$B' = respaldo $F (huella $(mval "$F.huella" huella)). La BD anterior quedo como '${B}_previo' (respaldo.sh descartar $B la elimina)."
}

cmd_descartar() {
  Q postgres "DROP DATABASE IF EXISTS \"${B}_previo\" WITH (FORCE)" >/dev/null && echo "Eliminada '${B}_previo' (si existia)."
}

lectura() { case "${2:-banco}" in banco*) "$1" "${2:-banco}" ;; *) die "base no permitida" ;; esac; }   # solo lectura: admite tambien _previo

# --- despacho: las operaciones que escriben toman el candado de la base y lo liberan SIEMPRE (EXIT, HUP, INT, TERM) -----------------------------------------------
# operacion BASE COMANDO [ARGS...] : valida la base, toma el candado de ESA base (entre procesos y conexiones independientes) y ejecuta el comando con B = BASE
operacion() {
  B=$1; shift
  base_valida "$B" || die "base no permitida: $B"
  adquirir "$B"
  trap liberar EXIT
  trap 'trap - EXIT; liberar; exit 129' HUP
  trap 'trap - EXIT; liberar; exit 130' INT
  trap 'trap - EXIT; liberar; exit 143' TERM
  "$@"
}
case "${1:-}" in
  backup)    operacion "${3:-banco}" cmd_backup "$2" ;;
  restore)   operacion "${3:-banco}" cmd_restore "$2" "$4" ;;
  recuperar) operacion "${2:-banco}" recuperar_cmd "${2:-banco}" ;;
  descartar) operacion "${2:-banco}" cmd_descartar ;;
  huella)    lectura huella "$2" ;;
  tablas)    lectura tablas_huella "$2" ;;
  manifiesto) lectura manifiesto "$2" ;;
  *) echo "Uso: respaldo.sh backup ARCHIVO [BASE] | restore ARCHIVO [BASE] --yes | recuperar [BASE] | descartar [BASE] | huella|tablas|manifiesto [BASE]" >&2; exit 64 ;;
esac
