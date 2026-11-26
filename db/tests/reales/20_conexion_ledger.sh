#!/bin/sh
# 20_conexion_ledger.sh - Etapa 2 - conexion REAL que asume banco_ledger mediante el rol-sonda ledger_probe.
# banco_ledger es NOLOGIN a proposito (nadie debe conectarse con el). Para tener una CONEXION REAL que ejerza sus
# permisos efectivos se crea, solo durante esta prueba, ledger_probe: LOGIN, NOINHERIT (sin privilegios propios) y
# miembro de banco_ledger (puede hacer SET ROLE). Su ELIMINACION esta garantizada: trap EXIT/INT/TERM aqui, mas el
# try/finally (ps1) o trap (sh) del runner, que la eliminan tambien al empezar y al terminar la corrida.
. /work/tests/reales/lib.sh

limpiar() { psql -X -q -U postgres -d postgres -f /work/tests/reales/limpiar_sonda.sql >/dev/null 2>&1 </dev/null; }
trap limpiar EXIT INT TERM
limpiar

A=$(root "SELECT tests.cliente(201)")
# (un CDT sin su pata de apertura es incoherente: se crea justo antes de su grupo CDT_CREACION, como lo hara la funcion de negocio)
root "SELECT tests.fondear(tests.c(201), 1500); SELECT tests.bolsillo(201, tests.c(201)); SELECT tests.credito(201, tests.c(201), 5000); SELECT tests.cdt(201, tests.c(201), 1000); SELECT tests.asentar(tests.pata('CDT_CREACION','CUENTA','S',1000,tests.c(201),NULL,tests.d(201)), tests.pata('CDT_CREACION','CDT','E',1000,tests.c(201),NULL,tests.d(201)))" >/dev/null
CU=20000000-0000-4000-8000-000000000201
BO=30000000-0000-4000-8000-000000000201
CD=50000000-0000-4000-8000-000000000201
CR=70000000-0000-4000-8000-000000000201

o=$(psql -X -q -At -U postgres -d postgres -c "CREATE ROLE ledger_probe LOGIN PASSWORD '$PROBE_PW' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION; GRANT banco_ledger TO ledger_probe WITH INHERIT FALSE, SET TRUE; GRANT CONNECT ON DATABASE $DB TO ledger_probe" 2>&1 </dev/null)
eq "se creo el rol-sonda ledger_probe (LOGIN, NOINHERIT, miembro de banco_ledger)" "t" "$(root "SELECT count(*) = 1 FROM pg_roles WHERE rolname='ledger_probe' AND rolcanlogin AND NOT rolsuper")"

# --- 1. Quien soy y que privilegios tengo ------------------------------------------------------------------------------
eq "la conexion real es ledger_probe (sin privilegios propios)" "ledger_probe|ledger_probe" "$(as ledger_probe $PROBE_PW "SELECT current_user || '|' || session_user")"
denegado "sin SET ROLE, la sonda no lee ni cuenta (NOINHERIT)" ledger_probe $PROBE_PW "SELECT * FROM public.cuenta"
eq "tras SET ROLE banco_ledger, current_user es banco_ledger y session_user sigue siendo la sonda" "banco_ledger|ledger_probe" \
   "$(as ledger_probe $PROBE_PW "SET ROLE banco_ledger; SELECT current_user || '|' || session_user")"

# --- 2. Lo que SI puede (lo minimo que necesita su funcion) ---------------------------------------------------------------
eq "banco_ledger lee id y balance de cuenta" "$CU|500.00" "$(as ledger_probe $PROBE_PW "SET ROLE banco_ledger; SELECT id || '|' || balance FROM public.cuenta WHERE id = '$CU'")"
eq "banco_ledger lee id, cuenta_id y balance de bolsillo" "$BO|$CU|0.00" "$(as ledger_probe $PROBE_PW "SET ROLE banco_ledger; SELECT id || '|' || cuenta_id || '|' || balance FROM public.bolsillo WHERE id = '$BO'")"
eq "banco_ledger lee id, cuenta_id y generado_acumulado de cdt" "$CD|$CU|0.00" "$(as ledger_probe $PROBE_PW "SET ROLE banco_ledger; SELECT id || '|' || cuenta_id || '|' || generado_acumulado FROM public.cdt WHERE id = '$CD'")"
eq "banco_ledger lee id, cuenta_id y capital_pendiente de credito" "$CR|$CU|0.00" "$(as ledger_probe $PROBE_PW "SET ROLE banco_ledger; SELECT id || '|' || cuenta_id || '|' || capital_pendiente FROM public.credito WHERE id = '$CR'")"
eq "banco_ledger puede bloquear la fila (SELECT ... FOR NO KEY UPDATE)" "$CU" "$(as ledger_probe $PROBE_PW "BEGIN; SET LOCAL ROLE banco_ledger; SELECT id FROM public.cuenta WHERE id = '$CU' FOR NO KEY UPDATE; ROLLBACK;")"

# --- 3. Lo que NO puede: leer mas de lo minimo ----------------------------------------------------------------------------
denegado "no lee numero_cuenta"        ledger_probe $PROBE_PW "SET ROLE banco_ledger; SELECT numero_cuenta FROM public.cuenta"
denegado "no lee la fila completa de cuenta (SELECT *)" ledger_probe $PROBE_PW "SET ROLE banco_ledger; SELECT * FROM public.cuenta"
denegado "no lee el monto de un CDT"   ledger_probe $PROBE_PW "SET ROLE banco_ledger; SELECT monto FROM public.cdt"
denegado "no lee usuario"              ledger_probe $PROBE_PW "SET ROLE banco_ledger; SELECT username FROM public.usuario"
denegado "no lee el libro"             ledger_probe $PROBE_PW "SET ROLE banco_ledger; SELECT count(*) FROM public.transaccion"
denegado "no lee la auditoria"         ledger_probe $PROBE_PW "SET ROLE banco_ledger; SELECT count(*) FROM audit.evento"

