#!/bin/sh
# mutaciones.sh - Etapa 2 - PRUEBAS DE MUTACION: ¿las pruebas detectan de verdad una defensa rota?
# Se corre DENTRO del contenedor "db" (ver docs/db/etapas/02-libro-mayor.md):
#   docker compose -f db/compose.dev.yml exec -T db sh -c "tr -d '\r' < /work/tests/mutaciones/mutaciones.sh | sh -s"
# Metodo: una base limpia (banco_mut_base: scripts 00-09 + helpers + harness) sirve de plantilla. Para CADA mutacion se
# clona a banco_mut, se rompe UNA cosa a proposito, y se ejecutan las pruebas en orden hasta que una FALLE (la mutacion fue
# detectada). Una mutacion que no hace fallar ninguna prueba demuestra un hueco en las pruebas. Salida: una linea por mutacion.
PGU="psql -X -q -At -U postgres"
FALLAS=0
TOTAL=0

# Los ROLES son globales del cluster: una mutacion de roles (GRANT de membresia, LOGIN) sobreviviria a DROP DATABASE y
# contaminaria las siguientes. Por eso se REPARAN antes de cada mutacion y al terminar (aunque falle o se interrumpa).
reparar_roles() {
  $PGU -d postgres -c "REVOKE banco_owner, banco_ledger FROM banco_app, banco_lector, banco_dev" -c "ALTER ROLE banco_owner NOLOGIN" -c "ALTER ROLE banco_ledger NOLOGIN" >/dev/null 2>&1
}
limpiar() { $PGU -d postgres -c "DROP DATABASE IF EXISTS banco_mut WITH (FORCE)" -c "DROP DATABASE IF EXISTS banco_mut_base WITH (FORCE)" >/dev/null 2>&1; reparar_roles; }
trap limpiar EXIT INT TERM
limpiar

