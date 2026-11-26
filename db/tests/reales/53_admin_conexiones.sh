#!/bin/sh
# 53_admin_conexiones.sh - Etapa 11 - las 12 funciones admin_* con conexiones REALES (TCP + contrasena) de banco_app, banco_lector y banco_dev, SIN superusuario.
#   A. La conversacion del backend (los mismos nombres y argumentos que backend/src/routes/admin.ts de origin/main: ids como texto, busqueda '', monto numerico, fecha_sistema NULL,
#      las 3 tasas como texto) y la secuencia de PUT /admin/tasas = BEGIN, 3 llamadas, COMMIT / ROLLBACK sobre UNA conexion real.
#   B. Permisos EFECTIVOS: un cliente real con SU usuario_id llamando a CADA una de las 12 = Acceso denegado; un admin bloqueado; banco_lector no ejecuta; ninguna escritura directa.
#   C. Atomicidad: falla inyectada y CORTE de la conexion a mitad de un ajuste y de un borrado (en cada pata / en la cascada): no queda nada, ni evento.
#   D. CARRERAS por borrado: el usuario desaparece mientras el ajuste o el detalle esperan; un borrado espera a la operacion en vuelo del usuario; la operacion del usuario que llega despues recibe Sesion invalida.
# Termina SIEMPRE sin disparadores de inyeccion, sin definiciones de prueba, sin tasa de mora y en modo real.
. /work/tests/reales/lib.sh

