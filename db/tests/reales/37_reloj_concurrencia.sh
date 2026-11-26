#!/bin/sh
# 37_reloj_concurrencia.sh - Etapa 3 - el reloj bajo CONCURRENCIA con conexiones reales de banco_app.
#  A. Una operacion en vuelo (instantanea FOR SHARE) ve UNA sola fecha: el cambio de reloj del admin ESPERA a que ella termine.
#  B. Lo mismo al volver a fecha real. Despues del COMMIT las operaciones nuevas usan la fecha nueva.
#  C. Tormenta: sesiones que cambian el reloj al azar (adelantar, volver a real, intentar retroceder) mientras otras asientan operaciones
#     con el protocolo estable. Ninguna operacion se rechaza, solo se rechazan retrocesos (mensaje exacto), sin deadlocks ni timeouts, saldos
#     exactos y nunca un retroceso manual->manual aceptado. Siempre se deja el reloj en modo real.
. /work/tests/reales/lib.sh

restaurar() { root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c37_*; }
trap restaurar EXIT
restaurar

R=$(root "SELECT (now() AT TIME ZONE 'America/Bogota')::date")
R10=$(root "SELECT DATE '$R' + 10")
A=$(root "SELECT tests.cliente(501)")
root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso('$A', 1000))" >/dev/null

