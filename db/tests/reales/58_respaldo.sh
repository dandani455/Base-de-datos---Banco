#!/bin/sh
# 58_respaldo.sh - Etapa 14 - Respaldo y restauracion PROTEGIDOS (P-DEMO-3) con el seed real, en BASES AISLADAS (banco_rs*): no toca banco ni banco_test.
#   A. backup: archivo valido + manifiesto, huella reproducible, bases invalidas rechazadas.
#   B. restore: sin --yes no hace nada; con --yes la BD vuelve EXACTAMENTE al respaldo (huella, integridad, reloj) y la anterior queda como _previo;
#      con conexiones abiertas; restaurar dos veces; descartar.
#   C. PROTECCIONES: archivo corrupto, sin manifiesto, manifiesto que no coincide, volcado de otra BD, nombres de BD no permitidos: se RECHAZAN y la BD
#      NO se modifica ni queda una BD de paso.
#   D. REPETIR LA DEMOSTRACION: restaurar y repetir el mismo adelanto da el mismo resultado (reproducibilidad funcional de la demostracion).
. /work/tests/reales/lib.sh
# FAIL_RAPIDO=1 (lo usa el arnes de mutaciones): la primera aserción fallida termina la prueba (la limpieza por trap se ejecuta)
if [ "${FAIL_RAPIDO:-}" = "1" ]; then fail() { echo "FAIL: $1"; exit 1; }; fi
SEED=${SEED_DIR:-/work/seed}
RS=banco_rs; TPL=banco_rs_tpl; RSB=banco_rs_base
RESP=$SEED/respaldo.sh
limpiar() { for d in $RS ${RS}_previo ${RS}_restaurando ${RS}_retirada ${RS}_previo_antiguo $TPL $RSB banco_rs_otra banco_rsx banco_rsy banco_rsz banco_rsj banco_rsj_retirada banco_rsj_previo banco_rsj_previo_antiguo banco_rsj_restaurando banco_rsn banco_rsm; do psql -X -q -U postgres -d postgres -c "DROP DATABASE IF EXISTS $d WITH (FORCE)" >/dev/null 2>&1 </dev/null; done; rm -rf /tmp/c58_*; }
trap limpiar EXIT
limpiar
PG() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$1" >/dev/null 2>&1 </dev/null; }
R() { sh $RESP "$@" 2>&1 </dev/null; }                       # respaldo.sh
RF() { _f=$1; shift; RESPALDO_ENTORNO_PRUEBAS=1 RESPALDO_FALLA=$_f sh $RESP "$@" 2>&1 </dev/null; }                 # respaldo.sh con un gancho de falla
RX() { _a=$1; _b=$2; shift 2; RESPALDO_ENTORNO_PRUEBAS=1 RESPALDO_FALLA=$_a RESPALDO_FALLA_RENAME=$_b sh $RESP "$@" 2>&1 </dev/null; }      # respaldo.sh con un gancho de falla Y/O transiciones de renombrado que fallan
huo() { if [ "$(existe $1)" = "1" ]; then hu $1; else echo -; fi; }                                                # huella de una BD, o "-" si no existe
verif_volcado() { # verif_volcado ARCHIVO -> "igual" si el CONTENIDO del volcado coincide linea a linea con el manifiesto
  PG "DROP DATABASE IF EXISTS banco_rsz WITH (FORCE)"; PG "CREATE DATABASE banco_rsz"
  pg_restore -U postgres --exit-on-error -d banco_rsz "$1" >/dev/null 2>&1 </dev/null || { echo error-restore; return; }
  sh $RESP tablas banco_rsz > /tmp/c58_z.txt 2>/dev/null </dev/null
  grep '^tabla\.\|^esquema=' "$1.huella" > /tmp/c58_zm.txt
  if cmp -s /tmp/c58_z.txt /tmp/c58_zm.txt; then echo igual; else echo distinto; fi
  PG "DROP DATABASE IF EXISTS banco_rsz WITH (FORCE)"
}
hu() { sh $RESP huella "$1" 2>/dev/null </dev/null; }
existe() { psql -X -q -At -U postgres -d postgres -c "SELECT count(*) FROM pg_database WHERE datname = '$1'" </dev/null; }