restaurar() { wait; root "SELECT tests.quitar_fallas()" >/dev/null; root "DROP TRIGGER IF EXISTS trg_zz_falla_borrado ON public.cuenta" >/dev/null; root "DROP FUNCTION IF EXISTS tests.trg_falla_borrado()" >/dev/null
  root "DELETE FROM public.cdt_definicion WHERE nombre LIKE 'T53 %'" >/dev/null; root "DELETE FROM public.credito_producto WHERE nombre LIKE 'T53 %'" >/dev/null; root "UPDATE public.parametro SET tasa_mora_anual = NULL" >/dev/null
  root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c53_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
root "UPDATE public.parametro SET tasa_mora_anual = NULL" >/dev/null
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
U() { root "SELECT tests.u($1)"; }
HUE() { root "SELECT tests.huella_saldos()"; }
NEV() { root "SELECT count(*) FROM audit.evento"; }
CD=$(root "WITH x AS (INSERT INTO public.cdt_definicion (nombre, plazo_dias, tasa_anual, monto_min) VALUES ('T53 CDT', 30, 10, 1) RETURNING id) SELECT id FROM x")
CP=$(root "WITH x AS (INSERT INTO public.credito_producto (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES ('T53 Libre', '', 18, 1, 1000000000, 1, 360) RETURNING id) SELECT id FROM x")
# clientes 1400 (conversacion), 1401 (a bloquear), 1402 (a borrar), 1403 (ajustes), 1405 (atomicidad ajuste), 1406 (atomicidad borrado), 1407/1408 (carreras), 1409 (operacion en vuelo); admins 1410 (valido) y 1411 (bloqueado)
for n in 1400 1401 1402 1403 1405 1406 1407 1408 1409; do alta $n 5000000; done
root "INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol, estado) VALUES
  ('adm1410', 'h', 'Adm', 'Uno', '9301410', 'a1410@t.co', '3171410410', DATE '1980-01-01', 'ADMIN', 'ACTIVO'), ('adm1411', 'h', 'Adm', 'Dos', '9301411', 'a1411@t.co', '3171411411', DATE '1980-01-01', 'ADMIN', 'BLOQUEADO')" >/dev/null
ADM=$(root "SELECT id FROM public.usuario WHERE username = 'adm1410'"); ADB=$(root "SELECT id FROM public.usuario WHERE username = 'adm1411'")
UA=$(U 1400); UCLI=$(U 1403)

# ============================================================================
# A. La conversacion del backend
# ============================================================================
eq "A1 admin_listar_usuarios('<admin>', '') por TCP (busqueda vacia, como la manda el backend): trae a los clientes y NO a los admin" "t|f" "$(as banco_app $APP_PW "SELECT (public.admin_listar_usuarios('$ADM', '') @> jsonb_build_array(jsonb_build_object('username', 'cli1400', 'estado', 'ACTIVO')))::text || '|' || (public.admin_listar_usuarios('$ADM', '') @> jsonb_build_array(jsonb_build_object('username', 'adm1410')))::text" | sed 's/true/t/g; s/false/f/g')"
eq "A1 ...con busqueda por numero de cuenta devuelve exactamente 1 cliente" "1|cli1402" "$(as banco_app $APP_PW "SELECT jsonb_array_length(x) || '|' || (x -> 0 ->> 'username') FROM (SELECT public.admin_listar_usuarios('$ADM', '4000001402')) y(x)" 2>&1 | tail -1)"
eq "A2 admin_detalle_usuario('<admin>', '<id>') por TCP: {username, balance {total, principal, bolsillos, cdts, creditos}, historial}" "cli1400|array|array|array|5000000.00" "$(as banco_app $APP_PW "SELECT (d ->> 'username') || '|' || jsonb_typeof(d #> '{balance,bolsillos}') || '|' || jsonb_typeof(d #> '{balance,cdts}') || '|' || jsonb_typeof(d -> 'historial') || '|' || (d #>> '{balance,principal}') FROM (SELECT public.admin_detalle_usuario('$ADM', '$UA') AS d) x")"
o=$(as banco_app $APP_PW "SELECT public.admin_ajustar_balance('$ADM', '$UCLI', 250000.5, NULL)")
contiene "A3 admin_ajustar_balance con un monto numerico y nota NULL (el backend manda nota ?? null) devuelve {id, monto, fecha}" "$o" '"monto": 250000.5.*"fecha"|"fecha".*"monto": 250000.5'
eq "A3 ...con el monto como TEXTO ('-1000.25') y el destino como username: el saldo queda en 5249000.25" "5249000.25" "$(as banco_app $APP_PW "SELECT public.admin_ajustar_balance('$ADM', 'cli1403', '-1000.25', 'cobro')" >/dev/null; root "SELECT balance FROM public.cuenta WHERE id = tests.c(1403)")"
D1=$(root "SELECT to_char(public.hoy_banco() + 3, 'YYYY-MM-DD')")
eq "A4 admin_set_reloj por TCP: adelantar 3 dias devuelve la vista del contrato y volver a real con fecha_sistema NULL deja fecha_sistema null" "false|$D1|true|null" "$(as banco_app $APP_PW "SELECT (r ->> 'usar_fecha_real') || '|' || (r ->> 'fecha_sistema') FROM (SELECT public.admin_set_reloj('$ADM', false, '$D1') AS r) x")|$(as banco_app $APP_PW "SELECT (r ->> 'usar_fecha_real') || '|' || jsonb_typeof(r -> 'fecha_sistema') FROM (SELECT public.admin_set_reloj('$ADM', true, NULL) AS r) x")"
rechazado "A4 ...retroceder: El reloj no puede retroceder (400 en el backend)" banco_app $APP_PW "SELECT public.admin_set_reloj('$ADM', false, '2020-01-01')" "retroceder|Fecha"
eq "A5 admin_get_tasas por TCP: {cdts, creditos, mora} con la mora en 0 (sin valor)" "object|number|0" "$(as banco_app $APP_PW "SELECT jsonb_typeof(j) || '|' || jsonb_typeof(j -> 'mora') || '|' || (j ->> 'mora') FROM (SELECT public.admin_get_tasas('$ADM') AS j) x")"
# PUT /admin/tasas = db.tx: UNA conexion, BEGIN, las 3 llamadas (tasas como TEXTO), COMMIT
o=$(PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "BEGIN" -c "SELECT public.admin_set_tasa_cdt('$ADM', '$CD', '12.5')" -c "SELECT public.admin_set_tasa_credito('$ADM', '$CP', '19')" -c "SELECT public.admin_set_tasa_mora('$ADM', '30')" -c "COMMIT" 2>&1 </dev/null)
eq "A6 BEGIN; set_tasa_cdt; set_tasa_credito; set_tasa_mora; COMMIT (la secuencia de db.tx) sobre una conexion real: las 3 quedan y hay 3 eventos TASA_CAMBIO" "12.500|19.000|30.000|3" "$(root "SELECT (SELECT tasa_anual FROM public.cdt_definicion WHERE id = '$CD') || '|' || (SELECT tasa_anual FROM public.credito_producto WHERE id = '$CP') || '|' || (SELECT tasa_mora_anual FROM public.parametro) || '|' || (SELECT count(*) FROM audit.evento WHERE accion = 'TASA_CAMBIO' AND actor_username = 'adm1410')")"
E0=$(NEV)
o=$(PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "BEGIN" -c "SELECT public.admin_set_tasa_cdt('$ADM', '$CD', '40')" -c "SELECT public.admin_set_tasa_credito('$ADM', '$CP', 'abc')" -c "ROLLBACK" 2>&1 </dev/null)
contiene "A7 la 2a llamada es invalida: el error llega como P0001 'Tasa inválida' (400 en el backend)" "$o" 'ERROR:  Tasa inválida'
eq "A7 ...y tras el ROLLBACK que hace el backend NINGUNA tasa cambio y no quedo evento (todo o nada del formulario)" "12.500|19.000|30.000|$E0" "$(root "SELECT (SELECT tasa_anual FROM public.cdt_definicion WHERE id = '$CD') || '|' || (SELECT tasa_anual FROM public.credito_producto WHERE id = '$CP') || '|' || (SELECT tasa_mora_anual FROM public.parametro) || '|' || (SELECT count(*) FROM audit.evento)")"
as banco_app $APP_PW "SELECT public.admin_bloquear('$ADM', '$(U 1401)')" >/dev/null
r1=$(as banco_app $APP_PW "SELECT public.vista_balance('$(U 1401)')" | grep -o 'restringida' | head -1)
as banco_app $APP_PW "SELECT public.admin_desbloquear('$ADM', '$(U 1401)')" >/dev/null
eq "A8 bloquear / desbloquear por TCP: el bloqueado recibe el mensaje de bloqueo en su SIGUIENTE peticion y vuelve a operar al desbloquearlo" "restringida|ACTIVO" "$r1|$(as banco_app $APP_PW "SELECT public.validar_sesion('$(U 1401)') ->> 'estado'")"
eq "A9 admin_borrar_usuario por TCP: devuelve borrado y el usuario, su cuenta y sus movimientos ya no estan" "true|0|0" "$(as banco_app $APP_PW "SELECT public.admin_borrar_usuario('$ADM', '$(U 1402)') ->> 'borrado'")|$(root "SELECT count(*) FROM public.usuario WHERE username = 'cli1402'")|$(root "SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(1402)")"

# ============================================================================
# B. Permisos efectivos
# ============================================================================
eq "B1 banco_app ejecuta EXACTAMENTE las 14 admin_* (12 de E11 + 2 de E12) y NINGUNA de las 4 internas de E11" "14|0" "$(root "SELECT count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE') AND p.proname LIKE 'admin\_%') || '|' || count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE') AND p.proname IN ('_reglas_admin', '_parse_tasa', '_cliente_objetivo', '_auditar_admin')) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace")"
FNS="admin_listar_usuarios|, NULL
admin_detalle_usuario|, 'x'
admin_bloquear|, 'x'
admin_desbloquear|, 'x'
admin_borrar_usuario|, 'x'
admin_ajustar_balance|, 'x', 1
admin_get_reloj|
admin_set_reloj|, true, NULL
admin_get_tasas|
admin_set_tasa_cdt|, 'x', '10'
admin_set_tasa_credito|, 'x', '10'
admin_set_tasa_mora|, '10'"
H0=$(HUE); E0=$(NEV); n1=0; n2=0; n3=0
IFS='
'
for l in $FNS; do
  f=${l%%|*}; ex=${l#*|}
  as banco_app $APP_PW "SELECT public.$f('$UA'$ex)" 2>&1 | grep -q 'ERROR:  Acceso denegado' && n1=$((n1+1))
  as banco_app $APP_PW "SELECT public.$f('$ADB'$ex)" 2>&1 | grep -q 'restringida' && n2=$((n2+1))
  as banco_app $APP_PW "SELECT public.$f(gen_random_uuid()$ex)" 2>&1 | grep -q 'ERROR:  Acceso denegado' && n3=$((n3+1))
done
unset IFS
eq "B2 un CLIENTE REAL con SU usuario_id llamando a CADA una de las 12 funciones admin_*: las 12 responden Acceso denegado" "12" "$n1"
eq "B2 ...un ADMIN BLOQUEADO: las 12 responden el mensaje de bloqueo" "12" "$n2"
eq "B2 ...un uuid desconocido: las 12 responden Acceso denegado" "12" "$n3"
eq "B2 ...y esos 36 rechazos no cambiaron NADA (saldos ni auditoria)" "$H0|$E0" "$(HUE)|$(NEV)"
denegado "B3 banco_lector NO ejecuta las admin_*" banco_lector $LECTOR_PW "SELECT public.admin_get_reloj('$ADM')"
denegado "B3 banco_lector NO ejecuta ni los helpers" banco_lector $LECTOR_PW "SELECT public._parse_tasa('10', false)"
denegado "B3 banco_app NO ejecuta los helpers (_reglas_admin)" banco_app $APP_PW "SELECT public._reglas_admin()"
denegado "B3 banco_app NO ejecuta _auditar_admin (no puede escribir eventos a su gusto)" banco_app $APP_PW "SELECT public._auditar_admin(NULL, 'X', 'x', 'x', NULL, NULL)"
contiene "B4 banco_dev hereda de banco_app: ejecuta las admin_*" "$(as banco_dev $DEV_PW "SELECT public.admin_get_reloj('$ADM')")" '"usar_fecha_real"'
denegado "B5 banco_app NO modifica usuarios directamente (bloquear a mano)" banco_app $APP_PW "UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE username = 'cli1400'"
denegado "B5 banco_app NO borra usuarios directamente" banco_app $APP_PW "DELETE FROM public.usuario WHERE username = 'cli1400'"
denegado "B5 banco_app NO cambia tasas directamente" banco_app $APP_PW "UPDATE public.cdt_definicion SET tasa_anual = 99"
denegado "B5 banco_app NO toca el reloj directamente" banco_app $APP_PW "UPDATE public.reloj SET usar_fecha_real = false"
denegado "B5 banco_app NO escribe en audit.evento" banco_app $APP_PW "INSERT INTO audit.evento (accion) VALUES ('FALSO')"
rechazado "B5 banco_lector NO borra la auditoria (solo lectura: sesion read-only y sin DELETE)" banco_lector $LECTOR_PW "DELETE FROM audit.evento" "read-only transaction|permission denied"
eq "B6 banco_lector SI puede LEER la auditoria de lo que hizo el admin (consulta y defensa)" "t" "$(as banco_lector $LECTOR_PW "SELECT (count(*) FILTER (WHERE accion = 'AJUSTE_ADMIN') >= 2 AND count(*) FILTER (WHERE accion = 'USUARIO_BORRADO' AND actor_username = 'adm1410') >= 1)::text FROM audit.evento" | sed 's/true/t/')"
contiene "B7 un error de negocio de admin llega con SQLSTATE P0001 (el backend lo convierte en 400)" "$(PGPASSWORD=$APP_PW psql -X -h "$HOST" -U banco_app -d "$DB" -v VERBOSITY=verbose -c "SELECT public.admin_bloquear('$ADM', 'no-es-un-uuid')" 2>&1 </dev/null)" 'P0001'
eq "B8 el ajuste a un id que es un ADMIN, a uno mismo o a un desconocido = Recurso no encontrado (nunca un error de driver)" "3" "$(for r in "$ADB" "$ADM" "00000000-0000-4000-8000-000000000999"; do as banco_app $APP_PW "SELECT public.admin_ajustar_balance('$ADM', '$r', 10, NULL)" 2>&1 | grep -c 'ERROR:  Recurso no encontrado'; done | awk '{n+=$1} END {print n}')"

# ============================================================================
# C. Atomicidad: falla inyectada y corte a mitad de un ajuste y de un borrado
# ============================================================================
U5=$(U 1405); root "SELECT tests.instalar_fallas()" >/dev/null
for p in tx:1 tx:2 corte:1 corte:2; do
  H0=$(HUE); E0=$(NEV)
  o=$(PGOPTIONS="-c tests.falla=$p" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.admin_ajustar_balance('$ADM', '$U5', 1000, 'x')" 2>&1 </dev/null)
  case $p in corte:*) contiene "C1 corte [$p] a mitad de admin_ajustar_balance: la conexion se cierra" "$o" 'terminating connection|server closed the connection|connection to server';;
             *) contiene "C1 falla inyectada [$p] en una pata del ajuste: el error llega" "$o" 'FALLA INYECTADA';; esac
  eq "C1 ...[$p] NADA cambio: ni libro, ni saldos, ni evento de auditoria" "$H0|$E0" "$(HUE)|$(NEV)"
