# Etapa 8 — Créditos (catálogo, simulación, solicitud y plan de cuotas) · paquete de entrega

**Estado (2026-11-24): COMPLETADA y APROBADA oficialmente por el responsable de BD (auditoría del ZIP de E8, sin cambios de código).** Diseño v1.1 aprobado el mismo día (`08-creditos-diseno.md`, D-E8-1 a D-E8-11). Sin commits; `front/` y backend intactos; **E9 implementada (`09-pagos.md`, pendiente de auditoría)**; este paquete describe E8 tal como se entregó (sin pagos, abonos, mora ni descuento automático). Se modificaron etapas aprobadas **solo** en los puntos de integración que el diseño contempla (`09_integridad.sql`: lista blanca y vistas de integridad) y se adaptaron las pruebas anteriores **solo** donde cambia su comportamiento (§3).

## 1. Qué se entrega

| Pieza | Archivo |
|---|---|
| Cálculo e integridad: `_reglas_credito`, `_tasa_mensual` (**D1**), `_fecha_vencimiento`, `_plan_cuotas`, `_patrimonio_neto` (**D6**), `_interes_corriendo`, `ct_credito_plan` (+ 2 constraint triggers diferidos `ct_credito_plan` en `credito` y `ct_credito_plan_cuota` en `cuota`) | `db/sql/19_creditos_calculo.sql` (idempotente, comentado) |
| Públicas: `productos_disponibles`, `productos_publicos`, `simular_credito`, `solicitar_credito`, `vista_creditos` + internas `_producto_credito`, `_validar_plazo`, `_limites_credito`, `_verificar_credito` | `db/sql/20_creditos.sql` |
| Integración (solo los puntos contemplados) | `db/sql/09_integridad.sql`: lista blanca de `banco_app` 16 → **21**; los 2 triggers nuevos entre los esperados; vista nueva `v_integridad_creditos` (+ columna `creditos_con_plan_incoherente` y la regla de planes dentro de `v_integridad_global.ok`) |
| Pruebas nuevas | `57_creditos_calculo.test.sql` (34), `58_creditos.test.sql` (72), `59_creditos_aleatorio.test.sql` (8), `reales/47_creditos_conexiones.sh` (85), `reales/48_creditos_concurrencia.sh` (24) = **223** |
| Pruebas adaptadas (solo lo que cambia por E8, §3) | `03_schema`, `09_idempotencia`, `10_libro_triggers`, `12`–`16`, `34`, `52`, `54`, `55`, `reales/45`, `harness.sql` |
| Mutaciones | `db/tests/mutaciones/mutaciones.sh`: **M176–M217** (42 nuevas) |
| Resumen para el backend | `docs/db/etapas/08-resumen-para-juan.md` |
| Evidencias | `docs/db/evidencias/08-creditos*.txt`, `08-pgadmin-demo.sql` y su salida, `git_status_e8.txt` |

## 2. Cómo funciona

```
solicitar_credito(usuario, producto_id text, monto numeric, plazo numeric)
 1 sesión (_validar_cliente) → monto (_validar_monto) → plazo (_validar_plazo) → producto (_producto_credito)      [sin bloqueos]
 2 UNA _reloj_instantanea() → (hoy, ahora)
 3 _avanzar_hasta(cuenta, hoy, ahora)      ← devenga bolsillos y CDT ANTES de calcular el tope
 4 _bloquear_cuentas([cuenta])             ← el MISMO FOR NO KEY UPDATE del libro: todo lo que decide el desembolso se lee bajo él
 5 ¿crédito ACTIVO de ese producto? → 'Ya tienes un crédito vigente de este producto'
 6 _verificar_credito: 'Monto fuera de rango' → 'Plazo fuera de rango' → 'Plazo excede el límite de edad'
 7 INSERT credito (capital_pendiente 0, tasa y plazo COPIADOS) → INSERT de las n cuotas (UNA sentencia desde _plan_cuotas)
   → afirma que insertó exactamente n → _asentar_grupo(CREDITO_DESEMBOLSO: CUENTA E + CREDITO E) → SET CONSTRAINTS ct_credito_plan IMMEDIATE
```

