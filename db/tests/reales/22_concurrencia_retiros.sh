#!/bin/sh
# 22_concurrencia_retiros.sh - Etapa 2 - seis conexiones REALES de banco_app intentan, a la vez, mover 800 de una
# cuenta que solo tiene 1000. Debe ganar EXACTAMENTE una; las otras cinco reciben "Saldo insuficiente"; el saldo
# nunca queda negativo y no hay deadlocks ni timeouts. Cada sesion espera a una hora de arranque comun para chocar.
. /work/tests/reales/lib.sh

A=$(root "SELECT tests.cliente(301)")
root "SELECT tests.bolsillo(301, tests.c(301)); SELECT tests.fondear(tests.c(301), 1000)" >/dev/null
BOL=$(root "SELECT tests.b(301)")

T=$(( $(date +%s) + 3 ))
i=1
while [ $i -le 6 ]; do
  ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" \
      -c "SELECT pg_sleep(GREATEST(0, $T - extract(epoch from clock_timestamp())))" \
      -c "SELECT tests.app_bolso_ingreso('$A', '$BOL', 800)" > /tmp/r22_$i.out 2>&1 </dev/null ) &
  i=$((i+1))
done
wait

OK=$(cat /tmp/r22_*.out | grep -cE '^[0-9a-f-]{36}$')
INS=$(cat /tmp/r22_*.out | grep -c 'Saldo insuficiente')
OTROS=$(cat /tmp/r22_*.out | grep -iE 'ERROR' | grep -vc 'Saldo insuficiente')
eq "exactamente 1 de las 6 sesiones concurrentes logro el movimiento" "1" "$OK"
eq "las otras 5 recibieron 'Saldo insuficiente'" "5" "$INS"
eq "ningun otro error (ni deadlock, ni timeout de bloqueo)" "0" "$OTROS"
eq "saldos finales exactos: cuenta 200.00 y bolsillo 800.00" "200.00|800.00" \
   "$(root "SELECT (SELECT balance FROM public.cuenta WHERE id='$A') || '|' || (SELECT balance FROM public.bolsillo WHERE id='$BOL')")"
eq "el saldo de la cuenta nunca queda negativo y las vistas de integridad estan en orden" "t" \
   "$(root "SELECT (SELECT balance >= 0 FROM public.cuenta WHERE id='$A') AND (SELECT ok FROM public.v_integridad_global)")"
rm -f /tmp/r22_*.out
fin
