# Etapa 3 — Reloj bancario · DISEÑO TÉCNICO (para aprobación)

> **ACTUALIZACIÓN — DISEÑO APROBADO (2026-11-21).** El responsable de BD aprobó este diseño con **D4 = opción A (definitiva)**: el reloj manual **solo adelanta**; **volver a fecha real está siempre permitido** y deja `fecha_sistema = NULL`. **No existe `desfase_dias`** ni reloj continuo con desfase (la opción C de este documento queda **descartada**; no se implementa ningún desfase). Decisiones D-E3-1 a D-E3-9 aprobadas (con D-E3-6 `Fecha inválida` **provisional** hasta que el equipo resuelva D13) y con las consecuencias funcionales documentadas en [03-reloj.md](03-reloj.md), que es el **documento de entrega vigente**. Donde este texto describe la opción C, `desfase_dias`, `trg_reloj_unico` o `v_integridad_global.patas_con_fecha_futura`, léase como **histórico**: lo implementado difiere en esos puntos y está descrito en `03-reloj.md` (sección "Desviaciones respecto del diseño").

> **ACLARACIÓN FUNCIONAL — D4 tiene ahora dos capas bien diferenciadas (2026-11-23).** **(1) D4 = mecánica del reloj** (lo de este documento: opción A; garantía técnica de la BD; sin cambios). **(2) D4-P = política de demostraciones**, una capa de **uso** aclarada por el responsable de BD tras hablar con el equipo: el adelanto temporal **no** es para que los clientes simulen sus finanzas, sino para que **administradores y desarrolladores demuestren al profesor** cómo se comporta el banco tras cierto tiempo. Flujo: preparar BD → respaldo → **un único adelanto** → operar → (opcional) volver a real con todo intacto → **restaurar el respaldo** para repetir. Restricción: **solo un adelanto por demostración** (ni siquiera una fecha posterior a la anterior), y **volver a real siempre se permite**. La mecánica de A **sigue permitiendo** varios adelantos hacia adelante; limitarlos a uno es una **política**, no una garantía de la BD. El análisis de si hace falta un mecanismo adicional (y las alternativas, con recomendación de **no añadir ninguno ahora**) está en [03-reloj.md §14](03-reloj.md). Donde este documento habla de «simular» o de «volver a fecha real tras adelantar», léase en el sentido de la demostración. No cambia ningún script, prueba ni decisión técnica de E3.

**Estado original del documento:** propuesta previa a la aprobación (laboratorio desechable `e3_lab`, ya eliminado, para validar suposiciones). Sin commits. No se toca `front/`, backend ni archivos de otros integrantes. No se decide nada financiero pendiente.

Parte de: diseño consolidado v3 (C.7 y D4), [E1](01-esquema.md), [E2](02-libro-mayor.md) y tus consideraciones (todo lo que escribe el libro pasa por `_asentar_grupo`; las limitaciones del superusuario siguen documentadas).

---

## 0. Resumen en una página

E3 da al banco **una sola noción de "hoy"**: `hoy_banco()` (fecha) y `ahora_banco()` (instante), de las que dependerán todos los intereses, vencimientos, cuotas y fechas de las patas del libro. Incluye el trigger que impone *"el reloj nunca retrocede"* y el contrato `GET/PUT /admin/reloj`.

1. **La pieza difícil no es técnica sino de significado (D4):** ¿qué pasa si el admin adelanta el reloj a 21-dic y luego marca "usar fecha real" el 21-nov? El spec dice a la vez *"nunca retrocede"* (§3, §6) y *"volver a fecha real está permitido"* (§15.10). Presento cuatro opciones con el mismo caso de ejemplo y recomiendo la **C (reloj continuo con desfase)**. **No la implemento sin decisión del equipo.**
2. **Diseño técnico (con la opción C):** una columna nueva (`reloj.desfase_dias`), 2 funciones públicas de lectura (`hoy_banco`, `ahora_banco`), una instantánea por operación que bloquea el reloj (`FOR SHARE`) para que una operación vea **una sola fecha** y el admin no cambie el reloj a mitad, y tres triggers (`BEFORE UPDATE` con la máquina de estados, auditoría y protección del registro único).
3. **Respeta el contrato del front:** `GET → { usar_fecha_real, fecha_sistema | null, fecha_actual = hoy_banco() }`, `PUT { usar_fecha_real, fecha_sistema }` (ignora la fecha en modo real) y el mensaje exacto **`El reloj no puede retroceder`** (P0001).
4. **Integración con E2:** el libro empieza a validar `fecha` contra el reloj (nunca posterior a `ahora_banco()`), sin romper el seed ni el cobro lazy (las fechas **pasadas** siguen permitidas).
5. **Pruebas:** funciones puras con instantes inyectados (medianoche de Bogotá, zonas de sesión distintas), matriz completa de transiciones, "viaje en el tiempo" controlado, concurrencia real y mutaciones. **Necesito 9 decisiones** (sección 11), la más importante D4.