* **Cálculo (D1 PROVISIONAL, `_tasa_mensual`):** la tasa del producto es efectiva anual, `i = (1+t/100)^(1/12) − 1`; cuota fija `C = round(P·i·q/(q−1), 2)` con `q = (1+i)^n`, todo en `numeric` (nunca `float`); por período `interés = round(saldo·i, 2)`, `capital = C − interés`; **la última cuota toma el capital restante exacto**. `simular_credito` y `solicitar_credito` usan el mismo `_plan_cuotas` (lo simulado es lo que se cobra: se prueba fila a fila). 360 cuotas ≈ 0,03 ms por plan; crédito de Inmuebles de 360 cuotas completo (inserción, asiento y verificación) en menos de 5 s.
* **Vencimientos (D-E8-3 PROVISIONAL):** desembolso + k meses calendario, anclado a la fecha original (31-ene → 28-feb, 31-mar…).
* **Topes efectivos (`_limites_credito`):** `monto_max = max(0, min(monto_max, tope_absoluto, trunc(multiplicador × patrimonio_neto, 2)))`; `patrimonio_neto = balance_total − Σ capital_pendiente` (D-E8-5, spec §7.6; `balance_total` **no cambia**, D6). Plazo: `min(plazo_max_meses, 360 técnico)` y, en Inmuebles, `min(·, (70 − edad) × 12)` con la edad en **años cumplidos** a la fecha de la instantánea. Un producto **siempre se lista**, aunque sus topes efectivos queden en 0.
* **Interés corriendo (D-E8-4 PROVISIONAL):** prorrata lineal por días del interés de la **próxima cuota impaga**, derivado (no escribe): `round(interes_programado × clamp((hoy − fecha_interes)/(vencimiento − fecha_interes), 0, 1), 2)`.
* **Capital pendiente, plan y libro (la sincronía pedida):** `credito.capital_pendiente` solo lo mueve el libro (guardia de E2); el plan lo escribe `solicitar_credito`; y **`ct_credito_plan`** (diferido, una sola regla, v1.1) exige `capital_pendiente = Σ (capital_programado − capital_pagado)` de las cuotas impagas, verificada **dentro** de `solicitar_credito` (no en el COMMIT del backend) y otra vez al confirmar. Un plan incompleto (n−1 cuotas), uno que no cuadra con la deuda o un desembolso fallido dejan **todo** como estaba (§3, C/atomicidad).
* **Motor sin cambios (D-E8-10):** `_avanzar_hasta` y el hueco de auto-descuento/mora quedan intactos para E9. El escaneo de catálogo de E7 (`54`) se amplió: devengan **12** funciones (las 8 de E7 + `productos_disponibles`, `simular_credito`, `solicitar_credito`, `vista_creditos`) y **9** están exentas (+ `productos_publicos`); cada implementadora llama `_avanzar_hasta(` y `_reloj_instantanea()` **una sola vez**, la instantánea primero; `solicitar_credito` bloquea la cuenta **una vez y después del devengo**; ninguna lee el reloj por su cuenta.

## 3. Resultados

| Verificación | Resultado |
|---|---|
| Suite completa (`ctl.sh test`) | **2436 aprobadas, 0 fallidas** (E7 cerró en 2213: +223 nuevas, 0 menos; las adaptadas siguen verdes) |
| Pruebas nuevas | 57 = 34 · 58 = 72 · 59 = 8 · reales/47 = 85 · reales/48 = 24 |
| `reset` + 3 × `apply` desde cero | **sin errores** (`08-creditos-aplicacion.txt`): 11 tablas, **90 funciones**, **20 triggers**, **8 vistas**; `banco_app` ejecuta exactamente **21**; las 11 internas de créditos sin EXECUTE; `ct_credito_plan` y `ct_credito_plan_cuota` habilitados y diferidos; `v_integridad_global` en orden; `banco` queda **limpia** (reloj real, 0 usuarios, 0 productos, 0 créditos) |
| Mutaciones nuevas M176–M217 | **42 de 42 detectadas** (`08-creditos-mutaciones.txt`) |
| Regresión de mutaciones de E7 que miran permisos/catálogo/devengo (M137–M142, M171–M174) | **10 de 10 detectadas** (`08-creditos-mutaciones-regresion.txt`) |

