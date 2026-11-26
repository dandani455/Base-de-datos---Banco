#!/bin/sh
# 41_transferencias_conexiones.sh - Etapa 5 - transferencias con conexiones REALES (TCP + contrasena) de banco_app, banco_lector y banco_dev.
#   A. La conversacion del backend: nombre_destinatario y hacer_transferencia (cuenta y bolsillo), salida jsonb, monto como texto, errores P0001 exactos.
#   B. Permisos EFECTIVOS: banco_app solo las 2 funciones (ni helpers internos ni tablas); lector ninguna; dev hereda de app.
#   C. Atomicidad sobre el estado CONFIRMADO: fallos inyectados en cada pata (incluso tras el debito) y CORTE de la conexion a mitad de la transferencia.
#   D. CARRERAS por borrado: el destino (o el bolsillo) se borra mientras la transferencia espera el bloqueo del reloj: se traduce a mensaje de negocio y
#      no queda rastro (nunca un error no-P0001, que el backend convertiria en 503).
# Termina SIEMPRE sin disparadores de inyeccion y en modo real.
. /work/tests/reales/lib.sh

restaurar() { wait; root "SELECT tests.quitar_fallas()" >/dev/null; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c41_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null

# clientes: 711 emisor (500000 + bolsillo 100000), 712 destino, 713 se bloqueara, 714 admin, 715 y 716 para las carreras
A=$(root "SELECT tests.cliente(711)"); B=$(root "SELECT tests.cliente(712)"); C=$(root "SELECT tests.cliente(713)")
root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso('$A', 600000))" >/dev/null
BA=$(root "SELECT tests.bolsillo(711, '$A')")
root "SELECT tests.app_bolso_ingreso('$A', '$BA', 100000)" >/dev/null
UA=$(root "SELECT tests.u(711)"); UB=$(root "SELECT tests.u(712)"); UC=$(root "SELECT tests.u(713)")
NB=4000000712; NC=4000000713
root "INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol) VALUES ('adm714', 'h', 'Adm', 'In', '9300714', 'a714@t.co', '3170000714', DATE '1980-01-01', 'ADMIN')" >/dev/null
UADM=$(root "SELECT id FROM public.usuario WHERE username = 'adm714'")
sal() { root "SELECT balance FROM public.cuenta WHERE id = '$1'"; }
salb() { root "SELECT balance FROM public.bolsillo WHERE id = '$1'"; }
T() { as banco_app $APP_PW "SELECT public.hacer_transferencia('$UA', $1, $2, $3, $4)"; }   # T "'destino'" monto nota bolsillo  (literales SQL)