PG "CREATE DATABASE $RSB" && PG "ALTER DATABASE $RSB SET timezone TO 'America/Bogota'"
for f in /work/sql/*.sql; do psql -X -q -v ON_ERROR_STOP=1 -U postgres -d $RSB -f "$f" >/dev/null 2>&1 </dev/null || { fail "no se pudo aplicar $f"; fin; exit 1; }; done
PG "CREATE DATABASE $RS TEMPLATE $RSB" && PG "ALTER DATABASE $RS SET timezone TO 'America/Bogota'"
BASE=$RS SEED_DIR=$SEED sh $SEED/sembrar.sh demo >/dev/null 2>&1 </dev/null
DB=$RS
H0=$(hu $RS)
eq "0 base de pruebas sembrada: 12 usuarios, integridad en orden" "12|true" "$(root "SELECT (SELECT count(*) FROM public.usuario) || '|' || (SELECT ok FROM public.v_integridad_global)")"

# ============================================================================
# A. backup
# ============================================================================
OUT=$(R backup /tmp/c58_a.dump $RS); RC=$?
eq "A1 backup termina bien y deja el archivo y su manifiesto (.huella)" "0|t|t" "$RC|$([ -s /tmp/c58_a.dump ] && echo t || echo f)|$([ -s /tmp/c58_a.dump.huella ] && echo t || echo f)"
eq "A2 el manifiesto trae la huella actual, 12 usuarios, integridad ok y la base de origen" "$H0|12|t|$RS" "$(grep '^huella=' /tmp/c58_a.dump.huella | cut -d= -f2)|$(grep '^usuarios=' /tmp/c58_a.dump.huella | cut -d= -f2)|$(grep '^integridad_ok=' /tmp/c58_a.dump.huella | cut -d= -f2)|$(grep '^base_origen=' /tmp/c58_a.dump.huella | cut -d= -f2)"
eq "A3 el archivo es un volcado valido (pg_restore -l lo lee) y trae las tablas del banco" "0|t" "$(pg_restore -l /tmp/c58_a.dump >/dev/null 2>&1; echo $?)|$(pg_restore -l /tmp/c58_a.dump 2>/dev/null | grep -c 'TABLE public \(usuario\|transaccion\|reloj\) ' | sed 's/^3$/t/')"
eq "A4 la huella es REPRODUCIBLE (dos lecturas seguidas iguales) y cambia cuando cambia el estado" "t|t" "$([ "$(hu $RS)" = "$H0" ] && echo t || echo f)|$(root "SELECT public.hacer_transferencia((SELECT id FROM public.usuario WHERE username = 'cgomez12'), '4001002003', 1, 'huella', NULL)" >/dev/null; [ "$(hu $RS)" != "$H0" ] && echo t || echo f)"
OUT=$(R backup /tmp/c58_x.dump banco_test); RC=$?
eq "A5 no se respalda una base no permitida (banco_test) ni se crea archivo" "t|f" "$([ "$RC" -ne 0 ] && echo t || echo f)|$([ -e /tmp/c58_x.dump ] && echo t || echo f)"
OUT=$(R backup /tmp/c58_x.dump no_existe_xx); RC=$?
eq "A6 una base inexistente o con nombre ajeno al banco se rechaza sin dejar archivos temporales" "t|f|f" "$([ "$RC" -ne 0 ] && echo t || echo f)|$([ -e /tmp/c58_x.dump ] && echo t || echo f)|$([ -e /tmp/c58_x.dump.tmp ] && echo t || echo f)"
# volver al estado del respaldo A (la huella de A4 cambio): nuevo respaldo del estado actual y estado de referencia
R backup /tmp/c58_b.dump $RS >/dev/null; HB=$(grep '^huella=' /tmp/c58_b.dump.huella | cut -d= -f2)

# ============================================================================
# B. restore
# ============================================================================
# se modifica el estado: adelanto del reloj +10 dias, avance de lo guardado y una transferencia
ADM=$(root "SELECT id FROM public.usuario WHERE username = 'admin1'")
root "SELECT public.admin_set_reloj('$ADM', false, (public.hoy_banco() + 10)::text)" >/dev/null
psql -X -q -At -U postgres -d $RS -c "CALL public.sp_avanzar_todos()" >/dev/null 2>&1 </dev/null
G_ADEL=$(psql -X -q -At -U postgres -d $RS -c "SELECT count(*) FROM public.transaccion" </dev/null)
HM=$(hu $RS)
eq "B0 el estado se alejo del respaldo (otra huella, reloj en manual +10)" "t|f" "$([ "$HM" != "$HB" ] && echo t || echo f)|$(root "SELECT usar_fecha_real FROM public.reloj" | sed 's/true/t/')"
OUT=$(R restore /tmp/c58_b.dump $RS); RC=$?
eq "B1 SIN --yes no hace nada: error, la BD queda como estaba y no existe BD de paso" "t|$HM|0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(hu $RS)|$(existe ${RS}_restaurando)"
OUT=$(R restore /tmp/c58_b.dump $RS --yes); RC=$?
eq "B2 con --yes restaura: codigo 0, la huella vuelve a la del respaldo y no queda BD de paso" "0|$HB|0" "$RC|$(hu $RS)|$(existe ${RS}_restaurando)"
eq "B3 la BD restaurada esta en orden: integridad ok, 0 defensas caidas, reloj en modo REAL, 12 usuarios, jperez483 con su cuenta fija" "true|0|true|12|4001002003" "$(root "SELECT (SELECT ok FROM public.v_integridad_global) || '|' || (SELECT defensas_fallidas FROM public.v_integridad_global) || '|' || (SELECT usar_fecha_real FROM public.reloj) || '|' || (SELECT count(*) FROM public.usuario) || '|' || (SELECT c.numero_cuenta FROM public.cuenta c JOIN public.usuario u ON u.id = c.usuario_id WHERE u.username = 'jperez483')")"
eq "B4 la BD anterior (con el adelanto) quedo como ${RS}_previo: es la vuelta atras" "1|$HM" "$(existe ${RS}_previo)|$(hu ${RS}_previo 2>/dev/null)"
eq "B5 el rol de acceso sigue funcionando sobre la BD restaurada (banco_app por TCP: validar_sesion de jperez483)" "jperez483" "$(as banco_app "$APP_PW" "SELECT public.validar_sesion('$(root "SELECT id FROM public.usuario WHERE username = 'jperez483'")') ->> 'username'")"
eq "B6 la zona horaria de la BD restaurada es America/Bogota y los permisos de las funciones siguen (banco_app ejecuta 40)" "America/Bogota|40" "$(root "SHOW timezone")|$(root "SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND pg_get_userbyid(p.proowner) = 'banco_owner' AND has_function_privilege('banco_app', p.oid, 'EXECUTE')")"
# conexion abierta durante la restauracion
( psql -X -q -At -U postgres -d $RS -c "SELECT pg_sleep(600)" >/dev/null 2>&1 </dev/null ) & sleep 1      # la conexion abierta dura MUCHO mas que la restauracion: solo termina si el restore la cierra
OUT=$(R restore /tmp/c58_b.dump $RS --yes); RC=$?
psql -X -q -U postgres -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$RS' AND pid <> pg_backend_pid()" >/dev/null 2>&1 </dev/null; wait 2>/dev/null
eq "B7 restaurar con una conexion ABIERTA en la BD (backend, pgAdmin) funciona: la cierra y la huella es la del respaldo" "0|$HB|1" "$RC|$(hu $RS)|$(existe ${RS}_previo)"
R descartar $RS >/dev/null
eq "B8 descartar elimina la BD _previo y no toca la actual" "0|$HB" "$(existe ${RS}_previo)|$(hu $RS)"

# ============================================================================
# C. Protecciones: nada se rechaza a medias
# ============================================================================
H1=$(hu $RS)
head -c 2000 /tmp/c58_b.dump > /tmp/c58_corrupto.dump; cp /tmp/c58_b.dump.huella /tmp/c58_corrupto.dump.huella
OUT=$(R restore /tmp/c58_corrupto.dump $RS --yes); RC=$?
eq "C1 un archivo CORRUPTO (truncado) se rechaza antes de tocar la BD; no queda BD de paso ni _previo" "t|$H1|0|0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(hu $RS)|$(existe ${RS}_restaurando)|$(existe ${RS}_previo)"
cp /tmp/c58_b.dump /tmp/c58_sinman.dump
OUT=$(R restore /tmp/c58_sinman.dump $RS --yes); RC=$?
eq "C2 un respaldo SIN manifiesto se rechaza (no se puede verificar) y la BD no cambia" "t|t|$H1" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -qi 'falta el manifiesto' && echo t || echo f)|$(hu $RS)"
cp /tmp/c58_b.dump /tmp/c58_mal.dump; sed 's/^tabla.public.usuario=.*/tabla.public.usuario=00000000000000000000000000000000/' /tmp/c58_b.dump.huella > /tmp/c58_mal.dump.huella
OUT=$(R restore /tmp/c58_mal.dump $RS --yes); RC=$?
eq "C3 un manifiesto que NO coincide con el contenido (una tabla distinta) se rechaza DESPUES de restaurar en la BD de paso, NOMBRANDO la tabla: la BD no cambia, la de paso se elimina y no se crea _previo" "t|t|t|$H1|0|0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -qi 'NO coincide' && echo t || echo f)|$(printf '%s' "$OUT" | grep -q 'public.usuario' && echo t || echo f)|$(hu $RS)|$(existe ${RS}_restaurando)|$(existe ${RS}_previo)"
PG "CREATE DATABASE banco_rs_otra"; psql -X -q -U postgres -d banco_rs_otra -c "CREATE TABLE t(x int)" >/dev/null 2>&1 </dev/null
pg_dump -U postgres -Fc -d banco_rs_otra -f /tmp/c58_otra.dump 2>/dev/null; cp /tmp/c58_b.dump.huella /tmp/c58_otra.dump.huella
OUT=$(R restore /tmp/c58_otra.dump $RS --yes); RC=$?
eq "C4 el volcado de OTRA base (sin las tablas del banco) se rechaza y la BD no cambia" "t|t|$H1" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -qi 'no parece' && echo t || echo f)|$(hu $RS)"
for b in banco_test algo_previo banco_rs_restaurando otra_base 'banco;DROP'; do
  OUT=$(R restore /tmp/c58_b.dump "$b" --yes); [ "$?" -ne 0 ] && RCx="$RCx t" || RCx="$RCx f"
