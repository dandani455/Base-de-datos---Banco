#!/bin/sh
# 26_atomicidad_sellado.sh - Etapa 2 - atomicidad y sellado con transacciones REALES: una pata suelta falla en el
# COMMIT y revierte hasta el saldo; un grupo confirmado no se puede ampliar desde otra transaccion; un corte de
# conexion a mitad de un grupo no deja rastro; y una sesion que sostiene el bloqueo de una cuenta SERIALIZA a la otra.
. /work/tests/reales/lib.sh

A=$(root "SELECT tests.cliente(341)")
root "SELECT tests.fondear(tests.c(341), 1000)" >/dev/null
H0=$(root "SELECT tests.huella_saldos()")

# 1. pata suelta con COMMIT directo (no pasa por _asentar_grupo): el cuadre diferido falla en el COMMIT
o=$(root "BEGIN; INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, cuenta_id) VALUES (gen_random_uuid(), now(), 'DEPOSITO_BANCO', 'CUENTA', 'E', 100, '$A'); COMMIT;")
contiene "una pata suelta con COMMIT directo falla (grupo con una sola pata)" "$o" "una sola pata"
eq "...y el saldo y el libro quedaron intactos (el trigger de saldos tambien se revirtio)" "$H0" "$(root "SELECT tests.huella_saldos()")"

# 2. grupo descuadrado con COMMIT directo
o=$(root "BEGIN; WITH g AS (SELECT gen_random_uuid() AS id) INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, cuenta_id) SELECT g.id, now(), 'DEPOSITO_BANCO', 'CUENTA', 'E', 100, '$A' FROM g; COMMIT;")
contiene "otro intento suelto tambien falla al COMMIT" "$o" "una sola pata|descuadrado"
eq "...sin cambios" "$H0" "$(root "SELECT tests.huella_saldos()")"

# 3. sellado: un grupo ya confirmado no se amplia desde otra transaccion
G=$(root "SELECT tests.fondear(tests.c(341), 10)")
H1=$(root "SELECT tests.huella_saldos()")
o=$(root "INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, cuenta_id) VALUES ('$G', now(), 'DEPOSITO_BANCO', 'CUENTA', 'E', 5, '$A')")
contiene "agregar una pata a un grupo ya confirmado se rechaza (sellado por tx_id)" "$o" "ya fue confirmado"
eq "...y nada cambio" "$H1" "$(root "SELECT tests.huella_saldos()")"
eq "el grupo confirmado tiene un solo tx_id" "1" "$(root "SELECT count(DISTINCT tx_id) FROM public.transaccion WHERE grupo_id = '$G'")"

# 4. corte de conexion a mitad de un grupo (ya con la primera pata insertada y el saldo actualizado dentro de la tx)
psql -X -q -At -U postgres -d "$DB" -c "BEGIN; INSERT INTO public.transaccion (grupo_id, fecha, tipo, contenedor, sentido, monto, cuenta_id) VALUES (gen_random_uuid(), now(), 'DEPOSITO_BANCO', 'CUENTA', 'E', 777, '$A'); SELECT pg_terminate_backend(pg_backend_pid());" >/dev/null 2>&1 </dev/null
eq "conexion cortada a mitad de un grupo: no queda ninguna pata ni saldo movido" "$H1" "$(root "SELECT tests.huella_saldos()")"

# 5. serializacion por el bloqueo de la cuenta: la sesion 2 espera a que la 1 confirme y luego avanza
( psql -X -q -At -U postgres -d "$DB" -c "BEGIN; SELECT tests.fondear(tests.c(341), 1); SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 </dev/null ) &
sleep 0.7
t0=$(date +%s)
o=$(as banco_app $APP_PW "SELECT tests.app_fondear('$A', 1)")
t1=$(date +%s)
wait
contiene "la sesion 2 (banco_app) logro su operacion despues de esperar el bloqueo de la cuenta" "$o" '^[0-9a-f-]{36}$'
if [ $((t1 - t0)) -ge 1 ]; then pass "...esperó al menos 1 s a la sesion 1 (serializacion por bloqueo de fila)"; else fail "la sesion 2 no esperó (t=$((t1 - t0)) s)"; fi
eq "ambas operaciones quedaron aplicadas: 1000 + 10 + 1 + 1 = 1012.00" "1012.00" "$(root "SELECT balance FROM public.cuenta WHERE id = '$A'")"
eq "las vistas de integridad estan en orden" "t" "$(root "SELECT ok FROM public.v_integridad_global")"
fin
