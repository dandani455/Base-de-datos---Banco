#!/bin/sh
# 51_vistas_conexiones.sh - Etapa 10 - vista_dashboard y vista_historial con conexiones REALES (TCP + contrasena) de banco_app, banco_lector y banco_dev, SIN superusuario.
#   A. La conversacion del backend: jsonb, limite como entero, fechas con -05:00 aunque la sesion pida UTC, [] sin movimientos.
#   B. Permisos EFECTIVOS: banco_app ejecuta las 2 publicas y NINGUNA interna, NO lee la vista ni el libro; banco_lector/dev leen la vista; el admin recibe Acceso denegado, el bloqueado su
#      mensaje exacto, un usuario inexistente Sesion invalida; un cliente jamas ve filas de otro.
#   C. Atomicidad sobre el estado CONFIRMADO: el dashboard dispara un cobro automatico (3 patas de cuota + 2 de mora); falla inyectada en cada pata y CORTE de la conexion no dejan nada.
#   D. CARRERA por borrado: el usuario desaparece mientras vista_dashboard / vista_historial esperan el bloqueo del reloj.
# Termina SIEMPRE sin disparadores de inyeccion, sin productos de prueba, sin tasa de mora y en modo real.
. /work/tests/reales/lib.sh

restaurar() { wait; root "SELECT tests.quitar_fallas()" >/dev/null; root "UPDATE public.usuario SET estado = 'ACTIVO' WHERE username LIKE 'cli12%'" >/dev/null; root "DELETE FROM public.credito WHERE producto_id IN (SELECT id FROM public.credito_producto WHERE nombre LIKE 'T51 %')" >/dev/null; root "DELETE FROM public.credito_producto WHERE nombre LIKE 'T51 %'" >/dev/null; root "UPDATE public.parametro SET tasa_mora_anual = NULL" >/dev/null; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
root "UPDATE public.parametro SET tasa_mora_anual = 30" >/dev/null
root "SELECT public._reloj_actualizar(false, to_char(public.hoy_banco(), 'YYYY-MM-DD'))" >/dev/null
jump() { root "SELECT public._reloj_actualizar(false, (public.hoy_banco() + $1)::text)" >/dev/null; }
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
sal() { root "SELECT balance FROM public.cuenta WHERE id = '$1'"; }
PL=$(root "WITH x AS (INSERT INTO public.credito_producto (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES ('T51 Libre', '', 18, 1, 1000000000, 1, 360) RETURNING id) SELECT id FROM x")
# clientes: 1200 (conversacion), 1201 (otro cliente), 1202 (bloqueado), 1203 (atomicidad: cobro automatico), 1204 (carrera dashboard), 1205 (carrera historial), 1206 (sin movimientos); 1210 admin
alta 1200 5000000; alta 1201 5000000; alta 1202 5000000; alta 1203 5000000; alta 1204 5000000; alta 1205 5000000; root "SELECT tests.cliente(1206)" >/dev/null
root "INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol) VALUES ('adm1210', 'h', 'Adm', 'In', '9301210', 'a1210@t.co', '3171210210', DATE '1980-01-01', 'ADMIN')"
UADM=$(root "SELECT id FROM public.usuario WHERE username = 'adm1210'")
UA=$(root "SELECT tests.u(1200)"); A=$(root "SELECT tests.c(1200)"); UB=$(root "SELECT tests.u(1201)"); B=$(root "SELECT tests.c(1201)")
NB=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = '$B'"); NA=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = '$A'")

