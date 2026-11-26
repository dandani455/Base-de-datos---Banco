#!/bin/sh
# 23_concurrencia_cruzadas.sh - Etapa 2 - transferencias CRUZADAS A->B y B->A al mismo tiempo desde dos conexiones
# reales de banco_app (200 cada una, cada transferencia en su propia transaccion). Con inserciones "naturales"
# (origen primero) este patron produce deadlocks (se demostro en el laboratorio); con el protocolo de bloqueo en
# orden de id NO debe haber ninguno. Saldos finales exactos (conservacion) e integridad en orden.
. /work/tests/reales/lib.sh

A=$(root "SELECT tests.cliente(311)"); B=$(root "SELECT tests.cliente(312)")
root "SELECT tests.fondear(tests.c(311), 100000); SELECT tests.fondear(tests.c(312), 100000)" >/dev/null
PATAS0=$(root "SELECT count(*) FROM public.transaccion")

gen() { # gen archivo origen destino monto n
  : > "$1"; k=0
  while [ $k -lt $5 ]; do echo "SELECT tests.app_envio('$2','$3',$4);" >> "$1"; k=$((k+1)); done
}
gen /tmp/c23_a.sql "$A" "$B" 1 200
gen /tmp/c23_b.sql "$B" "$A" 1 200

( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -f /tmp/c23_a.sql > /tmp/c23_a.out 2>&1 </dev/null ) &
( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -f /tmp/c23_b.sql > /tmp/c23_b.out 2>&1 </dev/null ) &
wait

eq "las 400 transferencias terminaron (200 + 200 grupos)" "400" "$(cat /tmp/c23_a.out /tmp/c23_b.out | grep -cE '^[0-9a-f-]{36}$')"
eq "ningun deadlock" "0" "$(cat /tmp/c23_a.out /tmp/c23_b.out | grep -ci 'deadlock')"
eq "ningun error de ningun tipo" "0" "$(cat /tmp/c23_a.out /tmp/c23_b.out | grep -ci 'error')"
eq "saldos finales exactos (lo enviado = lo recibido): 100000.00 y 100000.00" "100000.00|100000.00" \
   "$(root "SELECT (SELECT balance FROM public.cuenta WHERE id='$A') || '|' || (SELECT balance FROM public.cuenta WHERE id='$B')")"
eq "el libro tiene 800 patas nuevas (400 grupos x 2)" "800" "$(root "SELECT count(*) - $PATAS0 FROM public.transaccion")"
eq "las vistas de integridad estan en orden" "t" "$(root "SELECT ok FROM public.v_integridad_global")"
rm -f /tmp/c23_*.sql /tmp/c23_*.out
fin
