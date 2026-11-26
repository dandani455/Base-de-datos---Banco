#!/bin/sh
# 56_mantenimiento.sh - Etapa 13 - sp_avanzar_todos y sp_verificar_integridad con conexiones REALES (CALL en autocommit, como superusuario; los roles de acceso por TCP solo para los permisos).
#   A. EQUIVALENCIA con el motor perezoso: dos clientes identicos, uno al dia con la ruta perezosa (vista_dashboard) y el otro con sp_avanzar_todos terminan IGUAL; el resumen cuenta lo que de verdad se escribio.
#   B. IDEMPOTENCIA y auditoria: la 2.a corrida escribe 0 grupos; UN evento por corrida; sp_verificar_integridad en orden.
#   C. ATOMICIDAD (un COMMIT por cuenta): una falla inyectada en UNA cuenta revierte solo esa y la corrida sigue; un CORTE de la conexion deja confirmado lo ya procesado y re-ejecutar termina.
#   D. TIMEOUT DE BLOQUEO (55P03): una cuenta tomada por otra sesion, y el RELOJ tomado por otra sesion, dejan cuentas omitidas SIN detener la corrida ni contarlas como error.
#   E. CONCURRENCIA: 4 sesiones transfiriendo mientras corre el cierre: sin deadlocks, libro cuadrado.
#   F. No se puede llamar dentro de una transaccion; permisos (nadie salvo dueño/superusuario); rendimiento con +300 cuentas.
# Termina SIEMPRE en modo real, sin disparador de inyeccion, sin productos de prueba ni cuentas de relleno.
. /work/tests/reales/lib.sh

restaurar() { wait; root "DROP TRIGGER IF EXISTS trg_zz_falla_mant ON public.transaccion" >/dev/null; root "DROP FUNCTION IF EXISTS tests.trg_falla_mant()" >/dev/null
  root "DELETE FROM public.usuario WHERE username LIKE 'm56u%'" >/dev/null
  root "DELETE FROM public.credito WHERE producto_id IN (SELECT id FROM public.credito_producto WHERE nombre LIKE 'T56 %')" >/dev/null
  root "DELETE FROM public.credito_producto WHERE nombre LIKE 'T56 %'" >/dev/null; root "DELETE FROM public.cdt_definicion WHERE nombre LIKE 'T56 %'" >/dev/null
  root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c56_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
U() { root "SELECT tests.u($1)"; }
C() { root "SELECT tests.c($1)"; }
jump() { root "SELECT public._reloj_actualizar(false, (public.hoy_banco() + $1)::text)" >/dev/null; }
J() { root "SELECT \$j\$$1\$j\$::jsonb ->> '$2'"; }
# CALL en autocommit (una sola sentencia, como pide el procedimiento); el resultado es la fila INOUT; los NOTICE se descartan
mant() { PGOPTIONS="${1:-}" psql -X -q -At -U postgres -d "$DB" -c "CALL public.sp_avanzar_todos()" 2>/tmp/c56_err.out </dev/null; }
grupos() { root "SELECT count(DISTINCT grupo_id) FROM public.transaccion"; }
nev() { root "SELECT count(*) FROM audit.evento WHERE accion = 'MANTENIMIENTO_AVANZAR'"; }
pend() { root "SELECT (EXISTS (SELECT 1 FROM public.bolsillo WHERE cuenta_id = tests.c($1) AND ultimo_cobro < public.hoy_banco()))::text"; }
cdt() { root "SELECT estado FROM public.cdt WHERE cuenta_id = tests.c($1)"; }
huella_c() { root "SELECT md5(concat_ws('|', (SELECT balance FROM public.cuenta WHERE id = tests.c($1)), (SELECT string_agg(balance || '/' || ultimo_cobro, ',') FROM public.bolsillo WHERE cuenta_id = tests.c($1)),
  (SELECT string_agg(estado || '/' || generado_acumulado, ',') FROM public.cdt WHERE cuenta_id = tests.c($1)), (SELECT string_agg(capital_pendiente::text, ',') FROM public.credito WHERE cuenta_id = tests.c($1)),
  (SELECT count(*) FROM public.cuota q JOIN public.credito k ON k.id = q.credito_id WHERE k.cuenta_id = tests.c($1) AND q.pagada),
  (SELECT string_agg(tipo || ':' || sentido || ':' || contenedor || ':' || monto, ',' ORDER BY tipo, sentido, contenedor, monto) FROM public.transaccion WHERE cuenta_id = tests.c($1))))"; }
