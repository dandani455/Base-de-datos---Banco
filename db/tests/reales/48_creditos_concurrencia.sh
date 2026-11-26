#!/bin/sh
# 48_creditos_concurrencia.sh - Etapa 8 - creditos bajo CONCURRENCIA con conexiones reales de banco_app (cada sesion espera una hora de arranque comun para chocar de verdad):
#   1. 6 solicitar_credito simultaneos del MISMO producto y usuario: EXACTAMENTE un credito; el resto "Ya tienes un crédito vigente de este producto" (nunca un 23505 filtrado).
#   2. 12 sesiones MEZCLADAS del mismo cliente (3 productos de credito, CDT, bolsillo, envio, lecturas) con intereses de bolsillo pendientes: ninguna falla con un error
#      inesperado, un solo devengo por bolsillo, un credito por producto y el dinero se conserva.
#   3. Tope de Inmuebles contra un envio simultaneo del mismo cliente (8 rondas): el resultado es siempre uno de los dos ordenes serializables y nunca se rebasa el tope.
#   4. Solicitudes de credito + transferencias CRUZADAS A->B / B->A con devengo pendiente: sin deadlock.
#   5. 12 lecturas simultaneas (vista_creditos y productos_disponibles) tras un salto de reloj: EXACTAMENTE un juego de asientos de devengo.
#   6. Bloqueo de cuenta COMPARTIDO: con la cuenta bloqueada, solicitar_credito ESPERA; productos_publicos (exenta, no lee a nadie) NO espera.
# Termina SIEMPRE en modo real, sin productos de prueba y con la integridad global en orden.
. /work/tests/reales/lib.sh
restaurar() { wait; root "DELETE FROM public.credito WHERE producto_id IN (SELECT id FROM public.credito_producto WHERE nombre LIKE 'T48 %')" >/dev/null; root "DELETE FROM public.credito_producto WHERE nombre LIKE 'T48 %'" >/dev/null; root "DELETE FROM public.cdt_definicion WHERE nombre LIKE 'T48 %'" >/dev/null; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c48_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
root "SELECT public._reloj_actualizar(false, to_char(public.hoy_banco(), 'YYYY-MM-DD'))" >/dev/null
jump() { root "SELECT public._reloj_actualizar(false, (public.hoy_banco() + $1)::text)" >/dev/null; }

par() {
  _p=$1; _n=$2; _g=$3; _t=${START:-$(( $(date +%s) + 3 ))}; _i=1
  while [ $_i -le $_n ]; do
    _sql=$($_g $_i)
    ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" \
        -c "SELECT pg_sleep(GREATEST(0, $_t - extract(epoch from clock_timestamp())))" -c "$_sql" > /tmp/c48_${_p}_$_i.out 2>&1 </dev/null ) &
    _i=$((_i+1))
  done
  wait
}
cuenta() { cat /tmp/c48_$1_*.out | grep -c "$2"; }
sal() { root "SELECT balance FROM public.cuenta WHERE id = tests.c($1)"; }
salb() { root "SELECT balance FROM public.bolsillo WHERE id = tests.b($1)"; }
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
bolh() { root "INSERT INTO public.bolsillo (id, cuenta_id, nombre, ultimo_cobro) VALUES (tests.b($1), tests.c($2), 'B$1', public.hoy_banco())" >/dev/null; [ "${3:-0}" != 0 ] && root "SELECT tests.app_bolso_ingreso(tests.c($2), tests.b($1), $3)" >/dev/null; return 0; }
U() { root "SELECT tests.u($1)"; }
ngr() { root "SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE tipo = '$1' AND cuenta_id = tests.c($2)"; }
newprod() { root "WITH x AS (INSERT INTO public.credito_producto (nombre, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses, tope_absoluto, multiplicador_balance, aplica_regla_edad) VALUES ('$1', $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id) SELECT id FROM x"; }
PL=$(newprod 'T48 Libre' 23.9 1000000 30000000 6 24 30000000 NULL false)
PV=$(newprod 'T48 Vehiculo' 18.9 5000000 200000000 12 120 NULL NULL false)
PE=$(newprod 'T48 Educacion' 15.4 1000000 100000000 6 240 NULL NULL false)
PI=$(newprod 'T48 Inmuebles' 14.1 1 2000000000 12 360 2000000000 100 true)
root "WITH x AS (INSERT INTO public.cdt_definicion (nombre, plazo_dias, tasa_anual, monto_min) VALUES ('T48 CDT 90', 90, 10, 100000) RETURNING id) SELECT 1 FROM x" >/dev/null
DEF=$(root "SELECT id FROM public.cdt_definicion WHERE nombre = 'T48 CDT 90'")
PERMITIDOS='Ya tienes un crédito vigente de este producto|Monto fuera de rango|Saldo insuficiente'

# ---- 1. 6 solicitudes simultaneas del mismo producto y usuario ---------------------------------------------------------------------
alta 990 50000000; U990=$(U 990)
g1() { echo "SELECT public.solicitar_credito('$U990', '$PL', '5000000', 12)"; }
par c1 6 g1
eq "1. 6 solicitudes simultaneas del mismo producto: EXACTAMENTE 1 acierta y 5 reciben el mensaje de negocio" "1|5" "$(cuenta c1 '"id"')|$(cuenta c1 'Ya tienes un crédito vigente de este producto')"
eq "1. ...ni un solo error filtrado del indice unico, de FK, de deadlock ni de timeout" "0" "$(cat /tmp/c48_c1_*.out | grep -ci 'duplicate key\|unique\|violates\|deadlock\|timeout')"
eq "1. ...UN credito, 12 cuotas, plan = deuda = libro, un solo grupo de desembolso" "1|12|5000000.00|1|t" "$(root "SELECT (SELECT count(*) FROM public.credito WHERE cuenta_id = tests.c(990)) || '|' || (SELECT count(*) FROM public.cuota q JOIN public.credito k ON k.id = q.credito_id WHERE k.cuenta_id = tests.c(990)) || '|' || (SELECT capital_pendiente FROM public.credito WHERE cuenta_id = tests.c(990)) || '|' || (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE cuenta_id = tests.c(990) AND tipo = 'CREDITO_DESEMBOLSO') || '|' || (SELECT bool_and(ok) FROM public.v_integridad_creditos WHERE cuenta_id = tests.c(990))" | sed 's/true/t/')"
eq "1. ...la cuenta recibio el desembolso UNA sola vez (50.000.000 + 5.000.000)" "55000000.00" "$(sal 990)"

# ---- 2. 12 sesiones mezcladas del mismo cliente ------------------------------------------------------------------------------------
alta 991 40000000; alta 995 1000; bolh 9911 991 1000000; bolh 9912 991 1000000; U991=$(U 991)
jump 30
g2() { case $1 in
  1|2) echo "SELECT public.solicitar_credito('$U991', '$PL', '3000000', 12)";;
  3) echo "SELECT public.solicitar_credito('$U991', '$PV', '60000000', 24)";;
  4) echo "SELECT public.solicitar_credito('$U991', '$PE', '2000000', 12)";;
  5) echo "SELECT public.crear_cdt('$U991', '$DEF', '200000')";;
  6) echo "SELECT public.mover_a_bolsillo('$U991', '$(root 'SELECT tests.b(9911)')', 1000)";;
  7) echo "SELECT public.hacer_transferencia('$U991', '$(root 'SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(995)')', 10, 'mix', NULL)";;
  8|9|10) echo "SELECT public.vista_creditos('$U991')";;
  11|12) echo "SELECT public.productos_disponibles('$U991')";;
