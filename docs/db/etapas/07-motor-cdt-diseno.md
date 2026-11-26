# Etapa 7 — Motor de devengo (`_avanzar_hasta`) y CDT · DISEÑO TÉCNICO v1 (compacto, para aprobación)

**Estado (2026-11-24): DISEÑO APROBADO por el responsable de BD (D-E7-1 a D-E7-9, con 4 precisiones: `_factor_interes()` = E.A. estricta PROVISIONAL y centralizada; el límite de redondeo D-E7-9 se acepta y se documenta; `balance_total()` incluye provisionalmente los CDT activos con `monto + generado_acumulado` sin adelantar créditos; E5/E6 se modifican solo en los puntos de integración marcados). IMPLEMENTADO: ver `07-motor-cdt.md`.** (Texto original del diseño, conservado tal cual abajo: «Este documento es solo diseño: no hay SQL ni implementación».) E6 **aprobada oficialmente**. Sin commits; no se toca `front/`, backend ni etapas posteriores (E8 no se inicia). **Excepción que pide aprobación expresa (D-E7-4):** E7 debe editar las funciones aprobadas de E5 (`hacer_transferencia`) y E6 (`_mover_bolsillo`, `crear_bolsillo`, `vista_balance`, `balance_total`) en los puntos que ya están marcados `-- (E7: …)`.
Reutiliza: E2 (`_asentar_grupo`, plantillas `INTERES_BOLSO`, `INTERES_CDT`, `CDT_CREACION`, `CDT_VENCIMIENTO`, trigger diferido `ct_cdt_inversion`), E3 (`_reloj_instantanea()`, `_dias_por_cobrar`), E4–E6 (`_validar_cliente`, `_validar_monto`, `_msg_*`, patrón de carreras, `_bolsillo_propio`, `balance_total`).

## 1. Alcance

| Entra en E7 | No entra |
|---|---|
| `_avanzar_hasta` (devengo de **bolsillos** y **CDT**, cierre de CDT vencidos); integración en las 6 funciones marcadas de E5/E6; CDT: `listar_cdt_definiciones`, `simular_cdt`, `crear_cdt`, `vista_cdts` (4 públicas nuevas); guardia de monotonía de `ultimo_cobro`; escaneo de catálogo «toda función que lee o mueve saldos devenga primero» | Créditos: cuotas, mora, abono, auto-descuento (**E8/E9**; `_avanzar_hasta` deja el hueco documentado); `vista_dashboard`/`vista_historial` (E10); `sp_avanzar_todos` (E13); admin (E11); el catálogo real de CDT (D11) y su seed (E14) |

## 2. Cómo funciona el motor

```
operación de cliente (las 8 que leen/mueven saldos)
 1 _validar_cliente · validaciones propias de la función (sin bloqueos; mensajes y orden de E4–E6 sin cambios)
 2 UNA _reloj_instantanea()  →  (hoy, ahora)                                   ← FOR SHARE del reloj
 3 _bloquear_cuentas(ids)   [solo hacer_transferencia: ambas cuentas, orden de id]
 4 _avanzar_hasta(cuenta, hoy, ahora)   ← NO lee el reloj; usa (hoy, ahora) recibidos
      a) salida rápida SIN bloqueo si nada está vencido
      b) bloqueo de la fila de la cuenta (FOR NO KEY UPDATE: el MISMO del libro)
      c) relee lo vencido BAJO el bloqueo (sentencia nueva) y devenga
 5 la operación (mismo (hoy, ahora), mismo bloqueo ya tomado) → _asentar_grupo
```

### 2.1 `_avanzar_hasta(p_cuenta_id, p_hoy, p_ahora) → integer` (interna, nadie la ejecuta salvo el dueño)
Devuelve cuántos grupos escribió (sirve a las pruebas, nada más). Si la cuenta ya no existe devuelve 0 y el llamador sigue su ruta de carreras de E5/E6 (`Sesión inválida`). Bajo el bloqueo de la cuenta nada de lo suyo puede desaparecer (el borrado en cascada necesita ese mismo bloqueo).

