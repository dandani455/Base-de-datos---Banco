#!/bin/sh
# 39_auth_conexiones.sh - Etapa 4 - autenticacion y registro con conexiones REALES (TCP + contrasena) de banco_app, banco_lector y banco_dev.
#   A. Conversacion completa del backend: registro, login (credenciales -> bcrypt en el backend -> validar_sesion), bloqueo con sesion abierta, perfil, verificacion.
#   B. Permisos EFECTIVOS: banco_app solo funciones (ni tablas, ni internas, ni SET ROLE); lector sin funciones; dev hereda de app.
#   C. Atomicidad sobre el estado CONFIRMADO: fallos inyectados en cada pata del libro (incluso tras escribir saldos) y CORTE de la conexion a mitad del registro.
#   D. Medianoche (tiempo inyectado SOLO en banco_test/banco_mut): un registro que empieza antes de medianoche y obtiene el bloqueo del reloj despues ve el dia nuevo.
# Termina SIEMPRE: sin disparadores de inyeccion, con la _ahora_real() original, en modo real.
. /work/tests/reales/lib.sh
HASH='$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy'

ORIG=$(root "SELECT pg_get_functiondef('public._ahora_real()'::regprocedure)")
limpiar() {
  wait
  root "SELECT tests.quitar_fallas()" >/dev/null
  root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
  root "$ORIG" >/dev/null
  root "DROP TABLE IF EXISTS tests.reloj_falso" >/dev/null
  rm -f /tmp/c39_*
}
trap limpiar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null

# reg N NOMBRES APELLIDOS REF(literal SQL) VERIF [PGOPTIONS]  (6 argumentos como maximo)  ->  salida de psql
reg() {
  PGOPTIONS="${6:-}" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" \
    -c "SELECT public.registrar_usuario('$2', '$3', '8$(printf %08d $1)', 'reg$1@mail.co', '31$(printf %08d $1)', '1990-05-17', '$HASH', true, $4, $5)" 2>&1 </dev/null
}
campo_json() { echo "$1" | sed -n "s/.*\"$2\": \"\([^\"]*\)\".*/\1/p"; }
huella() { root "SELECT tests.huella_registro()"; }
R=$(root "SELECT (now() AT TIME ZONE 'America/Bogota')::date")

# ============================================================================
# A. La conversacion completa del backend con banco_app
# ============================================================================
eq "banco_app: conexion real, NO superusuario" "banco_app|off" "$(as banco_app $APP_PW "SELECT current_user || '|' || current_setting('is_superuser')")"
o=$(reg 1 'María del Pilar' 'Núñez Pérez' NULL true)
USR=$(campo_json "$o" username); UID1=$(campo_json "$o" usuario_id)
contiene "A1 registrar_usuario por TCP devuelve {usuario_id, username} (jsonb)" "$o" '^\{"username": "mnunez[0-9]{3,4}", "usuario_id": "[0-9a-f-]{36}"\}$'
eq "A1 ...el usuario existe en la base, su cuenta tiene 5 grupos de ingreso y el balance es la suma" "5|true" \
   "$(root "SELECT (SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE cuenta_id = c.id) || '|' || (c.balance = (SELECT sum(monto) FROM public.transaccion WHERE cuenta_id = c.id AND contenedor = 'CUENTA')) FROM public.cuenta c WHERE c.usuario_id = '$UID1'")"
