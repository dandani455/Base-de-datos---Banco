# Etapa 10 — Vistas del contrato (dashboard e historial) · paquete de entrega

**Estado (2026-11-24): IMPLEMENTADA, PENDIENTE DE TU AUDITORÍA.** Diseño v1 aprobado (`10-vistas-diseno.md`; D-E10-1 a D-E10-8 y D-E10-9 con el ajuste de alcance de la precisión) y seguido sin cambiar ninguna decisión ni fórmula. **D6 y D8 siguen siendo decisiones provisionales del equipo, sin resolver y sin cambiar su comportamiento** (§4). Sin commits; `front/` y backend intactos; **E11 no iniciada**.

## 1. Qué se entrega

| Pieza | Archivo |
|---|---|
| Públicas `vista_dashboard(usuario)` y `vista_historial(usuario, limite = 50)`; internas `_json_transacciones` (único formateador de `Transaccion[]`) y `_reglas_historial` (D8 provisional + tope 50); **vista real `v_transaccion_usuario`** (la regla de «fila visible»); `SET TimeZone` por código en las funciones que emiten fechas | `db/sql/23_vistas.sql` (idempotente, comentado) |
| Integración (solo los puntos del diseño) | `18_cdt.sql` (`vista_cdts.fecha_cierre` = instante ISO, **D-E10-5**), `09_integridad.sql` (lista blanca 24 → **26**, fila de defensa de la vista, excepción de `_reglas_historial` entre las internas), `05_permisos.sql` (la vista se vuelve a conceder a `banco_lector` al reaplicar) |
| Pruebas nuevas | `65_vistas_historial` (39), `66_vistas_aleatorio` (6), `67_contrato` (17), `reales/51_vistas_conexiones` (45), `reales/52_vistas_concurrencia` (10) = **117**; `db/tests/precision.test.mjs` (9, fuera del runner) |
| Pruebas adaptadas (solo inventarios y lo que cambia por E10, §3) | `03_schema`, `09_idempotencia`, `10_libro_triggers`, `52_bolsillos`, `54_devengo`, `55_cdt`, `reales/45`, `reales/47`, `reales/49` |
| Mutaciones | `db/tests/mutaciones/mutaciones.sh`: **M306–M340** (35 nuevas; helper `replv` para mutar vistas) |
| Resumen para el backend + **tabla maestra endpoint → función** (contrato §7.6) | `docs/db/etapas/10-resumen-para-juan.md` |
| Evidencias | `docs/db/evidencias/10-vistas*.txt`, `10-precision.txt`, `10-explain-historial.txt`, `10-pgadmin-demo.sql` y su salida, `git_status_e10.txt` |

## 2. Cómo funciona

```
vista_dashboard(usuario) / vista_historial(usuario, limite)
 sesión (_validar_cliente: Sesión inválida / Acceso denegado / mensaje de bloqueo) → cuenta del usuario
 → UNA _reloj_instantanea() → _avanzar_hasta (devenga, cierra CDT vencidos y COBRA cuotas con descuento ANTES de leer)
 → UNA sola sentencia (una sola foto): total, últimas 8, CDT y créditos nunca se ven a medias de un movimiento concurrente
```