1. **Bolsillos** (orden `id`): para cada uno con `ultimo_cobro < hoy`: `n = hoy − ultimo_cobro`; interés = `round(balance × _factor_interes(tasa_bolsillo, n), 2)`; si > 0, **un grupo** `INTERES_BOLSO` (`BOLSILLO E` + `RESULTADO E`, contraparte «Banco Digital», nota «N días»), fecha = `ahora`; **siempre** `UPDATE ultimo_cobro = hoy`, incluso con saldo 0 o interés redondeado a 0 (si no, un depósito posterior cobraría retroactivamente los días anteriores: mutación dedicada). Forma cerrada: coste O(bolsillos), no O(días); saltar 30 años no hace ningún bucle por día.
2. **CDT** vigentes (orden `fecha_fin, id`): `d = least(hoy, fecha_fin)`; **objetivo acumulado** `obj = round(monto × _factor_interes(tasa_cdt, d − fecha_inicio), 2)`; asiento = `obj − generado_acumulado` (si > 0, un grupo `INTERES_CDT`: `CDT E` + `RESULTADO E`); `ultimo_cobro = d`. Como el objetivo depende solo de los días transcurridos y el asiento es la diferencia con lo ya generado, **repetir la llamada produce 0 asientos y no hay deriva de redondeo**: idempotente por construcción, aunque falle otra defensa. Si `fecha_fin ≤ hoy`: `estado = 'CERRADO'` y un grupo `CDT_VENCIMIENTO` (`CDT S` por `monto + generado`, `CUENTA E`), en la **misma transacción** (el trigger `ct_cdt_inversion` lo exige); el interés no pasa de `fecha_fin` (M2) aunque el reloj salte años.
3. **Créditos (E8/E9):** hueco documentado y vacío. Hoy los pasos 1 y 2 son independientes (el cierre de un CDT acredita la cuenta; ningún devengo de E7 depende de ese saldo), así que el orden entre ellos no es observable. **E9** (auto-descuento, que sí debita la cuenta) tendrá que fusionarlos en orden cronológico de eventos (M10); la estructura de E7 (dos procedimientos internos `_devengar_bolsillos`/`_devengar_cdts`) lo permite sin reescribirla.

### 2.2 Las 4 garantías que pediste

| Garantía | Mecanismo | Cómo se prueba |
|---|---|---|
| **Devengar antes de leer o modificar bolsillos** | `_avanzar_hasta` en las 8 funciones: `hacer_transferencia`, `mover_a_bolsillo`, `retirar_de_bolsillo`, `mover_entre_bolsillos` (vía `_mover_bolsillo`), `crear_bolsillo`, `vista_balance`, `crear_cdt`, `vista_cdts`. **Cobertura por catálogo, no por memoria:** toda función de `banco_app` está en una de dos listas explícitas (*devenga* / *exenta*: `registrar_usuario`, `obtener_credenciales`, `validar_sesion`, `verificar_correo`, `vista_perfil`, `nombre_destinatario`, `listar_cdt_definiciones`, `simular_cdt`); una función nueva que no esté en ninguna **hace fallar la prueba** (E8–E10 la heredan) | escaneo + mutación «quitar `_avanzar_hasta`» por cada una de las 8 + prueba dinámica: tras saltar el reloj, retirar el interés recién generado funciona |
| **Una sola instantánea** | la operación llama `_reloj_instantanea()` **una vez** y pasa `(hoy, ahora)`; `_avanzar_hasta` y los dos `_devengar_*` no leen el reloj ni usan `now()`/`current_date`/`hoy_banco()`/`_ahora_real()` | escaneo (conteo = 1 por función; 0 en las internas) + conteo dinámico de lecturas (E5: 1 por instantánea + 1 por pata) + mutaciones |
| **Mismo bloqueo de cuenta** | `_avanzar_hasta` toma `FOR NO KEY UPDATE` sobre la fila de la cuenta, el mismo que el libro y el borrado en cascada; **bajo ese bloqueo relee lo vencido** (sentencia nueva; en `READ COMMITTED` ve lo que otra sesión acaba de devengar). La salida rápida sin bloqueo es segura: si con **mi** `hoy` nada está vencido, ninguna otra sesión del mismo cliente (que usa el mismo `hoy` o uno mayor, porque el reloj no cambia con operaciones en vuelo: FOR SHARE de E3) puede dejarme algo vencido | prueba con el bloqueo de la cuenta sostenido por otra sesión (la vista debe esperar) + concurrencia real |
| **Sin doble devengo / período repetido** | (i) `ultimo_cobro` se actualiza en la misma transacción que el asiento y bajo el bloqueo; (ii) `_dias_por_cobrar` vacío si `hoy ≤ ultimo_cobro` (volver al reloj real no recobra); (iii) CDT por objetivo acumulado (arriba); (iv) **guardia** nueva: `ultimo_cobro` no puede disminuir (trigger BEFORE UPDATE en `bolsillo` y `cdt`, recomendado en E3); (v) el diferido `ct_cdt_inversion` ya exige Σ `INTERES_CDT` = `generado_acumulado` | 2–6 sesiones simultáneas con el mismo `hoy` → exactamente un juego de asientos; reintento tras `tx:N`; volver a real; mutaciones: quitar el UPDATE de `ultimo_cobro`, quitar el bloqueo, un día de más, saltarse el UPDATE con saldo 0 |

