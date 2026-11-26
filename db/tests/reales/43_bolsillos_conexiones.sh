#!/bin/sh
# 43_bolsillos_conexiones.sh - Etapa 6 - bolsillos con conexiones REALES (TCP + contrasena) de banco_app, banco_lector y banco_dev.
#   A. La conversacion del backend: crear_bolsillo, vista_balance, mover_a_bolsillo, retirar_de_bolsillo y mover_entre_bolsillos; salida jsonb, monto como texto,
#      errores P0001 exactos; los ids de la vista sirven tal cual para operar.
#   B. Permisos EFECTIVOS: banco_app solo las 5 funciones (ni helpers internos ni tablas); lector ninguna; dev hereda de app.
#   C. Atomicidad sobre el estado CONFIRMADO: fallos inyectados en cada pata de las 3 operaciones y CORTE de la conexion a mitad de un movimiento.
#   D. CARRERAS por borrado: el bolsillo, el usuario o la cuenta desaparecen mientras la operacion espera el bloqueo del reloj: se traduce a mensaje de negocio
#      y no queda rastro (nunca un error no-P0001, que el backend convertiria en 503).
# Termina SIEMPRE sin disparadores de inyeccion y en modo real.
. /work/tests/reales/lib.sh

restaurar() { wait; root "SELECT tests.quitar_fallas()" >/dev/null; root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null; rm -f /tmp/c43_*; }
trap restaurar EXIT
root "UPDATE public.reloj SET usar_fecha_real = true" >/dev/null

# clientes: 910 principal (600000), 911 ajeno (con un bolsillo), 912 admin
A=$(root "SELECT tests.cliente(910)"); X=$(root "SELECT tests.cliente(911)")
root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso('$A', 600000))" >/dev/null
UA=$(root "SELECT tests.u(910)"); UX=$(root "SELECT tests.u(911)")
root "INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol) VALUES ('adm912', 'h', 'Adm', 'In', '9300912', 'a912@t.co', '3170000912', DATE '1980-01-01', 'ADMIN')" >/dev/null
UADM=$(root "SELECT id FROM public.usuario WHERE username = 'adm912'")
BX=$(root "SELECT tests.bolsillo(911, '$X')")                       # bolsillo AJENO (del cliente 911)
sal() { root "SELECT balance FROM public.cuenta WHERE id = '$1'"; }
salb() { root "SELECT balance FROM public.bolsillo WHERE id = '$1'"; }
bid() { root "SELECT id FROM public.bolsillo WHERE cuenta_id = '$A' AND nombre = '$1'"; }
V() { as banco_app $APP_PW "SELECT public.vista_balance('$UA')"; }

