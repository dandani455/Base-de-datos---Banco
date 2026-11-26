#!/bin/sh
# 47_creditos_conexiones.sh - Etapa 8 - creditos con conexiones REALES (TCP + contrasena) de banco_app, banco_lector y banco_dev, SIN superusuario.
#   A. La conversacion del backend: productos_disponibles / productos_publicos / simular_credito / solicitar_credito / vista_creditos (salida jsonb, monto y plazo como
#      numericos, errores P0001 con el mensaje exacto del contrato §6).
#   B. Permisos EFECTIVOS: banco_app ejecuta las 5 publicas y NINGUNA interna; lector ninguna; dev hereda de app; ninguna escritura directa de credito ni cuota.
#   C. Atomicidad sobre el estado CONFIRMADO: fallos inyectados en cada pata del desembolso y CORTE de la conexion a mitad de solicitar_credito.
#   D. CARRERAS por borrado: el usuario desaparece mientras solicitar_credito (con devengo pendiente) espera el bloqueo del reloj: mensaje de negocio, nunca un 503.
# Termina SIEMPRE sin disparadores de inyeccion, sin productos de prueba y en modo real.
. /work/tests/reales/lib.sh

restaurar() { wait; root "SELECT tests.quitar_fallas()" >/dev/null; root "DELETE FROM public.credito WHERE producto_id IN (SELECT id FROM public.credito_producto WHERE nombre LIKE 'T47 %')" >/dev/null; root "DELETE FROM public.credito_producto WHERE nombre LIKE 'T47 %'" >/dev/null; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c47_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
root "SELECT public._reloj_actualizar(false, to_char(public.hoy_banco(), 'YYYY-MM-DD'))" >/dev/null
jump() { root "SELECT public._reloj_actualizar(false, (public.hoy_banco() + $1)::text)" >/dev/null; }
sal() { root "SELECT balance FROM public.cuenta WHERE id = '$1'"; }
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
newprod() { root "WITH x AS (INSERT INTO public.credito_producto (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses, tope_absoluto, multiplicador_balance, aplica_regla_edad) VALUES ('$1', '$2', $3, $4, $5, $6, $7, $8, $9, ${10}) RETURNING id) SELECT id FROM x"; }

# productos: Libre (tope 30M), Inmuebles (100 x patrimonio, regla de edad)
PL=$(newprod 'T47 Libre' 'Dinero para lo que necesites' 23.9 1000000 30000000 6 24 30000000 NULL false)
PI=$(newprod 'T47 Inmuebles' 'Tu casa' 14.1 1 2000000000 12 360 2000000000 100 true)
# clientes: 980 (conversacion A), 981 (mayor de 70, regla de edad), 983 (atomicidad C); 984 admin
alta 980 20000000; alta 981 5000000; alta 983 20000000
root "UPDATE public.usuario SET fecha_nacimiento = public.hoy_banco() - interval '71 years' WHERE id = tests.u(981)" >/dev/null
UA=$(root "SELECT tests.u(980)"); A=$(root "SELECT tests.c(980)"); U81=$(root "SELECT tests.u(981)")
root "INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol) VALUES ('adm984', 'h', 'Adm', 'In', '9300984', 'a984@t.co', '3170000984', DATE '1980-01-01', 'ADMIN')"
UADM=$(root "SELECT id FROM public.usuario WHERE username = 'adm984'")

# ============================================================================
# A. La conversacion del backend
# ============================================================================
o=$(as banco_app $APP_PW "SELECT public.productos_disponibles('$UA')")
contiene "A1 productos_disponibles por TCP: [{id, nombre, tasa, monto_min, monto_max, plazo_min, plazo_max}] con numeros JSON" "$o" '"tasa": 23.900, "nombre": "T47 Libre"'
contiene "A1 ...Libre: monto_max 30.000.000 y plazo_max 24" "$o" '"nombre": "T47 Libre", "monto_max": 30000000.00, "monto_min": 1000000.00, "plazo_max": 24, "plazo_min": 6'
contiene "A1 ...Inmuebles: monto_max = 100 x patrimonio (20.000.000 -> 2.000.000.000 tope)" "$o" '"nombre": "T47 Inmuebles", "monto_max": 2000000000.00'
o=$(as banco_app $APP_PW "SELECT public.productos_publicos()")
contiene "A2 productos_publicos por TCP (sin sesion): trae descripcion y topes base" "$o" '"descripcion": "Dinero para lo que necesites"'
o=$(as banco_app $APP_PW "SELECT public.simular_credito('$UA', '$PL', '10000000', 12)")
contiene "A3 simular_credito por TCP (monto como TEXTO, plazo numerico): las 3 claves son numeros" "$o" '"cuota_mensual": [0-9]+\.[0-9]{2}'
contiene "A3 ...total_a_pagar e intereses_totales presentes" "$o" '"total_a_pagar": [0-9.]+.*"intereses_totales": [0-9.]+|"intereses_totales": [0-9.]+.*"total_a_pagar": [0-9.]+'
eq "A3 ...la simulacion no escribe nada: 0 creditos" "0" "$(root "SELECT count(*) FROM public.credito WHERE cuenta_id = '$A'")"
H0=$(sal $A)
o=$(as banco_app $APP_PW "SELECT public.solicitar_credito('$UA', '$PL', '10000000', 12)")
contiene "A4 solicitar_credito por TCP devuelve {id, fecha}" "$o" '^\{"id": "[0-9a-f-]{36}", "fecha": "[0-9-]{10}T[0-9:.]+[-+][0-9:]+"\}$'
K=$(root "SELECT id FROM public.credito WHERE cuenta_id = '$A'")
eq "A4 ...la cuenta recibe 10.000.000, 12 cuotas y capital_pendiente 10.000.000 (plan = deuda = libro)" "t|12|10000000.00" "$(root "SELECT (balance = $H0 + 10000000)::text || '|' || (SELECT count(*) FROM public.cuota WHERE credito_id = '$K') || '|' || (SELECT capital_pendiente FROM public.credito WHERE id = '$K') FROM public.cuenta WHERE id = '$A'" | sed 's/true/t/')"
eq "A4 ...UN grupo CREDITO_DESEMBOLSO de 2 patas" "2|1" "$(root "SELECT count(*) || '|' || count(DISTINCT grupo_id) FROM public.transaccion WHERE credito_id = '$K'")"
o=$(as banco_app $APP_PW "SELECT public.vista_creditos('$UA')")
contiene "A5 vista_creditos por TCP: producto, cuotas_pagadas 0, cuotas_faltantes 12, saldo" "$o" '"producto": "T47 Libre"'
contiene "A5 ...cuotas y saldo como numeros" "$o" '"cuotas_pagadas": 0.*"cuotas_faltantes": 12|"cuotas_faltantes": 12.*"cuotas_pagadas": 0'
contiene "A5 ...saldo 10.000.000" "$o" '"saldo": 10000000.00'
jump 15
o=$(as banco_app $APP_PW "SELECT public.vista_creditos('$UA')")
contiene "A6 15 dias despues: interes_mes > 0 (interes corriendo derivado)" "$o" '"interes_mes": [1-9][0-9]*\.[0-9]{2}'
eq "A6 ...la lectura no escribio asientos de credito: sigue habiendo 2 patas" "2" "$(root "SELECT count(*) FROM public.transaccion WHERE credito_id = '$K'")"
R() { rechazado "A7 $1" banco_app $APP_PW "$2" "$3"; }
R "segundo credito del mismo producto" "SELECT public.solicitar_credito('$UA', '$PL', '2000000', 12)" "Ya tienes un crédito vigente de este producto"
R "monto 0 (Monto invalido)" "SELECT public.solicitar_credito('$UA', '$PI', '0', 12)" "Monto inválido"
R "Inmuebles 3.000.000.000 (sobre el tope)" "SELECT public.solicitar_credito('$UA', '$PI', '3000000000', 12)" "Monto fuera de rango"
R "plazo fuera de rango (400 > 360)" "SELECT public.solicitar_credito('$UA', '$PI', '1000000', 400)" "Plazo fuera de rango"
R "plazo fraccionario 12.5 (nunca un error de driver)" "SELECT public.solicitar_credito('$UA', '$PI', '1000000', 12.5)" "Plazo fuera de rango"
R "regla de edad (71 años): Plazo excede el limite de edad" "SELECT public.solicitar_credito('$U81', '$PI', '1000000', 12)" "Plazo excede el límite de edad"
R "el artefacto de float 0.30000000000000004 es Monto invalido" "SELECT public.solicitar_credito('$UA', '$PL', 0.30000000000000004, 12)" "Monto inválido"
R "producto con texto que no es uuid (nunca un 503 del driver)" "SELECT public.solicitar_credito('$UA', 'no-es-uuid', 1000000, 12)" "Recurso no encontrado"
R "simular con producto inexistente" "SELECT public.simular_credito('$UA', gen_random_uuid()::text, 1000000, 12)" "Recurso no encontrado"
contiene "A7 el error de negocio llega con SQLSTATE P0001 (el backend lo convierte en 400)" "$(PGPASSWORD=$APP_PW psql -X -h "$HOST" -U banco_app -d "$DB" -v VERBOSITY=verbose -c "SELECT public.solicitar_credito('$UA', '$PL', 1, 12)" 2>&1 </dev/null)" 'P0001'
root "UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = '$UA'" >/dev/null
for f in "productos_disponibles('$UA')" "simular_credito('$UA', '$PL', 1000000, 12)" "solicitar_credito('$UA', '$PL', 1000000, 12)" "vista_creditos('$UA')"; do
  rechazado "A8 BLOQUEADO con sesion abierta: $(echo "$f" | cut -d'(' -f1) recibe el mensaje de bloqueo exacto" banco_app $APP_PW "SELECT public.$f" "Tu cuenta ha sido restringida, contacte con el banco para desbloquearla"
done
root "UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = '$UA'" >/dev/null
rechazado "A8 un ADMIN no usa creditos: Acceso denegado" banco_app $APP_PW "SELECT public.vista_creditos('$UADM')" "Acceso denegado"
rechazado "A8 usuario inexistente: Sesion invalida" banco_app $APP_PW "SELECT public.solicitar_credito(gen_random_uuid(), '$PL', 1000000, 12)" "Sesión inválida"

# ============================================================================
# B. Permisos efectivos por conexion real
# ============================================================================
for f in "productos_disponibles('$UA')" "productos_publicos()" "simular_credito('$UA', '$PL', 1000000, 12)" "solicitar_credito('$UA', '$PL', 1000000, 12)" "vista_creditos('$UA')"; do
  denegado "B1 banco_lector NO ejecuta $(echo "$f" | cut -d'(' -f1)" banco_lector $LECTOR_PW "SELECT public.$f"
done
for f in "_plan_cuotas(1000000, 18, 12)" "_tasa_mensual(18)" "_fecha_vencimiento(CURRENT_DATE, 1)" "_patrimonio_neto('$A')" "_interes_corriendo('$K', CURRENT_DATE)" "_reglas_credito()" "_producto_credito('$PL')" "_validar_plazo(12)"; do
  denegado "B2 banco_app NO ejecuta la interna $(echo "$f" | cut -d'(' -f1)" banco_app $APP_PW "SELECT public.$f"
  denegado "B2 banco_lector NO ejecuta la interna $(echo "$f" | cut -d'(' -f1)" banco_lector $LECTOR_PW "SELECT public.$f"
  denegado "B2 banco_dev NO ejecuta la interna $(echo "$f" | cut -d'(' -f1)" banco_dev $DEV_PW "SELECT public.$f"
done
denegado "B3 banco_app NO lee la tabla credito" banco_app $APP_PW "SELECT capital_pendiente FROM public.credito"
denegado "B3 banco_app NO lee la tabla cuota" banco_app $APP_PW "SELECT * FROM public.cuota"
denegado "B3 banco_app NO inserta un credito a mano" banco_app $APP_PW "INSERT INTO public.credito (cuenta_id, producto_id, monto, tasa_anual, plazo_meses, fecha_desembolso, capital_pendiente, fecha_interes) VALUES ('$A', '$PI', 1, 1, 1, CURRENT_DATE, 0, CURRENT_DATE)"
denegado "B3 banco_app NO toca capital_pendiente" banco_app $APP_PW "UPDATE public.credito SET capital_pendiente = 0 WHERE id = '$K'"
denegado "B3 banco_app NO inserta, edita ni borra cuotas" banco_app $APP_PW "DELETE FROM public.cuota WHERE credito_id = '$K'"
denegado "B3 ...(UPDATE)" banco_app $APP_PW "UPDATE public.cuota SET pagada = true WHERE credito_id = '$K'"
denegado "B3 banco_dev tampoco edita el plan" banco_dev $DEV_PW "UPDATE public.cuota SET capital_programado = 1 WHERE credito_id = '$K'"
rechazado "B3 banco_lector tampoco (sus sesiones son de solo lectura)" banco_lector $LECTOR_PW "UPDATE public.cuota SET pagada = true WHERE credito_id = '$K'" "read-only transaction|permission denied"
eq "B4 banco_lector SI lee el plan (solo lectura) y la vista de integridad de creditos" "12|t" "$(as banco_lector $LECTOR_PW "SELECT (SELECT count(*) FROM public.cuota WHERE credito_id = '$K') || '|' || (SELECT bool_and(ok) FROM public.v_integridad_creditos)" | sed 's/true/t/')"
contiene "B4 banco_dev hereda de banco_app: puede ver sus creditos" "$(as banco_dev $DEV_PW "SELECT public.vista_creditos('$UA')")" '"producto": "T47 Libre"'
eq "B5 la lista blanca de banco_app tiene EXACTAMENTE 40 funciones (E4-E12) y las defensas estan en orden" "t|40" "$(root "SELECT (SELECT bool_and(ok) FROM public.v_integridad_defensas)::text || '|' || (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e') AND has_function_privilege('banco_app', p.oid, 'EXECUTE'))" | sed 's/true/t/')"

# ============================================================================
# C. Atomicidad sobre el estado confirmado
# ============================================================================
U3=$(root "SELECT tests.u(983)"); C3=$(root "SELECT tests.c(983)")
root "SELECT tests.instalar_fallas()" >/dev/null
for p in tx:1 tx:2 corte:1 corte:2; do
  H0=$(root "SELECT tests.huella_saldos()")
  o=$(PGOPTIONS="-c tests.falla=$p" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.solicitar_credito('$U3', '$PL', '5000000', 12)" 2>&1 </dev/null)
  case $p in corte:*) contiene "C1 corte [$p] a mitad del desembolso: el cliente ve la conexion cerrada" "$o" 'terminating connection|server closed the connection|connection to server';;
             *) contiene "C1 falla inyectada [$p] (pata 1 = cuenta, pata 2 = credito): el error llega" "$o" 'FALLA INYECTADA';; esac
  eq "C1 ...[$p] NADA cambio: ni saldos, ni libro, ni creditos, ni cuotas" "$H0|0|0" "$(root "SELECT tests.huella_saldos()")|$(root "SELECT count(*) FROM public.credito WHERE cuenta_id = '$C3'")|$(root "SELECT count(*) FROM public.cuota q JOIN public.credito k ON k.id = q.credito_id WHERE k.cuenta_id = '$C3'")"
done
eq "C1 ...ninguna sesion de banco_app quedo colgada" "0" "$(root "SELECT count(*) FROM pg_stat_activity WHERE usename = 'banco_app' AND state <> 'idle' AND pid <> pg_backend_pid()")"
root "SELECT tests.quitar_fallas()" >/dev/null
as banco_app $APP_PW "SELECT public.solicitar_credito('$U3', '$PL', '5000000', 12)" >/dev/null
eq "C2 sin fallos el reintento crea UN credito con 12 cuotas y el plan cuadra con la deuda" "1|12|t" "$(root "SELECT (SELECT count(*) FROM public.credito WHERE cuenta_id = '$C3') || '|' || (SELECT count(*) FROM public.cuota q JOIN public.credito k ON k.id = q.credito_id WHERE k.cuenta_id = '$C3') || '|' || (SELECT ok FROM public.v_integridad_creditos WHERE cuenta_id = '$C3')" | sed 's/true/t/')"

# ============================================================================
# D. Carreras por borrado con devengo pendiente
# ============================================================================
holder() { ( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT pg_sleep(2.5); $1 COMMIT;" > /tmp/c47_h.out 2>&1 </dev/null ) & sleep 1; }
alta 985 3000000
U85=$(root "SELECT tests.u(985)"); C85=$(root "SELECT tests.c(985)")
as banco_app $APP_PW "SELECT public.crear_bolsillo('$U85', 'P')" >/dev/null
B85=$(root "SELECT id FROM public.bolsillo WHERE cuenta_id = '$C85'")
as banco_app $APP_PW "SELECT public.mover_a_bolsillo('$U85', '$B85', '1000000')" >/dev/null
jump 30
holder "DELETE FROM public.usuario WHERE id = '$U85';"
o=$(as banco_app $APP_PW "SELECT public.solicitar_credito('$U85', '$PL', '2000000', 12)")
wait
contiene "D1 el usuario se borra mientras solicitar_credito (con devengo pendiente) espera: 'Sesión inválida' (P0001, no un error de FK ni de libro)" "$o" 'ERROR:  Sesión inválida'
eq "D1 ...no queda rastro: ni usuario, ni creditos, ni cuotas, ni patas de esa cuenta" "0|0|0|0" "$(root "SELECT count(*) FROM public.usuario WHERE id = '$U85'")|$(root "SELECT count(*) FROM public.credito WHERE cuenta_id = '$C85'")|$(root "SELECT count(*) FROM public.cuota WHERE credito_id IN (SELECT id FROM public.credito WHERE cuenta_id = '$C85')")|$(root "SELECT count(*) FROM public.transaccion WHERE cuenta_id = '$C85'")"
alta 986 3000000
U86=$(root "SELECT tests.u(986)")
holder "DELETE FROM public.usuario WHERE id = '$U86';"
o=$(as banco_app $APP_PW "SELECT public.vista_creditos('$U86')")
wait
contiene "D2 el usuario se borra mientras vista_creditos espera: 'Sesión inválida' o una lista vacia valida (nunca un error no-P0001)" "$o" 'ERROR:  Sesión inválida|^\[\]$'
eq "D3 integridad global y de planes en orden tras todo (fallos, cortes y carreras)" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