### 2.3 Orden de bloqueos y el deadlock que hay que evitar (riesgo propio de E7)
Orden global fijo: **reloj (SHARE) → cuentas en orden de `id` → contenedores**. `_avanzar_hasta` bloquea primero *la cuenta del invocador*; en `hacer_transferencia` eso rompe el orden del libro (A→B ∥ B→A: A bloquea A, B bloquea B, ambos piden la otra: **deadlock**; ya lo anticipaba el diseño general D.7). Solución: `hacer_transferencia` resuelve ambos ids (sin bloquear, como hoy), toma la instantánea, **bloquea ambas cuentas en orden de `id`** (`_bloquear_cuentas`, interno), y solo entonces `_avanzar_hasta` (del **origen**; el destino solo recibe y su devengo no le afecta). El libro vuelve a pedir los mismos bloqueos (ya los tiene). Si en esa espera desaparece una cuenta se traduce con las reglas de carrera de E5 (`Sesión inválida` / `Cuenta no encontrada`). Prueba: A→B ∥ B→A con devengos pendientes en ambos, 40 pares, sin deadlock.

## 3. La fórmula (D1/D11 siguen siendo del equipo)
Una sola función pura `_factor_interes(tasa_pct, dias) → numeric` es el **único** punto con la matemática (la usan el motor y `simular_cdt`, por eso la simulación coincide con lo que de verdad se genera: se prueba `generado_vencimiento` = `generado_acumulado` final). **Valor provisional propuesto: E.A. estricta**, `(1 + tasa/100)^(días/365) − 1`, rotulada PROVISIONAL (D1) en código, `COMMENT` y pruebas; si el equipo elige otra convención, solo cambia ese cuerpo. Cifras (hoja de decisión del diseño general, §E.3): bolsillo $1.000.000 a 12 %/30 d → **$9.358,20** (E.A.) frente a ≈ $9.910 (nominal con capitalización diaria); CDT $10.000.000 al 10 %/360 d → **$985.647,56** (E.A.) frente a $986.301,37 (nominal simple).

**Hallazgo técnico que acota a D1 para los bolsillos:** el interés del bolsillo se acredita *dentro* del saldo y el esquema solo guarda `balance` y `ultimo_cobro`. Si la fórmula fuera interés **simple** (`saldo × tasa × días/365`, la lectura literal del spec), el resultado dependería de **cuántas veces consulta el usuario** (cada consulta capitaliza). Solo una fórmula **compuesta con factor diario fijo** (E.A. estricta, o nominal capitalizado `(1 + tasa/365)^días`) es independiente del número de llamadas, hasta el redondeo a centavos. Por eso recomiendo que D1 elija entre esas dos para los bolsillos; el interés simple solo es seguro para CDT (que no capitaliza en su base).

Parámetros: `tasa_bolsillo_anual` (parametro, 12; no editable por el admin según el contrato) y la tasa **copiada** en cada CDT al crearlo (`cdt.tasa_anual`; las ediciones de tasa de E11 no afectan CDT ya creados).

## 4. Funciones nuevas

