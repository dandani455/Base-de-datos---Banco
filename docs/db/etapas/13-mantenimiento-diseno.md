# Etapa 13 — Mantenimiento (`sp_avanzar_todos` y `sp_verificar_integridad`) · DISEÑO TÉCNICO v1 (compacto, para aprobación)

**Estado (2026-11-25): DISEÑO v1.1 APROBADO (D-E13-1 a D-E13-6 con 2 ajustes) e IMPLEMENTADO (ver `13-mantenimiento.md`, pendiente de auditoría).** E12 está aprobada y cerrada. Sin commits; `front/` y backend intactos; E14 no iniciada. *v1.1 = v1 + los 2 ajustes de la aprobación (§9).* **El backend de `origin/main` es un borrador temporal y no se usó como fuente de autoridad** (además, E13 no tiene ningún endpoint: nada que contrastar con él).

**Fuentes consultadas:** el diseño consolidado v3 (§D.4 *procedimientos*, §D.7 *concurrencia / `REPEATABLE READ READ ONLY` en la conciliación*, §E.5 rendimiento, §F.1 *hoja de ruta: E13 = «Mantenimiento: `sp_avanzar_todos`, `sp_verificar_integridad`», depende de E2*, §G *demostración académica*), `02-libro-mayor-diseno.md` §1 («`sp_verificar_integridad`: E13, **solo envolverá** las vistas `v_integridad_*`»), `01-esquema-diseno.md` («conciliación de E2/E13»), `03-reloj.md` §14 (política de demostraciones), `07/09` (motor y cobro automático), el contrato PDF, el spec y el plan (**no mencionan** procedimientos ni mantenimiento: es solo BD), `front/` (no los usa) y el código: `09_integridad.sql` (7 vistas), `17_motor_devengo.sql` (`_avanzar_hasta`), `11_reloj_funciones.sql` (`_reloj_instantanea`), `07_libro_mayor_funciones.sql` (`audit.evento`) y los inventarios de pruebas. **Experimento previo (BD temporal ya descartada):** con PostgreSQL 16, un procedimiento **con cláusula `SET`** o **`SECURITY DEFINER`** no puede hacer `COMMIT` (`invalid transaction termination`); uno sin ellas sí, incluso con un bloque `EXCEPTION` por iteración y un `COMMIT` después de cada bloque; dentro de `BEGIN … COMMIT` o en un `-c` con varias sentencias, el `COMMIT` del procedimiento falla.

## 1. Alcance

| Entra en E13 | No entra |
|---|---|
| **2 procedimientos** (`CALL`): `sp_avanzar_todos` (cierre de todas las cuentas, una transacción por cuenta) y `sp_verificar_integridad` (informe de todos los controles) + **1 interna** `_reglas_mantenimiento()` · script `db/sql/26_mantenimiento.sql` · sin tablas ni triggers · 1 evento de auditoría por corrida de `sp_avanzar_todos` | `sp_cargar_demo`, seed y rendimiento con +30 años (**E14**); programar la ejecución periódica (§5, equipo); cualquier cambio de `front/` o backend; ningún endpoint nuevo |

## 2. Qué dicen las fuentes y qué hallé

| Tema | Fuentes | Resolución |
|---|---|---|
| **Por qué procedimientos** | v3 §D.4/§G: «`CALL`; necesitan **control transaccional** que una función no tiene» (COMMIT por usuario) | `sp_avanzar_todos` sí lo necesita; `sp_verificar_integridad` es de solo lectura (lo es por cumplir la hoja de ruta y la demo académica `CALL …`). |
| **Restricción técnica descubierta** | v3 §D.2 pide que **toda** función lleve `SECURITY DEFINER` y `search_path` fijo; los inventarios (`03`, `10`) lo exigen a **todo** objeto de `pg_proc` | Un procedimiento que hace `COMMIT` **no puede** tener `SET` ni `SECURITY DEFINER` (verificado). Se compensa: `SECURITY INVOKER`, **sin permisos para nadie salvo el dueño/superusuario**, y `set_config('search_path', 'public, pg_temp', true)` **al inicio de CADA transacción** (la de captura de cuentas, cada cuenta y la final de auditoría: cada `COMMIT` descarta lo fijado con `set_config(…, true)`). Es una **excepción documentada** a la regla v3 (D-E13-2) y obliga a adaptar el inventario de `10` (§4). |
| **Qué cubre «I1, I5u, I5g»** | v3 §D.4 (de E1/E2); desde entonces se agregaron controles de reloj, autenticación (E4), planes de crédito (E8) y la lista blanca de `banco_app` (E4–E12) a las mismas vistas | Cubre **todo lo que ya mide `v_integridad_global`** (que agrega las 7 vistas), no solo I1/I5u/I5g: es la única forma de que el procedimiento y la vista no discrepen. |
| **Consistencia de la foto** | v3 §D.7: «`REPEATABLE READ READ ONLY` para la conciliación» | `SET TRANSACTION` dentro de un procedimiento ya con snapshot no es fiable; se logra lo mismo armando **todo el informe en UNA sola sentencia** (cada vista de E2 ya lo hace por diseño: «sin falsos positivos»). |
| **Quién lo ejecuta** | v3: «no los usa el backend» | Solo superusuario / dueño (conexión «administración (postgres)» de pgAdmin o `ctl.sh psql`): invocan internas sin `EXECUTE` para ningún rol. No se concede nada a `banco_app`, `banco_lector` ni `banco_dev` (la lista blanca de 40 no cambia). |
| **Relación con el visor (E12)** | E12/D-E12-4: el visor muestra lo **guardado**, no lo derivado | `sp_avanzar_todos` es justo lo que «pone al día» el estado guardado tras un salto de reloj, para que Control y pgAdmin lo muestren (P-DEMO de E3: respaldo → un adelanto → `CALL` → operar). |