Qué cubre cada archivo nuevo:
* **57** — aritmética del plan: cifras conocidas (10M/12/18 % = 910.463,77; 2.000M/14 %/360 con −17,96 en la última), 206 planes (200 aleatorios + extremos) contra una **referencia independiente** `exp/ln` en `float8`, invariantes (Σ capital = monto, saldo final 0 y decreciente, cuota = capital + interés, deriva de la última cuota acotada por el redondeo), calendario (fin de mes, bisiesto), `_validar_plazo` (9 valores inválidos), y **`ct_credito_plan` sobre pagos y abonos simulados** (pago completo cuadra; abono **sin** recalcular **falla**, **con** recalcular cuadra; liquidación con cuotas restantes marcadas o eliminadas cuadra; `capital_pagado` se descuenta; cuota borrada falla; no se exige un número de cuotas).
* **58** — topes (tope fijo que muerde, 100 × patrimonio con bolsillo y CDT, autoneutralización del crédito, piso 0 con patrimonio negativo, regla de edad 43/69/70/80 y cumpleaños), mensajes y **orden** de validación, un crédito vivo por producto (el PAGADO no bloquea), asiento y plan persistido, **simulación = lo cobrado**, **atomicidad con falla inyectada** en las 2 patas, el INSERT del crédito y la última cuota, plan incompleto y plan corrupto detectados **dentro** de la función, devengo previo con el reloj adelantado, interés corriendo (día 0, mitad, vencimiento, vencida, de vuelta al reloj real = 0), permisos, catálogo y **una sola instantánea** (conteo dinámico de lecturas del reloj).
* **59** — 160 operaciones aleatorias (solicitar/simular/CDT/bolsillos/envíos/lecturas/saltos de reloj): todas terminan en OK o en un mensaje de negocio permitido; cada crédito con su plan completo; Σ desembolsos = Σ montos = Σ deuda; a lo sumo un crédito activo por producto; ningún crédito supera su tope; el diferido sobre todo lo creado y `v_integridad_global.ok`.
* **reales/47** (roles reales por TCP, sin superusuario) — conversación del backend (salida jsonb, monto como texto, errores P0001 exactos), permisos efectivos (5 públicas sí; ninguna interna; lector/dev; ninguna escritura directa de `credito` ni `cuota`), atomicidad sobre el estado confirmado (falla en cada pata y **corte de conexión**), carreras por borrado (`Sesión inválida`, nunca un 503).
* **reales/48** — 6 solicitudes simultáneas del mismo producto (exactamente 1, sin `23505` filtrado), 12 sesiones mezcladas, Inmuebles al tope contra un envío simultáneo (8 rondas, siempre un orden serializable), solicitudes + 24 transferencias cruzadas sin deadlock, 12 lecturas simultáneas con un solo devengo, y el bloqueo de cuenta compartido (`solicitar_credito` espera; `productos_publicos` no).

**Pruebas anteriores adaptadas (solo donde cambia el comportamiento):**
* `03_schema`, `10_libro_triggers`: inventarios (74 → **90** funciones, 18 → **20** triggers, 7 → **8** vistas, 5 `ct_*`, lista blanca 16 → 21, SECURITY DEFINER).
* `09_idempotencia`: reaplica 19 y 20. `52`, `55`, `reales/45`: lista blanca 16 → 21. `54`: el catálogo ahora lista las 5 funciones nuevas (devenga 8 → 12, exentas 8 → 9).
* **`12`, `13`, `14`: `SET CONSTRAINTS ALL IMMEDIATE` → solo los 3 diferidos del libro** (`ct_transaccion_cuadre`, `ct_transaccion_cdt`, `ct_cdt_inversion`, los mismos que fuerza `_asentar_grupo`): esas pruebas fabrican créditos **sintéticos sin plan** para probar el libro, y `ALL` arrastraba el diferido nuevo.
* **`harness.sql`: `tests.ok_sin_plan()`** (el estado global sin la regla de planes). Lo usan `12`–`16` y `34` donde afirman `v_integridad_global.ok` con esos créditos sintéticos; la regla de planes se prueba en 57/58/59. `15` y `16` ajustan además su fixture (una cuota con el capital que quedó en el libro y el diferido evaluado antes del `TRUNCATE`/`ALTER TABLE`, porque PostgreSQL no permite ninguno con eventos diferidos pendientes).

