-- 30_reloj_funciones.test.sql · Etapa 3 · funciones del reloj: aritmética pura con instantes inyectados (medianoche de Bogotá,
-- zonas de sesión distintas), hoy_banco()/ahora_banco(), el jsonb del contrato y las reglas puras de cobro y de cuotas vencidas.
-- Una sola transacción con ROLLBACK final. Corre como superusuario en banco_test (el reloj de la base queda en modo real).
BEGIN;

-- ============================================================================
-- 1. _hoy_de: modo real = fecha de America/Bogota del instante (medianoche de Bogotá = 05:00 UTC)
-- ============================================================================
SELECT assert_eq('real: 31-dic 23:59:59 en Bogotá es 31-dic', public._hoy_de(true, NULL, '2026-12-31 23:59:59-05'), DATE '2026-12-31');
SELECT assert_eq('real: 1-ene 00:00:00 en Bogotá es 1-ene',   public._hoy_de(true, NULL, '2027-01-01 00:00:00-05'), DATE '2027-01-01');
SELECT assert_eq('real: 04:59:59 UTC (23:59:59 en Bogotá) sigue siendo 31-dic', public._hoy_de(true, NULL, '2027-01-01 04:59:59+00'), DATE '2026-12-31');
SELECT assert_eq('real: 05:00:00 UTC (00:00:00 en Bogotá) ya es 1-ene',         public._hoy_de(true, NULL, '2027-01-01 05:00:00+00'), DATE '2027-01-01');
SELECT assert_eq('real: 29-feb de un año bisiesto', public._hoy_de(true, NULL, '2028-02-29 12:00:00-05'), DATE '2028-02-29');
SELECT assert_eq('real: 1-mar tras el 29-feb',      public._hoy_de(true, NULL, '2028-03-01 00:00:01-05'), DATE '2028-03-01');
SELECT assert_eq('real: la fecha_sistema guardada se IGNORA en modo real', public._hoy_de(true, DATE '2030-01-01', '2026-11-21 10:00:00-05'), DATE '2026-11-21');

-- La zona horaria de la SESION no cambia nada: se prueba con zonas extremas
DO $$
DECLARE
  z text; v_mal int := 0;
BEGIN
  FOREACH z IN ARRAY ARRAY['UTC', 'Asia/Tokyo', 'America/Los_Angeles', 'Pacific/Kiritimati', 'Pacific/Pago_Pago', 'America/Bogota', 'Europe/Madrid'] LOOP
    PERFORM set_config('TimeZone', z, true);
    IF public._hoy_de(true, NULL, '2026-12-31 23:59:59-05') <> DATE '2026-12-31' THEN v_mal := v_mal + 1; END IF;
    IF public._hoy_de(true, NULL, '2027-01-01 00:00:00-05') <> DATE '2027-01-01' THEN v_mal := v_mal + 1; END IF;
    IF public._hoy_de(true, NULL, '2027-01-01 04:59:59+00') <> DATE '2026-12-31' THEN v_mal := v_mal + 1; END IF;
    IF public._hoy_de(true, NULL, '2027-01-01 05:00:00+00') <> DATE '2027-01-01' THEN v_mal := v_mal + 1; END IF;
    IF public._ahora_de(false, DATE '2026-12-21', '2026-11-21 14:30:15.123456-05') <> TIMESTAMPTZ '2026-12-21 14:30:15.123456-05' THEN v_mal := v_mal + 1; END IF;
  END LOOP;
  PERFORM tests.assert_eq('modo real y manual dan el MISMO resultado con la TimeZone de la sesion en UTC, Tokio, Los Angeles, Kiritimati, Pago Pago, Bogota y Madrid', v_mal, 0);
END $$;

