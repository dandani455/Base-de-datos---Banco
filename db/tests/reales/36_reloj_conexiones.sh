#!/bin/sh
# 36_reloj_conexiones.sh - Etapa 3 - el reloj visto por conexiones REALES (TCP + contrasena) de banco_app, banco_lector y banco_dev.
# banco_app solo llega al reloj por funciones definer (aqui, las del arnes que imitan a las futuras admin_*): no lee ni toca la tabla,
# no ejecuta las funciones internas ni hoy_banco() directamente. banco_lector/banco_dev leen el reloj y hoy_banco()/ahora_banco() pero no lo cambian.
# La fecha del banco NO depende de la TimeZone de la conexion. Al terminar (aunque falle algo) se deja el reloj en modo real.
. /work/tests/reales/lib.sh

restaurar() { root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; }
trap restaurar EXIT
restaurar

R=$(root "SELECT (now() AT TIME ZONE 'America/Bogota')::date")
root "SELECT tests.cliente(401); SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c(401), 10))" >/dev/null      # banco no vacio: rige la regla completa
eq "el banco tiene patas (la regla de no retroceso aplica)" "t" "$(root "SELECT EXISTS (SELECT 1 FROM public.transaccion)")"

# --- 1. banco_app: nada directo sobre el reloj ----------------------------------------------------------------------------
denegado "banco_app NO puede leer la tabla reloj"                 banco_app $APP_PW "SELECT * FROM public.reloj"
denegado "banco_app NO puede actualizar la tabla reloj"           banco_app $APP_PW "UPDATE public.reloj SET usar_fecha_real = false, fecha_sistema = DATE '2099-01-01'"
denegado "banco_app NO puede volver a fecha real por UPDATE"      banco_app $APP_PW "UPDATE public.reloj SET usar_fecha_real = true"
denegado "banco_app NO puede borrar el reloj"                     banco_app $APP_PW "DELETE FROM public.reloj"
denegado "banco_app NO puede vaciar el reloj"                     banco_app $APP_PW "TRUNCATE public.reloj"
denegado "banco_app NO puede insertar en el reloj"                banco_app $APP_PW "INSERT INTO public.reloj (id, usar_fecha_real) VALUES (2, true)"
denegado "banco_app NO puede leer v_reloj_estado"                 banco_app $APP_PW "SELECT * FROM public.v_reloj_estado"
denegado "banco_app NO ejecuta hoy_banco() directamente"          banco_app $APP_PW "SELECT public.hoy_banco()"
denegado "banco_app NO ejecuta ahora_banco() directamente"        banco_app $APP_PW "SELECT public.ahora_banco()"
denegado "banco_app NO ejecuta _reloj_actualizar"                 banco_app $APP_PW "SELECT public._reloj_actualizar(false, '2099-01-01')"
denegado "banco_app NO ejecuta _reloj_instantanea"                banco_app $APP_PW "SELECT * FROM public._reloj_instantanea()"
denegado "banco_app NO ejecuta _reloj_vista"                      banco_app $APP_PW "SELECT public._reloj_vista()"
denegado "banco_app NO ejecuta _ahora_real"                       banco_app $APP_PW "SELECT public._ahora_real()"
denegado "banco_app NO ejecuta las funciones del trigger del reloj" banco_app $APP_PW "SELECT public.trg_reloj_a_validar()"
denegado "banco_app NO puede apagar los triggers del reloj"       banco_app $APP_PW "ALTER TABLE public.reloj DISABLE TRIGGER ALL"
denegado "banco_app NO puede cambiar la restriccion de rango"     banco_app $APP_PW "ALTER TABLE public.reloj DROP CONSTRAINT ck_reloj_fecha_rango"
eq "tras todos esos intentos el reloj sigue en modo real" "true|" "$(root "SELECT usar_fecha_real || '|' || coalesce(fecha_sistema::text, '') FROM public.reloj")"

