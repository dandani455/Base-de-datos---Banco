#!/usr/bin/env bash
# qa/e2e.sh — Pruebas de punta a punta del stack completo, por HTTP y a través de nginx (igual que el navegador).
# Comprueba status y FORMA de cada respuesta contra lo que el front espera (front/src/api/types.ts).
#
# Requisitos: el stack arriba con la semilla demo (SEED=demo), curl y jq.
#   qa/e2e.sh                     flujos de cliente, seguridad y admin
#   qa/e2e.sh --apagon            además, el apagón de §10 (para y vuelve a iniciar db y backend)
# Variables: BASE_URL (http://localhost:8080) · COMPOSE ("docker compose", p. ej. "docker compose -p bancoqa --env-file x")
# Escribe datos (un usuario nuevo, envíos de $1.000, un bolsillo, un CDT): úsalo sobre un banco de pruebas.
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
API="$BASE_URL/api"
COMPOSE="${COMPOSE:-docker compose}"
CLAVE='Banco2026'   # clave de los usuarios de la semilla demo (ficticia)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CLI="$TMP/cli.jar"; ADM="$TMP/adm.jar"; NUEVO="$TMP/nuevo.jar"; OTRO="$TMP/otro.jar"
pass=0; fail=0; FALLOS=()

command -v jq >/dev/null || { echo "Falta jq"; exit 2; }

# req METODO RUTA [JAR] [BODY] -> deja status en $ST y el cuerpo en $TMP/r.json
req() {
  local m="$1" p="$2" jar="${3:-}" body="${4:-}"
  local args=(-s -o "$TMP/r.json" -w '%{http_code}' -X "$m")
  [ -n "$jar" ] && args+=(-b "$jar" -c "$jar")
  [ -n "$body" ] && args+=(-H 'content-type: application/json' -d "$body")
  ST="$(curl "${args[@]}" "$API$p" 2>/dev/null || echo 000)"
}
# chk "nombre" STATUS_ESPERADO 'filtro jq que debe dar true' (el filtro es opcional)
chk() {
  local n="$1" want="$2" f="${3:-}" ok=1
  [ "$ST" = "$want" ] || ok=0
  if [ $ok = 1 ] && [ -n "$f" ]; then jq -e "$f" "$TMP/r.json" >/dev/null 2>&1 || ok=0; fi
  if [ $ok = 1 ]; then pass=$((pass+1)); printf '  ok    %s\n' "$n"
  else
    fail=$((fail+1)); FALLOS+=("$n")
    printf '  FALLO %s  (esperado %s%s, vino %s) %s\n' "$n" "$want" "${f:+ y $f}" "$ST" "$(head -c 220 "$TMP/r.json" 2>/dev/null)"
  fi
}
login() { req POST /auth/login "$1" "{\"username\":\"$2\",\"password\":\"$CLAVE\"}"; }

echo "=== Banco Digital — E2E contra $BASE_URL ($(date '+%Y-%m-%d %H:%M'))"

echo "== Front (nginx)"
ST="$(curl -s -o "$TMP/r.json" -w '%{http_code}' "$BASE_URL/")"; chk 'GET / sirve el index.html' 200
ST="$(curl -s -o "$TMP/r.json" -w '%{http_code}' "$BASE_URL/cliente/balance")"; chk 'ruta SPA profunda devuelve index.html' 200
req GET /no-existe; chk 'ruta de API inexistente sin sesión → 401 (no 503)' 401

echo "== Público"
req GET /creditos/productos; chk 'GET /creditos/productos → lista de productos' 200 'type=="array" and length>=4 and (.[0]|has("id") and has("tasa") and has("plazo_max"))'

echo "== Registro y login"
R=$(( (RANDOM<<15 | RANDOM) % 900000000 + 100000000 ))
REG="{\"nombres\":\"Qa\",\"apellidos\":\"Prueba Docker\",\"cedula\":\"1$R\",\"correo\":\"qa$R@ejemplo.co\",\"telefono\":\"3$R\",\"fecha_nacimiento\":\"1995-04-10\",\"password\":\"$CLAVE\",\"acepta_politica\":true}"
req POST /auth/registro "" '{"nombres":"x","password":"corta"}'; chk 'registro con contraseña débil → 400' 400 '.error|test("8 caracteres")'
req POST /auth/registro "" "${REG/true/false}"; chk 'registro sin aceptar la política → 400' 400
req POST /auth/registro "" "$REG"; chk 'registro válido → username autogenerado' 200 '.username|test("^[a-z]+[0-9]{3,4}$")'
NUEVO_USER="$(jq -r '.username // empty' "$TMP/r.json")"
req POST /auth/registro "" "$REG"; chk 'registro duplicado (misma cédula) → 400' 400
if [ -n "$NUEVO_USER" ]; then
  login "$NUEVO" "$NUEVO_USER"; chk "login del usuario nuevo ($NUEVO_USER)" 200 '.rol=="CLIENTE"'
  req GET /transacciones "$NUEVO"; chk 'el usuario nuevo nace con 5 ingresos simulados' 200 'type=="array" and length>=5'