-- ============================================================================
-- 2. _hoy_de en modo manual y _ahora_de
-- ============================================================================
SELECT assert_eq('manual: el hoy es fecha_sistema, sin importar el instante', public._hoy_de(false, DATE '2026-12-21', '2030-05-05 08:00:00-05'), DATE '2026-12-21');
SELECT assert_eq('manual: ...ni siquiera con un instante anterior',         public._hoy_de(false, DATE '2026-12-21', '2020-01-01 00:00:00-05'), DATE '2026-12-21');
SELECT assert_eq('ahora real = el propio instante (hoy + hora real de Bogotá)', public._ahora_de(true, NULL, '2026-11-21 14:30:15.123456-05'), TIMESTAMPTZ '2026-11-21 14:30:15.123456-05');
SELECT assert_eq('ahora manual = fecha manual + hora REAL de Bogotá (conserva microsegundos)', public._ahora_de(false, DATE '2026-12-21', '2026-11-21 14:30:15.123456-05'), TIMESTAMPTZ '2026-12-21 14:30:15.123456-05');
SELECT assert_eq('ahora manual: el instante en UTC no cambia la hora local (19:30 UTC = 14:30 en Bogotá)', public._ahora_de(false, DATE '2026-12-21', '2026-11-21 19:30:00+00'), TIMESTAMPTZ '2026-12-21 14:30:00-05');
SELECT assert_eq('la fecha de bogota de ahora_de coincide con hoy_de (manual)', (public._ahora_de(false, DATE '2026-12-21', '2026-11-21 23:59:59-05') AT TIME ZONE 'America/Bogota')::date, DATE '2026-12-21');
-- D-E3-1 aprobada: en modo manual ahora_banco() NO es monotonico (la hora da la vuelta a medianoche con la fecha manual fija)
SELECT assert_true('manual: ahora NO es monotonico (a las 23:59:59 real da una hora MAYOR que a las 00:00:01 del dia siguiente con la misma fecha manual)',
                   public._ahora_de(false, DATE '2026-12-21', '2026-11-21 23:59:59-05') > public._ahora_de(false, DATE '2026-12-21', '2026-11-22 00:00:01-05'));
SELECT assert_true('...y en modo real SI es monotonico', public._ahora_de(true, NULL, '2026-11-21 23:59:59-05') < public._ahora_de(true, NULL, '2026-11-22 00:00:01-05'));

-- ============================================================================
-- 3. hoy_banco() y ahora_banco() sobre la fila real del reloj
-- ============================================================================
SELECT assert_eq('estado inicial: modo real y sin fecha manual', (SELECT (usar_fecha_real, fecha_sistema IS NULL)::text FROM public.reloj), '(t,t)'::text);
SELECT assert_eq('hoy_banco() = fecha actual de America/Bogota', public.hoy_banco(), (now() AT TIME ZONE 'America/Bogota')::date);
-- _ahora_real() es el reloj de PARED (clock_timestamp), no now(): ahora_banco() cae entre el inicio de la transaccion y el instante posterior
SELECT assert_true('ahora_banco() es el instante de pared en modo real (hoy + hora real de Bogota): entre now() y clock_timestamp()', public.ahora_banco() BETWEEN now() AND clock_timestamp());
SELECT assert_true('_ahora_real() NO es now(): usa clock_timestamp() y es VOLATILE (la instantanea del reloj no puede quedar obsoleta por una espera)',
                   (SELECT pg_get_functiondef(p.oid) LIKE '%clock_timestamp()%' AND p.provolatile = 'v' FROM pg_proc p WHERE p.oid = 'public._ahora_real()'::regprocedure));
SELECT assert_eq('hoy_banco() es la fecha de Bogota de ahora_banco()', public.hoy_banco(), (public.ahora_banco() AT TIME ZONE 'America/Bogota')::date);
DO $$
DECLARE z text; v_mal int := 0;
BEGIN
  FOREACH z IN ARRAY ARRAY['UTC', 'Asia/Tokyo', 'America/Los_Angeles', 'Pacific/Kiritimati', 'Pacific/Pago_Pago'] LOOP
    PERFORM set_config('TimeZone', z, true);
    IF public.hoy_banco() <> (now() AT TIME ZONE 'America/Bogota')::date THEN v_mal := v_mal + 1; END IF;
    IF public.ahora_banco() NOT BETWEEN now() AND clock_timestamp() THEN v_mal := v_mal + 1; END IF;
  END LOOP;
  PERFORM tests.assert_eq('hoy_banco()/ahora_banco() reales no dependen de la TimeZone de la sesion (5 zonas extremas)', v_mal, 0);
END $$;
SELECT assert_eq('dos lecturas seguidas del hoy dan la misma fecha (el hoy solo cambia con la medianoche de Bogota o con el admin)', (SELECT (SELECT public.hoy_banco()) = (SELECT public.hoy_banco() FROM generate_series(1, 3) LIMIT 1)), true);

