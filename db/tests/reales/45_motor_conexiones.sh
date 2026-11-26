#!/bin/sh
# 45_motor_conexiones.sh - Etapa 7 - motor de devengo y CDT con conexiones REALES (TCP + contrasena) de banco_app, banco_lector y banco_dev.
#   A. La conversacion del backend: vista_balance / retirar_de_bolsillo con intereses devengados, listar_cdt_definiciones, simular_cdt, crear_cdt y vista_cdts
#      (salida jsonb, monto como texto, errores P0001 exactos, cierre del CDT que acredita monto + generado).
#   B. Permisos EFECTIVOS: banco_app ejecuta las 4 publicas de CDT y NINGUNA interna del motor; lector ninguna; dev hereda de app; ninguna escritura directa de ultimo_cobro.
#   C. Atomicidad sobre el estado CONFIRMADO: fallos inyectados en CADA pata del devengo + la operacion posterior, y CORTE de la conexion a mitad del devengo.
#   D. CARRERAS por borrado: el usuario o el destino desaparecen mientras la operacion (con devengo pendiente) espera el bloqueo del reloj: mensaje de negocio, nunca
#      un error no-P0001 (el backend lo convertiria en 503) y sin rastro.
# Termina SIEMPRE sin disparadores de inyeccion, sin definiciones de prueba y en modo real.
. /work/tests/reales/lib.sh

