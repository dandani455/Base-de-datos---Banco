# Etapa 6 — Bolsillos (sin interés) · DISEÑO TÉCNICO v2 (compacto, para aprobación final)

**Estado (2026-11-24):** diseño **aprobado** por el responsable de BD e **implementado** — ver `06-bolsillos.md` (resultados, desviaciones y evidencias). *Desviaciones respecto de este diseño:* los 2 mensajes nuevos viven en `_reglas_bolsillo()` y no en `_msg_negocio` (esa función es de E5, que no se modifica); el inventario final es de **61** funciones (52 + 4 helpers + 5 públicas). Texto original del diseño v2:

v2. Aprobados por el responsable de BD: **D-E6-1 a D-E6-6, D-E6-8 y D-E6-9** (estos dos últimos como provisionales del equipo). **D-E6-7 queda resuelta por el contrato y `Balance.tsx`: `vista_balance(p_usuario_id)` entra en E6** (no se aplaza a E10; no se consulta a Juan; el monto como texto sigue siendo el criterio de E5). **No se ha escrito SQL ni se ha implementado nada.** Sin commits; no se toca `front/`, backend ni E5; no se empieza E7.
Reutiliza: E2 (`_asentar_grupo` y las plantillas `BOLSO_INGRESO`, `BOLSO_RETIRO`, `BOLSO_MOVIMIENTO`: cuadre, bloqueo ordenado, saldo ≥ 0), E3 (`_reloj_instantanea()` una vez por operación), E4 (`_validar_cliente`, `_norm_texto`, `_msg_auth`) y E5 (`_validar_monto`, `_msg_negocio`, patrón de carreras). **E5 no se modifica.**

## 1. Alcance

| Entra en E6 | No entra |
|---|---|
| `crear_bolsillo`, `mover_a_bolsillo` (ingresar), `retirar_de_bolsillo`, `mover_entre_bolsillos` **y `vista_balance`** (= `GET /bolsillos`) con su helper `balance_total` | Interés del 12 % y `avanzar_hasta` (**E7**, depende de D1); `vista_dashboard` y `vista_historial` (**E10**; el dashboard reutilizará `balance_total`); borrar o renombrar bolsillos (no existen en el contrato) |

## 2. Contrato del front (contraste)

| Endpoint | Función BD | Entrada → parámetros | Salida | Errores `P0001` |
|---|---|---|---|---|
| `GET /bolsillos` | **`vista_balance(p_usuario_id uuid)`** | el backend añade `p_usuario_id` | `jsonb` `{ total, principal, bolsillos: [{ id, nombre, saldo }] }` (contrato §3.2/§4; `types.ts` `Balance`) | solo los de sesión (E4) |
| `POST /bolsillos` | `crear_bolsillo(p_usuario_id uuid, p_nombre text)` | `{ nombre }` | `{ id, nombre }` (el front no lee la salida) | `Nombre de bolsillo inválido` (**nuevo**, D-E6-8) + sesión (E4) |
| `POST /bolsillos/:id/ingresar` | `mover_a_bolsillo(p_usuario_id uuid, p_bolsillo_id text, p_monto numeric)` | `{ monto }`: **cuenta → bolsillo** | `{ id, fecha }` | `Monto inválido` · `Recurso no encontrado` · `Saldo insuficiente` |
| `POST /bolsillos/:id/retirar` | `retirar_de_bolsillo(p_usuario_id uuid, p_bolsillo_id text, p_monto numeric)` | `{ monto }`: **bolsillo → cuenta** | `{ id, fecha }` | ídem |
| `POST /bolsillos/:id/mover` | `mover_entre_bolsillos(p_usuario_id uuid, p_bolsillo_origen text, p_bolsillo_destino text, p_monto numeric)` | `{ monto, destino_id }` | `{ id, fecha }` | ídem + `Los bolsillos de origen y destino deben ser distintos` (**nuevo**, D-E6-9) |

