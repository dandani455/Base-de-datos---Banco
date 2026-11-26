#!/bin/sh
# 21_conexion_lector_dev.sh - Etapa 2 - conexiones REALES de banco_lector y banco_dev: leen las vistas de
# integridad (la verificacion independiente), siguen sin escribir, sin password_hash y sin poder asumir los
# roles privilegiados.
. /work/tests/reales/lib.sh

# --- banco_lector ---------------------------------------------------------------------------------------------------------
eq "banco_lector: conexion real, solo lectura por defecto" "banco_lector|on" \
   "$(as banco_lector $LECTOR_PW "SELECT current_user || '|' || current_setting('default_transaction_read_only')")"
eq "banco_lector lee v_integridad_global (todo en orden)" "t" "$(as banco_lector $LECTOR_PW "SELECT ok FROM public.v_integridad_global")"
eq "banco_lector: v_integridad_defensas sin controles fallidos" "0" "$(as banco_lector $LECTOR_PW "SELECT count(*) FROM public.v_integridad_defensas WHERE NOT ok")"
eq "banco_lector: v_integridad_saldos / grupos / usuario sin desvios" "0|0|0" \
   "$(as banco_lector $LECTOR_PW "SELECT (SELECT count(*) FROM public.v_integridad_saldos WHERE NOT ok) || '|' || (SELECT count(*) FROM public.v_integridad_grupos WHERE NOT ok) || '|' || (SELECT count(*) FROM public.v_integridad_usuario WHERE NOT ok)")"
denegado  "banco_lector NO lee password_hash"          banco_lector $LECTOR_PW "SELECT password_hash FROM public.usuario"
denegado  "banco_lector NO actualiza balances (aun forzando lectura-escritura)" banco_lector $LECTOR_PW "BEGIN READ WRITE; UPDATE public.cuenta SET balance = balance + 1; COMMIT;"
denegado  "banco_lector NO inserta en el libro"        banco_lector $LECTOR_PW "BEGIN READ WRITE; INSERT INTO public.transaccion (grupo_id) VALUES (gen_random_uuid()); COMMIT;"
denegado  "banco_lector NO ejecuta _asentar_grupo"     banco_lector $LECTOR_PW "SELECT public._asentar_grupo(now(), '[]'::jsonb)"
denegado  "banco_lector NO asume banco_owner"          banco_lector $LECTOR_PW "SET ROLE banco_owner"
denegado  "banco_lector NO asume banco_ledger"         banco_lector $LECTOR_PW "SET ROLE banco_ledger"

# --- banco_dev (hereda lectura de banco_lector y EXECUTE de banco_app; nunca escritura) ----------------------------------------
eq "banco_dev: conexion real" "banco_dev" "$(as banco_dev $DEV_PW "SELECT current_user")"
eq "banco_dev lee v_integridad_global" "t" "$(as banco_dev $DEV_PW "SELECT ok FROM public.v_integridad_global")"
denegado  "banco_dev NO lee password_hash"             banco_dev $DEV_PW "SELECT password_hash FROM public.usuario"
denegado  "banco_dev NO actualiza balances"            banco_dev $DEV_PW "UPDATE public.cuenta SET balance = balance + 1"
denegado  "banco_dev NO borra patas"                   banco_dev $DEV_PW "DELETE FROM public.transaccion"
denegado  "banco_dev NO ejecuta _asentar_grupo"        banco_dev $DEV_PW "SELECT public._asentar_grupo(now(), '[]'::jsonb)"
denegado  "banco_dev NO asume banco_owner"             banco_dev $DEV_PW "SET ROLE banco_owner"
denegado  "banco_dev NO asume banco_ledger"            banco_dev $DEV_PW "SET ROLE banco_ledger"
denegado  "banco_dev NO desactiva triggers"            banco_dev $DEV_PW "ALTER TABLE public.transaccion DISABLE TRIGGER ALL"

# --- Nadie de uso diario es miembro de los roles privilegiados ----------------------------------------------------------------
eq "ningun rol (salvo superusuarios) es miembro de banco_owner ni de banco_ledger" "0" \
   "$(root "SELECT count(*) FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles mm ON mm.oid = m.member WHERE g.rolname IN ('banco_owner','banco_ledger') AND NOT mm.rolsuper")"
eq "banco_owner y banco_ledger: NOLOGIN y sin atributos especiales" "2" \
   "$(root "SELECT count(*) FROM pg_roles WHERE rolname IN ('banco_owner','banco_ledger') AND NOT rolcanlogin AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls")"
fin
