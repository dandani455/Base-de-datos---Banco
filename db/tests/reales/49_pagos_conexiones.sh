#!/bin/sh
# 49_pagos_conexiones.sh - Etapa 9 - pagos, abonos y descuento automatico con conexiones REALES (TCP + contrasena) de banco_app, banco_lector y banco_dev, SIN superusuario.
#   A. La conversacion del backend: solicitar, pagar_cuota (con y sin `numero`), abonar_credito, activar_descuento_automatico y vista_creditos (jsonb, monto como texto, errores
#      P0001 con el mensaje exacto del contrato §6).
#   B. Permisos EFECTIVOS: banco_app ejecuta las 3 publicas nuevas y NINGUNA interna; lector ninguna; ninguna escritura directa de cuota, de cobro_hasta ni de mora_hasta.
#   C. Atomicidad sobre el estado CONFIRMADO: falla inyectada en cada pata y CORTE de la conexion en un pago con mora, un abono con mora e interes y un COBRO AUTOMATICO.
#   D. CARRERAS por borrado: el usuario desaparece mientras pagar_cuota / abonar_credito / activar_descuento_automatico esperan el bloqueo del reloj.
# Termina SIEMPRE sin disparadores de inyeccion, sin productos de prueba, sin tasa de mora y en modo real.
. /work/tests/reales/lib.sh