## 3. Diseño

| Firma | Salida (`INOUT resultado jsonb`) | Detalle |
|---|---|---|
| `sp_avanzar_todos(INOUT resultado jsonb DEFAULT NULL)` | `{cuentas, procesadas, con_cambios, grupos, omitidas_por_timeout_de_bloqueo, con_error, errores:[{cuenta_id, mensaje}] (≤ 20), hoy_desde, hoy_hasta}` | Captura los ids de **todas** las cuentas al empezar (orden de id). **Por cada cuenta, en su propia transacción** (el `search_path` se fija también en la transacción de captura y en la final de auditoría): `set_config` de `search_path` y `lock_timeout` (2 s) locales → **una** `_reloj_instantanea()` → `_avanzar_hasta(cuenta, hoy, ahora)` (devenga, cobra y cierra; sale rápido sin trabajo) dentro de un bloque `EXCEPTION` → `COMMIT`. Un `55P03` (timeout de bloqueo: puede ser la **cuenta** —el cliente opera— o el **reloj** —el admin lo cambia—; **no se asume cuál**) = **omitida por timeout de bloqueo** (clave `omitidas_por_timeout_de_bloqueo`; su próxima operación o la próxima corrida la pone al día); cualquier otro error = **con_error** con su mensaje, **solo esa cuenta se revierte** y la corrida sigue. Al final: **un** evento `MANTENIMIENTO_AVANZAR` (entidad `banco`, `despues` = resumen sin la lista de errores, `actor_username` = `session_user`) y un `NOTICE` con el resumen (visible en la pestaña *Messages* de pgAdmin). Idempotente: repetir la corrida escribe 0 grupos. Cuentas creadas durante la corrida: no se tocan; borradas: no-op. |
| `sp_verificar_integridad(INOUT resultado jsonb DEFAULT NULL)` | `{ok, cuentas, patas, grupos, contenedores_con_desvio, grupos_con_error, cuentas_con_desvio_i5u, defensas_fallidas, desvio_transferencias, controles_auth_fallidos, creditos_con_plan_incoherente, cuentas_borradas, detalle:{saldos[], grupos[], usuario[], defensas[], auth[], creditos[]}}` | **Una sola sentencia** sobre las vistas `v_integridad_*`: los conteos son los de `v_integridad_global` y `detalle` trae **solo las filas defectuosas** (hasta 20 por control; `[]` si todo está bien). **No escribe nada ni audita.** Informa, no lanza error (quien automatice lee `resultado->>'ok'`). |
| `_reglas_mantenimiento()` (interna, `IMMUTABLE`) | `{lock_timeout: '2s', errores_max: 20, muestra_max: 20}` | Un solo lugar para lo provisional. |

**Permisos:** `EXECUTE` de los 2 procedimientos y de la interna **para nadie** (solo dueño / superusuario). **Esperado:** funciones **128 → 131** en `public` (2 procedimientos + 1 interna), lista blanca de `banco_app` **40 (sin cambio)**, 21 triggers, 11 tablas + `audit.evento`.

## 4. Integración, concurrencia y adaptaciones

