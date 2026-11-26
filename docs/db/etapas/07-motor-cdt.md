# Etapa 7 — Motor de devengo (`_avanzar_hasta`) y CDT · paquete de entrega

**Estado (2026-11-24): COMPLETADA y APROBADA oficialmente por el responsable de BD (auditoría del ZIP de E7, sin cambios de código).** Diseño aprobado el mismo día (`07-motor-cdt-diseno.md`, D-E7-1 a D-E7-9 con 4 precisiones, ver §4). Sin commits; `front/` y backend intactos; **E8: diseño en `08-creditos-diseno.md`, sin implementar**. Se modificaron E5 y E6 **solo** en los puntos de integración marcados (D-E7-4) y las pruebas anteriores **solo** donde el comportamiento cambia por el devengo (§3).

## 1. Qué se entrega

| Pieza | Archivo |
|---|---|
| Motor y ayudantes: `_factor_interes`, `_avanzar_hasta`, `_devengar_bolsillos`, `_devengar_cdts`, `_bloquear_cuentas`, `trg_ultimo_cobro_monotono` (+ 2 triggers `BEFORE UPDATE OF ultimo_cobro` en `bolsillo` y `cdt`) | `db/sql/17_motor_devengo.sql` (idempotente, comentado) |
| CDT: 4 públicas (`listar_cdt_definiciones`, `simular_cdt`, `crear_cdt`, `vista_cdts`) + 3 internas (`_reglas_cdt`, `_definicion_cdt`, `_texto_tiempo_restante`) | `db/sql/18_cdt.sql` |
| Integración en el código aprobado (solo los puntos marcados) | `15_transferencias.sql` (`hacer_transferencia`), `16_bolsillos.sql` (`_mover_bolsillo`, `crear_bolsillo`, `vista_balance`, `balance_total`) |
| Lista blanca de `banco_app`: 12 → **16** funciones | `db/sql/09_integridad.sql` (`v_integridad_defensas`) |
| Pruebas nuevas | `54_devengo.test.sql` (66), `55_cdt.test.sql` (63), `56_motor_aleatorio.test.sql` (19), `reales/45_motor_conexiones.sh` (110), `reales/46_motor_concurrencia.sh` (24) = **282** (+1 aserción añadida en `52`) |
| Pruebas adaptadas (solo lo que cambia por E7, §3) | `03_schema`, `09_idempotencia`, `10_libro_triggers`, `11_libro_guardias`, `50`/`52`, `harness.sql` |
| Mutaciones | `db/tests/mutaciones/mutaciones.sh`: **M137–M175** (39 nuevas) y M97/M121 adaptadas |
| Resumen para el backend | `docs/db/etapas/07-resumen-para-juan.md` |
| Evidencias | `docs/db/evidencias/07-motor-cdt*.txt`, `07-pgadmin-demo.sql` y su salida, `git_status_e7.txt` |

## 2. Cómo funciona

```
operación de cliente (las 8 que leen o mueven saldos)
 1 _validar_cliente · validaciones propias (sin bloqueos; mensajes y orden de E4–E6 sin cambios)
 2 UNA _reloj_instantanea() → (hoy, ahora)                           ← FOR SHARE del reloj
 3 _bloquear_cuentas([origen, destino])   [solo hacer_transferencia: ambas cuentas, ORDEN DE id]
 4 _avanzar_hasta(cuenta, hoy, ahora)     ← no lee el reloj; usa el (hoy, ahora) recibido
      a) salida rápida SIN bloqueo si nada está vencido
      b) bloqueo de la cuenta (FOR NO KEY UPDATE: el MISMO del libro y del borrado en cascada)
      c) relee lo vencido BAJO el bloqueo (sentencia nueva) y devenga
 5 la operación (mismo (hoy, ahora), mismo bloqueo ya tomado) → _asentar_grupo
```

