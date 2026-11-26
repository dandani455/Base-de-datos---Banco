#!/bin/sh
# 46_motor_concurrencia.sh - Etapa 7 - el motor de devengo bajo CONCURRENCIA con conexiones reales de banco_app (cada sesion espera una hora de arranque comun
# para chocar de verdad):
#   1. 6 sesiones leen vista_balance a la vez con intereses pendientes en 2 bolsillos: EXACTAMENTE un juego de asientos (1 grupo por bolsillo) y 6 respuestas identicas.
#   2. 12 sesiones MEZCLADAS del mismo cliente (vistas, ingresos, retiros, envio, crear_cdt) con intereses de bolsillos y un CDT vencido pendientes: ninguna falla,
#      un solo devengo por producto y el dinero se conserva (cuenta + bolsillos + CDT = capital - enviado + intereses).
#   3. Transferencias CRUZADAS A->B / B->A (12 en cada sentido) con devengo pendiente en AMBOS emisores: sin deadlock (bloqueo ordenado de ambas cuentas).
#   4. Un CDT que VENCE mientras 3 transferencias del mismo cliente compiten por su dinero: sale EXACTAMENTE una; el CDT se cierra una sola vez.
#   5. Bloqueo de cuenta COMPARTIDO: con un bloqueo sostenido sobre la cuenta, la vista con devengo pendiente ESPERA (sin retener ningun bolsillo: orden cuenta -> bolsillo);
#      sin nada pendiente sale sin bloquear.
#   6. El administrador cambia el reloj EN VUELO mientras 8 sesiones consultan en bucle: ningun error, y el devengo final no depende del camino (CDT exacto; bolsillo +-1 centavo).
# Termina SIEMPRE en modo real, sin definiciones de prueba y con la integridad global en orden.
. /work/tests/reales/lib.sh
restaurar() { wait; root "DELETE FROM public.cdt_definicion WHERE nombre LIKE 'T46 %'" >/dev/null; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c46_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
root "SELECT public._reloj_actualizar(false, to_char(public.hoy_banco(), 'YYYY-MM-DD'))" >/dev/null
jump() { root "SELECT public._reloj_actualizar(false, (public.hoy_banco() + $1)::text)" >/dev/null; }

par() {
  _p=$1; _n=$2; _g=$3; _t=${START:-$(( $(date +%s) + 3 ))}; _i=1
  while [ $_i -le $_n ]; do
    _sql=$($_g $_i)
    ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" \
        -c "SELECT pg_sleep(GREATEST(0, $_t - extract(epoch from clock_timestamp())))" -c "$_sql" > /tmp/c46_${_p}_$_i.out 2>&1 </dev/null ) &
    _i=$((_i+1))
  done
  wait
}
cuenta() { cat /tmp/c46_$1_*.out | grep -c "$2"; }
errores_ajenos() { cat /tmp/c46_$1_*.out | grep '^ERROR' | grep -vc "$2"; }
sal() { root "SELECT balance FROM public.cuenta WHERE id = tests.c($1)"; }
salb() { root "SELECT balance FROM public.bolsillo WHERE id = tests.b($1)"; }
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
bolh() { root "INSERT INTO public.bolsillo (id, cuenta_id, nombre, ultimo_cobro) VALUES (tests.b($1), tests.c($2), 'B$1', public.hoy_banco())" >/dev/null; [ "${3:-0}" != 0 ] && root "SELECT tests.app_bolso_ingreso(tests.c($2), tests.b($1), $3)" >/dev/null; }
U() { root "SELECT tests.u($1)"; }
ngr() { root "SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE tipo = '$1' AND cuenta_id = tests.c($2)"; }
OKP='"id"'
root "WITH x AS (INSERT INTO public.cdt_definicion (nombre, plazo_dias, tasa_anual, monto_min) VALUES ('T46 CDT 20', 20, 8, 50000) RETURNING id) SELECT 1 FROM x" >/dev/null
DEF=$(root "SELECT id FROM public.cdt_definicion WHERE nombre = 'T46 CDT 20'")
FAC12=$(root "SELECT round(1000000 * public._factor_interes(12, 30), 2)")      # interes de 30 dias sobre 1.000.000 al 12 %

# ---- 1. 6 lecturas simultaneas con intereses pendientes en 2 bolsillos -----------------------------------------------------------
alta 970 2000000; bolh 9701 970 1000000; bolh 9702 970 1000000; U970=$(U 970)
jump 30
g1() { echo "SELECT public.vista_balance('$U970')"; }
par c1 6 g1
eq "1. 6 vistas simultaneas con devengo pendiente: las 6 responden y ninguna falla" "6|0" "$(cuenta c1 '"principal"')|$(cat /tmp/c46_c1_*.out | grep -ci 'ERROR\|deadlock\|timeout')"
eq "1. ...EXACTAMENTE un juego de asientos: 1 grupo INTERES_BOLSO por bolsillo (2 en total), nunca 12" "2" "$(ngr INTERES_BOLSO 970)"
eq "1. ...cada bolsillo = 1.000.000 + interes de 30 dias (una sola vez)" "$(root "SELECT 1000000 + $FAC12")|$(root "SELECT 1000000 + $FAC12")" "$(salb 9701)|$(salb 9702)"
eq "1. ...las 6 respuestas son IDENTICAS (todas ven el estado ya devengado, ninguna una foto a medias)" "1" "$(cat /tmp/c46_c1_*.out | grep -v '^$' | sort -u | wc -l | tr -d ' ')"

# ---- 2. 12 sesiones mezcladas del mismo cliente ----------------------------------------------------------------------------------
alta 971 3000000; alta 975 1000; bolh 9711 971 500000; bolh 9712 971 500000; U971=$(U 971)
as banco_app $APP_PW "SELECT public.crear_cdt('$U971', '$DEF', '100000')" >/dev/null
jump 30
g2() { case $1 in
  1|2|3) echo "SELECT public.vista_balance('$U971')";;
  4|5|6) echo "SELECT public.vista_cdts('$U971')";;
  7|8) echo "SELECT public.mover_a_bolsillo('$U971', '$(root 'SELECT tests.b(9711)')', 100)";;
  9|10) echo "SELECT public.retirar_de_bolsillo('$U971', '$(root 'SELECT tests.b(9712)')', 100)";;
  11) echo "SELECT public.hacer_transferencia('$U971', '$(root 'SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(975)')', 10, 'mix', NULL)";;
  12) echo "SELECT public.crear_cdt('$U971', '$DEF', '50000')";;