restaurar() { wait; root "SELECT tests.quitar_fallas()" >/dev/null; root "DELETE FROM public.credito WHERE producto_id IN (SELECT id FROM public.credito_producto WHERE nombre LIKE 'T49 %')" >/dev/null; root "DELETE FROM public.credito_producto WHERE nombre LIKE 'T49 %'" >/dev/null; root "UPDATE public.parametro SET tasa_mora_anual = NULL" >/dev/null; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c49_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
root "UPDATE public.parametro SET tasa_mora_anual = 30" >/dev/null                       # fixture (D7 provisional)
root "SELECT public._reloj_actualizar(false, to_char(public.hoy_banco(), 'YYYY-MM-DD'))" >/dev/null
jump() { root "SELECT public._reloj_actualizar(false, (public.hoy_banco() + $1)::text)" >/dev/null; }
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
newprod() { root "WITH x AS (INSERT INTO public.credito_producto (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES ('$1', '', $2, 1, 1000000000, 1, 360) RETURNING id) SELECT id FROM x"; }
sal() { root "SELECT balance FROM public.cuenta WHERE id = '$1'"; }
# credito del cliente N con vencimientos deterministas (la cuota k vence a los 30*k dias de hoy)
cred() { _k=$(root "SELECT (public.solicitar_credito(tests.u($1), '$2', $3, $4) ->> 'id')"); root "UPDATE public.cuota SET fecha_vencimiento = public.hoy_banco() + 30 * numero WHERE credito_id = '$_k'" >/dev/null; echo "$_k"; }
PL=$(newprod 'T49 Libre' 18); PV=$(newprod 'T49 Vehiculo' 18)
# clientes: 1000 (conversacion A), 1001 (rechazos), 1002 (atomicidad pago), 1003 (atomicidad abono), 1004 (cobro automatico), 1005..1007 (carreras); 1010 admin
alta 1000 5000000; alta 1001 5000000; alta 1002 5000000; alta 1003 5000000; alta 1004 5000000; alta 1005 5000000; alta 1006 5000000; alta 1007 5000000
root "INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol) VALUES ('adm1010', 'h', 'Adm', 'In', '9301010', 'a1010@t.co', '3171010010', DATE '1980-01-01', 'ADMIN')"
UADM=$(root "SELECT id FROM public.usuario WHERE username = 'adm1010'")
UA=$(root "SELECT tests.u(1000)"); A=$(root "SELECT tests.c(1000)")

# ============================================================================
# A. La conversacion del backend
# ============================================================================
as banco_app $APP_PW "SELECT public.solicitar_credito('$UA', '$PL', '10000000', 12)" >/dev/null
K=$(root "SELECT id FROM public.credito WHERE cuenta_id = '$A'"); root "UPDATE public.cuota SET fecha_vencimiento = public.hoy_banco() + 30 * numero WHERE credito_id = '$K'" >/dev/null
o=$(as banco_app $APP_PW "SELECT public.pagar_cuota('$UA', '$K')")
contiene "A1 pagar_cuota por TCP devuelve {numero, pagado, mora, fecha} (la cuota 1, por adelantado, sin mora)" "$o" '"numero": 1'
contiene "A1 ...pagado 910.463,77 y mora 0 como numeros JSON" "$o" '"pagado": 910463.77.*"mora": 0.00|"mora": 0.00.*"pagado": 910463.77'
eq "A1 ...la cuota 1 queda pagada con capital_pagado = capital_programado y el credito con capital_pendiente 9.228.420,53" "t|9228420.53" "$(root "SELECT (SELECT pagada AND capital_pagado = capital_programado FROM public.cuota WHERE credito_id = '$K' AND numero = 1)::text || '|' || capital_pendiente FROM public.credito WHERE id = '$K'" | sed 's/true/t/')"
o=$(as banco_app $APP_PW "SELECT public.pagar_cuota('$UA', '$K', 1)")
contiene "A2 pagar_cuota con numero = 1 (ya pagada): Recurso no encontrado y NO paga otra" "$o" 'ERROR:  Recurso no encontrado'
eq "A2 ...sigue habiendo UNA sola cuota pagada" "1" "$(root "SELECT count(*) FROM public.cuota WHERE credito_id = '$K' AND pagada")"
o=$(as banco_app $APP_PW "SELECT public.abonar_credito('$UA', '$K', '1000000')")
contiene "A3 abonar_credito por TCP (monto como TEXTO): {fecha, mora, interes, capital, saldo, cuota_nueva}" "$o" '"capital": 1000000.00'
contiene "A3 ...saldo 8.228.420,53 (el abono anticipado baja todo a capital)" "$o" '"saldo": 8228420.53'
contiene "A3 ...cuota_nueva (la cuota francesa estandar de K a 11 cuotas, 811.805,09)" "$o" '"cuota_nueva": 811805.09'
eq "A3 ...11 cuotas impagas con los mismos vencimientos, valor_cuota_original intacto y el plan cuadra con la deuda" "11|910463.77|t" "$(root "SELECT (SELECT count(*) FILTER (WHERE NOT pagada) FROM public.cuota WHERE credito_id = '$K') || '|' || (SELECT max(valor_cuota_original) FROM public.cuota WHERE credito_id = '$K') || '|' || (SELECT ok FROM public.v_integridad_creditos WHERE credito_id = '$K')" | sed 's/true/t/')"
o=$(as banco_app $APP_PW "SELECT public.activar_descuento_automatico('$UA', '$K', true)")
contiene "A4 activar_descuento_automatico por TCP: {id, descuento_automatico true}" "$o" '"descuento_automatico": true'
o=$(as banco_app $APP_PW "SELECT public.vista_creditos('$UA')")
contiene "A5 vista_creditos por TCP trae descuento_automatico true y mora_acumulada numerica ademas de los 6 campos" "$o" '"mora_acumulada": 0.00'
contiene "A5 ...descuento_automatico true" "$o" '"descuento_automatico": true'
contiene "A5 ...y los 6 campos de siempre (cuotas_pagadas 1 y cuotas_faltantes 11)" "$o" '"cuotas_pagadas": 1.*"cuotas_faltantes": 11|"cuotas_faltantes": 11.*"cuotas_pagadas": 1'
R() { rechazado "A6 $1" banco_app $APP_PW "$2" "$3"; }
R "abono sobre la liquidacion = Monto fuera de rango" "SELECT public.abonar_credito('$UA', '$K', '99999999999')" "Monto fuera de rango"
R "el artefacto de float 0.30000000000000004 es Monto invalido" "SELECT public.abonar_credito('$UA', '$K', 0.30000000000000004)" "Monto inválido"
R "credito con texto que no es uuid (nunca un 503 del driver)" "SELECT public.pagar_cuota('$UA', 'no-es-uuid')" "Recurso no encontrado"
R "credito ajeno" "SELECT public.pagar_cuota('$(root "SELECT tests.u(1001)")', '$K')" "Recurso no encontrado"
R "activar sobre un credito ajeno" "SELECT public.activar_descuento_automatico('$(root "SELECT tests.u(1001)")', '$K', true)" "Recurso no encontrado"
contiene "A6 el error de negocio llega con SQLSTATE P0001 (el backend lo convierte en 400)" "$(PGPASSWORD=$APP_PW psql -X -h "$HOST" -U banco_app -d "$DB" -v VERBOSITY=verbose -c "SELECT public.pagar_cuota('$UA', 'x')" 2>&1 </dev/null)" 'P0001'
# saldo insuficiente
U1=$(root "SELECT tests.u(1001)"); C1=$(root "SELECT tests.c(1001)")
K1=$(cred 1001 "$PL" 3000000 6)
root "SELECT public.hacer_transferencia('$U1', '$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = '$A'")', $(sal $C1) - 100, 'gasto', NULL)" >/dev/null
rechazado "A7 pagar_cuota sin saldo: Saldo insuficiente y NADA cambia" banco_app $APP_PW "SELECT public.pagar_cuota('$U1', '$K1')" "Saldo insuficiente"
rechazado "A7 abonar_credito sin saldo: Saldo insuficiente y NADA cambia" banco_app $APP_PW "SELECT public.abonar_credito('$U1', '$K1', '500000')" "Saldo insuficiente"
root "UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = '$UA'" >/dev/null
for f in "pagar_cuota('$UA', '$K')" "abonar_credito('$UA', '$K', 1000)" "activar_descuento_automatico('$UA', '$K', true)"; do
  rechazado "A8 BLOQUEADO con sesion abierta: $(echo "$f" | cut -d'(' -f1) recibe el mensaje de bloqueo exacto" banco_app $APP_PW "SELECT public.$f" "Tu cuenta ha sido restringida, contacte con el banco para desbloquearla"