# --- A. Operacion lenta vs. cambio de reloj -----------------------------------------------------------------------------------
( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT tests.app_operacion_lenta(3.0)" > /tmp/c37_op1.out 2>&1 </dev/null ) &
sleep 1
( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" \
    -c "SELECT clock_timestamp()" -c "SELECT tests.app_reloj(false, '$R10')" -c "SELECT clock_timestamp()" > /tmp/c37_adm1.out 2>&1 </dev/null ) &
wait
eq "A: la operacion en vuelo vio UNA sola fecha (la de antes del cambio) en sus dos lecturas" "$R|$R" "$(cat /tmp/c37_op1.out)"
T1=$(head -1 /tmp/c37_adm1.out); T2=$(tail -1 /tmp/c37_adm1.out)
eq "A: el cambio del admin ESPERO a la operacion (tardo mas de 1 segundo)" "t" "$(root "SELECT extract(epoch FROM '$T2'::timestamptz - '$T1'::timestamptz) > 1")"
contiene "A: ...y el cambio se aplico (fecha_actual = R+10)" "$(cat /tmp/c37_adm1.out)" "\"fecha_actual\": \"$R10\""
eq "A: despues del COMMIT la fecha nueva rige: una operacion nueva ve R+10 las dos veces" "$R10|$R10" "$(as banco_app $APP_PW "SELECT tests.app_operacion_lenta(0.1)")"

# --- B. Volver a fecha real con una operacion en vuelo ------------------------------------------------------------------------
( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT tests.app_operacion_lenta(3.0)" > /tmp/c37_op2.out 2>&1 </dev/null ) &
sleep 1
( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" \
    -c "SELECT clock_timestamp()" -c "SELECT tests.app_reloj(true, '')" -c "SELECT clock_timestamp()" > /tmp/c37_adm2.out 2>&1 </dev/null ) &
wait
eq "B: la operacion en vuelo (reloj manual R+10) vio R+10 en sus dos lecturas" "$R10|$R10" "$(cat /tmp/c37_op2.out)"
T1=$(head -1 /tmp/c37_adm2.out); T2=$(tail -1 /tmp/c37_adm2.out)
eq "B: volver a real tambien espero a la operacion" "t" "$(root "SELECT extract(epoch FROM '$T2'::timestamptz - '$T1'::timestamptz) > 1")"
eq "B: ...y despues las operaciones nuevas usan la fecha de Colombia ($R)" "$R|$R" "$(as banco_app $APP_PW "SELECT tests.app_operacion_lenta(0.1)")"

# --- A2. Dos operaciones lentas a la vez no se bloquean entre si (FOR SHARE es compatible con FOR SHARE) -------------------------
for i in 1 2 3; do
  ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT tests.app_operacion_lenta(1.5)" > /tmp/c37_par$i.out 2>&1 </dev/null ) &
done
S0=$(date +%s); wait; S1=$(date +%s)
eq "A2: tres operaciones lentas concurrentes terminan sin errores y con una sola fecha cada una" "3" "$(cat /tmp/c37_par*.out | grep -c "^$R|$R\$")"
eq "A2: ...en paralelo (no se serializan: menos de 4 segundos en total)" "t" "$( [ $((S1 - S0)) -lt 4 ] && echo t || echo f )"

# --- C. Tormenta ------------------------------------------------------------------------------------------------------------------
N=40
: > /tmp/c37_adm.sql; : > /tmp/c37_ops.sql
k=0; while [ $k -lt $N ]; do
  echo "SELECT tests.app_reloj_aleatorio();" >> /tmp/c37_adm.sql
  echo "SELECT tests.app_fondear_estable('$A', 1);" >> /tmp/c37_ops.sql
  k=$((k+1))
done
EV0=$(root "SELECT count(*) FROM audit.evento WHERE accion = 'RELOJ_CAMBIO'")
T=$(( $(date +%s) + 3 ))
i=1; while [ $i -le 3 ]; do
  ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT pg_sleep(GREATEST(0, $T - extract(epoch from clock_timestamp())))" -f /tmp/c37_adm.sql > /tmp/c37_s_adm$i.out 2>&1 </dev/null ) &
  ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT pg_sleep(GREATEST(0, $T - extract(epoch from clock_timestamp())))" -f /tmp/c37_ops.sql > /tmp/c37_s_ops$i.out 2>&1 </dev/null ) &
  i=$((i+1))
done
wait

OPS_OK=$(cat /tmp/c37_s_ops*.out | grep -cE '^[0-9a-f-]{36}$')
OPS_ERR=$(cat /tmp/c37_s_ops*.out | grep -ci 'ERROR')
ADM_OK=$(cat /tmp/c37_s_adm*.out | grep -cE '^(real|manual)$')
ADM_RETRO=$(cat /tmp/c37_s_adm*.out | grep -c 'El reloj no puede retroceder')
ADM_OTROS=$(cat /tmp/c37_s_adm*.out | grep -iE 'ERROR' | grep -vc 'El reloj no puede retroceder')
REALES=$(cat /tmp/c37_s_adm*.out | grep -c '^real$')
eq "C: las 120 operaciones de las 3 sesiones asentaron TODAS (el reloj no cambia en medio de una operacion)" "120" "$OPS_OK"
eq "C: ...ninguna recibio error (ni 'posterior al reloj del banco', ni deadlock, ni timeout de bloqueo)" "0" "$OPS_ERR"
eq "C: las 120 peticiones de cambio de reloj se resolvieron: aceptadas o 'El reloj no puede retroceder'" "120" "$((ADM_OK + ADM_RETRO))"
eq "C: ...ningun otro error en los cambios de reloj (sin deadlocks ni timeouts)" "0" "$ADM_OTROS"
eq "C: la tormenta ejercito los dos caminos (hubo retrocesos rechazados y salidas a fecha real)" "t" "$( [ "$ADM_RETRO" -gt 0 ] && [ "$REALES" -gt 0 ] && echo t || echo f )"
eq "C: cada cambio aceptado efectivo quedo auditado (RELOJ_CAMBIO nuevos entre 1 y los aceptados)" "t"    "$(root "SELECT (count(*) - $EV0) BETWEEN 1 AND $ADM_OK FROM audit.evento WHERE accion = 'RELOJ_CAMBIO'")"
eq "C: ningun cambio manual->manual hacia atras fue aceptado (bitacora de auditoria)" "0" \
   "$(root "SELECT count(*) FROM audit.evento WHERE accion='RELOJ_CAMBIO' AND (antes->>'usar_fecha_real')::boolean = false AND (despues->>'usar_fecha_real')::boolean = false AND (despues->>'fecha_sistema')::date < (antes->>'fecha_sistema')::date")"
eq "C: saldo exacto de la cuenta (1000 + 120 operaciones de 1 peso)" "1120.00" "$(root "SELECT balance FROM public.cuenta WHERE id = '$A'")"
eq "C: v_integridad_global.ok (el libro cuadra, las patas futuras no son error)" "t" "$(root "SELECT ok FROM public.v_integridad_global")"
eq "C: ninguna sesion quedo bloqueada esperando (sin transacciones colgadas de banco_app)" "0" "$(root "SELECT count(*) FROM pg_stat_activity WHERE usename = 'banco_app' AND state <> 'idle' AND pid <> pg_backend_pid()")"

# --- D. Vuelta a real tras la tormenta ------------------------------------------------------------------------------------------
as banco_app $APP_PW "SELECT tests.app_reloj(true, '')" >/dev/null
eq "D: tras la tormenta el admin vuelve a fecha real (siempre permitido) y el hoy es el de Colombia" "$R" "$(as banco_app $APP_PW "SELECT tests.app_hoy()")"
eq "D: ...sin fecha guardada" "true|" "$(root "SELECT usar_fecha_real || '|' || coalesce(fecha_sistema::text, '') FROM public.reloj")"
eq "D: ...las patas fechadas en el futuro de la tormenta permanecen y solo se informan, no son error" "true|true" \
   "$(root "SELECT (patas_fechadas_en_el_futuro >= 0) || '|' || (SELECT ok FROM public.v_integridad_global) FROM public.v_reloj_estado")"
fin