Notas para Juan: (1) la tabla del contrato §3.3 sale ilegible en el PDF; las entradas se tomaron de `Balance.tsx` y del texto del contrato (`ingresar {monto}`, `retirar {monto}`, `mover {monto, destino_id}`); si `retirar` debe aceptar un `destino_id`, avísanos. (2) Ids y monto como **texto**, igual que E5 (criterio ya establecido). (3) `Recurso no encontrado` → 403. (4) `vista_balance` devuelve los ids de bolsillo como texto uuid: el front los usa tal cual en `/bolsillos/:id/…` y en `destino_id`.

## 3. Cómo funcionan (todas `SECURITY DEFINER`, `search_path = public, pg_temp`)

```
mover_a_bolsillo / retirar_de_bolsillo / mover_entre_bolsillos
1 _validar_cliente(p_usuario_id)                       sesión viva                                           (E4)
2 _validar_monto(p_monto)                              'Monto inválido'                                      (E5)
3 _bolsillo_propio(cuenta, texto) [x1 o x2]            uuid válido y de MI cuenta; si no 'Recurso no encontrado'  (nuevo, reutilizable E7–E9)
4 (mover) origen = destino → mensaje D-E6-9
5 UNA _reloj_instantanea()  →  [punto avanzar_hasta, E7]  →  _asentar_grupo(ahora, [pata CUENTA/BOLSILLO S, pata BOLSILLO/CUENTA E])   'Saldo insuficiente' lo da el libro
6 → { id: grupo, fecha: ahora }
crear_bolsillo: sesión → nombre (D-E6-8) → UNA instantánea → INSERT bolsillo (balance 0, ultimo_cobro = hoy, creado_en = ahora) → { id, nombre }
vista_balance:  sesión (_validar_cliente) → [punto avanzar_hasta, E7] → UNA sentencia de lectura → { total, principal, bolsillos[] }
```
* Un helper interno `_mover_bolsillo(...)` arma las patas, llama al libro y traduce carreras; las 3 públicas son delgadas.
* **Libro:** patas con `nota NULL` y `contraparte_nombre` = **nombre del bolsillo del otro lado** (snapshot de texto; sobrevive a borrados). Mismo `fecha`, grupo y `tx_id` en las 2 patas.
* **Carreras** (traducidas, nunca no-`P0001`): bolsillo borrado entre validar y bloquear → `Recurso no encontrado`; cuenta borrada → `Sesión inválida`; en `crear_bolsillo`, usuario borrado → violación de FK capturada → `Sesión inválida`.
* **Concurrencia de movimientos:** el libro bloquea primero la fila de la **cuenta** (orden de id) y todos los movimientos de un cliente se serializan ahí; mover A→B ∥ B→A no puede hacer deadlock entre bolsillos (se prueba, no se supone).