* **Motor (E7–E9):** reutiliza `_avanzar_hasta` tal cual (misma regla «una instantánea por operación»: aquí una por **cuenta**, porque cada cuenta es una operación). No toca el libro por su cuenta: todo el dinero sigue saliendo de `_asentar_grupo`.
* **Concurrencia:** una cuenta a la vez; el mismo bloqueo `FOR NO KEY UPDATE` del libro; nunca toma dos cuentas → sin deadlocks. El `FOR SHARE` del reloj dura una transacción por cuenta (el admin puede cambiar el reloj entre cuentas: cada cuenta usa el `hoy` vigente en su turno; el resumen informa `hoy_desde`/`hoy_hasta`).
* **Resiliencia:** un corte de la conexión a la mitad deja **confirmado** todo lo ya procesado y **nada a medias** en la cuenta en curso (la siguiente corrida continúa).
* **No se puede llamar dentro de una transacción** (`BEGIN … CALL`, script de varias sentencias, modo transacción de pgAdmin): falla con `invalid transaction termination` (SQLSTATE `2D000`); se documenta cómo ejecutarlo (`CALL` solo, en autocommit).
* **Adaptaciones de inventario (solo números y filtros; ninguna prueba se elimina):** `03_schema` (131 funciones, +3 nombres), `10_libro_triggers` (**«todas las funciones tienen `search_path` fijo» pasa a excluir `prokind = 'p'`**, razón técnica arriba; 130 de `banco_owner`; el diseño v1 decía 129), `09_idempotencia` (reaplica `26`). Los controles de `banco_app`/`banco_lector` y `54` no cambian (los procedimientos no se conceden).

## 5. Decisiones

**Técnicas (las aprueba el responsable de BD):**

| ID | Decisión | Recomendación |
|---|---|---|
| **D-E13-1** | Alcance: 2 procedimientos + `_reglas_mantenimiento()` + `26_mantenimiento.sql`; sin tablas/triggers; `sp_cargar_demo` queda en E14. | Aprobar. |
| **D-E13-2** | `sp_avanzar_todos`: `SECURITY INVOKER` **sin** `SET` (obligatorio para poder hacer `COMMIT`), `search_path` por `set_config` local en cada transacción, una transacción y una instantánea **por cuenta**, bloque `EXCEPTION` por cuenta, `lock_timeout` 2 s (ocupada = omitida), resumen `INOUT jsonb` + `NOTICE`, ejecutable solo por dueño/superusuario, error claro dentro de una transacción. | Aprobar (excepción documentada a «todo `SECURITY DEFINER` con `search_path` fijo»). |
| **D-E13-3** | `sp_verificar_integridad`: solo lectura, **una sentencia**, `jsonb` con los conteos de `v_integridad_global` y hasta 20 filas defectuosas por control; **sin modo estricto** (no lanza error) y sin permisos para roles de acceso. | Aprobar (alternativa: concederlo a `banco_lector`/`banco_dev`; exigiría 3 adaptaciones más de inventario y no la pide la hoja de ruta). |
| **D-E13-4** | Auditoría: **1 evento por corrida** de `sp_avanzar_todos` (`MANTENIMIENTO_AVANZAR`, resumen, actor = `session_user`); `sp_verificar_integridad` no audita. | Aprobar. |
| **D-E13-5** | Selección: **todas** las cuentas (ids al empezar; el motor sale rápido si no hay nada); se descarta un filtro previo de «cuentas con trabajo» (duplicaría la regla de E7). | Aprobar. |
| **D-E13-6** | Adaptación de `10` (excluir procedimientos del chequeo de `search_path` fijo) y de `03`/`09_idempotencia`. | Aprobar. |

**Pendiente del equipo (no se decide aquí):** **D-E13-D1** — ¿se quiere ejecutar `sp_avanzar_todos` **periódicamente** (cron, `pg_cron`, tarea programada) o solo a mano para demostraciones? El proyecto no tiene planificador (Compose: `db` y `pgadmin`) y el motor perezoso no lo necesita para ser correcto; E13 deja el procedimiento listo y **no** agrega ningún programador. Valor provisional: **solo manual**.

## 6. Ambigüedades y contradicciones detectadas

(a) v3 §D.2 («toda función `SECURITY DEFINER` + `search_path` fijo») **contradice** el control transaccional de §D.4 (verificado: son incompatibles); (b) v3 §D.7 pide `REPEATABLE READ READ ONLY` y aquí se cumple el objetivo con una sola sentencia; (c) v3 §D.4 lista `sp_cargar_demo` entre los procedimientos pero §F.1 lo asigna a E14; (d) «I1, I5u, I5g» ya no describe el alcance real de las vistas (E3–E12 agregaron controles); (e) contrato, spec, plan y front **no** mencionan mantenimiento (nada que contrastar).

## 7. Plan de pruebas (solo riesgos nuevos; no se repiten E1–E12)