done
eq "C5 las bases NO permitidas (banco_test, *_previo, *_restaurando, ajenas, con caracteres raros) se rechazan en restore" " t t t t t" "$RCx"
OUT=$(R restore /tmp/no_existe.dump $RS --yes); RC=$?
eq "C6 un archivo que no existe se rechaza con mensaje claro" "t|$H1" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(hu $RS)"
eq "C7 tras todas las pruebas de proteccion la BD sigue intacta (huella e integridad) y no sobran bases de paso ni _previo" "$H1|t|0|0" "$(hu $RS)|$(root "SELECT ok FROM public.v_integridad_global")|$(existe ${RS}_restaurando)|$(existe ${RS}_previo)"

# ============================================================================
# E. Integridad: ni backup ni restore aceptan una BD danada (correccion de la auditoria, punto 1)
# ============================================================================
PG "CREATE DATABASE banco_rsx TEMPLATE $RS" && PG "ALTER DATABASE banco_rsx SET timezone TO 'America/Bogota'"
psql -X -q -U postgres -d banco_rsx -c "ALTER TABLE public.cuenta DISABLE TRIGGER trg_zz_proteger_cuenta" -c "UPDATE public.cuenta SET balance = balance + 1 WHERE numero_cuenta = '4001002003'" >/dev/null 2>&1 </dev/null
eq "E0 el sabotaje (saldo alterado a mano con el guardia apagado) deja v_integridad_global.ok = false en la BD de prueba" "f" "$(psql -X -q -At -U postgres -d banco_rsx -c "SELECT ok FROM public.v_integridad_global" </dev/null)"
OUT=$(R backup /tmp/c58_dan.dump banco_rsx); RC=$?
eq "E1 backup RECHAZA una BD con integridad en false, con un mensaje que lo dice, y no deja archivos ni temporales" "t|t|f|f|f" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -qi 'integridad' && echo t || echo f)|$([ -e /tmp/c58_dan.dump ] && echo t || echo f)|$([ -e /tmp/c58_dan.dump.huella ] && echo t || echo f)|$([ -e /tmp/c58_dan.dump.tmp ] && echo t || echo f)"
sed 's/^integridad_ok=.*/integridad_ok=f/' /tmp/c58_b.dump.huella > /tmp/c58_ifalse.dump.huella; cp /tmp/c58_b.dump /tmp/c58_ifalse.dump
OUT=$(R restore /tmp/c58_ifalse.dump $RS --yes); RC=$?
eq "E2 restore RECHAZA un manifiesto que declara integridad_ok = f (antes de restaurar nada) y la BD no cambia" "t|t|$H1|0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -qi 'integridad' && echo t || echo f)|$(hu $RS)|$(existe ${RS}_restaurando)"
pg_dump -U postgres -Fc -d banco_rsx -f /tmp/c58_dan2.dump 2>/dev/null; sh $RESP manifiesto banco_rsx 2>/dev/null </dev/null | sed 's/^integridad_ok=.*/integridad_ok=t/' > /tmp/c58_dan2.dump.huella
OUT=$(R restore /tmp/c58_dan2.dump $RS --yes); RC=$?
eq "E3 restore EXIGE integridad verdadera en la BD restaurada aunque el manifiesto (falsificado con integridad_ok = t y las huellas correctas) coincida: se rechaza, la BD no cambia y no sobra la BD de paso" "t|t|$H1|0|0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -qi 'integridad' && echo t || echo f)|$(hu $RS)|$(existe ${RS}_restaurando)|$(existe ${RS}_previo)"
PG "DROP DATABASE IF EXISTS banco_rsx WITH (FORCE)"

# ============================================================================
# F. Huella: cualquier dato persistente relevante cambia la huella (correccion de la auditoria, punto 2)
# ============================================================================
HR=$(hu $RS)
cambia() { # cambia NUM SQL : clona RS, aplica el cambio (como superusuario, sin triggers) y devuelve 0 si la huella CAMBIO
  PG "DROP DATABASE IF EXISTS banco_rsy WITH (FORCE)"; PG "CREATE DATABASE banco_rsy TEMPLATE $RS" || return 2
  psql -X -q -v ON_ERROR_STOP=1 -U postgres -d banco_rsy -c "SET session_replication_role = replica" -c "$2" >/dev/null 2>&1 </dev/null || { echo "ERROR-SQL-$1"; return 2; }
  [ "$(hu banco_rsy)" != "$HR" ]
}
SIN=""
n=0
while IFS='|' read -r etq sql; do
  [ -n "$etq" ] || continue; n=$((n+1))
  r=$(cambia "$etq" "$sql") ; rc=$?
  [ "$rc" -eq 0 ] || SIN="$SIN $etq($r)"
done <<'CAMBIOS'
usuario.correo|UPDATE public.usuario SET correo = 'otro@correo.co' WHERE username = 'jperez483'
usuario.telefono|UPDATE public.usuario SET telefono = '3000000000' WHERE username = 'jperez483'
usuario.password_hash|UPDATE public.usuario SET password_hash = 'x' || password_hash WHERE username = 'jperez483'
usuario.correoverificado|UPDATE public.usuario SET correoverificado = NOT correoverificado WHERE username = 'cgomez12'
usuario.bono_referido_pagado|UPDATE public.usuario SET bono_referido_pagado = NOT bono_referido_pagado WHERE username = 'cgomez12'
cuenta.creado_en|UPDATE public.cuenta SET creado_en = creado_en + interval '1 second' WHERE numero_cuenta = '4001002003'
bolsillo.nombre|UPDATE public.bolsillo SET nombre = nombre || 'x' WHERE id = (SELECT id FROM public.bolsillo ORDER BY id LIMIT 1)
transaccion.nota|UPDATE public.transaccion SET nota = coalesce(nota, '') || 'x' WHERE id = (SELECT id FROM public.transaccion ORDER BY orden LIMIT 1)
transaccion.contraparte_nombre|UPDATE public.transaccion SET contraparte_nombre = 'Otro nombre' WHERE id = (SELECT id FROM public.transaccion WHERE contraparte_nombre IS NOT NULL ORDER BY orden LIMIT 1)
transaccion.fecha|UPDATE public.transaccion SET fecha = fecha - interval '1 minute' WHERE id = (SELECT id FROM public.transaccion ORDER BY orden LIMIT 1)
cdt.tasa_anual|UPDATE public.cdt SET tasa_anual = tasa_anual + 1 WHERE id = (SELECT id FROM public.cdt ORDER BY id LIMIT 1)
cdt_definicion.tasa_anual|UPDATE public.cdt_definicion SET tasa_anual = tasa_anual + 1 WHERE nombre = 'CDT 90 días'
credito.mora_acumulada|UPDATE public.credito SET mora_acumulada = mora_acumulada + 1 WHERE id = (SELECT id FROM public.credito ORDER BY id LIMIT 1)
credito.tasa_anual|UPDATE public.credito SET tasa_anual = tasa_anual + 1 WHERE id = (SELECT id FROM public.credito ORDER BY id LIMIT 1)
cuota.valor_cuota_original|UPDATE public.cuota SET valor_cuota_original = valor_cuota_original + 1 WHERE id = (SELECT id FROM public.cuota ORDER BY id LIMIT 1)
credito_producto.descripcion|UPDATE public.credito_producto SET descripcion = descripcion || 'x' WHERE nombre = 'Inmuebles'
parametro.bono_referido|UPDATE public.parametro SET bono_referido = bono_referido + 1
audit.evento.accion|UPDATE audit.evento SET accion = accion || 'X' WHERE id = (SELECT id FROM audit.evento ORDER BY id LIMIT 1)
permiso.funcion|REVOKE EXECUTE ON FUNCTION public.vista_dashboard(uuid) FROM banco_app
trigger.deshabilitado|ALTER TABLE public.cuenta DISABLE TRIGGER trg_zz_proteger_cuenta
CAMBIOS
eq "F1 la huella DETECTA cada una de las 20 alteraciones de datos o permisos (usuarios, cuentas, bolsillos, libro, CDT y catalogo, creditos, cuotas, productos, parametros, auditoria, permisos y triggers): ninguna queda sin detectar" "20|" "$n|$SIN"
PG "DROP DATABASE IF EXISTS banco_rsy WITH (FORCE)"; PG "CREATE DATABASE banco_rsy TEMPLATE $RS"
eq "F2 control: una copia SIN alteraciones tiene exactamente la misma huella (la huella es estable)" "$HR" "$(hu banco_rsy)"
eq "F3 el manifiesto trae una huella por tabla (12) y la del esquema" "12|1" "$(grep -c '^tabla\.' /tmp/c58_b.dump.huella)|$(grep -c '^esquema=' /tmp/c58_b.dump.huella)"
PG "DROP DATABASE IF EXISTS banco_rsy WITH (FORCE)"