# --- plantilla limpia ---------------------------------------------------------------------------------------------------
$PGU -d postgres -c "CREATE DATABASE banco_mut_base" -c "ALTER DATABASE banco_mut_base SET timezone TO 'America/Bogota'" >/dev/null
for f in /work/sql/*.sql; do $PGU -v ON_ERROR_STOP=1 -d banco_mut_base -f "$f" >/dev/null 2>&1 || { echo "ERROR aplicando $f"; exit 1; }; done
$PGU -v ON_ERROR_STOP=1 -d banco_mut_base -f /work/tests/helpers.sql >/dev/null 2>&1 || { echo "ERROR cargando helpers"; exit 1; }
$PGU -v ON_ERROR_STOP=1 -d banco_mut_base -f /work/tests/harness.sql >/dev/null 2>&1 || { echo "ERROR cargando harness"; exit 1; }
# la plantilla no debe estar siendo usada para poder clonarla
$PGU -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'banco_mut_base'" >/dev/null 2>&1

# repl FIRMA ANTES DESPUES : reemplaza texto en el cuerpo de una funcion (falla si el patron no existe)
repl() {
  [ "${SALTAR:-0}" = 1 ] && return 0
  $PGU -v ON_ERROR_STOP=1 -d banco_mut -c "DO \$m\$ DECLARE d text := pg_get_functiondef('$1'::regprocedure); BEGIN IF position(\$a\$$2\$a\$ in d) = 0 THEN RAISE EXCEPTION 'patron no encontrado'; END IF; EXECUTE replace(d, \$a\$$2\$a\$, \$b\$$3\$b\$); END \$m\$" >/dev/null 2>&1 || { echo "ERROR: no se pudo aplicar la mutacion repl $1"; exit 1; }
}
sqlm() { [ "${SALTAR:-0}" = 1 ] && return 0; $PGU -v ON_ERROR_STOP=1 -d banco_mut -c "$1" >/dev/null 2>&1 || { echo "ERROR: no se pudo aplicar la mutacion: $1"; exit 1; }; }

# nueva_mutacion ID DESCRIPCION : clona la plantilla
nueva() {
  ID="$1"; DESC="$2"; NUM=${ID#M}
  if [ "$NUM" -lt "${DESDE:-0}" ]; then SALTAR=1; return 0; fi        # DESDE=N: solo corre las mutaciones M>=N (para repetir un subconjunto)
  if [ -n "${SOLO:-}" ]; then case " $SOLO " in *" $ID "*) ;; *) SALTAR=1; return 0;; esac; fi        # SOLO="M56 M68": solo esas mutaciones
  SALTAR=0; TOTAL=$((TOTAL+1))
  reparar_roles
  $PGU -d postgres -c "DROP DATABASE IF EXISTS banco_mut WITH (FORCE)" -c "CREATE DATABASE banco_mut TEMPLATE banco_mut_base" >/dev/null 2>&1 || { echo "ERROR clonando la plantilla"; exit 1; }
  $PGU -d postgres -c "ALTER DATABASE banco_mut SET timezone TO 'America/Bogota'" -c "ALTER DATABASE banco_mut SET search_path TO public, tests" \
       -c "REVOKE ALL ON DATABASE banco_mut FROM PUBLIC" -c "GRANT CONNECT ON DATABASE banco_mut TO banco_app, banco_lector, banco_dev" >/dev/null 2>&1
}

# detectar [reales...] : corre las pruebas SQL en orden y luego (opcional) scripts reales; imprime quien detecto la mutacion
detectar() {
  [ "${SALTAR:-0}" = 1 ] && return 0
  QUIEN=""
  for t in ${PRIMERO:-} ${BASE_SQL-08_permisos 10_libro_triggers 11_libro_guardias 12_libro_asentar 13_libro_cuadre 14_libro_cdt 15_libro_inmutable 16_integridad_vistas \
           30_reloj_funciones 31_reloj_trigger 32_reloj_banco_vacio 33_reloj_libro 34_reloj_retorno_simulacion 35_reloj_viaje_tiempo \
           40_auth_normalizacion 44_auth_sesion 45_auth_permisos 46_auth_reloj 48_auth_atomicidad 43_auth_referidos 41_auth_registro 42_auth_ingresos 47_auth_aleatorio}; do
    if ! $PGU -v ON_ERROR_STOP=1 -d banco_mut -f /work/tests/$t.test.sql >/tmp/mut_out 2>&1; then
      QUIEN="$t"; MSG=$(grep -m1 -E 'FAIL:|ERROR:' /tmp/mut_out | sed 's/^psql:[^ ]* //' | cut -c1-150); break
    fi
  done
  if [ -z "$QUIEN" ]; then
    for r in "$@"; do
      if ! DB=banco_mut sh -c "tr -d '\r' < /work/tests/reales/$r.sh | sh -s" >/tmp/mut_out 2>&1; then
        QUIEN="reales/$r"; MSG=$(grep -m1 -E '^FAIL' /tmp/mut_out | cut -c1-150); break
      fi
    done
  fi
  if [ -n "$QUIEN" ]; then echo "$ID  DETECTADA  $DESC"; echo "      -> $QUIEN: $MSG"
  else echo "$ID  *** NO DETECTADA ***  $DESC"; FALLAS=$((FALLAS+1)); fi
}

# equivalente RAZON [reales...] : como detectar, pero una mutacion que NINGUNA prueba detecta se declara EQUIVALENTE (no observable) con su razon y no cuenta como hueco
equivalente() {
  [ "${SALTAR:-0}" = 1 ] && return 0
  _razon="$1"; shift; _f=$FALLAS; detectar "$@"
  if [ "$FALLAS" -gt "$_f" ]; then FALLAS=$_f; echo "      -> EQUIVALENTE (no observable, no es un hueco de pruebas): $_razon"; fi
}

echo "=== Pruebas de mutacion de E2 (cada una rompe UNA defensa y exige que alguna prueba falle) ==="
nueva M01 "se desactiva el guardia de cuenta.balance (trg_zz_proteger_cuenta)";                  sqlm "ALTER TABLE public.cuenta DISABLE TRIGGER trg_zz_proteger_cuenta"; detectar
nueva M02 "se desactiva el trigger que aplica los saldos (trg_transaccion_b_aplicar)";           sqlm "ALTER TABLE public.transaccion DISABLE TRIGGER trg_transaccion_b_aplicar"; detectar
nueva M03 "se elimina el trigger de cuadre (ct_transaccion_cuadre)";                             sqlm "DROP TRIGGER ct_transaccion_cuadre ON public.transaccion"; detectar
nueva M04 "se quita el sellado del grupo (patas agregadas despues de confirmar)";                repl "public.trg_transaccion_a_validar()" "AND t.tx_id <> NEW.tx_id" "AND false"; detectar 26_atomicidad_sellado
nueva M05 "el dueño recupera UPDATE sobre cuenta.balance";                                       sqlm "GRANT UPDATE (balance) ON public.cuenta TO banco_owner"; detectar
nueva M06 "el guardia confia en pg_trigger_depth() > 0 (banco_ledger podria actualizar a mano)"; repl "public.trg_zz_proteger_cuenta()" "pg_trigger_depth() > 1" "pg_trigger_depth() > 0"; detectar
nueva M07 "el guardia pasa a SECURITY DEFINER (veria al dueño, no a quien actualiza)";           sqlm "ALTER FUNCTION public.trg_zz_proteger_cuenta() SECURITY DEFINER"; detectar
nueva M08 "se permite el DELETE directo de patas";                                               repl "public.trg_transaccion_inmutable()" "IF EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = OLD.cuenta_id) THEN" "IF false THEN"; detectar
nueva M09 "se permite el UPDATE de patas";                                                       repl "public.trg_transaccion_inmutable()" "IF TG_OP = 'UPDATE' THEN" "IF false THEN"; detectar
nueva M10 "se elimina el trigger contra TRUNCATE del libro";                                     sqlm "DROP TRIGGER trg_transaccion_truncate ON public.transaccion"; detectar
nueva M11 "el dueño recupera UPDATE de tabla sobre transaccion";                                 sqlm "GRANT UPDATE ON public.transaccion TO banco_owner"; detectar
nueva M12 "banco_app recibe EXECUTE sobre _asentar_grupo";                                       sqlm "GRANT EXECUTE ON FUNCTION public._asentar_grupo(timestamptz, jsonb) TO banco_app"; detectar
nueva M13 "banco_app pasa a ser miembro de banco_ledger";                                        sqlm "GRANT banco_ledger TO banco_app"; detectar
nueva M14 "banco_owner pasa a poder iniciar sesion (LOGIN)";                                     sqlm "ALTER ROLE banco_owner LOGIN"; detectar
nueva M15 "se altera la plantilla BONO_REFERIDO (RESULTADO con sentido S)";                      repl "public._plantillas_validas()" "'BONO_REFERIDO|RESULTADO|E'" "'BONO_REFERIDO|RESULTADO|S'"; detectar
nueva M16 "el cuadre deja de comparar debitos con creditos";                                     repl "public.ct_transaccion_cuadre()" "IF g.debitos <> g.creditos_monto THEN" "IF false THEN"; detectar
nueva M17 "se eliminan los triggers de invariantes del CDT";                                     sqlm "DROP TRIGGER ct_cdt_inversion ON public.cdt; DROP TRIGGER ct_transaccion_cdt ON public.transaccion"; detectar
nueva M18 "el libro deja de rechazar saldos negativos (Saldo insuficiente)";                     repl "public.trg_transaccion_b_aplicar()" "IF v_post < 0 THEN" "IF false THEN"; detectar
nueva M19 "banco_ledger recibe SELECT de TABLA completa sobre cuenta";                           sqlm "GRANT SELECT ON public.cuenta TO banco_ledger"; detectar
nueva M20 "se desactiva la auditoria del borrado de cuentas";                                    sqlm "ALTER TABLE public.cuenta DISABLE TRIGGER trg_cuenta_auditar_borrado"; detectar
nueva M21 "sin bloqueo ordenado de cuentas ni insercion ordenada (deadlock en transferencias cruzadas)"
  repl "public._asentar_grupo(timestamptz, jsonb)" "PERFORM 1 FROM public.cuenta c WHERE c.id = ANY (v_cuentas) ORDER BY c.id FOR NO KEY UPDATE;" "PERFORM 1 FROM public.cuenta c WHERE c.id = ANY (v_cuentas);"
  repl "public._asentar_grupo(timestamptz, jsonb)" "ORDER BY x.cuenta_id, x.contenedor, coalesce(x.bolsillo_id, x.cdt_id, x.credito_id), x.sentido, x.tipo" "ORDER BY x.sentido DESC, x.tipo"
  detectar 23_concurrencia_cruzadas
nueva M22 "banco_ledger recibe UPDATE sobre cuenta.numero_cuenta";                                sqlm "GRANT UPDATE (numero_cuenta) ON public.cuenta TO banco_ledger"; detectar
nueva M23 "se elimina el guardia de cdt (trg_zz_proteger_cdt)";                                  sqlm "DROP TRIGGER trg_zz_proteger_cdt ON public.cdt"; detectar
nueva M24 "la funcion de aplicar cambia de dueño a banco_owner";                                 sqlm "ALTER FUNCTION public.trg_transaccion_b_aplicar() OWNER TO banco_owner"; detectar

echo ""
echo "=== Pruebas de mutacion de E3 (reloj bancario, opcion A) ==="
nueva M25 "se desactiva el trigger de validacion del reloj (trg_reloj_a_validar)";                 sqlm "ALTER TABLE public.reloj DISABLE TRIGGER trg_reloj_a_validar"; detectar
nueva M26 "el reloj manual puede retroceder (se quita la regla de no retroceso)";                  repl "public.trg_reloj_a_validar()" "IF NEW.fecha_sistema < v_hoy_old AND EXISTS (SELECT 1 FROM public.transaccion) THEN" "IF false THEN"; detectar
nueva M27 "se bloquea volver a fecha real (el modo real cae en la validacion manual)";             repl "public.trg_reloj_a_validar()" "IF NEW.usar_fecha_real THEN" "IF NEW.usar_fecha_real AND false THEN"; detectar
nueva M28 "al volver a real se conserva la fecha manual (desfase oculto)"
  repl "public.trg_reloj_a_validar()" "NEW.fecha_sistema := NULL;" "NULL;"
  repl "public._reloj_actualizar(boolean, text)" "UPDATE public.reloj SET usar_fecha_real = true, fecha_sistema = NULL WHERE id = 1;" "UPDATE public.reloj SET usar_fecha_real = true WHERE id = 1;"
  detectar
nueva M29 "se elimina el CHECK de rango de fecha_sistema";                                         sqlm "ALTER TABLE public.reloj DROP CONSTRAINT ck_reloj_fecha_rango"; detectar
nueva M30 "se elimina el trigger de auditoria del reloj";                                          sqlm "DROP TRIGGER trg_reloj_auditar ON public.reloj"; detectar
nueva M31 "banco_app recibe EXECUTE sobre hoy_banco()";                                            sqlm "GRANT EXECUTE ON FUNCTION public.hoy_banco() TO banco_app"; detectar 36_reloj_conexiones
nueva M32 "hoy_banco() usa current_date (zona de la sesion) en vez de America/Bogota";             repl "public.hoy_banco()" "public._hoy_de(r.usar_fecha_real, r.fecha_sistema, public._ahora_real())" "CASE WHEN r.usar_fecha_real THEN current_date ELSE r.fecha_sistema END"; detectar
nueva M33 "ahora_banco() descarta la hora real (medianoche de la sesion)";                         repl "public.ahora_banco()" "public._ahora_de(r.usar_fecha_real, r.fecha_sistema, public._ahora_real())" "public._hoy_de(r.usar_fecha_real, r.fecha_sistema, public._ahora_real())::timestamptz"; detectar
nueva M34 "el libro deja de rechazar patas fechadas despues del reloj";                            repl "public.trg_transaccion_a_validar()" "IF (NEW.fecha AT TIME ZONE 'America/Bogota')::date > public.hoy_banco() THEN" "IF false THEN"; detectar
nueva M35 "el libro compara instantes (timestamptz) en vez de fechas con el reloj";               repl "public.trg_transaccion_a_validar()" "(NEW.fecha AT TIME ZONE 'America/Bogota')::date > public.hoy_banco()" "NEW.fecha > public.ahora_banco()"; detectar
nueva M36 "_dias_por_cobrar genera dias con rangos negativos";                                     repl "public._dias_por_cobrar(date, date)" "generate_series(1, p_hasta - p_ultimo_cobro)" "generate_series(1, abs(p_hasta - p_ultimo_cobro))"; detectar
nueva M37 "_cuota_vencida cuenta como vencida la cuota que vence HOY";                             repl "public._cuota_vencida(date, boolean, date)" "p_fecha_vencimiento < p_hoy" "p_fecha_vencimiento <= p_hoy"; detectar
nueva M38 "el dueño recupera UPDATE de tabla completa sobre reloj";                                sqlm "GRANT UPDATE ON public.reloj TO banco_owner"; detectar
nueva M39 "la instantanea del reloj ya no toma FOR SHARE (el reloj cambia en medio de una operacion)"; repl "public._reloj_instantanea()" "WHERE x.id = 1 FOR SHARE;" "WHERE x.id = 1;"; detectar 36_reloj_conexiones 37_reloj_concurrencia
nueva M40 "el modo real toma la fecha de UTC/sesion en vez de America/Bogota";                      repl "public._hoy_de(boolean, date, timestamp with time zone)" "(p_instante AT TIME ZONE 'America/Bogota')::date" "p_instante::date"; detectar
nueva M41 "se elimina la proteccion contra DELETE del reloj";                                      sqlm "DROP TRIGGER trg_reloj_borrar ON public.reloj"; detectar
nueva M42 "se elimina la proteccion contra TRUNCATE del reloj";                                    sqlm "DROP TRIGGER trg_reloj_truncate ON public.reloj"; detectar
nueva M43 "se quita la clausula de banco vacio (el seed no podria arrancar en el pasado)";         repl "public.trg_reloj_a_validar()" " AND EXISTS (SELECT 1 FROM public.transaccion)" ""; detectar
nueva M44 "el retroceso se mide contra la fecha guardada y no contra el hoy real";                 repl "public.trg_reloj_a_validar()" "v_hoy_old := public._hoy_de(OLD.usar_fecha_real, OLD.fecha_sistema, public._ahora_real());" "v_hoy_old := OLD.fecha_sistema;"; detectar
nueva M45 "hoy_banco() deja de ser SECURITY DEFINER";                                              sqlm "ALTER FUNCTION public.hoy_banco() SECURITY INVOKER"; detectar 36_reloj_conexiones
nueva M46 "banco_app recibe UPDATE de columnas sobre reloj";                                       sqlm "GRANT UPDATE (usar_fecha_real, fecha_sistema) ON public.reloj TO banco_app"; detectar 36_reloj_conexiones
nueva M47 "se desactivan TODOS los triggers de usuario del reloj"; sqlm "ALTER TABLE public.reloj DISABLE TRIGGER USER"; detectar

echo ""
echo "=== Correccion de auditoria E3: _reloj_instantanea() toma PRIMERO el bloqueo y DESPUES el instante (reloj de pared) ==="
nueva M48 "el instante se captura ANTES de esperar el bloqueo (el defecto original: una espera cruzando la medianoche deja el dia viejo)"
  repl "public._reloj_instantanea()" "v_inst := public._ahora_real();" "NULL;"
  repl "public._reloj_instantanea()" "SELECT x.usar_fecha_real AS usar" "v_inst := public._ahora_real(); SELECT x.usar_fecha_real AS usar"
  detectar 38_reloj_instantanea
nueva M49 "_ahora_real() vuelve a now() (inicio de la transaccion): el instante queda obsoleto tras una espera";  repl "public._ahora_real()" "SELECT clock_timestamp()" "SELECT now()"; detectar 38_reloj_instantanea
nueva M50 "hoy_banco() deja de usar _ahora_real() (no se puede inyectar tiempo y se separa de la instantanea)";       repl "public.hoy_banco()" "public._hoy_de(r.usar_fecha_real, r.fecha_sistema, public._ahora_real())" "public._hoy_de(r.usar_fecha_real, r.fecha_sistema, now())"; detectar 38_reloj_instantanea


echo ""
echo "=== Pruebas de mutacion de E4 (autenticacion y registro) ==="
REG="public.registrar_usuario(text, text, text, text, text, text, text, boolean, text, boolean)"
BONO="public._pagar_bono_referido(uuid, timestamp with time zone)"
nueva M51 "la cedula acepta un + inicial (_norm_digitos no distingue el perfil cedula)";                          repl "public._norm_digitos(text, boolean)" "IF NOT coalesce(p_permite_mas_inicial, false) THEN RETURN NULL; END IF;" "NULL;"; detectar
nueva M52 "el telefono acepta un + en cualquier posicion (no solo al inicio)";                                   repl "public._norm_digitos(text, boolean)" "'^[0-9 ()-]+$'" "'^[0-9 ()+-]+$'"; detectar
nueva M53 "+57 y 10 digitos ya no se canoniza al numero nacional (el UNIQUE se burla con otro formato)";         repl "public._norm_telefono(text)" "IF d ~ '^57[0-9]{10}$' THEN RETURN substr(d, 3); END IF;" "NULL;"; detectar
nueva M54 "un telefono de 12 digitos SIN + se acepta (ambiguo)";                                                 repl "public._norm_telefono(text)" "IF length(d) <> (public._reglas_registro() ->> 'telefono_nacional_digitos')::int THEN RETURN NULL; END IF;" "NULL;"; detectar
nueva M55 "_es_hash_bcrypt acepta el prefijo 2c (que no existe)";                                                repl "public._es_hash_bcrypt(text)" "[aby]" "[abyc]"; detectar
nueva M56 "_nombre_valido deja pasar digitos NO ASCII (alfabeto arabe) en el nombre: [[:alpha:]] los acepta en esta configuracion regional";  repl "public._nombre_valido(text)" "0660-" "0664-"; detectar
nueva M57 "_nombre_valido solo acepta alfabeto latino (rechaza el nombre real en otro alfabeto)";                repl "public._nombre_valido(text)" "p_texto ~ '^[[:alpha:]]'" "p_texto ~ '^[a-zA-Z]'"; detectar
nueva M58 "_username_base sin respaldo: un nombre sin letras latinas produce NULL";                               repl "public._username_base(text, text)" "coalesce(substring(v_n FROM '[a-z]'), 'u')" "substring(v_n FROM '[a-z]')"; detectar
nueva M59 "_edad_en se adelanta un dia (la mayoria de edad se alcanza un dia antes)";                            repl "public._edad_en(date, date)" "age(p_hoy, p_nacimiento)" "age(p_hoy + 1, p_nacimiento)"; detectar
nueva M60 "registrar_usuario ya no exige aceptar la politica de datos";                                          repl "$REG" "IF p_acepta_politica IS NOT TRUE THEN" "IF false THEN"; detectar
nueva M61 "los duplicados de cedula ya no se detectan (ni el aviso previo ni la traduccion de la carrera del UNIQUE)"
  repl "$REG" "IF EXISTS (SELECT 1 FROM public.usuario WHERE cedula = v_cedula) THEN" "IF false THEN"
  repl "$REG" "IF v_con = 'uq_usuario_cedula' THEN" "IF false THEN"
  detectar
nueva M62 "se ignora la edad minima (un menor se registra)";                                                     repl "$REG" "IF v_edad < (public._reglas_registro() ->> 'edad_minima')::int THEN" "IF false THEN"; detectar
nueva M63 "la edad se mide con la fecha del sistema (current_date) y no con la instantanea del reloj del banco";   repl "$REG" "v_edad := public._edad_en(v_nac, v_hoy);" "v_edad := public._edad_en(v_nac, current_date);"; detectar
nueva M64 "los ingresos salen todos con la MISMA fecha y la autoverificacion esta desactivada"
  repl "$REG" "v_fechas := v_fechas || (v_ini + make_interval(secs => (v_k * v_ancho + floor(random() * v_ancho))::bigint));" "v_fechas := v_fechas || v_ini;"
  repl "$REG" "OR (v_k > 1 AND v_fechas[v_k] <= v_fechas[v_k - 1]) THEN" "OR false THEN"
  detectar
nueva M65 "la ventana de ingresos se duplica (fechas fuera de los 90 dias; la autoverificacion lo impide)";         repl "$REG" "v_total := v_dias::bigint * 86400 - v_margen;" "v_total := v_dias::bigint * 86400 * 2 - v_margen;"; detectar
nueva M66 "el bono no marca la bandera: se puede cobrar varias veces";                                           repl "$BONO" "UPDATE public.usuario SET bono_referido_pagado = true WHERE id = p_usuario_id;" "NULL;"; detectar
nueva M67 "el bono ya no mira si esta pagado: cada verificacion vuelve a pagar";                                 repl "$BONO" "IF NOT FOUND OR u.bono_referido_pagado OR u.referido_por IS NULL THEN" "IF NOT FOUND OR u.referido_por IS NULL THEN"; detectar
nueva M68 "verificar_correo y el bono sin bloqueo de la fila del referido y con el correo marcado AL FINAL (pagos simultaneos duplicados)"
  repl "$BONO" "SELECT * INTO u FROM public.usuario WHERE id = p_usuario_id FOR UPDATE;" "SELECT * INTO u FROM public.usuario WHERE id = p_usuario_id;"
  repl "public.verificar_correo(uuid)" "SELECT * INTO u FROM public.usuario WHERE id = p_usuario_id FOR UPDATE;" "SELECT * INTO u FROM public.usuario WHERE id = p_usuario_id;"
  repl "public.verificar_correo(uuid)" "UPDATE public.usuario SET correoverificado = true WHERE id = p_usuario_id;" "NULL;"
  repl "public.verificar_correo(uuid)" "PERFORM public._pagar_bono_referido(p_usuario_id, v_ahora);" "PERFORM public._pagar_bono_referido(p_usuario_id, v_ahora); UPDATE public.usuario SET correoverificado = true WHERE id = p_usuario_id;"
  detectar 40_auth_concurrencia
nueva M69 "el registro paga el bono aunque la verificacion este ACTIVA";                                         repl "$REG" "IF v_ref_id IS NOT NULL AND NOT coalesce(p_verificacion_activa, true) THEN" "IF v_ref_id IS NOT NULL THEN"; detectar
nueva M70 "p_verificacion_activa NULL se trata como apagada (paga dinero por una entrada ambigua)";             repl "$REG" "coalesce(p_verificacion_activa, true)" "coalesce(p_verificacion_activa, false)"; detectar
nueva M71 "verificar_correo no paga el bono";                                                                    repl "public.verificar_correo(uuid)" "PERFORM public._pagar_bono_referido(p_usuario_id, v_ahora);" "NULL;"; detectar
nueva M72 "un codigo de referido de un ADMIN se acepta (solo los CLIENTES refieren)";                           repl "$REG" "AND u.rol = 'CLIENTE';" ";"; detectar
nueva M73 "el codigo de referido invalido o inexistente se ignora en silencio";                                  repl "$REG" "RAISE EXCEPTION '%', public._msg_auth('referido') USING ERRCODE = 'P0001';" "NULL;"; detectar
nueva M74 "validar_sesion no rechaza al usuario BLOQUEADO";                                                      repl "public.validar_sesion(uuid)" "IF u.estado = 'BLOQUEADO' THEN" "IF false THEN"; detectar
nueva M75 "obtener_credenciales distingue mayusculas y espacios del username";                                   repl "public.obtener_credenciales(text)" "lower(btrim(p_username))" "p_username"; detectar
nueva M76 "_validar_cliente deja pasar a un ADMIN";                                                              repl "public._validar_cliente(uuid)" "IF u.rol <> 'CLIENTE' THEN" "IF false THEN"; detectar
nueva M77 "_validar_admin deja pasar a un CLIENTE";                                                              repl "public._validar_admin(uuid)" "IF NOT FOUND OR u.rol <> 'ADMIN' THEN" "IF NOT FOUND THEN"; detectar
nueva M78 "registrar_usuario acepta un hash que no es bcrypt (clave en claro)";                                  repl "$REG" "OR NOT public._es_hash_bcrypt(p_password_hash)" ""; detectar
nueva M79 "registrar_usuario toma la instantanea del reloj DOS veces";                                           repl "$REG" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i; PERFORM 1 FROM public._reloj_instantanea();"; detectar
nueva M80 "el registro fecha el bono con now() en vez del ahora de la instantanea";                               repl "$REG" "PERFORM public._pagar_bono_referido(v_id, v_ahora);" "PERFORM public._pagar_bono_referido(v_id, now());"; detectar
nueva M81 "_pagar_bono_referido consulta el reloj de pared en vez de usar el ahora que recibe";                   repl "$BONO" "PERFORM public._asentar_grupo(p_ahora, jsonb_build_array(" "PERFORM public._asentar_grupo(clock_timestamp(), jsonb_build_array("; detectar
nueva M82 "el fallo del bono se TRAGA (commit parcial: usuario registrado sin bono ni rollback)";                 repl "$REG" "PERFORM public._pagar_bono_referido(v_id, v_ahora);" "BEGIN PERFORM public._pagar_bono_referido(v_id, v_ahora); EXCEPTION WHEN OTHERS THEN NULL; END;"; detectar
nueva M83 "una colision de username deja de reintentarse (error en vez de otros digitos)";                       repl "$REG" "<> 'uq_usuario_username'" "<> 'uq_zzz'"; detectar
nueva M84 "el prefijo de cuenta cambia de 40 a 41 (valor centralizado)";                                         repl "public._reglas_registro()" "'40',  -- D-E4-4" "'41',  -- D-E4-4"; detectar
nueva M85 "el mensaje de la politica deja de ser el del contrato";                                               repl "public._msg_auth(text)" "'Debe aceptar la política de datos'" "'Debes aceptar la politica'"; detectar
nueva M86 "banco_app recibe EXECUTE de una funcion interna (_pagar_bono_referido)";                              sqlm "GRANT EXECUTE ON FUNCTION $BONO TO banco_app"; detectar 39_auth_conexiones
nueva M87 "PUBLIC recibe EXECUTE de obtener_credenciales";                                                       sqlm "GRANT EXECUTE ON FUNCTION public.obtener_credenciales(text) TO PUBLIC"; detectar
nueva M88 "banco_lector recibe EXECUTE de validar_sesion";                                                       sqlm "GRANT EXECUTE ON FUNCTION public.validar_sesion(uuid) TO banco_lector"; detectar 39_auth_conexiones
nueva M89 "banco_app recibe SELECT de la tabla usuario (veria password_hash)";                                   sqlm "GRANT SELECT ON public.usuario TO banco_app"; detectar 39_auth_conexiones
nueva M90 "el control de integridad de referidos se desactiva (siempre ok)";                                     sqlm "CREATE OR REPLACE VIEW public.v_integridad_auth AS SELECT 'x'::text AS control, true AS ok, ''::text AS detalle"; detectar
nueva M91 "registrar_usuario pierde su SECURITY DEFINER (el backend necesitaria privilegios sobre las tablas)";   sqlm "ALTER FUNCTION $REG SECURITY INVOKER"; detectar 39_auth_conexiones


echo ""
echo "=== Mutaciones de E5 (transferencias) ==="
PRIMERO="50_transferencias 51_transferencias_aleatorio"      # las pruebas de E5 primero: las mutaciones de E5 se detectan antes
HT='public.hacer_transferencia(uuid,text,numeric,text,text)'
ND='public.nombre_destinatario(uuid,text)'
nueva M92 "hacer_transferencia no valida la sesion (usuario inexistente/admin/bloqueado)";                       repl "$HT" "u := public._validar_cliente(p_usuario_id);" "SELECT * INTO u FROM public.usuario WHERE id = p_usuario_id;"; detectar
nueva M93 "_validar_monto acepta mas de 2 decimales";                                                             repl "public._validar_monto(numeric)" "scale(p_monto) > 2" "false"; detectar
nueva M94 "_validar_monto ignora parametro.monto_maximo";                                                         repl "public._validar_monto(numeric)" "OR p_monto > v_max" ""; detectar
nueva M95 "el autoenvio se permite";                                                                              repl "$HT" "IF v_dest_id = v_orig_id THEN" "IF false THEN"; detectar
nueva M96 "se quita la comprobacion de que el bolsillo es de MI cuenta (bolsillo ajeno)";                         repl "$HT" "WHERE b.id = v_bol_txt::uuid AND b.cuenta_id = v_orig_id;" "WHERE b.id = v_bol_txt::uuid;"; detectar
nueva M97 "hacer_transferencia toma la instantanea del reloj DOS veces";                                          repl "$HT" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i; SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;"; detectar
nueva M98 "las patas se fechan con now() en vez del ahora de la instantanea";                                     repl "$HT" "v_grupo := public._asentar_grupo(v_ahora," "v_grupo := public._asentar_grupo(now(),"; detectar
nueva M99 "la pata ENVIO lleva la cuenta del propio emisor como contraparte";                                     repl "$HT" "'contraparte_nombre', v_dest_nom, 'contraparte_cuenta', v_dest_num" "'contraparte_nombre', v_dest_nom, 'contraparte_cuenta', v_orig_num"; detectar
nueva M100 "se quita la traduccion de carreras (destino/bolsillo borrados llegan como error interno del libro)";   repl "$HT" "IF v_msg LIKE 'Libro mayor:%' THEN" "IF false THEN"; detectar 41_transferencias_conexiones
nueva M101 "un destino BLOQUEADO deja de poder recibir (cambia la decision provisional D-E5-9)";                  repl "$HT" "WHERE c.numero_cuenta = v_num;" "WHERE c.numero_cuenta = v_num AND us.estado = 'ACTIVO';"; detectar
nueva M102 "la nota no se recorta ni se normaliza";                                                               repl "$HT" "v_nota := nullif(public._norm_texto(p_nota), '');" "v_nota := nullif(p_nota, '');"; detectar
nueva M103 "nombre_destinatario no exige sesion viva (enumeracion anonima)";                                      repl "$ND" "u := public._validar_cliente(p_usuario_id);" "NULL;"; detectar
nueva M104 "el bolsillo de origen se ignora (el envio sale siempre de la cuenta principal)";                      repl "$HT" "SELECT b.id INTO v_bol FROM public.bolsillo b" "SELECT NULL::uuid INTO v_bol FROM public.bolsillo b"; detectar
nueva M105 "banco_app recibe EXECUTE de un helper interno (_reglas_transferencia)";                               sqlm "GRANT EXECUTE ON FUNCTION public._reglas_transferencia() TO banco_app"; detectar 41_transferencias_conexiones
nueva M106 "hacer_transferencia pierde su SECURITY DEFINER";                                                      sqlm "ALTER FUNCTION $HT SECURITY INVOKER"; detectar 41_transferencias_conexiones
nueva M107 "el monto se REDONDEA a 2 decimales en vez de validarse";                                              repl "$HT" "v_monto := public._validar_monto(p_monto);" "v_monto := round(p_monto, 2);"; detectar
nueva M108 "la longitud maxima de la nota pasa de 140 a 141 (valor centralizado)";                               repl "public._reglas_transferencia()" "'nota_max', 140" "'nota_max', 141"; detectar
nueva M109 "el mensaje de recurso ajeno pasa a 'Bolsillo no encontrado' (el del mock, no el del contrato)";      repl "public._msg_negocio(text)" "'Recurso no encontrado'" "'Bolsillo no encontrado'"; detectar
nueva M110 "se quita la traduccion del propio emisor borrado en carrera";                                          repl "$HT" "IF NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = v_orig_id) THEN" "IF false THEN"; detectar 41_transferencias_conexiones
nueva M111 "se quita la traduccion del bolsillo borrado en carrera";                                              repl "$HT" "ELSIF v_bol IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.bolsillo b WHERE b.id = v_bol) THEN" "ELSIF false THEN"; detectar 41_transferencias_conexiones
nueva M112 "banco_app pierde EXECUTE de hacer_transferencia (el backend dejaria de funcionar)";                   sqlm "REVOKE EXECUTE ON FUNCTION $HT FROM banco_app"; detectar
nueva M113 "banco_lector recibe EXECUTE de nombre_destinatario";                                                  sqlm "GRANT EXECUTE ON FUNCTION $ND TO banco_lector"; detectar 41_transferencias_conexiones

echo ""
echo "=== Mutaciones de E6 (bolsillos y vista_balance) ==="
PRIMERO="52_bolsillos 53_bolsillos_aleatorio"      # las pruebas de E6 primero: las mutaciones de E6 se detectan antes
MV='public._mover_bolsillo(uuid,text,text,text,numeric)'
CB='public.crear_bolsillo(uuid,text)'
VB='public.vista_balance(uuid)'
BT='public.balance_total(uuid)'
BP='public._bolsillo_propio(uuid,text)'
RB='public._reglas_bolsillo()'
MAB='public.mover_a_bolsillo(uuid,text,numeric)'
MEB='public.mover_entre_bolsillos(uuid,text,text,numeric)'
nueva M114 "vista_balance no valida la sesion (admin/bloqueado ven el balance)";                                  repl "$VB" "u := public._validar_cliente(p_usuario_id);" "SELECT * INTO u FROM public.usuario WHERE id = p_usuario_id;"; detectar
nueva M115 "balance_total omite los bolsillos (total = solo la cuenta principal)";                                repl "$BT" "c.balance + coalesce((SELECT sum(b.balance) FROM public.bolsillo b WHERE b.cuenta_id = c.id), 0)" "c.balance"; detectar
nueva M116 "vista_balance lista los bolsillos de TODAS las cuentas (sin filtro de cuenta)";                       repl "$VB" "FROM public.bolsillo b WHERE b.cuenta_id = c.id), '[]'::jsonb))" "FROM public.bolsillo b), '[]'::jsonb))"; detectar
nueva M117 "vista_balance devuelve null en vez de [] cuando no hay bolsillos";                                    repl "$VB" ", '[]'::jsonb))" ", NULL::jsonb))"; detectar
nueva M118 "balance_total pasa a VOLATILE (cada llamada toma su propia foto: lectura que puede ver un movimiento a medias)"; sqlm "ALTER FUNCTION $BT VOLATILE"; detectar
nueva M119 "_mover_bolsillo no valida la sesion (admin/bloqueado mueven dinero)";                                 repl "$MV" "u := public._validar_cliente(p_usuario_id);" "SELECT * INTO u FROM public.usuario WHERE id = p_usuario_id;"; detectar
nueva M120 "_bolsillo_propio acepta bolsillos de OTRA cuenta";                                                    repl "$BP" "WHERE b.id = v_txt::uuid AND b.cuenta_id = p_cuenta_id;" "WHERE b.id = v_txt::uuid;"; detectar
nueva M121 "_mover_bolsillo toma la instantanea del reloj DOS veces";                                             repl "$MV" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i; SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;"; detectar
nueva M122 "las patas se fechan con now() en vez del ahora de la instantanea";                                     repl "$MV" "v_grupo := public._asentar_grupo(v_ahora," "v_grupo := public._asentar_grupo(now(),"; detectar
nueva M123 "mover entre bolsillos: la pata de salida lleva el nombre del propio origen en vez del destino";        repl "$MV" "'bolsillo_id', v_a, 'contraparte_nombre', v_nb)" "'bolsillo_id', v_a, 'contraparte_nombre', v_na)"; detectar
nueva M124 "mover un bolsillo a si mismo se deja pasar al libro (se quita la comprobacion D-E6-9)";                repl "$MV" "IF v_a = v_b THEN" "IF false THEN"; detectar
nueva M125 "se quita la traduccion del bolsillo borrado en carrera (llega el texto interno del libro)";           repl "$MV" "ELSIF NOT EXISTS (SELECT 1 FROM public.bolsillo b WHERE b.id = v_a)" "ELSIF false"; detectar 43_bolsillos_conexiones
nueva M126 "se quita la traduccion del usuario borrado en carrera";                                               repl "$MV" "IF NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = v_cta) THEN" "IF false THEN"; detectar 43_bolsillos_conexiones
nueva M127 "crear_bolsillo no recorta ni normaliza el nombre";                                                    repl "$CB" "v_nombre := public._norm_texto(p_nombre);" "v_nombre := p_nombre;"; detectar
nueva M128 "la longitud maxima del nombre pasa de 40 a 41 (valor centralizado)";                                  repl "$RB" "'nombre_max',    40," "'nombre_max',    41,"; detectar
nueva M129 "crear_bolsillo deja escapar la violacion de FK (usuario borrado en carrera)";                          repl "$CB" "EXCEPTION WHEN foreign_key_violation THEN" "EXCEPTION WHEN no_data_found THEN"; detectar 43_bolsillos_conexiones
nueva M130 "crear_bolsillo usa current_date en vez del hoy del banco (ultimo_cobro)";                              repl "$CB" "VALUES (v_cta, v_nombre, v_hoy, v_ahora)" "VALUES (v_cta, v_nombre, current_date, v_ahora)"; detectar
nueva M131 "mover_a_bolsillo usa la plantilla de RETIRO (ingresa al reves)";                                       repl "$MAB" "'BOLSO_INGRESO', p_bolsillo_id" "'BOLSO_RETIRO', p_bolsillo_id"; detectar
nueva M132 "mover_entre_bolsillos intercambia origen y destino";                                                   repl "$MEB" "p_bolsillo_origen, p_bolsillo_destino, p_monto" "p_bolsillo_destino, p_bolsillo_origen, p_monto"; detectar
nueva M133 "banco_app recibe EXECUTE de balance_total (helper interno)";                                           sqlm "GRANT EXECUTE ON FUNCTION $BT TO banco_app"; detectar 43_bolsillos_conexiones
nueva M134 "banco_app pierde EXECUTE de vista_balance (el front no podria listar bolsillos)";                      sqlm "REVOKE EXECUTE ON FUNCTION $VB FROM banco_app"; detectar
nueva M135 "banco_lector recibe EXECUTE de crear_bolsillo";                                                        sqlm "GRANT EXECUTE ON FUNCTION $CB TO banco_lector"; detectar 43_bolsillos_conexiones
nueva M136 "crear_bolsillo pierde su SECURITY DEFINER";                                                            sqlm "ALTER FUNCTION $CB SECURITY INVOKER"; detectar 43_bolsillos_conexiones

echo ""
echo "=== Mutaciones de E7 (motor de devengo, CDT y guardia monotonica) ==="
PRIMERO="54_devengo 55_cdt 56_motor_aleatorio"      # las pruebas de E7 primero: las mutaciones de E7 se detectan antes
AV='public._avanzar_hasta(uuid,date,timestamptz)'
DB7='public._devengar_bolsillos(uuid,date,timestamptz)'
DC7='public._devengar_cdts(uuid,date,timestamptz)'
FI='public._factor_interes(numeric,integer)'
BC='public._bloquear_cuentas(uuid[])'
TM='public.trg_ultimo_cobro_monotono()'
HT='public.hacer_transferencia(uuid,text,numeric,text,text)'
MV='public._mover_bolsillo(uuid,text,text,text,numeric)'
CB='public.crear_bolsillo(uuid,text)'
VB='public.vista_balance(uuid)'
BT='public.balance_total(uuid)'
CC='public.crear_cdt(uuid,text,numeric)'
VC='public.vista_cdts(uuid)'
SC='public.simular_cdt(uuid,text,numeric)'
LC='public.listar_cdt_definiciones(uuid)'
nueva M137 "vista_balance NO devenga antes de leer (se quita _avanzar_hasta)";                                     repl "$VB" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M138 "los 3 movimientos de bolsillo (_mover_bolsillo) NO devengan antes del libro";                         repl "$MV" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M139 "crear_bolsillo NO devenga (uniformidad rota)";                                                         repl "$CB" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M140 "hacer_transferencia NO devenga al emisor antes del libro";                                             repl "$HT" "PERFORM public._avanzar_hasta(v_orig_id, v_hoy, v_ahora);" "NULL;"; detectar
nueva M141 "crear_cdt NO devenga antes de invertir";                                                               repl "$CC" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M142 "vista_cdts NO devenga ni cierra antes de leer";                                                        repl "$VC" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M143 "el motor NO toma el bloqueo de la cuenta (el devengo retendria bolsillos mientras espera el libro: riesgo de deadlock)"; repl "$AV" "WHERE c.id = p_cuenta_id FOR NO KEY UPDATE;" "WHERE c.id = p_cuenta_id;"; detectar 46_motor_concurrencia
nueva M144 "el devengo de bolsillos NO avanza ultimo_cobro (se cobraria el mismo periodo en cada consulta)";          repl "$DB7" "UPDATE public.bolsillo SET ultimo_cobro = p_hoy WHERE id = r.id;" "NULL;"; detectar
nueva M145 "ultimo_cobro avanza SOLO si hubo interes (un bolsillo vacio cobraria retroactivo al recibir dinero)";   repl "$DB7" "UPDATE public.bolsillo SET ultimo_cobro = p_hoy WHERE id = r.id;" "IF v_int > 0 THEN UPDATE public.bolsillo SET ultimo_cobro = p_hoy WHERE id = r.id; END IF;"; detectar
nueva M146 "el bolsillo cobra UN DIA DE MAS";                                                                       repl "$DB7" "v_dias := p_hoy - r.ultimo_cobro;" "v_dias := p_hoy - r.ultimo_cobro + 1;"; detectar
nueva M147 "el CDT cobra UN DIA DE MENOS";                                                                         repl "$DC7" "v_dias := v_d - r.fecha_inicio;" "v_dias := v_d - r.fecha_inicio - 1;"; detectar
nueva M148 "el motor lee el reloj (hoy_banco) en vez de usar el hoy de la instantanea";                            repl "$AV" "v_n := public._devengar_bolsillos(p_cuenta_id, p_hoy, p_ahora);" "v_n := public._devengar_bolsillos(p_cuenta_id, public.hoy_banco(), p_ahora);"; detectar
nueva M149 "el devengo de bolsillos fecha el asiento con now() en vez del ahora de la instantanea";                repl "$DB7" "PERFORM public._asentar_grupo(p_ahora, jsonb_build_array(" "PERFORM public._asentar_grupo(now(), jsonb_build_array("; detectar
nueva M150 "el CDT NO se topa en fecha_fin (el interes sigue corriendo si el reloj salta anos)";                   repl "$DC7" "v_d      := least(p_hoy, r.fecha_fin);" "v_d      := p_hoy;"; detectar
nueva M151 "el vencimiento NO marca el CDT como CERRADO";                                                          repl "$DC7" "UPDATE public.cdt SET estado = 'CERRADO' WHERE id = r.id;" "NULL;"; detectar
nueva M152 "el vencimiento acredita solo el monto (se pierde lo generado)";                                        repl "$DC7" "'monto', r.monto + v_gen" "'monto', r.monto"; detectar
nueva M153 "el motor reprocesa los CDT CERRADOS (intereses y vencimientos tras cerrar)";                           repl "$DC7" "WHERE d.cuenta_id = p_cuenta_id AND d.estado = 'ACTIVO' AND" "WHERE d.cuenta_id = p_cuenta_id AND"; detectar
nueva M154 "el cierre del CDT se fecha con el ahora de la operacion en vez de fecha_fin 00:00 de Bogota";         repl "$DC7" "(r.fecha_fin::timestamp AT TIME ZONE 'America/Bogota') ELSE p_ahora END" "p_ahora ELSE p_ahora END"; detectar
nueva M155 "_bloquear_cuentas bloquea en el orden pedido y no en orden de id (deadlock en transferencias cruzadas)"; repl "$BC" "PERFORM 1 FROM public.cuenta c WHERE c.id = ANY (p_ids) ORDER BY c.id FOR NO KEY UPDATE;" "PERFORM 1 FROM public.cuenta c WHERE c.id = p_ids[1] FOR NO KEY UPDATE; PERFORM pg_sleep(0.05); PERFORM 1 FROM public.cuenta c WHERE c.id = p_ids[2] FOR NO KEY UPDATE;"; repl "$BC" "GET DIAGNOSTICS v_n = ROW_COUNT;" "v_n := 2;"; detectar 46_motor_concurrencia
nueva M156 "hacer_transferencia devenga SIN bloquear antes ambas cuentas (A->B || B->A se bloquean entre si)";      repl "$HT" "IF public._bloquear_cuentas(ARRAY[v_orig_id, v_dest_id]) <> 2 THEN" "IF false THEN"; repl "$HT" "PERFORM public._avanzar_hasta(v_orig_id, v_hoy, v_ahora);" "PERFORM public._avanzar_hasta(v_orig_id, v_hoy, v_ahora); PERFORM pg_sleep(0.05);"; detectar 46_motor_concurrencia
nueva M157 "se elimina la guardia monotonica de ultimo_cobro en bolsillo";                                          sqlm "DROP TRIGGER trg_ultimo_cobro_monotono ON public.bolsillo"; detectar
nueva M158 "se elimina la guardia monotonica de ultimo_cobro en cdt";                                              sqlm "DROP TRIGGER trg_ultimo_cobro_monotono ON public.cdt"; detectar
nueva M159 "la guardia monotonica deja retroceder (IF false)";                                                     repl "$TM" "IF NEW.ultimo_cobro < OLD.ultimo_cobro THEN" "IF false THEN"; detectar
nueva M160 "el motor de bolsillos procesa tambien los bolsillos al dia o del futuro (sin filtro ultimo_cobro < hoy)"; repl "$DB7" "WHERE b.cuenta_id = p_cuenta_id AND b.ultimo_cobro < p_hoy" "WHERE b.cuenta_id = p_cuenta_id"; detectar
nueva M161 "el interes de bolsillo no se recorta a monto_maximo (error de dominio al desbordar)";                    repl "$DB7" "least(round(r.balance * public._factor_interes(v_tasa, v_dias), 2), greatest(v_max - r.balance, 0))" "round(r.balance * public._factor_interes(v_tasa, v_dias), 2)"; detectar
nueva M162 "la salida rapida ignora los CDT (solo mira bolsillos): un CDT vencido sin bolsillos nunca se cierra";   repl "$AV" "AND NOT EXISTS (SELECT 1 FROM public.cdt d WHERE" "AND NOT EXISTS (SELECT 1 FROM public.cdt d WHERE false AND"; detectar
nueva M163 "_factor_interes pasa a interes simple nominal (depende de cuantas veces se consulte)";                    repl "$FI" "power(1 + p_tasa_pct / 100, p_dias::numeric / 365) - 1" "p_tasa_pct / 100 * p_dias / 365"; detectar
nueva M164 "simular_cdt usa otra formula que el motor (la simulacion no coincide con lo generado)";                  repl "$SC" "'generado_vencimiento', round(v_monto * public._factor_interes(d.tasa_anual, d.plazo_dias), 2)" "'generado_vencimiento', round(v_monto * d.tasa_anual / 100 * d.plazo_dias / 365, 2)"; detectar
nueva M165 "crear_cdt copia una tasa distinta de la definicion";                                                    repl "$CC" "v_monto, d.tasa_anual, d.plazo_dias," "v_monto, d.tasa_anual + 1, d.plazo_dias,"; detectar
nueva M166 "vista_cdts omite los CDT cerrados";                                                                    repl "$VC" "FROM public.cdt d WHERE d.cuenta_id = c.id), '[]'::jsonb)" "FROM public.cdt d WHERE d.cuenta_id = c.id AND d.estado = 'ACTIVO'), '[]'::jsonb)"; detectar
nueva M167 "balance_total no suma los CDT activos (crear un CDT bajaria el total)";                                  repl "$BT" "+ coalesce((SELECT sum(d.monto + d.generado_acumulado) FROM public.cdt d WHERE d.cuenta_id = c.id AND d.estado = 'ACTIVO'), 0)" ""; detectar
nueva M168 "balance_total suma tambien los CDT cerrados (se cuenta el dinero dos veces)";                           repl "$BT" "WHERE d.cuenta_id = c.id AND d.estado = 'ACTIVO'), 0)" "WHERE d.cuenta_id = c.id), 0)"; detectar
nueva M169 "crear_cdt toma la instantanea del reloj DOS veces";                                                    repl "$CC" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i; SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;"; detectar
nueva M170 "vista_cdts pasa now() al motor en vez del ahora de la instantanea";                                      repl "$VC" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "PERFORM public._avanzar_hasta(v_cta, v_hoy, now());"; detectar
nueva M171 "banco_app recibe EXECUTE del motor (_avanzar_hasta)";                                                   sqlm "GRANT EXECUTE ON FUNCTION $AV TO banco_app"; detectar 45_motor_conexiones
nueva M172 "banco_app pierde EXECUTE de crear_cdt (el front no podria abrir CDT)";                                  sqlm "REVOKE EXECUTE ON FUNCTION $CC FROM banco_app"; detectar
nueva M173 "banco_lector recibe EXECUTE de vista_cdts";                                                             sqlm "GRANT EXECUTE ON FUNCTION $VC TO banco_lector"; detectar 45_motor_conexiones
nueva M174 "crear_cdt pierde su SECURITY DEFINER";                                                                  sqlm "ALTER FUNCTION $CC SECURITY INVOKER"; detectar 45_motor_conexiones
nueva M175 "listar_cdt_definiciones no exige sesion viva";                                                          repl "$LC" "u := public._validar_cliente(p_usuario_id);" "NULL;"; detectar

echo ""
echo "=== Mutaciones de E8 (creditos: tasa, plan frances, topes, regla de edad, interes corriendo, ct_credito_plan, devengo previo, permisos) ==="
PRIMERO="57_creditos_calculo 58_creditos 59_creditos_aleatorio"      # las pruebas de E8 primero: las mutaciones de E8 se detectan antes
PC='public._plan_cuotas(numeric,numeric,integer)'
TM8='public._tasa_mensual(numeric)'
FV='public._fecha_vencimiento(date,integer)'
PN='public._patrimonio_neto(uuid)'
IC='public._interes_corriendo(uuid,date)'
CPL='public.ct_credito_plan()'
LC8='public._limites_credito(uuid,date,public.credito_producto,date)'
VP8='public._validar_plazo(numeric)'
PD8='public.productos_disponibles(uuid)'
PP8='public.productos_publicos()'
SM8='public.simular_credito(uuid,text,numeric,numeric)'
SO8='public.solicitar_credito(uuid,text,numeric,numeric)'
VC8='public.vista_creditos(uuid)'
nueva M176 "la tasa mensual pasa a nominal i = tasa/12 (contradice la convencion E.A. centralizada en _tasa_mensual)";            repl "$TM8" "power(1 + p_tasa_pct / 100, 1::numeric / 12) - 1" "p_tasa_pct / 100 / 12"; detectar
nueva M177 "la cuota fija no se redondea a centavos";                                                                            repl "$PC" "c := round(p_monto * i * q / (q - 1), 2);" "c := p_monto * i * q / (q - 1);"; detectar
nueva M178 "el interes de cada periodo no se redondea a centavos";                                                               repl "$PC" "it := round(s * i, 2);" "it := s * i;"; detectar
nueva M179 "la ULTIMA cuota NO absorbe el redondeo (capital = cuota - interes tambien al final)";                                repl "$PC" "cp := s;" "cp := c - it;"; detectar
nueva M180 "los vencimientos pasan a 30 dias fijos en vez de meses calendario anclados";                                         repl "$FV" "(p_desembolso + make_interval(months => p_k))::date" "(p_desembolso + 30 * p_k)::date"; detectar
nueva M181 "solicitar_credito numera los vencimientos desde 0 (la cuota 1 vence el dia del desembolso)";                          repl "$SO8" "public._fecha_vencimiento(v_hoy, p.numero)" "public._fecha_vencimiento(v_hoy, p.numero - 1)"; detectar
nueva M182 "el patrimonio para el tope NO resta la deuda (el credito infla el tope de Inmuebles)";                               repl "$PN" "- coalesce((SELECT sum(k.capital_pendiente) FROM public.credito k WHERE k.cuenta_id = p_cuenta_id), 0)" ""; detectar
nueva M183 "el tope fijo del producto se ignora";                                                                                repl "$LC8" "v_max := least(v_max, p_prod.tope_absoluto);" "NULL;"; detectar
nueva M184 "el tope puede quedar NEGATIVO (sin el piso 0)";                                                                      repl "$LC8" "l_monto_max := greatest(0.00, v_max);" "l_monto_max := v_max;"; detectar
nueva M185 "el plazo tecnico (360) no se aplica a un producto mal cargado";                                                      repl "$LC8" "l_plazo_max_prod := least(p_prod.plazo_max_meses, (public._reglas_credito() ->> 'plazo_tecnico_max')::int);" "l_plazo_max_prod := p_prod.plazo_max_meses;"; detectar
nueva M186 "el multiplicador usa balance_total (sin restar la deuda) en vez del patrimonio neto";                                repl "$LC8" "public._patrimonio_neto(p_cuenta_id)" "public.balance_total(p_cuenta_id)"; detectar
nueva M187 "la edad se calcula por diferencia de anios calendario (no anios cumplidos)";                                         repl "$LC8" "date_part('year', age(p_hoy, p_nacimiento))::int" "(date_part('year', p_hoy) - date_part('year', p_nacimiento))::int"; detectar
nueva M188 "el plazo por edad regala 12 meses ((limite - edad) * 12 + 12)";                                                      repl "$LC8" "greatest(0, (v_lim - v_edad) * 12)" "greatest(0, (v_lim - v_edad) * 12 + 12)"; detectar
nueva M189 "productos_publicos no aplica el tope fijo (muestra monto_max del rango)";                                            repl "$PP8" "least(p.monto_max, coalesce(p.tope_absoluto, p.monto_max))" "p.monto_max"; detectar
nueva M190 "un plazo fraccionario (12,5) se acepta y se redondea";                                                               repl "$VP8" "OR p_plazo <> trunc(p_plazo) THEN" "THEN"; detectar
nueva M191 "el interes corriendo no se topa en el interes de la cuota (sigue creciendo vencida)";                               repl "$IC" "least(1::numeric," "least(100::numeric,"; detectar
nueva M192 "el interes corriendo puede ser negativo (sin el piso 0)";                                                            repl "$IC" "greatest(0::numeric," "greatest(-100::numeric,"; detectar
nueva M193 "el interes corriendo toma SIEMPRE la cuota 1 (no la proxima impaga)";                                                repl "$IC" "JOIN public.cuota q ON q.credito_id = k.id AND NOT q.pagada" "JOIN public.cuota q ON q.credito_id = k.id"; detectar
nueva M194 "ct_credito_plan deja de comparar el capital pendiente con el plan";                                                  repl "$CPL" "IF v_plan <> v_cap THEN" "IF false THEN"; detectar
nueva M195 "ct_credito_plan ignora capital_pagado";                                                                              repl "$CPL" "sum(q.capital_programado - q.capital_pagado)" "sum(q.capital_programado)"; detectar
nueva M196 "ct_credito_plan cuenta tambien las cuotas PAGADAS";                                                                  repl "$CPL" "WHERE q.credito_id = v_id AND NOT q.pagada;" "WHERE q.credito_id = v_id;"; detectar
nueva M197 "se elimina el trigger ct_credito_plan de credito (el UPDATE de capital_pendiente del libro no dispara la regla)";    sqlm "DROP TRIGGER ct_credito_plan ON public.credito"; detectar
nueva M198 "se elimina el trigger ct_credito_plan_cuota de cuota (una cuota borrada o editada no dispara la regla)";             sqlm "DROP TRIGGER ct_credito_plan_cuota ON public.cuota"; detectar
nueva M199 "solicitar_credito no verifica ct_credito_plan antes de volver (un plan corrupto solo fallaria en el COMMIT)";        repl "$SO8" "SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota IMMEDIATE;" "NULL;"; detectar
nueva M200 "solicitar_credito no afirma que inserto las n cuotas";                                                               repl "$SO8" "IF v_n <> v_plazo THEN" "IF false THEN"; detectar
nueva M201 "solicitar_credito NO devenga antes de calcular el tope y desembolsar";                                               repl "$SO8" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M202 "productos_disponibles NO devenga antes de calcular los topes";                                                       repl "$PD8" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M203 "simular_credito NO devenga antes de calcular los topes";                                                             repl "$SM8" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M204 "vista_creditos NO devenga antes de leer";                                                                            repl "$VC8" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M205 "solicitar_credito no bloquea explicitamente la cuenta (lee el tope sin el bloqueo del libro)";                       repl "$SO8" "IF public._bloquear_cuentas(ARRAY[v_cta]) <> 1 THEN" "IF false THEN"; detectar 48_creditos_concurrencia
nueva M206 "solicitar_credito no valida el credito vigente (solo el indice unico, traducido, y DESPUES de los rangos)";          repl "$SO8" "IF EXISTS (SELECT 1 FROM public.credito k WHERE k.cuenta_id = v_cta AND k.producto_id = d.id AND k.estado = 'ACTIVO') THEN" "IF false THEN"; detectar
nueva M207 "el credito vigente cuenta tambien los PAGADOS (un credito liquidado bloquea el producto para siempre)";               repl "$SO8" "AND k.estado = 'ACTIVO') THEN" ") THEN"; detectar
nueva M208 "el credito nace con capital_pendiente = monto (el libro lo subiria dos veces)";                                      repl "$SO8" "VALUES (v_cta, d.id, v_monto, d.tasa_anual, v_plazo, v_hoy, 0, v_hoy)" "VALUES (v_cta, d.id, v_monto, d.tasa_anual, v_plazo, v_hoy, v_monto, v_hoy)"; detectar
nueva M209 "el credito copia una tasa distinta de la del producto";                                                              repl "$SO8" "VALUES (v_cta, d.id, v_monto, d.tasa_anual," "VALUES (v_cta, d.id, v_monto, d.tasa_anual + 1,"; detectar
nueva M210 "simular_credito usa otra tasa que solicitar_credito (la simulacion no coincide con lo que se cobra)";                repl "$SM8" "FROM public._plan_cuotas(v_monto, d.tasa_anual, v_plazo) p;" "FROM public._plan_cuotas(v_monto, d.tasa_anual + 1, v_plazo) p;"; detectar
nueva M211 "solicitar_credito toma la instantanea del reloj DOS veces";                                                          repl "$SO8" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i; SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;"; detectar
nueva M212 "solicitar_credito pasa now() al motor en vez del ahora de la instantanea";                                           repl "$SO8" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "PERFORM public._avanzar_hasta(v_cta, v_hoy, now());"; detectar
nueva M213 "vista_creditos incluye los creditos PAGADOS";                                                                        repl "$VC8" "AND k.estado = 'ACTIVO'), '[]'::jsonb)" "), '[]'::jsonb)"; detectar
nueva M214 "banco_lector recibe EXECUTE de vista_creditos";                                                                      sqlm "GRANT EXECUTE ON FUNCTION $VC8 TO banco_lector"; detectar 47_creditos_conexiones
nueva M215 "banco_app pierde EXECUTE de solicitar_credito (el front no podria pedir creditos)";                                  sqlm "REVOKE EXECUTE ON FUNCTION $SO8 FROM banco_app"; detectar
nueva M216 "banco_app recibe EXECUTE de la interna _plan_cuotas";                                                                sqlm "GRANT EXECUTE ON FUNCTION $PC TO banco_app"; detectar 47_creditos_conexiones
nueva M217 "solicitar_credito pierde su SECURITY DEFINER";                                                                       sqlm "ALTER FUNCTION $SO8 SECURITY INVOKER"; detectar 47_creditos_conexiones

echo ""
echo "=== Mutaciones de E9 (pagos, abonos, mora, recalculo, cobro automatico cronologico, cursor, plantillas, permisos) ==="
PRIMERO="${PRIMERO9:-60_pagos_calculo 61_pagos 62_cobro_automatico 63_pagos_aleatorio 64_pagos_huecos}"      # las pruebas de E9 primero: las mutaciones de E9 se detectan antes
RP='public._reglas_pago()'
MC9='public._mora_cuota(numeric,integer)'
DM9='public._dias_mora(date,date,date)'
MD9='public._mora_de_cuota(uuid,integer,date)'
MP9='public._mora_pendiente(uuid,date)'
IP9='public._inicio_periodo(uuid,integer)'
PX9='public._proxima_cuota(uuid)'
PR9='public._plan_restante(numeric,numeric,integer,numeric)'
TG9='public.trg_cobro_hasta_monotono()'
CP9='public._credito_propio(uuid,text)'
PI9='public._pagar_cuota_interna(uuid,uuid,integer,timestamptz,date)'
CC9='public._cobrar_creditos(uuid,date,timestamptz)'
PC9='public.pagar_cuota(uuid,text,integer)'
AB9='public.abonar_credito(uuid,text,numeric)'
AD9='public.activar_descuento_automatico(uuid,text,boolean)'
PV9='public._plantillas_validas()'
R9='49_pagos_conexiones 50_pagos_concurrencia'
# ---- mora (D7, centralizada en _mora_cuota / _dias_mora / _reglas_pago) ----
nueva M218 "la base de dias de la mora pasa de 365 a 360 (_reglas_pago)";                                                        repl "$RP" "'base_dias_mora', 365" "'base_dias_mora', 360"; detectar
nueva M219 "la tasa de mora NULL no da 0 (la mora queda NULL: se rompe 'sin tasa no se inventa mora')";                          repl "$MC9" "OR pa.tasa_mora_anual IS NULL" ""; detectar
nueva M220 "la mora no se redondea a centavos";                                                                                  repl "$MC9" "round(p_valor * pa.tasa_mora_anual / 100 / (public._reglas_pago() ->> 'base_dias_mora')::numeric * p_dias, 2)" "(p_valor * pa.tasa_mora_anual / 100 / (public._reglas_pago() ->> 'base_dias_mora')::numeric * p_dias)"; detectar
nueva M221 "la mora pasa a E.A. compuesta (otra convencion en la funcion central)";                                              repl "$MC9" "p_valor * pa.tasa_mora_anual / 100 / (public._reglas_pago() ->> 'base_dias_mora')::numeric * p_dias" "p_valor * (power(1 + pa.tasa_mora_anual / 100, p_dias::numeric / 365) - 1)"; detectar
nueva M222 "los dias de mora cuentan el dia del vencimiento (+1)";                                                               repl "$DM9" "SELECT greatest(0, p_fecha - greatest(" "SELECT greatest(0, 1 + p_fecha - greatest("; detectar
nueva M223 "los dias de mora ignoran mora_hasta (la mora de un abono se cobra otra vez)";                                        repl "$DM9" "greatest(p_venc, coalesce(p_mora_hasta, p_venc))" "p_venc"; detectar
nueva M224 "la mora de una cuota usa el valor ORIGINAL de la cuota y no el vigente tras un abono";                               repl "$MD9" "public._mora_cuota(q.valor_cuota," "public._mora_cuota(q.valor_cuota_original,"; detectar
nueva M225 "la mora de una cuota se calcula tambien sobre cuotas PAGADAS";                                                       repl "$MD9" "AND q.numero = p_numero AND NOT q.pagada" "AND q.numero = p_numero"; detectar
nueva M226 "la mora pendiente suma tambien las cuotas PAGADAS";                                                                  repl "$MP9" "WHERE q.credito_id = p_credito_id AND NOT q.pagada AND q.fecha_vencimiento < p_fecha" "WHERE q.credito_id = p_credito_id AND q.fecha_vencimiento < p_fecha"; detectar
nueva M227 "la mora pendiente toma solo la cuota vencida mas grande (max en vez de sum)";                                        repl "$MP9" "coalesce(sum(" "coalesce(max("; detectar
# ---- periodos, proxima cuota y recalculo ----
nueva M228 "el periodo de la cuota 1 no arranca en el desembolso (usa la cuota anterior inexistente)";                            repl "$IP9" "WHEN p_numero <= 1 THEN" "WHEN p_numero < 1 THEN"; detectar
nueva M229 "la proxima cuota es la ULTIMA impaga y no la primera";                                                               repl "$PX9" "ORDER BY q.numero LIMIT 1" "ORDER BY q.numero DESC LIMIT 1"; detectar
nueva M230 "el recalculo ignora el primer periodo corto en la cuota fija (usa el capital a secas)";                              repl "$PR9" "round((p_capital + p_j0) * i" "round((p_capital) * i"; detectar
nueva M231 "el recalculo no deja que la ULTIMA cuota absorba el redondeo";                                                       repl "$PR9" "CASE WHEN k = p_m THEN s ELSE c - it END" "c - it"; detectar
nueva M232 "el recalculo cobra el primer periodo con interes completo (ignora j0)";                                              repl "$PR9" "CASE WHEN k = 1 THEN round(p_j0, 2) ELSE round(s * i, 2) END" "round(s * i, 2)"; detectar
# ---- cursor cobro_hasta: guardia y CHECK ----
nueva M233 "la guardia del cursor deja de rechazar un retroceso fecha -> fecha anterior";                                         repl "$TG9" "AND NEW.cobro_hasta < OLD.cobro_hasta THEN" "AND false THEN"; detectar
nueva M234 "la guardia del cursor tambien rechaza NULL -> fecha (no se podria activar el descuento)";                             repl "$TG9" "OLD.cobro_hasta IS NOT NULL AND NEW.cobro_hasta IS NOT NULL AND NEW.cobro_hasta < OLD.cobro_hasta" "NEW.cobro_hasta IS NOT NULL AND NEW.cobro_hasta < coalesce(OLD.cobro_hasta, '9999-12-31'::date)"; detectar
nueva M235 "se elimina el trigger trg_cobro_hasta_monotono";                                                                      sqlm "DROP TRIGGER trg_cobro_hasta_monotono ON public.credito"; detectar
nueva M236 "se elimina el CHECK descuento_automatico = (cobro_hasta IS NOT NULL)";                                                sqlm "ALTER TABLE public.credito DROP CONSTRAINT ck_credito_cobro_hasta"; detectar
# ---- _credito_propio (propiedad del recurso) ----
nueva M237 "_credito_propio no filtra por la cuenta (se opera un credito AJENO)";                                                 repl "$CP9" "AND x.cuenta_id = p_cuenta_id AND x.estado = 'ACTIVO'" "AND x.estado = 'ACTIVO'"; detectar
nueva M238 "_credito_propio acepta creditos ya PAGADOS";                                                                          repl "$CP9" "AND x.cuenta_id = p_cuenta_id AND x.estado = 'ACTIVO';" "AND x.cuenta_id = p_cuenta_id;"; detectar
nueva M239 "_credito_propio no valida el formato del uuid (un texto malo llega al cast como error de driver)";                    repl "$CP9" "v_txt IS NULL OR v_txt !~*" "v_txt IS NULL OR false AND v_txt !~*"; detectar
# ---- _pagar_cuota_interna ----
nueva M240 "la mora de un pago llega hasta HOY y no hasta la fecha real del intento";                                            repl "$PI9" "public._mora_de_cuota(p_credito_id, p_numero, p_dia)" "public._mora_de_cuota(p_credito_id, p_numero, public.hoy_banco())"; detectar
nueva M241 "la mora nunca se cobra (no hay grupo CREDITO_MORA)";                                                                  repl "$PI9" "IF v_mora > 0 THEN" "IF false THEN"; detectar
nueva M242 "la cuota pagada no se marca pagada (el plan no cuadra con el libro)";                                                 repl "$PI9" "SET pagada = true, fecha_pago = p_dia," "SET pagada = false, fecha_pago = p_dia,"; detectar
nueva M243 "fecha_pago usa hoy en vez de la fecha del intento";                                                                   repl "$PI9" "fecha_pago = p_dia," "fecha_pago = public.hoy_banco(),"; detectar
nueva M244 "intereses_pagados no suma el interes de la cuota";                                                                    repl "$PI9" "intereses_pagados = intereses_pagados + interes_programado" "intereses_pagados = intereses_pagados"; detectar
nueva M245 "el ancla fecha_interes puede RETROCEDER al pagar una cuota anterior (regla R)";                                       repl "$PI9" "greatest(fecha_interes, q.fecha_vencimiento)" "q.fecha_vencimiento"; detectar
nueva M246 "la ultima cuota pagada no cierra el credito (sigue ACTIVO con capital 0)";                                            repl "$PI9" "UPDATE public.credito SET estado = 'PAGADO' WHERE id = p_credito_id;" "NULL;"; detectar
nueva M247 "la cuota sin pata de interes (RESULTADO) deja el grupo descuadrado";                                                  repl "$PI9" "IF q.interes_programado > 0 THEN" "IF false THEN"; detectar
# ---- _cobrar_creditos (cobro automatico cronologico, diseno v1.2 §7) ----
nueva M248 "el cursor cobro_hasta no avanza tras el cobro (se re-procesa lo ya cobrado)";                                         repl "$CC9" "UPDATE public.credito k SET cobro_hasta = p_hoy" "UPDATE public.credito k SET cobro_hasta = k.cobro_hasta"; detectar
nueva M249 "los CDT NO se cierran antes de cada ronda de cobro (el vencimiento no financia la cuota)";                            repl "$CC9" "v_n := v_n + public._devengar_cdts(p_cuenta_id, d, p_ahora);" "NULL;"; detectar
nueva M250 "la ronda no cobra la cuota MAS ANTIGUA primero (orden por id)";                                                       repl "$CC9" "ORDER BY q.fecha_vencimiento, k.fecha_desembolso, k.id" "ORDER BY k.id, q.fecha_vencimiento"; detectar
nueva M251 "el desempate de la ronda ignora la fecha de desembolso (solo id)";                                                    repl "$CC9" "ORDER BY q.fecha_vencimiento, k.fecha_desembolso, k.id" "ORDER BY q.fecha_vencimiento, k.id"; detectar
nueva M252 "el saldo disponible incluye lo que ENTRO despues de la fecha del intento";                                            repl "$CC9" "AND t.fecha > v_corte), 0)" "AND false), 0)"; detectar
nueva M253 "el cobro automatico ignora la mora al decidir si alcanza el saldo (queda a medias)";                                  repl "$CC9" "IF v_saldo >= r.valor_cuota + v_mora THEN" "IF v_saldo >= r.valor_cuota THEN"; detectar
nueva M254 "un credito sin saldo ABORTA la ronda (los demas creditos no cobran)";                                                 repl "$CC9" "v_bloq := v_bloq || r.credito_id;" "EXIT;"; detectar
nueva M255 "la ventana de un credito incluye su propio dia de cursor (d >= cobro_hasta)";                                         repl "$CC9" "AND (d = p_hoy OR d > k.cobro_hasta)" "AND (d = p_hoy OR d >= k.cobro_hasta)"; detectar
nueva M256 "los cierres de CDT se buscan solo desde hoy y no desde el MENOR cursor";                                             repl "$CC9" "c.fecha_fin > v_cmin" "c.fecha_fin > p_hoy"; detectar
nueva M257 "las fechas-evento usan el menor cursor para los vencimientos de TODOS los creditos";                                 repl "$CC9" "AND NOT q.pagada AND q.fecha_vencimiento > k.cobro_hasta AND" "AND NOT q.pagada AND q.fecha_vencimiento > v_cmin AND"; detectar
nueva M258 "los cobros atrasados se fechan con la instantanea de hoy y no con el dia del vencimiento";                            repl "$CC9" "v_fecha := CASE WHEN d < p_hoy THEN (d::timestamp AT TIME ZONE 'America/Bogota') ELSE p_ahora END;" "v_fecha := p_ahora;"; detectar
nueva M259 "la mora de un cobro automatico llega hasta HOY y no hasta la fecha del intento d";                                    repl "$CC9" "public._mora_de_cuota(r.credito_id, r.numero, d)" "public._mora_de_cuota(r.credito_id, r.numero, p_hoy)"; detectar
nueva M260 "con el reloj por detras del cursor (cobro_hasta > hoy) el motor SIGUE cobrando (no se pausa)";                        repl "$CC9" "AND k.cobro_hasta IS NOT NULL AND k.cobro_hasta <= p_hoy" "AND k.cobro_hasta IS NOT NULL"; detectar
nueva M261 "la ronda de la fecha d cobra tambien cuotas que vencen DESPUES de d (hasta hoy)";                                     repl "$CC9" "AND q.fecha_vencimiento <= d" "AND q.fecha_vencimiento <= p_hoy"; detectar
# ---- pagar_cuota ----
nueva M262 "pagar_cuota NO corre el motor antes de decidir que cuota toca";                                                       repl "$PC9" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M263 "pagar_cuota con numero ya NO exige que sea la proxima (paga otra: sin idempotencia)";                                 repl "$PC9" "IF q.id IS NULL OR (p_numero IS NOT NULL AND p_numero <> q.numero) THEN" "IF q.id IS NULL THEN"; detectar
nueva M264 "pagar_cuota no bloquea la cuenta (dos pagos simultaneos pagan la misma cuota)";                                       repl "$PC9" "IF public._bloquear_cuentas(ARRAY[v_cta]) <> 1 THEN" "IF false THEN"; detectar $R9
nueva M265 "pagar_cuota toma la instantanea del reloj DOS veces";                                                                 repl "$PC9" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i; SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;"; detectar
nueva M266 "pagar_cuota informa 'pagado' sin la mora";                                                                             repl "$PC9" "'pagado', q.valor_cuota + v_mora" "'pagado', q.valor_cuota"; detectar
nueva M267 "pagar_cuota no verifica ct_credito_plan antes de volver";                                                             repl "$PC9" "SET CONSTRAINTS public.ct_credito_plan, public.ct_credito_plan_cuota IMMEDIATE;" "NULL;"; detectar
nueva M268 "pagar_cuota no traduce la carrera con el borrado del usuario (error 'Libro mayor' en vez de 'Sesion invalida')";       repl "$PC9" "IF v_msg LIKE 'Libro mayor:%' AND NOT EXISTS" "IF false AND NOT EXISTS"; equivalente "la rama traduce un error del libro cuando la cuenta ya no existe, pero _bloquear_cuentas toma el FOR NO KEY UPDATE de la cuenta antes y el borrado en cascada espera ese bloqueo: bajo el bloqueo la cuenta NO puede desaparecer (defensa en profundidad, como en E5-E8)" $R9
# ---- abonar_credito ----
nueva M269 "abonar_credito no cobra la mora vencida";                                                                             repl "$AB9" "v_mora := public._mora_pendiente(k.id, v_hoy);" "v_mora := 0;"; detectar
nueva M270 "abonar_credito no cobra el interes corriendo (todo el abono baja capital)";                                           repl "$AB9" "public._interes_corriendo(k.id, v_hoy)" "0::numeric"; detectar
nueva M271 "el abono no descuenta la mora del capital abonado (cobra mora ADEMAS del monto)";                                     repl "$AB9" "v_r := v_monto - v_mora - v_int;" "v_r := v_monto - v_int;"; detectar
nueva M272 "un abono igual a mora + interes (no baja capital) se acepta";                                                        repl "$AB9" "IF v_monto <= v_mora + v_int OR" "IF v_monto < v_mora + v_int OR"; detectar
nueva M273 "un abono mayor que la liquidacion se acepta";                                                                        repl "$AB9" "OR v_monto > v_mora + v_int + v_cap THEN" "THEN"; detectar
nueva M274 "la liquidacion no marca pagadas las cuotas restantes";                                                                repl "$AB9" "UPDATE public.cuota SET pagada = true, fecha_pago = v_hoy WHERE credito_id = k.id AND NOT pagada;" "NULL;"; detectar
nueva M275 "la liquidacion no cierra el credito (sigue ACTIVO con capital 0)";                                                    repl "$AB9" "UPDATE public.credito SET estado = 'PAGADO', fecha_interes = v_eff WHERE id = k.id;" "UPDATE public.credito SET fecha_interes = v_eff WHERE id = k.id;"; detectar
nueva M276 "el primer periodo corto usa la fraccion transcurrida (1 - f) y no la que FALTA del periodo completo";                repl "$AB9" "(v_v - v_eff)::numeric / v_l" "(v_hoy - v_s)::numeric / v_l"; detectar
nueva M277 "el primer periodo corto no multiplica por la tasa mensual";                                                           repl "$AB9" "* public._tasa_mensual(k.tasa_anual) * v_rem, 2);" "* public._tasa_mensual(k.tasa_anual), 2);"; detectar
nueva M278 "tras el abono el ancla fecha_interes no se actualiza";                                                                repl "$AB9" "UPDATE public.credito SET fecha_interes = v_eff WHERE id = k.id;" "NULL;"; detectar
nueva M279 "el ancla tras el abono puede RETROCEDER (ignora la fecha_interes actual)";                                            repl "$AB9" "v_eff := least(greatest(v_hoy, k.fecha_interes, v_s), v_v);" "v_eff := least(greatest(v_hoy, v_s), v_v);"; detectar
nueva M280 "el ancla tras el abono puede salirse del periodo (sin el tope v_j)";                                                  repl "$AB9" "v_eff := least(greatest(v_hoy, k.fecha_interes, v_s), v_v);" "v_eff := greatest(v_hoy, k.fecha_interes, v_s);"; detectar
nueva M281 "el interes cobrado en el abono no se suma a intereses_pagados de la cuota";                                           repl "$AB9" "UPDATE public.cuota SET intereses_pagados = intereses_pagados + v_int WHERE id = q.id;" "NULL;"; detectar
nueva M282 "la mora cobrada en un abono no se recuerda (mora_hasta): se cobra DOS veces";                                         repl "$AB9" "UPDATE public.credito SET mora_hasta = greatest(coalesce(mora_hasta, v_hoy), v_hoy) WHERE id = k.id;" "NULL;"; detectar
nueva M283 "abonar_credito NO corre el motor antes de calcular mora e interes";                                                   repl "$AB9" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M284 "abonar_credito no bloquea la cuenta (abonos simultaneos se pisan)";                                                   repl "$AB9" "IF public._bloquear_cuentas(ARRAY[v_cta]) <> 1 THEN" "IF false THEN"; detectar $R9
# ---- activar_descuento_automatico ----
nueva M285 "activar el descuento arranca el cursor en el DESEMBOLSO (cobros retroactivos)";                                       repl "$AD9" "SET descuento_automatico = true, cobro_hasta = v_hoy WHERE id = k.id;" "SET descuento_automatico = true, cobro_hasta = k.fecha_desembolso WHERE id = k.id;"; detectar
nueva M286 "activar un credito ya activo mueve el cursor (no es idempotente)";                                                    repl "$AD9" "IF p_activo AND k.cobro_hasta IS NULL THEN" "IF p_activo THEN"; detectar
nueva M287 "activar_descuento_automatico NO corre el motor antes de cambiar el cursor";                                           repl "$AD9" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M288 "desactivar el descuento no limpia el cursor";                                                                         repl "$AD9" "SET descuento_automatico = false, cobro_hasta = NULL WHERE id = k.id;" "SET descuento_automatico = false WHERE id = k.id;"; detectar
nueva M289 "activar_descuento_automatico acepta un booleano NULL";                                                                repl "$AD9" "IF p_activo IS NULL THEN" "IF false THEN"; detectar
# ---- integracion con el motor y vistas ----
nueva M290 "_avanzar_hasta ya no llama al cobro automatico de creditos";                                                          repl "$AV" "v_n := v_n + public._cobrar_creditos(p_cuenta_id, p_hoy, p_ahora);" "v_n := v_n;"; detectar
nueva M291 "la salida rapida de _avanzar_hasta ignora los creditos con descuento (una lectura no cobra lo vencido)";               repl "$AV" "SELECT 1 FROM public.credito k WHERE k.cuenta_id = p_cuenta_id AND k.estado = 'ACTIVO' AND k.cobro_hasta IS NOT NULL" "SELECT 1 FROM public.credito k WHERE false AND k.cuenta_id = p_cuenta_id AND k.estado = 'ACTIVO' AND k.cobro_hasta IS NOT NULL"; detectar
nueva M292 "la salida rapida ignora una cuota vencida impaga cuando el cursor ya es hoy (no se reintenta con saldo nuevo)";           repl "$AV" "(k.cobro_hasta < p_hoy OR EXISTS (SELECT 1 FROM public.cuota q" "(k.cobro_hasta < p_hoy OR false AND EXISTS (SELECT 1 FROM public.cuota q"; detectar
nueva M293 "vista_creditos muestra mora_acumulada 0";                                                                             repl "$VC8" "public._mora_pendiente(k.id, v_hoy)" "0::numeric"; detectar
nueva M294 "vista_creditos muestra siempre descuento_automatico false";                                                           repl "$VC8" "'descuento_automatico', k.descuento_automatico" "'descuento_automatico', false"; detectar
# ---- plantillas del libro ----
nueva M295 "la plantilla CREDITO_MORA pasa su pata RESULTADO a sentido E (la mora no se podria asentar)";                         repl "$PV9" "'CREDITO_MORA|RESULTADO|S'])" "'CREDITO_MORA|RESULTADO|E'])"; detectar
nueva M296 "la plantilla CREDITO_ABONO_SIN_INTERES pasa el capital a sentido E";                                                  repl "$PV9" "'CREDITO_ABONO|CREDITO|S'])" "'CREDITO_ABONO|CREDITO|E'])"; detectar
# ---- permisos ----
nueva M297 "banco_app pierde EXECUTE de pagar_cuota";                                                                             sqlm "REVOKE EXECUTE ON FUNCTION $PC9 FROM banco_app"; detectar
nueva M298 "banco_app recibe EXECUTE de la interna _cobrar_creditos";                                                             sqlm "GRANT EXECUTE ON FUNCTION $CC9 TO banco_app"; detectar 49_pagos_conexiones
nueva M299 "banco_app recibe EXECUTE de la interna _pagar_cuota_interna (pagar sin pasar por el motor)";                          sqlm "GRANT EXECUTE ON FUNCTION $PI9 TO banco_app"; detectar 49_pagos_conexiones
nueva M300 "banco_lector recibe EXECUTE de abonar_credito";                                                                       sqlm "GRANT EXECUTE ON FUNCTION $AB9 TO banco_lector"; detectar 49_pagos_conexiones
nueva M301 "pagar_cuota pierde su SECURITY DEFINER";                                                                              sqlm "ALTER FUNCTION $PC9 SECURITY INVOKER"; detectar 49_pagos_conexiones
nueva M302 "abonar_credito pierde su SECURITY DEFINER";                                                                           sqlm "ALTER FUNCTION $AB9 SECURITY INVOKER"; detectar 49_pagos_conexiones
nueva M303 "banco_app recibe UPDATE sobre credito.cobro_hasta (mover el cursor a mano)";                                          sqlm "GRANT UPDATE (cobro_hasta) ON public.credito TO banco_app"; detectar 49_pagos_conexiones
nueva M304 "banco_dev recibe EXECUTE de la interna _plan_restante";                                                               sqlm "GRANT EXECUTE ON FUNCTION $PR9 TO banco_dev"; detectar 49_pagos_conexiones
# auditoria de E9: el saldo disponible se corta en el INSTANTE del evento historico (d 00:00), no al final del dia d
nueva M305 "el saldo disponible de la ronda historica se corta al FIN del dia d (una transferencia externa del mismo dia d, despues de las 00:00, paga la cuota)";   repl "$CC9" "v_corte := CASE WHEN d < p_hoy THEN v_fecha ELSE 'infinity'::timestamptz END;" "v_corte := CASE WHEN d < p_hoy THEN ((d + 1)::timestamp AT TIME ZONE 'America/Bogota') ELSE 'infinity'::timestamptz END;"; detectar

echo ""
echo "=== Mutaciones de E10 (vistas del contrato: fila visible del historial, direccion, contraparte, D8, dashboard, motor, zona horaria, permisos) ==="
PRIMERO="${PRIMERO10:-65_vistas_historial 66_vistas_aleatorio 67_contrato}"      # las pruebas de E10 primero: las mutaciones de E10 se detectan antes
VT='public.v_transaccion_usuario'
JT='public._json_transacciones(uuid,integer)'
VH='public.vista_historial(uuid,integer)'
VD='public.vista_dashboard(uuid)'
R10='51_vistas_conexiones 52_vistas_concurrencia'
# replv VISTA ANTES DESPUES : como repl pero sobre la definicion de una VISTA (CREATE OR REPLACE VIEW con las mismas columnas); falla si el patron no existe
replv() {
  [ "${SALTAR:-0}" = 1 ] && return 0
  $PGU -v ON_ERROR_STOP=1 -d banco_mut -c "DO \$m\$ DECLARE d text := pg_get_viewdef('$1'::regclass); BEGIN IF position(\$a\$$2\$a\$ in d) = 0 THEN RAISE EXCEPTION 'patron no encontrado'; END IF; EXECUTE 'CREATE OR REPLACE VIEW $1 AS ' || replace(d, \$a\$$2\$a\$, \$b\$$3\$b\$); END \$m\$" >/dev/null 2>&1 || { echo "ERROR: no se pudo aplicar la mutacion replv $1"; exit 1; }
}
# ---- la regla de fila visible (v_transaccion_usuario) ----
nueva M306 "una pata BOLSILLO de un BOLSO_INGRESO tambien es visible (una fila por PATA y no por operacion)";                    replv "$VT" "(x.contenedor = 'CUENTA'::contenedor_contable)" "(x.contenedor = 'CDT'::contenedor_contable)"; detectar
nueva M307 "BOLSO_MOVIMIENTO muestra las DOS patas de bolsillo (la E y la S)";                                                    replv "$VT" "(t.tipo <> 'BOLSO_MOVIMIENTO'::tipo_transaccion) OR (t.sentido = 'S'::sentido_asiento)" "true"; detectar
nueva M308 "la pata CDT es siempre visible (CDT_CREACION y CDT_VENCIMIENTO salen dos veces)";                                      replv "$VT" "(x.contenedor = ANY (ARRAY['CUENTA'::contenedor_contable, 'BOLSILLO'::contenedor_contable]))" "(x.contenedor = 'RESULTADO'::contenedor_contable)"; detectar
nueva M309 "el historial incluye las patas RESULTADO (interes y mora como filas extra)";                                           replv "$VT" "ARRAY['CUENTA'::contenedor_contable, 'BOLSILLO'::contenedor_contable, 'CDT'::contenedor_contable]" "ARRAY['CUENTA'::contenedor_contable, 'BOLSILLO'::contenedor_contable, 'CDT'::contenedor_contable, 'RESULTADO'::contenedor_contable]"; replv "$VT" "(t.contenedor = 'CUENTA'::contenedor_contable) OR ((t.contenedor = 'BOLSILLO'" "(t.contenedor = ANY (ARRAY['CUENTA'::contenedor_contable, 'RESULTADO'::contenedor_contable])) OR ((t.contenedor = 'BOLSILLO'"; detectar
nueva M310 "la direccion se invierte (S = recibo, E = envio)";                                                                     replv "$VT" "THEN 'envio'::text" "THEN 'zz'::text"; replv "$VT" "ELSE 'recibo'::text" "ELSE 'envio'::text"; replv "$VT" "THEN 'zz'::text" "THEN 'recibo'::text"; detectar
nueva M311 "la cuenta de la contraparte sale tambien en los movimientos del banco (bono de referido)";                              replv "$VT" "(t.tipo = ANY (ARRAY['ENVIO'::tipo_transaccion, 'RECIBO'::tipo_transaccion])) AND " ""; detectar
nueva M312 "la contraparte sin snapshot no toma el nombre del bolsillo / CDT / producto";                                            replv "$VT" "b.nombre, d.nombre, pr.nombre, " ""; detectar
nueva M313 "la contraparte sin nada queda NULL (sin el respaldo Banco Digital)";                                                    replv "$VT" "pr.nombre, (_reglas_historial() ->> 'contraparte_respaldo'::text))" "pr.nombre)"; detectar
nueva M314 "D8: la regla mostrar_bolso se ignora (siempre visibles)";                                                              replv "$VT" "((_reglas_historial() ->> 'mostrar_bolso'::text))::boolean" "true"; detectar
nueva M315 "D8: los intereses de CDT quedan siempre ocultos";                                                                       replv "$VT" "((_reglas_historial() ->> 'mostrar_interes_cdt'::text))::boolean" "false"; detectar
nueva M316 "D8: los intereses de bolsillo quedan siempre ocultos";                                                                  replv "$VT" "((_reglas_historial() ->> 'mostrar_interes_bolso'::text))::boolean" "false"; detectar
# ---- el formateador y las dos publicas ----
nueva M317 "el historial se ordena por fecha y no por orden (un cobro atrasado quedaria en su sitio cronologico, no por descubrimiento)"; repl "$JT" "ORDER BY x.orden DESC" "ORDER BY x.fecha DESC, x.orden DESC"; detectar
nueva M318 "el limite maximo de _reglas_historial se ignora (50 fijo)";                                                             repl "$JT" "least(coalesce(p_limite, (public._reglas_historial() ->> 'limite_max')::integer), (public._reglas_historial() ->> 'limite_max')::integer)" "coalesce(p_limite, 50)"; detectar
nueva M319 "p_limite = 0 devuelve [] (sin el piso de 1)";                                                                            repl "$JT" "LIMIT greatest(1, least(" "LIMIT greatest(0, least("; detectar
nueva M320 "el formateador no filtra por la cuenta (devuelve el historial de TODOS)";                                                repl "$JT" "WHERE x.cuenta_id = p_cuenta_id" "WHERE true"; detectar
nueva M321 "vista_historial NO corre el motor antes de leer";                                                                         repl "$VH" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M322 "vista_dashboard NO corre el motor antes de leer (no cobra ni devenga)";                                                  repl "$VD" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M323 "vista_dashboard toma la instantanea del reloj DOS veces";                                                                repl "$VD" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i; SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;"; detectar
nueva M324 "vista_historial pasa now() al motor en vez del ahora de la instantanea";                                                  repl "$VH" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "PERFORM public._avanzar_hasta(v_cta, v_hoy, now());"; detectar
nueva M325 "dashboard: cdts.generado suma tambien los CDT CERRADOS";                                                                 repl "$VD" "sum(d.generado_acumulado), 0) FROM public.cdt d WHERE d.cuenta_id = c.id AND d.estado = 'ACTIVO'" "sum(d.generado_acumulado), 0) FROM public.cdt d WHERE d.cuenta_id = c.id"; detectar
nueva M326 "dashboard: cuota_por_pagar usa el capital de la cuota y no su valor";                                                   repl "$VD" "(public._proxima_cuota(k.id)).valor_cuota" "(public._proxima_cuota(k.id)).capital_programado"; detectar
nueva M327 "dashboard: interes_corriendo toma solo el mayor de los creditos (max en vez de sum)";                                   repl "$VD" "sum(public._interes_corriendo(k.id, v_hoy))" "max(public._interes_corriendo(k.id, v_hoy))"; detectar
nueva M328 "dashboard: trae 10 transacciones y no 8";                                                                                repl "$VD" "public._json_transacciones(c.id, 8)" "public._json_transacciones(c.id, 10)"; detectar
nueva M329 "dashboard: el saludo usa los apellidos";                                                                                 repl "$VD" "us.nombres" "us.apellidos"; detectar
nueva M330 "dashboard: balance_total es solo la cuenta principal (no la funcion unica balance_total)";                               repl "$VD" "public.balance_total(c.id)" "c.balance"; detectar
# ---- zona horaria por codigo y fecha_cierre ----
nueva M331 "vista_historial pierde su SET TimeZone (la fecha depende de la sesion)";                                                 sqlm "ALTER FUNCTION $VH RESET TimeZone"; detectar
nueva M332 "pagar_cuota pierde su SET TimeZone (D-E10-8: la fecha de un asiento depende de la sesion)";                              sqlm "ALTER FUNCTION public.pagar_cuota(uuid,text,integer) RESET TimeZone"; detectar
nueva M333 "vista_cdts vuelve a devolver fecha_cierre solo como fecha (D-E10-5: el front la mostraria un dia antes)";                repl "public.vista_cdts(uuid)" "'fecha_cierre', (d.fecha_fin::timestamp AT TIME ZONE 'America/Bogota')" "'fecha_cierre', to_char(d.fecha_fin, 'YYYY-MM-DD')"; detectar
# ---- permisos ----
nueva M334 "banco_app recibe SELECT sobre v_transaccion_usuario (leeria el historial de CUALQUIERA)";                                sqlm "GRANT SELECT ON $VT TO banco_app"; detectar $R10
nueva M335 "banco_app recibe EXECUTE del formateador interno _json_transacciones";                                                  sqlm "GRANT EXECUTE ON FUNCTION $JT TO banco_app"; detectar $R10
nueva M336 "banco_app pierde EXECUTE de vista_dashboard (el front no podria abrir el inicio)";                                       sqlm "REVOKE EXECUTE ON FUNCTION $VD FROM banco_app"; detectar
nueva M337 "vista_historial pierde su SECURITY DEFINER";                                                                             sqlm "ALTER FUNCTION $VH SECURITY INVOKER"; detectar $R10
nueva M338 "banco_lector pierde EXECUTE de _reglas_historial (ya no puede leer la vista)";                                         sqlm "REVOKE EXECUTE ON FUNCTION public._reglas_historial() FROM banco_lector"; detectar $R10
nueva M339 "PUBLIC recibe SELECT sobre v_transaccion_usuario";                                                                       sqlm "GRANT SELECT ON $VT TO PUBLIC"; detectar $R10
# correccion de auditoria de E10: la defensa de la vista debe FALLAR si la vista no existe
nueva M340 "la defensa de v_transaccion_usuario da ok = true cuando la vista desaparece (COALESCE(..., true)); la prueba 65/E6 borra la vista y exige ok = false";                  replv "public.v_integridad_defensas" "(to_regclass('public.v_transaccion_usuario'::text) IS NOT NULL) AND " ""; replv "public.v_integridad_defensas" "has_table_privilege('banco_lector'::name, (to_regclass('public.v_transaccion_usuario'::text))::oid, 'SELECT'::text)), false) AS ok" "has_table_privilege('banco_lector'::name, (to_regclass('public.v_transaccion_usuario'::text))::oid, 'SELECT'::text)), true) AS ok"; detectar


echo ""
echo "=== Mutaciones de E11 (administracion: control de acceso, alcance solo-clientes, detalle con motor, bloqueo, borrado, ajuste, reloj, tasas, auditoria y permisos) ==="
PRIMERO="${PRIMERO11:-69_admin_reloj_tasas 68_admin_usuarios 70_admin_aleatorio}"      # las pruebas de E11 primero: las mutaciones de E11 se detectan antes
R11='53_admin_conexiones 54_admin_concurrencia'
LU='public.admin_listar_usuarios(uuid,text)'
DE='public.admin_detalle_usuario(uuid,text)'
BL='public.admin_bloquear(uuid,text)'
BO='public.admin_borrar_usuario(uuid,text)'
AJ='public.admin_ajustar_balance(uuid,text,numeric,text)'
SR='public.admin_set_reloj(uuid,boolean,text)'
GT='public.admin_get_tasas(uuid)'
TC='public.admin_set_tasa_cdt(uuid,text,text)'
TK='public.admin_set_tasa_credito(uuid,text,text)'
TM='public.admin_set_tasa_mora(uuid,text)'
PT='public._parse_tasa(text,boolean)'
CO='public._cliente_objetivo(text,boolean)'
AA='public._auditar_admin(public.usuario,text,text,text,jsonb,jsonb)'
# ---- _validar_admin ausente en CADA una de las 12 (un cliente, un desconocido o un admin bloqueado la ejecutaria) ----
n=341
for spec in \
  "admin_listar_usuarios|uuid,text|PERFORM public._validar_admin(p_admin_id);" \
  "admin_detalle_usuario|uuid,text|PERFORM public._validar_admin(p_admin_id);" \
  "admin_bloquear|uuid,text|adm := public._validar_admin(p_admin_id);" \
  "admin_desbloquear|uuid,text|adm := public._validar_admin(p_admin_id);" \
  "admin_borrar_usuario|uuid,text|adm := public._validar_admin(p_admin_id);" \
  "admin_ajustar_balance|uuid,text,numeric,text|adm := public._validar_admin(p_admin_id);" \
  "admin_get_reloj|uuid|PERFORM public._validar_admin(p_admin_id);" \
  "admin_set_reloj|uuid,boolean,text|adm := public._validar_admin(p_admin_id);" \
  "admin_get_tasas|uuid|PERFORM public._validar_admin(p_admin_id);" \
  "admin_set_tasa_cdt|uuid,text,text|adm    := public._validar_admin(p_admin_id);" \
  "admin_set_tasa_credito|uuid,text,text|adm    := public._validar_admin(p_admin_id);" \
  "admin_set_tasa_mora|uuid,text|adm    := public._validar_admin(p_admin_id);"
do
  f=${spec%%|*}; rest=${spec#*|}; sig=${rest%%|*}; pat=${rest#*|}
  nueva "M$n" "$f NO valida al admin (un cliente, un desconocido o un admin bloqueado la ejecutaria)"
  repl "public.$f($sig)" "$pat" "NULL;"
  detectar
  n=$((n+1))
done
nueva M353 "admin_detalle_usuario valida al admin DESPUES de buscar al objetivo (un cliente sondearia ids)";   repl "$DE" "PERFORM public._validar_admin(p_admin_id);" "NULL;"; repl "$DE" "t := public._cliente_objetivo(p_usuario_id, false);" "t := public._cliente_objetivo(p_usuario_id, false); PERFORM public._validar_admin(p_admin_id);"; detectar
nueva M354 "_validar_admin deja pasar a un admin BLOQUEADO";                                                    repl "public._validar_admin(uuid)" "IF u.estado = 'BLOQUEADO' THEN" "IF false THEN"; detectar
# ---- alcance: solo CLIENTES ----
nueva M355 "ni _cliente_objetivo ni la relectura bajo bloqueo de admin_bloquear exigen rol CLIENTE (un admin podria bloquear a otro admin; cada capa por separado es redundante)"; repl "$CO" "WHERE us.id = v_ref::uuid AND us.rol = 'CLIENTE'" "WHERE us.id = v_ref::uuid"; repl "$BL" "WHERE us.id = t.id AND us.rol = 'CLIENTE' FOR NO KEY UPDATE" "WHERE us.id = t.id FOR NO KEY UPDATE"; detectar
nueva M356 "la lista no filtra por rol CLIENTE";                                                                 repl "$LU" "WHERE us.rol = 'CLIENTE'" "WHERE true"; equivalente "un ADMIN no tiene cuenta (FK compuesta de E1) y la lista hace JOIN con cuenta: el filtro de rol es una defensa redundante, no observable"
# ---- lista: busqueda ----
nueva M357 "la busqueda ignora el numero de cuenta";                                                              repl "$LU" "ILIKE v_pat)" "ILIKE 'zzzz')"; detectar
nueva M358 "la busqueda distingue tildes (sin unaccent en el nombre)";                                           repl "$LU" "public.unaccent(us.nombres || ' ' || us.apellidos) ILIKE public.unaccent(v_pat)" "(us.nombres || ' ' || us.apellidos) ILIKE v_pat"; detectar
nueva M359 "los comodines del usuario (% _) NO se escapan";                                                      repl "$LU" "replace(replace(replace(v_q, chr(92), chr(92) || chr(92)), '%', chr(92) || '%'), '_', chr(92) || '_')" "v_q"; detectar
nueva M360 "la lista no tiene tope (devuelve todos)";                                                            repl "$LU" "LIMIT (public._reglas_admin() ->> 'lista_max')::int" "LIMIT 100000"; detectar
# ---- detalle ----
nueva M361 "el detalle lista tambien los CDT CERRADOS";                                                          repl "$DE" "FROM public.cdt d WHERE d.cuenta_id = c.id AND d.estado = 'ACTIVO'" "FROM public.cdt d WHERE d.cuenta_id = c.id"; detectar
nueva M362 "el detalle lista tambien los creditos PAGADOS";                                                      repl "$DE" "WHERE k.cuenta_id = c.id AND k.estado = 'ACTIVO'" "WHERE k.cuenta_id = c.id"; detectar
nueva M363 "el detalle NO corre el motor sobre el consultado";                                                   repl "$DE" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M364 "el historial del detalle es el de OTRA cuenta";                                                      repl "$DE" "public._json_transacciones(c.id, (public._reglas_admin() ->> 'historial_max')::int)" "public._json_transacciones((SELECT cc.id FROM public.cuenta cc WHERE cc.id <> c.id ORDER BY cc.id LIMIT 1), 50)"; detectar
nueva M365 "el total del detalle es solo la cuenta principal (no la funcion unica balance_total)";                repl "$DE" "public.balance_total(c.id)" "c.balance"; detectar
nueva M366 "el detalle toma la instantanea del reloj DOS veces";                                                 repl "$DE" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i; SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;"; detectar
# ---- bloquear / desbloquear ----
nueva M367 "admin_bloquear en realidad desbloquea";                                                              repl "$BL" "'BLOQUEADO'" "'ACTIVO'"; detectar
nueva M368 "admin_bloquear no es idempotente (audita y actualiza aunque ya estuviera bloqueado)";                repl "$BL" "IF v_antes <> 'BLOQUEADO' THEN" "IF true THEN"; detectar
nueva M369 "admin_bloquear escribe un evento con otro nombre (la auditoria no lo reconoce)";                     repl "$BL" "'USUARIO_BLOQUEADO'" "'BLOQUEO'"; detectar
nueva M370 "_auditar_admin no registra al actor (ni id ni username)";                                            repl "$AA" "p_admin.id, p_admin.username, p_accion" "NULL, NULL, p_accion"; detectar
nueva M371 "_auditar_admin no fija banco.actor (el CUENTA_BORRADA y el RELOJ_CAMBIO quedan sin atribucion)";     repl "$AA" "PERFORM set_config('banco.actor', p_admin.username, true);" "NULL;"; detectar
# ---- borrar ----
nueva M372 "admin_borrar_usuario escribe el evento con otro nombre";                                             repl "$BO" "'USUARIO_BORRADO'" "'BORRADO'"; detectar
nueva M373 "admin_borrar_usuario no bloquea la cuenta antes de borrar";                                          repl "$BO" "PERFORM public._bloquear_cuentas(ARRAY(SELECT c.id FROM public.cuenta c WHERE c.usuario_id = t.id));" "NULL;"; detectar $R11
nueva M374 "referido_por deja de ser SET NULL (borrar al referidor falla)";                                      sqlm "ALTER TABLE public.usuario DROP CONSTRAINT fk_usuario_referidor, ADD CONSTRAINT fk_usuario_referidor FOREIGN KEY (referido_por) REFERENCES public.usuario (id) ON DELETE NO ACTION"; detectar
nueva M375 "la cascada del borrado se rompe (bolsillo RESTRICT)";                                                sqlm "ALTER TABLE public.bolsillo DROP CONSTRAINT fk_bolsillo_cuenta, ADD CONSTRAINT fk_bolsillo_cuenta FOREIGN KEY (cuenta_id) REFERENCES public.cuenta (id) ON DELETE RESTRICT"; detectar
# ---- ajuste ----
nueva M376 "el ajuste invierte el signo (positivo resta, negativo suma)";                                        repl "$AJ" "CASE WHEN p_monto > 0 THEN 'E' ELSE 'S' END" "CASE WHEN p_monto > 0 THEN 'S' ELSE 'E' END"; detectar
nueva M377 "el ajuste NO corre el motor antes de escribir";                                                      repl "$AJ" "PERFORM public._avanzar_hasta(v_cta, v_hoy, v_ahora);" "NULL;"; detectar
nueva M378 "el ajuste no bloquea la cuenta antes del motor";                                                     repl "$AJ" "IF public._bloquear_cuentas(ARRAY[v_cta]) <> 1 THEN" "IF NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.id = v_cta) THEN"; detectar $R11
nueva M379 "la nota del ajuste no tiene limite de longitud";                                                     repl "$AJ" "IF length(v_nota) > (public._reglas_admin() ->> 'nota_max')::int THEN" "IF false THEN"; detectar
nueva M380 "el ajuste escribe el evento con otro nombre";                                                        repl "$AJ" "PERFORM public._auditar_admin(adm, 'AJUSTE_ADMIN'," "PERFORM public._auditar_admin(adm, 'AJUSTE',"; detectar
nueva M381 "el ajuste no valida el monto (acepta 3 decimales, 1e13, ...)";                                       repl "$AJ" "PERFORM public._validar_monto(abs(p_monto));" "NULL;"; detectar
nueva M382 "el ajuste acepta como referencia solo el uuid (sin username ni numero de cuenta)";                    repl "$AJ" "t := public._cliente_objetivo(p_usuario_id, true);" "t := public._cliente_objetivo(p_usuario_id, false);"; detectar
# ---- reloj ----
nueva M383 "admin_set_reloj no atribuye el cambio al admin (el RELOJ_CAMBIO sale sin actor)";                      repl "$SR" "PERFORM set_config('banco.actor', adm.username, true);" "NULL;"; detectar
nueva M384 "admin_set_reloj ignora la fecha que manda el front (usa siempre la misma)";                           repl "$SR" "RETURN public._reloj_actualizar(p_usar_fecha_real, p_fecha_sistema);" "RETURN public._reloj_actualizar(p_usar_fecha_real, '2099-12-31');"; detectar
# ---- tasas ----
nueva M385 "_parse_tasa acepta mas de 100";                                                                       repl "$PT" "OR v_num > (public._reglas_admin() ->> 'tasa_max')::numeric" "OR false"; detectar
nueva M386 "_parse_tasa acepta el 0 tambien fuera de la mora";                                                    repl "$PT" "(v_num = 0 AND NOT coalesce(p_permite_cero, false))" "false"; detectar
nueva M387 "_parse_tasa acepta mas de 3 decimales";                                                               repl "$PT" "scale(v_num) > (public._reglas_admin() ->> 'tasa_decimales')::int" "false"; detectar
nueva M388 "admin_set_tasa_cdt ignora en silencio un id desconocido";                                             repl "$TC" "WHERE d.id = v_id::uuid FOR NO KEY UPDATE;" "WHERE d.id = v_id::uuid OR true LIMIT 1 FOR NO KEY UPDATE;"; detectar
nueva M389 "admin_set_tasa_cdt no toma el advisory lock de tasas (dos formularios se mezclan)";                    repl "$TC" "PERFORM pg_advisory_xact_lock(hashtextextended('banco.admin.tasas', 0));" "NULL;"; detectar $R11
nueva M390 "admin_set_tasa_mora no toma el advisory lock de tasas";                                               repl "$TM" "PERFORM pg_advisory_xact_lock(hashtextextended('banco.admin.tasas', 0));" "NULL;"; detectar $R11
nueva M391 "admin_set_tasa_credito escribe su evento con otro nombre";                                            repl "$TK" "'TASA_CAMBIO'" "'TASA'"; detectar
nueva M392 "la mora 0 se guarda como 0 y no como NULL (viola el dominio porcentaje)";                             repl "$TM" "nullif(v_tasa, 0)" "v_tasa"; detectar
nueva M393 "admin_get_tasas devuelve la mora NULL (el formulario del front no se puede guardar)";                 repl "$GT" "coalesce((SELECT p.tasa_mora_anual FROM public.parametro p WHERE p.id = 1), 0)" "(SELECT p.tasa_mora_anual FROM public.parametro p WHERE p.id = 1)"; detectar
nueva M394 "admin_set_tasa_mora guarda tambien cuando el valor no cambia (un evento por cada reenvio del formulario)"; repl "$TM" "IF v_antes IS DISTINCT FROM v_tasa THEN" "IF true THEN"; detectar
# ---- permisos ----
nueva M395 "banco_app recibe EXECUTE de _auditar_admin (escribiria eventos a su gusto)";                          sqlm "GRANT EXECUTE ON FUNCTION $AA TO banco_app"; detectar $R11
nueva M396 "PUBLIC recibe EXECUTE de admin_get_reloj";                                                            sqlm "GRANT EXECUTE ON FUNCTION public.admin_get_reloj(uuid) TO PUBLIC"; detectar $R11
nueva M397 "admin_bloquear pasa a SECURITY INVOKER";                                                              sqlm "ALTER FUNCTION $BL SECURITY INVOKER"; detectar $R11
nueva M398 "banco_lector recibe EXECUTE de admin_get_tasas";                                                      sqlm "GRANT EXECUTE ON FUNCTION $GT TO banco_lector"; detectar $R11
nueva M399 "banco_app recibe UPDATE sobre parametro (cambiaria la mora sin pasar por admin_set_tasa_mora)";       sqlm "GRANT UPDATE ON public.parametro TO banco_app"; detectar $R11
nueva M400 "banco_app recibe INSERT sobre audit.evento (falsificaria la auditoria)";                              sqlm "GRANT USAGE ON SCHEMA audit TO banco_app; GRANT INSERT ON audit.evento TO banco_app"; detectar $R11



echo ""
echo "=== Mutaciones de E12 (Control: lista blanca, hash, paginacion, orden, esquema, solo lectura, control de acceso y permisos) ==="
PRIMERO="${PRIMERO12:-71_control 69_admin_reloj_tasas}"      # las pruebas de E12 primero: las mutaciones de E12 se detectan antes
R12='55_control_conexiones'
ES='public.admin_esquema(uuid)'
TB='public.admin_tabla(uuid,text,text)'
RC='public._reglas_control()'
# ---- control de acceso ----
nueva M401 "admin_esquema NO valida al admin (un cliente, un desconocido o un admin bloqueado leeria el esquema)";            repl "$ES" "PERFORM public._validar_admin(p_admin_id);" "NULL;"; detectar
nueva M402 "admin_tabla NO valida al admin (leeria las filas de cualquier tabla de la lista)";                                repl "$TB" "PERFORM public._validar_admin(p_admin_id);" "NULL;"; detectar
nueva M403 "admin_tabla valida al admin DESPUES de comprobar la tabla (un cliente sondearia la lista blanca)";                  repl "$TB" "PERFORM public._validar_admin(p_admin_id);" "NULL;"; repl "$TB" "v_tam := (rg ->> 'pagina_tam')::integer;" "v_tam := (rg ->> 'pagina_tam')::integer; PERFORM public._validar_admin(p_admin_id);"; detectar
# ---- el hash ----
nueva M404 "el hash NO se enmascara (_reglas_control sin columnas enmascaradas)";                                              repl "$RC" "jsonb_build_object('usuario', jsonb_build_array('password_hash'))" "jsonb_build_object()"; detectar $R12
nueva M405 "se enmascara cedula en vez de password_hash (el hash viaja)";                                                     repl "$RC" "jsonb_build_array('password_hash')" "jsonb_build_array('cedula')"; detectar $R12
nueva M406 "la mascara no es la del contrato";                                                                                 repl "$RC" "'mascara',    '" "'mascara',    'X"; detectar
nueva M407 "el enmascarado sobrescribe pero NO quita la columna original (equivalente: el || reemplaza el valor)";             repl "$TB" "(to_jsonb(t) - %L::text[]) || %L::jsonb" "to_jsonb(t) || %L::jsonb"; repl "$TB" "v_menos, v_mascara," "v_mascara,"; equivalente "el operador || del JSON reemplaza el valor de la clave: el hash real no sale aunque no se quite antes (la resta es una defensa redundante)"
# ---- paginacion y orden ----
nueva M408 "50 por pagina pasa a 49";                                                                                          repl "$RC" "'pagina_tam', 50," "'pagina_tam', 49,"; detectar
nueva M409 "sin recorte superior de la pagina (la pagina 99 devuelve vacio)";                                                  repl "$TB" "greatest(1, least(v_txt::bigint, v_paginas::bigint))::integer" "greatest(1, v_txt::bigint)::integer"; detectar
nueva M410 "total_paginas redondea hacia abajo (la ultima pagina parcial no cuenta)";                                          repl "$TB" "ceil(v_total::numeric / v_tam)::integer" "floor(v_total::numeric / v_tam)::integer"; detectar
nueva M431 "un entero de mas de 9 digitos (1000000000) vuelve a la pagina 1 en vez de la ultima (caso limite de la auditoria)";   repl "$TB" "WHEN length(v_txt) > 18 THEN v_paginas" "WHEN length(v_txt) > 9 THEN 1"; detectar
nueva M432 "sin la guarda de longitud: un entero de mas de 18 digitos desborda el bigint (error en vez de la ultima pagina)";       repl "$TB" "WHEN length(v_txt) > 18 THEN v_paginas" "WHEN false THEN v_paginas"; detectar
nueva M433 "un entero de mas de 18 digitos da la pagina 1 en vez de la ultima";                                                     repl "$TB" "WHEN length(v_txt) > 18 THEN v_paginas" "WHEN length(v_txt) > 18 THEN 1"; detectar
nueva M411 "una pagina no numerica da la pagina 0 (offset negativo)";                                                          repl "$TB" "!~ '^[0-9]+$' THEN 1" "!~ '^[0-9]+$' THEN 0"; detectar
nueva M412 "transaccion sale de la mas antigua a la mas reciente";                                                             repl "$RC" "'transaccion', 't.orden DESC'" "'transaccion', 't.orden'"; detectar
nueva M413 "usuario se ordena por id descendente (no por creado_en)";                                                          repl "$RC" "'usuario', 't.creado_en DESC, t.id'" "'usuario', 't.id DESC'"; detectar
# ---- lista blanca ----
nueva M414 "la lista blanca incluye audit.evento";                                                                             repl "$RC" "'transaccion', 'reloj', 'parametro')" "'transaccion', 'reloj', 'parametro', 'audit.evento')"; detectar
nueva M415 "el nombre de tabla se compara sin distinguir mayusculas (Usuario pasa)";                                           repl "$TB" "WHERE t.nombre = p_tabla" "WHERE lower(t.nombre) = lower(p_tabla)"; detectar
nueva M416 "el mensaje de tabla no permitida cambia";                                                                          repl "$RC" "'Tabla no permitida'" "'Tabla no encontrada'"; detectar
nueva M417 "el SQL dinamico usa %s en vez de %I (sin entrecomillar identificadores)";                                          repl "$TB" "public.%I" "public.%s"; detectar
# ---- esquema ----
nueva M418 "la FK compuesta de cuenta sale duplicada (usuario_id -> id y rol -> rol)";                                         repl "$ES" "ca.attnum = k.conkey[1]" "ca.attnum = ANY (k.conkey)"; detectar
nueva M419 "las FK de una tabla a si misma (usuario.referido_por) no salen";                                                   repl "$ES" "AND tr.relname IN (SELECT w2.nombre FROM wl w2)" "AND tr.oid <> k.conrelid"; detectar
nueva M420 "llave marca las UNIQUE y no la clave primaria";                                                                     repl "$ES" "k.contype = 'p' AND a.attnum = ANY (k.conkey)" "k.contype = 'u' AND a.attnum = ANY (k.conkey)"; detectar
nueva M421 "unico marca tambien los UNIQUE compuestos (cuota.numero)";                                                          repl "$ES" "k.conkey = ARRAY[a.attnum]" "a.attnum = ANY (k.conkey)"; detectar
nueva M422 "no_nulo siempre falso";                                                                                             repl "$ES" "'no_nulo', a.attnotnull" "'no_nulo', false"; detectar
nueva M423 "tipo sin la precision (numeric(8,2) -> numeric)";                                                                   repl "$ES" "format_type(a.atttypid, a.atttypmod)" "format_type(a.atttypid, NULL)"; detectar
nueva M424 "las tablas del esquema salen en orden alfabetico y no en el de la lista";                                           repl "$ES" ") ORDER BY wl.ord), '[]'::jsonb))" ") ORDER BY wl.nombre), '[]'::jsonb))"; detectar
# ---- solo lectura y permisos ----
nueva M425 "admin_tabla pasa a VOLATILE (ya no es de solo lectura por catalogo)";                                               sqlm "ALTER FUNCTION $TB VOLATILE"; detectar
nueva M426 "admin_esquema pasa a VOLATILE";                                                                                      sqlm "ALTER FUNCTION $ES VOLATILE"; detectar
nueva M427 "admin_tabla pasa a SECURITY INVOKER";                                                                                sqlm "ALTER FUNCTION $TB SECURITY INVOKER"; detectar $R12
nueva M428 "banco_lector recibe EXECUTE de admin_tabla";                                                                         sqlm "GRANT EXECUTE ON FUNCTION $TB TO banco_lector"; detectar $R12
nueva M429 "PUBLIC recibe EXECUTE de admin_esquema";                                                                             sqlm "GRANT EXECUTE ON FUNCTION $ES TO PUBLIC"; detectar $R12
nueva M430 "banco_app recibe EXECUTE de _reglas_control";                                                                        sqlm "GRANT EXECUTE ON FUNCTION $RC TO banco_app"; detectar $R12



echo ""
echo "=== Mutaciones de E13 (mantenimiento: COMMIT por cuenta, search_path en cada transaccion, 55P03, motor, resumen, evento, informe de integridad y permisos) ==="
PRIMERO="${PRIMERO13:-72_mantenimiento}"      # las pruebas de E13 primero
BASE_SQL=""                                   # las mutaciones de E13 solo afectan a E13: no se corre la base de E2-E4 (solo 72 y despues reales/56)
R13='56_mantenimiento'
SA='public.sp_avanzar_todos(jsonb)'
SV='public.sp_verificar_integridad(jsonb)'
RM='public._reglas_mantenimiento()'
# ---- sp_avanzar_todos: transacciones, errores y bloqueos ----
nueva M434 "sin COMMIT por cuenta (todo el cierre en UNA transaccion: un corte pierde lo ya procesado)";               repl "$SA" "    END;
    COMMIT;
  END LOOP;" "    END;
  END LOOP;"; detectar $R13
nueva M435 "sin captura de errores por cuenta (una cuenta que falla aborta TODA la corrida)";                          repl "$SA" "WHEN OTHERS THEN" "WHEN no_data_found THEN"; detectar $R13
nueva M436 "sin lock_timeout (una cuenta tomada deja la corrida esperando indefinidamente)";                            repl "$SA" "PERFORM pg_catalog.set_config('lock_timeout', rg ->> 'lock_timeout', true);" "NULL;"; detectar $R13
nueva M437 "el 55P03 se cuenta como ERROR de la cuenta y no como timeout de bloqueo (ajuste 2)";                       repl "$SA" "WHEN lock_not_available THEN" "WHEN data_exception THEN"; detectar $R13
nueva M438 "UNA sola instantanea del reloj para todas las cuentas (fuera del bucle)";                                   repl "$SA" "SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;" "NULL;"; repl "$SA" "v_ids := ARRAY(SELECT c.id FROM public.cuenta c ORDER BY c.id);" "v_ids := ARRAY(SELECT c.id FROM public.cuenta c ORDER BY c.id); SELECT i.hoy, i.ahora INTO v_hoy, v_ahora FROM public._reloj_instantanea() i;"; detectar $R13
# ---- el search_path en CADA transaccion (ajuste 1) ----
nueva M439 "el search_path NO se fija al inicio de cada cuenta (un COMMIT lo descarto)";                                 repl "$SA" "LOOP
    PERFORM pg_catalog.set_config('search_path', 'public, pg_temp', true);" "LOOP
    NULL;"; detectar $R13
nueva M440 "el search_path NO se fija en la transaccion FINAL de auditoria";                                            repl "$SA" "search_path de nuevo
  PERFORM pg_catalog.set_config('search_path', 'public, pg_temp', true);" "search_path de nuevo
  NULL;"; detectar $R13
nueva M441 "el search_path NO se fija en la transaccion de CAPTURA de cuentas";                                         repl "$SA" "ANTES de cualquier otra cosa
  PERFORM pg_catalog.set_config('search_path', 'public, pg_temp', true);" "ANTES de cualquier otra cosa
  NULL;"; detectar $R13
# ---- sp_avanzar_todos: motor, resumen y auditoria ----
nueva M442 "el cierre NO llama al motor (_avanzar_hasta)";                                                              repl "$SA" "v_g := public._avanzar_hasta(v_id, v_hoy, v_ahora);" "v_g := 0;"; detectar $R13
nueva M443 "el total de grupos cuenta 1 por cuenta con cambios y no los grupos escritos";                               repl "$SA" "v_grupos  := v_grupos + v_g;" "v_grupos  := v_grupos + 1;"; detectar $R13
nueva M444 "con_cambios cuenta doble";                                                                                  repl "$SA" "v_cambios := v_cambios + 1;" "v_cambios := v_cambios + 2;"; detectar $R13
nueva M445 "las cuentas omitidas por timeout no se cuentan";                                                            repl "$SA" "v_omit := v_omit + 1;" "v_omit := v_omit;"; detectar $R13
nueva M446 "los errores por cuenta no se detallan";                                                                     repl "$SA" "IF jsonb_array_length(v_errores) < (rg ->> 'errores_max')::integer THEN" "IF false THEN"; detectar $R13
nueva M447 "el evento de auditoria lleva otro nombre";                                                                  repl "$SA" "'MANTENIMIENTO_AVANZAR'" "'MANTENIMIENTO'"; detectar $R13
nueva M448 "el evento guarda tambien la lista de errores";                                                              repl "$SA" "resultado - 'errores');" "resultado);"; detectar $R13
nueva M449 "el evento no registra quien lo ejecuto";                                                                    repl "$SA" "VALUES (session_user::text," "VALUES (NULL::text,"; detectar $R13
nueva M450 "la captura de cuentas es incompleta (solo 5)";                                                              repl "$SA" "ARRAY(SELECT c.id FROM public.cuenta c ORDER BY c.id)" "ARRAY(SELECT c.id FROM public.cuenta c ORDER BY c.id LIMIT 5)"; detectar $R13
# ---- sp_verificar_integridad ----
nueva M451 "el informe no trae las filas defectuosas de los creditos";                                                  repl "$SV" "public.v_integridad_creditos x WHERE NOT x.ok" "public.v_integridad_creditos x WHERE false"; detectar $R13
nueva M452 "el informe no trae las defensas caidas";                                                                    repl "$SV" "public.v_integridad_defensas x WHERE NOT x.ok" "public.v_integridad_defensas x WHERE false"; detectar $R13
nueva M453 "el informe no limita la muestra de filas (tope 1000 en vez de 20)";                                         repl "$SV" "LIMIT m) s" "LIMIT 1000) s"; detectar $R13
nueva M454 "el informe dice ok = true aunque haya desvios";                                                             repl "$SV" "'ok', g.ok," "'ok', true,"; detectar $R13
nueva M455 "el informe no restaura el search_path del llamador";                                                        repl "$SV" "PERFORM pg_catalog.set_config('search_path', v_sp, true);" "NULL;"; detectar $R13
nueva M456 "el tope de muestra se ignora (3 filas)";                                                                    repl "$SV" "m := (public._reglas_mantenimiento() ->> 'muestra_max')::integer;" "m := 3;"; detectar $R13
# ---- permisos y forma ----
nueva M457 "banco_app recibe EXECUTE de sp_avanzar_todos";                                                              sqlm "GRANT EXECUTE ON PROCEDURE $SA TO banco_app"; detectar $R13
nueva M458 "banco_lector recibe EXECUTE de sp_verificar_integridad";                                                    sqlm "GRANT EXECUTE ON PROCEDURE $SV TO banco_lector"; detectar $R13
nueva M459 "PUBLIC recibe EXECUTE de _reglas_mantenimiento";                                                            sqlm "GRANT EXECUTE ON FUNCTION $RM TO PUBLIC"; detectar $R13
nueva M460 "sp_avanzar_todos pasa a SECURITY DEFINER (ya no puede hacer COMMIT)";                                       sqlm "ALTER PROCEDURE $SA SECURITY DEFINER"; detectar $R13
nueva M461 "sp_avanzar_todos recibe una clausula SET search_path (ya no puede hacer COMMIT)";                           sqlm "ALTER PROCEDURE $SA SET search_path = public"; detectar $R13
nueva M462 "el lock_timeout provisional pasa de 2s a 60s";                                                              repl "$RM" "'lock_timeout', '2s'" "'lock_timeout', '60s'"; detectar $R13
# ---- el resumen no cuenta lo revertido (auditoria de E13: estado POR CUENTA y bandera de exito) ----
nueva M463 "sin estado por cuenta ni bandera de exito (una cuenta que falla arrastra el v_g de la anterior y se cuenta lo revertido)"; repl "$SA" "v_g  := 0;" "NULL;"; repl "$SA" "IF v_ok THEN" "IF true THEN"; detectar $R13
nueva M464 "una cuenta omitida por timeout de bloqueo se cuenta como cuenta con cambios y suma un grupo"; repl "$SA" "v_omit := v_omit + 1;" "v_omit := v_omit + 1; v_cambios := v_cambios + 1; v_grupos := v_grupos + 1;"; detectar $R13
nueva M465 "una cuenta con error se cuenta como cuenta con cambios y suma un grupo (contadores dentro del manejador)"; repl "$SA" "v_err := v_err + 1;" "v_err := v_err + 1; v_cambios := v_cambios + 1; v_grupos := v_grupos + 1;"; detectar $R13
nueva M466 "sin reinicio de v_g por cuenta (queda la bandera de exito)"; repl "$SA" "v_g  := 0;" "NULL;"; equivalente "defensa redundante: la bandera de exito ya impide contar una cuenta fallida, aunque v_g conserve el valor de la anterior (el reinicio y la bandera son dos defensas del mismo defecto; cada una por si sola basta)" $R13
nueva M467 "sin bandera de exito (queda el reinicio de v_g por cuenta)"; repl "$SA" "IF v_ok THEN" "IF true THEN"; equivalente "defensa redundante: el reinicio de v_g a 0 por cuenta ya impide contar una cuenta fallida (no asigna nada antes de fallar), aunque no haya bandera; las dos defensas son independientes" $R13
unset BASE_SQL

echo ""
echo "=== Mutaciones de E14 (seed y QA: catalogo, identidades fijas, clave, historia, estado final, limpieza del esquema seed, reproducibilidad y respaldo/restauracion protegidos) ==="
# Estas mutaciones rompen COPIAS de db/seed (/tmp/seed_mut) y ejecutan las pruebas reales/57 (seed) y reales/58 (respaldo) con SEED_DIR apuntando a la copia:
# trabajan en bases aisladas (banco_seed_*, banco_rs*) y no tocan banco, banco_test ni la plantilla de mutaciones.
nueva_seed() { # nueva_seed ID DESCRIPCION : copia limpia de db/seed
  ID="$1"; DESC="$2"; NUM=${ID#M}
  if [ "$NUM" -lt "${DESDE:-0}" ]; then SALTAR=1; return 0; fi
  if [ -n "${SOLO:-}" ]; then case " $SOLO " in *" $ID "*) ;; *) SALTAR=1; return 0;; esac; fi
  SALTAR=0; TOTAL=$((TOTAL+1))
  rm -rf /tmp/seed_mut; mkdir -p /tmp/seed_mut; cp /work/seed/* /tmp/seed_mut/
}
cambia() { # cambia ARCHIVO VIEJO NUEVO [N] : reemplazo LITERAL de la N-esima aparicion (1 por defecto) dentro de una linea; falla si el patron no existe
  [ "${SALTAR:-0}" = 1 ] && return 0
  OLD="$2" NEW="$3" N="${4:-1}" awk 'BEGIN { old = ENVIRON["OLD"]; new = ENVIRON["NEW"]; n = ENVIRON["N"] + 0; c = 0; hit = 0 }
    { line = $0; out = ""
      while ((i = index(line, old)) > 0) {
        c++
        if (c == n) { out = out substr(line, 1, i - 1) new; line = substr(line, i + length(old)); hit = 1; break }
        out = out substr(line, 1, i + length(old) - 1); line = substr(line, i + length(old))
      }
      print out line }
    END { if (!hit) exit 3 }' "/tmp/seed_mut/$1" > "/tmp/seed_mut/$1.x" || { echo "ERROR: patron no encontrado en $1: $2"; exit 1; }
  mv "/tmp/seed_mut/$1.x" "/tmp/seed_mut/$1"
}
detectar_seed() { # detectar_seed REAL... : exige que alguna prueba real falle con la copia mutada
  [ "${SALTAR:-0}" = 1 ] && return 0
  QUIEN=""
  for r in "$@"; do
    if ! FAIL_RAPIDO=1 SEED_DIR=/tmp/seed_mut DB=banco_mut sh -c "tr -d '\r' < /work/tests/reales/$r.sh | sh -s" >/tmp/mut_out 2>&1; then
      QUIEN="reales/$r"; MSG=$(grep -m1 -E '^FAIL' /tmp/mut_out | cut -c1-150); break
    fi
  done
  # un candado de respaldo que una mutacion deje retenido NO debe contaminar las siguientes: se cierran las sesiones que lo sostienen (desde el servidor, nunca con senales)
  $PGU -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype = 'advisory' AND classid = 7314 AND pid <> pg_backend_pid()" >/dev/null 2>&1
  if [ -n "$QUIEN" ]; then echo "$ID  DETECTADA  $DESC"; echo "      -> $QUIEN: $MSG"
  else echo "$ID  *** NO DETECTADA ***  $DESC"; FALLAS=$((FALLAS+1)); fi
}
equivalente_seed() { # equivalente_seed RAZON REAL... : como detectar_seed, pero una mutacion que NINGUNA prueba real detecta se declara EQUIVALENTE con su razon
  [ "${SALTAR:-0}" = 1 ] && return 0
  _razon="$1"; shift; _f=$FALLAS; detectar_seed "$@"
  if [ "$FALLAS" -gt "$_f" ]; then FALLAS=$_f; echo "      -> EQUIVALENTE (no observable, no es un hueco de pruebas): $_razon"; fi
}
# ---- catalogo ----
nueva_seed M468 "la tasa del CDT de 90 dias cambia (9,25 -> 9,5)";                                      cambia 00_catalogo.sql "('CDT 90 días',   90, 9.25," "('CDT 90 días',   90, 9.5,";            detectar_seed 57_seed
nueva_seed M469 "el tope de Libre inversion deja de ser 30M (31M)";                                      cambia 00_catalogo.sql "1000000,    30000000,  6,  24,  30000000" "1000000,    31000000,  6,  24,  31000000"; detectar_seed 57_seed
nueva_seed M470 "Inmuebles pierde la regla de edad";                                                     cambia 00_catalogo.sql "2000000000, 60, 360, 2000000000, 100,  true" "2000000000, 60, 360, 2000000000, 100,  false"; detectar_seed 57_seed
nueva_seed M471 "el minimo de los CDT baja a 50.000";                                                    cambia 00_catalogo.sql "10.00, 100000)" "10.00, 50000)";           detectar_seed 57_seed
nueva_seed M472 "recargar el catalogo ya no restaura la tasa editada de los CDT"; cambia 00_catalogo.sql "SET plazo_dias = EXCLUDED.plazo_dias, tasa_anual = EXCLUDED.tasa_anual, monto_min = EXCLUDED.monto_min;" "SET plazo_dias = EXCLUDED.plazo_dias, monto_min = EXCLUDED.monto_min;"; detectar_seed 57_seed
# ---- identidades, clave y estructura ----
nueva_seed M473 "el cliente no recibe sus identidades fijas (seed.fijar_identidad no se llama)";         cambia 10_funciones_seed.sql "PERFORM seed.fijar_identidad(v_id, p_username, p_cuenta, p_codigo);" "NULL;"; detectar_seed 57_seed
nueva_seed M474 "verificar_correo ANTES de fijar la identidad (el bono guardaria la cuenta aleatoria)";  cambia 10_funciones_seed.sql "PERFORM seed.fijar_identidad(v_id, p_username, p_cuenta, p_codigo);" "PERFORM public.verificar_correo(v_id); PERFORM seed.fijar_identidad(v_id, p_username, p_cuenta, p_codigo);"; detectar_seed 57_seed
nueva_seed M475 "session_replication_role no se restablece tras fijar la identidad";                    cambia 10_funciones_seed.sql "PERFORM pg_catalog.set_config('session_replication_role', 'origin', true);" "NULL;" 2; detectar_seed 57_seed
nueva_seed M476 "admin1 se crea como CLIENTE";                                                           cambia 10_funciones_seed.sql "p_nacimiento, 'ADMIN', 'ACTIVO'" "p_nacimiento, 'CLIENTE', 'ACTIVO'"; detectar_seed 57_seed
nueva_seed M477 "el hash demo ya no corresponde a Banco2026";                                            cambia 10_funciones_seed.sql "whFuDOa'" "whFuDOb'"; detectar_seed 57_seed
# ---- historia y estado final ----
nueva_seed M478 "el seed termina con el reloj en modo MANUAL (no vuelve a real)";                        cambia 20_demo.sql "PERFORM seed.volver_a_real();" "NULL;"; detectar_seed 57_seed
nueva_seed M479 "el seed no corre sp_avanzar_todos al final (lo guardado queda atrasado)";               cambia 20_demo.sql "CALL public.sp_avanzar_todos();" "SELECT 1;"; detectar_seed 57_seed
nueva_seed M480 "bloqueado1 no se bloquea";                                                              cambia 20_demo.sql "PERFORM public.admin_bloquear(ad, bl::text);" "NULL;"; detectar_seed 57_seed
nueva_seed M481 "la mora del seed deja de ser 30 %";                                                     cambia 20_demo.sql "admin_set_tasa_mora(ad, '30')" "admin_set_tasa_mora(ad, '0')"; detectar_seed 57_seed
nueva_seed M482 "el credito Vehiculo se crea con mas cuotas pagadas: se le activa el descuento automatico"; cambia 20_demo.sql "v_vehiculo := public.solicitar_credito(jp, p_vehiculo, 50000000, 48) ->> 'id';" "v_vehiculo := public.solicitar_credito(jp, p_vehiculo, 50000000, 48) ->> 'id'; PERFORM public.activar_descuento_automatico(jp, v_vehiculo, true);"; detectar_seed 57_seed
nueva_seed M483 "se omite setseed (los ingresos aleatorios dejan de ser reproducibles)";                 cambia 20_demo.sql "SELECT setseed(0.2026);" "SELECT 1;"; detectar_seed 57_seed
# ---- limpieza del esquema seed y negativas ----
nueva_seed M484 "el esquema seed ya no se elimina si la historia falla (sin trap de limpieza)";          cambia sembrar.sh "trap limpiar EXIT" "trap : EXIT"; detectar_seed 57_seed
nueva_seed M485 "el seed deja de negarse sobre un banco con datos";                                      cambia sembrar.sh 'if [ "$n" != "0" ]; then' 'if false; then'; detectar_seed 57_seed
# ---- respaldo / restauracion ----
nueva_seed M487 "restore se ejecuta sin --yes";                                                          cambia respaldo.sh '[ "$SI" = "--yes" ] || die' 'true || die'; detectar_seed 58_respaldo
nueva_seed M488 "restore no compara la BD de paso con el manifiesto antes de intercambiar";              cambia respaldo.sh 'if ! cmp -s /tmp/respaldo_h.$$ /tmp/respaldo_m.$$; then' 'if false; then'; detectar_seed 58_respaldo
nueva_seed M489 "restore no exige manifiesto";                                                           cambia respaldo.sh '[ -s "$F.huella" ] || die' 'true || die'; detectar_seed 58_respaldo
nueva_seed M490 "los renombrados no cierran las conexiones abiertas (backend, pgAdmin) antes de renombrar";   cambia respaldo.sh 'SELECT pg_terminate_backend(pid) FROM' 'SELECT 1 AS x FROM'; detectar_seed 58_respaldo
nueva_seed M491 "restore no comprueba que el volcado sea de este banco";                                 cambia respaldo.sh 'grep -q "TABLE $t " /tmp/respaldo_toc.$$ ||' 'true ||'; detectar_seed 58_respaldo
nueva_seed M492 "backup guarda un manifiesto sin la huella global";                                              cambia respaldo.sh '"$(md5sum < "$F.lineas.tmp" | cut -d'"'"' '"'"' -f1)"' '""'; detectar_seed 58_respaldo
nueva_seed M493 "la restauracion no conserva la BD anterior como _previo (la elimina en vez de renombrarla)";    cambia respaldo.sh 'if ! renombrar cerrar "$_R" "$_V"; then' 'if ! Q postgres "DROP DATABASE \"$_R\" WITH (FORCE)" >/dev/null 2>&1; then'; detectar_seed 58_respaldo
# ---- correccion de la auditoria de E14: integridad del respaldo, huella ampliada, intercambio seguro y limpieza ante HUP ----
nueva_seed M494 "backup deja de rechazar una BD con v_integridad_global.ok = false (ni en el chequeo previo ni en el snapshot)"; cambia respaldo.sh '[ "$(integridad "$B")" = "t" ] || die' 'true || die'; cambia respaldo.sh '[ "$(mval "$F.extra.tmp" integridad_ok)" = "t" ] || {' 'true || {'; detectar_seed 58_respaldo
nueva_seed M495 "restore no exige integridad verdadera en la BD restaurada (acepta lo que diga el manifiesto)"; cambia respaldo.sh '[ "$OK" = "t" ] || die' 'true || die'; detectar_seed 58_respaldo
nueva_seed M496 "restore acepta un manifiesto que declara integridad_ok = f";                            cambia respaldo.sh '[ "$(mval "$F.huella" integridad_ok)" = "t" ] || die' 'true || die'; detectar_seed 58_respaldo
nueva_seed M497 "la huella solo cuenta filas (no incluye el contenido de las columnas)";               cambia respaldo.sh "string_agg(x::text, E'" "string_agg('x', E'"; detectar_seed 58_respaldo
nueva_seed M498 "la huella del esquema ignora los permisos (ACL) y el dueño de las funciones";                  cambia respaldo.sh "|| ':' || coalesce(p.proacl::text, '') || ':' || pg_get_userbyid(p.proowner)" ""; detectar_seed 58_respaldo
nueva_seed M499 "la huella no incluye audit.evento";                                                    cambia respaldo.sh 'public.parametro audit.evento"' 'public.parametro"'; detectar_seed 58_respaldo
nueva_seed M500 "restore elimina el _previo ANTERIOR antes de completar el intercambio";               cambia respaldo.sh '  eB=$(existe "$B")' '  eB=$(existe "$B"); Q postgres "DROP DATABASE IF EXISTS \"${B}_previo\" WITH (FORCE)" >/dev/null'; detectar_seed 58_respaldo
nueva_seed M501 "recuperar no devuelve la BD anterior cuando el corte fue entre los dos renombrados"; cambia respaldo.sh 'if [ "$_eB" = "0" ] && [ "$_eR" = "1" ]; then' 'if false; then'; detectar_seed 58_respaldo
nueva_seed M502 "restore no se auto-recupera de un intercambio interrumpido antes de empezar";                   cambia respaldo.sh 'sanear "$B" || die "hay un intercambio anterior' 'true || die "hay un intercambio anterior'; detectar_seed 58_respaldo
nueva_seed M503 "restore no atiende la senal TERM (sin trap: queda entre los dos renombrados)";         cambia respaldo.sh "exit 143' TERM" "exit 143' TERM; trap - TERM"; detectar_seed 58_respaldo
nueva_seed M504 "recuperar no cierra un intercambio ya hecho pero sin terminar";                        cambia respaldo.sh 'elif [ "$_eB" = "1" ] && [ "$_eR" = "1" ]; then' 'elif false; then'; detectar_seed 58_respaldo
nueva_seed M505 "backup NO comparte el snapshot con pg_dump (el volcado ve los cambios posteriores al manifiesto)"; cambia respaldo.sh ' --snapshot="\$SNAP"' ''; detectar_seed 58_respaldo
nueva_seed M506 "sembrar.sh no atiende HUP (el esquema seed queda tras la interrupcion)";               cambia sembrar.sh "trap 'salir 129' HUP" "trap - HUP"; detectar_seed 57_seed
nueva_seed M507 "la limpieza de sembrar.sh no cierra la sesion del seed";                               cambia sembrar.sh "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name" "SELECT 1 FROM pg_stat_activity WHERE application_name"; detectar_seed 57_seed
nueva_seed M508 "sembrar.sh ejecuta psql en primer plano (la senal espera a que termine la historia)";  cambia sembrar.sh 'EJEC() { P "$@" & CH=$!; wait "$CH"; _rc=$?; CH=""; return $_rc; }' 'EJEC() { P "$@"; return $?; }'; detectar_seed 57_seed
nueva_seed M509 "recuperar devuelve EXITO aunque no pudo devolver la retirada a su nombre";                      cambia respaldo.sh 'Repite: respaldo.sh recuperar" >&2; return 1; fi' 'Repite: respaldo.sh recuperar" >&2; return 0; fi'; detectar_seed 58_respaldo
nueva_seed M510 "cerrar ELIMINA el previo anterior antes de apartarlo (el defecto de la auditoria)";               cambia respaldo.sh 'renombrar apartar "$_V" "$_O" ||' 'Q postgres "DROP DATABASE IF EXISTS \"$_V\" WITH (FORCE)" >/dev/null 2>&1; renombrar apartar "$_V" "$_O" ||'; detectar_seed 58_respaldo
nueva_seed M511 "si falla el renombrado de la retirada, el previo apartado NO vuelve a su nombre";                  cambia respaldo.sh 'renombrar deshacer_apartar "$_O" "$_V" || {' 'true || {'; detectar_seed 58_respaldo
nueva_seed M512 "cerrar no elimina el previo apartado una vez terminado el renombrado";                           cambia respaldo.sh 'Q postgres "DROP DATABASE IF EXISTS \"$_O\" WITH (FORCE)" >/dev/null 2>&1' ':'; detectar_seed 58_respaldo
nueva_seed M513 "el chequeo previo de integridad del backup sobra: el del snapshot tambien rechaza (defensa redundante)"; cambia respaldo.sh '[ "$(integridad "$B")" = "t" ] || die' 'true || die'; equivalente_seed "defensa redundante: el chequeo DENTRO del snapshot (integridad_ok del manifiesto) rechaza igual una BD danada con el mismo mensaje; el previo solo evita armar el volcado" 58_respaldo
nueva_seed M514 "recuperar devuelve EXITO aunque la BD principal no exista";                                      cambia respaldo.sh 'if [ "${2:-1}" = "1" ] && [ "$(existe "$1")" != "1" ]; then' 'if false; then'; detectar_seed 58_respaldo
nueva_seed M515 "sanear ignora los estados AMBIGUOS (actua aunque existan la retirada y el apartado a la vez)";      cambia respaldo.sh 'if [ "$_eB" = "0" ] && [ "$_eR" = "1" ] && [ "$_eO" = "1" ]; then' 'if false; then'; detectar_seed 58_respaldo
nueva_seed M516 "los ganchos de fallo funcionan SIN el indicador RESPALDO_ENTORNO_PRUEBAS (producto real expuesto)"; cambia respaldo.sh 'if [ "${RESPALDO_ENTORNO_PRUEBAS:-}" != "1" ]; then' 'if false; then'; cambia respaldo.sh 'hook() { [ "${RESPALDO_ENTORNO_PRUEBAS:-}" = "1" ] && [ "${B:-banco}" != "banco" ] && [' 'hook() { [ "${B:-banco}" != "banco" ] && ['; detectar_seed 58_respaldo
nueva_seed M517 "los ganchos de fallo tambien actuan sobre la BD REAL 'banco' (sin la exclusion de la base real)";   cambia respaldo.sh '[ "${B:-banco}" != "banco" ] && [ "${RESPALDO_FALLA:-}" = "$1" ]; }' '[ "${RESPALDO_FALLA:-}" = "$1" ]; }'; detectar_seed 58_respaldo
nueva_seed M518 "backup, restore, recuperar y descartar NO toman el candado (se pisan entre procesos)";                cambia respaldo.sh '  adquirir "$B"' '  :'; detectar_seed 58_respaldo
nueva_seed M519 "el candado es GLOBAL en vez de por base (una operacion bloquea a las de otras bases)";               cambia respaldo.sh 'hashtext('"'"'respaldo:$_base'"'"')' 'hashtext('"'"'respaldo'"'"')'; detectar_seed 58_respaldo
nueva_seed M520 "sin vigilante: tras un kill -9 el candado queda retenido y la segunda operacion no puede empezar";   cambia respaldo.sh 'while kill -0 $$ 2>/dev/null && kill -0 $HOLDER 2>/dev/null; do sleep 0.2; done' 'while false; do sleep 0.2; done'; detectar_seed 58_respaldo



echo ""
echo "RESUMEN: $((TOTAL - FALLAS)) de $TOTAL mutaciones detectadas"
[ "$FALLAS" -eq 0 ]