CD=$(root "WITH x AS (INSERT INTO public.cdt_definicion (nombre, plazo_dias, tasa_anual, monto_min) VALUES ('T56 CDT', 30, 10, 1) RETURNING id) SELECT id FROM x")
CP=$(root "WITH x AS (INSERT INTO public.credito_producto (nombre, descripcion, tasa_anual, monto_min, monto_max, plazo_min_meses, plazo_max_meses) VALUES ('T56 Libre', '', 18, 1, 100000000, 1, 360) RETURNING id) SELECT id FROM x")
# esc N : cliente con 5.000.000, un bolsillo con 100.000, un CDT de 30 dias de 1.000.000 y un credito de 2.000.000 a 12 meses con descuento automatico
esc() {
  alta $1 5000000; _u=$(U $1)
  _b=$(root "SELECT public.crear_bolsillo('$_u', 'B') ->> 'id'"); root "SELECT public.mover_a_bolsillo('$_u', '$_b', 100000)" >/dev/null
  root "SELECT public.crear_cdt('$_u', '$CD', 1000000)" >/dev/null
  _k=$(root "SELECT public.solicitar_credito('$_u', '$CP', 2000000, 12) ->> 'id'"); root "SELECT public.activar_descuento_automatico('$_u', '$_k', true)" >/dev/null
}
# disparador de inyeccion: falla (o corta la conexion) al insertar patas de UNA cuenta (GUC de sesion tests.falla_cuenta; sobrevive a los COMMIT)
cat > /tmp/c56_trg.sql <<'EOF'
CREATE OR REPLACE FUNCTION tests.trg_falla_mant() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
BEGIN
  IF NEW.cuenta_id::text = coalesce(current_setting('tests.falla_cuenta', true), '-') THEN
    IF current_setting('tests.falla_modo', true) = 'corte' THEN PERFORM pg_terminate_backend(pg_backend_pid()); PERFORM pg_sleep(5); END IF;
    RAISE EXCEPTION 'FALLA INYECTADA en la cuenta %', NEW.cuenta_id USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $f$;
DROP TRIGGER IF EXISTS trg_zz_falla_mant ON public.transaccion;
CREATE TRIGGER trg_zz_falla_mant BEFORE INSERT ON public.transaccion FOR EACH ROW EXECUTE FUNCTION tests.trg_falla_mant();
EOF
psql -X -q -U postgres -d "$DB" -f /tmp/c56_trg.sql >/dev/null 2>&1 </dev/null

