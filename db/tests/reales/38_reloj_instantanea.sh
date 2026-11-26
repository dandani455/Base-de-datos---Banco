#!/bin/sh
# 38_reloj_instantanea.sh - Etapa 3 (correccion de auditoria) - _reloj_instantanea(): PRIMERO el bloqueo FOR SHARE, DESPUES el instante.
# Antes se capturaba el instante (con now(), el inicio de la transaccion) ANTES de esperar el bloqueo: una operacion que empezaba antes de
# medianoche y obtenia el bloqueo despues veia el dia anterior. Aqui, con conexiones reales de banco_app:
#   A. operacion que obtiene el bloqueo normalmente (instante = reloj de pared, entre dos lecturas del reloj del servidor)
#   B. operacion que ESPERA (1) un bloqueo del admin con el reloj intacto y (2) una modificacion del reloj: el instante es posterior a la espera
#   C. operacion que empieza ANTES de medianoche y obtiene el bloqueo DESPUES (tiempo inyectado, SOLO en banco_test/banco_mut): ve el dia nuevo
#   D. tormenta: cambios de reloj concurrentes con operaciones de varias patas que se autoverifican (todas las patas con la misma instantanea)
#   E. la inyeccion de tiempo esta PROHIBIDA fuera de banco_test/banco_mut (base de prueba vacia)
# Termina SIEMPRE en modo real, con la _ahora_real() original y sin la tabla de tiempo falso.
. /work/tests/reales/lib.sh

ORIG=$(root "SELECT pg_get_functiondef('public._ahora_real()'::regprocedure)")
restaurar() {
  wait
  root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
  root "$ORIG" >/dev/null                                   # la _ahora_real() original (por si la prueba C no llego a restaurarla)
  root "DROP TABLE IF EXISTS tests.reloj_falso" >/dev/null
  psql -X -q -At -U postgres -d postgres -c "DROP DATABASE IF EXISTS banco_guardia_t WITH (FORCE)" >/dev/null 2>&1 </dev/null
  rm -f /tmp/c38_*
}
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null

R=$(root "SELECT (now() AT TIME ZONE 'America/Bogota')::date")
A=$(root "SELECT tests.cliente(601)"); B=$(root "SELECT tests.cliente(602)")
root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso('$A', 100000)); SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso('$B', 100000))" >/dev/null
campo() { echo "$1" | cut -d'|' -f"$2"; }
epoch() { root "SELECT extract(epoch FROM clock_timestamp())::numeric(20,3)"; }

# --- A. Sin espera -------------------------------------------------------------------------------------------------------------
T0=$(epoch)
o=$(as banco_app $APP_PW "SELECT tests.app_instantanea()")
T1=$(epoch)
eq "A: sin espera, el hoy de la instantanea es la fecha de Colombia" "$R" "$(campo "$o" 1)"
eq "A: ...y el instante es el reloj de PARED, tomado entre dos lecturas del reloj del servidor" "t" "$(root "SELECT $(campo "$o" 2) BETWEEN $T0 - 0.002 AND $T1 + 0.002")"
eq "A: ...y es la hora de Bogota de ese instante en el 4o campo, de la misma fecha" "$R" "$(campo "$o" 4 | cut -c1-10)"

# --- B1. Espera un bloqueo del admin con el reloj intacto: el instante es posterior a la espera ---------------------------------
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT pg_sleep(3); COMMIT;" \
       -c "SELECT extract(epoch FROM clock_timestamp())::numeric(20,3)" > /tmp/c38_b1.out 2>&1 </dev/null ) &
sleep 1
o=$(as banco_app $APP_PW "SELECT tests.app_instantanea()")
wait
TC=$(tail -1 /tmp/c38_b1.out)
eq "B1: la operacion que espero un bloqueo del reloj obtuvo el hoy correcto ($R)" "$R" "$(campo "$o" 1)"
eq "B1: ...su instante es POSTERIOR a la espera (no el inicio de la transaccion): al menos 1,5 s despues de empezar" "t" "$(root "SELECT $(campo "$o" 2) - $(campo "$o" 3) >= 1.5")"
eq "B1: ...y no anterior al momento en que el admin libero el bloqueo (COMMIT)" "t" "$(root "SELECT $(campo "$o" 2) >= $TC - 0.05")"