---

## 1. Alcance

| Entra en E3 | No entra (su etapa) |
|---|---|
| `hoy_banco()`, `ahora_banco()`, helpers puros e instantánea del reloj | `avanzar_hasta` y el cálculo de intereses/vencimientos/cuotas: **E7–E9** (D1, D7) |
| Trigger de no retroceso y máquina de estados real/manual | `admin_leer_reloj` / `admin_set_reloj` (envoltorios con validación de ADMIN): **E11**; aquí solo las **primitivas internas** que ellos usarán |
| `reloj.desfase_dias`, rango de fechas, permisos por columna | Autenticación y `_validar_admin`: E4/E11 |
| Regla del libro: `fecha` ≤ `ahora_banco()` | Seed con el reloj en el pasado: E14 (esta etapa solo deja lista la **cláusula de banco vacío**, aprobada en D5) |
| Auditoría de cada cambio del reloj, controles de integridad | Cualquier cambio en `front/` (el mock del front dice `El reloj solo puede adelantarse`: está desactualizado frente al contrato; es del equipo de front) |

---

## 2. Requisitos y fuentes

| Fuente | Qué exige |
|---|---|
| Spec §6 | `usar_fecha_real=true` → "hoy" real; `=false` → "hoy" es `fecha_sistema`, que el admin solo **avanza**; un **trigger** rechaza retrocesos con error. Todas las fechas de negocio salen del reloj, **nunca de `NOW()`** |
| Spec §7 (admin) | Toggle real/manual; apagado → elegir fecha; **solo adelantar** |
| Spec §15.10 | *"Volver a fecha real tras adelantar el reloj: permitido y sin corromper nada"* (el `ultimo_cobro` evita recargar intereses) y *"el reloj del banco no retrocede dentro del modo manual"* |
| Contrato 18-nov §3.6 | `GET /admin/reloj` → `{ usar_fecha_real: bool, fecha_sistema: "YYYY-MM-DD" \| null, fecha_actual: "YYYY-MM-DD" }`; `fecha_actual = hoy_banco()` es el **mínimo** del selector; `PUT` recibe `{ usar_fecha_real, fecha_sistema }` (el front manda la fecha **aunque** `usar_fecha_real` sea `true`: ignorarla); retroceder → `El reloj no puede retroceder` (P0001) |
| Contrato §1 | Fechas de negocio de `hoy_banco()/ahora_banco()`; instantes en ISO 8601 con zona (`…-05:00`); campos solo-fecha `YYYY-MM-DD` |
| Contrato §4 / checklist | Plazo de 360 cuotas con el reloj +30 años en < 5 s (para E7–E9: el reloj debe poder saltar décadas) |
| D5 (ya aprobada) | El seed arranca con el reloj ~120 días en el pasado **mientras el banco está vacío**, y luego avanza con funciones reales |
| `front/src/pages/admin/Reloj.tsx` | Muestra `fecha_actual`, deshabilita el selector con "usar fecha real", `min = fecha_actual`, **envía siempre** `fecha_sistema` (puede ser `''` si el valor guardado era `null`) |

**Lo que ya existe (E1/E2):** `reloj(id=1, usar_fecha_real, fecha_sistema)` con `ck_reloj_fila_unica` y `ck_reloj_fecha_si_manual`, una fila sembrada en modo real; `banco_lector` la lee, `banco_app` no; el propietario tiene todos los privilegios. E2: el libro guarda `fecha` (negocio) y `registrado_en` (real), y **no** valida `fecha` contra el reloj.