# ============================================================================
# A. La conversacion del backend
# ============================================================================
eq "banco_app: conexion real, NO superusuario" "banco_app|off" "$(as banco_app $APP_PW "SELECT current_user || '|' || current_setting('is_superuser')")"
eq "A1 nombre_destinatario por TCP: {nombre} = nombres + apellidos (numero con espacios y puntos)" '{"nombre": "Nombre712 Apellido"}' "$(as banco_app $APP_PW "SELECT public.nombre_destinatario('$UA', ' 40.0000.0712 ')")"
rechazado "A1 ...inexistente: Cuenta no encontrada" banco_app $APP_PW "SELECT public.nombre_destinatario('$UA', '4999999999')" "Cuenta no encontrada"
rechazado "A1 ...sin sesion (usuario desconocido): Sesion invalida" banco_app $APP_PW "SELECT public.nombre_destinatario(gen_random_uuid(), '$NB')" "Sesión inválida"
o=$(T "'$NB'" 150.50 "'  hola  '" NULL)
contiene "A2 hacer_transferencia por TCP devuelve {id, fecha} (jsonb)" "$o" '^\{"id": "[0-9a-f-]{36}", "fecha": "[0-9-]{10}T[0-9:.]+[-+][0-9:]+"\}$'
eq "A2 ...saldos: emisor 499849.50 y destino 150.50" "499849.50|150.50" "$(sal $A)|$(sal $B)"
eq "A2 ...2 patas en el grupo devuelto, con la nota recortada" "2|hola" "$(root "SELECT count(*) || '|' || min(nota) FROM public.transaccion WHERE grupo_id = '$(echo "$o" | sed -n 's/.*"id": "\([^"]*\)".*/\1/p')'")"
eq "A3 el monto llega como TEXTO ('0.10'): se acepta y mueve 10 centavos" "OK|150.60" "$(T "'$NB'" "'0.10'" NULL NULL | grep -q '"id"' && echo OK)|$(sal $B)"
rechazado "A3 el artefacto de float 0.30000000000000004 es Monto invalido (el backend debe pasar texto)" banco_app $APP_PW "SELECT public.hacer_transferencia('$UA', '$NB', 0.30000000000000004, NULL, NULL)" "Monto inválido"
o=$(T "'$NB'" 1000 NULL "'$BA'")
contiene "A4 desde el bolsillo: responde {id, fecha}" "$o" '"id"'
eq "A4 ...el bolsillo baja 100000 -> 99000 y la cuenta principal NO cambia" "99000.00|499849.40" "$(salb $BA)|$(sal $A)"
eq "A4 ...la pata ENVIO es del BOLSILLO y la RECIBO de CUENTA" "BOLSILLO|CUENTA" "$(root "SELECT (SELECT contenedor FROM public.transaccion WHERE tipo = 'ENVIO' AND bolsillo_id = '$BA' ORDER BY orden DESC LIMIT 1) || '|' || (SELECT contenedor FROM public.transaccion WHERE tipo = 'RECIBO' AND cuenta_id = '$B' ORDER BY orden DESC LIMIT 1)")"
R5() { rechazado "A5 $1" banco_app $APP_PW "SELECT public.hacer_transferencia('$UA', $2, $3, $4, $5)" "$6"; }   # R5 etiqueta destino monto nota bolsillo mensaje
R5 "Monto invalido" "'$NB'" 0 NULL NULL "Monto inválido"
R5 "Monto invalido (3 decimales)" "'$NB'" 1.234 NULL NULL "Monto inválido"
R5 "Monto invalido gana al destino inexistente" "'4999999999'" -5 NULL NULL "Monto inválido"
R5 "Cuenta no encontrada (inexistente)" "'4999999999'" 10 NULL NULL "Cuenta no encontrada"
R5 "Cuenta no encontrada (mal formada)" "'abc'" 10 NULL NULL "Cuenta no encontrada"
R5 "autoenvio" "'4000000711'" 10 NULL NULL "No puedes enviarte dinero a ti mismo"
R5 "bolsillo con texto que no es uuid (nunca un 503 del driver)" "'$NB'" 10 NULL "'no-es-uuid'" "Recurso no encontrado"
R5 "bolsillo inexistente" "'$NB'" 10 NULL "gen_random_uuid()::text" "Recurso no encontrado"
R5 "nota de 141 caracteres (provisional D-E5-8)" "'$NB'" 10 "repeat('n', 141)" NULL "Nota inválida"
R5 "saldo insuficiente (cuenta)" "'$NB'" 999999999 NULL NULL "Saldo insuficiente"
R5 "saldo insuficiente (bolsillo de 99000)" "'$NB'" 99000.01 NULL "'$BA'" "Saldo insuficiente"
contiene "A5 ...el autoenvio ANTES que bolsillo y que saldo" "$(T "'4000000711'" 99999999 NULL "'no-es-uuid'")" "No puedes enviarte dinero a ti mismo"
contiene "A6 el error de negocio llega con SQLSTATE P0001 (el backend lo convierte en 400)" "$(PGPASSWORD=$APP_PW psql -X -h "$HOST" -U banco_app -d "$DB" -v VERBOSITY=verbose -c "SELECT public.hacer_transferencia('$UA', '$NB', 0, NULL, NULL)" 2>&1 </dev/null)" 'P0001'
root "UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = '$UA'" >/dev/null
rechazado "A7 emisor con sesion abierta y luego BLOQUEADO: recibe el mensaje de bloqueo exacto" banco_app $APP_PW "SELECT public.hacer_transferencia('$UA', '$NB', 1, NULL, NULL)" "Tu cuenta ha sido restringida, contacte con el banco para desbloquearla"
rechazado "A7 ...tampoco puede consultar destinatarios" banco_app $APP_PW "SELECT public.nombre_destinatario('$UA', '$NB')" "Tu cuenta ha sido restringida"
root "UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = '$UA'" >/dev/null
rechazado "A7 un ADMIN no transfiere: Acceso denegado" banco_app $APP_PW "SELECT public.hacer_transferencia('$UADM', '$NB', 1, NULL, NULL)" "Acceso denegado"
rechazado "A7 usuario inexistente: Sesion invalida" banco_app $APP_PW "SELECT public.hacer_transferencia(gen_random_uuid(), '$NB', 1, NULL, NULL)" "Sesión inválida"
root "UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = '$UC'" >/dev/null
S0=$(sal $C); o=$(T "'$NC'" 5 NULL NULL)
eq "A8 D-E5-9 (PROVISIONAL, negocio pendiente): un destino BLOQUEADO puede recibir" "t" "$(root "SELECT balance = $S0 + 5 FROM public.cuenta WHERE id = '$C'")"
root "UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = '$UC'" >/dev/null