# --- 2. El camino legitimo: funcion definer (imita admin_set_reloj) ------------------------------------------------------
eq "banco_app via funcion definer: lee el hoy del banco (fecha de Colombia)" "$R" "$(as banco_app $APP_PW "SELECT tests.app_hoy()")"
o=$(as banco_app $APP_PW "SELECT tests.app_reloj(false, to_char(DATE '$R' + 10, 'YYYY-MM-DD'))")
contiene "banco_app via definer: adelantar 10 dias devuelve el contrato (usar_fecha_real=false, fecha_sistema)" "$o" '"usar_fecha_real": false'
contiene "...con fecha_actual = R+10" "$o" "\"fecha_actual\": \"$(root "SELECT DATE '$R' + 10")\""
eq "...y el hoy del banco es R+10" "$(root "SELECT DATE '$R' + 10")" "$(as banco_app $APP_PW "SELECT tests.app_hoy()")"
rechazado "retroceder a R+5 desde R+10 se rechaza con el mensaje exacto" banco_app $APP_PW "SELECT tests.app_reloj(false, to_char(DATE '$R' + 5, 'YYYY-MM-DD'))" "El reloj no puede retroceder"
eq "...y el hoy sigue siendo R+10" "$(root "SELECT DATE '$R' + 10")" "$(as banco_app $APP_PW "SELECT tests.app_hoy()")"
rechazado "una fecha mal formada se rechaza con 'Fecha inválida'" banco_app $APP_PW "SELECT tests.app_reloj(false, '2026-13-45')" "Fecha inv"
rechazado "una fecha vacia en modo manual se rechaza con 'Fecha inválida'" banco_app $APP_PW "SELECT tests.app_reloj(false, '')" "Fecha inv"
rechazado "una fecha de texto libre se rechaza (no llega un 503 por 22007)" banco_app $APP_PW "SELECT tests.app_reloj(false, 'manana')" "Fecha inv"
rechazado "usar_fecha_real nulo se rechaza" banco_app $APP_PW "SELECT tests.app_reloj(NULL, '')" "obligatorio"
o=$(as banco_app $APP_PW "SELECT tests.app_reloj(true, '')")
contiene "volver a fecha real (retrocede de R+10 a R): permitido, devuelve fecha_sistema null" "$o" '"fecha_sistema": null'
eq "...el hoy del banco vuelve a ser R (la simulacion no es contablemente reversible, pero el reloj si vuelve)" "$R" "$(as banco_app $APP_PW "SELECT tests.app_hoy()")"
eq "...y no queda fecha guardada ni desfase" "true|" "$(root "SELECT usar_fecha_real || '|' || coalesce(fecha_sistema::text, '') FROM public.reloj")"

