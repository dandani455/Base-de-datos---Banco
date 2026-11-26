#!/bin/sh
# 44_bolsillos_concurrencia.sh - Etapa 6 - bolsillos bajo CONCURRENCIA con conexiones reales de banco_app (cada sesion espera una hora de arranque comun
# para chocar de verdad):
#   1. 6 sesiones retiran 800 del MISMO bolsillo con saldo 1000: gana 1, las otras 5 reciben 'Saldo insuficiente'; el bolsillo queda en 200.
#   2. Movimientos CRUZADOS A->B / B->A (15 en cada sentido) mas ingresos y retiros del mismo cliente: ninguno falla, sin deadlock; el dinero se conserva.
#   3. Bolsillo vs ENVIO de E5 desde ese mismo bolsillo (4 retiros + 4 envios de 400 con saldo 500): sale EXACTAMENTE 1; conservacion entre cuenta, bolsillo y destino.
#   4. 12 crear_bolsillo concurrentes mientras el administrador BORRA al usuario: cada uno sale o recibe 'Sesion invalida' (nunca otro error) y no queda un bolsillo huerfano.
#   5. LECTURAS CONSISTENTES: 6 sesiones leen vista_balance en bucle mientras 4 sesiones mueven dinero sin parar: en TODAS las respuestas total = principal + suma de saldos
#      y el total del cliente es constante (nunca se ve un movimiento a medias).
#   6. 24 movimientos cruzados mientras el admin cambia el reloj (adelanta y vuelve a real): ninguno falla y cada movimiento lleva una sola fecha.
# Termina SIEMPRE en modo real y con la integridad global en orden.
. /work/tests/reales/lib.sh
restaurar() { wait; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c44_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null

# par PREFIJO N GENERADOR : N sesiones simultaneas; la sesion i ejecuta el SQL que imprime  GENERADOR i  y deja su salida en /tmp/c44_PREFIJO_i.out
# (START = instante comun de arranque; por defecto dentro de 3 s)
par() {
  _p=$1; _n=$2; _g=$3; _t=${START:-$(( $(date +%s) + 3 ))}; _i=1
  while [ $_i -le $_n ]; do
    _sql=$($_g $_i)
    ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" \
        -c "SELECT pg_sleep(GREATEST(0, $_t - extract(epoch from clock_timestamp())))" -c "$_sql" > /tmp/c44_${_p}_$_i.out 2>&1 </dev/null ) &
    _i=$((_i+1))
  done
  wait
}
cuenta() { cat /tmp/c44_$1_*.out | grep -c "$2"; }
errores_ajenos() { cat /tmp/c44_$1_*.out | grep '^ERROR' | grep -vc "$2"; }       # errores que NO son el esperado
sal() { root "SELECT balance FROM public.cuenta WHERE id = tests.c($1)"; }
salb() { root "SELECT balance FROM public.bolsillo WHERE id = tests.b($1)"; }
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
bol() { root "SELECT tests.bolsillo($1, tests.c($2))" >/dev/null; [ "${3:-0}" != 0 ] && root "SELECT tests.app_bolso_ingreso(tests.c($2), tests.b($1), $3)" >/dev/null; }   # bol N_BOLSILLO CLIENTE [MONTO]
U() { root "SELECT tests.u($1)"; }
OKP='"id"'

# ---- 1. 6 x 800 del mismo bolsillo (saldo 1000) ----------------------------------------------------------------------------------
alta 930 1000; bol 9301 930 1000; U930=$(U 930)
g1() { echo "SELECT public.retirar_de_bolsillo('$U930', '$(root 'SELECT tests.b(9301)')', 800)"; }
par c1 6 g1
eq "1. 6 retiros de 800 del mismo bolsillo con saldo 1000: exactamente UNO sale" "1" "$(cuenta c1 "$OKP")"
eq "1. ...los otros 5 reciben 'Saldo insuficiente' y ningun otro error (ni deadlock ni timeout)" "5|0" "$(cuenta c1 'Saldo insuficiente')|$(errores_ajenos c1 'Saldo insuficiente')"
eq "1. ...bolsillo 200, cuenta 800 y UN solo grupo BOLSO_RETIRO" "200.00|800.00|1" "$(salb 9301)|$(sal 930)|$(root "SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE tipo = 'BOLSO_RETIRO' AND cuenta_id = tests.c(930)")"

# ---- 2. cruzados A->B / B->A + ingresos y retiros del mismo cliente ---------------------------------------------------------------
alta 931 300000; bol 9311 931 100000; bol 9312 931 100000; U931=$(U 931); BA=$(root "SELECT tests.b(9311)"); BB=$(root "SELECT tests.b(9312)")
g2() { if [ $1 -le 15 ]; then echo "SELECT public.mover_entre_bolsillos('$U931', '$BA', '$BB', $((100 + $1)))"
       elif [ $1 -le 30 ]; then echo "SELECT public.mover_entre_bolsillos('$U931', '$BB', '$BA', $((200 + $1)))"
       elif [ $(($1 % 2)) -eq 1 ]; then echo "SELECT public.mover_a_bolsillo('$U931', '$BA', 50)"
       else echo "SELECT public.retirar_de_bolsillo('$U931', '$BB', 50)"; fi; }
par c2 40 g2
eq "2. 40 movimientos concurrentes (A->B, B->A, ingresos y retiros del mismo cliente): TODOS salen" "40|0" "$(cuenta c2 "$OKP")|$(cat /tmp/c44_c2_*.out | grep -v '^$' | grep -v "$OKP" | wc -l)"
eq "2. ...sin deadlock ni lock_timeout (cero errores de cualquier tipo)" "0" "$(cat /tmp/c44_c2_*.out | grep -ci 'deadlock\|timeout\|ERROR')"
eq "2. ...saldos exactos: A = 100000 - sum(101..115) + sum(216..230) + 5*50; B al reves - 5*50; cuenta = 100000 - 250 + 250" \
   "$(root "SELECT (100000 - (SELECT sum(100 + g) FROM generate_series(1,15) g) + (SELECT sum(200 + g) FROM generate_series(16,30) g) + 5 * 50)::numeric(18,2)")|$(root "SELECT (100000 + (SELECT sum(100 + g) FROM generate_series(1,15) g) - (SELECT sum(200 + g) FROM generate_series(16,30) g) - 5 * 50)::numeric(18,2)")|100000.00" \
   "$(salb 9311)|$(salb 9312)|$(sal 931)"
eq "2. ...el cliente conserva sus 300000 entre cuenta y bolsillos" "300000.00" "$(root "SELECT (SELECT balance FROM public.cuenta WHERE id = tests.c(931)) + (SELECT sum(balance) FROM public.bolsillo WHERE cuenta_id = tests.c(931))")"

# ---- 3. retiros vs envios de E5 desde el mismo bolsillo ---------------------------------------------------------------------------
alta 932 500; bol 9321 932 500; alta 933 0; U932=$(U 932); B932=$(root "SELECT tests.b(9321)")
g3() { if [ $1 -le 4 ]; then echo "SELECT public.retirar_de_bolsillo('$U932', '$B932', 400)"; else echo "SELECT public.hacer_transferencia('$U932', '4000000933', 400, NULL, '$B932')"; fi; }
par c3 8 g3
eq "3. 4 retiros y 4 envios de 400 desde un bolsillo con 500: sale EXACTAMENTE 1; los otros 7 'Saldo insuficiente' y ningun otro error" "1|7|0" "$(cuenta c3 "$OKP")|$(cuenta c3 'Saldo insuficiente')|$(errores_ajenos c3 'Saldo insuficiente')"
eq "3. ...el bolsillo queda en 100 y el dinero se conserva entre la cuenta, el bolsillo y el destino (500)" "100.00|500.00" "$(salb 9321)|$(root "SELECT (SELECT balance FROM public.cuenta WHERE id = tests.c(932)) + (SELECT balance FROM public.cuenta WHERE id = tests.c(933)) + (SELECT balance FROM public.bolsillo WHERE id = tests.b(9321))")"

# ---- 4. crear_bolsillo mientras el administrador borra al usuario ----------------------------------------------------------------
alta 934 1000; U934=$(U 934)
g4() { echo "SELECT public.crear_bolsillo('$U934', 'Carrera $1')"; }
START=$(( $(date +%s) + 3 ))
( psql -X -q -At -U postgres -d "$DB" -c "SELECT pg_sleep(GREATEST(0, $START - extract(epoch from clock_timestamp())) + 0.02)" -c "DELETE FROM public.usuario WHERE id = '$U934'" > /tmp/c44_c4_del.out 2>&1 </dev/null ) &
par c4 12 g4
wait
unset START
eq "4. 12 crear_bolsillo mientras el admin borra al usuario: el borrado se confirmo" "0" "$(root "SELECT count(*) FROM public.usuario WHERE id = '$U934'")"
eq "4. ...cada creacion salio o recibio 'Sesión inválida' (12 en total) y NINGUN otro error (ni FK ni 'Libro mayor')" "12|0" "$(($(cuenta c4 "$OKP") + $(cuenta c4 'Sesión inválida')))|$(errores_ajenos c4 'Sesión inválida')"
eq "4. ...no quedo ningun bolsillo huerfano (todos los 'Carrera N' se fueron con la cuenta)" "0" "$(root "SELECT count(*) FROM public.bolsillo WHERE nombre LIKE 'Carrera %'")"

# ---- 5. lecturas consistentes de vista_balance mientras otras sesiones mueven dinero --------------------------------------------
alta 935 1000000; bol 9351 935 250000; bol 9352 935 250000; U935=$(U 935); A5=$(root "SELECT tests.b(9351)"); B5=$(root "SELECT tests.b(9352)")
g5() {
  if [ $1 -le 4 ]; then
    echo "SELECT count(public.mover_entre_bolsillos('$U935', '$A5', '$B5', 1)) + count(public.mover_entre_bolsillos('$U935', '$B5', '$A5', 1)) + count(public.mover_a_bolsillo('$U935', '$A5', 1)) + count(public.retirar_de_bolsillo('$U935', '$A5', 1)) FROM generate_series(1, 50) g"
  else
    echo "SELECT count(*) || '|' || count(*) FILTER (WHERE (v ->> 'total')::numeric <> (v ->> 'principal')::numeric + (SELECT coalesce(sum((e ->> 'saldo')::numeric), 0) FROM jsonb_array_elements(v -> 'bolsillos') e)) || '|' || count(*) FILTER (WHERE (v ->> 'total')::numeric <> 1000000) FROM (SELECT public.vista_balance('$U935') AS v FROM generate_series(1, 250)) z"
  fi
}
# E9: cada movedor hace sus 200 movimientos en 5 sentencias de 10 vueltas (antes 1 de 50): con 10 sesiones contra UN cliente la sentencia unica rozaba el statement_timeout de 5 s de banco_app
par5() {
  _t=${START:-$(( $(date +%s) + 3 ))}; _i=1
  while [ $_i -le 10 ]; do
    if [ $_i -le 4 ]; then
      _m="SELECT count(public.mover_entre_bolsillos('$U935', '$A5', '$B5', 1)) + count(public.mover_entre_bolsillos('$U935', '$B5', '$A5', 1)) + count(public.mover_a_bolsillo('$U935', '$A5', 1)) + count(public.retirar_de_bolsillo('$U935', '$A5', 1)) FROM generate_series(1, 10) g"
      ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT pg_sleep(GREATEST(0, $_t - extract(epoch from clock_timestamp())))" -c "$_m" -c "$_m" -c "$_m" -c "$_m" -c "$_m" > /tmp/c44_c5_$_i.out 2>&1 </dev/null ) &
    else
      _sql=$(g5 $_i)
      ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT pg_sleep(GREATEST(0, $_t - extract(epoch from clock_timestamp())))" -c "$_sql" > /tmp/c44_c5_$_i.out 2>&1 </dev/null ) &
    fi
    _i=$((_i+1))
  done
  wait
}
par5
eq "5. los 4 movedores terminaron sus 200 movimientos cada uno, sin un solo error" "800|0" "$(cat /tmp/c44_c5_[1-4].out | awk '{n+=$1} END {print n}')|$(cat /tmp/c44_c5_*.out | grep -c ERROR)"
eq "5. las 6 sesiones lectoras hicieron 1500 lecturas: NINGUNA con total <> principal + suma de saldos y NINGUNA con total <> 1000000 (nunca un movimiento a medias)" "1500|0|0" "$(cat /tmp/c44_c5_[5-9].out /tmp/c44_c5_10.out | awk -F'|' '{n+=$1; s+=$2; t+=$3} END {print n"|"s"|"t}')"
eq "5. ...los movimientos son de suma cero: cuenta 500000 y bolsillos 250000 + 250000 al terminar" "500000.00|250000.00|250000.00" "$(sal 935)|$(salb 9351)|$(salb 9352)"

# ---- 6. movimientos mientras el admin cambia el reloj ---------------------------------------------------------------------------
alta 936 150000; bol 9361 936 50000; bol 9362 936 50000; U936=$(U 936); A6=$(root "SELECT tests.b(9361)"); B6=$(root "SELECT tests.b(9362)")
R=$(root "SELECT (now() AT TIME ZONE 'America/Bogota')::date")
( i=0; while [ $i -lt 8 ]; do
    psql -X -q -At -U postgres -d "$DB" -c "SELECT public._reloj_actualizar(false, DATE '$R' + $((i+2)))" >/dev/null 2>&1 </dev/null
    psql -X -q -At -U postgres -d "$DB" -c "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null 2>&1 </dev/null
    i=$((i+1)); done ) &
g6() { if [ $(($1 % 3)) -eq 0 ]; then echo "SELECT public.mover_entre_bolsillos('$U936', '$A6', '$B6', $((10 + $1)))"
       elif [ $(($1 % 3)) -eq 1 ]; then echo "SELECT public.mover_entre_bolsillos('$U936', '$B6', '$A6', $((10 + $1)))"
       else echo "SELECT public.mover_a_bolsillo('$U936', '$A6', $((10 + $1)))"; fi; }
par c6 24 g6
wait
eq "6. 24 movimientos concurrentes con cambios de reloj del admin al mismo tiempo: TODOS salen, sin errores" "24|0" "$(cuenta c6 "$OKP")|$(cat /tmp/c44_c6_*.out | grep -v '^$' | grep -vc "$OKP")"
eq "6. ...cada movimiento lleva UNA sola fecha en sus 2 patas y la pareja esta completa" "0" "$(root "SELECT count(*) FROM (SELECT grupo_id FROM public.transaccion WHERE tipo IN ('BOLSO_INGRESO','BOLSO_MOVIMIENTO') AND cuenta_id = tests.c(936) GROUP BY grupo_id HAVING min(fecha) <> max(fecha) OR count(*) <> 2) q")"
eq "6. ...el cliente conserva sus 150000 entre cuenta y bolsillos" "150000.00" "$(root "SELECT (SELECT balance FROM public.cuenta WHERE id = tests.c(936)) + (SELECT sum(balance) FROM public.bolsillo WHERE cuenta_id = tests.c(936))")"

# ---- cierre ------------------------------------------------------------------------------------------------------------------
eq "7. integridad global y defensas en orden" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
eq "7. nadie quedo con saldo negativo" "0" "$(root "SELECT (SELECT count(*) FROM public.cuenta WHERE balance < 0) + (SELECT count(*) FROM public.bolsillo WHERE balance < 0)")"
eq "7. el reloj termina en modo real" "t" "$(root "SELECT usar_fecha_real FROM public.reloj WHERE id = 1" | sed 's/true/t/')"
fin