fi
req POST /auth/login "" '{"username":"jperez483","password":"Mala1234"}'; chk 'login con clave errada → "Credenciales inválidas"' 400 '.error=="Credenciales inválidas"'
login "$OTRO" bloqueado1; chk 'login de usuario bloqueado → mensaje exacto de §7.2' 400 '.error|test("restringida")'

echo "== Cliente (jperez483)"
login "$CLI" jperez483; chk 'login jperez483' 200 '.rol=="CLIENTE"'
req GET /yo "$CLI"; chk 'GET /yo' 200 '.username=="jperez483"'
req GET /perfil "$CLI"; chk 'GET /perfil' 200 '.numero_cuenta=="4001002003" and (.codigo_referido|length)==36'
req GET /dashboard "$CLI"; chk 'GET /dashboard' 200 '(.balance_total|type)=="number" and (.transacciones|type)=="array" and has("cdts") and has("creditos")'
req GET /bolsillos "$CLI"; chk 'GET /bolsillos' 200 '(.principal|type)=="number" and (.bolsillos|type)=="array"'
BOLSILLO="$(jq -r '.bolsillos[0].id // empty' "$TMP/r.json")"
req GET '/transacciones?limite=50' "$CLI"; chk 'GET /transacciones?limite=50 → lista (≤50)' 200 'type=="array" and length>0 and length<=50 and (.[0]|has("tipo") and has("monto") and has("fecha"))'
req GET /destinatario/4003004005 "$CLI"; chk 'GET /destinatario/:numero → nombre' 200 '(.nombre|type)=="string" and (.nombre|length)>0'
req POST /envios "$CLI" '{"numero_destino":"4003004005","monto":1000,"nota":"QA e2e"}'; chk 'envío de $1.000 a cgomez12' 200
req POST /envios "$CLI" '{"numero_destino":"4003004005","monto":999999999999,"nota":"QA"}'; chk 'envío sin saldo → 400 con mensaje de la BD' 400 '(.error|type)=="string"'
req POST /envios "$CLI" '{"numero_destino":"0000000000","monto":1000}'; chk 'envío a cuenta inexistente → 400' 400
req POST /bolsillos "$CLI" "{\"nombre\":\"QA $R\"}"; chk 'crear bolsillo' 200
[ -n "$BOLSILLO" ] && { req POST "/bolsillos/$BOLSILLO/ingresar" "$CLI" '{"monto":1000}'; chk 'meter $1.000 a un bolsillo' 200; }
[ -n "$BOLSILLO" ] && { req POST "/bolsillos/$BOLSILLO/retirar" "$CLI" '{"monto":1000}'; chk 'sacar $1.000 de un bolsillo' 200; }
req GET /cdts/definiciones "$CLI"; chk 'GET /cdts/definiciones' 200 'type=="array" and length>=1 and (.[0]|has("id") and has("plazo_dias"))'
DEF="$(jq -r 'if type=="array" then .[0].id // empty else empty end' "$TMP/r.json")"
if [ -n "$DEF" ]; then
  req POST /cdts/simular "$CLI" "{\"definicion_id\":\"$DEF\",\"monto\":1000000}"; chk 'simular CDT' 200 'has("generado_vencimiento")'
  req POST /cdts "$CLI" "{\"definicion_id\":\"$DEF\",\"monto\":1000000}"; chk 'crear CDT de $1.000.000' 200
fi
req GET /cdts "$CLI"; chk 'GET /cdts → lista' 200 'type=="array" and length>=1 and (.[0]|has("monto") and has("tiempo_restante"))'
req GET /creditos/productos "$CLI"
PROD="$(jq -r 'if type=="array" then (.[]|select(.nombre=="Libre inversión")|.id) else empty end' "$TMP/r.json" | head -1)"
if [ -n "$PROD" ]; then
  req POST /creditos/simular "$CLI" "{\"producto_id\":\"$PROD\",\"monto\":5000000,\"plazo\":12}"; chk 'simular crédito' 200 '(.cuota_mensual|type)=="number" and .cuota_mensual>0'
  req POST /creditos "$CLI" "{\"producto_id\":\"$PROD\",\"monto\":5000000,\"plazo\":12}"; chk 'segundo crédito vivo del mismo producto → 400' 400
fi
req GET /creditos/mis-creditos "$CLI"; chk 'GET /creditos/mis-creditos → lista' 200 'type=="array" and length>=2 and (.[0]|has("cuotas_pagadas"))'