# --- 3. La fecha del banco NO depende de la TimeZone de la conexion --------------------------------------------------------
for z in UTC Asia/Tokyo America/Los_Angeles Pacific/Kiritimati Pacific/Pago_Pago America/Bogota; do
  o=$(PGOPTIONS="-c TimeZone=$z" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT tests.app_hoy()" 2>&1 </dev/null)
  eq "TimeZone de la conexion = $z: el hoy del banco sigue siendo el de Colombia" "$R" "$o"
done
root "SELECT public._reloj_actualizar(false, to_char(DATE '$R' + 3, 'YYYY-MM-DD'))" >/dev/null
o=$(PGOPTIONS="-c TimeZone=Pacific/Kiritimati" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT tests.app_hoy()" 2>&1 </dev/null)
eq "modo manual R+3 con TimeZone=Kiritimati: el hoy es R+3 (no depende de la zona)" "$(root "SELECT DATE '$R' + 3")" "$o"
restaurar

# --- 4. banco_lector y banco_dev: leen, no cambian --------------------------------------------------------------------------
for rol in banco_lector:$LECTOR_PW banco_dev:$DEV_PW; do
  U=${rol%%:*}; P=${rol#*:}
  eq "$U: lee la tabla reloj (modo real, sin fecha guardada)" "true|" "$(as $U $P "SELECT usar_fecha_real || '|' || coalesce(fecha_sistema::text, '') FROM public.reloj")"
  eq "$U: hoy_banco() es la fecha de Colombia" "$R" "$(as $U $P "SELECT public.hoy_banco()")"
  contiene "$U: ahora_banco() devuelve un instante" "$(as $U $P "SELECT public.ahora_banco()")" '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}'
  eq "$U: v_reloj_estado informa modo real y hoy" "true|$R" "$(as $U $P "SELECT usar_fecha_real || '|' || hoy_banco FROM public.v_reloj_estado")"
  denegado "$U NO puede actualizar el reloj"                $U $P "BEGIN READ WRITE; UPDATE public.reloj SET usar_fecha_real = false, fecha_sistema = DATE '2099-01-01'; COMMIT;"
  denegado "$U NO puede volver a real por UPDATE"           $U $P "BEGIN READ WRITE; UPDATE public.reloj SET usar_fecha_real = true; COMMIT;"
  denegado "$U NO puede borrar ni vaciar el reloj"          $U $P "BEGIN READ WRITE; DELETE FROM public.reloj; COMMIT;"
  denegado "$U NO ejecuta _reloj_actualizar"                $U $P "SELECT public._reloj_actualizar(false, '2099-01-01')"
  denegado "$U NO ejecuta _reloj_instantanea"               $U $P "SELECT * FROM public._reloj_instantanea()"
  denegado "$U NO ejecuta _ahora_real"                      $U $P "SELECT public._ahora_real()"
  denegado "$U NO puede apagar los triggers del reloj"      $U $P "BEGIN READ WRITE; ALTER TABLE public.reloj DISABLE TRIGGER ALL; COMMIT;"
done
eq "tras los intentos de lector y dev el reloj sigue en modo real sin fecha" "true|" "$(root "SELECT usar_fecha_real || '|' || coalesce(fecha_sistema::text, '') FROM public.reloj")"

# --- 5. Una operacion real fechada con el reloj del banco entra; una fechada en el futuro se rechaza (via definer) ----------
root "SELECT public._reloj_actualizar(false, to_char(DATE '$R' + 20, 'YYYY-MM-DD'))" >/dev/null
A=$(root "SELECT tests.c(401)")
o=$(as banco_app $APP_PW "SELECT tests.app_fondear_banco('$A', 5)")
contiene "con el reloj en R+20: una operacion de banco_app (fechada con ahora_banco()) se acepta" "$o" '^[0-9a-f-]{36}$'
eq "...la pata quedo fechada en R+20 y registrada hoy (hora real)" "(t,t)" \
   "$(root "SELECT ((fecha AT TIME ZONE 'America/Bogota')::date = DATE '$R' + 20, (registrado_en AT TIME ZONE 'America/Bogota')::date = DATE '$R')::text FROM public.transaccion WHERE cuenta_id = '$A' AND monto = 5 AND contenedor = 'CUENTA' ORDER BY orden DESC LIMIT 1")"
restaurar
eq "de vuelta a real: la pata de R+20 permanece en el libro (no se revierte)" "1" "$(root "SELECT count(*) FROM public.transaccion WHERE cuenta_id = '$A' AND monto = 5 AND contenedor = 'CUENTA'")"
eq "...se cuenta como pata fechada en el futuro (informativo)" "t" "$(root "SELECT patas_fechadas_en_el_futuro >= 1 FROM public.v_reloj_estado")"
eq "...y la integridad global sigue en orden" "t" "$(root "SELECT ok FROM public.v_integridad_global")"
o=$(root "SELECT public._asentar_grupo(((DATE '$R' + 20)::timestamp + time '12:00') AT TIME ZONE 'America/Bogota', tests.g_ingreso('$A', 7))")
contiene "una operacion NUEVA fechada en R+20 ya no entra (el hoy real es R)" "$o" "posterior al reloj del banco"

# --- 6. Auditoria: cada cambio efectivo quedo registrado ---------------------------------------------------------------------
eq "la auditoria registro cambios de reloj (RELOJ_CAMBIO)" "t" "$(root "SELECT count(*) >= 4 FROM audit.evento WHERE accion = 'RELOJ_CAMBIO'")"
eq "...y ninguno es un cambio manual->manual hacia atras" "0" \
   "$(root "SELECT count(*) FROM audit.evento WHERE accion='RELOJ_CAMBIO' AND (antes->>'usar_fecha_real')::boolean = false AND (despues->>'usar_fecha_real')::boolean = false AND (despues->>'fecha_sistema')::date < (antes->>'fecha_sistema')::date")"

eq "al final el reloj esta en modo real y las vistas de integridad en orden" "true|true" "$(root "SELECT (usar_fecha_real AND fecha_sistema IS NULL) || '|' || (SELECT ok FROM public.v_integridad_global) FROM public.reloj")"
fin
