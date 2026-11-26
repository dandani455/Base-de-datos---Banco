#!/bin/sh
# 40_auth_concurrencia.sh - Etapa 4 - registro y verificacion bajo CONCURRENCIA con conexiones reales de banco_app (cada sesion espera una hora de
# arranque comun para chocar de verdad):
#   1. 8 sesiones registran la MISMA cedula: gana 1, las otras 7 reciben el mensaje propio (nunca un error de la restriccion UNIQUE ni un 503).
#   2. 6 sesiones con el MISMO correo (con mayusculas distintas) y 6 con el MISMO telefono en formatos distintos.
#   3. 12 sesiones con el MISMO nombre (misma base de username): todas entran, usernames distintos.
#   4. 10 verificar_correo simultaneos del mismo usuario: un solo bono.
#   5. 15 registros referidos por el MISMO usuario con la verificacion apagada: el saldo del referidor es exacto.
#   6. Registros concurrentes con CAMBIOS DE RELOJ del admin: ninguno falla (cada registro ve una sola fecha), sin deadlocks.
# Termina SIEMPRE en modo real.
. /work/tests/reales/lib.sh
HASH='$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy'
restaurar() { wait; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c40_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null

# par PREFIJO N GENERADOR : lanza N sesiones simultaneas; la sesion i ejecuta el SQL que imprime  GENERADOR i  y deja su salida en /tmp/c40_PREFIJO_i.out
par() {
  _p=$1; _n=$2; _g=$3; _t=$(( $(date +%s) + 3 )); _i=1
  while [ $_i -le $_n ]; do
    _sql=$($_g $_i)
    ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" \
        -c "SELECT pg_sleep(GREATEST(0, $_t - extract(epoch from clock_timestamp())))" -c "$_sql" > /tmp/c40_${_p}_$_i.out 2>&1 </dev/null ) &
    _i=$((_i+1))
  done
  wait
}
cuenta() { cat /tmp/c40_$1_*.out | grep -c "$2"; }
nada_mas() { # nada_mas PREFIJO PATRON_OK PATRON_ESPERADO : errores/lineas que no son ni OK ni el mensaje esperado
  cat /tmp/c40_$1_*.out | grep -v '^$' | grep -v '^CONTEXT' | grep -v 'PL/pgSQL' | grep -v "$2" | grep -vc "$3"
}
reg_sql() { # reg_sql NOMBRES APELLIDOS CEDULA CORREO TEL REF VERIF
  echo "SELECT public.registrar_usuario('$1', '$2', '$3', '$4', '$5', '1990-05-17', '$HASH', true, $6, $7)"
}
OKP='"usuario_id"'

# ---- 1. misma cedula x8 -----------------------------------------------------------------------------------------------------
g1() { reg_sql 'Ana' 'Gomez' '5550001' "c1_$1@mail.co" "31$(printf %08d $((1000+$1)))" NULL true; }
par c1 8 g1
eq "1. misma cedula x8: exactamente UNA sesion registro" "1" "$(cuenta c1 "$OKP")"
eq "1. ...las otras 7 recibieron 'La cédula ya está registrada'" "7" "$(cuenta c1 'La cédula ya está registrada')"
eq "1. ...ningun otro error (ni unique_violation, ni deadlock, ni timeout)" "0" "$(nada_mas c1 "$OKP" 'La cédula ya está registrada')"
eq "1. ...y quedo un solo usuario con esa cedula, con su cuenta y sus 5 ingresos" "1|1|5" "$(root "SELECT count(*) || '|' || (SELECT count(*) FROM public.cuenta c JOIN public.usuario u ON u.id = c.usuario_id WHERE u.cedula = '5550001') || '|' || (SELECT count(DISTINCT t.grupo_id) FROM public.transaccion t JOIN public.cuenta c ON c.id = t.cuenta_id JOIN public.usuario u ON u.id = c.usuario_id WHERE u.cedula = '5550001') FROM public.usuario WHERE cedula = '5550001'")"

# ---- 2. mismo correo x6 (mayusculas distintas) y mismo telefono x6 (formatos distintos) -----------------------------------------
g2() { reg_sql 'Beto' 'Blanco' "55500$(printf %02d $((10+$1)))" "$(if [ $(($1 % 2)) -eq 0 ]; then echo 'MISMO@Mail.co'; else echo 'mismo@mail.co'; fi)" "31$(printf %08d $((2000+$1)))" NULL true; }
par c2 6 g2
eq "2. mismo correo x6 (con mayusculas distintas): 1 gana y 5 reciben 'El correo ya está registrado'" "1|5|0" "$(cuenta c2 "$OKP")|$(cuenta c2 'El correo ya está registrado')|$(nada_mas c2 "$OKP" 'El correo ya está registrado')"
g3() {
  case $1 in 1) T='3170000001';; 2) T='317 000 0001';; 3) T='+57 317 000 0001';; 4) T='(317) 000-0001';; 5) T='317-000-0001';; 6) T='+573170000001';; esac
  reg_sql 'Cora' 'Cano' "55501$(printf %02d $((10+$1)))" "c3_$1@mail.co" "$T" NULL true
}
par c3 6 g3
eq "2. mismo telefono x6 en 6 formatos (nacional, con espacios, +57, parentesis, guiones, +57 pegado): 1 gana y 5 reciben 'El teléfono ya está registrado'" "1|5|0" "$(cuenta c3 "$OKP")|$(cuenta c3 'El teléfono ya está registrado')|$(nada_mas c3 "$OKP" 'El teléfono ya está registrado')"
eq "2. ...el telefono quedo guardado una sola vez, en su forma canonica de 10 digitos" "1" "$(root "SELECT count(*) FROM public.usuario WHERE telefono = '3170000001'")"