---

## 3. Validación técnica previa (laboratorio `e3_lab`, ya eliminado)

| # | Suposición | Resultado | Consecuencia |
|---|---|---|---|
| L1 | Una función pura `fecha de Bogotá = (instante AT TIME ZONE 'America/Bogota')::date` da la misma respuesta con `TimeZone` de sesión en UTC o `Asia/Tokyo`; la medianoche de Bogotá (05:00 UTC) cambia el día exactamente ahí (`2026-12-31 23:59:59-05` → 31-dic; `2027-01-01 00:00:01-05` → 1-ene; `04:59:59+00` → 31-dic; `05:00:00+00` → 1-ene) | ✅ | La zona se fija **por código** (`'America/Bogota'`), no por la configuración de la sesión ni de la BD |
| L2 | En manual, `ahora = (fecha_sistema + hora_de_Bogotá) AT TIME ZONE 'America/Bogota'` conserva la hora local (`2026-12-21 14:30 -05`) | ✅ | Base de `ahora_banco()` en modo manual (D-E3-1) |
| L3 | Un trigger `BEFORE UPDATE` puede **fijar** `NEW.desfase_dias` aunque el `UPDATE` no lo mencione y aunque el dueño **no tenga** `UPDATE` sobre esa columna; el dueño que intenta `SET desfase_dias = 99` recibe *permission denied* | ✅ | Nadie (ni el dueño) puede fijar el desfase a mano: solo lo calcula el trigger |
| L4 | Con `UPDATE` solo por columna, el dueño **sí** puede `SELECT … FOR SHARE` sobre `reloj` | ✅ | La instantánea con bloqueo compartido es viable sin dar `UPDATE` de tabla |
| L5 | `banco_app` sin privilegios no puede leer `reloj` | ✅ | Se mantiene |

Además se sabe de E2: `now()` es constante dentro de una transacción (una función `STABLE` basada en él ve **un solo instante** por transacción), que los triggers de una tabla de **fila única** son baratos y que un trigger diferido corre con el usuario de la sesión (no aplica aquí: todo es `BEFORE`).

---

## 4. D4 — qué significa "nunca retrocede" (decisión del equipo)

Caso: hoy real = **21-nov**. El admin adelanta el reloj a **21-dic** (manual). Luego marca **"usar fecha real"**. ¿Qué es `hoy_banco()` en ese momento y después?

| Opción | `hoy_banco()` tras volver a "real" el 21-nov | 22-nov (al día siguiente) | Cumple *"nunca retrocede"* | Cumple *"volver a real permitido"* | Costo |
|---|---|---|---|---|---|
| **O1 — literal §15.10** | **21-nov** (salta 30 días atrás) | 22-nov | ❌ solo vale dentro del modo manual | ✅ | Hay que blindar cada función de cobro contra `hoy < ultimo_cobro` (no hacer nada) y el historial queda con fechas fuera de orden; contradice el titular de §3/§6 y el contrato |
| **A — rechazar** | PUT rechazado: `El reloj no puede retroceder` | idem | ✅ | ❌ (no se puede volver a real hasta que el calendario alcance 21-dic) | Simple y honesto; el admin queda en manual 30 días; no hay "volver a real" en la práctica |
| **B — `GREATEST(real, tope)`** | **21-dic congelado** | 21-dic (sigue congelado) | ✅ | ✅ (permitido, pero el banco queda parado) | Intereses y cuotas se detienen hasta que el calendario alcance 21-dic: parece un fallo |
| **C — reloj continuo con desfase (recomendada)** | **21-dic**, y sigue corriendo | **22-dic** | ✅ | ✅ | El "hoy" del banco queda **adelantado** respecto al calendario (+30 días) hasta reiniciar la BD; `fecha_actual` ≠ fecha real tras una prueba |

**Recomendación: C.** Es la única que cumple a la vez las dos frases del spec **y** no deja el banco parado (B) ni atrapado (A). El precio es que "usar fecha real" significa "seguir el calendario **desde este punto**": se documenta en el front/README y en el comentario de la función. Si el equipo prefiere minimizar el cambio de significado, la segunda opción es **A** (la regla más fácil de explicar).

