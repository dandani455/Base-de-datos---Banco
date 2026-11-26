#!/bin/sh
# lib.sh - utilidades de las pruebas con CONEXIONES REALES y CONCURRENCIA (Etapa 2).
# Estos scripts corren DENTRO del contenedor "db" (sh de busybox, sin bash) y se conectan por TCP al host "db"
# con contrasena (autenticacion real, como el backend). Imprimen "PASS: etiqueta" o "FAIL: detalle".
# El runner los ejecuta con:  tr -d '\r' < script.sh | sh -s      (por eso aqui NO se puede leer stdin).
DB=${DB:-banco_test}
HOST=db
APP_PW=banco_app_dev
LECTOR_PW=banco_lector_dev
DEV_PW=banco_dev_dev
PROBE_PW=probe_dev_pw
PASSES=0
FAILS=0

pass() { echo "PASS: $1"; PASSES=$((PASSES+1)); }
fail() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }
fin()  { echo "RESUMEN: $PASSES pass, $FAILS fail"; [ "$FAILS" -eq 0 ]; }

# root SQL            : superusuario por el socket local (solo para preparar datos y verificar)
root() { psql -X -q -At -U postgres -d "$DB" -c "$1" 2>&1 </dev/null; }
# as ROL CLAVE SQL   : conexion REAL (TCP + contrasena) con ese rol
as()   { PGPASSWORD="$2" psql -X -q -At -h "$HOST" -U "$1" -d "$DB" -c "$3" 2>&1 </dev/null; }

eq() { # eq etiqueta esperado actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (esperado=[$2] actual=[$3])"; fi
}
contiene() { # contiene etiqueta salida patron(ERE, sin distinguir mayusculas)
  if printf '%s' "$2" | grep -qiE "$3"; then pass "$1"; else fail "$1 (el patron [$3] no aparece en: $2)"; fi
}
# denegado etiqueta ROL CLAVE SQL : exige un error de PRIVILEGIOS y que el estado de los saldos no cambie
denegado() {
  _h0=$(root "SELECT tests.huella_saldos()")
  _o=$(as "$2" "$3" "$4")
  _h1=$(root "SELECT tests.huella_saldos()")
  if printf '%s' "$_o" | grep -qiE 'permission denied|must be owner|must be superuser|not permitted|permission denied to set'; then
    if [ "$_h0" = "$_h1" ]; then pass "$1"; else fail "$1 (se denego, pero el estado cambio)"; fi
  else
    fail "$1 (se esperaba permiso denegado; salida: $_o)"
  fi
}
# rechazado etiqueta ROL CLAVE SQL patron : exige un ERROR cuyo texto coincida y que el estado no cambie
rechazado() {
  _h0=$(root "SELECT tests.huella_saldos()")
  _o=$(as "$2" "$3" "$4")
  _h1=$(root "SELECT tests.huella_saldos()")
  if printf '%s' "$_o" | grep -qiE "ERROR.*($5)"; then
    if [ "$_h0" = "$_h1" ]; then pass "$1"; else fail "$1 (se rechazo, pero el estado cambio)"; fi
  else
    fail "$1 (se esperaba ERROR con [$5]; salida: $_o)"
  fi
}