* **Bolsillos:** por cada bolsillo con `ultimo_cobro < hoy`: `interés = round(saldo × factor(tasa_bolsillo, hoy − ultimo_cobro), 2)` en **forma cerrada** (coste O(bolsillos), nunca O(días): un salto de 30 años escribe UN grupo); un grupo `INTERES_BOLSO` (BOLSILLO E + RESULTADO E, contraparte «Banco Digital», nota «N días») si es > 0; **siempre** avanza `ultimo_cobro` (incluso con saldo 0, o un depósito posterior cobraría días retroactivos).
* **CDT:** **objetivo acumulado** `round(monto × factor(tasa copiada, min(hoy, fecha_fin) − fecha_inicio), 2)`; el asiento (`INTERES_CDT`) es la **diferencia** con `generado_acumulado` ⇒ repetir la llamada produce 0 asientos y no hay deriva de redondeo entre puntos de control (el CDT consultado 4 veces y el consultado una vez tienen **exactamente** el mismo generado). Si `fecha_fin ≤ hoy`: `estado = CERRADO` y un grupo `CDT_VENCIMIENTO` (CDT S + CUENTA E por `monto + generado`) **en la misma transacción**, fechado en `fecha_fin` 00:00 de Bogotá (D-E7-6); el interés nunca pasa de `fecha_fin` aunque el reloj salte años.
* **`_factor_interes(tasa, días)`** — la **única** fórmula (la usan el motor y `simular_cdt`, por eso lo simulado es lo que de verdad se genera): **E.A. estricta `(1+t)^(días/365) − 1`, PROVISIONAL (D1, decide el equipo)**. $1.000.000 al 12 % por 30 días = **$9.358,20**; $10.000.000 al 10 % por 360 días = **$985.647,56**. Si el equipo elige otra convención solo cambia ese cuerpo.
* **Integración (D-E7-4):** `hacer_transferencia` (instantánea → `_bloquear_cuentas` de ambas cuentas → devengo del emisor → libro), `_mover_bolsillo` (cubre las 3 de movimiento), `crear_bolsillo`, `vista_balance` (instantánea + devengo y **una sola sentencia de lectura**), `crear_cdt` y `vista_cdts`. Cobertura **por catálogo, no por memoria**: la prueba exige que cada función de `banco_app` esté en la lista «devenga» (8) o «exenta» (8, cada una con su razón); una función nueva de E8–E10 que no esté en ninguna **hace fallar la prueba**.
* **Bloqueos (anti-deadlock):** orden global **reloj (SHARE) → cuentas en orden de `id` → contenedores**. Devengar primero solo la cuenta del emisor rompería el orden del libro (A→B ∥ B→A); por eso `hacer_transferencia` bloquea **ambas** cuentas en orden de `id` antes de devengar. Probado: 24 transferencias cruzadas con devengo pendiente en ambos emisores, sin deadlock; y un test determinista de que el devengo, mientras espera el bloqueo de la cuenta, **no retiene ningún bolsillo**.
* **Sin doble devengo ni período repetido (5 defensas):** (i) `ultimo_cobro` se avanza en la misma transacción y bajo el bloqueo; (ii) `hoy ≤ ultimo_cobro` no hace nada (volver al reloj real no recobra); (iii) CDT por objetivo acumulado; (iv) **guardia monotónica** `trg_ultimo_cobro_monotono` (D-E7-8: `ultimo_cobro` no puede disminuir; igual se acepta); (v) el diferido `ct_cdt_inversion` (E2) valida Σ `INTERES_CDT` = `generado_acumulado` y la inversión al cerrar.
* **`balance_total` (D-E7-5, PROVISIONAL / D6 del equipo):** `cuenta + bolsillos + Σ(monto + generado_acumulado)` de los CDT **ACTIVOS**; crear un CDT ya no baja el total mostrado. La deuda de crédito **no** se resta (E8). Solo cambia esa función cuando el equipo decida D6.
* **CDT públicas:** `crear_cdt(usuario, definicion_id texto, monto)` → `{id (del CDT), fecha}`: copia nombre, monto, tasa y plazo (editar o borrar la definición no afecta a los CDT creados), `CDT_CREACION` y el INSERT en la misma transacción; `simular_cdt` → `{generado_mes (30 días o el plazo si es menor), generado_dia, generado_vencimiento}` sin escribir ni leer el reloj; `vista_cdts` → `[{id, monto, generado_hasta_hoy, tiempo_restante «N días»/«1 día»/«Cerrado», fecha_cierre}]` (vigentes primero); `listar_cdt_definiciones` → `[{id, nombre, tasa, plazo_dias, monto_min}]`. Mensajes: **ninguno inventado** (`Monto por debajo del mínimo del CDT` es del contrato §6).
* **Permisos:** `banco_app` (y `banco_dev` por herencia) ejecuta **exactamente 16** funciones; `banco_lector` y `PUBLIC` ninguna; las 9 internas, nadie salvo el dueño.