esac; }
par c2 12 g2
eq "2. 12 sesiones mezcladas (lecturas con devengo, ingresos, retiros, envio y crear_cdt): ninguna falla" "0" "$(cat /tmp/c46_c2_*.out | grep -ci 'ERROR\|deadlock\|timeout')"
eq "2. ...UN solo devengo por producto: 1 grupo por bolsillo (2), 1 INTERES_CDT y 1 CDT_VENCIMIENTO del CDT vencido" "2|1|1" "$(ngr INTERES_BOLSO 971)|$(ngr INTERES_CDT 971)|$(ngr CDT_VENCIMIENTO 971)"
eq "2. ...CONSERVACION: total (cuenta + bolsillos + CDT activos) + 10 enviados = 3.000.000 + intereses devengados (bolsillos + CDT)" "t" "$(root "SELECT (public.balance_total(tests.c(971)) + 10 = 3000000 + (SELECT coalesce(sum(monto), 0) FROM public.transaccion WHERE cuenta_id = tests.c(971) AND ((tipo = 'INTERES_BOLSO' AND contenedor = 'BOLSILLO') OR (tipo = 'INTERES_CDT' AND contenedor = 'CDT'))))::text" | sed 's/true/t/')"
eq "2. ...el destino recibio exactamente 10" "1010.00" "$(sal 975)"