# ============================================================================
# A. La conversacion del backend
# ============================================================================
eq "banco_app: conexion real, NO superusuario" "banco_app|off" "$(as banco_app $APP_PW "SELECT current_user || '|' || current_setting('is_superuser')")"
o=$(V)
contiene "A1 vista_balance sin bolsillos por TCP: bolsillos = [] (nunca null)" "$o" '"bolsillos": \[\]'
contiene "A1 ...total y principal = 600000.00 (numeros JSON, no cadenas)" "$o" '"total": 600000.00.*"principal": 600000.00|"principal": 600000.00.*"total": 600000.00'
o=$(as banco_app $APP_PW "SELECT public.crear_bolsillo('$UA', '  Vacaciones   2027 ')")
contiene "A2 crear_bolsillo por TCP devuelve {id, nombre} con el nombre normalizado" "$o" '^\{"id": "[0-9a-f-]{36}", "nombre": "Vacaciones 2027"\}$'
as banco_app $APP_PW "SELECT public.crear_bolsillo('$UA', 'Carro')" >/dev/null
B1=$(bid "Vacaciones 2027"); B2=$(bid "Carro")
eq "A2 ...nacen con balance 0 y ultimo_cobro = hoy del banco" "0.00|0.00|t" "$(salb $B1)|$(salb $B2)|$(root "SELECT bool_and(ultimo_cobro = public.hoy_banco()) FROM public.bolsillo WHERE cuenta_id = '$A'" | sed 's/true/t/')"
o=$(as banco_app $APP_PW "SELECT public.mover_a_bolsillo('$UA', '$B1', '150000.50')")
contiene "A3 mover_a_bolsillo por TCP devuelve {id, fecha} (jsonb) con el monto como TEXTO" "$o" '^\{"id": "[0-9a-f-]{36}", "fecha": "[0-9-]{10}T[0-9:.]+[-+][0-9:]+"\}$'
eq "A3 ...cuenta 449999.50 y bolsillo 150000.50" "449999.50|150000.50" "$(sal $A)|$(salb $B1)"
eq "A3 ...2 patas BOLSO_INGRESO en el grupo devuelto, con el nombre del bolsillo como contraparte" "2|BOLSO_INGRESO|Vacaciones 2027" "$(root "SELECT count(*) || '|' || min(tipo) || '|' || min(contraparte_nombre) FROM public.transaccion WHERE grupo_id = '$(echo "$o" | sed -n 's/.*"id": "\([^"]*\)".*/\1/p')'")"
o=$(as banco_app $APP_PW "SELECT public.retirar_de_bolsillo('$UA', '$B1', '0.50')")
contiene "A4 retirar_de_bolsillo por TCP devuelve {id, fecha}" "$o" '"id".*"fecha"'
eq "A4 ...cuenta 450000.00 y bolsillo 150000.00" "450000.00|150000.00" "$(sal $A)|$(salb $B1)"
o=$(as banco_app $APP_PW "SELECT public.mover_entre_bolsillos('$UA', '$B1', '$B2', '50000')")
contiene "A5 mover_entre_bolsillos por TCP devuelve {id, fecha}" "$o" '"id".*"fecha"'
eq "A5 ...Vacaciones 100000.00 y Carro 50000.00; la cuenta principal NO cambia" "100000.00|50000.00|450000.00" "$(salb $B1)|$(salb $B2)|$(sal $A)"
eq "A5 ...las 2 patas son BOLSILLO S (contraparte Carro) y BOLSILLO E (contraparte Vacaciones 2027), sin patas de la cuenta" "BOLSILLO,S,Carro|BOLSILLO,E,Vacaciones 2027" "$(root "SELECT string_agg(contenedor || ',' || sentido || ',' || contraparte_nombre, '|' ORDER BY sentido DESC) FROM public.transaccion WHERE grupo_id = '$(echo "$o" | sed -n 's/.*"id": "\([^"]*\)".*/\1/p')'")"
o=$(V)
contiene "A6 vista_balance por TCP tras operar: total 600000.00 = principal 450000.00 + saldos" "$o" '"total": 600000.00'
eq "A6 ...los 2 bolsillos con su id (texto), nombre y saldo, y NINGUNO del cliente ajeno" "Vacaciones 2027=100000.00,Carro=50000.00|0" "$(root "SELECT string_agg((e ->> 'nombre') || '=' || (e ->> 'saldo')::numeric, ',' ORDER BY ord) FROM jsonb_array_elements('$o'::jsonb -> 'bolsillos') WITH ORDINALITY q(e, ord)")|$(root "SELECT count(*) FROM jsonb_array_elements('$o'::jsonb -> 'bolsillos') e WHERE e ->> 'id' = '$BX'")"
VID=$(root "SELECT ('$o'::jsonb -> 'bolsillos' -> 0) ->> 'id'")
eq "A6 ...el id que entrega la vista sirve TAL CUAL (texto) para operar" "OK" "$(as banco_app $APP_PW "SELECT public.mover_a_bolsillo('$UA', '$VID', '1')" | grep -q '"id"' && echo OK)"
R5() { rechazado "A7 $1" banco_app $APP_PW "$2" "$3"; }
R5 "monto 0 (ingresar)" "SELECT public.mover_a_bolsillo('$UA', '$B1', 0)" "Monto inválido"
R5 "monto con 3 decimales (retirar)" "SELECT public.retirar_de_bolsillo('$UA', '$B1', 1.234)" "Monto inválido"
R5 "el artefacto de float 0.30000000000000004 es Monto invalido (el backend debe pasar texto)" "SELECT public.mover_a_bolsillo('$UA', '$B1', 0.30000000000000004)" "Monto inválido"
R5 "monto invalido gana al bolsillo mal formado" "SELECT public.mover_entre_bolsillos('$UA', 'zz', 'yy', -5)" "Monto inválido"
R5 "bolsillo con texto que no es uuid (nunca un 503 del driver)" "SELECT public.mover_a_bolsillo('$UA', 'no-es-uuid', 10)" "Recurso no encontrado"
R5 "bolsillo inexistente" "SELECT public.retirar_de_bolsillo('$UA', gen_random_uuid()::text, 10)" "Recurso no encontrado"
R5 "bolsillo AJENO (del cliente 911): indistinguible de uno inexistente" "SELECT public.mover_a_bolsillo('$UA', '$BX', 10)" "Recurso no encontrado"
R5 "mover con destino ajeno" "SELECT public.mover_entre_bolsillos('$UA', '$B1', '$BX', 10)" "Recurso no encontrado"
R5 "mover con origen ajeno" "SELECT public.mover_entre_bolsillos('$UA', '$BX', '$B1', 10)" "Recurso no encontrado"
R5 "D-E6-9 (PROVISIONAL): mover un bolsillo a si mismo" "SELECT public.mover_entre_bolsillos('$UA', '$B1', '$B1', 10)" "Los bolsillos de origen y destino deben ser distintos"
R5 "saldo insuficiente (ingresar mas que la cuenta)" "SELECT public.mover_a_bolsillo('$UA', '$B1', 999999999)" "Saldo insuficiente"
R5 "saldo insuficiente (retirar 1 centavo mas que el bolsillo)" "SELECT public.retirar_de_bolsillo('$UA', '$B2', 50000.01)" "Saldo insuficiente"
R5 "saldo insuficiente (mover 1 centavo mas que el origen)" "SELECT public.mover_entre_bolsillos('$UA', '$B2', '$B1', 50000.01)" "Saldo insuficiente"
R5 "nombre vacio" "SELECT public.crear_bolsillo('$UA', '   ')" "Nombre de bolsillo inválido"
R5 "nombre de 41 caracteres (provisional D-E6-8)" "SELECT public.crear_bolsillo('$UA', repeat('n', 41))" "Nombre de bolsillo inválido"
contiene "A8 el error de negocio llega con SQLSTATE P0001 (el backend lo convierte en 400)" "$(PGPASSWORD=$APP_PW psql -X -h "$HOST" -U banco_app -d "$DB" -v VERBOSITY=verbose -c "SELECT public.mover_a_bolsillo('$UA', '$B1', 0)" 2>&1 </dev/null)" 'P0001'
eq "A8 ...cuenta + bolsillos del cliente siguen sumando 600000 (los rechazos no mueven nada)" "600000.00" "$(root "SELECT (SELECT balance FROM public.cuenta WHERE id = '$A') + (SELECT sum(balance) FROM public.bolsillo WHERE cuenta_id = '$A')")"
# sesion
root "UPDATE public.usuario SET estado = 'BLOQUEADO' WHERE id = '$UA'" >/dev/null
for f in "crear_bolsillo('$UA', 'x')" "vista_balance('$UA')" "mover_a_bolsillo('$UA', '$B1', 1)" "retirar_de_bolsillo('$UA', '$B1', 1)" "mover_entre_bolsillos('$UA', '$B1', '$B2', 1)"; do
  rechazado "A9 BLOQUEADO con sesion abierta: $(echo "$f" | cut -d'(' -f1) recibe el mensaje de bloqueo exacto" banco_app $APP_PW "SELECT public.$f" "Tu cuenta ha sido restringida, contacte con el banco para desbloquearla"