# ============================================================================
# G. Intercambio de bases: un fallo o una interrupcion NO pierde banco ni el _previo anterior (correccion de la auditoria, punto 3)
# ============================================================================
tr1() { root "SELECT public.hacer_transferencia((SELECT id FROM public.usuario WHERE username = 'cgomez12'), '4001002003', $1, 'intercambio', NULL)" >/dev/null; }
tr1 11
HPRE=$(hu $RS)                                                       # estado A (con una transferencia mas)
R restore /tmp/c58_b.dump $RS --yes >/dev/null                       # RS = respaldo, _previo = estado A
tr1 12
H2=$(hu $RS)                                                         # estado B (el actual antes del restore que falla)
eq "G0 preparacion: banco_rs en el estado B, banco_rs_previo en el estado A (distintos entre si y del respaldo)" "t|$HPRE" "$([ "$H2" != "$HPRE" ] && [ "$H2" != "$HB" ] && [ "$HPRE" != "$HB" ] && echo t || echo f)|$(hu ${RS}_previo)"
OUT=$(RF error_entre restore /tmp/c58_b.dump $RS --yes); RC=$?
eq "G1 un FALLO entre los dos renombrados: el restore termina con error, banco_rs VUELVE a existir con su estado B, el _previo ANTERIOR sigue intacto y no sobran _retirada ni _restaurando" "t|$H2|$HPRE|0|0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(hu $RS)|$(hu ${RS}_previo)|$(existe ${RS}_retirada)|$(existe ${RS}_restaurando)"
OUT=$(RF term_entre restore /tmp/c58_b.dump $RS --yes); RC=$?
eq "G2 una senal TERM entre los dos renombrados (interrupcion controlable): codigo 143, banco_rs recuperada con su estado B, _previo intacto y sin restos" "143|$H2|$HPRE|0|0" "$RC|$(hu $RS)|$(hu ${RS}_previo)|$(existe ${RS}_retirada)|$(existe ${RS}_restaurando)"
OUT=$(RF kill_entre restore /tmp/c58_b.dump $RS --yes); RC=$?
eq "G3 un corte DURO (kill -9) entre los dos renombrados: banco_rs NO existe pero la BD anterior sigue entera como banco_rs_retirada y el _previo anterior esta intacto" "137|0|1|$HPRE" "$RC|$(existe $RS)|$(existe ${RS}_retirada)|$(hu ${RS}_previo)"
OUT=$(R recuperar $RS); RC=$?
eq "G4 'recuperar' devuelve la BD anterior a banco_rs (estado B), elimina la retirada y la de paso, y el _previo sigue intacto" "0|1|$H2|0|0|$HPRE" "$RC|$(existe $RS)|$(hu $RS)|$(existe ${RS}_retirada)|$(existe ${RS}_restaurando)|$(hu ${RS}_previo)"
OUT=$(R recuperar $RS); RC=$?
eq "G5 'recuperar' es IDEMPOTENTE: repetirla no cambia nada" "0|$H2|$HPRE" "$RC|$(hu $RS)|$(hu ${RS}_previo)"
OUT=$(RF kill_entre restore /tmp/c58_b.dump $RS --yes); RC=$?
OUT=$(R restore /tmp/c58_b.dump $RS --yes); RC2=$?
eq "G6 tras un corte duro, repetir el restore se AUTO-RECUPERA y termina bien: banco_rs = respaldo, el _previo es ahora el estado B (la BD retirada) y no sobra nada" "137|0|$HB|$H2|0|0" "$RC|$RC2|$(hu $RS)|$(hu ${RS}_previo)|$(existe ${RS}_retirada)|$(existe ${RS}_restaurando)"
tr1 13
H3=$(hu $RS)
OUT=$(RF kill_despues restore /tmp/c58_b.dump $RS --yes); RC=$?
eq "G7 un corte duro justo DESPUES del segundo renombrado: banco_rs ya es el respaldo y la BD anterior sigue como banco_rs_retirada (el intercambio solo falta cerrarlo)" "137|$HB|1" "$RC|$(hu $RS)|$(existe ${RS}_retirada)"
OUT=$(R recuperar $RS); RC=$?
eq "G8 'recuperar' CIERRA el intercambio: banco_rs sigue siendo el respaldo, el _previo es la BD anterior (estado C) y no sobra la retirada" "0|$HB|$H3|0" "$RC|$(hu $RS)|$(hu ${RS}_previo)|$(existe ${RS}_retirada)"
OUT=$(R restore /tmp/c58_b.dump $RS --yes); RC=$?
eq "G9 y la restauracion normal sigue funcionando despues de todas las interrupciones (huella del respaldo, integridad ok)" "0|$HB|t" "$RC|$(hu $RS)|$(psql -X -q -At -U postgres -d $RS -c "SELECT ok FROM public.v_integridad_global" </dev/null)"
R descartar $RS >/dev/null