done
eq "C1 ...ninguna sesion de banco_app quedo colgada" "0" "$(root "SELECT count(*) FROM pg_stat_activity WHERE usename = 'banco_app' AND state <> 'idle' AND pid <> pg_backend_pid()")"
root "SELECT tests.quitar_fallas()" >/dev/null
as banco_app $APP_PW "SELECT public.admin_ajustar_balance('$ADM', '$U5', 1000, 'x')" >/dev/null
eq "C1 sin fallas el mismo ajuste se aplica una vez: saldo +1000 y UN evento AJUSTE_ADMIN de esa cuenta" "5001000.00|1" "$(root "SELECT balance FROM public.cuenta WHERE id = tests.c(1405)")|$(root "SELECT count(*) FROM audit.evento WHERE accion = 'AJUSTE_ADMIN' AND entidad_id = tests.c(1405)::text")"
cat > /tmp/c53_trg.sql <<'EOF'
CREATE OR REPLACE FUNCTION tests.trg_falla_borrado() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
BEGIN
  IF current_setting('tests.falla_borrado', true) = '1' THEN RAISE EXCEPTION 'FALLA INYECTADA en el borrado de la cuenta' USING ERRCODE = 'P0001'; END IF;
  IF current_setting('tests.falla_borrado', true) = 'corte' THEN PERFORM pg_terminate_backend(pg_backend_pid()); PERFORM pg_sleep(5); END IF;
  RETURN OLD;
