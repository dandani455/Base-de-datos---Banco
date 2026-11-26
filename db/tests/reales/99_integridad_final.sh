#!/bin/sh
# 99_integridad_final.sh - Etapa 2 - despues de TODAS las pruebas con conexiones reales y concurrencia (que dejaron
# miles de patas confirmadas en banco_test), la verificacion independiente debe seguir en orden y las defensas activas.
. /work/tests/reales/lib.sh

eq "v_integridad_global.ok tras las pruebas reales" "t" "$(root "SELECT ok FROM public.v_integridad_global")"
eq "contenedores con desvio" "0" "$(root "SELECT contenedores_con_desvio FROM public.v_integridad_global")"
eq "grupos con error" "0" "$(root "SELECT grupos_con_error FROM public.v_integridad_global")"
eq "cuentas con desvio I5u" "0" "$(root "SELECT cuentas_con_desvio_i5u FROM public.v_integridad_global")"
eq "defensas fallidas" "0" "$(root "SELECT defensas_fallidas FROM public.v_integridad_global")"
eq "conservacion de transferencias (vivas + borradas) = 0" "0.00" "$(root "SELECT desvio_transferencias FROM public.v_integridad_global")"
eq "hay mas de 4000 patas (las pruebas reales dejaron actividad)" "t" "$(root "SELECT patas > 4000 FROM public.v_integridad_global")"
echo "info: $(root "SELECT 'cuentas=' || cuentas || ' grupos=' || grupos || ' patas=' || patas FROM public.v_integridad_global")"
fin
