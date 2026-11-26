#!/bin/sh
# 19_conexion_app.sh - Etapa 2 - conexion REAL de banco_app (TCP + contrasena, como el backend).
# Comprueba los permisos EFECTIVOS: banco_app no toca tablas, vistas ni funciones internas, no puede asumir roles
# privilegiados ni desactivar defensas; y el camino app -> funcion definer -> libro solo mueve saldos por el libro,
# rechaza lo forjado y es atomico (incluso si la conexion se corta antes del COMMIT).
. /work/tests/reales/lib.sh

A=$(root "SELECT tests.cliente(101)"); B=$(root "SELECT tests.cliente(102)")
root "SELECT tests.bolsillo(101, tests.c(101))" >/dev/null
BOL=$(root "SELECT tests.b(101)")

eq "banco_app: la conexion real es banco_app y NO es superusuario" "banco_app|off" \
   "$(as banco_app $APP_PW "SELECT current_user || '|' || current_setting('is_superuser')")"

# --- 1. Lo que banco_app NO puede hacer (privilegios efectivos) --------------------------------------------------
denegado "banco_app NO puede leer cuenta"                banco_app $APP_PW "SELECT * FROM public.cuenta"
denegado "banco_app NO puede leer password_hash"         banco_app $APP_PW "SELECT password_hash FROM public.usuario"
denegado "banco_app NO puede leer el libro"              banco_app $APP_PW "SELECT count(*) FROM public.transaccion"
denegado "banco_app NO puede actualizar balances"        banco_app $APP_PW "UPDATE public.cuenta SET balance = balance + 1000000"
denegado "banco_app NO puede actualizar el acumulador de bolsillo" banco_app $APP_PW "UPDATE public.bolsillo SET balance = balance + 1"
denegado "banco_app NO puede insertar en el libro"       banco_app $APP_PW "INSERT INTO public.transaccion (grupo_id) VALUES (gen_random_uuid())"
denegado "banco_app NO puede borrar patas"               banco_app $APP_PW "DELETE FROM public.transaccion"
denegado "banco_app NO puede vaciar el libro"            banco_app $APP_PW "TRUNCATE public.transaccion"
denegado "banco_app NO puede leer la auditoria"          banco_app $APP_PW "SELECT * FROM audit.evento"
denegado "banco_app NO puede leer las vistas de integridad" banco_app $APP_PW "SELECT * FROM public.v_integridad_global"
denegado "banco_app NO puede crear tablas"               banco_app $APP_PW "CREATE TABLE public.intruso (i int)"
denegado "banco_app NO puede crear funciones"            banco_app $APP_PW "CREATE FUNCTION public.intruso() RETURNS int LANGUAGE sql AS 'SELECT 1'"
denegado "banco_app NO puede ejecutar _asentar_grupo"    banco_app $APP_PW "SELECT public._asentar_grupo(now(), '[]'::jsonb)"
denegado "banco_app NO puede ejecutar la funcion de trigger del libro" banco_app $APP_PW "SELECT public.trg_transaccion_b_aplicar()"
denegado "banco_app NO puede asumir banco_owner"         banco_app $APP_PW "SET ROLE banco_owner"
denegado "banco_app NO puede asumir banco_ledger"        banco_app $APP_PW "SET ROLE banco_ledger"
denegado "banco_app NO puede desactivar triggers"        banco_app $APP_PW "ALTER TABLE public.cuenta DISABLE TRIGGER ALL"
denegado "banco_app NO puede borrar triggers"            banco_app $APP_PW "DROP TRIGGER trg_zz_proteger_cuenta ON public.cuenta"
denegado "banco_app NO puede apagar los event triggers"  banco_app $APP_PW "ALTER EVENT TRIGGER evt_ddl_protegido DISABLE"
denegado "banco_app NO puede usar session_replication_role" banco_app $APP_PW "SET session_replication_role = replica"
denegado "banco_app NO puede conceder permisos"          banco_app $APP_PW "GRANT UPDATE ON public.cuenta TO banco_app"