# ---- 3. mismo nombre x12 ------------------------------------------------------------------------------------------------------
g4() { reg_sql 'Juan' 'Pérez' "55502$(printf %03d $1)" "c4_$1@mail.co" "31$(printf %08d $((3000+$1)))" NULL true; }
par c4 12 g4
eq "3. 12 registros simultaneos de 'Juan Pérez': TODOS entraron" "12" "$(cuenta c4 "$OKP")"
eq "3. ...con 12 usernames distintos (jperez###) y ningun error" "12|0" "$(root "SELECT count(DISTINCT username) FROM public.usuario WHERE cedula LIKE '55502%' AND username ~ '^jperez[0-9]{3,4}$'")|$(cat /tmp/c40_c4_*.out | grep -ci 'error')"

# ---- 4. verificar_correo x10 simultaneos --------------------------------------------------------------------------------------
ANA=$(root "SELECT id FROM public.usuario WHERE cedula = '5550001'")
COD=$(root "SELECT codigo_referido FROM public.usuario WHERE id = '$ANA'")
o=$(PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "$(reg_sql 'Vero' 'Gil' '5550100' 'vero@mail.co' '3190000100' "'$COD'" true)" 2>&1 </dev/null)
VERO=$(echo "$o" | sed -n 's/.*"usuario_id": "\([^"]*\)".*/\1/p')
S0=$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$ANA'")
g5() { echo "SELECT public.verificar_correo('$VERO')"; }
par c5 10 g5
eq "4. 10 verificar_correo simultaneos: ninguno falla" "0" "$(cat /tmp/c40_c5_*.out | grep -ci 'error')"
eq "4. ...exactamente UN bono: un solo grupo y el referidor sube 50000 una sola vez" "1|$(root "SELECT $S0 + 50000")" "$(root "SELECT count(*) FROM public.transaccion WHERE tipo = 'BONO_REFERIDO' AND contraparte_cuenta = (SELECT numero_cuenta FROM public.cuenta WHERE usuario_id = '$VERO')")|$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$ANA'")"

# ---- 5. 15 registros referidos por el mismo usuario, verificacion apagada ----------------------------------------------------
S1=$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$ANA'")
g6() { reg_sql 'Rita' 'Rojas' "55503$(printf %03d $1)" "c6_$1@mail.co" "31$(printf %08d $((4000+$1)))" "'$COD'" false; }
par c6 15 g6
eq "5. 15 registros simultaneos referidos por el mismo usuario con bono inmediato: todos entran sin error (sin deadlock ni timeout de bloqueo)" "15|0" "$(cuenta c6 "$OKP")|$(cat /tmp/c40_c6_*.out | grep -ci 'error')"
eq "5. ...el referidor recibio EXACTAMENTE 15 x 50000 y hay 15 grupos de bono mas" "$(root "SELECT $S1 + 750000")|15" "$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$ANA'")|$(root "SELECT count(*) FROM public.usuario u WHERE u.cedula LIKE '55503%' AND u.bono_referido_pagado")"
eq "5. ...y la integridad de autenticacion (bono pagado <=> un solo grupo) esta en orden" "t" "$(root "SELECT bool_and(ok) FROM public.v_integridad_auth")"