# ============================================================================
# A. La conversacion del backend
# ============================================================================
as banco_app $APP_PW "SELECT public.hacer_transferencia('$UA', '$NB', 250000, 'arriendo', NULL)" >/dev/null
as banco_app $APP_PW "SELECT public.hacer_transferencia('$UB', '$NA', 40000, 'devuelta', NULL)" >/dev/null
as banco_app $APP_PW "SELECT public.solicitar_credito('$UA', '$PL', '3000000', 12)" >/dev/null
o=$(as banco_app $APP_PW "SELECT public.vista_dashboard('$UA')")
contiene "A1 vista_dashboard por TCP devuelve {nombre, balance_total, transacciones, cdts, creditos}" "$o" '"nombre": "Nombre1200".*"balance_total": [0-9]+'
contiene "A1 ...cdts {activos, generado} y creditos {cuota_por_pagar > 0 (hay un credito), interes_corriendo}" "$o" '"activos": 0.*"cuota_por_pagar": [1-9][0-9.]*'
eq "A1 ...y las 3 mas recientes son (de la mas reciente): desembolso, recibo de 40.000, envio de 250.000 con el nombre Y la cuenta de la contraparte" "CREDITO_DESEMBOLSO|RECIBO|ENVIO|Nombre1201 Apellido · 4000001201" "$(as banco_app $APP_PW "SELECT (public.vista_dashboard('$UA') -> 'transacciones' -> 0 ->> 'tipo_detalle') || '|' || (public.vista_dashboard('$UA') -> 'transacciones' -> 1 ->> 'tipo_detalle') || '|' || (public.vista_dashboard('$UA') -> 'transacciones' -> 2 ->> 'tipo_detalle') || '|' || (public.vista_dashboard('$UA') -> 'transacciones' -> 2 ->> 'contraparte')")"
o=$(as banco_app $APP_PW "SELECT public.vista_historial('$UA', 3)")
eq "A2 vista_historial por TCP con limite entero 3 devuelve 3 filas, la mas reciente primero (el desembolso del credito)" "3|CREDITO_DESEMBOLSO" "$(as banco_app $APP_PW "SELECT jsonb_array_length(public.vista_historial('$UA', 3)) || '|' || (public.vista_historial('$UA', 3) -> 0 ->> 'tipo_detalle')")"
eq "A2 ...limite 0, -5 y 1000 se acotan sin error: 1, 1 y todas (4: el ingreso inicial, 2 transferencias y el desembolso)" "1|1|4" "$(as banco_app $APP_PW "SELECT jsonb_array_length(public.vista_historial('$UA', 0)) || '|' || jsonb_array_length(public.vista_historial('$UA', -5)) || '|' || jsonb_array_length(public.vista_historial('$UA', 1000))")"
contiene "A3 la fecha sale con -05:00 aunque la conexion pida UTC (la zona la fija el codigo)" "$(PGOPTIONS='-c TimeZone=UTC' PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.vista_dashboard('$UA') -> 'transacciones' -> 0 ->> 'fecha'" 2>&1 </dev/null)" 'T[0-9:.]+-05:00$'
eq "A4 un cliente sin movimientos recibe [] en el historial y 0.00 en el dashboard" "[]|0.00" "$(as banco_app $APP_PW "SELECT public.vista_historial('$(root "SELECT tests.u(1206)")', 50)::text || '|' || (public.vista_dashboard('$(root "SELECT tests.u(1206)")') ->> 'balance_total')::numeric")"

