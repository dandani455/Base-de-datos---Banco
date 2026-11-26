# Etapa 8 — Créditos (catálogo, simulación, solicitud y plan de cuotas) · DISEÑO TÉCNICO v1.1 (compacto)

**Estado (2026-11-24): DISEÑO v1.1 APROBADO por el responsable de BD e IMPLEMENTADO** (paquete de entrega: `08-creditos.md`). Este documento se conserva como el diseño aprobado; lo que difiere de lo implementado está en `08-creditos.md` §5 (90 funciones en lugar de ≈ 87, +221 aserciones en lugar de ≈ 280, 42 mutaciones en lugar de ≈ 30, y las adaptaciones de pruebas de E2/E3). **v1.1:** D-E8-9 (`ct_credito_plan`) se revisó contra las fuentes: el invariante pasa de tres reglas a **una** (§6, §6.1) y se listan sus implicaciones para E9 (§6.1, §11).
Reutiliza: E2 (`_asentar_grupo`, plantilla `CREDITO_DESEMBOLSO`, acumulador `credito.capital_pendiente`, guardia `trg_zz_proteger_credito`), E3 (`_reloj_instantanea()`), E4–E6 (`_validar_cliente`, `_validar_monto`, `_msg_negocio`, `_bloquear_cuentas`), E7 (`_avanzar_hasta`, `balance_total`, patrón de `crear_cdt`/`simular_cdt`/`vista_cdts`, escaneo de catálogo). **No hay tablas nuevas**: `credito_producto`, `credito` y `cuota` ya existen desde E1.
Fuentes leídas completas para este diseño: contrato §1–§8 (PDF 2026-11-18), spec §5/§7.6/§8, `front/src/api/types.ts`, `Creditos.tsx`, `Simulador.tsx`, `Inicio.tsx` (landing), `Dashboard.tsx`, `Tasas.tsx` y `front/mock/server.mjs`. Los números de este documento salen de consultas ejecutadas en `banco` dentro de una transacción revertida (nada quedó escrito).

## 1. Alcance

| Entra en E8 | No entra (E9 y siguientes) |
|---|---|
| `productos_disponibles`, `productos_publicos`, `simular_credito`, `solicitar_credito`, `vista_creditos` (5 públicas). Plan de cuotas persistido al desembolsar. Tope de Inmuebles y regla de edad. Guardia de integridad del plan (`ct_credito_plan`). Integración con `_avanzar_hasta` en las 4 que leen saldos. | `pagar_cuota`, `abonar_credito` (`POST /creditos/:id/abono`), `activar_descuento_automatico`, mora, auto-descuento y las plantillas `CREDITO_CUOTA/ABONO/MORA` del libro (**D7**, equipo). `vista_dashboard` (`cuota_por_pagar`, `interes_corriendo`) = E10. `admin_set_tasa_credito` = E11. Seed del catálogo = E14. |

Consecuencia visible hasta E9: un crédito se puede **pedir y consultar**, pero **todavía no se puede pagar ni abonar** (el botón «Abonar a capital» del front no tendrá función de BD detrás; hay que avisárselo a Juan).

## 2. Lo que dicen contrato, spec y front (y las contradicciones)

| # | Hallazgo | Resolución propuesta |
|---|---|---|
| H1 | Contrato §2: `tasa` = **% E.A.**; contrato §3.5: «amortización francesa, **i = tasa/12**». Con E.A. no son lo mismo (ver §4.1). El mock usa `(1+EA)^(1/12)−1`; el spec dice `anual/12`. | **D1** (equipo). Provisional: **E.A. estricta**, en **una sola función** (`_tasa_mensual`). |
| H2 | Catálogo: spec §7.6 = Libre inversión / Vehículo / Educación / Inmuebles con topes ($30M, $50–200M, $1–100M, 100× balance ≤ $2.000M) y plazos 24/120/240/360 m. El mock tiene otros nombres («Vivienda», «Educativo») y otros límites. | **D11** (equipo): **la BD no trae catálogo** (igual que los CDT de E7); las pruebas crean sus productos. Las columnas ya soportan los 4 casos (§5.2). |
| H3 | Spec §7.6: «balance total para los topes = (principal + bolsillos + CDT activos) **− Σ capital_pendiente**». E7 dejó `balance_total` sin restar deuda (D6). | Separo ambas cosas (D-E8-5): el **tope** usa el neto del spec; `balance_total`/`vista_balance.total` **no cambian**. |
| H4 | Contrato §6 junta dos mensajes: «Plazo excede el límite de edad / Plazo fuera de rango». | Son **dos** mensajes, ambos exactos del contrato (D-E8-7 / D13). |
| H5 | Contrato §3.5: `simular_credito(p_producto_id, p_monto, p_plazo_meses)` **sin** `p_usuario_id`, pero el tope de Inmuebles y la edad dependen del usuario. | `p_usuario_id` primero (D10; mismo criterio que `simular_cdt` en E7). |
| H6 | La landing llama `GET /creditos/productos` **sin sesión** y usa `descripcion` (con respaldo estático). Contrato §7.3 deja abierto `productos_publicos()`. | La incluyo (D-E8-8); que el endpoint público lo exponga Juan es decisión suya. |
| H7 | `Simulador.tsx` manda `monto` y `plazo` como **números JSON** y `producto_id` como texto. Un `plazo` fraccionario (12,5) como `integer` sería un error de driver → 503. | `p_plazo_meses numeric`, validado en la BD (D-E8-8); monto como texto, como en E5–E7. |
| H8 | Contrato §3.5: `vista_creditos` = `[{id, producto, cuotas_pagadas, cuotas_faltantes, interes_mes, saldo}]` (+ `descuento_automatico`, `mora_acumulada` «opcional futuro»). `types.ts`: `saldo?` opcional. | Exactamente esos 6 campos (los 2 opcionales llegan con E9). |
| H9 | Spec §7.6: «desembolso instantáneo»; la hoja de decisión del plan fija «`total_a_pagar` = Σ cuotas». | Se respeta. |

