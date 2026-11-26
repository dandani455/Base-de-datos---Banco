#!/bin/sh
# 55_control_conexiones.sh - Etapa 12 - admin_esquema y admin_tabla (la pestaña Control) con conexiones REALES (TCP + contrasena) de banco_app, banco_lector y banco_dev, SIN superusuario.
#   A. La conversacion del front (/admin/esquema y /admin/tabla/:n): las 11 tablas responden, el hash REAL de la BD no viaja, fuera de la lista = Tabla no permitida con P0001.
#   B. Permisos EFECTIVOS: un cliente real con su usuario_id, un admin bloqueado y un uuid desconocido no leen nada; banco_lector no ejecuta; el helper no se ejecuta; ninguna escritura directa.
#   C. El ping es BARATO y no espera: 100 llamadas seguidas bajo un tope; el visor responde mientras otra sesion mantiene tomados el reloj y una cuenta (no bloquea ni es bloqueado).
#   D. CONCURRENCIA: 6 pings + 6 lecturas de transaccion mientras 4 sesiones transfieren: sin errores ni deadlocks y el libro cuadra.
# Termina SIEMPRE en modo real y con la integridad global en orden.
. /work/tests/reales/lib.sh
restaurar() { wait; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c55_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null
alta() { root "SELECT tests.cliente($1)" >/dev/null; root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso(tests.c($1), $2))" >/dev/null; }
U() { root "SELECT tests.u($1)"; }
NUM() { root "SELECT numero_cuenta FROM public.cuenta WHERE id = tests.c($1)"; }
# clientes 1600 (con movimientos), 1601 y 1602 (transferencias de la concurrencia), 1603 (cliente real para el acceso); admins 1610 (valido) y 1611 (bloqueado)
alta 1600 5000000; alta 1601 5000000; alta 1602 5000000; alta 1603 5000000
root "INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol, estado) VALUES
  ('adm1610', 'REALHASH-55-secreto-admin', 'Adm', 'Uno', '9301610', 'a1610@t.co', '3171610610', DATE '1980-01-01', 'ADMIN', 'ACTIVO'), ('adm1611', 'REALHASH-55-bloqueado', 'Adm', 'Dos', '9301611', 'a1611@t.co', '3171611611', DATE '1980-01-01', 'ADMIN', 'BLOQUEADO')" >/dev/null
root "UPDATE public.usuario SET password_hash = 'REALHASH-55-' || username WHERE username LIKE 'cli160%'" >/dev/null
ADM=$(root "SELECT id FROM public.usuario WHERE username = 'adm1610'"); ADB=$(root "SELECT id FROM public.usuario WHERE username = 'adm1611'")
TABLAS="usuario cuenta bolsillo cdt_definicion cdt credito_producto credito cuota transaccion reloj parametro"

# ============================================================================
# A. La conversacion del front
# ============================================================================
eq "A1 admin_esquema('<admin>') por TCP: objeto con las 11 tablas (nombre, columnas, fks), cada columna con tipo y banderas" "object|11|t" "$(as banco_app $APP_PW "SELECT jsonb_typeof(j) || '|' || jsonb_array_length(j -> 'tablas') || '|' || (SELECT bool_and(t ? 'nombre' AND t ? 'columnas' AND t ? 'fks') FROM jsonb_array_elements(j -> 'tablas') t) FROM (SELECT public.admin_esquema('$ADM') AS j) x" | sed 's/true/t/')"
eq "A2 el esquema trae la FK propia usuario.referido_por -> usuario.id y NINGUNA de audit" "t|f" "$(as banco_app $APP_PW "SELECT (e @> jsonb_build_object('tablas', jsonb_build_array(jsonb_build_object('nombre', 'usuario', 'fks', jsonb_build_array(jsonb_build_object('columna', 'referido_por', 'tabla_destino', 'usuario', 'columna_destino', 'id'))))))::text || '|' || (e::text LIKE '%evento%')::text FROM (SELECT public.admin_esquema('$ADM') AS e) x" | sed 's/true/t/g; s/false/f/g')"
n_ok=0
for t in $TABLAS; do
  as banco_app $APP_PW "SELECT (j ? 'columnas' AND j ? 'filas' AND j ? 'pagina' AND j ? 'total_paginas')::text FROM (SELECT public.admin_tabla('$ADM', '$t', '1') AS j) x" | grep -q '^true$' && n_ok=$((n_ok+1))
done
eq "A3 admin_tabla por TCP responde {columnas, filas, pagina, total_paginas} para las 11 tablas" "11" "$n_ok"
o=$(as banco_app $APP_PW "SELECT public.admin_tabla('$ADM', 'usuario', '1')")
eq "A4 el hash REAL de la BD no viaja: usuario sale con \"••••\" en todas las filas y 'REALHASH' no aparece en ninguna parte de la respuesta" "0|0" "$(printf '%s' "$o" | grep -c 'REALHASH')|$(as banco_app $APP_PW "SELECT count(*) FROM jsonb_array_elements(public.admin_tabla('$ADM', 'usuario', '1') -> 'filas') f WHERE f ->> 'password_hash' IS DISTINCT FROM repeat(chr(8226), 4)")"
eq "A5 ...y el hash real SI esta en la BD (la prueba no es vacia): 6 usuarios con REALHASH" "6" "$(root "SELECT count(*) FROM public.usuario WHERE password_hash LIKE 'REALHASH%'")"
rechazado "A6 una tabla fuera de la lista (audit.evento) = Tabla no permitida" banco_app $APP_PW "SELECT public.admin_tabla('$ADM', 'audit.evento', '1')" "Tabla no permitida"
rechazado "A6 ...y una con comillas e inyeccion" banco_app $APP_PW "SELECT public.admin_tabla('$ADM', 'usuario''; DROP TABLE cuenta; --', '1')" "Tabla no permitida"
contiene "A7 el error de tabla llega con SQLSTATE P0001 (el backend lo convierte en 400)" "$(PGPASSWORD=$APP_PW psql -X -h "$HOST" -U banco_app -d "$DB" -v VERBOSITY=verbose -c "SELECT public.admin_tabla('$ADM', 'evento', '1')" 2>&1 </dev/null)" 'P0001'
eq "A8 la pagina llega como texto del query-string ('2', 'abc', '') sin error de driver: las 3 responden una pagina valida" "3" "$(for p in 2 abc ''; do as banco_app $APP_PW "SELECT (public.admin_tabla('$ADM', 'cuenta', '$p') ->> 'pagina')::int >= 1"; done | grep -c '^t$')"

# ============================================================================
# B. Permisos efectivos
# ============================================================================
eq "B1 banco_app ejecuta EXACTAMENTE admin_esquema y admin_tabla entre las funciones de E12 y NO _reglas_control" "2|0" "$(root "SELECT count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE') AND p.proname IN ('admin_esquema', 'admin_tabla')) || '|' || count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE') AND p.proname = '_reglas_control') FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace")"
UC=$(U 1603)
n1=0; n2=0; n3=0
for c in "admin_esquema(%U)" "admin_tabla(%U, 'usuario', '1')"; do
  q1=$(echo "$c" | sed "s/%U/'$UC'/"); q2=$(echo "$c" | sed "s/%U/'$ADB'/"); q3=$(echo "$c" | sed "s/%U/gen_random_uuid()/")
  as banco_app $APP_PW "SELECT public.$q1" 2>&1 | grep -q 'ERROR:  Acceso denegado' && n1=$((n1+1))
  as banco_app $APP_PW "SELECT public.$q2" 2>&1 | grep -q 'restringida' && n2=$((n2+1))
  as banco_app $APP_PW "SELECT public.$q3" 2>&1 | grep -q 'ERROR:  Acceso denegado' && n3=$((n3+1))