# ============================================================================
# B. Permisos efectivos
# ============================================================================
eq "B1 banco_app ejecuta EXACTAMENTE vista_dashboard y vista_historial entre las funciones nuevas de E10 y NINGUNA de las 2 internas" "2|0" "$(root "SELECT count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE') AND p.proname IN ('vista_dashboard', 'vista_historial')) || '|' || count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE') AND p.proname IN ('_json_transacciones', '_reglas_historial')) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace")"
denegado "B2 banco_app NO lee la vista v_transaccion_usuario (miraria a todos los usuarios)" banco_app $APP_PW "SELECT count(*) FROM public.v_transaccion_usuario"
denegado "B2 banco_app tampoco lee el libro mayor" banco_app $APP_PW "SELECT count(*) FROM public.transaccion"
denegado "B3 banco_app NO ejecuta la interna _json_transacciones (leeria el historial de CUALQUIER cuenta)" banco_app $APP_PW "SELECT public._json_transacciones('$B', 50)"
denegado "B3 banco_app NO ejecuta _reglas_historial" banco_app $APP_PW "SELECT public._reglas_historial()"
denegado "B3 banco_lector NO ejecuta las publicas del cliente" banco_lector $LECTOR_PW "SELECT public.vista_dashboard('$UA')"
denegado "B3 banco_lector NO ejecuta _json_transacciones" banco_lector $LECTOR_PW "SELECT public._json_transacciones('$A', 5)"
eq "B4 banco_lector y banco_dev SI leen v_transaccion_usuario (consulta, JOIN para la defensa del proyecto): ven las filas de ambos clientes" "t|t" "$(as banco_lector $LECTOR_PW "SELECT (count(DISTINCT cuenta_id) >= 2)::text FROM public.v_transaccion_usuario WHERE cuenta_id IN ('$A', '$B')" | sed 's/true/t/')|$(as banco_dev $DEV_PW "SELECT (count(DISTINCT cuenta_id) >= 2)::text FROM public.v_transaccion_usuario WHERE cuenta_id IN ('$A', '$B')" | sed 's/true/t/')"
rechazado "B4 ...pero ninguno la modifica (la vista no es actualizable y banco_dev no tiene DELETE)" banco_dev $DEV_PW "DELETE FROM public.v_transaccion_usuario" "cannot delete|permission denied"
contiene "B5 banco_dev hereda de banco_app: ejecuta vista_dashboard" "$(as banco_dev $DEV_PW "SELECT public.vista_dashboard('$UA')")" '"nombre": "Nombre1200"'
eq "B6 aislamiento: NINGUNA fila del historial ni del dashboard de A pertenece a la cuenta de B (y viceversa)" "0|0" "$(root "SELECT count(*) FROM jsonb_array_elements(public.vista_historial('$UA', 50) || (public.vista_dashboard('$UA') -> 'transacciones')) e JOIN public.transaccion t ON t.id = (e ->> 'id')::uuid WHERE t.cuenta_id <> '$A'")|$(root "SELECT count(*) FROM jsonb_array_elements(public.vista_historial('$UB', 50)) e JOIN public.transaccion t ON t.id = (e ->> 'id')::uuid WHERE t.cuenta_id <> '$B'")"
rechazado "B7 el ADMIN llamando a las funciones del cliente: Acceso denegado (dashboard)" banco_app $APP_PW "SELECT public.vista_dashboard('$UADM')" "Acceso denegado"
rechazado "B7 ...y (historial)" banco_app $APP_PW "SELECT public.vista_historial('$UADM', 10)" "Acceso denegado"
root "UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = '$(root "SELECT tests.u(1202)")'" >/dev/null
rechazado "B8 usuario bloqueado con sesion abierta: el dashboard responde el mensaje de bloqueo EXACTO" banco_app $APP_PW "SELECT public.vista_dashboard('$(root "SELECT tests.u(1202)")')" "Tu cuenta ha sido restringida, contacte con el banco para desbloquearla"
rechazado "B8 ...y el historial" banco_app $APP_PW "SELECT public.vista_historial('$(root "SELECT tests.u(1202)")', 5)" "Tu cuenta ha sido restringida"
rechazado "B9 usuario inexistente: Sesion invalida (dashboard e historial)" banco_app $APP_PW "SELECT public.vista_dashboard(gen_random_uuid())" "Sesión inválida"
rechazado "B9 ...historial" banco_app $APP_PW "SELECT public.vista_historial(gen_random_uuid(), 5)" "Sesión inválida"
contiene "B10 el error de negocio llega con SQLSTATE P0001 (el backend lo convierte en 400)" "$(PGPASSWORD=$APP_PW psql -X -h "$HOST" -U banco_app -d "$DB" -v VERBOSITY=verbose -c "SELECT public.vista_dashboard(gen_random_uuid())" 2>&1 </dev/null)" 'P0001'