END $f$;
DROP TRIGGER IF EXISTS trg_zz_falla_borrado ON public.cuenta;
CREATE TRIGGER trg_zz_falla_borrado BEFORE DELETE ON public.cuenta FOR EACH ROW EXECUTE FUNCTION tests.trg_falla_borrado();
EOF
psql -X -q -U postgres -d "$DB" -f /tmp/c53_trg.sql >/dev/null 2>&1 </dev/null
U6=$(U 1406)
for m in 1 corte; do
  H0=$(HUE); E0=$(NEV)
  o=$(PGOPTIONS="-c tests.falla_borrado=$m" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.admin_borrar_usuario('$ADM', '$U6')" 2>&1 </dev/null)
  case $m in corte) contiene "C2 corte de la conexion DURANTE la cascada del borrado: la conexion se cierra" "$o" 'terminating connection|server closed the connection|connection to server';;
             *) contiene "C2 falla inyectada DURANTE la cascada del borrado: el error llega" "$o" 'FALLA INYECTADA';; esac
  eq "C2 ...[$m] el usuario y su cuenta SIGUEN ahi y no quedo ningun evento (ni USUARIO_BORRADO, que se escribe antes del borrado)" "1|1|$H0|$E0" "$(root "SELECT count(*) FROM public.usuario WHERE id = '$U6'")|$(root "SELECT count(*) FROM public.cuenta WHERE id = tests.c(1406)")|$(HUE)|$(NEV)"