## 3. Modelo de datos (sin cambios de tablas)

| Tabla.columna | Uso en E8 |
|---|---|
| `credito_producto` | `tasa_anual` (editable por E11), `monto_min`, `monto_max`, `plazo_min_meses`, `plazo_max_meses`, `tope_absoluto` (NULL = sin tope), `multiplicador_balance` (NULL = sin multiplicador), `aplica_regla_edad`, `descripcion`. |
| `credito` | Se inserta con `capital_pendiente = 0` (lo exige la guardia de E2) y `tasa_anual`/`plazo_meses`/`monto` **copiados** (inmutables). `fecha_desembolso = hoy`; `fecha_interes = fecha_desembolso` (= **inicio del período de interés vigente**: lo anterior a esa fecha ya está pagado). El libro sube `capital_pendiente` a `monto` con la pata `CREDITO E`. |
| `cuota` | El plan **completo** se inserta de una vez: `numero 1..n`, `fecha_vencimiento`, `valor_cuota_original = valor_cuota`, `capital_programado`, `interes_programado`, `capital_pagado = intereses_pagados = 0`, `pagada = false`. |

Un solo objeto nuevo de integridad: el constraint trigger diferido `ct_credito_plan` (D-E8-9, §6).

## 4. El cálculo (lo que pediste vigilar)

### 4.1 Tasa mensual (PROVISIONAL, D1) — centralizada en `_tasa_mensual(tasa_pct)`
`i = (1 + tasa/100)^(1/12) − 1` (E.A. estricta). Es la **única** función que hay que cambiar si el equipo elige otra convención; `_plan_cuotas` usa solo `i`.

| Caso medido ($10.000.000, 12 cuotas, 18 %) | cuota fija | última cuota | `total_a_pagar` | `intereses_totales` |
|---|---|---|---|---|
| **E.A. estricta (propuesta)** `i = 1,388843 %` | **910.463,77** | 910.463,73 | 10.925.565,20 | 925.565,20 |
| Nominal `i = 18/12 = 1,5 %` (lectura literal del contrato) | 916.799,93 | 916.799,92 | 11.001.599,15 | 1.001.599,15 |

(La hoja de decisión del plan decía 925.565,21: ese valor era `cuota × 12 − P`; el real, con la última cuota absorbiendo la diferencia, es 925.565,20.)

### 4.2 Plan francés (`_plan_cuotas(monto, tasa_pct, n)` → tabla `numero, cuota, capital, interes, saldo`; la usan simular **y** solicitar)
1. `i = _tasa_mensual(tasa)`, `q = (1+i)^n`, **cuota fija** `C = round(P·i·q / (q−1), 2)`. Se calcula en `numeric` (`power(numeric)` da ~20 dígitos; comprobado) y nunca en `float`.
2. Para `k = 1..n−1`: `interés_k = round(saldo_{k−1}·i, 2)`, `capital_k = C − interés_k`, `saldo_k = saldo_{k−1} − capital_k`.
3. **Última cuota absorbe la diferencia** (contrato): `capital_n = saldo_{n−1}`, `interés_n = round(saldo_{n−1}·i, 2)`, `cuota_n = capital_n + interés_n`.
4. `total_a_pagar = Σ cuota_k` (incluye la última real), `intereses_totales = Σ interés_k = total − P`, `cuota_mensual = C`.
5. Es un lazo secuencial (el redondeo de cada fila depende de la anterior): 360 cuotas ≈ 0,03 ms por plan (medido: 200 planes de 360 cuotas en 4,9 ms; ≪ los 5 s del contrato). Se usa `q = (1+i)^n` a partir de `i` (no el cierre `(1+t)^(n/12)`): da la misma cuota a 2 decimales (comprobado en 2.000M/14 %/360) y así D1 solo toca `_tasa_mensual`.

