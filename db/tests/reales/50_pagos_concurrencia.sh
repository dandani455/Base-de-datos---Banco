#!/bin/sh
# 50_pagos_concurrencia.sh - Etapa 9 - pagos, abonos y cobro automatico bajo CONCURRENCIA con conexiones reales de banco_app (cada sesion espera una hora de arranque comun para chocar
# de verdad):
#   1. 6 pagar_cuota SIMULTANEOS con `numero` = 1: EXACTAMENTE uno paga; los demas "Recurso no encontrado" (idempotencia, D-E9-8); una sola cuota pagada y un solo grupo de cuota.
#   2. 6 pagar_cuota SIMULTANEOS sin `numero`: se serializan y pagan 6 cuotas CONSECUTIVAS distintas (ni una repetida, ni una saltada).
#   3. 6 abonar_credito SIMULTANEOS: todos entran en serie y el capital baja exactamente 6 veces el abono; el plan cuadra con la deuda.
#   4. Una cuota vencida con descuento activo y saldo: 8 LECTURAS simultaneas + 2 pagos manuales con `numero` = 1: la cuota se paga UNA sola vez (automatica o manual) y nada falla.
#   5. Transferencias CRUZADAS A->B / B->A (12 en cada sentido) con cobros automaticos pendientes en AMBOS: sin deadlock y todas salen.
# Termina SIEMPRE en modo real, sin productos de prueba, sin tasa de mora y con la integridad global en orden.
. /work/tests/reales/lib.sh
restaurar() { wait; root "DELETE FROM public.credito WHERE producto_id IN (SELECT id FROM public.credito_producto WHERE nombre LIKE 'T50 %')" >/dev/null; root "DELETE FROM public.credito_producto WHERE nombre LIKE 'T50 %'" >/dev/null; root "UPDATE public.parametro SET tasa_mora_anual = NULL" >/dev/null; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c50_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
root "UPDATE public.parametro SET tasa_mora_anual = 30" >/dev/null
root "SELECT public._reloj_actualizar(false, to_char(public.hoy_banco(), 'YYYY-MM-DD'))" >/dev/null
jump() { root "SELECT public._reloj_actualizar(false, (public.hoy_banco() + $1)::text)" >/dev/null; }

par() {
  _p=$1; _n=$2; _g=$3; _t=${START:-$(( $(date +%s) + 3 ))}; _i=1
  while [ $_i -le $_n ]; do
    _sql=$($_g $_i)
    ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" \
        -c "SELECT pg_sleep(GREATEST(0, $_t - extract(epoch from clock_timestamp())))" -c "$_sql" > /tmp/c50_${_p}_$_i.out 2>&1 </dev/null ) &
    _i=$((_i+1))
  done
  wait
}
cuenta() { cat /tmp/c50_$1_*.out | grep -c "$2"; }
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
U() { root "SELECT tests.u($1)"; }
newprod() { root "WITH x AS (INSERT INTO public.credito_producto (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES ('$1', '', $2, 1, 1000000000, 1, 360) RETURNING id) SELECT id FROM x"; }
cred() { _k=$(root "SELECT (public.solicitar_credito(tests.u($1), '$2', $3, $4) ->> 'id')"); root "UPDATE public.cuota SET fecha_vencimiento = public.hoy_banco() + 30 * numero WHERE credito_id = '$_k'" >/dev/null; echo "$_k"; }
pagadas() { root "SELECT coalesce(string_agg(numero::text, ',' ORDER BY numero), '-') FROM public.cuota WHERE credito_id = '$1' AND pagada"; }
ngr() { root "SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE credito_id = '$1' AND tipo = '$2'"; }
PL=$(newprod 'T50 Libre' 18)

# ---- 1. 6 pagos con numero = 1 ------------------------------------------------------------------------------------------------------
alta 1100 30000000; U1=$(U 1100); K1=$(cred 1100 "$PL" 10000000 12)
g1() { echo "SELECT public.pagar_cuota('$U1', '$K1', 1)"; }
par c1 6 g1
eq "1. 6 pagos simultaneos con numero = 1: EXACTAMENTE 1 paga y 5 reciben Recurso no encontrado (idempotencia)" "1|5" "$(cuenta c1 '"numero": 1')|$(cuenta c1 'Recurso no encontrado')"
eq "1. ...ni un solo error filtrado de deadlock, timeout, saldo o llave duplicada" "0" "$(cat /tmp/c50_c1_*.out | grep -ci 'deadlock\|timeout\|Saldo\|duplicate\|violates')"
eq "1. ...UNA cuota pagada, UN grupo CREDITO_CUOTA y el plan cuadra con la deuda" "1|1|t" "$(pagadas $K1 | tr -d '\n')|$(ngr $K1 CREDITO_CUOTA)|$(root "SELECT ok FROM public.v_integridad_creditos WHERE credito_id = '$K1'" | sed 's/true/t/')"

# ---- 2. 6 pagos sin numero ----------------------------------------------------------------------------------------------------------
alta 1101 30000000; U2=$(U 1101); K2=$(cred 1101 "$PL" 10000000 12)
g2() { echo "SELECT public.pagar_cuota('$U2', '$K2')"; }
par c2 6 g2
eq "2. 6 pagos simultaneos sin numero: todos responden OK y se serializan" "6|0" "$(cuenta c2 '"numero"')|$(cat /tmp/c50_c2_*.out | grep -ci 'ERROR')"
eq "2. ...pagan 6 cuotas CONSECUTIVAS distintas (1..6): ninguna repetida ni saltada, y 6 grupos de cuota" "1,2,3,4,5,6|6" "$(pagadas $K2)|$(ngr $K2 CREDITO_CUOTA)"
eq "2. ...capital pendiente = capital de las 6 impagas restantes (ct_credito_plan) y saldo de la cuenta = 30.000.000 + 10.000.000 - 6 cuotas" "t|t" "$(root "SELECT ((SELECT ok FROM public.v_integridad_creditos WHERE credito_id = '$K2')::text) || '|' || ((SELECT balance FROM public.cuenta WHERE id = tests.c(1101)) = 40000000 - (SELECT sum(valor_cuota) FROM public.cuota WHERE credito_id = '$K2' AND pagada))::text" | sed 's/true/t/g')"

# ---- 3. 6 abonos simultaneos --------------------------------------------------------------------------------------------------------
alta 1102 30000000; U3=$(U 1102); K3=$(cred 1102 "$PL" 10000000 12)
g3() { echo "SELECT public.abonar_credito('$U3', '$K3', '500000')"; }
par c3 6 g3
eq "3. 6 abonos simultaneos del mismo credito: todos entran en serie, ninguno falla" "6|0" "$(cuenta c3 '"capital"')|$(cat /tmp/c50_c3_*.out | grep -ci 'ERROR')"
eq "3. ...el capital baja EXACTAMENTE 6 x 500.000 (7.000.000), 6 grupos de abono y el plan cuadra (11 cuotas... las 12 impagas)" "7000000.00|6|12|t" "$(root "SELECT (SELECT capital_pendiente FROM public.credito WHERE id = '$K3') || '|' || (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE credito_id = '$K3' AND tipo = 'CREDITO_ABONO') || '|' || (SELECT count(*) FROM public.cuota WHERE credito_id = '$K3' AND NOT pagada) || '|' || (SELECT ok FROM public.v_integridad_creditos WHERE credito_id = '$K3')" | sed 's/true/t/')"

# ---- 4. cobro automatico: lecturas simultaneas + pagos manuales con numero = 1 ------------------------------------------------------
alta 1103 30000000; U4=$(U 1103); K4=$(cred 1103 "$PL" 10000000 12)
as banco_app $APP_PW "SELECT public.activar_descuento_automatico('$U4', '$K4', true)" >/dev/null
jump 40                                                                                    # la cuota 1 vencio el dia 30
g4() { if [ $1 -le 8 ]; then echo "SELECT public.vista_creditos('$U4')"; else echo "SELECT public.pagar_cuota('$U4', '$K4', 1)"; fi; }
par c4 10 g4
eq "4. 8 lecturas + 2 pagos manuales con numero = 1 sobre una cuota vencida con descuento activo: ninguna falla con deadlock o timeout" "0" "$(cat /tmp/c50_c4_*.out | grep -ci 'deadlock\|timeout\|duplicate\|violates')"
eq "4. ...la cuota 1 se paga UNA sola vez (la automatica al dia de su vencimiento, sin mora, o la manual): 1 cuota pagada, 1 grupo de cuota y 0 de mora" "1|1|0" "$(pagadas $K4)|$(ngr $K4 CREDITO_CUOTA)|$(ngr $K4 CREDITO_MORA)"
eq "4. ...los pagos manuales sobrantes recibieron Recurso no encontrado (la cuota ya estaba pagada), nunca pagaron la 2" "t" "$(root "SELECT (SELECT count(*) FROM public.cuota WHERE credito_id = '$K4' AND pagada) = 1" | sed 's/true/t/')"
eq "4. ...integridad en orden (planes, cursor y libro)" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"

# ---- 5. transferencias cruzadas con cobros automaticos pendientes en ambos emisores ---------------------------------------------------
alta 1104 30000000; alta 1105 30000000; UA=$(U 1104); UB=$(U 1105)
KA=$(cred 1104 "$PL" 10000000 12); KB=$(cred 1105 "$PL" 10000000 12)
as banco_app $APP_PW "SELECT public.activar_descuento_automatico('$UA', '$KA', true)" >/dev/null; as banco_app $APP_PW "SELECT public.activar_descuento_automatico('$UB', '$KB', true)" >/dev/null
NA=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(1104)"); NB=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(1105)")
jump 80                                                                                    # las cuotas 1 y 2 (dias 30 y 60) de ambos vencieron: hay cobros automaticos pendientes en los DOS emisores
g5() { if [ $1 -le 12 ]; then echo "SELECT public.hacer_transferencia('$UA', '$NB', 1000, 'c', NULL)"; else echo "SELECT public.hacer_transferencia('$UB', '$NA', 1000, 'c', NULL)"; fi; }
par c5 24 g5
eq "5. 24 transferencias cruzadas con cobros automaticos pendientes en ambos emisores: sin deadlock ni timeout" "0" "$(cat /tmp/c50_c5_*.out | grep -ci 'deadlock\|timeout')"
eq "5. ...las 24 salen y cada credito cobro sus 2 cuotas vencidas UNA vez (2 pagadas, 2 grupos de cuota)" "24|2|2|2|2" "$(cuenta c5 '"id"')|$(pagadas $KA | tr ',' '\n' | wc -l | tr -d ' ')|$(ngr $KA CREDITO_CUOTA)|$(pagadas $KB | tr ',' '\n' | wc -l | tr -d ' ')|$(ngr $KB CREDITO_CUOTA)"
eq "5. ...integridad global (partida doble, I5u, planes) en orden" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
