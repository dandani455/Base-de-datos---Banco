# Etapa 5 — Transferencias · DISEÑO TÉCNICO (compacto, para aprobación)

**Estado (2026-11-23):** diseño **aprobado** (D-E5-1..7); **implementado** — ver `05-transferencias.md` (resultados, desviaciones y evidencias). Sin commits; no se toca `front/` ni backend; no se empieza E6. D-E5-8/9/10 siguen **provisionales** (equipo). *Desviación respecto de este diseño:* un helper interno extra, `_reglas_transferencia()` (la constante de la nota en un solo lugar), por lo que la BD tiene **52** funciones en `public` (no 51), y la traducción de carreras cubre también al **emisor borrado** (`Sesión inválida`).
Reutiliza E2 (`_asentar_grupo`: bloqueo ordenado, cuadre, atomicidad, plantillas `ENVIO_CUENTA` y `ENVIO_BOLSILLO`), E3 (`_reloj_instantanea()` una sola vez) y E4 (`_validar_cliente`, `_norm_digitos`, patrón de mensajes, parámetros `text`).

## 1. Alcance

| Entra en E5 | No entra |
|---|---|
| `nombre_destinatario`, `hacer_transferencia` (origen: cuenta principal **o** un bolsillo, con la plantilla `ENVIO_BOLSILLO` que ya existe) | Crear/mover bolsillos (**E6**); `avanzar_hasta` y el interés (**E7**); la lista de movimientos `vista_historial` (**E10**); bloquear/desbloquear usuarios (**E11**) |
| `_validar_monto` y `_msg_negocio` (helpers que reutilizarán E6–E9) | Límites diarios, comisiones, idempotencia (no existen en el spec) |

## 2. Contrato del front (contraste)

| Endpoint | Función | Entrada → parámetros | Salida | Errores `P0001` (exactos del contrato §6) |
|---|---|---|---|---|
| `GET /destinatario/:numero` | `nombre_destinatario(p_usuario_id uuid, p_numero_cuenta text)` | el backend añade `p_usuario_id` | `jsonb` `{ nombre }` = nombres + apellidos | `Cuenta no encontrada` |
| `POST /envios` | `hacer_transferencia(p_usuario_id uuid, p_numero_destino text, p_monto numeric, p_nota text, p_bolsillo_origen text)` | `{ numero_destino, monto, nota, bolsillo_origen? }` | `jsonb` `{ id, fecha }` (el front no lee la salida; basta 200) | `Monto inválido` · `Cuenta no encontrada` · `No puedes enviarte dinero a ti mismo` · `Recurso no encontrado` (bolsillo ajeno/inexistente) · `Saldo insuficiente` · `Acceso denegado`/bloqueo/`Sesión inválida` (de E4) |

Diferencias a comunicar a Juan (ver sección 7): (1) `nombre_destinatario` lleva `p_usuario_id` (el contrato lo omite por inconsistencia con su propia regla §1; **D10 del equipo**); (2) `p_bolsillo_origen` es `text` (un `uuid` mal formado sería 503, lección de E4); (3) `p_monto numeric`: el backend debe pasar el número **como texto**, no `float` (un `0.30000000000000004` da `Monto inválido`, correcto); (4) el mock usa `Bolsillo no encontrado`; el contrato manda: `Recurso no encontrado`.

## 3. Cómo funciona `hacer_transferencia` (una sentencia = una transacción, `SECURITY DEFINER`)