**Qué cambia entre opciones (para que la decisión sea barata):** el esquema es el mismo salvo una columna (`desfase_dias` en C; `fecha_tope` en B; ninguna en A/O1); `hoy_banco()` y la máquina de estados del trigger (sección 6.3) son lo único que difiere. Las demás piezas (instantánea, auditoría, permisos, regla del libro, pruebas) son idénticas. **El resto del documento describe la opción C**; las variantes A y B están indicadas donde difieren.

**Fuera de la decisión:** la **cláusula de banco vacío** (D5, ya aprobada) se aplica a las cuatro: mientras `transaccion` no tenga ninguna pata, el reloj **puede** moverse en cualquier dirección (así el seed arranca ~120 días atrás con funciones reales y luego avanza). En cuanto exista una pata, rige la opción elegida.

---

## 5. Modelo de datos (script `10_reloj_estructura.sql`)

| Cambio | Detalle |
|---|---|
| `reloj.desfase_dias integer NOT NULL DEFAULT 0` + `CHECK (desfase_dias >= 0)` | Solo la opción C. Días que el "hoy" del banco **adelanta** al calendario en modo real. Lo calcula el trigger; nadie lo escribe |
| `CHECK ck_reloj_fecha_rango` | `fecha_sistema IS NULL OR fecha_sistema BETWEEN DATE '2000-01-01' AND DATE '2100-12-31'` — evita fechas absurdas (año 275 760) que romperían `date + integer`; cubre de sobra "+30 años" |
| Permisos | `banco_owner` pierde `UPDATE` de tabla sobre `reloj` y recibe `UPDATE (usar_fecha_real, fecha_sistema)` (mismo patrón que E2; L3/L4). `desfase_dias` no se puede tocar. `banco_lector` mantiene `SELECT`; `banco_app` sigue sin nada. El propietario conserva `INSERT/DELETE/TRUNCATE` por el catálogo, pero los triggers los rechazan |
| Comentarios | `COMMENT` en la columna nueva y en la tabla (semántica de "usar fecha real" bajo C) |

No se agregan tablas (siguen 11 + `audit.evento`). `03_schema.sql` no se toca.

---

## 6. Objetos que se crean

Numeración: E2 usó `06–09`; E3 usa `10–12`.

| Script | Contenido |
|---|---|
| `10_reloj_estructura.sql` | Columna, CHECKs, permisos |
| `11_reloj_funciones.sql` | Funciones del reloj |
| `12_reloj_triggers.sql` | Triggers y controles de defensa (amplía `v_integridad_defensas` y `v_integridad_global` en `09_integridad.sql`) |

### 6.1 Funciones

| Función | Visibilidad | Rol |
|---|---|---|
| `_ahora_real()` | interna | Envoltorio de `now()` (instante de transacción). Existe **para poder inyectar tiempo en las pruebas** (el harness de `banco_test` la reemplaza; en producción es `now()`; **no** hay variable de sesión que falsee la hora) |
| `_hoy_de(usar boolean, fecha date, desfase int, p_instante timestamptz) → date` | interna, `IMMUTABLE` | **Pura:** `usar ? (p_instante AT TIME ZONE 'America/Bogota')::date + desfase : fecha`. Donde está toda la aritmética |
| `_ahora_de(usar, fecha, desfase, p_instante) → timestamptz` | interna, `IMMUTABLE` | **Pura:** real → `p_instante + desfase días`; manual → `(fecha + hora de Bogotá de p_instante) AT TIME ZONE 'America/Bogota'` (D-E3-1) |
| `hoy_banco() → date` | pública de lectura, `STABLE`, `SECURITY DEFINER` | `_hoy_de(` fila de `reloj` `, _ahora_real())` |
| `ahora_banco() → timestamptz` | ídem | `_ahora_de(…)` |
| `_reloj_instantanea() → (hoy date, ahora timestamptz)` | interna, `SECURITY DEFINER` (dueño) | **Toda operación de negocio la llama primero.** Lee la fila con `SELECT … FOR SHARE` (bloqueo compartido hasta el COMMIT): el reloj no puede cambiar a mitad de la operación y el admin espera a que terminen las operaciones en vuelo. Devuelve el par que la operación usará **todo el tiempo** |
| `_reloj_actualizar(p_usar boolean, p_fecha text) → jsonb` | interna, `SECURITY DEFINER` | Primitiva del admin (E11 la envolverá con `_validar_admin`): valida el texto (acepta `''`/`NULL` si `p_usar` es `true`; si no, `Fecha inválida` P0001), hace el `UPDATE` (el trigger decide) y devuelve la vista del contrato |
| `_reloj_vista() → jsonb` | interna, `STABLE` | `{ usar_fecha_real, fecha_sistema (null si es real), fecha_actual (texto YYYY-MM-DD) }` exactamente como el contrato |