### 3.1 `vista_balance` y `balance_total` (D-E6-7 resuelta)
* **`vista_balance(p_usuario_id uuid) → jsonb`:** pública (`banco_app`). Tras la sesión devuelve `total` = `balance_total(cuenta)`, `principal` = `cuenta.balance` y `bolsillos` = arreglo de `{ id (texto uuid), nombre, saldo }` con `saldo` = `bolsillo.balance`, **solo los de la cuenta del invocador**, orden estable (`creado_en`, luego `id`). Sin bolsillos devuelve `[]`, nunca `null`. Importes como número JSON con 2 decimales (transporte D.8 del plan general). Un cliente bloqueado o un admin recibe los mismos mensajes de sesión que en el resto de funciones (el contrato relee el estado en cada petición).
* **`balance_total(p_cuenta_id uuid) → numeric`:** helper **interno** (nadie salvo el dueño; no se concede a `banco_app`), `STABLE`. Es el **único punto** que define «total» (contrato: `balance_total()`); `vista_dashboard` (E10) lo reutilizará. **Composición provisional D-E6-12 (D6 pendiente del equipo):** hoy `total = cuenta.balance + Σ bolsillo.balance`. CDT vigentes y deudas de crédito **no** se suman todavía, porque cómo entran (con o sin interés generado, restando la deuda: el spec dejaría el total negativo) es exactamente D6; hasta E7–E9 esas tablas no tienen filas, así que el valor ya coincide con cualquier resolución de D6. Cuando el equipo decida, solo cambia esta función.
* **Lectura consistente sin bloquear:** `principal`, `bolsillos` y `total` salen de **una sola sentencia** (un único snapshot en `READ COMMITTED`); por eso `balance_total` es `STABLE` (una función `VOLATILE` tomaría su propia foto y podría ver un movimiento a medias entre `principal` y los bolsillos: la lección ya vista en E4). Garantía comprobada: `total = principal + Σ saldos` en **cada** respuesta, incluso con movimientos concurrentes. Si el usuario desaparece entre la sesión y la lectura, la función responde `Sesión inválida` (nunca `NULL` ni un error de driver): rama de defensa que no se puede forzar por tiempo (la lectura no toma el reloj ni la cuenta), documentada como tal.
* **No calcula interés:** `vista_balance` solo lee. El devengo es **exclusivo** de `avanzar_hasta` (E7), que escribirá `INTERES_BOLSO` por `_asentar_grupo`; E6 no duplica ni adelanta esa lógica.

### 3.2 Punto de integración con `avanzar_hasta` (E7) — cómo se garantizará el devengo
Mover dinero cambia la base del interés; por eso, **antes** de cualquier función que lea o modifique saldos de bolsillo, E7 debe devengar hasta hoy. E6 deja un punto marcado y fijo en **seis** funciones: `vista_balance`, `mover_a_bolsillo`, `retirar_de_bolsillo`, `mover_entre_bolsillos`, `crear_bolsillo` (uniformidad con el contrato §1; coste nulo) y, ya existente, `hacer_transferencia` (E5, D-E5-5). Plan para E7, que aquí solo se documenta:
1. **Una sola instantánea:** la operación toma `_reloj_instantanea()` una vez y **pasa** `(hoy, ahora)` a un `_avanzar_hasta(cuenta, hoy, ahora)` interno; `avanzar_hasta` no vuelve a leer el reloj (se respeta «una instantánea por operación»).
2. **Mismo bloqueo:** `avanzar_hasta` toma primero el bloqueo de la fila de la cuenta (el mismo que usa el libro), de modo que ningún movimiento ajeno se cuela entre el devengo y la operación, y el interés se calcula sobre el saldo realmente vigente.
3. **Cobertura por prueba, no por memoria:** E7 añadirá un escaneo del catálogo («toda función de `banco_app` que lee o mueve saldos de bolsillo llama a `_avanzar_hasta`»), más una mutación que lo quite de cada una. Una función nueva que olvide el punto hace fallar la prueba.
4. En E7, `vista_balance` pasa de lectura pura a lectura que escribe (devenga y luego lee); como entonces ya habrá tomado el bloqueo de la cuenta, la lectura posterior es consistente aunque sean sentencias separadas.

## 4. Qué prueba E6 (solo riesgos propios; E2/E5 no se repiten)