## 3. Resultados

| Verificación | Resultado |
|---|---|
| Suite completa (`db\ctl.cmd test`) | **2213 aprobadas, 0 fallidas** (baseline E6: 1930; E7 aporta 282 nuevas + 1 añadida en `52`) — `evidencias/07-motor-cdt.txt` |
| Ejecución desde cero | `reset` + 3 × `apply` (19 scripts cada vez): **0 errores**; 11 tablas + `audit.evento`; **74 funciones** (61 + 13: 4 públicas + 9 internas); 18 triggers; 7 vistas; `banco_app` ejecuta exactamente **16**; `v_integridad_global` ok — `evidencias/07-motor-cdt-aplicacion.txt` |
| Mutaciones nuevas (M137–M175) | **39 de 39** detectadas (38 en la primera pasada; **M160 no se detectó** —ninguna prueba mezclaba un bolsillo atrasado con otros adelantados— y se reforzó `54_devengo`; re-ejecutada, detectada) — `evidencias/07-motor-cdt-mutaciones.txt` |
| Regresión de mutaciones de E5/E6 que tocan el código integrado | **45 de 45** detectadas (M92–M136: todas las de E5 y E6, con el código ya integrado) — `evidencias/07-motor-cdt-mutaciones-regresion.txt` |
| Regresión E1–E6 | verde (mensajes, atomicidad, concurrencia y permisos de E4–E6 corren **sin tocar**, salvo lo adaptado abajo) |
| Demostración en pgAdmin | `evidencias/07-pgadmin-demo.sql` y `07-pgadmin-demo-salida.txt` |

**Pruebas anteriores adaptadas (y por qué; nada se relajó):**
* `03_schema` (61 → **74** funciones, 16 → **18** triggers), `10_libro_triggers` (60 → **73** de `banco_owner`, lista de funciones `SECURITY DEFINER` y lista blanca de **16**), `52` (lista blanca de 16): inventarios.
* `09_idempotencia`: reaplica también 17 y 18 (dos veces; huella del catálogo idéntica).
* `52_bolsillos`: «`vista_balance` no lee el reloj (0 lecturas)» → **1** (ahora toma la instantánea); «`vista_balance` de solo lectura sin reloj» → «no escribe por sí misma, usa solo la instantánea y llama al motor»; el marcador `-- (E7: …)` → `_avanzar_hasta` presente exactamente en `vista_balance`, `_mover_bolsillo` y `crear_bolsillo`.
* **`harness.sql`: `tests.bolsillo()` nace con `ultimo_cobro = hoy_banco()`** (antes la fecha fija 2026-11-21). Con E7 un bolsillo «creado» en el pasado tiene intereses pendientes y cambia los saldos de las pruebas de E5/E6 (p. ej. 300,01 sobre un bolsillo de 300 dejaba de dar *Saldo insuficiente* porque ya traía 0,28 de interés). Es el estado correcto de un bolsillo recién creado.
* `11_libro_guardias`: `UPDATE bolsillo SET ultimo_cobro = <fecha anterior>` (permiso del dueño) → `ultimo_cobro + 1`: la guardia monotónica de E7 no deja retroceder.
* `mutaciones.sh`: M97 y M121 (patrón de la instantánea, que ahora devuelve también `hoy`).

## 4. Decisiones aprobadas y cómo se reflejan

| ID | Decisión | Dónde |
|---|---|---|
| D-E7-1 | Proceder con D1 y D11 sin resolver, con valores **provisionales centralizados** | `_factor_interes` (17), `_reglas_cdt` (18); sin catálogo de CDT (las pruebas crean sus definiciones) |
| D-E7-2 / D-E7-3 | Bolsillo en forma cerrada (un grupo por bolsillo y llamada); CDT por objetivo acumulado con tope en `fecha_fin` y cierre en la misma transacción | 17 |
| D-E7-4 | Editar E5/E6 solo en los puntos marcados + protocolo de bloqueo | 15, 16 |
| D-E7-5 | `balance_total` incluye los CDT activos (`monto + generado`), sin créditos todavía | 16 |
| D-E7-6 | Cierre del CDT (y su último interés) fechado en `fecha_fin` 00:00 de Bogotá | 17 |
| D-E7-7 | **Visible a Juan, provisional:** `p_usuario_id` en listar/simular, `generado_mes` = 30 días, `vista_cdts` incluye cerrados con «Cerrado», `crear_cdt` devuelve `{id, fecha}` | 18, `07-resumen-para-juan.md` |
| D-E7-8 | Guardia monotónica de `ultimo_cobro` | 17 (triggers en `bolsillo` y `cdt`) |
| D-E7-9 | Límite de redondeo aceptado, sin columna de arrastre | §5.1 |