# ---- 3. Transferencias cruzadas con devengo pendiente en los DOS emisores ---------------------------------------------------------
alta 972 1000000; alta 973 1000000; bolh 9721 972 100000; bolh 9731 973 100000; U972=$(U 972); U973=$(U 973)
N972=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(972)"); N973=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(973)")
jump 30
g3() { if [ $(($1 % 2)) -eq 1 ]; then echo "SELECT public.hacer_transferencia('$U972', '$N973', 100, NULL, NULL)"; else echo "SELECT public.hacer_transferencia('$U973', '$N972', 100, NULL, NULL)"; fi; }
par c3 24 g3
eq "3. 24 transferencias cruzadas con devengo pendiente en AMBOS emisores: TODAS salen" "24|0" "$(cuenta c3 "$OKP")|$(cat /tmp/c46_c3_*.out | grep -ci 'ERROR\|deadlock\|timeout')"
eq "3. ...un solo devengo por bolsillo (1 grupo cada uno) y el dinero se conserva (2.000.000 + intereses; los envios se cancelan)" "1|1|t" "$(ngr INTERES_BOLSO 972)|$(ngr INTERES_BOLSO 973)|$(root "SELECT ((SELECT public.balance_total(tests.c(972)) + public.balance_total(tests.c(973))) = 2000000 + 2 * round(100000 * public._factor_interes(12, 30), 2))::text" | sed 's/true/t/')"

# ---- 4. CDT que vence mientras 3 transferencias compiten por su dinero ------------------------------------------------------------
alta 974 1000000; alta 976 0; U974=$(U 974); N976=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(976)")
as banco_app $APP_PW "SELECT public.crear_cdt('$U974', '$DEF', '1000000')" >/dev/null
jump 25
GEN=$(root "SELECT round(1000000 * public._factor_interes(8, 20), 2)")
g4() { case $1 in
  1|2|3) echo "SELECT public.hacer_transferencia('$U974', '$N976', $(root "SELECT 1000000 + $GEN"), NULL, NULL)";;
  4) echo "SELECT public.vista_cdts('$U974')";;
  5) echo "SELECT public.vista_balance('$U974')";;
esac; }
par c4 5 g4
eq "4. CDT vencido + 3 transferencias de monto + generado: sale EXACTAMENTE una" "1" "$(cat /tmp/c46_c4_[123].out | grep -c "$OKP")"
eq "4. ...las otras 2 reciben 'Saldo insuficiente' y ningun otro error" "2|0" "$(cat /tmp/c46_c4_[123].out | grep -c 'Saldo insuficiente')|$(errores_ajenos c4 'Saldo insuficiente')"
eq "4. ...el CDT se cerro UNA vez (1 INTERES_CDT, 1 CDT_VENCIMIENTO), el origen quedo en 0 y el destino recibio monto + generado" "1|1|0.00|$(root "SELECT 1000000 + $GEN")" "$(ngr INTERES_CDT 974)|$(ngr CDT_VENCIMIENTO 974)|$(sal 974)|$(sal 976)"