| Riesgo | Cómo | Dónde (nuevo) |
|---|---|---|
| Mensajes y orden, 3 movimientos, bolsillo ajeno/mal formado/inexistente, mismo bolsillo, saldo exacto y +0,01 en cada origen | SQL | `52_bolsillos.test.sql` |
| Patas correctas (plantilla, contraparte snapshot, misma fecha/grupo), `ultimo_cobro`/`creado_en` con la instantánea (reloj manual), una sola instantánea, ningún `INSERT/UPDATE` de saldos (solo el `INSERT` de `crear_bolsillo`) | SQL + escaneo del catálogo | `52` |
| Nombres: recorte/colapso, 40 vs 41, vacío/NULL/control, duplicados permitidos, no `UNIQUE` | SQL | `52` |
| **`vista_balance`:** forma exacta (claves, `id` texto uuid, números), `[]` sin bolsillos, orden estable, solo bolsillos propios (no se filtran los ajenos), `total = principal + Σ saldos`, coherencia con el libro tras cada tipo de movimiento, sesión/bloqueado/admin con los mensajes de E4, ids de la vista usables directamente en las 3 funciones de movimiento, sin escrituras ni reloj (escaneo: sin `INSERT/UPDATE/DELETE`, `now()`, `_reloj_instantanea`) | SQL + escaneo | `52` |
| **`balance_total`:** única definición de «total», `STABLE`, sin acceso para `banco_app`/`banco_lector`/`PUBLIC`, cuentas sin bolsillos y con varios | SQL | `52` |
| Atomicidad (fallo `tx:1`/`tx:2`, corte de conexión) | `tests.instalar_fallas` | `52`, `reales/43` |
| Conservación por cliente (cuenta + bolsillos), nunca negativo, 600 operaciones aleatorias contra un modelo (la vista se compara con el modelo en cada paso) | SQL | `53_bolsillos_aleatorio.test.sql` |
| Permisos con roles reales (12 funciones de `banco_app`; helpers nadie; `vista_balance` con TCP) | SQL + TCP | `52`, `reales/43` |
| Carreras: bolsillo/usuario borrado mientras espera el reloj | TCP | `reales/43` |
| Concurrencia: doble retiro del mismo bolsillo, mover A→B ∥ B→A, bolsillo ∥ envío E5 desde ese bolsillo, creación ∥ borrado de usuario, con cambios de reloj; **lecturas de `vista_balance` ∥ movimientos: cada respuesta cumple `total = principal + Σ saldos` y el total del cliente es constante** | TCP | `reales/44` |

Adaptaciones mínimas: `03`/`10`/`45` (inventario 52 → **61** funciones: +3 helpers de movimiento, +`balance_total`, +4 de movimiento y +`vista_balance`; lista blanca de `banco_app` 7 → **12**), `09_integridad.sql`, `09_idempotencia`. **Mutaciones ≈ 19** (las ≈ 14 de movimientos, más: `vista_balance` sin sesión, `total` que omite los bolsillos, bolsillos sin filtro de cuenta —filtra los de otros—, `NULL` en vez de `[]`, `balance_total` `VOLATILE` —lectura rota, detectada por la concurrencia de `reales/44`—, `balance_total` o helper concedido a `banco_app`). Total esperado ≈ **160** aserciones nuevas.

## 5. Decisiones