echo "== Seguridad (§9)"
req GET /dashboard; chk 'sin sesión → 401' 401
req GET /admin/usuarios "$CLI"; chk 'cliente en ruta de admin → 403' 403
login "$OTRO" cgomez12 >/dev/null
req GET /bolsillos "$OTRO"; AJENO="$(jq -r '.bolsillos[0].id // empty' "$TMP/r.json")"
[ -n "$AJENO" ] && { req POST "/bolsillos/$AJENO/retirar" "$CLI" '{"monto":1}'; chk 'operar bolsillo ajeno (cambiando el id) → 403' 403; }
req POST /bolsillos/no-es-un-uuid/retirar "$CLI" '{"monto":1}'; chk 'id malformado → 403 "Recurso no encontrado" (no 503)' 403

echo "== Admin (admin1)"
login "$ADM" admin1; chk 'login admin1' 200 '.rol=="ADMIN"'
req GET '/admin/usuarios?busqueda=perez' "$ADM"; chk 'GET /admin/usuarios?busqueda=' 200 'type=="array" and length>=1 and (.[0]|has("username") and has("estado"))'
# la búsqueda es por nombre, cédula, correo o número de cuenta (§7.7), no por username
req GET '/admin/usuarios?busqueda=4003004005' "$ADM"; chk 'búsqueda por número de cuenta → cgomez12' 200 'length==1 and .[0].username=="cgomez12"'
UID_CG="$(jq -r 'if type=="array" then .[0].id // "x" else "x" end' "$TMP/r.json")"
req GET "/admin/usuarios/$UID_CG" "$ADM"; chk 'GET /admin/usuarios/:id (detalle)' 200 '(.balance|has("principal") and has("bolsillos") and has("cdts") and has("creditos")) and (.historial|type)=="array"'
req POST "/admin/usuarios/$UID_CG/bloquear" "$ADM"; chk 'bloquear usuario' 200 '.estado=="BLOQUEADO"'
login "$OTRO" cgomez12; chk 'el bloqueado ya no puede entrar' 400 '.error|test("restringida")'
req POST "/admin/usuarios/$UID_CG/desbloquear" "$ADM"; chk 'desbloquear usuario' 200 '.estado=="ACTIVO"'
login "$OTRO" cgomez12; chk 'desbloqueado vuelve a entrar' 200
req POST /admin/balance "$ADM" '{"usuario_id":"cgomez12","monto":1000,"nota":"QA: el banco ha enviado"}'; chk 'POST /admin/balance (por username)' 200
req GET /admin/reloj "$ADM"; chk 'GET /admin/reloj' 200 'has("usar_fecha_real") and has("fecha_actual")'
req GET /admin/tasas "$ADM"; chk 'GET /admin/tasas' 200 '(.cdts|type)=="array" and (.creditos|type)=="array" and has("mora")'
req GET /admin/esquema "$ADM"; chk 'GET /admin/esquema (Control)' 200 '(.tablas|type)=="array" and (.tablas|length)>=10'
req GET '/admin/tabla/usuario?pagina=1' "$ADM"; chk 'GET /admin/tabla/usuario (password_hash enmascarado)' 200 '(.filas|type)=="array" and (.filas|length)>0 and all(.filas[]; .password_hash=="••••")'
req GET '/admin/tabla/pg_authid?pagina=1' "$ADM"; chk 'tabla fuera de la whitelist → 400 "Tabla no permitida"' 400 '.error=="Tabla no permitida"'

if [ "${1:-}" = "--apagon" ]; then
  echo "== Apagón (§10)"
  $COMPOSE stop db >/dev/null 2>&1
  req GET /dashboard "$CLI"; chk 'BD apagada: /dashboard → 503 sin_conexion' 503 '.error=="sin_conexion"'
  req POST /auth/login "" "{\"username\":\"jperez483\",\"password\":\"$CLAVE\"}"; chk 'BD apagada: login → 503 sin_conexion' 503 '.error=="sin_conexion"'
  req GET /creditos/productos; chk 'BD apagada: público → 503 sin_conexion' 503 '.error=="sin_conexion"'
  ST="$(curl -s -o "$TMP/r.json" -w '%{http_code}' "$BASE_URL/")"; chk 'BD apagada: el front sigue sirviendo la página' 200
  [ "$($COMPOSE ps -q --status running backend | wc -l | tr -d ' ')" = 1 ]; ST=$([ $? = 0 ] && echo 200 || echo 000); chk 'BD apagada: el backend NO se cayó' 200
  $COMPOSE start db >/dev/null 2>&1
  for _ in $(seq 1 40); do req GET /dashboard "$CLI"; [ "$ST" = 200 ] && break; sleep 1; done
  chk 'BD de vuelta: /dashboard → 200 sin reiniciar nada (misma sesión)' 200
  $COMPOSE stop backend >/dev/null 2>&1
  req GET /dashboard "$CLI"; chk 'backend apagado: nginx responde 503 sin_conexion' 503 '.error=="sin_conexion"'
  $COMPOSE start backend >/dev/null 2>&1
  for _ in $(seq 1 30); do req GET /dashboard "$CLI"; [ "$ST" = 200 ] && break; sleep 1; done
  chk 'backend de vuelta: /dashboard → 200' 200
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || { printf '  - %s\n' "${FALLOS[@]}"; exit 1; }