| Función | Entrada → salida | Notas |
|---|---|---|
| **públicas (4)**, `banco_app` pasa de 12 a **16** | | |
| `listar_cdt_definiciones(p_usuario_id)` | → `[{id, nombre, tasa, plazo_dias, monto_min}]` | solo sesión (E4); `[]` si no hay; **firma con `p_usuario_id`** (contrato §1; D10 con Juan) |
| `simular_cdt(p_usuario_id, p_definicion_id text, p_monto numeric)` | → `{generado_mes, generado_dia, generado_vencimiento}` | sin escribir ni reloj; mes = 30 días (**provisional**, D-E7-7); `Monto por debajo del mínimo del CDT` |
| `crear_cdt(p_usuario_id, p_definicion_id text, p_monto numeric)` | → `{id, fecha}` | sesión → monto → definición (`Recurso no encontrado`) → mínimo → instantánea → avanzar → `INSERT cdt` (copia tasa, plazo, monto; `ultimo_cobro = fecha_inicio = hoy`) y `CDT_CREACION` por `_asentar_grupo` **uno tras otro, misma transacción**; `Saldo insuficiente` lo da el libro; carreras traducidas como en E6 |
| `vista_cdts(p_usuario_id)` | → `[{id, monto, generado_hasta_hoy, tiempo_restante, fecha_cierre}]` | avanza y lee; `tiempo_restante` = «N días»/«1 día» o «Cerrado» (contrato); vigentes primero (`fecha_fin`), luego cerrados (D-E7-7) |
| **internas (nadie salvo el dueño)** | | |
| `_avanzar_hasta`, `_devengar_bolsillos`, `_devengar_cdts`, `_factor_interes`, `_bloquear_cuentas`, `_texto_tiempo_restante`, `trg_ultimo_cobro_monotono` | | inventario ≈ 61 → **≈ 69** funciones |

**Mensaje nuevo:** ninguno inventado. `Monto por debajo del mínimo del CDT` y `Recurso no encontrado` están en el contrato §6.

## 5. Cambios sobre E5/E6 (necesitan tu aprobación: modifican código aprobado)

| Función | Cambio mínimo (en el punto ya marcado) | Lo que NO cambia |
|---|---|---|
| `hacer_transferencia` (E5) | tras las validaciones y la nota: instantánea → `_bloquear_cuentas` (ambas, orden de id) → `_avanzar_hasta(origen)` → libro | orden y texto de los mensajes, firma, salida, carreras |
| `_mover_bolsillo` (E6, cubre las 3 de movimiento) | `_avanzar_hasta` justo después de la instantánea que ya toma y antes del libro (el devengo cambia saldos, no nombres: el snapshot de nombres no se mueve) | idem; sigue **una** instantánea |
| `crear_bolsillo` (E6) | `_avanzar_hasta` tras la instantánea (uniformidad, §3.2 de E6) | `ultimo_cobro = hoy`, `creado_en = ahora` |
| `vista_balance` (E6) | pasa de «lectura pura sin reloj» a: instantánea → `_avanzar_hasta` → **la misma sentencia única de lectura**. Es consistente: si devengó, el bloqueo sostenido impide que otro movimiento del cliente se interponga; si no devengó, es una sola foto | forma de la salida y mensajes |
| `balance_total` (E6) | D-E7-5 (abajo) | única definición, interna, `STABLE` |

Las pruebas de E5/E6 que **fijan el estado anterior a E7** se adaptan (y lo reporto): marcador `-- (E7:…)` → llamada real; `vista_balance` 0 lecturas del reloj → 1; «no existe `avanzar_hasta`»; invariante de `total` en `reales/44 §5`. Todo lo demás (mensajes, atomicidad, concurrencia, permisos) corre **sin tocar** como regresión.

## 6. Pruebas (solo riesgos del devengo; E2–E6 no se repiten)