done
eq "B2 un CLIENTE REAL con su usuario_id: las 2 = Acceso denegado; un ADMIN BLOQUEADO: las 2 = mensaje de bloqueo; un uuid desconocido: las 2 = Acceso denegado" "2|2|2" "$n1|$n2|$n3"
denegado "B3 banco_lector NO ejecuta admin_esquema" banco_lector $LECTOR_PW "SELECT public.admin_esquema('$ADM')"
denegado "B3 banco_lector NO ejecuta admin_tabla" banco_lector $LECTOR_PW "SELECT public.admin_tabla('$ADM', 'usuario', '1')"
denegado "B3 banco_app NO ejecuta _reglas_control" banco_app $APP_PW "SELECT public._reglas_control()"
denegado "B3 banco_dev NO ejecuta _reglas_control (aunque hereda de banco_app)" banco_dev $DEV_PW "SELECT public._reglas_control()"
contiene "B4 banco_dev hereda de banco_app: ejecuta admin_esquema" "$(as banco_dev $DEV_PW "SELECT jsonb_array_length(public.admin_esquema('$ADM') -> 'tablas')")" '^11$'
denegado "B5 banco_app NO lee las tablas directamente (el visor es la unica via)" banco_app $APP_PW "SELECT count(*) FROM public.usuario"
denegado "B5 banco_app NO lee audit.evento" banco_app $APP_PW "SELECT count(*) FROM audit.evento"