done
root "UPDATE public.usuario SET estado = 'ACTIVO' WHERE id = '$UA'" >/dev/null
rechazado "A9 un ADMIN no usa bolsillos: Acceso denegado (vista_balance)" banco_app $APP_PW "SELECT public.vista_balance('$UADM')" "Acceso denegado"
rechazado "A9 ...ni crea bolsillos" banco_app $APP_PW "SELECT public.crear_bolsillo('$UADM', 'x')" "Acceso denegado"
rechazado "A9 usuario inexistente: Sesion invalida (vista_balance)" banco_app $APP_PW "SELECT public.vista_balance(gen_random_uuid())" "Sesión inválida"
rechazado "A9 ...y en mover_a_bolsillo" banco_app $APP_PW "SELECT public.mover_a_bolsillo(gen_random_uuid(), '$B1', 1)" "Sesión inválida"

# ============================================================================
# B. Permisos efectivos por conexion real
# ============================================================================
for f in "crear_bolsillo('$UA', 'x')" "vista_balance('$UA')" "mover_a_bolsillo('$UA', '$B1', 1)" "retirar_de_bolsillo('$UA', '$B1', 1)" "mover_entre_bolsillos('$UA', '$B1', '$B2', 1)"; do
  denegado "B1 banco_lector NO ejecuta $(echo "$f" | cut -d'(' -f1)" banco_lector $LECTOR_PW "SELECT public.$f"