`hoy_banco()` y `ahora_banco()` llevan `search_path` fijo y `COMMENT`. **`EXECUTE`:** `banco_lector` y `banco_dev` (inspección desde pgAdmin); **no** `banco_app` ni `PUBLIC` (el backend no las llama: recibe la fecha dentro de las vistas del contrato). Las demás: sin `EXECUTE` para nadie salvo el dueño (como en E2).

### 6.2 Por qué la instantánea con `FOR SHARE`

Sin ella, una operación larga (p. ej. un salto de reloj de 30 años con 360 cuotas) podría leer `hoy_banco()` varias veces y obtener valores distintos si el admin cambia el reloj entre lecturas (en `READ COMMITTED` cada sentencia ve lo último confirmado). Con `FOR SHARE`: **todas las operaciones concurrentes comparten el bloqueo** (no se estorban), el `UPDATE` del admin espera a que terminen las que ya empezaron y las nuevas esperan el `UPDATE` (milisegundos). Es el mismo patrón que el bloqueo raíz de cuentas de E2 y no puede producir *deadlock* (una sola fila, un solo orden). Alternativa más simple (D-E3-4): que cada función llame `hoy_banco()` una vez al inicio; no impide el cambio concurrente pero lo hace inocuo (los cobros son idempotentes por `ultimo_cobro`).

### 6.3 Triggers (script `12_reloj_triggers.sql`)

| Trigger | Momento | Hace |
|---|---|---|
| `trg_reloj_a_validar` | `BEFORE UPDATE`, por fila | **Máquina de estados** (tabla siguiente), sin importar quién ejecuta (también el superusuario): fija `NEW.desfase_dias` y rechaza retrocesos con `El reloj no puede retroceder` |
| `trg_reloj_auditar` | `AFTER UPDATE`, por fila | Inserta en `audit.evento` la acción `RELOJ_CAMBIO` con `antes`/`despues` (`usar_fecha_real`, `fecha_sistema`, `desfase_dias`, `hoy_banco` antes y después) y el actor de `banco.actor` (solo atribución) |
| `trg_reloj_unico` | `BEFORE INSERT OR DELETE` por fila y `BEFORE TRUNCATE` | El registro único no se crea de nuevo, no se borra y no se vacía (el `CHECK id=1` ya impide una 2.ª fila; esto cierra DELETE/TRUNCATE) |

**Máquina de estados de `trg_reloj_a_validar` (opción C).** `H_old = hoy_banco` con la fila anterior; `R = fecha real de Bogotá (_ahora_real())`; "banco vacío" = no existe ninguna fila en `transaccion`.

| De → a | Condición | Efecto |
|---|---|---|
| real → real | sin cambios | permitido y **idempotente** (el front manda `fecha_sistema` aunque sea real: se ignora; `NEW` conserva los valores anteriores) |
| real → manual(F) | `F ≥ H_old` | `fecha_sistema := F`; `desfase_dias` queda (no se usa en manual) |
| manual(F) → manual(F2) | `F2 ≥ F` | `fecha_sistema := F2` (F2 = F es un no-op permitido) |
| manual(F) → real | siempre | `desfase_dias := GREATEST(0, F − R)`; así `H_new = max(R, F) ≥ F` (el reloj **sigue corriendo desde F**) |
| cualquiera → una fecha menor que `H_old` | y el banco **no** está vacío | **`El reloj no puede retroceder`** (P0001) |
| cualquiera → cualquiera | banco **vacío** | permitido; si el destino es "real", `desfase_dias := 0` |
| manual sin `fecha_sistema` | — | ya lo impide `ck_reloj_fecha_si_manual`; el helper lo convierte antes en `Fecha inválida` |

