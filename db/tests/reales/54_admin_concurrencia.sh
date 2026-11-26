#!/bin/sh
# 54_admin_concurrencia.sh - Etapa 11 - las funciones admin_* bajo CONCURRENCIA con conexiones reales de banco_app (cada sesion espera una hora de arranque comun para chocar de verdad):
#   1. 6 sesiones x 5 ajustes simultaneos (+1000) al MISMO usuario: la suma es exacta, 30 grupos AJUSTE_ADMIN y 30 eventos, sin un solo error.
#   2. ajustes del admin, detalles y transferencias CRUZADAS del mismo usuario a la vez: sin deadlock ni timeout y con conservacion exacta.
#   3. DOS administradores guardando las 3 tasas a la vez, cada uno con BEGIN ... COMMIT y en ORDEN OPUESTO (el backend las ejecuta en una transaccion): sin deadlock y el estado final es el de UNO
#      completo (nunca mezclado), gracias al advisory lock de tasas.
#   4. bloquear mientras el usuario opera: solo aparecen el exito o el mensaje de bloqueo (nunca otro error), y el usuario queda bloqueado.
#   5. BORRAR al usuario mientras sus propias sesiones operan (transferencias, dashboard, balance) y otros le envian dinero: solo exito, 'Sesion invalida' o 'Cuenta no encontrada'; nunca un error de FK ni un deadlock.
#   6. lectores del detalle contra escritores de ajustes: cada detalle es una sola foto (total = principal) y el saldo final es exacto.
# Termina SIEMPRE en modo real y con la integridad global en orden.
. /work/tests/reales/lib.sh
restaurar() { wait; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; root "DELETE FROM public.cdt_definicion WHERE nombre LIKE 'T54 %'" >/dev/null; root "DELETE FROM public.credito_producto WHERE nombre LIKE 'T54 %'" >/dev/null; root "UPDATE public.parametro SET tasa_mora_anual = NULL" >/dev/null; rm -f /tmp/c54_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
root "UPDATE public.parametro SET tasa_mora_anual = NULL" >/dev/null

# par PREFIJO N GENERADOR REPETICIONES : N sesiones simultaneas; cada una ejecuta GENERADOR(i) REPETICIONES veces (una sentencia por -c: ninguna roza el statement_timeout de 5 s de banco_app)
par() {
  _p=$1; _n=$2; _g=$3; _r=${4:-1}; _t=${START:-$(( $(date +%s) + 3 ))}; _i=1
  while [ $_i -le $_n ]; do
    ( set -- -c "SELECT pg_sleep(GREATEST(0, $_t - extract(epoch from clock_timestamp())))"
      _k=1; while [ $_k -le $_r ]; do set -- "$@" -c "$($_g $_i)"; _k=$((_k+1)); done
      PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" "$@" > /tmp/c54_${_p}_$_i.out 2>&1 </dev/null ) &
    _i=$((_i+1))
  done
  wait
}
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
U() { root "SELECT tests.u($1)"; }
NUM() { root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c($1)"; }
SAL() { root "SELECT balance FROM public.cuenta WHERE id = tests.c($1)"; }
errores() { cat /tmp/c54_$1_*.out | grep -c "$2"; }
root "INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol) VALUES ('adm1510', 'h', 'Adm', 'Uno', '9301510', 'a1510@t.co', '3171510510', DATE '1980-01-01', 'ADMIN')" >/dev/null
ADM=$(root "SELECT id FROM public.usuario WHERE username = 'adm1510'")
alta 1500 1000000; alta 1501 1000000; alta 1502 1000000; alta 1503 3000000; alta 1504 3000000; alta 1505 3000000; alta 1506 1000000
U0=$(U 1500); U1=$(U 1501); N0=$(NUM 1500); N1=$(NUM 1501)

# ---- 1. 6 sesiones x 5 ajustes simultaneos al mismo usuario ---------------------------------------------------------------------------
g1() { echo "SELECT public.admin_ajustar_balance('$ADM', '$U0', 1000, 'c$1')"; }
par c1 6 g1 5
eq "1. 30 ajustes simultaneos (6 sesiones x 5): TODOS devuelven su grupo y ninguna sesion falla (ni deadlock, ni timeout, ni llave duplicada)" "30|0" "$(cat /tmp/c54_c1_*.out | grep -c '"id"')|$(cat /tmp/c54_c1_*.out | grep -ci 'ERROR\|deadlock\|timeout\|duplicate\|violates')"
eq "1. ...la suma es EXACTA (1.000.000 + 30 x 1.000) y hay 30 grupos AJUSTE_ADMIN de 2 patas" "1030000.00|30|60" "$(SAL 1500)|$(root "SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE cuenta_id = tests.c(1500) AND tipo = 'AJUSTE_ADMIN'")|$(root "SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(1500) AND tipo = 'AJUSTE_ADMIN'")"
eq "1. ...y 30 eventos AJUSTE_ADMIN atribuidos al admin" "30" "$(root "SELECT count(*) FROM audit.evento WHERE accion = 'AJUSTE_ADMIN' AND entidad_id = tests.c(1500)::text AND actor_username = 'adm1510'")"

# ---- 2. ajustes + detalles + transferencias cruzadas del mismo usuario -----------------------------------------------------------------
g2() { if [ $1 -le 4 ]; then echo "SELECT public.admin_ajustar_balance('$ADM', '$U0', 5000, 'x')"
       elif [ $1 -le 8 ]; then echo "SELECT public.hacer_transferencia('$U0', '$N1', 100, 'c', NULL)"
       elif [ $1 -le 12 ]; then echo "SELECT public.hacer_transferencia('$U1', '$N0', 100, 'c', NULL)"
       else echo "SELECT public.admin_detalle_usuario('$ADM', '$U0') #>> '{balance,total}'"; fi; }
par c2 14 g2 8
eq "2. 14 sesiones x 8 operaciones (16 ajustes de admin del lado de 1500 x ..., 64 transferencias cruzadas y 16 detalles): sin deadlock, timeout ni error de ninguna clase" "0" "$(cat /tmp/c54_c2_*.out | grep -ci 'ERROR\|deadlock\|timeout\|duplicate\|violates')"
eq "2. ...conservacion exacta: 1500 recibe 4 x 8 x 5.000 de mas y su ida y vuelta con 1501 es neta cero; los 16 detalles responden un numero" "1190000.00|1000000.00|16" "$(SAL 1500)|$(SAL 1501)|$(cat /tmp/c54_c2_1[34].out | grep -c '^[0-9]')"

# ---- 3. dos administradores guardando las 3 tasas a la vez, en orden opuesto ------------------------------------------------------------
CD=$(root "WITH x AS (INSERT INTO public.cdt_definicion (nombre, plazo_dias, tasa_anual, monto_min) VALUES ('T54 CDT', 30, 10, 1) RETURNING id) SELECT id FROM x")
CP=$(root "WITH x AS (INSERT INTO public.credito_producto (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES ('T54 Libre', '', 18, 1, 1000000000, 1, 360) RETURNING id) SELECT id FROM x")
mixtos=0; fallos=0; E_T0=$(root "SELECT coalesce(max(orden), 0) FROM audit.evento")
for rep in 1 2 3 4 5; do
  ST=$(( $(date +%s) + 2 ))
  ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT pg_sleep(GREATEST(0, $ST - extract(epoch from clock_timestamp())))" -c "BEGIN" \
      -c "SELECT public.admin_set_tasa_cdt('$ADM', '$CD', '11')" -c "SELECT pg_sleep(0.3)" -c "SELECT public.admin_set_tasa_credito('$ADM', '$CP', '21')" -c "SELECT pg_sleep(0.3)" -c "SELECT public.admin_set_tasa_mora('$ADM', '31')" -c "COMMIT" > /tmp/c54_t1.out 2>&1 </dev/null ) &
  ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT pg_sleep(GREATEST(0, $ST - extract(epoch from clock_timestamp())))" -c "BEGIN" \
      -c "SELECT public.admin_set_tasa_mora('$ADM', '32')" -c "SELECT pg_sleep(0.3)" -c "SELECT public.admin_set_tasa_credito('$ADM', '$CP', '22')" -c "SELECT pg_sleep(0.3)" -c "SELECT public.admin_set_tasa_cdt('$ADM', '$CD', '12')" -c "COMMIT" > /tmp/c54_t2.out 2>&1 </dev/null ) &
  wait
  fin_t=$(root "SELECT (SELECT tasa_anual FROM public.cdt_definicion WHERE id = '$CD') || '|' || (SELECT tasa_anual FROM public.credito_producto WHERE id = '$CP') || '|' || (SELECT tasa_mora_anual FROM public.parametro)")
  case "$fin_t" in 11.000\|21.000\|31.000|12.000\|22.000\|32.000) ;; *) mixtos=$((mixtos+1));; esac
  grep -qi 'ERROR\|deadlock\|timeout' /tmp/c54_t1.out /tmp/c54_t2.out && fallos=$((fallos+1))
done
eq "3. 5 rondas de 2 admins guardando las 3 tasas a la vez (BEGIN ... COMMIT, ordenes opuestos): SIN deadlock ni timeout en ninguna" "0" "$fallos"
eq "3. ...y el estado final de CADA ronda es el de UN formulario COMPLETO (11/21/31 o 12/22/32), nunca mezclado" "0" "$mixtos"
eq "3. ...quedan solo eventos TASA_CAMBIO de cambios reales y todos con el admin como actor" "0" "$(root "SELECT count(*) FROM audit.evento WHERE accion = 'TASA_CAMBIO' AND orden > $E_T0 AND actor_username <> 'adm1510'")"

# ---- 4. bloquear mientras el usuario opera ----------------------------------------------------------------------------------------------
U2=$(U 1502)
g4() { if [ $1 -le 2 ]; then echo "SELECT public.hacer_transferencia('$U2', '$N1', 100, 'b', NULL)"; else echo "SELECT public.admin_bloquear('$ADM', '$U2')"; fi; }
START=$(( $(date +%s) + 3 )); par c4 3 g4 20; unset START
eq "4. el usuario operando y el admin bloqueandolo a la vez: SOLO aparece el exito o el mensaje de bloqueo (ningun otro error)" "0" "$(cat /tmp/c54_c4_[12].out | grep 'ERROR' | grep -vc 'Tu cuenta ha sido restringida')"
eq "4. ...el usuario queda BLOQUEADO y su saldo refleja exactamente las transferencias que SI salieron (1 ENVIO por cada id devuelto)" "BLOQUEADO|t" "$(root "SELECT estado FROM public.usuario WHERE id = '$U2'")|$(root "SELECT ((SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(1502) AND tipo = 'ENVIO') = $(cat /tmp/c54_c4_[12].out | grep -c '"id"') AND balance = 1000000 - 100 * $(cat /tmp/c54_c4_[12].out | grep -c '"id"'))::text FROM public.cuenta WHERE id = tests.c(1502)" | sed 's/true/t/')"
eq "4. ...y el bloqueo repetido por las 20 llamadas dejo UN solo evento USUARIO_BLOQUEADO (idempotente)" "1" "$(root "SELECT count(*) FROM audit.evento WHERE accion = 'USUARIO_BLOQUEADO' AND entidad_id = '$U2'")"

# ---- 5. borrar al usuario mientras sus sesiones operan y otros le envian dinero --------------------------------------------------------
U3=$(U 1503); N3=$(NUM 1503); N4=$(NUM 1504); U4=$(U 1504)
g5() { case $1 in
         1|2) echo "SELECT public.hacer_transferencia('$U3', '$N4', 100, 'v', NULL)";;
         3) echo "SELECT public.vista_dashboard('$U3') ->> 'nombre'";;
         4) echo "SELECT public.vista_balance('$U3') ->> 'total'";;
         5|6) echo "SELECT public.hacer_transferencia('$U4', '$N3', 100, 'a-v', NULL)";;
         *) echo "SELECT pg_sleep(0.25)";; esac; }
