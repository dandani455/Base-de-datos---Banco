#!/bin/sh
# 25_concurrencia_directa.sh - Etapa 2 - una sesion escribe en el libro por el camino NO sancionado (INSERT directo
# pata por pata, en orden "natural") mientras otra usa el camino sancionado (_asentar_grupo), cruzando las mismas
# cuentas. Los inserts directos NO siguen el protocolo de bloqueo, asi que PostgreSQL puede resolver algun deadlock
# abortando una transaccion (es el costo de no usar el camino sancionado). Lo que se exige es que NUNCA haya
# corrupcion: ni grupos incompletos, ni saldos que no cuadren con el libro, y que el dinero se conserve.
. /work/tests/reales/lib.sh

A=$(root "SELECT tests.cliente(331)"); B=$(root "SELECT tests.cliente(332)")
root "SELECT tests.fondear(tests.c(331), 10000); SELECT tests.fondear(tests.c(332), 10000)" >/dev/null
NA=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id='$A'"); NB=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id='$B'")

: > /tmp/c25_directo.sql
k=0
while [ $k -lt 60 ]; do
  cat >> /tmp/c25_directo.sql <<SQL
DO \$\$ DECLARE g uuid := gen_random_uuid(); BEGIN
  INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, cuenta_id, contraparte_nombre, contraparte_cuenta)
    VALUES (g, now(), 'ENVIO', 'CUENTA', 'S', 1, '$A', 'B', '$NB');
  PERFORM pg_sleep(0.01);
  INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, cuenta_id, contraparte_nombre, contraparte_cuenta)
    VALUES (g, now(), 'RECIBO', 'CUENTA', 'E', 1, '$B', 'A', '$NA');
END \$\$;
SQL
  k=$((k+1))
done
: > /tmp/c25_sancionado.sql
k=0
while [ $k -lt 60 ]; do echo "SELECT public._asentar_grupo(now(), tests.g_envio('$B','$A',1));" >> /tmp/c25_sancionado.sql; k=$((k+1)); done

( psql -X -q -At -U postgres -d "$DB" -f /tmp/c25_directo.sql > /tmp/c25_d.out 2>&1 </dev/null ) &
( psql -X -q -At -U postgres -d "$DB" -f /tmp/c25_sancionado.sql > /tmp/c25_s.out 2>&1 </dev/null ) &
wait

DEAD=$(cat /tmp/c25_d.out /tmp/c25_s.out | grep -ci 'deadlock')
OTROS=$(cat /tmp/c25_d.out /tmp/c25_s.out | grep -i 'error' | grep -vci 'deadlock')
echo "info: deadlocks resueltos por PostgreSQL en el camino no sancionado = $DEAD"
eq "ningun error que no sea un deadlock resuelto" "0" "$OTROS"
eq "sin grupos incompletos ni descuadrados (v_integridad_grupos)" "0" "$(root "SELECT count(*) FROM public.v_integridad_grupos WHERE NOT ok")"
eq "cada saldo coincide con la suma de sus patas (v_integridad_saldos)" "0" "$(root "SELECT count(*) FROM public.v_integridad_saldos WHERE NOT ok")"
eq "conservacion: 20000.00 en las dos cuentas" "20000.00" "$(root "SELECT sum(balance) FROM public.cuenta WHERE id IN ('$A','$B')")"
eq "las vistas de integridad estan en orden" "t" "$(root "SELECT ok FROM public.v_integridad_global")"
rm -f /tmp/c25_*
fin
