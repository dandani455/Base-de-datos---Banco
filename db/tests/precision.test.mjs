// precision.test.mjs · Etapa 10 · D.8 / D3: transporte de importes NUMERIC(18,2) -> jsonb -> JSON.parse (JavaScript Number) SIN perder los centavos DENTRO del rango representable.
//
// ALCANCE EXACTO DE LA GARANTIA (D-E10-9, ajustada por el responsable de BD): la conservacion EXACTA de centavos vale SOLO dentro del rango que un Number de JavaScript representa sin perdida:
// importes con 2 decimales y |valor| < 10^13 pesos (los centavos < 10^15 < 2^53). NO se garantiza para todo el dominio NUMERIC(18,2) (hasta 10^16): por encima, un Number no distingue centavos.
// Por eso la BD RECHAZA todo importe >= 1e13 (dominio `dinero` y `_validar_monto`) y esta prueba verifica LAS DOS MITADES:
//   (a) precision exacta de centavos dentro del rango (>= 100 000 importes aleatorios + extremos, y las salidas reales vista_balance / vista_dashboard), y
//   (b) rechazo de 1e13, 1e13 + 0,01, 1e15 y negativos del mismo orden, en el dominio y en `_validar_monto`.
// Uso (Docker en marcha, BD aplicada):   node db/tests/precision.test.mjs        (variable DB = banco por defecto; solo hace SELECT y una transaccion que se REVIERTE)
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..');
const DB = process.env.DB ?? 'banco';
const N_ALEATORIOS = Number(process.env.N ?? 100000);
let pasan = 0, fallan = 0;
const ok = (c, m) => { if (c) { pasan++; console.log(`PASS: ${m}`); } else { fallan++; console.log(`FAIL: ${m}`); } };

function psql(sql) {
  const r = spawnSync('docker', ['compose', '-f', join(RAIZ, 'compose.dev.yml'), 'exec', '-T', 'db', 'psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', DB],
                      { input: sql, encoding: 'utf8', maxBuffer: 1 << 28 });
  if (r.status !== 0) throw new Error(`psql fallo (${r.status}): ${r.stderr}`);
  return r.stdout;
}
// centavos recuperados tras JSON.parse: Math.round(x * 100) como BigInt (el contrato de transporte de D.8)
const recuperados = (txtJson) => BigInt(Math.round(JSON.parse(txtJson) * 100));

// ---------------------------------------------------------------------------------------------------------------------------------
// (a1) >= 100 000 importes: aleatorios uniformes, aleatorios en escala logaritmica y extremos del rango; positivos y negativos (los negativos solo existen en `total`, D6)
// ---------------------------------------------------------------------------------------------------------------------------------
const extremos = ['1', '2', '9', '10', '29', '30', '99', '100', '101', '105', '1005', '12345', '99999', '100000', '123456789', '999999999999', '1000000000000', '9999999999999', '999999999999999', '99999999999999',
                  '100000000000001', '900719925474099', '999999999999998', '999999999999999'];            // centavos: 0,01 0,29 1,00 1,05 ... 9.999.999.999.999,99 (el mayor admitido)
const sqlAleatorios = `
SELECT setseed(0.20261124);
WITH g AS (
  SELECT floor(random() * 999999999999999)::bigint + 1 AS c FROM generate_series(1, ${Math.floor(N_ALEATORIOS / 2)})
  UNION ALL SELECT floor(power(10, random() * 15))::bigint FROM generate_series(1, ${Math.ceil(N_ALEATORIOS / 2)})
  UNION ALL SELECT x::bigint FROM unnest(ARRAY[${extremos.join(',')}]::numeric[]) x
)
SELECT c::text || E'\\t' || to_jsonb(c::numeric / 100)::text || E'\\t' || to_jsonb(-(c::numeric / 100))::text FROM g WHERE c < 1000000000000000;`;
const filas = psql(sqlAleatorios).split('\n').filter((l) => l.includes('\t'));
let malos = 0, primero = '';
for (const l of filas) {
  const [c, pos, neg] = l.split('\t');
  const esp = BigInt(c);
  if (recuperados(pos) !== esp || recuperados(neg) !== -esp) { malos++; if (!primero) primero = `${c} -> ${pos} / ${neg}`; }
}
ok(filas.length >= N_ALEATORIOS, `se probaron ${filas.length} importes (>= ${N_ALEATORIOS}), positivos y negativos`);
ok(malos === 0, `100 % de los importes dentro del rango (< 1e13) conservan sus centavos exactos tras jsonb -> JSON.parse -> Math.round(x*100)${malos ? ` (primer fallo: ${primero})` : ''}`);
ok(recuperados('9999999999999.99') === 999999999999999n && recuperados('0.01') === 1n && recuperados('0.29') === 29n && recuperados('1234567.89') === 123456789n,
   'extremos del rango: 9.999.999.999.999,99, 0,01, 0,29 y 1.234.567,89 se recuperan exactos');