**Límite honesto (medido):** al redondear la cuota a centavos, el error se compone y la última cuota difiere de la fija:

| Monto | Tasa | Plazo | cuota fija | última | diferencia |
|---|---|---|---|---|---|
| 30.000.000 | 23,9 % | 24 | 1.550.764,56 | 1.550.764,58 | +0,02 |
| 50.000.000 | 18,9 % | 120 | 882.874,10 | 882.874,46 | +0,36 |
| 300.000.000 | 14,1 % | 240 | 3.571.142,85 | 3.571.142,74 | −0,11 |
| 500.000 | 12 % | 360 | 4.908,22 | 4.916,69 | +8,47 |
| 2.000.000.000 | 14 % | 360 | 22.397.296,18 | 22.397.278,22 | −17,96 |
| 2.000.000.000 | 30 % | 360 | 44.225.781,28 | 44.226.303,99 | +522,71 |

Es el comportamiento que pide el contrato («la última cuota absorbiendo la diferencia»); la diferencia máxima es ≈ 0,001 % de la cuota en los casos reales. Las pruebas la acotan (§8) y el documento de entrega la mostrará.

### 4.3 Vencimientos (PROVISIONAL, D-E8-3)
`fecha_vencimiento_k = fecha_desembolso + k meses calendario`, **anclado a la fecha original** (no iterativo): desembolso 31-ene → 28-feb, 31-mar, 30-abr, 31-may (PostgreSQL recorta al fin de mes; comprobado, también con 29-feb). El spec no define el calendario. Cada período lleva la **tasa mensual completa** (`saldo·i`), no una tasa por días: así `interes_programado` es el de la cuota francesa estándar.

### 4.4 Interés corriendo / `interes_mes` (PROVISIONAL, D-E8-4; contrato §7.4)
«Interés devengado del mes en curso, aún no pagado» = prorrata **lineal por días** dentro del período de la **próxima cuota impaga** `j`:
`interes_mes = round(interes_programado_j · clamp((hoy − fecha_interes) / (vencimiento_j − fecha_interes), 0, 1), 2)`; 0 si no hay cuota impaga.
Ejemplo ($10M, 18 % E.A.): cuota 1 trae interés 138.884,30; a mitad del período (día 15 de 30) `interes_mes = 69.442,15`; el día del vencimiento **y mientras no se pague** vale 138.884,30 (el interés ya es debido). Es **derivado**: se calcula al leer y **no escribe nada en el libro** (los intereses de crédito solo entran al libro cuando se **pagan**, en la cuota o abono de E9: no existe un tipo `INTERES_CREDITO`). Alternativa más simple: devolver siempre el interés completo de la próxima cuota.

## 5. Funciones

### 5.1 Públicas (EXECUTE solo `banco_app`; `banco_dev` por herencia; todas `SECURITY DEFINER`, `search_path = public, pg_temp`, salida `jsonb`)

| Función | Endpoint | Salida | Devenga |
|---|---|---|---|
| `productos_disponibles(usuario)` | `GET /creditos/productos` | `[{id, nombre, tasa, monto_min, monto_max, plazo_min, plazo_max}]` con **topes efectivos** del usuario; `[]` si no hay catálogo | sí |
| `productos_publicos()` (sin argumentos, sin sesión) | landing sin sesión | `[{id, nombre, descripcion, tasa, monto_min, monto_max, plazo_min, plazo_max}]` con topes **base** (sin datos personales) | no (exenta) |
| `simular_credito(usuario, producto_id text, monto numeric, plazo_meses numeric)` | `POST /creditos/simular` | `{cuota_mensual, total_a_pagar, intereses_totales}` | sí |
| `solicitar_credito(usuario, producto_id text, monto numeric, plazo_meses numeric)` | `POST /creditos` | `{id, fecha}` (id del crédito) | sí |
| `vista_creditos(usuario)` | `GET /creditos/mis-creditos` | `[{id, producto, cuotas_pagadas, cuotas_faltantes, interes_mes, saldo}]` | sí |