done
root "DROP TRIGGER trg_zz_falla_borrado ON public.cuenta" >/dev/null
eq "C2 sin fallas el borrado se completa: usuario fuera y sus 2 eventos (USUARIO_BORRADO y CUENTA_BORRADA) atribuidos a adm1410" "true|0|1|1" "$(as banco_app $APP_PW "SELECT public.admin_borrar_usuario('$ADM', '$U6') ->> 'borrado'")|$(root "SELECT count(*) FROM public.usuario WHERE id = '$U6'")|$(root "SELECT count(*) FROM audit.evento WHERE accion = 'USUARIO_BORRADO' AND entidad_id = '$U6' AND actor_username = 'adm1410'")|$(root "SELECT count(*) FROM audit.evento WHERE accion = 'CUENTA_BORRADA' AND entidad_id = tests.c(1406)::text AND actor_username = 'adm1410'")"

# ============================================================================
# D. Carreras por borrado
# ============================================================================
holder() { ( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT pg_sleep(2.5); $1 COMMIT;" > /tmp/c53_h.out 2>&1 </dev/null ) & sleep 1; }
U7=$(U 1407)
holder "DELETE FROM public.usuario WHERE id = '$U7';"
o=$(as banco_app $APP_PW "SELECT public.admin_ajustar_balance('$ADM', '$U7', 500, 'carrera')")
wait
contiene "D1 el usuario se borra mientras admin_ajustar_balance espera el reloj: 'Recurso no encontrado' (P0001, nunca un error de FK ni un 503)" "$o" 'ERROR:  Recurso no encontrado'
eq "D1 ...y no queda ningun evento de ajuste de ese usuario" "0" "$(root "SELECT count(*) FROM audit.evento WHERE accion = 'AJUSTE_ADMIN' AND entidad_id = tests.c(1407)::text")"
U8=$(U 1408)
holder "DELETE FROM public.usuario WHERE id = '$U8';"
o=$(as banco_app $APP_PW "SELECT public.admin_detalle_usuario('$ADM', '$U8')")
wait
contiene "D2 el usuario se borra mientras admin_detalle_usuario espera: 'Recurso no encontrado'" "$o" 'ERROR:  Recurso no encontrado'
# una operacion del usuario EN VUELO (mantiene el bloqueo de su cuenta) y el admin lo borra: el borrado ESPERA y completa
U9=$(U 1409)
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.cuenta WHERE id = tests.c(1409) FOR NO KEY UPDATE; SELECT pg_sleep(2.5); COMMIT;" > /tmp/c53_h2.out 2>&1 </dev/null ) & sleep 1
T0=$(date +%s)
o=$(as banco_app $APP_PW "SELECT public.admin_borrar_usuario('$ADM', '$U9') ->> 'borrado'")
T1=$(date +%s)
wait
eq "D3 el borrado de un usuario con una operacion en vuelo ESPERA a que termine (>= 1 s) y despues se completa" "true|t|0" "$o|$([ $((T1 - T0)) -ge 1 ] && echo t || echo f)|$(root "SELECT count(*) FROM public.usuario WHERE id = '$U9'")"
# el borrado va primero (dentro de una transaccion que tarda) y la operacion del usuario llega despues: Sesion invalida
alta 1412 5000000; alta 1413 5000000; U12=$(U 1412); N13=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(1413)")
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT public.admin_borrar_usuario('$ADM', '$U12'); SELECT pg_sleep(2.5); COMMIT;" > /tmp/c53_h3.out 2>&1 </dev/null ) & sleep 1
o=$(as banco_app $APP_PW "SELECT public.hacer_transferencia('$U12', '$N13', 1000, 'x', NULL)")
wait
contiene "D4 la transferencia del usuario que el admin esta borrando espera su bloqueo y, al terminar el borrado, recibe 'Sesión inválida' (no un error de FK)" "$o" 'ERROR:  Sesión inválida'
eq "D5 integridad global y defensas en orden tras todo (conservacion con los borrados incluidos)" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