```
1 _validar_cliente(p_usuario_id)          sesión viva (rol CLIENTE, no bloqueado)                       (E4)
2 _validar_monto(p_monto)                 NULL/NaN/≤0/más de 2 decimales/> parametro.monto_maximo → 'Monto inválido'
3 destino: _norm_digitos(p_numero_destino,false) = 10 dígitos y existe una cuenta → si no: 'Cuenta no encontrada'
4 destino = mi cuenta                     → 'No puedes enviarte dinero a ti mismo'
5 bolsillo origen (texto uuid, opcional)  existe y es de MI cuenta → si no: 'Recurso no encontrado'
6 nota: recorte; vacía = NULL; máx. 140   (D-E5-8)
7 UNA instantánea: SELECT ahora FROM _reloj_instantanea()
8 _asentar_grupo(ahora, [ENVIO (cuenta o bolsillo) S, RECIBO (cuenta destino) E])   ← bloquea ambas cuentas en orden de id; 'Saldo insuficiente' lo da el libro
9 → { id: grupo, fecha: ahora }
```
* **Libro (reutilizado de E2):** las 2 patas llevan `nota`, `contraparte_cuenta` = número de la otra cuenta y `contraparte_nombre` = nombre completo de la otra parte (instantánea de texto, sobrevive a los borrados). Mismo `fecha` y `tx_id`; el débito y el crédito son una sola transacción (E2 ya prueba atomicidad, cuadre y ausencia de deadlocks).
* **Carreras:** destino borrado entre la consulta y el bloqueo → el libro avisa («alguna cuenta del grupo no existe»), y la función lo traduce a `Cuenta no encontrada`; bolsillo borrado → `Recurso no encontrado`. Nunca llega un error no-`P0001` (sería 503).
* **Orden de validación (D-E5-2):** monto antes que destino, para que un cliente no pueda sondear números de cuenta con montos inválidos y para que el mensaje de un destino inexistente no se revele a quien manda datos malformados. El mock valida destino primero; el contrato no fija el orden.
* **`avanzar_hasta` (contrato §1):** no existe hasta E7. **Desviación consciente y temporal (D-E5-5):** E5 deja marcado el punto (tras el paso 5) donde E7 añadirá `PERFORM avanzar_hasta(p_usuario_id)`; E7 lo prueba. El saldo de bolsillo que se mueve en E5 todavía no devenga interés.

`nombre_destinatario`: `_validar_cliente` + misma normalización y búsqueda; devuelve `{ nombre }` (nombres + apellidos del dueño). No ejecuta el reloj ni el libro. Un cliente **bloqueado** o un admin no puede consultar (cierra la enumeración anónima: hace falta sesión viva).

## 4. Garantías y qué prueba E5 (sin repetir E2)

| Garantía | Cómo | Dónde (nuevo) |
|---|---|---|
| Todo movimiento por `_asentar_grupo` | ningún `INSERT`/`UPDATE` de saldos en el código | escaneo del catálogo + mutación |
| Atomicidad | fallos inyectados (`tests.instalar_fallas`, ya existe) en la 1.ª y 2.ª pata y corte de conexión: el emisor **no** pierde dinero | `50` y `reales/41` |
| Integridad contable | conservación (Σ saldos constante), nunca negativo, patas ENVIO/RECIBO con contrapartes cruzadas, `v_integridad_*` en orden tras 600 operaciones aleatorias contra un modelo | `51` |
| Concurrencia | 6 envíos de 800 con saldo 1000 → gana 1; A↔B cruzados sin deadlock; muchos→uno con saldo exacto; envíos ∥ cambios de reloj | `reales/42` |
| Reloj | una sola `_reloj_instantanea()`; ninguna función usa `now()`/`current_date`; ambas patas con la misma fecha | `50` (escaneo + conteo) |
| Permisos | `banco_app` ejecuta las 2 funciones y nada más; lector/dev; internas nadie; sin acceso a tablas | `50` (rol real) y `reales/41` (TCP) |

Adaptaciones mínimas: `03`/`10`/`45` (inventario 47 → 51 funciones y lista blanca de `banco_app` 5 → 7), `09_integridad.sql` (la lista blanca exacta pasa a 7), `_msg_negocio` fijado por prueba. **Mutaciones nuevas ≈ 14** (sin validar sesión, monto, autoenvío, ownership del bolsillo, `now()`, dos instantáneas, dinero sin contraparte, mapeo de carreras, permisos). Total esperado ≈ 130 aserciones nuevas.