done
for f in "_reglas_bolsillo()" "_bolsillo_propio(gen_random_uuid(), 'x')" "_mover_bolsillo('$UA', 'BOLSO_INGRESO', '$B1', NULL, 1)" "balance_total('$A')"; do
  denegado "B2 banco_app NO ejecuta el helper interno $(echo "$f" | cut -d'(' -f1)" banco_app $APP_PW "SELECT public.$f"
  denegado "B2 banco_lector NO ejecuta el helper interno $(echo "$f" | cut -d'(' -f1)" banco_lector $LECTOR_PW "SELECT public.$f"
  denegado "B2 banco_dev NO ejecuta el helper interno $(echo "$f" | cut -d'(' -f1)" banco_dev $DEV_PW "SELECT public.$f"
done
denegado "B3 banco_app NO lee los bolsillos ni los saldos por tabla" banco_app $APP_PW "SELECT balance FROM public.bolsillo"
denegado "B3 banco_app NO inserta bolsillos a mano (solo crear_bolsillo)" banco_app $APP_PW "INSERT INTO public.bolsillo (cuenta_id, nombre, ultimo_cobro) VALUES ('$A', 'directo', CURRENT_DATE)"
denegado "B3 banco_app NO modifica el saldo de un bolsillo" banco_app $APP_PW "UPDATE public.bolsillo SET balance = 1 WHERE id = '$B1'"
denegado "B3 banco_app NO invoca el libro mayor directamente" banco_app $APP_PW "SELECT public._asentar_grupo(now(), '[]'::jsonb)"
contiene "B4 banco_dev hereda de banco_app: puede ver el balance" "$(as banco_dev $DEV_PW "SELECT public.vista_balance('$UA')")" '"principal"'

# ============================================================================
# C. Atomicidad sobre el estado confirmado
# ============================================================================
root "SELECT tests.instalar_fallas()" >/dev/null
op_sql() { case $1 in
  ingresar) echo "SELECT public.mover_a_bolsillo('$UA', '$B1', 25)";;
  retirar)  echo "SELECT public.retirar_de_bolsillo('$UA', '$B1', 25)";;
  mover)    echo "SELECT public.mover_entre_bolsillos('$UA', '$B1', '$B2', 25)";;