-- modo manual (solo para leer las funciones: el banco esta vacio, asi que el trigger no estorba)
UPDATE public.reloj SET usar_fecha_real = false, fecha_sistema = public.hoy_banco() + 40;
SELECT assert_eq('manual: hoy_banco() = fecha_sistema', public.hoy_banco(), (now() AT TIME ZONE 'America/Bogota')::date + 40);
SELECT assert_eq('manual: ahora_banco() = fecha manual + hora real de Bogota',
                 (public.ahora_banco() AT TIME ZONE 'America/Bogota')::time BETWEEN (now() AT TIME ZONE 'America/Bogota')::time AND (clock_timestamp() AT TIME ZONE 'America/Bogota')::time, true);
SELECT assert_eq('manual: la FECHA de Bogota de ahora_banco() es la fecha manual', (public.ahora_banco() AT TIME ZONE 'America/Bogota')::date, public.hoy_banco());
DO $$
DECLARE z text; v_mal int := 0;
BEGIN
  FOREACH z IN ARRAY ARRAY['UTC', 'Asia/Tokyo', 'Pacific/Kiritimati'] LOOP
    PERFORM set_config('TimeZone', z, true);
    IF public.hoy_banco() <> (now() AT TIME ZONE 'America/Bogota')::date + 40 THEN v_mal := v_mal + 1; END IF;
    IF (public.ahora_banco() AT TIME ZONE 'America/Bogota')::date <> public.hoy_banco() THEN v_mal := v_mal + 1; END IF;
  END LOOP;
  PERFORM tests.assert_eq('modo manual: tampoco depende de la TimeZone de la sesion', v_mal, 0);
END $$;
SELECT assert_eq('_reloj_instantanea() devuelve el (hoy, ahora) del reloj: el mismo hoy y un ahora un instante anterior al de ahora_banco() (menos de 1 s)',
                 (SELECT (i.hoy = public.hoy_banco() AND i.ahora <= public.ahora_banco() AND public.ahora_banco() - i.ahora < interval '1 second')::text FROM public._reloj_instantanea() i), 'true'::text);
UPDATE public.reloj SET usar_fecha_real = true;
SELECT assert_eq('de vuelta a real: hoy_banco() = fecha de Bogota', public.hoy_banco(), (now() AT TIME ZONE 'America/Bogota')::date);

-- ============================================================================
-- 4. Contrato GET /admin/reloj
-- ============================================================================
SELECT assert_json_shape('vista en modo real: tres campos y fecha_sistema null', public._reloj_vista(),
                         '{"usar_fecha_real":"boolean","fecha_sistema":"null","fecha_actual":"string"}'::jsonb);
SELECT assert_eq('vista real: fecha_actual = hoy_banco() en YYYY-MM-DD', public._reloj_vista() ->> 'fecha_actual', to_char(public.hoy_banco(), 'YYYY-MM-DD'));
UPDATE public.reloj SET usar_fecha_real = false, fecha_sistema = public.hoy_banco() + 7;
SELECT assert_json_shape('vista en modo manual: fecha_sistema es texto', public._reloj_vista(),
                         '{"usar_fecha_real":"boolean","fecha_sistema":"string","fecha_actual":"string"}'::jsonb);
SELECT assert_eq('vista manual: fecha_sistema = fecha_actual (el hoy ES la fecha manual)', (public._reloj_vista() ->> 'fecha_sistema') = (public._reloj_vista() ->> 'fecha_actual'), true);
SELECT assert_true('vista: ambas fechas con formato YYYY-MM-DD', (public._reloj_vista() ->> 'fecha_actual') ~ '^\d{4}-\d{2}-\d{2}$' AND (public._reloj_vista() ->> 'fecha_sistema') ~ '^\d{4}-\d{2}-\d{2}$');
UPDATE public.reloj SET usar_fecha_real = true;

-- ============================================================================
-- 5. Permisos de ejecucion
-- ============================================================================
SELECT assert_ok('banco_lector ejecuta hoy_banco() y ahora_banco()', $$SET LOCAL ROLE banco_lector; SELECT public.hoy_banco(), public.ahora_banco()$$);
SELECT assert_ok('banco_dev (hereda de banco_lector) tambien', $$SET LOCAL ROLE banco_dev; SELECT public.hoy_banco()$$);
SELECT assert_raises('banco_app NO ejecuta hoy_banco()', $$SET LOCAL ROLE banco_app; SELECT public.hoy_banco()$$, 'permission denied for function hoy_banco', '42501');
SELECT assert_raises('banco_app NO ejecuta ahora_banco()', $$SET LOCAL ROLE banco_app; SELECT public.ahora_banco()$$, 'permission denied for function ahora_banco', '42501');
SELECT assert_raises('banco_lector NO ejecuta las internas (_reloj_actualizar)', $$SET LOCAL ROLE banco_lector; SELECT public._reloj_actualizar(true, '')$$, 'permission denied for function _reloj_actualizar', '42501');
SELECT assert_raises('banco_lector NO ejecuta _hoy_de (la usan las funciones DEFINER, no las vistas)', $$SET LOCAL ROLE banco_lector; SELECT public._hoy_de(true, NULL, now())$$, 'permission denied for function _hoy_de', '42501');