# ============================================================================
# A. Equivalencia con la ruta perezosa (clientes 1700..1707; A = 1700 con sp_avanzar_todos, B = 1701 con la ruta perezosa)
# ============================================================================
for n in 1700 1701 1702 1703 1704 1705 1706 1707; do esc $n; done
HOY0=$(root "SELECT public.hoy_banco()"); jump 45; HOY=$(root "SELECT public.hoy_banco()")
eq "A1 antes del cierre hay trabajo pendiente en los 8 clientes (intereses de bolsillo vencidos y CDT activos que ya vencieron)" "8|8" "$(for n in 1700 1701 1702 1703 1704 1705 1706 1707; do pend $n; done | grep -c true)|$(for n in 1700 1701 1702 1703 1704 1705 1706 1707; do cdt $n; done | grep -c ACTIVO)"
as banco_app $APP_PW "SELECT public.vista_dashboard('$(U 1701)')" >/dev/null                       # B se pone al dia por la ruta perezosa (lectura de su dashboard)
G0=$(grupos); N0=$(nev); T0TS=$(root "SELECT clock_timestamp()")
R1=$(mant)
G1=$(grupos)
eq "A2 el resumen cuenta lo que se escribio de verdad: grupos del resumen = grupos nuevos del libro" "$(( G1 - G0 ))" "$(J "$R1" grupos)"
eq "A3 todas las cuentas del banco procesadas, sin omitidas ni errores; hoy_desde = hoy_hasta = el hoy del reloj" "$(root "SELECT count(*) FROM public.cuenta")|0|0|$HOY|$HOY" "$(J "$R1" cuentas)|$(J "$R1" omitidas_por_timeout_de_bloqueo)|$(J "$R1" con_error)|$(J "$R1" hoy_desde)|$(J "$R1" hoy_hasta)"
eq "A4 con_cambios = EXACTAMENTE las cuentas en las que se escribio algo (oraculo: cuentas con patas nuevas del libro, >= 7: B ya estaba al dia por la ruta perezosa) y procesadas = cuentas" "$(root "SELECT count(DISTINCT cuenta_id) FROM public.transaccion WHERE registrado_en > '$T0TS'")|t" "$(J "$R1" con_cambios)|$(root "SELECT ((($(J "$R1" procesadas)) = ($(J "$R1" cuentas))) AND (($(J "$R1" con_cambios)) >= 7))::text" | sed 's/true/t/g')"
eq "A5 los 8 clientes quedan AL DIA: sin intereses pendientes, 8 CDT cerrados y la cuota 1 cobrada por descuento automatico en los 8" "0|8|8" "$(for n in 1700 1701 1702 1703 1704 1705 1706 1707; do pend $n; done | grep -c true)|$(for n in 1700 1701 1702 1703 1704 1705 1706 1707; do cdt $n; done | grep -c CERRADO)|$(root "SELECT count(DISTINCT k.cuenta_id) FROM public.cuota q JOIN public.credito k ON k.id = q.credito_id WHERE q.numero = 1 AND q.pagada AND k.cuenta_id IN (SELECT tests.c(g) FROM generate_series(1700, 1707) g)")"
eq "A6 EQUIVALENCIA: el cliente puesto al dia por sp_avanzar_todos (1700) quedo EXACTAMENTE igual que el de la ruta perezosa (1701): saldo, bolsillo, CDT, credito, cuotas y el multiconjunto de movimientos" "$(huella_c 1701)" "$(huella_c 1700)"
eq "A7 ...y los 6 restantes (1702..1707) tambien son identicos a 1701" "1" "$(for n in 1702 1703 1704 1705 1706 1707; do huella_c $n; done | sort -u | wc -l | tr -d ' ')"
eq "A8 hay UN evento MANTENIMIENTO_AVANZAR por corrida: actor = el usuario de la sesion, el resumen SIN la lista de errores y con los mismos grupos" "$(( N0 + 1 ))|postgres|$(J "$R1" grupos)|f" "$(nev)|$(root "SELECT actor_username FROM audit.evento WHERE accion = 'MANTENIMIENTO_AVANZAR' ORDER BY orden DESC LIMIT 1")|$(root "SELECT despues ->> 'grupos' FROM audit.evento WHERE accion = 'MANTENIMIENTO_AVANZAR' ORDER BY orden DESC LIMIT 1")|$(root "SELECT (despues ? 'errores')::text FROM audit.evento WHERE accion = 'MANTENIMIENTO_AVANZAR' ORDER BY orden DESC LIMIT 1" | sed 's/true/t/;s/false/f/')"
# ---- B. idempotencia ----
G2=$(grupos); R2=$(mant)
eq "B1 IDEMPOTENTE: la 2.a corrida no escribe nada (0 grupos, 0 con cambios, el libro igual) y deja su propio evento" "0|0|$G2|$(( N0 + 2 ))" "$(J "$R2" grupos)|$(J "$R2" con_cambios)|$(grupos)|$(nev)"
RV=$(psql -X -q -At -U postgres -d "$DB" -c "CALL public.sp_verificar_integridad()" 2>/dev/null </dev/null)
eq "B2 sp_verificar_integridad tras el cierre (CALL en autocommit por una conexion real): ok = true y ningun desvio" "true|0|0|0|0" "$(J "$RV" ok)|$(J "$RV" contenedores_con_desvio)|$(J "$RV" grupos_con_error)|$(J "$RV" cuentas_con_desvio_i5u)|$(J "$RV" defensas_fallidas)"