*Variante A:* manual → real solo si `R ≥ F` (si no, el mismo error); sin `desfase_dias`. *Variante B:* en lugar de `desfase_dias`, una columna `fecha_tope` que guarda el máximo alcanzado y `hoy = GREATEST(R, fecha_tope)`.

### 6.4 Integración con el libro (modifica `07_libro_mayor_funciones.sql` en su sitio — D-E3-3)

`trg_transaccion_a_validar` agrega una regla: **la `fecha` de una pata no puede ser posterior a `ahora_banco()`** (`Libro mayor: la fecha de la pata es posterior al reloj del banco`). Las fechas **pasadas se aceptan** (el cobro lazy genera patas de días anteriores y el seed arranca en el pasado). Como las funciones de negocio fechan con la instantánea del reloj, nunca chocan con la regla; protege contra una función defectuosa que use `now()` con el reloj atrasado respecto al calendario (o fechas futuras por error). Efecto en E2: las pruebas existentes usan `now()` real con el reloj en modo real sin desfase ⇒ la regla no las afecta; las que fijan fechas futuras a propósito se adaptan.

### 6.5 Integridad y defensas

* `v_integridad_defensas`: + los 3 triggers del reloj (existen, habilitados), los permisos del dueño sobre `reloj` (sin `UPDATE` de tabla ni de `desfase_dias`), `EXECUTE` de `hoy_banco/ahora_banco` (solo lector/dev), el trigger de la regla del libro ya está cubierto.
* `v_integridad_global`: + `patas_con_fecha_futura` (debe ser 0) y `reloj_ok` (la fila única existe y `hoy_banco() ≥` la fecha de la última pata con fecha ≤ ahora; solo informativo).

---

## 7. Contrato del front → funciones

| Endpoint | Función (E11 la envuelve con `_validar_admin`) | Notas |
|---|---|---|
| `GET /admin/reloj` | `_reloj_vista()` → `{ usar_fecha_real, fecha_sistema: null \| "YYYY-MM-DD", fecha_actual: "YYYY-MM-DD" }` | `fecha_sistema` es `null` en modo real (contrato); los 3 campos y tipos son los de `types.ts`. `desfase_dias` **no** se expone (el contrato admite campos extra, pero no hace falta) |
| `PUT /admin/reloj` | `_reloj_actualizar(p_usar, p_fecha text)` → devuelve la misma vista | La fecha llega como **texto** a propósito: el front manda `''` en modo real y un `date` fallaría en el *driver* con un error no-P0001 (el backend lo vería como 503). Mensajes: `El reloj no puede retroceder` (contrato) y `Fecha inválida` (nuevo, D13) |
| fechas del resto de endpoints | `hoy_banco()` / `ahora_banco()` (vía `_reloj_instantanea()`) | Instantes con zona `-05:00` (la zona de sesión del backend no cambia el valor: L1) |

---

## 8. Concurrencia y atomicidad

* **Operación de negocio ∥ cambio de reloj:** instantánea con `FOR SHARE` (6.2). Pruebas con sesiones reales: una operación larga sostiene el bloqueo y el `PUT` espera; después de confirmar, la siguiente operación ve el reloj nuevo; nunca una operación ve dos fechas.
* **Dos cambios de reloj simultáneos:** se serializan por el bloqueo de fila del `UPDATE`; la máquina de estados evalúa el segundo contra el estado ya confirmado del primero (`READ COMMITTED`, la fila se relee tras el bloqueo).
* **`lock_timeout` de `banco_app` (3 s):** el `FOR SHARE` espera como máximo lo que dure un `UPDATE` del reloj (milisegundos); si algún día expira, la función de negocio lo convertirá a `P0001` (patrón ya fijado para E5+).
* **Atomicidad:** el `UPDATE` del reloj, su validación y su auditoría son una sola transacción; si algo falla (retroceso, fecha inválida) no cambia nada ni queda evento.