done
root "UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = '$UA'" >/dev/null
rechazado "A8 un ADMIN no usa pagos: Acceso denegado" banco_app $APP_PW "SELECT public.pagar_cuota('$UADM', '$K')" "Acceso denegado"
rechazado "A8 usuario inexistente: Sesion invalida" banco_app $APP_PW "SELECT public.abonar_credito(gen_random_uuid(), '$K', 1000)" "Sesión inválida"

# ============================================================================
# B. Permisos efectivos por conexion real
# ============================================================================
for f in "pagar_cuota('$UA', '$K')" "abonar_credito('$UA', '$K', 1000)" "activar_descuento_automatico('$UA', '$K', true)"; do
  denegado "B1 banco_lector NO ejecuta $(echo "$f" | cut -d'(' -f1)" banco_lector $LECTOR_PW "SELECT public.$f"
done
for f in "_pagar_cuota_interna('$A', '$K', 1, now(), CURRENT_DATE)" "_cobrar_creditos('$A', CURRENT_DATE, now())" "_credito_propio('$A', '$K')" "_mora_cuota(1000, 5)" "_mora_pendiente('$K', CURRENT_DATE)" "_plan_restante(1000000, 18, 5, 0)" "_proxima_cuota('$K')" "_reglas_pago()"; do
  denegado "B2 banco_app NO ejecuta la interna $(echo "$f" | cut -d'(' -f1)" banco_app $APP_PW "SELECT public.$f"
  denegado "B2 banco_lector NO ejecuta la interna $(echo "$f" | cut -d'(' -f1)" banco_lector $LECTOR_PW "SELECT public.$f"
  denegado "B2 banco_dev NO ejecuta la interna $(echo "$f" | cut -d'(' -f1)" banco_dev $DEV_PW "SELECT public.$f"