# ============================================================================
# C. Atomicidad: UN COMMIT por cuenta (clientes 1710, 1711, 1712; la falla va en la del medio, 1711)
# ============================================================================
for n in 1710 1711 1712; do esc $n; done; jump 45
Y=$(C 1711); HY0=$(huella_c 1711); N0=$(nev); TC=$(root "SELECT clock_timestamp()")
R3=$(mant "-c tests.falla_cuenta=$Y")
eq "C1 una falla inyectada en UNA cuenta (1711): con_error = 1, la lista de errores trae SU cuenta y el mensaje, la corrida SIGUE y no hay omitidas" "1|$Y|t|0" "$(J "$R3" con_error)|$(root "SELECT \$j\$$R3\$j\$::jsonb #>> '{errores,0,cuenta_id}'")|$(root "SELECT (\$j\$$R3\$j\$::jsonb #>> '{errores,0,mensaje}' LIKE 'FALLA INYECTADA%')::text" | sed 's/true/t/')|$(J "$R3" omitidas_por_timeout_de_bloqueo)"
eq "C1b ...y el RESUMEN no cuenta lo revertido: grupos = EXACTAMENTE los grupos que quedaron CONFIRMADOS en el libro en esta corrida, con_cambios = las cuentas con patas confirmadas (>= 2: la anterior 1710 y la posterior 1712 tenian trabajo), y la fallida (1711) NO esta entre ellas ni dejo ni una pata" "$(root "SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE registrado_en > '$TC'")|$(root "SELECT count(DISTINCT cuenta_id) FROM public.transaccion WHERE registrado_en > '$TC'")|t|0" "$(J "$R3" grupos)|$(J "$R3" con_cambios)|$(root "SELECT (($(J "$R3" con_cambios)) >= 2 AND EXISTS (SELECT 1 FROM public.transaccion WHERE cuenta_id = tests.c(1710) AND registrado_en > '$TC') AND EXISTS (SELECT 1 FROM public.transaccion WHERE cuenta_id = tests.c(1712) AND registrado_en > '$TC'))::text" | sed 's/true/t/')|$(root "SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(1711) AND registrado_en > '$TC'")"
eq "C2 ...las cuentas ANTERIOR (1710) y POSTERIOR (1712) quedaron AL DIA y CONFIRMADAS (su COMMIT es independiente) y la fallida (1711) quedo EXACTAMENTE como estaba (se revirtio sola)" "false|false|true|$HY0" "$(pend 1710)|$(pend 1712)|$(pend 1711)|$(huella_c 1711)"
eq "C3 el evento de la corrida con falla existe y cuenta el error (con_error = 1, sin la lista)" "$(( N0 + 1 ))|1" "$(nev)|$(root "SELECT despues ->> 'con_error' FROM audit.evento WHERE accion = 'MANTENIMIENTO_AVANZAR' ORDER BY orden DESC LIMIT 1")"
R4=$(mant)
eq "C4 sin la falla, la siguiente corrida pone al dia la que fallo (con_error = 0) y queda igual que sus vecinas" "0|false|$(huella_c 1710)" "$(J "$R4" con_error)|$(pend 1711)|$(huella_c 1711)"
# ---- corte de la conexion ----
for n in 1720 1721 1722; do esc $n; done; jump 45
X=$(C 1721); N0=$(nev)
PGOPTIONS="-c tests.falla_cuenta=$X -c tests.falla_modo=corte" psql -X -q -At -U postgres -d "$DB" -c "CALL public.sp_avanzar_todos()" >/tmp/c56_corte.out 2>&1 </dev/null
eq "C5 el CORTE de la conexion a mitad de la corrida (en la cuenta 1721) deja CONFIRMADA la anterior (1720), SIN TOCAR la cortada (1721) ni la posterior (1722), y NO escribe el evento de la corrida" "false|true|true|$N0" "$(pend 1720)|$(pend 1721)|$(pend 1722)|$(nev)"
R5=$(mant)
eq "C6 re-ejecutar TERMINA el trabajo: las 3 al dia, sin errores, y ahora si hay evento" "false|false|false|0|$(( N0 + 1 ))" "$(pend 1720)|$(pend 1721)|$(pend 1722)|$(J "$R5" con_error)|$(nev)"
eq "C7 ninguna sesion quedo colgada ni transaccion abierta tras el corte" "0" "$(root "SELECT count(*) FROM pg_stat_activity WHERE datname = '$DB' AND usename = 'postgres' AND state LIKE 'idle in transaction%' AND pid <> pg_backend_pid()")"