## 9. Seguridad

* Nadie fija `desfase_dias` (privilegio + trigger); ninguna función pública de escritura sin ADMIN (E11); el reloj no se puede borrar ni vaciar.
* El trigger rige también para el superusuario por **datos** (no puede dejar el reloj retrocedido sin desactivar el trigger); desactivarlo es DDL: lo audita el event trigger de E2 (`ALTER TABLE reloj` **se agrega** a la lista de tablas protegidas) y lo detecta `v_integridad_defensas`. **Límite honesto (igual que en E2):** un superusuario puede desactivar triggers o usar `session_replication_role = replica`; las vistas y la auditoría **detectan**, no protegen de forma absoluta. Además el reloj depende de la hora del **servidor** (y de su NTP): un salto hacia atrás del reloj del sistema no lo vigila PostgreSQL.
* `banco_app` no lee `reloj` ni ejecuta `hoy_banco()`; `banco_lector`/`banco_dev` sí (solo lectura).

## 10. Estrategia de pruebas

| Archivo (nuevo) | Qué prueba | Aserciones aprox. |
|---|---|---|
| `30_reloj_funciones` | `_hoy_de/_ahora_de` con instantes inyectados: medianoche de Bogotá (31-dic/1-ene), sesiones en UTC/Tokyo/Los Ángeles, 29-feb, +30 años, desfase; `hoy_banco/ahora_banco` coinciden con la fecha real de Bogotá en modo real; manual conserva la hora local; `_reloj_vista` con la forma exacta del contrato (`assert_json_shape`, `fecha_sistema` null en real) | 30 |
| `31_reloj_trigger` | **Matriz completa de transiciones** (real↔manual × mayor/igual/menor) con el mensaje exacto; el caso 21-nov/21-dic/vuelta a real de cada opción; `desfase` recalculado; real→real idempotente con `fecha_sistema` basura; fechas fuera de rango; DELETE/TRUNCATE/INSERT rechazados; intentos del dueño/superusuario/app/lector/dev | 45 |
| `32_reloj_banco_vacio` | La cláusula de banco vacío: retroceso permitido sin patas, rechazado al existir **una** pata, y de nuevo permitido tras borrar la cuenta (cascada) | 12 |
| `33_reloj_libro` | La regla `fecha ≤ ahora_banco()` (pasado ok, igual ok, futuro rechazado, con reloj adelantado pasa y al volver a "real" con desfase sigue pasando); adaptación de las pruebas de E2 | 20 |
| `34_reloj_viaje_en_el_tiempo` | Con `_ahora_real()` sustituido (solo en `banco_test`): simulación de miles de secuencias aleatorias de cambios y de paso del tiempo; invariante **`hoy_banco` jamás disminuye** salvo banco vacío; y que el reloj real sin tocar sigue la fecha de Bogotá | 8 |
| **Conexiones reales** `reales/37` | `banco_app` no lee `reloj` ni ejecuta `hoy_banco()`; `banco_lector` y `banco_dev` sí; ni el dueño puede escribir `desfase_dias` (por una función definer de prueba) | 15 |
| **Concurrencia** `reales/38` | Operación larga con `FOR SHARE` ∥ `PUT` del admin (espera, luego pasa); 200 cambios de reloj concurrentes monótonos (sin retrocesos aceptados); el reloj no cambia entre dos lecturas de una misma operación | 8 |
| **Mutación** | ≥ 10 mutaciones (quitar el trigger, permitir retroceso, fijar `desfase` a mano, quitar el rango, quitar la regla del libro, `EXECUTE` a `banco_app`, ignorar la cláusula…) | 10 |
| **Adaptación de E1/E2** | `03` (funciones/triggers/columnas esperadas), `08` (permisos de `reloj`), `10`, `16` (controles nuevos de defensas) y la huella | — |

Total estimado: **≈ 150 aserciones nuevas** (sobre las 836). El script `29_integridad_final.sh` se renombra **`99_integridad_final.sh`** para que siga siendo el último (D-E3-9). Evidencias: `02`-style (`03-reloj.txt`, mutaciones, aplicación desde cero + 3 aplicaciones) y guía de verificación en pgAdmin (consultas con `_ahora_real()` real: cambiar el reloj en una transacción de prueba con `ROLLBACK`, ver el rechazo del retroceso, `v_integridad_*`).

