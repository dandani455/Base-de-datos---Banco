#!/bin/sh
# 59_volumen.sh - Etapa 14 (D-E14-7) - Volumen ACOTADO por las funciones REALES, en una BD aislada (banco_vol): ~300 clientes y > 15.000 patas.
#   Mide (sin cotas estrictas, solo anti-regresion amplias): busqueda de admin, pagina de tabla grande, historial, y sp_avanzar_todos con TRABAJO REAL en todas las
#   cuentas (reloj +40 dias, un bolsillo por cliente). La integridad debe seguir intacta. Imprime los tiempos y los EXPLAIN como lineas "info:" (evidencia).
. /work/tests/reales/lib.sh
V=banco_vol
limpiar() { psql -X -q -U postgres -d postgres -c "DROP DATABASE IF EXISTS $V WITH (FORCE)" >/dev/null 2>&1 </dev/null; [ -n "$KEEP59" ] || rm -f /tmp/c59_*; }
trap limpiar EXIT
limpiar
PG() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$1" >/dev/null 2>&1 </dev/null; }
# tm ROL CLAVE SQL : ejecuta SQL (por el socket si ROL = postgres; por TCP con contrasena si no) y deja en MS el tiempo en milisegundos y en RES el resultado
tm() {
  if [ "$1" = postgres ]; then _o=$(psql -X -q -At -U postgres -d "$DB" -c "SELECT clock_timestamp()" -c "$3" -c "SELECT clock_timestamp()" 2>&1 </dev/null)
  else _o=$(PGPASSWORD="$2" psql -X -q -At -h "$HOST" -U "$1" -d "$DB" -c "SELECT clock_timestamp()" -c "$3" -c "SELECT clock_timestamp()" 2>&1 </dev/null); fi
  _t0=$(printf '%s
' "$_o" | head -n1); _t1=$(printf '%s
' "$_o" | tail -n1); RES=$(printf '%s
' "$_o" | sed '1d;$d')
  MS=$(psql -X -q -At -U postgres -d postgres -c "SELECT round(extract(epoch FROM ('$_t1'::timestamptz - '$_t0'::timestamptz)) * 1000)" </dev/null)
}
PG "CREATE DATABASE $V" && PG "ALTER DATABASE $V SET timezone TO 'America/Bogota'"
for f in /work/sql/*.sql; do psql -X -q -v ON_ERROR_STOP=1 -U postgres -d $V -f "$f" >/dev/null 2>&1 </dev/null || { fail "no se pudo aplicar $f"; fin; exit 1; }; done
BASE=$V sh /work/seed/sembrar.sh catalogo >/dev/null 2>&1 </dev/null
DB=$V
HASH='$2a$10$NMLfLjyJywHJyB0aLK92VOZdoC4A82BHFFTmkfQhk8JSi9whFuDOa'
root "INSERT INTO public.usuario (username, password_hash, nombres, apellidos, cedula, correo, telefono, fecha_nacimiento, rol, estado, correoverificado) VALUES ('admin1', '$HASH', 'Admin', 'Banco', '900100200', 'admin@bancodigital.co', '3100000000', DATE '1985-03-12', 'ADMIN', 'ACTIVO', true)" >/dev/null
ADM=$(root "SELECT id FROM public.usuario WHERE username = 'admin1'")

# ---- carga: 300 clientes (registrar_usuario), un bolsillo con dinero cada uno y 6.000 transferencias aleatorias (hacer_transferencia) ----
T0=$(date +%s)
psql -X -q -v ON_ERROR_STOP=1 -U postgres -d $V >/tmp/c59_carga.out 2>&1 </dev/null <<SQL
DO \$carga\$
DECLARE i integer; u uuid; ids uuid[] := ARRAY[]::uuid[]; nums text[] := ARRAY[]::text[]; a integer; b integer; v_b text;
BEGIN
  FOR i IN 1 .. 300 LOOP
    u := (public.registrar_usuario('Cliente' || translate(i::text, '0123456789', 'abcdefghij'), 'Volumen' || translate(i::text, '0123456789', 'abcdefghij'), (2000000 + i)::text, 'vol' || i || '@mail.co', (3200000000 + i)::text, '1990-01-15', '$HASH', true, NULL, false) ->> 'usuario_id')::uuid;
    ids := ids || u;
    nums := nums || (SELECT numero_cuenta FROM public.cuenta WHERE usuario_id = u);
  END LOOP;
  FOR i IN 1 .. 300 LOOP
    v_b := public.crear_bolsillo(ids[i], 'Ahorro') ->> 'id';
    PERFORM public.mover_a_bolsillo(ids[i], v_b, 20000);
  END LOOP;
  FOR i IN 1 .. 6000 LOOP
    a := 1 + floor(random() * 300)::int; b := 1 + floor(random() * 300)::int;
    IF a <> b THEN
      BEGIN
        PERFORM public.hacer_transferencia(ids[a], nums[b], 1000 + floor(random() * 5000)::int, 'volumen ' || i, NULL);
      EXCEPTION WHEN OTHERS THEN NULL;       -- saldo insuficiente ocasional: se ignora
      END;
    END IF;
  END LOOP;
END
\$carga\$;
SQL
RC=$?; T1=$(date +%s)
eq "V0 la carga con funciones reales termina bien (300 clientes, 300 bolsillos, 6.000 transferencias)" "0" "$RC"
echo "info: carga $((T1 - T0)) s: $(root "SELECT 'cuentas=' || cuentas || ' grupos=' || grupos || ' patas=' || patas FROM public.v_integridad_global")"
eq "V1 el banco tiene >= 300 clientes y mas de 15.000 patas en el libro, y la integridad esta en orden tras la carga" "t|t|true|0" "$(root "SELECT ((SELECT count(*) FROM public.cuenta) >= 300)::text || '|' || (patas > 15000)::text || '|' || ok || '|' || defensas_fallidas FROM public.v_integridad_global" | sed 's/^true|/t|/;s/|true|/|t|/')"

# ---- lecturas ----
tm postgres x "SELECT jsonb_array_length(public.admin_listar_usuarios('$ADM', 'volumenbfa'))"
echo "info: admin_listar_usuarios('volumenbfa') = $RES fila(s) en $MS ms"
eq "V2 la busqueda de admin por nombre encuentra al cliente (150) y tarda menos de 2 s con 300 clientes" "1|t" "$RES|$([ "$MS" -lt 2000 ] && echo t || echo f)"
tm postgres x "SELECT jsonb_array_length(public.admin_tabla('$ADM', 'transaccion', '99999') -> 'filas')"
echo "info: admin_tabla('transaccion', ultima pagina) = $RES fila(s) en $MS ms (50 por pagina)"
eq "V3 la ULTIMA pagina de transaccion (mas de 15.000 filas) responde en menos de 2 s y trae como maximo 50 filas" "t|t" "$([ "$RES" -ge 1 ] && [ "$RES" -le 50 ] && echo t || echo f)|$([ "$MS" -lt 2000 ] && echo t || echo f)"
U1=$(root "SELECT id FROM public.usuario WHERE username <> 'admin1' ORDER BY (SELECT count(*) FROM public.transaccion t WHERE t.cuenta_id = (SELECT id FROM public.cuenta WHERE usuario_id = usuario.id)) DESC LIMIT 1")
tm banco_app "$APP_PW" "SELECT jsonb_array_length(public.vista_historial('$U1', 50))"
echo "info: vista_historial(50) del cliente con mas movimientos = $RES fila(s) en $MS ms (conexion real de banco_app)"
eq "V4 el historial de 50 del cliente con mas movimientos tarda menos de 1 s por la conexion real de banco_app" "50|t" "$RES|$([ "$MS" -lt 1000 ] && echo t || echo f)"
echo "info: EXPLAIN historial (indice ix_transaccion_cuenta_orden):"
PLAN=$(psql -X -q -At -U postgres -d $V -c "EXPLAIN (COSTS OFF) SELECT t.id FROM public.transaccion t WHERE t.cuenta_id = '$(root "SELECT id FROM public.cuenta WHERE usuario_id = '$U1'")' ORDER BY t.orden DESC LIMIT 50" 2>&1 </dev/null)
printf '%s
' "$PLAN" | sed 's/^/info:   /'
eq "V5 el plan del historial sobre el libro grande usa el indice ix_transaccion_cuenta_orden" "t" "$(printf '%s' "$PLAN" | grep -q 'ix_transaccion_cuenta_orden' && echo t || echo f)"
echo "info: EXPLAIN de la busqueda de admin con seqscan desactivado (muestra si algun indice sirve): $(psql -X -q -At -U postgres -d $V -c "SET enable_seqscan = off" -c "EXPLAIN (COSTS OFF) SELECT us.id FROM public.usuario us JOIN public.cuenta c ON c.usuario_id = us.id WHERE public.unaccent(us.nombres || ' ' || us.apellidos) ILIKE public.unaccent('%volumenbfa%')" 2>&1 </dev/null | tr '\n' ' ')"

# ---- el cierre con trabajo real en todas las cuentas ----
root "SELECT public._reloj_actualizar(false, (public.hoy_banco() + 40)::text)" >/dev/null
S=$(date +%s); RES=$(psql -X -q -At -U postgres -d $V -c "CALL public.sp_avanzar_todos()" 2>/dev/null </dev/null); E=$(date +%s)
echo "info: sp_avanzar_todos con trabajo real en todas las cuentas: $((E - S)) s -> $RES"
eq "V6 sp_avanzar_todos pone al dia las >= 300 cuentas (cada una con un bolsillo que devengo 40 dias): con_cambios = cuentas con bolsillo, sin errores ni omitidas" "t|0|0|t" "$(root "SELECT (($(psql -X -q -At -U postgres -d $V -c "SELECT \$j\$$RES\$j\$::jsonb ->> 'con_cambios'" </dev/null)) >= 300)::text" | sed 's/true/t/')|$(psql -X -q -At -U postgres -d $V -c "SELECT \$j\$$RES\$j\$::jsonb ->> 'con_error'" </dev/null)|$(psql -X -q -At -U postgres -d $V -c "SELECT \$j\$$RES\$j\$::jsonb ->> 'omitidas_por_timeout_de_bloqueo'" </dev/null)|$(psql -X -q -At -U postgres -d $V -c "SELECT (\$j\$$RES\$j\$::jsonb ->> 'procesadas' = \$j\$$RES\$j\$::jsonb ->> 'cuentas')::text" </dev/null | sed 's/true/t/')"
eq "V7 el cierre completo con >= 300 cuentas y trabajo real tarda menos de 120 s (cota amplia)" "t" "$([ $((E - S)) -lt 120 ] && echo t || echo f)"
RES2=$(psql -X -q -At -U postgres -d $V -c "CALL public.sp_avanzar_todos()" 2>/dev/null </dev/null)
eq "V8 una segunda corrida no escribe nada (idempotente a escala) y el banco sigue integro" "0|t|0" "$(psql -X -q -At -U postgres -d $V -c "SELECT \$j\$$RES2\$j\$::jsonb ->> 'grupos'" </dev/null)|$(root "SELECT ok FROM public.v_integridad_global")|$(root "SELECT defensas_fallidas FROM public.v_integridad_global")"
fin