# ============================================================================
# D. Timeout de bloqueo (55P03): lock_timeout 2 s
# ============================================================================
for n in 1730 1731; do esc $n; done; jump 45
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.cuenta WHERE id = tests.c(1730) FOR NO KEY UPDATE; SELECT pg_sleep(6); COMMIT;" > /tmp/c56_h1.out 2>&1 </dev/null ) & sleep 1
T0=$(date +%s); R6=$(mant); T1=$(date +%s); wait
eq "D1 una CUENTA tomada por otra sesion mas alla del lock_timeout: queda omitida por timeout de bloqueo (1), sin error, la corrida SIGUE (la vecina 1731 queda al dia) y esperó ~2 s por ella" "1|0|true|false|t" "$(J "$R6" omitidas_por_timeout_de_bloqueo)|$(J "$R6" con_error)|$(pend 1730)|$(pend 1731)|$([ $((T1 - T0)) -ge 2 ] && echo t || echo f)"
R7=$(mant)
eq "D2 libre el bloqueo, la siguiente corrida la pone al dia (omitidas = 0)" "false|0" "$(pend 1730)|$(J "$R7" omitidas_por_timeout_de_bloqueo)"
for n in 1734 1735; do esc $n; done; jump 45; TD=$(root "SELECT clock_timestamp()")
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.cuenta WHERE id = tests.c(1735) FOR NO KEY UPDATE; SELECT pg_sleep(6); COMMIT;" > /tmp/c56_h3.out 2>&1 </dev/null ) & sleep 1
R11=$(mant); wait
eq "D5 un timeout de bloqueo DESPUES de una cuenta con cambios (1734 se procesa, 1735 esta tomada): 1735 omitida (1), sin errores, 1734 al dia y 1735 sigue pendiente" "1|0|false|true" "$(J "$R11" omitidas_por_timeout_de_bloqueo)|$(J "$R11" con_error)|$(pend 1734)|$(pend 1735)"
eq "D6 ...y el resumen NO arrastra a la omitida: grupos = grupos confirmados en el libro en esa corrida, con_cambios = cuentas con patas confirmadas (>= 1), 1735 sin ninguna pata nueva" "$(root "SELECT count(DISTINCT grupo_id) FROM public.transaccion WHERE registrado_en > '$TD'")|$(root "SELECT count(DISTINCT cuenta_id) FROM public.transaccion WHERE registrado_en > '$TD'")|t|0" "$(J "$R11" grupos)|$(J "$R11" con_cambios)|$(root "SELECT (($(J "$R11" con_cambios)) >= 1 AND EXISTS (SELECT 1 FROM public.transaccion WHERE cuenta_id = tests.c(1734) AND registrado_en > '$TD'))::text" | sed 's/true/t/')|$(root "SELECT count(*) FROM public.transaccion WHERE cuenta_id = tests.c(1735) AND registrado_en > '$TD'")"
R12=$(mant)
eq "D7 libre el bloqueo, la siguiente corrida pone al dia a la omitida (omitidas = 0)" "false|0" "$(pend 1735)|$(J "$R12" omitidas_por_timeout_de_bloqueo)"
for n in 1732 1733; do esc $n; done; jump 45
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT pg_sleep(4); COMMIT;" > /tmp/c56_h2.out 2>&1 </dev/null ) & sleep 1
R8=$(mant); wait
eq "D3 el RELOJ tomado por otra sesion (el admin cambiandolo) tambien es un 55P03: cuentas omitidas por timeout de bloqueo (>= 1) SIN contarse como error y sin asumir que la cuenta estaba ocupada; procesadas + omitidas = cuentas" "t|0|t" "$(root "SELECT (($(J "$R8" omitidas_por_timeout_de_bloqueo)) >= 1)::text" | sed 's/true/t/')|$(J "$R8" con_error)|$(root "SELECT (($(J "$R8" procesadas)) + ($(J "$R8" omitidas_por_timeout_de_bloqueo)) = ($(J "$R8" cuentas)))::text" | sed 's/true/t/')"
R9=$(mant)
eq "D4 y la corrida siguiente deja a todos al dia: 1732 y 1733 sin pendientes, omitidas = 0" "false|false|0" "$(pend 1732)|$(pend 1733)|$(J "$R9" omitidas_por_timeout_de_bloqueo)"