### 5.2 Topes efectivos (`_limites_credito(usuario, producto, hoy)`)
* `monto_max_ef = greatest(0, least(monto_max, coalesce(tope_absoluto, ∞), coalesce(multiplicador × patrimonio_neto, ∞)))`. Libre inversión = `tope_absoluto` 30M; Vehículo/Educación = su rango; Inmuebles = `multiplicador 100`, `tope_absoluto 2.000M`.
* `plazo_max_ef = least(plazo_max_meses, plazo técnico)`; si `aplica_regla_edad`: `least(·, greatest(0, (edad_limite_inmuebles − edad) × 12))` con `edad` = **años cumplidos** a `hoy_banco()`. Ejemplo del spec: 43 años → 27 años = **324 m**.
* `patrimonio_neto(cuenta)` = `balance_total(cuenta) − Σ capital_pendiente` de los créditos ACTIVOS (función interna **distinta** de `balance_total`; D-E8-5). Ejemplo: cuenta 2.000.000 + bolsillo 1.000.000 + CDT 503.000 − deuda 1.200.000 = 2.303.000 → tope 100× = **230.300.000**. Con deuda mayor que activos el tope es 0.
* Un producto **siempre se lista**; sus topes efectivos pueden quedar en 0 (monto_max < monto_min o plazo_max < plazo_min): el front lo muestra y `solicitar` responde el mensaje de rango. (Alternativa: omitirlo.)
* Límites **técnicos** centralizados en `_reglas_credito()`: plazo máximo de cálculo **360** meses (la cifra del propio contrato §8; protege contra un producto mal cargado con millones de cuotas), mensajes del contrato §6.

### 5.3 `solicitar_credito`: orden de validación y pasos
1. `_validar_cliente` (sesión) → `_validar_monto` (`Monto inválido`) → plazo entero ≥ 1 (si no: `Plazo fuera de rango`) → producto (texto uuid válido y existente; si no: `Recurso no encontrado`).
2. `cuenta`; **una** `_reloj_instantanea()` → `(hoy, ahora)`.
3. `_avanzar_hasta(cuenta, hoy, ahora)` (devenga bolsillos/CDT **antes** de calcular el tope) y luego `_bloquear_cuentas([cuenta])`: **todo lo que decide el desembolso se lee bajo el bloqueo de la cuenta**.
4. ¿Ya hay crédito ACTIVO de ese producto? → `Ya tienes un crédito vigente de este producto`.
5. Monto vs `[monto_min, monto_max_ef]` → `Monto fuera de rango`. Plazo vs `[plazo_min, plazo_max_producto]` → `Plazo fuera de rango`; si cabe en el producto pero excede la edad → `Plazo excede el límite de edad`.
6. `INSERT credito` (capital 0) → `INSERT cuota` (las n filas en **una** sentencia desde `_plan_cuotas`) → `_asentar_grupo(ahora, [CUENTA E D +M, CREDITO E C +M])` (tipo `CREDITO_DESEMBOLSO`, `contraparte_nombre` = nombre del producto) → `SET CONSTRAINTS ct_credito_plan IMMEDIATE/DEFERRED` (un plan incoherente falla **dentro** de la función, no en el COMMIT del backend). Antes de asentar, la función afirma que insertó **exactamente `n` cuotas**: la completitud del plan **al crear** es responsabilidad de `solicitar_credito` y de sus pruebas, no de un trigger permanente (§6.1).
7. Carreras (`unique_violation` del índice `uq_credito_vivo_por_producto`, FK del producto o de la cuenta borrados): se traducen a `Ya tienes un crédito vigente…` / `Recurso no encontrado` / `Sesión inválida`; **nunca** un error de driver (503). Devuelve `{id, fecha}`.

`simular_credito` ejecuta 1–2 y 4–5 (sin el paso 4 del vigente) y devuelve el resumen de `_plan_cuotas`: **la simulación y la solicitud comparten helpers**, así que lo simulado es lo que se cobra (se prueba igualdad fila a fila).

## 6. Libro y capital pendiente

**Asiento del desembolso** (plantilla ya existente, E2): `CUENTA E` (débito, cuenta +M) y `CREDITO E` (crédito, `capital_pendiente +M`); activos +M, pasivos +M, patrimonio 0. Desembolso con `contraparte_nombre` = producto; el historial lo muestra como `recibo`.
**Invariante nueva, `ct_credito_plan`** (constraint trigger diferido sobre `credito` y `cuota`; D-E8-9, **revisada en v1.1**): al confirmar, para cada crédito existente, **`capital_pendiente` (el acumulador del libro) = Σ (`capital_programado` − `capital_pagado`) de sus cuotas NO pagadas**. Una sola regla, válida para ACTIVO y PAGADO. En E8 todas las cuotas están impagas con `capital_pagado = 0`, así que vale `Σ capital_programado = monto = capital_pendiente`. Es la red que protege a E9: un pago o abono que mueva la deuda sin dejar el plan coherente falla en la transacción. Las reglas v1 «(a) exactamente `plazo_meses` cuotas» y «(c) PAGADO ⇒ todas pagadas» **se eliminan** (§6.1: imponían decisiones que las fuentes dejan abiertas). No toca E2 (`_asentar_grupo` no se edita). Se añade el control a `v_integridad_defensas` (existe/habilitado) y una verificación por crédito a la vista de integridad.
**Limitación documentada:** como todo trigger, un superusuario puede desactivarlo; lo detectan las vistas y el event trigger de E2.