| Riesgo | Cómo | Dónde (nuevo) |
|---|---|---|
| Matemática: motor = referencia **independiente** escrita en la prueba (bucle por día en SQL); caso 0 días, saldo 0, n = 1, mes, año, 30 años (10 950 días, sin bucle); no supera `monto_maximo` (se recorta, nunca error de dominio) | SQL | `54_devengo.test.sql` |
| Independencia del camino: 1 llamada de 30 días vs 30 de 1 día (diferencia acotada por el redondeo, documentada) · idempotencia (2.ª llamada = 0 grupos) · `hoy < ultimo_cobro` (volver a real): nada · saldo 0 que luego recibe dinero no cobra retroactivo | SQL | `54` |
| Cobertura por catálogo: lista *devenga/exenta* completa; `_avanzar_hasta` presente 1 vez en cada una de las 8; **una** instantánea; internas sin reloj; sin `now()`/`current_date` | escaneo + conteo dinámico | `54` |
| CDT: creación atómica (`tx:1`/`tx:2`), mínimo, copia de tasa/plazo, objetivo acumulado = fórmula en cada punto de control, tope en `fecha_fin` con salto de años, cierre (`CERRADO`, cuenta recibe `monto + generado` a fecha `fecha_fin`), nada más se devenga después, `simular_cdt` = lo realmente generado, `vista_cdts` (vigentes/cerrados, `tiempo_restante`) | SQL | `55_cdt.test.sql` |
| Integridad global tras operaciones aleatorias con **saltos de reloj** (bolsillos, CDT, transferencias, retiros) contra un modelo; conservación por cliente (cuenta + bolsillos + CDT) salvo el interés devengado; `v_integridad_global` | SQL | `56_motor_aleatorio.test.sql` |
| Permisos con roles reales: `banco_app` ejecuta exactamente **16**; las internas, nadie; lector ninguna | TCP | `reales/45_motor_conexiones.sh` |
| Atomicidad: fallo `tx:N` y corte **dentro** del devengo (nada medio escrito; reintento posterior devenga una sola vez); carreras: usuario borrado mientras la operación espera el reloj | TCP | `reales/45` |
| Concurrencia: N sesiones devengando a la vez (un solo juego de asientos); vista ∥ movimientos con devengo pendiente (lecturas consistentes); A→B ∥ B→A con devengos pendientes (sin deadlock); bloqueo de cuenta sostenido → la vista espera; CDT que vence ∥ transferencia del mismo cliente; cambio de reloj en vuelo | TCP | `reales/46_motor_concurrencia.sh` |
| Mutaciones ≈ **25** (M137…): quitar `_avanzar_hasta` en cada una de las 8; quitar el bloqueo; quitar/mover el `UPDATE ultimo_cobro`; saltarlo con saldo 0; un día de más/de menos; segunda instantánea; `now()`; CDT sin tope en `fecha_fin`; vencimiento sin `CERRADO` o sin `generado`; interés tras cerrar; `_bloquear_cuentas` en orden inverso (deadlock); guardia monotónica quitada; permiso de una interna concedido; `simular` con otra fórmula | mutaciones | `mutaciones.sh` |

Estimación: ≈ **160** aserciones nuevas, regresión completa (1930 + nuevas), `reset` + 3 × `apply`.

## 7. Decisiones