# --- 2. Los roles privilegiados no inician sesion ------------------------------------------------------------------
o=$(PGPASSWORD=x psql -X -At -h "$HOST" -U banco_owner -d "$DB" -c "SELECT 1" 2>&1 </dev/null)
contiene "banco_owner (NOLOGIN) no puede iniciar sesion" "$o" "not permitted to log in|authentication failed"
o=$(PGPASSWORD=x psql -X -At -h "$HOST" -U banco_ledger -d "$DB" -c "SELECT 1" 2>&1 </dev/null)
contiene "banco_ledger (NOLOGIN) no puede iniciar sesion" "$o" "not permitted to log in|authentication failed"

# --- 3. Camino completo con el arnes (imita las funciones de negocio): solo se mueve dinero por el libro -----------------
o=$(as banco_app $APP_PW "SELECT tests.app_fondear('$A', 1000)")
contiene "banco_app: fondear una cuenta via funcion definer devuelve el grupo" "$o" '^[0-9a-f-]{36}$'
eq "...y el saldo lo movio el libro (1000.00)" "1000.00" "$(root "SELECT balance FROM public.cuenta WHERE id = '$A'")"
o=$(as banco_app $APP_PW "SELECT tests.app_envio('$A', '$B', 300)")
contiene "banco_app: transferencia A->B via funcion definer" "$o" '^[0-9a-f-]{36}$'
eq "...origen 700.00 y destino 300.00" "700.00|300.00" "$(root "SELECT (SELECT balance FROM public.cuenta WHERE id='$A') || '|' || (SELECT balance FROM public.cuenta WHERE id='$B')")"
eq "...con 4 patas en el libro (2 del ingreso, 2 de la transferencia)" "4" "$(root "SELECT count(*) FROM public.transaccion WHERE cuenta_id IN ('$A','$B')")"
o=$(as banco_app $APP_PW "SELECT tests.app_bolso_ingreso('$A', '$BOL', 200)")
contiene "banco_app: mover a un bolsillo via funcion definer" "$o" '^[0-9a-f-]{36}$'
eq "...cuenta 500.00 y bolsillo 200.00" "500.00|200.00" "$(root "SELECT (SELECT balance FROM public.cuenta WHERE id='$A') || '|' || (SELECT balance FROM public.bolsillo WHERE id='$BOL')")"
eq "las vistas de integridad (como superusuario) siguen en orden" "t" "$(root "SELECT ok FROM public.v_integridad_global")"

# --- 4. Lo forjado se rechaza aunque venga por una funcion definer --------------------------------------------------
rechazado "forjado: grupo descuadrado" banco_app $APP_PW \
  "SELECT tests.app_forjar(jsonb_build_array(tests.pata('INGRESO_SIMULADO','CUENTA','E',1000000,'$A'), tests.pata('INGRESO_SIMULADO','RESULTADO','E',1,'$A')))" "descuadrado"
rechazado "forjado: dinero de una cuenta a otra fuera de un par ENVIO/RECIBO" banco_app $APP_PW \
  "SELECT tests.app_forjar(jsonb_build_array(tests.pata('INGRESO_SIMULADO','CUENTA','E',500,'$A'), tests.pata('INGRESO_SIMULADO','RESULTADO','E',500,'$B')))" "una cuenta"
rechazado "forjado: bolsillo de otra cuenta" banco_app $APP_PW \
  "SELECT tests.app_forjar(jsonb_build_array(tests.pata('BOLSO_INGRESO','CUENTA','S',10,'$B','$BOL'), tests.pata('BOLSO_INGRESO','BOLSILLO','E',10,'$B','$BOL')))" "no pertenece"
rechazado "forjado: monto negativo" banco_app $APP_PW \
  "SELECT tests.app_forjar(jsonb_build_array(tests.pata('INGRESO_SIMULADO','CUENTA','E',-5,'$A'), tests.pata('INGRESO_SIMULADO','RESULTADO','E',-5,'$A')))" "Monto inv"
rechazado "forjado: monto con 3 decimales" banco_app $APP_PW \
  "SELECT tests.app_forjar(jsonb_build_array(tests.pata('INGRESO_SIMULADO','CUENTA','E',1.005,'$A'), tests.pata('INGRESO_SIMULADO','RESULTADO','E',1.005,'$A')))" "Monto inv"
rechazado "forjado: saldo insuficiente" banco_app $APP_PW \
  "SELECT tests.app_forjar(jsonb_build_array(tests.pata('BOLSO_INGRESO','CUENTA','S',999999,'$A','$BOL'), tests.pata('BOLSO_INGRESO','BOLSILLO','E',999999,'$A','$BOL')))" "Saldo insuficiente"