### 6.1 Pagos completos, parciales y abonos: qué definen realmente las fuentes (revisión de D-E8-9)

| Operación | Qué dicen las fuentes | Dónde |
|---|---|---|
| **Pago de cuota completo** | `pagar_cuota(usuario, credito)` **sin parámetro de monto**: «el usuario paga desde el principal (función de BD, genera `CREDITO_CUOTA`)»; `Saldo insuficiente` cubre «cuota». No hay endpoint en el contrato §3.5, ni UI en el front, ni ruta en el mock. | spec §7.6, plan Task 7, contrato §6 |
| **Pago parcial de una cuota** | **No existe en ninguna fuente.** Sin monto en `pagar_cuota`; `cuota.pagada` es booleano; la landing solo muestra «Pagada / Con abono / Pendiente». Las columnas `capital_pagado`/`intereses_pagados` («realmente pagado») existen, pero ninguna regla los usa de forma parcial. | spec §5.8, `Fragmentos.tsx` |
| **Abono extraordinario a capital** | `POST /creditos/:id/abono {monto}`: «primero los intereses del mes, el resto baja capital y **recalcula las cuotas restantes**» (mismo plazo y tasa, cuota nueva menor, **no acorta meses**), genera `CREDITO_ABONO`. Front: solo un campo monto y «Abonar a capital». El mock solo resta saldo (no calcula plan). `valor_cuota_original` frente a `valor_cuota` existen justamente para este recálculo. | spec §7.6/§15.3, contrato §3.5, `Creditos.tsx`, mock |
| Mora, auto-descuento, cómo se cobra el interés del abono | **D7, pendiente** (el libro ni siquiera tiene plantilla para `CREDITO_CUOTA/ABONO/MORA`). | spec §7.6, D-E2-1 |

**Conclusión.** `credito` + `cuota` soportan tal cual lo que las fuentes definen: pago completo de la próxima cuota y abono con recálculo (desglose **vigente** en `capital/interes/valor_cuota`, **original** en `valor_cuota_original`, **realizado** en `*_pagado`). El pago parcial no está definido: **E8 no lo modela, no lo asume y no lo impide**.

**Sobre tu observación.** Es cierta la asimetría: el libro baja `capital_pendiente` solo al asentar `CREDITO_ABONO`, mientras el plan únicamente cambia si la función lo reescribe. Pero eso es lo que el invariante debe **detectar**, no un defecto: el spec obliga a que el abono recalcule las cuotas restantes **en la misma operación**; si E9 asentara el abono y olvidara el recálculo, quedaría deuda sin plan y la transacción debe fallar. Al ser **diferido (COMMIT)**, el orden interno de `abonar_credito` (asentar antes o después de recalcular) no importa.

**El fallo real era de v1, no del concepto:** las reglas (a) «exactamente `n` cuotas» y (c) «PAGADO ⇒ todas pagadas» imponían decisiones que las fuentes dejan abiertas. Por ejemplo, cuando un abono **liquida** el crédito, ¿las cuotas restantes se marcan pagadas, se eliminan o quedan en cero? (no pueden quedar en cero: `ck_cuota_valores_positivos`). La regla (a) prohibiría eliminarlas; la (c) obligaría a marcarlas. Ninguna fuente lo dice, así que no deben quedar fijadas en un trigger.

**Solución mínima (v1.1): una sola regla**, expresada solo en términos de capital:
`capital_pendiente = Σ (capital_programado − capital_pagado)` sobre las cuotas **no pagadas**.
* Hoy `capital_pagado = 0` en toda cuota impaga, así que equivale a `Σ capital_programado`. La resta evita reescribir el trigger si D7 llegara a definir pagos parciales; no los introduce.
* Es neutral frente a la política de E9: cierra bien con recálculo, con liquidación (si E9 marca o elimina las cuotas restantes, la suma es 0 = capital 0) y con cualquier tratamiento de mora (la mora no es capital).
* La completitud al crear (exactamente `n` cuotas numeradas) la afirma `solicitar_credito` antes de asentar y la prueban sus tests (crédito con `n−1` cuotas ⇒ falla). Eso no necesita trigger permanente.

| Caso (todo en una transacción) | Resultado del invariante |
|---|---|
| Crédito recién desembolsado | cumple (`Σ = monto = capital_pendiente`) |
| Pago completo de la cuota *k*, puntual o tardío | cumple: `capital_pendiente` baja `capital_programado_k` y la cuota sale de las impagas |
| Abono **con** recálculo de las cuotas impagas | cumple |
| Abono **sin** recálculo | **falla (es el objetivo)** |
| Mora o interés del abono | no tocan capital: sin efecto |
| Abono que liquida el crédito | cumple si las restantes quedan pagadas o eliminadas; **cuál** es decisión de E9/D7 |