## 5. Desviaciones y límites (sin ocultar nada)

1. **D-E7-9 — la frecuencia de consulta puede producir diferencias en intereses pequeños.** El interés se redondea a centavos **por asiento**. Ejemplo ejecutado en `54`: un bolsillo de **$10,00** consultado **a diario** durante 30 días **no gana nada** (0,003/día se redondea a 0,00) y consultado **una sola vez a los 30 días gana $0,09**. Con saldos grandes la diferencia entre 30 consultas diarias y una de 30 días es solo redondeo (≤ $0,50 sobre $1.000.000, probado). Corregirlo exigiría una columna de arrastre en el esquema y en el libro; no se justifica a esta escala. El CDT **no** tiene este límite (objetivo acumulado).
2. **74 funciones, no ≈69:** el diseño estimaba 7 internas nuevas; son **9** (se separaron `_reglas_cdt`, centraliza lo provisional como en E5/E6, y `_definicion_cdt`).
3. **`_definicion_cdt`, no `_cdt_definicion`:** el segundo nombre coincide con el tipo array de la tabla `cdt_definicion` y PostgreSQL lo interpreta como un *cast* de estilo función al llamarlo con un literal (lo detectó la prueba de permisos). Cambio de nombre, sin impacto en el contrato.
4. **D1/D11 siguen siendo del equipo:** la fórmula (E.A. estricta, con tasa de bolsillo 12 % de `parametro`) y el catálogo vacío son **valores provisionales**; las cifras de esta etapa no deben presentarse como definitivas. Si el equipo elige interés nominal, solo cambia `_factor_interes` (probado por mutación M163).
5. **El mes de la simulación es de 30 días (D-E7-7, provisional)** y se topa en el plazo del CDT.
6. **`vista_balance` y `vista_cdts` ahora escriben** (el primer GET del día tras un salto de reloj). Los GET paralelos del mismo cliente se serializan en el bloqueo de la cuenta; la salida rápida evita el bloqueo si no hay nada vencido. Cada una toma además el `FOR SHARE` del reloj: el admin que cambia el reloj espera a las operaciones en vuelo, como en E5/E6.
7. **Supuestos de aislamiento:** `READ COMMITTED` (el libro ya lo exige; el backend usa el valor por defecto). La salida rápida sin bloqueo es segura porque el reloj no cambia con operaciones en vuelo: si con **mi** `hoy` nada está vencido, ninguna otra sesión del cliente puede dejarme algo vencido; si hay algo, se relee bajo el bloqueo.
8. **Un rechazo posterior en la misma operación** (p. ej. *Saldo insuficiente*) revierte también el devengo recién hecho; la siguiente operación lo repite **una sola vez** (probado, incluido un fallo inyectado en cada una de las 4 patas de devengo + operación y de cierre del CDT).
9. **Volver al reloj real** tras adelantar deja `ultimo_cobro` «en el futuro»: no se devenga ni se recobra hasta que el calendario lo alcance; el dinero movido en esa ventana no genera interés por esos días (límite de la simulación, ya documentado en E3 §14). Las patas fechadas en el futuro solo se informan, no son error. El cierre de un CDT se fecha en `fecha_fin` aunque se «descubra» después: **ordenar el historial por `orden`, no por `fecha`**.
10. **Casos de laboratorio:** el interés se recorta a `monto_maximo` (probado); si al cerrar un CDT el saldo de la cuenta superara el máximo del dominio (10¹³), el libro rechaza con un `Libro mayor: … excedería el máximo permitido` (P0001), no se recorta.
11. **Créditos (E8/E9):** `_avanzar_hasta` deja un hueco documentado. Hoy los pasos son independientes; el auto-descuento de E9 (que sí debita la cuenta) tendrá que fusionar los eventos en orden cronológico (M10).
12. **Superusuario:** el límite ya documentado de E2 (puede desactivar triggers, incluida la guardia monotónica); las pruebas de permisos usan roles reales por TCP.
13. **Sin idempotencia:** un doble clic en «Abrir CDT» = dos CDT, cada uno atómico (como E5/E6).
14. **Un hueco de pruebas hallado por las mutaciones (corregido):** M160 (motor sin el filtro `ultimo_cobro < hoy`) sobrevivió a la primera pasada porque tras «volver al reloj real» el motor ni se invocaba (todo estaba adelantado). Se añadió a `54` un bolsillo atrasado conviviendo con adelantados; la mutación ahora falla con el error de la guardia monotónica.
15. **Lecciones de las propias pruebas (no del código):** una función `STABLE` (la huella de saldos) en la **misma sentencia** que una `VOLATILE` que escribe no ve las escrituras (snapshot) y la comparación pasaba en vacío; se separaron las sentencias (el arnés lo documenta). Una consulta con `-c "a; b"` de `psql` corre en una sola transacción: las sesiones de la prueba 6 de concurrencia usan un `psql` por petición.