rechazado "forjado: tipo inexistente" banco_app $APP_PW \
  "SELECT tests.app_forjar(jsonb_build_array(tests.pata('ROBO','CUENTA','E',10,'$A'), tests.pata('ROBO','RESULTADO','E',10,'$A')))" "pata inv"
rechazado "forjado: una sola pata" banco_app $APP_PW \
  "SELECT tests.app_forjar(jsonb_build_array(tests.pata('INGRESO_SIMULADO','CUENTA','E',10,'$A')))" "al menos dos patas"
rechazado "forjado: combinacion fuera de la matriz contable" banco_app $APP_PW \
  "SELECT tests.app_forjar(jsonb_build_array(tests.pata('RECIBO','CUENTA','S',10,'$A'), tests.pata('RECIBO','RESULTADO','S',10,'$A')))" "ck_transaccion_tipo_contenedor_sentido"
rechazado "forjado: transferencia con contraparte falsa" banco_app $APP_PW \
  "SELECT tests.app_forjar(jsonb_build_array(tests.pata('ENVIO','CUENTA','S',10,'$A',NULL,NULL,NULL,'X','9999999999'), tests.pata('RECIBO','CUENTA','E',10,'$B',NULL,NULL,NULL,'Y','4000000000')))" "contraparte"

# saldos/registro que traiga el llamador se descartan: los fija el libro
o=$(as banco_app $APP_PW "SELECT tests.app_forjar(jsonb_build_array(
      tests.pata('INGRESO_SIMULADO','CUENTA','E',50,'$A') || '{\"saldo_previo\":999999,\"saldo_posterior\":999999,\"registrado_en\":\"2000-01-01\"}'::jsonb,
      tests.pata('INGRESO_SIMULADO','RESULTADO','E',50,'$A')))")
contiene "saldos y registrado_en enviados por el llamador se ignoran (grupo aceptado)" "$o" '^[0-9a-f-]{36}$'
eq "...el libro fijo el saldo real (500.00 -> 550.00)" "500.00|550.00" "$(root "SELECT saldo_previo || '|' || saldo_posterior FROM public.transaccion WHERE cuenta_id='$A' AND contenedor='CUENTA' AND monto=50")"
eq "...y registrado_en es reciente, no el del llamador" "t" "$(root "SELECT registrado_en > now() - interval '1 minute' FROM public.transaccion WHERE cuenta_id='$A' AND monto=50 AND contenedor='CUENTA'")"

# --- 5. Una funcion definer DEFECTUOSA (dueno banco_owner) tampoco puede saltarse el libro -------------------------------
denegado   "funcion defectuosa: UPDATE directo de balance (el dueno no tiene el privilegio)" banco_app $APP_PW "SELECT tests.app_tocar_saldo('$A', 99999999)"
rechazado  "funcion defectuosa: DELETE del libro (trigger de inmutabilidad)" banco_app $APP_PW "SELECT tests.app_borrar_patas()" "no se pueden borrar"
rechazado  "funcion defectuosa: pata suelta (falla al COMMIT por el cuadre diferido)" banco_app $APP_PW "SELECT tests.app_insertar_pata_suelta('$A')" "una sola pata"

# --- 6. Atomicidad: ROLLBACK y corte de conexion antes del COMMIT no dejan rastro -----------------------------------------
H0=$(root "SELECT tests.huella_saldos()")
as banco_app $APP_PW "BEGIN; SELECT tests.app_envio('$A','$B',100); ROLLBACK;" >/dev/null
eq "ROLLBACK explicito: ninguna pata ni saldo cambio" "$H0" "$(root "SELECT tests.huella_saldos()")"
as banco_app $APP_PW "BEGIN; SELECT tests.app_envio('$A','$B',100); SELECT pg_terminate_backend(pg_backend_pid());" >/dev/null
eq "conexion cortada antes del COMMIT: ninguna pata ni saldo cambio" "$H0" "$(root "SELECT tests.huella_saldos()")"

eq "al final de todo, las vistas de integridad siguen en orden" "t" "$(root "SELECT ok FROM public.v_integridad_global")"
fin