| Archivo | Riesgo que cubre | Aserciones ≈ |
|---|---|---|
| `72_mantenimiento.test.sql` (en una transacción con `ROLLBACK`, **solo** `sp_verificar_integridad`) | Informe = `v_integridad_global` (todas las columnas) con banco sano y `detalle` vacío; **cada control detecta su sabotaje** (saldo manipulado, grupo descuadrado, defensa caída, usuario sin cuenta, plan incoherente: `ok = false`, conteo y la fila en `detalle`); tope de 20 filas con 30 defectos (conteo real 30); **no escribe** (huella, auditoría); `sp_avanzar_todos` dentro de una transacción = `2D000` (documentado); catálogo (`prokind = 'p'`, `SECURITY INVOKER`, sin `proconfig`, con `COMMENT`, sin `EXECUTE` para nadie) | ≈ 25 |
| `reales/56_mantenimiento.sh` (psql real, `CALL` en autocommit) | **Equivalencia con la ruta perezosa:** dos clientes idénticos, uno al día con `sp_avanzar_todos` y el otro con `vista_dashboard`: mismos saldos, CDT y cuotas; corrida con trabajo pendiente (bolsillos, CDT que vence, cuota con descuento): resumen correcto; **idempotente** (la 2.ª corrida = 0 grupos) y **1 evento por corrida**; **un COMMIT por cuenta** (falla inyectada en una cuenta: solo esa queda sin cambios y se informa; **corte de la conexión** a la mitad: lo ya procesado queda confirmado y re-ejecutar termina); **cuenta ocupada** (otra sesión la tiene tomada > 2 s) = omitida sin detener la corrida; **concurrencia** con 4 sesiones transfiriendo (sin deadlocks, libro cuadrado, `sp_verificar_integridad` ok); `CALL` dentro de `BEGIN` falla; permisos (`banco_app`/`lector`/`dev` sin `EXECUTE` de las 3); con +300 cuentas la corrida termina en pocos segundos | ≈ 35 |

**Estimado: ≈ +60 aserciones; ≈ 20 mutaciones (M434…):** sin `COMMIT` por cuenta, sin bloque de excepción, sin `lock_timeout`, una sola instantánea para todas, motor omitido, conteos mal sumados, evento ausente, informe sin una vista / sin tope / `ok` mal calculado, `SECURITY DEFINER` o permisos concedidos, procedimiento que escribe. Regresión: las mutaciones de motor/permisos de E7–E12 que cambian por inventario.

## 8. Riesgos y límites

1. **No se puede ejecutar dentro de una transacción** (pgAdmin en modo transacción, scripts multisentencia): falla con un error claro; hay que llamarlo solo.
2. **Excepción a «`SECURITY DEFINER` + `search_path` fijo»:** el procedimiento corre con los privilegios de quien lo llama (solo superusuario/dueño) y fija `search_path` por `set_config`; no hay forma de cumplir ambas reglas y poder hacer `COMMIT`.
3. Una corrida sobre muchas cuentas dura lo que dure el trabajo pendiente (el resto sale rápido); bloquea una cuenta a la vez y puede dejar cuentas «omitidas» si sus dueños están operando (se ponen al día en su próxima operación).
4. Cambia el estado **guardado** de muchas cuentas de golpe (intereses, cierres, cobros automáticos): es su propósito, pero conviene hacer un respaldo antes de una demostración (política P-DEMO de E3).
5. Con el reloj en modo manual usa el hoy simulado; no corrige nada si el reloj no avanzó.

## 9. Cambios de la v1.1 (ajustes de la aprobación) y un hallazgo de la implementación

1. **`search_path` en CADA transacción:** `sp_avanzar_todos` lo fija al empezar la transacción de **captura de cuentas**, al empezar **cada cuenta** y en la transacción **final de auditoría** (cada `COMMIT` descarta lo local). Se prueba **estáticamente** el orden de las instrucciones (`S C F S R A C E S C` en `72`/C5) y con 3 mutaciones (una por cada punto).
2. **`55P03` = omisión por timeout de bloqueo:** la clave del resumen es `omitidas_por_timeout_de_bloqueo` (antes «ocupada»); se prueba con una **cuenta** tomada por otra sesión **y** con el **reloj** tomado (el mismo código de error por dos causas distintas).
3. **Hallazgo:** `sp_verificar_integridad` **sí puede llamarse dentro de una transacción** del llamador y su `set_config(…, true)` **duraría hasta el fin de esa transacción** (la propia suite lo detectó: los helpers dejaron de resolverse). Ahora **restaura el `search_path` del llamador** al terminar (mutación M455 y prueba `72`/A3b).