# --- B2. Espera una MODIFICACION del reloj: ve el estado posterior al admin --------------------------------------------------------
R10=$(root "SELECT DATE '$R' + 10")
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT public._reloj_actualizar(false, '$R10'); SELECT pg_sleep(3); COMMIT;" > /tmp/c38_b2.out 2>&1 </dev/null ) &
sleep 1
o=$(as banco_app $APP_PW "SELECT tests.app_instantanea()")
wait
eq "B2: la operacion que espero la modificacion del admin ve el estado NUEVO (hoy = R+10), no el anterior" "$R10" "$(campo "$o" 1)"
eq "B2: ...y su ahora esta en el dia nuevo" "$R10" "$(campo "$o" 4 | cut -c1-10)"
as banco_app $APP_PW "SELECT tests.app_reloj(true, '')" >/dev/null
eq "B2: (vuelta a fecha real)" "$R" "$(as banco_app $APP_PW "SELECT tests.app_hoy()")"

# --- C. Empieza antes de medianoche y obtiene el bloqueo despues (tiempo inyectado SOLO en banco_test / banco_mut) -----------------
cat > /tmp/c38_inyectar.sql <<'EOF'
DO $g$
BEGIN
  IF current_database() NOT IN ('banco_test', 'banco_mut') THEN
    RAISE EXCEPTION 'inyeccion de tiempo prohibida fuera de banco_test/banco_mut (BD: %)', current_database();
  END IF;
  CREATE TABLE IF NOT EXISTS tests.reloj_falso (instante timestamptz);
  DELETE FROM tests.reloj_falso;
  INSERT INTO tests.reloj_falso VALUES (NULL);            -- NULL = sin tiempo falso: la funcion cae al reloj de pared
  GRANT USAGE ON SCHEMA tests TO banco_owner;
  GRANT SELECT ON tests.reloj_falso TO banco_owner;
  EXECUTE $f$CREATE OR REPLACE FUNCTION public._ahora_real() RETURNS timestamptz LANGUAGE sql VOLATILE SECURITY DEFINER
             SET search_path = public, pg_temp AS $b$ SELECT coalesce((SELECT instante FROM tests.reloj_falso LIMIT 1), clock_timestamp()) $b$$f$;
END $g$;
EOF
psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d "$DB" -f /tmp/c38_inyectar.sql >/tmp/c38_inj.out 2>&1 </dev/null
eq "C: la inyeccion de tiempo se instalo en $DB (guardia superada)" "0" "$?"

FAKE1=$(root "SELECT (((DATE '$R' - 10) + time '23:59:58') AT TIME ZONE 'America/Bogota')::text")
FAKE2=$(root "SELECT (((DATE '$R' - 9) + time '00:00:03') AT TIME ZONE 'America/Bogota')::text")
D1=$(root "SELECT DATE '$R' - 10"); D2=$(root "SELECT DATE '$R' - 9")

root "UPDATE tests.reloj_falso SET instante = '$FAKE1'" >/dev/null
o=$(as banco_app $APP_PW "SELECT tests.app_instantanea()")
eq "C1: 23:59:58 y el bloqueo se obtiene enseguida: hoy = el dia viejo ($D1) y ahora = 23:59:58" "$D1|$D1 23:59:58" "$(campo "$o" 1)|$(campo "$o" 4)"