esac; }
par c2 12 g2
eq "2. 12 sesiones mezcladas: ninguna falla con un error inesperado (solo los mensajes de negocio permitidos)" "0" "$(cat /tmp/c48_c2_*.out | grep '^ERROR' | grep -vcE "$PERMITIDOS")"
eq "2. ...UN credito por producto (Libre pedido 2 veces: 1; Vehiculo: 1; Educacion: 1) y la deuda = 3.000.000 + 60.000.000 + 2.000.000" "1|1|1|65000000.00" "$(root "SELECT (SELECT count(*) FROM public.credito WHERE cuenta_id = tests.c(991) AND producto_id = '$PL') || '|' || (SELECT count(*) FROM public.credito WHERE cuenta_id = tests.c(991) AND producto_id = '$PV') || '|' || (SELECT count(*) FROM public.credito WHERE cuenta_id = tests.c(991) AND producto_id = '$PE') || '|' || (SELECT sum(capital_pendiente) FROM public.credito WHERE cuenta_id = tests.c(991))")"
eq "2. ...UN solo devengo por bolsillo (2 grupos INTERES_BOLSO en total, nunca uno por sesion)" "2" "$(ngr INTERES_BOLSO 991)"
eq "2. ...partida doble, I5u y planes en orden tras la mezcla" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"