restaurar() { wait; root "SELECT tests.quitar_fallas()" >/dev/null; root "DELETE FROM public.cdt_definicion WHERE nombre LIKE 'T45 %'" >/dev/null; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c45_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
# reloj MANUAL desde hoy: los saltos son deterministas (la fecha real no cambia a mitad de la prueba)
root "SELECT public._reloj_actualizar(false, to_char(public.hoy_banco(), 'YYYY-MM-DD'))" >/dev/null
jump() { root "SELECT public._reloj_actualizar(false, (public.hoy_banco() + $1)::text)" >/dev/null; }

sal() { root "SELECT balance FROM public.cuenta WHERE id = '$1'"; }
salb() { root "SELECT balance FROM public.bolsillo WHERE id = '$1'"; }
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
newdef() { root "WITH x AS (INSERT INTO public.cdt_definicion (nombre, plazo_dias, tasa_anual, monto_min) VALUES ('$1', $2, $3, $4) RETURNING id) SELECT id FROM x"; }

# clientes: 950 (conversacion A), 951 (atomicidad C bolsillo), 952 (atomicidad C CDT); 953 admin
alta 950 5000000; alta 951 1000000; alta 952 1000000
UA=$(root "SELECT tests.u(950)"); A=$(root "SELECT tests.c(950)")
root "INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol) VALUES ('adm953', 'h', 'Adm', 'In', '9300953', 'a953@t.co', '3170000953', DATE '1980-01-01', 'ADMIN')" >/dev/null
UADM=$(root "SELECT id FROM public.usuario WHERE username = 'adm953'")
D90=$(newdef 'T45 CDT 90' 90 10 100000); D20=$(newdef 'T45 CDT 20' 20 8 50000)
V() { as banco_app $APP_PW "SELECT public.vista_balance('$UA')"; }
VC() { as banco_app $APP_PW "SELECT public.vista_cdts('$UA')"; }

# ============================================================================
# A. La conversacion del backend, con devengo real
# ============================================================================
o=$(as banco_app $APP_PW "SELECT public.crear_bolsillo('$UA', 'Ahorro')")
contiene "A1 crear_bolsillo por TCP (reloj manual)" "$o" '"nombre": "Ahorro"'
B1=$(root "SELECT id FROM public.bolsillo WHERE cuenta_id = '$A'")
as banco_app $APP_PW "SELECT public.mover_a_bolsillo('$UA', '$B1', '1000000')" >/dev/null
eq "A1 1.000.000 en el bolsillo y 4.000.000 en la cuenta (sin intereses: acaba de crearse)" "1000000.00|4000000.00" "$(salb $B1)|$(sal $A)"
jump 30
o=$(V)
contiene "A2 vista_balance por TCP 30 dias despues: el bolsillo ya trae su interes (1.009.358,20 al 12 % E.A.) y el total lo incluye" "$o" '"saldo": 1009358.20'
contiene "A2 ...total 5.009.358,20 = principal 4.000.000 + bolsillo 1.009.358,20" "$o" '"total": 5009358.20'
eq "A2 ...UN grupo INTERES_BOLSO: 2 patas, 9358.20, nota '30 días', contraparte Banco Digital" "2|1|9358.20|30 días|Banco Digital" "$(root "SELECT count(*) || '|' || count(DISTINCT grupo_id) || '|' || min(monto) || '|' || min(nota) || '|' || min(contraparte_nombre) FROM public.transaccion WHERE tipo = 'INTERES_BOLSO' AND cuenta_id = '$A'")"
H0=$(root "SELECT tests.huella_saldos()")
V >/dev/null; V >/dev/null
eq "A2 ...consultar de nuevo (idempotente): no se escribe NADA mas" "$H0" "$(root "SELECT tests.huella_saldos()")"
o=$(as banco_app $APP_PW "SELECT public.retirar_de_bolsillo('$UA', '$B1', '1009358.20')")
contiene "A3 retirar el saldo CON intereses por TCP funciona (devengo antes del libro)" "$o" '"id".*"fecha"'
eq "A3 ...bolsillo 0 y cuenta 5.009.358,20" "0.00|5009358.20" "$(salb $B1)|$(sal $A)"

o=$(as banco_app $APP_PW "SELECT public.listar_cdt_definiciones('$UA')")
contiene "A4 listar_cdt_definiciones por TCP: [{id, nombre, tasa, plazo_dias, monto_min}] con numeros JSON" "$o" '"tasa": 10.000.*"plazo_dias": 90|"plazo_dias": 90.*"tasa": 10.000'
o=$(as banco_app $APP_PW "SELECT public.simular_cdt('$UA', '$D90', '1000000')")
contiene "A5 simular_cdt por TCP (monto como TEXTO): el JSON trae las 3 claves" "$o" '"generado_mes".*"generado_dia".*"generado_vencimiento"|"generado_dia".*"generado_mes".*"generado_vencimiento"'
eq "A5 ...generado_vencimiento coincide con la formula del motor" "t" "$(root "SELECT (public.simular_cdt('$UA', '$D90', 1000000) ->> 'generado_vencimiento')::numeric = round(1000000 * public._factor_interes(10, 90), 2)" | sed 's/true/t/')"
o=$(as banco_app $APP_PW "SELECT public.crear_cdt('$UA', '$D90', '1000000')")
contiene "A6 crear_cdt por TCP devuelve {id, fecha}" "$o" '^\{"id": "[0-9a-f-]{36}", "fecha": "[0-9-]{10}T[0-9:.]+[-+][0-9:]+"\}$'
CID=$(root "SELECT id FROM public.cdt WHERE cuenta_id = '$A'")
eq "A6 ...la cuenta baja a 4.009.358,20 y el CDT (copia 10 %, 90 dias) esta ACTIVO" "4009358.20|ACTIVO|10.000|90" "$(sal $A)|$(root "SELECT estado || '|' || tasa_anual || '|' || plazo_dias FROM public.cdt WHERE id = '$CID'")"
o=$(VC)
contiene "A7 vista_cdts por TCP: [{id, monto, generado_hasta_hoy 0, tiempo_restante '90 días', fecha_cierre}]" "$o" '"tiempo_restante": "90 días"'
contiene "A7 ...monto y generado son numeros JSON" "$o" '"monto": 1000000.00'
contiene "A7 ...generado_hasta_hoy 0 (numero) y fecha_cierre una fecha ISO" "$o" '"generado_hasta_hoy": 0.00'
contiene "A7 ...fecha_cierre = instante ISO con zona (D-E10-5, contrato §3.4)" "$o" '"fecha_cierre": "[0-9]{4}-[0-9]{2}-[0-9]{2}T00:00:00-05:00"'
jump 45
o=$(VC)
contiene "A8 45 dias despues el CDT devenga: tiempo_restante '45 días' y generado > 0" "$o" '"tiempo_restante": "45 días"'
eq "A8 ...generado = round(monto * factor(45 dias))" "t" "$(root "SELECT generado_acumulado = round(1000000 * public._factor_interes(10, 45), 2) FROM public.cdt WHERE id = '$CID'" | sed 's/true/t/')"
SC0=$(sal $A)
jump 50
o=$(VC)
contiene "A9 5 dias despues del vencimiento: 'Cerrado'" "$o" '"tiempo_restante": "Cerrado"'
eq "A9 ...CERRADO y la cuenta recibio monto + generado final (round(monto * factor(90 dias)))" "CERRADO|t" "$(root "SELECT estado || '|' || (($SC0 + 1000000 + (SELECT generado_acumulado FROM public.cdt WHERE id = '$CID')) = (SELECT balance FROM public.cuenta WHERE id = '$A') AND generado_acumulado = round(1000000 * public._factor_interes(10, 90), 2))::text FROM public.cdt WHERE id = '$CID'" | sed 's/true/t/')"
eq "A9 ...CDT_VENCIMIENTO fechado en fecha_fin 00:00 de Bogota" "t" "$(root "SELECT bool_and(t.fecha = (c.fecha_fin::timestamp AT TIME ZONE 'America/Bogota')) FROM public.transaccion t JOIN public.cdt c ON c.id = t.cdt_id WHERE t.tipo = 'CDT_VENCIMIENTO' AND c.id = '$CID'" | sed 's/true/t/')"
R5() { rechazado "A10 $1" banco_app $APP_PW "$2" "$3"; }
R5 "monto por debajo del minimo del CDT (mensaje exacto del contrato)" "SELECT public.crear_cdt('$UA', '$D90', '99999.99')" "Monto por debajo del mínimo del CDT"
R5 "simular con monto por debajo del minimo" "SELECT public.simular_cdt('$UA', '$D90', '1000')" "Monto por debajo del mínimo del CDT"
R5 "monto invalido (0) gana a la definicion" "SELECT public.crear_cdt('$UA', 'no-es-uuid', 0)" "Monto inválido"
R5 "el artefacto de float 0.30000000000000004 es Monto invalido (el backend debe pasar texto)" "SELECT public.crear_cdt('$UA', '$D90', 0.30000000000000004)" "Monto inválido"
R5 "definicion con texto que no es uuid (nunca un 503 del driver)" "SELECT public.crear_cdt('$UA', 'no-es-uuid', 100000)" "Recurso no encontrado"
R5 "definicion inexistente" "SELECT public.simular_cdt('$UA', gen_random_uuid()::text, 100000)" "Recurso no encontrado"
R5 "saldo insuficiente (el CDT supera la cuenta)" "SELECT public.crear_cdt('$UA', '$D90', 999999999)" "Saldo insuficiente"
contiene "A10 el error de negocio llega con SQLSTATE P0001 (el backend lo convierte en 400)" "$(PGPASSWORD=$APP_PW psql -X -h "$HOST" -U banco_app -d "$DB" -v VERBOSITY=verbose -c "SELECT public.crear_cdt('$UA', '$D90', 1)" 2>&1 </dev/null)" 'P0001'
root "UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = '$UA'" >/dev/null
for f in "listar_cdt_definiciones('$UA')" "simular_cdt('$UA', '$D90', 100000)" "crear_cdt('$UA', '$D90', 100000)" "vista_cdts('$UA')"; do
  rechazado "A11 BLOQUEADO con sesion abierta: $(echo "$f" | cut -d'(' -f1) recibe el mensaje de bloqueo exacto" banco_app $APP_PW "SELECT public.$f" "Tu cuenta ha sido restringida, contacte con el banco para desbloquearla"
done
root "UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = '$UA'" >/dev/null
rechazado "A11 un ADMIN no usa CDT: Acceso denegado (vista_cdts)" banco_app $APP_PW "SELECT public.vista_cdts('$UADM')" "Acceso denegado"
rechazado "A11 usuario inexistente: Sesion invalida (crear_cdt)" banco_app $APP_PW "SELECT public.crear_cdt(gen_random_uuid(), '$D90', 100000)" "Sesión inválida"

# ============================================================================
# B. Permisos efectivos por conexion real
# ============================================================================
for f in "listar_cdt_definiciones('$UA')" "simular_cdt('$UA', '$D90', 100000)" "crear_cdt('$UA', '$D90', 100000)" "vista_cdts('$UA')"; do
  denegado "B1 banco_lector NO ejecuta $(echo "$f" | cut -d'(' -f1)" banco_lector $LECTOR_PW "SELECT public.$f"
done
for f in "_avanzar_hasta('$A', CURRENT_DATE, now())" "_devengar_bolsillos('$A', CURRENT_DATE, now())" "_devengar_cdts('$A', CURRENT_DATE, now())" "_factor_interes(12, 30)" "_bloquear_cuentas(ARRAY['$A'::uuid])" "_reglas_cdt()" "_definicion_cdt('$D90')" "_texto_tiempo_restante(CURRENT_DATE, CURRENT_DATE, 'ACTIVO')" "trg_ultimo_cobro_monotono()"; do
  denegado "B2 banco_app NO ejecuta la interna $(echo "$f" | cut -d'(' -f1)" banco_app $APP_PW "SELECT public.$f"
  denegado "B2 banco_lector NO ejecuta la interna $(echo "$f" | cut -d'(' -f1)" banco_lector $LECTOR_PW "SELECT public.$f"
  denegado "B2 banco_dev NO ejecuta la interna $(echo "$f" | cut -d'(' -f1)" banco_dev $DEV_PW "SELECT public.$f"
done
denegado "B3 banco_app NO lee la tabla cdt" banco_app $APP_PW "SELECT generado_acumulado FROM public.cdt"
denegado "B3 banco_app NO inserta CDT a mano (solo crear_cdt)" banco_app $APP_PW "INSERT INTO public.cdt (cuenta_id, nombre, monto, tasa_anual, plazo_dias, fecha_inicio, fecha_fin, ultimo_cobro) VALUES ('$A', 'x', 1, 1, 1, CURRENT_DATE, CURRENT_DATE + 1, CURRENT_DATE)"
denegado "B3 banco_app NO cierra un CDT a mano" banco_app $APP_PW "UPDATE public.cdt SET estado = 'CERRADO' WHERE id = '$CID'"
denegado "B3 banco_app NO toca ultimo_cobro de un CDT ni de un bolsillo (ni para adelantarlo ni para retrocederlo)" banco_app $APP_PW "UPDATE public.cdt SET ultimo_cobro = ultimo_cobro - 1 WHERE id = '$CID'"
denegado "B3 ...(bolsillo)" banco_app $APP_PW "UPDATE public.bolsillo SET ultimo_cobro = CURRENT_DATE - 100 WHERE id = '$B1'"
denegado "B3 banco_dev tampoco toca ultimo_cobro" banco_dev $DEV_PW "UPDATE public.bolsillo SET ultimo_cobro = CURRENT_DATE - 100 WHERE id = '$B1'"
rechazado "B3 banco_lector tampoco (sus sesiones son de solo lectura)" banco_lector $LECTOR_PW "UPDATE public.cdt SET ultimo_cobro = CURRENT_DATE - 100 WHERE id = '$CID'" "read-only transaction|permission denied"
contiene "B4 banco_dev hereda de banco_app: puede ver sus CDT" "$(as banco_dev $DEV_PW "SELECT public.vista_cdts('$UA')")" '"tiempo_restante": "Cerrado"'
eq "B5 la lista blanca de banco_app tiene EXACTAMENTE 40 funciones (E4-E12) y la integridad de defensas esta en orden" "t|40" "$(root "SELECT (SELECT bool_and(ok) FROM public.v_integridad_defensas)::text || '|' || (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND has_function_privilege('banco_app', p.oid, 'EXECUTE') AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e'))" | sed 's/true/t/')"

# ============================================================================
# C. Atomicidad sobre el estado confirmado: devengo + operacion, y devengo + cierre de CDT
# ============================================================================
UB=$(root "SELECT tests.u(951)"); CB=$(root "SELECT tests.c(951)")
as banco_app $APP_PW "SELECT public.crear_bolsillo('$UB', 'Fondo')" >/dev/null
BB=$(root "SELECT id FROM public.bolsillo WHERE cuenta_id = '$CB'")
as banco_app $APP_PW "SELECT public.mover_a_bolsillo('$UB', '$BB', '500000')" >/dev/null
jump 30
root "SELECT tests.instalar_fallas()" >/dev/null
for p in tx:1 tx:2 tx:3 tx:4 corte:1 corte:3; do
  H0=$(root "SELECT tests.huella_saldos()"); U0=$(root "SELECT ultimo_cobro FROM public.bolsillo WHERE id = '$BB'")
  o=$(PGOPTIONS="-c tests.falla=$p" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.retirar_de_bolsillo('$UB', '$BB', '100')" 2>&1 </dev/null)
  case $p in corte:*) contiene "C1 corte [$p] a mitad del devengo+retiro: el cliente ve la conexion cerrada" "$o" 'terminating connection|server closed the connection|connection to server';;
             *) contiene "C1 falla inyectada [$p] (patas 1-2 = devengo, 3-4 = retiro): el error llega" "$o" 'FALLA INYECTADA';; esac
  eq "C1 ...[$p] NADA cambio: ni saldos, ni libro, ni ultimo_cobro (el devengo se revirtio junto con la operacion)" "$H0|$U0" "$(root "SELECT tests.huella_saldos()")|$(root "SELECT ultimo_cobro FROM public.bolsillo WHERE id = '$BB'")"
done
eq "C1 ...ninguna sesion de banco_app quedo colgada" "0" "$(root "SELECT count(*) FROM pg_stat_activity WHERE usename = 'banco_app' AND state <> 'idle' AND pid <> pg_backend_pid()")"
root "SELECT tests.quitar_fallas()" >/dev/null
as banco_app $APP_PW "SELECT public.retirar_de_bolsillo('$UB', '$BB', '100')" >/dev/null
eq "C2 sin fallos: el reintento devenga UNA sola vez (1 grupo) y retira 100" "1|t" "$(root "SELECT (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE tipo = 'INTERES_BOLSO' AND bolsillo_id = '$BB') || '|' || ((SELECT balance FROM public.bolsillo WHERE id = '$BB') = 500000 + round(500000 * public._factor_interes(12, 30), 2) - 100)::text" | sed 's/true/t/')"

# CDT: el cierre (INTERES_CDT final: patas 1-2; CDT_VENCIMIENTO: patas 3-4) es atomico
UC=$(root "SELECT tests.u(952)"); CC=$(root "SELECT tests.c(952)")
as banco_app $APP_PW "SELECT public.crear_cdt('$UC', '$D20', '200000')" >/dev/null
CD=$(root "SELECT id FROM public.cdt WHERE cuenta_id = '$CC'")
jump 25
root "SELECT tests.instalar_fallas()" >/dev/null
for p in tx:1 tx:2 tx:3 tx:4 corte:2; do
  H0=$(root "SELECT tests.huella_saldos()")
  o=$(PGOPTIONS="-c tests.falla=$p" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.vista_cdts('$UC')" 2>&1 </dev/null)
  contiene "C3 cierre de CDT con falla [$p] en una de las 4 patas: el error llega" "$o" 'FALLA INYECTADA|terminating connection|server closed the connection|connection to server'
  eq "C3 ...[$p] el CDT sigue ACTIVO con generado 0 y la cuenta intacta (ni interes ni vencimiento a medias)" "$H0|ACTIVO|0.00" "$(root "SELECT tests.huella_saldos()")|$(root "SELECT estado || '|' || generado_acumulado FROM public.cdt WHERE id = '$CD'")"
done
root "SELECT tests.quitar_fallas()" >/dev/null
as banco_app $APP_PW "SELECT public.vista_cdts('$UC')" >/dev/null
eq "C4 sin fallos el cierre ocurre UNA vez: CERRADO, 1 grupo INTERES_CDT, 1 CDT_VENCIMIENTO, cuenta = 1.000.000 + generado" "CERRADO|1|1|t" "$(root "SELECT c.estado || '|' || (SELECT count(DISTINCT grupo_id) FROM public.transaccion t WHERE t.cdt_id = c.id AND t.tipo = 'INTERES_CDT') || '|' || (SELECT count(DISTINCT grupo_id) FROM public.transaccion t WHERE t.cdt_id = c.id AND t.tipo = 'CDT_VENCIMIENTO') || '|' || ((SELECT balance FROM public.cuenta WHERE id = '$CC') = 1000000 + c.generado_acumulado)::text FROM public.cdt c WHERE c.id = '$CD'" | sed 's/true/t/')"
as banco_app $APP_PW "SELECT public.vista_cdts('$UC')" >/dev/null
eq "C4 ...y una segunda consulta no escribe nada mas" "1|1" "$(root "SELECT (SELECT count(DISTINCT grupo_id) FROM public.transaccion t WHERE t.cdt_id = '$CD' AND t.tipo = 'INTERES_CDT') || '|' || (SELECT count(DISTINCT grupo_id) FROM public.transaccion t WHERE t.cdt_id = '$CD' AND t.tipo = 'CDT_VENCIMIENTO')")"

# ============================================================================
# D. Carreras por borrado con devengo pendiente: algo desaparece mientras la operacion espera el bloqueo del reloj
# ============================================================================
holder() { # holder SQL : toma el bloqueo del reloj 2.5 s y ejecuta SQL antes de soltarlo
  ( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT pg_sleep(2.5); $1 COMMIT;" > /tmp/c45_h.out 2>&1 </dev/null ) &
  sleep 1
}
prep() { # prep N : cliente N con 100000 en un bolsillo con interes pendiente y un CDT por vencer; N+1 es el destino
  alta $1 300000
  _u=$(root "SELECT tests.u($1)"); _c=$(root "SELECT tests.c($1)")
  as banco_app $APP_PW "SELECT public.crear_bolsillo('$_u', 'P')" >/dev/null
  _b=$(root "SELECT id FROM public.bolsillo WHERE cuenta_id = '$_c'")
  as banco_app $APP_PW "SELECT public.mover_a_bolsillo('$_u', '$_b', '100000')" >/dev/null
  as banco_app $APP_PW "SELECT public.crear_cdt('$_u', '$D20', '100000')" >/dev/null
}
prep 960; prep 962; prep 964; prep 966; alta 961 1000; alta 965 1000
jump 30
U960=$(root "SELECT tests.u(960)"); U962=$(root "SELECT tests.u(962)"); U964=$(root "SELECT tests.u(964)"); U966=$(root "SELECT tests.u(966)")
# D1. vista_balance: el usuario se borra mientras espera (con intereses y un CDT vencido pendientes)
holder "DELETE FROM public.usuario WHERE id = '$U960';"
o=$(as banco_app $APP_PW "SELECT public.vista_balance('$U960')")
wait
contiene "D1 el usuario se borra mientras vista_balance (con devengo pendiente) espera: 'Sesión inválida' (P0001, no un error de FK ni de libro)" "$o" 'ERROR:  Sesión inválida'
eq "D1 ...no queda rastro: ni usuario, ni patas, ni bolsillos, ni CDT" "0|0|0|0" "$(root "SELECT count(*) FROM public.usuario WHERE id = '$U960'")|$(root "SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(960)")|$(root "SELECT count(*) FROM public.bolsillo WHERE cuenta_id = tests.c(960)")|$(root "SELECT count(*) FROM public.cdt WHERE cuenta_id = tests.c(960)")"
# D2. vista_cdts
holder "DELETE FROM public.usuario WHERE id = '$U962';"
o=$(as banco_app $APP_PW "SELECT public.vista_cdts('$U962')")
wait
contiene "D2 el usuario se borra mientras vista_cdts (con un CDT vencido pendiente) espera: 'Sesión inválida'" "$o" 'ERROR:  Sesión inválida'
# D3. crear_cdt: el INSERT choca con la FK y se traduce
holder "DELETE FROM public.usuario WHERE id = '$U964';"
o=$(as banco_app $APP_PW "SELECT public.crear_cdt('$U964', '$D90', '100000')")
wait
contiene "D3 el usuario se borra mientras crear_cdt espera: 'Sesión inválida' (la FK se traduce; no un error 23503)" "$o" 'ERROR:  Sesión inválida'
eq "D3 ...no existe ningun CDT huerfano de esa cuenta" "0" "$(root "SELECT count(*) FROM public.cdt WHERE cuenta_id = tests.c(964)")"
# D4. hacer_transferencia: el DESTINO se borra mientras espera (el emisor tiene intereses y un CDT vencido pendientes): el motor no se ejecuta a medias
H0=$(salb "$(root "SELECT id FROM public.bolsillo WHERE cuenta_id = tests.c(966)")")
holder "DELETE FROM public.usuario WHERE id = tests.u(965);"
o=$(as banco_app $APP_PW "SELECT public.hacer_transferencia('$U966', '$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(965)")', 10, NULL, NULL)")
wait
contiene "D4 el DESTINO se borra mientras la transferencia espera: 'Cuenta no encontrada' (traducido por el bloqueo ordenado de cuentas)" "$o" 'ERROR:  Cuenta no encontrada'
eq "D4 ...el emisor no pierde dinero y su devengo no quedo a medias (el bolsillo conserva su saldo y no hay patas de ENVIO)" "$H0|0" "$(salb "$(root "SELECT id FROM public.bolsillo WHERE cuenta_id = tests.c(966)")")|$(root "SELECT count(*) FROM public.transaccion WHERE tipo = 'ENVIO' AND cuenta_id = tests.c(966)")"
eq "D5 integridad global y defensas en orden tras todo (fallos, cortes y carreras)" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