* **Regla de «fila visible» (`v_transaccion_usuario`).** Una fila por **operación** del libro: la pata de la cuenta en un contenedor de liquidez, con prioridad `CUENTA` > `BOLSILLO` > `CDT` (en `BOLSO_MOVIMIENTO`, la de sentido `S`). Dirección = `sentido` (`S` = `envio`, `E` = `recibo`): reproduce la lista del contrato (`BOLSO_RETIRO` entra a la principal ⇒ recibo). Las patas `CREDITO` y `RESULTADO` nunca salen. `contraparte` nunca es null: (1) el snapshot de la pata (con ` · <cuenta>` **solo** en ENVIO/RECIBO), (2) el nombre de su bolsillo/CDT/producto (`LEFT JOIN`), (3) «Banco Digital». Orden: **`orden DESC`** (no `fecha`: un cobro del motor lleva la fecha del día en que debió ocurrir).
* **Dashboard.** `nombre` = nombres; `balance_total` = **`balance_total()`** (la misma función de `vista_balance`; D6 provisional); `transacciones` = las 8 primeras de `vista_historial`; `cdts` = cantidad y Σ `generado_acumulado` de los CDT **ACTIVOS**; `creditos.cuota_por_pagar` = Σ `valor_cuota` de la próxima cuota impaga de cada crédito ACTIVO (`_proxima_cuota`, sin mora); `creditos.interes_corriendo` = Σ `_interes_corriendo` (= Σ `interes_mes` de `vista_creditos`).
* **`p_limite`:** `NULL` = 50; se acota a [1, 50] (`_reglas_historial().limite_max`); sin mensaje nuevo.
* **D8 (provisional, del equipo/front):** `_reglas_historial()` = `{mostrar_bolso, mostrar_interes_bolso, mostrar_interes_cdt: true}` (el default del contrato: todo visible). Cambiarlo = cambiar solo ese cuerpo; se prueba apagándolo (F1–F4 de `65`).
* **Fechas ISO con zona de Bogotá por código:** las 2 funciones nuevas y las 9 de E5–E9 que devuelven un `timestamptz` (`hacer_transferencia`, 3 de bolsillo, `crear_cdt`, `vista_cdts`, `solicitar_credito`, `pagar_cuota`, `abonar_credito`) llevan `SET TimeZone = 'America/Bogota'` (D-E10-8): con la sesión en UTC siguen saliendo con `-05:00`.

## 3. Resultados

| Verificación | Resultado |
|---|---|
| Suite completa (`ctl.sh test --evidence 10-vistas`) | **2827 aprobadas, 0 fallidas** (E9 cerró en 2710: +117 nuevas, 0 menos; las adaptadas siguen verdes) |
| `precision.test.mjs` | **9 de 9** (`10-precision.txt`): 100 024 importes con centavos exactos dentro del rango (< 1e13), rechazo de 1e13 / 1e13+0,01 / 1e15 / −1e13 / 99.999.999.999.999.999 en el dominio y en `_validar_monto`, y las salidas reales de `vista_balance` y `vista_dashboard` con saldos de 9.999.99x.xxx.xxx |
| `reset` + 3 × `apply` desde cero | **sin errores** (`10-vistas-aplicacion.txt`; 24 archivos por pasada): 11 tablas, **109 funciones**, **21 triggers**, **9 vistas**, 20 plantillas; `banco_app` ejecuta exactamente **26**; `_json_transacciones` sin EXECUTE para app/lector/dev; `v_integridad_global` en orden; `banco` queda **limpia** (reloj real, 0 usuarios/créditos/productos, `tasa_mora_anual` NULL) |
| Mutaciones nuevas M306–M340 | **35 de 35 detectadas** (`10-vistas-mutaciones.txt`) |
| Regresión (E2/E5–E9: libro, integridad, motor, `vista_cdts` y permisos; 46) | **46 de 46 detectadas** (`10-vistas-mutaciones-regresion.txt`) |
| Demo de pgAdmin | `10-pgadmin-demo.sql` + salida real `10-pgadmin-demo-salida.txt` (todo en `BEGIN … ROLLBACK`) |

