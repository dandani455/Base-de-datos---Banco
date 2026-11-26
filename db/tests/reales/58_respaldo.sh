#!/bin/sh
# 58_respaldo.sh - Etapa 14 - Respaldo y restauracion PROTEGIDOS (P-DEMO-3) con el seed real, en BASES AISLADAS (banco_rs*): no toca banco ni banco_test.
#   A. backup: archivo valido + manifiesto, huella reproducible, bases invalidas rechazadas.
#   B. restore: sin --yes no hace nada; con --yes la BD vuelve EXACTAMENTE al respaldo (huella, integridad, reloj) y la anterior queda como _previo;
#      con conexiones abiertas; restaurar dos veces; descartar.
#   C. PROTECCIONES: archivo corrupto, sin manifiesto, manifiesto que no coincide, volcado de otra BD, nombres de BD no permitidos: se RECHAZAN y la BD
#      NO se modifica ni queda una BD de paso.
#   D. REPETIR LA DEMOSTRACION: restaurar y repetir el mismo adelanto da el mismo resultado (reproducibilidad funcional de la demostracion).
. /work/tests/reales/lib.sh
SEED=${SEED_DIR:-/work/seed}
RS=banco_rs; TPL=banco_rs_tpl; RSB=banco_rs_base
RESP=$SEED/respaldo.sh
limpiar() { for d in $RS ${RS}_previo ${RS}_restaurando ${RS}_retirada $TPL $RSB banco_rs_otra banco_rsx banco_rsy; do psql -X -q -U postgres -d postgres -c "DROP DATABASE IF EXISTS $d WITH (FORCE)" >/dev/null 2>&1 </dev/null; done; rm -rf /tmp/c58_*; }
trap limpiar EXIT
limpiar
PG() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$1" >/dev/null 2>&1 </dev/null; }
R() { sh $RESP "$@" 2>&1 </dev/null; }                       # respaldo.sh
RF() { _f=$1; shift; RESPALDO_FALLA=$_f sh $RESP "$@" 2>&1 </dev/null; }                 # respaldo.sh con un gancho de falla
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
OUT=$(RF cambio_durante backup /tmp/c58_cd.dump $RS); RC=$?
eq "E4 backup RECHAZA una BD que CAMBIA mientras se respalda (el manifiesto ya no describiria el volcado): error claro y sin archivos ni temporales" "t|t|f|f|f" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(printf '%s' "$OUT" | grep -qi 'cambio mientras' && echo t || echo f)|$([ -e /tmp/c58_cd.dump ] && echo t || echo f)|$([ -e /tmp/c58_cd.dump.huella ] && echo t || echo f)|$([ -e /tmp/c58_cd.dump.tmp ] && echo t || echo f)"
root "UPDATE public.parametro SET bono_referido = bono_referido - 1" >/dev/null
H1=$(hu $RS); HB=$(grep '^huella=' /tmp/c58_b.dump.huella | cut -d= -f2)
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