# ---- 3. Tope de Inmuebles contra un envio simultaneo (8 rondas) ---------------------------------------------------------------------
n=0; solo_ok=0; rechazo_tope=0; otros=0
while [ $n -lt 8 ]; do
  a=$((9930 + n * 2)); b=$((9931 + n * 2))
  alta $a 1000000; alta $b 1000; UA=$(U $a); NB=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c($b)")
  g3() { case $1 in 1) echo "SELECT public.solicitar_credito('$UA', '$PI', '100000000', 12)";; 2) echo "SELECT public.hacer_transferencia('$UA', '$NB', 600000, 'x', NULL)";; esac; }
  par c3_$n 2 g3
  ok_s=$(cat /tmp/c48_c3_${n}_1.out | grep -c '"id"'); rech=$(cat /tmp/c48_c3_${n}_1.out | grep -c 'Monto fuera de rango'); ok_t=$(cat /tmp/c48_c3_${n}_2.out | grep -c '"id"')
  if [ "$ok_s" = 1 ] && [ "$ok_t" = 1 ]; then solo_ok=$((solo_ok+1)); elif [ "$rech" = 1 ] && [ "$ok_t" = 1 ]; then rechazo_tope=$((rechazo_tope+1)); else otros=$((otros+1)); fi
  n=$((n+1))
done
eq "3. 8 rondas solicitar Inmuebles al tope (100 x 1.000.000) vs un envio de 600.000: siempre un orden serializable (credito+envio, o credito rechazado por tope y envio)" "0" "$otros"
eq "3. ...el tope nunca se rebasa: ningun credito de Inmuebles supera 100 x el patrimonio del momento (credito aprobado = patrimonio previo intacto)" "0" "$(root "SELECT count(*) FROM public.credito k WHERE k.producto_id = '$PI' AND k.monto > 100000000")"
eq "3. ...integridad global y planes en orden" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"

# ---- 4. Solicitudes + transferencias cruzadas con devengo pendiente en ambos emisores ----------------------------------------------
alta 992 20000000; alta 993 20000000; bolh 9921 992 1000000; bolh 9931 993 1000000; UA=$(U 992); UB=$(U 993)
NA=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(992)"); NBq=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(993)")
jump 30
T0=$(root "SELECT sum(balance) FROM public.cuenta WHERE id IN (tests.c(992), tests.c(993))")
g4() { if [ $1 -le 12 ]; then echo "SELECT public.hacer_transferencia('$UA', '$NBq', 1000, 'c', NULL)"; elif [ $1 -le 24 ]; then echo "SELECT public.hacer_transferencia('$UB', '$NA', 1000, 'c', NULL)"; elif [ $1 -le 27 ]; then echo "SELECT public.solicitar_credito('$UA', '$PL', '2000000', 12)"; else echo "SELECT public.solicitar_credito('$UB', '$PL', '2000000', 12)"; fi; }
par c4 30 g4
eq "4. 24 transferencias cruzadas + 6 solicitudes con devengo pendiente en ambos emisores: sin deadlock ni timeout" "0" "$(cat /tmp/c48_c4_*.out | grep -ci 'deadlock\|timeout')"
eq "4. ...las 24 transferencias salen y solo 1 credito por cliente (los demas reciben el mensaje de negocio)" "24|2|4" "$(root "SELECT count(*) FROM public.transaccion WHERE tipo = 'ENVIO' AND cuenta_id IN (tests.c(992), tests.c(993)) AND contenedor = 'CUENTA'")|$(root "SELECT count(*) FROM public.credito WHERE cuenta_id IN (tests.c(992), tests.c(993))")|$(cuenta c4 'Ya tienes un crédito vigente de este producto')"
eq "4. ...CONSERVACION: la suma de las dos cuentas = la inicial + 4.000.000 de desembolsos (los envios se cancelan; el interes de bolsillo queda en los bolsillos)" "t" "$(root "SELECT (sum(balance) = $T0 + 4000000) FROM public.cuenta WHERE id IN (tests.c(992), tests.c(993))" | sed 's/true/t/')"
eq "4. ...partida doble, I5u y planes en orden" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"