# login paso 1: credenciales (el backend compara bcrypt con el hash y luego llama validar_sesion)
o=$(as banco_app $APP_PW "SELECT * FROM public.obtener_credenciales('  $USR  ')")
eq "A2 obtener_credenciales por TCP: usuario_id|hash|rol|estado" "$UID1|$HASH|CLIENTE|ACTIVO" "$o"
eq "A2 ...un usuario inexistente da 0 filas (salida vacia, sin error)" "" "$(as banco_app $APP_PW "SELECT * FROM public.obtener_credenciales('nadie999')")"
# login paso 3 y cada peticion: validar_sesion
o=$(as banco_app $APP_PW "SELECT public.validar_sesion('$UID1')")
contiene "A3 validar_sesion por TCP: {username, rol CLIENTE, estado ACTIVO}" "$o" "\"username\": \"$USR\".*\"rol\": \"CLIENTE\"|\"rol\": \"CLIENTE\".*\"username\": \"$USR\""
# bloqueo con "sesion abierta": la siguiente peticion recibe el mensaje exacto y desbloquear lo repara, sin reiniciar nada
root "UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = '$UID1'" >/dev/null
rechazado "A4 sesion abierta + bloqueo: la SIGUIENTE peticion recibe el mensaje de bloqueo EXACTO" banco_app $APP_PW "SELECT public.validar_sesion('$UID1')" "Tu cuenta ha sido restringida, contacte con el banco para desbloquearla"
rechazado "A4 ...tambien el perfil" banco_app $APP_PW "SELECT public.vista_perfil('$UID1')" "Tu cuenta ha sido restringida"
eq "A4 ...pero obtener_credenciales sigue entregando al bloqueado (el backend compara bcrypt ANTES de validar_sesion)" "$UID1|$HASH|CLIENTE|BLOQUEADO" "$(as banco_app $APP_PW "SELECT * FROM public.obtener_credenciales('$USR')")"
root "UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = '$UID1'" >/dev/null
contiene "A4 ...al desbloquear vuelve a funcionar" "$(as banco_app $APP_PW "SELECT public.validar_sesion('$UID1')")" '"estado": "ACTIVO"'
# perfil
o=$(as banco_app $APP_PW "SELECT public.vista_perfil('$UID1')")
contiene "A5 vista_perfil: {username, numero_cuenta de 10 digitos, codigo_referido uuid}" "$o" '"numero_cuenta": "40[0-9]{8}"'
contiene "A5 ...con el codigo de referido (uuid)" "$o" '"codigo_referido": "[0-9a-f-]{36}"'
eq "A5 ...exactamente 3 claves (nada financiero)" "3" "$(root "SELECT count(*) FROM jsonb_object_keys('$o'::jsonb)")"
# registro con referido (verificacion encendida) y verificacion del correo
COD=$(root "SELECT codigo_referido FROM public.usuario WHERE id = '$UID1'")
S0=$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$UID1'")
o=$(reg 2 'Carlos' 'Ruiz' "'$COD'" true); UID2=$(campo_json "$o" usuario_id)
eq "A6 registro con referido y verificacion ENCENDIDA: no paga" "$S0" "$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$UID1'")"
as banco_app $APP_PW "SELECT public.verificar_correo('$UID2')" >/dev/null
eq "A6 verificar_correo por TCP: el referidor recibe 50000" "$(root "SELECT $S0 + 50000")" "$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$UID1'")"
as banco_app $APP_PW "SELECT public.verificar_correo('$UID2')" >/dev/null
eq "A6 ...una segunda verificacion no paga otra vez" "$(root "SELECT $S0 + 50000")" "$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$UID1'")"
o=$(reg 3 'Diana' 'Vega' "'$COD'" false); UID3=$(campo_json "$o" usuario_id)
eq "A7 registro con referido y verificacion APAGADA: el bono se paga al registrar (+50000 mas)" "$(root "SELECT $S0 + 100000")" "$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$UID1'")"