# ============================================================================
# H. Fallos en CADA transicion del intercambio: nunca se pierde banco ni el _previo anterior, y un error es EXPLICITO (correccion de la 2.a auditoria, punto 1)
#    Transiciones: retirar (banco->retirada), poner (paso->banco), apartar (previo->previo_antiguo), cerrar (retirada->previo), deshacer_apartar, recuperar_retirada
# ============================================================================
prep() { # RS = estado X (HCUR), banco_rs_previo = estado Y (HPREV), sin retirada ni apartado
  R restore /tmp/c58_b.dump $RS --yes >/dev/null; tr1 21; R restore /tmp/c58_b.dump $RS --yes >/dev/null; tr1 22
  HCUR=$(hu $RS); HPREV=$(huo ${RS}_previo)
}
estado() { echo "$(huo $RS)|$(huo ${RS}_previo)|$(huo ${RS}_retirada)|$(huo ${RS}_previo_antiguo)|$(existe ${RS}_restaurando)"; }   # banco|previo|retirada|apartado|paso
prep
eq "H0 preparacion: banco_rs = estado X, banco_rs_previo = estado Y (distintos), sin retirada, apartado ni BD de paso" "$HCUR|$HPREV|-|-|0" "$(estado)"
OUT=$(RX '' retirar restore /tmp/c58_b.dump $RS --yes); RC=$?
eq "H1 FALLA 'retirar' (banco -> retirada): el restore termina con ERROR y NO cambia nada (banco = X, previo = Y, sin restos)" "t|$HCUR|$HPREV|-|-|0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(estado)"
OUT=$(RX '' poner restore /tmp/c58_b.dump $RS --yes); RC=$?
eq "H2 FALLA 'poner' (paso -> banco, con la BD ya retirada): ERROR y se RECUPERA solo: banco vuelve a ser X, el previo Y sigue intacto y no sobra nada" "t|t|$HCUR|$HPREV|-|-|0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -q 'Recuperada' && echo t || echo f)|$(estado)"
OUT=$(RX '' poner,recuperar_retirada restore /tmp/c58_b.dump $RS --yes); RC=$?
eq "H3 FALLA 'poner' Y la recuperacion automatica ('recuperar_retirada'): ERROR EXPLICITO 'RECUPERACION INCOMPLETA', codigo != 0, banco_rs no existe pero la BD anterior sigue INTACTA como banco_rs_retirada y el previo Y esta intacto" "t|t|-|$HPREV|$HCUR|-" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -q 'RECUPERACION INCOMPLETA' && echo t || echo f)|$(huo $RS)|$(huo ${RS}_previo)|$(huo ${RS}_retirada)|$(huo ${RS}_previo_antiguo)"
OUT=$(RX '' recuperar_retirada recuperar $RS); RC=$?
eq "H4 'recuperar' NO devuelve exito si no consigue recuperar: codigo != 0 y mensaje 'RECUPERACION INCOMPLETA'; las bases siguen como estaban" "t|t|-|$HCUR" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -q 'RECUPERACION INCOMPLETA' && echo t || echo f)|$(huo $RS)|$(huo ${RS}_retirada)"
OUT=$(R recuperar $RS); RC=$?
eq "H5 sin el fallo, 'recuperar' devuelve la BD anterior: codigo 0, banco = X, sin retirada y el previo Y intacto" "0|$HCUR|$HPREV|-|-|0" "$RC|$(estado)"
prep
OUT=$(RX '' apartar restore /tmp/c58_b.dump $RS --yes); RC=$?
eq "H6 FALLA 'apartar' (al cerrar): el _previo anterior NO se elimina (sigue Y), la BD nueva ya es banco y la anterior sigue como retirada; ERROR explicito" "t|t|$HB|$HPREV|$HCUR|-" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -q 'RECUPERACION INCOMPLETA' && echo t || echo f)|$(huo $RS)|$(huo ${RS}_previo)|$(huo ${RS}_retirada)|$(huo ${RS}_previo_antiguo)"
OUT=$(R recuperar $RS); RC=$?
eq "H7 'recuperar' CIERRA el intercambio: banco = respaldo, previo = la BD anterior X, sin retirada ni apartado" "0|$HB|$HCUR|-|-|0" "$RC|$(estado)"
prep
OUT=$(RX '' cerrar restore /tmp/c58_b.dump $RS --yes); RC=$?
eq "H8 FALLA 'cerrar' (retirada -> previo) tras apartar: el previo anterior VUELVE a su nombre (Y), la retirada sigue (X) y ningun dato se pierde; ERROR explicito" "t|$HB|$HPREV|$HCUR|-|0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(estado)"
OUT=$(R recuperar $RS); RC=$?
eq "H9 'recuperar' termina el cierre: previo = X, sin retirada ni apartado" "0|$HB|$HCUR|-|-|0" "$RC|$(estado)"
prep
OUT=$(RX '' cerrar,deshacer_apartar restore /tmp/c58_b.dump $RS --yes); RC=$?
eq "H10 FALLA 'cerrar' Y 'deshacer_apartar': ERROR explicito 'RECUPERACION INCOMPLETA'; el previo anterior (Y) esta INTACTO como banco_rs_previo_antiguo, la BD anterior (X) como retirada y banco ya es el respaldo; NADA se elimino" "t|t|$HB|-|$HCUR|$HPREV" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -q 'RECUPERACION INCOMPLETA' && echo t || echo f)|$(huo $RS)|$(huo ${RS}_previo)|$(huo ${RS}_retirada)|$(huo ${RS}_previo_antiguo)"
OUT=$(R recuperar $RS); RC=$?
eq "H11 'recuperar' retoma ese estado: la retirada (X) pasa a ser el previo, se elimina SOLO ENTONCES el apartado (Y) y no queda nada pendiente" "0|$HB|$HCUR|-|-|0" "$RC|$(estado)"
prep
OUT=$(RX kill_apartado '' restore /tmp/c58_b.dump $RS --yes); RC=$?
eq "H12 CORTE DURO (kill -9) justo despues de apartar el previo: banco = respaldo, retirada = X, el previo anterior (Y) esta INTACTO como apartado y no existe banco_rs_previo" "137|$HB|-|$HCUR|$HPREV" "$RC|$(huo $RS)|$(huo ${RS}_previo)|$(huo ${RS}_retirada)|$(huo ${RS}_previo_antiguo)"
OUT=$(R recuperar $RS); RC=$?
eq "H13 'recuperar' tras ese corte: previo = X, apartado eliminado solo despues, y es IDEMPOTENTE (segunda llamada sin cambios)" "0|$HB|$HCUR|-|-|0|0|$HB|$HCUR" "$RC|$(estado)|$(R recuperar $RS >/dev/null; echo $?)|$(huo $RS)|$(huo ${RS}_previo)"
# resto de un cierre casi terminado: previo y apartado presentes, sin retirada
PG "CREATE DATABASE ${RS}_previo_antiguo"
OUT=$(R recuperar $RS); RC=$?
eq "H14 resto 'banco_rs_previo_antiguo' con previo presente y sin retirada: 'recuperar' elimina SOLO el apartado y conserva banco y previo" "0|$HB|$HCUR|-|-|0" "$RC|$(estado)"
OUT=$(R recuperar $RS); RC=$?
eq "H15 con todo en orden 'recuperar' no cambia nada y devuelve exito" "0|$HB|$HCUR" "$RC|$(huo $RS)|$(huo ${RS}_previo)"
R restore /tmp/c58_b.dump $RS --yes >/dev/null; R descartar $RS >/dev/null