# ============================================================================
# C. El ping es barato y no espera
# ============================================================================
T0=$(date +%s)
n=$(as banco_app $APP_PW "SELECT count(public.admin_esquema('$ADM')) FROM generate_series(1, 100)")
T1=$(date +%s)
eq "C1 100 llamadas seguidas a admin_esquema (el ping de 5 s) responden bien y tardan menos de 5 s en total" "100|t" "$n|$([ $((T1 - T0)) -lt 5 ] && echo t || echo f)"
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT 1 FROM public.cuenta WHERE id = tests.c(1600) FOR UPDATE; SELECT pg_sleep(3); COMMIT;" > /tmp/c55_h.out 2>&1 </dev/null ) & sleep 1
T0=$(date +%s)
o1=$(as banco_app $APP_PW "SELECT jsonb_array_length(public.admin_esquema('$ADM') -> 'tablas')")
o2=$(as banco_app $APP_PW "SELECT jsonb_array_length(public.admin_tabla('$ADM', 'cuenta', '1') -> 'filas') > 0")
o3=$(as banco_app $APP_PW "SELECT jsonb_array_length(public.admin_tabla('$ADM', 'reloj', '1') -> 'filas')")
T1=$(date +%s)
wait
eq "C2 con el reloj y una cuenta TOMADOS por otra sesion (3 s) el visor responde igual y SIN esperar (< 2 s): no bloquea ni lo bloquean" "11|t|1|t" "$o1|$(echo "$o2" | sed 's/true/t/')|$o3|$([ $((T1 - T0)) -lt 2 ] && echo t || echo f)"

# ============================================================================
# D. Concurrencia: pings y lecturas mientras 4 sesiones transfieren
# ============================================================================
par() {
  _p=$1; _n=$2; _g=$3; _r=${4:-1}; _t=${START:-$(( $(date +%s) + 3 ))}; _i=1
  while [ $_i -le $_n ]; do
    ( set -- -c "SELECT pg_sleep(GREATEST(0, $_t - extract(epoch from clock_timestamp())))"
      _k=1; while [ $_k -le $_r ]; do set -- "$@" -c "$($_g $_i)"; _k=$((_k+1)); done
      PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" "$@" > /tmp/c55_${_p}_$_i.out 2>&1 </dev/null ) &
    _i=$((_i+1))
  done
  wait
}
root "SELECT count(tests.fondear(tests.c(1600), 1000 + g)) FROM generate_series(1, 60) g" >/dev/null     # el libro ya tiene mas de 50 filas: toda lectura de transaccion trae una pagina llena
U1=$(U 1601); U2=$(U 1602); N1=$(NUM 1601); N2=$(NUM 1602)
g() { if [ $1 -le 2 ]; then echo "SELECT public.hacer_transferencia('$U1', '$N2', 100, 'c', NULL)"
      elif [ $1 -le 4 ]; then echo "SELECT public.hacer_transferencia('$U2', '$N1', 100, 'c', NULL)"
      elif [ $1 -le 10 ]; then echo "SELECT jsonb_array_length(public.admin_esquema('$ADM') -> 'tablas')"
      else echo "SELECT jsonb_array_length(public.admin_tabla('$ADM', 'transaccion', '1') -> 'filas')"; fi; }
par d 16 g 15
eq "D1 4 sesiones transfieren (60 transferencias) mientras 6 pings y 6 lecturas de transaccion (15 llamadas cada una): ninguna falla (ni deadlock, ni timeout, ni error)" "0" "$(cat /tmp/c55_d_*.out | grep -ci 'ERROR\|deadlock\|timeout')"
eq "D2 los 6 pings (90) devolvieron las 11 tablas y las 6 lecturas (90) devolvieron una pagina de 50 filas" "90|90" "$(cat /tmp/c55_d_[5-9].out /tmp/c55_d_10.out | grep -c '^11$')|$(cat /tmp/c55_d_1[1-6].out | grep -c '^50$')"
eq "D3 las 60 transferencias salieron una vez cada una (ids) y los dos saldos siguen sumando 10.000.000" "60|10000000.00" "$(cat /tmp/c55_d_[1-4].out | grep -c '"id"')|$(root "SELECT sum(balance) FROM public.cuenta WHERE id IN (tests.c(1601), tests.c(1602))")"
eq "D4 integridad global y defensas en orden tras todo" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