Costo y eventos: iguales a v1 (2 constraint triggers diferidos, sobre `credito` y `cuota`; el `UPDATE` de `credito` que hace el libro al asentar dispara la verificación aunque la función no toque el plan).

**Implicaciones para E9 (sin decidir nada de D7):**
1. `abonar_credito` debe, en la **misma transacción**, asentar `CREDITO_ABONO` y reescribir `capital_programado`, `interes_programado` y `valor_cuota` de las cuotas impagas de modo que la suma cuadre con el nuevo `capital_pendiente`; no toca `valor_cuota_original`, `numero` ni `fecha_vencimiento` (mismo plazo, no acorta). No debe llamar `SET CONSTRAINTS … IMMEDIATE` antes de terminar el recálculo; sí al final, como `solicitar_credito`.
2. `pagar_cuota` marca la cuota (`pagada`, `fecha_pago`, `capital_pagado`, `intereses_pagados`) y asienta `CREDITO_CUOTA` con el capital **vigente** (`capital_programado`) de esa cuota; el invariante lo verifica solo.
3. **Pendiente de D7:** pagos parciales (si existieran, se anotarían en `capital_pagado` de una cuota aún impaga; el invariante ya los admite), cómo se cierran las cuotas restantes al liquidar por abono, y cómo se cobra el interés del abono.
4. `interes_mes` (§4.4) está definido contra `(fecha_interes, vencimiento_j)` y `interes_programado_j`. Si E9 mueve `fecha_interes` a la fecha del abono, `interes_programado_j` tiene que ser el interés del **tramo restante** `[fecha_interes, vencimiento_j]` para que la prorrata siga siendo correcta. No se fija ahora: depende de cómo D7 cobre «los intereses del mes» del abono.
5. El auto-descuento del motor (hueco de `_avanzar_hasta`) reutilizará la misma lógica interna de `pagar_cuota`; no requiere cambios en el invariante.

## 7. Integración con `_avanzar_hasta` y concurrencia

* **Motor sin cambios en E8** (D-E8-10). Los créditos de E8 no tienen eventos que cambien con el tiempo: el interés corriendo es derivado y no hay mora ni cobro automático. El paso (d) de `_avanzar_hasta` sigue siendo el **hueco documentado**; el diseño lo deja listo: `cuota.fecha_vencimiento` + `ix_cuota_pendiente` (existe) son las «fechas de evento» que E9 fusionará **en orden cronológico** con los cierres de CDT y el interés de bolsillo (el auto-descuento depende del saldo que esos eventos dejaron).
* Las 4 funciones que leen saldos o calculan topes **devengan antes** (`productos_disponibles`, `simular_credito`, `solicitar_credito`, `vista_creditos`); `productos_publicos` es la única exenta. El escaneo de catálogo de E7 se amplía: devenga 8 → **12**, exenta 8 → **9**; cada implementadora tiene `_avanzar_hasta(` y `_reloj_instantanea()` **una sola vez**, la instantánea primero, y nunca `now()/current_date/hoy_banco()/_ahora_real()`.
* **Bloqueos:** solo la fila de **una** cuenta (FOR NO KEY UPDATE, el mismo del libro) → no hay orden entre cuentas que cuidar; el lock explícito tras el devengo cierra el «leer tope → escribir» sin huecos y serializa dos solicitudes del mismo usuario.
* **Concurrencia que se probará con conexiones reales:** N solicitudes simultáneas del mismo producto → **exactamente 1** crédito, el resto `Ya tienes un crédito vigente…` (sin `23505` filtrado); solicitudes de productos distintos + transferencias + `crear_cdt` del mismo usuario sin deadlock y con conservación; lecturas paralelas tras un salto de reloj sin devengo duplicado; corte de conexión a mitad de `solicitar` → nada queda (ni crédito, ni cuotas, ni asiento).

## 8. Plan de pruebas y mutaciones (ágil: solo los riesgos de E8)