# ============================================================================
# I. Consistencia del backup: el manifiesto corresponde EXACTAMENTE al contenido del volcado (UN snapshot compartido), aunque la BD cambie (o cambie y se revierta)
#    alrededor de la captura (correccion de la 2.a auditoria, punto 2). La prueba restaura el VOLCADO en una BD aparte y compara su contenido con el manifiesto.
# ============================================================================
esperar_snapshot() { _i=0; while [ "$_i" -lt 40 ] && [ ! -s "$1.lineas.tmp" ]; do _i=$((_i+1)); sleep 1; done; }
# I1: cambio PERMANENTE despues del snapshot y ANTES de que arranque pg_dump (el gancho pausa_dump mantiene el snapshot 4 s)
HSNAP=$(hu $RS)
( RF pausa_dump backup /tmp/c58_i1.dump $RS >/tmp/c58_i1.out 2>&1; echo $? > /tmp/c58_i1.rc ) &
esperar_snapshot /tmp/c58_i1.dump
root "UPDATE public.parametro SET bono_referido = bono_referido + 1" >/dev/null; tr1 7
wait
eq "I1 backup con la BD CAMBIANDO entre el snapshot y pg_dump: termina bien (codigo 0) y el volcado contiene EXACTAMENTE lo que describe el manifiesto (no los cambios posteriores)" "0|igual" "$(cat /tmp/c58_i1.rc)|$(verif_volcado /tmp/c58_i1.dump)"
eq "I2 ...el manifiesto es la huella del estado ANTERIOR al cambio (la BD viva ya es otra: la diferencia ocurrio durante el respaldo)" "$HSNAP|t" "$(grep '^huella=' /tmp/c58_i1.dump.huella | cut -d= -f2)|$([ "$(hu $RS)" != "$HSNAP" ] && echo t || echo f)"
# I3: cambio y REVERSION (A-B-A) dentro de la ventana, y despues otro cambio-reversion con el backup ya terminado
R restore /tmp/c58_b.dump $RS --yes >/dev/null; R descartar $RS >/dev/null
HSNAP=$(hu $RS)
( RF pausa_dump backup /tmp/c58_i3.dump $RS >/tmp/c58_i3.out 2>&1; echo $? > /tmp/c58_i3.rc ) &
esperar_snapshot /tmp/c58_i3.dump
root "UPDATE public.parametro SET bono_referido = bono_referido + 1" >/dev/null; root "UPDATE public.parametro SET bono_referido = bono_referido - 1" >/dev/null
wait
eq "I3 cambio y REVERSION (A-B-A) durante el respaldo: codigo 0, volcado == manifiesto y la huella final de la BD viva es la del manifiesto (una comparacion antes/despues no habria visto nada)" "0|igual|$HSNAP" "$(cat /tmp/c58_i3.rc)|$(verif_volcado /tmp/c58_i3.dump)|$(grep '^huella=' /tmp/c58_i3.dump.huella | cut -d= -f2)"
# I4: un modificador CONTINUO (mas de 150 pares +1/-1 y una transferencia por ciclo) mientras se hacen 3 respaldos seguidos
( n=0; while [ $n -lt 120 ]; do psql -X -q -U postgres -d $RS -c "UPDATE public.parametro SET bono_referido = bono_referido + 1" -c "UPDATE public.parametro SET bono_referido = bono_referido - 1" >/dev/null 2>&1 </dev/null; n=$((n+1)); done ) &
MOD=$!
OKS=""
for k in 1 2 3; do
  RF x backup /tmp/c58_i4_$k.dump $RS >/dev/null 2>&1; rc=$?
  OKS="$OKS $rc:$(verif_volcado /tmp/c58_i4_$k.dump)"
done
wait $MOD
eq "I4 un modificador CONTINUO (cientos de cambios y reversiones) durante 3 respaldos seguidos: los 3 terminan bien y en los 3 el volcado coincide EXACTAMENTE con su manifiesto" " 0:igual 0:igual 0:igual" "$OKS"
R restore /tmp/c58_b.dump $RS --yes >/dev/null; R descartar $RS >/dev/null

# ============================================================================
# J. Estado final de 'recuperar': exige la base principal y ningun estado intermedio; los estados ambiguos se rechazan SIN tocar nada (2.a auditoria, punto 1)
# ============================================================================
mkdb() { PG "DROP DATABASE IF EXISTS $1 WITH (FORCE)"; PG "CREATE DATABASE $1 TEMPLATE $RSB"; psql -X -q -U postgres -d $1 -c "UPDATE public.parametro SET bono_referido = $2" >/dev/null 2>&1 </dev/null; }
limpiaj() { for d in banco_rsj banco_rsj_retirada banco_rsj_previo banco_rsj_previo_antiguo banco_rsj_restaurando; do PG "DROP DATABASE IF EXISTS $d WITH (FORCE)"; done; }
ej() { echo "$(huo banco_rsj)|$(huo banco_rsj_previo)|$(huo banco_rsj_retirada)|$(huo banco_rsj_previo_antiguo)|$(existe banco_rsj_restaurando)"; }   # banco|previo|retirada|apartado|paso
limpiaj
OUT=$(R recuperar banco_rsj); RC=$?
eq "J1 'recuperar' NO devuelve exito si la BD principal no existe (no hay nada que recuperar): codigo != 0 y mensaje explicito" "t|t" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -q 'NO existe' && echo t || echo f)"
mkdb banco_rsj_previo 222; E0=$(ej)
OUT=$(R recuperar banco_rsj); RC=$?
eq "J2 solo existe el previo (sin banco ni retirada): error explicito y el previo queda intacto" "t|$E0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(ej)"
limpiaj; mkdb banco_rsj_retirada 111; mkdb banco_rsj_previo_antiguo 333; E0=$(ej)
OUT=$(R recuperar banco_rsj); RC=$?
eq "J3 AMBIGUO: sin banco, con retirada y apartado a la vez: error 'AMBIGUO' y NO se renombra ni se elimina nada" "t|t|$E0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -q 'AMBIGUO' && echo t || echo f)|$(ej)"
limpiaj; mkdb banco_rsj 100; mkdb banco_rsj_retirada 111; mkdb banco_rsj_previo 222; mkdb banco_rsj_previo_antiguo 333; E0=$(ej)
OUT=$(R recuperar banco_rsj); RC=$?
eq "J4 AMBIGUO: banco, retirada, previo y apartado a la vez: error 'AMBIGUO' y NO se elimina ninguna" "t|t|$E0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -q 'AMBIGUO' && echo t || echo f)|$(ej)"
limpiaj; mkdb banco_rsj 100; mkdb banco_rsj_restaurando 999; H100=$(huo banco_rsj)
OUT=$(R recuperar banco_rsj); RC=$?
eq "J5 una BD de paso suelta con banco presente: 'recuperar' la elimina, devuelve exito y banco queda intacto" "0|$H100|0" "$RC|$(huo banco_rsj)|$(existe banco_rsj_restaurando)"
limpiaj; mkdb banco_rsj 100; mkdb banco_rsj_previo_antiguo 333; H333=$(huo banco_rsj_previo_antiguo)
OUT=$(R recuperar banco_rsj); RC=$?
eq "J6 resto 'previo_antiguo' sin previo ni retirada: vuelve a ser el previo (exito); no queda apartado" "0|$H333|-" "$RC|$(huo banco_rsj_previo)|$(huo banco_rsj_previo_antiguo)"
limpiaj; mkdb banco_rsj 100; mkdb banco_rsj_retirada 111; H111=$(huo banco_rsj_retirada)
OUT=$(R recuperar banco_rsj); RC=$?
eq "J7 intercambio hecho sin previo anterior: 'recuperar' CIERRA (la retirada pasa a previo) y no deja retirada" "0|$H111|-" "$RC|$(huo banco_rsj_previo)|$(huo banco_rsj_retirada)"
limpiaj; mkdb banco_rsj_retirada 111; H111=$(huo banco_rsj_retirada)
OUT=$(R recuperar banco_rsj); RC=$?
eq "J8 corte entre los dos renombrados (solo la retirada): 'recuperar' la devuelve a banco (exito) y exige que banco exista al final" "0|$H111|-" "$RC|$(huo banco_rsj)|$(huo banco_rsj_retirada)"
limpiaj; mkdb banco_rsj_retirada 111; E0=$(ej)
OUT=$(RX "" recuperar_retirada restore /tmp/c58_b.dump banco_rsj --yes); RC=$?
eq "J11 un restore que NO puede sanear un intercambio previo (falla el renombrado de la retirada a banco) se NIEGA a continuar: codigo != 0, no crea banco, la retirada queda intacta y no queda BD de paso" "t|t|$E0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -q 'sin terminar' && echo t || echo f)|$(ej)"
limpiaj
OUT=$(R restore /tmp/c58_b.dump banco_rsn --yes); RC=$?
eq "J9 una PRIMERA restauracion sobre una base que no existe sigue funcionando (recuperar exige la base solo cuando existia): codigo 0, la base queda con la huella del respaldo y sin previo" "0|$HB|-" "$RC|$(huo banco_rsn)|$(huo banco_rsn_previo)"
OUT=$(R restore /tmp/c58_mal.dump banco_rsm --yes); RC=$?
eq "J10 una primera restauracion que FALLA (manifiesto que no coincide) sobre una base inexistente: error normal, SIN falso 'RECUPERACION INCOMPLETA', la base no se crea y no queda BD de paso" "t|f|t|0|0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -q 'RECUPERACION INCOMPLETA' && echo t || echo f)|$(printf '%s' "$OUT" | grep -q 'NO coincide' && echo t || echo f)|$(existe banco_rsm)|$(existe banco_rsm_restaurando)"
PG "DROP DATABASE IF EXISTS banco_rsn WITH (FORCE)"; limpiaj