Qué cubre cada archivo nuevo:
* **65** — historial **exacto** con los 17 tipos (incl. `AJUSTE_ADMIN` ±, bono y mora): una fila por grupo contra un oráculo independiente, tipo real, dirección, monto, contraparte (con la cuenta solo entre cuentas), nota y orden; el receptor ve el mismo envío como RECIBO; `p_limite` (NULL, 0, −7, 5, 51, 1000); respaldo de contraparte sin snapshot (bolsillo, CDT, producto, «Banco Digital») y el bono sin mostrar la cuenta; **orden por escritura con un cierre de CDT descubierto después de un recibo** (con límite 2 el corte es por `orden`); dashboard coherente con `/bolsillos`, `/cdts` y `/creditos` (2 créditos, 1 CDT activo, uno cerrado que no suma); un cliente sin productos en ceros; **el dashboard dispara un cobro automático con mora y una falla inyectada en cada una de las 5 patas lo revierte todo**; catálogo (1 `_avanzar_hasta`, 1 instantánea, sin leer el reloj), permisos, el índice del historial, D8 apagable (F1–F4), fechas `-05:00` con la sesión en UTC y UNA sola lectura del reloj.
* **66** — 140 operaciones aleatorias (solicitar, pagar, abonar, descuento, CDT, bolsillos, envíos, lecturas, saltos de reloj): todas terminan en OK o en un mensaje de negocio permitido; para los 5 clientes el historial coincide **fila por fila** con un oráculo independiente (`DISTINCT ON` por grupo), el dashboard con sus fuentes, ninguna fila es de `CREDITO`/`RESULTADO`; `v_integridad_global.ok`.
* **67** — conformidad con el contrato de las 26 funciones (una llamada de cada una, sesión en UTC): nombres de campo y tipos JSON contra `types.ts`, **ningún `numeric` como string** (recorrido recursivo), toda `fecha`/`fecha_cierre` ISO con `-05:00`, listas `[]`, ids como texto, el CDT cerrado con `fecha_cierre` instante; los 14 mensajes de §6 que emite la BD existen **byte a byte** en el catálogo y tres de ellos en vivo con `P0001`.
* **reales/51** (roles reales por TCP, sin superusuario) — conversación del backend, fechas con la conexión pidiendo UTC; **`banco_app` no lee la vista ni el libro ni ejecuta las internas**, `banco_lector`/`banco_dev` leen la vista; aislamiento (ninguna fila de otra cuenta); admin → `Acceso denegado`; bloqueado → mensaje exacto; inexistente → `Sesión inválida`; **falla inyectada en cada pata y corte de conexión** en un cobro disparado por el dashboard; carreras por borrado.
* **reales/52** — 6 lectores del dashboard contra 4 sesiones que mueven dinero de suma cero (540 lecturas: **ninguna** vio un `balance_total` distinto), 12 dashboards simultáneos con una cuota vencida (se cobra **una** vez), 24 transferencias cruzadas + 8 lecturas con cobros pendientes en ambos emisores (sin deadlock).

**Pruebas anteriores adaptadas (solo donde cambia el comportamiento; ninguna se eliminó):**
* `03_schema`, `10_libro_triggers`: inventarios (105 → **109** funciones, 8 → **9** vistas, lista blanca 24 → **26**, SECURITY DEFINER +2, `_reglas_historial` entre lo que el lector ejecuta). `52`, `55`, `reales/45`, `reales/47`, `reales/49`: lista blanca 26. `54`: el catálogo clasifica las 2 nuevas (**devengan 17**). `55` y `reales/45`: `fecha_cierre` ahora es instante ISO (D-E10-5). `09_idempotencia`: reaplica también `23_vistas.sql`.

## 4. Decisiones aprobadas y cómo se reflejan