esac; }
for p in tx:1 tx:2; do
  for nombre in ingresar retirar mover; do
    sql=$(op_sql $nombre)
    H0=$(root "SELECT tests.huella_saldos()"); SA0=$(sal $A); S10=$(salb $B1); S20=$(salb $B2)
    o=$(PGOPTIONS="-c tests.falla=$p" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "$sql" 2>&1 </dev/null)
    contiene "C1 falla inyectada [$p] en $nombre sobre TCP: el error llega" "$o" 'FALLA INYECTADA'
    eq "C1 ...[$p] nada cambio: ni la cuenta, ni los bolsillos, ni el libro" "$H0|$SA0|$S10|$S20" "$(root "SELECT tests.huella_saldos()")|$(sal $A)|$(salb $B1)|$(salb $B2)"
  done
done
for p in corte:1 corte:2; do
  H0=$(root "SELECT tests.huella_saldos()"); SA0=$(sal $A)
  o=$(PGOPTIONS="-c tests.falla=$p" PGPASSWORD=$APP_PW psql -X -q -At -h "$HOST" -U banco_app -d "$DB" -c "SELECT public.mover_a_bolsillo('$UA', '$B1', 25)" 2>&1 </dev/null)
  contiene "C2 corte de la conexion [$p] a mitad de un movimiento: el cliente ve la conexion cerrada" "$o" 'terminating connection|server closed the connection|connection to server'
  eq "C2 ...[$p] el estado confirmado no cambio (nadie pierde dinero)" "$H0|$SA0" "$(root "SELECT tests.huella_saldos()")|$(sal $A)"
done
eq "C2 ...ninguna sesion de banco_app quedo colgada" "0" "$(root "SELECT count(*) FROM pg_stat_activity WHERE usename = 'banco_app' AND state <> 'idle' AND pid <> pg_backend_pid()")"
root "SELECT tests.quitar_fallas()" >/dev/null
SA0=$(sal $A)
contiene "C3 sin disparadores de falla el movimiento vuelve a funcionar y mueve el dinero UNA vez" "$(as banco_app $APP_PW "SELECT public.mover_a_bolsillo('$UA', '$B1', 25)")" '"id"'
eq "C3 ...la cuenta perdio exactamente 25" "t" "$(root "SELECT $SA0 - 25 = balance FROM public.cuenta WHERE id = '$A'" | sed 's/true/t/')"
# deja el estado limpio para las carreras: 25 de vuelta a la cuenta
as banco_app $APP_PW "SELECT public.retirar_de_bolsillo('$UA', '$B1', 25)" >/dev/null