# ============================================================================
# K. Ganchos de pruebas protegidos: sin RESPALDO_ENTORNO_PRUEBAS=1 NO pueden provocar terminaciones ni alterar operaciones reales (2.a auditoria, punto 2)
# ============================================================================
R restore /tmp/c58_b.dump $RS --yes >/dev/null; R descartar $RS >/dev/null
OUT=$(RESPALDO_FALLA=kill_entre sh $RESP restore /tmp/c58_b.dump $RS --yes 2>&1 </dev/null); RC=$?
eq "K1 SIN el indicador, RESPALDO_FALLA=kill_entre (kill -9 entre los renombrados) se IGNORA con aviso: la restauracion termina bien (codigo 0) y banco_rs = respaldo" "0|t|$HB" "$RC|$(printf '%s' "$OUT" | grep -q 'se IGNORAN' && echo t || echo f)|$(hu $RS)"
OUT=$(RESPALDO_FALLA=error_entre RESPALDO_FALLA_RENAME=retirar,poner,apartar,cerrar,recuperar_retirada sh $RESP restore /tmp/c58_b.dump $RS --yes 2>&1 </dev/null); RC=$?
eq "K2 SIN el indicador, ni el fallo simulado ni los renombrados que 'fallan' tienen efecto: codigo 0, banco_rs = respaldo, el previo existe y no quedan restos" "0|$HB|1|0|0" "$RC|$(hu $RS)|$(existe ${RS}_previo)|$(existe ${RS}_retirada)|$(existe ${RS}_previo_antiguo)"
T0=$(date +%s); OUT=$(RESPALDO_FALLA=pausa_dump sh $RESP backup /tmp/c58_k3.dump $RS 2>&1 </dev/null); RC=$?; T1=$(date +%s)
eq "K3 SIN el indicador, el gancho 'pausa_dump' (4 s) NO retrasa un backup real: codigo 0 y menos de 4 s" "0|t" "$RC|$([ $((T1 - T0)) -lt 4 ] && echo t || echo f)"
T0=$(date +%s); OUT=$(RESPALDO_ENTORNO_PRUEBAS=1 RESPALDO_FALLA=pausa_dump sh $RESP backup /tmp/c58_k4.dump banco 2>&1 </dev/null); RC=$?; T1=$(date +%s)
eq "K4 CON el indicador pero sobre la BD REAL 'banco', los ganchos se rechazan igualmente (el backup de banco, de solo lectura, no se pausa): codigo 0 y menos de 4 s" "0|t" "$RC|$([ $((T1 - T0)) -lt 4 ] && echo t || echo f)"
R descartar $RS >/dev/null