| ID | Decisión | Quién | Propuesta |
|---|---|---|---|
| **D-E7-1** | **Empezar E7 con D1 y D11 aún sin resolver**, usando valores provisionales centralizados (`_factor_interes`) y sin catálogo (las pruebas crean sus definiciones). Es la única forma de avanzar sin que BD decida finanzas por el equipo | BD aprueba proceder; equipo decide después | Proceder; todo rotulado PROVISIONAL |
| **D-E7-2** | Bolsillo: factor diario fijo en **forma cerrada**, un grupo `INTERES_BOLSO` por bolsillo y llamada (§3: es la única familia independiente de las consultas) | BD | Aprobar |
| **D-E7-3** | CDT por **objetivo acumulado**, tope en `fecha_fin`, cierre en la misma transacción | BD | Aprobar |
| **D-E7-4** | Editar E5 y E6 en los puntos marcados (§5) y el protocolo de bloqueo (§2.3) | **BD (tú)** | Aprobar |
| **D-E7-5** | `balance_total` provisional (D-E6-12/D6, equipo): el contrato dice «principal + bolsillos + **CDT activos** − capital pendiente». Con la composición actual, **crear un CDT haría bajar el total mostrado** (el dinero sale de la cuenta). Propuesta: sumar `monto + generado_acumulado` de CDT `ACTIVO` (coincide con la inversión del libro y con `vista_cdts`); la deuda de crédito sigue fuera hasta E8. Alternativa: solo `monto` | Equipo (D6); BD implementa provisional | Incluir CDT con `generado`, rotulado provisional |
| **D-E7-6** | Fecha de los asientos del motor: intereses hasta hoy = `ahora`; **cierre de CDT (y su último interés) = `fecha_fin` a las 00:00 Bogotá**, para que el historial muestre el vencimiento en su fecha aunque el cliente lo «descubra» después de saltar el reloj. Alternativa: todo a `ahora` (más simple, vencimientos fechados en el día de proceso) | BD / front (D8) | Fecha de vencimiento |
| **D-E7-7** | Visible al front (provisional, a avisar a Juan): `listar_cdt_definiciones`/`simular_cdt` reciben `p_usuario_id` (D10); `generado_mes` = 30 días; `vista_cdts` incluye cerrados con «Cerrado» (spec §7.5; el seed demo tiene uno); `crear_cdt` devuelve `{id, fecha}` | Equipo/Juan | Aprobar como provisional |
| **D-E7-8** | Guardia `ultimo_cobro` no retrocede (nuevo trigger; recomendado en E3) | BD | Aprobar |
| **D-E7-9** | **Límite aceptado, sin columna de arrastre:** el redondeo a centavos por asiento hace que un bolsillo de menos de ≈ $16 que se consulta a diario no devengue (0,003/día → 0,00) pero sí en una sola llamada de un mes. Corregirlo exigiría una columna `interes_pendiente` (esquema y libro) que no se justifica a esta escala; se documenta con ejemplo | BD | Aceptar y documentar |

## 8. Riesgos y límites
* `vista_balance` y `vista_cdts` **escriben** (primer GET del día por cliente); los GET paralelos del mismo cliente se serializan en el bloqueo de la cuenta; la salida rápida evita el bloqueo cuando no hay nada vencido. Cada una toma además la instantánea (FOR SHARE del reloj): el admin que cambia el reloj espera a las operaciones en vuelo, como en E5/E6.
* El motor asume `READ COMMITTED` (el libro ya lo exige: `FOR NO KEY UPDATE` fallaría con 40001 en otros niveles); el backend usa el valor por defecto.
* Un rechazo posterior en la misma operación (p. ej. `Saldo insuficiente`) revierte también el devengo recién hecho; la siguiente operación lo repite una sola vez (idempotente).
* Volver al reloj real tras adelantar deja `ultimo_cobro` «en el futuro»: no se devenga ni se recobra hasta que el calendario lo alcance; dinero movido en esa ventana no genera interés por esos días (límite de la simulación, ya documentado en E3 §14).
* Saldos cercanos al tope del dominio (10¹³): el interés se recorta para no desbordar (nunca un error no-`P0001`); caso de laboratorio, probado en una aserción.
* `admin_detalle_usuario`, `vista_dashboard`, `productos/solicitar_credito`, `abonar/pagar` (E8–E11) **deberán** estar en la lista *devenga*; el escaneo de E7 lo impone desde ahora.

## 9. Resumen para Juan (cuando se implemente)
`GET /bolsillos`, `GET /cdts` y los `POST` de dinero ahora pueden **escribir** (devengo lazy): sin cambios de contrato. Nuevas: `SELECT listar_cdt_definiciones($1)`, `simular_cdt($1, $2 /*definicion_id, texto*/, $3 /*monto TEXTO*/)`, `crear_cdt($1, $2, $3)`, `vista_cdts($1)`. Errores nuevos: solo `Monto por debajo del mínimo del CDT` (400). Mismas reglas que E5/E6: ids y monto como texto.

## 10. Plan (cuando apruebes)
`17_motor_devengo.sql` (internas + guardia) → `18_cdt.sql` (4 públicas + permisos) → edición de `15`/`16` en los puntos marcados + `09_integridad.sql` (lista blanca 12 → 16) → `54`, `55`, `56`, `reales/45`, `46` (+ adaptaciones de inventario y de las pruebas que fijaban el estado previo) → mutaciones → reset + 3 `apply` + suite completa → `07-motor-cdt.md` con evidencias y guía pgAdmin. Una sola entrega y parada para tu auditoría; sin commits y sin empezar E8.