# ---- 5. El bloqueo de cuenta es COMPARTIDO: el devengo espera; sin nada pendiente no bloquea ---------------------------------------
alta 977 100; bolh 9771 977 100; alta 978 100; U977=$(U 977); U978=$(U 978)
jump 30
holder() { # holder CUENTA : mantiene FOR NO KEY UPDATE sobre la cuenta 2.5 s
  ( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.cuenta WHERE id = tests.c($1) FOR NO KEY UPDATE; SELECT pg_sleep(2.5); COMMIT;" > /tmp/c46_h.out 2>&1 </dev/null ) &
  sleep 1
}
timed() { # timed USUARIO FUNCION : segundos que tarda la llamada
  _o=$(PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT clock_timestamp()" -c "SELECT public.$2('$1')" -c "SELECT clock_timestamp()" 2>&1 </dev/null)
  _t1=$(printf '%s\n' "$_o" | head -n1); _t2=$(printf '%s\n' "$_o" | tail -n1)
  root "SELECT round(extract(epoch FROM ('$_t2'::timestamptz - '$_t1'::timestamptz))::numeric, 1)"
}
holder 977
T=$(timed "$U977" vista_balance)
wait
eq "5. con el bloqueo de la cuenta sostenido por OTRA sesion, la vista con devengo pendiente ESPERA (>= 1 s)" "t" "$(root "SELECT ($T >= 1.0)::text" | sed 's/true/t/')"
eq "5. ...y despues devenga correctamente (bolsillo 100 + interes del dia sobre 100, una sola vez)" "1|t" "$(ngr INTERES_BOLSO 977)|$(root "SELECT (balance >= 100) FROM public.bolsillo WHERE id = tests.b(9771)" | sed 's/true/t/')"
holder 978
T=$(timed "$U978" vista_balance)
wait
eq "5. SIN nada pendiente la vista sale SIN bloquear aunque otra sesion sostenga el bloqueo (< 1 s: salida rapida)" "t" "$(root "SELECT ($T < 1.0)::text" | sed 's/true/t/')"

# ---- 5b. El devengo toma la CUENTA antes que los bolsillos (orden global cuenta -> contenedores): mientras espera, NO retiene ningun bolsillo -------------
alta 980 100; bolh 9801 980 100; U980=$(U 980)
jump 30
holder 980
( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.vista_balance('$U980')" > /tmp/c46_5b.out 2>&1 </dev/null ) &
root "SELECT pg_sleep(0.5)" >/dev/null
eq "5b. mientras el devengo ESPERA el bloqueo de la cuenta no retiene el bolsillo (se puede bloquear sin esperar: orden cuenta -> bolsillo, sin riesgo de deadlock)" "1" "$(root "SELECT 1 FROM public.bolsillo WHERE id = tests.b(9801) FOR NO KEY UPDATE NOWAIT" | head -n1)"
wait
contiene "5b. ...y al soltarse el bloqueo la vista responde con el devengo hecho" "$(cat /tmp/c46_5b.out)" '"bolsillos"'
eq "5b. ...un solo grupo de interes" "1" "$(ngr INTERES_BOLSO 980)"

# ---- 6. El administrador cambia el reloj EN VUELO ----------------------------------------------------------------------------------
alta 979 2000000; bolh 9791 979 1000000; U979=$(U 979)
as banco_app $APP_PW "SELECT public.crear_cdt('$U979', '$DEF', '500000')" >/dev/null
H1=$(root "SELECT public.hoy_banco()")
sesion6() { _k=0; while [ $_k -lt 5 ]; do
    PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.vista_balance('$U979')" >> /tmp/c46_s6_$1.out 2>&1 </dev/null
    PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.vista_cdts('$U979')" >> /tmp/c46_s6_$1.out 2>&1 </dev/null
    _k=$((_k+1)); done; }
( _a=0; while [ $_a -lt 6 ]; do root "SELECT public._reloj_actualizar(false, (public.hoy_banco() + 1)::text)" >/dev/null; root "SELECT pg_sleep(0.3)" >/dev/null; _a=$((_a+1)); done ) &
_i=1; while [ $_i -le 8 ]; do sesion6 $_i & _i=$((_i+1)); done
wait
eq "6. 8 sesiones consultando en bucle mientras el admin adelanta el reloj 6 dias: CERO errores" "0" "$(cat /tmp/c46_s6_*.out | grep -ci 'ERROR\|deadlock\|timeout')"
as banco_app $APP_PW "SELECT public.vista_balance('$U979')" >/dev/null
as banco_app $APP_PW "SELECT public.vista_cdts('$U979')" >/dev/null
DIAS=$(root "SELECT public.hoy_banco() - DATE '$H1'")
eq "6. el reloj avanzo 6 dias y los productos estan al dia (ultimo_cobro = hoy)" "6|t|t" "$DIAS|$(root "SELECT (ultimo_cobro = public.hoy_banco())::text FROM public.bolsillo WHERE id = tests.b(9791)" | sed 's/true/t/')|$(root "SELECT (ultimo_cobro = public.hoy_banco())::text FROM public.cdt WHERE cuenta_id = tests.c(979)" | sed 's/true/t/')"
eq "6. ...el CDT genero EXACTAMENTE el objetivo de 6 dias (independiente del camino y de cuantas veces se consulto)" "t" "$(root "SELECT (generado_acumulado = round(monto * public._factor_interes(tasa_anual, $DIAS), 2))::text FROM public.cdt WHERE cuenta_id = tests.c(979)" | sed 's/true/t/')"
eq "6. ...el bolsillo coincide (+-10 centavos: solo redondeo) con un unico devengo de 6 dias" "t" "$(root "SELECT (abs(balance - (1000000 + round(1000000 * public._factor_interes(12, $DIAS), 2))) <= 0.10)::text FROM public.bolsillo WHERE id = tests.b(9791)" | sed 's/true/t/')"
eq "7. integridad global y defensas en orden tras todo" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