# ============================================================================
# D. Carreras por borrado: algo desaparece mientras la operacion espera el bloqueo del reloj
# ============================================================================
D=$(root "SELECT tests.cliente(913)"); UD=$(root "SELECT tests.u(913)")
root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso('$D', 10000))" >/dev/null
BD1=$(root "SELECT tests.bolsillo(913, '$D')")                       # bolsillo SIN patas (se puede borrar suelto)
E=$(root "SELECT tests.cliente(914)"); UE=$(root "SELECT tests.u(914)")
root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso('$E', 10000))" >/dev/null
BE1=$(root "SELECT tests.bolsillo(914, '$E')")
holder() { # holder SQL : toma el bloqueo del reloj 2.5 s y ejecuta SQL antes de soltarlo
  ( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT 1 FROM public.reloj WHERE id = 1 FOR UPDATE; SELECT pg_sleep(2.5); $1 COMMIT;" > /tmp/c43_h.out 2>&1 </dev/null ) &
  sleep 1
}
# D1. el bolsillo destino de un ingreso se borra mientras espera
H0=$(sal $D)
holder "DELETE FROM public.bolsillo WHERE id = '$BD1';"
o=$(as banco_app $APP_PW "SELECT public.mover_a_bolsillo('$UD', '$BD1', 100)")
wait
eq "D1 el bolsillo se borra mientras el ingreso espera el reloj: el borrado se confirmo (sin errores del administrador)" "0|0" "$(root "SELECT count(*) FROM public.bolsillo WHERE id = '$BD1'")|$(grep -c ERROR /tmp/c43_h.out)"
contiene "D1 ...el ingreso recibe 'Recurso no encontrado' (P0001 traducido; no un error de FK ni 'Libro mayor')" "$o" 'ERROR:  Recurso no encontrado'
eq "D1 ...la cuenta conserva su saldo y no quedo ninguna pata del bolsillo borrado" "$H0|0" "$(sal $D)|$(root "SELECT count(*) FROM public.transaccion WHERE bolsillo_id = '$BD1'")"
# D2. el bolsillo DESTINO de un movimiento entre bolsillos se borra mientras espera: el origen NO pierde dinero
root "SELECT tests.app_bolso_ingreso('$E', '$BE1', 1000)" >/dev/null
BE2=$(root "SELECT tests.bolsillo(916, '$E')")
H0=$(salb $BE1)
holder "DELETE FROM public.bolsillo WHERE id = '$BE2';"
o=$(as banco_app $APP_PW "SELECT public.mover_entre_bolsillos('$UE', '$BE1', '$BE2', 400)")
wait
contiene "D2 el bolsillo DESTINO se borra mientras el movimiento espera: 'Recurso no encontrado'" "$o" 'ERROR:  Recurso no encontrado'
eq "D2 ...el bolsillo origen conserva sus 1000 (la pata de salida se revirtio) y no quedo ninguna pata BOLSO_MOVIMIENTO" "$H0|0" "$(salb $BE1)|$(root "SELECT count(*) FROM public.transaccion WHERE tipo = 'BOLSO_MOVIMIENTO' AND cuenta_id = '$E'")"
# D3. el propio USUARIO se borra (cascada del admin) mientras el movimiento espera: Sesion invalida
F=$(root "SELECT tests.cliente(917)"); UF=$(root "SELECT tests.u(917)")
root "SELECT public._asentar_grupo(public.ahora_banco(), tests.g_ingreso('$F', 5000))" >/dev/null
BF=$(root "SELECT tests.bolsillo(917, '$F')")
holder "DELETE FROM public.usuario WHERE id = '$UF';"
o=$(as banco_app $APP_PW "SELECT public.mover_a_bolsillo('$UF', '$BF', 100)")
wait
contiene "D3 el usuario se borra mientras el ingreso espera: 'Sesión inválida' (traducido, sin el texto interno 'Libro mayor')" "$o" 'ERROR:  Sesión inválida'
eq "D3 ...el usuario ya no existe y no quedan patas ni bolsillos suyos" "0|0|0" "$(root "SELECT count(*) FROM public.usuario WHERE id = '$UF'")|$(root "SELECT count(*) FROM public.transaccion WHERE cuenta_id = '$F'")|$(root "SELECT count(*) FROM public.bolsillo WHERE cuenta_id = '$F'")"
# D4. crear_bolsillo mientras el usuario se borra (el INSERT choca con la FK): Sesion invalida y ningun bolsillo huerfano
G=$(root "SELECT tests.cliente(918)"); UG=$(root "SELECT tests.u(918)")
holder "DELETE FROM public.usuario WHERE id = '$UG';"
o=$(as banco_app $APP_PW "SELECT public.crear_bolsillo('$UG', 'Huerfano')")
wait
contiene "D4 el usuario se borra mientras crear_bolsillo espera: 'Sesión inválida' (la FK se traduce; no un error 23503)" "$o" 'ERROR:  Sesión inválida'
eq "D4 ...no existe ningun bolsillo llamado Huerfano" "0" "$(root "SELECT count(*) FROM public.bolsillo WHERE nombre = 'Huerfano'")"
eq "D5 integridad global y defensas en orden tras todo (fallos, cortes y carreras)" "t" "$(root "SELECT ok FROM public.v_integridad_global" | sed 's/true/t/')"
fin