( START=$(( $(date +%s) + 3 )); export START
  par c5 6 g5 80 ) &
sleep 3.4
as banco_app $APP_PW "SELECT public.admin_borrar_usuario('$ADM', '$U3')" > /tmp/c54_borrar.out
wait
eq "5. el admin borra al usuario con 4 sesiones suyas operando (320 operaciones) y 2 sesiones enviandole dinero: el borrado SE COMPLETA" "1|0" "$(grep -c true /tmp/c54_borrar.out)|$(root "SELECT count(*) FROM public.usuario WHERE id = '$U3'")"
eq "5. ...todo error es de NEGOCIO ('Sesión inválida' del borrado o 'Cuenta no encontrada' del destino borrado): ni FK, ni deadlock, ni timeout, ni error interno" "0" "$(cat /tmp/c54_c5_*.out | grep 'ERROR' | grep -vc 'Sesión inválida\|Cuenta no encontrada')"
eq "5. ...y hubo al menos un rechazo por el borrado (la carrera fue real) y la conservacion del dinero esta en orden" "t|t" "$([ "$(cat /tmp/c54_c5_*.out | grep -c 'Sesión inválida\|Cuenta no encontrada')" -ge 1 ] && echo t || echo f)|$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"

# ---- 6. lectores del detalle contra escritores de ajustes -------------------------------------------------------------------------------
U5=$(U 1505)
g6() { if [ $1 -le 3 ]; then echo "SELECT public.admin_ajustar_balance('$ADM', '$U5', 100, 's')"
       else echo "SELECT (d #>> '{balance,total}') = (d #>> '{balance,principal}') FROM (SELECT public.admin_detalle_usuario('$ADM', '$U5') AS d) x"; fi; }
par c6 9 g6 10
eq "6. 6 lectores del detalle x 10 contra 3 escritores x 10 ajustes: cada detalle es UNA foto (total = principal en las 60 lecturas) y nadie falla" "60|0|0" "$(cat /tmp/c54_c6_[4-9].out | grep -c '^t$')|$(cat /tmp/c54_c6_[4-9].out | grep -c '^f$')|$(cat /tmp/c54_c6_*.out | grep -ci 'ERROR\|deadlock\|timeout')"
eq "6. ...el saldo final es exacto: 3.000.000 + 30 x 100" "3003000.00" "$(SAL 1505)"
eq "7. integridad global y defensas en orden tras todo" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