## 4. Decisiones aprobadas y cómo se reflejan

| ID | Cómo quedó |
|---|---|
| D-E8-1 | Alcance exacto: 5 públicas + plan persistido. Nada de pagos, abonos, mora ni auto-descuento; las plantillas `CREDITO_CUOTA/ABONO/MORA` del libro siguen sin definirse. |
| D-E8-2 (D1 provisional) | Todo en `_tasa_mensual`; la prueba 57 contrasta con la cuota nominal (916.799,93). |
| D-E8-3 | `_plan_cuotas`, `_fecha_vencimiento`, `_reglas_credito` (plazo técnico 360). |
| D-E8-4 (provisional) | `_interes_corriendo`, derivado y sin escribir. |
| D-E8-5 (D6 provisional) | `_patrimonio_neto` separada; `balance_total` intacta (la prueba 58 lo afirma). |
| D-E8-6 (D11 provisional) | Sin catálogo; los tests crean sus productos; los productos se listan siempre. |
| D-E8-7 | Edad en años cumplidos; los 4 mensajes de crédito del contrato §6, ninguno inventado. |
| D-E8-8 (D10 provisional) | `p_usuario_id` en `simular_credito`; plazo `numeric`; `{id, fecha}`; `vista_creditos` solo ACTIVOS con los 6 campos. |
| D-E8-9 (v1.1) | `ct_credito_plan` con **una sola regla**; no se recuperó ninguna de las descartadas. |
| D-E8-10 | Motor intacto; 4 devengan; bloqueo explícito de la cuenta en `solicitar_credito`. |
| D-E8-11 | Deriva de la última cuota aceptada y acotada por prueba (cifras de 4 casos del diseño verificadas por aserción; los otros 2 por consulta). |

## 5. Desviaciones y límites (sin ocultar nada)

1. **90 funciones, no ≈ 87.** Dividí tres piezas más de las que listaba el diseño: `_fecha_vencimiento`, `_validar_plazo` y `_verificar_credito` (la comparten simular y solicitar). Las 5 públicas, los 20 triggers y la lista blanca de 21 son los previstos.
2. **`DROP TRIGGER IF EXISTS` + `CREATE CONSTRAINT TRIGGER`**, no `CREATE OR REPLACE`: PostgreSQL 16 no admite `OR REPLACE` en constraint triggers. (En `credito` el `DROP` lo registra el event trigger de E2 en `audit.evento` en cada reaplicación, igual que ya ocurre con los de `cdt`/`transaccion`.)
3. **`v_integridad_global.ok` ahora incluye los planes** (columna nueva `creditos_con_plan_incoherente` al final; vista nueva `v_integridad_creditos`). Por eso hubo que adaptar las pruebas de E2/E3 con créditos sintéticos (§3). Una base real nunca tiene un crédito sin plan: lo crea `solicitar_credito`.
4. **Aserciones: +223, no ≈ 280** como estimaba el diseño: 57/58/59 y los reales cubren los mismos riesgos con menos aserciones (se priorizó no duplicar). 42 mutaciones, no ≈ 30.
5. **Las lecturas escriben** (`productos_disponibles`, `simular_credito`, `vista_creditos`): la primera tras un salto de reloj devenga bolsillos/CDT (igual que E7). `productos_publicos` no.
6. **Límite aceptado (D-E8-11):** la última cuota difiere de la fija por el redondeo a centavos: +0,02 (30M/23,9 %/24), +0,36 (50M/18,9 %/120), −0,11 (300M/14,1 %/240), +8,47 (0,5M/12 %/360), −17,96 (2.000M/14 %/360), +522,71 (2.000M/30 %/360).
7. **`interes_mes` tras pagos/abonos (E9):** está definido contra `fecha_interes` y `interes_programado`; si E9 mueve `fecha_interes` a la fecha de un abono, `interes_programado` debe ser el del tramo restante (D7). No se fija ahora. Las pruebas de `cuotas_pagadas > 0` usan **datos preparados por el propio test** (asiento + cuota marcada), no una función pública de pago.
8. **El `total` de `vista_balance` sube con el desembolso** (la deuda no se resta; D6, equipo). `total` = cuenta + bolsillos + CDT activos, igual que en E7.
9. **Un superusuario puede desactivar `ct_credito_plan`** (límite de todo trigger, documentado desde E2): lo detectan `v_integridad_defensas` y `v_integridad_creditos`.
10. **No hay pruebas de «Abonar a capital»** (E9) y el front no tendrá función de BD detrás hasta entonces (avisado en el resumen para Juan).