# --- 4. Lo que NO puede: escribir fuera del trigger -------------------------------------------------------------------------
denegado  "no inserta en el libro"       ledger_probe $PROBE_PW "SET ROLE banco_ledger; INSERT INTO public.transaccion (grupo_id) VALUES (gen_random_uuid())"
denegado  "no borra patas"               ledger_probe $PROBE_PW "SET ROLE banco_ledger; DELETE FROM public.transaccion"
denegado  "no vacia el libro"            ledger_probe $PROBE_PW "SET ROLE banco_ledger; TRUNCATE public.transaccion"
denegado  "no cambia numero_cuenta"      ledger_probe $PROBE_PW "SET ROLE banco_ledger; UPDATE public.cuenta SET numero_cuenta = '0000000000'"
denegado  "no cambia el monto de un CDT" ledger_probe $PROBE_PW "SET ROLE banco_ledger; UPDATE public.cdt SET monto = 1"
denegado  "no crea objetos"              ledger_probe $PROBE_PW "SET ROLE banco_ledger; CREATE TABLE public.intruso (i int)"
rechazado "UPDATE directo de cuenta.balance: tiene el privilegio PERO el guardia lo frena (profundidad 1)" ledger_probe $PROBE_PW \
          "SET ROLE banco_ledger; UPDATE public.cuenta SET balance = balance + 1000 WHERE id = '$CU'" "solo lo modifica el libro"
rechazado "UPDATE directo de bolsillo.balance frenado por el guardia" ledger_probe $PROBE_PW \
          "SET ROLE banco_ledger; UPDATE public.bolsillo SET balance = balance + 1 WHERE id = '$BO'" "solo lo modifica el libro"
rechazado "UPDATE directo de cdt.generado_acumulado frenado por el guardia" ledger_probe $PROBE_PW \
          "SET ROLE banco_ledger; UPDATE public.cdt SET generado_acumulado = generado_acumulado + 1 WHERE id = '$CD'" "solo lo modifica el libro"
rechazado "UPDATE directo de credito.capital_pendiente frenado por el guardia" ledger_probe $PROBE_PW \
          "SET ROLE banco_ledger; UPDATE public.credito SET capital_pendiente = capital_pendiente + 1 WHERE id = '$CR'" "solo lo modifica el libro"
eq "un UPDATE que NO cambia el acumulador si pasa (el guardia bloquea cambios, no sentencias)" "" \
   "$(as ledger_probe $PROBE_PW "SET ROLE banco_ledger; UPDATE public.cuenta SET balance = balance WHERE id = '$CU'")"
rechazado "la funcion de trigger no se puede llamar a mano (aunque banco_ledger sea su dueno)" ledger_probe $PROBE_PW \
          "SET ROLE banco_ledger; SELECT public.trg_transaccion_b_aplicar()" "trigger functions can only be called as triggers"
denegado  "no puede ejecutar _asentar_grupo" ledger_probe $PROBE_PW "SET ROLE banco_ledger; SELECT public._asentar_grupo(now(), '[]'::jsonb)"
denegado  "banco_ledger no puede asumir banco_owner" ledger_probe $PROBE_PW "SET ROLE banco_ledger; SET ROLE banco_owner"
denegado  "la sonda no puede asumir banco_owner" ledger_probe $PROBE_PW "SET ROLE banco_owner"
denegado  "la sonda no puede asumir un superusuario" ledger_probe $PROBE_PW "SET ROLE postgres"
denegado  "la sonda no puede apagar triggers" ledger_probe $PROBE_PW "SET ROLE banco_ledger; ALTER TABLE public.cuenta DISABLE TRIGGER ALL"

# --- 5. El camino legitimo sigue funcionando mientras existe la sonda -------------------------------------------------------
root "SELECT tests.fondear(tests.c(201), 25)" >/dev/null
eq "el unico camino (grupo -> trigger de banco_ledger) mueve el saldo: 500 + 25" "525.00" "$(root "SELECT balance FROM public.cuenta WHERE id = '$CU'")"

# --- 6. La vista de defensas detecta a cualquier miembro de banco_ledger ------------------------------------------------------
eq "v_integridad_defensas DETECTA un miembro de banco_ledger (la sonda)" "f" \
   "$(root "SELECT ok FROM public.v_integridad_defensas WHERE control LIKE 'nadie (salvo superusuarios)%'")"

# --- 7. Eliminacion de la sonda ---------------------------------------------------------------------------------------------
limpiar
eq "la sonda se elimino (to_regrole es NULL)" "t" "$(root "SELECT to_regrole('ledger_probe') IS NULL")"
eq "...y ya nadie (salvo superusuarios) puede asumir banco_ledger ni banco_owner" "t" \
   "$(root "SELECT ok FROM public.v_integridad_defensas WHERE control LIKE 'nadie (salvo superusuarios)%'")"
o=$(PGPASSWORD=$PROBE_PW psql -X -At -h "$HOST" -U ledger_probe -d "$DB" -c "SELECT 1" 2>&1 </dev/null)
contiene "...y la conexion con la sonda ya no es posible" "$o" "authentication failed|does not exist"
fin