// ---------------------------------------------------------------------------------------------------------------------------------
// (b) FUERA del rango la BD RECHAZA: dominio `dinero` (CHECK de E1) y `_validar_monto` (Monto inválido); el limite es exactamente 1e13
// ---------------------------------------------------------------------------------------------------------------------------------
const sqlRechazos = `
DO $t$
DECLARE v text; r text := '';
BEGIN
  FOREACH v IN ARRAY ARRAY['10000000000000', '10000000000000.01', '1000000000000000', '-10000000000000', '99999999999999999'] LOOP
    BEGIN PERFORM v::numeric::public.dinero; r := r || 'dominio-ACEPTO:' || v || ';'; EXCEPTION WHEN check_violation OR numeric_value_out_of_range THEN NULL; END;
    BEGIN PERFORM public._validar_monto(v::numeric); r := r || 'validar-ACEPTO:' || v || ';'; EXCEPTION WHEN SQLSTATE 'P0001' THEN IF SQLERRM <> 'Monto inválido' THEN r := r || 'validar-MENSAJE:' || SQLERRM || ';'; END IF; END;
  END LOOP;
  FOREACH v IN ARRAY ARRAY['9999999999999.99', '0.01', '1234567.89'] LOOP
    BEGIN PERFORM v::numeric::public.dinero; PERFORM public._validar_monto(v::numeric); EXCEPTION WHEN OTHERS THEN r := r || 'RECHAZO-VALIDO:' || v || ';'; END;
  END LOOP;
  RAISE NOTICE 'RESULTADO[%]', r;
END $t$;`;
const r2 = spawnSync('docker', ['compose', '-f', join(RAIZ, 'compose.dev.yml'), 'exec', '-T', 'db', 'psql', '-X', '-U', 'postgres', '-d', DB, '-v', 'ON_ERROR_STOP=1'], { input: sqlRechazos, encoding: 'utf8' });
const m = /RESULTADO\[(.*)\]/.exec(r2.stderr + r2.stdout);
ok(m !== null && m[1] === '', `1e13, 1e13 + 0,01, 1e15, -1e13 y 99.999.999.999.999.999 se RECHAZAN en el dominio dinero y en _validar_monto (Monto inválido); 9.999.999.999.999,99, 0,01 y 1.234.567,89 se ACEPTAN${m && m[1] ? ` (anomalias: ${m[1]})` : ''}`);

// ---------------------------------------------------------------------------------------------------------------------------------
// (a2) las salidas REALES: un cliente con saldos en los dos extremos del rango, leido por vista_balance y vista_dashboard (todo dentro de una transaccion que se REVIERTE)
// ---------------------------------------------------------------------------------------------------------------------------------
const sqlReal = `
BEGIN;
DO $t$
DECLARE
  h constant text := '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';
  u uuid; c uuid; m numeric;
BEGIN
  u := (public.registrar_usuario('Pre', 'Cision', '9990001', 'pre.cision@mail.co', '3109990001', '1990-05-17', h, true, NULL, true) ->> 'usuario_id')::uuid;
  SELECT id INTO c FROM public.cuenta WHERE usuario_id = u;
  FOREACH m IN ARRAY ARRAY[0.01, 0.29, 1234567.89, 4999995000000.00, 4999995000000.10] LOOP
    PERFORM public._asentar_grupo(public.ahora_banco(), jsonb_build_array(
      jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'CUENTA', 'sentido', 'E', 'monto', m, 'cuenta_id', c),
      jsonb_build_object('tipo', 'DEPOSITO_BANCO', 'contenedor', 'RESULTADO', 'sentido', 'E', 'monto', m, 'cuenta_id', c, 'contraparte_nombre', 'Banco Digital')));
  END LOOP;
  PERFORM public.crear_bolsillo(u, 'Grande');
  PERFORM public.mover_a_bolsillo(u, (SELECT id::text FROM public.bolsillo WHERE cuenta_id = c LIMIT 1), 1234567.89);
  RAISE NOTICE 'SALIDA|%|%|%', (SELECT balance FROM public.cuenta WHERE id = c), public.vista_balance(u)::text, public.vista_dashboard(u)::text;
END $t$;
ROLLBACK;`;
const real = spawnSync('docker', ['compose', '-f', join(RAIZ, 'compose.dev.yml'), 'exec', '-T', 'db', 'psql', '-X', '-U', 'postgres', '-d', DB, '-v', 'ON_ERROR_STOP=1'], { input: sqlReal, encoding: 'utf8', maxBuffer: 1 << 26 });
const sal = /SALIDA\|([^|]*)\|(\{.*?\})\|(\{.*\})\s*$/m.exec((real.stderr + real.stdout).split('\n').find((l) => l.includes('SALIDA|')) ?? '');
if (!sal) { ok(false, `las salidas reales se leyeron (psql: ${(real.stderr + real.stdout).slice(0, 300)})`); }
else {
  const principal = BigInt(sal[1].replace('.', ''));                         // balance de la cuenta en centavos, leido como TEXTO desde la BD (la verdad)
  const bal = JSON.parse(sal[2]), dash = JSON.parse(sal[3]);
  const bolsillos = bal.bolsillos;
  ok(BigInt(Math.round(bal.principal * 100)) === principal, `vista_balance.principal (${bal.principal}) conserva sus centavos exactos`);
  ok(BigInt(Math.round(bal.total * 100)) === principal + BigInt(Math.round(bolsillos[0].saldo * 100)), `vista_balance.total (${bal.total}) = principal + bolsillos, centavos exactos (la BD lo calcula en NUMERIC)`);
  ok(BigInt(Math.round(dash.balance_total * 100)) === BigInt(Math.round(bal.total * 100)), `vista_dashboard.balance_total (${dash.balance_total}) = vista_balance.total`);
  ok(typeof bal.total === 'number' && typeof dash.balance_total === 'number' && dash.transacciones.every((t) => typeof t.monto === 'number'), 'todo importe de las salidas es un NUMBER (no string), como exige el contrato');
  ok(dash.transacciones.every((t) => BigInt(Math.round(t.monto * 100)) > 0n && Math.abs(t.monto) < 1e13), 'cada monto del historial del dashboard es positivo y menor que 1e13 (el signo lo da tipo)');
}
console.log(`RESUMEN: ${pasan} pass, ${fallan} fail`);
process.exit(fallan === 0 ? 0 : 1);
