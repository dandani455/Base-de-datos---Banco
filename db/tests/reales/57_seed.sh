#!/bin/sh
# 57_seed.sh - Etapa 14 - Catalogo, seed de demostracion y recorrido de banco_app sobre el seed. TODO en BASES AISLADAS (banco_seed_*): no toca banco ni banco_test.
#   A. CATALOGO: valores del spec y del mock, idempotente, la recarga restaura lo editado.
#   B. SEED: usuarios e identidades fijas, clave Banco2026, historia (bolsillos, 2 CDT, 2 creditos con mora, >= 20 filas de historial), bloqueo, bono de referido,
#      estado final (reloj real, 0 patas futuras, integridad, 1 evento de mantenimiento, esquema seed eliminado, 131 funciones, banco_app = 40).
#   C. PROTECCIONES: se niega sobre un banco con datos; un fallo a mitad NO deja nada (ni usuarios ni reloj movido) y el esquema seed se ELIMINA siempre;
#      las funciones solo-seed rechazan fijar identidad tarde / admin tardio.
#   D. REPRODUCIBILIDAD FUNCIONAL: dos siembras en bases distintas dan el mismo estado funcional (usuarios, cuentas, codigos, libro, productos, saldos).
#   E. RECORRIDO por TCP con banco_app (sin superusuario) sobre el seed: login, perfil, dashboard, historial, bolsillos, CDT, creditos, simulaciones,
#      bloqueado1, admin1 (Control, listado) y reglas del contrato sobre datos reales.
# SEED_DIR (opcional) apunta a una copia mutada de db/seed (las mutaciones de E14). Todo termina eliminando las bases.
. /work/tests/reales/lib.sh
SEED=${SEED_DIR:-/work/seed}
BASE=banco_seed_base; S1=banco_seed_1; S2=banco_seed_2; S3=banco_seed_3; S4=banco_seed_4; CAT=banco_seed_cat
limpiar() { for d in $BASE $S1 $S2 $S3 $S4 $CAT; do psql -X -q -U postgres -d postgres -c "DROP DATABASE IF EXISTS $d WITH (FORCE)" >/dev/null 2>&1 </dev/null; done; rm -rf /tmp/c57_*; }
trap limpiar EXIT
limpiar
PG() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$1" >/dev/null 2>&1 </dev/null; }
clon() { PG "CREATE DATABASE $1 TEMPLATE $BASE" && PG "ALTER DATABASE $1 SET timezone TO 'America/Bogota'"; }
sembrar() { # sembrar BASE modo -> salida; codigo en $?
  BASE=$1 SEED_DIR=$SEED sh $SEED/sembrar.sh "$2" 2>&1 </dev/null
}
J() { psql -X -q -At -U postgres -d "$DB" -c "SELECT \$j\$$1\$j\$::jsonb ->> '$2'" 2>&1 </dev/null; }
JL() { psql -X -q -At -U postgres -d "$DB" -c "SELECT jsonb_array_length(\$j\$$1\$j\$::jsonb)" 2>&1 </dev/null; }