# ---- 5. 12 lecturas simultaneas tras un salto de reloj -------------------------------------------------------------------------------
alta 994 5000000; bolh 9941 994 1000000; bolh 9942 994 1000000; U994=$(U 994)
jump 30
g5() { if [ $1 -le 6 ]; then echo "SELECT public.vista_creditos('$U994')"; else echo "SELECT public.productos_disponibles('$U994')"; fi; }
par c5 12 g5
eq "5. 12 lecturas simultaneas con devengo pendiente: ninguna falla" "0" "$(cat /tmp/c48_c5_*.out | grep -ci 'ERROR\|deadlock\|timeout')"
eq "5. ...EXACTAMENTE un juego de asientos: 1 grupo INTERES_BOLSO por bolsillo (2), nunca 12" "2" "$(ngr INTERES_BOLSO 994)"
eq "5. ...las 6 vistas devuelven lo mismo y las 6 listas de productos tambien (todas ven el estado ya devengado)" "1|1" "$(cat /tmp/c48_c5_[1-6].out | grep -v '^$' | sort -u | wc -l | tr -d ' ')|$(cat /tmp/c48_c5_[7-9].out /tmp/c48_c5_1[0-2].out | grep -v '^$' | sort -u | wc -l | tr -d ' ')"

# ---- 6. Bloqueo de cuenta compartido -------------------------------------------------------------------------------------------------
alta 996 5000000; U996=$(U 996)
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.cuenta WHERE id = tests.c(996) FOR NO KEY UPDATE; SELECT pg_sleep(2.5); COMMIT;" > /tmp/c48_h.out 2>&1 </dev/null ) &
sleep 1
t0=$(date +%s); as banco_app $APP_PW "SELECT public.productos_publicos()" >/dev/null; t1=$(date +%s)
eq "6. productos_publicos (exenta: no lee a nadie) NO espera el bloqueo de la cuenta" "0" "$((t1 - t0))"
t0=$(date +%s); o=$(as banco_app $APP_PW "SELECT public.solicitar_credito('$U996', '$PL', '2000000', 12)"); t1=$(date +%s)
wait
contiene "6. solicitar_credito ESPERA el bloqueo de la cuenta y despues se concede" "$o" '"id"'
eq "6. ...esperó al menos 1 segundo (el bloqueo se sostuvo 2,5 s)" "t" "$([ $((t1 - t0)) -ge 1 ] && echo t || echo f)"
# 6b. un RECHAZO de negocio tambien espera: las validaciones (vigente, topes) se leen BAJO el bloqueo de la cuenta (con el bloqueo explicito removido, saldria de inmediato)
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.cuenta WHERE id = tests.c(996) FOR NO KEY UPDATE; SELECT pg_sleep(2.5); COMMIT;" > /tmp/c48_h2.out 2>&1 </dev/null ) &
sleep 1
t0=$(date +%s); o=$(as banco_app $APP_PW "SELECT public.solicitar_credito('$U996', '$PE', '1', 12)"); t1=$(date +%s)
wait
contiene "6. un rechazo de rango (Monto fuera de rango) TAMBIEN espera el bloqueo de la cuenta y luego se responde" "$o" 'Monto fuera de rango'
eq "6. ...esperó al menos 1 segundo: las validaciones se leen bajo el bloqueo explicito de la cuenta" "t" "$([ $((t1 - t0)) -ge 1 ] && echo t || echo f)"
eq "6. integridad global y planes en orden al final" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