done
denegado "B3 banco_app NO marca una cuota como pagada a mano" banco_app $APP_PW "UPDATE public.cuota SET pagada = true WHERE credito_id = '$K'"
denegado "B3 banco_app NO toca el cursor cobro_hasta" banco_app $APP_PW "UPDATE public.credito SET cobro_hasta = CURRENT_DATE + 400 WHERE id = '$K'"
denegado "B3 banco_app NO toca mora_hasta" banco_app $APP_PW "UPDATE public.credito SET mora_hasta = CURRENT_DATE WHERE id = '$K'"
denegado "B3 banco_dev tampoco edita el plan ni el cursor" banco_dev $DEV_PW "UPDATE public.credito SET cobro_hasta = NULL, descuento_automatico = false WHERE id = '$K'"
rechazado "B3 banco_lector tampoco (sus sesiones son de solo lectura)" banco_lector $LECTOR_PW "UPDATE public.cuota SET valor_cuota = 1 WHERE credito_id = '$K'" "read-only transaction|permission denied"
contiene "B4 banco_dev hereda de banco_app: puede ver sus creditos con los campos nuevos" "$(as banco_dev $DEV_PW "SELECT public.vista_creditos('$UA')")" '"mora_acumulada"'
eq "B5 la lista blanca de banco_app tiene EXACTAMENTE 40 funciones (E4-E12) y las defensas estan en orden" "t|40" "$(root "SELECT (SELECT bool_and(ok) FROM public.v_integridad_defensas)::text || '|' || (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e') AND has_function_privilege('banco_app', p.oid, 'EXECUTE'))" | sed 's/true/t/')"

# ============================================================================
# C. Atomicidad sobre el estado confirmado: pago con mora, abono con mora e interes y cobro automatico
# ============================================================================
U2=$(root "SELECT tests.u(1002)"); C2=$(root "SELECT tests.c(1002)"); K2=$(cred 1002 "$PL" 10000000 12)
U3=$(root "SELECT tests.u(1003)"); C3=$(root "SELECT tests.c(1003)"); K3=$(cred 1003 "$PL" 10000000 12)
U4=$(root "SELECT tests.u(1004)"); C4=$(root "SELECT tests.c(1004)"); K4=$(cred 1004 "$PL" 10000000 12)
as banco_app $APP_PW "SELECT public.activar_descuento_automatico('$U4', '$K4', true)" >/dev/null
root "SELECT public.hacer_transferencia('$U4', '$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = '$A'")', $(sal $C4) - 100, 'gasto', NULL)" >/dev/null     # el cliente 1004 queda sin saldo con descuento activo
jump 40                                                                                     # las cuotas 1 (dia 30) estan vencidas 10 dias: hay mora
root "SELECT tests.instalar_fallas()" >/dev/null
HUE() { root "SELECT tests.huella_saldos()"; }
for p in tx:1 tx:2 tx:3 tx:4 tx:5 corte:2 corte:4; do
  H0=$(HUE)
  o=$(PGOPTIONS="-c tests.falla=$p" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.pagar_cuota('$U2', '$K2')" 2>&1 </dev/null)
  case $p in corte:*) contiene "C1 corte [$p] a mitad de un pago con mora (3 patas de cuota + 2 de mora): la conexion se cierra" "$o" 'terminating connection|server closed the connection|connection to server';;
             *) contiene "C1 falla inyectada [$p] en la pata $(echo $p | cut -d: -f2) del pago con mora: el error llega" "$o" 'FALLA INYECTADA';; esac
  eq "C1 ...[$p] NADA cambio: ni libro, ni saldos, ni cuotas pagadas" "$H0|0" "$(HUE)|$(root "SELECT count(*) FROM public.cuota WHERE credito_id = '$K2' AND pagada")"
done
for p in tx:1 tx:2 tx:3 tx:4 tx:5 corte:3; do
  H0=$(HUE)
  o=$(PGOPTIONS="-c tests.falla=$p" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.abonar_credito('$U3', '$K3', '2000000')" 2>&1 </dev/null)
  case $p in corte:*) contiene "C2 corte [$p] a mitad de un abono con mora e interes: la conexion se cierra" "$o" 'terminating connection|server closed the connection|connection to server';;
             *) contiene "C2 falla inyectada [$p] en la pata $(echo $p | cut -d: -f2) del abono (2 de mora + 3 de abono): el error llega" "$o" 'FALLA INYECTADA';; esac
  eq "C2 ...[$p] NADA cambio: ni libro, ni saldos, ni plan ni mora_hasta" "$H0|NULL|10000000.00" "$(HUE)|$(root "SELECT coalesce(mora_hasta::text, 'NULL') FROM public.credito WHERE id = '$K3'")|$(root "SELECT capital_pendiente FROM public.credito WHERE id = '$K3'")"
