#!/bin/sh
# 42_transferencias_concurrencia.sh - Etapa 5 - transferencias bajo CONCURRENCIA con conexiones reales de banco_app (cada sesion espera una hora de
# arranque comun para chocar de verdad):
#   1. 6 sesiones envian 800 desde una cuenta con 1000: gana 1, las otras 5 reciben 'Saldo insuficiente'; el saldo queda en 200.
#   2. Envios CRUZADOS A<->B (20 en cada sentido, mas 10 de un tercero): ninguno falla, sin deadlock; el dinero se conserva.
#   3. 10 emisores con saldo exacto envian TODO a un mismo receptor: el receptor suma exacto y los emisores quedan en 0.
#   4. Cuenta principal vs bolsillo del mismo cliente (4 envios de 400 desde cada uno, saldos de 500): gana 1 de cada uno.
#   5. 24 envios concurrentes mientras el admin cambia el reloj (adelanta y vuelve a real): ninguno falla y cada envio lleva una sola fecha.
# Termina SIEMPRE en modo real y con la integridad global en orden.
. /work/tests/reales/lib.sh
restaurar() { wait; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c42_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null

# par PREFIJO N GENERADOR : N sesiones simultaneas; la sesion i ejecuta el SQL que imprime  GENERADOR i  y deja su salida en /tmp/c42_PREFIJO_i.out
par() {
  _p=$1; _n=$2; _g=$3; _t=$(( $(date +%s) + 3 )); _i=1
  while [ $_i -le $_n ]; do
    _sql=$($_g $_i)
    ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" \
        -c "SELECT pg_sleep(GREATEST(0, $_t - extract(epoch from clock_timestamp())))" -c "$_sql" > /tmp/c42_${_p}_$_i.out 2>&1 </dev/null ) &
    _i=$((_i+1))
  done
  wait
}
cuenta() { cat /tmp/c42_$1_*.out | grep -c "$2"; }
sal() { root "SELECT balance FROM public.cuenta WHERE id = '$1'"; }
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
tr_sql() { echo "SELECT public.hacer_transferencia('$(root "SELECT tests.u($1)")', '40$(printf %08d $2)', $3, NULL, $4)"; }   # tr_sql DE A MONTO BOLSILLO(literal SQL)
SUMA() { root "SELECT sum(x) FROM (SELECT balance AS x FROM public.cuenta UNION ALL SELECT balance FROM public.bolsillo) z"; }
SUMA0=$(SUMA)
OKP='"id"'

# ---- 1. 6 x 800 con saldo 1000 --------------------------------------------------------------------------------------------------
alta 801 1000; alta 802 0
g1() { tr_sql 801 802 800 NULL; }
par c1 6 g1
eq "1. 6 envios de 800 con saldo 1000: exactamente UNO sale" "1" "$(cuenta c1 "$OKP")"
eq "1. ...los otros 5 reciben 'Saldo insuficiente' y ningun otro error (ni deadlock ni timeout)" "5|0" "$(cuenta c1 'Saldo insuficiente')|$(cat /tmp/c42_c1_*.out | grep '^ERROR' | grep -vc 'Saldo insuficiente')"
eq "1. ...emisor 200, receptor 800 y UN solo grupo ENVIO/RECIBO" "200.00|800.00|1" "$(sal "$(root 'SELECT tests.c(801)')")|$(sal "$(root 'SELECT tests.c(802)')")|$(root "SELECT count(*) FROM public.transaccion WHERE tipo = 'ENVIO' AND cuenta_id = tests.c(801)")"

# ---- 2. cruzados A<->B y un tercero ---------------------------------------------------------------------------------------------
alta 811 100000; alta 812 100000; alta 813 100000
g2() { if [ $1 -le 20 ]; then tr_sql 811 812 $((100 + $1)) NULL; elif [ $1 -le 40 ]; then tr_sql 812 811 $((200 + $1)) NULL; else tr_sql 813 $((811 + ($1 % 2))) 50 NULL; fi; }
par c2 50 g2
eq "2. 50 envios cruzados (A->B, B->A y C->A/B): TODOS salen" "50|0" "$(cuenta c2 "$OKP")|$(cat /tmp/c42_c2_*.out | grep -v '^$' | grep -v '^CONTEXT' | grep -v 'PL/pgSQL' | grep -v '^SQL statement' | grep -v '^[[:space:]]*$' | grep -vc "$OKP")"
eq "2. ...sin deadlock ni lock_timeout (cero errores de cualquier tipo)" "0" "$(cat /tmp/c42_c2_*.out | grep -ci 'deadlock\|timeout\|ERROR')"
eq "2. ...saldos exactos: A = 100000 - sum(101..120) + sum(221..240), B al reves, C = 100000 - 500" \
   "$(root "SELECT (100000 - (SELECT sum(100 + g) FROM generate_series(1,20) g) + (SELECT sum(200 + g) FROM generate_series(21,40) g) + 5 * 50)::numeric(18,2)")|$(root "SELECT (100000 + (SELECT sum(100 + g) FROM generate_series(1,20) g) - (SELECT sum(200 + g) FROM generate_series(21,40) g) + 5 * 50)::numeric(18,2)")|99500.00" \
   "$(sal "$(root 'SELECT tests.c(811)')")|$(sal "$(root 'SELECT tests.c(812)')")|$(sal "$(root 'SELECT tests.c(813)')")"

# ---- 3. muchos -> uno, saldo exacto ---------------------------------------------------------------------------------------------
alta 860 0
i=1; while [ $i -le 10 ]; do alta $((860 + i)) 100; i=$((i+1)); done
g3() { tr_sql $((860 + $1)) 860 100 NULL; }
par c3 10 g3
eq "3. 10 emisores con saldo EXACTO (100) envian todo al mismo receptor: todos salen" "10|0" "$(cuenta c3 "$OKP")|$(cat /tmp/c42_c3_*.out | grep -v '^$' | grep -v '^CONTEXT' | grep -v 'PL/pgSQL' | grep -v '^SQL statement' | grep -v '^[[:space:]]*$' | grep -vc "$OKP")"
eq "3. ...receptor 1000 exacto y los 10 emisores en 0 (nadie negativo)" "1000.00|0|0" "$(sal "$(root 'SELECT tests.c(860)')")|$(root "SELECT count(*) FROM public.cuenta WHERE id IN (SELECT tests.c(860 + g) FROM generate_series(1,10) g) AND balance <> 0")|$(root "SELECT count(*) FROM public.cuenta WHERE balance < 0")"

# ---- 4. cuenta principal vs bolsillo del mismo cliente -------------------------------------------------------------------------
alta 830 1000; alta 831 0
root "SELECT tests.bolsillo(830, tests.c(830))" >/dev/null
root "SELECT tests.app_bolso_ingreso(tests.c(830), tests.b(830), 500)" >/dev/null          # cuenta 500, bolsillo 500
g4() { if [ $1 -le 4 ]; then tr_sql 830 831 400 NULL; else tr_sql 830 831 400 "'$(root 'SELECT tests.b(830)')'"; fi; }
par c4 8 g4
eq "4. 4 envios de 400 desde la cuenta (500) y 4 desde el bolsillo (500): salen EXACTAMENTE 2 (1 de cada origen)" "2|6" "$(cuenta c4 "$OKP")|$(cuenta c4 'Saldo insuficiente')"
eq "4. ...cuenta 100, bolsillo 100 y el receptor +800" "100.00|100.00|800.00" "$(sal "$(root 'SELECT tests.c(830)')")|$(root "SELECT balance FROM public.bolsillo WHERE id = tests.b(830)")|$(sal "$(root 'SELECT tests.c(831)')")"

# ---- 5. envios mientras el admin cambia el reloj ------------------------------------------------------------------------------
alta 840 100000; alta 841 100000
R=$(root "SELECT (now() AT TIME ZONE 'America/Bogota')::date")
( i=0; while [ $i -lt 8 ]; do
    psql -X -q -At -U postgres -d "$DB" -c "SELECT public._reloj_actualizar(false, DATE '$R' + $((i+2)))" >/dev/null 2>&1 </dev/null
    psql -X -q -At -U postgres -d "$DB" -c "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null 2>&1 </dev/null
    i=$((i+1)); done ) &
g5() { if [ $(($1 % 2)) -eq 0 ]; then tr_sql 840 841 $((10 + $1)) NULL; else tr_sql 841 840 $((10 + $1)) NULL; fi; }
par c5 24 g5
wait
eq "5. 24 envios cruzados con cambios de reloj del admin al mismo tiempo: TODOS salen, sin errores" "24|0" "$(cuenta c5 "$OKP")|$(cat /tmp/c42_c5_*.out | grep -v '^$' | grep -v '^CONTEXT' | grep -v 'PL/pgSQL' | grep -v '^SQL statement' | grep -v '^[[:space:]]*$' | grep -vc "$OKP")"
eq "5. ...cada envio lleva UNA sola fecha en sus 2 patas y la pareja ENVIO/RECIBO esta completa" "0|48" "$(root "SELECT count(*) FROM (SELECT grupo_id FROM public.transaccion WHERE tipo IN ('ENVIO','RECIBO') AND cuenta_id IN (tests.c(840), tests.c(841)) GROUP BY grupo_id HAVING min(fecha) <> max(fecha) OR count(*) <> 2) q")|$(root "SELECT count(*) FROM public.transaccion WHERE tipo IN ('ENVIO','RECIBO') AND cuenta_id IN (tests.c(840), tests.c(841))")"
eq "5. ...el dinero entre los dos se conserva (200000)" "200000.00" "$(root "SELECT sum(balance) FROM public.cuenta WHERE id IN (tests.c(840), tests.c(841))")"

# ---- cierre ------------------------------------------------------------------------------------------------------------------
eq "6. conservacion global: la suma de todas las cuentas y bolsillos no cambio por las transferencias (solo se creo dinero con los ingresos de las altas)" "t" \
   "$(root "SELECT $(SUMA) = $SUMA0 + 503000 FROM (SELECT 1) q" | sed 's/true/t/')"
eq "6. integridad global y defensas en orden" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
eq "6. el reloj termina en modo real" "t" "$(root "SELECT usar_fecha_real FROM public.reloj WHERE id = 1" | sed 's/true/t/')"
fin