# errores de negocio por TCP: P0001 con el mensaje exacto y sin rastro
rechazado "A8 politica no aceptada (contrato §6)" banco_app $APP_PW "SELECT public.registrar_usuario('A','B','1234567','a@b.co','3000000000','1990-01-01','$HASH',false,NULL,true)" "Debe aceptar la política de datos"
rechazado "A8 hash en claro: la BD lo rechaza" banco_app $APP_PW "SELECT public.registrar_usuario('Ana','Bo','1234567','a@b.co','3000000000','1990-01-01','Banco2026',true,NULL,true)" "Datos de registro inválidos"
rechazado "A8 codigo de referido malformado = error de NEGOCIO (no un 503 por uuid invalido del driver)" banco_app $APP_PW "SELECT public.registrar_usuario('Ana','Bo','1234567','a@b.co','3000000000','1990-01-01','$HASH',true,'no-es-un-uuid',true)" "Código de referido inválido"
rechazado "A8 fecha de nacimiento imposible = error de negocio (no 22007 del driver)" banco_app $APP_PW "SELECT public.registrar_usuario('Ana','Bo','1234567','a@b.co','3000000000','1990-02-30','$HASH',true,NULL,true)" "Fecha de nacimiento inválida"
rechazado "A8 cedula duplicada" banco_app $APP_PW "SELECT public.registrar_usuario('Ana','Bo','8$(printf %08d 1)','otro@b.co','3000000000','1990-01-01','$HASH',true,NULL,true)" "La cédula ya está registrada"
o=$(as banco_app $APP_PW "SELECT public.registrar_usuario('Ana','Bo','1234567','a@b.co','3000000000','1990-01-01','$HASH',false,NULL,true)")
contiene "A8 ...el error llega con SQLSTATE P0001 (lo que el backend convierte en 400)" "$(PGPASSWORD=$APP_PW psql -X -h "$HOST" -U banco_app -d "$DB" -v VERBOSITY=verbose -c "SELECT public.registrar_usuario('Ana','Bo','1234567','a@b.co','3000000000','1990-01-01','$HASH',false,NULL,true)" 2>&1 </dev/null)" 'P0001'
# TimeZone de la conexion irrelevante: la edad se mide con la fecha de BOGOTA del reloj del banco
NAC18=$(root "SELECT to_char(DATE '$R' - interval '18 years', 'YYYY-MM-DD')"); NAC17=$(root "SELECT to_char(DATE '$R' - interval '18 years' + interval '1 day', 'YYYY-MM-DD')")
o=$(PGOPTIONS='-c TimeZone=Pacific/Kiritimati' PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.registrar_usuario('Edad','Justa','8100000018','edad18@b.co','3140000018','$NAC18','$HASH',true,NULL,true)" 2>&1 </dev/null)
contiene "A9 TimeZone=Kiritimati: justo 18 años segun la fecha de Bogota = mayor de edad" "$o" '"username"'
o=$(PGOPTIONS='-c TimeZone=Pacific/Pago_Pago' PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.registrar_usuario('Edad','Casi','8100000017','edad17@b.co','3140000017','$NAC17','$HASH',true,NULL,true)" 2>&1 </dev/null)
contiene "A9 TimeZone=Pago_Pago: un dia menos de 18 = menor, sin importar la zona de la sesion" "$o" 'Debes ser mayor de edad para registrarte'
# aislamiento: el libro exige READ COMMITTED
H0=$(huella)
o=$(PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT public.registrar_usuario('Rep','Read','8100000099','rr@b.co','3140000099','1990-01-01','$HASH',true,NULL,true); COMMIT;" 2>&1 </dev/null)
contiene "A10 con REPEATABLE READ el registro se rechaza con un mensaje claro (el libro exige READ COMMITTED)" "$o" 'READ COMMITTED'
eq "A10 ...y no deja rastro" "$H0" "$(huella)"

# ============================================================================
# B. Permisos EFECTIVOS por conexion real
# ============================================================================
denegado "B1 banco_app NO lee usuario"                 banco_app $APP_PW "SELECT * FROM public.usuario"
denegado "B1 banco_app NO lee password_hash"           banco_app $APP_PW "SELECT password_hash FROM public.usuario"
denegado "B1 banco_app NO lee cuenta ni el libro"      banco_app $APP_PW "SELECT count(*) FROM public.cuenta"
denegado "B1 banco_app NO inserta usuarios a mano"     banco_app $APP_PW "INSERT INTO public.usuario (username) VALUES ('x')"
denegado "B1 banco_app NO cambia el estado ni el rol"  banco_app $APP_PW "UPDATE public.usuario SET estado = 'ACTIVO', rol = 'ADMIN'"
denegado "B1 banco_app NO marca el bono a mano"        banco_app $APP_PW "UPDATE public.usuario SET bono_referido_pagado = true"
denegado "B1 banco_app NO ejecuta _pagar_bono_referido" banco_app $APP_PW "SELECT public._pagar_bono_referido('$UID2', now())"
denegado "B1 banco_app NO ejecuta _validar_admin"      banco_app $APP_PW "SELECT public._validar_admin('$UID2')"
denegado "B1 banco_app NO ejecuta _msg_auth ni _reglas_registro" banco_app $APP_PW "SELECT public._reglas_registro()"
denegado "B1 banco_app NO ejecuta _asentar_grupo"      banco_app $APP_PW "SELECT public._asentar_grupo(now(), '[]'::jsonb)"
denegado "B1 banco_app NO asume banco_owner (SET ROLE real, no desde un superusuario)" banco_app $APP_PW "SET ROLE banco_owner"
denegado "B1 banco_app NO lee las vistas de integridad" banco_app $APP_PW "SELECT * FROM public.v_integridad_auth"
for f in "registrar_usuario('A','B','1234567','a@b.co','3000000000','1990-01-01','x',true,NULL,true)" "obtener_credenciales('x')" "validar_sesion('$UID1')" "verificar_correo('$UID1')" "vista_perfil('$UID1')"; do
  denegado "B2 banco_lector NO ejecuta public.$(echo "$f" | cut -d'(' -f1)" banco_lector $LECTOR_PW "SELECT public.$f"
done
denegado "B2 banco_lector NO lee password_hash"        banco_lector $LECTOR_PW "SELECT password_hash FROM public.usuario"
eq "B2 banco_lector SI lee v_integridad_auth (verificacion independiente): todo en orden" "t" "$(as banco_lector $LECTOR_PW "SELECT bool_and(ok) FROM public.v_integridad_auth")"
eq "B3 banco_dev hereda de banco_app: ejecuta validar_sesion y vista_perfil" "2" "$(as banco_dev $DEV_PW "SELECT (public.validar_sesion('$UID1') ->> 'username' IS NOT NULL)::int + (public.vista_perfil('$UID1') ->> 'numero_cuenta' IS NOT NULL)::int")"
denegado "B3 banco_dev NO ejecuta las internas"        banco_dev $DEV_PW "SELECT public._validar_cliente('$UID1')"
denegado "B3 banco_dev NO lee password_hash"           banco_dev $DEV_PW "SELECT password_hash FROM public.usuario"
eq "B4 ni siquiera existe la funcion de reenvio de verificacion (D-E4-9 pendiente de Juan)" "" "$(root "SELECT to_regproc('public.datos_reenvio_verificacion')")"

# ============================================================================
# C. Atomicidad sobre el estado CONFIRMADO (la inyeccion de fallos vive solo en banco_test)
# ============================================================================
root "SELECT tests.instalar_fallas()" >/dev/null
REFC=$(root "SELECT codigo_referido FROM public.usuario WHERE id = '$UID1'")
N=100
for p in tx:1 tx:2 tx:3 tx:6 tx:9 tx:10 tx:11 tx:12 usuario cuenta bono_flag; do
  N=$((N+1)); H0=$(huella); SA0=$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$UID1'")
  o=$(reg $N 'Zoe' 'Vega' "'$REFC'" false "-c tests.falla=$p")
  contiene "C1 falla inyectada [$p] sobre TCP: el error llega al cliente" "$o" 'FALLA INYECTADA'
  eq "C1 ...[$p] el estado CONFIRMADO no cambio (usuarios, cuentas, patas, saldos, banderas)" "$H0" "$(huella)"
  eq "C1 ...[$p] el referidor conserva su saldo exacto y nadie con esa cedula quedo guardado" "$SA0|0" "$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$UID1'")|$(root "SELECT count(*) FROM public.usuario WHERE cedula = '8$(printf %08d $N)'")"
done
# verificar_correo con fallos
o=$(reg 200 'Vero' 'Gil' "'$REFC'" true); UID5=$(campo_json "$o" usuario_id)
for p in tx:1 tx:2 bono_flag verificar; do
  H0=$(huella); SA0=$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$UID1'")
  o=$(PGOPTIONS="-c tests.falla=$p" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.verificar_correo('$UID5')" 2>&1 </dev/null)
  contiene "C2 verificar_correo con falla [$p]: el error llega" "$o" 'FALLA INYECTADA'
  eq "C2 ...[$p] nada cambio: correo sin verificar, bono sin pagar, saldo del referidor igual" "$H0|$SA0" "$(huella)|$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$UID1'")"
done
as banco_app $APP_PW "SELECT public.verificar_correo('$UID5')" >/dev/null
eq "C2 tras los 4 fallos, el reintento verifica y paga el bono UNA vez" "t|1" "$(root "SELECT correoverificado FROM public.usuario WHERE id = '$UID5'")|$(root "SELECT count(*) FROM public.transaccion WHERE tipo = 'BONO_REFERIDO' AND contraparte_cuenta = (SELECT numero_cuenta FROM public.cuenta WHERE usuario_id = '$UID5')")"
# CORTE de la conexion a mitad del registro (a mitad de un ingreso y entre el 1.o y el 2.o tramo del bono)
for p in corte:2 corte:7 corte:11 corte:12; do
  N=$((N+1)); H0=$(huella); SA0=$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$UID1'")
  o=$(reg $N 'Cor' 'Te' "'$REFC'" false "-c tests.falla=$p")
  contiene "C3 corte de conexion [$p]: el cliente ve la conexion cerrada" "$o" 'terminating connection|server closed the connection|connection to server'
  eq "C3 ...[$p] el estado confirmado no cambio y el referidor conserva su saldo" "$H0|$SA0" "$(huella)|$(root "SELECT balance FROM public.cuenta WHERE usuario_id = '$UID1'")"
done
eq "C3 ...ninguna sesion de banco_app quedo colgada ni en transaccion" "0" "$(root "SELECT count(*) FROM pg_stat_activity WHERE usename = 'banco_app' AND state <> 'idle' AND pid <> pg_backend_pid()")"
root "SELECT tests.quitar_fallas()" >/dev/null
N=$((N+1)); o=$(reg $N 'Fin' 'Ok' "'$REFC'" false)
contiene "C4 sin disparadores de falla, el registro con bono vuelve a funcionar (no quedo nada roto)" "$o" '"username"'
eq "C4 integridad global y de autenticacion en orden tras 15 fallos y 4 cortes" "t|t" "$(root "SELECT (SELECT ok FROM public.v_integridad_global) || '|' || (SELECT bool_and(ok) FROM public.v_integridad_auth)" | sed 's/true/t/g')"

# ============================================================================
# D. Medianoche: el registro que empieza ANTES y obtiene el bloqueo del reloj DESPUES usa el dia nuevo (tiempo inyectado)
# ============================================================================
cat > /tmp/c39_inyectar.sql <<'EOF'
DO $g$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'inyeccion de tiempo prohibida fuera de banco_test/banco_mut (BD: %)', current_database();
  END IF;
  CREATE TABLE IF NOT EXISTS tests.reloj_falso (instante timestamptz);
  DELETE FROM tests.reloj_falso;
  INSERT INTO tests.reloj_falso VALUES (NULL);
  GRANT USAGE ON SCHEMA tests TO banco_owner;
  GRANT SELECT ON tests.reloj_falso TO banco_owner;
  EXECUTE $f$CREATE OR REPLACE FUNCTION public._ahora_real() RETURNS timestamptz LANGUAGE sql VOLATILE SECURITY DEFINER
             SET search_path = public, pg_temp AS $b$ SELECT coalesce((SELECT instante FROM tests.reloj_falso LIMIT 1), clock_timestamp()) $b$$f$;
END $g$;
EOF
psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d "$DB" -f /tmp/c39_inyectar.sql >/dev/null 2>&1 </dev/null
eq "D0 la inyeccion de tiempo se instalo en $DB (guardia superada)" "0" "$?"
FAKE1=$(root "SELECT (((DATE '$R' - 10) + time '23:59:58') AT TIME ZONE 'America/Bogota')::text")
FAKE2=$(root "SELECT (((DATE '$R' - 9) + time '00:00:03') AT TIME ZONE 'America/Bogota')::text")
D2=$(root "SELECT DATE '$R' - 9")
NACMED=$(root "SELECT to_char(DATE '$D2' - interval '18 years', 'YYYY-MM-DD')")      # cumple 18 EXACTOS el dia nuevo (D2); el dia anterior tiene 17
root "UPDATE tests.reloj_falso SET instante = '$FAKE1'" >/dev/null
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT pg_sleep(3); COMMIT;" > /tmp/c39_adm.out 2>&1 </dev/null ) &
sleep 1
( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" \
    -c "SELECT public.registrar_usuario('Noche','Buena','8100000555','noche@b.co','3140000555','$NACMED','$HASH',true,NULL,true)" > /tmp/c39_med.out 2>&1 </dev/null ) &
sleep 1
root "UPDATE tests.reloj_falso SET instante = '$FAKE2'" >/dev/null           # pasa la medianoche MIENTRAS el registro espera el bloqueo del reloj
wait
o=$(cat /tmp/c39_med.out)
contiene "D1 el registro que empezo a las 23:59:58 (cuando el nacido tenia 17) y obtuvo el bloqueo a las 00:00:03 (ya 18) FUE ACEPTADO: la edad usa la instantanea tomada DESPUES del bloqueo" "$o" '"username"'
eq "D1 ...creado_en es del dia nuevo ($D2 00:00:0x) y no del de su inicio" "$D2" "$(root "SELECT (creado_en AT TIME ZONE 'America/Bogota')::date FROM public.usuario WHERE cedula = '8100000555'")"
eq "D1 ...y los 5 ingresos son anteriores a esa instantanea y el libro los acepto" "5|t" "$(root "SELECT count(DISTINCT t.grupo_id) || '|' || bool_and(t.fecha < u.creado_en) FROM public.transaccion t JOIN public.cuenta c ON c.id = t.cuenta_id JOIN public.usuario u ON u.id = c.usuario_id WHERE u.cedula = '8100000555'" | sed 's/true/t/')"
# el mismo registro YA DENTRO del dia anterior (sin espera): el nacido tiene 17
root "UPDATE tests.reloj_falso SET instante = '$FAKE1'" >/dev/null
o=$(PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.registrar_usuario('Noche','Antes','8100000556','antes@b.co','3140000556','$NACMED','$HASH',true,NULL,true)" 2>&1 </dev/null)
contiene "D2 a las 23:59:58 (sin espera) el mismo nacido es MENOR: el control es de verdad por fecha" "$o" 'Debes ser mayor de edad para registrarte'
eq "D3 la inyeccion de tiempo se niega fuera de banco_test/banco_mut (base vacia de prueba)" "ok" \
   "$(psql -X -q -At -U postgres -d postgres -c "DROP DATABASE IF EXISTS banco_guardia_t39 WITH (FORCE)" -c "CREATE DATABASE banco_guardia_t39" >/dev/null 2>&1 </dev/null; o=$(psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d banco_guardia_t39 -f /tmp/c39_inyectar.sql 2>&1 </dev/null); psql -X -q -At -U postgres -d postgres -c "DROP DATABASE IF EXISTS banco_guardia_t39 WITH (FORCE)" >/dev/null 2>&1 </dev/null; case "$o" in *prohibida*) echo ok;; *) echo "$o";; esac)"
root "$ORIG" >/dev/null; root "DROP TABLE IF EXISTS tests.reloj_falso" >/dev/null
eq "D4 la _ahora_real() original quedo restaurada (clock_timestamp, VOLATILE, sin SECURITY DEFINER)" "t" "$(root "SELECT pg_get_functiondef(p.oid) LIKE '%SELECT clock_timestamp()%' AND p.provolatile = 'v' AND NOT p.prosecdef FROM pg_proc p WHERE p.oid = 'public._ahora_real()'::regprocedure")"
eq "al final: reloj en modo real y base sin disparadores de inyeccion" "true|0" "$(root "SELECT usar_fecha_real || '|' || (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_zz_falla') FROM public.reloj")"
fin