## 5. Decisiones

| ID | Decisión | Quién | Recomendación / valor provisional |
|---|---|---|---|
| D-E5-1 | Firmas con `text` en `p_numero_*`/`p_bolsillo_origen`, `p_monto numeric`, salidas `jsonb` | BD | Sí |
| D-E5-2 | Orden de validación (monto → destino → autoenvío → bolsillo → saldo) y mensajes exactos del contrato | BD | Sí |
| D-E5-3 | Patas con nota, contrapartes cruzadas y nombre completo; bolsillo origen por la plantilla `ENVIO_BOLSILLO` | BD | Sí |
| D-E5-4 | `_validar_monto` y `_msg_negocio` como helpers internos reutilizables (E4 no se toca) | BD | Sí |
| D-E5-5 | `avanzar_hasta` se difiere a E7 (punto documentado; desviación temporal del contrato §1) | BD | Sí |
| D-E5-6 | Una instantánea; ambas patas con la misma fecha; carreras traducidas a `Cuenta no encontrada`/`Recurso no encontrado` | BD | Sí |
| D-E5-7 | Whitelist de `banco_app`: 5 → 7 funciones (`09_integridad.sql`) | BD | Sí |
| **D-E5-8** | **Equipo (D12b/D13), provisional:** longitud máxima de la nota **140** y mensaje `Nota inválida` (nuevo) | Equipo | provisional, centralizado en `_msg_negocio` y una constante |
| **D-E5-9** | **Equipo (D12b), negocio pendiente:** ¿se puede enviar a una cuenta **bloqueada**? | Equipo | provisional: **sí** (bloquear restringe al titular, no la recepción; coherente con D-E4-19); un solo punto de cambio |
| **D-E5-10** | **Equipo/Juan (D10):** `nombre_destinatario` con `p_usuario_id` (exige sesión) y exposición del nombre completo a cualquier cliente que conozca un número de cuenta | Juan + front | provisional: con `p_usuario_id`; el backend debe limitar la tasa de consultas |
| D-E5-11 | **Negocio pendiente:** límites por envío/diarios, comisiones e idempotencia (doble clic = dos envíos). No existen en spec/contrato; **no se inventan** | Equipo | sin límites más allá de `monto_maximo` técnico |

## 6. Riesgos y límites
* **Doble clic = dos envíos** (el contrato no trae clave de idempotencia): la mitigación es del front/backend; cada envío es atómico y el saldo nunca queda negativo.
* **Enumeración** de cuentas y nombres con `nombre_destinatario` (spec 7.3 lo exige): exige sesión viva; rate limit en el backend.
* El estado `BLOQUEADO` del emisor se lee al iniciar; un bloqueo concurrente no cancela un envío ya en curso (instantes). Superusuario: límite ya documentado.
* El interés devengado de un bolsillo no se acredita antes de enviar hasta E7 (D-E5-5).

## 7. Resumen para Juan
`SELECT nombre_destinatario($1 /*usuario_id de la sesión*/, $2 /*numero, tal cual lo escribió el usuario*/)` → `{nombre}`. `SELECT hacer_transferencia($1, $2 /*numero_destino*/, $3 /*monto como TEXTO ('150000.50'), no float*/, $4 /*nota o NULL*/, $5 /*bolsillo_origen o NULL, texto*/)` → `{id, fecha}`; responde 200. Errores `P0001` → 400 con el mensaje tal cual (`Recurso no encontrado` → 403). `bolsillo_origen` vacío o ausente = cuenta principal. Sin idempotencia: evita reenvíos automáticos.

## 8. Plan (cuando apruebes)
`15_transferencias.sql` (helpers, 2 funciones, permisos) → ajuste de `09` y de las pruebas de inventario → `50`, `51`, `reales/41`, `42` → mutaciones → reset + 3 `apply` + suite completa → `05-transferencias.md` corto con evidencias. Una sola entrega y parada para tu auditoría; sin commits y sin empezar E6.