done
# cobro automatico: el cliente 1004 (sin saldo) recibe dinero y la lectura cobra la cuota vencida; una falla o un corte a mitad NO deja nada ni mueve el cursor
root "SELECT public.hacer_transferencia('$U2', '$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = '$C4'")', 3000000, 'llega', NULL)" >/dev/null 2>&1
CUR0=$(root "SELECT cobro_hasta FROM public.credito WHERE id = '$K4'")
for p in tx:1 tx:3 tx:5 corte:2; do
  H0=$(HUE)
  o=$(PGOPTIONS="-c tests.falla=$p" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.vista_creditos('$U4')" 2>&1 </dev/null)
  case $p in corte:*) contiene "C3 corte [$p] a mitad del COBRO AUTOMATICO: la conexion se cierra" "$o" 'terminating connection|server closed the connection|connection to server';;
             *) contiene "C3 falla inyectada [$p] en el cobro automatico (3 patas de cuota + 2 de mora): el error llega" "$o" 'FALLA INYECTADA';; esac
  eq "C3 ...[$p] NADA cambio: ni libro, ni cuotas pagadas, y el cursor cobro_hasta sigue igual" "$H0|0|$CUR0" "$(HUE)|$(root "SELECT count(*) FROM public.cuota WHERE credito_id = '$K4' AND pagada")|$(root "SELECT cobro_hasta FROM public.credito WHERE id = '$K4'")"
done
eq "C ...ninguna sesion de banco_app quedo colgada" "0" "$(root "SELECT count(*) FROM pg_stat_activity WHERE usename = 'banco_app' AND state <> 'idle' AND pid <> pg_backend_pid()")"
root "SELECT tests.quitar_fallas()" >/dev/null
as banco_app $APP_PW "SELECT public.vista_creditos('$U4')" >/dev/null
eq "C4 sin fallos la lectura cobra la cuota vencida UNA vez (con mora): cuota 1 pagada, 1 grupo de cuota, 1 de mora, cursor = hoy" "1|1|1" "$(root "SELECT (SELECT count(*) FROM public.cuota WHERE credito_id = '$K4' AND pagada) || '|' || (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE credito_id = '$K4' AND tipo = 'CREDITO_CUOTA') || '|' || (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE credito_id = '$K4' AND tipo = 'CREDITO_MORA')")"
as banco_app $APP_PW "SELECT public.vista_creditos('$U4')" >/dev/null
eq "C4 ...y una segunda lectura no cobra nada mas" "1" "$(root "SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE credito_id = '$K4' AND tipo = 'CREDITO_CUOTA'")"

# ============================================================================
# D. Carreras por borrado: el usuario desaparece mientras la operacion espera el bloqueo del reloj
# ============================================================================
holder() { ( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT pg_sleep(2.5); $1 COMMIT;" > /tmp/c49_h.out 2>&1 </dev/null ) & sleep 1; }
U5=$(root "SELECT tests.u(1005)"); K5=$(cred 1005 "$PL" 3000000 6)
holder "DELETE FROM public.usuario WHERE id = '$U5';"
o=$(as banco_app $APP_PW "SELECT public.pagar_cuota('$U5', '$K5')")
wait
contiene "D1 el usuario se borra mientras pagar_cuota espera: 'Sesión inválida' (P0001, no un error de FK ni de libro)" "$o" 'ERROR:  Sesión inválida|ERROR:  Recurso no encontrado'
U6=$(root "SELECT tests.u(1006)"); K6=$(cred 1006 "$PL" 3000000 6)
holder "DELETE FROM public.usuario WHERE id = '$U6';"
o=$(as banco_app $APP_PW "SELECT public.abonar_credito('$U6', '$K6', '100000')")
wait
contiene "D2 el usuario se borra mientras abonar_credito espera: 'Sesión inválida' o 'Recurso no encontrado' (nunca un error no-P0001)" "$o" 'ERROR:  Sesión inválida|ERROR:  Recurso no encontrado'
U7=$(root "SELECT tests.u(1007)"); K7=$(cred 1007 "$PL" 3000000 6)
holder "DELETE FROM public.usuario WHERE id = '$U7';"
o=$(as banco_app $APP_PW "SELECT public.activar_descuento_automatico('$U7', '$K7', true)")
wait
contiene "D3 el usuario se borra mientras activar_descuento_automatico espera: 'Sesión inválida' o 'Recurso no encontrado'" "$o" 'ERROR:  Sesión inválida|ERROR:  Recurso no encontrado'
eq "D4 los tres borrados no dejaron ni creditos ni cuotas huerfanos" "0" "$(root "SELECT count(*) FROM public.credito WHERE id IN ('$K5', '$K6', '$K7')")"
eq "D5 integridad global (con planes y cursores) en orden tras todo: fallos, cortes y carreras" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