## 6. Mutaciones

Resultado y detalle en `docs/db/evidencias/07-motor-cdt-mutaciones.txt`. Las M137–M175 rompen a propósito: el devengo quitado de **cada** función integrada (6 implementaciones que cubren las 8 públicas), el motor sin bloqueo de cuenta, `ultimo_cobro` sin avanzar (o solo si hubo interés), un día de más / de menos, el motor leyendo el reloj o fechando con `now()`, el CDT sin tope en `fecha_fin`, sin `CERRADO`, sin `generado` al vencer o reprocesando cerrados, el cierre fechado con el `ahora`, `_bloquear_cuentas` y `hacer_transferencia` sin el orden de bloqueo (deadlock), la guardia monotónica quitada o desactivada, el filtro `ultimo_cobro < hoy` quitado, sin recorte a `monto_maximo`, la salida rápida que ignora los CDT, otra fórmula (nominal simple) y otra en `simular_cdt`, una tasa copiada distinta, `vista_cdts` sin cerrados, `balance_total` sin CDT o con los cerrados, segunda instantánea / `now()`, y permisos (EXECUTE de una interna, REVOKE de una pública, `SECURITY INVOKER`, sesión sin validar).

## 7. Verifícalo en pgAdmin
Conexión «Banco — administración (postgres)», base `banco`, Query Tool → *Open File* → `docs/db/evidencias/07-pgadmin-demo.sql` → F5. Todo va en `BEGIN … ROLLBACK` (**también el salto de fecha**); los resultados salen en la pestaña **Messages** (`docs/db/evidencias/07-pgadmin-demo-salida.txt`). Recorrido: bolsillo + CDT → el reloj avanza 30 días → la primera consulta devenga (patas `INTERES_BOLSO` e `INTERES_CDT`) y la segunda no escribe nada → se retira el saldo **con** intereses → a los 95 días `vista_cdts` cierra el CDT y acredita `monto + generado` (patas `CDT_VENCIMIENTO` fechadas en `fecha_fin`) → a los 500 días no se devenga nada más → transferencia → volver al reloj real no recobra nada y la guardia rechaza un retroceso → rechazos con su mensaje exacto → integridad global.

Consultas sueltas (pegables, base `banco`):
```sql
-- las 16 funciones que ejecuta banco_app y las 9 internas del motor sin EXECUTE
SELECT count(*) FILTER (WHERE has_function_privilege('banco_app', p.oid, 'EXECUTE')) AS publicas FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace;
SELECT proname FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('_avanzar_hasta','_devengar_bolsillos','_devengar_cdts','_factor_interes','_bloquear_cuentas') ORDER BY 1;
-- la guardia monotónica
SELECT tgrelid::regclass AS tabla, tgname, tgenabled FROM pg_trigger WHERE tgname = 'trg_ultimo_cobro_monotono';
-- el factor de interes (D1 PROVISIONAL)
SELECT round(1000000 * public._factor_interes(12, 30), 2) AS bolsillo_30d_12pct, round(10000000 * public._factor_interes(10, 360), 2) AS cdt_360d_10pct;
```