| ID | Decisión | Quién | Estado |
|---|---|---|---|
| D-E6-1 | 5 funciones públicas con ids y monto como `text`/`numeric`, salidas `jsonb` (`{id, nombre}` al crear; `{id, fecha}` al mover; `{total, principal, bolsillos}` en la vista); nombres del contrato §B.2 | BD | **Aprobada** (ampliada con la vista) |
| D-E6-2 | Orden: sesión → monto → bolsillo(s) → (mismo bolsillo) → instantánea → libro; mensajes exactos del contrato §6 | BD | **Aprobada** |
| D-E6-3 | Solo plantillas E2 existentes; `nota` NULL; `contraparte_nombre` = nombre del bolsillo (snapshot) | BD | **Aprobada** |
| D-E6-4 | Helpers internos nuevos (`_bolsillo_propio`, `_mover_bolsillo`, `_reglas_bolsillo`, **`balance_total`**); lista blanca de `banco_app` 7 → **12** (4 de movimiento/creación + `vista_balance`); E5 no se toca | BD | **Aprobada** (ajustada: 11 → 12 y +1 helper) |
| D-E6-5 | `avanzar_hasta` diferido a E7 (punto marcado en 6 funciones; contrato de integración en §3.2) | BD | **Aprobada** |
| D-E6-6 | `crear_bolsillo` toma UNA instantánea: `ultimo_cobro` = hoy, `creado_en` = ahora | BD | **Aprobada** |
| D-E6-7 | **`vista_balance(p_usuario_id)` entra en E6** (contrato §3.2/§4 + `Balance.tsx`): `{ total, principal, bolsillos:[{id, nombre, saldo}] }`. No se consulta a Juan | BD (resuelta por contrato/front) | **Resuelta; pendiente solo tu aprobación final del diseño** |
| **D-E6-8** | **Equipo, provisional:** nombre = texto normalizado, 1–40 caracteres, sin caracteres de control; error `Nombre de bolsillo inválido`; **nombres repetidos permitidos** (sin `UNIQUE` en E1); **sin tope** de bolsillos | Equipo | **Aprobada como provisional**; centralizada en `_reglas_bolsillo()`/`_msg_negocio` |
| **D-E6-9** | **Equipo, provisional:** mover un bolsillo a sí mismo → `Los bolsillos de origen y destino deben ser distintos` | Equipo | **Aprobada como provisional** |
| D-E6-10 | **Negocio pendiente (sin implementar):** renombrar o borrar bolsillos; qué pasa con un bolsillo con saldo al borrarlo; tope de bolsillos | Equipo | no se inventan |
| D-E6-11 | **Pendiente D8 (E10):** si los movimientos cuenta↔bolsillo salen en el historial; E6 solo garantiza los datos | Front | E10 |
| **D-E6-12** | **Equipo, D6 pendiente (provisional):** composición de `balance_total` = `cuenta.balance + Σ bolsillo.balance`; CDT y créditos se incorporan cuando el equipo resuelva D6 (E7–E9/E10). Un solo punto de cambio | Front + equipo | **Provisional** |

## 6. Riesgos y límites
* Sin `avanzar_hasta`, el saldo de un bolsillo no devenga interés hasta E7 (D-E6-5); `vista_balance` mostrará el saldo sin interés pendiente hasta entonces.
* `total` no incluye todavía CDT ni deuda (D-E6-12): correcto hoy (no existen), pero **no** debe presentarse como la definición final de D6.
* Doble clic = dos movimientos (sin idempotencia, como E5); cada uno es atómico y nada queda negativo. Crear dos veces el mismo nombre crea dos bolsillos (D-E6-8).
* Un movimiento ya en curso no se cancela si el usuario es bloqueado a mitad (se lee el estado al iniciar). Superusuario: límite ya documentado.
* Un bolsillo con asientos no se puede borrar suelto (FK del libro); solo desaparece con el borrado en cascada del usuario (E11).
* La rama «usuario borrado entre la sesión y la lectura» de `vista_balance` es defensa no forzable por tiempo: queda sin prueba determinista y así se documentará.

## 7. Resumen para Juan
`GET /bolsillos` → `SELECT vista_balance($1 /*usuario_id*/)` → `{total, principal, bolsillos:[{id, nombre, saldo}]}` (pásalo tal cual; los ids son texto uuid). `SELECT crear_bolsillo($1, $2 /*nombre tal cual*/)` → `{id, nombre}` · `SELECT mover_a_bolsillo($1, $2 /*:id del bolsillo, texto*/, $3 /*monto como TEXTO*/)` · `retirar_de_bolsillo($1, $2, $3)` · `mover_entre_bolsillos($1, $2 /*:id origen*/, $3 /*destino_id*/, $4 /*monto TEXTO*/)` → `{id, fecha}`. Errores `P0001` → 400 con el mensaje tal cual (`Recurso no encontrado` → 403). No pases el id a `uuid` en el backend.

## 8. Plan (cuando apruebes)
`16_bolsillos.sql` (4 helpers, 5 funciones, permisos) → ajustes de `09`/inventarios → `52`, `53`, `reales/43`, `44` → mutaciones → reset + 3 `apply` + suite completa → `06-bolsillos.md` corto con evidencias y guía pgAdmin. Una sola entrega y parada para tu auditoría; sin commits y sin empezar E7.