# ============================================================================
# B. Permisos efectivos por conexion real
# ============================================================================
denegado "B1 banco_lector NO ejecuta hacer_transferencia" banco_lector $LECTOR_PW "SELECT public.hacer_transferencia('$UA', '$NB', 1, NULL, NULL)"
denegado "B1 banco_lector NO ejecuta nombre_destinatario" banco_lector $LECTOR_PW "SELECT public.nombre_destinatario('$UA', '$NB')"
for f in "_validar_monto(1)" "_msg_negocio('monto')" "_reglas_transferencia()"; do
  denegado "B2 banco_app NO ejecuta el helper interno $f" banco_app $APP_PW "SELECT public.$f"
  denegado "B2 banco_lector NO ejecuta el helper interno $f" banco_lector $LECTOR_PW "SELECT public.$f"
  denegado "B2 banco_dev NO ejecuta el helper interno $f" banco_dev $DEV_PW "SELECT public.$f"
done
denegado "B3 banco_app NO lee las cuentas ni los saldos" banco_app $APP_PW "SELECT balance FROM public.cuenta"
denegado "B3 banco_app NO escribe el libro mayor" banco_app $APP_PW "INSERT INTO public.transaccion (cuenta_id, tipo, monto) VALUES ('$A', 'ENVIO', 1)"
denegado "B3 banco_app NO invoca el libro mayor directamente" banco_app $APP_PW "SELECT public._asentar_grupo(now(), '[]'::jsonb)"
contiene "B4 banco_dev hereda de banco_app: puede consultar un destinatario" "$(as banco_dev $DEV_PW "SELECT public.nombre_destinatario('$UA', '$NB')")" '"nombre"'

