#!/bin/sh
# 24_concurrencia_carga.sh - Etapa 2 - carga mixta: 8 conexiones REALES de banco_app hacen 250 transferencias
# aleatorias cada una entre 6 cuentas (2000 transferencias, cada una en su propia transaccion) mientras una conexion
# de banco_lector verifica en bucle las vistas de integridad. Debe haber 0 errores, 0 deadlocks, la suma total de
# saldos constante (conservacion del dinero) y ningun falso positivo del verificador bajo escritura concurrente.
. /work/tests/reales/lib.sh

i=321
while [ $i -le 326 ]; do root "SELECT tests.cliente($i); SELECT tests.fondear(tests.c($i), 100000)" >/dev/null; i=$((i+1)); done
TOTAL0=$(root "SELECT sum(balance) FROM public.cuenta WHERE id BETWEEN tests.c(321) AND tests.c(326)")
eq "punto de partida: 6 cuentas con 100000.00 (600000.00 en total)" "600000.00" "$TOTAL0"

gen() { # gen archivo semilla n : n transferencias aleatorias entre las cuentas 321..326
  awk -v seed="$2" -v n="$3" 'BEGIN { srand(seed);
    for (k = 0; k < n; k++) {
      o = int(rand() * 6) + 321; d = int(rand() * 6) + 321; while (d == o) d = int(rand() * 6) + 321;
      m = int(rand() * 400) + 1;
      printf "SELECT tests.app_envio(tests.c(%d), tests.c(%d), %d);\n", o, d, m } }' > "$1"
}

s=1
while [ $s -le 8 ]; do
  gen /tmp/c24_$s.sql "$s" 250
  ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -f /tmp/c24_$s.sql > /tmp/c24_$s.out 2>&1 </dev/null ) &
  s=$((s+1))
done
# verificador concurrente (lector): cada consulta es UNA sentencia => un solo snapshot => sin falsos positivos
( k=0; while [ $k -lt 25 ]; do
    PGPASSWORD=$LECTOR_PW psql -X -q -At -h "$HOST" -U banco_lector -d "$DB" \
      -c "SELECT (SELECT count(*) FROM public.v_integridad_saldos WHERE NOT ok) + (SELECT count(*) FROM public.v_integridad_grupos WHERE NOT ok) + (SELECT count(*) FROM public.v_integridad_usuario WHERE NOT ok)" </dev/null
    k=$((k+1)); done > /tmp/c24_lector.out 2>&1 ) &
wait

OKS=$(cat /tmp/c24_[1-8].out | grep -cE '^[0-9a-f-]{36}$')
INS=$(cat /tmp/c24_[1-8].out | grep -c 'Saldo insuficiente')
ERR=$(cat /tmp/c24_[1-8].out | grep -i 'error' | grep -vc 'Saldo insuficiente')
eq "las 2000 transferencias se resolvieron (exitosas + 'Saldo insuficiente' legitimas)" "2000" "$((OKS + INS))"
eq "ningun error distinto de 'Saldo insuficiente' (ni deadlock ni timeout)" "0" "$ERR"
eq "ningun deadlock" "0" "$(cat /tmp/c24_[1-8].out | grep -ci deadlock)"
eq "conservacion: la suma de saldos sigue siendo 600000.00" "$TOTAL0" "$(root "SELECT sum(balance) FROM public.cuenta WHERE id BETWEEN tests.c(321) AND tests.c(326)")"
eq "el verificador concurrente dio 25 respuestas, todas 0 desvios (sin falsos positivos)" "25|25" \
   "$(grep -c '^0$' /tmp/c24_lector.out)|$(wc -l < /tmp/c24_lector.out | tr -d ' ')"
eq "ningun saldo negativo" "0" "$(root "SELECT count(*) FROM public.cuenta WHERE balance < 0")"
eq "las vistas de integridad estan en orden tras la carga" "t" "$(root "SELECT ok FROM public.v_integridad_global")"
rm -f /tmp/c24_*
fin