# C2: la operacion EMPIEZA a 23:59:58, espera el bloqueo y lo obtiene cuando el reloj de pared ya paso la medianoche (00:00:03)
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT pg_sleep(3); COMMIT;" > /tmp/c38_c2adm.out 2>&1 </dev/null ) &
sleep 1
( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT tests.app_op_verificada('$A', '$B', 1)" > /tmp/c38_c2.out 2>&1 </dev/null ) &
sleep 1
root "UPDATE tests.reloj_falso SET instante = '$FAKE2'" >/dev/null           # pasa la medianoche MIENTRAS la operacion espera
wait
o=$(cat /tmp/c38_c2.out)
eq "C2: la operacion que empezo antes de medianoche y obtuvo el bloqueo despues ve el DIA NUEVO ($D2 00:00:03), no el de su inicio" "$D2|$D2 00:00:03" "$(campo "$o" 5)|$(campo "$o" 6)"
eq "C2: ...y TODAS las patas de la operacion (2) llevan esa misma instantanea (1 fecha distinta, = ahora, de Bogota = hoy)" "2|1|true|true" "$(campo "$o" 1)|$(campo "$o" 2)|$(campo "$o" 3)|$(campo "$o" 4)"
eq "C2: ...y el libro la acepto (regla de fecha vs. reloj) y cuadra" "t" "$(root "SELECT ok FROM public.v_integridad_global")"

# C3: la operacion empieza DESPUES de medianoche: el instante es el nuevo y las patas tambien
o=$(as banco_app $APP_PW "SELECT tests.app_op_verificada('$B', '$A', 1)")
eq "C3: una operacion nueva a las 00:00:03 usa el dia nuevo en todas sus patas" "2|1|true|true|$D2" "$(campo "$o" 1)|$(campo "$o" 2)|$(campo "$o" 3)|$(campo "$o" 4)|$(campo "$o" 5)"

# C4: modo MANUAL con tiempo inyectado: el hoy es la fecha manual y la hora es la real inyectada
root "SELECT public._reloj_actualizar(false, to_char(DATE '$R' + 3, 'YYYY-MM-DD'))" >/dev/null
o=$(as banco_app $APP_PW "SELECT tests.app_instantanea()")
eq "C4: reloj manual R+3 con tiempo inyectado 00:00:03: hoy = R+3 y ahora = R+3 00:00:03 (fecha manual + hora real)" "$(root "SELECT DATE '$R' + 3")|$(root "SELECT DATE '$R' + 3") 00:00:03" "$(campo "$o" 1)|$(campo "$o" 4)"
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null

# restaurar la _ahora_real() original y quitar la tabla
root "$ORIG" >/dev/null; root "DROP TABLE IF EXISTS tests.reloj_falso" >/dev/null
eq "C: la _ahora_real() original quedo restaurada (clock_timestamp, VOLATILE, sin SECURITY DEFINER)" "t" \
   "$(root "SELECT pg_get_functiondef(p.oid) LIKE '%SELECT clock_timestamp()%' AND p.provolatile = 'v' AND NOT p.prosecdef FROM pg_proc p WHERE p.oid = 'public._ahora_real()'::regprocedure")"

# --- D. Tormenta: cambios de reloj concurrentes con operaciones multipata autoverificadas ------------------------------------------
N=40
: > /tmp/c38_adm.sql; : > /tmp/c38_ops.sql
k=0; while [ $k -lt $N ]; do
  echo "SELECT tests.app_reloj_aleatorio();" >> /tmp/c38_adm.sql
  if [ $((k % 2)) -eq 0 ]; then echo "SELECT tests.app_op_verificada('$A', '$B', 1);" >> /tmp/c38_ops.sql; else echo "SELECT tests.app_op_verificada('$B', '$A', 1);" >> /tmp/c38_ops.sql; fi
  k=$((k+1))
done
T=$(( $(date +%s) + 3 ))
i=1; while [ $i -le 3 ]; do
  ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT pg_sleep(GREATEST(0, $T - extract(epoch from clock_timestamp())))" -f /tmp/c38_adm.sql > /tmp/c38_s_adm$i.out 2>&1 </dev/null ) &
  ( PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT pg_sleep(GREATEST(0, $T - extract(epoch from clock_timestamp())))" -f /tmp/c38_ops.sql > /tmp/c38_s_ops$i.out 2>&1 </dev/null ) &
  i=$((i+1))
done
wait
OPS_BIEN=$(cat /tmp/c38_s_ops*.out | grep -cE '^2\|1\|true\|true\|[0-9-]{10}\|[0-9-]{10} [0-9:]{8}$')
OPS_ERR=$(cat /tmp/c38_s_ops*.out | grep -ci 'ERROR')
ADM_OK=$(cat /tmp/c38_s_adm*.out | grep -cE '^(real|manual)$')
ADM_RETRO=$(cat /tmp/c38_s_adm*.out | grep -c 'El reloj no puede retroceder')
ADM_OTROS=$(cat /tmp/c38_s_adm*.out | grep -iE 'ERROR' | grep -vc 'El reloj no puede retroceder')
eq "D: las 120 operaciones de 2 patas se autoverificaron: cada una uso UNA instantanea en todas sus patas y la fecha de Bogota = su hoy" "120" "$OPS_BIEN"
eq "D: ...ninguna recibio error (ni 'posterior al reloj del banco', ni deadlock, ni timeout)" "0" "$OPS_ERR"
eq "D: las 120 peticiones de cambio de reloj se resolvieron (aceptadas o 'El reloj no puede retroceder')" "120" "$((ADM_OK + ADM_RETRO))"
eq "D: ...sin otros errores (deadlocks / timeouts)" "0" "$ADM_OTROS"
eq "D: saldos exactos y conservacion (A + B = 200000.00; 120 operaciones de 1 peso entre ambos)" "200000.00" "$(root "SELECT sum(balance) FROM public.cuenta WHERE id IN ('$A', '$B')")"
eq "D: v_integridad_global.ok y ninguna transaccion colgada de banco_app" "t|0" "$(root "SELECT (SELECT ok FROM public.v_integridad_global) || '|' || (SELECT count(*) FROM pg_stat_activity WHERE usename = 'banco_app' AND state <> 'idle' AND pid <> pg_backend_pid())" | sed 's/true/t/')"

# --- E. La inyeccion de tiempo esta prohibida fuera de banco_test / banco_mut ---------------------------------------------------
psql -X -q -At -U postgres -d postgres -c "DROP DATABASE IF EXISTS banco_guardia_t WITH (FORCE)" -c "CREATE DATABASE banco_guardia_t" >/dev/null 2>&1 </dev/null
o=$(psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d banco_guardia_t -f /tmp/c38_inyectar.sql 2>&1 </dev/null)
contiene "E: el script de inyeccion se NIEGA a correr en otra base (p. ej. banco)" "$o" "prohibida fuera de banco_test/banco_mut"
eq "E: ...y no dejo nada (ni esquema tests ni tabla de tiempo falso)" "0" "$(psql -X -q -At -U postgres -d banco_guardia_t -c "SELECT count(*) FROM pg_namespace WHERE nspname = 'tests'" 2>&1 </dev/null)"
o=$(psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d banco_guardia_t -f /work/tests/35_reloj_viaje_tiempo.test.sql 2>&1 </dev/null)
contiene "E: la prueba de tiempo inyectado (35) tambien aborta en otra base" "$o" "SOLO puede correr en banco_test/banco_mut"
eq "E: la base banco conserva su _ahora_real() sin SECURITY DEFINER y sin esquema tests (la inyeccion nunca la toco)" "t|0" \
   "$(psql -X -q -At -U postgres -d banco -c "SELECT (NOT p.prosecdef)::text || '|' || (SELECT count(*) FROM pg_namespace WHERE nspname = 'tests') FROM pg_proc p WHERE p.oid = 'public._ahora_real()'::regprocedure" 2>&1 </dev/null | sed 's/^true/t/')"

as banco_app $APP_PW "SELECT tests.app_reloj(true, '')" >/dev/null           # la tormenta D deja el reloj en un estado manual aleatorio: vuelta a real (siempre permitida)
eq "al final el reloj esta en modo real y sin fecha guardada" "true|" "$(root "SELECT usar_fecha_real || '|' || coalesce(fecha_sistema::text, '') FROM public.reloj")"
fin