-- ============================================================================
-- 6. Reglas puras para E7-E9: rangos de cobro y cuotas vencidas
-- ============================================================================
SELECT assert_eq('_dias_por_cobrar (2026-11-20, 2026-11-23]: 3 dias, desde el dia siguiente al ultimo cobro',
                 (SELECT array_agg(d ORDER BY d) FROM public._dias_por_cobrar(DATE '2026-11-20', DATE '2026-11-23') d), ARRAY[DATE '2026-11-21', DATE '2026-11-22', DATE '2026-11-23']);
SELECT assert_eq('hoy = ultimo_cobro: NADA que cobrar', (SELECT count(*) FROM public._dias_por_cobrar(DATE '2026-11-20', DATE '2026-11-20')), 0::bigint);
SELECT assert_eq('hoy < ultimo_cobro (volvio a fecha real tras una simulacion): rango vacio, NO negativo', (SELECT count(*) FROM public._dias_por_cobrar(DATE '2027-01-20', DATE '2026-11-21')), 0::bigint);
SELECT assert_eq('hoy 1 dia despues: un solo dia', (SELECT count(*) FROM public._dias_por_cobrar(DATE '2026-11-20', DATE '2026-11-21')), 1::bigint);
SELECT assert_eq('NULL en cualquier extremo: nada', (SELECT count(*) FROM public._dias_por_cobrar(NULL, DATE '2026-11-21')) + (SELECT count(*) FROM public._dias_por_cobrar(DATE '2026-11-21', NULL)), 0::bigint);
SELECT assert_eq('+30 años (salto del reloj): 10958 dias, sin repetir ninguno', (SELECT (count(*), count(DISTINCT d))::text FROM public._dias_por_cobrar(DATE '2026-11-21', DATE '2056-11-21') d), '(10958,10958)'::text);
SELECT assert_eq('el rango nunca incluye el dia del ultimo cobro ni mas alla de hoy',
                 (SELECT (min(d) = DATE '2026-11-21', max(d) = DATE '2026-12-10')::text FROM public._dias_por_cobrar(DATE '2026-11-20', DATE '2026-12-10') d), '(t,t)'::text);

SELECT assert_eq('cuota NO pagada con fecha anterior a hoy: vencida', public._cuota_vencida(DATE '2026-11-20', false, DATE '2026-11-21'), true);
SELECT assert_eq('cuota NO pagada que vence HOY: todavia no esta vencida (fecha < hoy)', public._cuota_vencida(DATE '2026-11-21', false, DATE '2026-11-21'), false);
SELECT assert_eq('cuota NO pagada con fecha futura: no vencida', public._cuota_vencida(DATE '2026-11-22', false, DATE '2026-11-21'), false);
SELECT assert_eq('cuota PAGADA con fecha anterior: nunca vencida', public._cuota_vencida(DATE '2026-11-20', true, DATE '2026-11-21'), false);
SELECT assert_eq('la misma cuota deja de estar vencida si el hoy vuelve a una fecha anterior (dinamica, sin estado guardado)',
                 (public._cuota_vencida(DATE '2026-12-01', false, DATE '2026-12-15'), public._cuota_vencida(DATE '2026-12-01', false, DATE '2026-11-21'))::text, '(t,f)'::text);
SELECT assert_eq('NULL: nunca vencida', (public._cuota_vencida(NULL, false, DATE '2026-11-21'), public._cuota_vencida(DATE '2026-11-20', NULL, DATE '2026-11-21'), public._cuota_vencida(DATE '2026-11-20', false, NULL))::text, '(f,f,f)'::text);
SELECT assert_eq('el esquema NO guarda ninguna bandera de vencimiento (ni en cuota ni en credito)',
                 (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name IN ('cuota', 'credito') AND column_name ~ 'vencid'), 0::bigint);

ROLLBACK;
