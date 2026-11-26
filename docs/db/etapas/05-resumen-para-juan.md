# E5 — Resumen para Juan (backend): transferencias

**Estado (2026-11-23):** implementado y probado en la base (`db/sql/15_transferencias.sql`), **a la espera de la auditoría del responsable de BD**. Las decisiones D-E5-8/9/10 son **provisionales** (equipo); no las trates como definitivas.

## 1. Firmas (ambas `SECURITY DEFINER`; `banco_app` solo tiene `EXECUTE`)

| Endpoint | Llamada | Devuelve |
|---|---|---|
| `GET /destinatario/:numero` | `SELECT nombre_destinatario($1 /*usuario_id de la sesión*/, $2 /*numero tal cual lo escribió el usuario*/)` | `jsonb` `{ "nombre": "Nombres Apellidos" }` |
| `POST /envios` | `SELECT hacer_transferencia($1 /*usuario_id*/, $2 /*numero_destino*/, $3 /*monto como TEXTO*/, $4 /*nota o NULL*/, $5 /*bolsillo_origen o NULL*/)` | `jsonb` `{ "id": uuid, "fecha": timestamptz ISO }` (el front no lee la salida: basta responder 200) |

Todo error de negocio llega como **`P0001`** → tu 400 con el mensaje **tal cual** (y `Recurso no encontrado` → 403, como en el contrato).

## 2. Lo que debes hacer distinto
1. **`p_monto` como texto.** Pasa el número del body como cadena (`'150000.50'`) y deja que PostgreSQL lo convierta a `numeric`. Si lo conviertes a `float`, un `0.30000000000000004` llega con más de 2 decimales y la BD responde `Monto inválido` (correcto, pero evitable).
2. **`p_bolsillo_origen` es `text`**, tal cual llegó (vacío, ausente o basura es válido para la BD): ausente/vacío = cuenta principal; un valor que no es de un bolsillo **propio** (ajeno, inexistente o mal formado) = `Recurso no encontrado`. **No lo conviertas a uuid** en el backend (un uuid mal formado sería un 503).
3. **`nombre_destinatario` lleva `p_usuario_id`** (el contrato original lo omitía). Exige sesión viva: sin sesión no hay consulta de nombres (cierra la enumeración anónima). **D-E5-10, provisional:** coordinemos la firma; **limita la tasa** de consultas en el backend.
4. **No hay idempotencia:** un doble clic o un reintento automático hacen **dos** envíos (cada uno es atómico y el saldo nunca queda negativo). No reintentes un `POST /envios` por tu cuenta.
5. El front hoy muestra `Bolsillo no encontrado` solo en el mock: el contrato manda **`Recurso no encontrado`**.

## 3. Mensajes (exactos del contrato §6) y su orden
`Sesión inválida` / `Acceso denegado` / mensaje de bloqueo (E4) → `Monto inválido` → `Cuenta no encontrada` (destino inexistente o mal formado) → `No puedes enviarte dinero a ti mismo` → `Recurso no encontrado` (bolsillo) → `Nota inválida` (**provisional**, D-E5-8: más de 140 caracteres) → `Saldo insuficiente` (lo decide el libro, con el saldo ya bloqueado).
Si el destino o el bolsillo se borran justo mientras se procesa el envío, el resultado es `Cuenta no encontrada` / `Recurso no encontrado` (nunca un error interno ni un 503) y no queda nada a medias.

## 4. Pendiente del equipo (valores provisionales centralizados)
* **D-E5-8:** longitud máxima de la nota (140) y el mensaje `Nota inválida`.
* **D-E5-9:** ¿se puede enviar a una cuenta **bloqueada**? Provisional: **sí** (bloquear restringe al titular, no la recepción). Un solo punto de cambio en la función.
* **D-E5-10:** `nombre_destinatario` con `p_usuario_id` y exposición del nombre completo a cualquier cliente que conozca un número de cuenta.
* Sin límites diarios, comisiones ni idempotencia (no están en el spec ni en el contrato).
* `avanzar_hasta` (cobro lazy de intereses antes de enviar) llega con **E7**; mientras tanto el saldo de un bolsillo no devenga interés.