| Archivo | Cubre | Aserciones aprox. |
|---|---|---|
| `57_creditos_calculo.test.sql` | `_plan_cuotas` vs referencia independiente (lazo en `float8` con `exp/ln` y la misma regla de redondeo); invariantes (Σ capital = P, saldos ≥ 0 y decrecientes, `total = Σ cuotas`, última cuota acotada); 1 cuota, 360 cuotas, tasas extremas; ~200 casos aleatorios; fechas (fin de mes, bisiesto); `_tasa_mensual` centralizada (simular = solicitar = plan); interés corriendo (día 0, mitad, vencimiento, vencida, sin cuota impaga) | ~80 |
| `58_creditos.test.sql` | topes (Libre/Vehículo/Educación/Inmuebles con bolsillo, CDT y deuda), regla de edad (límites 69/70/71, cumpleaños, 43 → 324 m), mensajes y **orden** de validación, vigente por producto, asiento (2 patas, cuenta +M, `capital_pendiente = M`, contraparte, fecha), plan persistido, **atomicidad con falla inyectada** en cada paso (credito, cuotas, libro), devengo previo (salto de reloj antes del tope y del desembolso), forma exacta de las 5 salidas (números, `[]`), `ct_credito_plan` (crédito sin cuotas, Σ ≠ capital, cuota borrada, **abono simulado sin recálculo ⇒ falla** y **con recálculo ⇒ pasa**, pago completo de una cuota ⇒ pasa, liquidación con cuotas restantes marcadas o eliminadas ⇒ pasa, `capital_pagado` descontado) y `solicitar_credito` con `n−1` cuotas ⇒ falla antes de asentar, permisos (`banco_app` ejecuta 21; `banco_lector` ninguna), escaneo de catálogo y una sola instantánea | ~120 |
| `59_creditos_aleatorio.test.sql` | ~150 operaciones aleatorias (solicitar, CDT, bolsillos, envíos, saltos de reloj) con `v_integridad_global.ok` y conservación (I5u/I5g) al final | ~20 |
| `reales/47_creditos_conexiones.sh` | roles reales por TCP (`banco_app`, `banco_lector`, `banco_dev`), sin superusuario; corte de conexión a mitad de `solicitar` | ~60 |
| `reales/48_creditos_concurrencia.sh` | las 4 situaciones del §7 | ~25 |

Mutaciones nuevas M176–≈M205 (≈30): por ejemplo, tasa nominal en vez de E.A., redondeo de la cuota, última cuota sin absorber, vencimientos iterativos en vez de anclados, interés corriendo sin tope/sin clamp, tope Inmuebles sin restar deuda, regla de edad `<` por `<=` o sin ×12, vigente sin filtrar por estado, `_avanzar_hasta` o el lock explícito quitados de cada función, doble instantánea, `ct_credito_plan` sin la comparación, o ignorando `capital_pagado`, o sin el filtro de impagas, o sin el disparo desde `credito`; `solicitar_credito` sin la afirmación de `n` cuotas, desembolso fuera de `_asentar_grupo`, `EXECUTE` a `banco_lector`, `productos_publicos` con datos personales. Regresión: suite completa de E2–E7 (se adaptan solo los inventarios: funciones 74 → ≈ 87, triggers 18 → 20, lista blanca 16 → 21, reaplicación de 19/20) + re-ejecución de las mutaciones de E7 que miran permisos/catálogo (M137–M142, M171–M174). **Estimado: ≈ +280 aserciones.**

## 9. Decisiones que necesitan tu aprobación

| ID | Decisión | Tipo | Recomendación |
|---|---|---|---|
| **D-E8-1** | Alcance: E8 = productos, simular, solicitar, ver, plan persistido (5 públicas). Pagar/abonar/mora/auto-descuento = E9 (D7). | Técnica | Aprobar. El abono (`/creditos/:id/abono`) no existirá hasta E9. |
| **D-E8-2** | **Tasa mensual = E.A. estricta** `(1+t)^(1/12)−1`, centralizada en `_tasa_mensual`; contradice la frase literal «i = tasa/12» del contrato (H1). Cambia solo esa función. | **Financiera, PROVISIONAL (D1, equipo)** | Aprobar como provisional. Cifras comparadas en §4.1 para que el equipo decida. |
| **D-E8-3** | Cuota francesa en `numeric`; vencimientos = desembolso + k meses calendario anclados; interés por período `saldo·i`; última cuota absorbe; tope técnico de plazo 360. | Mixta (calendario = **provisional**, equipo) | Aprobar. |
| **D-E8-4** | `interes_mes` = prorrata lineal por días de la próxima cuota impaga, derivado (no escribe). | **PROVISIONAL (contrato §7.4; abono = D7)** | Aprobar; alternativa: interés completo de la próxima cuota. |
| **D-E8-5** | El **tope** de Inmuebles usa `balance_total − Σ capital_pendiente` (spec §7.6, piso 0); `balance_total`/`vista_balance.total` **no cambian** (D6 sigue abierta). Efecto visible: al desembolsar, el `total` mostrado sube en M (la deuda no se resta). | **Financiera, PROVISIONAL (D6, equipo)** | Aprobar; es lo que el spec define para los topes. |
| **D-E8-6** | Catálogo vacío (D11); producto siempre listado con topes efectivos ≥ 0; orden por nombre; sin seed. Nombres/montos/plazos de los 4 productos (spec vs mock) los decide el equipo. | **PROVISIONAL (D11, equipo)** | Aprobar. |
| **D-E8-7** | Regla de edad: años cumplidos a `hoy_banco()`, `plazo_max = (70 − edad) × 12` (`parametro.edad_limite_inmuebles`); dos mensajes del contrato (`Plazo excede el límite de edad`, `Plazo fuera de rango`), más `Monto fuera de rango` y `Ya tienes un crédito vigente de este producto`. **Ningún mensaje inventado.** | Contrato (D13) | Aprobar. |
| **D-E8-8** | Firmas: `p_usuario_id` en `simular_credito` (D10); `plazo` como `numeric` y monto como texto; `productos_publicos()` sin sesión; `solicitar` devuelve `{id, fecha}`; `vista_creditos` lista solo los **ACTIVOS**, con los 6 campos del contrato. | **PROVISIONAL (D10, Juan + front)** | Aprobar; avisar a Juan (incluido que el abono no existe hasta E9). |
| **D-E8-9 (v1.1)** | `ct_credito_plan`: 2 constraint triggers diferidos con **una sola regla**: `capital_pendiente = Σ (capital_programado − capital_pagado)` de las cuotas impagas (ACTIVO y PAGADO). Se eliminan «n cuotas» y «PAGADO ⇒ todo pagado» (decisiones abiertas de E9/D7); la completitud al crear la afirma `solicitar_credito`. + control en las vistas de integridad. Triggers 18 → 20. Implicaciones para E9 en §6.1. | Técnica | Aprobar (protege capital pendiente sin fijar D7). |
| **D-E8-10** | Motor `_avanzar_hasta` **sin cambios** en E8; 4 funciones devengan y `productos_publicos` es exenta; lock explícito de la cuenta en `solicitar`; el hueco de auto-descuento/mora queda para E9 (fusión cronológica). | Técnica | Aprobar. |
| **D-E8-11** | Aceptar el **límite** de la última cuota (±0,36 en créditos normales; hasta ≈ 20 pesos en 2.000M a 30 años y 14 %; 522,71 con 30 % E.A.) por el redondeo a centavos que exige el contrato. | Límite documentado | Aceptar y documentar. |