# ============================================================================
# L. Concurrencia REAL entre procesos: una segunda operacion sobre la misma base no interfiere con la BD intermedia ni con la recuperacion de la primera
#    (candado consultivo de PostgreSQL por base; 2.a auditoria, punto 3)
# ============================================================================
A_inicia() { # A_inicia GANCHO : restauracion A (tarda en el gancho) con el candado tomado; $APID = su PID
  RESPALDO_ENTORNO_PRUEBAS=1 RESPALDO_FALLA=$1 sh $RESP restore /tmp/c58_b.dump $RS --yes >/tmp/c58_la.out 2>&1 </dev/null &
  APID=$!
}
matar() { # matar SENAL PID : solo si ese PID sigue siendo respaldo.sh (nunca se envia una senal a un PID reutilizado por otro proceso, p. ej. un backend de PostgreSQL)
  if ps -o pid,args | grep -v grep | grep -q "^ *$2 .*respaldo.sh"; then kill -$1 $2; else echo "matar: el PID $2 ya no es respaldo.sh" >&2; return 1; fi
}
espera_bd() { _i=0; while [ "$_i" -lt 60 ] && [ "$(existe $1)" != "$2" ]; do _i=$((_i+1)); sleep 1; done; }
R restore /tmp/c58_b.dump $RS --yes >/dev/null; tr1 41; R descartar $RS >/dev/null
R restore /tmp/c58_b.dump $RS --yes >/dev/null; tr1 42
HCUR=$(hu $RS); HPREV=$(huo ${RS}_previo)
PG "DROP DATABASE IF EXISTS banco_rsx WITH (FORCE)"; PG "CREATE DATABASE banco_rsx TEMPLATE $RSB"
A_inicia pausa_restore
espera_bd ${RS}_restaurando 1
RCB=$(RESPALDO_ESPERA=0 sh $RESP restore /tmp/c58_b.dump $RS --yes >/tmp/c58_lb1.out 2>&1 </dev/null; echo $?)
eq "L1 con una restauracion A en curso (candado tomado, BD de paso ya creada), una SEGUNDA restauracion sobre la misma base se rechaza de inmediato: codigo 75 'ocupado' y NO toca la BD de paso de A" "75|t|1" "$RCB|$(grep -q 'ocupado' /tmp/c58_lb1.out && echo t || echo f)|$(existe ${RS}_restaurando)"
RC1=$(RESPALDO_ESPERA=0 sh $RESP backup /tmp/c58_lb2.dump $RS >/tmp/c58_lb2.out 2>&1 </dev/null; echo $?)
RC2=$(RESPALDO_ESPERA=0 sh $RESP recuperar $RS >/tmp/c58_lb3.out 2>&1 </dev/null; echo $?)
RC3=$(RESPALDO_ESPERA=0 sh $RESP descartar $RS >/tmp/c58_lb4.out 2>&1 </dev/null; echo $?)
eq "L2 durante la restauracion de A tambien se rechazan (75) un backup, un 'recuperar' y un 'descartar' sobre la misma base; el backup rechazado no deja archivos y el previo de A no se elimino" "75|75|75|f|$HPREV" "$RC1|$RC2|$RC3|$([ -e /tmp/c58_lb2.dump ] && echo t || echo f)|$(huo ${RS}_previo)"
RC4=$(RESPALDO_ESPERA=0 sh $RESP backup /tmp/c58_lb5.dump banco_rsx >/dev/null 2>&1 </dev/null; echo $?)
eq "L3 el candado es POR BASE: mientras A restaura banco_rs, un backup de OTRA base (banco_rsx) se hace sin esperar" "0" "$RC4"
wait $APID; RCA=$?
eq "L4 la restauracion A termina bien pese a los intentos rechazados: codigo 0, banco_rs = respaldo, el previo es el estado anterior de A y no sobran retirada, apartado ni BD de paso" "0|$HB|$HCUR|0|0|0" "$RCA|$(hu $RS)|$(huo ${RS}_previo)|$(existe ${RS}_retirada)|$(existe ${RS}_previo_antiguo)|$(existe ${RS}_restaurando)"
RC5=$(RESPALDO_ESPERA=0 sh $RESP recuperar $RS >/dev/null 2>&1 </dev/null; echo $?)
eq "L5 el candado se LIBERA al terminar A: una operacion inmediata despues (recuperar con espera 0) obtiene el candado y termina bien" "0" "$RC5"
# serializacion: B espera a que A termine y despues restaura
R restore /tmp/c58_b.dump $RS --yes >/dev/null; tr1 43; HCUR=$(hu $RS)
A_inicia pausa_restore
espera_bd ${RS}_restaurando 1
( RESPALDO_ESPERA=90 sh $RESP restore /tmp/c58_b.dump $RS --yes >/tmp/c58_lb.out 2>&1 </dev/null; echo $? > /tmp/c58_lb.rc; date +%s > /tmp/c58_lb.t ) &
BWRAP=$!
wait $APID; RCA=$?; date +%s > /tmp/c58_la.t
wait $BWRAP
eq "L6 SERIALIZACION: una segunda restauracion B que espera (espera 90 s) se ejecuta DESPUES de que A termina: las dos terminan bien (0 y 0), B acaba despues que A y el resultado es consistente (banco_rs = respaldo, previo = respaldo, sin restos)" "0|0|t|$HB|$HB|0|0|0" "$RCA|$(cat /tmp/c58_lb.rc)|$([ "$(cat /tmp/c58_lb.t)" -ge "$(cat /tmp/c58_la.t)" ] && echo t || echo f)|$(hu $RS)|$(huo ${RS}_previo)|$(existe ${RS}_retirada)|$(existe ${RS}_previo_antiguo)|$(existe ${RS}_restaurando)"
# interrupcion de A (TERM) en la ventana entre renombrados MIENTRAS B espera para comenzar
R restore /tmp/c58_b.dump $RS --yes >/dev/null; tr1 45; HCUR=$(hu $RS)
A_inicia pausa_entre
espera_bd ${RS}_retirada 1
( RESPALDO_ESPERA=90 sh $RESP restore /tmp/c58_b.dump $RS --yes >/tmp/c58_lb.out 2>&1 </dev/null; echo $? > /tmp/c58_lb.rc ) &
BWRAP=$!
sleep 3
EXIST_MIENTRAS=$(existe $RS)
matar TERM $APID; wait $APID; RCA=$?
wait $BWRAP
eq "L7 INTERRUPCION (TERM) de A entre los dos renombrados mientras B espera para empezar: A termina con 143 y se recupera sola; B (que NO vio la BD intermedia: banco_rs no existia mientras esperaba) se ejecuta despues, sin mensajes de recuperacion, y deja banco_rs = respaldo con el estado anterior como previo" "143|0|0|f|$HB|$HCUR|0|0|0" "$RCA|$(cat /tmp/c58_lb.rc)|$EXIST_MIENTRAS|$(grep -q 'Recuperada\|Cerrado el intercambio' /tmp/c58_lb.out && echo t || echo f)|$(hu $RS)|$(huo ${RS}_previo)|$(existe ${RS}_retirada)|$(existe ${RS}_previo_antiguo)|$(existe ${RS}_restaurando)"
# corte duro (kill -9) de A entre los dos renombrados mientras B espera: el candado se libera solo y B recupera antes de restaurar
R restore /tmp/c58_b.dump $RS --yes >/dev/null; tr1 47; HCUR=$(hu $RS)
A_inicia pausa_entre
espera_bd ${RS}_retirada 1
( RESPALDO_ESPERA=90 sh $RESP restore /tmp/c58_b.dump $RS --yes >/tmp/c58_lb.out 2>&1 </dev/null; echo $? > /tmp/c58_lb.rc ) &
BWRAP=$!
sleep 2
matar KILL $APID; wait $APID 2>/dev/null; RCA=$?
wait $BWRAP
eq "L8 CORTE DURO (kill -9) de A entre los dos renombrados mientras B espera: el candado se libera solo (vigilante), B obtiene el candado, RECUPERA primero la BD intermedia ('Recuperada') y luego restaura: codigo 0, banco_rs = respaldo, el estado anterior es el previo y no quedan restos" "137|0|t|$HB|$HCUR|0|0|0" "$RCA|$(cat /tmp/c58_lb.rc)|$(grep -q 'Recuperada' /tmp/c58_lb.out && echo t || echo f)|$(hu $RS)|$(huo ${RS}_previo)|$(existe ${RS}_retirada)|$(existe ${RS}_previo_antiguo)|$(existe ${RS}_restaurando)"
R restore /tmp/c58_b.dump $RS --yes >/dev/null; R descartar $RS >/dev/null
PG "DROP DATABASE IF EXISTS banco_rsx WITH (FORCE)"

# ============================================================================
# D. Repetir la demostracion
# ============================================================================
demo_adelanto() { # +10 dias, avance de lo guardado: devuelve el resumen funcional (sin uuid)
  psql -X -q -At -U postgres -d $RS -c "SELECT public.admin_set_reloj('$ADM', false, (public.hoy_banco() + 10)::text)" >/dev/null 2>&1 </dev/null
  psql -X -q -At -U postgres -d $RS -c "CALL public.sp_avanzar_todos()" 2>/dev/null </dev/null | sed 's/"hoy_desde": "[^"]*", "hoy_hasta": "[^"]*"//'
  psql -X -q -At -U postgres -d $RS -c "SELECT count(*) || '|' || coalesce(sum(monto), 0) FROM public.transaccion" </dev/null
}
RES1=$(demo_adelanto)
R restore /tmp/c58_b.dump $RS --yes >/dev/null
eq "D1 restaurar y repetir el MISMO adelanto da el mismo resultado (mismos grupos escritos y mismos totales del libro): la demostracion se repite" "$RES1" "$(demo_adelanto)"
R restore /tmp/c58_b.dump $RS --yes >/dev/null
eq "D2 y se puede volver al estado inicial las veces que haga falta (huella del respaldo)" "$HB" "$(hu $RS)"
# alternativa: plantilla
PG "CREATE DATABASE $TPL TEMPLATE $RS"
eq "D3 la alternativa de PLANTILLA (CREATE DATABASE ... TEMPLATE) da la misma huella que el respaldo" "$HB" "$(hu $TPL 2>/dev/null)"
eq "D4 y el estado final tras todo sigue en orden (integridad ok, 0 defensas caidas)" "true|0" "$(root "SELECT ok || '|' || defensas_fallidas FROM public.v_integridad_global")"
fin