# ============================================================================
# E. Concurrencia: 4 sesiones transfieren entre 1700 y 1701 mientras corre el cierre
# ============================================================================
jump 45
par() {
  _p=$1; _n=$2; _g=$3; _r=${4:-1}; _t=$5; _i=1
  while [ $_i -le $_n ]; do
    ( set -- -c "SELECT pg_sleep(GREATEST(0, $_t - extract(epoch from clock_timestamp())))"
      _k=1; while [ $_k -le $_r ]; do set -- "$@" -c "$($_g $_i)"; _k=$((_k+1)); done
      PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" "$@" > /tmp/c56_${_p}_$_i.out 2>&1 </dev/null ) &
    _i=$((_i+1))
  done
}
UA=$(U 1700); UB=$(U 1701); NA=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(1700)"); NB=$(root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c(1701)")
g() { if [ $1 -le 2 ]; then echo "SELECT public.hacer_transferencia('$UA', '$NB', 100, 'c', NULL)"; else echo "SELECT public.hacer_transferencia('$UB', '$NA', 100, 'c', NULL)"; fi; }
ST=$(( $(date +%s) + 3 ))
( psql -X -q -At -U postgres -d "$DB" -c "SELECT pg_sleep(GREATEST(0, $ST - extract(epoch from clock_timestamp())))" -c "CALL public.sp_avanzar_todos()" > /tmp/c56_call.out 2>/dev/null </dev/null ) &
par e 4 g 20 $ST
wait
eq "E1 4 sesiones x 20 transferencias cruzadas mientras corre el cierre: ninguna falla (ni deadlock, ni timeout, ni error) y las 80 salen" "0|80" "$(cat /tmp/c56_e_*.out | grep -ci 'ERROR\|deadlock\|timeout')|$(cat /tmp/c56_e_*.out | grep -c '"id"')"
R10=$(cat /tmp/c56_call.out | tr -d '\n')
eq "E2 el cierre concurrente termino sin errores (con_error = 0) y el banco queda en orden tras todo (v_integridad_global y 2.a corrida sin grupos nuevos)" "0|true|0" "$(J "$R10" con_error)|$(root "SELECT ok FROM public.v_integridad_global" | sed 's/t$/true/')|$(J "$(mant)" grupos)"

# ============================================================================
# F. Dentro de una transaccion, permisos y rendimiento
# ============================================================================
N0=$(nev); H0=$(root "SELECT tests.huella_saldos()")
o1=$(psql -X -q -At -U postgres -d "$DB" -c "BEGIN; CALL public.sp_avanzar_todos(); COMMIT;" 2>&1 </dev/null)
o2=$(psql -X -q -At -U postgres -d "$DB" -c "SELECT 1; CALL public.sp_avanzar_todos();" 2>&1 </dev/null)
contiene "F1 dentro de BEGIN ... COMMIT el CALL falla con 'invalid transaction termination'" "$o1" 'invalid transaction termination'
contiene "F2 con otra sentencia en el mismo -c (transaccion implicita) tambien" "$o2" 'invalid transaction termination'
eq "F3 ...y esos intentos no dejaron nada (ni evento ni cambios)" "$N0|$H0" "$(nev)|$(root "SELECT tests.huella_saldos()")"
n_den=0
for r in "banco_app $APP_PW" "banco_lector $LECTOR_PW" "banco_dev $DEV_PW"; do
  set -- $r
  for q in "CALL public.sp_avanzar_todos()" "CALL public.sp_verificar_integridad()" "SELECT public._reglas_mantenimiento()"; do
    as $1 $2 "$q" 2>&1 | grep -qi 'permission denied' && n_den=$((n_den+1))
  done
done
eq "F4 permisos EFECTIVOS: banco_app, banco_lector y banco_dev (sin superusuario) reciben 'permission denied' en los 2 procedimientos y en el helper (9 de 9)" "9" "$n_den"
root "INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento) SELECT 'm56u' || g, 'h', 'M', 'U', '97' || lpad(g::text, 7, '0'), 'm56u' || g || '@t.co', '3197' || lpad(g::text, 6, '0'), DATE '1990-01-01' FROM generate_series(1, 300) g" >/dev/null
root "INSERT INTO public.cuenta (usuario_id, numero_cuenta) SELECT id, '47' || lpad(substr(username, 5), 8, '0') FROM public.usuario WHERE username LIKE 'm56u%'" >/dev/null
T0=$(date +%s); R11=$(mant); T1=$(date +%s)
eq "F5 con mas de 300 cuentas (sin trabajo pendiente) el cierre termina en pocos segundos (< 30 s), sin errores y las procesa todas" "t|0|t" "$(root "SELECT (($(J "$R11" cuentas)) >= 300)::text" | sed 's/true/t/')|$(J "$R11" con_error)|$([ $((T1 - T0)) -lt 30 ] && echo t || echo f)"
eq "F6 integridad global y defensas en orden tras todo" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