| ID | Cómo quedó |
|---|---|
| D-E10-1 | 2 públicas + 2 internas + 1 vista + conformidad con el contrato + `precision.test.mjs` + tabla maestra para Juan. Ni front ni backend. |
| D-E10-2 | Regla de fila visible, dirección por `sentido`, `orden DESC`, contraparte con respaldo, `p_limite` acotado sin mensaje. |
| D-E10-3 | Dashboard como en §2 (nombres; `generado` solo ACTIVOS; Σ próxima cuota sin mora; Σ interés corriendo). |
| D-E10-4 | Una sentencia, una instantánea, motor antes de leer; catálogo de `54` (17 devengan). |
| D-E10-5 | `vista_cdts.fecha_cierre` = instante ISO con zona (una expresión de `18_cdt.sql`; `55` y `reales/45` adaptadas). |
| D-E10-6 | `banco_app` **sin** `SELECT` sobre `v_transaccion_usuario`; fila nueva en `v_integridad_defensas`; lista blanca 26. |
| D-E10-7 | Solo 1 vista real nueva. |
| D-E10-8 | `SET TimeZone` por código (2 nuevas + 9 anteriores por `ALTER FUNCTION`, solo configuración); probado con la sesión en UTC. |
| D-E10-9 (ajustada) | `precision.test.mjs` independiente del runner; **la precisión exacta de centavos se garantiza solo dentro del rango de `Number` (< 1e13)**, no para todo `NUMERIC(18,2)`; la BD rechaza ≥ 1e13 y la prueba verifica las dos mitades. |
| **D6 (equipo)** | **Provisional y sin tocar:** `balance_total` no resta la deuda; dashboard y `/bolsillos` usan la misma función. `58` sigue afirmando que no cambia. |
| **D8 (equipo)** | **Provisional y sin tocar:** todo visible (default del contrato) en `_reglas_historial()`. |
| D10 / D13 | Las firmas coinciden con el contrato; **ningún mensaje nuevo**. |

## 5. Desviaciones y límites (sin ocultar nada)

1. **`banco_lector` necesita `EXECUTE` de `_reglas_historial()` para leer la vista** (la prueba real lo detectó: *«permission denied for function _reglas_historial»*). Las funciones que llama una vista corren con los privilegios de **quien consulta**, no del dueño (la misma razón por la que `_plantillas_validas` ya lo tiene). Es una función **pura** que solo devuelve constantes; `banco_app` **no** la recibe. Se añadió su excepción a la defensa «funciones internas sin EXECUTE» de `09_integridad.sql`.
2. **`05_permisos.sql` (E1) editado en una línea:** al reaplicarlo sin `23` revocaba el `SELECT` del lector sobre la vista (`09_idempotencia` lo detectó); ahora la vuelve a conceder junto a las `v_integridad_*` y `v_reloj_*`.
3. **`ALTER FUNCTION … SET TimeZone` en 9 funciones de E5–E9** (D-E10-8 lo contemplaba): es configuración, no cuerpo. **Límite:** si se reaplica el script de una de ellas **sola** (`CREATE OR REPLACE`), la configuración se pierde hasta reaplicar `23` (igual que `06` → `21` en E9); `09_idempotencia` reaplica `23` al final y `ctl.sh apply` aplica en orden.
4. **La prueba del plan (`65`/E5) afirma solo el uso del índice**, no la ausencia de `Sort`: dentro de una transacción de prueba sin estadísticas el planificador elige otro camino (falló en la suite completa aunque pasaba aislada). Con las estadísticas reales de `banco_test` tras la suite el plan es **`Limit → Index Scan ix_transaccion_cuenta_orden` sin Sort** (`10-explain-historial.txt`).
5. **+117 aserciones, no ≈ +170; 35 mutaciones, no ≈ 28:** se priorizó no duplicar (el contrato se prueba con una llamada por función y los casos de negocio ya estaban en E4–E9).
6. **El «Balance total» sube al pedir un crédito (D6) y el historial puede llenarse de intereses (D8)**: límites conocidos mientras el equipo decide; están aislados en una función cada uno.
7. **Corrección de la auditoría de E10:** la defensa «`banco_app` no tiene `SELECT` sobre `v_transaccion_usuario`» usaba `COALESCE(…, true)`: si la vista desaparecía, el control daba `ok = true`. Ahora exige `to_regclass('public.v_transaccion_usuario') IS NOT NULL` y su valor por defecto es `false` (detalle «VISTA AUSENTE»): sin la vista, la defensa **y `v_integridad_global.ok` fallan**. Prueba nueva `65`/E6 (borra la vista dentro de un `SAVEPOINT`, exige `ok = false` y restaura) y mutación **M340** (reintroduce la guarda ausente y el `true` por defecto: detectada por E6; el primer intento de M340 era equivalente porque la guarda `IS NOT NULL` ya bastaba y se reescribió). Comentarios actualizados: `09_integridad.sql` (26 funciones públicas, E4–E10) y `18_cdt.sql` (`fecha_cierre` = instante ISO con zona, no fecha simple).
8. **Una lectura del dashboard/historial puede escribir** (cobros, intereses, cierres): idempotente y atómico (probado con falla inyectada y corte de conexión).