# ============================================================================
# C. Atomicidad: el dashboard dispara un cobro automatico (cuota vencida con mora)
# ============================================================================
U3=$(root "SELECT tests.u(1203)"); C3=$(root "SELECT tests.c(1203)")
as banco_app $APP_PW "SELECT public.solicitar_credito('$U3', '$PL', '3000000', 12)" >/dev/null
K3=$(root "SELECT id FROM public.credito WHERE cuenta_id = '$C3'"); root "UPDATE public.cuota SET fecha_vencimiento = public.hoy_banco() + 30 * numero WHERE credito_id = '$K3'" >/dev/null
as banco_app $APP_PW "SELECT public.activar_descuento_automatico('$U3', '$K3', true)" >/dev/null
root "SELECT public.hacer_transferencia('$U3', '$NA', $(sal $C3) - 100, 'gasto', NULL)" >/dev/null          # el cliente 1203 queda sin saldo con descuento activo
jump 40                                                                                     # la cuota 1 (dia 30) lleva 10 dias vencida: mora
root "SELECT public.hacer_transferencia('$UB', '$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = '$C3'")', 3000000, 'llega', NULL)" >/dev/null   # llega dinero por una operacion ajena: la primera ronda que lo ve es la de hoy
root "SELECT tests.instalar_fallas()" >/dev/null
HUE() { root "SELECT tests.huella_saldos()"; }
for p in tx:1 tx:2 tx:3 tx:4 tx:5 corte:2 corte:4; do
  H0=$(HUE)
  o=$(PGOPTIONS="-c tests.falla=$p" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.vista_dashboard('$U3')" 2>&1 </dev/null)
  case $p in corte:*) contiene "C1 corte [$p] a mitad del cobro disparado por el DASHBOARD: la conexion se cierra" "$o" 'terminating connection|server closed the connection|connection to server';;
             *) contiene "C1 falla inyectada [$p] en el cobro disparado por el dashboard (3 patas de cuota + 2 de mora): el error llega" "$o" 'FALLA INYECTADA';; esac
  eq "C1 ...[$p] NADA cambio: ni libro, ni saldos, ni cuotas pagadas, y el cursor sigue igual" "$H0|0" "$(HUE)|$(root "SELECT count(*) FROM public.cuota WHERE credito_id = '$K3' AND pagada")"
done
eq "C ...ninguna sesion de banco_app quedo colgada" "0" "$(root "SELECT count(*) FROM pg_stat_activity WHERE usename = 'banco_app' AND state <> 'idle' AND pid <> pg_backend_pid()")"
root "SELECT tests.quitar_fallas()" >/dev/null
o=$(as banco_app $APP_PW "SELECT public.vista_dashboard('$U3')")
eq "C2 sin fallas el dashboard cobra la cuota vencida UNA vez (con mora: 2 grupos) y la trae ya en sus ultimas transacciones" "1|2|CREDITO_MORA" "$(root "SELECT (SELECT count(*) FROM public.cuota WHERE credito_id = '$K3' AND pagada) || '|' || (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE credito_id = '$K3' AND tipo IN ('CREDITO_CUOTA', 'CREDITO_MORA')) || '|' || ('$o'::jsonb -> 'transacciones' -> 0 ->> 'tipo_detalle')")"
as banco_app $APP_PW "SELECT public.vista_dashboard('$U3')" >/dev/null; as banco_app $APP_PW "SELECT public.vista_historial('$U3', 50)" >/dev/null
eq "C2 ...y una segunda y tercera lectura no cobran nada mas" "1" "$(root "SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE credito_id = '$K3' AND tipo = 'CREDITO_CUOTA'")"

# ============================================================================
# D. Carreras por borrado: el usuario desaparece mientras la lectura espera el bloqueo del reloj
# ============================================================================
holder() { ( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT pg_sleep(2.5); $1 COMMIT;" > /tmp/c51_h.out 2>&1 </dev/null ) & sleep 1; }
U4=$(root "SELECT tests.u(1204)")
holder "DELETE FROM public.usuario WHERE id = '$U4';"
o=$(as banco_app $APP_PW "SELECT public.vista_dashboard('$U4')")
wait
contiene "D1 el usuario se borra mientras vista_dashboard espera: 'Sesión inválida' (P0001, nunca un error de FK ni un 503)" "$o" 'ERROR:  Sesión inválida'
U5=$(root "SELECT tests.u(1205)")
holder "DELETE FROM public.usuario WHERE id = '$U5';"
o=$(as banco_app $APP_PW "SELECT public.vista_historial('$U5', 20)")
wait
contiene "D2 el usuario se borra mientras vista_historial espera: 'Sesión inválida'" "$o" 'ERROR:  Sesión inválida'
eq "D3 integridad global y defensas en orden tras todo (incluida la defensa de la vista)" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