# ---- base con el esquema aplicado y VACIA (plantilla de las demas) ----
PG "CREATE DATABASE $BASE" && PG "ALTER DATABASE $BASE SET timezone TO 'America/Bogota'"
for f in /work/sql/*.sql; do psql -X -q -v ON_ERROR_STOP=1 -U postgres -d $BASE -f "$f" >/dev/null 2>&1 </dev/null || { fail "no se pudo aplicar $f a la base plantilla"; fin; exit 1; }; done
DB=$BASE
eq "0 la base plantilla esta VACIA (sin usuarios ni libro) y sin catalogo" "0|0|0|0" "$(root "SELECT (SELECT count(*) FROM public.usuario) || '|' || (SELECT count(*) FROM public.transaccion) || '|' || (SELECT count(*) FROM public.cdt_definicion) || '|' || (SELECT count(*) FROM public.credito_producto)")"

# ============================================================================
# A. Catalogo
# ============================================================================
clon $CAT; DB=$CAT
OUT=$(sembrar $CAT catalogo); RC=$?
eq "A1 sembrar.sh catalogo termina bien" "0" "$RC"
eq "A2 3 CDT (nombre|plazo|tasa|minimo): 90, 180 y 360 dias con tasas crecientes y minimo 100.000 (D-E14-D1)" "CDT 180 días|180|10.000|100000.00;CDT 360 días|360|10.750|100000.00;CDT 90 días|90|9.250|100000.00" "$(root "SELECT string_agg(nombre || '|' || plazo_dias || '|' || tasa_anual || '|' || monto_min, ';' ORDER BY nombre COLLATE \"C\") FROM public.cdt_definicion")"
eq "A3 4 productos de credito segun el spec §7.6 (nombre|min|max|plazos|tope|multiplicador|edad) con las tasas del mock" "Educación|1000000.00|100000000.00|6|240|||false|15.400;Inmuebles|20000000.00|2000000000.00|60|360|2000000000.00|100.00|true|14.100;Libre inversión|1000000.00|30000000.00|6|24|30000000.00||false|23.900;Vehículo|50000000.00|200000000.00|12|120|||false|18.900" "$(root "SELECT string_agg(nombre || '|' || monto_min || '|' || monto_max || '|' || plazo_min_meses || '|' || plazo_max_meses || '|' || coalesce(tope_absoluto::text, '') || '|' || coalesce(multiplicador_balance::text, '') || '|' || aplica_regla_edad || '|' || tasa_anual, ';' ORDER BY nombre COLLATE \"C\") FROM public.credito_producto")"
eq "A4 solo Inmuebles aplica la regla de edad y el multiplicador (100 x patrimonio, tope 2.000M); Libre inversion tiene tope fijo 30M" "Inmuebles|Inmuebles|Libre inversión" "$(root "SELECT (SELECT string_agg(nombre, ',') FROM public.credito_producto WHERE aplica_regla_edad) || '|' || (SELECT string_agg(nombre, ',') FROM public.credito_producto WHERE multiplicador_balance IS NOT NULL) || '|' || (SELECT string_agg(nombre, ',') FROM public.credito_producto WHERE tope_absoluto = 30000000)")"
H1=$(root "SELECT md5(string_agg(id::text || nombre || tasa_anual::text || monto_min::text, ',' ORDER BY nombre)) FROM public.cdt_definicion"); P1=$(root "SELECT md5(string_agg(id::text || nombre || tasa_anual::text || monto_max::text, ',' ORDER BY nombre)) FROM public.credito_producto")
sembrar $CAT catalogo >/dev/null
eq "A5 IDEMPOTENTE: cargarlo otra vez no cambia ni crea filas (mismos ids y valores; sigue habiendo 3 y 4)" "$H1|$P1|3|4" "$(root "SELECT md5(string_agg(id::text || nombre || tasa_anual::text || monto_min::text, ',' ORDER BY nombre)) FROM public.cdt_definicion")|$(root "SELECT md5(string_agg(id::text || nombre || tasa_anual::text || monto_max::text, ',' ORDER BY nombre)) FROM public.credito_producto")|$(root "SELECT count(*) FROM public.cdt_definicion")|$(root "SELECT count(*) FROM public.credito_producto")"
root "UPDATE public.cdt_definicion SET tasa_anual = 1 WHERE nombre = 'CDT 90 días'; UPDATE public.credito_producto SET monto_max = 31000000 WHERE nombre = 'Libre inversión'" >/dev/null
sembrar $CAT catalogo >/dev/null
eq "A6 recargar el catalogo RESTAURA los valores editados (y conserva los ids)" "9.250|30000000.00|$H1" "$(root "SELECT (SELECT tasa_anual FROM public.cdt_definicion WHERE nombre = 'CDT 90 días') || '|' || (SELECT monto_max FROM public.credito_producto WHERE nombre = 'Libre inversión')")|$(root "SELECT md5(string_agg(id::text || nombre || tasa_anual::text || monto_min::text, ',' ORDER BY nombre)) FROM public.cdt_definicion")"
eq "A7 el catalogo NO crea usuarios, libro ni deja el esquema seed" "0|0|t" "$(root "SELECT (SELECT count(*) FROM public.usuario) || '|' || (SELECT count(*) FROM public.transaccion) || '|' || (to_regnamespace('seed') IS NULL)" | sed 's/true/t/')"

# ============================================================================
# B. Seed de demostracion
# ============================================================================
clon $S1; DB=$S1
OUT=$(sembrar $S1 demo); RC=$?
eq "B1 sembrar.sh demo termina bien y avisa que el esquema seed fue eliminado" "0|t" "$RC|$(printf '%s' "$OUT" | grep -q 'Seed completo. Esquema seed eliminado' && echo t || echo f)"
root "CREATE EXTENSION IF NOT EXISTS pgcrypto" >/dev/null
eq "B2 12 usuarios: 1 ADMIN y 11 CLIENTE; solo bloqueado1 esta BLOQUEADO; el ADMIN no tiene cuenta" "12|1|11|bloqueado1|0" "$(root "SELECT (SELECT count(*) FROM public.usuario) || '|' || (SELECT count(*) FROM public.usuario WHERE rol = 'ADMIN') || '|' || (SELECT count(*) FROM public.usuario WHERE rol = 'CLIENTE') || '|' || (SELECT string_agg(username, ',') FROM public.usuario WHERE estado = 'BLOQUEADO') || '|' || (SELECT count(*) FROM public.cuenta c JOIN public.usuario u ON u.id = c.usuario_id WHERE u.rol = 'ADMIN')")"
eq "B3 identidades FIJAS del contrato §5 (username|cuenta|codigo de referido)" "bloqueado1|4005006007|b1000000-0000-4000-8000-000000000003;cgomez12|4003004005|c4000000-0000-4000-8000-000000000004;jperez483|4001002003|8f3c2a10-5b7e-4d3a-9c21-6a7b1d0e42f9" "$(root "SELECT string_agg(u.username || '|' || c.numero_cuenta || '|' || u.codigo_referido, ';' ORDER BY u.username) FROM public.usuario u JOIN public.cuenta c ON c.usuario_id = u.id WHERE u.username IN ('jperez483', 'cgomez12', 'bloqueado1')")"
eq "B4 admin1 es ADMIN activo y verificado; nombres colombianos (Camila Rodriguez Peña, Juan Pérez Gutiérrez)" "ADMIN|ACTIVO|t|Camila Rodríguez Peña|Juan Pérez Gutiérrez" "$(root "SELECT (SELECT rol || '|' || estado || '|' || correoverificado FROM public.usuario WHERE username = 'admin1') || '|' || (SELECT nombres || ' ' || apellidos FROM public.usuario WHERE username = 'cgomez12') || '|' || (SELECT nombres || ' ' || apellidos FROM public.usuario WHERE username = 'jperez483')" | sed 's/|true|/|t|/')"
eq "B5 la clave Banco2026 corresponde al hash de los 12 usuarios (crypt) y el hash es bcrypt valido" "12|12" "$(root "SELECT count(*) FILTER (WHERE password_hash = crypt('Banco2026', password_hash)) || '|' || count(*) FILTER (WHERE public._es_hash_bcrypt(password_hash)) FROM public.usuario")"
eq "B6 el referido: daniela (dtorres219) fue referida por jperez483 y su referidor recibio UN BONO_REFERIDO de 50000 con la cuenta FIJA de ella como contraparte" "jperez483|1|50000.00|4006667778" "$(root "SELECT (SELECT r.username FROM public.usuario d JOIN public.usuario r ON r.id = d.referido_por WHERE d.username = 'dtorres219') || '|' || count(*) || '|' || max(t.monto) || '|' || max(t.contraparte_cuenta) FROM public.transaccion t JOIN public.cuenta c ON c.id = t.cuenta_id JOIN public.usuario u ON u.id = c.usuario_id WHERE u.username = 'jperez483' AND t.tipo = 'BONO_REFERIDO' AND t.contenedor = 'CUENTA'")"
eq "B7 NINGUN asiento menciona un numero de cuenta que no exista (las identidades se fijaron antes de cualquier otra operacion)" "0" "$(root "SELECT count(*) FROM public.transaccion WHERE contraparte_cuenta IS NOT NULL AND contraparte_cuenta NOT IN (SELECT numero_cuenta FROM public.cuenta)")"
JP=$(root "SELECT id FROM public.usuario WHERE username = 'jperez483'"); CG=$(root "SELECT id FROM public.usuario WHERE username = 'cgomez12'"); BL=$(root "SELECT id FROM public.usuario WHERE username = 'bloqueado1'"); AD=$(root "SELECT id FROM public.usuario WHERE username = 'admin1'")
eq "B8 jperez483: 2 bolsillos (Viajes y Emergencias), 2 CDT (1 ACTIVO y 1 CERRADO, de 180 y 90 dias) y 2 creditos de PRODUCTOS DISTINTOS" "Emergencias,Viajes|ACTIVO,CERRADO|2|Libre inversión,Vehículo" "$(root "SELECT (SELECT string_agg(nombre, ',' ORDER BY nombre) FROM public.bolsillo WHERE cuenta_id = (SELECT id FROM public.cuenta WHERE usuario_id = '$JP')) || '|' || (SELECT string_agg(estado::text, ',' ORDER BY estado::text) FROM public.cdt WHERE cuenta_id = (SELECT id FROM public.cuenta WHERE usuario_id = '$JP')) || '|' || (SELECT count(DISTINCT producto_id) FROM public.credito WHERE cuenta_id = (SELECT id FROM public.cuenta WHERE usuario_id = '$JP')) || '|' || (SELECT string_agg(p.nombre, ',' ORDER BY p.nombre) FROM public.credito k JOIN public.credito_producto p ON p.id = k.producto_id WHERE k.cuenta_id = (SELECT id FROM public.cuenta WHERE usuario_id = '$JP'))")"
VC=$(root "SELECT public.vista_creditos('$JP')")
eq "B9 el credito Libre inversion tiene descuento automatico y esta AL DIA (mora 0); el Vehiculo NO lo tiene y no ha pagado ninguna cuota" "true|0.00|false|0" "$(root "SELECT (e ->> 'descuento_automatico') || '|' || (e ->> 'mora_acumulada') FROM jsonb_array_elements(\$j\$$VC\$j\$::jsonb) e WHERE e ->> 'producto' = 'Libre inversión'")|$(root "SELECT (e ->> 'descuento_automatico') || '|' || (e ->> 'cuotas_pagadas') FROM jsonb_array_elements(\$j\$$VC\$j\$::jsonb) e WHERE e ->> 'producto' = 'Vehículo'")"
eq "B9b ...el Vehiculo tiene mora_acumulada > 0 y el Libre inversion >= 2 cuotas pagadas" "t|t" "$(root "SELECT ((e ->> 'mora_acumulada')::numeric > 0)::text FROM jsonb_array_elements(\$j\$$VC\$j\$::jsonb) e WHERE e ->> 'producto' = 'Vehículo'" | sed 's/true/t/')|$(root "SELECT ((e ->> 'cuotas_pagadas')::int >= 2)::text FROM jsonb_array_elements(\$j\$$VC\$j\$::jsonb) e WHERE e ->> 'producto' = 'Libre inversión'" | sed 's/true/t/')"
HI=$(root "SELECT public.vista_historial('$JP', 50)")
eq "B10 el historial de jperez483 tiene 50 filas visibles (limite), con ENVIOS y RECIBOS y al menos 8 contrapartes distintas" "50|t|t|t" "$(JL "$HI")|$(root "SELECT bool_or(e ->> 'tipo' = 'envio')::text FROM jsonb_array_elements(\$j\$$HI\$j\$::jsonb) e" | sed 's/true/t/')|$(root "SELECT bool_or(e ->> 'tipo' = 'recibo')::text FROM jsonb_array_elements(\$j\$$HI\$j\$::jsonb) e" | sed 's/true/t/')|$(root "SELECT (count(DISTINCT e ->> 'contraparte') >= 8)::text FROM jsonb_array_elements(\$j\$$HI\$j\$::jsonb) e" | sed 's/true/t/')"
eq "B11 mas de 20 movimientos de envio/recibo entre personas en el libro de jperez483 (>= 20 grupos de ENVIO/RECIBO)" "t" "$(root "SELECT (count(DISTINCT t.grupo_id) >= 20)::text FROM public.transaccion t JOIN public.cuenta c ON c.id = t.cuenta_id WHERE c.usuario_id = '$JP' AND t.tipo IN ('ENVIO', 'RECIBO')" | sed 's/true/t/')"
eq "B12 bloqueado1 recibe el mensaje de bloqueo EXACTO; cgomez12 tiene su bolsillo Ahorro" "Tu cuenta ha sido restringida, contacte con el banco para desbloquearla|Ahorro" "$(root "SELECT public.validar_sesion('$BL')" | sed 's/^ERROR:  //' | head -n1)|$(root "SELECT nombre FROM public.bolsillo WHERE cuenta_id = (SELECT id FROM public.cuenta WHERE usuario_id = '$CG')")"
eq "B13 ESTADO FINAL: reloj en modo REAL, sin fecha manual, 0 patas en el futuro, banco no vacio" "t||0|f" "$(root "SELECT usar_fecha_real || '|' || coalesce(fecha_sistema::text, '') || '|' || patas_fechadas_en_el_futuro || '|' || banco_vacio FROM public.v_reloj_estado" | sed 's/true/t/;s/false/f/')"
eq "B14 integridad: v_integridad_global.ok, 0 defensas caidas, 0 grupos con error y 0 desvios; 11 cuentas" "t|0|0|0|11" "$(root "SELECT ok || '|' || defensas_fallidas || '|' || grupos_con_error || '|' || contenedores_con_desvio || '|' || cuentas FROM public.v_integridad_global" | sed 's/^true/t/')"
eq "B15 el seed termina con UN evento MANTENIMIENTO_AVANZAR y una segunda corrida no escribe nada (lo guardado esta al dia)" "1|0" "$(root "SELECT count(*) FROM audit.evento WHERE accion = 'MANTENIMIENTO_AVANZAR'")|$(psql -X -q -At -U postgres -d "$DB" -c "CALL public.sp_avanzar_todos()" 2>/dev/null </dev/null | sed 's/.*"grupos": \([0-9]*\).*/\1/')"
eq "B16 se auditan las acciones del admin: tasa de mora = 30 en el seed, 1 bloqueo, 10 ajustes y los cambios del reloj" "30.000|1|10|t" "$(root "SELECT (SELECT tasa_mora_anual FROM public.parametro WHERE id = 1) || '|' || (SELECT count(*) FROM audit.evento WHERE accion = 'USUARIO_BLOQUEADO') || '|' || (SELECT count(*) FROM audit.evento WHERE accion = 'AJUSTE_ADMIN') || '|' || (SELECT (count(*) > 0)::text FROM audit.evento WHERE accion = 'RELOJ_CAMBIO')" | sed 's/true/t/')"
eq "B17 el esquema seed NO existe y public sigue con las 131 funciones propias; banco_app ejecuta exactamente 40" "t|131|40" "$(root "SELECT (to_regnamespace('seed') IS NULL)::text || '|' || (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')) || '|' || (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND pg_get_userbyid(p.proowner) = 'banco_owner' AND has_function_privilege('banco_app', p.oid, 'EXECUTE'))" | sed 's/^true/t/')"
eq "B18 las 4 defensas de roles/trigger siguen activas: el guardia de cuenta, la inmutabilidad del libro y el cuadre (el seed no deshabilito nada)" "0|0" "$(root "SELECT count(*) FROM public.v_integridad_defensas WHERE NOT ok")|$(root "SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgenabled <> 'O' AND tgrelid::regclass::text IN ('public.cuenta', 'public.transaccion', 'public.usuario')")"
H_S1=$(root "SELECT md5(concat_ws('|', (SELECT string_agg(id::text || balance::text, ',' ORDER BY id) FROM public.cuenta), (SELECT count(*)::text FROM public.transaccion)))")

# ============================================================================
# C. Protecciones
# ============================================================================
DB=$S1
OUT=$(sembrar $S1 demo); RC=$?
eq "C1 sobre un banco CON datos el seed se NIEGA (codigo 2, mensaje claro) y no cambia nada" "2|t|$H_S1|t" "$RC|$(printf '%s' "$OUT" | grep -q 'banco vacio' && echo t || echo f)|$(root "SELECT md5(concat_ws('|', (SELECT string_agg(id::text || balance::text, ',' ORDER BY id) FROM public.cuenta), (SELECT count(*)::text FROM public.transaccion)))")|$(root "SELECT (to_regnamespace('seed') IS NULL)::text" | sed 's/true/t/')"
# fallo a mitad de la historia: copia del seed con un error al final de la transaccion
mkdir -p /tmp/c57_roto && cp $SEED/*.sql $SEED/*.sh /tmp/c57_roto/
sed -i "s/  PERFORM seed.volver_a_real();/  PERFORM public.hacer_transferencia(jp, '9999999999', 1, 'cuenta inexistente', NULL);\n  PERFORM seed.volver_a_real();/" /tmp/c57_roto/20_demo.sql
clon $S3; DB=$S3
OUT=$(BASE=$S3 SEED_DIR=/tmp/c57_roto sh $SEED/sembrar.sh demo 2>&1 </dev/null); RC=$?
eq "C2 un fallo a MITAD de la historia (ultimo paso) termina con error" "t" "$([ "$RC" -ne 0 ] && echo t || echo f)"
eq "C3 ...y NO deja nada: 0 usuarios, 0 patas, el reloj sigue en modo real sin fecha manual" "0|0|t|" "$(root "SELECT (SELECT count(*) FROM public.usuario) || '|' || (SELECT count(*) FROM public.transaccion) || '|' || (SELECT usar_fecha_real FROM public.reloj) || '|' || coalesce((SELECT fecha_sistema::text FROM public.reloj), '')" | sed 's/true/t/')"
eq "C4 ...y el esquema temporal seed fue ELIMINADO igualmente (condicion de limpieza)" "t" "$(root "SELECT (to_regnamespace('seed') IS NULL)::text" | sed 's/true/t/')"
# fallo al crear las funciones solo-seed (sintaxis rota): tambien se limpia
cp $SEED/*.sql $SEED/*.sh /tmp/c57_roto/
printf '\nCREATE FUNCTION seed.rota( RETURNS;\n' >> /tmp/c57_roto/10_funciones_seed.sql
OUT=$(BASE=$S3 SEED_DIR=/tmp/c57_roto sh $SEED/sembrar.sh demo 2>&1 </dev/null); RC=$?
eq "C5 un fallo al CREAR las funciones solo-seed tambien termina con error y deja el esquema seed ELIMINADO y el banco intacto" "t|t|0" "$([ "$RC" -ne 0 ] && echo t || echo f)|$(root "SELECT (to_regnamespace('seed') IS NULL)::text" | sed 's/true/t/')|$(root "SELECT count(*) FROM public.usuario")"
# interrupcion DURANTE la historia: HUP y TERM (correccion de la auditoria, punto 4). La copia del seed espera 120 s dentro de la transaccion; se envia la senal con el esquema seed ya creado.
mkdir -p /tmp/c57_int
for sig in HUP TERM; do
  cp $SEED/*.sql $SEED/*.sh /tmp/c57_int/
  awk '/^DO \$demo\$/ { print "SELECT pg_sleep(120);" } { print }' /tmp/c57_int/20_demo.sql > /tmp/c57_int/20_demo.x && mv /tmp/c57_int/20_demo.x /tmp/c57_int/20_demo.sql
  PG "DROP DATABASE IF EXISTS $S4 WITH (FORCE)"; clon $S4
  BASE=$S4 SEED_DIR=/tmp/c57_int sh $SEED/sembrar.sh demo >/tmp/c57_int.out 2>&1 </dev/null &
  SPID=$!
  i=0; while [ $i -lt 30 ]; do [ "$(psql -X -q -At -U postgres -d postgres -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$S4' AND application_name = 'sembrar_seed' AND query LIKE 'SELECT pg_sleep%'" </dev/null)" = "1" ] && break; i=$((i+1)); sleep 1; done
  ANTES=$(psql -X -q -At -U postgres -d $S4 -c "SELECT to_regnamespace('seed') IS NOT NULL" </dev/null)
  T0=$(date +%s); kill -$sig $SPID; wait $SPID; RC=$?; T1=$(date +%s)
  case $sig in HUP) ESP=129;; TERM) ESP=143;; esac
  SES=$(psql -X -q -At -U postgres -d $S4 -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$S4' AND application_name = 'sembrar_seed'" </dev/null)
  RES=$(psql -X -q -At -U postgres -d $S4 -c "SELECT (SELECT count(*) FROM public.usuario) || '|' || (SELECT count(*) FROM public.transaccion) || '|' || (to_regnamespace('seed') IS NOT NULL) || '|' || (SELECT usar_fecha_real FROM public.reloj) || '|' || coalesce((SELECT fecha_sistema::text FROM public.reloj), '')" </dev/null)
  eq "C11 una senal $sig durante la historia (con el esquema seed YA creado): el script termina con codigo $ESP en menos de 20 s, el esquema seed queda ELIMINADO, la sesion del seed se cierra y no queda NADA (0 usuarios, 0 patas, reloj real sin fecha manual)" "t|$ESP|t|0|0|0|false|true|" "$ANTES|$RC|$([ $((T1 - T0)) -lt 20 ] && echo t || echo f)|$SES|$RES"
done
PG "DROP DATABASE IF EXISTS $S4 WITH (FORCE)"
# las funciones solo-seed por si solas (esquema cargado a mano): protecciones de uso
psql -X -q -v ON_ERROR_STOP=1 -U postgres -d $S3 -f $SEED/00_catalogo.sql >/dev/null 2>&1 </dev/null
psql -X -q -v ON_ERROR_STOP=1 -U postgres -d $S3 -f $SEED/10_funciones_seed.sql >/dev/null 2>&1 </dev/null
O1=$(root "SELECT seed.cliente('Ana', 'Prueba', '9700001', 'ana.s@mail.co', '3109700001', '1990-05-17', 'ana1x', '4090000001')" 2>&1)
eq "C6 seed.cliente crea un cliente con username y cuenta fijos y la cuenta tiene sus 5 ingresos simulados" "ana1x|4090000001|5" "$(root "SELECT u.username || '|' || c.numero_cuenta || '|' || (SELECT count(DISTINCT grupo_id) FROM public.transaccion t WHERE t.cuenta_id = c.id AND t.tipo = 'INGRESO_SIMULADO') FROM public.usuario u JOIN public.cuenta c ON c.usuario_id = u.id WHERE u.username = 'ana1x'")"
UA=$(root "SELECT id FROM public.usuario WHERE username = 'ana1x'")
O2=$(root "SELECT seed.cliente('Beto', 'Prueba', '9700002', 'beto.s@mail.co', '3109700002', '1991-02-10', 'Beto', '4090000002')")
eq "C7 seed.cliente con un username que no cumple el formato se rechaza (y no deja el cliente a medias)" "t|0" "$(printf '%s' "$O2" | grep -qi 'username invalido' && echo t || echo f)|$(root "SELECT count(*) FROM public.usuario WHERE cedula = '9700002'")"
root "SELECT public.crear_bolsillo('$UA', 'Despues')" >/dev/null
O3=$(root "SELECT seed.fijar_identidad('$UA', 'otro1x', '4090000003', NULL)")
eq "C8 seed.fijar_identidad se RECHAZA si el cliente ya tiene operaciones (solo vale justo despues de registrar)" "t|ana1x|4090000001" "$(printf '%s' "$O3" | grep -qi 'ya tiene operaciones' && echo t || echo f)|$(root "SELECT u.username || '|' || c.numero_cuenta FROM public.usuario u JOIN public.cuenta c ON c.usuario_id = u.id WHERE u.id = '$UA'")"
O4=$(root "SELECT seed.crear_admin('admin9', 'Otro', 'Admin', '9700009', 'a9@mail.co', '3109700009', DATE '1985-01-01')")
eq "C9 seed.crear_admin se RECHAZA con el libro ya operando (solo sobre un banco vacio de operaciones)" "t|0" "$(printf '%s' "$O4" | grep -qi 'banco vacio' && echo t || echo f)|$(root "SELECT count(*) FROM public.usuario WHERE username = 'admin9'")"
eq "C10 session_replication_role queda en 'origin' tras fijar identidad (no se filtra la excepcion de triggers)" "origin" "$(root "SHOW session_replication_role")"
psql -X -q -U postgres -d $S3 -c "DROP SCHEMA IF EXISTS seed CASCADE" >/dev/null 2>&1 </dev/null

# ============================================================================
# D. Reproducibilidad funcional (dos siembras independientes)
# ============================================================================
clon $S2; sembrar $S2 demo >/dev/null
func() { # huella FUNCIONAL: todo salvo uuid, instantes y orden fisico dentro del mismo dia (el libro como multiconjunto por dia); fechas como desfase respecto del hoy real
  psql -X -q -At -U postgres -d "$1" -c "SELECT md5(concat_ws('#',
    (SELECT string_agg(u.username || '|' || u.rol || '|' || u.estado || '|' || u.nombres || '|' || u.apellidos || '|' || u.cedula || '|' || u.correo || '|' || u.telefono || '|' || u.fecha_nacimiento || '|' || CASE WHEN u.username IN ('jperez483', 'cgomez12', 'bloqueado1') THEN u.codigo_referido::text ELSE '' END || '|' || coalesce(c.numero_cuenta, '') || '|' || coalesce(c.balance::text, '') || '|' || coalesce(r.username, ''), ';' ORDER BY u.username)
       FROM public.usuario u LEFT JOIN public.cuenta c ON c.usuario_id = u.id LEFT JOIN public.usuario r ON r.id = u.referido_por),
    (SELECT string_agg(us.username || ':' || t.dias || ':' || t.tipo || t.sentido || t.contenedor || t.monto || ':' || coalesce(t.nota, '') || ':' || coalesce(t.contraparte_nombre, '') || ':' || coalesce(t.contraparte_cuenta, ''), ';' ORDER BY us.username, t.dias, t.tipo, t.sentido, t.contenedor, t.monto, coalesce(t.nota, ''))
       FROM (SELECT x.*, (x.fecha AT TIME ZONE 'America/Bogota')::date - public.hoy_banco() AS dias FROM public.transaccion x) t
       JOIN public.cuenta c ON c.id = t.cuenta_id JOIN public.usuario us ON us.id = c.usuario_id),
    (SELECT string_agg(b.nombre || ':' || b.balance, ';' ORDER BY b.nombre, b.balance) FROM public.bolsillo b),
    (SELECT string_agg(d.estado || ':' || d.monto || ':' || d.tasa_anual || ':' || d.plazo_dias || ':' || d.generado_acumulado, ';' ORDER BY d.estado, d.monto) FROM public.cdt d),
    (SELECT string_agg(k.estado || ':' || k.monto || ':' || k.tasa_anual || ':' || k.plazo_meses || ':' || k.capital_pendiente || ':' || k.descuento_automatico, ';' ORDER BY k.monto) FROM public.credito k)))" 2>&1 </dev/null
}
F1=$(func $S1); F2=$(func $S2)
eq "D1 REPRODUCIBLE: dos siembras en bases distintas dan el MISMO estado funcional (usuarios, cuentas, codigos, libro con montos, notas y contrapartes, bolsillos, CDT y creditos)" "$F1" "$F2"
eq "D2 ...aunque los identificadores internos (uuid) son distintos: no es una copia byte a byte, es la misma historia" "t" "$(psql -X -q -At -U postgres -d $S1 -c "SELECT (SELECT id FROM public.usuario WHERE username = 'jperez483')::text" 2>&1 </dev/null > /tmp/c57_u1; psql -X -q -At -U postgres -d $S2 -c "SELECT id::text FROM public.usuario WHERE username = 'jperez483'" > /tmp/c57_u2 2>&1 </dev/null; [ "$(cat /tmp/c57_u1)" != "$(cat /tmp/c57_u2)" ] && echo t || echo f)"
eq "D3 un seed sin setseed no seria igual: con setseed el saldo inicial de jperez483 es el mismo en las dos siembras" "$(psql -X -q -At -U postgres -d $S1 -c "SELECT balance FROM public.cuenta WHERE numero_cuenta = '4001002003'" </dev/null)" "$(psql -X -q -At -U postgres -d $S2 -c "SELECT balance FROM public.cuenta WHERE numero_cuenta = '4001002003'" </dev/null)"
PG "DROP DATABASE IF EXISTS $S2 WITH (FORCE)"

# ============================================================================
# E. Recorrido de banco_app por TCP sobre el seed (sin superusuario)
# ============================================================================
DB=$S1
CR=$(as banco_app "$APP_PW" "SELECT usuario_id || '|' || rol || '|' || estado || '|' || (password_hash = crypt('Banco2026', password_hash)) FROM public.obtener_credenciales('jperez483')")
eq "E1 LOGIN: obtener_credenciales('jperez483') por TCP entrega usuario, rol y estado; la clave Banco2026 coincide con el hash (el backend compara con bcrypt)" "$JP|CLIENTE|ACTIVO" "$(printf '%s' "$CR" | sed 's/|true$//' | head -n1)"
eq "E2 validar_sesion y vista_perfil de jperez483: username, cuenta 4001002003 y el codigo de referido fijo" "jperez483|CLIENTE|ACTIVO|4001002003|8f3c2a10-5b7e-4d3a-9c21-6a7b1d0e42f9" "$(as banco_app "$APP_PW" "SELECT (public.validar_sesion('$JP') ->> 'username') || '|' || (public.validar_sesion('$JP') ->> 'rol') || '|' || (public.validar_sesion('$JP') ->> 'estado') || '|' || (public.vista_perfil('$JP') ->> 'numero_cuenta') || '|' || (public.vista_perfil('$JP') ->> 'codigo_referido')")"
DASH=$(as banco_app "$APP_PW" "SELECT public.vista_dashboard('$JP')")
eq "E3 vista_dashboard: nombre Juan, balance_total > 0, 1 CDT activo, cuota por pagar > 0 e interes corriendo > 0; 8 transacciones a lo sumo" "Juan|t|1|t|t|8" "$(J "$DASH" nombre)|$(root "SELECT ((\$j\$$DASH\$j\$::jsonb ->> 'balance_total')::numeric > 0)::text" | sed 's/true/t/')|$(root "SELECT \$j\$$DASH\$j\$::jsonb #>> '{cdts,activos}'")|$(root "SELECT ((\$j\$$DASH\$j\$::jsonb #>> '{creditos,cuota_por_pagar}')::numeric > 0)::text" | sed 's/true/t/')|$(root "SELECT ((\$j\$$DASH\$j\$::jsonb #>> '{creditos,interes_corriendo}')::numeric > 0)::text" | sed 's/true/t/')|$(root "SELECT jsonb_array_length(\$j\$$DASH\$j\$::jsonb -> 'transacciones')")"
eq "E4 vista_historial(50): 50 filas; vista_balance: 2 bolsillos y total = principal + bolsillos + CDT activos (D6 provisional)" "50|t|t" "$(as banco_app "$APP_PW" "SELECT jsonb_array_length(public.vista_historial('$JP', 50))")|$(as banco_app "$APP_PW" "SELECT (SELECT jsonb_array_length(b -> 'bolsillos') = 2 FROM (SELECT public.vista_balance('$JP') b) x)::text" | sed 's/true/t/')|$(as banco_app "$APP_PW" "SELECT (abs((b ->> 'total')::numeric - (b ->> 'principal')::numeric - (SELECT sum((e ->> 'saldo')::numeric) FROM jsonb_array_elements(b -> 'bolsillos') e) - (SELECT coalesce(sum((c ->> 'monto')::numeric + (c ->> 'generado_hasta_hoy')::numeric), 0) FROM jsonb_array_elements(public.vista_cdts('$JP')) c WHERE c ->> 'tiempo_restante' <> 'Cerrado')) < 0.01)::text FROM (SELECT public.vista_balance('$JP') b) x" | sed 's/true/t/')"
eq "E5 vista_cdts: 2 (uno 'Cerrado' y otro con tiempo restante) y vista_creditos: 2" "2|1|2" "$(as banco_app "$APP_PW" "SELECT jsonb_array_length(public.vista_cdts('$JP'))")|$(as banco_app "$APP_PW" "SELECT count(*) FROM jsonb_array_elements(public.vista_cdts('$JP')) e WHERE e ->> 'tiempo_restante' = 'Cerrado'")|$(as banco_app "$APP_PW" "SELECT jsonb_array_length(public.vista_creditos('$JP'))")"
eq "E6 catalogo visible para el cliente: productos_disponibles = 4 productos, listar_cdt_definiciones = 3, productos_publicos (landing) = 4 con descripcion" "4|3|4|t" "$(as banco_app "$APP_PW" "SELECT jsonb_array_length(public.productos_disponibles('$JP'))")|$(as banco_app "$APP_PW" "SELECT jsonb_array_length(public.listar_cdt_definiciones('$JP'))")|$(as banco_app "$APP_PW" "SELECT jsonb_array_length(public.productos_publicos())")|$(as banco_app "$APP_PW" "SELECT bool_and(length(e ->> 'descripcion') > 0)::text FROM jsonb_array_elements(public.productos_publicos()) e" | sed 's/true/t/')"
PLIB=$(root "SELECT id FROM public.credito_producto WHERE nombre = 'Libre inversión'"); CDEF=$(root "SELECT id FROM public.cdt_definicion WHERE nombre = 'CDT 90 días'"); PINM=$(root "SELECT id FROM public.credito_producto WHERE nombre = 'Inmuebles'")
eq "E7 simulaciones: simular_cdt de 1.000.000 a 90 dias y simular_credito de Inmuebles dentro del tope devuelven los campos del contrato" "t|t" "$(as banco_app "$APP_PW" "SELECT (public.simular_cdt('$JP', '$CDEF', 1000000) ? 'generado_vencimiento')::text" | sed 's/true/t/')|$(as banco_app "$APP_PW" "SELECT (public.simular_credito('$JP', '$PINM', 20000000, 60) ? 'cuota_mensual')::text" | sed 's/true/t/')"
eq "E8 reglas del contrato sobre los datos sembrados: un 2.o credito vivo del mismo producto y un CDT bajo el minimo se rechazan con el mensaje exacto" "Ya tienes un crédito vigente de este producto|Monto por debajo del mínimo del CDT" "$(as banco_app "$APP_PW" "SELECT public.solicitar_credito('$JP', '$PLIB', 2000000, 12)" | sed 's/^ERROR:  //' | head -n1)|$(as banco_app "$APP_PW" "SELECT public.crear_cdt('$JP', '$CDEF', 50000)" | sed 's/^ERROR:  //' | head -n1)"
eq "E9 cgomez12 envia 100 a la cuenta 4001002003 y jperez483 la ve como RECIBO mas reciente de 'Prueba de recorrido' (el recorrido real entre dos clientes sembrados)" "recibo|Prueba de recorrido|100.00" "$(as banco_app "$APP_PW" "SELECT public.hacer_transferencia('$CG', '4001002003', 100, 'Prueba de recorrido', NULL)" >/dev/null; as banco_app "$APP_PW" "SELECT (e ->> 'tipo') || '|' || (e ->> 'nota') || '|' || (e ->> 'monto') FROM jsonb_array_elements(public.vista_historial('$JP', 1)) e")"
eq "E10 bloqueado1 (sesion abierta en el backend): validar_sesion y vista_dashboard devuelven el mensaje EXACTO de bloqueo" "Tu cuenta ha sido restringida, contacte con el banco para desbloquearla|Tu cuenta ha sido restringida, contacte con el banco para desbloquearla" "$(as banco_app "$APP_PW" "SELECT public.validar_sesion('$BL')" | sed 's/^ERROR:  //' | head -n1)|$(as banco_app "$APP_PW" "SELECT public.vista_dashboard('$BL')" | sed 's/^ERROR:  //' | head -n1)"
eq "E11 admin1: admin_esquema devuelve las 11 tablas, admin_tabla('usuario') enmascara el hash y admin_listar_usuarios(cuenta 4001002003) lo encuentra" "11|••••|t|1" "$(as banco_app "$APP_PW" "SELECT jsonb_array_length(public.admin_esquema('$AD') -> 'tablas')")|$(as banco_app "$APP_PW" "SELECT (public.admin_tabla('$AD', 'usuario', '1') -> 'filas' -> 0 ->> 'password_hash')")|$(as banco_app "$APP_PW" "SELECT (SELECT bool_and(e ->> 'password_hash' = '••••') FROM jsonb_array_elements(public.admin_tabla('$AD', 'usuario', '1') -> 'filas') e)::text" | sed 's/true/t/')|$(as banco_app "$APP_PW" "SELECT jsonb_array_length(public.admin_listar_usuarios('$AD', '4001002003'))")"
eq "E12 un cliente NO puede usar las funciones de admin sobre los datos sembrados: Acceso denegado" "Acceso denegado" "$(as banco_app "$APP_PW" "SELECT public.admin_esquema('$JP')" | sed 's/^ERROR:  //' | head -n1)"
GEN0=$(root "SELECT (\$j\$$DASH\$j\$::jsonb #>> '{cdts,generado}')::numeric"); BAL0=$(root "SELECT sum((e ->> 'saldo')::numeric) FROM jsonb_array_elements(public.vista_balance('$JP') -> 'bolsillos') e"); HIST0=$(root "SELECT count(*) FROM public.transaccion WHERE tipo = 'INTERES_BOLSO'")
root "SELECT public.admin_set_reloj('$AD', false, (public.hoy_banco() + 30)::text)" >/dev/null
DASH30=$(as banco_app "$APP_PW" "SELECT public.vista_dashboard('$JP')")
BAL30=$(root "SELECT sum((e ->> 'saldo')::numeric) FROM jsonb_array_elements(public.vista_balance('$JP') -> 'bolsillos') e")
eq "E13 contrato §8 sobre el seed: con el reloj adelantado 30 dias, vista_dashboard YA trae el interes cobrado (generado del CDT y saldo de bolsillos mayores) y el interes de bolsillos quedo escrito en el libro" "t|t|t" "$(root "SELECT ((\$j\$$DASH30\$j\$::jsonb #>> '{cdts,generado}')::numeric > $GEN0)::text" | sed 's/true/t/')|$(root "SELECT ($BAL30 > $BAL0)::text" | sed 's/true/t/')|$(root "SELECT (count(*) > $HIST0)::text FROM public.transaccion WHERE tipo = 'INTERES_BOLSO'" | sed 's/true/t/')"
eq "E14 tras todo el recorrido (y el adelanto de 30 dias) la integridad sigue en orden" "t|0" "$(root "SELECT ok || '|' || defensas_fallidas FROM public.v_integridad_global" | sed 's/^true/t/')"
fin