---

## 11. Decisiones que necesito

| ID | Decisión | Quién | Recomendación |
|---|---|---|---|
| **D4** | Semántica de "nunca retrocede" y "volver a fecha real" (sección 4) | **Equipo** (spec §15.10; Daniel García + todos) | **C** (reloj continuo con desfase). Alternativa conservadora: **A** |
| **D-E3-1** | Hora de `ahora_banco()` en modo manual | Tú | **Fecha manual + hora real de Bogotá** (el día "avanza" a medianoche real; la hora puede "dar la vuelta" y por eso el historial se ordena por `orden`, no por fecha). Alternativa: 00:00 fijo |
| **D-E3-2** | Definición de "banco vacío" para la cláusula de D5 | Tú (ya aprobada) | **Ninguna fila en `transaccion`** (en cuanto se registra un cliente hay patas) |
| **D-E3-3** | Regla del libro `fecha ≤ ahora_banco()` modificando `07` en su sitio | Tú | **Sí** (pasado permitido; futuro rechazado) |
| **D-E3-4** | Instantánea con `FOR SHARE` (6.2) vs. cada función lee `hoy_banco()` una vez | Tú | **`FOR SHARE`** (todas las operaciones ven una sola fecha y el admin no cambia el reloj a mitad) |
| **D-E3-5** | Alcance: E3 entrega las **primitivas internas** y E11 los `admin_*`; o incluir ya `admin_leer_reloj/admin_set_reloj` | Tú | **E11** (necesitan `_validar_admin`) |
| **D-E3-6** | Mensajes: `El reloj no puede retroceder` (contrato) y `Fecha inválida` (nuevo) | Front + equipo (D13) | Aprobar `Fecha inválida` (ya lo usa el mock) |
| **D-E3-7** | `EXECUTE` de `hoy_banco/ahora_banco` solo para `banco_lector`/`banco_dev`; `banco_app` no | Tú | **Sí** |
| **D-E3-8** | Rango de `fecha_sistema` `2000-01-01…2100-12-31` (CHECK) y auditar cada cambio (`RELOJ_CAMBIO`) | Tú | **Sí** |
| **D-E3-9** | Renombrar `29_integridad_final.sh` → `99_integridad_final.sh` y sustituir `_ahora_real()` solo en `banco_test` para las pruebas de tiempo | Tú | **Sí** |

## 12. Riesgos y límites

1. **D4 sin decidir bloquea E3** (y condiciona E7: los cobros asumen `hoy ≥ ultimo_cobro`; bajo O1 habría que blindarlos).
2. Bajo **C** el "hoy" del banco queda adelantado respecto al calendario tras una prueba con el reloj; solo `reset`/recrear la BD lo restablece. Hay que decírselo al equipo y reflejarlo en la documentación del front.
3. El reloj depende de la hora del servidor/Docker; no se protege de un salto del sistema operativo. `now()` es estable por transacción (efecto deseado) pero una transacción de horas verá la fecha de su inicio.
4. El superusuario puede saltarse el trigger (límite documentado; auditoría y vistas lo detectan).
5. La regla del libro (D-E3-3) obliga a las funciones de negocio a usar la instantánea del reloj, no `now()` (ya era la norma del spec).
6. El mock del front (`El reloj solo puede adelantarse`, sin `null` en `fecha_sistema` cuando es real) no coincide con el contrato: es del equipo de front; E3 sigue el **contrato**.

## 13. Plan de ejecución (cuando apruebes)

E3.1 estructura y permisos (10) → E3.2 funciones puras, instantánea y vista (11) → E3.3 triggers y auditoría (12) → E3.4 regla del libro y controles de integridad → E3.5 pruebas SQL (30–34) y adaptación de E1/E2 → E3.6 conexiones reales y concurrencia → E3.7 mutación, documentación, evidencias y guía de pgAdmin. Una sola entrega al final (reset + 3 `apply`, suite completa en verde) y **parada para tu revisión**, sin commits y sin empezar E4.
