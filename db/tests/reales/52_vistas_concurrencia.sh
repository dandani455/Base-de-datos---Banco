#!/bin/sh
# 52_vistas_concurrencia.sh - Etapa 10 - vista_dashboard y vista_historial bajo CONCURRENCIA con conexiones reales de banco_app (cada sesion espera una hora de arranque comun para chocar de verdad):
#   1. 6 lectores del dashboard mientras 4 sesiones mueven dinero entre la principal y los bolsillos (suma cero): TODAS las lecturas ven el mismo balance_total (nunca un movimiento a medias).
#   2. 12 dashboards simultaneos sobre un cliente con una cuota vencida, descuento activo y dinero recien llegado: la cuota se cobra UNA sola vez (con su mora) y ninguna lectura falla.
#   3. 24 transferencias cruzadas entre dos clientes con cobros automaticos pendientes en AMBOS, mas dashboards e historiales de los dos: sin deadlock ni timeout, y cada cobro UNA vez.
# Termina SIEMPRE en modo real, sin productos de prueba, sin tasa de mora y con la integridad global en orden.
. /work/tests/reales/lib.sh
restaurar() { wait; root "DELETE FROM public.credito WHERE producto_id IN (SELECT id FROM public.credito_producto WHERE nombre LIKE 'T52 %')" >/dev/null; root "DELETE FROM public.credito_producto WHERE nombre LIKE 'T52 %'" >/dev/null; root "UPDATE public.parametro SET tasa_mora_anual = NULL" >/dev/null; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c52_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
root "UPDATE public.parametro SET tasa_mora_anual = 30" >/dev/null
root "SELECT public._reloj_actualizar(false, to_char(public.hoy_banco(), 'YYYY-MM-DD'))" >/dev/null
jump() { root "SELECT public._reloj_actualizar(false, (public.hoy_banco() + $1)::text)" >/dev/null; }

# par PREFIJO N GENERADOR REPETICIONES : N sesiones simultaneas; cada una ejecuta GENERADOR(i) REPETICIONES veces (una sentencia por -c: ninguna roza el statement_timeout de 5 s de banco_app)
par() {
  _p=$1; _n=$2; _g=$3; _r=${4:-1}; _t=${START:-$(( $(date +%s) + 3 ))}; _i=1
  while [ $_i -le $_n ]; do
    ( set -- -c "SELECT pg_sleep(GREATEST(0, $_t - extract(epoch from clock_timestamp())))"
      _k=1; while [ $_k -le $_r ]; do set -- "$@" -c "$($_g $_i)"; _k=$((_k+1)); done
      PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" "$@" > /tmp/c52_${_p}_$_i.out 2>&1 </dev/null ) &
    _i=$((_i+1))
  done
  wait
}
cuenta() { cat /tmp/c52_$1_*.out | grep -c "$2"; }
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
U() { root "SELECT tests.u($1)"; }
NUM() { root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c($1)"; }
ngr() { root "SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE credito_id = '$1' AND tipo = '$2'"; }
PL=$(root "WITH x AS (INSERT INTO public.credito_producto (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES ('T52 Libre', '', 18, 1, 1000000000, 1, 360) RETURNING id) SELECT id FROM x")
cred() { _k=$(root "SELECT (public.solicitar_credito(tests.u($1), '$PL', 3000000, 12) ->> 'id')"); root "UPDATE public.cuota SET fecha_vencimiento = public.hoy_banco() + 30 * numero WHERE credito_id = '$_k'" >/dev/null; echo "$_k"; }

# clientes: 1300 (movimientos y lectores), 1301..1303 (cobros pendientes), 1306 (sumidero)
alta 1300 1000000; alta 1306 20000000
U0=$(U 1300); B1=$(root "SELECT public.crear_bolsillo('$U0', 'B1') ->> 'id'"); B2=$(root "SELECT public.crear_bolsillo('$U0', 'B2') ->> 'id'")
root "SELECT public.mover_a_bolsillo('$U0', '$B1', 250000)" >/dev/null; root "SELECT public.mover_a_bolsillo('$U0', '$B2', 250000)" >/dev/null
for n in 1301 1302 1303; do
  alta $n 3000000; K=$(cred $n)
  root "SELECT public.activar_descuento_automatico(tests.u($n), '$K', true)" >/dev/null
  root "SELECT public.hacer_transferencia(tests.u($n), '$(NUM 1306)', (SELECT balance FROM public.cuenta WHERE id = tests.c($n)) - 100, 'gasto', NULL)" >/dev/null     # sin saldo, con descuento activo
done
K1=$(root "SELECT id FROM public.credito WHERE cuenta_id = tests.c(1301)"); K2=$(root "SELECT id FROM public.credito WHERE cuenta_id = tests.c(1302)"); K3=$(root "SELECT id FROM public.credito WHERE cuenta_id = tests.c(1303)")

# ---- 1. lectores del dashboard contra movimientos de suma cero ------------------------------------------------------------------------
g1() { if [ $1 -le 4 ]; then echo "SELECT count(public.mover_a_bolsillo('$U0', '$B1', 1000)) + count(public.retirar_de_bolsillo('$U0', '$B1', 1000)) + count(public.mover_entre_bolsillos('$U0', '$B2', '$B1', 500)) + count(public.mover_entre_bolsillos('$U0', '$B1', '$B2', 500)) FROM generate_series(1, 10) g"
       else echo "SELECT count(*) || '|' || count(*) FILTER (WHERE (v ->> 'balance_total')::numeric <> 1000000) || '|' || count(*) FILTER (WHERE jsonb_array_length(v -> 'transacciones') > 8) FROM (SELECT public.vista_dashboard('$U0') AS v FROM generate_series(1, 15) g) x"; fi; }
par c1 10 g1 6
eq "1. los 4 movedores terminaron sus 240 movimientos (4 sesiones x 6 sentencias x 40 operaciones), sin un solo error" "960|0" "$(cat /tmp/c52_c1_[1-4].out | awk '{n+=$1} END {print n}')|$(cat /tmp/c52_c1_*.out | grep -c ERROR)"
eq "1. los 6 lectores hicieron 540 dashboards (6 x 6 x 15): NINGUNO vio un balance_total distinto de 1.000.000 y ninguno trajo mas de 8 transacciones" "540|0|0" "$(cat /tmp/c52_c1_[5-9].out /tmp/c52_c1_10.out | awk -F'|' '{n+=$1; a+=$2; b+=$3} END {print n"|"a"|"b}')"
eq "1. ...el cliente conserva su millon entre cuenta y bolsillos y la integridad global esta en orden" "1000000.00|t" "$(root "SELECT public.balance_total(tests.c(1300))")|$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"

# ---- 2. 12 dashboards simultaneos con un cobro automatico pendiente -------------------------------------------------------------------
jump 40                                                                                    # la cuota 1 (dia 30) lleva 10 dias vencida: hay mora
for n in 1301 1302 1303; do root "SELECT public.hacer_transferencia(tests.u(1306), '$(NUM $n)', 3000000, 'llega', NULL)" >/dev/null; done      # dinero por una operacion ajena
g2() { echo "SELECT public.vista_dashboard('$(U 1301)') -> 'creditos' ->> 'cuota_por_pagar'"; }
par c2 12 g2
eq "2. 12 dashboards simultaneos: todos responden y ninguno falla (ni deadlock, ni timeout, ni llave duplicada)" "12|0" "$(cat /tmp/c52_c2_*.out | grep -c '^[0-9]')|$(cat /tmp/c52_c2_*.out | grep -ci 'ERROR\|deadlock\|timeout\|duplicate\|violates')"
eq "2. ...la cuota vencida se cobra UNA sola vez: 1 grupo de cuota, 1 de mora, la cuota 1 pagada y el cursor en hoy" "1|1|1" "$(ngr $K1 CREDITO_CUOTA)|$(ngr $K1 CREDITO_MORA)|$(root "SELECT count(*) FROM public.cuota WHERE credito_id = '$K1' AND pagada")"
eq "2. ...todas las lecturas vieron la MISMA cuota por pagar (la 2: nunca la 1 ya pagada a medias con la mora sin cobrar)" "1" "$(cat /tmp/c52_c2_*.out | grep '^[0-9]' | sort -u | wc -l | tr -d ' ')"

# ---- 3. transferencias cruzadas con cobros pendientes en ambos emisores y lectores en paralelo ------------------------------------------
g3() { if [ $1 -le 12 ]; then echo "SELECT public.hacer_transferencia('$(U 1302)', '$(NUM 1303)', 1000, 'c', NULL)"
       elif [ $1 -le 24 ]; then echo "SELECT public.hacer_transferencia('$(U 1303)', '$(NUM 1302)', 1000, 'c', NULL)"
       elif [ $1 -le 28 ]; then echo "SELECT public.vista_dashboard('$(U 1302)') ->> 'nombre'"
       else echo "SELECT jsonb_array_length(public.vista_historial('$(U 1303)', 50))"; fi; }
par c3 32 g3
eq "3. 24 transferencias cruzadas + 8 lecturas con cobros automaticos pendientes en ambos emisores: sin deadlock ni timeout" "0" "$(cat /tmp/c52_c3_*.out | grep -ci 'deadlock\|timeout\|duplicate\|violates')"
eq "3. ...las 24 transferencias salen (24 ids) y las 8 lecturas responden" "24|8" "$(cat /tmp/c52_c3_[1-9].out /tmp/c52_c3_1[0-9].out /tmp/c52_c3_2[0-4].out | grep -c '"id"')|$(cat /tmp/c52_c3_2[5-9].out /tmp/c52_c3_3[0-2].out | grep -c '[A-Za-z0-9]')"
as banco_app $APP_PW "SELECT public.vista_dashboard('$(U 1302)')" >/dev/null; as banco_app $APP_PW "SELECT public.vista_dashboard('$(U 1303)')" >/dev/null
eq "3. ...cada credito cobro su cuota vencida UNA vez (2 grupos por cliente: cuota y mora) y el historial de cada uno trae ese cobro" "1|1|1|1" "$(ngr $K2 CREDITO_CUOTA)|$(ngr $K3 CREDITO_CUOTA)|$(root "SELECT count(*) FROM jsonb_array_elements(public.vista_historial(tests.u(1302), 50)) e WHERE e ->> 'tipo_detalle' = 'CREDITO_CUOTA'")|$(root "SELECT count(*) FROM jsonb_array_elements(public.vista_historial(tests.u(1303), 50)) e WHERE e ->> 'tipo_detalle' = 'CREDITO_CUOTA'")"
eq "3. ...integridad global (partida doble, I5u, planes y defensas) en orden" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