# ---- 6. registros concurrentes con cambios de reloj del admin -----------------------------------------------------------------
: > /tmp/c40_adm.sql; : > /tmp/c40_regs_1.sql; : > /tmp/c40_regs_2.sql; : > /tmp/c40_regs_3.sql
k=0; while [ $k -lt 25 ]; do echo "SELECT tests.app_reloj_aleatorio();" >> /tmp/c40_adm.sql; k=$((k+1)); done
i=1; while [ $i -le 3 ]; do
  k=1; while [ $k -le 12 ]; do echo "$(reg_sql 'Reloj' 'Cambio' "55504$i$(printf %02d $k)" "c7_${i}_$k@mail.co" "31$(printf %08d $((5000+i*100+k)))" NULL true);" >> /tmp/c40_regs_$i.sql; k=$((k+1)); done
  i=$((i+1))
done
T=$(( $(date +%s) + 3 ))
i=1; while [ $i -le 3 ]; do
  ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT pg_sleep(GREATEST(0, $T - extract(epoch from clock_timestamp())))" -f /tmp/c40_adm.sql > /tmp/c40_s_adm$i.out 2>&1 </dev/null ) &
  ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT pg_sleep(GREATEST(0, $T - extract(epoch from clock_timestamp())))" -f /tmp/c40_regs_$i.sql > /tmp/c40_s_reg$i.out 2>&1 </dev/null ) &
  i=$((i+1))
done
wait
REGS_OK=$(cat /tmp/c40_s_reg*.out | grep -c "$OKP"); REGS_ERR=$(cat /tmp/c40_s_reg*.out | grep -ci 'error')
ADM_OK=$(cat /tmp/c40_s_adm*.out | grep -cE '^(real|manual)$'); ADM_RETRO=$(cat /tmp/c40_s_adm*.out | grep -c 'El reloj no puede retroceder'); ADM_OTROS=$(cat /tmp/c40_s_adm*.out | grep -iE 'ERROR' | grep -vc 'El reloj no puede retroceder')
eq "6. 36 registros concurrentes con 75 cambios de reloj: TODOS los registros entraron (cada uno ve UNA sola fecha) y ninguno dio error" "36|0" "$REGS_OK|$REGS_ERR"
eq "6. ...los 75 cambios de reloj se resolvieron (aceptados o 'El reloj no puede retroceder') sin deadlocks ni timeouts" "75|0" "$((ADM_OK + ADM_RETRO))|$ADM_OTROS"
as banco_app $APP_PW "SELECT tests.app_reloj(true, '')" >/dev/null
eq "6. ...cada cuenta nueva tiene exactamente 5 grupos de ingreso con fechas anteriores a su creado_en" "0" \
   "$(root "SELECT count(*) FROM (SELECT c.id FROM public.cuenta c JOIN public.usuario u ON u.id = c.usuario_id LEFT JOIN public.transaccion t ON t.cuenta_id = c.id AND t.tipo = 'INGRESO_SIMULADO' WHERE u.cedula LIKE '55504%' GROUP BY c.id, u.creado_en HAVING count(DISTINCT t.grupo_id) <> 5 OR max(t.fecha) >= u.creado_en) x")"
eq "6. ...integridad global y de autenticacion en orden; reloj de vuelta a real" "t|t|true" "$(root "SELECT (SELECT ok FROM public.v_integridad_global) || '|' || (SELECT bool_and(ok) FROM public.v_integridad_auth) || '|' || (SELECT usar_fecha_real FROM public.reloj)" | sed 's/true|true|true/t|t|true/')"
eq "ninguna sesion de banco_app quedo colgada" "0" "$(root "SELECT count(*) FROM pg_stat_activity WHERE usename = 'banco_app' AND state <> 'idle' AND pid <> pg_backend_pid()")"
fin