## 6. Mutaciones

Bloque **M306–M340** (35): fila visible (pata `BOLSILLO` duplicada, `BOLSO_MOVIMIENTO` con las dos patas, pata `CDT` siempre visible, patas `RESULTADO` incluidas), dirección invertida, cuenta de la contraparte en el bono, sin respaldo de contraparte (bolsillo/CDT/producto y «Banco Digital»), D8 ignorado o forzado (3), orden por fecha, límite sin tope / sin piso / formateador sin filtro de cuenta, `vista_historial`/`vista_dashboard` sin motor, doble instantánea, `now()`, `cdts.generado` con cerrados, `cuota_por_pagar` con el capital, `interes_corriendo` con `max`, 10 transacciones, saludo con apellidos, `balance_total` solo principal, sin `SET TimeZone` (nueva y anterior), `fecha_cierre` en fecha y 6 cambios de permisos/SECURITY DEFINER.

**Resultado: 35 de 35** (M306–M339 con `DESDE=306` y M340 con `SOLO=M340`; `10-vistas-mutaciones.txt`). **Dos huecos hallados y corregidos (como en E7–E9):** M311 (la cuenta de la contraparte salía también en el bono de referido: ninguna prueba tenía un bono **con** `contraparte_cuenta`) y M317 (ordenar por `fecha` en vez de `orden` pasaba porque el `jsonb_agg` exterior reordena: solo un **límite menor que el número de filas** distingue los dos criterios). Se añadieron A11 y B2 a `65`. Además, un patrón de M325 estaba mal escrito (no aplicaba) y se corrigió.

**Regresión** (`10-vistas-mutaciones-regresion.txt`): las mutaciones de E2/E5–E7 sobre libro, integridad, motor y permisos, M142/M170–M174 sobre `vista_cdts` y las de permisos y motor de E8/E9: **46 de 46**.

## 7. Verifícalo en pgAdmin

1. Conexión **«Banco — administración (postgres)»** → base `banco` → Query Tool → *Open File* → [10-pgadmin-demo.sql](../evidencias/10-pgadmin-demo.sql) → **F5** (todo va en `BEGIN … ROLLBACK`; los resultados salen como `NOTICE` en *Messages*). Salida de referencia: [10-pgadmin-demo-salida.txt](../evidencias/10-pgadmin-demo-salida.txt). Recorre: el historial de una cuenta con todos los tipos (una fila por operación), `p_limite`, el recibo del receptor, el dashboard tras un salto de reloj (trae los intereses y el cierre ya escritos), un cobro automático disparado por el dashboard con la fecha del cierre del CDT, la segunda lectura sin escribir, `_reglas_historial()`, permisos e integridad.
2. Consultas sueltas (superusuario; no escriben):
   * `SELECT * FROM public.v_transaccion_usuario WHERE cuenta_id = (SELECT id FROM public.cuenta LIMIT 1) ORDER BY orden DESC LIMIT 10;` — el historial «crudo» (solo `banco_lector`/`banco_dev`/superusuario).
   * `SELECT public._reglas_historial();` — D8 y el tope en un solo lugar.
   * `SELECT control, ok FROM public.v_integridad_defensas WHERE control LIKE 'banco_app NO tiene SELECT sobre v_transaccion_usuario%' OR control LIKE 'banco_app ejecuta%';`
   * `node db/tests/precision.test.mjs` (en una terminal, con Docker en marcha).