# ============================================================================
# C. Atomicidad sobre el estado confirmado
# ============================================================================
root "SELECT tests.instalar_fallas()" >/dev/null
for p in tx:1 tx:2; do
  for bol in NULL "'$BA'"; do
    H0=$(root "SELECT tests.huella_saldos()"); SA0=$(sal $A); SB0=$(sal $B); BB0=$(salb $BA)
    o=$(PGOPTIONS="-c tests.falla=$p" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.hacer_transferencia('$UA', '$NB', 25, 'x', $bol)" 2>&1 </dev/null)
    contiene "C1 falla inyectada [$p] (origen $bol) sobre TCP: el error llega" "$o" 'FALLA INYECTADA'
    eq "C1 ...[$p] nada cambio: ni el emisor (cuenta/bolsillo), ni el destino, ni el libro" "$H0|$SA0|$SB0|$BB0" "$(root "SELECT tests.huella_saldos()")|$(sal $A)|$(sal $B)|$(salb $BA)"
  done
done
for p in corte:1 corte:2; do
  H0=$(root "SELECT tests.huella_saldos()"); SA0=$(sal $A)
  o=$(PGOPTIONS="-c tests.falla=$p" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.hacer_transferencia('$UA', '$NB', 25, 'x', NULL)" 2>&1 </dev/null)
  contiene "C2 corte de la conexion [$p] a mitad de la transferencia: el cliente ve la conexion cerrada" "$o" 'terminating connection|server closed the connection|connection to server'
  eq "C2 ...[$p] el estado confirmado no cambio (el emisor no pierde dinero)" "$H0|$SA0" "$(root "SELECT tests.huella_saldos()")|$(sal $A)"
done
eq "C2 ...ninguna sesion de banco_app quedo colgada" "0" "$(root "SELECT count(*) FROM pg_stat_activity WHERE usename = 'banco_app' AND state <> 'idle' AND pid <> pg_backend_pid()")"
root "SELECT tests.quitar_fallas()" >/dev/null
contiene "C3 sin disparadores de falla la transferencia vuelve a funcionar y mueve el dinero UNA vez" "$(T "'$NB'" 25 NULL NULL)" '"id"'
eq "C3 ...el emisor perdio exactamente 25 en total tras 4 fallos, 2 cortes y 1 exito" "t" "$(root "SELECT $SA0 - 25 = balance FROM public.cuenta WHERE id = '$A'")"

# ============================================================================
# D. Carreras por borrado: el destino / el bolsillo desaparece mientras la transferencia espera el bloqueo del reloj
# ============================================================================
D=$(root "SELECT tests.cliente(715)"); ND=4000000715
E=$(root "SELECT tests.cliente(716)"); UE=$(root "SELECT tests.u(716)"); UD=$(root "SELECT tests.u(715)")
root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso('$E', 10000))" >/dev/null
BE=$(root "SELECT tests.bolsillo(716, '$E')")
H0=$(root "SELECT tests.huella_saldos()")
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT pg_sleep(2.5); DELETE FROM public.usuario WHERE id = '$UD'; COMMIT;" > /tmp/c41_d1.out 2>&1 </dev/null ) &
sleep 1
o=$(as banco_app $APP_PW "SELECT public.hacer_transferencia('$UE', '$ND', 100, 'carrera', NULL)")
wait
eq "D1 el administrador borra al destino mientras la transferencia espera el reloj: el borrado se confirmo" "0" "$(root "SELECT count(*) FROM public.usuario WHERE id = '$UD'")"
contiene "D1 ...la transferencia recibe el mensaje de NEGOCIO 'Cuenta no encontrada' (P0001, no un error de FK)" "$o" 'ERROR:  Cuenta no encontrada'
eq "D1 ...el emisor conserva su saldo y no quedo ninguna pata hacia ese destino" "10000.00|0" "$(sal $E)|$(root "SELECT count(*) FROM public.transaccion WHERE contraparte_cuenta = '$ND'")"
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT pg_sleep(2.5); DELETE FROM public.bolsillo WHERE id = '$BE'; COMMIT;" > /tmp/c41_d2.out 2>&1 </dev/null ) &
sleep 1
o=$(as banco_app $APP_PW "SELECT public.hacer_transferencia('$UE', '$NB', 100, 'carrera', '$BE')")
wait
eq "D2 el bolsillo se borra mientras la transferencia espera: el borrado se confirmo (sin errores del administrador)" "0|" "$(root "SELECT count(*) FROM public.bolsillo WHERE id = '$BE'")|$(grep -c ERROR /tmp/c41_d2.out | sed 's/^0$//')"
contiene "D2 ...la transferencia recibe 'Recurso no encontrado' (traducido)" "$o" 'ERROR:  Recurso no encontrado'
eq "D2 ...no quedo ninguna pata del emisor hacia el destino 712 tras la carrera" "0" "$(root "SELECT count(*) FROM public.transaccion WHERE cuenta_id = '$E' AND tipo = 'ENVIO'")"
# D4. El propio EMISOR es borrado (cascada del admin) mientras espera: Sesion invalida (no el texto interno del libro)
F=$(root "SELECT tests.cliente(717)"); UF=$(root "SELECT tests.u(717)")
root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso('$F', 1000))" >/dev/null
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT pg_sleep(2.5); DELETE FROM public.usuario WHERE id = '$UF'; COMMIT;" > /tmp/c41_d4.out 2>&1 </dev/null ) &
sleep 1
o=$(as banco_app $APP_PW "SELECT public.hacer_transferencia('$UF', '$NB', 100, NULL, NULL)")
wait
contiene "D4 el emisor borrado a mitad de la operacion: 'Sesión inválida' (traducido, sin el texto interno 'Libro mayor')" "$o" 'ERROR:  Sesión inválida'
eq "D4 ...el destino no recibio nada de ese envio" "0" "$(root "SELECT count(*) FROM public.transaccion WHERE tipo = 'RECIBO' AND contraparte_cuenta = '4000000717'")"
eq "D3 integridad global y defensas en orden tras todo (fallos, cortes y carreras)" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