## 6. Mutaciones

Bloque **M176–M217** (42): tasa nominal, cuota sin redondear, interés sin redondear, última cuota sin absorber, vencimientos a 30 días y numeración desde 0, patrimonio sin restar la deuda, tope fijo ignorado, sin piso 0, plazo técnico ignorado, multiplicador sobre `balance_total`, edad por años calendario y con 12 meses de regalo, `productos_publicos` sin tope fijo, plazo fraccionario aceptado, interés corriendo sin tope/sin piso/con la cuota 1 siempre, `ct_credito_plan` sin comparación / sin `capital_pagado` / sin el filtro de impagas / sin el disparo desde `credito` / sin el de `cuota`, `solicitar_credito` sin la verificación inmediata / sin la afirmación de n cuotas / sin devengo / sin bloqueo explícito / sin validar el vigente / con el vigente contando los PAGADOS / con capital inicial = monto / con otra tasa / con doble instantánea / con `now()`, devengo ausente en `productos_disponibles`, `simular_credito` y `vista_creditos`, simulación con otra tasa, `vista_creditos` con PAGADOS y los 4 cambios de permisos.

**Resultado: 42 de 42 detectadas** (corrida con `DESDE=176`; salida completa en `08-creditos-mutaciones.txt`: cada mutación con la prueba que la detectó). Las pruebas de E8 corren primero; ninguna fue necesaria más allá de 57/58 salvo lo indicado.

**Un hueco de pruebas hallado por las mutaciones (corregido, igual que en E7):** M205 («`solicitar_credito` no toma el bloqueo explícito de la cuenta») la detectaba **solo la prueba estructural** de 58 (cuenta el texto `_bloquear_cuentas(`). Al ejecutarla aislada contra `reales/48` (regresión: `08-creditos-mutaciones-regresion.txt`) salió **NO DETECTADA**: el comportamiento observable era equivalente porque `_asentar_grupo` toma el mismo bloqueo al escribir, y la carrera tope-contra-envío es serializable con o sin él. El bloqueo explícito sí cambia **dónde espera** la operación: las validaciones (vigente, topes) se leen bajo el bloqueo. Se añadió a `reales/48` la prueba 6b (con la cuenta bloqueada por otra sesión, **un rechazo de rango también espera**; sin el bloqueo explícito respondería de inmediato) y M205 pasó a **DETECTADA** también por el comportamiento. El bloqueo es defensa en profundidad, no una condición de corrección: sin él los resultados observables de `solicitar_credito` serían los mismos.

**Regresión de E7** (M137–M142: devengo en las funciones integradas; M171–M174: permisos y SECURITY DEFINER de CDT): **10 de 10 detectadas** con las pruebas adaptadas.

## 7. Verifícalo en pgAdmin

1. Conexión **«Banco — administración (postgres)»** → base `banco` → Query Tool → *Open File* → [08-pgadmin-demo.sql](../evidencias/08-pgadmin-demo.sql) → **F5** (todo va en `BEGIN … ROLLBACK`; los resultados salen como `NOTICE` en la pestaña *Messages*). Salida de referencia: [08-pgadmin-demo-salida.txt](../evidencias/08-pgadmin-demo-salida.txt).
2. Consultas sueltas (superusuario; no escriben):
   * `SELECT * FROM public._plan_cuotas(10000000, 18, 12);` — el plan (cuota 910.463,77; la última 910.463,73).
   * `SELECT public.productos_publicos();` — `[]` hasta que el equipo cargue el catálogo (D11).
   * `SELECT control, ok FROM public.v_integridad_defensas WHERE control LIKE '%credito%' OR control LIKE 'banco_app ejecuta%';`
   * `SELECT * FROM public.v_integridad_creditos;` y `SELECT ok, creditos_con_plan_incoherente FROM public.v_integridad_global;`