**Siguen siendo del equipo (no se programan como definitivas):** D1 (convención de tasas), D6 (qué cifra es el «balance total»), D7 (mora y abono), D11 (catálogo), D13 (mensajes), D10 (firmas). Todas centralizadas: `_tasa_mensual`, `_reglas_credito()`, `patrimonio_neto`, `balance_total`.

## 10. Riesgos y límites que conviene tener presentes

1. **Sin pagos hasta E9**: los créditos solo crecen; las pruebas de `cuotas_pagadas > 0` y de «vencida» usan datos preparados por el propio test (marcar cuota pagada + asiento), no una función pública.
2. **`total` mostrado inflado** al desembolsar (D-E8-5/M8): por diseño hasta que el equipo resuelva D6.
3. **Las lecturas escriben** (`vista_creditos`, `productos_disponibles`, `simular_credito`): el primer GET tras un salto de reloj devenga bolsillos/CDT, como en E7.
4. **Borrado de usuario** con créditos vivos destruye deuda y dinero (ya trazado en `audit` por E2); el borrado en cascada no dispara `ct_credito_plan` (el crédito ya no existe).
5. **Backend (Juan):** el abono no existe hasta E9; `plazo` y `monto` deben pasar tal cual (texto/numérico), no como `float`/`integer` del driver.
6. **Superusuario:** puede saltarse `ct_credito_plan` (documentado; lo detectan las vistas).

## 11. Cambios de la v1.1 (solo D-E8-9)

| Dónde | Cambio |
|---|---|
| §6 | `ct_credito_plan`: de tres reglas (n cuotas, Σ capital, PAGADO ⇒ todo pagado) a **una** (`capital_pendiente = Σ (capital_programado − capital_pagado)` de impagas). |
| §6.1 (nuevo) | Contraste con contrato, `types.ts`/`Creditos.tsx`/`Fragmentos.tsx`, mock, spec y plan: pago completo, pago parcial (no definido), abono (recalcula, no acorta); casos del invariante; 5 implicaciones para E9. |
| §5.3 paso 6 | `solicitar_credito` afirma que insertó `n` cuotas antes de asentar. |
| §8 | Pruebas y mutaciones de `ct_credito_plan` ajustadas (abono sin/con recálculo, liquidación, `capital_pagado`). Cantidad estimada de aserciones sin cambio material. |
| §9 | Fila D-E8-9 reescrita. Ninguna otra decisión cambia; **no se tocó ninguna decisión financiera pendiente** (D1, D6, D7, D11). |

**Hallazgo al releer las fuentes (no cambia D-E8-5, solo lo dejo a la vista):** spec §7.6 y el plan (Task 7: `balance_total` = … − Σ `capital_pendiente`, con la prueba «tomar crédito no aumenta `balance_total`») definen el total **neto de deuda**, mientras E7 dejó `balance_total` sin restarla por indicación tuya (D6). D-E8-5 mantiene esa decisión provisional; si el equipo adopta el neto en D6, solo cambia `balance_total` y `patrimonio_neto` pasa a ser un alias.
